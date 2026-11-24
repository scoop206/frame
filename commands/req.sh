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
#
# frame req status [TOKEN…] — what became of requests THIS frame sent. No
# TOKEN: every request sent and not yet drained from the inbox (the outbox in
# this frame's FrameState, recorded by `frame req`, cleared by `frame inbox`).
# One line each: token, age, state, first line of the text. The state comes
# live from the TARGET's broker (FrameBrokerState): queued #N, working <age>,
# blocked (paused on its human), reply on its way, in your inbox, or lost (the
# frame died or rebooted, or it finished without reply text). A lost request
# is reported once, then dropped from the list.
#   `frame req status` is never a send: a request needs TEXT, and status's
#   arguments must all be tokens (NAME/TOPIC#rN). So `frame req status run the
#   tests` still sends "run the tests" to a frame whose topic is status.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

# ── frame req status ──────────────────────────────────────────────────────────
_is_status=0
if [[ "${1:-}" == status ]]; then
  _is_status=1
  for _a in "${@:2}"; do
    [[ "$_a" == */*\#r<-> ]] || { _is_status=0; break; }
  done
fi
if (( _is_status )); then
  shift
  if ! frame_self_identity; then
    echo "$X_MARK frame req status must be run from inside a frame (it reads that frame's outbox)" >&2
    exit 1
  fi
  FROM="$SELF_NAME/$SELF_TOPIC"
  _own="$FRAME_RUNDIR/$SELF_NAME-$SELF_TOPIC.nvim"
  if [[ ! -S "$_own" ]]; then
    echo "$X_MARK no frame session for $FROM (no socket at $_own)" >&2
    frame_session_down_hint "$SELF_NAME" "$SELF_TOPIC"
    exit 1
  fi
  _q=${(j:\t:)@}
  if ! _rows=$(frame_rpc_expr "$_own" "v:lua.FrameOutboxQuery('${_q//\'/\'\'}')"); then
    echo "$X_MARK session at $_own didn't answer — layout may predate req status;" >&2
    echo "  reboot the frame (:FrameQuit, then frame wt $SELF_TOPIC)" >&2
    exit 1
  fi
  if [[ -z "$_rows" ]]; then
    echo "$OK_MARK nothing outstanding — every request you sent has been answered and read"
    exit 0
  fi
  typeset -a _lines; _lines=()
  for _row in "${(@f)_rows}"; do
    _f=("${(@ps:\t:)_row}")
    _tok=${_f[1]} _age=${_f[2]:-} _here=${_f[3]:-0} _line=${_f[4]:-}
    [[ -n "$_age" ]] && _age=$(frame_fmt_age "$_age") || _age=-
    if [[ "$_here" == 1 ]]; then
      REQ_STATE=here REQ_DESC="in your inbox"
    else
      frame_req_probe "$_tok" "$FROM"
    fi
    # lost/unknown carry a long reason; keep the STATE column short and put
    # the reason after the request text.
    _st=$REQ_DESC _why=""
    if [[ "$REQ_DESC" == (lost|unknown|blocked)\ \(*\) ]]; then
      _st=${REQ_DESC%% *} _why="  (${${REQ_DESC#* \(}%\)})"
    fi
    _lines+=("$(printf '%-28s %5s  %-18s %s%s' "$_tok" "$_age" "$_st" "$_line" "$_why")")
    # A lost request is reported once, then dropped, so the list doesn't fill
    # with the dead.
    if [[ "$REQ_STATE" == lost && "$_age" != - ]]; then
      frame_rpc_expr "$_own" "v:lua.FrameOutboxForget('${_tok//\'/\'\'}')" >/dev/null || true
    fi
  done
  printf '%-28s %5s  %-18s %s\n' TOKEN AGE STATE REQUEST
  print -rl -- "${_lines[@]}"
  exit 0
fi

if (( $# < 1 )); then
  echo "$X_MARK usage: frame req <topic|name/topic> TEXT…   |   frame req status [TOKEN…]" >&2
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
    echo "token: $NAME/$TOPIC#$_result"
    echo "check later: frame req status $NAME/$TOPIC#$_result"
    # Record it in our own outbox (best-effort — a send from a bare shell has
    # no session to record into). First line of the text, tabs flattened.
    if [[ -S "$FRAME_RUNDIR/$SELF_NAME-$SELF_TOPIC.nvim" ]]; then
      _first=${${TEXT%%$'\n'*}//$'\t'/ }
      (( ${#_first} > 60 )) && _first="${_first[1,57]}..."
      _tk="$NAME/$TOPIC#$_result"
      frame_rpc_expr "$FRAME_RUNDIR/$SELF_NAME-$SELF_TOPIC.nvim" \
        "v:lua.FrameOutboxAdd('${_tk//\'/\'\'}','${_first//\'/\'\'}')" >/dev/null || true
    fi ;;
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
