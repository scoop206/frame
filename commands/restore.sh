# frame restore — bring back frames that went down without a teardown, or
# that are still running but lost their window.
#
#   frame restore                  list them; at a terminal, pick which to reboot
#   frame restore TOPIC            reboot that one (a topic, or NAME/TOPIC)
#   frame restore --all            reboot every one
#   frame restore --print [...]    print the boot commands instead of opening tabs
#   frame restore --forget TOPIC|--all
#                                  drop the record(s) without booting — for a
#                                  frame you don't want back
#   frame restore --backfill       write a record for every live frame that
#                                  lacks one (booted before records existed),
#                                  so a crash or Ghostty quit is restorable now
#
# Every frame leaves a durable record in $FRAME_STATEDIR (see
# frame_record_save in lib/helpers.sh). Teardown deletes it; anything else that
# ends a frame — a crash, a reboot, Ghostty quitting, `frame stop`, :FrameQuit
# — leaves it. A record with no live frame behind it is what this lists:
# STATE is "stopped" (frame stop) or "died" (everything else). A frame that's
# still running with no window (Ghostty quit, its tab closed) is listed too,
# as "detached": restoring it just attaches a tab (frame attach), no reboot.
#
# Each one reboots in its own Ghostty tab (the workers window, as frame spawn
# opens them) with the right form:
#   wt     cd DIR && frame wt --resume ID       (the worktree, branch and all)
#   shell  frame shell -C DIR TOPIC --resume ID
# and its claude resumes the recorded session, told at SessionStart that it
# was interrupted and to wait for your go-ahead rather than carry on (see
# frame_restore_note in commands/swarm.sh). A frame whose claude never started
# a session reboots fresh. Off macOS (no AppleScript tabs), --print is implied:
# run each printed command in its own terminal.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

_usage() {
  echo "Usage: frame restore [TOPIC | NAME/TOPIC | --all] [--print]" >&2
  echo "       frame restore --forget TOPIC | NAME/TOPIC | --all" >&2
  exit 2
}

# --backfill: frames booted before records existed only get one at their
# claude's next SessionStart. Write them now from what each live session can
# tell us over its socket (its boot env) plus its claude's current session id:
# the running claude's own registry first, then the rundir .session pointer
# those frames wrote. Never overwrites an existing record.
if [[ "${1:-}" == --backfill ]]; then
  typeset -A _sid_of
  if (( $+commands[jq] )); then
    while IFS=$'\t' read -r _sid _pid; do
      _n=$(frame_proc_env "$_pid" FRAME_NAME 2>/dev/null) || continue
      _t=$(frame_proc_env "$_pid" FRAME_TOPIC 2>/dev/null) || continue
      [[ -n "$_n" && -n "$_t" ]] && _sid_of[$_n/$_t]=$_sid
    done < <(frame_session_running 2>/dev/null)
  fi
  _made=0 _had=0 _failed=0
  while IFS=$'\t' read -r _n _t _; do
    [[ -n "$_n" ]] || continue
    if [[ -f "$(frame_record_file "$_n" "$_t")" ]]; then (( ++_had )); continue; fi
    _env=$(frame_rpc_expr "$FRAME_RUNDIR/$_n-$_t.nvim" \
      'join([$FRAME_MAIN_WT, $FRAME_WT, $FRAME_SHELL_DIR], "\t")' 5) || _env=""
    _e=("${(@ps:\t:)_env}")
    _sid=${_sid_of[$_n/$_t]:-}
    if [[ -z "$_sid" && -r "$FRAME_RUNDIR/$_n-$_t.session" ]]; then
      _sid=$(<"$FRAME_RUNDIR/$_n-$_t.session")
    fi
    [[ "$_sid" =~ '^[A-Za-z0-9-]*$' ]] || _sid=""
    if [[ -z "${_e[1]:-}${_e[3]:-}" ]]; then
      echo "$X_MARK $_n/$_t: couldn't read where it runs — skipped (it gets a record at its next session start)" >&2
      (( ++_failed )); continue
    fi
    ( FRAME_NAME=$_n FRAME_TOPIC=$_t FRAME_MAIN_WT=${_e[1]:-} FRAME_WT=${_e[2]:-} \
      FRAME_SHELL_DIR=${_e[3]:-} frame_record_save session "$_sid" )
    if [[ -n "$_sid" ]]; then
      echo "$OK_MARK recorded $_n/$_t (session $_sid)"
    else
      echo "$OK_MARK recorded $_n/$_t (no claude session found — it would restore fresh)"
    fi
    (( ++_made ))
  done < <(frame_live_frames)
  _sum="backfill: $_made recorded, $_had already had one"
  (( _failed )) && _sum+=", $_failed skipped"
  echo "$_sum"
  (( _failed == 0 ))
  exit $?
