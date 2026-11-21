#!/usr/bin/env zsh
# frame shell — casual frames in the current dir (or -C DIR), no branch.
# The PATH-stubbed nvim records what the editor launch would have seen.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

test_shell_boots_in_cwd() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/w/scratch" && cd "$SANDBOX/w/scratch"
  run_frame shell jam
  assert_status 0
  local log=$(<$FAKE_NVIM_LOG)
  assert_contains "$log" "argv: -S $FRAME_CHECKOUT/layouts/session.lua"
  assert_contains "$log" "cwd: $SANDBOX/w/scratch"
  assert_contains "$log" "FRAME_NAME=shell"
  assert_contains "$log" "FRAME_TOPIC=jam"
  assert_contains "$log" "FRAME_SHELL_DIR=$SANDBOX/w/scratch"
  assert_contains "$log" "FRAME_BUFFERS=claude local"
  # empty on purpose: no primary checkout → the layout swaps in the
  # shell-frame :FrameDown (quit only) instead of the worktree one
  assert_contains "$log" "FRAME_MAIN_WT="$'\n'
  # no git hint outside a checkout, and nothing written into the dir
  assert_not_contains "$OUT" "git checkout"
  assert_dir_absent "$SANDBOX/w/scratch/.claude"
}

test_shell_refuses_topic_live_elsewhere() {
  # A live frame in another project already carries this topic — a shell frame
  # with the same topic would make `frame focus jam` ambiguous, so refuse it
  # before booting. The nvim stub answers FrameInfo() from the
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
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_shell_refuses_home_dir() {
  # Booting in ~ would give claude your whole home as its cwd.
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  cd "$HOME"
  run_frame shell jam
  assert_status 1
  assert_contains "$OUT" "refusing to boot in your home dir"
  assert_file_absent "$FAKE_NVIM_LOG"
}

# Claude's hooks come from frame's claude/hooks.json via --settings, so a shell
# dir is never written: no .claude/ appears, and an existing one is untouched.
test_shell_passes_hooks_and_writes_no_settings() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/frames/jam" && cd "$SANDBOX/frames/jam"
  run_frame shell jam
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_CLAUDE_FLAGS=--settings $HOME/.local/share/frame/claude-hooks.json"
  assert_dir_absent "$SANDBOX/frames/jam/.claude"
}

test_shell_leaves_existing_claude_settings_alone() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/frames/jam/.claude" && cd "$SANDBOX/frames/jam"
  print -r -- '{"custom": true}' > "$SANDBOX/frames/jam/.claude/settings.json"
  run_frame shell jam
  assert_status 0
  assert_eq "$(<$SANDBOX/frames/jam/.claude/settings.json)" '{"custom": true}'
}

test_shell_rejects_extra_args_and_flags() {
  # frame shell takes exactly one TOPIC. Two args — or a leading-dash arg that
  # would read as a flag — is a usage error.
  run_frame shell a b
  assert_status 2
  assert_contains "$OUT" "Usage: frame shell [-C DIR] TOPIC"
  run_frame shell -x
  assert_status 2
  assert_contains "$OUT" "Usage: frame shell [-C DIR] TOPIC"
}

test_shell_requires_topic() {
  # Booting fresh, no minting, no guessing from the dir name: the topic is the
  # frame's handle. (Only a resume names itself after its dir — see below.)
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame shell
  assert_status 2
  assert_contains "$OUT" "Usage: frame shell [-C DIR] TOPIC"
  mkdir -p "$SANDBOX/g/foobar"
  run_frame shell -C "$SANDBOX/g/foobar"
  assert_status 2
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_shell_rejects_slash_in_topic() {
  run_frame shell nested/topic
  assert_status 2
  assert_contains "$OUT" "no slashes"
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
  # Any dir works for -C — no prep needed.
  mkdir -p "$1"
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
  run_frame shell -C foobar jam
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_SHELL_DIR=$SANDBOX/g/foobar"
}

test_shell_C_refuses_missing_dir() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame shell -C "$SANDBOX/nope" jam
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

test_shell_C_boots_any_dir_and_writes_nothing() {
  # -C never writes into DIR, and needs nothing in it: a bare dir boots, with
  # claude's hooks passed by flag.
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/g/foobar"
  run_frame shell -C "$SANDBOX/g/foobar" jam
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_CLAUDE_FLAGS=--settings $HOME/.local/share/frame/claude-hooks.json"
  assert_dir_absent "$SANDBOX/g/foobar/.claude"
}

test_shell_C_works_in_a_git_checkout() {
  # A git repo is fine — with a one-line note that frame wt isolates instead.
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  make_repo
  run_frame shell -C "$REPO" jam
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "cwd: $REPO"
  assert_contains "$OUT" "is a git checkout"
}

test_shell_C_defaults_to_claude_local_without_config() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  _wire_dir "$SANDBOX/g/foobar"
  run_frame shell -C "$SANDBOX/g/foobar" foobar
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
  run_frame shell -C "$SANDBOX/g/foobar" foobar
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
  run_frame shell -C "$SANDBOX/g/foobar" foobar
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_BUFFERS=claude"$'\n'
}

