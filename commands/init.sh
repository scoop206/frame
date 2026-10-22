# frame init — scaffold a project's .frame/ directory:
#   .frame/config.sh        committed project facts (template, edit to fit)
#   .frame/local/           personal overrides + state — appended to .gitignore
#
# No .claude/settings.json: every frame's claude gets frame's hooks from
# claude/hooks.json via --settings (see frame_export_claude_flags), so there's
# nothing to wire per project. A committed settings.json from older frames is
# harmless — Claude Code runs an identical hook only once — and can be deleted.
#
# --type TYPE picks the scaffold flavour, and stacks: one BASE (generic default,
# or astrojs) plus any LAYERS (cloudflare), e.g. `--type astrojs --type
# cloudflare`. --type astrojs additionally scaffolds a worktree-ready Astro
# project: package.json / astro.config.mjs / tsconfig.json / src/pages, an
# astro-shaped config.sh (vite buffer, VITE_DIR=., WT_LINKS=(node_modules), and a
# stack_up that installs deps once in the primary), and the matching .gitignore
# lines. --type cloudflare layers Cloudflare's .dev.vars (its .env-equivalent
# local secrets) onto whatever base is chosen: adds it to WT_LINKS so every
# worktree symlinks it from the primary, and gitignores it. --type shell used to
# wire a dir for `frame shell -C`; any dir works now, so it just says so.
#
# No git repo is needed. Outside one (or under a $HOME dotfiles repo) init
# scaffolds the cwd and skips the .gitignore lines — a config.sh there still
# picks `frame shell -C DIR`'s buffers. It refuses ~ itself.
# init NEVER stages or commits on your behalf — because `frame wt` only inherits
# COMMITTED files, it prints a reminder to review + commit the scaffold yourself
# so the very first `frame wt` inherits a working project via git. Deps aren't
# installed at init — stack_up does that lazily on first boot (see
# .frame/config.sh). Templates live in templates/astrojs/.
#
# Idempotent: existing files are left alone, the gitignore entry is added once.
# A one-row-per-file table summarizes what was modified vs left as-is.
#
# Exit status: 0 ok; 1 = run in ~ itself; 2 = usage error.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

# --force (-f) used to re-sync .claude/settings.json; there's nothing to re-sync
# now, so it's accepted and ignored (old warnings and scripts still say it).
#
# --type TYPE selects the scaffold flavour (default generic). Accepts both
# `--type astrojs` and `--type=astrojs`.
typeset -a _types
while (( $# )); do
  case "$1" in
    -f|--force) ;;
    --type)
      shift
      [[ -n "${1:-}" ]] || { echo "$X_MARK frame init: --type needs a value" >&2; exit 2; }
      _types+=("$1") ;;
    --type=*) _types+=("${1#--type=}") ;;
    -*) echo "$X_MARK frame init: unknown flag: $1" >&2; exit 2 ;;
    *)  echo "$X_MARK frame init: unexpected argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# Types stack. Each project has exactly one BASE flavour (generic | astrojs)
# plus any composable LAYERS (cloudflare). `--type astrojs --type cloudflare` is an
# Astro project whose worktrees also carry Cloudflare's .dev.vars; a bare `--type
# cloudflare` layers onto the default generic base. Two DIFFERENT bases is a
# conflict — a project can't be both generic and astrojs.
BASE=generic
IN_GIT=0
_base_set=0
CLOUDFLARE=0
for _t in "${_types[@]}"; do
  case "$_t" in
    shell)
      echo "$OK_MARK nothing to do — frame shell -C DIR works on any dir now (claude gets frame's hooks from frame itself)"
      exit 0 ;;
    generic|astrojs)
      if (( _base_set )) && [[ "$BASE" != "$_t" ]]; then
        echo "$X_MARK frame init: conflicting base types '$BASE' and '$_t' (a project has one base)" >&2
        exit 2
      fi
      BASE="$_t"; _base_set=1 ;;
    cloudflare) CLOUDFLARE=1 ;;
    *) echo "$X_MARK frame init: unknown --type '$_t' (known: generic, astrojs, cloudflare)" >&2; exit 2 ;;
  esac
