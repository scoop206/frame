#!/usr/bin/env zsh
# White-box tests for frame_trust_dir: pre-accepting claude's workspace-trust
# dialog for a worktree by seeding .projects[DIR].hasTrustDialogAccepted in
# ~/.claude.json, without disturbing anything else in the file.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"
export FRAME_ROOT="$FRAME_CHECKOUT"
source "$FRAME_ROOT/lib/helpers.sh"

_trusted() {  # _trusted DIR — print the seeded flag for DIR
  jq -r --arg p "${1:A}" '.projects[$p].hasTrustDialogAccepted' "$HOME/.claude.json"
}

test_seeds_trust_and_keeps_other_keys() {
  command -v jq >/dev/null || return 0
  local wt="$HOME/git/_proj-topic"; mkdir -p "$wt"
  print -r -- '{"userID":"u1","projects":{"/other":{"allowedTools":["x"]}}}' > "$HOME/.claude.json"
  frame_trust_dir "$wt"
  assert_eq "$(_trusted "$wt")" "true"
  assert_eq "$(jq -r '.userID' "$HOME/.claude.json")" "u1"
  assert_eq "$(jq -r '.projects["/other"].allowedTools[0]' "$HOME/.claude.json")" "x"
}

test_merges_into_existing_project_entry() {
  command -v jq >/dev/null || return 0
  local wt="$HOME/git/_proj-merge"; mkdir -p "$wt"
  jq -n --arg p "${wt:A}" '{projects:{($p):{lastCost:3,hasTrustDialogAccepted:false}}}' > "$HOME/.claude.json"
  frame_trust_dir "$wt"
  assert_eq "$(_trusted "$wt")" "true"
  assert_eq "$(jq -r --arg p "${wt:A}" '.projects[$p].lastCost' "$HOME/.claude.json")" "3"
}

test_already_trusted_is_untouched() {
  command -v jq >/dev/null || return 0
  local wt="$HOME/git/_proj-done"; mkdir -p "$wt"
  jq -n --arg p "${wt:A}" '{projects:{($p):{hasTrustDialogAccepted:true}}}' > "$HOME/.claude.json"
  touch -t 202001010000 "$HOME/.claude.json"
  local before=$(stat -f %m "$HOME/.claude.json" 2>/dev/null || stat -c %Y "$HOME/.claude.json")
  frame_trust_dir "$wt"
  local after=$(stat -f %m "$HOME/.claude.json" 2>/dev/null || stat -c %Y "$HOME/.claude.json")
  assert_eq "$after" "$before"
}

test_missing_config_is_a_noop() {
  rm -f "$HOME/.claude.json"
  frame_trust_dir "$HOME/git/_proj-none"
  [[ -e "$HOME/.claude.json" ]] && fail "must not create ~/.claude.json"
  return 0
}

test_corrupt_config_left_alone() {
  command -v jq >/dev/null || return 0
  print -r -- 'not json' > "$HOME/.claude.json"
  frame_trust_dir "$HOME/git/_proj-bad"
  assert_eq "$(cat "$HOME/.claude.json")" "not json"
  assert_eq "$(print -r -- "$HOME"/.claude.json.frame.*(N) | wc -w | tr -d ' ')" "0"
}

run_tests "$0"
