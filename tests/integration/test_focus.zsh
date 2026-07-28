#!/usr/bin/env zsh
# frame focus — raise a frame's ghostty window. The osascript stub swallows
# the AppleScript; FAKE_OSASCRIPT_RESULT stands in for its return value
# ("raised" when AXRaise matched a window, "activated" when it didn't).
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

setup_frame_env() {
  mkdir -p "$SANDBOX/frames/$TNAME"
  cd "$SANDBOX/frames/$TNAME"
  export FRAME_NAME=shell FRAME_TOPIC=$TNAME
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
  export FAKE_OSASCRIPT_RESULT=raised
}

test_explicit_target_passed_to_applescript() {
  setup_frame_env
  run_frame focus flipnem/schema
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - flipnem/schema"
  assert_contains "$OUT" "focused flipnem/schema"
}

test_bare_focus_derives_identity_from_env() {
  setup_frame_env
  run_frame focus
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - shell/$TNAME"
}

test_no_matching_window_fails() {
  setup_frame_env
  export FAKE_OSASCRIPT_RESULT=activated
  run_frame focus gone/frame
  assert_status 1
  assert_contains "$OUT" "no window titled gone/frame"
}

run_tests "$0"
