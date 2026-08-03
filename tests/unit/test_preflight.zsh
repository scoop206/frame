#!/usr/bin/env zsh
# In-process tests of the dependency preflight (frame_require / frame_dep_hint /
# frame_check_terminal in lib/helpers.sh). frame_require exits 127 on a miss, so
# each call runs in its own subshell and captures rc explicitly.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"
export FRAME_ROOT="$FRAME_CHECKOUT"
source "$FRAME_ROOT/lib/helpers.sh"

# zsh is guaranteed present (we're running under it); git too in any dev/CI box.

test_require_passes_when_present() {
  local out rc
  out=$( frame_require zsh git 2>&1 ) && rc=0 || rc=$?
  assert_eq "$rc" 0
  assert_eq "$out" ""
}

test_require_exits_127_on_missing() {
  local out rc
  out=$( frame_require zsh frame-nope-xyz 2>&1 ) && rc=0 || rc=$?
  assert_eq "$rc" 127
  assert_contains "$out" "missing required dependency"
  assert_contains "$out" "frame-nope-xyz"
}

test_require_lists_every_missing_dep() {
  local out rc
  out=$( frame_require frame-nope-1 frame-nope-2 2>&1 ) && rc=0 || rc=$?
  assert_eq "$rc" 127
  assert_contains "$out" "missing required dependencies"   # plural
  assert_contains "$out" "frame-nope-1"
  assert_contains "$out" "frame-nope-2"
}

test_dep_hint_names_installer() {
  assert_contains "$(frame_dep_hint nvim)"   "neovim"
  assert_contains "$(frame_dep_hint claude)" "Claude Code"
  assert_contains "$(frame_dep_hint git)"    "git"
}

# OSTYPE can be reassigned in-process (zsh only pins it at startup), so the
# platform gate and the docker-refusal paths are testable here — but NOT via
# run_frame: a child zsh recomputes OSTYPE and ignores the exported fake.
# docker/open are shadowed as functions so the PATH tripwire stubs never fire.

test_is_macos_matches_ostype() {
  local rc
  ( OSTYPE=darwin25.0; frame_is_macos ) && rc=0 || rc=$?
  assert_eq "$rc" 0
  ( OSTYPE=linux-gnu; frame_is_macos ) && rc=0 || rc=$?
  assert_eq "$rc" 1
}

test_ensure_docker_quiet_when_daemon_up() {
  local out rc
  docker() { return 0 }
  out=$( ensure_docker 2>&1 ) && rc=0 || rc=$?
  assert_eq "$rc" 0
  assert_eq "$out" ""
}

test_ensure_docker_refuses_off_macos_instead_of_hanging() {
  local out rc
  docker() { return 1 }
  out=$( OSTYPE=linux-gnu; ensure_docker 2>&1 ) && rc=0 || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "start your docker daemon"
}

test_ensure_docker_refuses_when_orbstack_launch_fails() {
  local out rc
  docker() { return 1 }
  open() { return 1 }
  out=$( OSTYPE=darwin25.0; ensure_docker 2>&1 ) && rc=0 || rc=$?
  assert_eq "$rc" 1
  assert_contains "$out" "couldn't launch OrbStack"
}

test_check_terminal_quiet_in_ghostty() {
  local out
  out=$( TERM_PROGRAM=ghostty frame_check_terminal 2>&1 )
  assert_eq "$out" ""
}

test_check_terminal_warns_elsewhere() {
  local out
  out=$( TERM_PROGRAM=Apple_Terminal frame_check_terminal 2>&1 )
  assert_contains "$out" "not running in Ghostty"
  assert_contains "$out" "Apple_Terminal"
}

run_tests "$0"
