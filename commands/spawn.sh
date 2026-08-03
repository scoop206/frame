# frame spawn shell|wt TOPIC — boot a WORKER frame in a new ghostty tab,
# without replacing the window you're in. `frame shell` / `frame wt` end in
# `exec nvim` — they take over the current terminal by design; spawn is the
# dispatch counterpart: an orchestrator (or you) launches a frame *from*
# anywhere, keeps its own session, and follows up with `frame req` / blocks
# on `frame inbox --wait` for the answer.
#
#   frame spawn shell                           worker in a fresh dated ~/frames dir
#   frame spawn shell calc                      worker frame in ~/frames/calc
#   frame spawn shell calc --req "what is 2+2? reply with just the number"
#   frame spawn shell calc --req "…" --ephemeral    reaps itself after replying
#   frame spawn wt search                       worktree worker in this project
#   frame spawn wt search --cwd ~/git_repos/flipnem   …in that project
#
# The launch is Ghostty's AppleScript dictionary (frame_open_window): workers
# open as tabs congregating in one shared workers window — and spawn records
# the window/tab ids to $SOCKET.gtab for focus (select by id) and reap
# (`frame spawn close-tab`, an internal kind run by the worker tab's shell
# once the frame exits — scripted surfaces hold on [Process exited] rather
# than auto-close, so the close must be explicit; the `&&` in the bootstrap
# means a FAILED boot skips it, leaving the error readable in the tab).
# After launching, spawn polls the worker's socket for FrameReady — the claude
# buffer's channel captured (boot's LAST step) AND claude's input prompt
# rendered on screen — and only then reports up and sends --req. The rendered
# prompt matters: text sent while claude's own process is still booting piles
# up in the pty and is read as one pasted chunk, which swallows the submitting
# Enter (see frame_submit). --timeout N (default 30) bounds the wait; exit 3
# on timeout, mirroring `frame inbox --wait`.
#
# wt workers belong to a project: NAME comes from its .frame config (socket
# $FRAME_RUNDIR/NAME-TOPIC.nvim), resolved at --cwd or the current directory. No
# --ephemeral for wt — a worktree frame's self-reap would force-delete a
# branch, which no spawn flag should reach (see FrameBrokerOnTurnEnd).
# Sourced by bin/frame; helpers + set -euo pipefail already active.

USAGE="usage: frame spawn shell [TOPIC] [--req TEXT] [--timeout SECONDS] [--ephemeral]
       frame spawn wt TOPIC [--cwd PATH] [--req TEXT] [--timeout SECONDS]"

KIND="${1:-}"
case "$KIND" in
  shell|wt) shift ;;
  close-tab)
    # Internal (not in usage): the worker tab's shell runs this after the
    # frame exits — close the tab by the ids spawn recorded. Scripted Ghostty
    # surfaces hold on [Process exited] instead of auto-closing, so the frame's
    # window dies here, however the frame ended (:FrameDown! self-reap or a
    # plain quit). Silent no-op without a recording (legacy `open -na` window
    # closes with its instance; a hand-booted frame was never ours to close).
    # Argument is [NAME/]TOPIC — bare TOPIC means a shell worker.
    ARG="${2:-}"
    if [[ -z "$ARG" ]]; then
      echo "$X_MARK usage: frame spawn close-tab [NAME/]TOPIC" >&2
      exit 2
    fi
    if [[ "$ARG" == */* ]]; then
      GTAB="$FRAME_RUNDIR/${ARG%%/*}-${ARG#*/}.nvim.gtab"
    else
      GTAB="$FRAME_RUNDIR/shell-$ARG.nvim.gtab"
    fi
    [[ -f "$GTAB" ]] || exit 0
    read -r G_WID G_TID < "$GTAB"
    rm -f "$GTAB"
    # Recorded window first; then every window — dragging a tab out of the
    # workers window rehomes it under a NEW window id, but the tab id survives.
    osascript - "$G_WID" "$G_TID" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  set wid to item 1 of argv
  set tid to item 2 of argv
  tell application "Ghostty"
    try
      close tab (tab id tid of window id wid)
      return
    end try
    repeat with w in windows
      try
        close tab (tab id tid of w)
        return
      end try
    end repeat
  end tell
end run
APPLESCRIPT
    exit 0 ;;
  *)
    echo "$X_MARK $USAGE" >&2
    exit 2 ;;
