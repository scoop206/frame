# frame attach — give a detached frame a window again.
#
#   frame attach                 every detached frame, each in its own tab
#   frame attach TOPIC           that one (a topic, or NAME/TOPIC)
#   frame attach --here TOPIC    …in THIS terminal instead of a new tab
#
# A frame's nvim runs as a headless server and its Ghostty tab is just a
# client (frame_exec_session in lib/helpers.sh), so closing the tab or quitting
# Ghostty leaves the frame running — claude mid-turn, dev servers up — with no
# window: "detached" in `frame ls`. This reopens one. Tabs land in the workers
# window, as `frame spawn` opens them, and their ids are re-recorded so
# `frame focus` and the banner click find the new tab.
#
# A frame whose nvim is gone too (a crash, a reboot) isn't detached but down:
# `frame restore` reboots it (and attaches the detached ones as well).
# Sourced by bin/frame; helpers + set -euo pipefail already active.

_usage() {
  echo "Usage: frame attach [TOPIC | NAME/TOPIC | --all]" >&2
  echo "       frame attach --here TOPIC | NAME/TOPIC" >&2
  exit 2
}

HERE=0 SPEC=""
while (( $# )); do
  case "$1" in
    --here)    HERE=1 ;;
    -a|--all)  ;;                      # the bare form already means all
    -h|--help) sed -n '1,16p' "$FRAME_ROOT/commands/attach.sh" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        echo "$X_MARK unknown flag: $1" >&2; _usage ;;
    *)         [[ -z "$SPEC" ]] || { echo "$X_MARK more than one frame given ($SPEC, $1)" >&2; _usage; }
               SPEC=$1 ;;
  esac
  shift
done

# The detached frames: live, with no window attached.
typeset -a DETACHED   # NAME/TOPIC
while IFS=$'\t' read -r _line; do
  _f=("${(@ps:\t:)_line}")
  [[ "${_f[6]:-}" == 0 ]] && DETACHED+=("$_f[1]/$_f[2]")
done < <(frame_live_frames)

typeset -a PICKED
if [[ -n "$SPEC" ]]; then
  frame_self_identity 2>/dev/null || true
  frame_resolve_target "$SPEC" || exit 1
  if (( ! ${DETACHED[(Ie)$NAME/$TOPIC]} )); then
    if _uis=$(frame_session_uis "$NAME" "$TOPIC"); then
      echo "$X_MARK $NAME/$TOPIC already has a window — frame focus $NAME/$TOPIC" >&2
    else
      echo "$X_MARK $NAME/$TOPIC isn't detached (it may predate detachable frames;" >&2
      echo "  reboot it once to get one): frame focus $NAME/$TOPIC" >&2
    fi
    exit 1
  fi
  PICKED=("$NAME/$TOPIC")
else
  if (( HERE )); then
    echo "$X_MARK --here attaches one frame — name it: frame attach --here TOPIC" >&2; exit 2
  fi
  if (( ! $#DETACHED )); then
    echo "$OK_MARK no detached frames — every running frame has a window"
    exit 0
  fi
  PICKED=("${DETACHED[@]}")
fi

if (( HERE )); then
  frame_guard_nested || exit 1
  frame_attach_here "${PICKED[1]%%/*}" "${PICKED[1]#*/}"
fi

if ! frame_is_macos; then
  echo "$X_MARK tabs open via Ghostty's AppleScript dictionary (macOS only) — attach each in" >&2
  echo "  a terminal of its own:" >&2
  for _h in "${PICKED[@]}"; do echo "    frame attach --here $_h" >&2; done
  exit 1
fi

_rc=0
for _h in "${PICKED[@]}"; do
  if frame_open_frame_tab "${_h%%/*}" "${_h#*/}" "${(q)FRAME_ROOT}/bin/frame attach --here ${(q)_h}"; then
    echo "$OK_MARK attached $_h in a new tab"
  else
    echo "$X_MARK $_h: couldn't open a ghostty tab — run: frame attach --here $_h" >&2
    _rc=1
  fi
done
exit $_rc
