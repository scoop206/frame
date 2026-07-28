# frame scaffold — scaffold a project's .frame/ directory:
#   .frame/config.sh        committed project facts (template, edit to fit)
#   .frame/local/           personal overrides + state — appended to .gitignore
#   .claude/settings.json   claude-code hooks: `frame notify` when a turn ends,
#                           clear the title status when the next prompt lands
# Idempotent: existing files are left alone, the gitignore entry is added once.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

PROJECT_ROOT=$(frame_project_root) || {
  echo "✗ frame: not inside a git repository" >&2
  exit 1
}
cd "$PROJECT_ROOT"

mkdir -p .frame/local

if [[ -f .frame/config.sh ]]; then
  echo "✓ .frame/config.sh already exists — leaving it alone"
else
  _name="${$(frame_main_wt "$PROJECT_ROOT"):t}"
  cat > .frame/config.sh <<EOF
# Frame project config — committed project facts (like an .env.dev + hooks).
# Personal overrides go in .frame/local/config.sh (gitignored, wins over this).
NAME=$_name

# Required: which buffers each frame opens (definitions live in frame's
# buffers.json). Authoritative even when empty — BUFFERS=() opens none.
BUFFERS=(claude local)

# Uncomment what applies; everything below is optional.
#SERVER_CMD='cargo run -p $_name-server'
#API_PORT=3000  VITE_PORT=5173  HMR_PORT=24678   # base ports; each frame scans upward
#WT_LINKS=(.env web/node_modules)   # gitignored assets symlinked into fresh worktrees

# Bring up everything the dev stack needs — runs on every \`frame wt\` boot, so
# keep it idempotent. Shared postgres/minio come from frame; only
# project-unique containers belong in this repo's compose file (pin those with
# --project-directory "\$MAIN_WT" so every frame shares one instance).
#stack_up() {
#  frame_services_up postgres minio
#  ensure_pg_db $_name
#  ensure_minio_bucket $_name-dev
#}

# Point the app at the shared services (exported before the server launches;
# wins over .env — dotenvy never overrides the environment).
#app_env() {
#  export DATABASE_URL=postgres://$_name:devpassword@localhost:5432/$_name
#}
EOF
  echo "✓ scaffolded .frame/config.sh — edit it to fit the project"
fi

if [[ -f .claude/settings.json ]]; then
  echo "✓ .claude/settings.json already exists — leaving it alone"
  echo "  (for notifications, add hooks yourself: Stop → 'frame notify',"
  echo "   UserPromptSubmit → 'frame status')"
else
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
  echo "✓ scaffolded .claude/settings.json — claude notifies via 'frame notify'"
fi

if [[ -f .gitignore ]] && grep -qxF '.frame/local/' .gitignore; then
  echo "✓ .gitignore already covers .frame/local/"
else
  printf '\n# frame — personal/local harness overrides, never committed\n.frame/local/\n' >> .gitignore
  echo "✓ added .frame/local/ to .gitignore"
fi
