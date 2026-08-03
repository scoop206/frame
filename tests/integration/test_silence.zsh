#!/usr/bin/env zsh
# frame silence [--off] — the CLI twin of :FrameSilence: flips
# g:frame_notify_muted in the TARGET frame's session over its socket, the
# same flag notify.sh reads before popping a banner. A real unix socket plus
# the nvim stub stand in for the session: FAKE_NVIM_EXPR_RESULT (set-but-empty
# = the RPC succeeds) and FAKE_NVIM_EXPR_LOG (asserts the expr actually sent).
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

# A live target session: socket at $FRAME_RUNDIR/<name>-<topic>.nvim, answered
# by the stub. The <sock>.info companion (FrameInfo) is only needed by the
# bare-topic test — explicit NAME/TOPIC hits the socket directly.
plant_target() {  # plant_target NAME TOPIC
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
    "$FRAME_RUNDIR/$1-$2.nvim"
  export FAKE_NVIM_EXPR_RESULT=""
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs.log"
}

test_explicit_target_silences() {
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  plant_target proj "$TNAME"
  run_frame silence proj/$TNAME
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "let g:frame_notify_muted = 1"
  assert_contains "$OUT" "banners silenced for proj/$TNAME"
}

test_off_restores_banners() {
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  plant_target proj "$TNAME"
  run_frame silence --off proj/$TNAME
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "let g:frame_notify_muted = 0"
  assert_contains "$OUT" "banners on for proj/$TNAME"
}

test_bare_topic_resolves_unique_live_frame() {
  # Outside any frame, a bare TOPIC resolves through frame_live_frames —
  # the stub answers FrameInfo from the planted .info companion.
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  plant_target proj "$TNAME"
  printf '%s\t%s\t%s\t%s\n' proj "$TNAME" '' working \
    > "$FRAME_RUNDIR/proj-$TNAME.nvim.info"
  run_frame silence "$TNAME"
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "let g:frame_notify_muted = 1"
  assert_contains "$OUT" "banners silenced for proj/$TNAME"
}

test_no_arg_inside_frame_silences_self() {
  # Shell-frame identity carried in the session env, like notify.sh's tests.
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  plant_target shell "$TNAME"
  export FRAME_NAME=shell FRAME_TOPIC=$TNAME
  run_frame silence
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "let g:frame_notify_muted = 1"
  assert_contains "$OUT" "banners silenced for shell/$TNAME"
}

test_no_arg_outside_frame_errors() {
  cd "$SANDBOX"
  run_frame silence
  assert_status 1
  assert_contains "$OUT" "not inside a frame"
}

test_dead_target_errors() {
  # No socket at all → resolve fails before any RPC.
  run_frame silence proj/$TNAME
  assert_status 1
  assert_contains "$OUT" "no frame session for proj/$TNAME"
}

test_unanswerable_session_errors() {
  # Socket exists but the session never answers (no FAKE_NVIM_EXPR_RESULT →
  # the stub tripwires, as a wedged nvim would time out) — unlike notify's
  # err-toward-firing default, an explicit silence must report the failure.
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
    "$FRAME_RUNDIR/proj-$TNAME.nvim"
  run_frame silence proj/$TNAME
  assert_status 1
  assert_contains "$OUT" "didn't answer"
}

test_bad_flag_shows_usage() {
  run_frame silence --nope proj/x
  assert_status 2
  assert_contains "$OUT" "usage: frame silence"
}

test_extra_args_show_usage() {
  run_frame silence proj/x stray
  assert_status 2
  assert_contains "$OUT" "usage: frame silence"
}

run_tests "$0"
