# frame ls — list every live frame, across all projects:
#
#   $ frame ls
#      NAME     TOPIC              PORT   STATUS
#    → shell    show-hacker-news   5173   waiting
#      flipnem  schema             5175   working
#      pactduo  billing-fix        -      deploying
#
# STATUS is the same free-text field as the window-title suffix (frame
# status); the claude hooks drive it through the turn lifecycle — "working"
# from prompt (UserPromptSubmit → frame status --prompt) to "waiting" at
# Stop (frame notify).
#
# A dashboard for the shared harness: one row per running frame on this
# machine, so you can spot one and `frame focus` it. Read-only — it never
# creates, boots, or tears anything down.
#
# A running frame is exactly one with a live nvim socket at
# /tmp/<name>-<topic>.nvim (the same sockets status.sh/notify.sh use). For each,
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
typeset -a _rows _f
while IFS= read -r _line; do
  _f=("${(@ps:\t:)_line}")
  _name=$_f[1] _topic=$_f[2] _port=$_f[3] _status=$_f[4]
  [[ -n "$_name" ]] || continue
  _mark=' '
  [[ "$_name" == "$_cur_name" && "$_topic" == "$_cur_topic" ]] && _mark='→'
  # Sort key (name, then topic) up front; stripped before printing.
  _rows+=("$_name	$_topic	$_mark	$_name	$_topic	${_port:--}	${_status:--}")
done < <(frame_live_frames)

if (( ${#_rows} == 0 )); then
  echo "no frames running"
  return 0
fi

# ── render aligned columns ────────────────────────────────────────────────────
_rows=("${(@f)$(print -rl -- "${_rows[@]}" | sort -t$'\t' -k1,1 -k2,2)}")

# Column widths: header labels vs. the widest value in each column.
integer _wn=4 _wt=5 _wp=4   # NAME / TOPIC / PORT
for _r in "${_rows[@]}"; do
  _f=("${(@ps:\t:)_r}")   # name topic mark NAME TOPIC PORT STATUS
  (( ${#_f[4]} > _wn )) && _wn=${#_f[4]}
  (( ${#_f[5]} > _wt )) && _wt=${#_f[5]}
  (( ${#_f[6]} > _wp )) && _wp=${#_f[6]}
done

printf ' %s %-*s  %-*s  %-*s  %s\n' ' ' $_wn NAME $_wt TOPIC $_wp PORT STATUS
for _r in "${_rows[@]}"; do
  _f=("${(@ps:\t:)_r}")
  printf ' %s %-*s  %-*s  %-*s  %s\n' \
    "$_f[3]" $_wn "$_f[4]" $_wt "$_f[5]" $_wp "$_f[6]" "$_f[7]"
done
