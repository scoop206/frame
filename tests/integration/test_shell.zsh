#!/usr/bin/env zsh
# frame shell — casual frames: a generated directory, no git anywhere.
# The PATH-stubbed nvim records what the editor launch would have seen.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

test_shell_creates_dir_and_boots() {
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame shell jam
  assert_status 0
  assert_dir_exists "$SANDBOX/frames/jam"
  local log=$(<$FAKE_NVIM_LOG)
  assert_contains "$log" "argv: -S $FRAME_CHECKOUT/layouts/session.lua"
  assert_contains "$log" "cwd: $SANDBOX/frames/jam"
  assert_contains "$log" "FRAME_NAME=shell"
  assert_contains "$log" "FRAME_TOPIC=jam"
  assert_contains "$log" "FRAME_BUFFERS=claude local"
  # empty on purpose: no primary checkout → the layout swaps in the
  # shell-frame :FrameDown (dir delete) instead of the worktree one
  assert_contains "$log" "FRAME_MAIN_WT="$'\n'
  # and no git repo was conjured up around the topic dir
  ! git -C "$SANDBOX/frames/jam" rev-parse --show-toplevel >/dev/null 2>&1 \
    || fail "topic dir unexpectedly inside a git repo"
}

test_shell_refuses_topic_live_elsewhere() {
  # A live frame in another project already carries this topic — a shell frame
  # with the same topic would make `frame focus jam` ambiguous, so refuse it
  # before the topic dir is created. The nvim stub answers FrameInfo() from the
  # planted companion; socket carries $TNAME so sandbox_down sweeps it.
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  local sock="$FRAME_RUNDIR/$TNAME-other.nvim"
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$sock"
  printf '%s\t%s\t%s\t%s\n' flipnem jam 5173 '' > "$sock.info"
  run_frame shell jam
  assert_status 1
  assert_contains "$OUT" "is already live"
  assert_dir_absent "$SANDBOX/frames/jam"
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_shell_home_defaults_under_home() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame shell jam
  assert_status 0
  assert_dir_exists "$HOME/frames/jam"
}

test_shell_wires_claude_hooks() {
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame shell jam
  assert_status 0
  assert_contains "$OUT" "wired claude hooks"
  local settings="$SANDBOX/frames/jam/.claude/settings.json"
  assert_file_exists "$settings"
  assert_contains "$(<$settings)" "frame notify"
  assert_contains "$(<$settings)" "frame status --prompt"
}

test_shell_leaves_existing_claude_settings_alone() {
  # Covers both a user-customized file and a dir from before hook-wiring
  # existed once it's been written: later boots must not clobber it.
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/frames/jam/.claude"
  print -r -- '{"custom": true}' > "$SANDBOX/frames/jam/.claude/settings.json"
  run_frame shell jam
  assert_status 0
  assert_not_contains "$OUT" "wired claude hooks"
  assert_eq "$(<$SANDBOX/frames/jam/.claude/settings.json)" '{"custom": true}'
}

test_shell_refreshes_stale_frame_hooks() {
  # A dir wired by an older frame carries 'frame notify' but not 'frame reply'
  # (the hook set grew). Reboot must refresh it — a stale file means a worker's
  # reply never routes home — while test_shell_leaves_existing_claude_settings_
  # alone pins the flip side: no frame fingerprint → user file → untouched.
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/frames/jam/.claude"
  print -r -- '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"frame notify >/dev/null 2>&1 || true"}]}]}}' \
    > "$SANDBOX/frames/jam/.claude/settings.json"
  run_frame shell jam
  assert_status 0
  assert_contains "$OUT" "refreshed claude hooks"
  local settings="$SANDBOX/frames/jam/.claude/settings.json"
  assert_contains "$(<$settings)" "frame reply"
  assert_contains "$(<$settings)" "frame notify"
  assert_contains "$(<$settings)" "frame status --prompt"
}

test_shell_refreshes_pre_prompt_status_hook() {
  # The full hook set as written before `frame status --prompt` existed:
  # UserPromptSubmit → bare `frame status`. Recognizably frame-authored, but
  # its frames never show "working" — a reboot must rewrite it.
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/frames/jam/.claude"
  print -r -- '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"frame notify >/dev/null 2>&1 || true"},{"type":"command","command":"frame reply >/dev/null 2>&1 || true"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"frame status >/dev/null 2>&1 || true"}]}]}}' \
    > "$SANDBOX/frames/jam/.claude/settings.json"
  run_frame shell jam
  assert_status 0
  assert_contains "$OUT" "refreshed claude hooks"
  assert_contains "$(<$SANDBOX/frames/jam/.claude/settings.json)" "frame status --prompt"
}

