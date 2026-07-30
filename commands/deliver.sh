# frame deliver <TOPIC | NAME/TOPIC> [--from NAME/TOPIC] MESSAGE… — drop a
# REPORT into a frame's inbox. The mirror of `frame req`: req injects a
# command into a frame's prompt; deliver appends a message to its inbox
# (FrameInboxAdd in layouts/worktree.lua), to be read later with `frame inbox`.
#
#   frame deliver hub "migration finished, tests green"
#   frame deliver flipnem/hub --from flipnem/auth "done"
#
# The broker (FrameBrokerOnTurnEnd) calls this to route an agent's turn home;
# you can also call it directly to leave a note. --from records the sender for
# display in the recipient's inbox. NAME/TOPIC reaches any project; a bare TOPIC
# pairs with the current frame's own NAME. See docs/agent-messaging.md.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

if (( $# < 1 )); then
  echo "$X_MARK usage: frame deliver <topic|name/topic> [--from NAME/TOPIC] MESSAGE…" >&2
  exit 2
fi

TARGET_SPEC="$1"; shift

FROM=""
if [[ "${1:-}" == "--from" ]]; then
  FROM="${2:-}"; shift 2
fi

if (( $# == 0 )); then
  echo "$X_MARK frame deliver: nothing to deliver" >&2
  echo "  usage: frame deliver <topic|name/topic> [--from NAME/TOPIC] MESSAGE…" >&2
  exit 2
fi

if [[ "$TARGET_SPEC" == */* ]]; then
  NAME="${TARGET_SPEC%%/*}" TOPIC="${TARGET_SPEC#*/}"
else
  # Bare topic — pair with the caller's own NAME (a sibling frame).
  if ! frame_self_identity; then
    echo "$X_MARK bare topic '$TARGET_SPEC' needs a project — run from a frame, or pass NAME/TOPIC" >&2
    exit 1
  fi
  NAME=$SELF_NAME TOPIC="$TARGET_SPEC"
fi

SOCKET="/tmp/$NAME-$TOPIC.nvim"
if [[ ! -S "$SOCKET" ]]; then
  echo "$X_MARK no frame session for $NAME/$TOPIC (no socket at $SOCKET)" >&2
  exit 1
fi

# Vimscript single-quoted strings: only ' needs escaping, as ''.
TEXT="$*"
_esc=${TEXT//\'/\'\'}
_from=${FROM//\'/\'\'}
if _n=$(nvim --headless --server "$SOCKET" \
    --remote-expr "v:lua.FrameInboxAdd('$_from', '$_esc')"); then
  echo "$OK_MARK delivered to $NAME/$TOPIC inbox ($_n waiting)"
else
  echo "$X_MARK session at $SOCKET didn't accept the delivery — layout may predate" >&2
  echo "  FrameInboxAdd; reboot the frame (:FrameQuit, then frame wt $TOPIC)" >&2
  exit 1
fi
