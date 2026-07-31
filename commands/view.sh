# frame view [TOPIC | NAME/TOPIC] — dump one frame's full state:
#
#   $ frame view
#     flipnem [ schema ]   → this frame
#
#     socket     /tmp/frame/flipnem-schema.nvim
#     cwd        ~/git_repos/_flipnem-schema
#     main wt    ~/git_repos/flipnem
#
#     status     working
#     ready      no
#     notify     on
#
#     ports      api 3001 · vite 5174 · hmr 24679
#     server     npm run dev
#     buffers    claude, local
#
#     broker     #7 in-flight · queued #8, #9
#     inbox      2 pending (from pactduo, remote)
#
# The debug companion to `frame ls`: ls is the one-line-per-frame dashboard,
# view is everything about a single frame. No arg dumps the frame you're in;
# a TOPIC (or NAME/TOPIC) targets another, resolved exactly like `frame req` /
# `frame deliver` (frame_resolve_target — same-project sibling first, then the
# unique live frame carrying that topic). Read-only, one RPC round-trip: the
# session reports its own attributes via FrameDebug (layouts/worktree.lua), so
# view never re-parses the title or guesses. The inbox is peeked, never drained.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

# ── resolve the target frame → NAME / TOPIC / SOCKET ──────────────────────────
if (( $# == 0 )); then
  # No arg: the frame we're in. Same identity derivation as `frame status`.
  if ! frame_self_identity; then
    echo "$X_MARK not inside a frame — pass a TOPIC or NAME/TOPIC to view one" >&2
    exit 1
  fi
  NAME=$SELF_NAME TOPIC=$SELF_TOPIC SOCKET="$FRAME_RUNDIR/$NAME-$TOPIC.nvim"
  if [[ ! -S "$SOCKET" ]]; then
    echo "$X_MARK no frame session for $NAME/$TOPIC (no socket at $SOCKET)" >&2
    frame_session_down_hint "$NAME" "$TOPIC"
    exit 1
  fi
else
  # A target: set SELF_* first so a bare topic can resolve to our own sibling,
  # then resolve (best-effort self — outside any frame we just search live ones).
  frame_self_identity 2>/dev/null || true
  frame_resolve_target "$1" || exit 1
fi

# ── one round-trip: the session dumps its own attributes ──────────────────────
if ! _dump=$(frame_rpc_expr "$SOCKET" 'v:lua.FrameDebug()'); then
  echo "$X_MARK session at $SOCKET didn't answer FrameDebug — the layout predates" >&2
  echo "  it. Reboot the frame for the full view (:FrameQuit, then frame wt $TOPIC)." >&2
  exit 1
fi

# key<TAB>value lines → assoc array. IFS=tab splits on the first tab only, so a
# value may itself contain spaces (e.g. the server command).
typeset -A A
_k= _v=
while IFS=$'\t' read -r _k _v; do
  [[ -n "$_k" ]] && A[$_k]=$_v
done <<< "$_dump"

# ── render ────────────────────────────────────────────────────────────────────
# '-' for an empty field; ~ for $HOME in paths; comma-lists get ", " spacing.
_or()   { [[ -n "$1" ]] && print -r -- "$1" || print -r -- '-'; }
_tilde(){ [[ -n "$1" ]] && print -r -- "${1/#$HOME/~}" || print -r -- '-'; }
_commas(){ [[ -n "$1" ]] && print -r -- "${1//,/, }" || print -r -- '-'; }

# Heading: "NAME [ TOPIC ]", marked when it's the frame we're standing in.
_head="${A[name]} [ ${A[topic]} ]"
if [[ "${A[name]}" == "${SELF_NAME:-}" && "${A[topic]}" == "${SELF_TOPIC:-}" ]]; then
  _head+="   → this frame"
fi

# ports: "api X · vite Y · hmr Z", each present part only; none → the no-web note.
typeset -a _ports
[[ -n "${A[api_port]}"  ]] && _ports+=("api ${A[api_port]}")
[[ -n "${A[vite_port]}" ]] && _ports+=("vite ${A[vite_port]}")
[[ -n "${A[hmr_port]}"  ]] && _ports+=("hmr ${A[hmr_port]}")
if (( ${#_ports} )); then _ports_line="${(j: · :)_ports}"; else _ports_line="- (no web stack)"; fi

# broker: in-flight id + queued ids (bare 'rN' handles, as the broker mints
# them), or "idle".
_broker=idle
if [[ -n "${A[broker_inflight]}" || -n "${A[broker_queue]}" ]]; then
  typeset -a _bparts
  [[ -n "${A[broker_inflight]}" ]] && _bparts+=("${A[broker_inflight]} in-flight")
  [[ -n "${A[broker_queue]}" ]] && _bparts+=("queued ${A[broker_queue]//,/, }")
  _broker="${(j: · :)_bparts}"
fi

# inbox: "N pending (from …)", or "empty".
if (( ${A[inbox_count]:-0} > 0 )); then
  _inbox="${A[inbox_count]} pending (from $(_commas "${A[inbox_from]}"))"
else
  _inbox=empty
fi

print -r -- "  $_head"
print
printf '  %-10s %s\n' socket  "$SOCKET"
printf '  %-10s %s\n' cwd     "$(_tilde "${A[cwd]}")"
printf '  %-10s %s\n' 'main wt' "$(_tilde "${A[main_wt]}")"
print
printf '  %-10s %s\n' status  "$(_or "${A[status]}")"
printf '  %-10s %s\n' ready   "$([[ ${A[ready]} == 1 ]] && echo yes || echo no)"
printf '  %-10s %s\n' notify  "$(_or "${A[notify]}")"
[[ "${A[ephemeral]}" == yes ]] && printf '  %-10s %s\n' ephemeral yes
print
printf '  %-10s %s\n' ports   "$_ports_line"
printf '  %-10s %s\n' server  "$(_or "${A[server]}")"
printf '  %-10s %s\n' buffers "$(_commas "${A[buffers]}")"
print
printf '  %-10s %s\n' broker  "$_broker"
printf '  %-10s %s\n' inbox   "$_inbox"
