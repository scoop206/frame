#!/usr/bin/env zsh
# frame req status — the sender's view of requests it sent. The outbox lives in
# THIS frame's session (FrameOutboxQuery: the stub serves a <sock>.outbox
# companion); each request's state comes from its TARGET's broker
# (FrameBrokerState: the stub serves a <sock>.state companion). Also: `frame req`
# records into the outbox and prints the check-later hint.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

in_hub() {
  export FRAME_NAME=$TNAME FRAME_TOPIC=hub
  HUB="$FRAME_RUNDIR/$TNAME-hub.nvim"
  _mksock "$HUB"
}
# target TOPIC STATE — a live target frame whose broker answers STATE
target() { _mksock "$FRAME_RUNDIR/$TNAME-$1.nvim"; print -rn -- "$2" > "$FRAME_RUNDIR/$TNAME-$1.nvim.state"; }
# row TOKEN AGE IN_INBOX LINE — one outbox row
row() { print -r -- "$1"$'\t'"$2"$'\t'"$3"$'\t'"$4" >> "$HUB.outbox"; }

test_req_prints_hint_and_records_outbox() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-alpha.nvim"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs" FAKE_BROKER_SUBMIT=r3
  run_frame req "$TNAME/alpha" $'run the tests\nand report back'
  assert_status 0
  assert_contains "$OUT" "check later: frame req status $TNAME/alpha#r3"
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameOutboxAdd('$TNAME/alpha#r3','run the tests')"
}

test_status_empty_outbox() {
  in_hub
  print -rn -- "" > "$HUB.outbox"
  run_frame req status
  assert_status 0
  assert_contains "$OUT" "nothing outstanding"
}

test_status_lists_every_state() {
  in_hub
  target q   $'queued\t2'
  target w   $'inflight\t420\tworking'
  target b   $'inflight\t30\tblocked'
  target d   $'done\tdelivered'
  target e   $'done\tempty'
  target r   'gone'
  row "$TNAME/q#r1" 5   0 "queued one"
  row "$TNAME/w#r2" 500 0 "working one"
  row "$TNAME/b#r3" 40  0 "blocked one"
  row "$TNAME/d#r4" 60  0 "delivering one"
  row "$TNAME/e#r5" 60  0 "empty one"
  row "$TNAME/r#r6" 60  0 "rebooted one"
  row "$TNAME/x#r7" 60  0 "dead one"           # no socket at all
  row "$TNAME/h#r8" 60  1 "answered one"       # reply already here
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  run_frame req status
  assert_status 0
  assert_contains "$OUT" "TOKEN"
  assert_contains "$OUT" "queued #2"
  assert_contains "$OUT" "working 7m"
  assert_contains "$OUT" "blocked one  (waiting on its human)"
  assert_contains "$OUT" "reply on its way"
  assert_contains "$OUT" "lost               empty one  (it finished without reply text)"
  assert_contains "$OUT" "($TNAME/r no longer knows it"
  assert_contains "$OUT" "dead one  ($TNAME/x is no longer running)"
  assert_contains "$OUT" "in your inbox"
  assert_contains "$OUT" "8m"      # the working one's age (500s)
  local log="$(<$FAKE_NVIM_EXPR_LOG)"
  # the target is asked about OUR request (sender address guards id reuse)
  assert_contains "$log" "FrameBrokerState('r2','$TNAME/hub')"
  # the reply already here needs no target RPC
  assert_not_contains "$log" "FrameBrokerState('r8'"
  # lost ones are reported once, then dropped; live ones stay
  assert_contains "$log" "FrameOutboxForget('$TNAME/x#r7')"
  assert_contains "$log" "FrameOutboxForget('$TNAME/e#r5')"
  assert_not_contains "$log" "FrameOutboxForget('$TNAME/w#r2')"
}

test_status_with_tokens_asks_only_those() {
  in_hub
  target w $'inflight\t10\tworking'
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  run_frame req status "$TNAME/w#r2"
  assert_status 0
  assert_contains "$OUT" "working 10s"
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameOutboxQuery('$TNAME/w#r2')"
}

test_old_target_layout_is_unknown_not_lost() {
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-old.nvim"     # no .state → RPC error
  row "$TNAME/old#r1" 5 0 "x"
  run_frame req status
  assert_status 0
  assert_contains "$OUT" "unknown"
  assert_contains "$OUT" "didn't answer, or predates req status"
}

test_status_text_to_a_frame_named_status_still_sends() {
  # Not all tokens → it's a request to the frame whose topic is `status`.
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-status.nvim"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  run_frame req status "run the tests"
  assert_status 0
  assert_contains "$OUT" "sent to $TNAME/status"
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameBrokerSubmit('run the tests'"
}

test_status_refuses_outside_a_frame() {
  run_frame req status
  assert_status 1
  assert_contains "$OUT" "must be run from inside a frame"
}

test_swarm_recipe_captures_just_the_token() {
  # The level-2 ask recipe stores `frame req`'s output in $t and hands it to
  # `inbox --wait --for`. frame req prints several lines, so the recipe must
  # extract only the token. Run the recipe's own line, as the agent would.
  in_hub
  _mksock "$FRAME_RUNDIR/$TNAME-alpha.nvim"
  export FAKE_BROKER_SUBMIT=r5
  "$FRAME_BIN" swarm 2 >/dev/null
  local line
  line=$("$FRAME_BIN" swarm --context | grep -m1 '^ *t=\$(frame req')
  assert_contains "$line" "frame req NAME/TOPIC"
  line=${line/NAME\/TOPIC/$TNAME/alpha}
  local t
  export PATH="$FRAME_CHECKOUT/bin:$PATH"   # the recipe calls `frame` by name
  eval "$line"
  assert_eq "$t" "$TNAME/alpha#r5"
  assert_contains "$("$FRAME_BIN" swarm --context)" "Exit 5 means no reply is coming"
}

test_old_layout_hint_names_the_right_boot_command() {
  # A shell frame reboots with `frame shell TOPIC`, a worktree frame with
  # `frame wt TOPIC`; the "layout may predate" hint must say which.
  export FRAME_NAME=shell FRAME_TOPIC=$TNAME
  _mksock "$FRAME_RUNDIR/shell-$TNAME.nvim"; touch "$FRAME_RUNDIR/shell-$TNAME.nvim.nooutbox"
  run_frame req status
  assert_status 1
  assert_contains "$OUT" "(:FrameQuit, then frame shell $TNAME)"
  export FRAME_NAME=$TNAME FRAME_TOPIC=hub
  _mksock "$FRAME_RUNDIR/$TNAME-hub.nvim"; touch "$FRAME_RUNDIR/$TNAME-hub.nvim.nooutbox"
  run_frame req status
  assert_status 1
  assert_contains "$OUT" "(:FrameQuit, then frame wt hub)"
}

run_tests "$0"
