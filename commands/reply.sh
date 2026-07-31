# frame reply — the Stop-hook sensor: reads the just-ended turn's last assistant
# message from the transcript Claude Code pipes in as JSON on stdin, and hands it
# to the broker (FrameOnStop → FrameBrokerOnTurnEnd in layouts/worktree.lua),
# which routes the in-flight request's answer home and feeds claude the next
# queued one. Wired into the Stop hook alongside `frame notify` (see
# frame_write_claude_hooks); like notify it must never disrupt the hook, so it
# always exits 0. Takes no arguments — routing is the broker's job now (the old
# explicit `frame reply TEXT` form is retired). See docs/claude-broker.md.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

if (( $# )); then
  echo "$X_MARK frame reply takes no arguments — it is the Stop hook; the broker routes replies" >&2
  exit 2
fi

# Which frame are we in? No frame → nothing to route from. Stay silent + exit 0:
# the hook must never fail on our account.
if ! frame_self_identity; then
  exit 0
fi
SOCKET="$FRAME_RUNDIR/$SELF_NAME-$SELF_TOPIC.nvim"
if [[ ! -S "$SOCKET" ]]; then
  exit 0
fi

# Without a piped payload (a human typed `frame reply` at a
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
