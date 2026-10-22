#!/usr/bin/env zsh
# `frame reload-editor` (the PostToolUse editor-reload hook) — its do-no-harm
# guards. Its wiring in claude/hooks.json is covered by test_claude_hooks.zsh.
# The buffer logic itself lives in Lua
# (layouts/session.lua FrameReload) and needs a real nvim; the path-parse +
# socket RPC is covered in tests/integration/test_reload_editor.zsh.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"
export FRAME_ROOT="$FRAME_CHECKOUT"
source "$FRAME_ROOT/lib/helpers.sh"

# Edit-shaped PostToolUse payload, for feeding the hook on stdin.
_edit_payload() { print -r -- "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$1\"}}"; }

# ── do-no-harm guards (exit 0, silent) ────────────────────────────────────────

test_noop_outside_a_frame() {
  # sandbox_up strips FRAME_NAME/FRAME_TOPIC, so this is "not in a frame". The
  # hook must bail before any nvim contact: exit 0 with no output on stdout/err.
  local out rc
  out=$(_edit_payload /some/README.md | "$FRAME_BIN" reload-editor 2>&1) && rc=0 || rc=$?
  assert_eq "$rc" 0
  assert_eq "$out" "" "reload-editor emitted output on the idle (no-frame) path"
}

test_noop_when_socket_absent() {
  # In a frame by identity, but no live nvim socket → nothing to drive. Still a
  # clean, silent exit 0 (Tier 2 autoread catches the buffer up later).
  local out rc
  out=$(FRAME_NAME=$TNAME FRAME_TOPIC=work \
        _edit_payload /some/README.md | "$FRAME_BIN" reload-editor 2>&1) && rc=0 || rc=$?
  assert_eq "$rc" 0
  assert_eq "$out" "" "reload-editor emitted output when the socket was absent"
}

run_tests "$0"
