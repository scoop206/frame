#!/usr/bin/env zsh
# Black-box tests of `frame swarm` — the toggle and its --context hook target.
# The sandbox redirects HOME, so the swarm= key lands in the sandbox's global
# config; it also strips FRAME_* from the env, so a test is "not in a frame"
# until it exports the identity itself.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

# ── the toggle ────────────────────────────────────────────────────────────────

test_default_is_off() {
  run_frame swarm
  assert_status 0
  assert_contains "$OUT" "swarm is off"
}

test_on_then_reports_on() {
  run_frame swarm on
  assert_status 0
  assert_contains "$OUT" "swarm on"
  run_frame swarm
  assert_contains "$OUT" "swarm is on"
}

test_off_after_on() {
  run_frame swarm on
  run_frame swarm off
  assert_contains "$OUT" "swarm off"
  run_frame swarm
  assert_contains "$OUT" "swarm is off"
}

test_bad_arg_exits_2() {
  run_frame swarm bogus
  assert_status 2
  assert_contains "$OUT" "Usage: frame swarm"
}

# ── --context: when it stays silent ───────────────────────────────────────────

test_context_silent_when_off() {
  # Off (the default) → no output even inside a frame.
  export FRAME_NAME=flipnem FRAME_TOPIC=inspect FRAME_VITE_PORT=5173
  run_frame swarm --context
  assert_status 0
  assert_eq "$OUT" "" "printed the block while swarm is off"
}

test_context_silent_when_not_in_a_frame() {
  # On, but no FRAME_NAME in the env (sandbox stripped it) → nothing to identify.
  run_frame swarm on
  run_frame swarm --context
  assert_status 0
  assert_eq "$OUT" "" "printed the block outside a frame"
}

# ── --context: the block ──────────────────────────────────────────────────────

test_context_prints_identity_and_rules() {
  run_frame swarm on
  export FRAME_NAME=flipnem FRAME_TOPIC=inspect-backticks FRAME_VITE_PORT=5173
  run_frame swarm --context
  assert_status 0
  assert_contains "$OUT" "frame flipnem/inspect-backticks"
  # the load-bearing safety rules
  assert_contains "$OUT" "run FOREGROUND"
  assert_contains "$OUT" "frame merge"
  assert_contains "$OUT" "frame wt -d"
  assert_contains "$OUT" "pushing to origin is NOT"
  assert_contains "$OUT" "answer, not an action"
}

test_context_port_line_present_with_port() {
  run_frame swarm on
  export FRAME_NAME=flipnem FRAME_TOPIC=x FRAME_VITE_PORT=5173
  run_frame swarm --context
  assert_contains "$OUT" "http://localhost:5173"
}

test_context_port_line_absent_without_port() {
  # A frame with no vite port (e.g. a shell frame) → generic verify line, no URL.
  run_frame swarm on
  export FRAME_NAME=flipnem FRAME_TOPIC=x
  run_frame swarm --context
  assert_not_contains "$OUT" "localhost:"
  assert_contains "$OUT" "Verify your own running app"
}

# ── --context: the swarm_context() append ─────────────────────────────────────

test_context_appends_project_hook() {
  # A swarm_context() in the machine-global config.sh is appended after the core.
  mkdir -p "$HOME/.config/frame"
  cat > "$HOME/.config/frame/config.sh" <<'CFG'
swarm_context() { echo; echo "OWNS: the flashcard app."; }
CFG
  run_frame swarm on
  export FRAME_NAME=flipnem FRAME_TOPIC=x FRAME_VITE_PORT=5173
  run_frame swarm --context
  assert_status 0
  assert_contains "$OUT" "OWNS: the flashcard app."
  # core still present and still ahead of the append (append can't replace it)
  assert_contains "$OUT" "run FOREGROUND"
}

run_tests "$0"