fi

ALL=0 PRINT=0 FORGET=0 SPEC=""
while (( $# )); do
  case "$1" in
    -a|--all)  ALL=1 ;;
    --print)   PRINT=1 ;;
    --forget)  FORGET=1 ;;
    -h|--help) sed -n '1,26p' "$FRAME_ROOT/commands/restore.sh" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        echo "$X_MARK unknown flag: $1" >&2; _usage ;;
    *)         [[ -z "$SPEC" ]] || { echo "$X_MARK more than one frame given ($SPEC, $1)" >&2; _usage; }
               SPEC=$1 ;;
  esac
  shift
done
if (( ALL )) && [[ -n "$SPEC" ]]; then
  echo "$X_MARK --all and a TOPIC are mutually exclusive" >&2; _usage
fi
if (( FORGET && ! ALL )) && [[ -z "$SPEC" ]]; then
  echo "$X_MARK --forget needs a TOPIC (or --all)" >&2; _usage
fi
frame_is_macos || PRINT=1

# ── the restorable frames ─────────────────────────────────────────────────────
# One row per record whose frame isn't live — or is live but detached (no
# window): name<TAB>topic<TAB>file, sorted. DETACHED marks the latter.
typeset -a DEAD
typeset -A REC DETACHED
for _f in $FRAME_STATEDIR/*.json(N); do
  frame_record_read "$_f" || continue
  if frame_session_alive "${REC[name]}" "${REC[topic]}"; then
    _uis=$(frame_session_uis "${REC[name]}" "${REC[topic]}") || continue
    (( _uis == 0 )) || continue
    DETACHED[$_f]=1
  fi
  DEAD+=("${REC[name]}	${REC[topic]}	$_f")
done
DEAD=("${(@f)$(print -rl -- "${DEAD[@]}" | sort -t$'\t' -k1,1 -k2,2)}")
DEAD=(${DEAD:#})

# Running frames with no record (booted before records existed, no claude
# session start since) are invisible to everything below — say so, rather than
# let "nothing to restore" read as "everything is covered".
if (( ! FORGET )); then
  typeset -a _unrec=()
  while IFS=$'\t' read -r _n _t _; do
    [[ -n "$_n" && ! -f "$(frame_record_file "$_n" "$_t")" ]] && _unrec+=("$_n/$_t")
  done < <(frame_live_frames)
  if (( $#_unrec )); then
    echo "$WARN_MARK ${#_unrec} running frame(s) have no record, so restore couldn't bring them back:" >&2
    echo "    ${(j:, :)_unrec}" >&2
    echo "  record them now: frame restore --backfill" >&2
  fi
fi

if (( ! $#DEAD )); then
  if [[ -n "$SPEC" ]]; then
    echo "$X_MARK nothing to restore matches '$SPEC' — no frame went down without a teardown" >&2
    exit 1
  fi
  echo "$OK_MARK nothing to restore — every recorded frame is running, with a window"
  exit 0
fi

_list() {
  # Numbered table of DEAD.
  local _i=0 _r _now=$EPOCHSECONDS _state _dir _wn=4 _wt=5 _x
  for _r in "${DEAD[@]}"; do
    _x=${_r%%$'\t'*};  (( ${#_x} > _wn )) && _wn=${#_x}
    _x=${${_r#*$'\t'}%%$'\t'*}; (( ${#_x} > _wt )) && _wt=${#_x}
  done
  printf '   %-3s %-*s  %-*s  %-6s %-14s %s\n' '#' $_wn NAME $_wt TOPIC TYPE STATE DIR
  for _r in "${DEAD[@]}"; do
    (( ++_i ))
    frame_record_read "${_r##*$'\t'}"
    if [[ -n "${DETACHED[${_r##*$'\t'}]:-}" ]]; then
      _state="detached"
    elif [[ -n "${REC[stopped_at]:-}" ]]; then
      _state="stopped $(frame_fmt_age $(( _now - REC[stopped_at] ))) ago"
    else
      _state="died"
    fi
    _dir=${REC[dir]/#$HOME/~}
    printf '   %-3s %-*s  %-*s  %-6s %-14s %s\n' "$_i" $_wn "${REC[name]}" $_wt "${REC[topic]}" \
      "${REC[type]}" "$_state" "$_dir"
  done
}

# ── pick ──────────────────────────────────────────────────────────────────────
typeset -a PICKED   # entries of DEAD
if (( ALL )); then
  PICKED=("${DEAD[@]}")
elif [[ -n "$SPEC" ]]; then
  for _r in "${DEAD[@]}"; do
    _n=${_r%%$'\t'*} _rest=${_r#*$'\t'} _t=${_rest%%$'\t'*}
    if [[ "$SPEC" == */* ]]; then
      [[ "$_n/$_t" == "$SPEC" ]] && PICKED+=("$_r")
    else
      [[ "$_t" == "$SPEC" ]] && PICKED+=("$_r")
    fi
  done
  if (( ! $#PICKED )); then
    echo "$X_MARK nothing to restore matches '$SPEC' — the restorable frames are:" >&2
    _list >&2
    exit 1
  fi
  if (( $#PICKED > 1 )); then
    echo "$X_MARK '$SPEC' names ${#PICKED} restorable frames — use NAME/TOPIC:" >&2
    for _r in "${PICKED[@]}"; do echo "    ${_r%%$'\t'*}/${${_r#*$'\t'}%%$'\t'*}" >&2; done
    exit 1
  fi
else
  echo "Frames to bring back (went down without a teardown, or lost their window):"
  _list
  if [[ ! -t 0 ]]; then
    echo "  restore with: frame restore TOPIC  (or --all; --forget TOPIC drops one)"
    exit 0
  fi
  print -n "Restore which? (numbers, a = all, Enter = none) "
  _reply=""
  read -r _reply || _reply=""
  case "$_reply" in
    "") echo "nothing restored"; exit 0 ;;
    a|A|all) PICKED=("${DEAD[@]}") ;;
    *)
      for _w in ${=_reply//,/ }; do
        if [[ "$_w" != <1-> ]] || (( _w > $#DEAD )); then
          echo "$X_MARK not a row number: $_w" >&2; exit 2
        fi
        PICKED+=("${DEAD[$_w]}")
      done ;;
  esac
fi

# ── forget ────────────────────────────────────────────────────────────────────
if (( FORGET )); then
  for _r in "${PICKED[@]}"; do
    if [[ -n "${DETACHED[${_r##*$'\t'}]:-}" ]]; then
      echo "$X_MARK ${_r%%$'\t'*}/${${_r#*$'\t'}%%$'\t'*} is still running (detached) — stop or tear it down instead" >&2
      continue
    fi
    rm -f -- "${_r##*$'\t'}"
    echo "$OK_MARK forgot ${_r%%$'\t'*}/${${_r#*$'\t'}%%$'\t'*} — frame restore won't offer it again"
  done
  exit 0
fi

# ── reboot ────────────────────────────────────────────────────────────────────
# Sessions open right now (claude's own registry): a recorded session that's
# already open elsewhere — another frame resumed it — must not get a second
# writer. Best-effort: no jq, no check.
typeset -A _open
if (( $+commands[jq] )); then
  while IFS=$'\t' read -r _sid _pid; do _open[$_sid]=$_pid; done < <(frame_session_running 2>/dev/null)
fi

_rc=0
for _r in "${PICKED[@]}"; do
  frame_record_read "${_r##*$'\t'}" || continue
  _n=${REC[name]} _t=${REC[topic]} _dir=${REC[dir]} _sid=${REC[session]:-} _h="${REC[name]}/${REC[topic]}"
  # Still running, just no window: attach, don't reboot.
  if [[ -n "${DETACHED[${_r##*$'\t'}]:-}" ]]; then
    _cmd="${(q)FRAME_ROOT}/bin/frame attach --here ${(q)_h}"
    if (( PRINT )); then print -r -- "$_cmd"; continue; fi
    if frame_open_frame_tab "$_n" "$_t" "$_cmd"; then
      echo "$OK_MARK attached $_h (it was still running) in a new tab"
    else
      echo "$X_MARK $_h: couldn't open a ghostty tab — run it yourself: $_cmd" >&2; _rc=1
    fi
    continue
  fi
  if [[ -n "$_sid" && ! "$_sid" =~ '^[A-Za-z0-9-]+$' ]]; then
    echo "$X_MARK $_h: its record holds a malformed session id — skipped" >&2; _rc=1; continue
  fi
  if [[ ! -d "$_dir" ]]; then
    echo "$X_MARK $_h: its dir is gone (${_dir/#$HOME/~}) — nothing to reboot into." >&2
    echo "  Drop it with: frame restore --forget $_h" >&2
    [[ -n "$_sid" ]] && echo "  (its conversation is still there: frame shell --resume $_sid)" >&2
    _rc=1; continue
  fi
  if [[ -n "$_sid" && -n "${_open[$_sid]:-}" ]]; then
    echo "$X_MARK $_h: its session $_sid is already open (claude pid ${_open[$_sid]}) — skipped;" >&2
    echo "  a second claude would write the same conversation" >&2
    _rc=1; continue
  fi
  if ! frame_assert_topic_free "$_n" "$_t" 2>/dev/null; then
    echo "$X_MARK $_h: another live frame now has topic '$_t' — skipped" >&2
    _rc=1; continue
  fi

  if [[ "${REC[type]}" == wt ]]; then
    # Topicless `frame wt` boots the worktree it runs in — its topic comes from
    # the dir (_NAME-TOPIC) or, for the primary checkout, the branch.
    _cmd="cd ${(q)_dir} && ${(q)FRAME_ROOT}/bin/frame wt${_sid:+ --resume $_sid}"
  else
    _cmd="${(q)FRAME_ROOT}/bin/frame shell -C ${(q)_dir} ${(q)_t}${_sid:+ --resume $_sid}"
  fi

  # One-shot stamp: the resumed claude's SessionStart hook tells it it was
  # interrupted (frame swarm --context). Only for a resume — a fresh claude
  # has nothing to have been interrupted in.
  [[ -n "$_sid" ]] && : > "$(frame_rundir)/$_n-$_t.restored"

  if (( PRINT )); then
    print -r -- "$_cmd"
    continue
  fi
  if ! frame_open_frame_tab "$_n" "$_t" "$_cmd"; then
    echo "$X_MARK $_h: couldn't open a ghostty tab — run it yourself: $_cmd" >&2
    _rc=1; continue
  fi
  echo "$OK_MARK restoring $_h${_sid:+ (resuming session $_sid)}"
done
exit $_rc
