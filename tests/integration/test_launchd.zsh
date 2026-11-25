#!/usr/bin/env zsh
# frame launchd — the optional macOS login agent. launchctl is stubbed (never
# the real launchd) and the plist goes to a sandbox dir (FRAME_LAUNCHAGENTS_DIR).
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

macos() { [[ "$(uname -s)" == Darwin ]]; }

setup_agent() {
  export FRAME_LAUNCHAGENTS_DIR="$SANDBOX/LaunchAgents" FAKE_LAUNCHCTL_LOG="$SANDBOX/launchctl.log"
  PLIST="$FRAME_LAUNCHAGENTS_DIR/frame.agent.plist"
}

test_install_writes_and_loads_the_plist() {
  macos || { skip "LaunchAgents are macOS-only"; return 0; }
  setup_agent
  run_frame launchd install
  assert_status 0
  assert_contains "$OUT" "installed the frame login agent"
  local plist=$(<$PLIST)
  assert_contains "$plist" "<string>$FRAME_CHECKOUT/bin/frame</string>"
  assert_contains "$plist" "<string>launchd</string>"
  assert_contains "$plist" "<string>run</string>"
  assert_not_contains "$plist" "--restore"
  assert_contains "$plist" "<key>PATH</key>"
  assert_contains "$plist" "<key>FRAME_STATEDIR</key><string>$FRAME_STATEDIR</string>"
  assert_contains "$(<$FAKE_LAUNCHCTL_LOG)" "argv: bootstrap gui/$UID $PLIST"
  if (( $+commands[plutil] )); then
    plutil -lint "$PLIST" >/dev/null || fail "plist doesn't lint"
  fi
}

test_install_restore_adds_the_flag() {
  macos || { skip "LaunchAgents are macOS-only"; return 0; }
  setup_agent
  run_frame launchd install --restore
  assert_status 0
  assert_contains "$(<$PLIST)" "<string>--restore</string>"
  assert_contains "$OUT" "frame restore --all"
}

test_uninstall_and_status() {
  macos || { skip "LaunchAgents are macOS-only"; return 0; }
  setup_agent
  run_frame launchd status
  assert_contains "$OUT" "not installed"
  run_frame launchd install --restore
  run_frame launchd status
  assert_contains "$OUT" "NOT loaded"
  assert_contains "$OUT" "restore at login"
  FAKE_LAUNCHCTL_LOADED=1 run_frame launchd status
  assert_contains "$OUT" "installed and loaded"
  run_frame launchd uninstall
  assert_status 0
  assert_file_absent "$PLIST"
  assert_contains "$(<$FAKE_LAUNCHCTL_LOG)" "bootout gui/$UID/frame.agent"
}

test_install_refused_off_macos() {
  macos && { skip "checks the non-macOS refusal"; return 0; }
  setup_agent
  run_frame launchd install
  assert_status 1
  assert_contains "$OUT" "macOS-only"
}

test_agent_stops_every_frame_on_sigterm() {
  # The agent sleeps until launchd's SIGTERM, then frame-stops each live frame
  # (keeping its record, stamped stopped).
  mkdir -p "$FRAME_STATEDIR"
  local sock="$FRAME_RUNDIR/shell-jam.nvim"
  _mksock "$sock"
  printf 'shell\tjam\t\twaiting\t,0,0\t1\n' > "$sock.info"
  printf '{\n  "name": "shell",\n  "topic": "jam",\n  "type": "shell",\n  "dir": "%s"\n}\n' "$SANDBOX" \
    > "$FRAME_STATEDIR/shell-jam.json"
  "$FRAME_BIN" launchd run >/dev/null 2>&1 &
  local pid=$!
  local i
  for i in {1..50}; do [[ -f "$FRAME_STATEDIR/agent.log" ]] && break; sleep 0.1; done
  kill -TERM $pid
  wait $pid
  assert_file_absent "$sock"
  assert_contains "$(<$FRAME_STATEDIR/agent.log)" "SIGTERM — stopping every frame"
  assert_contains "$(<$FRAME_STATEDIR/agent.log)" "stopped shell/jam"
  assert_contains "$(<$FRAME_STATEDIR/shell-jam.json)" '"stopped_at": "1'
}

test_agent_restores_at_login() {
  mkdir -p "$FRAME_STATEDIR" "$SANDBOX/notes"
  printf '{\n  "name": "shell",\n  "topic": "notes",\n  "type": "shell",\n  "dir": "%s",\n  "session": "sid-n"\n}\n' \
    "$SANDBOX/notes" > "$FRAME_STATEDIR/shell-notes.json"
  export FRAME_AGENT_RESTORE_DELAY=0 FAKE_OSASCRIPT_RESULT="1 2"
  "$FRAME_BIN" launchd run --restore >/dev/null 2>&1 &
  local pid=$! i
  for i in {1..100}; do
    grep -q 'shell/notes\|notes --resume' "$FRAME_STATEDIR/agent.log" 2>/dev/null && break
    sleep 0.1
  done
  kill -TERM $pid; wait $pid
  local log=$(<$FRAME_STATEDIR/agent.log)
  assert_contains "$log" "login — frame restore --all"
  if macos; then
    assert_contains "$log" "restoring shell/notes (resuming session sid-n)"
  else
    assert_contains "$log" "shell -C $SANDBOX/notes notes --resume sid-n"
  fi
}

run_tests "$0"
