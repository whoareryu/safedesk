#!/usr/bin/env bash
# Test scripts/lib/env.sh load_env for the local + cloudflare target.
set -u
ROOT="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/env-test.XXXXXX")"
trap 'rm -rf "$tmp"; rm -f "${ASSERT_STATE:-}"' EXIT

# write_env <file> [extra lines...]: a complete local env, then extras appended
# (a later assignment overrides an earlier one).
write_env() {
  local f="$1"
  shift
  cat >"$f" <<'ENV'
TARGET=local
HOST_SAFEDESK=safedesk.example.invalid
HOST_MINISHOP=minishop.example.invalid
HOST_RELAY=relay.example.invalid
CF_ZONE=example.invalid
LIMA_INSTANCE=test-vm
TUNNEL_NAME=test-tunnel
ACME_EMAIL=test@example.invalid
K3S_VERSION=v1.99.0+k3s1
ENV
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >>"$f"
}

# load <file> [cmd]: run load_env in a fresh bash against <file>, then cmd.
load() {
  CLUSTER_ENV_FILE="$1" bash -c '. "$1/scripts/lib/env.sh"; load_env; eval "${2:-:}"' _ "$ROOT" "${2:-:}"
}

write_env "$tmp/ok.env"
assert_succeeds "local env without PUBLIC_IP/TS_IP loads" -- load "$tmp/ok.env"

write_env "$tmp/oci.env" TARGET=oci
assert_fails_with "oci target not implemented" --rc 2 --match 'TARGET=oci is not implemented yet' -- load "$tmp/oci.env"

write_env "$tmp/staging.env" TARGET=staging
assert_fails_with "unknown target rejected" --rc 2 --match 'unsupported TARGET: staging \(expected: local\)' -- load "$tmp/staging.env"

write_env "$tmp/nolima.env" LIMA_INSTANCE=
assert_fails_with "local requires LIMA_INSTANCE" --rc 2 --match 'missing required variables:.*LIMA_INSTANCE' -- load "$tmp/nolima.env"

write_env "$tmp/notunnel.env" TUNNEL_NAME=
assert_fails_with "local requires TUNNEL_NAME" --rc 2 --match 'missing required variables:.*TUNNEL_NAME' -- load "$tmp/notunnel.env"

write_env "$tmp/notarget.env" TARGET=
assert_fails_with "TARGET required" --rc 2 --match 'missing required variables:.*TARGET' -- load "$tmp/notarget.env"

write_env "$tmp/nozone.env" CF_ZONE=
assert_fails_with "CF_ZONE required" --rc 2 --match 'missing required variables:.*CF_ZONE' -- load "$tmp/nozone.env"

# Required-variable check comes before the TARGET value check.
write_env "$tmp/oci-missing.env" TARGET=oci ACME_EMAIL=
assert_fails_with "missing vars reported before oci rejection" --rc 2 --match 'missing required variables:.*ACME_EMAIL' -- load "$tmp/oci-missing.env"

# PUBLIC_IP / TS_IP are no longer required; stale values are not exported.
write_env "$tmp/stale.env" PUBLIC_IP=203.0.113.7 TS_IP=100.64.0.9
assert_succeeds "stale PUBLIC_IP/TS_IP tolerated" -- load "$tmp/stale.env"
# shellcheck disable=SC2016
out="$(load "$tmp/stale.env" 'sh -c "printf %s \"\${PUBLIC_IP-unset}/\${TS_IP-unset}\""' 2>&1)"
assert_eq unset/unset "$out" "stale PUBLIC_IP/TS_IP not exported"

# TUNNEL_ID is optional; when set it is exported to child processes.
fake_id="$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 12)"
write_env "$tmp/tid.env" "TUNNEL_ID=$fake_id"
# shellcheck disable=SC2016
out="$(load "$tmp/tid.env" 'bash -c "printf %s \"\${TUNNEL_ID:-unset}\""' 2>&1)"
assert_eq "$fake_id" "$out" "TUNNEL_ID visible in child process"
# shellcheck disable=SC2016
out="$(load "$tmp/ok.env" 'bash -c "printf %s \"\${TUNNEL_ID:-unset}\""' 2>&1)"
assert_eq unset "$out" "TUNNEL_ID unset when absent"
write_env "$tmp/tid-empty.env" TUNNEL_ID=
assert_succeeds "empty TUNNEL_ID is allowed" -- load "$tmp/tid-empty.env"

# Required vars are exported to children.
# shellcheck disable=SC2016
out="$(load "$tmp/ok.env" 'bash -c "printf %s \"\$TARGET/\$LIMA_INSTANCE/\$CF_ZONE\""' 2>&1)"
assert_eq "local/test-vm/example.invalid" "$out" "required vars exported"

assert_summary
