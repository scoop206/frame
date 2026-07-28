# Frame helper library (zsh). Sourced by bin/frame before any command runs,
# so every function here is also available inside a project's .frame/config.sh
# (stack_up / app_env hooks).

FRAME_SERVICES_COMPOSE="$FRAME_ROOT/services/docker-compose.yml"

# ── project discovery ─────────────────────────────────────────────────────────

frame_project_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

frame_main_wt() {
  # The primary checkout: first entry in `git worktree list`.
  git -C "${1:-.}" worktree list --porcelain | head -1 | cut -d' ' -f2
}

frame_load_config() {
  # Sets PROJECT_ROOT, MAIN_WT, NAME, PORT_PREFIX, plus whatever the project
  # config defines (SERVER_CMD, ports, stack_up, app_env, …).
  #
  # Config lookup order — first hit wins:
  #   <this checkout>/.frame/local/config.sh   (personal, gitignored)
  #   <this checkout>/.frame/config.sh         (committed project facts)
  #   <primary checkout>/.frame/…              (fallback: a worktree created
  #                                             before .frame was committed)
  PROJECT_ROOT=$(frame_project_root) || {
    echo "✗ frame: not inside a git repository" >&2
    return 1
  }
  MAIN_WT=$(frame_main_wt "$PROJECT_ROOT")

  local _dir _f _cfg=""
  for _dir in "$PROJECT_ROOT" "$MAIN_WT"; do
    for _f in "$_dir/.frame/local/config.sh" "$_dir/.frame/config.sh"; do
      if [[ -f "$_f" ]]; then _cfg=$_f; break 2; fi
    done
  done
  if [[ -n "$_cfg" ]]; then
    source "$_cfg"
  fi

  # NAME defaults to the primary checkout's directory name; PORT_PREFIX is the
  # env-var prefix the project's own code reads (e.g. FLIPNEM_VITE_PORT).
  : "${NAME:=${MAIN_WT:t}}"
  : "${PORT_PREFIX:=${(U)NAME//-/_}}"
}

frame_resolve() {
  # frame_resolve dev.lua → first existing of:
  #   .frame/local/<f> → .frame/<f> (this checkout, then primary) → frame default
  local _f=$1 _dir
  for _dir in "$PROJECT_ROOT/.frame/local" "$PROJECT_ROOT/.frame" \
              "$MAIN_WT/.frame/local"     "$MAIN_WT/.frame"; do
    if [[ -f "$_dir/$_f" ]]; then echo "$_dir/$_f"; return 0; fi
  done
  if [[ -f "$FRAME_ROOT/layouts/$_f" ]]; then
    echo "$FRAME_ROOT/layouts/$_f"; return 0
  fi
  echo "✗ frame: no $_f found (project override or $FRAME_ROOT/layouts)" >&2
  return 1
}

# ── claude-code hooks ─────────────────────────────────────────────────────────

frame_write_claude_hooks() {
  # .claude/settings.json in cwd, wiring claude-code to frame's notification
  # channels: Stop → `frame notify` (banner + "- ⏸ waiting" title status),
  # UserPromptSubmit → `frame status` (clears it). Callers guard the
  # file-exists case — this always writes.
  mkdir -p .claude
  cat > .claude/settings.json <<'EOF'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "frame notify >/dev/null 2>&1 || true"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "frame status >/dev/null 2>&1 || true"
          }
        ]
      }
    ]
  }
}
EOF
}

# ── window titling ────────────────────────────────────────────────────────────

set_title() {
  # Set the ghostty window title now, before nvim takes over — windows are
  # Raycast-findable even mid-boot or after nvim exits.
  printf '\e]2;%s\e\\' "$1"
}

# ── docker / shared services ──────────────────────────────────────────────────

ensure_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo "▶ starting OrbStack…"
    open -a OrbStack
    until docker info >/dev/null 2>&1; do sleep 0.5; done
  fi
}

frame_services_up() {
  # frame_services_up [postgres] [minio] — start (default: both) and wait ready.
  ensure_docker
  if (( $# == 0 )); then set -- postgres minio; fi
  echo "▶ starting shared services: $*…"
  if ! docker compose -f "$FRAME_SERVICES_COMPOSE" up -d "$@"; then
    echo "✗ frame services failed to start. If a port is taken, an old" >&2
    echo "  per-project stack may still be running (its minio binds :9000):" >&2
    docker ps --format '  {{.Names}}  {{.Ports}}' | grep -E '5432|9000|9001' >&2 || true
    return 1
  fi
  local _s
  for _s in "$@"; do
    case "$_s" in
      postgres) wait_for_pg ;;
      minio)    wait_for_url http://localhost:9000/minio/health/live minio ;;
    esac
  done
}

wait_for_pg() {
  echo "▶ waiting for postgres…"
  until docker compose -f "$FRAME_SERVICES_COMPOSE" exec -T postgres \
        pg_isready -U frame -d frame >/dev/null 2>&1; do
    sleep 0.5
  done
  echo "✓ postgres ready"
}

wait_for_url() {
  # wait_for_url URL [LABEL]
  local _url=$1 _label=${2:-$1}
  echo "▶ waiting for $_label…"
  until curl -sf "$_url" >/dev/null 2>&1; do sleep 0.5; done
  echo "✓ $_label ready"
}

ensure_pg_db() {
  # ensure_pg_db NAME [PASSWORD] — idempotent role + database, owned by the
  # role, on the shared postgres. Role-per-project keeps one project's tests
  # from touching another's database.
  local _db=$1 _pass=${2:-devpassword}
  local -a _psql
  _psql=(docker compose -f "$FRAME_SERVICES_COMPOSE" exec -T postgres
         psql -U frame -d frame -v ON_ERROR_STOP=1 -qAt)
  if [[ "$("${_psql[@]}" -c "SELECT 1 FROM pg_roles WHERE rolname='$_db'")" != 1 ]]; then
    "${_psql[@]}" -c "CREATE ROLE \"$_db\" LOGIN PASSWORD '$_pass'" >/dev/null
    echo "✓ created role $_db"
  fi
  if [[ "$("${_psql[@]}" -c "SELECT 1 FROM pg_database WHERE datname='$_db'")" != 1 ]]; then
    "${_psql[@]}" -c "CREATE DATABASE \"$_db\" OWNER \"$_db\"" >/dev/null
    echo "✓ created database $_db"
  fi
}

ensure_minio_bucket() {
  # ensure_minio_bucket BUCKET — idempotent bucket on the shared minio.
  local _b=$1
  docker compose -f "$FRAME_SERVICES_COMPOSE" run --rm mc \
    mb --ignore-existing "local/$_b" >/dev/null 2>&1
  echo "✓ bucket $_b"
}

# ── misc ──────────────────────────────────────────────────────────────────────

find_free_port() {
  # Scan upward from $1 until a port nothing is listening on.
  local _p=$1
  while lsof -nP -iTCP:$_p -sTCP:LISTEN >/dev/null 2>&1; do
    _p=$((_p + 1))
  done
  echo $_p
}
