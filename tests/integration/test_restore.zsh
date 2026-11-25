#!/usr/bin/env zsh
# Durable frame records, frame restore and frame stop. Records live in the
# sandbox's private $FRAME_STATEDIR; the nvim stub stands in for live sessions
# (a planted socket with a <sock>.info companion answers FrameInfo).
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

plant_live() {  # plant_live NAME TOPIC — a live frame answering FrameInfo
  local sock="$FRAME_RUNDIR/$1-$2.nvim"
  _mksock "$sock"
  printf '%s\t%s\t\twaiting\n' "$1" "$2" > "$sock.info"
}

# write_record NAME TOPIC TYPE DIR [SESSION] [STOPPED_AT]
write_record() {
  mkdir -p "$FRAME_STATEDIR"
  cat > "$FRAME_STATEDIR/$1-$2.json" <<EOF
{
  "name": "$1",
  "topic": "$2",
  "type": "$3",
  "dir": "$4",
  "main_wt": "",
  "branch": "",
  "session": "${5:-}",
  "booted_at": "1000",
  "updated_at": "1000",
  "stopped_at": "${6:-}"
}
EOF
}

field() {  # field FILE KEY — a record field, via the same reader frame uses
  ( FRAME_ROOT=$FRAME_CHECKOUT source "$FRAME_CHECKOUT/lib/helpers.sh"
    typeset -A REC; frame_record_read "$1" && print -r -- "${REC[$2]:-}" )
}

setup_project() {
  make_repo
  write_config <<'EOF'
BUFFERS=()
EOF
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
}

# ── the record's lifecycle ───────────────────────────────────────────────────

test_wt_boot_writes_record() {
  setup_project
  run_frame wt topic
  assert_status 0
  local rec="$FRAME_STATEDIR/$TNAME-topic.json"
  assert_file_exists "$rec"
  assert_eq "$(field $rec name)" "$TNAME"
  assert_eq "$(field $rec topic)" topic
  assert_eq "$(field $rec type)" wt
  assert_eq "$(field $rec dir)" "$SANDBOX/_$TNAME-topic"
  assert_eq "$(field $rec main_wt)" "$REPO"
  assert_eq "$(field $rec branch)" topic
  assert_eq "$(field $rec session)" ""
  assert_eq "$(field $rec stopped_at)" ""
}

test_wt_resume_boot_records_the_session() {
  setup_project
  run_frame wt topic --resume sid-abc-123
  assert_status 0
  assert_eq "$(field $FRAME_STATEDIR/$TNAME-topic.json session)" sid-abc-123
}

test_shell_boot_writes_record() {
  export FAKE_NVIM_LOG="$SANDBOX/nvim.log"
  mkdir -p "$SANDBOX/w/scratch" && cd "$SANDBOX/w/scratch"
  run_frame shell jam
  assert_status 0
  local rec="$FRAME_STATEDIR/shell-jam.json"
  assert_eq "$(field $rec type)" shell
  assert_eq "$(field $rec dir)" "$SANDBOX/w/scratch"
  assert_eq "$(field $rec main_wt)" ""
}

test_wt_teardown_drops_record() {
  setup_project
  run_frame wt topic
  unset FAKE_NVIM_LOG
  cd "$REPO"
  print -r -- sid-old > "$FRAME_RUNDIR/$TNAME-topic.session"   # legacy pointer
  run_frame wt -d topic
  assert_status 0
  assert_file_absent "$FRAME_STATEDIR/$TNAME-topic.json"
  assert_file_absent "$FRAME_RUNDIR/$TNAME-topic.session"
}

test_shell_teardown_drops_record_even_when_down() {
  write_record shell jam shell "$SANDBOX"
  run_frame shell -d jam
  assert_status 0
  assert_file_absent "$FRAME_STATEDIR/shell-jam.json"
}

test_record_survives_odd_characters() {
  # Quotes, backslashes and spaces round-trip through the writer and reader.
  ( FRAME_ROOT=$FRAME_CHECKOUT source "$FRAME_CHECKOUT/lib/helpers.sh"
    frame_record_write "$FRAME_STATEDIR/x-y.json" name x topic y dir 'a "b" \n c\\d' )
  assert_eq "$(field $FRAME_STATEDIR/x-y.json dir)" 'a "b" \n c\\d'
}

test_from_prefers_the_record_session() {
  setup_project
  write_record "$TNAME" src wt "$SANDBOX/_$TNAME-src" sid-from-record
  print -r -- sid-legacy > "$FRAME_RUNDIR/$TNAME-src.session"
  run_frame wt topic --from src
  assert_status 0
  assert_contains "$OUT" "resuming session sid-from-record from frame src"
}

# ── frame restore ────────────────────────────────────────────────────────────

