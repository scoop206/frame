# frame services — manage the shared postgres/minio stack directly.
#   frame services        start (same as `up`)
#   frame services up
#   frame services down   stop containers (volumes/data untouched)
#   frame services ps
# Sourced by bin/frame; helpers + set -euo pipefail already active.

case "${1:-up}" in
  up)   frame_services_up ;;
  down) docker compose -f "$FRAME_SERVICES_COMPOSE" down ;;
  ps)   docker compose -f "$FRAME_SERVICES_COMPOSE" ps ;;
  *)    echo "Usage: frame services [up|down|ps]" >&2; exit 2 ;;
esac
