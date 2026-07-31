#!/usr/bin/env zsh
# frame spawn — boot a worker frame as a tab in the shared workers window. The
# launch is the `osascript` stub (FAKE_OSASCRIPT_LOG records it,
# FAKE_OSASCRIPT_RESULT stands in for the "WINDOW_ID TAB_ID" the dictionary
# returns; without a result frame_open_window falls back to the legacy `open`
# stub / FAKE_OPEN_LOG). Readiness is the socket plus FrameReady() over RPC,
# where a planted AF_UNIX socket with a `.ready` companion stands in for a
# fully-booted session (without one the nvim stub answers 0 — still booting).
# Worker topics are $TNAME so sandbox_down's $FRAME_RUNDIR/*-$TNAME.nvim* patterns reap
# the plants.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_spawn_env() {
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
  export FAKE_OSASCRIPT_RESULT="fake-win fake-tab"
}

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

in_head() { export FRAME_NAME=$TNAME FRAME_TOPIC=head; }

_plant_booted_worker() {
  _mksock "$FRAME_RUNDIR/shell-$TNAME.nvim"
  touch "$FRAME_RUNDIR/shell-$TNAME.nvim.ready"
}

test_no_args_shows_usage() {
  run_frame spawn
  assert_status 2
  assert_contains "$OUT" "usage: frame spawn shell [TOPIC]"
}

test_unknown_kind_shows_usage() {
  run_frame spawn banana calc
  assert_status 2
  assert_contains "$OUT" "usage: frame spawn shell [TOPIC]"
}

test_spawn_wt_needs_a_project() {
  run_frame spawn wt calc   # sandbox root is not a git repo
  assert_status 1
  assert_contains "$OUT" "no project at"
}

test_spawn_wt_rejects_ephemeral() {
  run_frame spawn wt calc --ephemeral
  assert_status 2
  assert_contains "$OUT" "no --ephemeral"
}

test_spawn_shell_rejects_cwd() {
  run_frame spawn shell calc --cwd /tmp
  assert_status 2
  assert_contains "$OUT" "--cwd is a wt flag"
}

test_spawn_wt_boots_project_worker_as_tab() {
  # Project NAME comes from the target checkout's .frame config; the bootstrap
  # cd's there, boots `frame wt`, and chains close-tab as NAME/TOPIC. Readiness
  # polls the project-named socket.
  _spawn_env
  make_repo "checkout-$TNAME"
  write_config <<'EOF'
NAME=stompy
EOF
  _mksock "$FRAME_RUNDIR/stompy-$TNAME.nvim"
  touch "$FRAME_RUNDIR/stompy-$TNAME.nvim.ready"
  run_frame spawn wt $TNAME
  assert_status 0
  assert_contains "$OUT" "spawned tab for stompy/$TNAME"
  assert_contains "$OUT" "stompy/$TNAME is up"
  local log="$(<$FAKE_OSASCRIPT_LOG)"
  assert_contains "$log" "cd $REPO"
  assert_contains "$log" "frame wt $TNAME"
  assert_contains "$log" "frame spawn close-tab stompy/$TNAME"
  assert_eq "$(<$FRAME_RUNDIR/stompy-$TNAME.nvim.gtab)" "fake-win fake-tab"
}

test_spawn_wt_cwd_targets_another_project() {
  # From anywhere, --cwd points spawn at the project; relative paths land
  # absolute in the bootstrap (the surface's shell starts elsewhere).
  _spawn_env
  make_repo "checkout-$TNAME"
  write_config <<'EOF'
NAME=stompy
EOF
  _mksock "$FRAME_RUNDIR/stompy-$TNAME.nvim"
  touch "$FRAME_RUNDIR/stompy-$TNAME.nvim.ready"
  cd "$SANDBOX"
  run_frame spawn wt $TNAME --cwd "checkout-$TNAME"
  assert_status 0
  assert_contains "$OUT" "stompy/$TNAME is up"
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "cd $REPO"
}

