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
--   FRAME_VITE_PORT   this worktree's vite port (title + ngrok target)
--   FRAME_BUFFERS     the buffers to open (authoritative; empty → none)
-- Config vars that buffers.json references (SERVER_CMD, PORT_PREFIX, the
-- scanned ports) are exported by wt.sh under their own names.
-- The buffers themselves come from the buffers.json registry (see below).

vim.o.hidden = true

local name = vim.env.FRAME_NAME or '?'
local topic = vim.env.FRAME_TOPIC or '?'
local vite_port = vim.env.FRAME_VITE_PORT or ''

-- Name the terminal window "<name> [ <topic> :<vite port> ]" so parallel
-- Ghostty windows are tellable apart — bare name, the topic bracketed with the
-- browser's vite port beside it (omitted when there's no vite port). nvim owns
-- the title for the whole session, so shell integration can't overwrite it.
-- lib/helpers.sh frame_base_title builds the same shape for the pre-nvim title
-- and the notify banner; commands/focus.sh matches against it. Keep them in step.
local base_title = name .. ' [ ' .. topic
    .. (vite_port ~= '' and (' :' .. vite_port) or '')
    .. ' ]'
vim.o.title = true
vim.o.titlestring = base_title

-- FrameState — this session's coordination state, kept in one place. It lives
-- in the running nvim (like the socket in the identity model) and dies with it,
-- so there's nothing to garbage-collect. The window title is a pure *view* of
-- .status, never the source of truth (FrameInfo reads the field, never
-- re-parses the title).
--   status       window-title status suffix (frame status / :FrameStatus)
--   chan         per-buffer terminal job channels (name → channel), for send
--   subscribers  return addresses awaiting a reply — Phase 3; empty for now
--   inbox        reports routed home to this frame — Phase 3; empty for now
-- The notify mute switch is deliberately NOT a field here: it stays
-- vim.g.frame_notify_muted because `frame notify` reads it over RPC as
-- get(g:, 'frame_notify_muted', 0), so sessions predating it degrade to
-- unmuted. Keeping it a g: var preserves that cheap, backward-compatible read.
local FrameState = { status = '', chan = {}, subscribers = {}, inbox = {} }

-- Status suffix: appends " - TEXT" to the base title (which never changes).
-- Global so `frame status` can call it over the socket from any terminal
-- buffer; returns the new title for the caller to echo.
_G.FrameSetStatus = function(status)
  FrameState.status = status
  vim.o.titlestring = base_title
      .. (status ~= '' and (' - ' .. status) or '')
  return vim.o.titlestring
end

-- _G.FrameInfo() — this session's identity as one tab-delimited record for
-- `frame ls`:   name<TAB>topic<TAB>port<TAB>status
-- Queried over the socket exactly like FrameSetStatus, so ls reads clean fields
-- straight from the session instead of parsing the window title (whose dashes
-- make <name>-<topic> ambiguous). port and status are '' when absent — ls
-- renders those as '-'. Sessions booted before this helper existed lack it; ls
-- falls back to parsing &titlestring for those.
_G.FrameInfo = function()
  return table.concat({ name, topic, vite_port, FrameState.status }, '\t')
end

-- _G.FrameAgentSend(text) — type TEXT into the `claude` buffer and submit it,
-- exactly as if the operator had typed it there. `frame agent <name/topic> TEXT`
-- calls this over the socket. FrameState.chan['claude'] is the buffer's terminal
-- job channel (captured at boot, bottom of this file); chansend to it writes to
-- the pty exactly as if the keys were typed. The trailing '\r' is the Enter key
-- (a pty in raw mode delivers Return as CR). Returns 'ok', or 'no-claude-buffer'
-- when this frame opened no claude buffer to message.
_G.FrameAgentSend = function(text)
  local chan = FrameState.chan['claude']
  if not chan then return 'no-claude-buffer' end
  vim.fn.chansend(chan, text .. '\r')
  return 'ok'
end

-- :FrameStatus TEXT — set the status suffix; no TEXT clears it.
vim.api.nvim_create_user_command('FrameStatus', function(opts)
  _G.FrameSetStatus(opts.args)
end, { nargs = '*', desc = 'Set window-title status suffix (empty clears)' })

