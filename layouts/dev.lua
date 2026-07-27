-- Frame primary dev layout — opens named terminal buffers, lands in `claude`.
-- Sourced by `frame dev`:  nvim -S layouts/dev.lua
--
-- Parameterized by env vars exported by commands/dev.sh:
--   FRAME_NAME        project name (window title)
--   FRAME_SERVER_CMD  server command (buffer skipped when empty)
--   FRAME_VITE_PORT   primary vite port (title + ngrok target)
--   FRAME_NGROK_AUTO  '1' → auto-run ngrok; else pre-fill the command
-- A project can replace this file wholesale via .frame/dev.lua (committed) or
-- .frame/local/dev.lua (personal).
--
-- Each terminal is its own buffer in a single window (no tabs, no splits).
-- Previous terminals stay alive as hidden buffers — switch between them with
-- :b local / :b server / :bnext / :bprev, etc.

vim.o.hidden = true

local name = vim.env.FRAME_NAME or '?'
local vite_port = vim.env.FRAME_VITE_PORT or ''

-- Name the terminal window so the primary env is tellable apart from worktree
-- windows ("<name>/<topic> :<port>") in Raycast's ghostty window list.
vim.o.title = true
vim.o.titlestring = name .. (vite_port ~= '' and (' :' .. vite_port) or '')

local function term(cmd_name, cmd)
  -- :terminal opens a new terminal buffer in the current window (replacing the
  -- visible buffer; the old one just goes hidden).
  vim.cmd.terminal(cmd ~= '' and cmd or nil)
  -- Rename the terminal buffer (nvim-native equivalent of :Rename).
  vim.cmd('keepalt file ' .. cmd_name)
end

-- Durable variant: auto-runs `cmd`, then `exec`s an interactive zsh so the buffer
-- stays usable after the process exits — crucially, also on Ctrl-C. A plain
-- `zsh -c` exits on SIGINT by default (killing the buffer before `exec` runs), so
-- `trap ':' INT` overrides that: the child still gets the interrupt and dies, but
-- this shell survives to reach `exec`. Rerun by retyping. Assumes `cmd` has no
-- single quotes.
local function term_durable(cmd_name, cmd)
  term(cmd_name, 'zsh -c "trap \':\' INT; ' .. cmd .. '; exec zsh"')
end

-- Pre-filled variant: drops the command into the prompt without running it.
local function term_prefill(cmd_name, cmd)
  term(cmd_name, 'zsh -c "print -z \'' .. cmd .. '\'; exec zsh"')
end

--           name       command
term(        'local',  '')
term(        'node',   '')
if (vim.env.FRAME_SERVER_CMD or '') ~= '' then
  term_durable('server', vim.env.FRAME_SERVER_CMD)
end
if vim.fn.isdirectory('web') == 1 then
  term_durable('vite', 'cd web && npm run dev')
end
if vite_port ~= '' then
  -- Auto-run only when the project opts in (a free ngrok plan allows one live
  -- tunnel, so parallel dev envs shouldn't all grab it on boot).
  if vim.env.FRAME_NGROK_AUTO == '1' then
    term_durable('ngrok', 'ngrok http ' .. vite_port)
  else
    term_prefill('ngrok', 'ngrok http ' .. vite_port)
  end
end
term_durable('claude', 'brew upgrade claude-code && claude --dangerously-skip-permissions')

-- Land showing the claude buffer, in terminal-insert mode, ready to type.
vim.cmd.buffer('claude')
vim.cmd.startinsert()
