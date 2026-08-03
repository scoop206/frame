#!/usr/bin/env zsh
# buf-preview.sh — fzf.vim :Buffers preview that previews the BUFFER, not a
# path that happens to share its name.
#
# fzf.vim's stock previewer (bin/preview.sh in the plugin) treats each row's
# buffer NAME as a file path. frame renames its terminal buffers to bare names
# (vite, server, claude — layouts/session.lua term()), so in a frame session
# every terminal row previews as "File not found vite" — or, on a name
# collision, as the wrong thing entirely (a buffer named `server` shows the
# repo's server/ directory tree).
#
# This wrapper checks the buffer FIRST, the filesystem second. fzf runs inside
# nvim, so $NVIM carries the parent session's RPC socket; a terminal buffer's
# scrollback tail (its latest log lines / the TUI's screen) IS its preview.
# Anything that isn't a terminal buffer delegates to the stock script
# untouched, so file rows keep their bat-highlighted preview.
#
# frame never installs this — wiring it is the user's editor-config call
# (docs/fzf-buffer-previews.md), per frame's rule of never overriding
# editor behavior from the layout. Opt in from init.lua by redefining
# :Buffers with
#     --preview '<this script> <stock preview.sh> {1} {3}'
# ({1} = the row's filename[:lnum] target, {3} = its "[bufnr]" field; fzf
# hands both over ANSI-stripped and shell-quoted).
#
# usage: buf-preview.sh STOCK_PREVIEW_SH TARGET BUFNR_FIELD
#
# Degrades to the stock script whenever anything is missing: no $NVIM (run
# outside nvim), an unparsable bufnr field, or a failed/timed-out RPC
# (frame_rpc_expr bounds it, so a wedged session costs seconds, never a hung
# preview). With no usable stock script either, a readable file is cat'd and
# anything else gets the stock previewer's own not-found wording.

FRAME_ROOT="${${(%):-%x}:A:h:h}"
source "$FRAME_ROOT/lib/helpers.sh"

# fzf always passes all three argv (placeholders expand to '' at worst); fewer
# means a human ran this by hand — tell them what it is and how to wire it in.
if (( $# < 2 )); then
  print -ru2 -- "buf-preview.sh — buffer-first fzf.vim :Buffers previewer (not a frame subcommand)
usage (as an fzf --preview command, from your init.lua):
    --preview '$0 <stock preview.sh> {1} {3}'
See docs/fzf-buffer-previews.md in the frame repo for the full init.lua snippet."
  exit 2
fi

stock=$1 target=$2

delegate() {
  [[ -n "$stock" && -x "$stock" ]] && exec "$stock" "$target"
  local f=${target%%:*}
  [[ -f "$f" && -r "$f" ]] && exec cat -- "$f"
  print -r -- "File not found $f"
  exit 1
}

# "[12] %" → 12. An ANSI leak or reordered field parses non-numeric and falls
# through to today's behavior rather than erroring in the preview pane.
bufnr=${3#\[}; bufnr=${bufnr%%\]*}
[[ -n "${NVIM:-}" && "$bufnr" == <-> ]] || delegate

buftype=$(frame_rpc_expr "$NVIM" "getbufvar($bufnr, '&buftype')") || delegate
[[ "$buftype" == terminal ]] || delegate

# The tail is the story for a terminal. Fetch a padded window — terminals
# blank-pad below their last output — then trim trailing blanks and keep the
# last screenful ($FZF_PREVIEW_LINES is exported by fzf inside the preview).
rows=${FZF_PREVIEW_LINES:-${LINES:-60}}
(( rows > 0 )) || rows=60   # $LINES is 0 without a tty; a 0-row tail previews as blank
content=$(frame_rpc_expr "$NVIM" \
  "join(getbufline($bufnr, max([1, getbufinfo($bufnr)[0].linecount - $((rows + 400))]), '\$'), nr2char(10))" \
  5) || delegate
print -r -- "$content" | awk -v max="$rows" '
  { line[NR] = $0 }
  END {
    n = NR
    while (n > 0 && line[n] ~ /^[[:space:]]*$/) n--
    s = n - max + 1; if (s < 1) s = 1
    for (i = s; i <= n; i++) print line[i]
  }'
