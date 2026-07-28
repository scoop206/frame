#!/usr/bin/env zsh
# In-process tests of frame_global_get / frame_global_set (lib/helpers.sh).
# helpers.sh is sourced before any sandbox exists, so FRAME_GLOBAL_CONFIG
# captured the real HOME — every test repoints it into its sandbox first.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"
export FRAME_ROOT="$FRAME_CHECKOUT"
source "$FRAME_ROOT/lib/helpers.sh"

use_sandbox_config() {
  FRAME_GLOBAL_CONFIG="$HOME/.local/share/frame/config"
}

test_get_without_file_is_empty() {
  use_sandbox_config
  assert_eq "$(frame_global_get notify)" ""
}

test_first_set_creates_file_with_header() {
  use_sandbox_config
  frame_global_set notify off
  assert_file_exists "$FRAME_GLOBAL_CONFIG"
  assert_contains "$(<$FRAME_GLOBAL_CONFIG)" "# frame settings"
  assert_eq "$(frame_global_get notify)" "off"
}

test_set_updates_in_place() {
  use_sandbox_config
  frame_global_set notify off
  frame_global_set notify on
  assert_eq "$(frame_global_get notify)" "on"
  assert_eq "$(grep -c '^notify=' "$FRAME_GLOBAL_CONFIG")" "1"
}

test_set_preserves_other_lines() {
  use_sandbox_config
  mkdir -p "${FRAME_GLOBAL_CONFIG:h}"
  cat > "$FRAME_GLOBAL_CONFIG" <<'EOF'
# hand-written note

future_setting=7
EOF
  frame_global_set notify off
  assert_contains "$(<$FRAME_GLOBAL_CONFIG)" "# hand-written note"
  assert_eq "$(frame_global_get future_setting)" "7"
  assert_eq "$(frame_global_get notify)" "off"
}

test_get_last_occurrence_wins() {
  use_sandbox_config
  mkdir -p "${FRAME_GLOBAL_CONFIG:h}"
  cat > "$FRAME_GLOBAL_CONFIG" <<'EOF'
notify=on
notify=off
EOF
  assert_eq "$(frame_global_get notify)" "off"
}

run_tests "$0"
