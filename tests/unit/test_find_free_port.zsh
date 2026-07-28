#!/usr/bin/env zsh
# In-process tests of find_free_port against the deterministic lsof stub.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"
export FRAME_ROOT="$FRAME_CHECKOUT"
source "$FRAME_ROOT/lib/helpers.sh"

test_free_start_port_returned_as_is() {
  export FAKE_BUSY_PORTS=""
  assert_eq "$(find_free_port 4000)" "4000"
}

test_scans_upward_past_busy_ports() {
  export FAKE_BUSY_PORTS="4000 4001"
  assert_eq "$(find_free_port 4000)" "4002"
}

test_busy_port_above_start_is_irrelevant() {
  export FAKE_BUSY_PORTS="4001"
  assert_eq "$(find_free_port 4000)" "4000"
}

run_tests "$0"