test_shell_reuses_existing_dir() {
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame shell jam
  run_frame shell jam
  assert_status 0
  assert_contains "$OUT" "already exists — reusing"
}

test_shell_rejects_extra_args_and_flags() {
  # frame shell takes at most one TOPIC. Two args — or a leading-dash arg that
  # would read as a flag — is a usage error. A BARE `frame shell` is NOT: it
  # mints or infers a topic (see test_shell_no_arg_mints_dated_frame).
  run_frame shell a b
  assert_status 2
  assert_contains "$OUT" "Usage: frame shell [-C DIR] [TOPIC]"
  run_frame shell -x
  assert_status 2
  assert_contains "$OUT" "Usage: frame shell [-C DIR] [TOPIC]"
}

test_shell_no_arg_mints_dated_frame() {
  # No TOPIC and nowhere to infer one (the sandbox cwd isn't a shell-frame dir)
  # → a fresh dated scratch topic is minted and booted, so a bare `frame shell`
  # always lands you somewhere new. The old contract erred here; commit 24d7a7e
  # made TOPIC optional (reuse the cwd if it's a shell frame dir, else mint).
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame shell
  assert_status 0
  assert_contains "$OUT" "new scratch frame '"
  local log=$(<$FAKE_NVIM_LOG)
  assert_contains "$log" "FRAME_NAME=shell"
  assert_contains "$log" "FRAME_TOPIC=$(date +%Y-%m-%d)-"
}

test_shell_rejects_slash_in_topic() {
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  run_frame shell nested/topic
  assert_status 2
  assert_contains "$OUT" "no slashes"
  assert_dir_absent "$SANDBOX/frames/nested"
}

test_status_in_shell_frame_uses_session_env() {
  # A shell frame's buffers aren't in a git repo; status must fall back to
  # the session's FRAME_NAME/FRAME_TOPIC. No nvim runs in tests, so the
  # proof is the error naming the right socket rather than a git failure.
  # $TNAME keeps the $FRAME_RUNDIR/shell-<topic>.nvim probe clear of real sessions.
  mkdir -p "$SANDBOX/frames/$TNAME"
  cd "$SANDBOX/frames/$TNAME"
  export FRAME_NAME=shell FRAME_TOPIC=$TNAME
  run_frame status busy
  assert_status 1
  assert_contains "$OUT" "no frame session for shell/$TNAME"
  assert_not_contains "$OUT" "not inside a git repository"
}

test_notify_in_shell_frame_banners_with_session_identity() {
  mkdir -p "$SANDBOX/frames/$TNAME"
  cd "$SANDBOX/frames/$TNAME"
  export FRAME_NAME=shell FRAME_TOPIC=$TNAME
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
  run_frame notify
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - task complete shell [ $TNAME ]"
}

test_notify_outside_any_frame_still_exits_0() {
  # Hook-safe contract: no repo, no session env — notify must not fail.
  mkdir -p "$SANDBOX/nowhere"
  cd "$SANDBOX/nowhere"
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
  run_frame notify
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - task complete ? [ ? ]"
}

_plant_shell_socket() {
  # Stand in for a live shell-frame session: a real unix socket at the path
  # `frame shell -d` probes ($FRAME_RUNDIR/shell-<topic>.nvim). The nvim stub
  # ignores it and just logs the --remote-send it receives.
  local sock="$FRAME_RUNDIR/shell-$1.nvim"
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$sock"
}

test_shell_down_quits_session_and_keeps_dir() {
  # frame shell -d TOPIC: a shell has no branch/worktree, so teardown is just a
  # quit — send :qa! to the session's socket and leave the scratch dir alone.
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/frames/jam"
  _plant_shell_socket jam
  run_frame shell -d jam
  assert_status 0
  assert_contains "$OUT" "quit shell frame jam"
  # the quit went to nvim as a mode-agnostic :qa! over the right socket…
  local log=$(<$FAKE_NVIM_LOG)
  assert_contains "$log" "--server $FRAME_RUNDIR/shell-jam.nvim"
  assert_contains "$log" "--remote-send <Cmd>qa!<CR>"
  # …and the disposable dir is kept for a later `frame shell jam`
  assert_dir_exists "$SANDBOX/frames/jam"
}

test_shell_down_infers_topic_from_cwd() {
  # No TOPIC: standing in a shell frame's own dir, its name is the topic.
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/frames/jam"
  _plant_shell_socket jam
  cd "$SANDBOX/frames/jam"
  run_frame shell -d
  assert_status 0
  assert_contains "$OUT" "quit shell frame jam"
  assert_contains "$(<$FAKE_NVIM_LOG)" "--server $FRAME_RUNDIR/shell-jam.nvim"
}

