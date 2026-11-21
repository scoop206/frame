# frame merge — merge a topic branch into the primary branch from the primary
# worktree, without leaving whichever worktree you're in (port of
# merge-to-main.sh). The primary branch is whatever the primary checkout has
# checked out — main, master, trunk; nothing here hardcodes a name.
#
# The checkouts are git worktrees sharing one object store, so the primary
# checkout already sees every topic branch. This drives that primary worktree
# via `git -C`: fast-forward the primary branch to origin, merge the topic
# branch, and (only when asked) push.
#
#   frame merge                merge the CURRENT worktree's branch
#   frame merge TOPIC          merge branch TOPIC
#   frame merge TOPIC --push   …and push the primary branch to origin afterward
#   frame merge --no-push      don't push, even when push_on_merge is on
#   frame merge --ff           fast-forward instead of a merge commit
#   frame merge -n             dry run: print the plan, change nothing
#
# Safety rails: refuses if the primary worktree has uncommitted tracked
# changes; aborts if the primary branch has diverged from origin; on a merge
# conflict it stops and tells you how to back out. A local-only repo (no origin
# remote) skips the origin sync entirely and merges anyway. Worktree/branch
# cleanup is left to `frame wt -d TOPIC`; pushing later, to `frame push`.
#
# Two `frame kv` settings, read for the frame being merged (NAME/TOPIC):
# push_on_merge=true makes a bare merge push as if --push were given (the
# human's standing "yes, publish"; --no-push overrides it once), and
# deploy_on_merge=true prints a reminder to deploy — frame has no deploy step of
# its own, so it tells the agent at the one moment it matters.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

frame_load_config
MAIN_BRANCH=$(git -C "$MAIN_WT" rev-parse --abbrev-ref HEAD)

PUSH=false
NO_PUSH=false
FF=false
DRY=false
TOPIC=""
for arg in "$@"; do
  case "$arg" in
    --push)        PUSH=true ;;
    --no-push)     NO_PUSH=true ;;
    --ff)          FF=true ;;
    -n|--dry-run)  DRY=true ;;
    -*)            echo "$X_MARK unknown flag: $arg" >&2; exit 2 ;;
    *)
      if [[ -n "$TOPIC" ]]; then
        echo "$X_MARK more than one branch given ($TOPIC, $arg)" >&2; exit 2
      fi
      TOPIC=$arg ;;
  esac
done

# Default the topic to the branch of the worktree we were invoked from.
if [[ -z "$TOPIC" ]]; then
  TOPIC=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
fi

if $PUSH && $NO_PUSH; then
  echo "$X_MARK --push and --no-push together — pick one" >&2
  exit 2
fi

# The frame layer is keyed by the topic being merged, which from :FrameMerge
# (cwd = primary checkout) isn't the branch we're standing on.
frame_kv_scope "$NAME" "$TOPIC" "$MAIN_WT"
if ! $PUSH && ! $NO_PUSH && frame_kv_is_true push_on_merge; then
  frame_kv_lookup push_on_merge
  if git -C "$MAIN_WT" remote get-url origin >/dev/null 2>&1; then
    PUSH=true
    echo "→ push_on_merge=true ($KV_LAYER) — will push after merging (--no-push to skip)"
  else
    # A standing setting (likely --user) shouldn't fail every local-only project.
    echo "→ push_on_merge=true ($KV_LAYER), but there's no 'origin' remote — merging locally only"
  fi
fi

if [[ "$TOPIC" == "$MAIN_BRANCH" ]]; then
  echo "$X_MARK topic branch is '$MAIN_BRANCH' — nothing to merge into itself" >&2
  exit 1
fi
if ! git -C "$MAIN_WT" show-ref --verify --quiet "refs/heads/$TOPIC"; then
  echo "$X_MARK no local branch '$TOPIC'" >&2
  exit 1
fi

run() {
  echo "  \$ $*"
  $DRY || "$@"
}

echo "$RUN_MARK merging '$TOPIC' → '$MAIN_BRANCH' in $MAIN_WT"
$DRY && echo "  (dry run — no changes will be made)"

# 1. Primary worktree must be clean of tracked changes. Untracked files are
#    fine — a merge won't touch them.
if ! git -C "$MAIN_WT" diff --quiet || ! git -C "$MAIN_WT" diff --cached --quiet; then
  echo "$X_MARK $MAIN_WT has uncommitted changes on $MAIN_BRANCH — commit or stash first" >&2
  exit 1
fi

# 2. Warn (don't block) about uncommitted work in the topic worktree: only the
#    committed branch tip gets merged, so such changes would be silently left out.
TOPIC_WT=$(git -C "$PROJECT_ROOT" worktree list --porcelain \
  | awk -v b="refs/heads/$TOPIC" '/^worktree /{w=$2} $0=="branch "b{print w}')
if [[ -n "$TOPIC_WT" ]] && { ! git -C "$TOPIC_WT" diff --quiet || ! git -C "$TOPIC_WT" diff --cached --quiet; }; then
  echo "⚠ $TOPIC_WT has uncommitted changes — they are NOT part of this merge"
