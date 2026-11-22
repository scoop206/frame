#!/usr/bin/env zsh
# The shared-services credential contract (services/docker-compose.yml +
# frame_source_machine_config). The suite never runs docker (stub tripwire),
# so the compose side is a drift guard on the file itself: the FRAME_* env
# interpolations and the loopback-only port bindings are load-bearing —
# overrides documented in the README stop working if they drift.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"
export FRAME_ROOT="$FRAME_CHECKOUT"
source "$FRAME_ROOT/lib/helpers.sh"

_compose="$FRAME_ROOT/services/docker-compose.yml"

test_compose_credentials_are_env_overridable() {
  local _y="$(<$_compose)"
  assert_contains "$_y" 'POSTGRES_USER: ${FRAME_PG_USER:-frame}'
  assert_contains "$_y" 'POSTGRES_PASSWORD: ${FRAME_PG_PASSWORD:-devpassword}'
  assert_contains "$_y" 'MINIO_ROOT_USER: ${FRAME_MINIO_USER:-minioadmin}'
  assert_contains "$_y" 'MINIO_ROOT_PASSWORD: ${FRAME_MINIO_PASSWORD:-minioadmin}'
  # ensure_minio_bucket execs mc inside minio itself; no tools image to pull.
  assert_not_contains "$_y" 'minio/mc'
}

test_compose_ports_bind_loopback_only() {
  assert_contains "$(<$_compose)" '127.0.0.1:5432:5432'
  assert_contains "$(<$_compose)" '127.0.0.1:9000:9000'
  assert_contains "$(<$_compose)" '127.0.0.1:9001:9001'
  assert_eq "$(grep -cE '^\s+- "[0-9]+:[0-9]+"' "$_compose")" "0" \
    "a published port is missing its 127.0.0.1 host binding"
}

test_machine_config_sourced_when_present() {
  mkdir -p "$HOME/.config/frame"
  cat > "$HOME/.config/frame/config.sh" <<'EOF'
export FRAME_PG_PASSWORD=sekret
EOF
  frame_source_machine_config
  assert_eq "$FRAME_PG_PASSWORD" "sekret"
}

test_machine_config_absent_is_a_silent_noop() {
  unset FRAME_PG_PASSWORD
  local _out _rc
  _out=$(frame_source_machine_config 2>&1) && _rc=0 || _rc=$?
  assert_eq "$_rc" "0"
  assert_eq "$_out" ""
  assert_eq "${FRAME_PG_PASSWORD:-}" ""
}

test_ensure_minio_bucket_execs_mc_inside_minio() {
  docker() { print -r -- "docker $*" >> "$HOME/docker.log"; print "Bucket created"; }
  local _out
  _out=$(ensure_minio_bucket proj-dev 2>&1); assert_eq "$?" "0"
  assert_contains "$_out" "bucket proj-dev"
  local _log="$(<$HOME/docker.log)"
  assert_contains "$_log" "exec -T minio sh -c"
  assert_contains "$_log" "proj-dev"
  assert_not_contains "$_log" "run --rm"
}

test_ensure_minio_bucket_failure_is_loud_and_nonzero() {
  docker() { print -r -- "mc: <ERROR> Unable to make bucket"; return 1; }
  local _out _rc
  _out=$(ensure_minio_bucket proj-dev 2>&1) && _rc=0 || _rc=$?
  assert_eq "$_rc" "1"
  assert_contains "$_out" "couldn't create minio bucket proj-dev"
  assert_contains "$_out" "Unable to make bucket"
  assert_not_contains "$_out" "✓"
}

run_tests "$0"
