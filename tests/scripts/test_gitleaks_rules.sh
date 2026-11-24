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

# Cloudflare positives. Values are runtime-generated; the base64 token prefix and
# the PEM header are split so no complete secret-shaped literal exists here.
b64() { head -c "$1" /dev/urandom | base64 | tr -d '\n=' ; }
rndw() { LC_ALL=C tr -dc 'A-Za-z0-9_-' </dev/urandom | head -c "$1"; }
CFT="$(rndw 40)"
TOK="eyJh""Ijoi$(b64 150 | tr '+/' '-_')"
printf 'CF_API_TOKEN=%s\n' "$CFT" >"$fx/positive/cf-env.txt"
printf 'apiVersion: v1\nkind: Secret\nstringData:\n  api-token: %s\n' "$(rndw 40)" >"$fx/positive/cf-secret.yaml"
printf '{"AccountTag":"%s","TunnelSecret":"%s=","TunnelID":"%s"}\n' "$(rnd 32)" "$(b64 32)" "$(uuid)" >"$fx/positive/tunnel-creds.json"
printf 'TUNNEL_TOKEN=%s\n' "$TOK" >"$fx/positive/tunnel-token.env"
printf -- '-----BEGIN ARGO ''TUNNEL TOKEN-----\n%s\n-----END ARGO TUNNEL TOKEN-----\n' "$(b64 220 | fold -w 64)" >"$fx/positive/origin-cert.txt"

# Cloudflare negatives: template variable, placeholders, redacted
# shellcheck disable=SC2016  # literal ${TUNNEL_ID}, not expanded
printf 'tunnel: ${TUNNEL_ID}\ncredentials-file: /etc/cloudflared/${TUNNEL_ID}.json\n' >"$fx/negative/config.yml.tmpl"
printf 'CF_API_TOKEN=<placeholder>\n' >"$fx/negative/cf-placeholder.env"
printf '{"TunnelSecret": "<redacted>"}\n' >"$fx/negative/tunnel-redacted.json"

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

assert_eq 17 "$(printf "%s\n" "$flagged" | grep -c .)" "exactly the 17 positive fixtures are flagged"

assert_summary
