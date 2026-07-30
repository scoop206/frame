# The head frame — driving work through frames

*Design note. Captures how an operator (or an orchestrator Claude) drives a plan
of work through worker frames: the head frame concept, the atomicity
convention, and concrete specs for the two gating primitives —
`frame inbox --wait` and `frame spawn`. Builds directly on
[agent-messaging](agent-messaging.md); this is its phase 4 made concrete.*

## The idea

The operator needs their own frame — one with **no worktree and no branch** —
from which to command workers and collect their replies. A "head" drives a plan
(a list of commands) by dispatching each atomic piece of work to a worker
frame, verifying the reply, and moving on:

```
"Determine what two plus two is"
verify we got the right answer back.
Once verified, figure out what that answer plus seven would be.
verify that answer.
put that answer in a report at ~/tmp/answer
```

## The head is not a new frame kind

[agent-messaging.md](agent-messaging.md) already commits to this: roles are
emergent, every endpoint is a frame, and *"the operator doesn't message from a
bare shell — they sit inside a frame and command from there."* The head is that
frame. Two consequences:

- **The branchless home frame already exists: `frame shell`.** No repo, no
  branch, no worktree — but full identity (socket + `FRAME_NAME`/`FRAME_TOPIC`),
  Stop hooks, and an inbox. "The operator's own frame" is the shell frame's job
  description.
- **The operator's frame and the head are the same object at two levels of
  automation.** Drive it by hand (`frame req` / `frame inbox` yourself), or seed
  its Claude with an orchestrator prompt + a plan and let it drive. A future
  `frame head` entry point is just `frame shell` + that seeding — **not** a new
  mechanism. (Not `frame -h`: `-h` is `--help`, and top-level dispatch is by
  subcommand word, never a flag.)

The round-trip the head runs is the shipped one:

```
head:   frame req worker "do X"     → injects, arms one-shot reply
worker: …works, turn ends…          → Stop hook routes answer home
head:   frame inbox                 → reads the reply, verifies, next step
```

## What's actually missing — four primitives

1. **A blocking receive** — `frame inbox --wait`. The keystone. Reply delivery
   is async and the head goes idle after dispatching; the "wake a parked node"
   machinery was explicitly deferred. A *blocking* inbox read dissolves the
   problem: the head's Claude blocks on the subprocess, so dispatch→receive
   becomes one synchronous sequence inside a single turn. Spec below.
2. **Spawn a worker in a new window** — `frame spawn`. Nothing creates a frame
   *from* a frame today; `frame wt`/`frame shell` end in `exec nvim` and take
   over the current window. The head needs "open a new ghostty window running
   this frame." Spec below.
3. **Reaping + correlation** — who tears down the workers, and which reply
   answers which step when several are outstanding. `--from` covers correlation
   by sender for v1; `--ephemeral` reaping is a fast follow (below). Deferred
   while v1 is sequential.
4. **A result contract** — replies are free-text `last_assistant_message`;
   there is no headless `claude -p` path, so the reply *is* the result channel.
   A light convention (`RESULT: …` / `STATUS: ok|fail` lines in the worker's
   final message) makes "verify the answer" parseable rather than vibes.
   Convention-only; lives in the head's orchestrator prompt.

## The atomicity convention

Which pieces of a plan deserve their own frame is non-obvious — resolve it with
two axes, **author-declared with a fallback heuristic**, not guessed fresh each
run:

- **Axis 1 — inline vs. spin-out.** Inline = the head does it in its own Claude
  turn (verification, glue, cheap reasoning, passing data between steps).
  Spin-out = a self-contained deliverable another agent could produce without
  the head's running context. Every spin-out pays a full window + nvim + Claude
  boot — and with no headless claude, "inline" never means shelling out to a
  quick one-shot; it means *no worker at all*. "Determine 2+2" is inline.
- **Axis 2 — branchless vs. branch-bearing worker.** Maps onto existing tools:
  a worker producing **committable code** is a `frame wt TOPIC` (survives to
  merge); a worker producing an **answer/artifact with nothing to merge** is a
  `frame shell TOPIC` (ephemeral, reaped after reply).

Default heuristic for the head's prompt: *spin a worker when the step is a
self-contained deliverable; do it inline when it's judgment or glue.
Branch-bearing when the deliverable is code, branchless when it's an answer.*
Plan authors can override per step: `[inline]`, `[worker]`, `[worker:branch]`.
Frames earn their weight on isolatable code work you can see, focus, and jump
into — never spin a window to add two numbers.

---

## Spec: `frame inbox --wait`

```
frame inbox                     show + drain now (unchanged)
frame inbox --wait              block until ≥1 message, then drain + print
frame inbox --wait --timeout N  give up after N seconds (default 900)
frame inbox --wait --count K    block until ≥K messages present, then drain all (default 1)
```

