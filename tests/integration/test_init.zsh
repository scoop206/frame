#!/usr/bin/env zsh
# frame init end-to-end in scratch repos.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

test_init_fresh_repo() {
  make_repo
  run_frame init
  assert_status 0
  assert_contains "$OUT" "scaffolded — edit it to fit"
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
  assert_contains "$OUT" "already exists — left alone"
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

test_init_warns_when_existing_settings_lacks_hooks() {
  make_repo
  mkdir -p "$REPO/.claude"
  print -r -- '{"hooks":{}}' > "$REPO/.claude/settings.json"
  local before=$(cksum "$REPO/.claude/settings.json")
  run_frame init
  assert_status 0
  assert_contains "$OUT" "frame hooks missing, merge by hand"
  assert_contains "$OUT" "frame's notification hooks"
  assert_contains "$OUT" "frame notify"
  # the existing file must be left byte-for-byte untouched
  assert_eq "$(cksum "$REPO/.claude/settings.json")" "$before" "settings.json was rewritten"
}

test_init_quiet_when_existing_settings_already_wired() {
  make_repo
  run_frame init          # writes frame's hooks
  run_frame init          # second run sees them already wired
  assert_status 0
  assert_contains "$OUT" "already wired for frame"
  # no hand-merge warning when the hooks are present
  if [[ "$OUT" == *"merge by hand"* ]]; then
    fail "warned about hooks that are already wired"
  fi
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
