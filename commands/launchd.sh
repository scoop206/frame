# frame launchd — an optional macOS login agent: the reboot safety net.
#
#   frame launchd install [--restore]   install + load it (--restore: also
#                                       reopen your frames at login)
#   frame launchd uninstall             unload + remove it
#   frame launchd status                is it installed / loaded, and how
#
# The agent is a tiny long-lived process launchd starts at login
# (~/Library/LaunchAgents/frame.agent.plist). At logout, restart or shutdown
# launchd sends it SIGTERM, and it runs `frame stop` on every live frame at
# once — dev servers Ctrl-C'd, nvim quit, records stamped "stopped" — in the
# few seconds macOS allows (FRAME_STOP_TIMEOUT drops to 3s per frame there).
# Best effort: a frame it can't stop in time (unsaved buffers, no time left)
# still has its durable record, so `frame restore` brings it back as "died"
# either way. With --restore it also runs `frame restore --all` shortly after
# login, reopening every frame in Ghostty tabs (the first time, macOS asks to
# let the agent control Ghostty).
#
# Log: $FRAME_STATEDIR/agent.log. The agent is run as `frame launchd run`
# (internal — launchd's ProgramArguments; not for humans).
# Sourced by bin/frame; helpers + set -euo pipefail already active.

LABEL=frame.agent
AGENT_DIR=${FRAME_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}
PLIST="$AGENT_DIR/$LABEL.plist"
LOG="$FRAME_STATEDIR/agent.log"

_usage() {
  echo "Usage: frame launchd install [--restore] | uninstall | status" >&2
  exit 2
}

_xml() {  # XML-escape $1
  local s=$1
  s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}
  print -rn -- "$s"
}

_log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

case "${1:-}" in
  install)
    shift
    RESTORE=0
    for _a in "$@"; do
      case "$_a" in
        --restore) RESTORE=1 ;;
        *) echo "$X_MARK unknown argument: $_a" >&2; _usage ;;
      esac
    done
    if ! frame_is_macos; then
      echo "$X_MARK frame launchd is macOS-only (a LaunchAgent). On Linux, a systemd user" >&2
      echo "  unit with ExecStop='frame stop --all' does the same job." >&2
      exit 1
    fi
    mkdir -p "$AGENT_DIR" "$FRAME_STATEDIR"
    _args=("$FRAME_ROOT/bin/frame" launchd run)
    (( RESTORE )) && _args+=(--restore)
    # launchd starts agents with a bare PATH; carry this shell's so the agent
    # finds nvim, claude, git and the rest the way your terminal does.
    {
      print -r -- '<?xml version="1.0" encoding="UTF-8"?>'
      print -r -- '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
      print -r -- '<plist version="1.0">'
      print -r -- '<dict>'
      print -r -- "  <key>Label</key><string>$LABEL</string>"
      print -r -- '  <key>ProgramArguments</key>'
      print -r -- '  <array>'
      for _a in "${_args[@]}"; do print -r -- "    <string>$(_xml "$_a")</string>"; done
      print -r -- '  </array>'
      print -r -- '  <key>EnvironmentVariables</key>'
      print -r -- '  <dict>'
      print -r -- "    <key>PATH</key><string>$(_xml "$PATH")</string>"
      print -r -- "    <key>FRAME_STATEDIR</key><string>$(_xml "$FRAME_STATEDIR")</string>"
      print -r -- "    <key>FRAME_RUNDIR</key><string>$(_xml "$FRAME_RUNDIR")</string>"
      print -r -- '  </dict>'
      print -r -- '  <key>RunAtLoad</key><true/>'
      print -r -- '  <key>KeepAlive</key><false/>'
      print -r -- '  <key>ExitTimeOut</key><integer>30</integer>'
      print -r -- "  <key>StandardOutPath</key><string>$(_xml "$LOG")</string>"
      print -r -- "  <key>StandardErrorPath</key><string>$(_xml "$LOG")</string>"
      print -r -- '</dict>'
      print -r -- '</plist>'
    } > "$PLIST"
    # Reload: bootout a previous copy (fails harmlessly when none is loaded).
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
    if ! launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null; then
      echo "$X_MARK wrote $PLIST but launchctl couldn't load it — try: launchctl bootstrap gui/$UID ${(q)PLIST}" >&2
      exit 1
    fi
    echo "$OK_MARK installed the frame login agent ($PLIST)"
    echo "  at logout/shutdown it stops every frame (restorable with frame restore)"
    if (( RESTORE )); then
      echo "  at login it reopens them: frame restore --all"
    else
      echo "  at login it does nothing (--restore to reopen your frames then)"
    fi
    echo "  log: $LOG"
    ;;

  uninstall)
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
    if [[ -f "$PLIST" ]]; then
      rm -f "$PLIST"
      echo "$OK_MARK removed the frame login agent"
    else
      echo "$OK_MARK the frame login agent isn't installed"
    fi
    ;;

  status)
    if [[ ! -f "$PLIST" ]]; then
      echo "not installed — frame launchd install [--restore]"
      exit 0
    fi
    _mode="stop at shutdown"
    grep -q -- '<string>--restore</string>' "$PLIST" && _mode+=", restore at login"
    if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
      echo "installed and loaded ($_mode) — $PLIST"
    else
      echo "installed but NOT loaded ($_mode) — frame launchd install to reload"
    fi
    echo "log: $LOG"
    ;;

  run)
    # The agent itself. Sleep until launchd's SIGTERM, then stop every frame in
    # parallel — seconds count at shutdown.
    shift
    RESTORE=0
    [[ "${1:-}" == --restore ]] && RESTORE=1
    mkdir -p "$FRAME_STATEDIR"
    _log "agent up (pid $$, $( (( RESTORE )) && echo 'stop at shutdown + restore at login' || echo 'stop at shutdown'))"
    _sleeper=""
    _on_term() {
      [[ -n "$_sleeper" ]] && kill "$_sleeper" 2>/dev/null
      _log "SIGTERM — stopping every frame"
      local _n _t _h
      local -a _pids=()
      while IFS=$'\t' read -r _n _t _; do
        [[ -n "$_n" ]] || continue
        _h="$_n/$_t"
        FRAME_STOP_TIMEOUT=${FRAME_STOP_TIMEOUT:-3} "$FRAME_ROOT/bin/frame" stop "$_h" >> "$LOG" 2>&1 &
        _pids+=($!)
      done < <(frame_live_frames)
      (( $#_pids )) && wait "${_pids[@]}" 2>/dev/null
      _log "done (${#_pids} frame(s))"
      exit 0
    }
    trap _on_term TERM INT
    if (( RESTORE )); then
      # Let the login settle (Ghostty, the Dock) before opening tabs.
      sleep "${FRAME_AGENT_RESTORE_DELAY:-10}" & wait $! 2>/dev/null || true
      _log "login — frame restore --all"
      "$FRAME_ROOT/bin/frame" restore --all >> "$LOG" 2>&1 || _log "restore reported a problem (see above)"
    fi
    while :; do
      sleep 86400 & _sleeper=$!
      wait $_sleeper 2>/dev/null || true
    done
    ;;

  ""|-h|--help)
    sed -n '1,21p' "$FRAME_ROOT/commands/launchd.sh" | sed 's/^# \{0,1\}//'
    ;;
  *) _usage ;;
esac