test_shell_honors_config_without_C() {
  # A cwd shell reads its dir's .frame config the same way.
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/frames/jam/.frame" && cd "$SANDBOX/frames/jam"
  print -r -- 'BUFFERS=(claude local server)' > "$SANDBOX/frames/jam/.frame/config.sh"
  run_frame shell jam
  assert_status 0
  assert_contains "$OUT" "buffers: claude local server"
  local log=$(<$FAKE_NVIM_LOG)
  assert_contains "$log" "FRAME_BUFFERS=claude local server"
  assert_contains "$log" "FRAME_TOPIC=jam"
  assert_contains "$log" "cwd: $SANDBOX/frames/jam"
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
  # note must point back at that dir.
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

# ── resuming a past session: --resume ID / --find WORDS ──────────────────────

_session() {  # _session ID CWD TEXT — plant a transcript of a message typed in CWD
  local pdir="$HOME/.claude/projects/${2//[^A-Za-z0-9]/-}"
  mkdir -p "$pdir"
  jq -nc --arg c "$2" --arg t "$3" \
    '{type:"user", cwd:$c, timestamp:"2026-11-03T10:00:00Z", entrypoint:"cli", message:{role:"user", content:$t}}' \
    >> "$pdir/$1.jsonl"
}

test_shell_resume_boots_in_the_sessions_dir() {
  # claude --resume only finds a session from its own dir, so boot there —
  # wherever frame shell was run from.
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  local docs="${${:-$SANDBOX/w/docs}:A}"
  mkdir -p "$docs" "$SANDBOX/w/elsewhere" && cd "$SANDBOX/w/elsewhere"
  _session abc-123 "$docs" "my 2023 tax return"
  run_frame shell taxes --resume abc-123
  assert_status 0
  local log=$(<$FAKE_NVIM_LOG)
  assert_contains "$log" "cwd: $docs"
  assert_contains "$log" "FRAME_SHELL_DIR=$docs"
  assert_contains "$log" "--resume abc-123"
}

test_shell_resume_with_C_bridges_the_transcript() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  local docs="${${:-$SANDBOX/w/docs}:A}" other="${${:-$SANDBOX/w/other}:A}"
  mkdir -p "$docs" "$other"
  _session abc-123 "$docs" "my 2023 tax return"
  run_frame shell taxes --resume=abc-123 -C "$other"
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "cwd: $other"
  assert_file_exists "$HOME/.claude/projects/${other//[^A-Za-z0-9]/-}/abc-123.jsonl"
}

test_shell_resume_refuses_unknown_bad_or_gone() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame shell taxes --resume nope-000
  assert_status 1
  assert_contains "$OUT" "no transcript for session nope-000"
  run_frame shell taxes --resume 'x;rm'
  assert_status 2
  assert_contains "$OUT" "not a valid session id"
  _session gone-1 "$SANDBOX/w/deleted" "hi"
  run_frame shell taxes --resume gone-1
  assert_status 1
  assert_contains "$OUT" "which is gone"
  assert_contains "$OUT" "-C DIR"
  run_frame shell taxes --resume
  assert_status 2
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_shell_resume_and_find_are_exclusive() {
  run_frame shell taxes --resume a-1 --find tax
  assert_status 2
  assert_contains "$OUT" "mutually exclusive"
}

