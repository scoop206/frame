# frame inbox [--wait [--timeout N] [--count K | --for TOKEN…]] — show and clear
# THIS frame's inbox: the reports other frames have delivered here (replies to
# your `frame req` messages, or notes left with `frame deliver`). Reading drains
# it (FrameInboxDrain in layouts/session.lua), so each message is shown once.
#
# The bare form returns immediately (empty inbox → "inbox empty"). --wait
# blocks until mail arrives, then drains and prints it — the receive half of a
# req→reply round-trip, so an orchestrator can dispatch work and block on the
# answer inside one turn. The wait polls the frame's own socket from THIS
# subprocess (FrameInboxDrainAtLeast, ~1s cadence), so the session's nvim never
# blocks and the human keeps their editor. --timeout N gives up after N
# seconds (default 900; exits 3, distinct from delivery 0 and error 1);
# --count K holds out until K messages are present, then drains ALL of them —
# a fan-in barrier for parallel dispatch. --for TOKEN (repeatable) is the
# correlated barrier: it holds out until the specific replies with those `from#id`
# tokens (printed by `frame req`) have all arrived, then drains ONLY those,
# leaving unrelated mail — so a fan-out caller collects exactly its own answers.
# --for and --count are two ways to say "how many", so they're mutually exclusive.
#
# While --wait --for waits, every few polls it also asks each awaited reply's
# TARGET what became of the request (frame_req_probe → FrameBrokerState), so a
# reply that can't come doesn't run out the clock:
#   exit 5  lost     the target frame is gone or rebooted, or it finished the
#                    turn without reply text — no reply is coming
# Nothing is drained on 5. A target that is on our request but paused waiting
# for ITS human (status "blocked") is only a warning, printed once per token:
# the wait goes on. Not an exit, because that status can linger after the human
# answers (until the turn's Stop or the next prompt), and an exit would make the
# caller give up on a frame that is already working again. On timeout (3) --for
# says what each target was doing ("working 7m", "queued #2", "blocked").
# Exit codes in full: 0 delivered, 1 error, 2 usage, 3 timeout, 5 lost.
# Run from inside a frame — the inbox is that frame's, read over its own socket.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

WAIT=0 TIMEOUT=900 COUNT=1 MODIFIER=""
typeset -a FORS; FORS=()
USAGE="usage: frame inbox [--wait [--timeout SECONDS] [--count N | --for TOKEN…]]"
while (( $# )); do
  case "$1" in
    --wait)
      WAIT=1; shift ;;
    --timeout|--count)
      # <-> is the zsh all-digits pattern; rejects '', 'abc', '-5'.
      if [[ "${2:-}" != <-> ]] || (( $2 < 1 )); then
        echo "$X_MARK frame inbox: $1 needs a positive integer" >&2
        echo "  $USAGE" >&2
        exit 2
      fi
      MODIFIER=$1
      [[ "$1" == --timeout ]] && TIMEOUT=$2 || COUNT=$2
      shift 2 ;;
    --for)
      if [[ -z "${2:-}" ]]; then
        echo "$X_MARK frame inbox: --for needs a TOKEN (from#id, as printed by frame req)" >&2
        echo "  $USAGE" >&2
        exit 2
      fi
      FORS+=("$2")
      shift 2 ;;
    *)
      echo "$X_MARK frame inbox: unknown argument '$1'" >&2
      echo "  $USAGE" >&2
      exit 2 ;;
  esac
