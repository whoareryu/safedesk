#!/usr/bin/env bash
# Run every tests/scripts/test_*.sh; exit 1 if any fails.
set -u
DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
failed=0
found=0
for t in "$DIR"/test_*.sh; do
  [ -e "$t" ] || continue
  found=$((found + 1))
  echo "=== $(basename "$t")"
  if ! bash "$t"; then
    echo "FAILED: $(basename "$t")"
    failed=$((failed + 1))
  fi
done
if [ "$found" -eq 0 ]; then
  echo "no tests found" >&2
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  echo "$failed test file(s) failed"
  exit 1
fi
echo "all $found test file(s) passed"