done

# Inside a git repo, scaffold at its root. Outside one — or under a $HOME
# dotfiles repo, which is never a frame project — scaffold the cwd as-is:
# nothing init writes needs git except the .gitignore lines, which are
# skipped there (re-run init after `git init` to add them).
if PROJECT_ROOT=$(frame_project_root); then
  IN_GIT=1
else
  IN_GIT=0
  PROJECT_ROOT=$PWD
  if [[ "${PWD:A}" == "${HOME:A}" ]]; then
    echo "$X_MARK frame init: refusing to scaffold your home dir (~) — cd into a project first" >&2
    exit 1
  fi
fi
cd "$PROJECT_ROOT"
mkdir -p .frame/local

# The NAME a scaffold pins in its comment: the primary checkout's dir name in a
# repo (so init from a worktree still names the project), else the cwd's.
_init_name() {
  if (( IN_GIT )); then print -r -- "${$(frame_main_wt "$PROJECT_ROOT"):t}"
  else print -r -- "${PROJECT_ROOT:t}"; fi
}

# WT_LINKS seed for the generated config.sh (see wt.sh — gitignored assets
# symlinked from the primary checkout into each fresh worktree). node_modules is
# NOT symlinked for astro: stack_up gives each worktree its own copy-on-write
# node_modules so the per-frame .vite/.astro dep caches stop fighting (see
# frame_clone_node_modules). The cloudflare layer adds .dev.vars, Cloudflare's
# local-secrets file — the .env of a Workers/Pages project — so worktrees
# symlink it exactly like .env.
_astro_wt_links=".env"
_cf_link_comment=""
if (( CLOUDFLARE )); then
  _astro_wt_links+=" .dev.vars"
  _cf_link_comment=$'\n# .dev.vars is the Cloudflare local-secrets file (the .env of a Workers/Pages\n# project); symlink it per-worktree the same way.'
  # generic base: promote the commented default to an active line that carries
  # .dev.vars (web/node_modules dropped — a Workers project is not a web/ app).
  _generic_wt_links='WT_LINKS=(.env .dev.vars)   # symlinked into fresh worktrees; .dev.vars = Cloudflare local secrets'
else
  _generic_wt_links='#WT_LINKS=(.env web/node_modules)   # gitignored assets symlinked into fresh worktrees'
fi

# Each block records one "FILE|MODIFIED|NOTE" row; the table prints at the end so
# a yes/no column shows at a glance what init touched vs what it left alone.
typeset -a _rows

if [[ -f .frame/config.sh ]]; then
  _rows+=( ".frame/config.sh|no|already exists — left alone" )
elif [[ "$BASE" == astrojs ]]; then
  _name=$(_init_name)
  cat > .frame/config.sh <<EOF
# Frame project config — Astro variant, scaffolded by \`frame init --type astrojs\`.
# Committed project facts; personal overrides go in .frame/local/config.sh
# (gitignored, wins over this).

# NAME defaults to the primary checkout's directory name ($_name today) and
# follows a rename automatically. Set it only to pin a name that outlives the dir.
#NAME=$_name

# claude, a bare local shell, and the vite buffer that runs \`npm run dev\`
# (Astro's dev server IS vite).
BUFFERS=(claude local vite)

# Astro's dev server lives at the repo ROOT, not a web/ subdir — point the vite
# buffer there.
VITE_DIR=.

# Only shared config files are symlinked from the primary; node_modules is NOT —
# each worktree gets its OWN copy-on-write clone (see stack_up) so every frame
# has its own .vite/.astro dep-optimizer cache and the dev servers stop fighting
# over one shared cache.${_cf_link_comment}
WT_LINKS=($_astro_wt_links)

