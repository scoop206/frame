# frame notify [TEXT…] — ping the human that this frame wants attention:
#
#   frame notify
#     → banner "⏸ waiting", title "<name>/<topic> :<port> - ⏸ waiting"
#   frame notify needs guidance: schema change
#     → the same, carrying that text
#
# Two channels, both best-effort: the window-title status (frame status —
# needs the session's nvim socket) and a macOS banner (osascript). Built to
# be the target of Claude Code hooks (Stop → `frame notify`), so a channel
# failing must never fail the hook: every step is guarded and the command
# always exits 0.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

frame_load_config

TEXT="${*:-⏸ waiting}"

"$FRAME_ROOT/bin/frame" status "$TEXT" 2>/dev/null || true

# Same topic derivation as status.sh, for the banner's title — except
# guarded: HEAD is unresolvable in a repo with no commits yet.
if [[ "${PROJECT_ROOT:t}" == _$NAME-* ]]; then
  TOPIC="${${PROJECT_ROOT:t}#_$NAME-}"
else
  TOPIC=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null) || TOPIC='?'
fi

# argv, not string interpolation — TEXT may contain quotes.
osascript - "$TEXT" "$NAME/$TOPIC" >/dev/null 2>&1 <<'EOF' || true
on run argv
  display notification (item 1 of argv) with title (item 2 of argv) sound name "Glass"
end run
EOF