fi

# 3. Bring the primary branch level with origin first (fast-forward only). A
#    divergence means it has local commits origin doesn't; stop rather than guess.
#    Local-only projects (no origin — e.g. the mock_sites) have nothing to sync
#    against, so skip the whole step rather than hard-fail on `fetch origin`.
#    Same guard push.sh uses.
if git -C "$MAIN_WT" remote get-url origin >/dev/null 2>&1; then
  run git -C "$MAIN_WT" fetch origin "$MAIN_BRANCH"
  if ! $DRY && ! git -C "$MAIN_WT" merge-base --is-ancestor "$MAIN_BRANCH" "origin/$MAIN_BRANCH" \
       && ! git -C "$MAIN_WT" merge-base --is-ancestor "origin/$MAIN_BRANCH" "$MAIN_BRANCH"; then
    echo "$X_MARK $MAIN_BRANCH has diverged from origin/$MAIN_BRANCH — reconcile manually first" >&2
    exit 1
  fi
  run git -C "$MAIN_WT" merge --ff-only "origin/$MAIN_BRANCH"
else
  echo "→ no 'origin' remote — skipping origin sync (local-only project)"
fi

# 4. Merge the topic branch. A failed `git merge` isn't always a conflict: a
#    missing git identity, untracked files in the way, or a refusing hook all
#    fail it too, often with nothing left in progress — so tell the cases apart
#    from the repo state instead of assuming, and only suggest --abort when
#    there is a merge to abort.
merge_failed() {
  local git_out=$1
  if git -C "$MAIN_WT" rev-parse -q --verify MERGE_HEAD >/dev/null; then
    if [[ -n $(git -C "$MAIN_WT" ls-files -u) ]]; then
      echo "$X_MARK merge hit conflicts. Resolve in $MAIN_WT, or back out with:" >&2
    else
      # In progress but nothing unmerged: git stopped before committing.
      echo "$X_MARK merge stopped before committing. Finish it in $MAIN_WT with 'git commit', or back out with:" >&2
    fi
    echo "    git -C $MAIN_WT merge --abort" >&2
  else
    echo "$X_MARK merge of '$TOPIC' into $MAIN_BRANCH failed — nothing was merged, $MAIN_BRANCH is unchanged." >&2
    # Repeat git's own error (its fatal:/error: lines; else its last line) so
    # the cause sits next to frame's verdict instead of scrolled above it.
    local -a why=( ${(M)${(f)git_out}:#(fatal|error):*} )
    (( $#why )) || why=( "${${(f)git_out}[-1]}" )
    [[ -n ${why[1]} ]] && printf '    git: %s\n' "${why[@]}" >&2
  fi
  exit 1
}

if $FF; then
  merge_args=( --ff "$TOPIC" )
else
  merge_args=( --no-ff -m "Merge branch '$TOPIC'" "$TOPIC" )
fi
echo "  \$ git -C $MAIN_WT merge ${merge_args[*]}"
if ! $DRY; then
  # Capture (for merge_failed) while still showing git's output as usual.
  merge_out=$(git -C "$MAIN_WT" merge "${merge_args[@]}" 2>&1) && merge_rc=0 || merge_rc=$?
  [[ -n $merge_out ]] && print -r -- "$merge_out"
  (( merge_rc == 0 )) || merge_failed "$merge_out"
fi
echo "$OK_MARK merged '$TOPIC' into $MAIN_BRANCH"

# 5. Push only on request.
if $PUSH && ! git -C "$MAIN_WT" remote get-url origin >/dev/null 2>&1; then
  echo "$X_MARK --push given but there's no 'origin' remote in $MAIN_WT — merged locally only" >&2
  exit 1
fi
if $PUSH; then
  run git -C "$MAIN_WT" push origin "$MAIN_BRANCH"
  echo "$OK_MARK pushed $MAIN_BRANCH to origin"
else
  echo "→ not pushed. To push:  frame push"
  echo "  (or re-run with --push)"
fi

if ! $DRY && frame_kv_is_true deploy_on_merge; then
  frame_kv_lookup deploy_on_merge
  echo "→ deploy_on_merge=true ($KV_LAYER) — deploy '$MAIN_BRANCH' now, using this project's deploy step"
fi

# Optional project hook, run after a successful merge: merge_epilog TOPIC PUSHED
# (PUSHED = true when --push / :FrameMerge! was used). Merging is not always the
# end — plenty of flows merge mid-stream and keep working — so the tool prints
# nothing on its own; a project that wants a wrap-up nudge (e.g. "now tear down
# the frame") defines merge_epilog in .frame/config.sh (or the machine-wide
# ~/.config/frame/config.sh) and decides, from the push flag or anything else,
# when to speak. Same seam as stack_up / app_env. Skipped on a dry run.
if ! $DRY && (( $+functions[merge_epilog] )); then
  merge_epilog "$TOPIC" "$PUSH"
fi
