# Frame test harness. A test file sources this, defines test_* functions,
# and ends with:  run_tests "$0"
#
# Each test_* function runs in its own subshell with a fresh sandbox (see
# sandbox.zsh), so failures, cds, and exports never leak between tests.
# Inside a test, err_return is active: an unexpected failing command (a broken
# fixture, say) aborts that test as FAIL. Assert failures print file:line,
# mark the test failed, and let it continue to the next assertion.
# The file's exit code is the number of failed tests (0 = green).

TESTS_DIR="${${(%):-%x}:A:h:h}"
FRAME_CHECKOUT="${TESTS_DIR:h}"
FRAME_BIN="$FRAME_CHECKOUT/bin/frame"
source "$TESTS_DIR/helpers/sandbox.zsh"
source "$TESTS_DIR/helpers/gitrepo.zsh"

# ── running frame ─────────────────────────────────────────────────────────────

run_frame() {
  # Invoke frame, capturing stdout+stderr into $OUT and exit code into $STATUS.
  # Never trips err_return — tests assert on $STATUS explicitly.
  OUT=$("$FRAME_BIN" "$@" 2>&1) && STATUS=0 || STATUS=$?
}

# ── asserts ───────────────────────────────────────────────────────────────────

_assert_fail() {
  # $funcfiletrace[2] = the test line that called the assert function
  print -r -- "    ✗ ${funcfiletrace[2]}: $1"
  _TEST_FAILED=1
}

fail() { print -r -- "    ✗ ${funcfiletrace[1]}: $1"; _TEST_FAILED=1; }
skip() { print -r -- "    ~ ${funcfiletrace[1]}: skipped — $1"; }

assert_eq()           { [[ "$1" == "$2" ]]   || _assert_fail "${3:-expected [$2], got [$1]}"; }
assert_status()       { (( STATUS == $1 ))   || _assert_fail "expected exit $1, got $STATUS — output: $OUT"; }
assert_contains()     { [[ "$1" == *"$2"* ]] || _assert_fail "${3:-expected to contain [$2], got: $1}"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || _assert_fail "${3:-expected NOT to contain [$2]}"; }
assert_file_exists()  { [[ -f "$1" ]]        || _assert_fail "expected file $1"; }
assert_file_absent()  { [[ ! -e "$1" ]]      || _assert_fail "expected $1 to be absent"; }
assert_dir_exists()   { [[ -d "$1" ]]        || _assert_fail "expected dir $1"; }
assert_dir_absent()   { [[ ! -d "$1" ]]      || _assert_fail "expected dir $1 to be absent"; }
assert_link_target()  {
  [[ "$(readlink "$1" 2>/dev/null)" == "$2" ]] \
    || _assert_fail "expected $1 -> $2, got $(readlink "$1" 2>/dev/null || echo '<not a link>')"
}
assert_branch_exists() {
  git -C "$1" show-ref --verify --quiet "refs/heads/$2" \
    || _assert_fail "expected branch $2 in $1"
}
assert_branch_absent() {
  ! git -C "$1" show-ref --verify --quiet "refs/heads/$2" \
    || _assert_fail "expected branch $2 to be gone from $1"
}

# ── runner ────────────────────────────────────────────────────────────────────

run_tests() {
  local file=$1 failed=0 t rc
  local -a tests
  tests=(${(M)${(ok)functions}:#test_*})
  print -r -- "── ${file:t} (${#tests} tests)"
  for t in $tests; do
    # NOT `if ( … )`: a subshell in a tested position would suppress err_return
    # inside it. Run bare, read $? after.
    (
      setopt err_return
      _TEST_FAILED=0
      trap 'rc=$?; if (( _TEST_FAILED )); then rc=1; fi; sandbox_down; exit $rc' EXIT
      sandbox_up
      "$t"
    )
    rc=$?
    if (( rc == 0 )); then
      print -r -- "  ok   $t"
    else
      print -r -- "  FAIL $t"
      failed=$((failed + 1))
    fi
  done
  (( failed )) && print -r -- "── ${file:t}: $failed FAILED"
  exit $failed
}
