#!/usr/bin/env zsh
# frame deliver — append a report to a target frame's inbox (FrameInboxAdd). A
# planted AF_UNIX socket satisfies the target `-S` check; FAKE_NVIM_EXPR_RESULT
# stands in for the new inbox length the call returns. Unlike `frame req`,
# deliver with a NAME/TOPIC target needs no caller identity.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

test_delivers_to_named_target() {
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT=1
  run_frame deliver "$TNAME/hub" "migration finished"
  assert_status 0
  assert_contains "$OUT" "delivered to $TNAME/hub inbox (1 waiting)"
}

test_from_flag_is_accepted() {
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT=2
  run_frame deliver "$TNAME/hub" --from "$TNAME/auth" "done"
  assert_status 0
  assert_contains "$OUT" "delivered to $TNAME/hub inbox (2 waiting)"
}

test_id_flag_is_threaded_to_inbox_add() {
  # --id rides alongside --from and lands as the 3rd FrameInboxAdd arg — the
  # correlation id that lets the recipient's `frame inbox --for` match this reply.
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT=1
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  run_frame deliver "$TNAME/hub" --from "$TNAME/auth" --id r7 "done"
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameInboxAdd('$TNAME/auth', 'done', 'r7')"
}

test_id_before_from_also_accepted() {
  # The broker emits --from then --id, but order shouldn't matter.
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT=1
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  run_frame deliver "$TNAME/hub" --id r7 --from "$TNAME/auth" "done"
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameInboxAdd('$TNAME/auth', 'done', 'r7')"
}

test_plain_note_has_empty_id() {
  # A hand-written note (no --id) → empty id, so it never matches a --for token.
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT=1
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  run_frame deliver "$TNAME/hub" "just a note"
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameInboxAdd('', 'just a note', '')"
}

test_dead_target_fails() {
  run_frame deliver "$TNAME/ghost" "anyone?"
  assert_status 1
  assert_contains "$OUT" "no frame session for $TNAME/ghost"
}

test_missing_message_is_usage_error() {
  _mksock "/tmp/$TNAME-hub.nvim"
  run_frame deliver "$TNAME/hub"
  assert_status 2
  assert_contains "$OUT" "nothing to deliver"
}

test_missing_message_after_from_is_usage_error() {
  _mksock "/tmp/$TNAME-hub.nvim"
  run_frame deliver "$TNAME/hub" --from "$TNAME/auth"
  assert_status 2
  assert_contains "$OUT" "nothing to deliver"
}

run_tests "$0"
