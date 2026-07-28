# frame status [TEXT…] — set a status suffix on this frame's window title:
#
#   frame status DEPLOYED. Waiting verification
#     → "<name>/<topic> :<port> - DEPLOYED. Waiting verification"
#   frame status
#     → back to the base "<name>/<topic> :<port>" title
#
# The base name/topic part never changes — the status is purely appended.
# nvim owns the title for the whole session, so this works by RPC over the
# frame's named socket (calls FrameSetStatus in layouts/worktree.lua). Run it
# from any terminal buffer inside the session — including claude marking a
# milestone — or from outside the frame while its session is up.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

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

SOCKET="/tmp/$NAME-$TOPIC.nvim"
if [[ ! -S "$SOCKET" ]]; then
  echo "✗ no frame session for $NAME/$TOPIC (no socket at $SOCKET)" >&2
  exit 1
fi

# Vimscript single-quoted string: only ' needs escaping, as ''.
TEXT="$*"
_esc=${TEXT//\'/\'\'}
if _title=$(nvim --server "$SOCKET" --remote-expr "v:lua.FrameSetStatus('$_esc')"); then
  echo "✓ title: $_title"
else
  echo "✗ session at $SOCKET didn't accept the update — layout predates" >&2
  echo "  FrameSetStatus? Reboot the frame (:FrameQuit, then frame wt $TOPIC)" >&2
  exit 1
fi
