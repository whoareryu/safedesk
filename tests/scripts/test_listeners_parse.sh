#!/usr/bin/env bash
# Test scripts/verify/lib/listeners.sh (lima_listeners, guest_listeners).
set -u
ROOT="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/assert.sh"
# shellcheck source=/dev/null
. "$ROOT/scripts/verify/lib/listeners.sh"
FX="$ROOT/tests/scripts/fixtures"

# Output is sorted in the C locale: 127.0.0.1:60022 sorts before 127.0.0.1:6443.
assert_eq "127.0.0.1:60022
127.0.0.1:6443" "$(lima_listeners "$FX/lsof-tcp-lima.txt")" \
  "limactl/ssh listeners only, sorted and de-duplicated (rapportd ignored)"
assert_contains "$(lima_listeners "$FX/lsof-tcp-wildcard.txt")" "*:443" \
  "limactl bound to *:443 is reported"
assert_eq "" "$(lima_listeners "$FX/lsof-tcp-none.txt")" "no limactl/ssh listener -> empty"
assert_eq "*:8125
127.0.0.1:5353" "$(lima_listeners "$FX/lsof-udp-lima.txt")" \
  "UDP: only limactl sockets are reported (mDNSResponder ignored)"
assert_eq "" "$(lima_listeners "$FX/lsof-udp-none.txt")" "no limactl UDP socket -> empty"
assert_fails_with "missing lsof file is an error" --rc 2 --match '^lima_listeners: cannot read ' -- \
  lima_listeners "$FX/does-not-exist.txt"
assert_fails_with "lima_listeners needs one or two arguments" --rc 2 --match '^lima_listeners: usage' -- \
  lima_listeners
assert_fails_with "lima_listeners rejects three arguments" --rc 2 --match '^lima_listeners: usage' -- \
  lima_listeners "$FX/lsof-tcp-lima.txt" "$FX/lima22-pids.txt" extra

# --- Lima 2.2 shapes: connected rows, non-LISTEN TCP states, foreign instances ---
# One argument: every limactl/ssh LISTEN row (also foreign ones), never "a->b"
# connected rows or ESTABLISHED/CLOSE_WAIT rows.
assert_eq "*:10250
*:53
127.0.0.1:51233
127.0.0.1:51234
[::1]:6443" "$(lima_listeners "$FX/lsof-tcp-lima22.txt")" \
  "lima 2.2 tcp: LISTEN rows only, connected/ESTABLISHED/CLOSE_WAIT rows dropped"
assert_eq "*:53
127.0.0.1:51300" "$(lima_listeners "$FX/lsof-udp-lima22.txt")" \
  "lima 2.2 udp: connected 'a->b' rows (v4 and v6) dropped, bound sockets kept"
# Two arguments: only rows whose PID is listed in the pid file.
assert_eq "127.0.0.1:51233
127.0.0.1:51234
[::1]:6443" "$(lima_listeners "$FX/lsof-tcp-lima22.txt" "$FX/lima22-pids.txt")" \
  "pid filter keeps only this instance's listeners (foreign *:53 / *:10250 dropped)"
assert_eq "127.0.0.1:51300" "$(lima_listeners "$FX/lsof-udp-lima22.txt" "$FX/lima22-pids.txt")" \
  "pid filter on udp keeps only this instance's bound socket"
assert_eq "" "$(lima_listeners "$FX/lsof-tcp-lima22.txt" "$FX/lima22-pids-empty.txt")" \
  "empty pid file -> empty output"
assert_eq "" "$(lima_listeners "$FX/lsof-tcp-lima.txt" "$FX/lima22-pids.txt")" \
  "pid filter: rows of unlisted PIDs are dropped even when COMMAND is limactl"
assert_fails_with "missing pid file is an error" --rc 2 --match '^lima_listeners: cannot read ' -- \
  lima_listeners "$FX/lsof-tcp-lima22.txt" "$FX/does-not-exist.txt"
# No outbound row leaks a peer address through the parser.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/listeners-test.XXXXXX")"
trap 'rm -rf "$tmp"; rm -f "${ASSERT_STATE:-}"' EXIT
lima_listeners "$FX/lsof-udp-lima22.txt" >"$tmp/udp.out"
assert_succeeds "udp output not empty" -- test -s "$tmp/udp.out"
assert_fails_with "no peer address in udp output" --rc 1 -- grep -Fq -- '->' "$tmp/udp.out"

assert_eq "tcp 0.0.0.0:22
tcp 127.0.0.1:6443
tcp [::]:22
udp 127.0.0.53:53
udp 127.0.0.54:53
udp 192.0.2.15:68" "$(guest_listeners "$FX/ss-guest.txt")" \
  "ss output -> 'proto addr:port', sorted, %iface stripped, de-duplicated"
assert_eq "" "$(guest_listeners "$FX/ss-empty.txt")" "empty ss output -> empty"
assert_fails_with "missing ss file is an error" --rc 2 --match '^guest_listeners: cannot read ' -- \
  guest_listeners "$FX/does-not-exist.txt"
assert_summary
