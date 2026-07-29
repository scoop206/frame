#!/usr/bin/env zsh
# frame merge in scratch repos with a local bare origin. Nothing here ever
# touches the network; --push lands on $SANDBOX/origin.git.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

setup_topic() {
  # repo on main (pushed) + topic branch "feature" with one commit, cwd = repo
  make_repo
  make_topic feature
  cd "$REPO"
}

test_dry_run_changes_nothing() {
  setup_topic
  local before=$(git -C "$REPO" rev-parse main)
  local before_origin=$(git -C "$SANDBOX/origin.git" rev-parse main)
  run_frame merge feature -n
  assert_status 0
  assert_contains "$OUT" "(dry run"
  assert_contains "$OUT" "merge --no-ff"
  assert_eq "$(git -C "$REPO" rev-parse main)" "$before" "dry run moved main"
  assert_eq "$(git -C "$SANDBOX/origin.git" rev-parse main)" "$before_origin" "dry run touched origin"
}

test_merge_creates_merge_commit_and_does_not_push() {
  setup_topic
  local before_origin=$(git -C "$SANDBOX/origin.git" rev-parse main)
  run_frame merge feature
  assert_status 0
  assert_contains "$OUT" "merged 'feature' into main"
  assert_contains "$OUT" "not pushed"
  assert_eq "$(git -C "$REPO" log -1 --format=%s main)" "Merge branch 'feature'"
  assert_eq "$(git -C "$SANDBOX/origin.git" rev-parse main)" "$before_origin" "pushed without --push"
}

test_ff_merge_fast_forwards() {
  setup_topic
  run_frame merge feature --ff
  assert_status 0
  assert_eq "$(git -C "$REPO" rev-parse main)" "$(git -C "$REPO" rev-parse feature)"
  assert_eq "$(git -C "$REPO" log -1 --format=%s main)" "add feature.txt" "expected no merge commit"
}

test_push_updates_origin() {
  setup_topic
  run_frame merge feature --push
  assert_status 0
  assert_contains "$OUT" "pushed main to origin"
  assert_eq "$(git -C "$SANDBOX/origin.git" rev-parse main)" "$(git -C "$REPO" rev-parse main)"
}

test_topic_defaults_to_current_worktree_branch() {
  setup_topic
  cd "$SANDBOX/_$TNAME-feature"
  run_frame merge
  assert_status 0
  assert_contains "$OUT" "merging 'feature' → 'main'"
}

test_explicit_topic_overrides_cwd_branch() {
  # :FrameMerge always passes an explicit topic while cwd is the primary
  # worktree (main_wt), never the topic's own. Pin that an explicit topic wins
  # over the invoking worktree's branch — the config where getting it wrong
  # merges the WRONG branch rather than harmlessly refusing.
  setup_topic
  make_topic other
  cd "$SANDBOX/_$TNAME-other"
  run_frame merge feature
  assert_status 0
  assert_contains "$OUT" "merging 'feature' → 'main'"
  assert_eq "$(git -C "$REPO" log -1 --format=%s main)" "Merge branch 'feature'"
}

test_merging_main_into_itself_fails() {
  setup_topic
  run_frame merge main
  assert_status 1
  assert_contains "$OUT" "nothing to merge into itself"
}

test_unknown_branch_fails() {
  setup_topic
  run_frame merge nope
  assert_status 1
  assert_contains "$OUT" "no local branch 'nope'"
}

test_dirty_primary_blocks_merge() {
  setup_topic
  print -r -- "dirty" >> "$REPO/README.md"
  run_frame merge feature
  assert_status 1
  assert_contains "$OUT" "uncommitted changes"
}

test_untracked_files_in_primary_do_not_block() {
  setup_topic
  touch "$REPO/untracked.txt"
  run_frame merge feature
  assert_status 0
  assert_contains "$OUT" "merged 'feature' into main"
}

test_dirty_topic_worktree_warns_but_merges() {
  setup_topic
  print -r -- "uncommitted" >> "$SANDBOX/_$TNAME-feature/feature.txt"
  run_frame merge feature
  assert_status 0
  assert_contains "$OUT" "NOT part of this merge"
  assert_contains "$OUT" "merged 'feature' into main"
}

test_diverged_main_aborts() {
  setup_topic
  git clone -q "$SANDBOX/origin.git" "$SANDBOX/second"
  commit_file "$SANDBOX/second" other.txt "from second clone"
  git -C "$SANDBOX/second" push -q origin main
  commit_file "$REPO" local.txt "local-only main commit"
  run_frame merge feature
  assert_status 1
  assert_contains "$OUT" "diverged from origin/main"
}

test_conflict_stops_with_abort_hint() {
  setup_topic
  # add/add conflict: both main and feature create feature.txt differently
  commit_file "$REPO" feature.txt "conflicting content on main"
  run_frame merge feature
  assert_status 1
  assert_contains "$OUT" "merge hit conflicts"
  assert_contains "$OUT" "merge --abort"
  git -C "$REPO" rev-parse -q --verify MERGE_HEAD >/dev/null \
    || fail "expected an in-progress merge (MERGE_HEAD)"
}

test_unknown_flag_exits_2() {
  setup_topic
  run_frame merge feature -x
  assert_status 2
  assert_contains "$OUT" "unknown flag: -x"
}

test_two_topics_exit_2() {
  setup_topic
  run_frame merge feature extra
  assert_status 2
  assert_contains "$OUT" "more than one branch"
}

run_tests "$0"
