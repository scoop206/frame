#!/usr/bin/env zsh
# frame init end-to-end in scratch repos.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

test_init_fresh_repo() {
  make_repo
  run_frame init
  assert_status 0
  assert_contains "$OUT" "scaffolded — edit it to fit"
  assert_file_exists "$REPO/.frame/config.sh"
  assert_contains "$(<$REPO/.frame/config.sh)" "NAME=$TNAME"
  assert_dir_exists "$REPO/.frame/local"
  grep -qxF '.frame/local/' "$REPO/.gitignore" || fail ".gitignore missing .frame/local/"
}

test_init_is_idempotent() {
  make_repo
  run_frame init
  local sum_before=$(cksum "$REPO/.frame/config.sh")
  run_frame init
  assert_status 0
  assert_contains "$OUT" "already exists — left alone"
  assert_contains "$OUT" "already covers .frame/local/"
  assert_eq "$(cksum "$REPO/.frame/config.sh")" "$sum_before" "config.sh was rewritten"
  assert_eq "$(grep -cxF '.frame/local/' "$REPO/.gitignore")" "1" "gitignore entry duplicated"
}

test_init_respects_existing_gitignore_entry() {
  make_repo
  print -r -- '.frame/local/' > "$REPO/.gitignore"
  run_frame init
  assert_status 0
  assert_contains "$OUT" "already covers .frame/local/"
  assert_eq "$(grep -cxF '.frame/local/' "$REPO/.gitignore")" "1"
}

test_init_warns_when_existing_settings_lacks_hooks() {
  make_repo
  mkdir -p "$REPO/.claude"
  print -r -- '{"hooks":{}}' > "$REPO/.claude/settings.json"
  local before=$(cksum "$REPO/.claude/settings.json")
  run_frame init
  # left out of sync (no --force) → init doubles as a drift check, exit 3
  assert_status 3
  assert_contains "$OUT" "frame hooks missing, re-sync with --force"
  assert_contains "$OUT" "frame's notification hooks"
  assert_contains "$OUT" "frame notify"
  # the caution points at --force as the one-shot fix
  assert_contains "$OUT" "frame init --force"
  # the existing file must be left byte-for-byte untouched
  assert_eq "$(cksum "$REPO/.claude/settings.json")" "$before" "settings.json was rewritten"
}

test_init_force_overwrites_frame_only_settings() {
  # --force re-syncs a settings.json that holds nothing but stale/empty frame
  # hooks: the file is rewritten to frame's canonical hooks, no caution printed.
  command -v jq >/dev/null 2>&1 || { skip "jq not installed"; return; }
  make_repo
  mkdir -p "$REPO/.claude"
  print -r -- '{"hooks":{}}' > "$REPO/.claude/settings.json"
  run_frame init --force
  assert_status 0
  assert_contains "$OUT" "overwritten (--force)"
  assert_contains "$(<$REPO/.claude/settings.json)" "frame notify --blocked"
  assert_contains "$(<$REPO/.claude/settings.json)" "frame status --prompt"
  # no hand-merge caution when --force did the job
  if [[ "$OUT" == *"re-sync with --force"* ]]; then
    fail "printed the missing-hooks caution after --force already fixed it"
  fi
}

test_init_force_refuses_custom_content() {
  # --force must NOT clobber a settings.json carrying the user's own content
  # (here a top-level "permissions" key): it leaves the file byte-for-byte
  # untouched and points the user at a hand-merge.
  command -v jq >/dev/null 2>&1 || { skip "jq not installed"; return; }
  make_repo
  mkdir -p "$REPO/.claude"
  print -r -- '{"permissions":{"allow":["Bash"]},"hooks":{}}' > "$REPO/.claude/settings.json"
  local before=$(cksum "$REPO/.claude/settings.json")
  run_frame init --force
  # --force refused (custom content) → still out of sync → exit 3
  assert_status 3
  assert_contains "$OUT" "has custom content"
  assert_contains "$OUT" "merge these in by hand"
  assert_eq "$(cksum "$REPO/.claude/settings.json")" "$before" "--force clobbered custom content"
}

