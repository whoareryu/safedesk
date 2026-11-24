#!/usr/bin/env bash
# Test scripts/verify/lib/scrub.sh and scripts/verify/check-evidence-clean.sh.
# All "private" values are fabricated at run time; nothing real is committed.
set -u
ROOT="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/assert.sh"
CHECK="$ROOT/scripts/verify/check-evidence-clean.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/scrub-test.XXXXXX")"
trap 'rm -rf "$tmp"; rm -f "${ASSERT_STATE:-}"' EXIT

n=$(printf '%s' "$$$RANDOM" | tr -cd '0-9')
fakehost="zzhost-$n"
fakeuser="zzuser$n"
fakemac="02:$(printf '%02x:%02x:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))"
lan_ip="10.77.$((RANDOM % 200 + 1)).$((RANDOM % 200 + 1))"
guest_ip="10.88.$((RANDOM % 200 + 1)).$((RANDOM % 200 + 1))"
home_ip="198.18.$((RANDOM % 200 + 1)).$((RANDOM % 200 + 1))"
other_ip="172.16.$((RANDOM % 200 + 1)).$((RANDOM % 200 + 1))"
h8=$(printf '%08x' $((RANDOM * RANDOM)))
uuid="${h8}-1a2b-4c3d-8e4f-$(printf '%012x' $((RANDOM * RANDOM * RANDOM)))"
hex32="$(printf '%08x' $((RANDOM * RANDOM)))$(printf '%08x' $((RANDOM * RANDOM)))$(printf '%08x' $((RANDOM * RANDOM)))9f00dd11"
email="zz$n@private-mail.test"
token="ghp_$(printf 'A1b2C3d4E5f6G7h8I9j0%s' "$n")"

# Environment as the real scripts see it, with fabricated values.
run_in_env() {
  (
    export HOME="/Users/$fakeuser" USER="$fakeuser" EVIDENCE_EXTRA_HOSTNAMES="$fakehost"
    export LAN_IP="$lan_ip" GUEST_IP="$guest_ip" HOME_IP="$home_ip" TUNNEL_ID="$uuid"
    "$@"
  )
}
scrub() {
  # shellcheck disable=SC2016  # $1/$2 expand in the inner shell, as intended
  run_in_env bash -c '. "$1/scripts/verify/lib/scrub.sh" && scrub_evidence "$2"' _ "$ROOT" "$1"
}
check() { run_in_env "$CHECK" "$@"; }

# --- scrub_evidence removes every private value -----------------------------
f="$tmp/dirty.txt"
{
  echo "host $fakehost and upper $(printf '%s' "$fakehost" | tr '[:lower:]' '[:upper:]')"
  echo "path /Users/$fakeuser/.kube/config and user $fakeuser"
  echo "other user path /Users/someoneelse/x"
  echo "mac $fakemac"
  echo "lan $lan_ip guest $guest_ip home $home_ip lan again $lan_ip:6443"
  echo "tunnel $uuid"
  echo "other id $hex32"
  echo "keep 127.0.0.1:6443 0.0.0.0:22 sha256 $(printf 'ab%.0s' $(seq 1 32))"
} >"$f"
assert_fails_with "dirty file is detected before scrubbing" --rc 1 --match '^check-evidence-clean: ' -- \
  "$CHECK" "$f"
scrub "$f"
for v in "$fakehost" "$fakeuser" "$fakemac" "$lan_ip" "$guest_ip" "$home_ip" "$uuid" "$hex32" "someoneelse"; do
  assert_fails_with "scrubbed file no longer contains a private value" --rc 1 -- grep -Fiq -- "$v" "$f"
done
assert_succeeds "check-evidence-clean passes after scrub" -- check "$f"
scrubbed="$(cat "$f")"
assert_contains "$scrubbed" "/Users/<user>/.kube/config" "home path replaced by /Users/<user>"
assert_contains "$scrubbed" "<MAC>" "MAC placeholder"
assert_contains "$scrubbed" "<LAN_IP>:6443" "LAN_IP placeholder keeps port"
assert_contains "$scrubbed" "<GUEST_IP>" "GUEST_IP placeholder"
assert_contains "$scrubbed" "<HOME_IP>" "HOME_IP placeholder"
assert_contains "$scrubbed" "<TUNNEL_ID>" "TUNNEL_ID placeholder"
assert_contains "$scrubbed" "127.0.0.1:6443 0.0.0.0:22" "loopback and wildcard addresses are kept"

# --- scrub is idempotent ------------------------------------------------------
cp "$f" "$tmp/again.txt"
scrub "$tmp/again.txt"
assert_succeeds "second scrub changes nothing" -- cmp -s "$f" "$tmp/again.txt"

# --- check-evidence-clean: one kind per leak, value never printed ------------
expect_leak() { # <kind> <line> <secret-value>
  local kind="$1" line="$2" secret="$3" file out
  file="$tmp/leak-$kind.txt"
  out="$tmp/leak-$kind.out"
  printf 'header\n%s\n' "$line" >"$file"
  assert_fails_with "leak detected: $kind" --rc 1 --match "^check-evidence-clean: ${kind} " -- \
    check "$file"
  check "$file" >"$out" 2>&1
  assert_fails_with "leak output for $kind does not echo the value" --rc 1 -- grep -Fq -- "$secret" "$out"
}
expect_leak hostname "scanned from $fakehost today" "$fakehost"
expect_leak user-path "kubeconfig at /Users/$fakeuser/.kube/config" "$fakeuser"
expect_leak user-path "kubeconfig at /Users/anotherperson/.kube/config" "anotherperson"
expect_leak user "login as $fakeuser" "$fakeuser"
expect_leak mac "iface ether $fakemac" "$fakemac"
expect_leak ip "scanned $other_ip" "$other_ip"
expect_leak ip "env lan $lan_ip" "$lan_ip"
expect_leak uuid "tunnel $uuid" "$uuid"
expect_leak uuid "account id $hex32" "$hex32"
expect_leak email "contact $email" "$email"
expect_leak token "token $token" "$token"
expect_leak token "key -----BEGIN OPENSSH PRIVATE KEY-----" "BEGIN OPENSSH"

# --- allowed content is not flagged (false-positive guard) -------------------
ok="$tmp/ok.txt"
cat >"$ok" <<'E'
# lima listeners (127.0.0.1 and wildcard are fine)
127.0.0.1:6443
0.0.0.0:22 [::1]:6443 [::]:22
tcp 127.0.0.53:53
placeholders <LAN_IP> <GUEST_IP> <HOME_IP> <TUNNEL_ID> <MAC> /Users/<user>/x
k3s v1.34.1+k3s1 containerd v1.7.2.1 kernel 6.8.0-1.2.3.4-generic ubuntu 24.04.1
pod 10.42.0.15 service 10.43.0.1 cidr 10.42.0.0/16
docs 192.0.2.10 198.51.100.7 203.0.113.9
public hosts safedesk.whoareryu.cloud relay.whoareryu.cloud minishop.whoareryu.cloud
sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
commit 0123456789abcdef0123456789abcdef01234567
Host: <LAN_IP> ()	Ports: 22/open/tcp//ssh///
author Whoareryu <12345+whoareryu@users.noreply.github.com> admin@example.invalid
E
assert_succeeds "allowed content passes the check" -- check "$ok"

# --- usage errors --------------------------------------------------------------
assert_fails_with "no files is a usage error" --rc 2 --match '^check-evidence-clean: usage' -- "$CHECK"
assert_fails_with "missing file is an error" --rc 2 --match '^check-evidence-clean: cannot read ' -- \
  "$CHECK" "$tmp/nope.txt"
assert_summary
