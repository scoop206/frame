#!/usr/bin/env zsh
# White-box tests for frame_session_search / frame_session_cwd — the engine
# behind `frame shell TOPIC --find WORDS`. Fixtures are hand-built transcripts
# in the sandbox HOME's ~/.claude/projects, shaped like Claude Code's jsonl.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"
export FRAME_ROOT="$FRAME_CHECKOUT"
source "$FRAME_ROOT/lib/helpers.sh"

_t() {  # _t SESSION_ID CWD — echo a fresh transcript's path
  local sid=$1 cwd=$2
  local pdir="$HOME/.claude/projects/${cwd//[^A-Za-z0-9]/-}"
  mkdir -p "$pdir"
  : > "$pdir/$sid.jsonl"
  print -r -- "$pdir/$sid.jsonl"
}
_typed() {  # _typed FILE CWD TEXT [extra jq fields] — a message the user typed
  jq -nc --arg c "$2" --arg t "$3" "{type:\"user\", cwd:\$c, timestamp:\"2026-11-03T10:00:00Z\", entrypoint:\"cli\", message:{role:\"user\", content:\$t}} ${4:+| . + $4}" >> "$1"
}
_line() { print -r -- "$2" >> "$1"; }

test_matches_only_typed_messages() {
  local f=$(_t s-typed /w/docs) g=$(_t s-noise /w/code)
  _typed "$f" /w/docs "help me with my 2023 tax return"
  # noise: tax in a tool result, in claude's reply, a hook echo, a meta line
  _line "$g" '{"type":"user","cwd":"/w/code","message":{"role":"user","content":[{"type":"tool_result","content":"tax tax"}]}}'
  _line "$g" '{"type":"assistant","cwd":"/w/code","message":{"role":"assistant","content":[{"type":"text","text":"your tax"}]}}'
  _typed "$g" /w/code "<command-name>/tax</command-name>"
  _typed "$g" /w/code "tax meta" '{isMeta:true}'
  _typed "$g" /w/code "tax summary" '{isCompactSummary:true}'
  _typed "$g" /w/code "tax headless" '{entrypoint:"sdk-cli"}'
  local out=$(frame_session_search tax)
  assert_contains "$out" "s-typed"
  assert_not_contains "$out" "s-noise"
}

test_word_start_not_substring() {
  local f=$(_t s-syn /w/a) g=$(_t s-taxes /w/b)
  _typed "$f" /w/a "fix the syntax error"
  _typed "$g" /w/b "are my Taxes filed?"
  local out=$(frame_session_search tax)
  assert_contains "$out" "s-taxes"
  assert_not_contains "$out" "s-syn"
}

test_every_word_across_the_session() {
  local f=$(_t s-both /w/a) g=$(_t s-one /w/b)
  _typed "$f" /w/a "the tax return"
  _typed "$f" /w/a "it was for 2023"
  _typed "$g" /w/b "the tax return"
  local out=$(frame_session_search 2023 tax)
  assert_contains "$out" "s-both"
  assert_not_contains "$out" "s-one"
}

test_text_blocks_with_images_count() {
  local f=$(_t s-img /w/a)
  _line "$f" '{"type":"user","cwd":"/w/a","message":{"role":"user","content":[{"type":"text","text":"is this the tax form? [Image #1]"},{"type":"image","source":{"type":"base64","data":"'"${(l:500::A:)}"'"}}]}}'
  assert_contains "$(frame_session_search tax)" "s-img"
}

test_newest_first_and_bridged_copies_deduped() {
  local old=$(_t s-old /w/a) new=$(_t s-new /w/b)
  _typed "$old" /w/a "tax one"
  _typed "$new" /w/b "tax two"
  # a bridged copy of s-old (frame_bridge_transcript) under another project
  local copy=$(_t s-old /w/c)
  _typed "$copy" /w/a "tax one"
  # stamp after writing: appending bumps the mtime the ranking reads
  touch -t 202001010000 "$old"; touch -t 202401010000 "$new"; touch -t 201901010000 "$copy"
  local -a ids=( ${(f)"$(frame_session_search tax | cut -f2)"} )
  assert_eq "${ids[*]}" "s-new s-old"
}

test_row_shape() {
  local f=$(_t s-row /w/docs)
  _typed "$f" /w/docs "my tax return"
  local -a cols=( "${(@s:	:)$(frame_session_search tax)}" )
  assert_eq "$cols[2]" "s-row"
  assert_eq "$cols[3]" "/w/docs"
  assert_eq "$cols[4]" "$f"
  assert_eq "$cols[5]" "my tax return"
}

test_no_match_returns_nonzero() {
  local f=$(_t s-x /w/a)
  _typed "$f" /w/a "hello"
  if frame_session_search zebra >/dev/null; then
    fail "expected nonzero when nothing matches"
  fi
}

