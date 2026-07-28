#!/usr/bin/env zsh
# In-process tests of frame_load_config / frame_main_wt (lib/helpers.sh).
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"
export FRAME_ROOT="$FRAME_CHECKOUT"
source "$FRAME_ROOT/lib/helpers.sh"

test_defaults_from_primary_dirname() {
  git init -q "$SANDBOX/my-app"
  cd "$SANDBOX/my-app"
  frame_load_config
  assert_eq "$PROJECT_ROOT" "$SANDBOX/my-app"
  assert_eq "$MAIN_WT" "$SANDBOX/my-app"
  assert_eq "$NAME" "my-app"
  assert_eq "$PORT_PREFIX" "MY_APP"
}

test_committed_config_beats_default() {
  make_repo
  write_config <<'EOF'
NAME=committed
EOF
  frame_load_config
  assert_eq "$NAME" "committed"
}

test_local_config_beats_committed() {
  make_repo
  write_config <<'EOF'
NAME=committed
EOF
  write_local_config <<'EOF'
NAME=local
EOF
  frame_load_config
  assert_eq "$NAME" "local"
}

test_worktree_falls_back_to_primary_config() {
  # .frame/config.sh exists only in the primary checkout (untracked, so the
  # worktree doesn't have its own copy) — lookup falls through to MAIN_WT.
  make_repo
  write_config <<'EOF'
NAME=primaryconf
EOF
  git -C "$REPO" worktree add -q "$SANDBOX/wt" -b topic
  cd "$SANDBOX/wt"
  frame_load_config
  assert_eq "$NAME" "primaryconf"
  assert_eq "$MAIN_WT" "$REPO"
}

test_worktree_local_beats_primary_config() {
  make_repo
  write_config <<'EOF'
NAME=primaryconf
EOF
  git -C "$REPO" worktree add -q "$SANDBOX/wt" -b topic
  write_local_config "$SANDBOX/wt" <<'EOF'
NAME=wtlocal
EOF
  cd "$SANDBOX/wt"
  frame_load_config
  assert_eq "$NAME" "wtlocal"
}

test_main_wt_from_linked_worktree() {
  make_repo
  git -C "$REPO" worktree add -q "$SANDBOX/wt" -b topic
  assert_eq "$(frame_main_wt "$SANDBOX/wt")" "$REPO"
}

test_non_git_dir_fails() {
  mkdir -p "$SANDBOX/plain"
  cd "$SANDBOX/plain"
  local out st
  out=$(frame_load_config 2>&1) && st=0 || st=$?
  assert_eq "$st" "1"
  assert_contains "$out" "not inside a git repository"
}

test_barebones_example_loads() {
  make_repo
  mkdir -p "$REPO/.frame"
  cp "$FRAME_CHECKOUT/examples/barebones/.frame/config.sh" "$REPO/.frame/config.sh"
  frame_load_config
  assert_eq "$NAME" "barebones"
  assert_eq "$PORT_PREFIX" "BAREBONES"
  assert_eq "${BUFFERS[*]}" "claude local"
}

run_tests "$0"
