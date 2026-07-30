# The claude broker — concurrent access to one frame's local claude

## Why

Claude is a single serial worker: one TUI, one input box, one turn at a time.
To let N independent clients (a `local` shell, a vim buffer plugin, a future
MCP-ish consumer, another frame via `frame req`) query it concurrently and each
get *their own* answer, we put a **queue with a single worker** in front of it,
living in the session (nvim). Clients never touch claude; they hand requests to
the broker, which feeds claude one prompt at a time and routes each turn's
answer back to whoever asked.

The load-bearing property: **strict serialization costs nothing**, because
claude can't answer two turns at once regardless. One prompt in flight ⇒ "which
turn is this Stop?" is never ambiguous — it's the in-flight one. No token
matching, no order-fragility.

This **replaces** the arm/subscriber model (`FrameState.subscribers` +
`FrameOnTurnEnd` fan-out). Every path that types into claude — local
`frame claude`, cross-frame `frame req` — becomes a broker client. `frame req`
*must* be migrated too: it is a second writer into the same buffer, and left
un-brokered it breaks the single-writer invariant the broker depends on.

Out of scope: cross-frame *scheduling* concurrency beyond routing `req` through
the broker; request priorities; streaming partial output. `frame deliver` /
`frame inbox` (pure mailbox, no claude) are untouched.

## Data model (in `FrameState`)

```
FrameState.broker = {
  seq      = 0,      -- monotonic id source
  queue    = {},     -- FIFO list of request ids awaiting submit
  inflight = nil,    -- the id currently being answered by claude (or nil)
  reqs     = {},     -- id -> request
}
```

A request:

```
{
  id      = 'r7',
  text    = '…the prompt…',
  ret     = { kind = 'local' }             -- answer awaited over this socket by id
          | { kind = 'inbox' }             -- answer dropped into THIS frame's inbox
          | { kind = 'remote', addr = 'name/topic' },  -- delivered to a sender's inbox
  status  = 'queued' | 'inflight' | 'done' | 'cancelled',
  answer  = nil,     -- set when done (last assistant message; '' allowed)
}
```

## Operations (in-session Lua, called over the socket)

- **`FrameBrokerSubmit(text, ret)` → `id` | `'no-claude-buffer'` | `'not-ready'`**
  Refuses only when there's structurally nowhere to send (no claude buffer) or
  claude hasn't booted its prompt yet. **Busy is not a refusal** — it enqueues.
  Creates the request, appends to `queue`, calls `pump()`, returns the id.

- **`FrameBrokerAwait(id)` → `pending` | `done\n<answer>` | `gone`**
  Client poll. `gone` = unknown/evicted id. `done` returns the answer and
  **collects** it (removes the request) so mailboxes don't leak.

- **`FrameBrokerCancel(id, mode)` → `'ok'`** where `mode ∈ {drop, inbox}`
  Queued ⇒ remove from queue. Inflight ⇒ mark `cancelled`; its eventual Stop
  still advances the queue but its answer is dropped (mode=drop) or routed to
  this frame's inbox (mode=inbox). Done ⇒ discard stored answer.

- **`FrameBrokerStatus()`** → tab/line-delimited snapshot of `queue` + `inflight`
  (id, position, status) for `frame claude status` and future clients.

- **`FrameBrokerOnTurnEnd(text)`** — the Stop-hook pump. Take `inflight`; route
  `text` to its `ret` (local: store answer + mark done; inbox: `FrameInboxAdd`;
  remote: `jobstart frame deliver addr --from <self> text`); clear `inflight`;
  `pump()`. With `inflight == nil` (a human-typed turn nobody brokered) it is a
  no-op, exactly as the old fan-out was with no subscribers.

- **`pump()`** (internal) — if `inflight == nil`, `queue` non-empty, and claude
  is ready (`FrameReady()`), pop the front id, set `inflight`, `frame_submit`
  it. If not ready, leave it queued and re-arm a deferred `pump()` (readiness
  retry). Never submits while `inflight` is set.

### Policies (chosen; flag if you disagree)

- **Empty / tool-only final turn:** still advances the queue and delivers `''`.
  Advancing on *every* Stop is what keeps turn↔request binding aligned; a
  local client renders `''` as "(no textual answer)".
- **Ctrl-C on `frame claude` = detach, not drop:** the CLI's INT trap calls
  `Cancel(id, inbox)`, so the in-flight answer lands in `frame inbox` when the
  turn finishes — preserving the "Ctrl-C then read it later" behavior we liked,
  now race-free.
- **Banner suppression:** a turn that answered a brokered request suppresses the
  `frame notify` banner (the client already got the answer); human-driven turns
  still banner. (Pump sets a one-shot "brokered turn" flag the notify RPC reads.)
- **Queue cap:** default 32; `Submit` returns `'queue-full'` past it. Generous;
  a backstop, not a real limit.
- **Eviction:** `done` requests are collected on `Await`. A lightweight sweep
  drops `done`/`cancelled` requests older than a TTL to cover clients that die
  before collecting.

## Wire protocol

Same `--headless --server … --remote-expr` + single-quote escaping as `req`.
`ret` is encoded compactly: `local`, `inbox`, or `remote:name/topic`.