-- Banner mute switch, session-scoped: before popping a macOS banner,
-- `frame notify` asks this session over the socket — get(g:, 'frame_notify_muted', 0)
-- — so muting lives with the frame and dies with it. Only the banner+sound
-- is suppressed; the window-title status still updates.
-- :FrameNotify off | on — mute/unmute; bare :FrameNotify reports state.
vim.g.frame_notify_muted = 0
vim.api.nvim_create_user_command('FrameNotify', function(opts)
  if opts.args == 'off' then vim.g.frame_notify_muted = 1
  elseif opts.args == 'on' then vim.g.frame_notify_muted = 0
  elseif opts.args ~= '' then
    vim.notify('usage: :FrameNotify [on|off]', vim.log.levels.ERROR)
    return
  end
  vim.notify('frame: notify banners '
    .. (vim.g.frame_notify_muted == 1 and 'muted' or 'on')
    .. ' for ' .. base_title)
end, {
  nargs = '?',
  complete = function() return { 'on', 'off' } end,
  desc = 'Mute/unmute frame notify banners (bare: show state)',
})

-- Register a named socket so `frame wt -d TOPIC` can send :qa! remotely.
-- serverstart THROWS if the path already exists — unguarded, that would abort
-- this whole layout (no terminals, no :FrameDown). Probe a conflicting socket:
-- connectable means a live twin session owns it (leave it alone); otherwise
-- it's stale debris from a crash — reclaim it.
local sock = '/tmp/' .. name .. '-' .. topic .. '.nvim'
if not pcall(vim.fn.serverstart, sock) then
  local live, chan = pcall(vim.fn.sockconnect, 'pipe', sock, { rpc = true })
  if live and chan > 0 then
    pcall(vim.fn.chanclose, chan)
    vim.notify('frame: ' .. sock .. ' belongs to another live session — '
      .. 'frame status / frame wt -d will reach that one, not this window',
      vim.log.levels.WARN)
  else
    vim.fn.delete(sock)
    if not pcall(vim.fn.serverstart, sock) then
      vim.notify('frame: could not register ' .. sock, vim.log.levels.WARN)
    end
  end
end

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
    -- Normally the reaper's :qa! kills this session and nothing below runs.
    -- Two ways it can't: teardown was refused (dirty worktree / unmerged
    -- branch) — surface the reason; or teardown succeeded without reaching us
    -- (socket missing/stale) — the worktree under our feet is gone, so finish
    -- the job and close the window ourselves.
    local tries = 0
    local function watch()
      tries = tries + 1
      local text = vim.fn.filereadable(log) == 1
          and table.concat(vim.fn.readfile(log), '\n') or ''
      if text:find('removed worktree and branch', 1, true) then
        vim.cmd('qa!')
      elseif text:find('✗', 1, true) then
        vim.notify(text, vim.log.levels.WARN)
      elseif tries < 10 then
        vim.defer_fn(watch, 1500)
      elseif text ~= '' then
        vim.notify(text, vim.log.levels.WARN)
      end
    end
    vim.defer_fn(watch, 1500)
  end, { bang = true, desc = 'Tear down this frame (worktree + branch)' })
