# frame reload-editor — the PostToolUse-hook sensor: after Claude edits a file,
# reload that file into THIS frame's nvim buffer (if it's open) so a buffer-tied
# viewer — markdown-preview.nvim, a README the user is reading — follows the edit
# with zero manual :e. Reads the PostToolUse JSON Claude Code pipes in on stdin,
# pulls the edited path, and drives this frame's nvim over its socket:
# v:lua.FrameReload(path). See layouts/session.lua FrameReload for the buffer
# logic (open? clean? reload; dirty → warn, never clobber) and the docs above it.
#
# Wired by frame_write_claude_hooks as
#   PostToolUse (Edit|Write|MultiEdit|NotebookEdit) → 'frame reload-editor'.
# Best-effort and STRICTLY do-no-harm: it fires synchronously after EVERY edit,
# so the idle path (not in a frame, or the file isn't open) must be cheap and
# silent, and a wedged nvim must not stall the edit. Every exit is 0 — a hook
# that fails a tool call would be worse than the manual reload it replaces. Frame
# deliberately owns nothing in the user's editor config; when this bails, nvim's
# own autoread default (and a manual :e) is the fallback, as it was before.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

# ── cheapest guards first: bail before reading stdin or touching nvim ─────────
# Not in a frame (bare terminal / missing identity) → nothing to reload. The
# common idle case must never spawn an nvim round trip.
[[ -n "${FRAME_NAME:-}" && -n "${FRAME_TOPIC:-}" && -n "${FRAME_RUNDIR:-}" ]] || exit 0
_sock="$FRAME_RUNDIR/$FRAME_NAME-$FRAME_TOPIC.nvim"
# No live socket → nvim isn't listening (or this isn't a real frame). Exit before
# any parse or RPC; nvim's own autoread catches the buffer up on the next check.
[[ -S "$_sock" ]] || exit 0
# Parsing the payload needs jq; without it, don't guess at JSON — just bail. jq
# is a soft dependency across frame (cf. frame_settings_is_frame_only).
command -v jq >/dev/null 2>&1 || exit 0

# ── extract the edited path from the PostToolUse payload on stdin ─────────────
# The hook always pipes JSON in; a tty on stdin means a human ran this by hand
# (no payload) — exit rather than block forever on `cat`.
[[ -t 0 ]] && exit 0
# Edit/Write/MultiEdit carry .tool_input.file_path; NotebookEdit uses
# .tool_input.notebook_path. `// empty` so jq prints nothing (not "null") when
# neither is present, and `|| _path=` keeps set -e from aborting on jq's exit 1.
_payload=$(cat 2>/dev/null) || exit 0
_path=$(print -r -- "$_payload" | jq -re '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null) || _path=
[[ -n "$_path" ]] || exit 0
# Resolve a cwd-relative path against the hook's cwd (= this claude's cwd). Leave
# absolute paths as-is; FrameReload runs fnamemodify(:p) to match how nvim stores
# the buffer name, so we don't over-normalize (no symlink resolution) here.
[[ "$_path" == /* ]] || _path="$PWD/$_path"

# ── drive this frame's nvim: reload just that buffer ─────────────────────────
# Single quotes in the path would break out of the Vimscript string literal;
# double them (the Vimscript escape) before embedding. frame_rpc_expr bounds the
# call with a short timeout (FRAME_RPC_TIMEOUT, default 2s) — a wedged nvim times
# out instead of stalling the edit. Output and exit status are both discarded:
# reload is advisory, and the layout's autoread is the fallback regardless.
_esc=${_path//\'/\'\'}
frame_rpc_expr "$_sock" "v:lua.FrameReload('$_esc')" >/dev/null 2>&1 || true
exit 0
