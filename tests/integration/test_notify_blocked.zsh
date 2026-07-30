#!/usr/bin/env zsh
# frame notify --blocked — the Notification-hook mode: claude paused MID-turn on
# a permission prompt (or an idle/needs-input stall), a state neither Stop nor
# UserPromptSubmit fires for. It sets a "blocked" title status and, unlike the
# bare Stop mode, banners THROUGH the brokered- and quick-turn gates (those
# silence "done" pings; a mid-turn block is exactly when you want interrupting).
# The session mute and global switch still apply. Same shell-frame + live-socket
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

test_blocked_rejects_extra_args() {
  setup_shell_frame
  run_frame notify --blocked extra
  assert_status 2
  assert_contains "$OUT" "takes no arguments"
}

run_tests "$0"