test_shell_down_infers_topic_from_session_env() {
  # No TOPIC and cwd isn't a shell dir, but the session identity is exported
  # (a shell frame's claude carries FRAME_NAME=shell / FRAME_TOPIC) — use it.
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  export FRAME_NAME=shell FRAME_TOPIC=jam
  _plant_shell_socket jam
  cd "$SANDBOX"
  run_frame shell -d
  assert_status 0
  assert_contains "$OUT" "quit shell frame jam"
}

test_shell_down_not_running_is_benign() {
  # No live socket → nothing to quit. Idempotent teardown: succeed with a note,
  # not an error (a claude that already went down shouldn't see a failure).
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  run_frame shell -d jam
  assert_status 0
  assert_contains "$OUT" "not running"
}

test_shell_down_no_topic_outside_frame_errors() {
  # No TOPIC, no session env, cwd isn't a shell dir → can't tell what to quit.
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  mkdir -p "$SANDBOX/nowhere"
  cd "$SANDBOX/nowhere"
  run_frame shell -d
  assert_status 1
  assert_contains "$OUT" "Usage: frame shell -d"
}

test_shell_down_accepts_force_noop() {
  # -f is accepted for muscle-memory parity with `frame wt -d -f`; a scratch
  # dir has no git safeguards for it to override, so it changes nothing.
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  _plant_shell_socket jam
  run_frame shell -d -f jam
  assert_status 0
  assert_contains "$OUT" "quit shell frame jam"
}

test_shell_down_rejects_second_topic() {
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  run_frame shell -d a b
  assert_status 2
  assert_contains "$OUT" "more than one topic given"
}

# ── frame shell -C DIR ────────────────────────────────────────────────────────

_wire_dir() {
  # A dir prepped the way the -C refusal tells you to: frame init --type=shell.
  mkdir -p "$1"
  ( cd "$1" && run_frame init --type=shell ) >/dev/null
}

test_shell_C_boots_in_dir_with_dirname_topic() {
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  _wire_dir "$SANDBOX/g/foobar"
  run_frame shell -C "$SANDBOX/g/foobar"
  assert_status 0
  assert_contains "$OUT" "using 'foobar' from $SANDBOX/g/foobar"
  local log=$(<$FAKE_NVIM_LOG)
  assert_contains "$log" "cwd: $SANDBOX/g/foobar"
  assert_contains "$log" "FRAME_NAME=shell"
  assert_contains "$log" "FRAME_TOPIC=foobar"
  assert_contains "$log" "FRAME_SHELL_DIR=$SANDBOX/g/foobar"
  # nothing conjured under the shell home
  assert_dir_absent "$SANDBOX/frames/foobar"
}

test_shell_C_explicit_topic_either_order() {
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  _wire_dir "$SANDBOX/g/foobar"
  run_frame shell -C "$SANDBOX/g/foobar" jam
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_TOPIC=jam"
  rm -f "$FAKE_NVIM_LOG"
  run_frame shell jam -C "$SANDBOX/g/foobar"
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "cwd: $SANDBOX/g/foobar"
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_TOPIC=jam"
}

test_shell_C_resolves_relative_dir() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  _wire_dir "$SANDBOX/g/foobar"
  cd "$SANDBOX/g"
  run_frame shell -C foobar
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_SHELL_DIR=$SANDBOX/g/foobar"
}

test_shell_C_refuses_missing_dir() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame shell -C "$SANDBOX/nope"
  assert_status 1
  assert_contains "$OUT" "no such directory"
  assert_dir_absent "$SANDBOX/nope"
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_shell_C_requires_a_value() {
  run_frame shell -C
  assert_status 2
  assert_contains "$OUT" "-C needs a directory"
}

