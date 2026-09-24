#!/usr/bin/env zsh
# frame kv — the layered agent-behavior settings, black-box. HOME is sandboxed,
# so the frame/user layers land in the sandbox; the project layer lands in the
# scratch repo's gitignored-by-convention .frame/local/.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

setup_frame() {
  # repo + topic worktree "feature", cwd inside it — frame_self_identity derives
  # NAME/TOPIC from the _NAME-TOPIC dir, exactly as inside a real frame.
  make_repo
  make_topic feature
  cd "$SANDBOX/_$TNAME-feature"
}

test_list_shows_every_key_from_default() {
  setup_frame
  run_frame kv
  assert_status 0
  local k
  for k in autocommit merge_on_commit push_on_merge deploy_on_merge; do
    assert_contains "$OUT" "$k"
  done
  assert_contains "$OUT" "default"
}

test_set_defaults_to_the_frame_layer() {
  setup_frame
  run_frame kv set push_on_merge true
  assert_status 0
  assert_contains "$OUT" "push_on_merge=true (frame)"
  assert_file_exists "$HOME/.local/share/frame/kv/$TNAME/feature"
  run_frame kv get push_on_merge
  assert_eq "$OUT" true
}

test_frame_setting_does_not_leak_to_sibling() {
  setup_frame
  run_frame kv set autocommit true
  make_topic other
  cd "$SANDBOX/_$TNAME-other"
  run_frame kv get autocommit
  assert_eq "$OUT" false
}

test_project_layer_shared_by_worktrees_and_keeps_main_clean() {
  setup_frame
  run_frame kv set --project autocommit true
  assert_status 0
  assert_file_exists "$REPO/.frame/local/kv"
  make_topic other
  cd "$SANDBOX/_$TNAME-other"
  run_frame kv get autocommit
  assert_eq "$OUT" true
  # untracked only — frame merge's clean-tree guard looks at tracked changes
  assert_eq "$(git -C "$REPO" diff --name-only)" ""
}

test_user_layer_and_shadow_warning() {
  setup_frame
  run_frame kv set push_on_merge false
  run_frame kv set --user push_on_merge true
  assert_status 0
  assert_contains "$OUT" "but the frame layer wins"
  assert_contains "$(<$HOME/.config/frame/kv)" "push_on_merge=true"
}

test_unset_falls_through_to_next_layer() {
  setup_frame
  run_frame kv set --user deploy_on_merge true
  run_frame kv set deploy_on_merge false
  run_frame kv unset deploy_on_merge
  assert_status 0
  assert_contains "$OUT" "now deploy_on_merge=true from user"
}

test_unknown_key_and_bad_bool_exit_2() {
  setup_frame
  run_frame kv set merge_push true
  assert_status 2
  assert_contains "$OUT" "unknown key 'merge_push'"
  run_frame kv set autocommit yes
  assert_status 2
  assert_contains "$OUT" "takes true or false"
}

test_frame_layer_needs_a_frame() {
  mkdir -p "$SANDBOX/nowhere"; cd "$SANDBOX/nowhere"
  run_frame kv set autocommit true
  assert_status 1
  assert_contains "$OUT" "not inside a frame"
  run_frame kv set --user autocommit true
  assert_status 0
}

test_agent_may_only_set_false() {
  setup_frame
  export CLAUDECODE=1
  run_frame kv set push_on_merge true
  assert_status 1
  assert_contains "$OUT" "settings are the human's"
  run_frame kv get push_on_merge
  assert_eq "$OUT" false
  run_frame kv set push_on_merge false
  assert_status 0
  run_frame kv unset push_on_merge
  assert_status 1
}

test_bad_usage_exits_2() {
  setup_frame
  run_frame kv frobnicate
  assert_status 2
  assert_contains "$OUT" "Usage: frame kv"
  run_frame kv set --bogus autocommit true
  assert_status 2
}

# ── consumers: frame merge + the swarm block ──────────────────────────────────

test_merge_push_on_merge_pushes() {
  setup_frame
  run_frame kv set push_on_merge true
  cd "$REPO"
  run_frame merge feature
  assert_status 0
  assert_contains "$OUT" "push_on_merge=true (frame)"
  assert_contains "$OUT" "pushed main to origin"
  assert_eq "$(git -C "$SANDBOX/origin.git" rev-parse main)" "$(git -C "$REPO" rev-parse main)"
}

test_merge_no_push_overrides_setting() {
  setup_frame
  run_frame kv set push_on_merge true
  cd "$REPO"
  local before=$(git -C "$SANDBOX/origin.git" rev-parse main)
  run_frame merge feature --no-push
  assert_status 0
  assert_contains "$OUT" "not pushed"
  assert_eq "$(git -C "$SANDBOX/origin.git" rev-parse main)" "$before"
}

test_merge_push_on_merge_without_origin_merges_locally() {
  make_repo
  git -C "$REPO" remote remove origin
  make_topic feature
  cd "$REPO"
  run_frame kv set --user push_on_merge true
  run_frame merge feature
  assert_status 0
  assert_contains "$OUT" "merging locally only"
  assert_eq "$(git -C "$REPO" log -1 --format=%s main)" "Merge branch 'feature'"
}

test_merge_deploy_on_merge_reminds() {
  setup_frame
  cd "$REPO"
  run_frame merge feature
  assert_not_contains "$OUT" "deploy_on_merge"
  git -C "$REPO" reset -q --hard HEAD~1
  run_frame kv set --project deploy_on_merge true
  run_frame merge feature
  assert_status 0
  assert_contains "$OUT" "deploy_on_merge=true (project) — deploy"
}

test_teardown_reaps_frame_layer() {
  setup_frame
  run_frame kv set autocommit true
  cd "$REPO"
  git -C "$REPO" merge -q feature
  run_frame wt -d feature
  assert_status 0
  assert_file_absent "$HOME/.local/share/frame/kv/$TNAME/feature"
}

test_swarm_block_carries_kv_values() {
  setup_frame
  run_frame kv set merge_on_commit true
  run_frame swarm 1
  export FRAME_NAME=$TNAME FRAME_TOPIC=feature
  run_frame swarm --context
  assert_status 0
  assert_contains "$OUT" "merge_on_commit=true"
  assert_contains "$OUT" "autocommit=false"
  assert_contains "$OUT" "frame kv get KEY"
}

run_tests "$0"
