#!/usr/bin/env zsh
# frame wt -d: safety rails, forced teardown, and the detached reaper.
# No nvim socket ever exists here (unique $TNAME), so teardown takes the
# "no nvim socket" path and the nvim stub is never invoked.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

setup_frame() {
  # repo + booted worktree "topic", cwd left in the primary checkout
  make_repo
  write_config <<'EOF'
BUFFERS=()
EOF
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame wt topic
  assert_status 0
  unset FAKE_NVIM_LOG
  WT="$SANDBOX/_$TNAME-topic"
  cd "$REPO"
}

test_clean_teardown_removes_worktree_and_branch() {
  setup_frame
  run_frame wt -d topic
  assert_status 0
  assert_contains "$OUT" "no nvim socket"
  assert_contains "$OUT" "✓ removed worktree and branch topic"
  assert_dir_absent "$WT"
  assert_branch_absent "$REPO" topic
}

test_dirty_worktree_blocks_teardown() {
  setup_frame
  touch "$WT/junk"
  run_frame wt -d topic
  assert_status 1
  assert_contains "$OUT" "uncommitted/untracked files"
  assert_dir_exists "$WT"
  assert_branch_exists "$REPO" topic
}

test_unmerged_branch_blocks_teardown() {
  setup_frame
  commit_file "$WT" work.txt "unmerged work"
  run_frame wt -d topic
  assert_status 1
  assert_contains "$OUT" "commits not on main"
  assert_contains "$OUT" "frame merge"
  assert_dir_exists "$WT"
}

test_force_overrides_both_rails() {
  setup_frame
  commit_file "$WT" work.txt "unmerged work"
  touch "$WT/junk"
  run_frame wt -d -f topic
  assert_status 0
  assert_dir_absent "$WT"
  assert_branch_absent "$REPO" topic
}

test_live_holder_blocks_socketless_teardown() {
  # No socket exists here (unique $TNAME), so teardown can't confirm the session
  # is down. A live process still sitting in the worktree (its cwd) must block
  # removal rather than have the tree deleted out from under it — the husk bug.
  setup_frame
  export FAKE_HELD_DIR="$WT"
  run_frame wt -d topic
  unset FAKE_HELD_DIR
  assert_status 1
  assert_contains "$OUT" "still in use"
  assert_dir_exists "$WT"
  assert_branch_exists "$REPO" topic
}

test_force_teardown_ignores_live_holder() {
  # -f is the deliberate nuke: it skips the holder check entirely.
  setup_frame
  export FAKE_HELD_DIR="$WT"
  run_frame wt -d -f topic
  unset FAKE_HELD_DIR
  assert_status 0
  assert_dir_absent "$WT"
  assert_branch_absent "$REPO" topic
}

test_missing_worktree_fails() {
  make_repo
  run_frame wt -d nope
  assert_status 1
  assert_contains "$OUT" "no worktree at"
}

test_no_topic_outside_a_frame_shows_usage() {
  make_repo
  run_frame wt -d
  assert_status 1
  assert_contains "$OUT" "Usage: frame wt -d"
}

test_teardown_from_inside_hands_off_to_reaper() {
  setup_frame
  cd "$WT"
  run_frame wt -d
  assert_status 0
  assert_contains "$OUT" "handing off to a detached reaper"
  # the nohup'd re-invocation removes the worktree shortly after we return
  local i
  for i in {1..25}; do
    [[ -d "$WT" ]] || break
    sleep 0.2
  done
  assert_dir_absent "$WT"
  assert_branch_absent "$REPO" topic
}

test_dev_server_race_leaves_no_husk_or_orphan_branch() {
  # Regression: nvim's :qa! kills the vite/astro dev job, but a lingering child
  # keeps regenerating gitignored caches (.astro/, node_modules/) for a beat.
  # git worktree remove unregisters the tree and deletes its tracked files, then
  # its final rmdir trips over a cache the child recreated — "Directory not
  # empty", non-zero — which under set -e used to abort teardown before
  # `git branch -D`, stranding an orphaned branch beside a husk dir git no
  # longer tracks (the "missed worktree"). Teardown must survive it: clean tree,
  # gone branch.
  #
  # The failure is a genuine race, so rather than time one we drop in a git shim
  # (ahead of real git on PATH for the teardown call only) that reproduces the
  # exact state real git leaves on losing it — verified by hand: worktree
  # unregistered, a leftover husk dir, and a non-zero "Directory not empty".
  # Everything else passes straight through to real git.
  make_repo
  local real_git=$(whence -p git)
  mkdir -p "$SANDBOX/gitshim"
  cat > "$SANDBOX/gitshim/git" <<SHIM
#!/usr/bin/env zsh
# frame calls: git -C main worktree remove wt. Match the subsequence, not
# positional \$1/\$2, and take the path from the last arg.
if [[ " \$* " == *" worktree remove "* ]]; then
  wt=\${@[-1]}
  "$real_git" "\$@" >/dev/null 2>&1                  # real: unregister + delete
  mkdir -p "\$wt/.astro"; : > "\$wt/.astro/leftover"  # husk the race recreated
  print -r -- "error: failed to delete '\$wt': Directory not empty" >&2
  exit 1
fi
exec "$real_git" "\$@"
SHIM
  chmod +x "$SANDBOX/gitshim/git"

  write_config <<'EOF'
BUFFERS=()
EOF
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  run_frame wt topic
  assert_status 0
  unset FAKE_NVIM_LOG
  WT="$SANDBOX/_$TNAME-topic"
  cd "$REPO"

  # Each test runs in its own subshell, so shadowing git for the rest of it is
  # safe — the shim forwards everything except the one `worktree remove` call.
  export PATH="$SANDBOX/gitshim:$PATH"
  run_frame wt -d topic
  assert_status 0
  assert_contains "$OUT" "removed worktree and branch topic"
  assert_contains "$OUT" "lingered after removal"
  assert_dir_absent "$WT"
  assert_branch_absent "$REPO" topic
}

test_merge_then_teardown_happy_path() {
  setup_frame
  commit_file "$WT" work.txt "feature work"
  run_frame merge topic
  assert_status 0
  run_frame wt -d topic
  assert_status 0
  assert_dir_absent "$WT"
  assert_branch_absent "$REPO" topic
}

run_tests "$0"
