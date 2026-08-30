#!/usr/bin/env zsh
# frame wt create/reuse/boot. The PATH-stubbed nvim (recording mode via
# FAKE_NVIM_LOG) becomes the exec'd process, so its log proves what the
# editor launch would have seen.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

setup_project() {
  make_repo
  write_config <<'EOF'
BUFFERS=()
EOF
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
}

# A live frame owned by some OTHER project carrying $2 as its topic — the nvim
# stub answers FrameInfo() from the planted <sock>.info companion (see
# test_ls.zsh). Socket name carries $TNAME so sandbox_down sweeps it.
plant_live_topic() {  # plant_live_topic NAME TOPIC
  local sock="$FRAME_RUNDIR/$TNAME-other.nvim"
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$sock"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" 5173 '' > "$sock.info"
}

test_create_boots_into_nvim() {
  setup_project
  run_frame wt topic
  assert_status 0
  assert_dir_exists "$SANDBOX/_$TNAME-topic"
  assert_branch_exists "$REPO" topic
  assert_file_exists "$FAKE_NVIM_LOG"
  local log=$(<$FAKE_NVIM_LOG)
  assert_contains "$log" "argv: -S $FRAME_CHECKOUT/layouts/session.lua"
  assert_contains "$log" "cwd: $SANDBOX/_$TNAME-topic"
  assert_contains "$log" "FRAME_NAME=$TNAME"
  assert_contains "$log" "FRAME_TOPIC=topic"
  assert_contains "$log" "FRAME_WT=$SANDBOX/_$TNAME-topic"
}

test_missing_buffers_refuses_to_boot() {
  make_repo  # no config at all → BUFFERS undefined
  run_frame wt topic
  assert_status 1
  assert_contains "$OUT" "must define BUFFERS"
  assert_dir_absent "$SANDBOX/_$TNAME-topic"
}

test_existing_worktree_is_reused() {
  setup_project
  run_frame wt topic
  run_frame wt topic
  assert_status 0
  assert_contains "$OUT" "already exists — reusing"
}

