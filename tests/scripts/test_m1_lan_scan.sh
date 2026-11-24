#!/usr/bin/env bash
# Test scripts/verify/m1-lan-scan.sh with synthetic gnmap pairs (RFC 5737 IPs)
# and a fake socketfilterfw. No scan is run, nothing touches the real firewall.
set -u
ROOT="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/assert.sh"
# shellcheck source=/dev/null
. "$ROOT/scripts/verify/lib/lan-scan.sh"
SCRIPT="$ROOT/scripts/verify/m1-lan-scan.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/m1lanscan-test.XXXXXX")"
trap 'rm -rf "$tmp"; rm -f "${ASSERT_STATE:-}"' EXIT

# Fake socketfilterfw: state from $FW_STATE_TEXT, app list from $FW_APPS_FILE.
cat >"$tmp/fw" <<'FW'
#!/bin/sh
case "$1" in
  --getglobalstate) echo "${FW_STATE_TEXT:-Firewall is disabled. (State = 0)}" ;;
  --listapps) cat "$FW_APPS_FILE" ;;
  *) echo "unexpected fake socketfilterfw call: $1" >&2; exit 9 ;;
esac
FW
chmod +x "$tmp/fw"
echo "ALF : 1 apps (fake)" >"$tmp/apps-empty"
export SOCKETFILTERFW="$tmp/fw" FW_APPS_FILE="$tmp/apps-empty"

# mk <file> <ports line> [hostname-in-parens] [header lines...]
# ports line example: "22/open/tcp//ssh///, 18090/open/tcp////"
mk() {
  local f="$1" ports="$2" name="$3"
  shift 3
  {
    local h
    for h in "$@"; do printf '%s\n' "$h"; done
    echo "# Nmap 7.98 scan initiated Mon Jan  1 00:00:00 2026 as: nmap -n -Pn -p- -T4 -oG x 192.0.2.10"
    printf 'Host: 192.0.2.10 (%s)\tStatus: Up\n' "$name"
    printf 'Host: 192.0.2.10 (%s)\tPorts: %s\n' "$name" "$ports"
    echo "# Nmap done at Mon Jan  1 00:01:00 2026 -- 1 IP address (1 host up) scanned in 60.00 seconds"
  } >"$f"
}
H_DEV=("# scanner: device" "# control-port: 18090" "# firewall-state: disabled" "# firewall-allowance: no")
CTRL="18090/open/tcp////"

mk "$tmp/off.gnmap" "$CTRL" "" "${H_DEV[@]}"
mk "$tmp/on.gnmap" "$CTRL" "" "${H_DEV[@]}"
run() { env -u ASSERT_STATE bash "$SCRIPT" --ssh-port 60022 "$@"; }

echo "-- good pair"
assert_succeeds "good pair passes" -- run --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on.gnmap"

echo "-- VM adds a port"
mk "$tmp/on-extra.gnmap" "8080/open/tcp////, $CTRL" "" "${H_DEV[@]}"
assert_fails_with "VM-added port detected" --rc 1 --match 'FAIL - VM adds no port on Mac LAN IP' -- \
  run --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on-extra.gnmap"

echo "-- forbidden port open (same in both files)"
mk "$tmp/off-443.gnmap" "443/open/tcp////, $CTRL" "" "${H_DEV[@]}"
mk "$tmp/on-443.gnmap" "443/open/tcp////, $CTRL" "" "${H_DEV[@]}"
assert_fails_with "443 open on LAN IP detected" --rc 1 --match 'FAIL - 443 not open on Mac LAN IP' -- \
  run --vm-off "$tmp/off-443.gnmap" --vm-on "$tmp/on-443.gnmap"

echo "-- reverse DNS name present"
mk "$tmp/on-name.gnmap" "$CTRL" "some-laptop" "${H_DEV[@]}"
assert_fails_with "reverse-DNS name detected" --rc 1 --match 'FAIL - no reverse-DNS names in scan \(on-name.gnmap\)' -- \
  run --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on-name.gnmap"

