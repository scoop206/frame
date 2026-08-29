# frame init — scaffold a project's .frame/ directory:
#   .frame/config.sh        committed project facts (template, edit to fit)
#   .frame/local/           personal overrides + state — appended to .gitignore
#   .claude/settings.json   claude-code hooks: `frame notify` when a turn ends,
#                           clear the title status when the next prompt lands
#
# --type TYPE picks the config.sh flavour (default: generic — the template
# above). --type astrojs additionally scaffolds a worktree-ready Astro project:
# package.json / astro.config.mjs / tsconfig.json / src/pages, an astro-shaped
# config.sh (vite buffer, VITE_DIR=., WT_LINKS=(node_modules), and a stack_up
# that installs deps once in the primary), and the matching .gitignore lines.
# init NEVER stages or commits on your behalf — because `frame wt` only inherits
# COMMITTED files, it prints a reminder to review + commit the scaffold yourself
# so the very first `frame wt` inherits a working project via git. Deps aren't
# installed at init — stack_up does that lazily on first boot (see
# .frame/config.sh). Templates live in templates/astrojs/.
#
# Idempotent: existing files are left alone, the gitignore entry is added once.
# A one-row-per-file table summarizes what was modified vs left as-is. When a
# settings.json already exists we can't safely rewrite it, so init checks
# whether frame's hooks are wired and warns the user to merge them by hand if
# not — or, with --force, overwrites settings.json to re-sync the hooks, but only
# when the file holds nothing but frame's own hooks (jq confirms that); a file
# with custom hooks or settings is still left for a hand-merge.
#
# Exit status: 0 when everything's in sync (including a clean --force re-sync);
# 3 when a settings.json is left out of sync — its frame hooks are missing and
# init didn't fix it (no --force, custom content, or jq unavailable) — so `frame
# init` doubles as a drift check. 1 = not a git repo; 2 = usage error.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

PROJECT_ROOT=$(frame_project_root) || {
  echo "$X_MARK frame: not inside a git repository" >&2
  exit 1
}
cd "$PROJECT_ROOT"

# --force (-f): when .claude/settings.json already exists but is out of sync with
# frame's hooks, overwrite it instead of leaving it alone — but only if it holds
# nothing but frame's own hooks; a file with custom content is left for a
# hand-merge. Only settings.json has a canonical form to re-sync to; config.sh is
# yours to edit, so --force never touches it.
#
# --type TYPE selects the scaffold flavour (default generic). Accepts both
# `--type astrojs` and `--type=astrojs`.
FORCE=0
TYPE=generic
while (( $# )); do
  case "$1" in
    -f|--force) FORCE=1 ;;
    --type)
      shift
      TYPE="${1:-}"
      [[ -n "$TYPE" ]] || { echo "$X_MARK frame init: --type needs a value" >&2; exit 2; } ;;
    --type=*) TYPE="${1#--type=}" ;;
    -*) echo "$X_MARK frame init: unknown flag: $1" >&2; exit 2 ;;
    *)  echo "$X_MARK frame init: unexpected argument: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$TYPE" in
  generic|astrojs) ;;
  *) echo "$X_MARK frame init: unknown --type '$TYPE' (known: generic, astrojs)" >&2; exit 2 ;;
esac

mkdir -p .frame/local

# Each block records one "FILE|MODIFIED|NOTE" row; the table prints at the end so
# a yes/no column shows at a glance what init touched vs what it left alone.
typeset -a _rows
_hooks_hint=

if [[ -f .frame/config.sh ]]; then
  _rows+=( ".frame/config.sh|no|already exists — left alone" )
elif [[ "$TYPE" == astrojs ]]; then
  _name="${$(frame_main_wt "$PROJECT_ROOT"):t}"
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

# node_modules lives once in the primary checkout and is symlinked into each
# fresh worktree — it's gitignored, so git can't carry it the way it carries the
# committed scaffold.
WT_LINKS=(node_modules)

# Guarantee the primary checkout's deps exist before a worktree symlinks them.
# Runs on every \`frame wt\` boot (before WT_LINKS symlinking) and must stay
# idempotent — the install is skipped once node_modules is present. This is what
# makes a fresh clone / fresh checkout self-heal without a manual npm install.
stack_up() {
  [ -d "\$MAIN_WT/node_modules" ] || ( cd "\$MAIN_WT" && npm install )
}
EOF
  _rows+=( ".frame/config.sh|yes|scaffolded (astrojs) — edit it to fit the project" )
else
  _name="${$(frame_main_wt "$PROJECT_ROOT"):t}"
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
#WT_LINKS=(.env web/node_modules)   # gitignored assets symlinked into fresh worktrees

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

