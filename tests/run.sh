#!/usr/bin/env zsh
# Frame test runner.
#   tests/run.sh                     lint + all tests
#   tests/run.sh --unit [PATTERN]    unit tier only
#   tests/run.sh --integration       integration tier only
#   tests/run.sh --lint              lint only
#   tests/run.sh merge               any tier, files matching *merge*
set -uo pipefail

ROOT="${${(%):-%x}:A:h:h}"
tier=all
pattern=""
for arg in "$@"; do
  case "$arg" in
    --unit)        tier=unit ;;
    --integration) tier=integration ;;
    --lint)        tier=lint ;;
    -h|--help)     sed -n '2,8p' "${(%):-%x}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)            print -r -- "✗ unknown flag: $arg" >&2; exit 2 ;;
    *)             pattern=$arg ;;
  esac
done

failed=0

if [[ $tier == all || $tier == lint ]]; then
  if ! zsh "$ROOT/tests/lint.sh"; then
    failed=$((failed + 1))
  fi
fi

typeset -a files
if [[ $tier == all || $tier == unit ]]; then
  files+=($ROOT/tests/unit/test_*.zsh(N))
fi
if [[ $tier == all || $tier == integration ]]; then
  files+=($ROOT/tests/integration/test_*.zsh(N))
fi
if [[ -n $pattern ]]; then
  files=(${(M)files:#*$pattern*})
  if (( ${#files} == 0 )) && [[ $tier != lint ]]; then
    print -r -- "✗ no test files match '$pattern'" >&2
    exit 2
  fi
fi

ran=0
for f in $files; do
  zsh "$f"
  rc=$?
  ran=$((ran + 1))
  if (( rc != 0 )); then
    failed=$((failed + 1))
  fi
done

print -r -- ""
if (( failed )); then
  print -r -- "✗ $failed of $ran test file(s) (or lint) FAILED"
  exit 1
fi
print -r -- "✓ all green ($ran test files)"