# Runs on every \`frame wt\` boot, in the worktree, with \$MAIN_WT set (before
# WT_LINKS symlinking). Must stay idempotent. frame_clone_node_modules (a frame
# helper, see lib/helpers.sh) heals the primary's deps — so a fresh clone/checkout
# self-heals without a manual npm install — then gives this worktree its own
# copy-on-write node_modules and reconciles it only when deps drift.
stack_up() {
  frame_clone_node_modules
}
EOF
  _rows+=( ".frame/config.sh|yes|scaffolded (astrojs) — edit it to fit the project" )
else
  _name=$(_init_name)
  cat > .frame/config.sh <<EOF
# Frame project config — committed project facts (like an .env.dev + hooks).
# Personal overrides go in .frame/local/config.sh (gitignored, wins over this).

# NAME defaults to the primary checkout's directory name ($_name today) and
# follows a rename automatically — window titles, worktree dirs, and frame
# addresses all derive from it. Set it only to pin a name that outlives the
# directory.
#NAME=$_name

# Required: which buffers each frame opens (definitions live in frame's
# buffers.json). Authoritative even when empty — BUFFERS=() opens none.
BUFFERS=(claude local)

# Uncomment what applies; everything below is optional.
#SERVER_CMD='cargo run -p $_name-server'
# Base ports; each frame scans upward and exports its picks as PORT /
# FRAME_API_PORT / FRAME_VITE_PORT / FRAME_HMR_PORT for your code to read.
#API_PORT=3000  VITE_PORT=5173  HMR_PORT=24678
${_generic_wt_links}

# Bring up everything the dev stack needs — runs on every \`frame wt\` boot, so
# keep it idempotent. Shared postgres/minio come from frame; only
# project-unique containers belong in this repo's compose file (pin those with
# --project-directory "\$MAIN_WT" so every frame shares one instance).
#stack_up() {
#  frame_services_up postgres minio
#  ensure_pg_db $_name
#  ensure_minio_bucket $_name-dev
#}

# Point the app at the shared services (exported before the server launches;
# wins over .env — dotenvy never overrides the environment). devpassword is
# ensure_pg_db's dev-only default — pass your own (ensure_pg_db $_name PASSWORD)
# and keep the URL in sync.
#app_env() {
#  export DATABASE_URL=postgres://$_name:devpassword@localhost:5432/$_name
#}

# Run after a successful \`frame merge\`: merge_epilog TOPIC PUSHED (\$2 is 'true'
# when --push / :FrameMerge! was used). Off unless you define it — use it to
# nudge the last step agents tend to forget: tearing the frame down. Fire on
# every merge (agents rarely --push, so don't gate on \$2 if it's them you're
# reminding), or gate on \$2 for a push-means-done policy. A machine-wide default
# can live in ~/.config/frame/config.sh; this overrides it per-project.
#merge_epilog() {
#  echo "→ done with '\$1'? tear it down:  frame wt -d \$1   (or :FrameDown from inside)"
#}
EOF
  _rows+=( ".frame/config.sh|yes|scaffolded — edit it to fit the project" )
fi

if (( ! IN_GIT )); then
  _rows+=( ".gitignore|no|not a git repo — skipped (re-run init after git init)" )
elif [[ -f .gitignore ]] && grep -qxF '.frame/local/' .gitignore; then
  _rows+=( ".gitignore|no|already covers .frame/local/" )
else
  printf '\n# frame — personal/local harness overrides, never committed\n.frame/local/\n' >> .gitignore
  _rows+=( ".gitignore|yes|added .frame/local/" )
fi

