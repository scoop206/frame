#!/usr/bin/env zsh
# bin/buf-preview.sh — the buffer-first fzf :Buffers previewer: terminal
# buffers preview their scrollback tail over $NVIM RPC (the stub nvim answers
# the getbufvar/getbufline probes); everything else falls through to the stock
# fzf.vim previewer untouched. The degrade ladder matters most — every broken
# input must land on today's behavior, never an error in the preview pane.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"
BUF_PREVIEW="$FRAME_CHECKOUT/bin/buf-preview.sh"

# A stand-in for fzf.vim's preview.sh that records how it was called.
_mkstock() {
  print -r -- '#!/usr/bin/env zsh
print -r -- "stock:$1"' > "$SANDBOX/stock.sh"
  chmod +x "$SANDBOX/stock.sh"
}

_run() { OUT=$("$@" 2>&1) && STATUS=0 || STATUS=$?; }

test_terminal_buffer_previews_tail() {
  # A terminal row previews the buffer's content — trailing blank padding
  # (the empty screen rows below a terminal's last output) trimmed off — and
  # never touches the stock script. The bufnr comes from the "[N]" field.
  _mkstock
  print -rl -- one two three four five '' '' '' > "$SANDBOX/lines"
  export NVIM="$SANDBOX/fake.sock" FAKE_NVIM_BUFTYPE=terminal \
         FAKE_NVIM_BUFLINES_FILE="$SANDBOX/lines" \
         FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs"
  _run "$BUF_PREVIEW" "$SANDBOX/stock.sh" 'vite:1' '[5] #'
  assert_status 0
  assert_eq "$OUT" $'one\ntwo\nthree\nfour\nfive'
  local exprs=$(<"$SANDBOX/exprs")
  assert_contains "$exprs" "getbufvar(5" "type probe queried the wrong bufnr"
  assert_contains "$exprs" "getbufline(5" "tail fetch queried the wrong bufnr"
}

test_tail_caps_at_preview_height() {
  # fzf exports FZF_PREVIEW_LINES inside the preview; only the last screenful
  # of a long scrollback is printed.
  _mkstock
  print -rl -- one two three four five > "$SANDBOX/lines"
  export NVIM="$SANDBOX/fake.sock" FAKE_NVIM_BUFTYPE=terminal \
         FAKE_NVIM_BUFLINES_FILE="$SANDBOX/lines" FZF_PREVIEW_LINES=2
  _run "$BUF_PREVIEW" "$SANDBOX/stock.sh" 'vite:1' '[5] #'
  assert_status 0
  assert_eq "$OUT" $'four\nfive'
}

test_file_buffer_delegates_to_stock() {
  # A non-terminal buffer (getbufvar answers '' — the stub's default) keeps
  # the stock preview, target passed through untouched (":lnum" intact, for
  # the stock script's centering).
  _mkstock
  export NVIM="$SANDBOX/fake.sock"
  _run "$BUF_PREVIEW" "$SANDBOX/stock.sh" 'README.md:12' '[3]  '
  assert_status 0
  assert_eq "$OUT" "stock:README.md:12"
}

test_outside_nvim_delegates_without_rpc() {
  # No $NVIM (sandbox_up strips it) → straight to stock, no nvim contact at
  # all — the stub's tripwire would exit 97 loudly if the script called out.
  _mkstock
  _run "$BUF_PREVIEW" "$SANDBOX/stock.sh" 'vite:1' '[5] #'
  assert_status 0
  assert_eq "$OUT" "stock:vite:1"
}

test_garbled_bufnr_field_delegates() {
  # A field that doesn't parse to a number (ANSI leak, format drift) falls
  # through to stock rather than sending a broken expr.
  _mkstock
  export NVIM="$SANDBOX/fake.sock"
  _run "$BUF_PREVIEW" "$SANDBOX/stock.sh" 'vite:1' 'junk'
  assert_status 0
  assert_eq "$OUT" "stock:vite:1"
}

test_rpc_failure_falls_through_to_stock() {
  # Terminal probe succeeds but the tail fetch RPC errors (no
  # FAKE_NVIM_BUFLINES_FILE → the stub exits 1, like a just-wiped buffer or a
  # dead socket) → stock, not an empty/broken preview.
  _mkstock
  export NVIM="$SANDBOX/fake.sock" FAKE_NVIM_BUFTYPE=terminal
  _run "$BUF_PREVIEW" "$SANDBOX/stock.sh" 'vite:1' '[5] #'
  assert_status 0
  assert_eq "$OUT" "stock:vite:1"
}

test_no_stock_readable_file_is_cat() {
  # Bottom of the ladder, half full: no stock script but the target IS a real
  # file → bare cat.
  print -r -- "hello" > "$SANDBOX/notes.md"
  cd "$SANDBOX"
  _run "$BUF_PREVIEW" '' 'notes.md:1' '[2]  '
  assert_status 0
  assert_eq "$OUT" "hello"
}

test_no_stock_no_file_reports_not_found() {
  # Bottom of the ladder, empty: mimic the stock previewer's wording and its
  # nonzero exit.
  cd "$SANDBOX"
  _run "$BUF_PREVIEW" '' 'vite:1' 'junk'
  assert_status 1
  assert_eq "$OUT" "File not found vite"
}

test_bare_invocation_prints_usage() {
  # A human running the script by hand (fzf always supplies all three argv)
  # gets pointed at the doc wiring, not a confusing "File not found ".
  _run "$BUF_PREVIEW"
  assert_status 2
  assert_contains "$OUT" "usage"
  assert_contains "$OUT" "docs/fzf-buffer-previews.md"
}

run_tests "$0"