test_close_tab_accepts_name_topic_form() {
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
  print -r -- "w-7 t-7" > "$FRAME_RUNDIR/stompy-$TNAME.nvim.gtab"
  run_frame spawn close-tab stompy/$TNAME
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - w-7 t-7"
  assert_file_absent "$FRAME_RUNDIR/stompy-$TNAME.nvim.gtab"
}

test_no_topic_shell_mints_dated_worker() {
  # A bare `frame spawn shell` — no TOPIC — mints a fresh dated scratch topic
  # (like `frame shell`) and dispatches a worker on it instead of erroring. The
  # topic is random, so its socket can't be planted ahead of time: assert the
  # mint message and that the boot command carries the dated topic; the
  # readiness poll then times out (exit 3), which is enough to prove the launch.
  _spawn_env
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  run_frame spawn shell --timeout 1
  assert_status 3
  assert_contains "$OUT" "new scratch worker '"
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "frame shell $(date +%Y-%m-%d)-"
}

test_no_topic_wt_shows_usage() {
  # wt still requires a TOPIC — it names a branch, nothing to mint from.
  run_frame spawn wt
  assert_status 2
  assert_contains "$OUT" "usage: frame spawn shell [TOPIC]"
}

test_rejects_slash_in_topic() {
  run_frame spawn shell a/b
  assert_status 2
  assert_contains "$OUT" "no slashes"
}

test_rejects_unknown_argument() {
  run_frame spawn shell $TNAME --bogus
  assert_status 2
  assert_contains "$OUT" "unknown argument '--bogus'"
}

test_rejects_non_numeric_timeout() {
  run_frame spawn shell $TNAME --timeout soon
  assert_status 2
  assert_contains "$OUT" "--timeout needs a positive integer"
}

test_refuses_live_topic_before_opening_a_window() {
  # A live frame (socket answering FrameInfo via its .info companion) already
  # owns the topic → refused, and neither launch path may ever have fired.
  export FAKE_OPEN_LOG="$SANDBOX/open.log"
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
  _mksock "$FRAME_RUNDIR/other-$TNAME.nvim"
  print -r -- "other	$TNAME		" > "$FRAME_RUNDIR/other-$TNAME.nvim.info"
  run_frame spawn shell $TNAME
  assert_status 1
  assert_contains "$OUT" "already live"
  assert_file_absent "$FAKE_OPEN_LOG"
  assert_file_absent "$FAKE_OSASCRIPT_LOG"
}

test_happy_path_opens_tab_and_reports_up() {
  _spawn_env
  _plant_booted_worker
  run_frame spawn shell $TNAME
  assert_status 0
  assert_contains "$OUT" "spawned tab for shell/$TNAME"
  assert_contains "$OUT" "shell/$TNAME is up"
  local log="$(<$FAKE_OSASCRIPT_LOG)"
  assert_contains "$log" "/bin/zsh -ic"
  assert_contains "$log" "frame shell $TNAME"
  # The bootstrap must chain the tab closer — scripted surfaces never
  # auto-close, the worker's shell closes its own tab once the frame exits.
  assert_contains "$log" "frame spawn close-tab $TNAME"
  assert_not_contains "$log" "FRAME_EPHEMERAL"
  # The surface ids are recorded for focus/close-tab, and the workers window
  # persists as a WINDOW+TAB pair — reuse validates both, so a recycled
  # window id alone can never pull workers into an unrelated window.
  assert_eq "$(<$FRAME_RUNDIR/shell-$TNAME.nvim.gtab)" "fake-win fake-tab"
  assert_eq "$(<$FRAME_WORKERS_WINDOW)" "fake-win fake-tab"
}

test_ephemeral_rides_into_the_bootstrap() {
  # --ephemeral must reach the worker as FRAME_EPHEMERAL=1 in the tab's
  # bootstrap command — the frame is born ephemeral; its reply router reads the
  # env and self-reaps after routing its first reply home.
  _spawn_env
  _plant_booted_worker
  run_frame spawn shell $TNAME --ephemeral
  assert_status 0
  assert_contains "$OUT" "shell/$TNAME is up"
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "FRAME_EPHEMERAL=1 "
}

