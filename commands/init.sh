# frame init — scaffold a project's .frame/ directory:
#   .frame/config.sh   committed project facts (template, edit to fit)
#   .frame/local/      personal overrides + state — appended to .gitignore
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

# Uncomment what applies; a project defining none of these still gets
# \`frame wt\` and \`frame merge\` with sensible defaults.
#SERVER_CMD='cargo run -p $_name-server'
#API_PORT=3000  VITE_PORT=5173  HMR_PORT=24678   # primary-env ports; worktrees scan upward
#NGROK_AUTO=1          # auto-run ngrok in the primary layout (default: pre-filled prompt)
#WT_LINKS=(.env web/node_modules)   # gitignored assets symlinked into fresh worktrees

# Bring up everything the dev stack needs. Shared postgres/minio come from
# frame; only project-unique containers belong in this repo's compose file.
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

if [[ -f .gitignore ]] && grep -qxF '.frame/local/' .gitignore; then
  echo "✓ .gitignore already covers .frame/local/"
else
  printf '\n# frame — personal/local harness overrides, never committed\n.frame/local/\n' >> .gitignore
  echo "✓ added .frame/local/ to .gitignore"
fi
