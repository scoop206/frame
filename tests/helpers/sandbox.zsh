# Per-test sandbox lifecycle. Sourced by harness.zsh; sandbox_up runs inside
# each test's subshell so every export/cd dies with the test.
#
# Isolation guarantees:
#   - all filesystem work happens under a mktemp dir ($SANDBOX)
#   - HOME is redirected into the sandbox, with a self-contained gitconfig,
#     so git never reads (or writes) the real user config
#   - the stubs dir is PATH-prepended: nvim/docker/open become tripwires and
#     lsof becomes deterministic
#   - FRAME_RUNDIR is a private per-test dir, so this test's sockets / stamps /
#     logs never touch (or see) a real frame session's runtime files — and the
#     whole tree is removed with one rm -rf on teardown. Kept short (in /tmp, not
#     under the deep $SANDBOX path) so planted unix socket paths stay under the
#     ~103-char sun_path limit.
#   - $TNAME is unique per test, so names/topics still can't collide across
#     concurrent tests sharing the machine

sandbox_up() {
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/frame-test.XXXXXX")
  # :A resolves symlinks (macOS /var → /private/var) so paths compare equal
  # to what git rev-parse --show-toplevel reports.
  export SANDBOX=${SANDBOX:A}
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_NOSYSTEM=1
  cat > "$HOME/.gitconfig" <<'EOF'
[user]
	name = Frame Tests
	email = tests@frame.invalid
[init]
	defaultBranch = main
[protocol "file"]
	allow = always
EOF
  export PATH="$TESTS_DIR/stubs:$PATH"
  export TNAME="proj$RANDOM$RANDOM"
  # Private runtime dir for this test — every frame command and every planted
  # socket resolves here instead of the shared /tmp/frame, so tests are isolated
  # from each other and from real sessions. Short path (see sandbox note above).
  export FRAME_RUNDIR="/tmp/frame-test.$TNAME"
  mkdir -m 700 -p "$FRAME_RUNDIR"
  # Keep frame_open_window's workers-window recording out of the real /tmp —
  # a test run must never clobber (or read) a live session's window id.
  export FRAME_WORKERS_WINDOW="$SANDBOX/frame-workers.window"
  unset FAKE_NVIM_LOG FAKE_BUSY_PORTS FAKE_OSASCRIPT_LOG FAKE_NVIM_EXPR_RESULT \
        FAKE_OSASCRIPT_RESULT FAKE_NVIM_EXPR_LOG FAKE_NVIM_EXPR_EMPTY_POLLS \
        FAKE_NVIM_POLL_COUNT_FILE FAKE_OPEN_LOG \
        FAKE_NVIM_BUFTYPE FAKE_NVIM_BUFLINES_FILE
  # The suite may itself be running inside a frame session, whose exports
  # (PORT_PREFIX, FRAME_*, SERVER_CMD, <PREFIX>_*_PORT, …) would leak into
  # frame_load_config's ${VAR:=default} lines. Strip them. FRAME_ROOT is
  # deliberately spared: bin/frame re-exports its own, and unit test files
  # set it explicitly before sourcing lib/helpers.sh.
  local _v
  for _v in ${(M)${(k)parameters}:#[A-Z0-9_]##_(API|VITE|HMR)_PORT}; do unset "$_v"; done
  unset NAME PORT_PREFIX BUFFERS SERVER_CMD PORT WT_LINKS \
        API_PORT VITE_PORT HMR_PORT FRAME_SHELL_HOME \
        FRAME_NAME FRAME_TOPIC FRAME_MAIN_WT FRAME_VITE_PORT FRAME_BUFFERS \
        FRAME_CLAUDE_FLAGS \
        NVIM  # a suite run from inside a frame's nvim must not trip frame_guard_nested
  cd "$SANDBOX"
}

sandbox_down() {
  cd /
  [[ -n "${SANDBOX:-}" ]] && rm -rf "$SANDBOX"
  # Every runtime file this test created — sockets, .info/.hang/.ready stubs,
  # .gtab, .prompt, .teardown.log — lives under the private FRAME_RUNDIR, so one
  # rm -rf reaps them all (no per-suffix glob sweep to keep in sync).
  [[ -n "${FRAME_RUNDIR:-}" ]] && rm -rf "$FRAME_RUNDIR"
  return 0
}
