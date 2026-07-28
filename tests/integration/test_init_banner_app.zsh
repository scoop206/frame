#!/usr/bin/env zsh
# frame init's banner-app step (notifier.sh): the macOS notification grant is
# keyed to the bundle's code signature, so re-inits must skip the rebuild
# unless an input actually changed — a no-op re-sign would silently revoke
# the grant. A fake brew ahead of the suite's failing stub supplies a
# skeletal-but-buildable source app; the real sips/iconutil/PlistBuddy/
# codesign toolchain runs against it (killall is stubbed, and the bundle's
# fake binary makes the post-build self-test a guarded no-op).
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

test_first_init_builds_then_reinit_skips() {
  make_repo
  plant_brew_and_source
  run_frame init
  assert_status 0
  assert_contains "$OUT" "built $(APP_DIR)"
  assert_file_exists "$(APP_DIR)/Contents/Resources/frame-fingerprint"
  touch "$(APP_DIR)/marker"
  run_frame init
  assert_status 0
  assert_contains "$OUT" "banner app already built"
  assert_file_exists "$(APP_DIR)/marker"
}

test_changed_input_rebuilds_on_next_init() {
  make_repo
  plant_brew_and_source
  run_frame init
  touch "$(APP_DIR)/marker"
  print -r -- "fake notifier binary v2" \
    > "$SRC/bin/terminal-notifier.app/Contents/MacOS/terminal-notifier"
  run_frame init
  assert_status 0
  assert_not_contains "$OUT" "already built"
  assert_contains "$OUT" "built $(APP_DIR)"
  assert_file_absent "$(APP_DIR)/marker"
}

test_missing_notifier_hints_instead_of_installing() {
  # the suite's default brew stub has nothing installed — init must finish,
  # hint at the install command, and not have run brew install itself
  make_repo
  run_frame init
  assert_status 0
  assert_contains "$OUT" "scaffolded .frame/config.sh"
  assert_contains "$OUT" "brew install terminal-notifier"
  assert_not_contains "$OUT" "installing"
  assert_dir_absent "$(APP_DIR)"
}

run_tests "$0"
