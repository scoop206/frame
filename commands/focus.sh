# frame focus [NAME/TOPIC] — bring a frame's ghostty window to the front:
#
#   frame focus                 the frame you're in
#   frame focus flipnem/schema  any frame, by banner title
#
# Built to be the click target of the notify banner (notify.sh passes it via
# the notifier app's -execute), so the argument form matches the banner title
# exactly. Activating ghostty needs no permissions; raising the *specific*
# window goes through System Events (AXRaise), which asks for Accessibility
# once — declined, the try block leaves plain activation, so clicking still
# surfaces ghostty, just not the exact window.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

if (( $# )); then
  TARGET="$*"
else
  # Same identity derivation as status.sh: shell frames carry it in the
  # session env, checkouts derive it from worktree/branch.
  if ! frame_project_root >/dev/null \
      && [[ -n "${FRAME_NAME:-}" && -n "${FRAME_TOPIC:-}" ]]; then
    NAME=$FRAME_NAME TOPIC=$FRAME_TOPIC
  else
    frame_load_config
    if [[ "${PROJECT_ROOT:t}" == _$NAME-* ]]; then
      TOPIC="${${PROJECT_ROOT:t}#_$NAME-}"
    else
      TOPIC=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
    fi
  fi
  TARGET="$NAME/$TOPIC"
fi

# Titles are "<name>/<topic>" pre-nvim and "<name>/<topic> :<port>[ - status]"
# once the session owns them — exact match or "<target> " prefix, so
# shell/foo never grabs shell/foo-bar's window.
RESULT=$(osascript - "$TARGET" <<'EOF'
on run argv
  set t to item 1 of argv
  tell application "Ghostty" to activate
  tell application "System Events" to tell process "Ghostty"
    try
      perform action "AXRaise" of ¬
        (first window whose name is t or name begins with (t & " "))
      return "raised"
    end try
  end tell
  return "activated"
end run
EOF
) || { echo "$X_MARK couldn't reach ghostty (is Ghostty installed?)" >&2; exit 1; }

if [[ "$RESULT" == raised ]]; then
  echo "$OK_MARK focused $TARGET"
else
  echo "$X_MARK ghostty raised, but no window titled $TARGET — frame closed," >&2
  echo "  or Accessibility not granted (System Settings → Privacy → Accessibility)" >&2
  exit 1
fi