else
  -- Shell frame (frame shell): no worktree or branch — teardown means
  -- deleting the topic directory itself, and no git backs it up. So where a
  -- worktree frame's plain :FrameDown refuses on uncommitted work, here
  -- EVERYTHING is uncommitted: plain always refuses, :FrameDown! deletes.
  -- Same reaper shape as above — nvim can't rm its own cwd out from under
  -- its terminal buffers, so a detached job waits for the socket to unlink
  -- (nvim removes it on exit) and only then deletes; if nvim somehow
  -- survives, the timeout leaves the directory alone.
  local shell_dir = vim.fn.getcwd()
  vim.api.nvim_create_user_command('FrameDown', function(opts)
    if not opts.bang then
      vim.notify('shell frame: nothing in ' .. shell_dir .. ' is under git — '
        .. ':FrameDown! deletes it forever; :FrameQuit keeps it',
        vim.log.levels.WARN)
      return
    end
    if shell_dir == '' or shell_dir == '/' or shell_dir == vim.env.HOME then
      vim.notify('frame: refusing to delete ' .. shell_dir, vim.log.levels.ERROR)
      return
    end
    local cmd = string.format(
      'n=0; while [ -e %s ] && [ $n -lt 100 ]; do sleep 0.2; n=$((n+1)); done; '
      .. '[ -e %s ] || rm -rf %s',
      vim.fn.shellescape(sock), vim.fn.shellescape(sock),
      vim.fn.shellescape(shell_dir))
    vim.fn.jobstart({ 'zsh', '-c', cmd },
      { cwd = vim.fn.fnamemodify(shell_dir, ':h'), detach = true })
    vim.cmd('qa!')
  end, { bang = true,
    desc = 'Delete this casual frame\'s directory (! required — no git net)' })
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

-- ── buffers ──────────────────────────────────────────────────────────────────
-- Which terminals open is data, not code: $FRAME_ROOT/buffers.json is the
-- single registry of every buffer frame supports — project-unique buffers
-- are defined there too; there is no project-level registry. Per entry:
-- name; mode (bare | durable | prefill, default durable); command — ${VAR}
-- replaced from the environment at boot; optional dir to run in; env — vars
-- the command reads (a declared contract: unset ones are warned about, never
-- set here); focus — land here after boot.
--
-- BUFFERS=(…) in config.sh — FRAME_BUFFERS here, required by frame wt — is
-- authoritative even when empty: exactly those buffers open, and an empty
-- list opens none. No conditional gating beyond that: a command
-- missing its env or dir fails inside its own buffer, visibly. The one
-- softening: a command that resolves to '' opens as a bare shell (an empty
-- durable command would be a zsh parse error — a broken buffer, not an
-- instructive failure).

local function read_json(path)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local ok, decoded = pcall(vim.json.decode,
    table.concat(vim.fn.readfile(path), '\n'))
  if ok and type(decoded) == 'table' then return decoded end
  vim.notify('frame: ignoring unparsable ' .. path, vim.log.levels.WARN)
  return nil
end

local function interpolate(s)
  return (s:gsub('%${([%w_]+)}', function(v) return vim.env[v] or '' end))
end

local buffers = read_json((vim.env.FRAME_ROOT or '') .. '/buffers.json') or {}

local picked, index = {}, {}
for _, b in ipairs(buffers) do index[b.name] = b end
for bname in (vim.env.FRAME_BUFFERS or ''):gmatch('[^%s,]+') do
  if index[bname] then table.insert(picked, index[bname])
  else
    vim.notify('frame: BUFFERS names unknown buffer "' .. bname .. '"',
      vim.log.levels.WARN)
  end
end

local focus, launched, missing = nil, 0, {}
for _, b in ipairs(picked) do
  local mode = b.mode or 'durable'
  local cmd = interpolate(b.command or '')
  if cmd == '' then mode = 'bare' end
  if mode == 'durable' then term_durable(b.name, cmd, b.dir)
  elseif mode == 'prefill' then term_prefill(b.name, cmd)
  else term(b.name, '') end
  -- Right after term*(), the new terminal is the current buffer — record its
  -- job channel so FrameAgentSend can type into it later (see FrameState above).
  FrameState.chan[b.name] = vim.b.terminal_job_id
  launched = launched + 1
  if b.focus then focus = b.name end
  for _, e in ipairs(b.env or {}) do
    local var = interpolate(e)
    if (vim.env[var] or '') == '' then
      table.insert(missing, b.name .. ' reads $' .. var)
    end
  end
end
if #missing > 0 then
  vim.notify('frame: env some buffers read is unset — '
    .. table.concat(missing, ', '), vim.log.levels.WARN)
end

-- Land in the focus buffer (without one, stay in the last opened), in
-- terminal-insert mode, ready to type.
if focus then vim.cmd.buffer(focus) end
if launched > 0 then vim.cmd.startinsert() end
