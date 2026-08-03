#!/usr/bin/env zsh
# `frame reload-editor` end-to-end: with a live nvim socket, it parses the edited
# path out of a PostToolUse payload on stdin and drives THIS frame's nvim with
# v:lua.FrameReload('<abs-path>'). Identity comes from a shell-frame env; a
# planted unix socket + the nvim stub stand in for the running session, and
# FAKE_NVIM_EXPR_LOG captures the exact remote-expr so we can assert the path.
# (The buffer open/dirty/clean logic itself is Lua in layouts/session.lua and
# needs a real nvim; here we prove the path handed to it is right.)
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

# A frame with a live socket + a captured expr log. Exports FRAME_NAME/FRAME_TOPIC
# so reload-editor resolves $FRAME_RUNDIR/$NAME-$TOPIC.nvim to the planted socket;
# the stub answers any expr with 'ok' and appends it to $EXPRLOG.
_arm_frame() {
  command -v python3 >/dev/null 2>&1 || { skip "python3 needed to plant a socket"; return 1; }
  command -v jq >/dev/null 2>&1 || { skip "jq needed to parse the payload"; return 1; }
  export FRAME_NAME=$TNAME FRAME_TOPIC=work
  _mksock "$FRAME_RUNDIR/$TNAME-work.nvim"
  export EXPRLOG="$SANDBOX/expr.log"; : > "$EXPRLOG"
  export FAKE_NVIM_EXPR_LOG="$EXPRLOG" FAKE_NVIM_EXPR_RESULT=ok
}

# Run reload-editor with $1 as the JSON payload on stdin; capture rc.
_run_hook() { local rc; print -r -- "$1" | "$FRAME_BIN" reload-editor; rc=$?; return $rc; }

test_edit_payload_reloads_the_edited_path() {
  _arm_frame || return
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/proj/README.md"}}'
  assert_eq "$?" 0
  assert_contains "$(<$EXPRLOG)" "v:lua.FrameReload('/tmp/proj/README.md')"
}

test_write_payload_uses_file_path() {
  _arm_frame || return
  _run_hook '{"tool_name":"Write","tool_input":{"file_path":"/tmp/proj/docs/x.md"}}'
  assert_contains "$(<$EXPRLOG)" "FrameReload('/tmp/proj/docs/x.md')"
}

test_multiedit_payload_uses_file_path() {
  _arm_frame || return
  _run_hook '{"tool_name":"MultiEdit","tool_input":{"file_path":"/tmp/proj/a.txt","edits":[]}}'
  assert_contains "$(<$EXPRLOG)" "FrameReload('/tmp/proj/a.txt')"
}

test_notebookedit_payload_uses_notebook_path() {
  # NotebookEdit carries notebook_path, not file_path.
  _arm_frame || return
  _run_hook '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"/tmp/proj/nb.ipynb"}}'
  assert_contains "$(<$EXPRLOG)" "FrameReload('/tmp/proj/nb.ipynb')"
}

test_relative_path_resolved_against_cwd() {
  # A cwd-relative file_path is made absolute before it reaches FrameReload.
  _arm_frame || return
  mkdir -p "$SANDBOX/wt"; cd "$SANDBOX/wt"
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"sub/note.md"}}'
  assert_contains "$(<$EXPRLOG)" "FrameReload('$SANDBOX/wt/sub/note.md')"
}

test_single_quote_in_path_is_escaped() {
  # A quote in the path would break out of the Vimscript string literal; it must
  # be doubled ('' ) so the expr stays well-formed.
  _arm_frame || return
  _run_hook "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/proj/it's.md\"}}"
  assert_contains "$(<$EXPRLOG)" "FrameReload('/tmp/proj/it''s.md')"
}

test_no_path_in_payload_is_a_silent_noop() {
  # A payload with no file_path/notebook_path (or junk) → no RPC issued, exit 0.
  _arm_frame || return
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  assert_eq "$?" 0
  assert_eq "$(<$EXPRLOG)" "" "issued a FrameReload for a payload with no path"
}

run_tests "$0"
