#!/usr/bin/env bash
# shellcheck disable=SC2016  # bash -c bodies: $1/$2 expand in the inner shell, as intended
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

# Fabricated macOS identity behind PATH shims (scutil, hostname, id): the default
# ComputerName has a curly apostrophe and the owner's real name in it.
fakefirst="Zq$n"
fakelast="Kimora"
fakereal="$fakefirst $fakelast"
fakecomputer="$fakefirst ${fakelast}’s MacBook Pro"
fakelocal="$fakefirst-${fakelast}s-MacBook-Pro"
shim="$tmp/shim"
mkdir -p "$shim"
cat >"$shim/scutil" <<SH
#!/bin/sh
case "\$2" in
  LocalHostName) echo "$fakelocal" ;;
  ComputerName) echo "$fakecomputer" ;;
  *) exit 1 ;;
esac
SH
cat >"$shim/hostname" <<SH
#!/bin/sh
case "\${1:-}" in -s) echo "$fakelocal" ;; *) echo "$fakelocal.local" ;; esac
SH
cat >"$shim/id" <<SH
#!/bin/sh
case "\${1:-}" in -un) echo "$fakeuser" ;; -F) echo "$fakereal" ;; *) exit 1 ;; esac
SH
chmod +x "$shim/scutil" "$shim/hostname" "$shim/id"