test_husk_directory_is_not_reused() {
  # A bare directory where the worktree belongs — left by a torn-down or
  # half-removed frame — has no .git; booting into it fails cryptically
  # mid-setup. Refuse before any side effect rather than "reusing" it.
  setup_project
  mkdir -p "$SANDBOX/_$TNAME-topic"      # husk: exists, not a registered worktree
  run_frame wt topic
  assert_status 1
  assert_contains "$OUT" "not a live worktree"
  assert_branch_absent "$REPO" topic
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_existing_branch_gets_worktree() {
  setup_project
  git -C "$REPO" branch topic2
  run_frame wt topic2
  assert_status 0
  assert_contains "$OUT" "on existing branch topic2"
  assert_dir_exists "$SANDBOX/_$TNAME-topic2"
}

test_no_arg_boots_current_frame() {
  setup_project
  run_frame wt topic
  cd "$SANDBOX/_$TNAME-topic"
  run_frame wt
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_TOPIC=topic"
}

test_no_arg_in_primary_uses_branch_name() {
  setup_project
  run_frame wt
  assert_status 0
  local log=$(<$FAKE_NVIM_LOG)
  assert_contains "$log" "FRAME_TOPIC=main"
  assert_contains "$log" "cwd: $REPO"
}

test_stack_up_hook_runs() {
  make_repo
  write_config <<'EOF'
BUFFERS=()
stack_up() { touch "$SANDBOX/stack_ran"; }
EOF
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame wt topic
  assert_status 0
  assert_file_exists "$SANDBOX/stack_ran"
}

test_port_scan_and_exports() {
  make_repo
  write_config <<'EOF'
BUFFERS=()
API_PORT=4000
VITE_PORT=5000
HMR_PORT=6000
EOF
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  export FAKE_BUSY_PORTS="4000"
  run_frame wt topic
  assert_status 0
  assert_contains "$OUT" "server :4001 · vite :5000 · hmr :6000"
  local log=$(<$FAKE_NVIM_LOG) prefix=${(U)TNAME}
  assert_contains "$log" "PORT=4001"
  assert_contains "$log" "${prefix}_API_PORT=4001"
  assert_contains "$log" "${prefix}_VITE_PORT=5000"
  assert_contains "$log" "${prefix}_HMR_PORT=6000"
  assert_contains "$log" "FRAME_API_PORT=4001"
  assert_contains "$log" "FRAME_VITE_PORT=5000"
  assert_contains "$log" "FRAME_HMR_PORT=6000"
}

test_wt_links_symlinks_gitignored_assets() {
  make_repo
  print -r -- "SECRET=1" > "$REPO/.env"
  commit_file "$REPO" .gitignore ".env"
  write_config <<'EOF'
BUFFERS=()
WT_LINKS=(.env nope.txt)
EOF
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame wt topic
  assert_status 0
  assert_link_target "$SANDBOX/_$TNAME-topic/.env" "$REPO/.env"
  # entries missing in the primary checkout are skipped silently
  assert_file_absent "$SANDBOX/_$TNAME-topic/nope.txt"
}

test_topic_live_elsewhere_is_refused() {
  setup_project
  plant_live_topic othername topic     # another project already owns "topic"
  run_frame wt topic
  assert_status 1
  assert_contains "$OUT" "is already live"
  # Refused before side effects: no worktree, no branch, no editor launch.
  assert_dir_absent "$SANDBOX/_$TNAME-topic"
  assert_branch_absent "$REPO" topic
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_same_name_topic_reboot_is_allowed() {
  # A live frame with this frame's OWN name+topic is a reboot, not a collision.
  setup_project
  plant_live_topic "$TNAME" topic
  run_frame wt topic
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_TOPIC=topic"
}

test_different_topic_ignores_live_frame() {
  setup_project
  plant_live_topic othername othertopic   # different topic → no conflict
  run_frame wt topic
  assert_status 0
  assert_dir_exists "$SANDBOX/_$TNAME-topic"
}

test_nested_boot_refused_noninteractively() {
  # $NVIM set = we're inside an existing frame's nvim; a non-tty caller gets a
  # refusal BEFORE any side effect — no worktree, no branch, no nvim.
  setup_project
  export NVIM=$FRAME_RUNDIR/fake-parent.sock
  run_frame wt topic < /dev/null
  assert_status 1
  assert_contains "$OUT" "refusing to boot a frame inside this frame's nvim"
  assert_dir_absent "$SANDBOX/_$TNAME-topic"
  assert_file_absent "$FAKE_NVIM_LOG"
}

# ── committed-hook drift sniff ────────────────────────────────────────────────
# A worktree inherits the branch's COMMITTED .claude/settings.json, so a file
# that drifted from frame's canonical hook set silently breaks the frame's
# notifications. wt boot greps it (frame_claude_hooks_missing) and exports
# FRAME_HOOK_DRIFT — the comma-joined missing hooks, empty when in sync — which
# layouts/session.lua turns into a vim.notify warning that survives the exec
# into nvim. The stub's env dump proves what the boot exported.

commit_claude_settings() {  # commit_claude_settings <<'EOF' … EOF
  mkdir -p "$REPO/.claude"
  cat > "$REPO/.claude/settings.json"
  git -C "$REPO" add .claude/settings.json
  git -C "$REPO" commit -qm "add claude settings"
}

test_wt_boot_flags_hook_drift() {
  setup_project
  # committed file wired for Stop→notify + UserPromptSubmit only: 'frame reply'
  # and 'frame notify --blocked' are absent.
  commit_claude_settings <<'EOF'
{ "hooks": {
  "Stop": [{ "hooks": [{ "type": "command", "command": "frame notify" }] }],
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "frame status --prompt" }] }]
} }
EOF
  run_frame wt topic
  assert_status 0
  # named in canonical order, so the layout's warning reads predictably
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_HOOK_DRIFT=frame reply, frame notify --blocked"
}

test_wt_boot_no_drift_when_hooks_complete() {
  setup_project
  commit_claude_settings <<'EOF'
{ "hooks": {
  "Stop": [{ "hooks": [
    { "type": "command", "command": "frame notify" },
    { "type": "command", "command": "frame reply" } ] }],
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "frame status --prompt" }] }],
  "Notification": [{ "hooks": [{ "type": "command", "command": "frame notify --blocked" }] }],
  "SessionStart": [{ "hooks": [{ "type": "command", "command": "frame swarm --context" }] }],
  "PostToolUse": [{ "matcher": "Edit|Write|MultiEdit|NotebookEdit", "hooks": [{ "type": "command", "command": "frame reload-editor" }] }]
} }
EOF
  run_frame wt topic
  assert_status 0
  # all present → exported empty (no warning fires in the layout)
  assert_contains "$(<$FAKE_NVIM_LOG)" $'FRAME_HOOK_DRIFT=\n'
}

# ── --resume / --from: carry a warm session into the new frame ────────────────
# The claude buffer boots as `claude ${FRAME_CLAUDE_FLAGS}`; these flags inject
# `--resume <id>` into that env, which the stub records in FAKE_NVIM_LOG.

