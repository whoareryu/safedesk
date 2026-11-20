#!/usr/bin/env bash
# Exercise .gitleaks.toml rules against fake secrets generated at runtime
# (positive must be flagged, negative must not). Nothing key-shaped is stored in
# the repo: every value is assembled here into a temp dir.
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
fx="$tmp/fx"
mkdir -p "$fx/positive" "$fx/negative"

rnd() { LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c "$1"; }
uuid() { printf '%s-%s-%s-%s-%s' "$(rnd 8)" "$(rnd 4)" "$(rnd 4)" "$(rnd 4)" "$(rnd 12)"; }
TS="tsk""ey-" # prefix split so no complete key literal exists in this file

U1="$(uuid)"
U2="$(uuid)"
UU="$(printf '%s' "$U2" | tr 'a-f' 'A-F')"

# DuckDNS / UUID token positives
printf 'curl "https://www.duckdns.org/update?domains=example&token=%s&ip="\n' "$U1" >"$fx/positive/update-url.sh"
printf 'token: %s\n' "$U1" >"$fx/positive/token.yaml"
printf 'TOKEN=%s\n' "$UU" >"$fx/positive/upper.txt"
printf 'duckdns:\n  domain: example\n  key: %s\n' "$U2" >"$fx/positive/duckdns-block.yaml"
printf 'duckdns:\n  apiKey: %s\n' "$U2" >"$fx/positive/apikey.yaml"
printf 'DUCKDNS_DOMAIN_TOKEN_VALUE_FOR_CRON_JOB_OF_THE_NODE_XXXXXXXXXXXXXXXX = %s\n' "$U1" >"$fx/positive/far-keyword.txt"
printf '%s\n' "$U1" >"$fx/positive/duckdns-token"

# Tailscale positives (all forms)
printf 'TS_AUTHKEY=%sauth-k%sCNTRL-%s\n' "$TS" "$(rnd 8)" "$(rnd 32)" >"$fx/positive/ts-auth.txt"
printf 'key: %sclient-k%sCNTRL-%s\n' "$TS" "$(rnd 8)" "$(rnd 32)" >"$fx/positive/ts-client.txt"
printf 'key: %sapi-k%sCNTRL-%s\n' "$TS" "$(rnd 8)" "$(rnd 32)" >"$fx/positive/ts-api.txt"
printf 'key: %s%s\n' "$TS" "$(rnd 44)" >"$fx/positive/ts-legacy.txt"
printf 'key: %sk%s-%s\n' "$TS" "$(rnd 10)" "$(rnd 32)" >"$fx/positive/ts-kid.txt"

# Negatives: documentation placeholders and a bare uuid with no keyword
printf 'Example: tailscale up --auth-key=%sauth-%s\nor %sxxxx\n' "$TS" "$(printf 'X%.0s' $(seq 1 24))" "$TS" >"$fx/negative/ts-placeholder.md"
printf 'metadata:\n  uid: %s\n' "$(uuid)" >"$fx/negative/uid.yaml"

# Config under test: the repo config as-is (it carries no path allowlist).
assert_fails "repo config has no fixture allowlist" -- grep -q 'fixtures' "$ROOT/.gitleaks.toml"

gitleaks dir "$fx" --config "$ROOT/.gitleaks.toml" --report-format json \
  --report-path "$tmp/report.json" --no-banner --log-level error >/dev/null 2>&1
flagged="$(jq -r '.[].File' "$tmp/report.json" 2>/dev/null | sed "s#^$fx/##" | sort -u)"

for f in "$fx"/positive/*; do
  n="positive/$(basename "$f")"
  assert_contains "$flagged" "$n" "flagged: $n"
done
for f in "$fx"/negative/*; do
  n="negative/$(basename "$f")"
  hit=no
  case "$flagged" in *"$n"*) hit=yes ;; esac
  assert_eq no "$hit" "not flagged: $n"
done

assert_eq 12 "$(printf "%s\n" "$flagged" | grep -c .)" "exactly the 12 positive fixtures are flagged"

assert_summary
