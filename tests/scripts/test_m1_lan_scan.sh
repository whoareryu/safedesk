#!/usr/bin/env bash
# Test scripts/verify/m1-lan-scan.sh with synthetic, already-scrubbed gnmap pairs
# (Host: <LAN_IP> ()) and a fake socketfilterfw, plus lan_scan_preflight from
# scripts/verify/lib/lan-scan.sh. No scan is run, nothing touches the firewall.
set -u
ROOT="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/assert.sh"
# shellcheck source=/dev/null
. "$ROOT/scripts/verify/lib/listeners.sh"
# shellcheck source=/dev/null
. "$ROOT/scripts/verify/lib/lan-scan.sh"
SCRIPT="$ROOT/scripts/verify/m1-lan-scan.sh"
FX="$ROOT/tests/scripts/fixtures"

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
# Globals: SCAN_ARGS (nmap command line), SCAN_HOSTS (space-separated targets),
# SCAN_TOTAL (ports accounted for: listed + Ignored State).
SCAN_ARGS_FULL="nmap -n -Pn -p- -T4 -oG x <LAN_IP>"
SCAN_ARGS="$SCAN_ARGS_FULL" SCAN_HOSTS="<LAN_IP>" SCAN_TOTAL=65535
mk() {
  local f="$1" ports="$2" name="$3" listed h host
  shift 3
  listed=$(printf '%s' "$ports" | awk -F, '{print NF}')
  {
    for h in "$@"; do printf '%s\n' "$h"; done
    echo "# Nmap 7.98 scan initiated Mon Jan  1 00:00:00 2026 as: $SCAN_ARGS"
    for host in $SCAN_HOSTS; do
      printf 'Host: %s (%s)\tStatus: Up\n' "$host" "$name"
      printf 'Host: %s (%s)\tPorts: %s\tIgnored State: closed (%s)\n' "$host" "$name" "$ports" "$((SCAN_TOTAL - listed))"
    done
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

echo "-- scan target is not the (scrubbed) Mac LAN IP"
SCAN_HOSTS="192.0.2.99" mk "$tmp/on-wronghost.gnmap" "$CTRL" "" "${H_DEV[@]}"
assert_fails_with "other scan target rejected" --rc 1 --match 'FAIL - every Host line is <LAN_IP> \(on-wronghost.gnmap\)' -- \
  run --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on-wronghost.gnmap"
SCAN_HOSTS="<LAN_IP> 192.0.2.99" mk "$tmp/on-twohosts.gnmap" "$CTRL" "" "${H_DEV[@]}"
assert_fails_with "multi-target scan rejected" --rc 1 --match 'FAIL - every Host line is <LAN_IP> \(on-twohosts.gnmap\)' -- \
  run --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on-twohosts.gnmap"
SCAN_HOSTS="192.0.2.99" mk "$tmp/on-nolan.gnmap" "$CTRL" "" "${H_DEV[@]}"
assert_fails_with "scan without a <LAN_IP> Host line rejected" --rc 1 --match 'FAIL - scan has a Host: <LAN_IP> \(\) line \(on-nolan.gnmap\)' -- \
  run --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on-nolan.gnmap"

echo "-- port range not proven"
SCAN_ARGS="nmap -n -Pn -p 18090 -oG x <LAN_IP>" SCAN_TOTAL=1 mk "$tmp/on-ctrlonly.gnmap" "$CTRL" "" "${H_DEV[@]}"
assert_fails_with "-p 18090 scan rejected (args)" --rc 1 --match 'FAIL - full-range nmap arguments \(on-ctrlonly.gnmap\)' -- \
  run --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on-ctrlonly.gnmap"
assert_fails_with "-p 18090 scan rejected (port count)" --rc 1 --match 'FAIL - all 65535 TCP ports accounted for \(on-ctrlonly.gnmap\)' -- \
  run --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on-ctrlonly.gnmap"
SCAN_TOTAL=1000 mk "$tmp/on-top.gnmap" "$CTRL" "" "${H_DEV[@]}"
assert_fails_with "args claim -p- but only 1000 ports accounted for" --rc 1 --match 'FAIL - all 65535 TCP ports accounted for \(on-top.gnmap\)' -- \
  run --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on-top.gnmap"
SCAN_ARGS="nmap -Pn -p- -T4 -oG x <LAN_IP>" mk "$tmp/on-nodns.gnmap" "$CTRL" "" "${H_DEV[@]}"
assert_fails_with "scan without -n rejected" --rc 1 --match 'FAIL - full-range nmap arguments \(on-nodns.gnmap\)' -- \
  run --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on-nodns.gnmap"
SCAN_ARGS="nmap -n -Pn -p1-65535 -T4 -oG x <LAN_IP>" mk "$tmp/on-p1.gnmap" "$CTRL" "" "${H_DEV[@]}"
assert_succeeds "-p1-65535 is accepted as full range" -- run --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on-p1.gnmap"

echo "-- docker scans"
H_DOCK=("# scanner: docker" "# control-port: 18090" "# firewall-state: disabled" "# firewall-allowance: no")
H_DOCKRT=("# docker-context: desktop-linux" "# docker-runtime: Docker Desktop 0.0.0")
mk "$tmp/doff.gnmap" "$CTRL" "" "${H_DOCK[@]}" "${H_DOCKRT[@]}"
mk "$tmp/don.gnmap" "$CTRL" "" "${H_DOCK[@]}" "${H_DOCKRT[@]}"
assert_fails_with "docker scan without limitation sentence rejected" --rc 1 --match 'FAIL - docker scan carries the limitation sentence' -- \
  run --vm-off "$tmp/doff.gnmap" --vm-on "$tmp/don.gnmap"
mk "$tmp/doff2.gnmap" "$CTRL" "" "${H_DOCK[@]}" "${H_DOCKRT[@]}" "$LAN_SCAN_DOCKER_LIMITATION"
mk "$tmp/don2.gnmap" "$CTRL" "" "${H_DOCK[@]}" "${H_DOCKRT[@]}" "$LAN_SCAN_DOCKER_LIMITATION"
assert_succeeds "docker scan with limitation sentence and runtime passes" -- run --vm-off "$tmp/doff2.gnmap" --vm-on "$tmp/don2.gnmap"
mk "$tmp/don3.gnmap" "$CTRL" "" "${H_DOCK[@]}" "$LAN_SCAN_DOCKER_LIMITATION"
assert_fails_with "docker scan without runtime headers rejected" --rc 1 --match 'FAIL - docker scan records its context and runtime \(don3.gnmap\)' -- \
  run --vm-off "$tmp/doff2.gnmap" --vm-on "$tmp/don3.gnmap"
mk "$tmp/don4.gnmap" "$CTRL" "" "${H_DOCK[@]}" "# docker-context: colima" "# docker-runtime: Ubuntu 24.04" "$LAN_SCAN_DOCKER_LIMITATION"
assert_fails_with "docker scan from a non-Docker-Desktop runtime rejected" --rc 1 --match 'FAIL - docker scan records its context and runtime \(don4.gnmap\)' -- \
  run --vm-off "$tmp/doff2.gnmap" --vm-on "$tmp/don4.gnmap"

echo "-- firewall state mismatch"
assert_fails_with "header says disabled but firewall is enabled" --rc 1 --match 'FAIL - firewall state matches the evidence header' -- \
  env -u ASSERT_STATE FW_STATE_TEXT="Firewall is enabled. (State = 1)" bash "$SCRIPT" --ssh-port 60022 --vm-off "$tmp/off.gnmap" --vm-on "$tmp/on.gnmap"

echo "-- firewall allowance yes"
PYLINK="/opt/example/bin/python3"
PYREAL="/opt/example/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python"
H_ALLOW=("# scanner: device" "# control-port: 18090" "# firewall-state: enabled" "# firewall-allowance: yes"
  "# firewall-python: $PYLINK" "# firewall-python-resolved: $PYREAL")
mk "$tmp/aoff.gnmap" "$CTRL" "" "${H_ALLOW[@]}"
mk "$tmp/aon.gnmap" "$CTRL" "" "${H_ALLOW[@]}"
assert_succeeds "allowance removed passes" -- \
  env -u ASSERT_STATE FW_STATE_TEXT="Firewall is enabled. (State = 1)" bash "$SCRIPT" --ssh-port 60022 --vm-off "$tmp/aoff.gnmap" --vm-on "$tmp/aon.gnmap"
echo "1 : $PYLINK (Allow incoming connections)" >"$tmp/apps-leftover"
assert_fails_with "python (link path) still listed in firewall rejected" --rc 1 --match 'FAIL - temporary python firewall allowance removed' -- \
  env -u ASSERT_STATE FW_STATE_TEXT="Firewall is enabled. (State = 1)" FW_APPS_FILE="$tmp/apps-leftover" bash "$SCRIPT" --ssh-port 60022 --vm-off "$tmp/aoff.gnmap" --vm-on "$tmp/aon.gnmap"
echo "1 : $PYREAL (Allow incoming connections)" >"$tmp/apps-leftover-real"
assert_fails_with "python (resolved path) still listed in firewall rejected" --rc 1 --match 'FAIL - temporary python firewall allowance removed \(resolved path\)' -- \
  env -u ASSERT_STATE FW_STATE_TEXT="Firewall is enabled. (State = 1)" FW_APPS_FILE="$tmp/apps-leftover-real" bash "$SCRIPT" --ssh-port 60022 --vm-off "$tmp/aoff.gnmap" --vm-on "$tmp/aon.gnmap"
H_ALLOW_NORES=("# scanner: device" "# control-port: 18090" "# firewall-state: enabled" "# firewall-allowance: yes" "# firewall-python: $PYLINK")
mk "$tmp/aoff2.gnmap" "$CTRL" "" "${H_ALLOW_NORES[@]}"
mk "$tmp/aon2.gnmap" "$CTRL" "" "${H_ALLOW_NORES[@]}"
assert_fails_with "allowance without the resolved python path rejected" --rc 1 --match 'FAIL - resolved python firewall path known' -- \
  env -u ASSERT_STATE FW_STATE_TEXT="Firewall is enabled. (State = 1)" bash "$SCRIPT" --ssh-port 60022 --vm-off "$tmp/aoff2.gnmap" --vm-on "$tmp/aon2.gnmap"

echo "-- usage errors"
assert_fails_with "missing --vm-on is a usage error" --rc 2 --match '^usage:' -- env -u ASSERT_STATE bash "$SCRIPT" --vm-off "$tmp/off.gnmap"

echo "-- pre-scan guard (lan_scan_preflight)"
assert_succeeds "loopback-only limactl/ssh listeners pass the guard" -- \
  lan_scan_preflight "$FX/lsof-tcp-lima.txt" "$FX/lsof-udp-none.txt"
assert_fails_with "foreign Lima/Colima wildcard listeners fail the guard" --rc 1 \
  --match '^lan_scan_preflight: limactl/ssh processes hold non-loopback listeners on port\(s\): 53 10250$' -- \
  lan_scan_preflight "$FX/lsof-tcp-lima22.txt" "$FX/lsof-udp-lima22.txt"
assert_fails_with "limactl *:443 fails the guard" --rc 1 --match 'on port\(s\): 443$' -- \
  lan_scan_preflight "$FX/lsof-tcp-wildcard.txt" "$FX/lsof-udp-none.txt"
assert_fails_with "limactl UDP *:8125 fails the guard" --rc 1 --match 'on port\(s\): 8125$' -- \
  lan_scan_preflight "$FX/lsof-tcp-none.txt" "$FX/lsof-udp-lima.txt"
assert_fails_with "unreadable lsof file is an error" --rc 2 --match '^lima_listeners: cannot read ' -- \
  lan_scan_preflight "$FX/does-not-exist.txt" "$FX/lsof-udp-none.txt"

assert_summary
