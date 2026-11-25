# frame stop [TOPIC | NAME/TOPIC | --all] [-f] — shut a frame down gracefully
# and KEEP it restorable. The opposite of teardown: nothing is removed (no
# worktree, no branch, no durable record); `frame restore` brings it back with
# its claude conversation resumed.
#
#   frame stop                 the frame you're in
#   frame stop schema          that frame (a topic, or NAME/TOPIC)
#   frame stop --all           every live frame on this machine
#   -f                         stop even with unsaved editor buffers (losing
#                              those edits), or a frame with no durable record
#
# Per frame, over its nvim socket:
#   1. refuse if a file buffer has unsaved changes (-f overrides) — :qa! would
#      throw them away
#   2. Ctrl-C every non-claude terminal buffer (FrameStopBuffers — the same
#      reap teardown uses), then wait until none still has a job running
#      (FrameBusyBuffers), up to FRAME_STOP_TIMEOUT seconds (default 10)
#   3. :qa! and wait for the socket to go away
#   4. stamp the record's stopped_at, so `frame restore` lists it as stopped
#      rather than died
#
# Run from inside the target frame (its own claude stopping it), the work is
# handed to a detached copy — this shell is a terminal buffer of the nvim
# about to quit.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

_usage() {
  echo "Usage: frame stop [TOPIC | NAME/TOPIC | --all] [-f]" >&2
  exit 2
}

FORCE=0 ALL=0 SPEC=""
while (( $# )); do
  case "$1" in
    -f|--force) FORCE=1 ;;
    -a|--all)   ALL=1 ;;
    -h|--help)  sed -n '1,24p' "$FRAME_ROOT/commands/stop.sh" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "$X_MARK unknown flag: $1" >&2; _usage ;;
    *)          [[ -z "$SPEC" ]] || { echo "$X_MARK more than one frame given ($SPEC, $1)" >&2; _usage; }
                SPEC=$1 ;;
  esac
  shift
done
if (( ALL )) && [[ -n "$SPEC" ]]; then
  echo "$X_MARK --all and a TOPIC are mutually exclusive" >&2; _usage
fi