test_init_force_leaves_wired_settings_alone() {
  # --force only rewrites when hooks are out of sync; an already-wired file is
  # left byte-for-byte untouched.
  make_repo
  run_frame init            # writes frame's hooks
  local before=$(cksum "$REPO/.claude/settings.json")
  run_frame init --force    # nothing to re-sync
  assert_status 0
  assert_contains "$OUT" "already wired for frame"
  assert_eq "$(cksum "$REPO/.claude/settings.json")" "$before" "wired settings.json was rewritten"
}

test_init_rejects_unknown_flag() {
  make_repo
  run_frame init --bogus
  assert_status 2
  assert_contains "$OUT" "unknown flag"
}

test_init_quiet_when_existing_settings_already_wired() {
  make_repo
  run_frame init          # writes frame's hooks
  run_frame init          # second run sees them already wired
  assert_status 0
  assert_contains "$OUT" "already wired for frame"
  # no hand-merge warning when the hooks are present
  if [[ "$OUT" == *"merge by hand"* ]]; then
    fail "warned about hooks that are already wired"
  fi
}

test_init_scaffolds_notification_hook() {
  # A fresh scaffold wires the Notification hook → `frame notify --blocked`, so
  # a frame that pauses mid-turn on a permission prompt surfaces as "blocked".
  make_repo
  run_frame init
  assert_status 0
  assert_contains "$(<$REPO/.claude/settings.json)" '"Notification"'
  assert_contains "$(<$REPO/.claude/settings.json)" "frame notify --blocked"
}

test_init_scaffolds_sessionstart_hook() {
  # A fresh scaffold wires the SessionStart hook → `frame swarm --context`, the
  # frame-awareness injection point (a no-op until `frame swarm on`).
  make_repo
  run_frame init
  assert_status 0
  assert_contains "$(<$REPO/.claude/settings.json)" '"SessionStart"'
  assert_contains "$(<$REPO/.claude/settings.json)" "frame swarm --context"
}

test_init_scaffolds_posttooluse_hook() {
  # A fresh scaffold wires the PostToolUse hook → `frame reload-editor` (matcher
  # Edit|Write|MultiEdit|NotebookEdit), so this frame's nvim buffer follows
  # Claude's on-disk edits without a manual :e.
  make_repo
  run_frame init
  assert_status 0
  local body=$(<$REPO/.claude/settings.json)
  assert_contains "$body" '"PostToolUse"'
  assert_contains "$body" "frame reload-editor"
  assert_contains "$body" "Edit|Write|MultiEdit|NotebookEdit"
}

test_init_flags_wiring_predating_notification_hook() {
  # A settings.json carrying the pre-Notification frame hooks (fingerprint
  # present, --blocked hook absent) is stale: flag it for a hand-merge rather
  # than reporting "already wired", and name the missing hook.
  make_repo
  mkdir -p "$REPO/.claude"
  print -r -- '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"frame notify"},{"type":"command","command":"frame reply"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"frame status --prompt"}]}]}}' \
    > "$REPO/.claude/settings.json"
  run_frame init
  # stale pre-Notification wiring, no --force → out of sync → exit 3
  assert_status 3
  assert_contains "$OUT" "frame hooks missing, re-sync with --force"
  assert_contains "$OUT" "frame notify --blocked"
}

test_init_outside_git_fails() {
  mkdir -p "$SANDBOX/plain"
  cd "$SANDBOX/plain"
  run_frame init
  assert_status 1
  assert_contains "$OUT" "not inside a git repository"
}

test_init_in_worktree_uses_primary_name() {
  make_repo
  git -C "$REPO" worktree add -q "$SANDBOX/some-random-dirname" -b topic
  cd "$SANDBOX/some-random-dirname"
  run_frame init
  assert_status 0
  # NAME comes from the primary checkout's basename, not the worktree dir
  assert_contains "$(<$SANDBOX/some-random-dirname/.frame/config.sh)" "NAME=$TNAME"
}

run_tests "$0"
