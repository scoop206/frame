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

_live() {
  # _live NAME TOPIC — a running session for NAME/TOPIC (the nvim stub answers
  # FrameKv* from a <sock>.kv companion).
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$FRAME_RUNDIR/$1-$2.nvim"
}

test_defaults_file_lists_the_known_keys() {
  assert_eq "${(j:,:)${(f)"$(frame_kv_keys)"}}" \
    "autocommit,merge_on_commit,push_on_merge,deploy_on_merge,spawn_frames"
}

test_default_layer_answers_when_nothing_is_set() {
  frame_kv_scope proj topic "$SANDBOX/main"
  frame_kv_lookup push_on_merge
  assert_eq "$KV_VALUE" false
  assert_eq "$KV_LAYER" default
}

test_spawn_frames_defaults_to_true() {
  frame_kv_scope proj topic "$SANDBOX/main"
  frame_kv_lookup spawn_frames
  assert_eq "$KV_VALUE" true
  assert_eq "$KV_LAYER" default
}

test_precedence_frame_over_project_over_user() {
  _live proj topic
  frame_kv_scope proj topic "$SANDBOX/main"
  frame_kvfile_set "$FRAME_KV_FILE[user]" push_on_merge true
  frame_kv_lookup push_on_merge;  assert_eq "$KV_LAYER" user
  frame_kvfile_set "$FRAME_KV_FILE[project]" push_on_merge false
  frame_kv_lookup push_on_merge;  assert_eq "$KV_LAYER" project
  assert_eq "$KV_VALUE" false
  frame_kv_frame_write s push_on_merge true
  frame_kv_lookup push_on_merge;  assert_eq "$KV_LAYER" frame
  assert_eq "$KV_VALUE" true
}

test_frame_layer_is_per_topic() {
  _live proj one; _live proj two
  frame_kv_scope proj one ""
  frame_kv_frame_write s autocommit true
  frame_kv_scope proj two ""
  assert_eq "$(frame_kv_get autocommit)" false
}

test_frame_layer_is_fetched_from_the_session() {
  _live proj topic
  frame_kv_scope proj topic ""
  assert_eq "$FRAME_KV_FRAME_STATE" live
  frame_kv_frame_write s autocommit true
  frame_kv_frame_write n ticket "ENG 1"
  frame_kv_scope proj topic ""               # a fresh scope re-reads the session
  assert_eq "$(frame_kv_get autocommit)" true
  assert_eq "$(frame_kv_get ticket)" "ENG 1"
}

test_stopped_frame_has_an_empty_frame_layer() {
  frame_kv_scope proj gone ""
  assert_eq "$FRAME_KV_FRAME_STATE" down
  assert_eq "$(frame_kv_get autocommit)" false
  local rc=0
  frame_kv_frame_write s autocommit true 2>/dev/null || rc=$?
  assert_eq "$rc" 1
}

test_frame_write_unset_reports_absent() {
  _live proj topic
  frame_kv_scope proj topic ""
  local rc=0
  frame_kv_frame_write n nope || rc=$?
  assert_eq "$rc" 2
}

test_empty_scope_drops_frame_and_project_layers() {
  frame_kv_scope "" "" ""
  assert_eq "$FRAME_KV_FRAME_STATE" none
  assert_eq "$FRAME_KV_FILE[project]" ""
  assert_eq "$(frame_kv_get autocommit)" false
}

test_is_true_fails_safe_on_junk() {
  _live proj topic
  frame_kv_scope proj topic ""
  frame_kv_frame_write s push_on_merge yes
  frame_kv_is_true push_on_merge && fail "junk value read as true"
  frame_kv_frame_write s push_on_merge true
  frame_kv_is_true push_on_merge || fail "true not read as true"
}

test_global_config_wrappers_still_work() {
  FRAME_GLOBAL_CONFIG="$HOME/.local/share/frame/config"
  assert_eq "$(frame_global_get notify)" ""
  frame_global_set notify off
  assert_eq "$(frame_global_get notify)" off
}

# ── declarations: custom keys ─────────────────────────────────────────────────

_decl() {
  # _decl FILE LINES… — write a declaration file.
  mkdir -p "${1:h}"; local f=$1; shift
  print -rl -- "$@" > "$f"
}

test_project_and_user_keys_follow_builtins_in_order() {
  _decl "$SANDBOX/main/.frame/kv.defaults" "# Review language." "review_lang=en"
  _decl "$HOME/.config/frame/kv.defaults" "# Run e2e before commit." "run_e2e=false"
  frame_kv_scope proj topic "$SANDBOX/main"
  assert_eq "${(j:,:)${(f)"$(frame_kv_keys)"}}" \
    "autocommit,merge_on_commit,push_on_merge,deploy_on_merge,spawn_frames,review_lang,run_e2e"
  assert_eq "$FRAME_KV_FROM[review_lang]" project
  assert_eq "$FRAME_KV_FROM[run_e2e]" user
}

