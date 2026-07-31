#!/usr/bin/env zsh
# frame claude — client of this frame's claude broker: submit(local) → id, poll
# await(id), print the answer. Identity comes from a shell-frame env; a planted
# AF_UNIX socket satisfies the `-S` check. FAKE_BROKER_SUBMIT is the submit
# result (default 'r1'; 'FAIL' → old layout; or a verdict); FAKE_BROKER_AWAIT is
# the poll result ('done' = empty answer; $'done\n<text>' for a real one; 'gone').
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

in_hub() { export FRAME_NAME=$TNAME FRAME_TOPIC=hub; }

# ── happy path ────────────────────────────────────────────────────────────────

test_submits_and_prints_the_answer() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_BROKER_AWAIT=$'done\n42, and the tests are green'
  run_frame claude "how many left?"
  assert_status 0
  assert_contains "$OUT" "queued (r1)"
  assert_contains "$OUT" "42, and the tests are green"
}

test_submit_carries_text_and_local_return() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  export FAKE_BROKER_AWAIT=$'done\nok'
  run_frame claude "run the migration"
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameBrokerSubmit("
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "run the migration"
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "'local'"
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameBrokerAwait('r1')"
}

test_polls_until_the_answer_is_ready() {
  # 'pending' for the first 2 polls, then the answer — proves it genuinely polls.
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_BROKER_AWAIT=$'done\nhere is the summary'
  export FAKE_NVIM_EXPR_EMPTY_POLLS=2
  export FAKE_NVIM_POLL_COUNT_FILE="$SANDBOX/polls"
  run_frame claude --timeout 10 "summarize the diff"
  assert_status 0
  assert_contains "$OUT" "here is the summary"
  assert_eq "$(<$FAKE_NVIM_POLL_COUNT_FILE)" "3"   # 2 pending + the hit
}

test_empty_answer_is_labelled() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_BROKER_AWAIT="done"     # 'done' with no text → empty answer
  run_frame claude "just run it, no need to explain"
  assert_status 0
  assert_contains "$OUT" "(no textual answer)"
}

# ── submit-side outcomes ──────────────────────────────────────────────────────

test_reports_missing_claude_buffer() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_BROKER_SUBMIT=no-claude-buffer
  run_frame claude "anyone?"
  assert_status 1
  assert_contains "$OUT" "no 'claude' buffer"
}

test_queue_full_is_retryable() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_BROKER_SUBMIT=queue-full
  run_frame claude "one more"
  assert_status 4
  assert_contains "$OUT" "queue is full"
}

test_old_layout_points_at_reboot() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_BROKER_SUBMIT=FAIL
  run_frame claude "hello?"
  assert_status 1
  assert_contains "$OUT" "reboot the frame"
}

# ── waiting: timeout + detach ─────────────────────────────────────────────────

test_timeout_detaches_to_inbox() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  export FAKE_NVIM_EXPR_EMPTY_POLLS=999      # never resolves
  export FAKE_NVIM_POLL_COUNT_FILE="$SANDBOX/polls"
  run_frame claude --timeout 1 "will you answer?"
  assert_status 3
  assert_contains "$OUT" "detached"
  assert_contains "$OUT" "frame inbox"
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameBrokerCancel('r1', 'inbox')"
}

test_gone_id_errors() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_BROKER_AWAIT=gone
  run_frame claude "where did it go?"
  assert_status 1
  assert_contains "$OUT" "lost track of r1"
}

# ── status ────────────────────────────────────────────────────────────────────

test_status_shows_the_queue() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_BROKER_STATUS=$'r4\tinflight\nr5\tqueued#1'
  run_frame claude status
  assert_status 0
  assert_contains "$OUT" "inflight"
  assert_contains "$OUT" "queued#1"
}

test_status_idle_says_so() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_BROKER_STATUS=""
  run_frame claude status
  assert_status 0
  assert_contains "$OUT" "broker idle"
}

test_status_takes_no_args() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  run_frame claude status extra
  assert_status 2
  assert_contains "$OUT" "takes no arguments"
}

# ── guards ────────────────────────────────────────────────────────────────────

test_refuses_when_not_in_a_frame() {
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_BROKER_AWAIT=$'done\nhi'
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
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  run_frame claude
  assert_status 2
  assert_contains "$OUT" "nothing to send"
}

test_timeout_needs_a_number() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  run_frame claude --timeout soon "hello?"
  assert_status 2
  assert_contains "$OUT" "--timeout needs a positive integer"
}

run_tests "$0"
