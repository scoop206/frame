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

# A live FrameInfo session: socket + <sock>.info companion the nvim stub serves,
# so frame_live_frames (the bare-topic fallback) sees it as a real frame.
plant_live() {  # plant_live SOCK NAME TOPIC PORT STATUS
  _mksock "$1"
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" > "$1.info"
}

# Stand in for "running inside the hub frame" — identity from the session env.
in_hub() { export FRAME_NAME=$TNAME FRAME_TOPIC=hub; }

test_name_topic_target_submits_and_names_return_address() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-alpha.nvim"
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
  _mksock "$FRAME_RUNDIR/$TNAME-alpha.nvim"
  run_frame req alpha "run the tests again"
  assert_status 0
  assert_contains "$OUT" "sent to $TNAME/alpha"
}

test_emits_correlation_token_from_the_returned_id() {
  # The broker returns 'r7'; req composes <target-addr>#<id> so a fan-out caller
  # can `frame inbox --wait --for` exactly this reply.
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-alpha.nvim"
  export FAKE_BROKER_SUBMIT=r7
  run_frame req "$TNAME/alpha" "question"
  assert_status 0
  assert_contains "$OUT" "token: $TNAME/alpha#r7"
}

test_refuses_when_not_in_a_frame() {
  # No FRAME_NAME and a non-git sandbox cwd → no return address → refuse.
  _mksock "$FRAME_RUNDIR/$TNAME-alpha.nvim"
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
  _mksock "$FRAME_RUNDIR/$TNAME-alpha.nvim"
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
  _mksock "$FRAME_RUNDIR/$TNAME-alpha.nvim"
  export FAKE_BROKER_SUBMIT=no-claude-buffer
  run_frame req "$TNAME/alpha" "nowhere to type"
  assert_status 1
  assert_contains "$OUT" "no 'claude' buffer"
}

test_full_queue_is_retryable() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-alpha.nvim"
  export FAKE_BROKER_SUBMIT=queue-full
  run_frame req "$TNAME/alpha" "one more"
  assert_status 4
  assert_contains "$OUT" "queue is full"
}

# ── bare-topic fallback across projects ───────────────────────────────────────

test_bare_topic_falls_back_to_a_unique_live_frame() {
  # A `shell` head frame (no shell/<topic> sibling) reaching a frame in another
  # project by bare topic — resolves to the sole live match. Topic == $TNAME so
  # the planted socket gets swept.
  export FRAME_NAME=shell FRAME_TOPIC=headv2
  plant_live "$FRAME_RUNDIR/webproj-$TNAME.nvim" webproj "$TNAME" '' waiting
  run_frame req "$TNAME" "ping"
  assert_status 0
  assert_contains "$OUT" "sent to webproj/$TNAME"
}

test_same_project_sibling_wins_over_the_search() {
  # Our own NAME/topic is preferred even when another project shares the topic.
  export FRAME_NAME=shell FRAME_TOPIC=headv2
  _mksock "$FRAME_RUNDIR/shell-$TNAME.nvim"                       # our sibling
  plant_live "$FRAME_RUNDIR/webproj-$TNAME.nvim" webproj "$TNAME" '' waiting
  run_frame req "$TNAME" "ping"
  assert_status 0
  assert_contains "$OUT" "sent to shell/$TNAME"
}

test_bare_topic_ambiguous_refuses() {
  export FRAME_NAME=shell FRAME_TOPIC=headv2
  plant_live "$FRAME_RUNDIR/aa-$TNAME.nvim" aa "$TNAME" '' waiting
  plant_live "$FRAME_RUNDIR/bb-$TNAME.nvim" bb "$TNAME" '' waiting
  run_frame req "$TNAME" "which one?"
  assert_status 1
  assert_contains "$OUT" "ambiguous topic '$TNAME'"
}

test_bare_topic_no_match_asks_for_name_topic() {
  export FRAME_NAME=shell FRAME_TOPIC=headv2
  run_frame req "$TNAME" "anyone?"
  assert_status 1
  assert_contains "$OUT" "no live frame with topic '$TNAME'"
}

run_tests "$0"