test_resume_injects_flag_into_claude_env() {
  setup_project
  run_frame wt topic --resume sid-abc-123
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_CLAUDE_FLAGS=--resume sid-abc-123"
}

test_from_resolves_recorded_session_and_injects() {
  setup_project
  # The source frame recorded its live session id (frame swarm --context does
  # this at SessionStart); --from reads it by frame name. Not live (no socket).
  print -r -- "sid-from-file" > "$FRAME_RUNDIR/$TNAME-src.session"
  run_frame wt topic --from src
  assert_status 0
  assert_contains "$OUT" "resuming session sid-from-file from frame src"
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_CLAUDE_FLAGS=--resume sid-from-file"
}

test_from_accepts_name_topic_handle_across_projects() {
  # The :FrameName / `frame name` handle is NAME/TOPIC — a sibling in ANOTHER
  # project. --from must resolve it against the SOURCE project's name, not the
  # current project's, so a copied handle pastes straight in. Bug: it used to
  # prepend the current $NAME, mangling `other/src` into `<thisproj>-other/src`.
  setup_project
  print -r -- "sid-cross-proj" > "$FRAME_RUNDIR/otherproj-src.session"
  run_frame wt topic --from otherproj/src
  assert_status 0
  assert_contains "$OUT" "resuming session sid-cross-proj from frame otherproj/src"
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_CLAUDE_FLAGS=--resume sid-cross-proj"
}

# A real AF_UNIX socket file stands in for src's live nvim (the -S gate); the
# stub nvim answers the FrameClaudeAlive RPC from FAKE_NVIM_EXPR_RESULT.
_plant_src_socket() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$FRAME_RUNDIR/$TNAME-src.nvim"; }

test_from_live_claude_is_refused() {
  # One owner per session: a source whose CLAUDE is running is refused, before
  # any side effect. The frame being up is not enough — the claude must be live.
  setup_project
  _plant_src_socket
  export FAKE_NVIM_EXPR_RESULT=1        # FrameClaudeAlive() → claude running
  run_frame wt topic --from src
  assert_status 1
  assert_contains "$OUT" "still running"
  assert_dir_absent "$SANDBOX/_$TNAME-topic"
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_from_exited_claude_proceeds_with_frame_up() {
  # The case that motivated the precise probe: the source frame is still up, but
  # its claude was quit. Resuming must be allowed (no live writer).
  setup_project
  print -r -- "sid-quit" > "$FRAME_RUNDIR/$TNAME-src.session"
  _plant_src_socket
  export FAKE_NVIM_EXPR_RESULT=0        # FrameClaudeAlive() → claude quit
  run_frame wt topic --from src
  assert_status 0
  assert_contains "$OUT" "resuming session sid-quit from frame src"
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_CLAUDE_FLAGS=--resume sid-quit"
}

test_from_unverifiable_source_warns_and_proceeds() {
  # A source predating the probe (RPC errors) can't be checked — warn, don't
  # block a frame that may be idle. The stub tripwires on an un-stubbed expr, so
  # leaving FAKE_NVIM_EXPR_RESULT unset makes the RPC fail like an old layout.
  setup_project
  print -r -- "sid-old" > "$FRAME_RUNDIR/$TNAME-src.session"
  _plant_src_socket
  run_frame wt topic --from src
  assert_status 0
  assert_contains "$OUT" "couldn't check"
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_CLAUDE_FLAGS=--resume sid-old"
}

test_resume_and_from_are_mutually_exclusive() {
  setup_project
  run_frame wt topic --resume sid-1 --from src
  assert_status 2
  assert_contains "$OUT" "mutually exclusive"
  assert_dir_absent "$SANDBOX/_$TNAME-topic"   # rejected before any side effect
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_resume_rejects_non_uuid_charset() {
  setup_project
  run_frame wt topic --resume 'bad id!'
  assert_status 2
  assert_contains "$OUT" "not a valid session id"
  assert_dir_absent "$SANDBOX/_$TNAME-topic"
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_from_unknown_frame_errors_before_side_effects() {
  setup_project
  run_frame wt topic --from ghost
  assert_status 1
  assert_contains "$OUT" "no claude session found"
  assert_dir_absent "$SANDBOX/_$TNAME-topic"
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_resume_missing_value_errors() {
  setup_project
  run_frame wt topic --resume
  assert_status 2
  assert_contains "$OUT" "--resume needs a session id"
}

run_tests "$0"
