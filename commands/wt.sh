# frame wt — worktree dev bootstrap (generic port of dev-worktree.sh).
#
#   frame wt TOPIC     create (or reuse) branch TOPIC and worktree
#                      ../_<NAME>-TOPIC beside the primary checkout, boot it
#   frame wt           boot the worktree you're already in
#   frame wt -d [-f] [TOPIC]
#                      tear down: quit the nvim session, remove worktree,
#                      delete branch. TOPIC defaults to the frame you're
#                      standing in (teardown is handed to a detached reaper so
#                      it survives its own nvim dying). Refuses if the worktree
#                      is dirty or the branch isn't merged; -f overrides.
#
# Every frame is a self-sufficient peer: this runs the project's stack_up
# (idempotent — first boot brings up the shared services, later boots no-op)
# and gives the worktree its OWN server and vite on free ports, scanned upward
# from the project's defaults, exported with the project's PORT_PREFIX so its
# code (e.g. web/vite.config.ts) picks them up. The primary checkout is just
# the git anchor merges land on; it never needs a dev session.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

frame_load_config

# -d [-f] [TOPIC]: gracefully quit the nvim session, then remove the
# worktree + branch. Works from inside the target frame too — see below.
if [[ "${1:-}" == "-d" ]]; then
  shift
  FORCE=0 TOPIC=""
  for _arg in "$@"; do
    case "$_arg" in
      -f|--force) FORCE=1 ;;
      -*) echo "$X_MARK unknown flag: $_arg" >&2; exit 2 ;;
      *)
        if [[ -n "$TOPIC" ]]; then
          echo "$X_MARK more than one topic given ($TOPIC, $_arg)" >&2; exit 2
        fi
        TOPIC=$_arg ;;
    esac
  done
  if [[ -z "$TOPIC" ]]; then
    if [[ "${PROJECT_ROOT:t}" == _$NAME-* ]]; then
      TOPIC="${${PROJECT_ROOT:t}#_$NAME-}"
    else
      echo "Usage: frame wt -d [-f] [TOPIC]  (TOPIC only optional inside a frame)" >&2
      exit 1
    fi
  fi

  WT_DIR="${MAIN_WT:h}/_$NAME-$TOPIC"
  SOCKET="/tmp/$NAME-$TOPIC.nvim"
  if [[ ! -d "$WT_DIR" ]]; then
    echo "$X_MARK no worktree at $WT_DIR" >&2; exit 1
  fi

  # Safety rails run BEFORE touching nvim — failing after the editor is gone
  # would leave a half-torn-down frame with no session to fix it from.
  if (( ! FORCE )); then
    if [[ -n "$(git -C "$WT_DIR" status --porcelain)" ]]; then
      echo "$X_MARK $WT_DIR has uncommitted/untracked files — commit or stash them," >&2
      echo "  or discard with: frame wt -d -f $TOPIC" >&2
      exit 1
    fi
    MAIN_BRANCH=$(git -C "$MAIN_WT" rev-parse --abbrev-ref HEAD)
    if ! git -C "$MAIN_WT" merge-base --is-ancestor "$TOPIC" "$MAIN_BRANCH"; then
      echo "$X_MARK branch $TOPIC has commits not on $MAIN_BRANCH — merge first" >&2
      echo "  (frame merge $TOPIC), or discard with: frame wt -d -f $TOPIC" >&2
      exit 1
    fi
  fi

  # Standing inside the target frame: this shell is a terminal buffer of the
  # nvim about to die, and its cwd is inside the worktree about to be removed —
  # an inline teardown would kill itself halfway. Hand off to a detached
  # re-invocation rooted in MAIN_WT; nohup shields it from the SIGHUP that
  # nvim's exit sends this terminal.
  if [[ "${PROJECT_ROOT:A}" == "${WT_DIR:A}" ]]; then
    _log="/tmp/$NAME-$TOPIC.teardown.log"
    _flags=(); if (( FORCE )); then _flags=(-f); fi
    echo "$RUN_MARK tearing down $TOPIC from inside — handing off to a detached reaper"
    echo "  (log: $_log). nvim will quit and this window will close; if no nvim"
    echo "  is running, cd out of the removed directory afterwards."
    cd "$MAIN_WT"
    nohup "$FRAME_ROOT/bin/frame" wt -d "${_flags[@]}" "$TOPIC" >"$_log" 2>&1 &
    exit 0
  fi

  if [[ -S "$SOCKET" ]]; then
    echo "$RUN_MARK sending :qa! to nvim ($SOCKET)…"
    # <Cmd>qa!<CR> executes from ANY mode — the session normally sits in
    # terminal-insert mode, where raw ':qa!' keys would just be typed into the
    # foreground program. The ! also bypasses :qa guards in a user's vimrc.
    if nvim --server "$SOCKET" --remote-send '<Cmd>qa!<CR>' 2>/dev/null; then
      # nvim unlinks its socket on exit — poll for that instead of blind sleep.
      for _i in {1..50}; do
        [[ -e "$SOCKET" ]] || break
        sleep 0.2
      done
      if [[ -e "$SOCKET" ]]; then
        echo "$X_MARK nvim still running after 10s — aborting teardown" >&2
        exit 1
      fi
    else
      echo "⚠ socket is stale (no nvim listening) — removing it"
      rm -f "$SOCKET"
    fi
  else
    echo "⚠ no nvim socket at $SOCKET — session may already be closed"
  fi
  _rm_flags=(); if (( FORCE )); then _rm_flags=(--force); fi
  git -C "$MAIN_WT" worktree remove "${_rm_flags[@]}" "$WT_DIR"
  git -C "$MAIN_WT" branch -D "$TOPIC"
  # :FrameDown's watcher matches this line to know teardown finished without
  # reaching the session — keep the wording in sync with layouts/worktree.lua.
  echo "$OK_MARK removed worktree and branch $TOPIC"
  exit 0
