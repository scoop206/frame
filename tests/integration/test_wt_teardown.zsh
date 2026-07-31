#!/usr/bin/env zsh
# frame wt -d: safety rails, forced teardown, and the detached reaper.
# No nvim socket ever exists here (unique $TNAME), so teardown takes the
# "no nvim socket" path and the nvim stub is never invoked.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

setup_frame() {
  # repo + booted worktree "topic", cwd left in the primary checkout
  make_repo
  write_config <<'EOF'
BUFFERS=()
EOF
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame wt topic
  assert_status 0
  unset FAKE_NVIM_LOG
  WT="$SANDBOX/_$TNAME-topic"
  cd "$REPO"
}

test_clean_teardown_removes_worktree_and_branch() {
  setup_frame
  run_frame wt -d topic
  assert_status 0
  assert_contains "$OUT" "no nvim socket"
  assert_contains "$OUT" "✓ removed worktree and branch topic"
  assert_dir_absent "$WT"
  assert_branch_absent "$REPO" topic
}

test_dirty_worktree_blocks_teardown() {
  setup_frame
  touch "$WT/junk"
  run_frame wt -d topic
  assert_status 1
  assert_contains "$OUT" "uncommitted/untracked files"
  assert_dir_exists "$WT"
  assert_branch_exists "$REPO" topic
}

test_unmerged_branch_blocks_teardown() {
  setup_frame
  commit_file "$WT" work.txt "unmerged work"
  run_frame wt -d topic
  assert_status 1
  assert_contains "$OUT" "commits not on main"
  assert_contains "$OUT" "frame merge"
  assert_dir_exists "$WT"
}

test_force_overrides_both_rails() {
  setup_frame
  commit_file "$WT" work.txt "unmerged work"
  touch "$WT/junk"
  run_frame wt -d -f topic
  assert_status 0
  assert_dir_absent "$WT"
  assert_branch_absent "$REPO" topic
}

test_live_holder_blocks_socketless_teardown() {
  # No socket exists here (unique $TNAME), so teardown can't confirm the session
  # is down. A live process still sitting in the worktree (its cwd) must block
  # removal rather than have the tree deleted out from under it — the husk bug.
  setup_frame
  export FAKE_HELD_DIR="$WT"
  run_frame wt -d topic
  unset FAKE_HELD_DIR
  assert_status 1
  assert_contains "$OUT" "still in use"
  assert_dir_exists "$WT"
  assert_branch_exists "$REPO" topic
}

test_force_teardown_ignores_live_holder() {
  # -f is the deliberate nuke: it skips the holder check entirely.
  setup_frame
  export FAKE_HELD_DIR="$WT"
  run_frame wt -d -f topic
  unset FAKE_HELD_DIR
  assert_status 0
  assert_dir_absent "$WT"
  assert_branch_absent "$REPO" topic
}

test_missing_worktree_fails() {
  make_repo
  run_frame wt -d nope
  assert_status 1
  assert_contains "$OUT" "no worktree at"
}

test_no_topic_outside_a_frame_shows_usage() {
  make_repo
  run_frame wt -d
  assert_status 1
  assert_contains "$OUT" "Usage: frame wt -d"
}

test_teardown_from_inside_hands_off_to_reaper() {
  setup_frame
  cd "$WT"
  run_frame wt -d
  assert_status 0
  assert_contains "$OUT" "handing off to a detached reaper"
  # the nohup'd re-invocation removes the worktree shortly after we return
  local i
  for i in {1..25}; do
    [[ -d "$WT" ]] || break
    sleep 0.2
  done
  assert_dir_absent "$WT"
  assert_branch_absent "$REPO" topic
}

test_merge_then_teardown_happy_path() {
  setup_frame
  commit_file "$WT" work.txt "feature work"
  run_frame merge topic
  assert_status 0
  run_frame wt -d topic
  assert_status 0
  assert_dir_absent "$WT"
  assert_branch_absent "$REPO" topic
}

run_tests "$0"
