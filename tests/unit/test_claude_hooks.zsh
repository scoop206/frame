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

# The flag points at a copy beside the machine config, never frame's own path
# (which may contain spaces); the copy tracks frame's file.
test_flags_pass_a_home_copy_of_the_hooks() {
  FRAME_GLOBAL_CONFIG="$SANDBOX/share/frame/config"   # not this machine's yolo switch
  frame_export_claude_flags 2>/dev/null
  assert_eq "$FRAME_CLAUDE_FLAGS" "--settings $SANDBOX/share/frame/claude-hooks.json"
  assert_eq "$(<$SANDBOX/share/frame/claude-hooks.json)" "$(<$(_hooks))" "copy differs"
}

test_flags_refresh_a_stale_copy() {
  FRAME_GLOBAL_CONFIG="$SANDBOX/share/frame/config"
  mkdir -p "$SANDBOX/share/frame"
  print -r -- '{"hooks":{}}' > "$SANDBOX/share/frame/claude-hooks.json"
  frame_export_claude_flags 2>/dev/null
  assert_eq "$(<$SANDBOX/share/frame/claude-hooks.json)" "$(<$(_hooks))" "stale copy kept"
}

test_flags_compose_with_yolo() {
  FRAME_GLOBAL_CONFIG="$SANDBOX/share/frame/config"
  local flags
  flags=$(frame_global_get() { [[ $1 == yolo ]] && print on; }
          frame_export_claude_flags 2>/dev/null; print -r -- "$FRAME_CLAUDE_FLAGS")
  assert_eq "$flags" "--settings $SANDBOX/share/frame/claude-hooks.json --dangerously-skip-permissions"
}

# frame at a path with spaces is fine — only the copy's path rides the flag.
test_flags_frame_path_with_spaces_still_works() {
  FRAME_GLOBAL_CONFIG="$SANDBOX/share/frame/config"
  local root="$SANDBOX/has space" out
  mkdir -p "$root/claude" && cp "$(_hooks)" "$root/claude/"
  out=$(FRAME_ROOT=$root; frame_export_claude_flags 2>&1; print -r -- "FLAGS=[$FRAME_CLAUDE_FLAGS]")
  assert_contains "$out" "FLAGS=[--settings $SANDBOX/share/frame/claude-hooks.json]"
}

# A home path with spaces can't ride the flag: warn, boot without hooks, and
# write nothing into the cwd.
test_flags_unsafe_home_warns_and_skips() {
  FRAME_GLOBAL_CONFIG="$SANDBOX/my home/frame/config"
  mkdir -p "$SANDBOX/work" && cd "$SANDBOX/work"
  local out
  out=$(frame_export_claude_flags 2>&1; print -r -- "FLAGS=[$FRAME_CLAUDE_FLAGS]")
  assert_contains "$out" "booting without frame's hooks"
  assert_contains "$out" "FLAGS=[]"
  assert_dir_absent "$SANDBOX/work/.claude"
}

run_tests "$0"
