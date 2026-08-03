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
  while :; do
    if [[ ! -S "$SOCKET" ]]; then
      echo "$X_MARK frame session for $SELF_NAME/$SELF_TOPIC went away mid-wait" >&2
      exit 1
    fi
    if ! _out=$(nvim --headless --server "$SOCKET" --remote-expr "$DRAIN_EXPR"); then
      echo "$X_MARK session at $SOCKET didn't answer — layout may predate" >&2
      echo "  $DRAIN_FN; reboot the frame (:FrameQuit, then frame wt $SELF_TOPIC)" >&2
      exit 1
    fi
    if [[ -n "$_out" ]]; then
      print -r -- "$_out"
      break
    fi
    if (( SECONDS >= DEADLINE )); then
      echo "$X_MARK inbox --wait: no mail after ${TIMEOUT}s" >&2
      exit 3
    fi
    sleep 1
  done
fi
