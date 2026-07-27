-- Frame worktree layout — opens named terminal buffers, lands in `claude`.
-- Sourced by `frame wt`:  nvim -S layouts/worktree.lua
--
-- Secondary-worktree variant of dev.lua: runs its own server and vite on the
-- free ports commands/wt.sh exported (PORT / <PREFIX>_VITE_PORT / …, inherited
-- by these terminal buffers). Docker services stay owned by the primary env.
--
-- Parameterized by env vars exported by commands/wt.sh:
--   FRAME_NAME        project name
--   FRAME_TOPIC       worktree topic (branch name)
--   FRAME_MAIN_WT     primary checkout (reaper cwd for :FrameDown)
--   FRAME_SERVER_CMD  server command (buffer skipped when empty)
--   FRAME_VITE_PORT   this worktree's vite port (title + ngrok target)
-- A project can replace this file wholesale via .frame/worktree.lua or
-- .frame/local/worktree.lua.

vim.o.hidden = true

local name = vim.env.FRAME_NAME or '?'
local topic = vim.env.FRAME_TOPIC or '?'
local vite_port = vim.env.FRAME_VITE_PORT or ''

-- Name the terminal window "<name>/<topic> :<vite port>" so parallel Ghostty
-- windows are tellable apart — the port shown is the one the browser connects
-- to. nvim owns the title for the whole session, so shell integration can't
-- overwrite it.
vim.o.title = true
vim.o.titlestring = name .. '/' .. topic
    .. (vite_port ~= '' and (' :' .. vite_port) or '')

-- Register a named socket so `frame wt -d TOPIC` can send :qa! remotely.
vim.fn.serverstart('/tmp/' .. name .. '-' .. topic .. '.nvim')

-- :FrameQuit — close the session only: worktree and branch stay intact, and
-- `frame wt <topic>` boots the frame back up later. Equivalent to :qa!
-- (the ! sidesteps vimrc quit guards).
vim.api.nvim_create_user_command('FrameQuit', function()
  vim.cmd('qa!')
end, { desc = 'Quit this frame session (keep worktree + branch)' })

-- :FrameDown[!] — tear down this frame from inside nvim. Spawns a detached
-- `frame wt -d` rooted in the primary checkout; that reaper sends :qa! back to
-- this session, waits for it to exit, then removes the worktree and deletes
-- the branch. Bang = -f (discard uncommitted changes / unmerged commits).
local main_wt = vim.env.FRAME_MAIN_WT or ''
local frame_bin = (vim.env.FRAME_ROOT or '') .. '/bin/frame'
if main_wt ~= '' then
  vim.api.nvim_create_user_command('FrameDown', function(opts)
    local log = '/tmp/' .. name .. '-' .. topic .. '.teardown.log'
    -- Redirect to a log file: once this nvim dies, a write to an inherited
    -- pipe would SIGPIPE the reaper mid-teardown.
    local cmd = string.format('%s wt -d %s%s >%s 2>&1',
      vim.fn.shellescape(frame_bin),
      opts.bang and '-f ' or '',
      vim.fn.shellescape(topic),
      vim.fn.shellescape(log))
    vim.fn.jobstart({ 'zsh', '-c', cmd }, { cwd = main_wt, detach = true })
    -- If teardown is refused (dirty worktree / unmerged branch), this session
    -- survives — surface the reaper's reason after a beat.
    vim.defer_fn(function()
      if vim.fn.filereadable(log) == 1 then
        vim.notify(table.concat(vim.fn.readfile(log), '\n'), vim.log.levels.WARN)
      end
    end, 2500)
  end, { bang = true, desc = 'Tear down this frame (worktree + branch)' })
end

local function term(cmd_name, cmd)
  vim.cmd.terminal(cmd ~= '' and cmd or nil)
  vim.cmd('keepalt file ' .. cmd_name)
end

-- Durable variant: auto-runs `cmd`, then `exec`s an interactive zsh so the buffer
-- stays usable after the process exits — crucially, also on Ctrl-C. A plain
-- `zsh -c` exits on SIGINT by default (killing the buffer before `exec` runs), so
-- `trap ':' INT` overrides that: the child still gets the interrupt and dies, but
-- this shell survives to reach `exec`. Assumes `cmd` has no single quotes.
--
-- Once `cmd` dies, it's appended to the zsh history file so the replacement
-- shell boots with it as the LAST entry — ↑ + Enter reruns it. Appending must
-- happen here (post-exit, pre-exec): the wrapper is non-interactive so the
-- command never enters history on its own, and seeding any earlier would let
-- other exiting shells bury it. `dir`, when given, is entered before `cmd`
-- runs but kept out of the seeded entry, which must rerun from the cwd the
-- replacement shell actually lands in.
local function term_durable(cmd_name, cmd, dir)
  term(cmd_name, 'zsh -c "' .. (dir and ('cd ' .. dir .. '; ') or '')
    .. 'trap \':\' INT; ' .. cmd
    .. '; print -r -- \'' .. cmd .. '\' >> ${HISTFILE:-$HOME/.zsh_history}'
    .. '; exec zsh"')
end

-- Pre-filled variant: drops the command into the prompt without running it.
local function term_prefill(cmd_name, cmd)
  term(cmd_name, 'zsh -c "print -z \'' .. cmd .. '\'; exec zsh"')
end

--           name       command
term(        'local',  '')
if (vim.env.FRAME_SERVER_CMD or '') ~= '' then
  term_durable('server', vim.env.FRAME_SERVER_CMD)
end
if vim.fn.isdirectory('web') == 1 then
  term_durable('vite', 'npm run dev', 'web')
end
if vite_port ~= '' then
  -- Pre-filled, never auto-run: the primary env usually owns the ngrok tunnel.
  term_prefill('ngrok', 'ngrok http ' .. vite_port)
end
term_durable('claude', 'claude --dangerously-skip-permissions')

-- Land showing the claude buffer, in terminal-insert mode, ready to type.
vim.cmd.buffer('claude')
vim.cmd.startinsert()
