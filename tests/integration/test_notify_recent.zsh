#!/usr/bin/env zsh
# frame notify's quick-turn gate: sending a prompt stamps
# /tmp/<name>-<topic>.prompt (UserPromptSubmit hook → bare `frame status`),
# and notify skips the banner when the stamp is 10 seconds old or less — the
# human just prompted, they're still looking at the frame.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

# Shell frame for identity (env-carried, no repo fixture needed); the gate is
# frame-kind-agnostic. The notify tests run with no session socket at all —
# the gate is a pure file check, and socketless is the err-toward-firing
# baseline the stale test relies on.
setup_frame_env() {
  mkdir -p "$SANDBOX/frames/$TNAME"
  cd "$SANDBOX/frames/$TNAME"
  export FRAME_NAME=shell FRAME_TOPIC=$TNAME
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
}

# The status tests need the RPC to land, so add a live socket (as in
# test_notify_mute.zsh) and let the nvim stub answer FrameSetStatus.
setup_live_session() {
  setup_frame_env
  export FAKE_NVIM_EXPR_RESULT="shell/$TNAME"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
    "/tmp/shell-$TNAME.nvim"
}

test_bare_status_writes_prompt_stamp() {
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_live_session
  run_frame status
  assert_status 0
  assert_file_exists "/tmp/shell-$TNAME.prompt"
}

test_status_with_text_does_not_stamp() {
  # Claude marking a milestone (`frame status DEPLOYED…`) is not the human
  # prompting — only the bare clear form stamps.
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_live_session
  run_frame status milestone
  assert_status 0
  assert_file_absent "/tmp/shell-$TNAME.prompt"
}

test_fresh_prompt_suppresses_banner() {
  setup_frame_env
  touch "/tmp/shell-$TNAME.prompt"
  run_frame notify
  assert_status 0
  assert_file_absent "$FAKE_OSASCRIPT_LOG"
}

test_stale_prompt_still_banners() {
  setup_frame_env
  touch -t 202601010000 "/tmp/shell-$TNAME.prompt"
  run_frame notify
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - waiting shell [ $TNAME ]"
}

test_no_stamp_still_banners() {
  setup_frame_env
  run_frame notify
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - waiting shell [ $TNAME ]"
}

run_tests "$0"
