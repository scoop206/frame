# frame claude — a client of THIS frame's claude broker (docs/claude-broker.md).
#
#   frame claude [--timeout N] TEXT…   ask this frame's claude and block for the
#                                      answer. Queues behind anything already
#                                      running, so several callers can ask at once
#                                      and each gets their own answer.
#   frame claude status                show the broker's queue
#
# Submits TEXT to the broker and polls for that request's answer. Ctrl-C
# detaches rather than drops — the answer lands in `frame inbox` once the turn
# finishes — as does a timeout. Exit codes: 0 answered, 2 usage, 3 timed out
# (answer → inbox), 4 queue full, 1 everything else. Run from inside a frame.
# See docs/claude-broker.md and docs/agent-messaging.md.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

# Identity + socket — both modes need them. --headless for the same reason as
# status.sh: keep the expr result on stdout, terminal probes off the tty.
_resolve_socket() {
  if ! frame_self_identity; then
    echo "$X_MARK frame claude must be run from inside a frame (it talks to that frame's claude)" >&2
    exit 1
  fi
  SOCKET="/tmp/$SELF_NAME-$SELF_TOPIC.nvim"
  if [[ ! -S "$SOCKET" ]]; then
    echo "$X_MARK no frame session for $SELF_NAME/$SELF_TOPIC (no socket at $SOCKET)" >&2
    frame_session_down_hint "$SELF_NAME" "$SELF_TOPIC"
    exit 1
  fi
}

# frame claude status — dump the queue.
if [[ "${1:-}" == status ]]; then
  if (( $# > 1 )); then
    echo "$X_MARK frame claude status takes no arguments" >&2
    exit 2
  fi
  _resolve_socket
  if ! _out=$(nvim --headless --server "$SOCKET" --remote-expr "v:lua.FrameBrokerStatus()"); then
    echo "$X_MARK session at $SOCKET didn't answer — layout may predate the broker" >&2
    exit 1
  fi
  if [[ -z "$_out" ]]; then
    echo "$OK_MARK broker idle (nothing queued)"
  else
    print -r -- "$_out"
  fi
  exit 0
fi

TIMEOUT=300
USAGE="usage: frame claude [--timeout SECONDS] TEXT…  |  frame claude status"

if [[ "${1:-}" == --timeout ]]; then
  # <-> is the zsh all-digits pattern; rejects '', 'abc', '-5'.
  if [[ "${2:-}" != <-> ]] || (( $2 < 1 )); then
    echo "$X_MARK frame claude: --timeout needs a positive integer" >&2
    echo "  $USAGE" >&2
    exit 2
  fi
  TIMEOUT=$2; shift 2
fi

if (( $# == 0 )); then
  echo "$X_MARK frame claude: nothing to send" >&2
  echo "  $USAGE" >&2
  exit 2
fi

_resolve_socket

# Vimscript single-quoted strings: only ' needs escaping, as ''.
TEXT="$*"
_esc=${TEXT//\'/\'\'}

# Submit into the broker — returns a request id (e.g. r7). A busy claude is not
# a refusal here: the request just queues.
if ! ID=$(nvim --headless --server "$SOCKET" \
    --remote-expr "v:lua.FrameBrokerSubmit('$_esc', 'local')"); then
  echo "$X_MARK session at $SOCKET didn't accept the request — layout may predate" >&2
  echo "  the broker; reboot the frame (:FrameQuit, then frame wt $SELF_TOPIC)" >&2
  exit 1
fi
case "$ID" in
  r<->) ;;                       # a request id
  no-claude-buffer)
    echo "$X_MARK this frame has no 'claude' buffer to talk to" >&2
    exit 1 ;;
  queue-full)
    echo "$X_MARK claude's queue is full — try again shortly" >&2
    exit 4 ;;
  *)
    echo "$X_MARK unexpected response from the broker: $ID" >&2
    exit 1 ;;
esac

# Ctrl-C (and the timeout below) DETACH rather than drop: redirect the in-flight
# answer to this frame's inbox so the turn's work isn't lost. Best-effort —
# never let cleanup block the exit.
_detach() {
  nvim --headless --server "$SOCKET" \
    --remote-expr "v:lua.FrameBrokerCancel('$ID', 'inbox')" >/dev/null 2>&1 || true
}
trap '_detach; print -u2 -r -- ""; echo "$OK_MARK detached — answer will land in: frame inbox" >&2; exit 130' INT

echo "$OK_MARK queued ($ID) — waiting for claude (up to ${TIMEOUT}s, Ctrl-C to detach)…" >&2

# Poll this request's answer (~1s cadence, like `frame inbox --wait`).
DEADLINE=$(( SECONDS + TIMEOUT ))
while :; do
  if [[ ! -S "$SOCKET" ]]; then
    echo "$X_MARK frame session for $SELF_NAME/$SELF_TOPIC went away mid-wait" >&2
    exit 1
  fi
  if ! _out=$(nvim --headless --server "$SOCKET" \
      --remote-expr "v:lua.FrameBrokerAwait('$ID')"); then
    echo "$X_MARK session at $SOCKET stopped answering mid-wait" >&2
    exit 1
  fi
  case "${_out%%$'\n'*}" in
    done)
      _ans="${_out#done}"; _ans="${_ans#$'\n'}"
      if [[ -z "$_ans" ]]; then
        print -r -- "(no textual answer)"
      else
        print -r -- "$_ans"
      fi
      exit 0 ;;
    gone)
      echo "$X_MARK the broker lost track of $ID (evicted?) — check: frame inbox" >&2
      exit 1 ;;
  esac
  if (( SECONDS >= DEADLINE )); then
    _detach
    echo "$X_MARK no answer after ${TIMEOUT}s — detached; it'll land in: frame inbox" >&2
    exit 3
  fi
  sleep 1
done
