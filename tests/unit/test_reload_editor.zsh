#!/usr/bin/env zsh
# `frame reload-editor` (the PostToolUse editor-reload hook) — its do-no-harm
# guards, and the drift/scaffold bookkeeping that must stay in step so a
# freshly-written settings.json still classifies "safe" now that PostToolUse is
# one of frame's canonical hooks. The buffer logic itself lives in Lua
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

# ── drift / scaffold bookkeeping stays in step ───────────────────────────────

test_fresh_hooks_classify_safe() {
  # frame_write_claude_hooks writes a PostToolUse block; frame_settings_is_frame_only
  # must still call the result "safe" (its allowlist gained "PostToolUse"). If the
  # two drifted, --force re-sync would refuse a frame's own file as "custom".
  command -v jq >/dev/null 2>&1 || { skip "jq not installed"; return; }
  mkdir -p "$SANDBOX/proj"; cd "$SANDBOX/proj"
  frame_write_claude_hooks
  assert_eq "$(frame_settings_is_frame_only .claude/settings.json)" "safe"
}

test_fresh_hooks_wire_reload_editor() {
  # A freshly-scaffolded file carries the PostToolUse → frame reload-editor hook
  # with its tool matcher, and reports nothing missing (reload-editor is one of
  # the required hooks now).
  mkdir -p "$SANDBOX/proj"; cd "$SANDBOX/proj"
  frame_write_claude_hooks
  local body=$(<.claude/settings.json)
  assert_contains "$body" '"PostToolUse"'
  assert_contains "$body" "frame reload-editor"
  assert_contains "$body" "Edit|Write|MultiEdit|NotebookEdit"
  assert_eq "$(frame_claude_hooks_missing .claude/settings.json)" "" \
    "a freshly-written settings.json reports hooks missing"
}

test_reload_editor_is_a_required_hook() {
  # The canonical list drives init's drift check / --force re-sync; reload-editor
  # must be in it, or the feature never propagates to existing frame projects.
  assert_contains "$(frame_claude_required_hooks)" "frame reload-editor"
}

test_file_predating_the_hook_reports_it_missing() {
  # A settings.json with the pre-PostToolUse frame hooks is drifted: the missing
  # list must name `frame reload-editor` so init points the user at --force.
  mkdir -p "$SANDBOX/proj"; cd "$SANDBOX/proj"; mkdir -p .claude
  print -r -- '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"frame notify"},{"type":"command","command":"frame reply"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"frame status --prompt"}]}],"Notification":[{"hooks":[{"type":"command","command":"frame notify --blocked"}]}],"SessionStart":[{"hooks":[{"type":"command","command":"frame swarm --context"}]}]}}' \
    > .claude/settings.json
  local missing=$(frame_claude_hooks_missing .claude/settings.json)
  assert_contains "$missing" "frame reload-editor"
}

run_tests "$0"
