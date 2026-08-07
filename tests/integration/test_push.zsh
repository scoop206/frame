#!/usr/bin/env zsh
# frame push in scratch repos with a local bare origin. Nothing here ever
# touches the network; pushes land on $SANDBOX/origin.git.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

setup_merged() {
  # repo on main with topic "feature" merged locally — origin doesn't have it yet
  make_repo
  make_topic feature
  cd "$REPO"
  run_frame merge feature
  assert_status 0
}

test_push_publishes_primary() {
  setup_merged
  run_frame push
  assert_status 0
  assert_contains "$OUT" "pushed main to origin"
  assert_eq "$(git -C "$SANDBOX/origin.git" rev-parse main)" "$(git -C "$REPO" rev-parse main)"
}

test_push_works_from_topic_worktree() {
  setup_merged
  cd "$SANDBOX/_$TNAME-feature"
  run_frame push
  assert_status 0
  assert_contains "$OUT" "pushed main to origin"
  assert_eq "$(git -C "$SANDBOX/origin.git" rev-parse main)" "$(git -C "$REPO" rev-parse main)"
}

test_level_with_origin_is_a_clean_noop() {
  make_repo
  run_frame push
  assert_status 0
  assert_contains "$OUT" "nothing to push"
}

test_dry_run_changes_nothing() {
  setup_merged
  local before_origin=$(git -C "$SANDBOX/origin.git" rev-parse main)
  run_frame push -n
  assert_status 0
  assert_contains "$OUT" "(dry run"
  assert_eq "$(git -C "$SANDBOX/origin.git" rev-parse main)" "$before_origin" "dry run touched origin"
}

test_behind_origin_refuses() {
  make_repo
  git clone -q "$SANDBOX/origin.git" "$SANDBOX/second"
  commit_file "$SANDBOX/second" other.txt "from second clone"
  git -C "$SANDBOX/second" push -q origin main
  run_frame push
  assert_status 1
  assert_contains "$OUT" "behind origin/main"
}

test_diverged_primary_refuses() {
  make_repo
  git clone -q "$SANDBOX/origin.git" "$SANDBOX/second"
  commit_file "$SANDBOX/second" other.txt "from second clone"
  git -C "$SANDBOX/second" push -q origin main
  commit_file "$REPO" local.txt "local-only main commit"
  run_frame push
  assert_status 1
  assert_contains "$OUT" "diverged from origin/main"
}

test_no_origin_remote_refuses() {
  make_repo
  git -C "$REPO" remote remove origin
  run_frame push
  assert_status 1
  assert_contains "$OUT" "no 'origin' remote"
}

test_master_primary_branch_pushes() {
  # Nothing hardcodes 'main': a repo whose primary branch is 'master' pushes
  # the same way.
  make_repo "$TNAME" master
  make_topic feature
  cd "$REPO"
  run_frame merge feature
  assert_status 0
  run_frame push
  assert_status 0
  assert_contains "$OUT" "pushed master to origin"
  assert_eq "$(git -C "$SANDBOX/origin.git" rev-parse master)" "$(git -C "$REPO" rev-parse master)"
}

test_unknown_flag_exits_2() {
  make_repo
  run_frame push -x
  assert_status 2
  assert_contains "$OUT" "unknown argument: -x"
}

run_tests "$0"
