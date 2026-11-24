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
assert_fails_with "lima_listeners needs exactly one argument" --rc 2 --match '^lima_listeners: usage' -- \
  lima_listeners

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
