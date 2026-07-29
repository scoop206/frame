# frame agent <TOPIC | NAME/TOPIC> TEXT… — send a message to the Claude agent
# running inside another frame. TEXT is typed into that frame's `claude` buffer
# over its nvim socket (calls FrameAgentSend in layouts/worktree.lua) and lands
# in Claude's prompt and submits, exactly as if you'd typed it there.
#
#   frame agent web/auth "what's blocking the migration?"
#   frame agent schema "run the tests again"    # schema in the current project
#
# Target: NAME/TOPIC reaches any project's frame; a bare TOPIC resolves NAME
# from the current project's config, so you can message a sibling frame by topic
# alone. If Claude is mid-turn the text queues in its input, like typing while
# it works.
#
# v1 is send-only — no reply is captured yet. See docs/agent-messaging.md.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

if (( $# < 1 )); then
  echo "$X_MARK usage: frame agent <topic|name/topic> TEXT…" >&2
  exit 2
fi

TARGET_SPEC="$1"; shift
if (( $# == 0 )); then
  echo "$X_MARK frame agent: nothing to send" >&2
  echo "  usage: frame agent <topic|name/topic> TEXT…" >&2
  exit 2
fi

if [[ "$TARGET_SPEC" == */* ]]; then
  NAME="${TARGET_SPEC%%/*}" TOPIC="${TARGET_SPEC#*/}"
else
  # Bare topic — pair it with the current project's NAME so you can message a
  # sibling frame by topic alone. Same identity source as status.sh/focus.sh:
  # a shell frame carries NAME in the session env; inside a checkout it comes
  # from config. NAME/TOPIC is the cross-project form that needs neither.
  if ! frame_project_root >/dev/null && [[ -n "${FRAME_NAME:-}" ]]; then
    NAME=$FRAME_NAME
  else
    frame_load_config
  fi
  TOPIC="$TARGET_SPEC"
fi

SOCKET="/tmp/$NAME-$TOPIC.nvim"
if [[ ! -S "$SOCKET" ]]; then
  echo "$X_MARK no frame session for $NAME/$TOPIC (no socket at $SOCKET)" >&2
  exit 1
fi

# Vimscript single-quoted string: only ' needs escaping, as ''.
TEXT="$*"
_esc=${TEXT//\'/\'\'}
# --headless for the same reason as status.sh: keep the expr result on stdout
# and the terminal-capability probes off the caller's tty.
if _result=$(nvim --headless --server "$SOCKET" --remote-expr "v:lua.FrameAgentSend('$_esc')"); then
  case "$_result" in
    ok)
      echo "$OK_MARK sent to $NAME/$TOPIC" ;;
    no-claude-buffer)
      echo "$X_MARK $NAME/$TOPIC has no 'claude' buffer to message" >&2
      exit 1 ;;
    *)
      echo "$X_MARK unexpected response from $NAME/$TOPIC: $_result" >&2
      exit 1 ;;
  esac
else
  echo "$X_MARK session at $SOCKET didn't accept the message — does its layout" >&2
  echo "  predate FrameAgentSend? Reboot the frame (:FrameQuit, then frame wt $TOPIC)" >&2
  exit 1
fi
