# Frame project config — committed project facts (like an .env.dev + hooks).
# Personal overrides go in .frame/local/config.sh (gitignored, wins over this).
NAME=shared-services

# Whatever command starts this project's dev server — it runs verbatim in the
# layout's `server` buffer (omit SERVER_CMD to skip that buffer). It inherits
# the exported ports below, so the server should bind $PORT.
SERVER_CMD='cargo run -p shared-services-server'

# The primary checkout's normal dev ports (api / vite dev server / vite HMR
# websocket). These are bases: each frame scans upward from them for free
# ports (primary 3000/5173/24678 → first worktree 3001/5174/24679, …) and
# exports the result as PORT plus SHARED_SERVICES_API_PORT / _VITE_PORT /
# _HMR_PORT for the server and vite.config to read. Vite's defaults are
# 5173/24678; pick per-project bases (e.g. 3100/5273/24778) if you run several
# projects' primary envs side by side and want predictable ports.
API_PORT=3000  VITE_PORT=5173  HMR_PORT=24678

# Buffers: left unset, the when-gates in frame's buffers.json decide — this
# config yields local/server/vite/ngrok/claude. Uncomment to pin an exact
# list (order preserved, gates bypassed):
#BUFFERS=(claude server vite local)

# Runs on every `frame wt` boot (idempotent). Shared postgres/minio come from
# frame — no project-unique containers. ensure_pg_db / ensure_minio_bucket
# carve out this project's tenant (role + database, bucket) on the shared
# instances.
stack_up() {
  frame_services_up postgres minio
  ensure_pg_db shared-services
  ensure_minio_bucket shared-services-dev
}

# Point the app at the shared services. Exported before the server launches,
# so these win over .env (dotenvy never overrides the environment).
app_env() {
  export DATABASE_URL=postgres://shared-services:devpassword@localhost:5432/shared-services
  export S3_ENDPOINT=http://localhost:9000
}
