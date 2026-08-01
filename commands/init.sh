# frame init — scaffold a project's .frame/ directory:
#   .frame/config.sh        committed project facts (template, edit to fit)
#   .frame/local/           personal overrides + state — appended to .gitignore
#   .claude/settings.json   claude-code hooks: `frame notify` when a turn ends,
#                           clear the title status when the next prompt lands
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
FORCE=0
for _arg in "$@"; do
  case "$_arg" in
    -f|--force) FORCE=1 ;;
    -*) echo "$X_MARK frame init: unknown flag: $_arg" >&2; exit 2 ;;
    *)  echo "$X_MARK frame init: unexpected argument: $_arg" >&2; exit 2 ;;
  esac
done

mkdir -p .frame/local

# Each block records one "FILE|MODIFIED|NOTE" row; the table prints at the end so
# a yes/no column shows at a glance what init touched vs what it left alone.
typeset -a _rows
_hooks_hint=

if [[ -f .frame/config.sh ]]; then
  _rows+=( ".frame/config.sh|no|already exists — left alone" )
else
  _name="${$(frame_main_wt "$PROJECT_ROOT"):t}"
  cat > .frame/config.sh <<EOF
# Frame project config — committed project facts (like an .env.dev + hooks).
# Personal overrides go in .frame/local/config.sh (gitignored, wins over this).
NAME=$_name

# Required: which buffers each frame opens (definitions live in frame's
# buffers.json). Authoritative even when empty — BUFFERS=() opens none.
BUFFERS=(claude local)

# Uncomment what applies; everything below is optional.
#SERVER_CMD='cargo run -p $_name-server'
#API_PORT=3000  VITE_PORT=5173  HMR_PORT=24678   # base ports; each frame scans upward
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
# wins over .env — dotenvy never overrides the environment).
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
