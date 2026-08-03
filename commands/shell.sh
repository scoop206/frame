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
# no project behind it.
#
#   frame shell -d [TOPIC]   tear down: just quit the session. A shell has no
#                            branch or worktree to reap, so teardown collapses
#                            to a quit (the scratch dir is disposable and kept —
#                            `frame shell TOPIC` reboots it). TOPIC defaults to
#                            the shell frame you're standing in. This is the CLI
#                            a shell's OWN claude runs to tear itself down: it
#                            lives in a terminal buffer and can't type :FrameDown,
#                            so it reaches nvim over the socket instead (:FrameDown
#                            is the same quit from inside the editor).
# Sourced by bin/frame; helpers + set -euo pipefail already active.

SHELL_HOME="${FRAME_SHELL_HOME:-$HOME/frames}"

# -d [-f] [TOPIC]: tear down a shell frame. No git branch/worktree means there's
# nothing to reap and no dir to remove out from under ourselves — so unlike
# `frame wt -d` there's no reaper handoff, just a :qa! to the session's socket.
# Works from inside the target frame too (that's the point): the send lands
# before nvim exits and SIGHUPs this terminal.
if [[ "${1:-}" == "-d" ]]; then
  shift
  # -f is accepted (no-op) for muscle-memory parity with `frame wt -d -f`; a
  # scratch dir carries no git safeguards for a force flag to override.
  TOPIC=""
  for _arg in "$@"; do
    case "$_arg" in
      -f|--force) ;;
      -*) echo "$X_MARK unknown flag: $_arg" >&2; exit 2 ;;
      *)
        if [[ -n "$TOPIC" ]]; then
          echo "$X_MARK more than one topic given ($TOPIC, $_arg)" >&2; exit 2
        fi
        TOPIC=$_arg ;;
    esac
  done
  if [[ -z "$TOPIC" ]]; then
    # Inside a shell frame, infer the topic: prefer the exported session
    # identity (a shell frame's claude carries FRAME_NAME=shell / FRAME_TOPIC),
    # else the cwd if it's a direct child of $FRAME_SHELL_HOME.
    if [[ "${FRAME_NAME:-}" == shell && -n "${FRAME_TOPIC:-}" ]]; then
      TOPIC="$FRAME_TOPIC"
    elif [[ "${PWD:h}" == "$SHELL_HOME" ]]; then
      TOPIC="${PWD:t}"
    else
      echo "Usage: frame shell -d [-f] [TOPIC]  (TOPIC only optional inside a shell frame)" >&2
      exit 1
    fi
  fi

  SOCKET="$FRAME_RUNDIR/shell-$TOPIC.nvim"
  if [[ -S "$SOCKET" ]]; then
    echo "$RUN_MARK tearing down shell $TOPIC — quitting the session (:qa! → $SOCKET)…"
    # <Cmd>qa!<CR> runs from any mode — the session sits in terminal-insert,
    # where raw ':qa!' keys would just type into the foreground program; the !
    # bypasses any vimrc quit guards. --remote-send returns once the keys are
    # delivered (it doesn't wait for them to run), so even though nvim then
    # exits and SIGHUPs this terminal, the quit has already been handed off.
    if nvim --server "$SOCKET" --remote-send '<Cmd>qa!<CR>' 2>/dev/null; then
      echo "$OK_MARK quit shell frame $TOPIC (dir kept: $SHELL_HOME/$TOPIC — reboot with: frame shell $TOPIC)"
    else
      echo "⚠ socket is stale (no nvim listening) — removing it"
      rm -f "$SOCKET"
      echo "$OK_MARK shell frame $TOPIC was already down"
    fi
  else
    echo "$OK_MARK shell frame $TOPIC is not running — nothing to tear down"
  fi
  exit 0
fi

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
  # bare `frame shell` always lands you somewhere new (shared with spawn shell).
  TOPIC="$(frame_mint_shell_topic)"
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
  && [[ -n "$(frame_claude_hooks_missing .claude/settings.json)" ]]; then
  frame_write_claude_hooks
  echo "$OK_MARK refreshed claude hooks (.claude/settings.json) — stale frame wiring"
fi

set_title "$(frame_base_title "$NAME" "$TOPIC")"
frame_record_gtab "$NAME" "$TOPIC"

# Same layout as worktree frames — it's parameterized entirely by env, and
# an empty FRAME_MAIN_WT is the "no primary checkout" signal that selects
# the shell-frame :FrameDown (quit only) over the worktree one.
# FRAME_NAME/FRAME_TOPIC double as the session's identity
# for status/notify run from its buffers, where no git repo can answer.
export FRAME_NAME="$NAME"
export FRAME_TOPIC="$TOPIC"
export FRAME_MAIN_WT=""
export FRAME_VITE_PORT=""
export FRAME_BUFFERS="claude local"
frame_export_claude_flags

# Refuse before exec if a boot-critical dependency is missing (see frame_require).
# A shell frame has no git repo, so git isn't required; it always opens a claude
# buffer. Terminal mismatch is a soft warning, not a refusal.
frame_check_terminal
frame_require zsh nvim claude

exec nvim -S "$FRAME_ROOT/layouts/session.lua"
