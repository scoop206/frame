#!/usr/bin/env zsh
# frame reply — route this frame's answer home to whoever req'd it. Explicit
# form (`frame reply TEXT`) calls FrameOnTurnEnd; bare form reads Claude Code's
# hook JSON on stdin (transcript path) and calls FrameReplyFromHook. Identity
# comes from a shell-frame env; a planted socket + FAKE_NVIM_EXPR_RESULT stand in
# for the live session's routing count.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

as_work() { export FRAME_NAME=$TNAME FRAME_TOPIC=work; }

test_explicit_reply_routes_and_reports_count() {
  as_work
  _mksock "/tmp/$TNAME-work.nvim"
  export FAKE_NVIM_EXPR_RESULT=1
  run_frame reply "widget built, tests green"
  assert_status 0
  assert_contains "$OUT" "replied to 1 waiting"
}

test_explicit_reply_refuses_when_not_in_a_frame() {
  run_frame reply "who am I even talking to"
  assert_status 1
  assert_contains "$OUT" "must be run from inside a frame"
}

test_explicit_reply_no_session_fails() {
  as_work   # identity resolves, but no socket planted
  run_frame reply "hello?"
  assert_status 1
  assert_contains "$OUT" "no frame session"
}

test_hook_form_reads_stdin_payload_and_exits_zero() {
  # Bare form fed a hook payload on stdin (a pipe, so not a tty): it stashes the
  # JSON and hands the path to nvim (stubbed here). Must stay silent + exit 0 so
  # it never disrupts the Stop hook.
  as_work
  _mksock "/tmp/$TNAME-work.nvim"
  export FAKE_NVIM_EXPR_RESULT=0
  local out st
  out=$(print -r -- '{"transcript_path":"/nonexistent"}' | "$FRAME_BIN" reply 2>&1)
  st=$?
  assert_eq "$st" "0" "bare hook form must exit 0"
  assert_eq "$out" "" "bare hook form must stay silent"
}

run_tests "$0"
