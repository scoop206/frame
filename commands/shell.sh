# frame shell [TOPIC] — a casual frame: no repo, no branch, no worktree.
#
# With no TOPIC: if the cwd is a shell frame's own dir (a direct child of
# $FRAME_SHELL_HOME) the dir name becomes the topic and it's re-fired in place
# (like `frame wt` with no arg); otherwise a fresh dated topic (2026-07-30-a3f9)
# is minted so a bare `frame shell` always lands you somewhere new.
#
# Creates (or reuses) $FRAME_SHELL_HOME/TOPIC (default ~/frames) and boots
# the usual session there with just the claude + local buffers. Everything
# non-git about a frame still works — window title shell/TOPIC, frame
# status / frame notify (and the claude Stop hook), :FrameQuit — for
# scratch work that deserves its own claude instance and directory but has
# no project behind it. :FrameDown quits and deletes the topic dir — no
# branch or worktree here, so there are no git safeguards and no bang needed.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

SHELL_HOME="${FRAME_SHELL_HOME:-$HOME/frames}"

if (( $# > 1 )) || [[ "${1:-}" == -* ]]; then
  echo "Usage: frame shell [TOPIC]  (no TOPIC: reuse the cwd if it's a shell frame dir, else a fresh dated one)" >&2
  exit 2
fi

if (( $# == 1 )); then
  TOPIC=$1
elif [[ "${PWD:h}" == "$SHELL_HOME" ]]; then
  # No topic, but we're standing in a shell frame's own dir (a direct child of
  # $FRAME_SHELL_HOME) — the dir name IS the topic. Re-fire it in place, the way
  # `frame wt` with no arg reboots the worktree you're in.
  TOPIC="${PWD:t}"
  echo "$OK_MARK no topic given — inferring '$TOPIC' from the current directory"
else
  # No topic and nowhere to infer from — mint a fresh dated scratch topic so a
  # bare `frame shell` always lands you somewhere. Regenerate on the (rare)
  # collision with an existing dir so we never reuse someone else's scratch.
  TOPIC="$(date +%Y-%m-%d)-$(printf '%04x' $RANDOM)"
  while [[ -d "$SHELL_HOME/$TOPIC" ]]; do
    TOPIC="$(date +%Y-%m-%d)-$(printf '%04x' $RANDOM)"
  done
  echo "$OK_MARK no topic given — new scratch frame '$TOPIC'"
fi

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

# Ask before any side effect — a nested boot aborted here leaves nothing behind.
frame_guard_nested || exit 1

DIR="$SHELL_HOME/$TOPIC"
if [[ -d "$DIR" ]]; then
  echo "$OK_MARK directory $DIR already exists — reusing"
else
  echo "$RUN_MARK creating $DIR…"
  mkdir -p "$DIR"
fi
cd "$DIR"

# No repo → no `frame init` — wire the claude-code hooks here instead, or a
# casual claude never fires Stop → frame notify / frame reply. Shell topics
# get reused across months, and the hook set grows: a dir wired before a hook
# existed would otherwise be frozen without it forever (the worker answers but
# its reply never routes home — how shell/qqq silently ate a reply). So a file
# that is recognizably frame-authored but stale — it carries 'frame notify',
# frame's fingerprint since day one, yet lacks a current hook — is rewritten.
# A file WITHOUT the fingerprint is the user's own: left alone, same promise
# frame init makes.
if [[ ! -f .claude/settings.json ]]; then
  frame_write_claude_hooks
  echo "$OK_MARK wired claude hooks (.claude/settings.json) — Stop → frame notify"
elif grep -qF 'frame notify' .claude/settings.json \
  && { ! grep -qF 'frame reply' .claude/settings.json \
    || ! grep -qF 'frame status --prompt' .claude/settings.json \
    || ! grep -qF 'frame notify --blocked' .claude/settings.json; }; then
  frame_write_claude_hooks
  echo "$OK_MARK refreshed claude hooks (.claude/settings.json) — stale frame wiring"
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
