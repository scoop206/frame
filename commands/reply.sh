# frame reply [TEXT…] — reply home to whoever last messaged this frame with
# `frame req`. Two forms:
#
#   frame reply                (bare)  the Stop-hook sensor: reads the just-ended
#                                      turn's last assistant message from the
#                                      transcript Claude Code pipes in as JSON on
#                                      stdin, and routes it to this frame's armed
#                                      return addresses (FrameOnTurnEnd).
#   frame reply "all done"     (text)  route TEXT explicitly, ignoring the turn.
#
# Either way the reply lands in the sender's inbox (`frame inbox`) and the armed
# address is cleared (one-shot). Wired into the Stop hook alongside `frame
# notify` (see frame_write_claude_hooks); like notify it must never disrupt the
# hook, so the bare form always exits 0. See docs/agent-messaging.md.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

# Which frame are we in? No frame → nothing to reply from. (Bare/hook form must
# stay silent and exit 0; the explicit form can be a touch louder.)
if ! frame_self_identity; then
  (( $# )) && echo "$X_MARK frame reply must be run from inside a frame" >&2
  exit $(( $# ? 1 : 0 ))
fi
SOCKET="/tmp/$SELF_NAME-$SELF_TOPIC.nvim"
if [[ ! -S "$SOCKET" ]]; then
  (( $# )) && echo "$X_MARK no frame session for $SELF_NAME/$SELF_TOPIC" >&2
  exit $(( $# ? 1 : 0 ))
fi

if (( $# )); then
  # Explicit reply — route TEXT directly.
  TEXT="$*"
  _esc=${TEXT//\'/\'\'}
  _n=$(nvim --headless --server "$SOCKET" \
    --remote-expr "v:lua.FrameOnTurnEnd('$_esc')" 2>/dev/null) || _n=0
  echo "$OK_MARK replied to $_n waiting"
  exit 0
fi

# Bare/hook form. Without a piped payload (a human typed `frame reply` at a
# prompt) there's nothing to read — say so instead of blocking on stdin.
if [[ -t 0 ]]; then
  echo "$OK_MARK frame reply: no message and no hook payload on stdin — nothing to do"
  exit 0
fi

# Stash Claude Code's hook JSON to a temp file and let nvim (vim.json) parse both
# it and the transcript — all JSON parsing stays in Lua. Best-effort throughout:
# the Stop hook must not fail on our account.
_tmp=$(mktemp "${TMPDIR:-/tmp}/frame-reply.XXXXXX") 2>/dev/null || exit 0
cat > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; exit 0; }
_p=${_tmp//\'/\'\'}
nvim --headless --server "$SOCKET" \
  --remote-expr "v:lua.FrameReplyFromHook('$_p')" >/dev/null 2>&1 || true
rm -f "$_tmp"
exit 0
