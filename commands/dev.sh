# frame dev — boot the project's primary dev environment.
#   1. title the window (findable even mid-boot)
#   2. stack_up   (project-owned: shared services + project-unique containers)
#   3. app_env    (exports pointing the app at the shared services)
#   4. nvim with the dev layout (project override → frame default)
# Sourced by bin/frame; helpers + set -euo pipefail already active.

frame_load_config
cd "$PROJECT_ROOT"

set_title "$NAME dev"

if (( $+functions[stack_up] )); then stack_up; fi
if (( $+functions[app_env]  )); then app_env;  fi

# Layout parameters — read by layouts/dev.lua (or a project override).
export FRAME_NAME="$NAME"
export FRAME_SERVER_CMD="${SERVER_CMD:-}"
export FRAME_VITE_PORT="${VITE_PORT:-}"
export FRAME_NGROK_AUTO="${NGROK_AUTO:-0}"

layout=$(frame_resolve dev.lua)
if [[ "${FRAME_NO_NVIM:-0}" == 1 ]]; then
  echo "✓ dev env ready (nvim skipped) — layout: $layout"
else
  exec nvim -S "$layout"
fi