if [[ -f .claude/settings.json ]]; then
  # We never rewrite an existing settings.json — it may hold the user's own
  # hooks or keys that a blind overwrite would clobber, and merging JSON is
  # surgery frame won't attempt. Instead detect whether frame's notification
  # hooks are already wired; if any are missing, flag it so the user knows the
  # file needs a hand-merge rather than assuming init finished the job.
  typeset -a _missing
  _missing=(${(f)"$(frame_claude_hooks_missing .claude/settings.json)"})
  if (( ${#_missing} )); then
    if (( FORCE )); then
      # --force overwrites only when the file is frame's-hooks-or-nothing;
      # anything else (custom hooks/keys, or jq missing so we can't tell) is
      # left for a hand-merge — a blind rewrite would clobber the user's config.
      case "$(frame_settings_is_frame_only .claude/settings.json)" in
        safe)
          frame_write_claude_hooks
          _rows+=( ".claude/settings.json|yes|overwritten (--force) — frame hooks re-synced" ) ;;
        custom)
          _rows+=( ".claude/settings.json|no|has custom content — --force won't clobber it, merge by hand" )
          _hooks_hint=custom ;;
        nojq)
          _rows+=( ".claude/settings.json|no|need jq to confirm --force is safe here" )
          _hooks_hint=nojq ;;
      esac
    else
      _rows+=( ".claude/settings.json|no|exists — frame hooks missing, re-sync with --force" )
      _hooks_hint=missing
    fi
  else
    _rows+=( ".claude/settings.json|no|already wired for frame" )
  fi
else
  frame_write_claude_hooks
  _rows+=( ".claude/settings.json|yes|scaffolded — claude notifies via 'frame notify'" )
fi

if [[ -f .gitignore ]] && grep -qxF '.frame/local/' .gitignore; then
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
if [[ "$TYPE" == astrojs ]]; then
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
  if [[ -f .gitignore ]] && grep -qF '# frame:astrojs' .gitignore; then
    _rows+=( ".gitignore|no|already covers astrojs artifacts" )
  else
    {
      printf '\n# frame:astrojs — build + dependency artifacts (gitignored)\n'
      # node_modules is bare (no trailing slash) on purpose: in a worktree it's a
      # SYMLINK (WT_LINKS), not a dir, and `node_modules/` would only match a real
      # directory — leaving the symlink tracked. Bare matches both.
      printf 'node_modules\ndist/\n.astro/\n*.log\n'
      printf '# Anchor root asset ignores: `/images/`, NEVER a bare `images` —\n'
      printf '# a bare pattern also matches public/images/ and drops web assets.\n'
    } >> .gitignore
    _rows+=( ".gitignore|yes|added astrojs artifacts" )
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
if [[ "$TYPE" == astrojs ]] && [[ -n "$(git status --porcelain)" ]]; then
  print -- "\n  $WARN_MARK the astrojs scaffold is NOT committed — \`frame wt <topic>\` only"
  print -- "    inherits committed files, so review the scaffold and commit it yourself:"
  print -- "        git add -A && git commit -m 'frame init: scaffold Astro project'"
fi

if [[ -n $_hooks_hint ]]; then
  print
  case $_hooks_hint in
    missing)
      print -- "  $WARN_MARK .claude/settings.json already exists, so frame left it untouched —"
      print -- "    it's missing frame's notification hooks. Re-run \`frame init --force\`"
      print -- "    to overwrite it with frame's hooks (only if it holds no custom"
      print -- "    content), or add these by hand:" ;;
    custom)
      print -- "  $WARN_MARK .claude/settings.json holds custom hooks or settings, so --force"
      print -- "    left it untouched rather than clobber them. It's missing frame's"
      print -- "    notification hooks — merge these in by hand:" ;;
    nojq)
      print -- "  $WARN_MARK --force needs \`jq\` to confirm settings.json holds nothing but"
      print -- "    frame's hooks before overwriting it, and jq isn't installed. Install"
      print -- "    it (brew install jq) and re-run, or add the missing hooks by hand:" ;;
  esac
  # Walk the canonical hooks table (helpers.sh) and print a labelled line for
  # each hook that's in $_missing. Driving both the drift check and this warning
  # from that one table means every missing hook necessarily has a row here — no
  # hook can be detected-but-unlabelled, which is exactly the gap this replaced.
  # Table order (Stop, UserPromptSubmit, …) groups the output by event for free.
  frame_claude_hooks_table | while IFS='|' read -r _cmd _event _why; do
    (( ${_missing[(Ie)$_cmd]} )) || continue
    printf "      %-16s → '%s'  (%s)\n" "$_event" "$_cmd" "$_why"
  done

  # A left-untouched, out-of-sync settings.json is a failure to signal, not just
  # a note to read: exit nonzero so `frame init` doubles as a drift check (CI, a
  # pre-flight, or a human who scripts it) and the drift can't pass silently.
  exit 3
fi
