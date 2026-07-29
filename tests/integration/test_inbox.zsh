#!/usr/bin/env zsh
# frame inbox — show and drain THIS frame's inbox (FrameInboxDrain). Identity
# comes from a shell-frame env; a planted AF_UNIX socket at the frame's own path
# satisfies the `-S` check, and FAKE_NVIM_EXPR_RESULT stands in for the drained
# text ('' → empty).
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

in_hub() { export FRAME_NAME=$TNAME FRAME_TOPIC=hub; }

test_shows_inbox_contents() {
  in_hub
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT="from $TNAME/work:
widget built, tests green"
  run_frame inbox
  assert_status 0
  assert_contains "$OUT" "from $TNAME/work:"
  assert_contains "$OUT" "widget built, tests green"
}

test_empty_inbox_says_so() {
  in_hub
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT=""
  run_frame inbox
  assert_status 0
  assert_contains "$OUT" "inbox empty"
}

test_refuses_when_not_in_a_frame() {
  run_frame inbox
  assert_status 1
  assert_contains "$OUT" "must be run from inside a frame"
}

test_no_session_fails() {
  in_hub   # identity resolves, but no socket planted
  run_frame inbox
  assert_status 1
  assert_contains "$OUT" "no frame session for $TNAME/hub"
}

test_rejects_arguments() {
  in_hub
  run_frame inbox extra args
  assert_status 2
  assert_contains "$OUT" "takes no arguments"
}

run_tests "$0"
