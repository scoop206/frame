# frame yolo [on|off] — master switch for claude's permission prompts:
#
#   frame yolo on    claude in every frame launches with
#                    --dangerously-skip-permissions
#   frame yolo off   back to plain `claude`, prompts intact (the default)
#   frame yolo       show the current state
#
# Machine-global like the banner switch (the `yolo` key of
# frame_global_get/set — helpers.sh): one flip covers every project's frames
# and shell frames on this machine. Read at boot by frame_export_claude_flags,
# so it takes effect on the next frame boot — running sessions keep the
# claude they started with.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

if (( $# > 1 )); then
  echo "Usage: frame yolo [on|off]" >&2
  exit 2
fi

case "${1:-}" in
  "")
    if [[ "$(frame_global_get yolo)" == on ]]; then
      echo "yolo is on — claude launches with --dangerously-skip-permissions"
    else
      echo "yolo is off — claude keeps its permission prompts"
    fi
    ;;
  on)
    frame_global_set yolo on
    echo "$OK_MARK yolo on — claude in every new frame runs with --dangerously-skip-permissions"
    ;;
  off)
    frame_global_set yolo off
    echo "$OK_MARK yolo off — claude in new frames keeps its permission prompts"
    ;;
  *)
    echo "Usage: frame yolo [on|off]" >&2
    exit 2
    ;;
esac
