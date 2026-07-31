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
  local sock="/tmp/$TNAME-other.nvim"
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
  assert_contains "$log" "argv: -S $FRAME_CHECKOUT/layouts/worktree.lua"
  assert_contains "$log" "cwd: $SANDBOX/_$TNAME-topic"
  assert_contains "$log" "FRAME_NAME=$TNAME"
  assert_contains "$log" "FRAME_TOPIC=topic"
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
  assert_contains "$log" "FRAME_VITE_PORT=5000"
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
  export NVIM=/tmp/fake-parent.sock
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
# layouts/worktree.lua turns into a vim.notify warning that survives the exec
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
  "Notification": [{ "hooks": [{ "type": "command", "command": "frame notify --blocked" }] }]
} }
EOF
  run_frame wt topic
  assert_status 0
  # all four present → exported empty (no warning fires in the layout)
  assert_contains "$(<$FAKE_NVIM_LOG)" $'FRAME_HOOK_DRIFT=\n'
}

run_tests "$0"
