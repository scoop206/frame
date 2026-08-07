# NAME isn't set: it defaults to the checkout's directory name.

# Whatever command starts this project's dev server — it runs verbatim in the
# layout's `server` buffer.  It inherits the exported ports below, so the server 
# should bind $PORT (see buffers.json). If it does not then cross connect in app_env() below
SERVER_CMD='cargo run -p standard-web-server'

# The primary checkout's normal dev ports (api / vite dev server / vite HMR
# websocket). These are bases: each frame scans upward from them for free
# ports (primary 3000/5173/24678 → first worktree 3001/5174/24679, …) and
# exports the result as PORT plus FRAME_API_PORT / FRAME_VITE_PORT /
# FRAME_HMR_PORT for the server and vite.config to read. Vite's defaults are
# 5173/24678; pick per-project bases (e.g. 3100/5273/24778) if you run several
# projects' primary envs side by side and want predictable ports.
API_PORT=3000  VITE_PORT=5173  HMR_PORT=24678

# Required: which buffers each frame opens (definitions live in frame's
# buffers.json).
BUFFERS=(local server vite ngrok claude)

# Runs on every `frame wt` boot (idempotent). 
stack_up() {
  frame_services_up postgres minio
  ensure_pg_db standard-web
  ensure_minio_bucket standard-web-dev
}

# Point the app at the shared services. Exported before the server launches,
app_env() {
  # devpassword is ensure_pg_db's dev-only default — pass your own
  # (ensure_pg_db standard-web PASSWORD) and update this URL to match.
  export DATABASE_URL=postgres://standard-web:devpassword@localhost:5432/standard-web
  export S3_ENDPOINT=http://localhost:9000

  # As defined in buffers.json, frame tracks the PORT env var; if your app
  # reads a differently named one, export it here.
  # export SERVICE_PORT="$PORT"
}