# ── which frames ──────────────────────────────────────────────────────────────
typeset -a TARGETS   # NAME/TOPIC
if (( ALL )); then
  while IFS=$'\t' read -r _n _t _; do
    [[ -n "$_n" ]] && TARGETS+=("$_n/$_t")
  done < <(frame_live_frames)
  if (( ! $#TARGETS )); then
    echo "$OK_MARK no frames running — nothing to stop"
    exit 0
  fi
elif [[ -n "$SPEC" ]]; then
  frame_self_identity 2>/dev/null || true
  frame_resolve_target "$SPEC" || exit 1
  TARGETS=("$NAME/$TOPIC")
else
  if ! frame_self_identity 2>/dev/null; then
    echo "$X_MARK not inside a frame — name one: frame stop TOPIC (or --all)" >&2
    exit 1
  fi
  TARGETS=("$SELF_NAME/$SELF_TOPIC")
fi

# Am I a terminal buffer of this frame's nvim? Then stopping it inline would
# kill this very shell halfway (step 3 SIGHUPs it).
_is_self() {
  [[ -n "${NVIM:-}" && "$1" == "${FRAME_NAME:-}/${FRAME_TOPIC:-}" ]]
}

# Unsaved FILE buffers (terminal buffers are always "modified" — skip them),
# one path per line. Plain vimscript, so it works on a session of any age.
_UNSAVED_EXPR='join(map(filter(getbufinfo({"bufmodified": 1}), {i, b -> getbufvar(b.bufnr, "&buftype") ==# ""}), {i, b -> empty(b.name) ? "[No Name]" : fnamemodify(b.name, ":~")}), "\n")'

_stop_one() {
  # _stop_one NAME TOPIC — returns 0 stopped (or wasn't running), 1 refused/failed.
  local _name=$1 _topic=$2 _sock="$FRAME_RUNDIR/$1-$2.nvim" _h="$1/$2"
  local _rec_file=$(frame_record_file "$_name" "$_topic")
  if ! frame_session_alive "$_name" "$_topic"; then
    echo "$OK_MARK $_h is not running — nothing to stop"
    return 0
  fi
  if [[ ! -f "$_rec_file" ]] && (( ! FORCE )); then
    echo "$X_MARK $_h has no durable record yet (it booted before frame restore existed," >&2
    echo "  and claude hasn't started a session since) — frame restore couldn't bring it" >&2
    echo "  back. Reboot it once, or stop it anyway with: frame stop -f $_h" >&2
    return 1
  fi
  local _unsaved
  _unsaved=$(frame_rpc_expr "$_sock" "$_UNSAVED_EXPR" 5) || _unsaved=""
  if [[ -n "$_unsaved" ]] && (( ! FORCE )); then
    echo "$X_MARK $_h has unsaved changes — save them (:wa) or stop anyway with -f:" >&2
    print -r -- "$_unsaved" | sed 's/^/    /' >&2
    return 1
  fi

  # Drain the terminal buffers while their process trees are intact.
  local _sent _busy _waited=0 _timeout=${FRAME_STOP_TIMEOUT:-10}
  _sent=$(frame_rpc_expr "$_sock" 'luaeval("FrameStopBuffers()")' 5) || _sent=""
  if [[ "$_sent" == <1-> ]]; then
    echo "$RUN_MARK $_h: sent Ctrl-C to $_sent terminal buffer(s) — waiting for them to exit…"
    while :; do
      _busy=$(frame_rpc_expr "$_sock" 'luaeval("FrameBusyBuffers()")' 5) || _busy=""
      if [[ "$_busy" != <-> ]]; then
        sleep 1.5; break           # a session predating the probe: teardown's beat
      fi
      (( _busy == 0 )) && break
      if (( _waited >= _timeout * 2 )); then
        echo "$WARN_MARK $_h: $_busy buffer(s) still busy after ${_timeout}s — quitting anyway"
        break
      fi
      sleep 0.5; (( _waited++ ))
    done
  fi

  # :qa! from any mode, then wait for nvim to unlink its socket.
  if ! nvim --server "$_sock" --remote-send '<Cmd>qa!<CR>' 2>/dev/null; then
    echo "$X_MARK $_h didn't take :qa! — is it wedged?" >&2
    return 1
  fi
  local _i
  for _i in {1..50}; do
    [[ -e "$_sock" ]] || break
    sleep 0.2
  done
  if [[ -e "$_sock" ]]; then
    echo "$X_MARK $_h: nvim still running after 10s" >&2
    return 1
  fi
  frame_record_set "$_name" "$_topic" stopped_at "$EPOCHSECONDS"
  echo "$OK_MARK stopped $_h — bring it back with: frame restore $_h"
  return 0
}

_rc=0 _self=""
for _h in "${TARGETS[@]}"; do
  if _is_self "$_h"; then _self=$_h; continue; fi
  _stop_one "${_h%%/*}" "${_h#*/}" || _rc=1
done

if [[ -n "$_self" ]]; then
  # Check the refusals here, where they're readable, before handing off.
  _sn=${_self%%/*} _st=${_self#*/}
  if (( ! FORCE )); then
    if [[ ! -f "$(frame_record_file "$_sn" "$_st")" ]]; then
      echo "$X_MARK $_self has no durable record yet — frame restore couldn't bring it back;" >&2
      echo "  stop it anyway with: frame stop -f" >&2
      exit 1
    fi
    _unsaved=$(frame_rpc_expr "$FRAME_RUNDIR/$_sn-$_st.nvim" "$_UNSAVED_EXPR" 5) || _unsaved=""
    if [[ -n "$_unsaved" ]]; then
      echo "$X_MARK $_self has unsaved changes — save them (:wa) or stop anyway with -f:" >&2
      print -r -- "$_unsaved" | sed 's/^/    /' >&2
      exit 1
    fi
  fi
  _log="$(frame_rundir)/$_sn-$_st.stop.log"
  echo "$RUN_MARK stopping $_self from inside — handing off to a detached copy (log: $_log)."
  echo "  This window's nvim will quit; bring it back with: frame restore $_self"
  # Unset NVIM so the copy doesn't see itself as inside the frame again.
  NVIM= nohup "$FRAME_ROOT/bin/frame" stop -f "$_self" >"$_log" 2>&1 &
  exit $_rc
fi
exit $_rc
