# frame silence [--off] [TOPIC | NAME/TOPIC] — silence a frame's banners:
#
#   frame silence comms           silence that frame's banners
#   frame silence --off comms     restore them
#   frame silence                 the frame you're in
#
# The CLI spelling of :FrameSilence (layouts/session.lua): both flip
# g:frame_notify_muted in the target's live session, which `frame notify`
# asks over the socket before popping a banner (notify.sh). Session-scoped
# like the vim command — the silence dies with the frame; the machine-global
# switch is `frame notifications off`. Only the banner+sound is suppressed;
# the window-title status still updates. Targets resolve exactly like
# `frame req` / `frame deliver` (frame_resolve_target — same-project sibling
# first, then the unique live frame carrying that topic); no arg means the
# frame you're in, derived as `frame status` does.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

VAL=1
if [[ "${1:-}" == --off ]]; then
  VAL=0
  shift
fi
if (( $# > 1 )) || [[ "${1:-}" == -* ]]; then
  echo "$X_MARK usage: frame silence [--off] [TOPIC|NAME/TOPIC]" >&2
  exit 2
fi

# ── resolve the target frame → NAME / TOPIC / SOCKET ──────────────────────────
if (( $# == 0 )); then
  if ! frame_self_identity; then
    echo "$X_MARK not inside a frame — pass a TOPIC or NAME/TOPIC to silence one" >&2
    exit 1
  fi
  NAME=$SELF_NAME TOPIC=$SELF_TOPIC SOCKET="$FRAME_RUNDIR/$NAME-$TOPIC.nvim"
  if [[ ! -S "$SOCKET" ]]; then
    echo "$X_MARK no frame session for $NAME/$TOPIC (no socket at $SOCKET)" >&2
    exit 1
  fi
else
  # Set SELF_* first so a bare topic can resolve to our own sibling (outside
  # any frame we just search live ones).
  frame_self_identity 2>/dev/null || true
  frame_resolve_target "$1" || exit 1
fi

# One RPC round-trip: set the flag notify.sh reads. execute() because
# --remote-expr takes an expression, not a command; works against any session
# (the flag needs no layout support — notify.sh get()s it with a default).
if ! frame_rpc_expr "$SOCKET" "execute('let g:frame_notify_muted = $VAL')" >/dev/null; then
  echo "$X_MARK session for $NAME/$TOPIC didn't answer over its socket —" >&2
  echo "  the frame may be mid-boot or wedged; try again, or reboot it" >&2
  exit 1
fi

if (( VAL )); then
  echo "$OK_MARK banners silenced for $NAME/$TOPIC — frame silence --off $TOPIC restores"
else
  echo "$OK_MARK banners on for $NAME/$TOPIC"
fi
