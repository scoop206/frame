#!/usr/bin/env zsh
# frame kv — the layered agent-behavior settings, black-box. HOME is sandboxed,
# so the user layer lands in the sandbox; the project layer lands in the scratch
# repo's gitignored-by-convention .frame/local/. The frame layer lives in the
# frame's session: a planted socket the nvim stub answers FrameKv* for, keeping
# the table in a <sock>.kv companion.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

live_frame() {
  # live_frame TOPIC — a running session for $TNAME/TOPIC.
  _mksock "$FRAME_RUNDIR/$TNAME-$1.nvim"
}

setup_frame() {
  # repo + topic worktree "feature", cwd inside it — frame_self_identity derives
  # NAME/TOPIC from the _NAME-TOPIC dir, exactly as inside a real frame — and
  # its session running.
  make_repo
  make_topic feature
  live_frame feature
  cd "$SANDBOX/_$TNAME-feature"
}

test_list_shows_every_key_from_default() {
  setup_frame
  run_frame kv
  assert_status 0
  local k
  for k in autocommit merge_on_commit push_on_merge deploy_on_merge spawn_frames; do
    assert_contains "$OUT" "$k"
  done
  assert_contains "$OUT" "default"
}

test_set_defaults_to_the_frame_layer() {
  setup_frame
  run_frame kv set push_on_merge true
  assert_status 0
  assert_contains "$OUT" "push_on_merge=true (frame)"
  # held by the session, not written anywhere on disk by frame
  assert_contains "$(<$FRAME_RUNDIR/$TNAME-feature.nvim.kv)" $'s\tpush_on_merge\ttrue'
  assert_file_absent "$HOME/.local/share/frame/kv"
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

test_stopped_frame_reads_shared_layers_and_refuses_writes() {
  # The frame layer lives in the session: with the frame down it reads as empty
  # (lookups fall through) and writes are refused rather than lost.
  setup_frame
  run_frame kv set autocommit true
  run_frame kv set --user push_on_merge true
  rm "$FRAME_RUNDIR/$TNAME-feature.nvim"
  run_frame kv get autocommit
  assert_eq "$OUT" false
  run_frame kv get push_on_merge
  assert_eq "$OUT" true
  run_frame kv set autocommit true
  assert_status 1
  assert_contains "$OUT" "isn't running"
  CLAUDECODE=1 run_frame kv set ticket X
  assert_status 1
  run_frame kv set --user autocommit true     # shared layers still work
  assert_status 0
}

test_old_layout_without_kv_reads_as_stopped() {
  setup_frame
  touch "$FRAME_RUNDIR/$TNAME-feature.nvim.nokv"
  run_frame kv set autocommit true
  assert_status 1
  assert_contains "$OUT" "Reboot it to use its own kv"
  run_frame kv
  assert_status 0
}

test_merge_of_a_stopped_frame_warns_when_shared_layer_pushes() {
  setup_frame
  run_frame kv set push_on_merge false          # the frame was told not to push…
  run_frame kv set --user push_on_merge true
  rm "$FRAME_RUNDIR/$TNAME-feature.nvim"        # …then quit
  cd "$REPO"
  run_frame merge feature
  assert_status 0
  assert_contains "$OUT" "feature isn't running, so its own kv settings can't be read — push_on_merge=true comes from user"
}

test_merge_of_a_live_frame_honors_its_own_setting() {
  setup_frame
  run_frame kv set push_on_merge false
  run_frame kv set --user push_on_merge true
  cd "$REPO"
  local before=$(git -C "$SANDBOX/origin.git" rev-parse main)
  run_frame merge feature
  assert_status 0
  assert_not_contains "$OUT" "isn't running"
  assert_eq "$(git -C "$SANDBOX/origin.git" rev-parse main)" "$before"
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
  assert_contains "$OUT" "spawn_frames=true"
  assert_contains "$OUT" "frame kv get KEY"
}

# ── custom keys ───────────────────────────────────────────────────────────────

declare_keys() {
  # Committed project declarations in the primary checkout.
  mkdir -p "$REPO/.frame"
  cat > "$REPO/.frame/kv.defaults" <<'EOF'
# Language the agent writes review comments in.
# Any ISO 639-1 code.
review_lang=en

# Run the e2e suite before each commit.
run_e2e=false
EOF
}

test_custom_keys_listed_with_origin() {
  setup_frame
  declare_keys
  run_frame kv
  assert_status 0
  assert_contains "$OUT" "review_lang"
  assert_contains "$OUT" "default (project)"
}

test_custom_string_key_round_trip() {
  setup_frame
  declare_keys
  run_frame kv set review_lang "pt br"
  assert_status 0
  assert_contains "$OUT" "review_lang=pt br (frame)"
  run_frame kv get review_lang
  assert_eq "$OUT" "pt br"
  run_frame kv unset review_lang
  assert_contains "$OUT" "now review_lang=en from default (project)"
}

test_custom_bool_key_is_validated() {
  setup_frame
  declare_keys
  run_frame kv set run_e2e yes
  assert_status 2
  assert_contains "$OUT" "takes true or false"
}

test_unknown_key_says_how_to_declare() {
  setup_frame
  run_frame kv get review_lang
  assert_status 2
  assert_contains "$OUT" ".frame/kv.defaults"
}

test_user_declared_key_works_outside_a_project() {
  mkdir -p "$SANDBOX/nowhere" "$HOME/.config/frame"; cd "$SANDBOX/nowhere"
  print -r -- "editor_theme=dark" > "$HOME/.config/frame/kv.defaults"
  run_frame kv get editor_theme
  assert_eq "$OUT" dark
  run_frame kv set --user editor_theme light
  assert_status 0
  run_frame kv get editor_theme
  assert_eq "$OUT" light
}

test_agent_guard_on_custom_keys() {
  setup_frame
  declare_keys
  export CLAUDECODE=1
  run_frame kv set review_lang de
  assert_status 1
  assert_contains "$OUT" "can't set a string key"
  assert_contains "$OUT" "frame kv set review_lang de"
  run_frame kv set run_e2e true
  assert_status 1
  run_frame kv set run_e2e false
  assert_status 0
  run_frame kv unset run_e2e
  assert_status 1
}

test_describe_one_and_all() {
  setup_frame
  declare_keys
  run_frame kv describe review_lang
  assert_status 0
  assert_contains "$OUT" "review_lang = en  from default (project)"
  assert_contains "$OUT" "string, default en, declared project"
  assert_contains "$OUT" "Any ISO 639-1 code."
  run_frame kv describe
  assert_status 0
  assert_contains "$OUT" "autocommit = false  from default"
  assert_contains "$OUT" "boolean, default false, declared built-in"
  assert_contains "$OUT" "run_e2e = false"
  run_frame kv describe nope
  assert_status 2
}

test_redeclared_builtin_warns_in_list() {
  setup_frame
  mkdir -p "$REPO/.frame"
  print -r -- "autocommit=true" > "$REPO/.frame/kv.defaults"
  run_frame kv
  assert_status 0
  assert_contains "$OUT" "autocommit is a built-in key"
  run_frame kv get autocommit
  assert_eq "$OUT" false
}

test_swarm_block_lists_custom_keys() {
  setup_frame
  run_frame swarm 1
  export FRAME_NAME=$TNAME FRAME_TOPIC=feature
  run_frame swarm --context
  assert_not_contains "$OUT" "Custom keys"
  assert_not_contains "$OUT" "@KV_CUSTOM@"
  declare_keys
  run_frame swarm --context
  assert_status 0
  assert_contains "$OUT" "review_lang=en"
  assert_contains "$OUT" "Custom keys (frame kv describe KEY for more):"
  assert_contains "$OUT" "review_lang → Language the agent writes review comments in."
  assert_not_contains "$OUT" "Any ISO 639-1 code."
}

# ── agent notes: undeclared keys, the agent's own, frame layer only ─────────────

test_agent_keeps_notes_on_its_frame() {
  setup_frame
  export CLAUDECODE=1
  run_frame kv set ticket ENG-412
  assert_status 0
  assert_contains "$OUT" "ticket=ENG-412 (frame, agent note)"
  assert_contains "$(<$FRAME_RUNDIR/$TNAME-feature.nvim.kv)" $'n\tticket\tENG-412'
  run_frame kv get ticket
  assert_eq "$OUT" ENG-412
  run_frame kv
  assert_contains "$OUT" "frame (agent)"
  run_frame kv describe ticket
  assert_contains "$OUT" "agent note"
  run_frame kv unset ticket
  assert_status 0
  run_frame kv get ticket
  assert_status 2
  assert_contains "$OUT" "frame kv set ticket VALUE"
}

test_agent_notes_do_not_leak_to_siblings() {
  setup_frame
  CLAUDECODE=1 run_frame kv set ticket ENG-412
  make_topic other
  cd "$SANDBOX/_$TNAME-other"
  run_frame kv get ticket
  assert_status 2
}

test_agent_cannot_write_project_or_user_layers() {
  setup_frame
  export CLAUDECODE=1
  run_frame kv set --project autocommit false
  assert_status 1
  assert_contains "$OUT" "only write its own frame"
  run_frame kv set --user ticket X
  assert_status 1
  run_frame kv unset --project autocommit
  assert_status 1
  assert_file_absent "$REPO/.frame/local/kv"
}

test_agent_notes_cannot_touch_declared_keys() {
  setup_frame
  declare_keys
  export CLAUDECODE=1
  run_frame kv set autocommit true
  assert_status 1
  run_frame kv set review_lang de
  assert_status 1
  assert_file_absent "$FRAME_RUNDIR/$TNAME-feature.nvim.kv"
}

test_agent_note_key_must_be_a_name() {
  setup_frame
  CLAUDECODE=1 run_frame kv set Bad-Key x
  assert_status 2
  assert_contains "$OUT" "isn't a key name"
}

test_declared_key_shadows_an_older_note() {
  setup_frame
  CLAUDECODE=1 run_frame kv set review_lang de
  assert_status 0
  declare_keys
  run_frame kv get review_lang
  assert_eq "$OUT" en
  run_frame kv
  assert_contains "$OUT" "agent note 'review_lang' is ignored"
}

test_human_can_edit_and_drop_notes_but_not_invent_them() {
  setup_frame
  run_frame kv set ticket ENG-1
  assert_status 2
  assert_contains "$OUT" "unknown key 'ticket'"
  CLAUDECODE=1 run_frame kv set ticket ENG-1
  run_frame kv set ticket ENG-2
  assert_status 0
  run_frame kv get ticket
  assert_eq "$OUT" ENG-2
  run_frame kv set --project ticket ENG-3
  assert_status 2
  run_frame kv unset ticket
  assert_status 0
}

test_swarm_block_carries_agent_notes() {
  setup_frame
  run_frame swarm 1
  export FRAME_NAME=$TNAME FRAME_TOPIC=feature
  run_frame swarm --context
  assert_contains "$OUT" "This frame has a scratchpad"
  assert_not_contains "$OUT" "Your notes on this frame"
  CLAUDECODE=1 run_frame kv set ticket ENG-412
  run_frame swarm --context
  assert_contains "$OUT" "Your notes on this frame: ticket=ENG-412"
}

# ── reading another frame: frame kv --of ──────────────────────────────────────

plant_sibling() {
  # A live "other" frame of this project: socket + FrameDebug answer naming the
  # primary checkout. Its agent writes a note from inside it.
  make_topic other
  local sock="$FRAME_RUNDIR/$TNAME-other.nvim"
  live_frame other
  print -r -- "main_wt	$REPO" > "$sock.debug"
  ( cd "$SANDBOX/_$TNAME-other" && CLAUDECODE=1 "$FRAME_BIN" kv set ticket ENG-9 >/dev/null )
}

test_read_a_siblings_notes_and_settings() {
  setup_frame
  declare_keys
  plant_sibling
  ( cd "$SANDBOX/_$TNAME-other" && "$FRAME_BIN" kv set merge_on_commit true >/dev/null )
  run_frame kv --of other get ticket
  assert_status 0
  assert_eq "$OUT" ENG-9
  run_frame kv --of "$TNAME/other"
  assert_status 0
  assert_contains "$OUT" "ticket"
  assert_contains "$OUT" "frame (agent)"
  assert_contains "$OUT" "review_lang"        # project declarations come along
  run_frame kv --of other get merge_on_commit
  assert_eq "$OUT" true
  run_frame kv get merge_on_commit             # ours is untouched
  assert_eq "$OUT" false
}

test_of_is_read_only() {
  setup_frame
  plant_sibling
  run_frame kv --of other set ticket X
  assert_status 2
  assert_contains "$OUT" "read-only"
  CLAUDECODE=1 run_frame kv --of other unset ticket
  assert_status 2
  run_frame kv --of other get ticket
  assert_eq "$OUT" ENG-9
}

test_of_needs_a_live_frame() {
  setup_frame
  run_frame kv --of nobody
  assert_status 1
  assert_contains "$OUT" "no live frame"
}

test_of_unknown_key_names_the_frame() {
  setup_frame
  plant_sibling
  run_frame kv --of other get nope
  assert_status 2
  assert_contains "$OUT" "$TNAME/other has no setting or agent note"
}

test_of_without_debug_still_reads_frame_layers() {
  setup_frame
  plant_sibling
  rm "$FRAME_RUNDIR/$TNAME-other.nvim.debug"
  run_frame kv --of other get ticket
  assert_status 0
  assert_contains "$OUT" "ENG-9"
  assert_contains "$OUT" "project layer isn't shown"
}

# ── frame view shows a frame's kv ─────────────────────────────────────────────

debug_answer() {
  # A full FrameDebug answer (every field the layout reports) for TOPIC.
  local f
  for f in cwd wt status ready notify ephemeral prefix api_port vite_port hmr_port \
           server buffers broker_inflight broker_queue inbox_count inbox_from; do
    printf '%s\t\n' $f
  done
  printf 'name\t%s\ntopic\t%s\nmain_wt\t%s\n' "$TNAME" "$1" "$REPO"
}

test_view_shows_non_default_settings_and_notes() {
  setup_frame
  plant_sibling
  debug_answer other > "$FRAME_RUNDIR/$TNAME-other.nvim.debug"
  ( cd "$SANDBOX/_$TNAME-other" && "$FRAME_BIN" kv set merge_on_commit true >/dev/null )
  run_frame kv set --project push_on_merge true
  run_frame view other
  assert_status 0
  assert_contains "$OUT" "merge_on_commit=true (frame)"
  assert_contains "$OUT" "push_on_merge=true (project)"
  assert_contains "$OUT" "ticket=ENG-9"
  assert_not_contains "$OUT" "autocommit"       # defaults stay out
}

test_view_with_nothing_set() {
  setup_frame
  make_topic other
  local sock="$FRAME_RUNDIR/$TNAME-other.nvim"
  _mksock "$sock"
  debug_answer other > "$sock.debug"
  run_frame view other
  assert_status 0
  assert_contains "$OUT" "all defaults"
  assert_contains "$OUT" "none"
}

run_tests "$0"