test_session_cwd_is_the_latest() {
  # A session bridged into a new dir and resumed there now lives in the new dir.
  local f=$(_t s-moved /w/old)
  _typed "$f" /w/old "first"
  _typed "$f" /w/new "after the move"
  _line "$f" '{"type":"assistant","message":{"role":"assistant","content":"ok"}}'
  assert_eq "$(frame_session_cwd "$f")" "/w/new"
}

test_recent_lists_newest_with_first_message() {
  local a=$(_t r-old /w/a) b=$(_t r-new /w/b) h=$(_t r-headless /w/h) e=$(_t r-empty /w/e)
  _typed "$a" /w/a "first thing in old"
  _typed "$a" /w/a "second thing in old"
  _typed "$b" /w/b "  the new one"
  _typed "$b" /w/c "moved on"
  _typed "$h" /w/h "a headless run" '{entrypoint:"sdk-cli"}'
  _line "$e" '{"type":"assistant","message":{"role":"assistant","content":"hi"}}'
  touch -t 202001010000 "$a"; touch -t 202401010000 "$b"
  local out=$(frame_session_recent)
  local -a ids=( ${(f)"$(print -r -- "$out" | cut -f2)"} )
  assert_eq "${ids[*]}" "r-new r-old"
  local -a cols=( "${(@s:	:)${(f)out}[1]}" )
  assert_eq "$cols[3]" "/w/c"
  assert_eq "$cols[5]" "the new one"
  assert_contains "$out" "first thing in old"
  assert_not_contains "$out" "second thing"
}

test_recent_respects_limit() {
  local i f
  for i in 1 2 3; do f=$(_t r-$i /w/$i); _typed "$f" /w/$i "msg $i"; done
  assert_eq "$(frame_session_recent 2 | wc -l | tr -d ' ')" "2"
}

_repo_dirs() {  # a plain checkout and one linked worktree of it, under $HOME/r
  mkdir -p "$HOME/r/repo/.git" "$HOME/r/repo/sub" "$HOME/r/_repo-topic/sub" "$HOME/r/plain"
  print -r -- "gitdir: $HOME/r/repo/.git/worktrees/_repo-topic" > "$HOME/r/_repo-topic/.git"
}

_place_kind() { local p; p=$(frame_session_place "$1") || { print none; return; }; print -r -- "${p%%$'\t'*}"; }
_place_col() { local p; p=$(frame_session_place "$1") || return 1; print -r -- "$(print -r -- "$p" | cut -f$2)"; }

test_place_kinds() {
  _repo_dirs
  local R=${HOME:A}/r
  assert_eq "$(_place_kind "$HOME/r/repo/sub")"        "main"
  assert_eq "$(_place_kind "$HOME/r/plain")"           "plain"
  assert_eq "$(_place_kind "$HOME/r/_repo-topic/sub")" "wt"
  assert_eq "$(_place_kind "$HOME/r/_repo-done/web")"  "gone"
  assert_eq "$(_place_kind "$HOME/r/gone")"            "none"
  assert_eq "$(_place_kind "$HOME")"                   "none"
  # MAIN: the anchor every kind of a repo's dirs share
  assert_eq "$(_place_col "$HOME/r/repo/sub" 2)"        "$R/repo"
  assert_eq "$(_place_col "$HOME/r/_repo-topic/sub" 2)" "$R/repo"
  assert_eq "$(_place_col "$HOME/r/_repo-done/web" 2)"  "$R/repo"
  # RESUME: the dir itself, a live worktree's root, or the main checkout
  assert_eq "$(_place_col "$HOME/r/repo/sub" 3)"        "$R/repo/sub"
  assert_eq "$(_place_col "$HOME/r/_repo-topic/sub" 3)" "$R/_repo-topic"
  assert_eq "$(_place_col "$HOME/r/_repo-done/web" 3)"  "$R/repo"
  # LABEL
  assert_eq "$(_place_col "$HOME/r/repo/sub" 4)"        "repo/sub"
  assert_eq "$(_place_col "$HOME/r/_repo-topic/sub" 4)" "repo · wt topic"
  assert_eq "$(_place_col "$HOME/r/_repo-done/web" 4)"  "repo · wt done (gone)"
  assert_eq "$(_place_col "$HOME/r/plain" 4)"           "~/r/plain"
}

test_gone_worktree_main_longest_name_first() {
  mkdir -p "$HOME/r/common-goal-fitness/.git" "$HOME/r/common-goal/.git"
  assert_eq "$(frame_gone_worktree_main "$HOME/r/_common-goal-fitness-88")" "${HOME:A}/r/common-goal-fitness"
  frame_gone_worktree_main "$HOME/r/_nope-topic" && fail "no checkout to map to"
  return 0
}

test_repo_main() {
  _repo_dirs
  assert_eq "$(frame_repo_main "$HOME/r/_repo-topic/sub")" "${HOME:A}/r/repo"
  assert_eq "$(frame_repo_main "$HOME/r/repo")"            "${HOME:A}/r/repo"
  frame_repo_main "$HOME/r/plain" && fail "plain dir has no repo"
  return 0
}

