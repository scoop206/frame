#!/usr/bin/env zsh
# Shape validation of the buffers.json registry, and cross-check that the
# scaffold template's default BUFFERS all exist in it.
source "${${(%):-%x}:A:h:h}/helpers/harness.zsh"

test_registry_shape() {
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available"
    return 0
  fi
  local out st
  out=$(python3 - "$FRAME_CHECKOUT/buffers.json" <<'PY' 2>&1
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
assert isinstance(data, list) and data, "must be a non-empty array"
names = [b.get("name") for b in data]
assert all(names), "every buffer needs a name"
assert len(names) == len(set(names)), f"duplicate buffer names: {names}"
for b in data:
    assert b.get("mode") in ("bare", "durable", "prefill"), f"bad mode: {b}"
PY
) && st=0 || st=$?
  assert_eq "$st" "0" "buffers.json shape check failed: $out"
}

test_init_default_buffers_exist_in_registry() {
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available"
    return 0
  fi
  make_repo
  run_frame init
  assert_status 0
  local -a bufs
  bufs=($(zsh -c 'source .frame/config.sh && print -r -- $BUFFERS'))
  if (( ${#bufs} == 0 )); then
    fail "could not parse BUFFERS out of the scaffold template"
    return 0
  fi
  local out st
  out=$(python3 - "$FRAME_CHECKOUT/buffers.json" $bufs <<'PY' 2>&1
import json, sys
names = {b["name"] for b in json.load(open(sys.argv[1]))}
missing = [n for n in sys.argv[2:] if n not in names]
assert not missing, f"scaffold BUFFERS not in registry: {missing}"
PY
) && st=0 || st=$?
  assert_eq "$st" "0" "$out"
}

run_tests "$0"
