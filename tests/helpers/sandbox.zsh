# Per-test sandbox lifecycle. Sourced by harness.zsh; sandbox_up runs inside
# each test's subshell so every export/cd dies with the test.
#
# Isolation guarantees:
#   - all filesystem work happens under a mktemp dir ($SANDBOX)
#   - HOME is redirected into the sandbox, with a self-contained gitconfig,
#     so git never reads (or writes) the real user config
#   - the stubs dir is PATH-prepended: nvim/docker/open become tripwires and
#     lsof becomes deterministic
#   - $TNAME is unique per test, keeping wt.sh's hardcoded /tmp/$NAME-$TOPIC.*
#     paths clear of any real frame session

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
  unset FAKE_NVIM_LOG FAKE_BUSY_PORTS FAKE_OSASCRIPT_LOG FAKE_NVIM_EXPR_RESULT \
        FAKE_OSASCRIPT_RESULT
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
        FRAME_CLAUDE_FLAGS
  cd "$SANDBOX"
}

sandbox_down() {
  cd /
  [[ -n "${SANDBOX:-}" ]] && rm -rf "$SANDBOX"
  [[ -n "${TNAME:-}" ]] && rm -f /tmp/$TNAME-*.teardown.log(N) \
                                 /tmp/*-$TNAME.nvim(N) /tmp/$TNAME-*.nvim(N) \
                                 /tmp/*-$TNAME.nvim.info(N) /tmp/$TNAME-*.nvim.info(N) \
                                 /tmp/*-$TNAME.prompt(N) /tmp/$TNAME-*.prompt(N)
  return 0
}
