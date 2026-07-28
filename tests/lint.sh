#!/usr/bin/env zsh
# Parse-check (zsh -n) every zsh script in the repo, plus a buffers.json
# validity check. shellcheck is deliberately absent — it has no zsh support.
set -uo pipefail

ROOT="${${(%):-%x}:A:h:h}"
failed=0

typeset -a files
files=(
  $ROOT/bin/frame
  $ROOT/lib/*.sh(N)
  $ROOT/commands/*.sh(N)
  $ROOT/examples/*/.frame/config.sh(N)
  $ROOT/tests/*.sh(N)
  $ROOT/tests/helpers/*.zsh(N)
  $ROOT/tests/unit/*.zsh(N)
  $ROOT/tests/integration/*.zsh(N)
  $ROOT/tests/stubs/*(N)
)

for f in $files; do
  if ! zsh -n "$f"; then
    print -r -- "✗ syntax: $f"
    failed=1
  fi
done
print -r -- "✓ zsh -n: ${#files} files parsed"

if command -v python3 >/dev/null 2>&1; then
  if python3 -m json.tool "$ROOT/buffers.json" >/dev/null; then
    print -r -- "✓ buffers.json is valid JSON"
  else
    print -r -- "✗ buffers.json is not valid JSON"
    failed=1
  fi
else
  print -r -- "~ python3 not found — skipping buffers.json check"
fi

exit $failed
