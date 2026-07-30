#!/usr/bin/env zsh
# frame ls — lists live frames by querying each /tmp/*.nvim socket for its
# identity via FrameInfo(). The nvim stub stands in for a live session: a
# socket with a <sock>.info companion answers FrameInfo(); a socket without one
# is "dead" and its query fails, exactly as a real crashed session's (or one
# predating the helper) would. Socket names carry $TNAME so sandbox_down
# sweeps them.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

# A real AF_UNIX socket file, so ls's `-S` filter sees it as a live socket.
_mksock() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"; }

plant_live() {  # plant_live SOCK NAME TOPIC PORT STATUS  — a FrameInfo session
  _mksock "$1"
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" > "$1.info"
}
plant_dead() { _mksock "$1"; }                                  # no responder
plant_hung() { _mksock "$1"; : > "$1.hang"; }                   # alive but wedged

test_lists_live_frames_in_columns() {
  plant_live "/tmp/$TNAME-alpha.nvim" "$TNAME" alpha 5173 WAITING
  plant_live "/tmp/$TNAME-beta.nvim"  "$TNAME" beta  5175 ''
  run_frame ls
  assert_status 0
  assert_contains "$OUT" "NAME"
  assert_contains "$OUT" "TOPIC"
  assert_contains "$OUT" "PORT"
  assert_contains "$OUT" "STATUS"
  assert_contains "$OUT" "alpha"
  assert_contains "$OUT" "5173"
  assert_contains "$OUT" "WAITING"
  assert_contains "$OUT" "beta"
}

test_empty_port_and_status_render_as_dash() {
  # A shell frame: no port, status cleared → both columns show "-".
  plant_live "/tmp/$TNAME-shellish.nvim" "$TNAME" shellish '' ''
  run_frame ls
  assert_status 0
  local row=$(print -r -- "$OUT" | grep shellish)
  # topic, then "-" for port, then "-" for status
  assert_contains "$row" "shellish"
  assert_contains "$row" "-"
}

test_portless_status_stays_in_status_column() {
  # A port-less frame with a status returns `name\ttopic\t\twaiting` — a run
  # of tabs that `read` (tab = IFS whitespace) merges, sliding the status left
  # into the PORT column. ls splits with (ps:\t:) to keep the empty field:
  # the row must read "- waiting" (port dash, then status), not "waiting -".
  plant_live "/tmp/$TNAME-portless.nvim" "$TNAME" portless '' waiting
  run_frame ls
  assert_status 0
  local row=$(print -r -- "$OUT" | grep portless)
  [[ "$row" == *portless*-*waiting ]] \
    || fail "status not in STATUS column, got row: $row"
}

test_current_frame_is_marked() {
  plant_live "/tmp/$TNAME-alpha.nvim" "$TNAME" alpha 5173 WAITING
  plant_live "/tmp/$TNAME-beta.nvim"  "$TNAME" beta  5175 ''
  # No git repo under the sandbox cwd → identity comes from the session env,
  # same as a shell-frame buffer.
  export FRAME_NAME=$TNAME FRAME_TOPIC=alpha
  run_frame ls
  assert_status 0
  local alpha_row=$(print -r -- "$OUT" | grep alpha)
  local beta_row=$(print -r -- "$OUT" | grep beta)
  assert_contains "$alpha_row" "→"
  assert_not_contains "$beta_row" "→"
}

test_stale_socket_excluded() {
  plant_live "/tmp/$TNAME-live.nvim" "$TNAME" live 5173 ''
  plant_dead "/tmp/$TNAME-dead.nvim"          # answers nothing
  run_frame ls
  assert_status 0
  assert_contains "$OUT" "live"
  assert_not_contains "$OUT" "dead"
}

test_unresponsive_socket_skipped_promptly() {
  # An alive-but-wedged frame (socket up, but its nvim never answers the RPC)
  # must not hang the sweep: frame_rpc_expr's timeout bounds the probe, the
  # frame is skipped like dead debris, and the responsive rows still list. A
  # short timeout keeps the suite fast; without the bound this test would hang.
  export FRAME_RPC_TIMEOUT=1
  plant_live "/tmp/$TNAME-live.nvim" "$TNAME" live 5173 ''
  plant_hung "/tmp/$TNAME-hung.nvim"          # blocks forever if not bounded
  run_frame ls
  assert_status 0
  assert_contains "$OUT" "live"
  assert_not_contains "$OUT" "hung"
}

test_no_live_frames_prints_message() {
  # Plant nothing. Any real sockets on the machine can't be answered by the
  # stub (no companion file), so they're skipped too → truly empty.
  run_frame ls
  assert_status 0
  assert_contains "$OUT" "no frames running"
}

test_rows_sorted_by_name_then_topic() {
  # topic=$TNAME (so sandbox_down's *-$TNAME.nvim glob sweeps them); names vary.
  plant_live "/tmp/zzz-$TNAME.nvim" zzz "$TNAME" 5173 ''
  plant_live "/tmp/aaa-$TNAME.nvim" aaa "$TNAME" 5174 ''
  run_frame ls
  assert_status 0
  # aaa must appear before zzz in the output.
  (( ${OUT[(i)aaa]} < ${OUT[(i)zzz]} )) \
    || fail "expected aaa row before zzz row, got: $OUT"
}

run_tests "$0"
