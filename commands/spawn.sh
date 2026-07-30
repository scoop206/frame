# frame spawn shell TOPIC [--req TEXT] [--timeout N] — boot a WORKER frame in
# a NEW ghostty window, without replacing the window you're in. `frame shell` /
# `frame wt` end in `exec nvim` — they take over the current terminal by
# design; spawn is the head-frame counterpart: an orchestrator (or you)
# dispatches a frame *from* a frame, keeps its own session, and follows up
# with `frame req` / blocks on `frame inbox --wait` for the answer.
#
#   frame spawn shell calc                      worker frame in ~/frames/calc
#   frame spawn shell calc --req "what is 2+2? reply with just the number"
#
# The launch is `open -na Ghostty.app` (frame_open_window — macOS Ghostty has
# no CLI new-window action) with --quit-after-last-window-closed=true so the
# extra app instance exits with its window instead of lingering in the dock.
# After launching, spawn polls the worker's socket for FrameReady — the claude
# buffer's channel is captured as boot's LAST step — and only then reports up
# and sends --req, so a request on "ready" lands in a live prompt instead of
# racing the boot. (claude's own TUI may still be drawing when ready fires;
# earlier keystrokes queue in the pty, same as typing into a just-booted
# frame.) --timeout N (default 30) bounds the wait; exit 3 on timeout,
# mirroring `frame inbox --wait`. `frame spawn wt` (a code worker in a project
# checkout) is scoped but not yet built — see docs/head-frame.md.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

USAGE="usage: frame spawn shell TOPIC [--req TEXT] [--timeout SECONDS]"

KIND="${1:-}"
case "$KIND" in
  shell) shift ;;
  wt)
    echo "$X_MARK frame spawn wt is not built yet (frame spawn shell is) — see docs/head-frame.md" >&2
    exit 2 ;;
  *)
    echo "$X_MARK $USAGE" >&2
    exit 2 ;;
esac

TOPIC="${1:-}"
if [[ -z "$TOPIC" || "$TOPIC" == -* ]]; then
  echo "$X_MARK $USAGE" >&2
  exit 2
fi
shift
if [[ "$TOPIC" == */* ]]; then
  echo "$X_MARK frame spawn: TOPIC becomes a directory name — no slashes" >&2
  exit 2
fi

REQ="" TIMEOUT=30
while (( $# )); do
  case "$1" in
    --req)
      if [[ -z "${2:-}" ]]; then
        echo "$X_MARK frame spawn: --req needs the request text" >&2
        exit 2
      fi
      REQ=$2; shift 2 ;;
    --timeout)
      # <-> is the zsh all-digits pattern; rejects '', 'abc', '-5'.
      if [[ "${2:-}" != <-> ]] || (( $2 < 1 )); then
        echo "$X_MARK frame spawn: --timeout needs a positive integer" >&2
        exit 2
      fi
      TIMEOUT=$2; shift 2 ;;
    *)
      echo "$X_MARK frame spawn: unknown argument '$1'" >&2
      echo "  $USAGE" >&2
      exit 2 ;;
  esac
done

# A worker booted by `frame shell` is owned by NAME=shell (commands/shell.sh);
# its socket is /tmp/shell-TOPIC.nvim.
NAME=shell

# --req means a reply will route home — same rule as `frame req`: refuse before
# opening any window when there's no frame here to receive it.
if [[ -n "$REQ" ]] && ! frame_self_identity; then
  echo "$X_MARK frame spawn --req must be run from inside a frame — its inbox receives the reply" >&2
  exit 1
fi

# Refuse a taken topic HERE, where the error is readable — inside the new
# window it would flash and die unread. (shell.sh re-checks at boot; that
# check's same-frame exemption can't mask a real collision we'd care about,
# since we just proved no live frame owns this topic.)
frame_assert_topic_free "$NAME" "$TOPIC" || exit 1

# zsh -ic (inside frame_open_window) sources ~/.zshrc, so the worker's PATH and
# env come up exactly as when a human opens a window and types `frame shell
# TOPIC`. The absolute FRAME_ROOT pins this checkout's frame — `open` launches
# via launchd, which does not carry the caller's environment.
if ! frame_open_window "exec ${(q)FRAME_ROOT}/bin/frame shell ${(q)TOPIC}"; then
  echo "$X_MARK couldn't open a ghostty window (is Ghostty installed?)" >&2
  exit 1
fi

echo "$RUN_MARK spawned window for $NAME/$TOPIC — waiting for it to boot…"
SOCKET="/tmp/$NAME-$TOPIC.nvim"
DEADLINE=$(( SECONDS + TIMEOUT ))
while :; do
  if [[ -S "$SOCKET" ]]; then
    _ready=$(nvim --headless --server "$SOCKET" \
        --remote-expr "v:lua.FrameReady()" 2>/dev/null) || _ready=0
    [[ "$_ready" == 1 ]] && break
  fi
  if (( SECONDS >= DEADLINE )); then
    echo "$X_MARK spawn: $NAME/$TOPIC didn't come up within ${TIMEOUT}s —" >&2
    echo "  check the new window: still booting (retry with --timeout), or died mid-boot" >&2
    exit 3
  fi
  sleep 0.5
done
echo "$OK_MARK $NAME/$TOPIC is up"

if [[ -n "$REQ" ]]; then
  "$FRAME_ROOT/bin/frame" req "$NAME/$TOPIC" "$REQ"
fi