test_resumable_filters_rows_by_last_cwd() {
  _repo_dirs
  local a=$(_t k-repo x) b=$(_t k-wt x) c=$(_t k-gone x) d=$(_t k-moved x) e=$(_t k-down x)
  _typed "$a" "$HOME/r/repo" "tax in repo"
  _typed "$b" "$HOME/r/_repo-topic" "tax in worktree"
  _typed "$c" "$HOME/r/gone" "tax in gone"
  _typed "$d" "$HOME/r/_repo-topic" "tax first"
  _typed "$d" "$HOME/r/plain" "moved out"
  _typed "$e" "$HOME/r/_repo-done" "tax in torn-down worktree"
  local out=$(frame_session_search tax | frame_session_resumable)
  assert_contains "$out" "k-repo"
  assert_contains "$out" "k-moved"
  assert_contains "$out" "k-wt"
  assert_contains "$out" "k-down"
  assert_not_contains "$out" "k-gone"
  # CWD column is where the pick resumes
  assert_eq "$(print -r -- "$out" | grep k-moved | cut -f3)" "${HOME:A}/r/plain"
  assert_eq "$(print -r -- "$out" | grep k-wt | cut -f3)"    "${HOME:A}/r/_repo-topic"
  assert_eq "$(print -r -- "$out" | grep k-down | cut -f3)"  "${HOME:A}/r/repo"
}

test_resumable_repo_scope() {
  _repo_dirs
  mkdir -p "$HOME/r/other/.git"
  local a=$(_t s-main x) b=$(_t s-wt x) c=$(_t s-down x) d=$(_t s-other x) e=$(_t s-plain x)
  _typed "$a" "$HOME/r/repo/sub" "dns main"
  _typed "$b" "$HOME/r/_repo-topic" "dns wt"
  _typed "$c" "$HOME/r/_repo-done" "dns down"
  _typed "$d" "$HOME/r/other" "dns other"
  _typed "$e" "$HOME/r/plain" "dns plain"
  local -a ids=( ${(fo)"$(frame_session_search dns | frame_session_resumable --repo "${HOME:A}/r/repo" | cut -f2)"} )
  assert_eq "${ids[*]}" "s-down s-main s-wt"
  ids=( ${(fo)"$(frame_session_recent --repo "${HOME:A}/r/repo" 10 | cut -f2)"} )
  assert_eq "${ids[*]}" "s-down s-main s-wt"
  assert_eq "$(frame_session_recent --resumable 10 | wc -l | tr -d ' ')" "5"
}

test_recent_resumable_respects_limit_and_skips_unresumable() {
  _repo_dirs
  local i f
  for i in 1 2 3; do f=$(_t g-$i x); _typed "$f" "$HOME/r/gone" "gone $i"; done
  f=$(_t p-1 x); _typed "$f" "$HOME/r/plain" "plain one"; touch -t 202001010000 "$f"
  f=$(_t p-2 x); _typed "$f" "$HOME/r/repo" "repo one";   touch -t 202001010000 "$f"
  local -a ids=( ${(f)"$(frame_session_recent --resumable 2 | cut -f2)"} )
  local -a sorted=( ${(o)ids} )
  assert_eq "${sorted[*]}" "p-1 p-2"
  assert_eq "$(frame_session_recent 10 | wc -l | tr -d ' ')" "5"
}

test_session_running_lists_live_pids_only() {
  mkdir -p "$HOME/.claude/sessions"
  sleep 60 & local live=$!
  print -r -- '{"sessionId":"s-live"}' > "$HOME/.claude/sessions/$live.json"
  print -r -- '{"sessionId":"s-dead"}' > "$HOME/.claude/sessions/999999.json"
  local out=$(frame_session_running)
  kill $live 2>/dev/null
  assert_eq "$out" "s-live"$'\t'"$live"
}

test_proc_env_reads_a_running_process() {
  # jq, not sleep: macOS hides an Apple-signed binary's env (see frame_proc_env).
  # It waits on a fifo it holds open itself (<>), so no feeder to clean up.
  mkfifo "$HOME/hold"
  env FRAME_TOPIC=cowpoke jq -R . <>"$HOME/hold" >/dev/null 2>&1 & local pid=$!
  sleep 0.2
  local got=$(frame_proc_env $pid FRAME_TOPIC)
  frame_proc_env $pid NOT_THERE_X >/dev/null && fail "unset var should return 1"
  kill $pid 2>/dev/null
  assert_eq "$got" "cowpoke"
}

test_preview_abbreviates_home_and_uses_local_time() {
  local f=$(_t s-prev "$HOME/code/app")
  _typed "$f" "$HOME/code/app" "why does the cache miss?"
  local out=$(TZ=America/Los_Angeles frame_session_preview "$f")
  assert_contains "$out" "cwd     ~/code/app"
  assert_not_contains "$out" "$HOME/code/app"
  # 2026-11-03T10:00:00Z is 02:00 in Los Angeles — the list's local time
  assert_contains "$out" "2026-11-03 02:00  why does the cache miss?"
}

run_tests "$0"