# Environment as the real scripts see it, with fabricated values.
run_in_env() {
  (
    export PATH="$shim:$PATH"
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
assert_fails_with "evidence leak detected" --rc 1 --match '^check-evidence-clean: (hostname|user-path|mac|ip|uuid)' -- \
  check "$f"
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

# --- IPv6 (I2): global, ULA, link-local (EUI-64 = mac) -----------------------
g6="2600:1700:$(printf '%x' $((RANDOM % 4096 + 4096))):1234:aaaa:bbbb:cccc:dddd"
ula="fd7a:115c:a1e0:$(printf '%x' $((RANDOM % 4096 + 4096)))::1"
ll_eui="fe80::1c2b:3cff:fe4d:$(printf '%x' $((RANDOM % 4096 + 4096)))%en0"
ll_plain="fe80::a1b2:c3d4:e5f6:$(printf '%x' $((RANDOM % 4096 + 4096)))"
guest_ll="[fe80::5054:ff:fe12:$(printf '%x' $((RANDOM % 4096 + 4096)))]:546"
expect_leak ip "inet6 $g6 prefixlen 64" "$g6"
expect_leak ip "vpn $ula" "$ula"
expect_leak mac "inet6 $ll_eui" "$ll_eui"
expect_leak ip "inet6 $ll_plain" "$ll_plain"
expect_leak mac "udp $guest_ll" "$guest_ll"

# --- MAC forms (I3) -----------------------------------------------------------
mac_short="a4:83:e7:$((RANDOM % 9 + 1)):2:3"
mac_dash="A4-83-E7-$(printf '%02X' $((RANDOM % 256)))-02-03"
mac_dot="a483.e7$(printf '%02x' $((RANDOM % 256))).0203"
expect_leak mac "? (10.0.0.1) at $mac_short on en0" "$mac_short"
expect_leak mac "adapter $mac_dash" "$mac_dash"
expect_leak mac "cisco $mac_dot" "$mac_dot"

# --- host-name and real-name variants (I4) ------------------------------------
v_straight="$fakefirst ${fakelast}'s MacBook Pro"
v_noapos="$fakefirst ${fakelast}s MacBook Pro"
v_escaped="$fakefirst\\ ${fakelast}’s\\ MacBook\\ Pro"
v_url="$fakefirst%20$fakelast%E2%80%99s%20MacBook%20Pro"
v_lower="$(printf '%s' "$fakecomputer" | tr '[:upper:]' '[:lower:]')"
expect_leak hostname "name $fakecomputer" "$fakecomputer"
expect_leak hostname "name $v_straight" "$v_straight"
expect_leak hostname "name $v_noapos" "$v_noapos"
expect_leak hostname "path $v_escaped" "$v_escaped"
expect_leak hostname "url $v_url" "$v_url"
expect_leak hostname "name $v_lower" "$v_lower"
expect_leak user "owner $fakereal" "$fakereal"
expect_leak user "surname $fakelast only" "$fakelast"
expect_leak user "login $(printf '%s' "$fakeuser" | tr '[:lower:]' '[:upper:]')" "$fakeuser"
expect_leak user "file ${fakeuser}_x" "$fakeuser"
expect_leak user "file ${fakeuser}2" "$fakeuser"

f="$tmp/variants.txt"
{
  echo "1 $fakecomputer"; echo "2 $v_straight"; echo "3 $v_noapos"; echo "4 $v_escaped"
  echo "5 $v_url"; echo "6 $v_lower"; echo "7 $fakereal"; echo "8 $fakelast"
  echo "9 ${fakeuser}_x ${fakeuser}2 $(printf '%s' "$fakeuser" | tr '[:lower:]' '[:upper:]')"
  echo "10 $g6 $ula $ll_eui $ll_plain udp $guest_ll"
  echo "11 $mac_short $mac_dash $mac_dot"
  echo "12 keep [::1]:6443 [::]:22 :: ff02::fb fe80::1%lo0 2001:db8::7 12:34:56 std::string Mon Jun  1"
} >"$f"
scrub "$f"
for v in "$fakecomputer" "$v_straight" "$v_noapos" "$v_escaped" "$v_url" "$fakereal" "$fakelast" "$fakefirst" \
  "$fakeuser" "$g6" "$ula" "$ll_eui" "$ll_plain" "$guest_ll" "$mac_short" "$mac_dash" "$mac_dot"; do
  assert_fails_with "variant scrubbed" --rc 1 -- grep -Fiq -- "$v" "$f"
done
assert_succeeds "check passes after scrubbing variants" -- check "$f"
assert_contains "$(cat "$f")" "keep [::1]:6443 [::]:22 :: ff02::fb fe80::1%lo0 2001:db8::7 12:34:56 std::string Mon Jun  1" \
  "loopback/unspecified/multicast/doc IPv6, times and C++ scopes are kept"
assert_contains "$(cat "$f")" "10 <IPV6> <IPV6> <IPV6> <IPV6> udp [<IPV6>]:546" \
  "each IPv6 (zone id included) becomes <IPV6>, surrounding text and port kept"
assert_contains "$(cat "$f")" "11 <MAC> <MAC> <MAC>" "each MAC form becomes <MAC>"
cp "$f" "$tmp/variants2.txt"
scrub "$tmp/variants2.txt"
assert_succeeds "variant scrub is idempotent" -- cmp -s "$f" "$tmp/variants2.txt"

# --- env IPs replaced on numeric boundaries only (M1) ------------------------
f="$tmp/m1.txt"
echo "mac 10.77.5.25 neighbour 10.77.5.250 dashed ip-10-77-5-25" >"$f"
# shellcheck disable=SC2016
run_in_env env LAN_IP=10.77.5.25 bash -c '. "$1/scripts/verify/lib/scrub.sh" && scrub_evidence "$2"' _ "$ROOT" "$f"
assert_eq "mac <LAN_IP> neighbour 10.77.5.250 dashed ip-<LAN_IP>" "$(cat "$f")" \
  "LAN_IP is not replaced inside a longer address; dashed form is replaced"

# --- IPv4 glued to words or dashes is still an IP (M2) -----------------------
expect_leak ip "name host-$other_ip" "$other_ip"
expect_leak ip "flag -$other_ip" "$other_ip"
expect_leak ip "range 192.0.2.1-$other_ip" "$other_ip"
expect_leak ip "var a_$other_ip" "$other_ip"
dashed="ip-$(printf '%s' "$other_ip" | tr . -)"
expect_leak ip "aws $dashed" "$dashed"

# --- names that occur in placeholders or ordinary words (M3) -----------------
f="$tmp/m3.txt"
echo "hostname <HOSTNAME> macOS <MAC> /Users/someoneelse/x userspace" >"$f"
# shellcheck disable=SC2016
m3() { run_in_env env EVIDENCE_EXTRA_HOSTNAMES="host mac user" "$@"; }
m3 bash -c '. "$1/scripts/verify/lib/scrub.sh" && scrub_evidence "$2"' _ "$ROOT" "$f"
assert_eq "hostname <HOSTNAME> macOS <MAC> /Users/<user>/x userspace" "$(cat "$f")" \
  "names contained in placeholders/Users are skipped; /Users/<other> replaced by shape"
cp "$f" "$tmp/m3b.txt"
m3 bash -c '. "$1/scripts/verify/lib/scrub.sh" && scrub_evidence "$2"' _ "$ROOT" "$tmp/m3b.txt"
assert_succeeds "scrub idempotent with placeholder-like names" -- cmp -s "$f" "$tmp/m3b.txt"
assert_succeeds "check passes with placeholder-like names" -- m3 "$CHECK" "$f"

# --- public IP allowlist file (M5) -------------------------------------------
pub="$tmp/pub.txt"
f="$tmp/public.txt"
echo "edge 1.1.1.1 apex 76.76.21.21 v6 2606:4700::1111" >"$f"
expect_public() { run_in_env env EVIDENCE_PUBLIC_IPS_FILE="$pub" "$@"; }
: >"$pub"
assert_fails_with "public IPs are leaks without an allowlist entry" --rc 1 --match '^check-evidence-clean: ip ' -- \
  expect_public "$CHECK" "$f"
printf '# test allowlist\n1.1.1.1\n76.76.21.0/24   # apex\n2606:4700::/32\n' >"$pub"
assert_succeeds "allowlisted public IPs pass" -- expect_public "$CHECK" "$f"
cp "$f" "$tmp/public2.txt"
# shellcheck disable=SC2016
expect_public bash -c '. "$1/scripts/verify/lib/scrub.sh" && scrub_evidence "$2"' _ "$ROOT" "$f"
assert_succeeds "scrub keeps allowlisted public IPs" -- cmp -s "$f" "$tmp/public2.txt"
printf '192.168.0.0/16\n' >"$pub"
assert_fails_with "private range in the allowlist is rejected" --rc 2 --match '^check-evidence-clean: bad public-IP allowlist entry' -- \
  expect_public "$CHECK" "$f"
printf 'not-an-ip\n' >"$pub"
assert_fails_with "garbage in the allowlist is rejected" --rc 2 --match '^check-evidence-clean: bad public-IP allowlist entry' -- \
  expect_public "$CHECK" "$f"
assert_succeeds "committed allowlist file parses" -- run_in_env "$CHECK" "$ok"

# --- fix round 2 ---------------------------------------------------------------
# N1: macOS netstat / tcpdump print addr.port (v4) and addr.port (v6).
expect_leak ip "tcp4       0      0  $other_ip.53412        198.51.100.7.443       ESTABLISHED" "$other_ip"
expect_leak ip "IP $other_ip.5353 > 224.0.0.251.5353: 0 PTR (QM)? _ssh._tcp.local." "$other_ip"
g6p="2600:1700:abcd:$(printf '%x' $((RANDOM % 4096 + 4096)))::5"
expect_leak ip "tcp6       0      0  $g6p.443        2001:db8::9.443       ESTABLISHED" "$g6p"
f="$tmp/n1.txt"
{
  echo "tcp4       0      0  10.77.5.25.53412       198.51.100.7.443       ESTABLISHED"
  echo "IP 10.77.5.25.5353 > 224.0.0.251.5353: 0 PTR (QM)?"
  echo "tcp6       0      0  $g6p.443        2001:db8::9.443       ESTABLISHED"
} >"$f"
run_in_env env LAN_IP=10.77.5.25 bash -c '. "$1/scripts/verify/lib/scrub.sh" && scrub_evidence "$2"' _ "$ROOT" "$f"
assert_eq "tcp4       0      0  <LAN_IP>.53412       198.51.100.7.443       ESTABLISHED
IP <LAN_IP>.5353 > 224.0.0.251.5353: 0 PTR (QM)?
tcp6       0      0  <IPV6>.443        2001:db8::9.443       ESTABLISHED" "$(cat "$f")" \
  "netstat/tcpdump addr.port: address replaced, port kept"
assert_succeeds "netstat/tcpdump lines clean after scrub" -- run_in_env env LAN_IP=10.77.5.25 "$CHECK" "$f"

# N3: IPv4-mapped (hex and dotted), NAT64 and embedded-v4 IPv6 forms.
expect_leak ip "mapped ::ffff:c0a8:4d19" "c0a8:4d19"
expect_leak ip "nat64 64:ff9b::c0a8:4d19" "c0a8:4d19"
expect_leak ip "mapped ::ffff:$other_ip" "$other_ip"
f="$tmp/n3.txt"
{
  echo "a 2600:1700:abcd:1234:aaaa:bbbb:10.77.5.25 b"
  echo "b ::ffff:c0a8:4d19 c 64:ff9b::c0a8:4d19 d ::ffff:$other_ip e"
  echo "keep ::ffff:127.0.0.1 ::ffff:7f00:1 64:ff9b::c000:20a"
} >"$f"
run_in_env env LAN_IP=10.77.5.25 bash -c '. "$1/scripts/verify/lib/scrub.sh" && scrub_evidence "$2"' _ "$ROOT" "$f"
assert_eq "a <IPV6> b
b <IPV6> c <IPV6> d <IPV6> e
keep ::ffff:127.0.0.1 ::ffff:7f00:1 64:ff9b::c000:20a" "$(cat "$f")" \
  "embedded-v4 global, mapped and NAT64 private forms fully scrubbed; loopback/doc mapped kept"
assert_succeeds "mapped forms clean after scrub" -- check "$f"

# N4: a quad glued after <alnum>- is an address, not a version.
expect_leak ip "iface eth0-$other_ip" "$other_ip"
expect_leak ip "name node-1-$other_ip" "$other_ip"
fp="$tmp/fp.txt"
cat >"$fp" <<'E'
k3s v1.34.1+k3s1 k8s v1.31.4 kubelet/v1.31.4 (linux/arm64) kubernetes/a1b2c3d
containerd v1.7.2.1 containerd 1.7.22-0ubuntu0.24.04.1 runc 1.1.12-0ubuntu3.1
kernel 6.8.0-1.2.3.4-generic linux 6.8.0-134-generic ubuntu 24.04.1 LTS
etcd 3.5.16-0 flannel v0.26.1 go1.23.4 coredns 1.11.3 traefik 3.3.2
libssl.so.3 libc.so.6 libfoo.so.1.2.3 python 3.12.3 openssh 9.6p1
sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
2026-11-24T13:55:10.123+09:00 cf-ray 8f1e2d3c4b5a6978-NRT
lsof [::1]:6443 127.0.0.1.6443 0.0.0.0.22 *.22 multicast 224.0.0.251.5353 ff02::fb.5353
E
assert_succeeds "version strings, digests, loopback addr.port and multicast are not flagged" -- check "$fp"

# N2: allowlist entries overlapping private/reserved space, or too short, are rejected.
f="$tmp/public.txt"
for bad in 192.0.0.0/8 172.0.0.0/8 100.0.0.0/8 169.0.0.0/8 192.0.0.0/16 8.8.0.0/15 2600::/16 2002:c0a8::/32 2001:0::/32; do
  printf '%s\n' "$bad" >"$pub"
  assert_fails_with "allowlist entry $bad rejected" --rc 2 --match '^check-evidence-clean: bad public-IP allowlist entry' -- \
    expect_public "$CHECK" "$f"
done
printf '8.8.0.0/16\n2606:4700::/32\n' >"$pub"
assert_succeeds "public /16 and /32 entries accepted" -- expect_public "$CHECK" "$fp"

# --- usage errors --------------------------------------------------------------
assert_fails_with "no files is a usage error" --rc 2 --match '^check-evidence-clean: usage' -- "$CHECK"
assert_fails_with "missing file is an error" --rc 2 --match '^check-evidence-clean: cannot read ' -- \
  "$CHECK" "$tmp/nope.txt"
assert_summary
