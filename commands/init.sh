# frame init — scaffold a project's .frame/ directory:
#   .frame/config.sh        committed project facts (template, edit to fit)
#   .frame/local/           personal overrides + state — appended to .gitignore
#   .claude/settings.json   claude-code hooks: `frame notify` when a turn ends,
#                           clear the title status when the next prompt lands
# Also builds the machine-global banner app (notifier.sh) so banners wear the
# frame icon from the first init on.
# Idempotent: existing files are left alone, the gitignore entry is added
# once, and the banner app is rebuilt only when its inputs changed.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

PROJECT_ROOT=$(frame_project_root) || {
  echo "$X_MARK frame: not inside a git repository" >&2
  exit 1
}
cd "$PROJECT_ROOT"

mkdir -p .frame/local

if [[ -f .frame/config.sh ]]; then
  echo "$OK_MARK .frame/config.sh already exists — leaving it alone"
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
  echo "$OK_MARK scaffolded .frame/config.sh — edit it to fit the project"
fi

if [[ -f .claude/settings.json ]]; then
  echo "$OK_MARK .claude/settings.json already exists — leaving it alone"
  echo "  (for notifications, add hooks yourself: Stop → 'frame notify',"
  echo "   UserPromptSubmit → 'frame status')"
else
  frame_write_claude_hooks
  echo "$OK_MARK scaffolded .claude/settings.json — claude notifies via 'frame notify'"
fi

if [[ -f .gitignore ]] && grep -qxF '.frame/local/' .gitignore; then
  echo "$OK_MARK .gitignore already covers .frame/local/"
else
  printf '\n# frame — personal/local harness overrides, never committed\n.frame/local/\n' >> .gitignore
  echo "$OK_MARK added .frame/local/ to .gitignore"
fi

# Banner app (machine-global, not per-project): notifier.sh skips by content
# fingerprint, so only the first init on a machine — or one after the icon
# art or brew copy changed — actually builds. Own process + || true: a failed
# build (no homebrew, say) leaves the osascript banner fallback, never a
# broken init. Not `( source … ) || true` — in a ||-tested subshell zsh
# suppresses ERR_EXIT, and notifier.sh leans on set -e between its steps.
"$FRAME_ROOT/bin/frame" notifier || true
