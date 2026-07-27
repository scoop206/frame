# frame merge — merge a topic branch into main from the primary worktree,
# without leaving whichever worktree you're in (port of merge-to-main.sh).
#
# The checkouts are git worktrees sharing one object store, so the primary
# checkout (on `main`) already sees every topic branch. This drives that
# primary worktree via `git -C`: fast-forward main to origin, merge the topic
# branch, and (only when asked) push.
#
#   frame merge                merge the CURRENT worktree's branch
#   frame merge TOPIC          merge branch TOPIC
#   frame merge TOPIC --push   …and push main to origin afterward
#   frame merge --ff           fast-forward instead of a merge commit
#   frame merge -n             dry run: print the plan, change nothing
#
# Safety rails: refuses if the primary worktree has uncommitted tracked
# changes; aborts if main has diverged from origin; on a merge conflict it
# stops and tells you how to back out. Worktree/branch cleanup is left to
# `frame wt -d TOPIC`.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

frame_load_config
MAIN_BRANCH=$(git -C "$MAIN_WT" rev-parse --abbrev-ref HEAD)

PUSH=false
FF=false
DRY=false
TOPIC=""
for arg in "$@"; do
  case "$arg" in
    --push)        PUSH=true ;;
    --ff)          FF=true ;;
    -n|--dry-run)  DRY=true ;;
    -*)            echo "✗ unknown flag: $arg" >&2; exit 2 ;;
    *)
      if [[ -n "$TOPIC" ]]; then
        echo "✗ more than one branch given ($TOPIC, $arg)" >&2; exit 2
      fi
      TOPIC=$arg ;;
  esac
done

# Default the topic to the branch of the worktree we were invoked from.
if [[ -z "$TOPIC" ]]; then
  TOPIC=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
fi

if [[ "$TOPIC" == "$MAIN_BRANCH" ]]; then
  echo "✗ topic branch is '$MAIN_BRANCH' — nothing to merge into itself" >&2
  exit 1
fi
if ! git -C "$MAIN_WT" show-ref --verify --quiet "refs/heads/$TOPIC"; then
  echo "✗ no local branch '$TOPIC'" >&2
  exit 1
fi

run() {
  echo "  \$ $*"
  $DRY || "$@"
}

echo "▶ merging '$TOPIC' → '$MAIN_BRANCH' in $MAIN_WT"
$DRY && echo "  (dry run — no changes will be made)"

# 1. Primary worktree must be clean of tracked changes. Untracked files are
#    fine — a merge won't touch them.
if ! git -C "$MAIN_WT" diff --quiet || ! git -C "$MAIN_WT" diff --cached --quiet; then
  echo "✗ $MAIN_WT has uncommitted changes on $MAIN_BRANCH — commit or stash first" >&2
  exit 1
fi

# 2. Warn (don't block) about uncommitted work in the topic worktree: only the
#    committed branch tip gets merged, so such changes would be silently left out.
TOPIC_WT=$(git -C "$PROJECT_ROOT" worktree list --porcelain \
  | awk -v b="refs/heads/$TOPIC" '/^worktree /{w=$2} $0=="branch "b{print w}')
if [[ -n "$TOPIC_WT" ]] && { ! git -C "$TOPIC_WT" diff --quiet || ! git -C "$TOPIC_WT" diff --cached --quiet; }; then
  echo "⚠ $TOPIC_WT has uncommitted changes — they are NOT part of this merge"
fi

# 3. Bring main level with origin first (fast-forward only). A divergence means
#    main has local commits origin doesn't; stop rather than guess.
run git -C "$MAIN_WT" fetch origin "$MAIN_BRANCH"
if ! $DRY && ! git -C "$MAIN_WT" merge-base --is-ancestor "$MAIN_BRANCH" "origin/$MAIN_BRANCH" \
     && ! git -C "$MAIN_WT" merge-base --is-ancestor "origin/$MAIN_BRANCH" "$MAIN_BRANCH"; then
  echo "✗ $MAIN_BRANCH has diverged from origin/$MAIN_BRANCH — reconcile manually first" >&2
  exit 1
fi
run git -C "$MAIN_WT" merge --ff-only "origin/$MAIN_BRANCH"

# 4. Merge the topic branch.
if $FF; then
  run git -C "$MAIN_WT" merge --ff "$TOPIC"
else
  if ! run git -C "$MAIN_WT" merge --no-ff -m "Merge branch '$TOPIC'" "$TOPIC"; then
    echo "✗ merge hit conflicts. Resolve in $MAIN_WT, or back out with:" >&2
    echo "    git -C $MAIN_WT merge --abort" >&2
    exit 1
  fi
fi
echo "✓ merged '$TOPIC' into $MAIN_BRANCH"

# 5. Push only on request.
if $PUSH; then
  run git -C "$MAIN_WT" push origin "$MAIN_BRANCH"
  echo "✓ pushed $MAIN_BRANCH to origin"
else
  echo "→ not pushed. To push:  git -C $MAIN_WT push origin $MAIN_BRANCH"
  echo "  (or re-run with --push)"
fi
