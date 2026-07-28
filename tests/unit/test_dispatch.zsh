#!/usr/bin/env zsh
# Black-box dispatch behavior of bin/frame.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

test_no_args_prints_usage() {
  run_frame
  assert_status 0
  assert_contains "$OUT" "Usage:"
  assert_contains "$OUT" "frame wt TOPIC"
}

test_help_flags_match_no_args() {
  run_frame
  local base=$OUT
  local flag
  for flag in --help -h help; do
    run_frame $flag
    assert_status 0
    assert_eq "$OUT" "$base" "output of 'frame $flag' differs from bare 'frame'"
  done
}

test_unknown_command_exits_2() {
  run_frame bogus
  assert_status 2
  assert_contains "$OUT" "unknown command 'bogus'"
}

test_worktree_synonym_dispatches_to_wt() {
  # Both spellings must reach wt.sh — proven by hitting its first failure
  # (config load outside a git repo) identically.
  mkdir -p "$SANDBOX/empty"
  cd "$SANDBOX/empty"
  run_frame worktree
  assert_status 1
  assert_contains "$OUT" "not inside a git repository"
  local synonym_out=$OUT
  run_frame wt
  assert_eq "$OUT" "$synonym_out" "'frame worktree' and 'frame wt' behave differently"
}

test_services_bad_arg_exits_2() {
  run_frame services bogus
  assert_status 2
  assert_contains "$OUT" "Usage: frame services [up|down|ps]"
}

test_wt_unknown_flag_exits_2() {
  make_repo
  run_frame wt -x
  assert_status 2
  assert_contains "$OUT" "unknown flag: -x"
}

test_wt_merge_flag_removed_notice() {
  make_repo
  run_frame wt -m
  assert_status 2
  assert_contains "$OUT" "use: frame merge"
}

run_tests "$0"