done
if (( ${#FORS} )) && [[ "$MODIFIER" == --count ]]; then
  echo "$X_MARK frame inbox: --for and --count can't be combined (both say how many)" >&2
  echo "  $USAGE" >&2
  exit 2
fi
# --for works with or without --wait (barrier vs drain-if-complete); --count and
# --timeout only make sense while waiting.
if (( ! WAIT )) && [[ "$MODIFIER" == --count || "$MODIFIER" == --timeout ]]; then
  echo "$X_MARK frame inbox: $MODIFIER only makes sense with --wait" >&2
  echo "  $USAGE" >&2
  exit 2
fi

if ! frame_self_identity; then
  echo "$X_MARK frame inbox must be run from inside a frame (it reads that frame's inbox)" >&2
  exit 1
fi

SOCKET="$FRAME_RUNDIR/$SELF_NAME-$SELF_TOPIC.nvim"
if [[ ! -S "$SOCKET" ]]; then
  echo "$X_MARK no frame session for $SELF_NAME/$SELF_TOPIC (no socket at $SOCKET)" >&2
  frame_session_down_hint "$SELF_NAME" "$SELF_TOPIC"
  exit 1
fi

# --for selects the token-keyed drain (an all-or-nothing barrier on the specific
# from#id replies); otherwise the count-keyed drain. Both are instant RPCs.
if (( ${#FORS} )); then
  # Vimscript single-quoted string; tokens joined by TAB (which never appears in
  # a from#id token). Only ' needs escaping, as ''.
  _tok=${(j:\t:)FORS}
  _tok=${_tok//\'/\'\'}
  DRAIN_FN="FrameInboxDrainFor"
  DRAIN_EXPR="v:lua.FrameInboxDrainFor('$_tok')"
else
  DRAIN_FN="FrameInboxDrainAtLeast"
  DRAIN_EXPR="v:lua.FrameInboxDrainAtLeast($COUNT)"
fi

if (( ! WAIT )); then
  # Bare (no --for): FrameInboxDrain takes everything. With --for: a single
  # non-blocking check of the barrier — drains iff all requested replies are here.
  (( ${#FORS} )) && NOW_EXPR="$DRAIN_EXPR" || NOW_EXPR="v:lua.FrameInboxDrain()"
  if _out=$(nvim --headless --server "$SOCKET" --remote-expr "$NOW_EXPR"); then
    if [[ -z "$_out" ]]; then
      if (( ${#FORS} )); then
        echo "$OK_MARK none of the requested replies have arrived yet"
      else
        echo "$OK_MARK inbox empty"
      fi
    else
      print -r -- "$_out"
    fi
  else
    echo "$X_MARK session at $SOCKET didn't answer — layout may predate the inbox" >&2
    exit 1
  fi
else
  # Block here, in this subprocess, polling the session with cheap instant
  # RPCs — never a vim.wait in the server, which would freeze the editor the
  # operator is sitting in for the length of the wait.
  DEADLINE=$(( SECONDS + TIMEOUT ))
  _from="$SELF_NAME/$SELF_TOPIC"
  _polls=0
  # _check_targets — for --for: probe each awaited reply that isn't already in
  # our inbox. Sets _lost / _blocked / _report (one line per token). Returns 1
  # when our own session can't say which replies are here (old layout): then
  # we don't judge, we just keep waiting.
  _check_targets() {
    _lost=() _blocked=() _report=()
    local _rows _row _t _here
    local -a _f
    _rows=$(frame_rpc_expr "$SOCKET" "v:lua.FrameOutboxQuery('$_tok')") || return 1
    for _row in "${(@f)_rows}"; do
      _f=("${(@ps:\t:)_row}")
      _t=${_f[1]} _here=${_f[3]:-0}
      [[ -n "$_t" ]] || continue
      if [[ "$_here" == 1 ]]; then _report+=("$_t: in your inbox"); continue; fi
      frame_req_probe "$_t" "$_from"
      _report+=("$_t: $REQ_DESC")
      case "$REQ_STATE" in
        lost)    _lost+=("$_t ${REQ_DESC#lost }") ;;
        blocked) _blocked+=("$_t") ;;
      esac
    done
    return 0
  }
  typeset -a _lost _blocked _report
  typeset -A _warned      # tokens we've already said are blocked
  while :; do
    if [[ ! -S "$SOCKET" ]]; then
      echo "$X_MARK frame session for $SELF_NAME/$SELF_TOPIC went away mid-wait" >&2
      exit 1
    fi
    if ! _out=$(nvim --headless --server "$SOCKET" --remote-expr "$DRAIN_EXPR"); then
      echo "$X_MARK session at $SOCKET didn't answer — layout may predate" >&2
      echo "  $DRAIN_FN; reboot the frame (:FrameQuit, then $(frame_boot_cmd "$SELF_NAME" "$SELF_TOPIC"))" >&2
      exit 1
    fi
    if [[ -n "$_out" ]]; then
      print -r -- "$_out"
      break
    fi
    _polls=$(( _polls + 1 ))
    # Every 5th poll (~5s), not every second: one RPC per awaited target.
    if (( ${#FORS} )) && (( _polls % 5 == 0 )) && _check_targets; then
      if (( ${#_lost} )); then
        for _l in "${_lost[@]}"; do echo "lost: $_l" >&2; done
        echo "  no reply is coming for that; nothing was drained (frame req status for the rest)" >&2
        exit 5
      fi
      for _b in "${_blocked[@]}"; do
        (( ${+_warned[$_b]} )) && continue
        _warned[$_b]=1
        echo "$WARN_MARK ${_b%\#*} is waiting on its human ($_b); still waiting" >&2
      done
    fi
    if (( SECONDS >= DEADLINE )); then
      echo "$X_MARK inbox --wait: no mail after ${TIMEOUT}s" >&2
      if (( ${#FORS} )) && _check_targets; then
        for _r in "${_report[@]}"; do echo "  $_r" >&2; done
      fi
      echo "  check later: frame req status" >&2
      exit 3
    fi
    sleep 1
  done
fi
