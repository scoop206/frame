#!/usr/bin/env zsh
# frame req — hand a request to ANOTHER frame's claude broker (FrameBrokerSubmit)
# with a remote return address, so the answer routes back to THIS frame's inbox.
# A planted AF_UNIX socket satisfies the target `-S` check; FAKE_BROKER_SUBMIT is
# the broker's reply (a request id like 'r1' by default, or a verdict). The
# caller's own identity (the return address) comes from a shell-frame env;
# sending from no frame is refused. $TNAME keeps socket paths unique.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

# Stand in for "running inside the hub frame" — identity from the session env.
in_hub() { export FRAME_NAME=$TNAME FRAME_TOPIC=hub; }

test_name_topic_target_submits_and_names_return_address() {
  in_hub
  _mksock "/tmp/$TNAME-alpha.nvim"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  run_frame req "$TNAME/alpha" "what is blocking the migration?"
  assert_status 0
  assert_contains "$OUT" "sent to $TNAME/alpha"
  assert_contains "$OUT" "reply → $TNAME/hub inbox"
  # the request carries the text and a remote return address to this frame
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameBrokerSubmit("
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "what is blocking the migration?"
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "'remote:$TNAME/hub'"
}

test_bare_topic_pairs_with_own_name() {
  in_hub
  _mksock "/tmp/$TNAME-alpha.nvim"
  run_frame req alpha "run the tests again"
  assert_status 0
  assert_contains "$OUT" "sent to $TNAME/alpha"
}

test_refuses_when_not_in_a_frame() {
  # No FRAME_NAME and a non-git sandbox cwd → no return address → refuse.
  _mksock "/tmp/$TNAME-alpha.nvim"
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
  export FAKE_BROKER_SUBMIT=no-claude-buffer
  run_frame req "$TNAME/alpha" "nowhere to type"
  assert_status 1
  assert_contains "$OUT" "no 'claude' buffer"
}

test_full_queue_is_retryable() {
  in_hub
  _mksock "/tmp/$TNAME-alpha.nvim"
  export FAKE_BROKER_SUBMIT=queue-full
  run_frame req "$TNAME/alpha" "one more"
  assert_status 4
  assert_contains "$OUT" "queue is full"
}

run_tests "$0"
