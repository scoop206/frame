# Frame project config — committed project facts (like an .env.dev + hooks).
# Personal overrides go in .frame/local/config.sh (gitignored, wins over this).
NAME=sidecar
BUFFERS=(local server vite ngrok claude)
SERVER_CMD='cargo run -p sidecar-server'
API_PORT=3200  VITE_PORT=5373  HMR_PORT=24878   # base ports; each frame scans upward

# Runs on every `frame wt` boot (idempotent). Shared postgres/minio come from
# frame; only the worker sidecar is project-unique. It's profile-gated and
# built from source, so it's started explicitly with --build to pick up
# changes. --project-directory pins compose to the primary checkout: one
# shared sidecar instance (compose project "sidecar") no matter which frame
# boots it — from a worktree, compose would otherwise derive a fresh project
# named after the worktree dir and fight over :8890.
stack_up() {
  frame_services_up postgres minio
  ensure_pg_db sidecar
  ensure_minio_bucket sidecar-dev
  echo "▶ building + starting worker sidecar…"
  docker compose --project-directory "$MAIN_WT" --profile worker up -d --build worker
  wait_for_url http://localhost:8890/health worker
}

# Point the app at the shared services + sidecar. Exported before the server
# launches, so these win over .env (dotenvy never overrides the environment).
app_env() {
  export DATABASE_URL=postgres://sidecar:devpassword@localhost:5432/sidecar
  export S3_ENDPOINT=http://localhost:9000
  export WORKER_URL=http://localhost:8890
}
