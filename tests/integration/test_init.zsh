#!/usr/bin/env zsh
# frame init end-to-end in scratch repos.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

test_init_fresh_repo() {
  make_repo
  run_frame init
  assert_status 0
  assert_contains "$OUT" "scaffolded .frame/config.sh"
  assert_file_exists "$REPO/.frame/config.sh"
  assert_contains "$(<$REPO/.frame/config.sh)" "NAME=$TNAME"
  assert_dir_exists "$REPO/.frame/local"
  grep -qxF '.frame/local/' "$REPO/.gitignore" || fail ".gitignore missing .frame/local/"
}

test_init_is_idempotent() {
  make_repo
  run_frame init
  local sum_before=$(cksum "$REPO/.frame/config.sh")
  run_frame init
  assert_status 0
  assert_contains "$OUT" "already exists — leaving it alone"
  assert_contains "$OUT" "already covers .frame/local/"
  assert_eq "$(cksum "$REPO/.frame/config.sh")" "$sum_before" "config.sh was rewritten"
  assert_eq "$(grep -cxF '.frame/local/' "$REPO/.gitignore")" "1" "gitignore entry duplicated"
}

test_init_respects_existing_gitignore_entry() {
  make_repo
  print -r -- '.frame/local/' > "$REPO/.gitignore"
  run_frame init
  assert_status 0
  assert_contains "$OUT" "already covers .frame/local/"
  assert_eq "$(grep -cxF '.frame/local/' "$REPO/.gitignore")" "1"
}

test_init_outside_git_fails() {
  mkdir -p "$SANDBOX/plain"
  cd "$SANDBOX/plain"
  run_frame init
  assert_status 1
  assert_contains "$OUT" "not inside a git repository"
}

test_init_in_worktree_uses_primary_name() {
  make_repo
  git -C "$REPO" worktree add -q "$SANDBOX/some-random-dirname" -b topic
  cd "$SANDBOX/some-random-dirname"
  run_frame init
  assert_status 0
  # NAME comes from the primary checkout's basename, not the worktree dir
  assert_contains "$(<$SANDBOX/some-random-dirname/.frame/config.sh)" "NAME=$TNAME"
}

run_tests "$0"