esac

# The launch surface (frame_open_window) is Ghostty's AppleScript dictionary —
# macOS-only, even under Linux Ghostty. Refuse here, after close-tab: that
# kind's osascript is already a guarded no-op, and a Linux worker shell
# running it must still exit 0. Guarding shell|wt keeps the error readable in
# the caller's terminal instead of failing inside a window that never opens.
if ! frame_is_macos; then
  echo "$X_MARK frame spawn is macOS-only — worker tabs open via Ghostty's AppleScript dictionary;" >&2
  echo "  boot the worker by hand instead: frame shell TOPIC / frame wt TOPIC in another terminal" >&2
  exit 1
fi

# TOPIC is the frame's dir/handle. A shell worker may omit it — like `frame
# shell`, spawn then mints a fresh dated scratch topic so a bare `frame spawn
# shell` always dispatches a new worker. wt still needs one (it names a branch).
# Spawn must know the topic up front regardless: the socket it polls, the gtab
# it records, and the --req return address are all keyed on it, so the minting
# happens HERE rather than deferring to `frame shell` inside the tab.
if [[ -n "${1:-}" && "$1" != -* ]]; then
  TOPIC=$1; shift
  if [[ "$TOPIC" == */* ]]; then
    echo "$X_MARK frame spawn: TOPIC becomes a directory name — no slashes" >&2
    exit 2
  fi
elif [[ "$KIND" == shell ]]; then
  TOPIC="$(frame_mint_shell_topic)"
  echo "$OK_MARK no topic given — new scratch worker '$TOPIC'"
else
  echo "$X_MARK $USAGE" >&2
  exit 2
fi

REQ="" TIMEOUT=30 EPHEMERAL="" CWD=""
while (( $# )); do
  case "$1" in
    --ephemeral)
      EPHEMERAL=1; shift ;;
    --cwd)
      if [[ -z "${2:-}" ]]; then
        echo "$X_MARK frame spawn: --cwd needs a path" >&2
        exit 2
      fi
      CWD=$2; shift 2 ;;
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

if [[ "$KIND" == shell && -n "$CWD" ]]; then
  echo "$X_MARK frame spawn shell: --cwd is a wt flag (shell frames live in ~/frames)" >&2
  exit 2
fi
if [[ "$KIND" == wt && -n "$EPHEMERAL" ]]; then
  echo "$X_MARK frame spawn wt: no --ephemeral — a worktree frame's self-reap would delete a branch" >&2
  exit 2
fi

# W_NAME, not NAME: frame_self_identity (below) may source the surrounding
# checkout's .frame/config.sh, which assigns NAME — spawn's worker name must
# survive that. shell workers are owned by name `shell` (commands/shell.sh,
# socket $FRAME_RUNDIR/shell-TOPIC.nvim); wt workers by their project's NAME, resolved
# in a subshell so the target project's config can't pollute this one.
if [[ "$KIND" == shell ]]; then
  W_NAME=shell
else
  PROJ="${CWD:-$PWD}"
  # `unset NAME`: a frame session exports its own NAME — without this, a
  # target project that leaves NAME to the dirname default would inherit ours.
  if ! W_NAME=$(cd "$PROJ" 2>/dev/null && unset NAME && frame_load_config 2>/dev/null && print -r -- "$NAME") \
      || [[ -z "$W_NAME" ]]; then
    echo "$X_MARK frame spawn wt: no project at ${PROJ} (need a git checkout; point --cwd at one)" >&2
    exit 1
  fi
  PROJ=${PROJ:A}
fi

# --req means a reply will route home — same rule as `frame req`: refuse before
# opening any window when there's no frame here to receive it.
if [[ -n "$REQ" ]] && ! frame_self_identity; then
  echo "$X_MARK frame spawn --req must be run from inside a frame — its inbox receives the reply" >&2
  exit 1
fi

# Refuse a taken topic HERE, where the error is readable without hunting down
# the new tab. (The frame command re-checks at boot; its same-frame exemption
# can't mask a real collision we'd care about, since we just proved no live
# frame owns this topic.)
frame_assert_topic_free "$W_NAME" "$TOPIC" || exit 1

# zsh -ic (inside frame_open_window) sources ~/.zshrc, so the worker's PATH and
# env come up exactly as when a human opens a window and types the frame
# command. The absolute FRAME_ROOT pins this checkout's frame — the surface's
# command does not carry the caller's environment; wt additionally cd's to the
# project, which is how `frame wt` resolves it. --ephemeral rides in as
# FRAME_EPHEMERAL=1: the worker is BORN ephemeral, and its broker
# (FrameBrokerOnTurnEnd) self-reaps the frame — dir, window — right after its
# first reply routes home. No `exec` before the frame command: the tab's zsh must
# survive nvim to run close-tab (`&&` — only after a clean exit; a failed boot
# leaves the tab stranded on the error, readable).
SOCKET="$FRAME_RUNDIR/$W_NAME-$TOPIC.nvim"
# FRAME_SPAWNED=1: spawn records the authoritative .gtab below from the window
# it creates (frame_open_window), so the inner frame shell/wt must NOT re-record
# from its own "front window" — a worker tab isn't frontmost at boot, so it would
# capture the head window's ids and misdirect focus. (See frame_record_gtab.)
if [[ "$KIND" == shell ]]; then
  BOOT="FRAME_SPAWNED=1 ${EPHEMERAL:+FRAME_EPHEMERAL=1 }${(q)FRAME_ROOT}/bin/frame shell ${(q)TOPIC}"
  BOOT+=" && ${(q)FRAME_ROOT}/bin/frame spawn close-tab ${(q)TOPIC}"
else
  BOOT="cd ${(q)PROJ} && FRAME_SPAWNED=1 ${(q)FRAME_ROOT}/bin/frame wt ${(q)TOPIC}"
  BOOT+=" && ${(q)FRAME_ROOT}/bin/frame spawn close-tab ${(q)W_NAME}/${(q)TOPIC}"
fi
if ! IDS=$(frame_open_window "$BOOT"); then
  echo "$X_MARK couldn't open a ghostty tab (is Ghostty installed?)" >&2
  exit 1
fi
# Record the surface for `frame focus` (select by id) and close-tab. Empty IDS
# = the legacy `open -na` fallback fired — no recording, focus falls back to
# title matching and the extra instance reaps its own window. Say so: a user
# whose Automation grant is missing should learn why spawns aren't tabbing.
if [[ -n "$IDS" ]]; then
  print -r -- "$IDS" > "$SOCKET.gtab"
  echo "$RUN_MARK spawned tab for $W_NAME/$TOPIC — waiting for it to boot…"
else
  echo "⚠ AppleScript launch unavailable (needs Ghostty ≥1.3 + macOS Automation grant — see README) — separate window instead"
  echo "$RUN_MARK spawned window for $W_NAME/$TOPIC — waiting for it to boot…"
fi
DEADLINE=$(( SECONDS + TIMEOUT ))
while :; do
  if [[ -S "$SOCKET" ]]; then
    _ready=$(nvim --headless --server "$SOCKET" \
        --remote-expr "v:lua.FrameReady()" 2>/dev/null) || _ready=0
    [[ "$_ready" == 1 ]] && break
  fi
  if (( SECONDS >= DEADLINE )); then
    echo "$X_MARK spawn: $W_NAME/$TOPIC didn't come up within ${TIMEOUT}s —" >&2
    echo "  check the new tab: still booting (retry with --timeout), or died mid-boot" >&2
    exit 3
  fi
  sleep 0.5
done
echo "$OK_MARK $W_NAME/$TOPIC is up"

if [[ -n "$REQ" ]]; then
  "$FRAME_ROOT/bin/frame" req "$W_NAME/$TOPIC" "$REQ"
fi
