# frame inbox [--wait [--timeout N] [--count K]] — show and clear THIS frame's
# inbox: the reports other frames have delivered here (replies to your
# `frame req` messages, or notes left with `frame deliver`). Reading drains it
# (FrameInboxDrain in layouts/worktree.lua), so each message is shown once.
#
# The bare form returns immediately (empty inbox → "inbox empty"). --wait
# blocks until mail arrives, then drains and prints it — the receive half of a
# req→reply round-trip, so an orchestrator can dispatch work and block on the
# answer inside one turn. The wait polls the frame's own socket from THIS
# subprocess (FrameInboxDrainAtLeast, ~1s cadence), so the session's nvim never
# blocks and the human keeps their editor. --timeout N gives up after N
# seconds (default 900; exits 3, distinct from delivery 0 and error 1);
# --count K holds out until K messages are present, then drains ALL of them —
# a fan-in barrier for parallel dispatch. Run from inside a frame — the inbox
# is that frame's, read over its own socket. See docs/head-frame.md and
# docs/agent-messaging.md.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

WAIT=0 TIMEOUT=900 COUNT=1 MODIFIER=""
USAGE="usage: frame inbox [--wait [--timeout SECONDS] [--count N]]"
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
    *)
      echo "$X_MARK frame inbox: unknown argument '$1'" >&2
      echo "  $USAGE" >&2
      exit 2 ;;
  esac
done
if (( ! WAIT )) && [[ -n "$MODIFIER" ]]; then
  echo "$X_MARK frame inbox: $MODIFIER only makes sense with --wait" >&2
  echo "  $USAGE" >&2
  exit 2
fi

if ! frame_self_identity; then
  echo "$X_MARK frame inbox must be run from inside a frame (it reads that frame's inbox)" >&2
  exit 1
fi

SOCKET="/tmp/$SELF_NAME-$SELF_TOPIC.nvim"
if [[ ! -S "$SOCKET" ]]; then
  echo "$X_MARK no frame session for $SELF_NAME/$SELF_TOPIC (no socket at $SOCKET)" >&2
  exit 1
fi

if (( ! WAIT )); then
  if _out=$(nvim --headless --server "$SOCKET" --remote-expr "v:lua.FrameInboxDrain()"); then
    if [[ -z "$_out" ]]; then
      echo "$OK_MARK inbox empty"
    else
      print -r -- "$_out"
    fi
  else
    echo "$X_MARK session at $SOCKET didn't answer — layout may predate FrameInboxDrain" >&2
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
    if ! _out=$(nvim --headless --server "$SOCKET" \
        --remote-expr "v:lua.FrameInboxDrainAtLeast($COUNT)"); then
      echo "$X_MARK session at $SOCKET didn't answer — layout may predate" >&2
      echo "  FrameInboxDrainAtLeast; reboot the frame (:FrameQuit, then frame wt $SELF_TOPIC)" >&2
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
