#!/usr/bin/env zsh
# White-box tests for resume-between-frames (frame wt --from/--resume). The
# resolver frame_session_id_for_dir maps a worktree path to its newest claude
# transcript's session id — the fallback path when a frame recorded no
# .session (the authoritative source; see the swarm/wt tests). Keys on the same
# sanitization Claude Code uses: absolute cwd, every non-alnum char → '-'.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"
export FRAME_ROOT="$FRAME_CHECKOUT"
source "$FRAME_ROOT/lib/helpers.sh"

_plant() {  # _plant DIR SESSION_ID [touch-stamp]
  # Mirror frame_session_id_for_dir's keying (${dir:A} then non-alnum → '-') so
  # the fixture lands where the resolver looks, symlinked TMPDIR/HOME and all.
  local dir=$1 sid=$2 stamp=${3:-}
  local proj="${${dir:A}//[^A-Za-z0-9]/-}"
  local pdir="$HOME/.claude/projects/$proj"
  mkdir -p "$pdir"
  local f="$pdir/$sid.jsonl"
  print -r -- '{}' > "$f"
  if [[ -n "$stamp" ]]; then touch -t "$stamp" "$f"; fi
}

test_returns_newest_session_id() {
  local wt="$HOME/git/_proj-topic"
  _plant "$wt" old-1111 202001010000
  _plant "$wt" new-2222 202401010000
  assert_eq "$(frame_session_id_for_dir "$wt")" "new-2222"
}

test_single_session_resolves() {
  local wt="$HOME/git/_proj-solo"
  _plant "$wt" only-abcd
  assert_eq "$(frame_session_id_for_dir "$wt")" "only-abcd"
}

test_missing_project_dir_returns_nonzero() {
  # `if COND` exempts the nonzero return from err_return; a SUCCESS is the bug.
  if frame_session_id_for_dir "$HOME/git/_proj-nope" >/dev/null; then
    fail "expected nonzero for a worktree with no transcript dir"
  fi
}

test_empty_project_dir_returns_nonzero() {
  local wt="$HOME/git/_proj-empty"
  mkdir -p "$HOME/.claude/projects/${${wt:A}//[^A-Za-z0-9]/-}"
  if frame_session_id_for_dir "$wt" >/dev/null; then
    fail "expected nonzero for a transcript dir with no *.jsonl"
  fi
}

run_tests "$0"