test_shell_C_refuses_unwired_dir_and_writes_nothing() {
  # -C never writes into DIR: no settings.json → refuse and name the init.
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/g/foobar"
  run_frame shell -C "$SANDBOX/g/foobar"
  assert_status 1
  assert_contains "$OUT" "isn't wired for frame"
  assert_contains "$OUT" "frame init --type=shell"
  assert_not_contains "$OUT" "--force"
  assert_dir_absent "$SANDBOX/g/foobar/.claude"
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_shell_C_refuses_stale_hooks_and_leaves_file_alone() {
  # A settings.json without (all of) frame's hooks — the user's own, or stale
  # frame wiring. Either way -C doesn't touch it; it points at --force.
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/g/foobar/.claude"
  print -r -- '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"frame notify >/dev/null 2>&1 || true"}]}]}}' \
    > "$SANDBOX/g/foobar/.claude/settings.json"
  local before=$(cksum "$SANDBOX/g/foobar/.claude/settings.json")
  run_frame shell -C "$SANDBOX/g/foobar"
  assert_status 1
  assert_contains "$OUT" "missing frame's claude hooks"
  assert_contains "$OUT" "frame init --type=shell --force"
  assert_eq "$(cksum "$SANDBOX/g/foobar/.claude/settings.json")" "$before" "settings.json was rewritten"
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_shell_C_works_in_a_git_checkout() {
  # A git repo is fine — -C doesn't care what DIR is, only that it's wired.
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  make_repo
  ( cd "$REPO" && run_frame init --type=shell ) >/dev/null
  run_frame shell -C "$REPO" jam
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "cwd: $REPO"
}

test_shell_C_defaults_to_claude_local_without_config() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  _wire_dir "$SANDBOX/g/foobar"
  run_frame shell -C "$SANDBOX/g/foobar"
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_BUFFERS=claude local"$'\n'
}

test_shell_C_honors_project_config_buffers() {
  # DIR's .frame/config.sh picks the buffers, and what they run on comes along:
  # SERVER_CMD and the port scan. Its NAME/DIR can't clobber the shell's own
  # identity or dir.
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  _wire_dir "$SANDBOX/g/foobar"
  mkdir -p "$SANDBOX/g/foobar/.frame"
  cat > "$SANDBOX/g/foobar/.frame/config.sh" <<'EOF'
NAME=foo
DIR=/nowhere
BUFFERS=(claude local server)
SERVER_CMD='cargo run'
API_PORT=3000
EOF
  run_frame shell -C "$SANDBOX/g/foobar"
  assert_status 0
  assert_contains "$OUT" "buffers: claude local server"
  local log=$(<$FAKE_NVIM_LOG)
  assert_contains "$log" "cwd: $SANDBOX/g/foobar"
  assert_contains "$log" "FRAME_NAME=shell"
  assert_contains "$log" "FRAME_TOPIC=foobar"
  assert_contains "$log" "FRAME_SHELL_DIR=$SANDBOX/g/foobar"
  assert_contains "$log" "FRAME_BUFFERS=claude local server"
  assert_contains "$log" "SERVER_CMD=cargo run"
  assert_contains "$log" "FRAME_API_PORT="
  assert_contains "$log" "FOO_API_PORT="
}

test_shell_C_local_config_wins() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  _wire_dir "$SANDBOX/g/foobar"
  mkdir -p "$SANDBOX/g/foobar/.frame/local"
  print -r -- 'BUFFERS=(claude local vite)' > "$SANDBOX/g/foobar/.frame/config.sh"
  print -r -- 'BUFFERS=(claude)' > "$SANDBOX/g/foobar/.frame/local/config.sh"
  run_frame shell -C "$SANDBOX/g/foobar"
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_BUFFERS=claude"$'\n'
}

test_shell_ignores_config_without_C() {
  # A plain ~/frames shell never reads a .frame config — the flag opts in.
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/frames/jam/.frame"
  print -r -- 'BUFFERS=(claude local server)' > "$SANDBOX/frames/jam/.frame/config.sh"
  run_frame shell jam
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_BUFFERS=claude local"$'\n'
}

test_shell_does_not_inherit_worktree_buffer_env() {
  # Booted from inside a worktree frame's terminal: its exported SERVER_CMD /
  # FRAME_VITE_PORT must not ride into the shell frame.
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  export SERVER_CMD='leaked' FRAME_VITE_PORT=5999
  run_frame shell jam
  assert_status 0
  local log=$(<$FAKE_NVIM_LOG)
  assert_not_contains "$log" "leaked"
  assert_not_contains "$log" "FRAME_VITE_PORT=5999"
}

test_shell_down_names_C_reboot_from_inside() {
  # From inside a -C frame (its claude carries FRAME_SHELL_DIR), the teardown
  # note must point back at that dir, not at ~/frames/TOPIC.
  export FRAME_SHELL_HOME="$SANDBOX/frames"
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  export FRAME_NAME=shell FRAME_TOPIC=jam FRAME_SHELL_DIR="$SANDBOX/g/foobar"
  _plant_shell_socket jam
  run_frame shell -d
  assert_status 0
  assert_contains "$OUT" "dir kept: $SANDBOX/g/foobar"
  assert_contains "$OUT" "frame shell -C $SANDBOX/g/foobar jam"
}

test_nested_boot_refused_noninteractively() {
  # $NVIM set = we're inside an existing frame's nvim; a non-tty caller (an
  # agent, a script) gets a refusal, not a hanging y/N prompt.
  export NVIM=$FRAME_RUNDIR/fake-parent.sock
  run_frame shell $TNAME < /dev/null
  assert_status 1
  assert_contains "$OUT" "refusing to boot a frame inside this frame's nvim"
  assert_contains "$OUT" "frame spawn"
}

run_tests "$0"
