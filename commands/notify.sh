# frame notify [--blocked] — ping the human that this frame wants attention:
#
#   frame notify
#     → banner "task complete", title "<name> [ <topic> :<port> ] - waiting"
#   frame notify --blocked
#     → banner "needs your input", title "… - blocked"
#
# The controls live under `frame notifications` (notification.sh): on|off is
# the global banner switch, init the banner-app build/repair.
#
# Two modes, one Claude Code hook each:
#   (bare)     the Stop hook — the turn ENDED, claude is done and waiting.
#   --blocked  the Notification hook — claude paused MID-turn for input: a
#              permission prompt, or an idle/needs-input stall. Neither Stop nor
#              UserPromptSubmit fires here, so without this the frame would keep
#              reading "working" while it's actually frozen on the human. But the
#              same hook ALSO fires an idle ping ~60s after a turn ENDS; that one
#              lands on an already-"waiting" frame, so a status-gate below drops
#              it — otherwise a finished, unattended frame would flip to a
#              phantom "blocked". See the gate for the full story.
#
# Two channels, both best-effort: the window-title status (frame status —
# needs the session's nvim socket) and a desktop banner (macOS: the Frame
# notifier app when `frame notifier` has built it, else osascript; Linux:
# notify-send when libnotify is installed). Built to be the
# target of Claude Code hooks, so a channel failing must never fail the hook:
# every step is guarded and the command always exits 0. The banner (never the
# title status) is skipped when the global switch is off (machine-global config,
# read below) or the session silenced it with :FrameSilence on / frame silence
# (asked over the socket below). The bare mode additionally skips the banner
# for brokered turns
# (the client already has the answer) and quick turns (the human prompted within
# the last 10s and is still looking) — both are "done" heuristics that are wrong
# for --blocked, where a mid-turn block is exactly when you want interrupting, so
# --blocked bypasses those two gates.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

# Hook target, mainly: the bare form is the Stop hook; --blocked is the
# Notification hook. Humans run the bare form too, to test the banner pipeline.
# Any other arg is a usage error — fine hook-wise, since the hooks always call
# one of these two.
_mode=stop
if [[ "${1:-}" == --blocked ]]; then
  _mode=blocked
  shift
fi
if (( $# )); then
  echo "$X_MARK frame notify takes no arguments (controls: frame notifications on|off|init)" >&2
  exit 2
fi

# Two distinct strings per mode: the title status reflects the frame's ongoing
# state, the banner is the proactive ping. STATUS goes to the window title, TEXT
# to the banner below. Stop → done and waiting; Notification → blocked on input.
if [[ $_mode == blocked ]]; then
  STATUS="blocked"
  TEXT="needs your input"
else
  STATUS="waiting"
  TEXT="task complete"
fi

# Identity for the banner's title, the blocked status-gate just below, and the
# socket every RPC here rides on — best-effort like everything else: a shell
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
SOCKET="$FRAME_RUNDIR/$NAME-$TOPIC.nvim"

# Blocked status-gate — the fix for the "phantom blocked" ping. Claude Code's
# Notification hook (this --blocked path) fires for TWO things: a genuine
# mid-turn block (a permission/plan prompt), and an idle "waiting for your
# input" ping it emits ~60s after a turn ENDS. The idle one lands on an
# already-finished frame — Stop has run, so the title status reads "waiting" —
# and must NOT masquerade as blocked (title flip + "needs your input" banner)
# when claude is merely done and unattended. A real mid-turn block still reads
# "working" (no Stop since the prompt), so it falls through untouched. Gate
# BEFORE the title flip below — otherwise the phantom would still repaint it
# "blocked". Best-effort: FrameInfo → name<TAB>topic<TAB>port<TAB>status<TAB>health
# — status is field 4, and stays field 4 whether or not the (later-appended)
# health field is present, so read it by position, NOT as the last field: ls's
# broker-health column (d5c81d4) made health the trailing field, and a
# last-field read would test health ("," + numbers), never match "waiting", and
# let every idle ping through — the very phantom this gate exists to stop. No
# socket / session predating FrameInfo / no answer → empty → field 4 empty →
# err toward firing, the pre-fix behaviour. This matters most for shell frames:
# they run bypass-permissions, so their ONLY Notifications are these idle ones —
# without the gate the banner is almost always a false alarm.
if [[ $_mode == blocked && -S "$SOCKET" ]]; then
  _info=$(frame_rpc_expr "$SOCKET" 'v:lua.FrameInfo()') || _info=""
  # ps:\t: — the p flag makes \t a real tab in the split spec; a bare s:\t:
  # would split on the literal two chars backslash-t and never see the fields.
  _fields=( "${(@ps:\t:)_info}" )
  if [[ "${_fields[4]:-}" == waiting ]]; then
    exit 0
  fi
fi

"$FRAME_ROOT/bin/frame" status "$STATUS" 2>/dev/null || true

# Globally off → no banner from any frame. The title status above still
# ran — same contract as the session mute.
if [[ "$(frame_global_get notify)" == off ]]; then
  exit 0
fi

# The next two gates are "done" heuristics — they silence the Stop banner when
# the human doesn't need pulling back. A --blocked ping is the opposite: claude
# is frozen mid-turn on the human, so both gates are skipped and the banner
# always fires (subject only to the global/session mutes above). Crucially,
# --blocked must NOT read-and-clear the brokered flag either — the eventual Stop
# notify still needs to consume it, or that turn would double-banner.
if [[ $_mode != blocked ]]; then
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

  # Quick-turn gate: sending a prompt stamps $FRAME_RUNDIR/<name>-<topic>.prompt (the
  # UserPromptSubmit hook runs the bare `frame status` clear — see status.sh).
  # A stamp this fresh means the human prompted seconds ago and is still
  # looking at the frame — only turns long enough to have walked away from are
  # banner-worthy. No stamp, or an old one → the banner fires. ms-11 = mtime
  # within the last 10 seconds.
  _recent=( "$FRAME_RUNDIR/$NAME-$TOPIC.prompt"(N.ms-11) )
  if (( $#_recent )); then
    exit 0
  fi
fi

# The session holds the banner silence switch (:FrameSilence on) — ask it over
# the socket. No session, or no/odd answer → unsilenced: the banner errs toward
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
# On Linux neither exists — notify-send (libnotify) carries the banner
# instead: no click-to-focus (that callback is the notifier app's -execute),
# but the ping itself lands. No channel at all → silent, like every other
# best-effort step here.
NOTIFIER="$HOME/.local/share/frame/Frame.app/Contents/MacOS/terminal-notifier"
if [[ -x "$NOTIFIER" ]]; then
  "$NOTIFIER" -title "$TITLE" -message "$TEXT" -sound Glass \
    -group "frame-$NAME-$TOPIC" \
    -execute "${(q)FRAME_ROOT}/bin/frame focus ${(q)NAME}/${(q)TOPIC}" \
    >/dev/null 2>&1 || true
elif (( $+commands[osascript] )); then
  osascript - "$TEXT" "$TITLE" >/dev/null 2>&1 <<'EOF' || true
on run argv
  display notification (item 1 of argv) with title (item 2 of argv) sound name "Glass"
end run
EOF
elif (( $+commands[notify-send] )); then
  notify-send --app-name=frame "$TITLE" "$TEXT" >/dev/null 2>&1 || true
fi
