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
4. **A result contract** — a frame worker's reply is free-text
   `last_assistant_message`, so the reply *is* the result channel. A light
   convention (`RESULT: …` / `STATUS: ok|fail` lines in the worker's final
   message) makes "verify the answer" parseable rather than vibes.
   Convention-only; lives in the head's orchestrator prompt. (Headless
   `claude -p --output-format json` returns structured results natively —
   one more reason it's the right rung for answer-only steps; see the tiers
   below.)

## The atomicity convention

Which pieces of a plan deserve their own frame is non-obvious — resolve it with
two axes, **author-declared with a fallback heuristic**, not guessed fresh each
run:

- **Axis 1 — how much machinery the step earns.** Four rungs:
  - **Inline** — the head does it in its own Claude turn (verification, glue,
    cheap reasoning, passing data between steps). No process spawned at all.
    "Determine 2+2" is inline.
  - **Subagent** — the Task-tool fan-out *inside* a claude (the head's or a
    worker's): fresh context, parallel, reports land in-context. Free — but
    the spawner frames the question and receives the answer, so it's an arm
    of its spawner, not an independent voice. Every worker frame has this for
    free, which raises the bar for giving a step its own sibling frame.
  - **Headless spin-out** — `claude -p "…"` from the head's own shell: a full
    agentic turn, tools included, but no window, no frame, no reply routing —
    stdout is the result, `--output-format json` makes it structured (and
    carries a session id, so a surprising verdict can be interrogated later
    with `--resume`). The rung for a self-contained *answer* nobody needs to
    watch or interrupt. Pays a claude boot; saves the window, nvim, readiness
    dance, and inbox entirely.
  - **Windowed worker** — `frame spawn` (ephemeral or not): a visible frame
    you can watch, focus, jump into, and `req` mid-task. Pays the full window
    + nvim + claude boot. The rung for work that runs long, touches a repo,
    or benefits from a glance.

  **QA belongs on the headless rung.** Verification is answer-only work where
  *independence of the asker* matters: a worker checking itself — even via a
  fresh subagent — grades its own homework, while the head probing a worker's
  output with `claude -p` (a prompt the worker never saw, a verdict the head
  parses) is an independent gate cheap enough to run after every step.
- **Axis 2 — branchless vs. branch-bearing worker.** Maps onto existing tools:
  a worker producing **committable code** is a `frame wt TOPIC` (survives to
  merge); a worker producing an **answer/artifact with nothing to merge** is a
  `frame shell TOPIC` (ephemeral, reaped after reply).

Default heuristic for the head's prompt: *inline for judgment and glue;
`claude -p` for a self-contained answer nobody needs to watch; a frame when
the deliverable is code or the work is worth a window. Branch-bearing when
there's something to merge, branchless when there isn't.* Plan authors can
override per step: `[inline]`, `[headless]`, `[worker]`, `[worker:branch]`.
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
frame spawn shell TOPIC [--req TEXT] [--timeout N] [--ephemeral]  projectless worker
frame spawn wt    TOPIC [--cwd PATH] [--req TEXT] [--timeout N]   code worker in a project
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
open), and the claude *channel* (captured at the end of boot) is still too
early: claude's own process takes seconds more to boot, and anything sent
meanwhile queues in the pty and arrives as one pasted chunk whose CR gets
swallowed. `FrameReady` therefore requires both the captured channel *and*
claude's input prompt (`❯`) rendered in the buffer — proof the TUI is reading
stdin, so `FrameRequest`'s deferred Enter registers as a real keypress. A
first-run trust dialog never renders `❯`; spawn times out and points a human
at the window.

**The window-open path, pinned** (verified against Ghostty 1.3.1): Ghostty
≥1.3 ships an AppleScript dictionary (`Ghostty.sdef` in the app bundle), so
`frame_open_window` (`lib/helpers.sh`) opens each worker as a **tab in one
shared workers window** of the running Ghostty — head keeps its own window,
workers congregate beside it. The last spawn's "WINDOW_ID TAB_ID" persists in
`/tmp/frame-workers.window`; reuse requires that exact pair to still exist —
Ghostty ids are address-based and recycle, and a bare window id once resolved
to the head window after a restart, piling workers in as tabs. Invalid pair →
fresh window, re-recorded. Dragging a tab out of the workers window rehomes it
under a new window id; focus and close-tab therefore fall back to scanning
every window for the recorded tab id.

