#!/usr/bin/env bash
# Mac. Compares two nmap -oG scans of the Mac LAN IP taken from ANOTHER device
# on the same LAN (or the Docker fallback): VM off vs VM on (S1 substitute).
#
#   m1-lan-scan.sh --vm-off <gnmap> --vm-on <gnmap> [--control-port 18090]
#                  [--ssh-port <n|none>] [--python-path <path>]
#
# Inputs are the SCRUBBED copies (scrub_evidence with LAN_IP exported), so the
# scan target appears as the literal "Host: <LAN_IP> ()". They carry header
# lines (written by hand or by lan-scan-docker.sh):
#   # scanner: device|docker
#   # control-port: 18090
#   # firewall-state: enabled|disabled
#   # firewall-allowance: yes|no
#   # firewall-python: <path>            (only with allowance yes)
#   # firewall-python-resolved: <path>   (only with allowance yes; realpath)
#   # docker-context: / # docker-runtime: Docker Desktop ...  (scanner docker)
#   # limitation: ...                    (only/required with scanner docker)
# Scan validity: every Host line is "<LAN_IP> ()", the nmap command line has
# -n -Pn -p- (or -p1-65535) -oG, and each Host line accounts for 65535 ports.
# Env overrides (tests): SOCKETFILTERFW.
# Read-only: never changes the firewall and never uses sudo.
# shellcheck disable=SC2016  # sh -c bodies are constants; values travel as positional args
set -uo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(CDPATH='' cd -- "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$REPO/scripts/lib/assert.sh"
# shellcheck source=lib/listeners.sh
. "$HERE/lib/listeners.sh"
# shellcheck source=lib/lan-scan.sh
. "$HERE/lib/lan-scan.sh"

off="" on="" control="18090" ssh_port="" py_override=""
usage() {
  echo "usage: $0 --vm-off <gnmap> --vm-on <gnmap> [--control-port n] [--ssh-port n|none] [--python-path p]" >&2
  exit 2
}
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --vm-off) off="$2" ;;
    --vm-on) on="$2" ;;
    --control-port) control="$2" ;;
    --ssh-port) ssh_port="$2" ;;
    --python-path) py_override="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$off" ] && [ -n "$on" ] || usage
case "$control" in ''|*[!0-9]*) usage ;; esac
fwbin="${SOCKETFILTERFW:-/usr/libexec/ApplicationFirewall/socketfilterfw}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/m1-lan-scan.XXXXXX")"
trap 'rm -rf "$tmp"; rm -f "${ASSERT_STATE:-}"' EXIT

# hdr <file> <key>: value of the first "# key: value" header line.
hdr() { sed -n "s/^# $2: //p" "$1" | head -n 1; }

for f in "$off" "$on"; do
  assert_succeeds "readable and non-empty: $(basename -- "$f")" -- test -s "$f"
done

# Input hygiene
for f in "$off" "$on"; do
  b="$(basename -- "$f")"
  assert_fails_with "no reverse-DNS names in scan ($b)" --rc 1 -- grep -Eq '^Host: [^ ]+ \([^)]' "$f"
  assert_succeeds "header scanner present ($b)" -- grep -Eq '^# scanner: (device|docker)$' "$f"
  assert_succeeds "header control-port present ($b)" -- grep -Eq '^# control-port: [0-9]+$' "$f"
  assert_succeeds "header firewall-state present ($b)" -- grep -Eq '^# firewall-state: (enabled|disabled)$' "$f"
  assert_succeeds "header firewall-allowance present ($b)" -- grep -Eq '^# firewall-allowance: (yes|no)$' "$f"
  if [ "$(hdr "$f" scanner)" = docker ]; then
    assert_succeeds "docker scan carries the limitation sentence ($b)" -- grep -Fxq "$LAN_SCAN_DOCKER_LIMITATION" "$f"
    assert_succeeds "docker scan records its context and runtime ($b)" -- \
      sh -c 'grep -Eq "^# docker-context: [^ ]+$" "$1" && grep -Eq "^# docker-runtime: Docker Desktop " "$1"' _ "$f"
  fi
  # Scan validity: finished scan of exactly the (scrubbed) Mac LAN IP.
  assert_succeeds "scan finished ($b)" -- grep -q '^# Nmap done' "$f"
  assert_succeeds "scan has a Host: <LAN_IP> () line ($b)" -- grep -Eq '^Host: <LAN_IP> \(\)([[:space:]]|$)' "$f"
  grep '^Host: ' "$f" >"$tmp/hosts.txt" 2>/dev/null
  assert_succeeds "Host lines extracted ($b)" -- test -s "$tmp/hosts.txt"
  assert_fails_with "every Host line is <LAN_IP> ($b)" --rc 1 -- grep -Ev '^Host: <LAN_IP> \(\)([[:space:]]|$)' "$tmp/hosts.txt"
  # Full range: the command line asks for every port and nmap accounted for them.
  sed -n 's/^# Nmap .* as: //p' "$f" | head -n 1 >"$tmp/args.txt"
  assert_succeeds "nmap command line recorded ($b)" -- test -s "$tmp/args.txt"
  assert_succeeds "full-range nmap arguments ($b)" -- awk '
    { for (i = 1; i <= NF; i++) {
        if ($i == "-n") n = 1
        if ($i == "-Pn") pn = 1
        if ($i == "-oG") og = 1
        if ($i == "-p-" || $i == "-p1-65535" || ($i == "-p" && $(i + 1) == "1-65535")) p = 1
    } }
    END { exit (n && pn && og && p) ? 0 : 1 }' "$tmp/args.txt"
  assert_succeeds "nmap_port_totals ($b)" -- bash -c '. "$1"; nmap_port_totals "$2" >"$3"' _ "$HERE/lib/listeners.sh" "$f" "$tmp/totals.txt"
  assert_succeeds "port totals present ($b)" -- test -s "$tmp/totals.txt"
  assert_fails_with "all 65535 TCP ports accounted for ($b)" --rc 1 -- grep -vx 65535 "$tmp/totals.txt"
