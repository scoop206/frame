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
--   FRAME_SERVER_CMD  server command (gates the server buffer)
--   FRAME_VITE_PORT   this worktree's vite port (title + ngrok gate/target)
--   FRAME_PORT_PREFIX project env-var prefix, interpolated in buffers.json
--   FRAME_BUFFERS     explicit buffer pick-list (empty → when-gates decide)
-- The buffers themselves come from the buffers.json registry (see below).
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
local base_title = name .. '/' .. topic
    .. (vite_port ~= '' and (' :' .. vite_port) or '')
vim.o.title = true
vim.o.titlestring = base_title

-- Status suffix: appends " - TEXT" to the base title (which never changes).
-- Global so `frame status` can call it over the socket from any terminal
-- buffer; returns the new title for the caller to echo.
_G.FrameSetStatus = function(status)
  vim.o.titlestring = base_title
      .. (status ~= '' and (' - ' .. status) or '')
  return vim.o.titlestring
end

-- :FrameStatus TEXT — set the status suffix; no TEXT clears it.
vim.api.nvim_create_user_command('FrameStatus', function(opts)
  _G.FrameSetStatus(opts.args)
end, { nargs = '*', desc = 'Set window-title status suffix (empty clears)' })

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
-- ordered registry of every buffer frame supports. Per entry: name; mode
-- (bare | durable | prefill, default durable); command — a template, ${VAR}
-- replaced from the environment at boot; optional dir to run in; env — vars
-- the command reads (a declared contract: unset ones are warned about, never
-- set here); when — gate, {"env": V} var non-empty and/or {"dir": D}
-- directory exists; focus — land here after boot.
--
-- A project extends/overrides via .frame/buffers.json (first found wins:
-- .frame/local/ → .frame/ → same chain under the primary checkout). Entries
-- merge by name; new names slot in before the focus buffer. BUFFERS=(…) in
-- config.sh — FRAME_BUFFERS here — picks an exact list instead: its order
-- wins and the when-gates are bypassed.

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

local overrides
for _, dir in ipairs({ '.frame/local', '.frame',
  main_wt .. '/.frame/local', main_wt .. '/.frame' }) do
  overrides = read_json(dir .. '/buffers.json')
  if overrides then break end
end
if overrides then
  -- Replacements first: inserting first would shift indexes under the map.
  local index = {}
  for i, b in ipairs(buffers) do index[b.name] = i end
  local fresh = {}
  for _, b in ipairs(overrides) do
    if index[b.name] then buffers[index[b.name]] = b
    else table.insert(fresh, b) end
  end
  -- New names land before the focus buffer so the session still ends there.
  local at = #buffers + 1
  for i, b in ipairs(buffers) do
    if b.focus then at = i; break end
  end
  for n, b in ipairs(fresh) do table.insert(buffers, at + n - 1, b) end
end

local picked = {}
if (vim.env.FRAME_BUFFERS or '') ~= '' then
  local index = {}
  for _, b in ipairs(buffers) do index[b.name] = b end
  for bname in vim.env.FRAME_BUFFERS:gmatch('[^%s,]+') do
    if index[bname] then table.insert(picked, index[bname])
    else
      vim.notify('frame: BUFFERS names unknown buffer "' .. bname .. '"',
        vim.log.levels.WARN)
    end
  end
else
  for _, b in ipairs(buffers) do
    local gate = b.when or {}
    if (not gate.env or (vim.env[gate.env] or '') ~= '')
        and (not gate.dir or vim.fn.isdirectory(gate.dir) == 1) then
      table.insert(picked, b)
    end
  end
end

local focus, launched, missing = nil, 0, {}
for _, b in ipairs(picked) do
  local mode = b.mode or 'durable'
  local cmd = interpolate(b.command or '')
  if mode ~= 'bare' and cmd == '' then
    -- Reachable only via an explicit BUFFERS pick of a buffer whose gate env
    -- is empty (default gating filters these out).
    vim.notify('frame: buffer "' .. b.name .. '" resolved to an empty command'
      .. ' — skipped', vim.log.levels.WARN)
  else
    if mode == 'durable' then term_durable(b.name, cmd, b.dir)
    elseif mode == 'prefill' then term_prefill(b.name, cmd)
    else term(b.name, '') end
    launched = launched + 1
    if b.focus then focus = b.name end
    for _, e in ipairs(b.env or {}) do
      local var = interpolate(e)
      if (vim.env[var] or '') == '' then
        table.insert(missing, b.name .. ' reads $' .. var)
      end
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
