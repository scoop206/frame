#!/usr/bin/env zsh
# frame spawn — boot a worker frame in a NEW ghostty window. The window launch
# is the `open` stub (FAKE_OPEN_LOG records it); readiness is the socket plus
# FrameReady() over RPC, where a planted AF_UNIX socket with a `.ready`
# companion stands in for a fully-booted session (without one the nvim stub
# answers 0 — still booting). Worker topics are $TNAME so sandbox_down's
# /tmp/*-$TNAME.nvim* patterns reap the plants.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

in_head() { export FRAME_NAME=$TNAME FRAME_TOPIC=head; }

_plant_booted_worker() {
  _mksock "/tmp/shell-$TNAME.nvim"
  touch "/tmp/shell-$TNAME.nvim.ready"
}

test_no_args_shows_usage() {
  run_frame spawn
  assert_status 2
  assert_contains "$OUT" "usage: frame spawn shell TOPIC"
}

test_unknown_kind_shows_usage() {
  run_frame spawn banana calc
  assert_status 2
  assert_contains "$OUT" "usage: frame spawn shell TOPIC"
}

test_spawn_wt_not_built_yet() {
  run_frame spawn wt calc
  assert_status 2
  assert_contains "$OUT" "not built yet"
}

test_missing_topic_shows_usage() {
  run_frame spawn shell
  assert_status 2
  assert_contains "$OUT" "usage: frame spawn shell TOPIC"
}

test_rejects_slash_in_topic() {
  run_frame spawn shell a/b
  assert_status 2
  assert_contains "$OUT" "no slashes"
}

test_rejects_unknown_argument() {
  run_frame spawn shell $TNAME --bogus
  assert_status 2
  assert_contains "$OUT" "unknown argument '--bogus'"
}

test_rejects_non_numeric_timeout() {
  run_frame spawn shell $TNAME --timeout soon
  assert_status 2
  assert_contains "$OUT" "--timeout needs a positive integer"
}

test_refuses_live_topic_before_opening_a_window() {
  # A live frame (socket answering FrameInfo via its .info companion) already
  # owns the topic → refused, and `open` must never have fired.
  export FAKE_OPEN_LOG="$SANDBOX/open.log"
  _mksock "/tmp/other-$TNAME.nvim"
  print -r -- "other	$TNAME		" > "/tmp/other-$TNAME.nvim.info"
  run_frame spawn shell $TNAME
  assert_status 1
  assert_contains "$OUT" "already live"
  assert_file_absent "$FAKE_OPEN_LOG"
}

test_happy_path_opens_window_and_reports_up() {
  export FAKE_OPEN_LOG="$SANDBOX/open.log"
  _plant_booted_worker
  run_frame spawn shell $TNAME
  assert_status 0
  assert_contains "$OUT" "shell/$TNAME is up"
  local log="$(<$FAKE_OPEN_LOG)"
  assert_contains "$log" "-na Ghostty.app --args --quit-after-last-window-closed=true -e zsh -ic"
  assert_contains "$log" "frame shell $TNAME"
}

test_boot_timeout_exits_3() {
  export FAKE_OPEN_LOG="$SANDBOX/open.log"
  # no socket ever appears → the poll runs out
  run_frame spawn shell $TNAME --timeout 1
  assert_status 3
  assert_contains "$OUT" "didn't come up within 1s"
}

test_not_ready_session_times_out() {
  export FAKE_OPEN_LOG="$SANDBOX/open.log"
  _mksock "/tmp/shell-$TNAME.nvim"   # socket up, but no .ready — mid-boot
  run_frame spawn shell $TNAME --timeout 1
  assert_status 3
  assert_contains "$OUT" "didn't come up within 1s"
}

test_req_outside_a_frame_is_refused() {
  run_frame spawn shell $TNAME --req "compute 2+2"
  assert_status 1
  assert_contains "$OUT" "must be run from inside a frame"
}

test_req_is_sent_once_ready() {
  in_head
  export FAKE_OPEN_LOG="$SANDBOX/open.log"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  export FAKE_NVIM_EXPR_RESULT="ok"   # answers FrameRequest (FrameReady is case-matched first)
  _plant_booted_worker
  run_frame spawn shell $TNAME --req "compute 2+2"
  assert_status 0
  assert_contains "$OUT" "shell/$TNAME is up"
  assert_contains "$OUT" "sent to shell/$TNAME"
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameRequest('$TNAME/head', 'compute 2+2')"
}

run_tests "$0"
