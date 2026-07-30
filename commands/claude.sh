# frame claude [--timeout SECONDS] TEXT… — send TEXT to THIS frame's own claude
# and BLOCK until it answers, then print the answer here. The synchronous cousin
# of `frame req`: req fires a command at ANOTHER frame and routes the reply to
# your inbox to read later; `frame claude` talks to the claude sitting in your
# OWN frame and waits for it inline — one shell round-trip, no inbox dance.
#
#   frame claude "what's left on the migration?"
#   frame claude --timeout 120 "summarize the diff"
#
# It needs an IDLE claude. If claude is mid-turn it refuses (exit 4) rather than
# risk handing you the PREVIOUS turn's answer — wait for it to finish, or queue
# the message asynchronously with `frame req`. Exit codes: 0 answered, 2 usage,
# 3 timed out waiting, 4 claude busy/not ready (retry), 1 everything else.
# Run from inside a frame. See docs/agent-messaging.md.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

TIMEOUT=300
USAGE="usage: frame claude [--timeout SECONDS] TEXT…"

# --timeout is the only flag and must lead (everything after is TEXT, verbatim).
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

# This frame's own claude is the target, and its inbox receives the reply — so
# we need our own identity. No frame → nothing to talk to.
if ! frame_self_identity; then
  echo "$X_MARK frame claude must be run from inside a frame (it talks to that frame's claude)" >&2
  exit 1
fi

SOCKET="/tmp/$SELF_NAME-$SELF_TOPIC.nvim"
if [[ ! -S "$SOCKET" ]]; then
  echo "$X_MARK no frame session for $SELF_NAME/$SELF_TOPIC (no socket at $SOCKET)" >&2
  exit 1
fi

# Vimscript single-quoted strings: only ' needs escaping, as ''.
TEXT="$*"
_esc=${TEXT//\'/\'\'}

# Gate + flush + arm + submit, atomically in-session (FrameClaudeSend). One RPC
# so the idle check and the send can't race. --headless for the same reason as
# status.sh: keep the expr result on stdout and terminal probes off the tty.
if ! _verdict=$(nvim --headless --server "$SOCKET" \
    --remote-expr "v:lua.FrameClaudeSend('$_esc')"); then
  echo "$X_MARK session at $SOCKET didn't accept the send — layout may predate" >&2
  echo "  FrameClaudeSend; reboot the frame (:FrameQuit, then frame wt $SELF_TOPIC)" >&2
  exit 1
fi
case "$_verdict" in
  ok) ;;
  busy)
    echo "$X_MARK claude is mid-turn — frame claude needs an idle claude" >&2
    echo "  wait for it to finish, or queue the message with: frame req $SELF_TOPIC …" >&2
    exit 4 ;;
  not-ready)
    echo "$X_MARK claude isn't ready yet (still booting, or waiting at a dialog)" >&2
    exit 4 ;;
  no-claude-buffer)
    echo "$X_MARK this frame has no 'claude' buffer to talk to" >&2
    exit 1 ;;
  *)
    echo "$X_MARK unexpected response from the session: $_verdict" >&2
    exit 1 ;;
esac

echo "$OK_MARK sent — waiting for claude (up to ${TIMEOUT}s, Ctrl-C to stop)…" >&2

# Block here, polling our own inbox for the self-addressed reply the Stop hook
# routes home (FrameInboxDrainSelf leaves any unrelated mail for `frame inbox`).
# Same cheap ~1s-cadence poll as `frame inbox --wait` — the blocking lives in
# this subprocess, never a vim.wait that would freeze the editor.
DEADLINE=$(( SECONDS + TIMEOUT ))
while :; do
  if [[ ! -S "$SOCKET" ]]; then
    echo "$X_MARK frame session for $SELF_NAME/$SELF_TOPIC went away mid-wait" >&2
    exit 1
  fi
  if ! _out=$(nvim --headless --server "$SOCKET" \
      --remote-expr "v:lua.FrameInboxDrainSelf()"); then
    echo "$X_MARK session at $SOCKET stopped answering mid-wait" >&2
    exit 1
  fi
  if [[ -n "$_out" ]]; then
    print -r -- "$_out"
    exit 0
  fi
  if (( SECONDS >= DEADLINE )); then
    echo "$X_MARK no reply after ${TIMEOUT}s — is claude waiting on a permission prompt? check the pane" >&2
    exit 3
  fi
  sleep 1
done
