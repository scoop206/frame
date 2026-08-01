#!/usr/bin/env zsh
# Black-box tests of `frame swarm` — the level dial and its --context hook target.
# The sandbox redirects HOME, so the swarm= key lands in the sandbox's global
# config; it also strips FRAME_* from the env, so a test is "not in a frame"
# until it exports the identity itself.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

# ── the dial ──────────────────────────────────────────────────────────────────

test_default_is_off() {
  run_frame swarm
  assert_status 0
  assert_contains "$OUT" "swarm is off (level 0)"
}

test_set_level_1() {
  run_frame swarm 1
  assert_status 0
  assert_contains "$OUT" "level 1 (aware)"
  run_frame swarm
  assert_contains "$OUT" "level 1 (aware)"
}

test_set_level_2() {
  run_frame swarm 2
  assert_status 0
  assert_contains "$OUT" "level 2 (ask)"
  run_frame swarm
  assert_contains "$OUT" "level 2 (ask)"
}

test_on_off_aliases_map_to_1_and_0() {
  run_frame swarm on
  assert_contains "$OUT" "level 1 (aware)"
  run_frame swarm off
  assert_contains "$OUT" "swarm off"
  run_frame swarm
  assert_contains "$OUT" "level 0"
}

test_singularity_clamps_to_max_and_says_so() {
  run_frame swarm singularity
  assert_status 0
  assert_contains "$OUT" "clamped to level 2"
  assert_contains "$OUT" "isn't implemented yet"
  # the dial is really armed at the ceiling, not left off
  run_frame swarm
  assert_contains "$OUT" "level 2 (ask)"
}

test_unbuilt_level_refused() {
  run_frame swarm 3
  assert_status 2
  assert_contains "$OUT" "isn't built yet"
}

test_bad_arg_exits_2() {
  run_frame swarm bogus
  assert_status 2
  assert_contains "$OUT" "Usage: frame swarm"
}

# ── --context: when it stays silent ───────────────────────────────────────────

test_context_silent_when_off() {
  export FRAME_NAME=flipnem FRAME_TOPIC=inspect FRAME_VITE_PORT=5173
  run_frame swarm --context
  assert_status 0
  assert_eq "$OUT" "" "printed the block while swarm is off"
}

test_context_silent_when_not_in_a_frame() {
  run_frame swarm 1
  run_frame swarm --context      # no FRAME_NAME (sandbox stripped it)
  assert_status 0
  assert_eq "$OUT" "" "printed the block outside a frame"
}

# ── --context: the level-1 core ───────────────────────────────────────────────

test_context_level_1_has_identity_and_safety() {
  run_frame swarm 1
  export FRAME_NAME=flipnem FRAME_TOPIC=inspect-backticks FRAME_VITE_PORT=5173
  run_frame swarm --context
  assert_status 0
  assert_contains "$OUT" "frame flipnem/inspect-backticks"
  assert_contains "$OUT" "run FOREGROUND"
  assert_contains "$OUT" "frame merge"
  assert_contains "$OUT" "frame wt -d"
  assert_contains "$OUT" "pushing to origin is NOT"
  assert_contains "$OUT" "answer it"
}

test_context_level_1_omits_ask_recipe() {
  # The ask-a-sibling recipe belongs to level 2 — level 1 must not carry it.
  run_frame swarm 1
  export FRAME_NAME=flipnem FRAME_TOPIC=x FRAME_VITE_PORT=5173
  run_frame swarm --context
  assert_not_contains "$OUT" "frame req NAME/TOPIC"
  assert_not_contains "$OUT" "ask sibling frames"
}

test_context_port_line_present_with_port() {
  run_frame swarm 1
  export FRAME_NAME=flipnem FRAME_TOPIC=x FRAME_VITE_PORT=5173
  run_frame swarm --context
  assert_contains "$OUT" "http://localhost:5173"
}

test_context_port_line_absent_without_port() {
  run_frame swarm 1
  export FRAME_NAME=flipnem FRAME_TOPIC=x
  run_frame swarm --context
  assert_not_contains "$OUT" "localhost:"
  assert_contains "$OUT" "Verify your own running app"
}

# ── --context: the level-2 additions ──────────────────────────────────────────

test_context_level_2_adds_ask_recipe() {
  run_frame swarm 2
  export FRAME_NAME=flipnem FRAME_TOPIC=x FRAME_VITE_PORT=5173
  run_frame swarm --context
  assert_status 0
  assert_contains "$OUT" "ask sibling frames"
  assert_contains "$OUT" "frame req NAME/TOPIC"
  assert_contains "$OUT" "inbox --wait --for"
  assert_contains "$OUT" "2 broker hops"
  # level-1 core is still there — level 2 is additive, not a replacement
  assert_contains "$OUT" "run FOREGROUND"
}

# ── --context: the swarm_context() append ─────────────────────────────────────

test_context_appends_project_hook() {
  mkdir -p "$HOME/.config/frame"
  cat > "$HOME/.config/frame/config.sh" <<'CFG'
swarm_context() { echo; echo "OWNS: the flashcard app."; }
CFG
  run_frame swarm 1
  export FRAME_NAME=flipnem FRAME_TOPIC=x FRAME_VITE_PORT=5173
  run_frame swarm --context
  assert_status 0
  assert_contains "$OUT" "OWNS: the flashcard app."
  assert_contains "$OUT" "run FOREGROUND"   # core still present, ahead of the append
}

run_tests "$0"
