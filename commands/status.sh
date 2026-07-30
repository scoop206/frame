# frame status [TEXT…] — set a status suffix on this frame's window title:
#
#   frame status DEPLOYED. Waiting verification
#     → "<name> [ <topic> :<port> ] - DEPLOYED. Waiting verification"
#   frame status
#     → back to the base "<name> [ <topic> :<port> ]" title
#   frame status --prompt
#     → "<name> [ <topic> :<port> ] - working", plus the turn-start stamp
#
# The base name/topic part never changes — the status is purely appended.
# nvim owns the title for the whole session, so this works by RPC over the
# frame's named socket (calls FrameSetStatus in layouts/worktree.lua). Run it
# from any terminal buffer inside the session — including claude marking a
# milestone — or from outside the frame while its session is up.
#
# --prompt is the UserPromptSubmit hook target: the human just handed claude a
# turn, so the frame is now working — mark it. Together with the Stop hook
# (frame notify → "waiting") the title and `frame ls` carry claude's whole
# lifecycle: working while it runs, waiting once it wants the human. Its own
# spelling rather than `frame status working` because the hook also stamps the
# turn start (notify's quick-turn gate below), and a milestone that merely
# *says* working mustn't stamp.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

_prompt=0
if [[ "${1:-}" == --prompt ]]; then
  if (( $# > 1 )); then
    echo "$X_MARK frame status --prompt takes no further arguments" >&2
    exit 2
  fi
  _prompt=1
fi

# A shell frame (frame shell) has no git repo to derive identity from — its
# buffers inherit FRAME_NAME/FRAME_TOPIC from the session instead. Inside a
# checkout the usual config + worktree/branch derivation still wins.
if ! frame_project_root >/dev/null \
    && [[ -n "${FRAME_NAME:-}" && -n "${FRAME_TOPIC:-}" ]]; then
  NAME=$FRAME_NAME TOPIC=$FRAME_TOPIC
else
  frame_load_config
  # Same topic derivation as wt.sh: worktree dir name, or branch name in the
  # primary checkout.
  if [[ "${PROJECT_ROOT:t}" == _$NAME-* ]]; then
    TOPIC="${${PROJECT_ROOT:t}#_$NAME-}"
  else
    TOPIC=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
  fi
fi

# Turn-start stamp for notify's quick-turn gate: --prompt IS the
# UserPromptSubmit hook, so "stamped just now" ≡ "the human prompted just
# now". notify.sh reads the stamp's age to skip banners for fast turns.
# Before the socket check on purpose — the stamp must land even when the
# session is down and the RPC can't. The bare clear form still stamps too:
# it was the hook's spelling before --prompt existed, and projects wired back
# then keep their gate until their settings.json is refreshed.
if (( _prompt )); then
  touch "/tmp/$NAME-$TOPIC.prompt" 2>/dev/null || true
  set -- working
elif (( $# == 0 )); then
  touch "/tmp/$NAME-$TOPIC.prompt" 2>/dev/null || true
fi

SOCKET="/tmp/$NAME-$TOPIC.nvim"
if [[ ! -S "$SOCKET" ]]; then
  echo "$X_MARK no frame session for $NAME/$TOPIC (no socket at $SOCKET)" >&2
  frame_session_down_hint "$NAME" "$TOPIC"
  exit 1
fi

# Vimscript single-quoted string: only ' needs escaping, as ''.
TEXT="$*"
_esc=${TEXT//\'/\'\'}
# --headless: the remote-expr client must not attach a UI. Without it, a
# recent nvim (0.10+) whose stdout is a pipe — as it is under this $(…) —
# routes the expr result to /dev/tty instead of stdout (so $_title comes
# back empty) and probes the terminal for capabilities, whose replies then
# leak onto the caller's prompt. Headless writes to real stdout and never
# touches the tty.
if _title=$(nvim --headless --server "$SOCKET" --remote-expr "v:lua.FrameSetStatus('$_esc')"); then
  echo "$OK_MARK title: $_title"
else
  echo "$X_MARK session at $SOCKET didn't accept the update — layout predates" >&2
  echo "  FrameSetStatus? Reboot the frame (:FrameQuit, then frame wt $TOPIC)" >&2
  exit 1
fi
