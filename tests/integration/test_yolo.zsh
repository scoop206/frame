#!/usr/bin/env zsh
# frame yolo — the machine-global master switch that adds
# --dangerously-skip-permissions to every frame's claude buffer (the `yolo`
# key of $HOME/.local/share/frame/config, read at boot by
# frame_export_claude_flags). HOME is sandboxed per test, so toggling never
# touches the real machine's settings.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

CONFIG_REL=".local/share/frame/config"

test_default_reports_off() {
  run_frame yolo
  assert_status 0
  assert_contains "$OUT" "yolo is off"
}

test_on_writes_setting_and_reports() {
  run_frame yolo on
  assert_status 0
  assert_contains "$OUT" "dangerously-skip-permissions"
  assert_contains "$(<$HOME/$CONFIG_REL)" "yolo=on"
  run_frame yolo
  assert_contains "$OUT" "yolo is on"
}

test_off_restores_default() {
  run_frame yolo on
  run_frame yolo off
  assert_status 0
  assert_contains "$(<$HOME/$CONFIG_REL)" "yolo=off"
  run_frame yolo
  assert_contains "$OUT" "yolo is off"
}

test_bad_argument_exits_2() {
  run_frame yolo maybe
  assert_status 2
  assert_contains "$OUT" "Usage: frame yolo"
}

test_extra_args_exit_2() {
  run_frame yolo on off
  assert_status 2
  assert_contains "$OUT" "Usage: frame yolo"
}

# ── the switch reaches the boot exports ───────────────────────────────────────
# buffers.json's claude command is `claude ${FRAME_CLAUDE_FLAGS}`, so what the
# nvim stub logs for FRAME_CLAUDE_FLAGS is exactly what claude launches with.

setup_project() {
  make_repo
  write_config <<'EOF'
BUFFERS=()
EOF
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
}

test_wt_boot_default_exports_empty_flags() {
  setup_project
  run_frame wt topic
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" $'FRAME_CLAUDE_FLAGS=\n'
}

test_wt_boot_yolo_on_exports_skip_permissions() {
  setup_project
  run_frame yolo on
  run_frame wt topic
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" \
    "FRAME_CLAUDE_FLAGS=--dangerously-skip-permissions"
}

test_shell_boot_yolo_on_exports_skip_permissions() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame yolo on
  run_frame shell scratch
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" \
    "FRAME_CLAUDE_FLAGS=--dangerously-skip-permissions"
}

run_tests "$0"
