# Agent messaging & the frame-resident coordination object

*Design note. Captures how an operator (a human, or an orchestrator Claude) sends
a message to the Claude agent in another frame and gets its reply routed home to
an inbox — without polling. Written while scoping `frame agent`. Builds directly
on the [identity model](identity-model.md).*

*Revised (v2): **commander/worker is not a stored mode.** Roles are emergent and
relational — a frame is a "commander" of any frame it sends a command to, a
"worker" of any frame that commands it, and it can be both at once (an
orchestrator that is itself commanded from above). Every frame has an inbox;
delivery discipline is decided by the operation (command → inject, report →
inbox), not by a role attribute. See [Roles are emergent](#roles-are-emergent-not-a-stored-attribute).*

## TL;DR

- **A frame already exposes exactly one way in: its nvim RPC socket**
  (`/tmp/<name>-<topic>.nvim`). `status`, `notify`, `ls`, teardown all go
  through it; nothing talks to the Claude process directly. `frame agent` is
  just the newest consumer of that same socket.
- **Send is easy** because nvim *owns the terminal Claude runs in*: RPC into the
  socket → `chansend` the text into the `claude` buffer's channel. It arrives as
  if typed. No tmux, no new IPC.
- **Reply is the real design.** The agent's only out-channel is the `frame` CLI
  (that's how the Stop hook fires `notify` today). So a reply travels back
  *through frame*, into an **inbox**, and the recipient reads it — never by
  scraping the agent's terminal.
- **Every endpoint is a frame — no file backend, no stored role.** You (the
  operator) don't message from a bare shell; you sit *inside a frame* and command
  from there, so replies come home to a socket like everything else. An
  orchestrator agent commands the same way. Whether a frame is "commander" or
  "worker" is **emergent** — it's just which end of a given exchange it's on, and
  a mid-hierarchy frame is both at once. **Delivery discipline follows the
  operation, not a role:** a *command* injects into the target's Claude prompt; a
  *report* lands in the recipient's inbox.
- **Reports always accumulate — there is no delivery preference.** A *command*
  injects (that's the point of a command); a *report* is reference data for the
  operator, so it lands in an inbox to be pulled, never spliced into anyone's
  conversation mid-reasoning — for agents as much as humans. The only remaining
  concept is **the pattern of checking your inbox**.
- **State lives in the frame, not on our side.** The running nvim grows a
  `FrameState` object — the generalization of today's `current_status` +
  `frame_notify_muted` — holding `subscribers` (who's listening to me) and
  `inbox` (reports coming home to me). Coordination becomes *RPC into a state
  object*, and liveness is free: frame dies → socket + state vanish, nothing to
  garbage-collect.
- **Division of labor:** nvim = coordination brain (all routing + state); the
  Stop hook = a dumb sensor that reads the agent's clean last response from the
  JSONL **transcript** (never the TUI buffer) and hands it to the brain.

## The two hard constraints

Everything below is shaped by two facts about how a frame runs (see the
[architecture summary](identity-model.md) and `layouts/worktree.lua`):

1. **Claude is a neovim `:terminal` buffer**, not a server and not a detached
   process. It acts only on input, emits only terminal output, and the only
   process that can reach it is the nvim that hosts it.
2. **The only IPC into a frame is the nvim RPC socket.** There are no fifos, no
   custom sockets. Every existing cross-process feature is `nvim --headless
   --server $SOCK --remote-expr 'v:lua.Frame…()'`.

Consequence: **send** is a natural fit (nvim owns the terminal, so it can type
into it), and **reply** must ride the one out-channel the agent already has (the
`frame` CLI), landing somewhere the sender can read on its own schedule.

## Send: `frame agent <name>/<topic> TEXT`

```
frame agent web/auth "what's blocking the migration?"
```

→ resolve the target socket from `<name>/<topic>` (same lookup `status`/`focus`
use) → RPC in → find the `claude` terminal buffer's job channel →
`chansend(chan, TEXT .. "\r")`. The text lands in Claude's prompt and submits.

Notes / open questions for this half:

- **Finding the channel.** The layout knows which buffer is `claude`
  (`buffers.json`); `FrameState` should stash that buffer/channel handle at boot
  so `frame agent` doesn't have to hunt for it.
- **Timing / consent.** If the agent is mid-turn, injected text queues in
  Claude Code's input the same way typing-while-busy does. That's acceptable
  default behavior; a future `--interrupt` could send an Esc first. Not in v1.

## Reply: the gate, the marker, the inbox

The Stop hook fires on **every** turn-end — turns you triggered, turns the
agent's own work triggered, everything. So "every Stop → write to an inbox"
is wrong: it would flood the inbox with unrelated turn-endings. There must be a
gate, and **the gate is the "subscribe" concept.**

**A send arms the gate.** `frame agent` records a *return address* on the target
frame — an entry in `FrameState.subscribers`, "someone is waiting to hear back,
here's who." On turn-end the hook-fed router checks it:

| Marker state | Router action |
|---|---|
| `subscribers` empty | Nothing beyond the existing `notify` banner. Inbox stays clean. |
| `subscribers` non-empty | Accumulate this turn's response in each address's inbox, then update the marker per the model below. |

### One-shot vs. subscription — build the atom, not the sugar

- **One-shot / request–reply** (the atom): a send arms *one* reply. Turn-end
  fulfills and **removes** the address. Keep talking by sending again. Zero
  leakage — an unrelated later turn-end routes to nobody.
- **Subscription / watch** (sugar): `frame agent --watch` **keeps** the address
  after firing, so every future turn-end of the target flows to the watcher
  until it unsubscribes. Good for an orchestrator passively monitoring a worker.

**Decision: implement one-shot as the base primitive; `--watch` is later, and is
just "don't remove the address on fire."** One-shot already gives full
back-and-forth (send → reply lands → read → send again). Subscription-first would
be noisier and you can't easily *stop* a chatty frame from filling your inbox.

Multiple senders before a reply falls out naturally: `subscribers` is a *set* of
addresses; the reply broadcasts to all, then one-shot clears them / watch keeps
them.

## `FrameState`: the frame-resident coordination object

Today the frame already keeps canonical state in the running nvim and treats the
window title as a mere *view* of it (`worktree.lua:40-46`: `current_status` is
the value, the title suffix is its rendering; `FrameInfo` reads the value, never
re-parses the title). `FrameState` is the same move, generalized:

```lua
local FrameState = {
  status      = '',   -- == today's current_status (window-title suffix)
  chan        = {},   -- name → terminal job channel (for send); e.g. ['claude']
  subscribers = {},   -- return addresses currently listening to ME
  inbox       = {},   -- reports come home here (EVERY frame has one)
}
```

- `FrameSetStatus` becomes a setter on `FrameState.status`; `FrameInfo` reads it;
  the title stays a pure view. **This consolidates `current_status` and the
  send-channel registry that already exist**, then adds the coordination tables
  (`subscribers`, `inbox`) in the same place — not a new mechanism, an extension
  of a pattern the code already committed to.
- **The notify mute switch stays `vim.g.frame_notify_muted`, not a `FrameState`
  field.** `frame notify` reads it over RPC as `get(g:, 'frame_notify_muted', 0)`,
  so sessions predating the switch degrade gracefully to unmuted. Folding it into
  a Lua table would trade that cheap, backward-compatible read for uniformity —
  not worth it. Mute is the one piece of per-frame state that stays a `g:` var by
  design.
- **No `mode` field, no delivery preference.** Every frame has an `inbox`
  unconditionally; "commander"/"worker" are descriptions of position in an
  exchange, not stored state (see
  [Roles are emergent](#roles-are-emergent-not-a-stored-attribute)). Reports
  always accumulate — no per-node config for how they arrive.
- **Liveness for free**, exactly like `frame ls`: the socket *is* the liveness
  handle, so when the frame dies its subscriptions and inbox die with it. No
  stale-subscription GC, no orphaned inbox files.
- `frame ls` can later surface `subscribers` count ("2 watchers") by extending
  `FrameInfo()`.

### Routing lives in Lua; the hook is a dumb sensor

**Do not scrape the response text out of the Claude terminal buffer.** That
buffer is a live TUI — ANSI codes, redraws, spinners, boxes;
`nvim_buf_get_lines` returns a repainting screen, not a transcript. This is the
one place the "state in nvim" idea fights physics.

Clean split:

- **Stop hook = sensor.** It already receives the `transcript_path` on stdin
  (Claude Code hook contract). It reads the agent's *actual* last assistant
  message from that JSONL (clean, structured) and RPCs it into the frame:
  `v:lua.FrameOnTurnEnd(text)`. The hook decides nothing.
- **`FrameOnTurnEnd(text)` = brain.** One Lua function does all routing: if
  `subscribers` is empty, no-op (the existing banner still fires); else deliver
  `text` home to each address as a **report** — appended to that address's
  `inbox` — then clear/keep per one-shot/watch. A report always accumulates; only
  a `frame agent` *command* injects (you're telling the target to act). The
  operation picks the discipline, and there are exactly two.

That marries both ideas: nvim holds the state and owns the routing; the hook
exists only because it's the one thing with easy access to clean response text.

## Roles are emergent, not a stored attribute

**Every endpoint is a frame**, so there's no file backend — but a frame is *not*
tagged commander-or-worker. The role is just which end of an exchange it's on:

- A frame is a **commander** *of* any frame it sends a command to.
- A frame is a **worker** *of* any frame that commands it.
- A frame can be **both at the same instant** — an orchestrator agent that is
  commanded from above and commands workers below is a worker (to you) and a
  commander (to them) simultaneously. This is a tree, not a two-level star, so a
  worker-XOR-commander attribute — static *or* flippable — can't describe it: the
  frame isn't switching roles over time, it holds both at once.

So role isn't stored anywhere. What's stored is the mechanics that make the two
*operations* work, and the operation picks the delivery discipline:

| Operation | What it is | Delivery |
|---|---|---|
| **command** (`frame agent T "…"`) | tell T to do something | **inject** into T's Claude prompt (injecting *is* the point) |
| **report** (reply routed home) | tell the sender what happened | **accumulate** in the recipient's inbox (reference data, never spliced into a live turn) |

Reports always accumulate — there is no per-node delivery preference. Injecting a
report into a busy node (agent *or* human) is the intrusion we're avoiding, and a
command's injection is fine because a command is *meant* to be a new prompt (and
if the target is busy it merely queues in Claude Code, non-destructively).

Every frame owns `FrameState.inbox`, so a report always has a socket to come home
to. The operator doesn't message from a bare shell — **they sit inside a frame
and command from there**; the frame they're in *becomes* a commander by virtue of
sending, and its inbox collects the replies. Keeping that frame alive is the
whole ceremony ("keep it around so I can command"). No `frame mode` command, no
graduation step: send a command and you're commanding; receive one and you're
working.

You fire `frame agent web/auth "…"` → injected into that worker → it works → its
reply routes to *your* frame's inbox (your frame was the return address) → you
read it and command again. An orchestrator agent runs the identical loop from its
Claude buffer, draining its own inbox on each idle turn-end.

Multiple concurrent commanders are never ambiguous: the return address is always
*the sending frame*, so a report always knows its one true home.

### Reading the inbox

- **`frame inbox`** — list / drain `FrameState.inbox` by RPC into the caller's
  *own* socket. Same command whether a human runs it from a shell buffer or an
  agent runs it from its Claude buffer.
- **The check-inbox pattern.** A report is surfaced when the recipient is idle:
  the existing `notify` banner nudges a human; an agent's Stop hook (turn-end =
  idle by definition) is the safe moment to check and drain. The one gap — a node
  that's *already* parked idle won't get another turn-end — is left to convention
  for v1 (the agent's frame CLAUDE.md tells it to `frame inbox` as a habit); an
  actual wake mechanism rides in with `--watch`/escalation later (below).

## Build phases

1. **Send only.** `frame agent name/topic TEXT` → `chansend` into the `claude`
   buffer. Stash `claude_chan` in `FrameState` at boot. No reply yet — already
   useful (fire a message into a frame).
2. **`FrameState` consolidation.** Fold `current_status` + `frame_notify_muted`
   into `FrameState`; every frame gets an `inbox`; keep the title a pure view.
   Mostly a refactor — de-risks the rest.
3. **One-shot reply into the sender's inbox.** Arm `subscribers` on send; teach the
   Stop hook to read the transcript tail and call `FrameOnTurnEnd`; deliver the
   report socket-to-socket into the sending frame's `inbox`; `frame inbox` to
   read. The first real round-trip — and since inboxes are already socket-backed,
   there's no separate human/file path to build.
4. **Agent↔agent.** Same delivery, exercised with an orchestrator agent that
   commands workers below while being commanded from above — proving a frame is
   worker and commander at once, with the check-inbox convention as the only glue.
5. **`--watch` subscription.** One flag: keep the address on fire instead of
   clearing. Surface `subscribers` count in `frame ls`.

Escalation (`--interrupt`) and a real idle-wake are explicitly **out of v1** —
accumulation covers ~99%, and the two ends of the spectrum (polite accumulate,
hard `frame wt -d` teardown) already exist. Revisit alongside `--watch`.

## Decisions

- **Peer delivery goes through the `frame` CLI, not nvim→nvim.**
  `FrameOnTurnEnd`'s captured text is delivered by shelling out to
  `frame deliver <addr> "…"`, which does the socket write — the same
  "talk-to-a-frame" path `status` / `notify` / `ls` already use. One consistent
  code path; the per-message process spawn is negligible. (Rejected: direct
  nvim→nvim RPC — fewer processes, but a second style of cross-frame call.)
- **An idle agent checking its inbox is convention-only in v1.** The agent's
  frame CLAUDE.md instructs it to `frame inbox` as a habit (after dispatching
  work, before considering itself done). Human operators are covered by the
  banner. A real async-wake (type a nudge into an idle prompt) is deferred to
  ride in with `--watch`/escalation — it's the "wake a parked node" machinery we
  already scoped out of v1.
- **`frame agent` run outside any frame is refused in v1.** With no return
  socket there's no inbox for a reply to come home to, so it errors: *"run
  `frame agent` from inside a frame — no inbox to receive replies."* Fired from
  *any* frame is fine (that frame is the return address). A fire-and-forget
  `--no-reply` for bare terminals is an easy later add if demand appears.

## Open questions

- **Transcript-tail extraction robustness** — the Stop-hook sensor reads the
  agent's last turn from the JSONL: last assistant message only, or the whole
  final turn? What about a turn that ends on a tool call with no closing prose?
  An implementation detail to settle while building phase 3.

## Related

- [identity-model.md](identity-model.md) — the socket-is-identity rule this
  builds on; `FrameState` is its state counterpart.
- `layouts/worktree.lua` — `current_status` / `FrameInfo` / `FrameSetStatus`, the
  seed of `FrameState`.
- `commands/notify.sh` — the Stop-hook out-channel that becomes the reply sensor.
