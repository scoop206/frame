NAME=sidecar
BUFFERS=(local server vite ngrok claude)
SERVER_CMD='cargo run -p sidecar-server'
API_PORT=3200  VITE_PORT=5373  HMR_PORT=24878   # base ports; each frame scans upward

# Runs on every `frame wt` boot (idempotent)
stack_up() {
  frame_services_up postgres minio

  # our sidecar needs a database so use the helper function
  ensure_pg_db sidecar

  # our sidecar needs a minio bucket so use the helper function
  ensure_minio_bucket sidecar-dev

  echo "▶ building + starting sidecar…"
  docker compose --project-directory "$MAIN_WT" --profile sidecar up -d --build sidecar
  wait_for_url http://localhost:8890/health sidecar
}

app_env() {
  # devpassword is ensure_pg_db's dev-only default — pass your own
  # (ensure_pg_db sidecar PASSWORD) and update this URL to match.
  export DATABASE_URL=postgres://sidecar:devpassword@localhost:5432/sidecar
  export S3_ENDPOINT=http://localhost:9000
  export SIDECAR_URL=http://localhost:8890
}