# ── astrojs scaffold ──────────────────────────────────────────────────────────
# Copy the Astro scaffold (idempotent — existing files are left alone) and ensure
# the build/deps ignore lines. init does NOT stage or commit — it prints a
# reminder below so the user reviews + commits the scaffold themselves, since
# `frame wt` only inherits committed files. Deps are NOT installed here — the
# config.sh stack_up does that lazily on first boot.
if [[ "$BASE" == astrojs ]]; then
  _tpl="$FRAME_ROOT/templates/astrojs"
  # dest paths relative to the project root; each is copied verbatim if absent.
  for _rel in package.json astro.config.mjs tsconfig.json src/pages/index.astro; do
    if [[ -e "$_rel" ]]; then
      _rows+=( "$_rel|no|already exists — left alone" )
    else
      mkdir -p "${_rel:h}"
      cp "$_tpl/$_rel" "$_rel"
      _rows+=( "$_rel|yes|scaffolded (astrojs)" )
    fi
  done

  # Build + dependency artifacts. IMPORTANT: any root asset ignore must be
  # anchored `/images/`, never a bare `images` — a bare pattern also swallows
  # public/images/ and silently drops committed web assets. A marker line keeps
  # this block append-once.
  if (( ! IN_GIT )); then
    :  # no repo to ignore build artifacts in (row already printed above)
  elif [[ -f .gitignore ]] && grep -qF '# frame:astrojs' .gitignore; then
    _rows+=( ".gitignore|no|already covers astrojs artifacts" )
  else
    {
      printf '\n# frame:astrojs — build + dependency artifacts (gitignored)\n'
      # node_modules is bare (no trailing slash) on purpose: a bare pattern
      # matches both a real directory (the COW clone each worktree gets from
      # stack_up) and a legacy WT_LINKS symlink, whereas `node_modules/` would
      # only match a directory — leaving an old symlink tracked.
      printf 'node_modules\ndist/\n.astro/\n*.log\n'
      printf '# Anchor root asset ignores: `/images/`, NEVER a bare `images` —\n'
      printf '# a bare pattern also matches public/images/ and drops web assets.\n'
    } >> .gitignore
    _rows+=( ".gitignore|yes|added astrojs artifacts" )
  fi
fi

# ── cloudflare layer ──────────────────────────────────────────────────────────
# .dev.vars holds local secrets (Cloudflare's .env) — never commit it. WT_LINKS
# already symlinks it into fresh worktrees (see config.sh above); here we just
# make sure git ignores it. .dev.vars.* covers wrangler's per-environment
# variants (.dev.vars.staging, …). A marker line keeps this block append-once.
if (( CLOUDFLARE )); then
  if (( ! IN_GIT )); then
    :  # no repo — .dev.vars stays untracked by default
  elif [[ -f .gitignore ]] && grep -qF '# frame:cloudflare' .gitignore; then
    _rows+=( ".gitignore|no|already covers cloudflare (.dev.vars)" )
  else
    printf '\n# frame:cloudflare — local secrets (like .env), never committed\n.dev.vars\n.dev.vars.*\n' >> .gitignore
    _rows+=( ".gitignore|yes|added cloudflare (.dev.vars)" )
  fi
fi

# Print the summary table: widen the FILE column to its longest entry so the
# MODIFIED / NOTE columns line up.
_w=4  # len("FILE")
for _r in $_rows; do
  _f=${_r%%|*}
  (( ${#_f} > _w )) && _w=${#_f}
done
printf '\n  %-*s  %-8s  %s\n' $_w FILE MODIFIED NOTE
for _r in $_rows; do
  _f=${_r%%|*}; _rest=${_r#*|}
  printf '  %-*s  %-8s  %s\n' $_w "$_f" "${_rest%%|*}" "${_rest#*|}"
done

# Remind the user to commit the astrojs scaffold themselves. `frame wt` only
# hands a worktree the COMMITTED files, so an uncommitted scaffold reproduces the
# first-boot failure this type exists to fix — but init must never stage or
# commit on the user's behalf (it surprised people), so we nudge rather than act.
# Only nudge when the tree is actually dirty; a fully-committed re-run stays quiet.
if [[ "$BASE" == astrojs ]] && (( IN_GIT )) && [[ -n "$(git status --porcelain)" ]]; then
  print -- "\n  $WARN_MARK the astrojs scaffold is NOT committed — \`frame wt <topic>\` only"
  print -- "    inherits committed files, so review the scaffold and commit it yourself:"
  print -- "        git add -A && git commit -m 'frame init: scaffold Astro project'"
fi
