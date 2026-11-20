#!/usr/bin/env zsh
# frame_reap_orphans_in — teardown stops dev servers a dead frame left running
# in its worktree (they recreate the dir as a cache-only husk after git removes
# it), but never signals a process that still has a live parent. Uses the real
# lsof and real processes, so the stub lsof is taken off PATH.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"
export FRAME_ROOT="$FRAME_CHECKOUT"
source "$FRAME_ROOT/lib/helpers.sh"

_real_path() { path=( ${path:#*/tests/stubs} ); }

test_orphan_is_stopped() {
  _real_path
  (( $+commands[lsof] )) || return 0
  local d="${${:-$SANDBOX/wt}:A}" pidf="$SANDBOX/orphan.pid"
  mkdir -p "$d"
  # The subshell exits at once, so its sleep is reparented to pid 1 — the shape
  # of a dev server left behind by a dead nvim.
  ( cd "$d" && { sleep 60 & print $! > "$pidf"; } )
  local pid=$(<"$pidf")
  for _ in {1..20}; do [[ "$(ps -o ppid= -p $pid | tr -d ' ')" == 1 ]] && break; sleep 0.1; done
  local out=$(frame_reap_orphans_in "$d" 2>&1)
  assert_contains "$out" "stopped leftover process $pid"
  if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid"; fail "orphan $pid still running"; fi
}

test_process_with_live_parent_is_left_alone() {
  _real_path
  (( $+commands[lsof] )) || return 0
  local d="${${:-$SANDBOX/wt}:A}"
  mkdir -p "$d"
  # Child of this test shell (alive, cwd outside d): like your own shell cd'd
  # into the worktree from another tab.
  zsh -fc "cd ${(q)d} && sleep 60" &
  local parent=$!
  sleep 0.3
  local out=$(frame_reap_orphans_in "$d" 2>&1)
  assert_contains "$out" "not ours to stop"
  assert_not_contains "$out" "stopped leftover"
  kill -0 "$parent" 2>/dev/null || fail "live-parented holder was signalled"
  pkill -KILL -P "$parent" 2>/dev/null || true
  kill -KILL "$parent" 2>/dev/null || true
}

test_nothing_holding_is_a_quick_noop() {
  _real_path
  local d="$SANDBOX/empty"; mkdir -p "$d"
  assert_eq "$(frame_reap_orphans_in "$d" 2>&1)" ""
}

run_tests "$0"
