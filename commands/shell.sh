# frame shell TOPIC — a casual frame in the current dir: no branch, no
# worktree. TOPIC is required — it's the frame's handle (window title, focus,
# req) and must be unique across live frames.
#
# Boots the usual session in the cwd with just the claude + local buffers — or,
# if the dir carries a frame project config (.frame/local/config.sh, else
# .frame/config.sh), its BUFFERS plus what those buffers run on: SERVER_CMD,
# VITE_DIR, the port scan and app_env. Worktree machinery (stack_up, WT_LINKS)
# is not run: there's no worktree to feed. Everything non-git about a frame
# still works — window title shell/TOPIC, frame status / frame notify, :FrameQuit.
# The dir is never written: claude gets frame's hooks via --settings (see
# frame_export_claude_flags). Refuses ~ itself (claude would get your whole home
# as its cwd); in a git checkout it notes that `frame wt` gives a branch +
# worktree instead.
#
#   frame shell -C DIR TOPIC boot in DIR instead of the cwd. `frame spawn shell`
#                            uses this for its scratch dirs under
#                            frame_shell_home (~/.local/share/frame/shells).
#
#   frame shell TOPIC --resume ID
#                            resume past claude session ID. Boots in the dir the
#                            session last ran in (`claude --resume` only finds a
#                            session from its own dir), unless -C says
#                            otherwise; then the transcript is bridged there.
#
#   frame shell TOPIC --find "WORDS"
#                            search past sessions for WORDS (every word, at a
#                            word start, case-insensitive) in what YOU typed:
#                            tool output and claude's replies don't count. Pick
#                            one (fzf when installed, else a numbered list) and
#                            it's resumed as with --resume.
#
#   frame shell -d [TOPIC]   tear down: just quit the session. A shell has no
#                            branch or worktree to reap, so teardown collapses
#                            to a quit (the dir is kept). TOPIC defaults to the
#                            shell frame you're standing in. This is the CLI
#                            a shell's OWN claude runs to tear itself down: it
#                            lives in a terminal buffer and can't type :FrameDown,
#                            so it reaches nvim over the socket instead (:FrameDown
#                            is the same quit from inside the editor).
# Sourced by bin/frame; helpers + set -euo pipefail already active.

SHELL_HOME=$(frame_shell_home)

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
      # A shell frame's own claude carries its dir (FRAME_SHELL_DIR, exported at
      # boot) — name the reboot that lands back there.
      if [[ "${FRAME_TOPIC:-}" == "$TOPIC" && -n "${FRAME_SHELL_DIR:-}" ]]; then
        echo "$OK_MARK quit shell frame $TOPIC (dir kept: $FRAME_SHELL_DIR — reboot with: frame shell -C ${(q-)FRAME_SHELL_DIR} $TOPIC)"
      else
        echo "$OK_MARK quit shell frame $TOPIC"
      fi
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

_usage() {
  echo "Usage: frame shell [-C DIR] TOPIC [--resume ID | --find \"WORDS\"]" >&2
  echo "       (boots in DIR, default the current dir — or the session's own dir)" >&2
  exit 2
}

# -C DIR: boot there instead of the cwd. Flags are accepted before or after
# TOPIC, like git/make/tar's -C.
DIR=$PWD
DIR_GIVEN=0
RESUME_ID="" FIND=""
typeset -a _pos
while (( $# )); do
  case "$1" in
    -C)
      shift
      [[ -n "${1:-}" ]] || { echo "$X_MARK frame shell: -C needs a directory" >&2; _usage; }
      DIR=$1 DIR_GIVEN=1 ;;
    --resume)
      shift
      [[ -n "${1:-}" ]] || { echo "$X_MARK frame shell: --resume needs a session id" >&2; _usage; }
      RESUME_ID=$1 ;;
    --resume=*) RESUME_ID=${1#--resume=} ;;
    --find)
      shift
      [[ -n "${1:-}" ]] || { echo "$X_MARK frame shell: --find needs search words" >&2; _usage; }
      FIND=$1 ;;
    --find=*) FIND=${1#--find=} ;;
    -*) _usage ;;
    *)  _pos+=("$1") ;;
  esac
  shift
