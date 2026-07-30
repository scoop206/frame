# frame focus [TOPIC | NAME/TOPIC] — bring a frame's ghostty window to the front:
#
#   frame focus                 the frame you're in
#   frame focus schema          any frame with that topic, whatever its name
#   frame focus flipnem/schema  a specific frame, name and topic
#
# You never type the window title's brackets — pass the bare topic (optionally
# NAME/topic to disambiguate) and focus builds the bracketed match internally.
# Built to be the click target of the notify banner (notify.sh passes it via
# the notifier app's -execute as NAME/TOPIC), so the argument form matches what
# the banner knows. Spawned frames are found by recorded window/tab id (fast
# path below — permission-free). Otherwise: activating ghostty needs no
# permissions; raising the *specific* window goes through System Events
# (AXRaise), which asks for Accessibility once — declined, the try block
# leaves plain activation, so clicking still surfaces ghostty, just not the
# exact window.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

if (( $# )); then
  ARG="$*"
  if [[ "$ARG" == */* ]]; then
    F_NAME="${ARG%%/*}" F_TOPIC="${ARG#*/}"
  else
    # Topic only — match any name carrying this topic.
    F_NAME="" F_TOPIC="$ARG"
  fi
else
  # Same identity derivation as status.sh: shell frames carry it in the
  # session env, checkouts derive it from worktree/branch.
  if ! frame_project_root >/dev/null \
      && [[ -n "${FRAME_NAME:-}" && -n "${FRAME_TOPIC:-}" ]]; then
    F_NAME=$FRAME_NAME F_TOPIC=$FRAME_TOPIC
  else
    frame_load_config
    F_NAME=$NAME
    if [[ "${PROJECT_ROOT:t}" == _$NAME-* ]]; then
      F_TOPIC="${${PROJECT_ROOT:t}#_$NAME-}"
    else
      F_TOPIC=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
    fi
  fi
fi

# Human-readable label for messages (mirrors what was typed).
TARGET="${F_NAME:+$F_NAME/}$F_TOPIC"

# Fast path: spawned frames record their ghostty window/tab ids (spawn writes
# $SOCKET.gtab) — select the exact tab by id and bring its window forward. No
# System Events, no Accessibility grant, and background tabs are reachable
# (the title matcher below only sees each window's SELECTED tab). Anything
# without a recording — hand-booted frames, legacy `open -na` windows — falls
# through to the matcher; a stale recording (frame died, tab gone) is deleted
# so it can't misdirect again.
if [[ -n "$F_NAME" ]]; then
  GTABS=(/tmp/$F_NAME-$F_TOPIC.nvim.gtab(N))
else
  GTABS=(/tmp/*-$F_TOPIC.nvim.gtab(N))
fi
if (( $#GTABS )); then
  read -r G_WID G_TID < "$GTABS[1]"
  R=$(osascript - "$G_WID" "$G_TID" 2>/dev/null <<'APPLESCRIPT'
on run argv
  set wid to item 1 of argv
  tell application "Ghostty"
    select tab (tab id (item 2 of argv) of window id wid)
    activate window (window id wid)
    activate
  end tell
  return "selected"
end run
APPLESCRIPT
  ) || R=""
  if [[ "$R" == selected ]]; then
    echo "$OK_MARK focused $TARGET"
    exit 0
  fi
  rm -f "$GTABS[1]"
fi

# Match against the bracketed base title — "<name> [ <topic>" pre-nvim and
# "<name> [ <topic> :<port> ]" once the session owns it — anchored on the
# space+":" (vite) or space+"]" (no port) that always follows the topic, so
# `foo` never grabs `foo-bar`'s window. Empty name matches any owner.
RESULT=$(osascript - "$F_NAME" "$F_TOPIC" <<'EOF'
on run argv
  set nm to item 1 of argv
  set tp to item 2 of argv
  if nm is "" then
    set aPort to " [ " & tp & " :"
    set aClose to " [ " & tp & " ]"
  else
    set aPort to nm & " [ " & tp & " :"
    set aClose to nm & " [ " & tp & " ]"
  end if
  tell application "Ghostty" to activate
  tell application "System Events" to tell process "Ghostty"
    try
      set hits to (every window whose (name contains aPort) or (name contains aClose))
      if (count of hits) is 0 then return "nomatch"
      perform action "AXRaise" of (item 1 of hits)
      return "raised"
    end try
  end tell
  return "activated"
end run
EOF
) || { echo "$X_MARK couldn't reach ghostty (is Ghostty installed?)" >&2; exit 1; }

case "$RESULT" in
  raised)
    echo "$OK_MARK focused $TARGET" ;;
  nomatch)
    echo "$X_MARK no frame matching $TARGET (check frame status)" >&2
    exit 1 ;;
  *)  # activated — found nothing to raise through System Events; the usual
      # cause is Accessibility not being granted (AXRaise is gated).
    echo "$X_MARK ghostty raised, but couldn't raise the $TARGET window —" >&2
    echo "  grant Accessibility (System Settings → Privacy → Accessibility)" >&2
    exit 1 ;;
esac