test_restore_nothing_to_restore() {
  run_frame restore
  assert_status 0
  assert_contains "$OUT" "nothing to restore"
}

test_restore_lists_dead_skips_live() {
  mkdir -p "$SANDBOX/a" "$SANDBOX/b"
  write_record shell dead1 shell "$SANDBOX/a" sid-1
  write_record shell stopped1 shell "$SANDBOX/b" sid-2 "$(date +%s)"
  write_record shell alive1 shell "$SANDBOX/b"
  plant_live shell alive1
  run_frame restore          # no tty: list only
  assert_status 0
  assert_contains "$OUT" dead1
  assert_contains "$OUT" died
  assert_contains "$OUT" stopped1
  assert_contains "$OUT" "s ago"
  assert_not_contains "$OUT" alive1
  assert_contains "$OUT" "frame restore TOPIC"
}

test_restore_print_wt_form_and_stamp() {
  mkdir -p "$SANDBOX/_p-topic"
  write_record p topic wt "$SANDBOX/_p-topic" sid-abc
  run_frame restore topic --print
  assert_status 0
  assert_contains "$OUT" "cd $SANDBOX/_p-topic && $FRAME_CHECKOUT/bin/frame wt --resume sid-abc"
  assert_file_exists "$FRAME_RUNDIR/p-topic.restored"
}

test_restore_print_shell_form() {
  mkdir -p "$SANDBOX/notes"
  write_record shell notes shell "$SANDBOX/notes" sid-n
  run_frame restore shell/notes --print
  assert_status 0
  assert_contains "$OUT" "$FRAME_CHECKOUT/bin/frame shell -C $SANDBOX/notes notes --resume sid-n"
}

test_restore_without_session_boots_fresh_no_stamp() {
  mkdir -p "$SANDBOX/notes"
  write_record shell notes shell "$SANDBOX/notes"
  run_frame restore notes --print
  assert_status 0
  assert_not_contains "$OUT" "--resume"
  assert_file_absent "$FRAME_RUNDIR/shell-notes.restored"
}

test_restore_all_prints_each() {
  mkdir -p "$SANDBOX/a" "$SANDBOX/b"
  write_record shell one shell "$SANDBOX/a" sid-1
  write_record shell two shell "$SANDBOX/b" sid-2
  run_frame restore --all --print
  assert_status 0
  assert_contains "$OUT" "-C $SANDBOX/a one --resume sid-1"
  assert_contains "$OUT" "-C $SANDBOX/b two --resume sid-2"
}

test_restore_gone_dir_is_reported() {
  write_record shell lost shell "$SANDBOX/nope" sid-l
  run_frame restore lost --print
  assert_status 1
  assert_contains "$OUT" "dir is gone"
  assert_contains "$OUT" "frame restore --forget shell/lost"
  assert_contains "$OUT" "frame shell --resume sid-l"
}

test_restore_unknown_and_ambiguous() {
  mkdir -p "$SANDBOX/a"
  write_record shell x shell "$SANDBOX/a"
  write_record other x shell "$SANDBOX/a"
  run_frame restore nope
  assert_status 1
  assert_contains "$OUT" "nothing to restore matches 'nope'"
  run_frame restore x --print
  assert_status 1
  assert_contains "$OUT" "names 2 restorable frames"
  run_frame restore other/x --print
  assert_status 0
}

test_restore_forget_drops_record() {
  mkdir -p "$SANDBOX/a"
  write_record shell gone shell "$SANDBOX/a"
  run_frame restore --forget gone
  assert_status 0
  assert_contains "$OUT" "forgot shell/gone"
  assert_file_absent "$FRAME_STATEDIR/shell-gone.json"
  run_frame restore --forget
  assert_status 2
}

test_restore_opens_a_tab_and_records_it() {
  frame_is_macos_here || { skip "tabs are macOS-only"; return 0; }
  mkdir -p "$SANDBOX/notes"
  write_record shell notes shell "$SANDBOX/notes" sid-n
  export FAKE_OSASCRIPT_RESULT="11 22" FAKE_OSASCRIPT_LOG="$SANDBOX/osa.log"
  run_frame restore notes
  assert_status 0
  assert_contains "$OUT" "restoring shell/notes (resuming session sid-n)"
  assert_eq "$(<$FRAME_RUNDIR/shell-notes.nvim.gtab)" "11 22"
  assert_contains "$(<$SANDBOX/osa.log)" "FRAME_SPAWNED=1"
  assert_contains "$(<$SANDBOX/osa.log)" "spawn close-tab shell/notes"
}
frame_is_macos_here() { [[ "$(uname -s)" == Darwin ]]; }

