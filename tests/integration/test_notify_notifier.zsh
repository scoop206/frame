#!/usr/bin/env zsh
# frame notify's banner channel selection: with the Frame notifier app built
# (~/.local/share/frame/Frame.app — HOME is sandboxed, so planting a fake
# binary at that path flips the branch) the banner goes through it, carrying
# the click-to-focus command; without it, the osascript fallback fires (that
# path is covered by test_notify_recent.zsh).
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

setup_frame_env() {
  mkdir -p "$SANDBOX/frames/$TNAME"
  cd "$SANDBOX/frames/$TNAME"
  export FRAME_NAME=shell FRAME_TOPIC=$TNAME
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
}

plant_notifier() {
  local _bin="$HOME/.local/share/frame/Frame.app/Contents/MacOS"
  mkdir -p "$_bin"
  cat > "$_bin/terminal-notifier" <<EOF
#!/usr/bin/env zsh
print -r -- "argv: \$*" >> "$SANDBOX/notifier.log"
EOF
  chmod +x "$_bin/terminal-notifier"
}

test_notifier_app_preferred_over_osascript() {
  setup_frame_env
  plant_notifier
  run_frame notify
  assert_status 0
  assert_contains "$(<$SANDBOX/notifier.log)" "-title shell [ $TNAME ]"
  assert_contains "$(<$SANDBOX/notifier.log)" "-message task complete"
  assert_file_absent "$FAKE_OSASCRIPT_LOG"
}

test_banner_click_focuses_this_frame() {
  setup_frame_env
  plant_notifier
  run_frame notify
  assert_status 0
  assert_contains "$(<$SANDBOX/notifier.log)" "frame focus shell/$TNAME"
}

test_quick_turn_gate_still_applies() {
  setup_frame_env
  plant_notifier
  touch "$FRAME_RUNDIR/shell-$TNAME.prompt"
  run_frame notify
  assert_status 0
  assert_file_absent "$SANDBOX/notifier.log"
}

run_tests "$0"