echo "-- missing headers"
mk "$tmp/on-nohdr.gnmap" "$CTRL" ""
assert_fails_with "missing headers detected" --rc 1 --match 'FAIL - header scanner present \(on-nohdr.gnmap\)' -- \
  run --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on-nohdr.gnmap"

echo "-- control port missing (filtered): scan is invalid"
mk "$tmp/off-filt.gnmap" "18090/filtered/tcp////" "" "${H_DEV[@]}"
assert_fails_with "filtered control port invalidates the scan" --rc 1 --match 'FAIL - vm-off scan sees control port 18090 open' -- \
  run --vm-off "$tmp/off-filt.gnmap" --vm-on "$tmp/on.gnmap"

echo "-- incomplete scan"
grep -v '^# Nmap done' "$tmp/on.gnmap" >"$tmp/on-trunc.gnmap"
assert_fails_with "unfinished scan detected" --rc 1 --match 'FAIL - scan finished \(on-trunc.gnmap\)' -- \
  run --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on-trunc.gnmap"

echo "-- docker without limitation sentence"
H_DOCK=("# scanner: docker" "# control-port: 18090" "# firewall-state: disabled" "# firewall-allowance: no")
mk "$tmp/doff.gnmap" "$CTRL" "" "${H_DOCK[@]}"
mk "$tmp/don.gnmap" "$CTRL" "" "${H_DOCK[@]}"
assert_fails_with "docker scan without limitation sentence rejected" --rc 1 --match 'FAIL - docker scan carries the limitation sentence' -- \
  run --vm-off "$tmp/doff.gnmap" --vm-on "$tmp/don.gnmap"
mk "$tmp/doff2.gnmap" "$CTRL" "" "${H_DOCK[@]}" "$LAN_SCAN_DOCKER_LIMITATION"
mk "$tmp/don2.gnmap" "$CTRL" "" "${H_DOCK[@]}" "$LAN_SCAN_DOCKER_LIMITATION"
assert_succeeds "docker scan with limitation sentence passes" -- run --vm-off "$tmp/doff2.gnmap" --vm-on "$tmp/don2.gnmap"

echo "-- firewall state mismatch"
assert_fails_with "header says disabled but firewall is enabled" --rc 1 --match 'FAIL - firewall state matches the evidence header' -- \
  env -u ASSERT_STATE FW_STATE_TEXT="Firewall is enabled. (State = 1)" bash "$SCRIPT" --ssh-port 60022 --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on.gnmap"

echo "-- firewall allowance yes"
H_ALLOW=("# scanner: device" "# control-port: 18090" "# firewall-state: enabled" "# firewall-allowance: yes" "# firewall-python: /opt/example/python3")
mk "$tmp/aoff.gnmap" "$CTRL" "" "${H_ALLOW[@]}"
mk "$tmp/aon.gnmap" "$CTRL" "" "${H_ALLOW[@]}"
assert_succeeds "allowance removed passes" -- \
  env -u ASSERT_STATE FW_STATE_TEXT="Firewall is enabled. (State = 1)" bash "$SCRIPT" --ssh-port 60022 --vm-off "$tmp/aoff.gnmap" --vm-on "$tmp/aon.gnmap"
echo "1 : /opt/example/python3 (Allow incoming connections)" >"$tmp/apps-leftover"
assert_fails_with "python still listed in firewall rejected" --rc 1 --match 'FAIL - temporary python firewall allowance removed' -- \
  env -u ASSERT_STATE FW_STATE_TEXT="Firewall is enabled. (State = 1)" FW_APPS_FILE="$tmp/apps-leftover" bash "$SCRIPT" --ssh-port 60022 --vm-off "$tmp/aoff.gnmap" --vm-on "$tmp/aon.gnmap"

echo "-- usage errors"
assert_fails_with "missing --vm-on is a usage error" --rc 2 --match '^usage:' -- env -u ASSERT_STATE bash "$SCRIPT" --vm-off "$tmp/off.gnmap"

assert_summary