test_backfill_records_live_frames_without_one() {
  # A frame booted before records existed: its env (over RPC) says where it
  # runs, the legacy .session pointer says which conversation.
  mkdir -p "$SANDBOX/old"
  plant_live shell old
  print -r -- sid-legacy > "$FRAME_RUNDIR/shell-old.session"
  export FAKE_NVIM_EXPR_RESULT=$'\t\t'"$SANDBOX/old"
  write_record shell has shell "$SANDBOX/old" sid-h
  plant_live shell has
  run_frame restore --backfill
  assert_status 0
  assert_contains "$OUT" "recorded shell/old (session sid-legacy)"
  assert_contains "$OUT" "1 recorded, 1 already had one"
  local rec="$FRAME_STATEDIR/shell-old.json"
  assert_eq "$(field $rec type)" shell
  assert_eq "$(field $rec dir)" "$SANDBOX/old"
  assert_eq "$(field $rec session)" sid-legacy
  assert_eq "$(field $FRAME_STATEDIR/shell-has.json session)" sid-h   # untouched
}

test_restore_warns_about_unrecorded_live_frames() {
  plant_live shell norec
  run_frame restore
  assert_status 0
  assert_contains "$OUT" "1 running frame(s) have no record"
  assert_contains "$OUT" "shell/norec"
  assert_contains "$OUT" "frame restore --backfill"
}

test_backfill_wt_frame() {
  plant_live proj topic
  export FAKE_NVIM_EXPR_RESULT="$SANDBOX/proj"$'\t'"$SANDBOX/_proj-topic"$'\t'
  run_frame restore --backfill
  assert_status 0
  assert_eq "$(field $FRAME_STATEDIR/proj-topic.json type)" wt
  assert_eq "$(field $FRAME_STATEDIR/proj-topic.json dir)" "$SANDBOX/_proj-topic"
  assert_eq "$(field $FRAME_STATEDIR/proj-topic.json main_wt)" "$SANDBOX/proj"
}

# ── frame stop ───────────────────────────────────────────────────────────────

test_stop_quits_and_keeps_record() {
  mkdir -p "$SANDBOX/a"
  write_record shell jam shell "$SANDBOX/a" sid-j
  plant_live shell jam
  : > "$FRAME_RUNDIR/shell-jam.nvim.stopbufs"; print -n 2 > "$FRAME_RUNDIR/shell-jam.nvim.stopbufs"
  export FAKE_NVIM_EXPR_LOG="$SANDBOX/exprs.log"
  run_frame stop jam
  assert_status 0
  assert_contains "$OUT" "sent Ctrl-C to 2 terminal buffer(s)"
  assert_contains "$OUT" "stopped shell/jam"
  assert_file_absent "$FRAME_RUNDIR/shell-jam.nvim"
  assert_file_exists "$FRAME_STATEDIR/shell-jam.json"
  [[ "$(field $FRAME_STATEDIR/shell-jam.json stopped_at)" == <1-> ]] || fail "stopped_at not stamped"
  assert_eq "$(field $FRAME_STATEDIR/shell-jam.json session)" sid-j
  assert_contains "$(<$SANDBOX/exprs.log)" FrameBusyBuffers
}

test_stop_refuses_unsaved_buffers() {
  write_record shell jam shell "$SANDBOX"
  plant_live shell jam
  print -r -- "~/notes.md" > "$FRAME_RUNDIR/shell-jam.nvim.unsaved"
  run_frame stop jam
  assert_status 1
  assert_contains "$OUT" "unsaved changes"
  assert_contains "$OUT" "~/notes.md"
  [[ -S "$FRAME_RUNDIR/shell-jam.nvim" ]] || fail "session should still be up"
  run_frame stop -f jam
  assert_status 0
  assert_file_absent "$FRAME_RUNDIR/shell-jam.nvim"
}

test_stop_refuses_frame_without_record() {
  plant_live shell jam
  run_frame stop jam
  assert_status 1
  assert_contains "$OUT" "no durable record"
  run_frame stop -f jam
  assert_status 0
}

test_stop_all_stops_every_live_frame() {
  write_record shell one shell "$SANDBOX"
  write_record shell two shell "$SANDBOX"
  plant_live shell one
  plant_live shell two
  run_frame stop --all
  assert_status 0
  assert_contains "$OUT" "stopped shell/one"
  assert_contains "$OUT" "stopped shell/two"
}

test_stop_all_with_nothing_running() {
  run_frame stop --all
  assert_status 0
  assert_contains "$OUT" "no frames running"
}

test_stop_then_restore_round_trip() {
  mkdir -p "$SANDBOX/a"
  write_record shell jam shell "$SANDBOX/a" sid-j
  plant_live shell jam
  run_frame stop jam
  assert_status 0
  run_frame restore jam --print
  assert_status 0
  assert_contains "$OUT" "shell -C $SANDBOX/a jam --resume sid-j"
}

run_tests "$0"
