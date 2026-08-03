# Buffer previews in fzf — `bin/buf-preview.sh`

*Opt-in previewer for fzf.vim users. Frame never wires this up itself —
layouts don't override editor behavior — so everything here goes in your own
init.lua.*

fzf.vim's stock `:Buffers` preview treats each buffer's *name* as a file path.
Frame renames its terminal buffers to bare names (`vite`, `server`, `claude`,
…), so in a frame session every terminal row previews as `File not found vite`
— or, when a name collides with a real path, as the wrong thing entirely (a
buffer named `server` previews the repo's `server/` directory tree).

This is an fzf.vim quirk, not a frame one: in-process pickers (telescope,
snacks, mini.pick) hold the real bufnr and preview buffer contents directly,
so their users need none of this. fzf is an external process — its previewer
only ever sees the row's text.

`bin/buf-preview.sh` is a buffer-first previewer: fzf runs inside nvim, so the
script asks the parent session over `$NVIM` whether the row is a terminal
buffer and, if so, previews its scrollback tail — the live vite log, claude's
screen. Everything else (and every failure: no `$NVIM`, unparsable row, RPC
timeout) falls through to the stock previewer untouched, so file rows keep
their highlighted preview.

## Wiring it up

Opt in from your init.lua by redefining `:Buffers` (fzf.vim skips its
default definition when the command already exists, and the last definition
wins regardless of load order):

```lua
-- frame: buffer-first :Buffers preview — terminal buffers preview their live
-- content; file buffers keep fzf.vim's stock (bat) preview.
local frame_buf_preview = vim.fn.expand('~/git_repos/frame/bin/buf-preview.sh')
if vim.fn.executable(frame_buf_preview) == 1 then
  vim.api.nvim_create_user_command('Buffers', function(o)
    local stock = vim.api.nvim_get_runtime_file('bin/preview.sh', false)[1] or ''
    vim.fn['fzf#vim#buffers'](o.args, {
      options = { '--preview', vim.fn.shellescape(frame_buf_preview) .. ' '
        .. vim.fn.shellescape(stock) .. ' {1} {3}' },
    }, o.bang and 1 or 0)
  end, { bang = true, bar = true, nargs = '?', complete = 'buffer',
         desc = 'fzf buffers with buffer-first preview (frame)' })
end
```

`{1}` is the row's `filename[:lnum]` target (what the stock script already
receives), `{3}` its `[bufnr]` field — how the script finds the buffer without
trusting the name.
