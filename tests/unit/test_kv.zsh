#!/usr/bin/env zsh
# In-process tests of the key=value file primitives and the frame kv layer
# lookup (lib/helpers.sh). Every path is inside the per-test sandbox.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"
export FRAME_ROOT="$FRAME_CHECKOUT"
source "$FRAME_ROOT/lib/helpers.sh"

# ── frame_kvfile_* ────────────────────────────────────────────────────────────

test_kvfile_get_absent_file_returns_1() {
  local rc=0
  frame_kvfile_get "$SANDBOX/nope" k >/dev/null || rc=$?
  assert_eq "$rc" 1
}

test_kvfile_get_distinguishes_empty_from_absent() {
  print -r -- "k=" > "$SANDBOX/f"
  local rc=0
  assert_eq "$(frame_kvfile_get "$SANDBOX/f" k)" ""
  frame_kvfile_get "$SANDBOX/f" k >/dev/null || rc=$?
  assert_eq "$rc" 0 "empty value read as absent"
  rc=0
  frame_kvfile_get "$SANDBOX/f" other >/dev/null || rc=$?
  assert_eq "$rc" 1
}

test_kvfile_set_creates_dir_and_header() {
  frame_kvfile_set "$SANDBOX/a/b/f" k v "# hdr"
  assert_eq "$(head -1 "$SANDBOX/a/b/f")" "# hdr"
  assert_eq "$(frame_kvfile_get "$SANDBOX/a/b/f" k)" "v"
}

test_kvfile_unset_keeps_other_lines() {
  printf '# note\nk=1\nj=2\nk=3\n' > "$SANDBOX/f"
  frame_kvfile_unset "$SANDBOX/f" k
  assert_eq "$(<$SANDBOX/f)" $'# note\nj=2'
  local rc=0
  frame_kvfile_unset "$SANDBOX/f" k || rc=$?
  assert_eq "$rc" 1 "unsetting an absent key should report nothing to do"
}

# ── layers ────────────────────────────────────────────────────────────────────

test_defaults_file_lists_the_known_keys() {
  assert_eq "${(j:,:)${(f)"$(frame_kv_keys)"}}" \
    "autocommit,merge_on_commit,push_on_merge,deploy_on_merge"
}

test_default_layer_answers_when_nothing_is_set() {
  frame_kv_scope proj topic "$SANDBOX/main"
  frame_kv_lookup push_on_merge
  assert_eq "$KV_VALUE" false
  assert_eq "$KV_LAYER" default
}

test_precedence_frame_over_project_over_user() {
  frame_kv_scope proj topic "$SANDBOX/main"
  frame_kvfile_set "$FRAME_KV_FILE[user]" push_on_merge true
  frame_kv_lookup push_on_merge;  assert_eq "$KV_LAYER" user
  frame_kvfile_set "$FRAME_KV_FILE[project]" push_on_merge false
  frame_kv_lookup push_on_merge;  assert_eq "$KV_LAYER" project
  assert_eq "$KV_VALUE" false
  frame_kvfile_set "$FRAME_KV_FILE[frame]" push_on_merge true
  frame_kv_lookup push_on_merge;  assert_eq "$KV_LAYER" frame
  assert_eq "$KV_VALUE" true
}

test_frame_layer_is_per_topic() {
  frame_kv_scope proj one ""
  frame_kvfile_set "$FRAME_KV_FILE[frame]" autocommit true
  frame_kv_scope proj two ""
  assert_eq "$(frame_kv_get autocommit)" false
}

test_slashed_topic_stays_one_file() {
  frame_kv_scope proj feature/x ""
  assert_eq "${FRAME_KV_FILE[frame]:t}" "feature%x"
}

test_empty_scope_drops_frame_and_project_layers() {
  frame_kv_scope "" "" ""
  assert_eq "$FRAME_KV_FILE[frame]" ""
  assert_eq "$FRAME_KV_FILE[project]" ""
  assert_eq "$(frame_kv_get autocommit)" false
}

test_is_true_fails_safe_on_junk() {
  frame_kv_scope proj topic ""
  frame_kvfile_set "$FRAME_KV_FILE[frame]" push_on_merge yes
  frame_kv_is_true push_on_merge && fail "junk value read as true"
  frame_kvfile_set "$FRAME_KV_FILE[frame]" push_on_merge true
  frame_kv_is_true push_on_merge || fail "true not read as true"
}

test_global_config_wrappers_still_work() {
  FRAME_GLOBAL_CONFIG="$HOME/.local/share/frame/config"
  assert_eq "$(frame_global_get notify)" ""
  frame_global_set notify off
  assert_eq "$(frame_global_get notify)" off
}

run_tests "$0"