done

for k in scanner control-port firewall-state firewall-allowance; do
  assert_eq "$(hdr "$off" "$k")" "$(hdr "$on" "$k")" "header $k identical in both files"
done
assert_eq "$control" "$(hdr "$off" control-port)" "header control-port equals $control"

# Positive control: the scanner really sees an open port on the Mac.
assert_succeeds "open_tcp_ports (vm off)" -- bash -c '. "$1"; open_tcp_ports "$2" >"$3"' _ "$HERE/lib/listeners.sh" "$off" "$tmp/open-off.txt"
assert_succeeds "open_tcp_ports (vm on)" -- bash -c '. "$1"; open_tcp_ports "$2" >"$3"' _ "$HERE/lib/listeners.sh" "$on" "$tmp/open-on.txt"
assert_succeeds "vm-off scan sees control port $control open" -- grep -Eqx "$control" "$tmp/open-off.txt"
assert_succeeds "vm-on scan sees control port $control open" -- grep -Eqx "$control" "$tmp/open-on.txt"

# Firewall state now vs header, sudo-free read-only commands.
assert_succeeds "firewall state readable" -- sh -c '"$1" --getglobalstate >"$2" 2>&1' _ "$fwbin" "$tmp/fwstate"
cur="$(awk '/^Firewall is/ {print ($3 ~ /^enabled/) ? "enabled" : "disabled"; exit}' "$tmp/fwstate")"
assert_eq "$(hdr "$off" firewall-state)" "$cur" "firewall state matches the evidence header"
allow="$(hdr "$off" firewall-allowance)"
if [ "$cur" = enabled ] && [ "$allow" = no ]; then
  echo "  note - firewall enabled with no python allowance; the control-port positive control above decides"
fi
# expand_user <path>: the header holds /Users/<user>/...; expand it for lookups.
expand_user() {
  case "$1" in /Users/\<user\>/*) printf '%s\n' "$HOME/${1#/Users/<user>/}" ;; *) printf '%s\n' "$1" ;; esac
}
if [ "$allow" = yes ]; then
  py="$(expand_user "${py_override:-$(hdr "$off" firewall-python)}")"
  # The application firewall records the RESOLVED binary (a Homebrew/CLT python3
  # is a symlink into an app bundle), so the resolved path is checked as well.
  pyreal="$(expand_user "$(hdr "$off" firewall-python-resolved)")"
  assert_succeeds "python firewall path known" -- test -n "$py"
  assert_succeeds "resolved python firewall path known" -- test -n "$pyreal"
  assert_succeeds "firewall app list readable" -- sh -c '"$1" --listapps >"$2" 2>&1' _ "$fwbin" "$tmp/fwapps"
  assert_succeeds "firewall app list not empty" -- test -s "$tmp/fwapps"
  assert_fails_with "temporary python firewall allowance removed" --rc 1 -- grep -Fq "$py" "$tmp/fwapps"
  if [ -n "$pyreal" ]; then
    assert_fails_with "temporary python firewall allowance removed (resolved path)" --rc 1 -- grep -Fq "$pyreal" "$tmp/fwapps"
  fi
fi

# The VM must not add any open port on the Mac LAN IP.
assert_succeeds "open ports (vm off) not empty" -- test -s "$tmp/open-off.txt"
assert_succeeds "open ports (vm on) not empty" -- test -s "$tmp/open-on.txt"
assert_succeeds "VM adds no port on Mac LAN IP" -- cmp -s "$tmp/open-off.txt" "$tmp/open-on.txt"

# Explicit negatives, including the Lima SSH port.
if [ -z "$ssh_port" ]; then
  # shellcheck source=../lib/env.sh
  . "$REPO/scripts/lib/env.sh"
  load_env
  assert_succeeds "limactl list --json" -- sh -c 'limactl list --json "$1" >"$2" 2>/dev/null' _ "$LIMA_INSTANCE" "$tmp/inst.json"
  ssh_port="$(jq -r '.sshLocalPort // 0' "$tmp/inst.json" 2>/dev/null)"
  case "$ssh_port" in ''|0|null) ssh_port=none ;; esac
fi
ports="22 80 443 6443 10250 20241"
case "$ssh_port" in none) echo "  note - no Lima SSH local port (vsock SSH); skipping that port" ;; *[!0-9]*) usage ;; *) ports="$ports $ssh_port" ;; esac
for p in $ports; do
  assert_fails_with "$p not open on Mac LAN IP" --rc 1 -- grep -Eqx "$p" "$tmp/open-on.txt"
done

assert_summary
