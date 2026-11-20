#!/usr/bin/env bash
# Exercise .gitleaks.toml rules against fixtures (positive must be flagged,
# negative must not). Uses a temp config copy without the fixture allowlist.
set -u
ROOT="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/assert.sh"

if ! command -v gitleaks >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: gitleaks and jq are required"
  exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitleaks-test.XXXXXX")"
trap 'rm -rf "$tmp"; rm -f "${ASSERT_STATE:-}"' EXIT
grep -v 'FIXTURE-ALLOWLIST' "$ROOT/.gitleaks.toml" | grep -v '^\[allowlist\]' >"$tmp/gitleaks.toml"
assert_fails "temp config has no fixture allowlist" -- grep -q 'fixtures/gitleaks' "$tmp/gitleaks.toml"

cp -R "$ROOT/tests/scripts/fixtures/gitleaks/." "$tmp/fx/" 2>/dev/null || mkdir -p "$tmp/fx"
gitleaks dir "$tmp/fx" --config "$tmp/gitleaks.toml" --report-format json \
  --report-path "$tmp/report.json" --no-banner --log-level error >/dev/null 2>&1
flagged="$(jq -r '.[].File' "$tmp/report.json" 2>/dev/null | sed "s#^$tmp/fx/##" | sort -u)"

for f in "$tmp"/fx/positive/*; do
  n="positive/$(basename "$f")"
  assert_contains "$flagged" "$n" "flagged: $n"
done
for f in "$tmp"/fx/negative/*; do
  n="negative/$(basename "$f")"
  hit=no
  case "$flagged" in *"$n"*) hit=yes ;; esac
  assert_eq no "$hit" "not flagged: $n"
done

# Repo's own config (with allowlist) must treat fixtures as clean.
assert_succeeds "fixtures allowlisted in repo config" -- \
  gitleaks dir "$ROOT/tests/scripts/fixtures/gitleaks" --config "$ROOT/.gitleaks.toml" --no-banner --log-level error

assert_summary
