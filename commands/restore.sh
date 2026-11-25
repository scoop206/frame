# frame restore — bring back frames that went down without a teardown.
#
#   frame restore                  list them; at a terminal, pick which to reboot
#   frame restore TOPIC            reboot that one (a topic, or NAME/TOPIC)
#   frame restore --all            reboot every one
#   frame restore --print [...]    print the boot commands instead of opening tabs
#   frame restore --forget TOPIC|--all
#                                  drop the record(s) without booting — for a
#                                  frame you don't want back
#
# Every frame leaves a durable record in $FRAME_STATEDIR (see
# frame_record_save in lib/helpers.sh). Teardown deletes it; anything else that
# ends a frame — a crash, a reboot, Ghostty quitting, `frame stop`, :FrameQuit
# — leaves it. A record with no live frame behind it is what this lists:
# STATE is "stopped" (frame stop) or "died" (everything else).
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
# One row per record whose frame isn't live: file<TAB>name<TAB>topic, sorted.
typeset -a DEAD
typeset -A REC
for _f in $FRAME_STATEDIR/*.json(N); do
  frame_record_read "$_f" || continue
  frame_session_alive "${REC[name]}" "${REC[topic]}" && continue
  DEAD+=("${REC[name]}	${REC[topic]}	$_f")
done
DEAD=("${(@f)$(print -rl -- "${DEAD[@]}" | sort -t$'\t' -k1,1 -k2,2)}")
DEAD=(${DEAD:#})

if (( ! $#DEAD )); then
  if [[ -n "$SPEC" ]]; then
    echo "$X_MARK nothing to restore matches '$SPEC' — no frame went down without a teardown" >&2
    exit 1
  fi
  echo "$OK_MARK nothing to restore — every recorded frame is running"
  exit 0
fi

_list() {
  # Numbered table of DEAD.
  local _i=0 _r _now=$EPOCHSECONDS _state _dir
  printf '   %-3s %-12s %-20s %-6s %-14s %s\n' '#' NAME TOPIC TYPE STATE DIR
  for _r in "${DEAD[@]}"; do
    (( ++_i ))
    frame_record_read "${_r##*$'\t'}"
    if [[ -n "${REC[stopped_at]:-}" ]]; then
      _state="stopped $(frame_fmt_age $(( _now - REC[stopped_at] ))) ago"
    else
      _state="died"
    fi
    _dir=${REC[dir]/#$HOME/~}
    printf '   %-3s %-12s %-20s %-6s %-14s %s\n' "$_i" "${REC[name]}" "${REC[topic]}" \
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
  echo "Frames that went down without a teardown:"
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
    _close="${(q)FRAME_ROOT}/bin/frame spawn close-tab ${(q)_n}/${(q)_t}"
  else
    _cmd="${(q)FRAME_ROOT}/bin/frame shell -C ${(q)_dir} ${(q)_t}${_sid:+ --resume $_sid}"
    _close="${(q)FRAME_ROOT}/bin/frame spawn close-tab ${(q)_t}"
  fi

  # One-shot stamp: the resumed claude's SessionStart hook tells it it was
  # interrupted (frame swarm --context). Only for a resume — a fresh claude
  # has nothing to have been interrupted in.
  [[ -n "$_sid" ]] && : > "$(frame_rundir)/$_n-$_t.restored"

  if (( PRINT )); then
    print -r -- "$_cmd"
    continue
  fi
  # FRAME_SPAWNED=1: we record the tab's ids ourselves (as frame spawn does);
  # the boot mustn't re-record the front window, which isn't this tab.
  _boot="FRAME_SPAWNED=1 $_cmd && $_close"
  if ! _ids=$(frame_open_window "$_boot"); then
    echo "$X_MARK $_h: couldn't open a ghostty tab — run it yourself: $_cmd" >&2
    _rc=1; continue
  fi
  [[ -n "$_ids" ]] && print -r -- "$_ids" > "$FRAME_RUNDIR/$_n-$_t.nvim.gtab"
  echo "$OK_MARK restoring $_h${_sid:+ (resuming session $_sid)}"
done
exit $_rc
