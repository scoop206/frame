#!/usr/bin/env zsh
# frame notify's global banner switch (frame notification off|on): the `notify`
# key of the machine-global config, $HOME/.local/share/frame/config. HOME is
# sandboxed per test, so the toggle never touches (or reads) the real
# machine's settings.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

CONFIG_REL=".local/share/frame/config"

# Shell-frame identity (env-carried, no repo fixture needed) — the global
# switch itself is frame-kind-agnostic, and toggling needs no frame at all.
setup_shell_frame() {
  mkdir -p "$SANDBOX/frames/$TNAME"
  cd "$SANDBOX/frames/$TNAME"
  export FRAME_NAME=shell FRAME_TOPIC=$TNAME
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
}

test_off_writes_setting_and_reports() {
  run_frame notification off
  assert_status 0
  assert_contains "$(<$HOME/$CONFIG_REL)" "notify=off"
  assert_contains "$OUT" "banners off everywhere"
}

test_off_suppresses_banner() {
  setup_shell_frame
  run_frame notification off
  run_frame notify
  assert_status 0
  assert_file_absent "$FAKE_OSASCRIPT_LOG"
}

test_on_restores_banner() {
  setup_shell_frame
  run_frame notification off
  run_frame notification on
  assert_contains "$(<$HOME/$CONFIG_REL)" "notify=on"
  run_frame notify
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - task complete shell [ $TNAME ]"
}

test_toggle_never_banners() {
  # `frame notification on` is the toggle, not a banner that says "on".
  setup_shell_frame
  run_frame notification on
  assert_status 0
  assert_file_absent "$FAKE_OSASCRIPT_LOG"
}

test_notify_args_are_a_usage_error() {
  # notify is the bare hook target — any args (including the old on|off
  # spellings) error and point at frame notification, without a banner.
  setup_shell_frame
  run_frame notify pssst
  assert_status 2
  assert_contains "$OUT" "frame notification"
  assert_file_absent "$FAKE_OSASCRIPT_LOG"
  run_frame notify off
  assert_status 2
}

test_notification_needs_a_subcommand() {
  setup_shell_frame
  run_frame notification
  assert_status 2
  assert_contains "$OUT" "usage: frame notification"
  run_frame notification pssst
  assert_status 2
  assert_file_absent "$FAKE_OSASCRIPT_LOG"
}

test_toggle_is_idempotent() {
  run_frame notification off
  run_frame notification off
  assert_status 0
  assert_eq "$(grep -c '^notify=' "$HOME/$CONFIG_REL")" "1"
  run_frame notification on
  run_frame notification on
  assert_status 0
  assert_contains "$(<$HOME/$CONFIG_REL)" "notify=on"
}

test_toggle_preserves_other_settings() {
  # The switch edits its own key only — a hand-added setting survives.
  mkdir -p "$HOME/${CONFIG_REL:h}"
  echo "future_setting=7" > "$HOME/$CONFIG_REL"
  run_frame notification off
  assert_status 0
  assert_contains "$(<$HOME/$CONFIG_REL)" "future_setting=7"
  assert_contains "$(<$HOME/$CONFIG_REL)" "notify=off"
}

run_tests "$0"
