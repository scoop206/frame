-- claude_screen.lua — classify claude's rendered terminal screen for FrameReady.
-- Pure Lua (no vim.*), so tests/unit/test_claude_screen.zsh can drive it with
-- any Lua runtime and feed it captured screens.
--
-- classify(lines) → 'prompt' | 'menu' | 'none'
--   'prompt'  claude's input box is up and reading: the bottom-most '❯' sits
--             directly under a ─── rule with another rule below it — the box
--             renders as  ───── / ❯ … / ─────  (a multi-line draft adds lines
--             between the ❯ and the bottom rule, never above it).
--   'menu'    a '❯' is on screen but it is a selection cursor, not the input:
--             startup menus (folder trust, "allow external CLAUDE.md imports?",
--             new-version notices) and permission dialogs all use '❯' as the
--             cursor. Anything typed + Enter there ANSWERS the menu, so a
--             brokered request sent now would be lost.
--   'none'    no '❯' yet — claude is still booting.
--
-- Only the bottom-most '❯' counts: earlier ones are the transcript (user turns
-- render as '❯ text'), which says nothing about what is live now.

local M = {}

local CURSOR = '❯'

local function is_rule(s)
  return s ~= nil and s:find('────', 1, true) ~= nil
end

function M.classify(lines)
  local at
  for i = #lines, 1, -1 do
    if lines[i]:find(CURSOR, 1, true) then at = i; break end
  end
  if not at then return 'none' end

  -- The real input box: rule directly above, a rule somewhere below (after
  -- the draft's continuation lines). A menu never qualifies: its title and
  -- prompt text sit between any rule and its options, so the line above its
  -- '❯' is text or another option ('  1. Yes' over '❯ 2. No'). Numbered-option
  -- shape is deliberately NOT the test — a human's draft '❯ 1. fix it' in the
  -- real box looks exactly like a menu option.
  if is_rule(lines[at - 1]) then
    for j = at + 1, #lines do
      if is_rule(lines[j]) then return 'prompt' end
    end
  end
  return 'menu'
end

return M