fi

if [[ "${1:-}" == -* ]]; then
  if [[ "$1" == "-m" || "$1" == "--merge" ]]; then
    echo "$X_MARK frame wt -m was removed — use: frame merge [TOPIC]" >&2
  else
    echo "$X_MARK unknown flag: $1" >&2
  fi
  exit 2
fi

# BUFFERS is required to boot a frame, and authoritative even when empty:
# BUFFERS=() opens no buffers. Definitions live in $FRAME_ROOT/buffers.json;
# BUFFERS says which of them this project's frames open.
if (( ! ${+BUFFERS} )); then
  echo "$X_MARK frame: .frame/config.sh must define BUFFERS=(…) — the buffers to open" >&2
  echo "  (definitions: $FRAME_ROOT/buffers.json; e.g. BUFFERS=(claude local))" >&2
  exit 1
fi

if (( $# >= 1 )); then
  TOPIC=$1
  WT_DIR="${MAIN_WT:h}/_$NAME-$TOPIC"
  if [[ ! -d "$WT_DIR" ]]; then
    if git -C "$MAIN_WT" show-ref --verify --quiet "refs/heads/$TOPIC"; then
      echo "$RUN_MARK adding worktree $WT_DIR on existing branch $TOPIC…"
      git -C "$MAIN_WT" worktree add "$WT_DIR" "$TOPIC"
    else
      echo "$RUN_MARK creating branch $TOPIC + worktree $WT_DIR…"
      git -C "$MAIN_WT" worktree add -b "$TOPIC" "$WT_DIR"
    fi
  else
    echo "$OK_MARK worktree $WT_DIR already exists — reusing"
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

set_title "$(frame_base_title "$NAME" "$TOPIC")"

# Frames are self-sufficient: whichever boots first brings up the world.
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
    echo "$OK_MARK symlinked $_l from $MAIN_WT"
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
  echo "$OK_MARK worktree env: server :$PORT · vite :$FRAME_VITE_PORT · hmr :$_hmr"
fi

if (( $+functions[app_env] )); then app_env; fi

# Layout parameters — read by layouts/worktree.lua.
export FRAME_NAME="$NAME"
export FRAME_TOPIC="$TOPIC"
export FRAME_MAIN_WT="$MAIN_WT"
export FRAME_VITE_PORT
export FRAME_BUFFERS="${BUFFERS[*]}"
# Config vars referenced by buffers.json are exported under their own names,
# so the registry reads exactly like the config. FRAME_* stays reserved for
# frame-computed values with no config counterpart.
export SERVER_CMD="${SERVER_CMD:-}"
export PORT_PREFIX
frame_export_claude_flags

exec nvim -S "$FRAME_ROOT/layouts/worktree.lua"
