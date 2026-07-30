# frame notify — ping the human that this frame wants attention:
#
#   frame notify
#     → banner "task complete", title "<name> [ <topic> :<port> ] - waiting"
#
# The controls live under `frame notification` (notification.sh): on|off is
# the global banner switch, init the banner-app build/repair.
#
# Two channels, both best-effort: the window-title status (frame status —
# needs the session's nvim socket) and a macOS banner (the Frame notifier
# app when `frame notifier` has built it, else osascript). Built to
# be the target of Claude Code hooks (Stop → `frame notify`), so a channel
# failing must never fail the hook: every step is guarded and the command
# always exits 0. The banner (never the title status) is skipped in three
# cases: the global switch is off (the machine-global config, read below),
# the session muted it with :FrameNotify off (asked over the socket below),
# or the turn was quick — the human prompted within the last 10 seconds
# (the stamp check below).
# Sourced by bin/frame; helpers + set -euo pipefail already active.

# Hook target only — no arguments. Pointing stray args (including the old
# on|off|init spellings) at frame notification beats guessing; the usage
# error is fine hook-wise — hooks always call the bare form.
if (( $# )); then
  echo "$X_MARK frame notify takes no arguments (controls: frame notification on|off|init)" >&2
  exit 2
fi

# Two distinct strings: the title status reflects the frame's ongoing state
# (it's waiting on the human), while the banner is the proactive "I'm done"
# ping. STATUS goes to the window title, TEXT to the banner below.
STATUS="waiting"
TEXT="task complete"

"$FRAME_ROOT/bin/frame" status "$STATUS" 2>/dev/null || true

# Globally off → no banner from any frame. The title status above still
# ran — same contract as the session mute.
if [[ "$(frame_global_get notify)" == off ]]; then
  exit 0
fi

# Identity for the banner's title, best-effort like everything here: a shell
# frame (frame shell — no git repo) carries it in the session env; a checkout
# derives it as status.sh does (guarded: HEAD is unresolvable in a repo with
# no commits yet); anywhere else fall back to ?/? — the banner still fires.
if ! frame_project_root >/dev/null \
    && [[ -n "${FRAME_NAME:-}" && -n "${FRAME_TOPIC:-}" ]]; then
  NAME=$FRAME_NAME TOPIC=$FRAME_TOPIC
elif frame_load_config 2>/dev/null; then
  if [[ "${PROJECT_ROOT:t}" == _$NAME-* ]]; then
    TOPIC="${${PROJECT_ROOT:t}#_$NAME-}"
  else
    TOPIC=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null) || TOPIC='?'
  fi
else
  NAME='?' TOPIC='?'
fi

# The banner wears the frame's identity block (bracketed, matching the window
# title). Port omitted — notify doesn't compute it, and the identity reads fine
# without it.
TITLE=$(frame_base_title "$NAME" "$TOPIC")
SOCKET="/tmp/$NAME-$TOPIC.nvim"

# Brokered turns get no banner: the client (frame claude / frame req) already
# received the answer over the socket, so a "come look" desktop ping is noise.
# Read-and-clear the flag the broker set at submit (FrameTakeBrokeredFlag) —
# BEFORE the quick-turn gate, so a fast brokered turn still consumes it and it
# can't linger to mute a later human turn. Old layouts lack the function → the
# query fails → 0 → the banner fires exactly as it used to.
if [[ -S "$SOCKET" ]]; then
  _brokered=$(nvim --headless --server "$SOCKET" \
    --remote-expr "v:lua.FrameTakeBrokeredFlag()" 2>/dev/null) || _brokered=0
  if [[ "$_brokered" == 1 ]]; then
    exit 0
  fi
fi

# Quick-turn gate: sending a prompt stamps /tmp/<name>-<topic>.prompt (the
# UserPromptSubmit hook runs the bare `frame status` clear — see status.sh).
# A stamp this fresh means the human prompted seconds ago and is still
# looking at the frame — only turns long enough to have walked away from are
# banner-worthy. No stamp, or an old one → the banner fires. ms-11 = mtime
# within the last 10 seconds.
_recent=( "/tmp/$NAME-$TOPIC.prompt"(N.ms-11) )
if (( $#_recent )); then
  exit 0
fi

# The session holds the banner mute switch (:FrameNotify off) — ask it over
# the socket. No session, or no/odd answer → unmuted: the banner errs toward
# firing, and sessions predating the switch just don't have g:frame_notify_muted.
if [[ -S "$SOCKET" ]]; then
  # --headless: without it a piped-stdout nvim client (0.10+) sends the
  # result to /dev/tty instead of stdout and leaks terminal-probe replies
  # onto the prompt — see the note in status.sh. Headless captures cleanly.
  _muted=$(nvim --headless --server "$SOCKET" \
    --remote-expr "get(g:, 'frame_notify_muted', 0)" 2>/dev/null) || _muted=0
  if [[ "$_muted" == 1 ]]; then
    exit 0
  fi
fi

# The banner itself, best channel first. The Frame notifier app (built once
# by `frame notifier`) is a real bundle, so the banner wears the frame icon
# and clicking it runs `frame focus` on this frame — by absolute path, since
# the click callback runs under a bare /bin/sh env. -group: a frame's new
# banner replaces its previous one instead of stacking. Without the app,
# the osascript banner (Script Editor icon, click opens it) still fires.
NOTIFIER="$HOME/.local/share/frame/Frame.app/Contents/MacOS/terminal-notifier"
if [[ -x "$NOTIFIER" ]]; then
  "$NOTIFIER" -title "$TITLE" -message "$TEXT" -sound Glass \
    -group "frame-$NAME-$TOPIC" \
    -execute "${(q)FRAME_ROOT}/bin/frame focus ${(q)NAME}/${(q)TOPIC}" \
    >/dev/null 2>&1 || true
else
  osascript - "$TEXT" "$TITLE" >/dev/null 2>&1 <<'EOF' || true
on run argv
  display notification (item 1 of argv) with title (item 2 of argv) sound name "Glass"
end run
EOF
fi
