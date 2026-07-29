# frame inbox — show and clear THIS frame's inbox: the reports other frames have
# delivered here (replies to your `frame req` messages, or notes left with
# `frame deliver`). Reading drains it (FrameInboxDrain in layouts/worktree.lua),
# so each message is shown once. Run from inside a frame — the inbox is that
# frame's, read over its own socket. See docs/agent-messaging.md.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

if (( $# )); then
  echo "$X_MARK frame inbox takes no arguments" >&2
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
