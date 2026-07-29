# frame req <TOPIC | NAME/TOPIC> TEXT… — send a request (a COMMAND) to the
# Claude agent running inside another frame. TEXT is typed into that frame's
# `claude` buffer over its nvim socket (FrameRequest in layouts/worktree.lua)
# and lands in Claude's prompt and submits, exactly as if you'd typed it there.
#
#   frame req web/auth "what's blocking the migration?"
#   frame req schema "run the tests again"       # schema in the current project
#
# The request/reply pair: `frame req` asks, the agent's `frame reply` answers.
# Sending ARMS a one-shot reply — when the agent finishes its turn, its answer
# routes back to THIS frame's inbox (read it with `frame inbox`). So `frame req`
# must be run from inside a frame — that frame is the reply's return address.
# NAME/TOPIC reaches any project; a bare TOPIC pairs with the current frame's
# own NAME. If Claude is mid-turn the text queues, like typing while it works.
# See docs/agent-messaging.md.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

if (( $# < 1 )); then
  echo "$X_MARK usage: frame req <topic|name/topic> TEXT…" >&2
  exit 2
fi

TARGET_SPEC="$1"; shift
if (( $# == 0 )); then
  echo "$X_MARK frame req: nothing to send" >&2
  echo "  usage: frame req <topic|name/topic> TEXT…" >&2
  exit 2
fi

# This frame is where the response comes home, so we need our own identity. No
# frame → refuse before sending (nowhere for the answer to land).
if ! frame_self_identity; then
  echo "$X_MARK frame req must be run from inside a frame — its inbox receives the reply" >&2
  exit 1
fi
FROM="$SELF_NAME/$SELF_TOPIC"

if [[ "$TARGET_SPEC" == */* ]]; then
  NAME="${TARGET_SPEC%%/*}" TOPIC="${TARGET_SPEC#*/}"
else
  # Bare topic — pair it with this frame's own NAME (a sibling in the same
  # project). NAME/TOPIC is the cross-project form.
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
# --headless for the same reason as status.sh: keep the expr result on stdout
# and the terminal-capability probes off the caller's tty.
if _result=$(nvim --headless --server "$SOCKET" \
    --remote-expr "v:lua.FrameRequest('$_from', '$_esc')"); then
  case "$_result" in
    ok)
      echo "$OK_MARK sent to $NAME/$TOPIC (reply → $FROM inbox)" ;;
    no-claude-buffer)
      echo "$X_MARK $NAME/$TOPIC has no 'claude' buffer to message" >&2
      exit 1 ;;
    *)
      echo "$X_MARK unexpected response from $NAME/$TOPIC: $_result" >&2
      exit 1 ;;
  esac
else
  echo "$X_MARK session at $SOCKET didn't accept the message — does its layout" >&2
  echo "  predate FrameRequest? Reboot the frame (:FrameQuit, then frame wt $TOPIC)" >&2
  exit 1
fi
