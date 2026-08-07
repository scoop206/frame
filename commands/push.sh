# frame push — publish the primary branch to origin, from wherever you are.
#
# The push half of `frame merge --push`, as its own step: `frame merge` lands a
# topic on the primary branch locally and deliberately never touches origin;
# when you're ready to publish, this sends it. Like merge, it drives the
# primary worktree via `git -C`, so it runs from any worktree of the project.
#
#   frame push        push the primary branch to origin
#   frame push -n     dry run: print the plan, change nothing
#
# The primary branch is whatever the primary checkout has checked out — main,
# master, trunk; frame never hardcodes a name. Safety rails: refuses when there
# is no origin remote, when the primary branch is behind origin (a push would
# be rejected as a non-fast-forward — fast-forward locally first), or when the
# two have diverged (reconcile manually); already level is a clean no-op.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

frame_load_config
MAIN_BRANCH=$(git -C "$MAIN_WT" rev-parse --abbrev-ref HEAD)

DRY=false
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY=true ;;
    *) echo "$X_MARK unknown argument: $arg" >&2; exit 2 ;;
  esac
done

run() {
  echo "  \$ $*"
  $DRY || "$@"
}

if ! git -C "$MAIN_WT" remote get-url origin >/dev/null 2>&1; then
  echo "$X_MARK no 'origin' remote in $MAIN_WT — nowhere to push" >&2
  exit 1
fi

echo "$RUN_MARK pushing '$MAIN_BRANCH' to origin from $MAIN_WT"
$DRY && echo "  (dry run — no changes will be made)"

# Judge ahead/behind against origin's actual tip, not a stale remote ref.
# (Skipped on a dry run, which then judges against whatever was last fetched.)
run git -C "$MAIN_WT" fetch origin "$MAIN_BRANCH"

if git -C "$MAIN_WT" rev-parse -q --verify "refs/remotes/origin/$MAIN_BRANCH" >/dev/null; then
  if [[ "$(git -C "$MAIN_WT" rev-parse "$MAIN_BRANCH")" == \
        "$(git -C "$MAIN_WT" rev-parse "origin/$MAIN_BRANCH")" ]]; then
    echo "$OK_MARK $MAIN_BRANCH is already level with origin/$MAIN_BRANCH — nothing to push"
    exit 0
  fi
  if git -C "$MAIN_WT" merge-base --is-ancestor "$MAIN_BRANCH" "origin/$MAIN_BRANCH"; then
    echo "$X_MARK $MAIN_BRANCH is behind origin/$MAIN_BRANCH — nothing local to push;" >&2
    echo "  fast-forward first:  git -C $MAIN_WT merge --ff-only origin/$MAIN_BRANCH" >&2
    exit 1
  fi
  if ! git -C "$MAIN_WT" merge-base --is-ancestor "origin/$MAIN_BRANCH" "$MAIN_BRANCH"; then
    echo "$X_MARK $MAIN_BRANCH has diverged from origin/$MAIN_BRANCH — reconcile manually first" >&2
    exit 1
  fi
  echo "  $(git -C "$MAIN_WT" rev-list --count "origin/$MAIN_BRANCH..$MAIN_BRANCH") commit(s) to publish"
fi

run git -C "$MAIN_WT" push origin "$MAIN_BRANCH"
echo "$OK_MARK pushed $MAIN_BRANCH to origin"
