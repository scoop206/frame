#!/usr/bin/env zsh
# frame init end-to-end in scratch repos.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

test_init_fresh_repo() {
  make_repo
  run_frame init
  assert_status 0
  assert_contains "$OUT" "scaffolded — edit it to fit"
  assert_file_exists "$REPO/.frame/config.sh"
  # NAME is dynamic (defaults to the checkout's dirname) — the scaffold only
  # carries it as a commented-out pin, never sets it.
  assert_contains "$(<$REPO/.frame/config.sh)" "#NAME=$TNAME"
  assert_not_contains "$(<$REPO/.frame/config.sh)" $'\nNAME='
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

# Claude's hooks come from frame's claude/hooks.json (--settings at boot), so
# init writes nothing into .claude/ and never touches an existing settings.json.
test_init_writes_no_claude_settings() {
  make_repo
  run_frame init
  assert_status 0
  assert_dir_absent "$REPO/.claude"
}

test_init_leaves_existing_settings_alone() {
  make_repo
  mkdir -p "$REPO/.claude"
  print -r -- '{"hooks":{}}' > "$REPO/.claude/settings.json"
  local before=$(cksum "$REPO/.claude/settings.json")
  run_frame init --force   # --force is accepted and ignored now
  assert_status 0
  assert_eq "$(cksum "$REPO/.claude/settings.json")" "$before" "settings.json was rewritten"
}

test_init_rejects_unknown_flag() {
  make_repo
  run_frame init --bogus
  assert_status 2
  assert_contains "$OUT" "unknown flag"
}

test_init_rejects_unknown_type() {
  make_repo
  run_frame init --type nope
  assert_status 2
  assert_contains "$OUT" "unknown --type 'nope'"
}

test_init_type_needs_a_value() {
  make_repo
  run_frame init --type
  assert_status 2
  assert_contains "$OUT" "--type needs a value"
}

test_init_astrojs_scaffolds_project() {
  make_repo
  run_frame init --type astrojs
  assert_status 0
  # committed scaffold files land at the repo root
  assert_file_exists "$REPO/package.json"
  assert_file_exists "$REPO/astro.config.mjs"
  assert_file_exists "$REPO/tsconfig.json"
  assert_file_exists "$REPO/src/pages/index.astro"
  # astro-shaped config.sh: vite buffer, root VITE_DIR, COW node_modules stack_up
  local cfg="$(<$REPO/.frame/config.sh)"
  assert_contains "$cfg" "BUFFERS=(claude local vite)"
  assert_contains "$cfg" "VITE_DIR=."
  # node_modules is NOT symlinked (COW per-worktree); only .env is linked
  assert_contains "$cfg" "WT_LINKS=(.env)"
  assert_not_contains "$cfg" "WT_LINKS=(node_modules)"
  assert_contains "$cfg" "stack_up()"
  assert_contains "$cfg" 'frame_clone_node_modules'
  # no port machinery: config.sh doesn't prescribe a port and astro.config lets
  # Vite pick one (host:true binds the network, but no port is set)
  assert_not_contains "$cfg" "VITE_PORT"
  local astrocfg="$(<$REPO/astro.config.mjs)"
  assert_contains "$astrocfg" "host: true"
  assert_not_contains "$astrocfg" "FRAME_VITE_PORT"
  assert_not_contains "$astrocfg" "process.env"
  # gitignore covers deps/build AND the anchored-images caution
  local gi="$(<$REPO/.gitignore)"
  # bare node_modules (no trailing slash) so both the per-worktree COW directory
  # and a legacy symlink are ignored, not just a real directory
  assert_contains "$gi" $'\nnode_modules\n'
  assert_not_contains "$gi" "node_modules/"
  assert_contains "$gi" ".astro/"
  assert_contains "$gi" ".frame/local/"
  assert_contains "$gi" "NEVER a bare"
}

test_init_astrojs_does_not_commit_the_scaffold() {
  # init must NEVER stage or commit on the user's behalf: the scaffold lands as
  # uncommitted changes, HEAD is unchanged, and a reminder tells the user to
  # review + commit it themselves.
  make_repo
  local head_before=$(git -C "$REPO" rev-parse HEAD)
  run_frame init --type astrojs
  assert_status 0
  # no commit was made
  assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$head_before" "init made a commit"
  # the scaffold exists as uncommitted (untracked) changes, not in a commit
  assert_file_exists "$REPO/package.json"
  assert_file_exists "$REPO/src/pages/index.astro"
  if git -C "$REPO" cat-file -e HEAD:package.json 2>/dev/null; then
    fail "package.json was committed"
  fi
  assert_contains "$(git -C "$REPO" status --porcelain)" "package.json"
  # nothing was staged on the user's behalf
  if ! git -C "$REPO" diff --cached --quiet; then
    fail "init staged changes on the user's behalf"
  fi
  # the reminder points the user at committing it themselves
  assert_contains "$OUT" "the astrojs scaffold is NOT committed"
  assert_contains "$OUT" "git add -A && git commit"
}

test_init_astrojs_is_idempotent() {
  make_repo
  run_frame init --type astrojs
  local sum_before=$(cksum "$REPO/package.json")
  local head_before=$(git -C "$REPO" rev-parse HEAD)
  run_frame init --type astrojs
  assert_status 0
  assert_contains "$OUT" "already exists — left alone"
  assert_eq "$(cksum "$REPO/package.json")" "$sum_before" "package.json rewritten"
  # no new commit on a re-run
  assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$head_before" "re-run made a new commit"
  # gitignore artifact block not duplicated
  assert_eq "$(grep -c '# frame:astrojs' "$REPO/.gitignore")" "1" "astrojs gitignore block duplicated"
}

test_init_generic_makes_no_commit() {
  # the default (generic) type must not auto-commit or scaffold an astro project
  make_repo
  local head_before=$(git -C "$REPO" rev-parse HEAD)
  run_frame init
  assert_status 0
  assert_file_absent "$REPO/package.json"
  assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$head_before" "generic init made a commit"
  assert_not_contains "$OUT" "committed the astrojs scaffold"
  # generic leaves WT_LINKS commented so wt.sh's default (.env web/node_modules)
  # applies; no cloudflare wiring leaks into a plain init
  local cfg="$(<$REPO/.frame/config.sh)"
  assert_contains "$cfg" "#WT_LINKS=(.env web/node_modules)"
  assert_not_contains "$cfg" ".dev.vars"
  assert_not_contains "$(<$REPO/.gitignore)" ".dev.vars"
}

test_init_cloudflare_layers_onto_generic_base() {
  # a bare `--type cloudflare` layers onto the default generic base: the
  # commented WT_LINKS default is promoted to an active line carrying .dev.vars,
  # and .dev.vars is gitignored. No astro scaffold, no commit.
  make_repo
  local head_before=$(git -C "$REPO" rev-parse HEAD)
  run_frame init --type cloudflare
  assert_status 0
  assert_file_absent "$REPO/package.json"
  assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$head_before" "cloudflare init made a commit"
  local cfg="$(<$REPO/.frame/config.sh)"
  assert_contains "$cfg" "WT_LINKS=(.env .dev.vars)"
  assert_not_contains "$cfg" "#WT_LINKS="
  local gi="$(<$REPO/.gitignore)"
  assert_contains "$gi" $'\n.dev.vars\n'
  assert_contains "$gi" "# frame:cloudflare"
}

test_init_astrojs_cloudflare_stack() {
  # `--type astrojs --type cloudflare` stacks the layer onto the astro base:
  # .dev.vars joins .env in WT_LINKS (node_modules is COW, not symlinked), and
  # gets gitignored, while the full astro scaffold still lands.
  make_repo
  run_frame init --type astrojs --type cloudflare
  assert_status 0
  assert_file_exists "$REPO/package.json"
  local cfg="$(<$REPO/.frame/config.sh)"
  assert_contains "$cfg" "WT_LINKS=(.env .dev.vars)"
  assert_contains "$cfg" "BUFFERS=(claude local vite)"
  local gi="$(<$REPO/.gitignore)"
  assert_contains "$gi" $'\n.dev.vars\n'
  assert_contains "$gi" "# frame:cloudflare"
}

test_init_cloudflare_gitignore_is_idempotent() {
  make_repo
  run_frame init --type cloudflare
  run_frame init --type cloudflare
  assert_status 0
  assert_eq "$(grep -c '# frame:cloudflare' "$REPO/.gitignore")" "1" "cloudflare gitignore block duplicated"
}

test_init_rejects_conflicting_base_types() {
  make_repo
  run_frame init --type generic --type astrojs
  assert_status 2
  assert_contains "$OUT" "conflicting base types"
}

# init needs no git: outside a repo it scaffolds the cwd, skipping .gitignore.
test_init_outside_git_scaffolds_cwd() {
  mkdir -p "$SANDBOX/plain"
  cd "$SANDBOX/plain"
  run_frame init --type astrojs --type cloudflare
  assert_status 0
  assert_file_exists "$SANDBOX/plain/.frame/config.sh"
  assert_contains "$(<$SANDBOX/plain/.frame/config.sh)" "#NAME=plain"
  assert_dir_exists "$SANDBOX/plain/.frame/local"
  assert_file_exists "$SANDBOX/plain/package.json"
  assert_file_absent "$SANDBOX/plain/.gitignore"
  assert_contains "$OUT" "not a git repo — skipped"
  assert_not_contains "$OUT" "NOT committed"
}

# A dotfiles repo at ~ must not adopt every un-git'd project dir beneath it:
# the project dir is scaffolded as a plain dir, never ~ itself.
test_init_under_home_dotfiles_repo_uses_cwd() {
  git init -q "$HOME"
  mkdir -p "$HOME/code/newproj"
  cd "$HOME/code/newproj"
  run_frame init
  assert_status 0
  assert_file_exists "$HOME/code/newproj/.frame/config.sh"
  assert_dir_absent "$HOME/.frame"
  assert_file_absent "$HOME/.gitignore"
  assert_file_absent "$HOME/.claude/settings.json"
}

test_init_refuses_home_dir() {
  cd "$HOME"
  run_frame init
  assert_status 1
  assert_contains "$OUT" "refusing to scaffold your home dir"
  assert_dir_absent "$HOME/.frame"
}

test_init_in_worktree_uses_primary_name() {
  make_repo
  git -C "$REPO" worktree add -q "$SANDBOX/some-random-dirname" -b topic
  cd "$SANDBOX/some-random-dirname"
  run_frame init
  assert_status 0
  # the commented NAME pin names the primary checkout, not the worktree dir
  assert_contains "$(<$SANDBOX/some-random-dirname/.frame/config.sh)" "#NAME=$TNAME"
}

# ── --type shell ──────────────────────────────────────────────────────────────

# --type shell used to wire a dir for `frame shell -C`; any dir works now, so it
# says so and writes nothing.
test_init_shell_is_a_noop() {
  mkdir -p "$SANDBOX/g/foobar"
  cd "$SANDBOX/g/foobar"
  run_frame init --type=shell
  assert_status 0
  assert_contains "$OUT" "nothing to do"
  assert_dir_absent "$SANDBOX/g/foobar/.claude"
  assert_dir_absent "$SANDBOX/g/foobar/.frame"
}

run_tests "$0"