- submit:  `v:lua.FrameBrokerSubmit('<esc text>', '<ret>')`
- await:   `v:lua.FrameBrokerAwait('<id>')`
- cancel:  `v:lua.FrameBrokerCancel('<id>', '<mode>')`
- status:  `v:lua.FrameBrokerStatus()`

## Clients

- **`frame claude [--timeout N] TEXT…`** — `Submit(local)` → id; poll `Await(id)`
  (~1s cadence, like `inbox --wait`) until `done`/timeout; print the answer.
  INT trap → `Cancel(id, inbox)`. No more busy-refusal: a busy claude just means
  your question queues. `no-claude-buffer` / `not-ready` stay hard errors.
  `frame claude status` → `FrameBrokerStatus()`.
- **`frame req <target> TEXT…`** — runs on the *sender*, opens the *target's*
  socket, calls the target's `Submit(remote:<sender-addr>)`. Fire-and-forget
  from the sender (returns "sent"); the target broker delivers the answer to the
  sender's inbox when the turn ends. No arming on the sender anymore.
- **`frame reply`** (Stop hook, bare form) — rewired to `FrameBrokerOnTurnEnd`
  (pump). The explicit `frame reply TEXT` form is retired (its job is now the
  broker's routing).
- **`frame deliver` / `frame inbox`** — remote answers arrive via broker →
  `frame deliver` → inbox, indistinguishable to the reader. `deliver` now also
  carries `--id <broker-id>`, and `inbox --for <token>` filters on it — see
  Correlated fan-out below.

## Correlated fan-out (reply tokens)

The local path correlates answers by id (await binds `frame claude` to its exact
request). The **cross-frame** path closes the same gap without minting anything
new: the broker already has a per-request id on the *target*, and `frame req`
already gets it back from `Submit` — so `<target-addr>#<id>` (e.g.
`frame/comms2#r7`) is already a globally-unique correlation token. `frame req`
prints it (`token: …`); the reply is delivered with that id and the inbox stores
it, so the sender can match reply→request instead of guessing by order/content.

- **route → deliver** threads `req.id`: `frame deliver <addr> --from <self> --id
  <id> <text>`. `FrameInboxAdd(from, text, id)` stores `{from, text, id}` (id
  defaults `''`; a hand-written note never carries one, so it never matches).
- **`frame inbox --for <token>`** (repeatable) is the correlated fan-in barrier:
  `FrameInboxDrainFor(tokens)` holds out until *every* requested `from#id` is
  present, then drains **only** those, leaving unrelated mail. `--for` and
  `--count` are mutually exclusive (two ways to say "how many"); `--for` works
  with or without `--wait` (barrier vs drain-if-complete).
- **Fan-out usage**: fire N `frame req`s, capture each `token:` line, then
  `frame inbox --wait --for $t1 --for $t2 …` to collect exactly those N answers —
  an unrelated `frame deliver` note landing mid-wait is left behind, not counted.

Wire additions: `v:lua.FrameInboxAdd('<from>', '<text>', '<id>')` and
`v:lua.FrameInboxDrainFor('<tab-joined tokens>')`. Additive and backward
compatible — plain notes, untokened reqs, and `inbox` with no `--for` are
unchanged. Not built: synchronous `frame req --wait` (submit + inline
`inbox --wait --for`); the token machinery is its prerequisite, ~15 lines when
wanted.

## Migration — sequenced so the suite stays green at each step

**Phase 1 — broker core + local `frame claude`.**
Add broker state + `Submit/Await/Cancel/Status/OnTurnEnd/pump` to
`worktree.lua`. Rewrite `commands/claude.sh` onto submit/await + INT-trap
cancel. Update the `nvim` stub (broker RPCs) and rewrite `test_claude.zsh` for
the new protocol. `frame req` still uses the old `FrameRequest`/subscribers path
(coexists; harmless in tests, which stub nvim). Retire the Phase-1 self-filter
(`FrameInboxDrainSelf`) and the idle-gate/flush from `claude.sh`.

**Phase 2 — migrate `frame req` onto the broker.**
`req` calls the target's `Submit(remote)`. Broker `OnTurnEnd` routes remote
requests via `frame deliver`. Update `test_req` / `test_reply`. Delete
`FrameRequest`, `subscribers`, `FrameOnTurnEnd`, `frame_submit`'s old caller →
single-writer restored (broker is the only writer).

**Phase 3 — cleanup + docs.**
Rewire the `frame reply` Stop hook → `FrameBrokerOnTurnEnd`; delete
`FrameReplyFromHook`/`FrameOnTurnEnd` remnants. Update `docs/agent-messaging.md`.
Full suite green; live-verify concurrent multi-local in a real frame.

## The sharp edges this retires

Wrong-turn delivery, stale-orphan replies, the Ctrl-C-refire race, and
multi-caller collision all dissolve into one model: a request is bound to its
turn by being the single in-flight job, and to its client by its id.

## The one accepted assumption

The broker owns claude's input. A human typing *directly* into the claude pane
while requests are queued injects an untracked turn that can desync the
in-flight binding. Documented, not defended against, in v1: drive through
clients, or accept a race if you also hand-type mid-queue.
