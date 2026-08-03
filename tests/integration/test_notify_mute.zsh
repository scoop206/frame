#!/usr/bin/env zsh
# frame notify's session silence switch (:FrameSilence on): the CLI asks the
# live session over its socket before popping a banner. A real unix socket
# at the session path plus FAKE_NVIM_EXPR_RESULT (the stub's answer to the
# remote-expr query) stand in for the nvim side.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

# Uses a shell frame for identity (env-carried, no repo fixture needed);
# the mute logic itself is frame-kind-agnostic. $TNAME keeps the hardcoded
# $FRAME_RUNDIR/<name>-<topic>.nvim path unique per test (sandbox_down sweeps it).
setup_shell_frame() {
  mkdir -p "$SANDBOX/frames/$TNAME"
  cd "$SANDBOX/frames/$TNAME"
  export FRAME_NAME=shell FRAME_TOPIC=$TNAME
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
    "$FRAME_RUNDIR/shell-$TNAME.nvim"
}

test_muted_session_suppresses_banner() {
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_shell_frame
  export FAKE_NVIM_EXPR_RESULT=1
  run_frame notify
  assert_status 0
  assert_file_absent "$FAKE_OSASCRIPT_LOG"
}

test_unmuted_session_still_banners() {
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_shell_frame
  export FAKE_NVIM_EXPR_RESULT=0
  run_frame notify
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - task complete shell [ $TNAME ]"
}

test_brokered_turn_suppresses_banner() {
  # The broker answered a client directly (FrameTakeBrokeredFlag → 1), so no
  # banner even though the session is unmuted and it's not a quick turn.
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_shell_frame
  export FAKE_BROKERED=1
  export FAKE_NVIM_EXPR_RESULT=0   # not muted — suppression is the brokered flag
  run_frame notify
  assert_status 0
  assert_file_absent "$FAKE_OSASCRIPT_LOG"
}

test_non_brokered_turn_still_banners() {
  # A human-typed turn (flag 0) banners as before.
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_shell_frame
  export FAKE_BROKERED=0
  export FAKE_NVIM_EXPR_RESULT=0
  run_frame notify
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - task complete shell [ $TNAME ]"
}

test_unanswerable_session_defaults_to_banner() {
  # Socket exists but the query fails (session predates the switch, or nvim
  # is wedged) — the banner must err toward firing. Without
  # FAKE_NVIM_EXPR_RESULT the stub treats the RPC as a tripwire (exit 97).
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_shell_frame
  run_frame notify
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - task complete shell [ $TNAME ]"
}

run_tests "$0"
