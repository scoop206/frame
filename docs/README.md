# docs/

Research notes, design decisions, and specs for `frame` — the durable reasoning
behind changes, so it doesn't have to be re-derived from scratch.

Not user-facing docs (that's the top-level `README.md`). This is the "why" and
the "what we're about to build."

## Notes

- [identity-model.md](identity-model.md) — a frame's identity is its socket +
  env, not its window title; what does / doesn't break when the title changes.
- [agent-messaging.md](agent-messaging.md) — `frame req` / `frame reply` /
  `frame deliver` / `frame inbox`: message the Claude in another frame and route
  its reply back via an inbox; `FrameState` as the frame-resident coordination
  object.
- [fixing-stuck-banner-badge.md](fixing-stuck-banner-badge.md) — when a rebuilt
  `Frame.app` banner keeps showing the old icon: it's macOS's icon cache keyed
  to the stable bundle ID; the escalation ladder, and why bouncing the Dock is
  what fixes it.
