#!/usr/bin/env zsh
# frame claude — synchronous round-trip to THIS frame's own claude: gate + send
# (FrameClaudeSend), then poll the self-addressed inbox (FrameInboxDrainSelf).
# Identity comes from a shell-frame env; a planted AF_UNIX socket satisfies the
# `-S` check. FAKE_CLAUDE_SEND is the send verdict (default 'ok'; 'FAIL' → the
# RPC errors, as an old layout would); FAKE_NVIM_EXPR_RESULT stands in for the
# reply the poll drains ('' → nothing yet).
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

in_hub() { export FRAME_NAME=$TNAME FRAME_TOPIC=hub; }

# ── happy path ────────────────────────────────────────────────────────────────

test_sends_and_prints_the_reply() {
  in_hub
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT="42, and the tests are green"
  run_frame claude "how many left?"
  assert_status 0
  assert_contains "$OUT" "sent — waiting for claude"
  assert_contains "$OUT" "42, and the tests are green"
}

test_text_reaches_the_session() {
  in_hub
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  export FAKE_NVIM_EXPR_RESULT="done"
  run_frame claude "run the migration"
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameClaudeSend("
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "run the migration"
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameInboxDrainSelf()"
}

test_polls_until_the_reply_arrives() {
  # Empty for the first 2 drains, then the reply — proves it genuinely polls.
  in_hub
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT="here is the summary"
  export FAKE_NVIM_EXPR_EMPTY_POLLS=2
  export FAKE_NVIM_POLL_COUNT_FILE="$SANDBOX/polls"
  run_frame claude --timeout 10 "summarize the diff"
  assert_status 0
  assert_contains "$OUT" "here is the summary"
  assert_eq "$(<$FAKE_NVIM_POLL_COUNT_FILE)" "3"   # 2 empty + the hit
}

# ── the idle-gate ─────────────────────────────────────────────────────────────

test_refuses_when_claude_is_busy() {
  in_hub
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_CLAUDE_SEND=busy
  run_frame claude "quick question"
  assert_status 4
  assert_contains "$OUT" "mid-turn"
  assert_contains "$OUT" "frame req hub"
}

test_refuses_when_claude_not_ready() {
  in_hub
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_CLAUDE_SEND=not-ready
  run_frame claude "you up?"
  assert_status 4
  assert_contains "$OUT" "isn't ready yet"
}

test_reports_missing_claude_buffer() {
  in_hub
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_CLAUDE_SEND=no-claude-buffer
  run_frame claude "anyone?"
  assert_status 1
  assert_contains "$OUT" "no 'claude' buffer"
}

test_old_layout_points_at_reboot() {
  in_hub
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_CLAUDE_SEND=FAIL
  run_frame claude "hello?"
  assert_status 1
  assert_contains "$OUT" "reboot the frame"
}

# ── waiting ───────────────────────────────────────────────────────────────────

test_times_out_when_no_reply() {
  in_hub
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_CLAUDE_SEND=ok
  export FAKE_NVIM_EXPR_RESULT=""     # set-but-empty → poll always drains nothing
  run_frame claude --timeout 1 "will you answer?"
  assert_status 3
  assert_contains "$OUT" "no reply after 1s"
  assert_contains "$OUT" "permission prompt"
}

# ── guards ────────────────────────────────────────────────────────────────────

test_refuses_when_not_in_a_frame() {
  # No FRAME_NAME and a non-git sandbox cwd → no identity → refuse.
  _mksock "/tmp/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT=hi
  run_frame claude "hello?"
  assert_status 1
  assert_contains "$OUT" "must be run from inside a frame"
}

test_no_session_fails() {
  in_hub   # identity resolves, but no socket planted
  run_frame claude "hello?"
  assert_status 1
  assert_contains "$OUT" "no frame session for $TNAME/hub"
}

test_missing_text_is_usage_error() {
  in_hub
  _mksock "/tmp/$TNAME-hub.nvim"
  run_frame claude
  assert_status 2
  assert_contains "$OUT" "nothing to send"
}

test_timeout_needs_a_number() {
  in_hub
  _mksock "/tmp/$TNAME-hub.nvim"
  run_frame claude --timeout soon "hello?"
  assert_status 2
  assert_contains "$OUT" "--timeout needs a positive integer"
}

test_bare_timeout_without_text_is_usage_error() {
  in_hub
  _mksock "/tmp/$TNAME-hub.nvim"
  run_frame claude --timeout 30
  assert_status 2
  assert_contains "$OUT" "nothing to send"
}

run_tests "$0"