**Recommended cockpit setup — a bare shell, until you need replies.** The
dispatch-and-watch commands (`frame ls`, `frame spawn`, `frame focus`) work
from any plain terminal — for a human-driven cockpit, head doesn't need to be
a frame at all: keep a bare shell window, spawn workers, tile the workers
window beside it. Head must BE a frame only for the reply half — `frame spawn
--req` and `frame inbox --wait` need a frame's inbox to receive — i.e. when
claude is the orchestrator. For that, open a fresh window and type `frame
shell head`: it takes the window over in place (`exec nvim`), nothing
spawned, nothing left behind. Avoid `frame spawn shell head` (head lands as a
tab among the workers and the launcher window is orphaned — if you do end up
there, drag the head tab out; recorded ids follow a tab wherever it lives),
and avoid `frame shell` from inside a frame (nests nvim-in-nvim — guarded
with a confirm/refusal, use spawn). The new
surface runs `/bin/zsh -ic '<bootstrap>'` via the scripting `command`
configuration and its window/tab ids are recorded to `/tmp/shell-<topic>.nvim.gtab`
for `frame focus` (select tab by id — no System Events, no Accessibility) and
reaping.

Bootstrap is `$FRAME_ROOT/bin/frame shell <topic>; $FRAME_ROOT/bin/frame
spawn close-tab <topic>` (absolute paths — the surface command drops the
caller's environment; `zsh -ic` sources zshrc so the worker's PATH comes up
as a human's would). No `exec`: scripted surfaces do **not** auto-close when
their command exits — they strand on `[Process exited]` even with
`wait after command:false` — so the tab's zsh survives nvim and closes its own
tab by recorded id, however the frame ended (`:FrameDown!` self-reap or plain
quit). Everything above `frame_open_window` stays terminal-agnostic.

Fallback (Ghostty <1.3 / no dictionary): the legacy separate-instance launch,
`open -na Ghostty.app --args --quit-after-last-window-closed=true -e zsh -ic
'<bootstrap>'` — no ids recorded, focus falls back to title matching, and the
extra instance quits with its window.

Open decisions:

1. **Project resolution for `wt` workers: `--cwd PATH`, defaulting to the
   current directory. ✅ shipped.** Frame has no name→path registry; `--cwd`
   (or standing in the project) keeps the caller honest and defers the
   registry. The worker's NAME comes from the target project's `.frame`
   config, resolved in a subshell so it can't pollute the caller. No
   `--ephemeral` for wt — a worktree frame's self-reap would force-delete a
   branch, which no spawn flag should reach.
2. **Reaping: `frame spawn … --ephemeral`. ✅ shipped (shell frames).** The
   flag rides into the worker as `FRAME_EPHEMERAL=1` in the window bootstrap —
   the frame is *born* ephemeral. Its reply router (`FrameOnTurnEnd`), right
   after routing its answer home, `jobwait`s the deliver jobs (they'd die with
   nvim) and self-tears-down via `:FrameDown!` — the dir vanishes, and the
   tab's surviving shell closes the tab by recorded id (`frame spawn
   close-tab`) the instant it has reported. Shell frames only for now: a worktree frame's `FrameDown!`
   force-deletes a branch, which no env var should be able to reach.

   **Ephemeral wt (future, rides on `spawn wt`): the merge-before-reply
   contract.** The worker's job is "do X, commit, `frame merge`, *then*
   reply" — so at reply-time the branch is merged and the reap can use the
   *plain* `frame wt -d`, no force anywhere. Teardown-success then IS the
   merged-ness gate: a worker that finished cleanly vanishes; one that ended
   its turn early (question, conflict, red tests) still routes its reply home
   but the reap refuses, leaving a live, inspectable frame as the attention
   flag. Self-merge trusts the worker's own done-judgment — the head can
   interpose a headless `claude -p` QA probe as the merge gate when that
   trust needs a check. Note the whole contract presumes **one claude per
   frame**: reply-means-done and reply routing assume the frame has a single
   mouth. A multi-claude frame (e.g. an adversarial pair sharing a worktree)
   needs buffer-qualified addresses, per-buffer arming, and an explicit
   completion act — its own design session, deferred.

## Build order

*Status: 1–4 are implemented and shipped; 5 is not yet built.*

1. **`frame inbox --wait`** — self-contained, no external uncertainty, testable
   by hand with two frames. ✅ shipped
2. **`frame spawn shell`** — pin the Ghostty line, wire readiness + `--req`.
   ✅ shipped
3. **`--ephemeral` reaping.** ✅ shipped
4. **`frame spawn wt [--cwd]`.** ✅ shipped
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
