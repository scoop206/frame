# frame name — print THIS frame's name/topic to stdout. The CLI twin of
# :FrameName: where the vim command puts the handle on the system clipboard for
# a human to paste, the CLI writes it to stdout so it composes — grab it into a
# variable, pipe it, or `frame req "$(frame name)" …` from a script.
#
# name/topic is the unambiguous form the sibling-addressing commands take
# (frame req/focus/view/deliver) — a bare topic can collide across projects.
#
# Pure identity, no session required: like `frame status`, a shell frame carries
# its identity in the session env (FRAME_NAME/FRAME_TOPIC) while a checkout
# derives it from the worktree dir or current branch — exactly what
# frame_self_identity does. So this works from a bare shell inside a checkout too,
# with no live nvim session to talk to.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

if (( $# )); then
  echo "$X_MARK frame name takes no arguments — it prints this frame's name/topic" >&2
  exit 2
fi

if ! frame_self_identity; then
  echo "$X_MARK frame name must be run from inside a frame (or a checkout it can" >&2
  echo "  derive an identity from) — there's no name/topic to print here." >&2
  exit 1
fi

print -r -- "$SELF_NAME/$SELF_TOPIC"
