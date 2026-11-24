#!/usr/bin/env bash
# Test open_tcp_ports from scripts/verify/lib/listeners.sh.
set -u
ROOT="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/assert.sh"
# shellcheck source=/dev/null
. "$ROOT/scripts/verify/lib/listeners.sh"
FX="$ROOT/tests/scripts/fixtures"

assert_eq "22
6443
18090" "$(open_tcp_ports "$FX/nmap-three-open.gnmap")" "open ports, numeric ascending"
assert_eq "80" "$(open_tcp_ports "$FX/nmap-filtered.gnmap")" \
  "filtered/closed/UDP excluded"
assert_eq "" "$(open_tcp_ports "$FX/nmap-none.gnmap")" "no Ports field -> empty"
assert_eq "22
18090" "$(open_tcp_ports "$FX/nmap-spaces.gnmap")" \
  "fields separated by spaces instead of tabs (editor-expanded) still parse"

# nmap_port_totals: listed entries + 'Ignored State' count per Host line with ports.
assert_eq "65535" "$(nmap_port_totals "$FX/nmap-three-open.gnmap")" "full range: 3 listed + 65532 ignored"
assert_eq "65535" "$(nmap_port_totals "$FX/nmap-spaces.gnmap")" "full range with space separators"
assert_eq "65535" "$(nmap_port_totals "$FX/nmap-none.gnmap")" "only an Ignored State field"
assert_eq "1" "$(nmap_port_totals "$FX/nmap-control-only.gnmap")" "-p 18090 scan covers one port"
assert_fails_with "missing gnmap file is an error (totals)" --rc 2 --match '^nmap_port_totals: cannot read ' -- \
  nmap_port_totals "$FX/does-not-exist.gnmap"
assert_fails_with "missing gnmap file is an error" --rc 2 --match '^open_tcp_ports: cannot read ' -- \
  open_tcp_ports "$FX/does-not-exist.gnmap"
assert_summary
