#!/usr/bin/env zsh
# frame notify --blocked — the Notification-hook mode: claude paused MID-turn on
# a permission prompt (or an idle/needs-input stall), a state neither Stop nor
# UserPromptSubmit fires for. It sets a "blocked" title status and, unlike the
# bare Stop mode, banners THROUGH the brokered- and quick-turn gates (those
# silence "done" pings; a mid-turn block is exactly when you want interrupting).
# The session mute and global switch still apply. It does, though, honour ONE
# suppressor of its own — the status-gate: the same Notification hook fires an
# idle ping ~60s after a turn ENDS, and that phantom must not repaint a
# finished ("waiting") frame as "blocked". Same shell-frame + live-socket
# fixtures as test_notify_mute.zsh.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

setup_shell_frame() {
  mkdir -p "$SANDBOX/frames/$TNAME"
  cd "$SANDBOX/frames/$TNAME"
  export FRAME_NAME=shell FRAME_TOPIC=$TNAME
  export FAKE_OSASCRIPT_LOG="$SANDBOX/osascript.log"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs.log"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
    "/tmp/shell-$TNAME.nvim"
}

# Plant the live-session answer to FrameInfo() the status-gate reads: the nvim
# stub serves <sock>.info as name<TAB>topic<TAB>port<TAB>status (status last,
# the field the gate inspects). Call after setup_shell_frame.
plant_status() {
  printf '%s\t%s\t%s\t%s\n' shell "$TNAME" '' "$1" > "/tmp/shell-$TNAME.nvim.info"
}

test_blocked_sets_blocked_status() {
  # The title/`frame ls` status flips to "blocked" via FrameSetStatus, so a
  # frame frozen on a permission prompt stops reading as "working".
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_shell_frame
  export FAKE_NVIM_EXPR_RESULT=0   # unmuted
  run_frame notify --blocked
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameSetStatus('blocked')"
}

test_blocked_banners_with_needs_input_text() {
  # The proactive ping carries its own text, distinct from the Stop banner.
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_shell_frame
  export FAKE_NVIM_EXPR_RESULT=0
  run_frame notify --blocked
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - needs your input shell [ $TNAME ]"
}

test_blocked_bypasses_quick_turn_gate() {
  # A fresh prompt stamp suppresses the Stop banner (the human just prompted and
  # is watching) — but a mid-turn block must ping anyway.
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_shell_frame
  export FAKE_NVIM_EXPR_RESULT=0
  touch "/tmp/shell-$TNAME.prompt"
  run_frame notify --blocked
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - needs your input shell [ $TNAME ]"
}

test_blocked_bypasses_brokered_gate_without_consuming_flag() {
  # A brokered turn suppresses the Stop banner, but --blocked banners through it.
  # And it must NOT read-and-clear the brokered flag — the eventual Stop notify
  # still needs to consume it, or that turn would double-banner. Assert the flag
  # RPC was never issued.
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_shell_frame
  export FAKE_BROKERED=1
  export FAKE_NVIM_EXPR_RESULT=0
  run_frame notify --blocked
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - needs your input shell [ $TNAME ]"
  if [[ "$(<$FAKE_NVIM_EXPR_LOG)" == *FrameTakeBrokeredFlag* ]]; then
    fail "--blocked consumed the brokered flag"
  fi
}

test_blocked_respects_session_mute() {
  # An explicit :FrameNotify off still silences the banner — mute is a deliberate
  # "shut up this frame", not a "done" heuristic. The status update still lands.
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_shell_frame
  export FAKE_NVIM_EXPR_RESULT=1   # muted
  run_frame notify --blocked
  assert_status 0
  assert_file_absent "$FAKE_OSASCRIPT_LOG"
}

test_blocked_gated_when_turn_already_ended() {
  # The phantom ping: Claude Code fires the Notification hook ~60s after a turn
  # ENDS if the human hasn't typed. That frame already ran Stop → status
  # "waiting", so this --blocked must be a no-op: no "needs your input" banner
  # AND no repaint to "blocked" (frame status never runs). Otherwise a finished,
  # unattended frame screams for attention it doesn't need — the bug this gate
  # fixes.
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_shell_frame
  plant_status waiting
  export FAKE_NVIM_EXPR_RESULT=0   # unmuted — proves the mute switch isn't why
  run_frame notify --blocked
  assert_status 0
  assert_file_absent "$FAKE_OSASCRIPT_LOG"
  local _log=""; [[ -f "$FAKE_NVIM_EXPR_LOG" ]] && _log="$(<$FAKE_NVIM_EXPR_LOG)"
  assert_not_contains "$_log" "FrameSetStatus('blocked')"
}

test_blocked_fires_mid_turn_when_working() {
  # The genuine block: claude paused mid-turn (a permission/plan prompt) with no
  # Stop since the prompt, so status still reads "working". The gate lets it
  # through — title flips to "blocked" and the banner fires, exactly as before.
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_shell_frame
  plant_status working
  export FAKE_NVIM_EXPR_RESULT=0
  run_frame notify --blocked
  assert_status 0
  assert_contains "$(<$FAKE_NVIM_EXPR_LOG)" "FrameSetStatus('blocked')"
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - needs your input shell [ $TNAME ]"
}

test_blocked_fires_when_status_unreadable() {
  # Degrade-to-firing: a session predating FrameInfo (or a wedged/absent socket)
  # can't answer the gate's query. Rather than swallow a possibly-real block, the
  # gate errs toward firing — the pre-fix behaviour. No .info companion ⇒ the
  # nvim stub fails the FrameInfo query, standing in for the old session.
  (( $+commands[python3] )) || { skip "python3 not found"; return }
  setup_shell_frame            # note: no plant_status → FrameInfo query fails
  export FAKE_NVIM_EXPR_RESULT=0
  run_frame notify --blocked
  assert_status 0
  assert_contains "$(<$FAKE_OSASCRIPT_LOG)" "argv: - needs your input shell [ $TNAME ]"
}

test_blocked_rejects_extra_args() {
  setup_shell_frame
  run_frame notify --blocked extra
  assert_status 2
  assert_contains "$OUT" "takes no arguments"
}

run_tests "$0"
