#!/usr/bin/env zsh
# The Lua behind `frame req status` (layouts/session.lua), run in a REAL headless
# nvim: the sender's outbox (FrameOutboxAdd/Query, cleared by draining the reply)
# and the target's per-request FrameBrokerState through queued → inflight →
# blocked → done. The claude buffer is a `cat` standing in for claude, so the
# broker has a channel to type into. Skipped when no real nvim is installed.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_real_nvim() {
  local d
  for d in ${(s.:.)PATH}; do
    [[ "$d" == "$TESTS_DIR/stubs" ]] && continue
    [[ -x "$d/nvim" ]] && { print -r -- "$d/nvim"; return 0; }
  done
  return 1
}

# lua_run SCRIPT — source session.lua (claude buffer = cat), run SCRIPT, print
# what it p()'s. FRAME_ROOT points at a private buffers.json.
lua_run() {
  local nv; nv=$(_real_nvim) || return 1
  mkdir -p "$SANDBOX/root/bin"
  print -r -- '[{ "name": "claude", "mode": "durable", "command": "cat" }]' > "$SANDBOX/root/buffers.json"
  { print -r -- 'local function p(...) io.stdout:write(table.concat({...}, " ") .. "\n") end'
    print -r -- "$1"
    print -r -- 'vim.cmd("qa!")'; } > "$SANDBOX/t.lua"
  FRAME_NAME=tgt FRAME_TOPIC=t FRAME_BUFFERS=claude FRAME_ROOT="$SANDBOX/root" \
    "$nv" --headless -u NONE -c "source $FRAME_CHECKOUT/layouts/session.lua" \
    -c "luafile $SANDBOX/t.lua" 2>/dev/null
}

test_outbox_add_query_and_clear_on_drain() {
  _real_nvim >/dev/null || { skip "no real nvim"; return 0; }
  local out; out=$(lua_run '
_G.FrameOutboxAdd("x/a#r1", "first")
_G.FrameOutboxAdd("x/b#r2", "second")
p("A", (_G.FrameOutboxQuery(""):gsub("\t", "|")))
_G.FrameInboxAdd("x/a", "answer", "r1")
p("B", (_G.FrameOutboxQuery("x/a#r1"):gsub("\t", "|")))
_G.FrameInboxDrainFor("x/a#r1")
p("C", (_G.FrameOutboxQuery(""):gsub("\t", "|")))
_G.FrameInboxAdd("x/b", "answer", "r2")
_G.FrameInboxDrain()
p("D[" .. _G.FrameOutboxQuery("") .. "]")
p("E", (_G.FrameOutboxQuery("y/z#r9"):gsub("\t", "|")))')
  assert_contains "$out" "A x/a#r1|0|0|first"
  assert_contains "$out" "x/b#r2|0|0|second"
  assert_contains "$out" "B x/a#r1|0|1|first"        # reply arrived, not drained
  assert_contains "$out" "C x/b#r2|0|0|second"       # x/a cleared by DrainFor
  assert_not_contains "$out" "C x/a"
  assert_contains "$out" "D[]"                        # cleared by plain drain
  assert_contains "$out" "E y/z#r9||0|"               # untracked token
}

test_broker_state_through_a_request_life() {
  _real_nvim >/dev/null || { skip "no real nvim"; return 0; }
  local out; out=$(lua_run '
local a = _G.FrameBrokerSubmit("one", "remote:me/hub")
local b = _G.FrameBrokerSubmit("two", "remote:me/hub")
p("ids", a, b)
p("q1", _G.FrameBrokerState(a, "me/hub"))
_G.FrameBrokerOnTurnEnd("")          -- a turn ends → pump submits r1
p("s1", _G.FrameBrokerState(a, "me/hub"))
p("s2", _G.FrameBrokerState(b, "me/hub"))
p("other", _G.FrameBrokerState(a, "someone/else"))
_G.FrameSetStatus("blocked")
p("blk", _G.FrameBrokerState(a, "me/hub"))
_G.FrameBrokerOnTurnEnd("")          -- r1 finishes with no text
p("e1", _G.FrameBrokerState(a, "me/hub"))
p("none", _G.FrameBrokerState("r99", "me/hub"))')
  assert_contains "$out" "ids r1 r2"
  assert_contains "$out" $'q1 queued\t1'
  assert_contains "$out" $'s1 inflight\t0\t'
  assert_contains "$out" $'s2 queued\t1'
  assert_contains "$out" "other gone"                 # id reuse guard
  assert_contains "$out" $'blk inflight\t0\tblocked'
  assert_contains "$out" $'e1 done\tempty'
  assert_contains "$out" "none gone"
}

run_tests "$0"
