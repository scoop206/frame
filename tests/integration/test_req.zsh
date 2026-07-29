#!/usr/bin/env zsh
# frame req — send a request into another frame's `claude` buffer and arm a
# one-shot reply. A planted AF_UNIX socket satisfies the target `-S` check;
# FAKE_NVIM_EXPR_RESULT is what FrameRequest "returns" ('ok' | 'no-claude-buffer').
# The caller's own identity (the reply's return address) comes from a shell-frame
# env; sending from no frame is refused. $TNAME keeps socket paths unique.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

# Stand in for "running inside the hub frame" — identity from the session env.
in_hub() { export FRAME_NAME=$TNAME FRAME_TOPIC=hub; }

test_name_topic_target_sends_and_names_return_address() {
  in_hub
  _mksock "/tmp/$TNAME-alpha.nvim"
  export FAKE_NVIM_EXPR_RESULT=ok
  run_frame req "$TNAME/alpha" "what is blocking the migration?"
  assert_status 0
  assert_contains "$OUT" "sent to $TNAME/alpha"
  assert_contains "$OUT" "reply → $TNAME/hub inbox"
}

test_bare_topic_pairs_with_own_name() {
  in_hub
  _mksock "/tmp/$TNAME-alpha.nvim"
  export FAKE_NVIM_EXPR_RESULT=ok
  run_frame req alpha "run the tests again"
  assert_status 0
  assert_contains "$OUT" "sent to $TNAME/alpha"
}

test_refuses_when_not_in_a_frame() {
  # No FRAME_NAME and a non-git sandbox cwd → no return address → refuse.
  _mksock "/tmp/$TNAME-alpha.nvim"
  export FAKE_NVIM_EXPR_RESULT=ok
  run_frame req "$TNAME/alpha" "hello?"
  assert_status 1
  assert_contains "$OUT" "must be run from inside a frame"
}

test_dead_target_no_socket_fails() {
  in_hub
  run_frame req "$TNAME/ghost" "anyone home?"
  assert_status 1
  assert_contains "$OUT" "no frame session for $TNAME/ghost"
}

test_missing_text_is_usage_error() {
  in_hub
  _mksock "/tmp/$TNAME-alpha.nvim"
  run_frame req "$TNAME/alpha"
  assert_status 2
  assert_contains "$OUT" "nothing to send"
}

test_no_args_is_usage_error() {
  run_frame req
  assert_status 2
  assert_contains "$OUT" "usage: frame req"
}

test_frame_without_claude_buffer_reports_it() {
  in_hub
  _mksock "/tmp/$TNAME-alpha.nvim"
  export FAKE_NVIM_EXPR_RESULT=no-claude-buffer
  run_frame req "$TNAME/alpha" "nowhere to type"
  assert_status 1
  assert_contains "$OUT" "no 'claude' buffer"
}

run_tests "$0"
