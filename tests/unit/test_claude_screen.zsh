#!/usr/bin/env zsh
# layouts/claude_screen.lua — the screen classifier behind FrameReady. It must
# tell claude's real input prompt (─── rule, '❯ …', ─── rule) from a startup
# menu or dialog that uses '❯' as its selection cursor: a `frame spawn --req`
# or brokered `frame req` typed into a menu answers the menu and is lost.
# The module is pure Lua, so any Lua runtime drives it: lua, luajit, or a real
# nvim's `-l` (the tests/stubs nvim on PATH is skipped).
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_LUA=()
for _c in lua luajit; do
  whence -p $_c >/dev/null && { _LUA=($(whence -p $_c)); break }
done
if (( ! $#_LUA )); then
  for _n in $(whence -pa nvim); do
    [[ $_n == $FRAME_CHECKOUT/tests/stubs/* ]] && continue
    _LUA=($_n -l); break
  done
fi

# _classify — stdin is a rendered screen; prints prompt | menu | none.
_classify() {
  local screen=$SANDBOX/screen.txt
  cat > $screen
  "${_LUA[@]}" =(print -r -- '
    local m = dofile(arg[1])
    local lines = {}
    for l in io.lines(arg[2]) do lines[#lines + 1] = l end
    io.write(m.classify(lines))') "$FRAME_CHECKOUT/layouts/claude_screen.lua" $screen
}

_need_lua() { (( $#_LUA )) || { skip "no Lua runtime (lua, luajit or nvim)"; return 1 } }

R='────────────────────────────────────────────────────────────'

test_real_prompt_is_ready() {
  _need_lua || return 0
  assert_eq "$(_classify <<EOF
 ✻ Welcome to Claude Code!

$R
❯
$R
  ? for shortcuts
EOF
)" prompt
}

test_prompt_below_transcript_turns_is_ready() {
  # Earlier user turns render as '❯ text' in the transcript; only the bottom
  # '❯' — the live input box — decides.
  _need_lua || return 0
  assert_eq "$(_classify <<EOF
❯ 1. first thing
  2. second thing

⏺ Done.

$R
❯
$R
EOF
)" prompt
}

test_multiline_draft_is_ready() {
  # A human's half-typed draft, even one that looks like a numbered list,
  # is still the input box.
  _need_lua || return 0
  assert_eq "$(_classify <<EOF
$R
❯ 1. fix the thing
  2. then the other
$R
EOF
)" prompt
}

test_external_import_menu_is_not_ready() {
  _need_lua || return 0
  assert_eq "$(_classify <<EOF
$R
 Allow external CLAUDE.md file imports?

 This project's CLAUDE.md imports files outside the current working directory.

 ❯ 1. Yes, allow external imports
   2. No, disable external imports

 Enter to confirm · Esc to cancel
EOF
)" menu
}

test_menu_with_second_option_selected_is_not_ready() {
  _need_lua || return 0
  assert_eq "$(_classify <<EOF
$R
 Do you trust the files in this folder?

   1. Yes, proceed
 ❯ 2. No, exit
$R
EOF
)" menu
}

test_menu_under_old_transcript_prompt_is_not_ready() {
  # A dialog drawn below an earlier input box: the bottom '❯' is the menu's.
  _need_lua || return 0
  assert_eq "$(_classify <<EOF
$R
❯ do the thing
$R

 Do you want to proceed?
 ❯ 1. Yes
   2. No
EOF
)" menu
}

test_boxed_menu_is_not_ready() {
  _need_lua || return 0
  assert_eq "$(_classify <<EOF
╭──────────────────────────────────╮
│ Do you trust this folder?        │
│ ❯ 1. Yes, proceed                │
│   2. No, exit                    │
╰──────────────────────────────────╯
EOF
)" menu
}

test_unbracketed_cursor_is_not_ready() {
  # A '❯' with no input-box rules around it is some other selection list.
  _need_lua || return 0
  assert_eq "$(_classify <<EOF
 Select a theme
 ❯ Dark mode
   Light mode
EOF
)" menu
}

test_booting_screen_is_none() {
  _need_lua || return 0
  assert_eq "$(_classify <<EOF
 ✻ Welcome to Claude Code!

EOF
)" none
}

run_tests "$0"
