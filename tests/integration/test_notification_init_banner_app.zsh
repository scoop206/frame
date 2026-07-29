#!/usr/bin/env zsh
# The banner-app build (notifier.sh), reached as `frame notification init`.
# `frame init` no longer builds it — the build/repair lives here alone (split
# out in d182db2), so it's exercised through `frame notification init`.
#
# The macOS notification grant is keyed to the bundle's code signature, so
# re-inits must skip the rebuild unless an input actually changed — a no-op
# re-sign would silently revoke the grant. A fake brew ahead of the suite's
# failing stub supplies a skeletal-but-buildable source app; the real sips/
# iconutil/PlistBuddy/codesign toolchain runs against it (killall is stubbed,
# and the bundle's fake binary makes the post-build self-test a guarded
# no-op). That toolchain only exists on macOS, so the build tests skip
# elsewhere.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

APP_DIR() { print -r -- "$HOME/.local/share/frame/Frame.app"; }

plant_brew_and_source() {
  SRC="$SANDBOX/brew/opt/terminal-notifier"
  local _app="$SRC/bin/terminal-notifier.app/Contents"
  mkdir -p "$_app/MacOS" "$_app/Resources" "$SANDBOX/bin"
  print -r -- "fake notifier binary" > "$_app/MacOS/terminal-notifier"
  cat > "$_app/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>com.example.terminal-notifier</string>
	<key>CFBundleName</key><string>terminal-notifier</string>
</dict>
</plist>
EOF
  cat > "$SANDBOX/bin/brew" <<EOF
#!/usr/bin/env zsh
print -r -- "$SRC"
EOF
  chmod +x "$SANDBOX/bin/brew"
  path=("$SANDBOX/bin" $path)
}

test_first_notification_init_builds_then_reinit_skips() {
  [[ $OSTYPE == darwin* ]] || { skip "banner-app build needs the macOS toolchain"; return }
  plant_brew_and_source
  run_frame notification init
  assert_status 0
  assert_contains "$OUT" "built $(APP_DIR)"
  assert_file_exists "$(APP_DIR)/Contents/Resources/frame-fingerprint"
  touch "$(APP_DIR)/marker"
  run_frame notification init
  assert_status 0
  assert_contains "$OUT" "banner app already built"
  assert_file_exists "$(APP_DIR)/marker"
}

test_changed_input_rebuilds_on_next_notification_init() {
  [[ $OSTYPE == darwin* ]] || { skip "banner-app build needs the macOS toolchain"; return }
  plant_brew_and_source
  run_frame notification init
  touch "$(APP_DIR)/marker"
  print -r -- "fake notifier binary v2" \
    > "$SRC/bin/terminal-notifier.app/Contents/MacOS/terminal-notifier"
  run_frame notification init
  assert_status 0
  assert_not_contains "$OUT" "already built"
  assert_contains "$OUT" "built $(APP_DIR)"
  assert_file_absent "$(APP_DIR)/marker"
}

test_missing_notifier_hints_instead_of_installing() {
  # the suite's default brew stub has nothing installed — notification init
  # must bow out non-zero, hint at the install command, and not have run brew
  # install itself
  run_frame notification init
  assert_status 1
  assert_contains "$OUT" "brew install terminal-notifier"
  assert_not_contains "$OUT" "installing"
  assert_dir_absent "$(APP_DIR)"
}

test_frame_init_does_not_build_banner_app() {
  # the split (d182db2): `frame init` scaffolds the project but never touches
  # the machine-global banner app, even with a working brew on PATH.
  make_repo
  plant_brew_and_source
  run_frame init
  assert_status 0
  assert_contains "$OUT" ".frame/config.sh"
  assert_contains "$OUT" "scaffolded"
  assert_not_contains "$OUT" "built $(APP_DIR)"
  assert_dir_absent "$(APP_DIR)"
}

run_tests "$0"
