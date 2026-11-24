#!/usr/bin/env bash
# Test scripts/hooks/check-cluster-values.sh in a throwaway git repo.
set -u
ROOT="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/assert.sh"
HOOK="$ROOT/scripts/hooks/check-cluster-values.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cluster-hook.XXXXXX")"
trap 'rm -rf "$tmp"; rm -f "${ASSERT_STATE:-}"' EXIT
cd "$tmp" || exit 1
git init -q . && git config user.email t@example.invalid && git config user.name t
mkdir config

run_hook() { (cd "$tmp" && "$HOOK"); }
reset() { git reset -q 2>/dev/null; rm -f note.md; }

echo "see 203.0.113.7" >note.md
git add note.md
assert_succeeds "passes when cluster.env is absent" -- run_hook

cat >config/cluster.env <<'ENV'
PUBLIC_IP=203.0.113.7
TS_IP=100.64.0.9
HOST_SAFEDESK=safedesk-test.example.invalid
ACME_EMAIL="test@example.invalid"
K3S_VERSION=v1.99.0+k3s1
TARGET=local
CF_ZONE=zone-test.example.invalid
LIMA_INSTANCE=lima-test-vm
TUNNEL_NAME=tunnel-test-name
TUNNEL_ID=tunid-test-0123456789
EMPTY=
ENV

assert_fails_with "PUBLIC_IP blocked" --rc 1 --match 'value of PUBLIC_IP from config/cluster.env appears' -- run_hook
out="$(run_hook 2>&1)"
assert_contains "$out" "PUBLIC_IP" "message names the variable"
leak=no
case "$out" in *203.0.113.7*) leak=yes ;; esac
assert_eq no "$leak" "message does not print the value"
reset

echo "mail test@example.invalid" >note.md
git add note.md
assert_fails_with "ACME_EMAIL blocked" --rc 1 --match 'value of ACME_EMAIL from config/cluster.env appears' -- run_hook
reset

echo "tunnel tunid-test-0123456789" >note.md
git add note.md
assert_fails_with "TUNNEL_ID blocked" --rc 1 --match 'value of TUNNEL_ID from config/cluster.env appears' -- run_hook
out="$(run_hook 2>&1)"
leak=no
case "$out" in *tunid-test-0123456789*) leak=yes ;; esac
assert_eq no "$leak" "TUNNEL_ID message does not print the value"
reset

echo "target local zone zone-test.example.invalid vm lima-test-vm tunnel tunnel-test-name" >note.md
git add note.md
assert_succeeds "TARGET CF_ZONE LIMA_INSTANCE TUNNEL_NAME are allowed" -- run_hook
reset

echo "host safedesk-test.example.invalid and v1.99.0+k3s1" >note.md
git add note.md
assert_succeeds "HOST_* and K3S_VERSION are allowed" -- run_hook
reset

echo "nothing sensitive" >note.md
git add note.md
assert_succeeds "passes when no value appears" -- run_hook
reset

# Only added lines count: a removed line containing the value is fine.
echo "203.0.113.7" >old.md
git add old.md && git commit -q -m base
git rm -q old.md
assert_succeeds "removed lines are ignored" -- run_hook

assert_summary
