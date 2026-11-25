#!/usr/bin/env zsh
# Detachable frames: the headless nvim server + --remote-ui window boot
# (frame_exec_session), frame attach, and detached frames in ls/restore.
# The nvim stub models the server launch (FAKE_NVIM_SERVE_LOG: stands up the
# socket with a 0-window FrameInfo) and the window (FAKE_NVIM_UI_LOG).
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

plant() {  # plant NAME TOPIC UIS — a live frame with UIS windows attached
  local sock="$FRAME_RUNDIR/$1-$2.nvim"
  _mksock "$sock"
  printf '%s\t%s\t\twaiting\t,0,0\t%s\n' "$1" "$2" "$3" > "$sock.info"
}

write_record() {  # write_record NAME TOPIC DIR [SESSION]
  mkdir -p "$FRAME_STATEDIR"
  cat > "$FRAME_STATEDIR/$1-$2.json" <<EOF
{
  "name": "$1",
  "topic": "$2",
  "type": "shell",
  "dir": "$3",
  "session": "${4:-}",
  "stopped_at": ""
}
EOF
}

headless() {
  export FRAME_HEADLESS=1 FAKE_NVIM_SERVE_LOG="$SANDBOX/serve.log" FAKE_NVIM_UI_LOG="$SANDBOX/ui.log"
}

# ── the boot ─────────────────────────────────────────────────────────────────

test_shell_boots_headless_server_then_window() {
  headless
  mkdir -p "$SANDBOX/w" && cd "$SANDBOX/w"
  run_frame shell jam
  assert_status 0
  local serve=$(<$SANDBOX/serve.log)
  assert_contains "$serve" "argv: --headless -S $FRAME_CHECKOUT/layouts/session.lua"
  assert_contains "$serve" "cwd: $SANDBOX/w"
  assert_contains "$serve" "FRAME_NAME=shell"
  assert_contains "$serve" "FRAME_TOPIC=jam"
  assert_contains "$(<$SANDBOX/ui.log)" "argv: --remote-ui --server $FRAME_RUNDIR/shell-jam.nvim"
  assert_file_exists "$FRAME_STATEDIR/shell-jam.json"
}

test_wt_boots_headless_server_then_window() {
  headless
  make_repo
  write_config <<'EOF'
BUFFERS=()
EOF
  run_frame wt topic
  assert_status 0
  assert_contains "$(<$SANDBOX/serve.log)" "cwd: $SANDBOX/_$TNAME-topic"
  assert_contains "$(<$SANDBOX/ui.log)" "--server $FRAME_RUNDIR/$TNAME-topic.nvim"
}

test_server_that_never_comes_up_is_reported() {
  export FRAME_HEADLESS=1 FRAME_SERVER_TIMEOUT=2   # no FAKE_NVIM_SERVE_LOG: the stub dies
  mkdir -p "$SANDBOX/w" && cd "$SANDBOX/w"
  run_frame shell jam
  assert_status 1
  assert_contains "$OUT" "didn't come up"
  assert_contains "$OUT" "FRAME_HEADLESS=0"
}

test_booting_a_detached_frame_attaches_instead() {
  headless
  plant shell jam 0
  mkdir -p "$SANDBOX/w" && cd "$SANDBOX/w"
  run_frame shell jam
  assert_status 0
  assert_contains "$OUT" "already running, detached — attaching"
  assert_contains "$(<$SANDBOX/ui.log)" "--server $FRAME_RUNDIR/shell-jam.nvim"
  assert_file_absent "$SANDBOX/serve.log"          # no second server
}

test_booting_a_frame_open_elsewhere_refuses() {
  headless
  plant shell jam 1
  mkdir -p "$SANDBOX/w" && cd "$SANDBOX/w"
  run_frame shell jam
  assert_status 1
  assert_contains "$OUT" "already running in another window"
  assert_file_absent "$SANDBOX/serve.log"
  assert_file_absent "$SANDBOX/ui.log"
}

# ── ls / attach ──────────────────────────────────────────────────────────────

test_ls_marks_detached_frames() {
  plant shell gone 0
  plant shell here 1
  run_frame ls
  assert_status 0
  assert_contains "$OUT" "detached · waiting"
  [[ "$(print -r -- "$OUT" | grep ' here ')" != *detached* ]] || fail "attached frame marked detached"
}

test_attach_with_nothing_detached() {
  plant shell here 1
  run_frame attach
  assert_status 0
  assert_contains "$OUT" "no detached frames"
}

test_attach_here_becomes_the_window() {
  export FAKE_NVIM_UI_LOG="$SANDBOX/ui.log"
  plant shell jam 0
  run_frame attach --here jam
  assert_status 0
  assert_contains "$(<$SANDBOX/ui.log)" "--remote-ui --server $FRAME_RUNDIR/shell-jam.nvim"
}

test_attach_refuses_a_frame_with_a_window() {
  plant shell jam 1
  run_frame attach jam
  assert_status 1
  assert_contains "$OUT" "already has a window"
}

test_attach_here_needs_a_topic() {
  plant shell jam 0
  run_frame attach --here
  assert_status 2
}

test_attach_opens_tabs_for_every_detached_frame() {
  [[ "$(uname -s)" == Darwin ]] || { skip "tabs are macOS-only"; return 0; }
  plant shell one 0
  plant shell two 0
  plant shell three 1
  export FAKE_OSASCRIPT_RESULT="7 8" FAKE_OSASCRIPT_LOG="$SANDBOX/osa.log"
  run_frame attach
  assert_status 0
  assert_contains "$OUT" "attached shell/one"
  assert_contains "$OUT" "attached shell/two"
  assert_not_contains "$OUT" "shell/three"
  assert_eq "$(<$FRAME_RUNDIR/shell-one.nvim.gtab)" "7 8"
  assert_contains "$(<$SANDBOX/osa.log)" "attach --here shell/one"
  assert_contains "$(<$SANDBOX/osa.log)" "close-tab shell/one"
}

# ── restore: detached → attach, not reboot ───────────────────────────────────

test_restore_lists_and_attaches_detached() {
  write_record shell jam "$SANDBOX" sid-j
  plant shell jam 0
  run_frame restore
  assert_status 0
  assert_contains "$OUT" "detached"
  run_frame restore jam --print
  assert_status 0
  assert_contains "$OUT" "bin/frame attach --here shell/jam"
  assert_not_contains "$OUT" "--resume"
  assert_file_absent "$FRAME_RUNDIR/shell-jam.restored"   # nothing was interrupted
}

test_restore_skips_frames_with_a_window() {
  write_record shell jam "$SANDBOX" sid-j
  plant shell jam 1
  run_frame restore
  assert_status 0
  assert_contains "$OUT" "nothing to restore"
}

test_restore_forget_refuses_a_running_detached_frame() {
  write_record shell jam "$SANDBOX"
  plant shell jam 0
  run_frame restore --forget jam
  assert_contains "$OUT" "still running (detached)"
  assert_file_exists "$FRAME_STATEDIR/shell-jam.json"
}

run_tests "$0"