test_shell_find_without_tty_lists_matches() {
  # No tty to pick on (an agent, a script): list the hits and how to resume.
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  local docs="${${:-$SANDBOX/w/docs}:A}"
  mkdir -p "$docs"
  _session tax-1 "$docs" "my 2023 tax return"
  _session syn-2 "$docs" "fix this syntax error"
  run_frame shell taxes --find "tax 2023" < /dev/null
  assert_status 1
  assert_contains "$OUT" "tax-1"
  assert_contains "$OUT" "my 2023 tax return"
  assert_not_contains "$OUT" "syn-2"
  assert_contains "$OUT" "--resume ID"
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_shell_find_no_match() {
  _session tax-1 "$SANDBOX/w/docs" "my 2023 tax return"
  run_frame shell taxes --find zebra < /dev/null
  assert_status 1
  assert_contains "$OUT" "no resumable past session"
}

test_shell_recent_without_tty_lists_sessions() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  local docs="${${:-$SANDBOX/w/docs}:A}"
  mkdir -p "$docs"
  _session tax-1 "$docs" "my 2023 tax return"
  _session syn-2 "$docs" "fix this syntax error"
  run_frame shell taxes --recent < /dev/null
  assert_status 1
  assert_contains "$OUT" "tax-1"
  assert_contains "$OUT" "syn-2"
  assert_contains "$OUT" "fix this syntax error"
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_shell_resume_without_topic_names_it_after_the_dir() {
  # Resuming, TOPIC is optional: the frame takes the session dir's name.
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  local docs="${${:-$SANDBOX/w/my docs}:A}"
  mkdir -p "$docs" "$SANDBOX/w/elsewhere" && cd "$SANDBOX/w/elsewhere"
  _session abc-123 "$docs" "my 2023 tax return"
  run_frame shell --resume abc-123
  assert_status 0
  local log=$(<$FAKE_NVIM_LOG)
  assert_contains "$log" "FRAME_TOPIC=my-docs"$'\n'
  assert_contains "$log" "cwd: $docs"
  assert_contains "$OUT" "topic: my-docs"
}

test_shell_resume_without_topic_skips_a_live_topic() {
  # The dir's name is taken by a live frame → -2, never a collision.
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  local docs="${${:-$SANDBOX/w/docs}:A}"
  mkdir -p "$docs"
  _session abc-123 "$docs" "my 2023 tax return"
  local sock="$FRAME_RUNDIR/$TNAME-other.nvim"
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$sock"
  printf '%s\t%s\t%s\t%s\n' shell docs '' '' > "$sock.info"
  run_frame shell --resume abc-123
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_LOG)" "FRAME_TOPIC=docs-2"$'\n'
}

test_shell_recent_without_topic_lists_sessions() {
  _session tax-1 "${${:-$SANDBOX/w/docs}:A}" "my 2023 tax return"
  mkdir -p "$SANDBOX/w/docs"
  run_frame shell --recent < /dev/null
  assert_status 1
  assert_contains "$OUT" "tax-1"
  assert_not_contains "$OUT" "Usage:"
}

_open_session() {  # _open_session ID [ENV…] — a live stand-in claude for session ID; echoes its pid
  # jq waiting on a fifo it holds open (<>), not sleep: macOS hides an
  # Apple-signed binary's env, and the in-a-frame case reads FRAME_NAME/TOPIC.
  mkdir -p "$HOME/.claude/sessions"
  local hold="$HOME/hold-$1"
  [[ -p "$hold" ]] || mkfifo "$hold"
  env "${@:2}" jq -R . <>"$hold" >/dev/null 2>&1 &
  print -r -- "{\"sessionId\":\"$1\"}" > "$HOME/.claude/sessions/$!.json"
  print -r -- $!
}

test_shell_recent_marks_open_sessions() {
  local docs="${${:-$SANDBOX/w/docs}:A}"
  mkdir -p "$docs"
  _session open-1 "$docs" "the open one"
  _session shut-2 "$docs" "the closed one"
  local pid=$(_open_session open-1)
  run_frame shell --recent < /dev/null
  kill $pid 2>/dev/null
  assert_contains "$OUT" "open-1  ● "
  assert_not_contains "$OUT" "shut-2  ● "
}

test_shell_resume_open_session_outside_a_frame_refuses() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  local docs="${${:-$SANDBOX/w/docs}:A}"
  mkdir -p "$docs"
  _session open-1 "$docs" "the open one"
  local pid=$(_open_session open-1)
  run_frame shell --resume open-1
  kill $pid 2>/dev/null
  assert_status 1
  assert_contains "$OUT" "already open (claude pid $pid"
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_shell_resume_open_session_in_a_frame_switches_to_it() {
  [[ $OSTYPE == darwin* ]] || { skip "focus rides AppleScript — macOS-only"; return }
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  local docs="${${:-$SANDBOX/w/docs}:A}"
  mkdir -p "$docs"
  _session open-1 "$docs" "the open one"
  local sock="$FRAME_RUNDIR/$TNAME-cow.nvim"
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$sock"
  printf '%s\t%s\t%s\t%s\n' shell cowpoke '' '' > "$sock.info"
  local pid=$(_open_session open-1 FRAME_NAME=shell FRAME_TOPIC=cowpoke)
  # the osascript stub stands in for AppleScript's answer (see test_focus.zsh)
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log" FAKE_OSASCRIPT_RESULT=raised
  sleep 0.2
  run_frame shell --resume open-1
  kill $pid 2>/dev/null
  assert_status 0
  assert_contains "$OUT" "already open in frame shell/cowpoke — switching to it"
  assert_contains "$OUT" "focused shell/cowpoke"
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - shell cowpoke"
  assert_file_absent "$FAKE_NVIM_LOG"
}

test_shell_recent_is_exclusive_with_find() {
  run_frame shell taxes --recent --find tax
  assert_status 2
  assert_contains "$OUT" "mutually exclusive"
}

run_tests "$0"
