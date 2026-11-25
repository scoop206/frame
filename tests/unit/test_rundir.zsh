#!/usr/bin/env zsh
# The runtime and state dir defaults (lib/helpers.sh).
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_load() {  # source helpers fresh with the given env, print a var
  ( export FRAME_ROOT=$FRAME_CHECKOUT; source "$FRAME_CHECKOUT/lib/helpers.sh"; print -r -- "${(P)1}" )
}

test_rundir_uses_xdg_runtime_dir_when_present() {
  mkdir -p "$SANDBOX/run"
  unset FRAME_RUNDIR
  export XDG_RUNTIME_DIR="$SANDBOX/run"
  assert_eq "$(_load FRAME_RUNDIR)" "$SANDBOX/run/frame"
}

test_rundir_falls_back_to_tmp_frame() {
  unset FRAME_RUNDIR XDG_RUNTIME_DIR
  assert_eq "$(_load FRAME_RUNDIR)" /tmp/frame
}

test_rundir_ignores_a_missing_xdg_runtime_dir() {
  unset FRAME_RUNDIR
  export XDG_RUNTIME_DIR="$SANDBOX/nope"
  assert_eq "$(_load FRAME_RUNDIR)" /tmp/frame
}

test_rundir_override_wins() {
  export FRAME_RUNDIR="$SANDBOX/mine" XDG_RUNTIME_DIR="$SANDBOX"
  assert_eq "$(_load FRAME_RUNDIR)" "$SANDBOX/mine"
}

test_statedir_defaults() {
  unset FRAME_STATEDIR XDG_STATE_HOME
  assert_eq "$(_load FRAME_STATEDIR)" "$HOME/.local/state/frame"
  export XDG_STATE_HOME="$SANDBOX/st"
  assert_eq "$(_load FRAME_STATEDIR)" "$SANDBOX/st/frame"
}

run_tests "$0"
