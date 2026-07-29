#!/usr/bin/env zsh
# frame shell — casual frames: a generated directory, no git anywhere.
# The PATH-stubbed nvim records what the editor launch would have seen.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

test_shell_creates_dir_and_boots() {
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame shell jam
  assert_status 0
  assert_dir_exists "$SANDBOX/frames/jam"
  local log=$(<$FAKE_NVIM_LOG)
  assert_contains "$log" "argv: -S $FRAME_CHECKOUT/layouts/worktree.lua"
  assert_contains "$log" "cwd: $SANDBOX/frames/jam"
  assert_contains "$log" "FRAME_NAME=shell"
  assert_contains "$log" "FRAME_TOPIC=jam"
  assert_contains "$log" "FRAME_BUFFERS=claude local"
  # empty on purpose: no primary checkout → the layout swaps in the
  # shell-frame :FrameDown (bang-only dir delete) instead of the worktree one
  assert_contains "$log" "FRAME_MAIN_WT="$'\n'
  # and no git repo was conjured up around the topic dir
  ! git -C "$SANDBOX/frames/jam" rev-parse --show-toplevel >/dev/null 2>&1 \
    || fail "topic dir unexpectedly inside a git repo"
}

test_shell_home_defaults_under_home() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame shell jam
  assert_status 0
  assert_dir_exists "$HOME/frames/jam"
}

test_shell_wires_claude_hooks() {
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame shell jam
  assert_status 0
  assert_contains "$OUT" "wired claude hooks"
  local settings="$SANDBOX/frames/jam/.claude/settings.json"
  assert_file_exists "$settings"
  assert_contains "$(<$settings)" "frame notify"
  assert_contains "$(<$settings)" "frame status"
}

test_shell_leaves_existing_claude_settings_alone() {
  # Covers both a user-customized file and a dir from before hook-wiring
  # existed once it's been written: later boots must not clobber it.
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/frames/jam/.claude"
  print -r -- '{"custom": true}' > "$SANDBOX/frames/jam/.claude/settings.json"
  run_frame shell jam
  assert_status 0
  assert_not_contains "$OUT" "wired claude hooks"
  assert_eq "$(<$SANDBOX/frames/jam/.claude/settings.json)" '{"custom": true}'
}

test_shell_reuses_existing_dir() {
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame shell jam
  run_frame shell jam
  assert_status 0
  assert_contains "$OUT" "already exists — reusing"
}

test_shell_requires_exactly_one_topic() {
  run_frame shell
  assert_status 2
  assert_contains "$OUT" "Usage: frame shell TOPIC"
  run_frame shell a b
  assert_status 2
  assert_contains "$OUT" "Usage: frame shell TOPIC"
}

test_shell_rejects_slash_in_topic() {
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  run_frame shell nested/topic
  assert_status 2
  assert_contains "$OUT" "no slashes"
  assert_dir_absent "$SANDBOX/frames/nested"
}

test_status_in_shell_frame_uses_session_env() {
  # A shell frame's buffers aren't in a git repo; status must fall back to
  # the session's FRAME_NAME/FRAME_TOPIC. No nvim runs in tests, so the
  # proof is the error naming the right socket rather than a git failure.
  # $TNAME keeps the /tmp/shell-<topic>.nvim probe clear of real sessions.
  mkdir -p "$SANDBOX/frames/$TNAME"
  cd "$SANDBOX/frames/$TNAME"
  export FRAME_NAME=shell FRAME_TOPIC=$TNAME
  run_frame status busy
  assert_status 1
  assert_contains "$OUT" "no frame session for shell/$TNAME"
  assert_not_contains "$OUT" "not inside a git repository"
}

test_notify_in_shell_frame_banners_with_session_identity() {
  mkdir -p "$SANDBOX/frames/$TNAME"
  cd "$SANDBOX/frames/$TNAME"
  export FRAME_NAME=shell FRAME_TOPIC=$TNAME
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
  run_frame notify
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - waiting shell [ $TNAME ]"
}

test_notify_outside_any_frame_still_exits_0() {
  # Hook-safe contract: no repo, no session env — notify must not fail.
  mkdir -p "$SANDBOX/nowhere"
  cd "$SANDBOX/nowhere"
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
  run_frame notify
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - waiting ? [ ? ]"
}

run_tests "$0"
