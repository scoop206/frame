# frame shell TOPIC — a casual frame: no repo, no branch, no worktree.
#
# Creates (or reuses) $FRAME_SHELL_HOME/TOPIC (default ~/frames) and boots
# the usual session there with just the claude + local buffers. Everything
# non-git about a frame still works — window title shell/TOPIC, frame
# status / frame notify (and the claude Stop hook), :FrameQuit — for
# scratch work that deserves its own claude instance and directory but has
# no project behind it. :FrameDown quits and deletes the topic dir — no
# branch or worktree here, so there are no git safeguards and no bang needed.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

if (( $# != 1 )) || [[ "$1" == -* ]]; then
  echo "Usage: frame shell TOPIC" >&2
  exit 2
fi
TOPIC=$1
if [[ "$TOPIC" == */* ]]; then
  echo "$X_MARK frame shell: TOPIC becomes a directory name — no slashes" >&2
  exit 2
fi

NAME=shell

# Topics are the handle `frame focus TOPIC` matches on, ignoring the owner name,
# so a topic must be unique across every live frame (shell frames included) or
# focus can't disambiguate. Refuse before creating the dir. (Re-entering this
# same shell frame is exempt — see frame_assert_topic_free.)
frame_assert_topic_free "$NAME" "$TOPIC" || exit 1

DIR="${FRAME_SHELL_HOME:-$HOME/frames}/$TOPIC"
if [[ -d "$DIR" ]]; then
  echo "$OK_MARK directory $DIR already exists — reusing"
else
  echo "$RUN_MARK creating $DIR…"
  mkdir -p "$DIR"
fi
cd "$DIR"

# No repo → no `frame init` — wire the claude-code notification hooks
# here instead, or a casual claude never fires Stop → frame notify. Runs on
# reuse boots too, so dirs created before this existed get it; an existing
# file (however it got there) is left alone.
if [[ ! -f .claude/settings.json ]]; then
  frame_write_claude_hooks
  echo "$OK_MARK wired claude hooks (.claude/settings.json) — Stop → frame notify"
fi

set_title "$(frame_base_title "$NAME" "$TOPIC")"

# Same layout as worktree frames — it's parameterized entirely by env, and
# an empty FRAME_MAIN_WT is the "no primary checkout" signal that selects
# the shell-frame :FrameDown (dir delete) over the worktree one.
# FRAME_NAME/FRAME_TOPIC double as the session's identity
# for status/notify run from its buffers, where no git repo can answer.
export FRAME_NAME="$NAME"
export FRAME_TOPIC="$TOPIC"
export FRAME_MAIN_WT=""
export FRAME_VITE_PORT=""
export FRAME_BUFFERS="claude local"
frame_export_claude_flags

exec nvim -S "$FRAME_ROOT/layouts/worktree.lua"
