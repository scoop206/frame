#!/usr/bin/env zsh
# frame reply — the Stop-hook sensor. Bare form reads Claude Code's hook JSON on
# stdin (transcript path) and hands it to the broker (FrameReplyFromHook →
# FrameOnStop). The old explicit `frame reply TEXT` form is retired — routing is
# the broker's job now. Identity comes from a shell-frame env; a planted socket +
# FAKE_NVIM_EXPR_RESULT stand in for the live session's answer.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

as_work() { export FRAME_NAME=$TNAME FRAME_TOPIC=work; }

test_explicit_form_is_retired() {
  as_work
  _mksock "/tmp/$TNAME-work.nvim"
  run_frame reply "widget built, tests green"
  assert_status 2
  assert_contains "$OUT" "takes no arguments"
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

test_bare_form_outside_a_frame_exits_zero() {
  # No frame identity, but the Stop hook must never fail on our account.
  local out st
  out=$(print -r -- '{"transcript_path":"/nonexistent"}' | "$FRAME_BIN" reply 2>&1)
  st=$?
  assert_eq "$st" "0" "bare form outside a frame must still exit 0"
  assert_eq "$out" "" "bare form outside a frame must stay silent"
}

run_tests "$0"