**Poll from the client, not `vim.wait` in the server.** A blocking predicate
inside the head's own nvim would spin its event loop for up to the timeout —
freezing the editor the operator is sitting in. Instead the `frame inbox`
*subprocess* (which Claude's Bash tool is already blocking on) polls the socket
with cheap, instant RPCs, once per second. The nvim never blocks; the human
keeps their editor.

**Lua** (`layouts/worktree.lua`), one function beside `FrameInboxDrain`:

```lua
-- Drain only if the inbox has reached `n` entries; otherwise leave it and
-- return ''. Lets --wait block client-side without ever partially draining
-- (a peek that consumes would lose messages on a retry). n<=1 = "any mail".
_G.FrameInboxDrainAtLeast = function(n)
  if #FrameState.inbox < (n or 1) then return '' end
  return _G.FrameInboxDrain()
end
```

**Shell** (`commands/inbox.sh`): bare form byte-for-byte unchanged; `--wait`
loops `FrameInboxDrainAtLeast($count)` → non-empty prints and exits 0; else
sleep 1 until deadline.

Decisions:

- **Exit codes:** `0` mail delivered, `3` timed out empty, `1` no socket /
  layout predates the helper. The head branches on `3` — a distinct code, not
  empty-string sniffing.
- **Mail already waiting → returns immediately.** Never blocks when the
  answer's already home.
- **`--count K` is the fan-in barrier.** Drains *all* present once ≥K (a burst
  may exceed K). Entries carry `from NAME/TOPIC:`, so the head correlates
  replies by sender. Per-task correlation ids are a later refinement.
- **Cost:** one `nvim --headless` spawn per second, only while actively
  waiting. A persistent RPC connection is a later optimization.
- **This dissolves the idle-wake problem** for the sequential driver: the head
  receives synchronously inside its own turn, so it's never parked idle waiting
  to be woken. `--watch` and prompt-nudging stay deferred.

## Spec: `frame spawn`

```
frame spawn shell TOPIC [--req TEXT] [--timeout N]            projectless worker
frame spawn wt    TOPIC --cwd PATH [--req TEXT] [--timeout N] code worker in a project
```

A distinct verb, not a flag on `wt`: `wt`/`shell` *take over* the current
window (`exec nvim`) by design; spawn's intent is the opposite — new window,
don't replace me.

The composition with `--wait` is one round-trip:

```
head: frame spawn shell calc --req "compute 2+2, reply with just the number"
head: frame inbox --wait          → blocks…
                                  …worker boots, answers, Stop hook routes home
head: unblocks with "4"
```

Flow inside `commands/spawn.sh`:

1. `frame_assert_topic_free` — clean refusal instead of a topic collision.
2. `--req` requires `frame_self_identity` (the reply needs the head's return
   address — same rule `req` enforces).
3. Launch the window (the one OS-coupled line, below).
4. Wait for readiness — poll client-side like `--wait`: socket exists *and*
   claude buffer live, or timeout.
5. `--req` → deliver via the existing req path. Exit `0` ready(+sent), `3`
   boot timeout, `1` launch failed / topic taken.

**Readiness RPC** — `FrameInfo()` answers too early (defined before buffers
open); key on the claude channel, set at the *end* of boot:

```lua
_G.FrameReady = function() return FrameState.chan['claude'] ~= nil and 1 or 0 end
```

**The window-open line, pinned** (verified against Ghostty 1.3.1 — macOS has
no CLI new-window action; `ghostty +new-window` refuses on this platform):

```
open -na Ghostty.app --args --quit-after-last-window-closed=true -e zsh -ic '<bootstrap>'
```

with bootstrap `exec $FRAME_ROOT/bin/frame shell <topic>` (absolute path —
`open` launches via launchd, which drops the caller's environment; `zsh -ic`
sources zshrc so the worker's PATH comes up as a human's would). Findings:
`open -n` starts a *second app instance* per spawn; without the
`--quit-after-last-window-closed` config override that instance lingers
windowless in the dock after its frame exits — with it, it quits cleanly.
Isolated in `frame_open_window` (`lib/helpers.sh`) so everything above the
helper stays terminal-agnostic, mirroring how `focus` is frame's lone
AXRaise-coupled spot.

**Known limitation:** while a spawned worker is alive there are two Ghostty
processes, and `commands/focus.sh`'s `tell process "Ghostty"` may target the
wrong one — `frame focus` on a spawned frame is unreliable until focus.sh
iterates every process named Ghostty. Follow-up, not in this cut.

Open decisions:

1. **Project resolution for `wt` workers: explicit `--cwd PATH` in v1.** The
   head is projectless and frame has no name→path registry; `--cwd` keeps the
   head honest and defers the registry. Head-driven examples so far are all
   `shell` workers, so this doesn't gate the first cut.
2. **Reaping: `frame spawn … --ephemeral` as a fast follow.** A `wt` worker
   reaps with `frame wt -d TOPIC`; a shell frame today tears down only from
   *inside* (`:FrameDown!`), so a head can't clean up throwaway compute workers
   and windows pile up. `--ephemeral`: the worker's reply router
   (`FrameOnTurnEnd`), right after routing its answer home, self-tears-down the
   frame — throwaway workers vanish the instant they've reported.

## Build order

*Status: 1 and 2 are implemented and shipped; 3–5 are not yet built.*

1. **`frame inbox --wait`** — self-contained, no external uncertainty, testable
   by hand with two frames. ✅ shipped
2. **`frame spawn shell`** — pin the Ghostty line, wire readiness + `--req`.
   ✅ shipped (`frame spawn wt` refuses with a pointer here)
3. **`--ephemeral` reaping.**
4. **`frame spawn wt --cwd`.**
5. **`frame head`** — `frame shell` + orchestrator prompt + plan file, riding on
   all of the above. Sequential v1; fan-out (correlation ids, `--count`
   barriers) after.

## Related

- [agent-messaging.md](agent-messaging.md) — the req/reply/deliver/inbox
  round-trip and the emergent-roles model this drives through; the head is its
  phase 4.
- [identity-model.md](identity-model.md) — socket-is-identity; readiness and
  liveness checks here key off the socket, never the title.
- `commands/inbox.sh` · `layouts/worktree.lua` (`FrameInboxDrainAtLeast`) — the
  `--wait` implementation.
