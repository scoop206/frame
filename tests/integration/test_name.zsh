#!/usr/bin/env zsh
# frame name — the CLI twin of :FrameName: prints THIS frame's NAME/TOPIC to
# stdout (where the vim command copies it to the clipboard). Pure identity — no
# session/socket needed — so it resolves the same three ways frame_self_identity
# does: session env (shell frame), worktree dir name, or the current branch in
# the primary checkout.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

test_worktree_prints_name_topic() {
  # Inside a worktree the identity comes from the _$NAME-$TOPIC dir name.
  make_repo
  make_topic feature-x
  cd "$SANDBOX/_$TNAME-feature-x"
  run_frame name
  assert_status 0
  assert_eq "$OUT" "$TNAME/feature-x"
}

test_shell_frame_prints_session_env() {
  # A shell frame (no git repo) carries its identity in the session env.
  cd "$SANDBOX"
  export FRAME_NAME=shell FRAME_TOPIC=$TNAME
  run_frame name
  assert_status 0
  assert_eq "$OUT" "shell/$TNAME"
}

test_primary_checkout_prints_name_branch() {
  # In the primary checkout the topic is the current branch.
  make_repo
  cd "$REPO"
  run_frame name
  assert_status 0
  assert_eq "$OUT" "$TNAME/main"
}

test_outside_frame_errors() {
  cd "$SANDBOX"
  run_frame name
  assert_status 1
  assert_contains "$OUT" "must be run from inside a frame"
}

test_extra_args_show_usage() {
  export FRAME_NAME=shell FRAME_TOPIC=$TNAME
  run_frame name stray
  assert_status 2
  assert_contains "$OUT" "takes no arguments"
}

run_tests "$0"