test_custom_default_answers_with_its_origin() {
  _live proj topic
  _decl "$SANDBOX/main/.frame/kv.defaults" "review_lang=en"
  frame_kv_scope proj topic "$SANDBOX/main"
  frame_kv_lookup review_lang
  assert_eq "$KV_VALUE" en
  assert_eq "$KV_LAYER" "default (project)"
  frame_kv_frame_write s review_lang de
  frame_kv_lookup review_lang
  assert_eq "$KV_VALUE/$KV_LAYER" de/frame
}

test_description_is_the_comment_block_above() {
  _decl "$SANDBOX/main/.frame/kv.defaults" \
    "# header, separated by a blank line" "" \
    "# Language for review comments." "# Any ISO code." "review_lang=en"
  frame_kv_scope proj topic "$SANDBOX/main"
  assert_eq "$FRAME_KV_DESC[review_lang]" $'Language for review comments.\nAny ISO code.'
}

test_type_comes_from_the_default() {
  _decl "$SANDBOX/main/.frame/kv.defaults" "run_e2e=false" "review_lang=en"
  frame_kv_scope proj topic "$SANDBOX/main"
  frame_kv_is_bool run_e2e || fail "false default should be boolean"
  frame_kv_is_bool autocommit || fail "built-in should be boolean"
  frame_kv_is_bool review_lang && fail "en default should be a string"
  return 0
}

test_no_main_wt_means_no_project_declarations() {
  _decl "$SANDBOX/main/.frame/kv.defaults" "review_lang=en"
  frame_kv_scope proj topic ""
  (( ${FRAME_KV_KEYS[(Ie)review_lang]} )) && fail "project key leaked without MAIN_WT"
  return 0
}

test_builtin_cannot_be_redeclared() {
  _decl "$SANDBOX/main/.frame/kv.defaults" "autocommit=true"
  frame_kv_scope proj topic "$SANDBOX/main"
  frame_kv_lookup autocommit
  assert_eq "$KV_VALUE/$KV_LAYER" false/default
  assert_contains "$FRAME_KV_WARNINGS" "autocommit is a built-in key"
}

test_project_declaration_beats_user() {
  _decl "$SANDBOX/main/.frame/kv.defaults" "review_lang=en"
  _decl "$HOME/.config/frame/kv.defaults" "review_lang=fr"
  frame_kv_scope proj topic "$SANDBOX/main"
  assert_eq "$(frame_kv_get review_lang)" en
  assert_contains "$FRAME_KV_WARNINGS" "already declared by the project"
}

test_same_default_redeclared_is_quiet() {
  _decl "$SANDBOX/main/.frame/kv.defaults" "review_lang=en"
  _decl "$HOME/.config/frame/kv.defaults" "review_lang=en"
  frame_kv_scope proj topic "$SANDBOX/main"
  assert_eq "$#FRAME_KV_WARNINGS" 0
}

test_malformed_lines_are_skipped_with_a_warning() {
  _decl "$SANDBOX/main/.frame/kv.defaults" "Bad-Key=1" "no equals" "ok_key=1"
  frame_kv_scope proj topic "$SANDBOX/main"
  assert_eq "${(j:,:)FRAME_KV_KEYS[6,-1]}" ok_key
  assert_eq "$#FRAME_KV_WARNINGS" 2
  assert_contains "$FRAME_KV_WARNINGS" "kv.defaults:1: not a declaration"
}

test_undeclared_key_has_no_value_even_if_set_in_a_layer() {
  frame_kv_scope proj topic ""
  local rc=0
  frame_kv_lookup nope || rc=$?
  assert_eq "$rc" 1
}

test_agent_note_answers_only_for_undeclared_keys() {
  _live proj topic
  frame_kv_scope proj topic "$SANDBOX/main"
  frame_kv_frame_write n ticket ENG-1
  frame_kv_frame_write n autocommit true
  frame_kv_lookup ticket
  assert_eq "$KV_VALUE/$KV_LAYER" "ENG-1/frame (agent)"
  frame_kv_lookup autocommit
  assert_eq "$KV_VALUE/$KV_LAYER" false/default
  assert_eq "$(frame_kv_agent_keys)" ticket
  assert_eq "$(frame_kv_agent_keys --shadowed)" autocommit
}

test_no_frame_means_no_agent_notes() {
  frame_kv_scope "" "" ""
  assert_eq "$FRAME_KV_SOCKET" ""
  assert_eq "$(frame_kv_agent_keys)" ""
}

run_tests "$0"