test_no_dictionary_falls_back_to_open() {
  # osascript yielding no ids (Ghostty <1.3, script error) → the legacy
  # separate-instance launch, and no surface recording is written.
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
  export FAKE_OPEN_LOG="$SANDBOX/open.log"
  _plant_booted_worker
  run_frame spawn shell $TNAME
  assert_status 0
  assert_contains "$OUT" "AppleScript launch unavailable"
  assert_contains "$OUT" "spawned window for shell/$TNAME"
  assert_contains "$OUT" "shell/$TNAME is up"
  local log="$(<$FAKE_OPEN_LOG)"
  assert_contains "$log" "-na Ghostty.app --args --quit-after-last-window-closed=true -e zsh -ic"
  assert_contains "$log" "frame shell $TNAME"
  assert_file_absent "$FRAME_RUNDIR/shell-$TNAME.nvim.gtab"
}

test_close_tab_closes_recorded_tab() {
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
  print -r -- "w-1 t-1" > "$FRAME_RUNDIR/shell-$TNAME.nvim.gtab"
  run_frame spawn close-tab $TNAME
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - w-1 t-1"
  assert_file_absent "$FRAME_RUNDIR/shell-$TNAME.nvim.gtab"
}

test_close_tab_without_recording_is_silent() {
  # No recording (legacy window, hand-booted frame) → clean no-op.
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
  run_frame spawn close-tab $TNAME
  assert_status 0
  assert_eq "$OUT" ""
  assert_file_absent "$FAKE_OSASCRIPT_LOG"
}

test_close_tab_requires_topic() {
  run_frame spawn close-tab
  assert_status 2
  assert_contains "$OUT" "usage: frame spawn close-tab [NAME/]TOPIC"
}

test_boot_timeout_exits_3() {
  export FAKE_OPEN_LOG="$SANDBOX/open.log"
  # no socket ever appears → the poll runs out
  run_frame spawn shell $TNAME --timeout 1
  assert_status 3
  assert_contains "$OUT" "didn't come up within 1s"
}

test_not_ready_session_times_out() {
  export FAKE_OPEN_LOG="$SANDBOX/open.log"
  _mksock "$FRAME_RUNDIR/shell-$TNAME.nvim"   # socket up, but no .ready — mid-boot
  run_frame spawn shell $TNAME --timeout 1
  assert_status 3
  assert_contains "$OUT" "didn't come up within 1s"
}

test_req_outside_a_frame_is_refused() {
  run_frame spawn shell $TNAME --req "compute 2+2"
  assert_status 1
  assert_contains "$OUT" "must be run from inside a frame"
}

test_req_is_sent_once_ready() {
  in_head
  export FAKE_OPEN_LOG="$SANDBOX/open.log"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  # FrameReady is case-matched first (booted worker); the --req then lands as a
  # broker submit carrying a remote return address to this frame.
  _plant_booted_worker
  run_frame spawn shell $TNAME --req "compute 2+2"
  assert_status 0
  assert_contains "$OUT" "shell/$TNAME is up"
  assert_contains "$OUT" "sent to shell/$TNAME"
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameBrokerSubmit('compute 2+2', 'remote:$TNAME/head')"
}

test_worker_name_survives_checkout_config() {
  # Regression: run spawn from inside a git checkout whose .frame/config.sh
  # assigns NAME (frame_self_identity sources it for the --req return address).
  # That assignment must not redirect the readiness poll or the req target away
  # from shell/TOPIC — it once did, and spawn polled a socket that never appears.
  export FAKE_OPEN_LOG="$SANDBOX/open.log"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  _plant_booted_worker
  make_repo "checkout-$TNAME"
  write_config <<'EOF'
NAME=stompy
EOF
  run_frame spawn shell $TNAME --req "compute 2+2" --timeout 2
  assert_status 0
  assert_contains "$OUT" "shell/$TNAME is up"
  assert_contains "$OUT" "sent to shell/$TNAME"
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameBrokerSubmit('compute 2+2', 'remote:stompy/main')"
}

run_tests "$0"
