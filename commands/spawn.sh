# frame spawn shell TOPIC [--req TEXT] [--timeout N] — boot a WORKER frame in
# a NEW ghostty window, without replacing the window you're in. `frame shell` /
# `frame wt` end in `exec nvim` — they take over the current terminal by
# design; spawn is the head-frame counterpart: an orchestrator (or you)
# dispatches a frame *from* a frame, keeps its own session, and follows up
# with `frame req` / blocks on `frame inbox --wait` for the answer.
#
#   frame spawn shell calc                      worker frame in ~/frames/calc
#   frame spawn shell calc --req "what is 2+2? reply with just the number"
#   frame spawn shell calc --req "…" --ephemeral    reaps itself after replying
#
# The launch is Ghostty's AppleScript dictionary (frame_open_window): workers
# open as tabs congregating in one shared workers window — head keeps its own
# window — and spawn records the window/tab ids to $SOCKET.gtab for
# focus (select by id) and reap (`frame spawn close-tab`, an internal kind run
# by the worker tab's shell once the frame exits — scripted surfaces hold on
# [Process exited] rather than auto-close, so the close must be explicit).
# After launching, spawn polls the worker's socket for FrameReady — the claude
# buffer's channel captured (boot's LAST step) AND claude's input prompt
# rendered on screen — and only then reports up and sends --req. The rendered
# prompt matters: text sent while claude's own process is still booting piles
# up in the pty and is read as one pasted chunk, which swallows the submitting
# Enter (see FrameRequest). --timeout N (default 30) bounds the wait; exit 3 on
# timeout,
# mirroring `frame inbox --wait`. `frame spawn wt` (a code worker in a project
# checkout) is scoped but not yet built — see docs/head-frame.md.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

USAGE="usage: frame spawn shell TOPIC [--req TEXT] [--timeout SECONDS] [--ephemeral]"

KIND="${1:-}"
case "$KIND" in
  shell) shift ;;
  wt)
    echo "$X_MARK frame spawn wt is not built yet (frame spawn shell is) — see docs/head-frame.md" >&2
    exit 2 ;;
  close-tab)
    # Internal (not in usage): the worker tab's shell runs this after `frame
    # shell` exits — close the tab by the ids spawn recorded. Scripted Ghostty
    # surfaces hold on [Process exited] instead of auto-closing, so the frame's
    # window dies here, however the frame ended (:FrameDown! self-reap or a
    # plain quit). Silent no-op without a recording (legacy `open -na` window
    # closes with its instance; a hand-booted frame was never ours to close).
    TOPIC="${2:-}"
    if [[ -z "$TOPIC" ]]; then
      echo "$X_MARK usage: frame spawn close-tab TOPIC" >&2
      exit 2
    fi
    GTAB="/tmp/shell-$TOPIC.nvim.gtab"
    [[ -f "$GTAB" ]] || exit 0
    read -r G_WID G_TID < "$GTAB"
    rm -f "$GTAB"
    osascript - "$G_WID" "$G_TID" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  tell application "Ghostty"
    close tab (tab id (item 2 of argv) of window id (item 1 of argv))
  end tell
end run
APPLESCRIPT
    exit 0 ;;
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

REQ="" TIMEOUT=30 EPHEMERAL=""
while (( $# )); do
  case "$1" in
    --ephemeral)
      EPHEMERAL=1; shift ;;
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

# A worker booted by `frame shell` is owned by name `shell` (commands/shell.sh);
# its socket is /tmp/shell-TOPIC.nvim. W_NAME, not NAME: frame_self_identity
# (below) may source the surrounding checkout's .frame/config.sh, which assigns
# NAME — spawn's worker name must survive that.
W_NAME=shell

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
frame_assert_topic_free "$W_NAME" "$TOPIC" || exit 1

# zsh -ic (inside frame_open_window) sources ~/.zshrc, so the worker's PATH and
# env come up exactly as when a human opens a window and types `frame shell
# TOPIC`. The absolute FRAME_ROOT pins this checkout's frame — the surface's
# command does not carry the caller's environment. --ephemeral rides
# in as FRAME_EPHEMERAL=1: the worker is BORN ephemeral, and its reply router
# (FrameOnTurnEnd) self-reaps the frame — dir, window — right after its first
# reply routes home. No `exec` before `frame shell`: the tab's zsh must
# survive nvim to run close-tab, which closes the tab (nvim's own exit merely
# strands the surface on [Process exited] — see the close-tab kind above).
SOCKET="/tmp/$W_NAME-$TOPIC.nvim"
BOOT="${EPHEMERAL:+FRAME_EPHEMERAL=1 }${(q)FRAME_ROOT}/bin/frame shell ${(q)TOPIC}"
BOOT+="; ${(q)FRAME_ROOT}/bin/frame spawn close-tab ${(q)TOPIC}"
if ! IDS=$(frame_open_window "$BOOT"); then
  echo "$X_MARK couldn't open a ghostty tab (is Ghostty installed?)" >&2
  exit 1
fi
# Record the surface for `frame focus` (select by id) and close-tab. Empty IDS
# = the legacy `open -na` fallback fired — no recording, focus falls back to
# title matching and the extra instance reaps its own window.
[[ -n "$IDS" ]] && print -r -- "$IDS" > "$SOCKET.gtab"

echo "$RUN_MARK spawned tab for $W_NAME/$TOPIC — waiting for it to boot…"
DEADLINE=$(( SECONDS + TIMEOUT ))
while :; do
  if [[ -S "$SOCKET" ]]; then
    _ready=$(nvim --headless --server "$SOCKET" \
        --remote-expr "v:lua.FrameReady()" 2>/dev/null) || _ready=0
    [[ "$_ready" == 1 ]] && break
  fi
  if (( SECONDS >= DEADLINE )); then
    echo "$X_MARK spawn: $W_NAME/$TOPIC didn't come up within ${TIMEOUT}s —" >&2
    echo "  check the new window: still booting (retry with --timeout), or died mid-boot" >&2
    exit 3
  fi
  sleep 0.5
done
echo "$OK_MARK $W_NAME/$TOPIC is up"

if [[ -n "$REQ" ]]; then
  "$FRAME_ROOT/bin/frame" req "$W_NAME/$TOPIC" "$REQ"
fi
