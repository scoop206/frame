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

-- Where this session's socket + teardown log live. bin/frame exports FRAME_RUNDIR
-- and creates it before exec'ing nvim, so it's present at boot; but it can be
-- reaped by macOS's tmp_cleaner during a long idle, so every writer below
-- re-ensures it via vim.fn.mkdir(rundir, 'p') first. Kept in sync with the shell
-- default in lib/helpers.sh.
local rundir = (vim.env.FRAME_RUNDIR ~= nil and vim.env.FRAME_RUNDIR ~= '')
  and vim.env.FRAME_RUNDIR or '/tmp/frame'

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
--   buf          per-buffer buffer handles (name → bufnr), so FrameReady can
--                read claude's rendered screen
--   inbox        reports routed home here (frame deliver / remote broker replies)
--   broker       the request queue in front of claude (docs/claude-broker.md)
-- The notify mute switch is deliberately NOT a field here: it stays
-- vim.g.frame_notify_muted because `frame notify` reads it over RPC as
-- get(g:, 'frame_notify_muted', 0), so sessions predating it degrade to
-- unmuted. Keeping it a g: var preserves that cheap, backward-compatible read.
local FrameState = { status = '', chan = {}, buf = {}, inbox = {},
  broker = { seq = 0, queue = {}, inflight = nil, inflight_since = nil,
    reqs = {}, pump_scheduled = false } }

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
-- `frame ls`:   name<TAB>topic<TAB>port<TAB>status<TAB>health
-- Queried over the socket exactly like FrameSetStatus, so ls reads clean fields
-- straight from the session instead of parsing the window title (whose dashes
-- make <name>-<topic> ambiguous). port and status are '' when absent — ls
-- renders those as '-'. Sessions booted before this helper existed lack it; ls
-- falls back to parsing &titlestring for those.
--
-- `health` is the broker-state signal behind ls's COMMS column, a
-- comma-joined triple `<inflight_age>,<queue_depth>,<inbox_count>` read live
-- off FrameState.broker/inbox — never draining anything (cf. FrameDebug):
--   inflight_age  seconds the in-flight turn has been running (os.time now
--                 minus its start stamp), or '' when nothing is in flight.
--                 A large value with no matching long turn is the wedge signal.
--   queue_depth   requests waiting behind the in-flight one.
--   inbox_count   reports delivered but not yet drained by `frame inbox`.
-- APPENDED, never reordered: pre-health sessions return the 4-field record and
-- ls just renders a blank COMMS column for them (frame_live_frames tolerates a
-- missing 5th field). ls owns the display policy (thresholds, formatting); we
-- ship raw numbers so that stays in the presentation layer.
_G.FrameInfo = function()
  local b = FrameState.broker
  local age = b.inflight_since and (os.time() - b.inflight_since) or ''
  local health = table.concat({ age, #b.queue, #FrameState.inbox }, ',')
  return table.concat({ name, topic, vite_port, FrameState.status, health }, '\t')
end

-- _G.FrameDebug() — the full attribute dump behind `frame view`: one
-- `key<TAB>value` record per line (value is the rest of the line, so it may hold
-- spaces). Read straight from the running session — its own env, FrameState, and
-- the live FrameReady/broker/inbox reads — so `frame view` never guesses or
-- re-parses the title. Strictly non-destructive: the inbox is counted and its
-- senders listed, never drained (unlike FrameInboxDrain). A superset of
-- FrameInfo; sessions booted before this helper lack it, so `frame view` falls
-- back to the FrameInfo fields for them. Keep the keys in step with view.sh.
_G.FrameDebug = function()
  local prefix = vim.env.PORT_PREFIX or ''
  -- env(k): a session env var, or '' when unset/empty (view.sh renders '-').
  local function env(k) local v = vim.env[k]; return (v ~= nil and v ~= '') and v or '' end
  -- inbox peek: count + senders, mapping an empty sender to '-'. Never drains.
  local froms = {}
  for _, m in ipairs(FrameState.inbox) do
    froms[#froms + 1] = (m.from ~= nil and m.from ~= '') and m.from or '-'
  end
  -- buffers: the names we opened (FrameState.buf keys), in a stable order.
  local bufs = {}
  for n in pairs(FrameState.buf) do bufs[#bufs + 1] = n end
  table.sort(bufs)
  local b = FrameState.broker
  local lines = {
    'name\t' .. name,
    'topic\t' .. topic,
    'cwd\t' .. vim.fn.getcwd(),
    'main_wt\t' .. env('FRAME_MAIN_WT'),
    'status\t' .. FrameState.status,
    'ready\t' .. _G.FrameReady(),
    'notify\t' .. (vim.g.frame_notify_muted == 1 and 'muted' or 'on'),
    'ephemeral\t' .. (env('FRAME_EPHEMERAL') == '1' and 'yes' or 'no'),
    'prefix\t' .. prefix,
    'api_port\t' .. env('PORT'),
    'vite_port\t' .. vite_port,
    'hmr_port\t' .. (prefix ~= '' and env(prefix .. '_HMR_PORT') or ''),
    'server\t' .. env('SERVER_CMD'),
    'buffers\t' .. table.concat(bufs, ','),
    'broker_inflight\t' .. (b.inflight or ''),
    'broker_queue\t' .. table.concat(b.queue, ','),
    'inbox_count\t' .. #FrameState.inbox,
    'inbox_from\t' .. table.concat(froms, ','),
  }
  return table.concat(lines, '\n')
end

-- _G.FrameReady() — 1 once this session can accept a `frame req`: the claude
-- buffer's terminal channel is captured (the last step of boot, bottom of this
-- file) AND claude's TUI has rendered its input prompt ('❯' on screen). The
-- channel alone fires seconds too early — claude the process is still booting,
-- so anything sent meanwhile piles up unread in the pty and arrives as ONE
-- chunk when its TUI first reads stdin; paste-detection then eats the
-- submitting CR (see frame_submit). A rendered prompt means claude is actively
-- reading, so a deferred Enter lands as its own keypress. First-run chrome
-- (trust dialog etc.) never renders '❯' — spawn times out and points at the
-- window, which genuinely needs a human. `frame spawn` polls this after
-- opening a worker's window; the socket alone is not readiness either
-- (serverstart runs before the buffers open).
_G.FrameReady = function()
  local chan, buf = FrameState.chan['claude'], FrameState.buf['claude']
  if not chan or not buf then return 0 end
  for _, s in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if s:find('❯', 1, true) then return 1 end
  end
  return 0
end

-- frame_submit(chan, text) — type TEXT into a claude terminal channel and
-- submit it. Two writes with the Enter deferred ~200ms: claude's TUI
-- paste-detection folds a CR arriving in the same rapid chunk into a newline
-- instead of a submit; a lone late '\r' registers as a real keypress. Used by
-- the broker's pump — the sole writer into claude.
local function frame_submit(chan, text)
  vim.fn.chansend(chan, text)
  vim.defer_fn(function() vim.fn.chansend(chan, '\r') end, 200)
end

-- ── the claude broker ────────────────────────────────────────────────────────
-- A queue with a single worker in front of the one serial claude, so many
-- clients (local `frame claude`, cross-frame `frame req`, future consumers) can
-- ask concurrently and each get THEIR answer. Only the broker writes into
-- claude; clients submit requests and it feeds them one at a time. Because
-- exactly one request is in flight, each Stop is unambiguously that request's
-- answer — bound to its turn by being the sole in-flight job, to its client by
-- its id. See docs/claude-broker.md.
--
-- A request: { id, text, ret, status, answer }. ret says where the answer goes:
--   { kind = 'local' }           awaited over this socket by id (frame claude)
--   { kind = 'inbox' }           dropped into THIS frame's inbox (detach/timeout)
--   { kind = 'remote', addr=… }  delivered to a sender's inbox (frame req)
--   { kind = 'drop' }            discarded (a hard cancel)

-- route(req, text) — hand a finished turn's answer to req's return mailbox and
-- return the deliver job handle (remote only; nil otherwise, so the ephemeral
-- reaper can jobwait it). A 'local' request keeps its answer for the client to
-- collect via Await; every other kind is terminal here, so the request is
-- removed. An empty answer (a tool-only final turn) skips inbox/remote delivery
-- — nothing to report — but still completes the request, keeping the queue
-- aligned.
local function route(req, text)
  local k = req.ret.kind
  if k == 'local' then
    req.answer = text
    req.status = 'done'
    return nil
  end
  if k == 'callback' then
    -- In-process push tier (a vim buffer, via FrameBrokerSubmitCb): hand the
    -- answer straight to a live Lua fn. pcall so a buggy buffer-write can never
    -- wedge the pump / Stop hook. Fires even on '' (tool-only final turn) — the
    -- callback tolerates empty. Terminal: nothing to collect, drop the request.
    if type(req.ret.fn) == 'function' then pcall(req.ret.fn, text) end
    FrameState.broker.reqs[req.id] = nil
    return nil
  end
  local job = nil
  if text ~= '' then
    if k == 'inbox' then
      table.insert(FrameState.inbox, { from = '', text = text })
    elseif k == 'remote' then
      local from = name .. '/' .. topic
      local frame_bin = (vim.env.FRAME_ROOT or '') .. '/bin/frame'
      job = vim.fn.jobstart({ frame_bin, 'deliver', req.ret.addr, '--from', from, '--id', req.id, text })
    end
  end -- 'drop': nothing
  FrameState.broker.reqs[req.id] = nil
  return job
end

-- pump(from_stop) — submit the next queued request if the worker is free. Never
-- submits while one is in flight. from_stop=true means a turn just ended, so
-- claude is idle by construction — submit straight away. from_stop=false is a
-- cold nudge from Submit: only submit if claude's prompt is up (else re-arm a
-- deferred pump while it boots) and no turn is already running (a human's — its
-- Stop will re-pump). See the accepted assumption in docs/claude-broker.md.
local function pump(from_stop)
  local b = FrameState.broker
  if b.inflight then return end
  if #b.queue == 0 then return end
  if not from_stop then
    if _G.FrameReady() ~= 1 then
      if not b.pump_scheduled then
        b.pump_scheduled = true
        vim.defer_fn(function()
          FrameState.broker.pump_scheduled = false
          pump(false)
        end, 500)
      end
      return
    end
    if FrameState.status == 'working' then return end
  end
  local id = table.remove(b.queue, 1)
  local req = b.reqs[id]
  if not req then return pump(from_stop) end -- cancelled while queued; try the next
  req.status = 'inflight'
  b.inflight = id
  b.inflight_since = os.time()   -- stamp turn start, for `frame ls`'s wedge age
  frame_submit(FrameState.chan['claude'], req.text)
  -- Mark this turn as brokered so the Stop hook's `frame notify` skips its
  -- desktop banner — the client already has the answer, so a "come look" ping
  -- is noise. Set at submit (not at Stop): the Stop hook runs `frame notify`
  -- (which reads+clears this) before `frame reply` (which pumps the next
  -- request and re-sets it), so each brokered turn's flag is consumed by its
  -- own notify. FrameTakeBrokeredFlag below.
  vim.g.frame_brokered_pending = 1
end

-- broker_enqueue(text, ret) — the shared guard+mint+enqueue+pump behind both
-- submit entry points. Returns the new id, or nil + a reason
-- ('no-claude-buffer' | 'queue-full') when the request can't be accepted. Busy
-- is NOT a refusal — a request submitted while claude works just waits its turn.
local function broker_enqueue(text, ret)
  local b = FrameState.broker
  if not FrameState.chan['claude'] then return nil, 'no-claude-buffer' end
  if #b.queue >= 32 then return nil, 'queue-full' end
  b.seq = b.seq + 1
  local id = 'r' .. b.seq
  b.reqs[id] = { id = id, text = text, ret = ret, status = 'queued', answer = nil }
  table.insert(b.queue, id)
  pump(false)
  return id
end

-- _G.FrameBrokerSubmit(text, ret_str) — enqueue a prompt over the socket;
-- returns its id, or 'no-claude-buffer' / 'queue-full'. ret_str is 'local' |
-- 'inbox' | 'remote:name/topic'.
_G.FrameBrokerSubmit = function(text, ret_str)
  local ret
  if ret_str == 'inbox' then ret = { kind = 'inbox' }
  elseif type(ret_str) == 'string' and ret_str:sub(1, 7) == 'remote:' then
    ret = { kind = 'remote', addr = ret_str:sub(8) }
  else ret = { kind = 'local' } end
  local id, reason = broker_enqueue(text, ret)
  return id or reason
end

-- _G.FrameBrokerSubmitCb(text, fn) — IN-PROCESS ONLY submit: enqueue a request
-- whose answer is delivered by calling fn(answer) when its turn ends (a push
-- mailbox — no id juggling, no socket, no polling). Returns the id, or nil if
-- fn isn't a function / there's no claude buffer / the queue is full. NOT
-- reachable over the socket (fn is a live Lua value) — for plugin code running
-- in this same nvim (e.g. :FrameClaude). answer may be '' (tool-only turn).
_G.FrameBrokerSubmitCb = function(text, fn)
  if type(fn) ~= 'function' then return nil end
  return (broker_enqueue(text, { kind = 'callback', fn = fn }))
end

-- _G.FrameBrokerAwait(id) — client poll. 'pending' while queued/in-flight,
-- 'gone' for an unknown/evicted id, or 'done\n<answer>' once finished (which
-- also collects the request so its mailbox doesn't leak). The answer may be
-- empty (a tool-only final turn) or contain newlines.
_G.FrameBrokerAwait = function(id)
  local req = FrameState.broker.reqs[id]
  if not req then return 'gone' end
  if req.status == 'done' then
    local ans = req.answer or ''
    FrameState.broker.reqs[id] = nil
    return 'done\n' .. ans
  end
  return 'pending'
end

-- _G.FrameBrokerCancel(id, mode) — abandon a request. Queued → drop it from the
-- line. In-flight → can't unsend, so redirect where its answer lands when the
-- turn ends: mode 'inbox' (detach — the answer waits in `frame inbox`) or 'drop'
-- (discard). Done → discard the uncollected answer.
_G.FrameBrokerCancel = function(id, mode)
  local b = FrameState.broker
  local req = b.reqs[id]
  if not req then return 'ok' end
  if req.status == 'queued' then
    for i, q in ipairs(b.queue) do
      if q == id then table.remove(b.queue, i) break end
    end
    b.reqs[id] = nil
  elseif req.status == 'inflight' then
    req.ret = (mode == 'inbox') and { kind = 'inbox' } or { kind = 'drop' }
  else
    b.reqs[id] = nil
  end
  return 'ok'
end

-- _G.FrameBrokerStatus() — one line per request, 'id<TAB>state', in-flight
-- first: visibility for `frame claude status` and future clients.
_G.FrameBrokerStatus = function()
  local b = FrameState.broker
  local out = {}
  if b.inflight then table.insert(out, b.inflight .. '\tinflight') end
  for i, id in ipairs(b.queue) do
    table.insert(out, id .. '\tqueued#' .. i)
  end
  return table.concat(out, '\n')
end

-- _G.FrameBrokerOnTurnEnd(text) — the pump, driven by the Stop hook: route the
-- in-flight request's answer home, clear the slot, feed claude the next queued
-- request. Advances on EVERY Stop (even empty text) to keep turn↔request binding
-- aligned. No in-flight request → a turn nobody brokered just ended; still pump,
-- in case a request queued while it ran.
_G.FrameBrokerOnTurnEnd = function(text)
  local b = FrameState.broker
  local id = b.inflight
  if id then
    b.inflight = nil
    b.inflight_since = nil
    local req = b.reqs[id]
    if req then
      local remote = req.ret.kind == 'remote'
      local job = route(req, text or '')
      -- An ephemeral worker (frame spawn --ephemeral) exists to report home
      -- once; having done so, it self-reaps via :FrameDown! (its dir + window
      -- die with it). Deferred so this RPC returns to the Stop hook first;
      -- jobwait lets the deliver finish before teardown. Shell frames only — on
      -- a worktree FrameDown! force-deletes a branch, which no env should reach.
      if remote and vim.env.FRAME_EPHEMERAL == '1' and (vim.env.FRAME_MAIN_WT or '') == '' then
        vim.defer_fn(function()
          if job then vim.fn.jobwait({ job }, 10000) end
          vim.cmd('FrameDown!')
        end, 0)
      end
    end
  end
  pump(true)
  return 0
end

-- _G.FrameTakeBrokeredFlag() — read-and-clear "the turn that just ended was one
-- the broker submitted". `frame notify` (the Stop hook) reads this to skip the
-- banner for brokered turns. Consumed on read so it can't go stale and mute a
-- later human-typed turn. A g: var like frame_notify_muted, so sessions
-- predating it just read 0 (banner fires, as before). Set by pump().
_G.FrameTakeBrokeredFlag = function()
  local v = vim.g.frame_brokered_pending or 0
  vim.g.frame_brokered_pending = 0
  return v
end

-- last_assistant_text(path) — pull the last assistant message out of a Claude
-- Code JSONL transcript: scan from the end for the last `assistant` event and
-- return its concatenated text blocks. '' when that event was tool-only (no
-- prose) or the file is unreadable — the caller treats '' as "nothing to report".
local function last_assistant_text(path)
  if vim.fn.filereadable(path) ~= 1 then return '' end
  local lines = vim.fn.readfile(path)
  for i = #lines, 1, -1 do
    if lines[i] ~= '' then
      local ok, ev = pcall(vim.json.decode, lines[i])
      if ok and type(ev) == 'table' then
        local msg = ev.message
        local is_assistant = ev.type == 'assistant'
          or (type(msg) == 'table' and msg.role == 'assistant')
        if is_assistant then
          local content = type(msg) == 'table' and msg.content or nil
          if type(content) == 'string' then return content end
          if type(content) == 'table' then
            local parts = {}
            for _, b in ipairs(content) do
              if type(b) == 'table' and b.type == 'text' and type(b.text) == 'string' then
                table.insert(parts, b.text)
              end
            end
            return table.concat(parts, '\n')
          end
          return ''
        end
      end
    end
  end
  return ''
end

-- _G.FrameOnStop(text) — the Stop-hook entry point: every turn-end flows here
-- (via FrameReplyFromHook) into the broker, which routes the in-flight request's
-- answer home and feeds claude the next queued one. The stable name the hook
-- targets; the broker is the sole router now. See docs/claude-broker.md.
_G.FrameOnStop = function(text)
  return _G.FrameBrokerOnTurnEnd(text)
end

-- _G.FrameReplyFromTranscript(path) — pull the last assistant message out of a
-- transcript and route it. _G.FrameReplyFromHook(payload_path) — the Stop-hook
-- path: `frame reply` stashes Claude Code's hook JSON to a temp file and passes
-- its path here, so all JSON parsing stays in Lua (vim.json), which frame
-- already trusts. Both return whatever the router returned.
_G.FrameReplyFromTranscript = function(path)
  return _G.FrameOnStop(last_assistant_text(path))
end
_G.FrameReplyFromHook = function(payload_path)
  if vim.fn.filereadable(payload_path) ~= 1 then return 0 end
  local ok, payload = pcall(vim.json.decode,
    table.concat(vim.fn.readfile(payload_path), '\n'))
  if not ok or type(payload) ~= 'table' then return 0 end
  -- Prefer the answer the hook hands us directly: Claude Code's Stop payload
  -- carries `last_assistant_message` (the flattened text) synchronously — no
  -- file, no parse, and crucially no flush race. The transcript on disk often
  -- lags the Stop hook (the final assistant line isn't written yet), so parsing
  -- transcript_path here would read a stale/empty tail. Keep it only as a
  -- backstop for payloads that lack the field.
  local msg = payload.last_assistant_message
  if type(msg) == 'string' and msg ~= '' then
    return _G.FrameOnStop(msg)
  end
  if type(payload.transcript_path) == 'string' then
    return _G.FrameReplyFromTranscript(payload.transcript_path)
  end
  return 0
end

-- _G.FrameInboxAdd(from, text, id) — `frame deliver` calls this over the socket
-- to append a report to this frame's inbox; returns the new inbox length. `id`
-- is the answering request's broker id (present on brokered `frame req` replies,
-- '' for plain notes); with `from` it forms the `from#id` correlation token that
-- FrameInboxDrainFor matches on.
-- _G.FrameInboxDrain() — `frame inbox` reads AND clears the inbox, returning it
-- as human-readable text ('' when empty).
_G.FrameInboxAdd = function(from, text, id)
  table.insert(FrameState.inbox, { from = from or '', text = text or '', id = id or '' })
  return #FrameState.inbox
end
_G.FrameInboxDrain = function()
  local box = FrameState.inbox
  if #box == 0 then return '' end
  local out = {}
  for _, m in ipairs(box) do
    table.insert(out, (m.from ~= '' and ('from ' .. m.from .. ':\n') or '') .. m.text)
  end
  FrameState.inbox = {}
  return table.concat(out, '\n\n──\n\n')
end

-- _G.FrameInboxDrainAtLeast(n) — drain only when the inbox holds at least `n`
-- messages; otherwise leave it untouched and return ''. `frame inbox --wait`
-- polls this over the socket, so the blocking lives in the CLI subprocess and
-- this session's event loop never waits. Draining is all-or-nothing — a peek
-- that consumed would lose messages if the client died between polls. n<=1
-- means "any mail at all"; --count K holds out for K (a fan-in barrier).
_G.FrameInboxDrainAtLeast = function(n)
  if #FrameState.inbox < (tonumber(n) or 1) then return '' end
  return _G.FrameInboxDrain()
end

-- _G.FrameInboxDrainFor(tokens) — token-keyed sibling of DrainAtLeast for the
-- fan-out fan-in barrier. `tokens` is a TAB-separated set of `from#id` strings.
-- Returns '' until EVERY requested token is present (so `frame inbox --wait --for
-- a --for b` blocks for exactly those replies); once all are present, drains ONLY
-- the matching messages (leaving unrelated notes/replies in the box) and returns
-- them as human-readable text. Split each token on the LAST '#': addresses hold
-- '/' but never '#', so the id is whatever follows it.
_G.FrameInboxDrainFor = function(tokens)
  local want = {}
  local n = 0
  for tok in tostring(tokens or ''):gmatch('[^\t]+') do
    if not want[tok] then want[tok] = true; n = n + 1 end
  end
  if n == 0 then return '' end
  -- present[] = which wanted tokens are currently in the box
  local present = {}
  for _, m in ipairs(FrameState.inbox) do
    local tok = (m.from or '') .. '#' .. (m.id or '')
    if want[tok] then present[tok] = true end
  end
  for tok in pairs(want) do
    if not present[tok] then return '' end -- not all arrived yet
  end
  -- all present: partition the box, keeping non-matching messages
  local out, keep = {}, {}
  for _, m in ipairs(FrameState.inbox) do
    local tok = (m.from or '') .. '#' .. (m.id or '')
    if want[tok] then
      table.insert(out, (m.from ~= '' and ('from ' .. m.from .. ':\n') or '') .. m.text)
    else
      table.insert(keep, m)
    end
  end
  FrameState.inbox = keep
  return table.concat(out, '\n\n──\n\n')
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

-- ── :[range]FrameClaude [question] ────────────────────────────────────────────
-- Opens THIS frame's live claude terminal in a far-right vertical split and drops
-- you into Terminal-mode at the prompt — the in-editor way to reach the same one
-- claude conversation `frame claude` talks to. Behavior is keyed on two things,
-- a RANGE (attaches context) and a QUESTION (submits):
--   :FrameClaude              — no range, no question → just open the prompt.
--   :'<,'>FrameClaude         — a range/visual selection, no question → paste the
--                               file:line + fenced source and leave it in the
--                               prompt for you to type your question and submit.
--   :FrameClaude <question>   — question → attach the current line (or the
--                               range/selection) as context and SUBMIT it.
-- So `<leader>c → :FrameClaude<cr>` opens claude; selecting code then bare
-- :FrameClaude drops that code in for you; `<leader>ca → :FrameClaude ` (normal
-- or visual) leaves you typing the question, submitted on <CR>.
-- NOTE: this is a direct write into claude, NOT a brokered turn (cf.
-- docs/claude-broker.md) — it interleaves with an in-flight turn exactly as
-- manual typing would.

-- Open the claude terminal in a vsplit (reusing its window if already visible)
-- and start Terminal-mode insert. Returns the terminal's job channel so a caller
-- can paste into the prompt, or nil (with a notified error) when this session
-- has no claude buffer.
local function frameclaude_open()
  local buf = FrameState.buf['claude']
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    vim.notify('frame: no claude buffer in this session', vim.log.levels.ERROR)
    return nil
  end
  local win
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then win = w; break end
  end
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd('botright vsplit')
    vim.api.nvim_win_set_buf(0, buf)
  end
  vim.cmd.startinsert() -- terminal buffer → enter Terminal-mode at the prompt
  return FrameState.chan['claude']
end

vim.api.nvim_create_user_command('FrameClaude', function(opts)
  local has_q = opts.args ~= ''
  local has_range = opts.range > 0 -- 0 = none, 1 = one line, 2 = a range/visual

  -- Capture context from the CURRENT (code) buffer BEFORE opening claude —
  -- frameclaude_open() switches windows, after which buffer 0 is the terminal.
  -- Context is attached whenever there's a question or an explicit range; a bare
  -- rangeless :FrameClaude leaves text nil (just open the prompt).
  local text
  if has_q or has_range then
    local l1, l2 = opts.line1, opts.line2
    local src = vim.api.nvim_buf_get_lines(0, l1 - 1, l2, false)
    local file = vim.fn.expand('%:.')
    if file == '' then file = '[No Name]' end
    local where = file .. ':' .. l1 .. (l2 > l1 and ('-' .. l2) or '')
    local parts = {}
    if has_q then parts[#parts + 1] = opts.args; parts[#parts + 1] = '' end
    parts[#parts + 1] = where
    parts[#parts + 1] = ''
    parts[#parts + 1] = '```' .. vim.bo.filetype
    parts[#parts + 1] = table.concat(src, '\n')
    parts[#parts + 1] = '```'
    text = table.concat(parts, '\n')
  end

  local chan = frameclaude_open()
  if not chan then return end
  if not text then return end -- bare, rangeless → just opened the prompt
  -- Both paths send one rapid chunk — claude's TUI paste-detection folds the
  -- embedded newlines into the input box rather than submitting each line.
  if has_q then
    -- Question → run it. frame_submit sends the paste, then a LONE '\r' ~200ms
    -- later (a CR in the same chunk would fold to a newline, not submit).
    frame_submit(chan, text)
  else
    -- Range but no question → leave the context in the prompt (trailing newline
    -- drops your cursor onto a fresh line) for you to type your question + submit.
    vim.fn.chansend(chan, text .. '\n')
  end
end, {
  range = true,
  nargs = '*',
  desc = "Open this frame's claude (bare); with a question, ask it about the line/selection",
})

-- Register a named socket so `frame wt -d TOPIC` can send :qa! remotely.
-- serverstart THROWS if the path already exists — unguarded, that would abort
-- this whole layout (no terminals, no :FrameDown). Probe a conflicting socket:
-- connectable means a live twin session owns it (leave it alone); otherwise
-- it's stale debris from a crash — reclaim it.
vim.fn.mkdir(rundir, 'p')
local sock = rundir .. '/' .. name .. '-' .. topic .. '.nvim'
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
    vim.fn.mkdir(rundir, 'p')   -- outer shell opens `>log` before frame runs; ensure the dir now
    local log = rundir .. '/' .. name .. '-' .. topic .. '.teardown.log'
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

  -- :FrameMerge[!] — merge this frame's branch into main from the primary
  -- worktree, without leaving this session. A thin passthrough to `frame merge`:
  -- every safety rail (clean primary tree, no origin divergence, conflict abort)
  -- lives there and reports itself, so we just run it and surface the result.
  -- Bang pushes main afterward (mirrors `frame merge --push`). Unlike :FrameDown
  -- the merge runs in $FRAME_MAIN_WT, not our cwd, so no reaper is needed — nvim
  -- outlives it. Pass `topic` explicitly: with cwd=main_wt a bare `frame merge`
  -- would resolve the topic from main's own branch and refuse.
  vim.api.nvim_create_user_command('FrameMerge', function(opts)
    local args = { frame_bin, 'merge', topic }
    if opts.bang then table.insert(args, '--push') end
    vim.notify('frame: merging ' .. topic .. ' → main…', vim.log.levels.INFO)
    vim.system(args, { cwd = main_wt, text = true }, function(res)
      vim.schedule(function()
        local out = vim.trim((res.stdout or '') .. (res.stderr or ''))
        vim.notify(out, res.code == 0 and vim.log.levels.INFO
                                       or vim.log.levels.WARN)
      end)
    end)
  end, { bang = true, desc = 'Merge this frame into main (! also pushes)' })
else
  -- Shell frame (frame shell): no worktree or branch — teardown means
  -- deleting the topic directory itself. Scratch dirs are disposable by
  -- design, so plain :FrameDown just does it; there are no git safeguards
  -- for a bang to override (it's accepted as a no-op for muscle-memory
  -- parity with worktree frames). :FrameQuit keeps the dir.
  -- Same reaper shape as above — nvim can't rm its own cwd out from under
  -- its terminal buffers, so a detached job waits for the socket to unlink
  -- (nvim removes it on exit) and only then deletes; if nvim somehow
  -- survives, the timeout leaves the directory alone.
  local shell_dir = vim.fn.getcwd()
  vim.api.nvim_create_user_command('FrameDown', function()
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
    desc = 'Tear down this casual frame (delete its directory — no git net)' })
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
  -- job channel so FrameAgentSend can type into it later, and its buffer so
  -- FrameReady can read the rendered screen (see FrameState above).
  FrameState.chan[b.name] = vim.b.terminal_job_id
  FrameState.buf[b.name] = vim.api.nvim_get_current_buf()
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

-- Committed-hook drift: commands/wt.sh sniffs .claude/settings.json against
-- frame's canonical hook set and hands us the comma-joined list of missing
-- hooks (empty when in sync). Surfaced here rather than in the boot shell so it
-- survives the exec into nvim — a scrolled-away warning is exactly how the
-- missing-notification bite goes unnoticed. Warn only; wt.sh never rewrites a
-- tracked settings.json.
local hook_drift = vim.env.FRAME_HOOK_DRIFT or ''
if hook_drift ~= '' then
  vim.notify('frame: .claude/settings.json is missing frame hooks (' .. hook_drift
    .. ') — notifications may not fire here. Re-sync: frame init --force',
    vim.log.levels.WARN)
end

-- Land in the focus buffer (without one, stay in the last opened), in
-- terminal-insert mode, ready to type.
if focus then vim.cmd.buffer(focus) end
if launched > 0 then vim.cmd.startinsert() end
