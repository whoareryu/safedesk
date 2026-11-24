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
assert_fails_with "missing gnmap file is an error" --rc 2 --match '^open_tcp_ports: cannot read ' -- \
  open_tcp_ports "$FX/does-not-exist.gnmap"
assert_summary
