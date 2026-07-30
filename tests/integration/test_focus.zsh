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
  # name and topic reach the matcher as separate args (it builds the brackets).
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - flipnem schema"
  assert_contains "$OUT" "focused flipnem/schema"
}

test_topic_only_target_matches_any_name() {
  setup_frame_env
  run_frame focus schema
  assert_status 0
  # Empty name → the matcher wildcards the owner (leading empty arg).
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: -  schema"
  assert_contains "$OUT" "focused schema"
}

test_bare_focus_derives_identity_from_env() {
  setup_frame_env
  run_frame focus
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - shell $TNAME"
}

test_no_matching_window_fails() {
  setup_frame_env
  export FAKE_OSASCRIPT_RESULT=nomatch
  run_frame focus gone/frame
  assert_status 1
  assert_contains "$OUT" "no frame matching gone/frame"
}

test_activate_fallback_reports_accessibility() {
  setup_frame_env
  export FAKE_OSASCRIPT_RESULT=activated
  run_frame focus flipnem/schema
  assert_status 1
  assert_contains "$OUT" "Accessibility"
}

test_recorded_ids_take_the_fast_path() {
  # A spawned frame's .gtab recording → select the exact tab by id; the title
  # matcher (and its System Events/Accessibility dependency) never runs.
  setup_frame_env
  print -r -- "w-9 t-9" > "/tmp/shell-$TNAME.nvim.gtab"
  export FAKE_OSASCRIPT_RESULT=selected
  run_frame focus $TNAME
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - w-9 t-9"
  assert_contains "$OUT" "focused $TNAME"
}

test_stale_recording_is_deleted_and_falls_back() {
  # Recording points at a dead tab (script answers something ≠ "selected") →
  # delete it so it can't misdirect again, fall through to the title matcher.
  setup_frame_env
  print -r -- "w-9 t-9" > "/tmp/shell-$TNAME.nvim.gtab"
  export FAKE_OSASCRIPT_RESULT=raised
  run_frame focus $TNAME
  assert_status 0
  assert_contains "$OUT" "focused $TNAME"
  assert_file_absent "/tmp/shell-$TNAME.nvim.gtab"
}

run_tests "$0"
