#!/usr/bin/env zsh
# In-process tests of frame_resolve's 4-dir lookup order + frame fallback.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"
export FRAME_ROOT="$FRAME_CHECKOUT"
source "$FRAME_ROOT/lib/helpers.sh"

# frame_resolve only reads $PROJECT_ROOT / $MAIN_WT — no git needed.

test_resolution_order() {
  PROJECT_ROOT="$SANDBOX/wt"
  MAIN_WT="$SANDBOX/main"
  local -a dirs
  dirs=("$PROJECT_ROOT/.frame/local" "$PROJECT_ROOT/.frame"
        "$MAIN_WT/.frame/local"      "$MAIN_WT/.frame")
  local d
  for d in $dirs; do
    mkdir -p "$d"
    touch "$d/foo.lua"
  done
  # Peel one layer per assertion: each time the winner disappears, the next
  # directory in the documented order takes over.
  for d in $dirs; do
    assert_eq "$(frame_resolve foo.lua)" "$d/foo.lua"
    rm "$d/foo.lua"
  done
}

test_fallback_to_frame_layouts() {
  PROJECT_ROOT="$SANDBOX/proj"
  MAIN_WT="$SANDBOX/proj"
  mkdir -p "$PROJECT_ROOT"
  assert_eq "$(frame_resolve worktree.lua)" "$FRAME_ROOT/layouts/worktree.lua"
}

test_missing_file_fails() {
  PROJECT_ROOT="$SANDBOX/proj"
  MAIN_WT="$SANDBOX/proj"
  mkdir -p "$PROJECT_ROOT"
  local out st
  out=$(frame_resolve missing.lua 2>&1) && st=0 || st=$?
  assert_eq "$st" "1"
  assert_contains "$out" "no missing.lua found"
}

run_tests "$0"
