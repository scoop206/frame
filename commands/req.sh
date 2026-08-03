# frame req <TOPIC | NAME/TOPIC> TEXT… — send a request (a COMMAND) to the
# Claude agent running inside ANOTHER frame. The request is handed to that
# frame's claude broker (FrameBrokerSubmit in layouts/session.lua) with a
# remote return address, so when its turn ends the answer is delivered back to
# THIS frame's inbox — read it with `frame inbox`.
#
#   frame req web/auth "what's blocking the migration?"
#   frame req schema "run the tests again"       # schema in the current project
#
# The request/reply pair: `frame req` asks (async — it returns as soon as the
# request is queued), the target's broker answers home when the turn finishes.
# So `frame req` must be run from inside a frame — that frame is the reply's
# return address. NAME/TOPIC reaches any project; a bare TOPIC pairs with the
# current frame's own NAME.
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

# The reply comes home to FROM's inbox — but only if FROM is itself a live
# session. From a bare shell in a checkout, frame_self_identity resolves FROM
# from git yet no session exists there, so the answer would land nowhere. Warn
# (don't refuse — the request still reaches the target, and a caller may not
# need the reply) and point at the fix.
if [[ ! -S "$FRAME_RUNDIR/$SELF_NAME-$SELF_TOPIC.nvim" ]]; then
  echo "$WARN_MARK reply address $FROM has no live session — its answer will have nowhere to land." >&2
  frame_session_down_hint "$SELF_NAME" "$SELF_TOPIC"
fi

# Resolve the target to a live session (sets NAME / TOPIC / SOCKET). A bare
# topic pairs with our own NAME first, then falls back to the unique live frame
# with that topic — so a head frame reaches `comms2` without naming its project.
frame_resolve_target "$TARGET_SPEC" || exit 1

# Vimscript single-quoted strings: only ' needs escaping, as ''.
TEXT="$*"
_esc=${TEXT//\'/\'\'}
_ret="remote:$FROM"
_ret=${_ret//\'/\'\'}
# --headless for the same reason as status.sh: keep the expr result on stdout
# and the terminal-capability probes off the caller's tty.
if ! _result=$(nvim --headless --server "$SOCKET" \
    --remote-expr "v:lua.FrameBrokerSubmit('$_esc', '$_ret')"); then
  echo "$X_MARK session at $SOCKET didn't accept the request — layout may predate" >&2
  echo "  the broker; reboot the frame (:FrameQuit, then frame wt $TOPIC)" >&2
  exit 1
fi
case "$_result" in
  r<->)
    echo "$OK_MARK sent to $NAME/$TOPIC (reply → $FROM inbox)"
    # Correlation token: the reply lands tagged `from#id` (from = the target we
    # resolved, id = the broker id it just returned). Emit it machine-parseably so
    # a fan-out caller can `frame inbox --wait --for $token` for exactly this reply.
    echo "token: $NAME/$TOPIC#$_result" ;;
  no-claude-buffer)
    echo "$X_MARK $NAME/$TOPIC has no 'claude' buffer to message" >&2
    exit 1 ;;
  queue-full)
    echo "$X_MARK $NAME/$TOPIC's claude queue is full — try again shortly" >&2
    exit 4 ;;
  *)
    echo "$X_MARK unexpected response from $NAME/$TOPIC: $_result" >&2
    exit 1 ;;
esac
