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
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT="from $TNAME/work:
widget built, tests green"
  run_frame inbox
  assert_status 0
  assert_contains "$OUT" "from $TNAME/work:"
  assert_contains "$OUT" "widget built, tests green"
}

test_empty_inbox_says_so() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
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

test_rejects_unknown_argument() {
  in_hub
  run_frame inbox extra args
  assert_status 2
  assert_contains "$OUT" "unknown argument 'extra'"
}

# ── --wait ────────────────────────────────────────────────────────────────────

test_wait_returns_immediately_when_mail_present() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT="from $TNAME/calc:
4"
  run_frame inbox --wait --timeout 5
  assert_status 0
  assert_contains "$OUT" "from $TNAME/calc:"
}

test_wait_polls_until_mail_arrives() {
  # Stub answers '' for the first 2 drains, then serves the mail — proves the
  # loop genuinely polls rather than only checking once.
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT="from $TNAME/calc:
tests green"
  export FAKE_NVIM_EXPR_EMPTY_POLLS=2
  export FAKE_NVIM_POLL_COUNT_FILE="$SANDBOX/polls"
  run_frame inbox --wait --timeout 10
  assert_status 0
  assert_contains "$OUT" "tests green"
  assert_eq "$(<$FAKE_NVIM_POLL_COUNT_FILE)" "3"   # 2 empty + the hit
}

test_wait_times_out_empty() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT=""
  run_frame inbox --wait --timeout 1
  assert_status 3
  assert_contains "$OUT" "no mail after 1s"
}

test_wait_count_reaches_the_session() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  export FAKE_NVIM_EXPR_RESULT="from $TNAME/a: x"
  run_frame inbox --wait --count 3
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameInboxDrainAtLeast(3)"
}

test_wait_rejects_non_numeric_timeout() {
  in_hub
  run_frame inbox --wait --timeout soon
  assert_status 2
  assert_contains "$OUT" "--timeout needs a positive integer"
}

test_modifiers_require_wait() {
  in_hub
  run_frame inbox --timeout 5
  assert_status 2
  assert_contains "$OUT" "--timeout only makes sense with --wait"
}

test_wait_refuses_when_not_in_a_frame() {
  run_frame inbox --wait
  assert_status 1
  assert_contains "$OUT" "must be run from inside a frame"
}

# ── --for (correlated fan-in) ─────────────────────────────────────────────────

test_for_barrier_reaches_session_by_token() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  export FAKE_NVIM_EXPR_RESULT="from $TNAME/calc:
4"
  run_frame inbox --wait --for "$TNAME/calc#r7"
  assert_status 0
  assert_contains "$OUT" "from $TNAME/calc:"
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameInboxDrainFor('$TNAME/calc#r7')"
}

test_for_joins_tokens_with_tab() {
  # Two --for → an exact both-present barrier; tokens ride tab-joined in one call.
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  export FAKE_NVIM_EXPR_RESULT="two replies"
  run_frame inbox --wait --for "$TNAME/a#r1" --for "$TNAME/b#r2"
  assert_status 0
  _log="$(<$FAKE_NVIM_EXPR_LOG)"
  assert_contains "$_log" "FrameInboxDrainFor("
  assert_contains "$_log" "$TNAME/a#r1"
  assert_contains "$_log" "$TNAME/b#r2"
}

test_for_without_wait_drains_when_all_present() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  export FAKE_NVIM_EXPR_RESULT="from $TNAME/calc:
4"
  run_frame inbox --for "$TNAME/calc#r7"
  assert_status 0
  assert_contains "$OUT" "from $TNAME/calc:"
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameInboxDrainFor('$TNAME/calc#r7')"
}

test_for_without_wait_none_present_says_so() {
  # The barrier is unmet (stub returns '') and we're not waiting → a clear message
  # distinct from "inbox empty" (other mail may well be sitting there).
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT=""
  run_frame inbox --for "$TNAME/calc#r7"
  assert_status 0
  assert_contains "$OUT" "none of the requested replies have arrived yet"
}

test_for_polls_until_reply_arrives() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"
  export FAKE_NVIM_EXPR_RESULT="from $TNAME/calc:
done"
  export FAKE_NVIM_EXPR_EMPTY_POLLS=2
  export FAKE_NVIM_POLL_COUNT_FILE="$SANDBOX/polls"
  run_frame inbox --wait --for "$TNAME/calc#r7" --timeout 10
  assert_status 0
  assert_contains "$OUT" "done"
  assert_eq "$(<$FAKE_NVIM_POLL_COUNT_FILE)" "3"
}

test_for_and_count_are_mutually_exclusive() {
  in_hub
  run_frame inbox --wait --for "$TNAME/a#r1" --count 2
  assert_status 2
  assert_contains "$OUT" "--for and --count can't be combined"
}

test_for_needs_a_token() {
  in_hub
  run_frame inbox --wait --for
  assert_status 2
  assert_contains "$OUT" "--for needs a TOKEN"
}

run_tests "$0"
