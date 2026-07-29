# docs/

Research notes, design decisions, and specs for `frame` — the durable reasoning
behind changes, so it doesn't have to be re-derived from scratch.

Not user-facing docs (that's the top-level `README.md`). This is the "why" and
the "what we're about to build."

## Notes

- [identity-model.md](identity-model.md) — a frame's identity is its socket +
  env, not its window title; what does / doesn't break when the title changes.
- [agent-messaging.md](agent-messaging.md) — `frame agent`: send a message to
  the Claude in a frame and route its reply back via an inbox; `FrameState` as
  the frame-resident coordination object.
