# frame wt — worktree dev bootstrap (generic port of dev-worktree.sh).
#
#   frame wt TOPIC     create (or reuse) branch TOPIC and worktree
#                      ../_<NAME>-TOPIC beside the primary checkout, boot it
#   frame wt           boot the worktree you're already in
#   frame wt -d TOPIC  quit the nvim session, remove worktree, delete branch
#   frame wt -m [...]  merge into main (delegates to frame merge)
#
# Every framelet is a self-sufficient peer: this runs the project's stack_up
# (idempotent — first boot brings up the shared services, later boots no-op)
# and gives the worktree its OWN server and vite on free ports, scanned upward
# from the project's defaults, exported with the project's PORT_PREFIX so its
# code (e.g. web/vite.config.ts) picks them up. The primary checkout is just
# the git anchor merges land on; it never needs a dev session.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

frame_load_config

# -d TOPIC: gracefully quit the nvim session, then remove the worktree + branch.
if [[ "${1:-}" == "-d" ]]; then
  if (( $# < 2 )); then
    echo "Usage: frame wt -d TOPIC" >&2; exit 1
  fi
  TOPIC=$2
  WT_DIR="${MAIN_WT:h}/_$NAME-$TOPIC"
  SOCKET="/tmp/$NAME-$TOPIC.nvim"
  if [[ -S "$SOCKET" ]]; then
    echo "▶ sending :qa! to nvim ($SOCKET)…"
    nvim --server "$SOCKET" --remote-send ':qa!<CR>' 2>/dev/null || true
    sleep 0.5  # give nvim a moment to release the worktree files
  else
    echo "⚠ no nvim socket at $SOCKET — session may already be closed"
  fi
  git -C "$MAIN_WT" worktree remove "$WT_DIR"
  git -C "$MAIN_WT" branch -D "$TOPIC"
  echo "✓ removed worktree and branch $TOPIC"
  exit 0
fi

# -m [TOPIC] [flags]: merge into main — same logic as `frame merge`.
if [[ "${1:-}" == "-m" || "${1:-}" == "--merge" ]]; then
  shift
  source "$FRAME_ROOT/commands/merge.sh" "$@"
  exit $?
fi

if (( $# >= 1 )); then
  TOPIC=$1
  WT_DIR="${MAIN_WT:h}/_$NAME-$TOPIC"
  if [[ ! -d "$WT_DIR" ]]; then
    if git -C "$MAIN_WT" show-ref --verify --quiet "refs/heads/$TOPIC"; then
      echo "▶ adding worktree $WT_DIR on existing branch $TOPIC…"
      git -C "$MAIN_WT" worktree add "$WT_DIR" "$TOPIC"
    else
      echo "▶ creating branch $TOPIC + worktree $WT_DIR…"
      git -C "$MAIN_WT" worktree add -b "$TOPIC" "$WT_DIR"
    fi
  else
    echo "✓ worktree $WT_DIR already exists — reusing"
  fi
  PROJECT_DIR="$WT_DIR"
else
  PROJECT_DIR="$PROJECT_ROOT"
  if [[ "$PROJECT_DIR" == "$MAIN_WT" ]]; then
    # Booting the primary checkout itself — no worktree dir to derive a topic
    # from, so use the branch name (usually `main`).
    TOPIC=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)
  else
    TOPIC="${${PROJECT_DIR:t}#_$NAME-}"
  fi
fi
cd "$PROJECT_DIR"

set_title "$NAME/$TOPIC"

# Framelets are self-sufficient: whichever boots first brings up the world.
# stack_up is idempotent (compose up -d no-ops, ensure_* helpers no-op), so
# this is cheap when the stack is already running.
if (( $+functions[stack_up] )); then stack_up; fi

# Gitignored assets a fresh worktree lacks — symlink from the primary checkout
# so it boots instantly. Default covers .env (shared server config; exported
# vars still win — dotenvy never overrides the environment) and web/node_modules
# (safe until package.json diverges; npm install manually if it does). Projects
# override with WT_LINKS=(…) in config; entries missing in the primary checkout
# are skipped silently.
if (( ${+WT_LINKS} )); then _links=("${WT_LINKS[@]}"); else _links=(.env web/node_modules); fi
for _l in "${_links[@]}"; do
  if [[ ! -e "$_l" && -e "$MAIN_WT/$_l" ]]; then
    ln -s "$MAIN_WT/$_l" "$_l"
    echo "✓ symlinked $_l from $MAIN_WT"
  fi
done

# Free ports, scanned upward from the project's primary-env defaults (primary
# on 3000/5173/24678 → first worktree 3001/5174/24679, and so on). Exported
# with the project's own prefix so its code inherits them.
FRAME_VITE_PORT=""
if [[ -n "${API_PORT:-}${VITE_PORT:-}" ]]; then
  export PORT=$(find_free_port "${API_PORT:-3000}")
  FRAME_VITE_PORT=$(find_free_port "${VITE_PORT:-5173}")
  _hmr=$(find_free_port "${HMR_PORT:-24678}")
  export "${PORT_PREFIX}_API_PORT=$PORT"
  export "${PORT_PREFIX}_VITE_PORT=$FRAME_VITE_PORT"
  export "${PORT_PREFIX}_HMR_PORT=$_hmr"
  echo "✓ worktree env: server :$PORT · vite :$FRAME_VITE_PORT · hmr :$_hmr"
fi

if (( $+functions[app_env] )); then app_env; fi

# Layout parameters — read by layouts/worktree.lua (or a project override).
export FRAME_NAME="$NAME"
export FRAME_TOPIC="$TOPIC"
export FRAME_SERVER_CMD="${SERVER_CMD:-}"
export FRAME_VITE_PORT

layout=$(frame_resolve worktree.lua)
if [[ "${FRAME_NO_NVIM:-0}" == 1 ]]; then
  echo "✓ worktree ready (nvim skipped) — layout: $layout"
else
  exec nvim -S "$layout"
fi
