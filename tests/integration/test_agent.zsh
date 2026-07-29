#!/usr/bin/env zsh
# frame agent — type a message into another frame's `claude` buffer over its
# nvim socket. The nvim stub stands in for the live session: a planted AF_UNIX
# socket satisfies agent.sh's `-S` check, and FAKE_NVIM_EXPR_RESULT is what
# FrameAgentSend "returns" over --remote-expr ('ok' | 'no-claude-buffer').
# Socket names carry $TNAME so sandbox_down sweeps them.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

# A real AF_UNIX socket file, so agent.sh's `-S "$SOCKET"` sees a live socket.
_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

test_name_topic_target_sends() {
  _mksock "/tmp/$TNAME-alpha.nvim"
  export FAKE_NVIM_EXPR_RESULT=ok
  run_frame agent "$TNAME/alpha" "what is blocking the migration?"
  assert_status 0
  assert_contains "$OUT" "sent to $TNAME/alpha"
}

test_bare_topic_derives_name_from_env() {
  # No git repo under the sandbox cwd → NAME comes from the session env, same as
  # a shell-frame buffer. Bare topic pairs with it.
  _mksock "/tmp/$TNAME-alpha.nvim"
  export FRAME_NAME=$TNAME
  export FAKE_NVIM_EXPR_RESULT=ok
  run_frame agent alpha "run the tests again"
  assert_status 0
  assert_contains "$OUT" "sent to $TNAME/alpha"
}

test_dead_target_no_socket_fails() {
  # Nothing planted → no socket → refused before any RPC.
  run_frame agent "$TNAME/ghost" "anyone home?"
  assert_status 1
  assert_contains "$OUT" "no frame session for $TNAME/ghost"
}

test_missing_text_is_usage_error() {
  _mksock "/tmp/$TNAME-alpha.nvim"
  run_frame agent "$TNAME/alpha"
  assert_status 2
  assert_contains "$OUT" "nothing to send"
}

test_no_args_is_usage_error() {
  run_frame agent
  assert_status 2
  assert_contains "$OUT" "usage: frame agent"
}

test_frame_without_claude_buffer_reports_it() {
  # The session answers, but has no claude buffer: FrameAgentSend returns the
  # 'no-claude-buffer' sentinel, which the command surfaces as an error.
  _mksock "/tmp/$TNAME-alpha.nvim"
  export FAKE_NVIM_EXPR_RESULT=no-claude-buffer
  run_frame agent "$TNAME/alpha" "you have no inbox to type into"
  assert_status 1
  assert_contains "$OUT" "no 'claude' buffer"
}

run_tests "$0"
