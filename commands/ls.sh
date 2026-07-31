# frame ls — list every live frame, across all projects:
#
#   $ frame ls
#      NAME     TOPIC              PORT   DUR       QUEUE  INBOX  STATUS
#    → shell    show-hacker-news   5173   -         -      -      waiting
#      flipnem  schema             5175   40s       -      -      working
#      pactduo  billing-fix        -      -         2      3      deploying
#      orch     fan-out            5180   STUCK 7m  1      -      working
#
# STATUS is the same free-text field as the window-title suffix (frame
# status); the claude hooks drive it through the turn lifecycle — "working"
# from prompt (UserPromptSubmit → frame status --prompt) to "waiting" at
# Stop (frame notify).
#
# DUR / QUEUE / INBOX are a read-only peek at the claude broker
# (docs/claude-broker.md), straight off the same FrameInfo RPC — never draining.
# Each shows '-' when there's nothing to report:
#   DUR    how long the current in-flight turn has been running (Ns/Nm) — the
#          turn's duration so far. STUCK Nm once past FRAME_STUCK_SECS (default
#          300) — a likely wedged inflight lock: the turn ended but the Stop hook
#          never advanced it. A legit long turn looks the same until the
#          threshold — the age is the tell, not an alarm.
#   QUEUE  requests waiting behind the in-flight one.
#   INBOX  reports delivered but not yet drained by `frame inbox`; a count that
#          only ever climbs is undrained mail piling up.
# Tune the wedge threshold with FRAME_STUCK_SECS (seconds).
#
# A dashboard for the shared harness: one row per running frame on this
# machine, so you can spot one and `frame focus` it. Read-only — it never
# creates, boots, or tears anything down.
#
# A running frame is exactly one with a live nvim socket at
# $FRAME_RUNDIR/<name>-<topic>.nvim (same sockets status.sh/notify.sh use). For each,
# we ask the session for its own identity over that socket — FrameInfo, added
# next to FrameSetStatus in layouts/worktree.lua — rather than parsing the
# filename, whose <name>-<topic> is ambiguous when the topic has dashes. A
# socket that doesn't answer FrameInfo is skipped: either dead (stale debris
# from a crash) or a session predating the helper, which a reboot fixes.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

# ── which frame am I in? (to mark it with →) ──────────────────────────────────
# Same identity derivation as status.sh/focus.sh, but fully best-effort: ls
# runs from anywhere (including a plain terminal in no frame at all), so a
# failure here just means no row gets marked — it must never abort the listing.
_cur_name='' _cur_topic=''
if ! frame_project_root >/dev/null 2>&1 \
    && [[ -n "${FRAME_NAME:-}" && -n "${FRAME_TOPIC:-}" ]]; then
  _cur_name=$FRAME_NAME _cur_topic=$FRAME_TOPIC
elif frame_project_root >/dev/null 2>&1 && frame_load_config 2>/dev/null; then
  _cur_name=$NAME
  if [[ "${PROJECT_ROOT:t}" == _$NAME-* ]]; then
    _cur_topic="${${PROJECT_ROOT:t}#_$NAME-}"
  else
    _cur_topic=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null) || true
  fi
fi

# ── ask each live socket for its identity ─────────────────────────────────────
# The socket sweep + FrameInfo query lives in lib/helpers.sh (frame_live_frames),
# shared with the creation paths' topic-collision guard so the two can't drift.
# It prints one `name<TAB>topic<TAB>port<TAB>status` row per live frame; here we
# just mark the current frame and shape the columns. Split with (ps:\t:), which
# keeps empty fields — `read` treats the tab as IFS whitespace and merges runs
# of it, so a port-less frame's status would slide left into the PORT column.
# ── broker cells: FrameInfo's raw `<age>,<queue>,<inbox>` triple → TURN/QUEUE/INBOX
# Splits the one health field into three display cells, tab-separated, each '-'
# when there's nothing to show. Presentation only — thresholds and formatting
# live here, not in the broker, which just ships numbers. Empty triple (a
# pre-health session) → all '-'.
_frame_comms_cells() {
  local _h=$1
  [[ -n "$_h" ]] || { print -r -- $'-\t-\t-'; return; }
  local _age=${_h%%,*}; _h=${_h#*,}
  local _q=${_h%%,*}    _in=${_h#*,}
  local _stuck=${FRAME_STUCK_SECS:-300} _turn='-' _disp
  if [[ -n "$_age" ]]; then
    if (( _age < 90 )); then _disp="${_age}s"; else _disp="$(( _age / 60 ))m"; fi
    if (( _age >= _stuck )); then _turn="STUCK ${_disp}"; else _turn=$_disp; fi
  fi
  (( _q  > 0 )) || _q='-'
  (( _in > 0 )) || _in='-'
  print -r -- "$_turn	$_q	$_in"
}

typeset -a _rows _f
while IFS= read -r _line; do
  _f=("${(@ps:\t:)_line}")
  _name=$_f[1] _topic=$_f[2] _port=$_f[3] _status=$_f[4] _health=$_f[5]
  [[ -n "$_name" ]] || continue
  _mark=' '
  [[ "$_name" == "$_cur_name" && "$_topic" == "$_cur_topic" ]] && _mark='→'
  IFS=$'\t' read -r _turn _queue _inbox <<< "$(_frame_comms_cells "$_health")"
  # Sort key (name, then topic) up front; stripped before printing.
  _rows+=("$_name	$_topic	$_mark	$_name	$_topic	${_port:--}	$_turn	$_queue	$_inbox	${_status:--}")
done < <(frame_live_frames)

if (( ${#_rows} == 0 )); then
  echo "no frames running"
  return 0
fi

# ── render aligned columns ────────────────────────────────────────────────────
_rows=("${(@f)$(print -rl -- "${_rows[@]}" | sort -t$'\t' -k1,1 -k2,2)}")

# Column widths: header labels vs. the widest value in each column.
integer _wn=4 _wt=5 _wp=4 _wtu=3 _wq=5 _wi=5   # NAME/TOPIC/PORT/DUR/QUEUE/INBOX
for _r in "${_rows[@]}"; do
  _f=("${(@ps:\t:)_r}")   # name topic mark NAME TOPIC PORT DUR QUEUE INBOX STATUS
  (( ${#_f[4]}  > _wn ))  && _wn=${#_f[4]}
  (( ${#_f[5]}  > _wt ))  && _wt=${#_f[5]}
  (( ${#_f[6]}  > _wp ))  && _wp=${#_f[6]}
  (( ${#_f[7]}  > _wtu )) && _wtu=${#_f[7]}
  (( ${#_f[8]}  > _wq ))  && _wq=${#_f[8]}
  (( ${#_f[9]}  > _wi ))  && _wi=${#_f[9]}
done

printf ' %s %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %s\n' \
  ' ' $_wn NAME $_wt TOPIC $_wp PORT $_wtu DUR $_wq QUEUE $_wi INBOX STATUS
for _r in "${_rows[@]}"; do
  _f=("${(@ps:\t:)_r}")
  printf ' %s %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %s\n' \
    "$_f[3]" $_wn "$_f[4]" $_wt "$_f[5]" $_wp "$_f[6]" \
    $_wtu "$_f[7]" $_wq "$_f[8]" $_wi "$_f[9]" "$_f[10]"
done