done
(( ${#_pos} == 1 )) || _usage
TOPIC=$_pos[1]
if [[ -n "$RESUME_ID" && -n "$FIND" ]]; then
  echo "$X_MARK frame shell: --resume and --find are mutually exclusive" >&2; exit 2
fi
if [[ -z "$TOPIC" || "$TOPIC" == */* ]]; then
  echo "$X_MARK frame shell: TOPIC must be a plain name — no slashes" >&2
  exit 2
fi
NAME=shell

# Topics are the handle `frame focus TOPIC` matches on, ignoring the owner name,
# so a topic must be unique across every live frame (shell frames included) or
# focus can't disambiguate. Refuse before booting — and before --find asks you
# to pick a session. (Re-entering this same shell frame is exempt — see
# frame_assert_topic_free.)
frame_assert_topic_free "$NAME" "$TOPIC" || exit 1

# --find WORDS: search past sessions, let the user pick one, resume it.
if [[ -n "$FIND" ]]; then
  _words=( ${=FIND} )
  (( $#_words )) || { echo "$X_MARK frame shell: --find needs search words" >&2; exit 2; }
  frame_require jq perl
  echo "$RUN_MARK searching your past claude sessions for: ${_words[*]}…" >&2
  if ! _rows=$(frame_session_search "${_words[@]}"); then
    echo "$X_MARK no past session has a message of yours matching: ${_words[*]}" >&2
    exit 1
  fi
  RESUME_ID=$(frame_session_pick "$_rows") || exit 1
fi

# --resume ID (or the --find pick): boot claude as `claude --resume ID` in the
# dir the session last ran in, unless -C names another (bridged further down).
if [[ -n "$RESUME_ID" ]]; then
  # It flows straight onto claude's command line — keep it to the UUID charset
  # (defends the buffers.json `claude ${FRAME_CLAUDE_FLAGS}` split).
  if [[ ! "$RESUME_ID" =~ '^[A-Za-z0-9-]+$' ]]; then
    echo "$X_MARK not a valid session id: $RESUME_ID" >&2; exit 2
  fi
  if ! _transcript=$(frame_session_transcript "$RESUME_ID"); then
    echo "$X_MARK no transcript for session $RESUME_ID under ~/.claude/projects" >&2
    exit 1
  fi
  if (( ! DIR_GIVEN )); then
    if ! DIR=$(frame_session_cwd "$_transcript"); then
      echo "$X_MARK can't tell which dir session $RESUME_ID ran in — pass -C DIR" >&2
      exit 1
    fi
    if [[ ! -d "$DIR" ]]; then
      echo "$X_MARK session $RESUME_ID ran in $DIR, which is gone —" >&2
      echo "  pass -C DIR to resume it somewhere else" >&2
      exit 1
    fi
    if [[ "${DIR:A}" == "${HOME:A}" ]]; then
      echo "$X_MARK session $RESUME_ID ran in your home dir (~), where frame shell won't boot —" >&2
      echo "  pass -C DIR to resume it somewhere else" >&2
      exit 1
    fi
  fi
fi

if [[ ! -d "$DIR" ]]; then
  echo "$X_MARK frame shell: no such directory: $DIR" >&2
  exit 1
fi
DIR=${DIR:A}
if [[ "$DIR" == "${HOME:A}" ]]; then
  echo "$X_MARK frame shell: refusing to boot in your home dir (~) — cd somewhere, or pass -C DIR" >&2
  exit 1
fi

# Ask before any side effect — a nested boot aborted here leaves nothing behind.
frame_guard_nested || exit 1

# Defaults, reset rather than inherited: booted from inside a worktree frame,
# its exported SERVER_CMD/FRAME_VITE_PORT would otherwise leak into this one.
BUFFERS=(claude local)
SERVER_CMD="" VITE_DIR="" PORT_PREFIX="" FRAME_VITE_PORT=""
cd "$DIR"
# frame_project_root skips a $HOME dotfiles repo; no git installed → no hint.
if (( $+commands[git] )) && frame_project_root >/dev/null; then
  echo "$OK_MARK $DIR is a git checkout — a shell frame works on it directly (frame wt gives a branch + worktree)"
fi

# A frame project config in the dir picks the buffers (first hit wins, like
# frame_load_config). It's sourced for real — it's the user's own project
# code, same trust as `frame wt` — but
# NAME/TOPIC/DIR are this command's own and restored afterwards. NAME/PORT_PREFIX
# only feed the port aliases here.
for _f in .frame/local/config.sh .frame/config.sh; do
  [[ -f "$_f" ]] || continue
  _self=("$NAME" "$TOPIC" "$DIR")
  unset NAME
  source "$_f"
  : "${PORT_PREFIX:=${(U)${NAME:-${DIR:t}}//[^[:alnum:]]/_}}"
  [[ "$PORT_PREFIX" == [0-9]* ]] && PORT_PREFIX="_$PORT_PREFIX"
  NAME=$_self[1] TOPIC=$_self[2] DIR=$_self[3]
  echo "$OK_MARK using $DIR/$_f — buffers: ${BUFFERS[*]:-(none)}"
  frame_export_ports
  if (( $+functions[app_env] )); then app_env; fi
  break
done

set_title "$(frame_base_title "$NAME" "$TOPIC")"
frame_record_gtab "$NAME" "$TOPIC"

# Same layout as worktree frames — it's parameterized entirely by env, and
# an empty FRAME_MAIN_WT is the "no primary checkout" signal that selects
# the shell-frame :FrameDown (quit only) over the worktree one.
# FRAME_NAME/FRAME_TOPIC double as the session's identity
# for status/notify run from its buffers, where no git repo can answer.
export FRAME_NAME="$NAME"
export FRAME_TOPIC="$TOPIC"
export FRAME_SHELL_DIR="$DIR"
export FRAME_MAIN_WT=""
export FRAME_WT=""
export FRAME_VITE_PORT
export FRAME_BUFFERS="${BUFFERS[*]}"
# Config vars buffers.json reads (only set by a project config; see wt.sh).
export SERVER_CMD
export VITE_DIR="${VITE_DIR:-web}"
export FRAME_PORT_PREFIX="$PORT_PREFIX"
frame_export_claude_flags
# Same as `frame wt --resume`: appended after frame_export_claude_flags so it
# composes with the yolo flag, and bridged in case -C moved it to a new dir.
if [[ -n "$RESUME_ID" ]]; then
  export FRAME_CLAUDE_FLAGS="${FRAME_CLAUDE_FLAGS:+$FRAME_CLAUDE_FLAGS }--resume $RESUME_ID"
  frame_bridge_transcript "$RESUME_ID" "$DIR" || true
  echo "$OK_MARK resuming session $RESUME_ID in $DIR"
fi

# Refuse before exec if a boot-critical dependency is missing (see frame_require).
# A shell frame has no git repo, so git isn't required; claude only when the
# buffers include it (always, unless a project config says otherwise). Terminal
# mismatch is a soft warning, not a refusal.
frame_check_terminal
_req=(zsh nvim)
[[ " $FRAME_BUFFERS " == *" claude "* ]] && _req+=(claude)
frame_require "$_req[@]"

exec nvim -S "$FRAME_ROOT/layouts/session.lua"
