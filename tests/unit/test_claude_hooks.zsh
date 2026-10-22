#!/usr/bin/env zsh
# claude/hooks.json — the hooks every frame's claude boots with — and the
# --settings flag that hands it over (frame_export_claude_flags).
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"
export FRAME_ROOT="$FRAME_CHECKOUT"
source "$FRAME_ROOT/lib/helpers.sh"

_hooks() { print -r -- "$FRAME_ROOT/claude/hooks.json"; }

test_hooks_file_is_valid_json() {
  command -v jq >/dev/null 2>&1 || { skip "jq not installed"; return; }
  jq -e .hooks "$(_hooks)" >/dev/null || fail "claude/hooks.json isn't valid JSON with a hooks key"
}

test_hooks_file_wires_every_frame_hook() {
  command -v jq >/dev/null 2>&1 || { skip "jq not installed"; return; }
  local f=$(_hooks) row ev cmd
  for row in \
    'Stop|frame notify >' \
    'Stop|frame reply' \
    'UserPromptSubmit|frame status --prompt' \
    'Notification|frame notify --blocked' \
    'SessionStart|frame swarm --context' \
    'PostToolUse|frame reload-editor'; do
    ev=${row%%|*} cmd=${row#*|}
    assert_contains "$(jq -r ".hooks.${ev}[].hooks[].command" "$f")" "$cmd" "$ev lacks '$cmd'"
  done
  assert_eq "$(jq -r '.hooks.PostToolUse[0].matcher' "$f")" "Edit|Write|MultiEdit|NotebookEdit"
}

test_hooks_never_fail_the_hook() {
  # Every command ends in `|| true` so a frame failure never disrupts claude.
  command -v jq >/dev/null 2>&1 || { skip "jq not installed"; return; }
  local c
  jq -r '.hooks[][].hooks[].command' "$(_hooks)" | while IFS= read -r c; do
    [[ "$c" == *'|| true' ]] || fail "hook can fail: $c"
  done
}

test_flags_pass_the_hooks_file() {
  FRAME_GLOBAL_CONFIG="$SANDBOX/no-config"   # not this machine's yolo switch
  frame_export_claude_flags 2>/dev/null
  assert_contains "$FRAME_CLAUDE_FLAGS" "--settings $(_hooks)"
}

test_flags_compose_with_yolo() {
  local flags
  flags=$(frame_global_get() { [[ $1 == yolo ]] && print on; }
          frame_export_claude_flags 2>/dev/null; print -r -- "$FRAME_CLAUDE_FLAGS")
  assert_eq "$flags" "--settings $(_hooks) --dangerously-skip-permissions"
}

test_flags_skip_a_path_with_spaces() {
  FRAME_GLOBAL_CONFIG="$SANDBOX/no-config"
  local root="$SANDBOX/has space"
  mkdir -p "$root/claude" && cp "$(_hooks)" "$root/claude/"
  local err
  err=$(FRAME_ROOT=$root; frame_export_claude_flags 2>&1; print -r -- "FLAGS=[$FRAME_CLAUDE_FLAGS]")
  assert_contains "$err" "boots without frame's hooks"
  assert_contains "$err" "FLAGS=[]"
}

run_tests "$0"
