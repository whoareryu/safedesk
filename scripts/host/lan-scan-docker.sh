#!/usr/bin/env bash
# Mac, FALLBACK ONLY: run the LAN scan from a Docker container (nmap image pinned
# by digest) when no other real device is available. Writes the evidence header
# (including the Docker limitation sentence) followed by the raw nmap -oG output.
# The output still contains the LAN IP: write it to a gitignored raw/ directory,
# then copy it and run scrub_evidence on the copy (see docs/runbooks/m1-lima-vm.md).
#
#   lan-scan-docker.sh --out <file> [--lan-ip <ip>] [--control-port 18090]
#                      [--firewall-state enabled|disabled]
#                      [--firewall-allowance yes|no] [--python-path <path>]
set -uo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../verify/lib/lan-scan.sh
. "$HERE/../verify/lib/lan-scan.sh"

out="" lan_ip="" control="18090" fw_state="" fw_allow="no" py_path=""
usage() {
  echo "usage: $0 --out <file> [--lan-ip ip] [--control-port n] [--firewall-state enabled|disabled] [--firewall-allowance yes|no] [--python-path p]" >&2
  exit 2
}
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --out) out="$2" ;;
    --lan-ip) lan_ip="$2" ;;
    --control-port) control="$2" ;;
    --firewall-state) fw_state="$2" ;;
    --firewall-allowance) fw_allow="$2" ;;
    --python-path) py_path="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$out" ] || usage

if [ -z "$lan_ip" ]; then
  iface="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')"
  [ -n "$iface" ] || { echo "no default-route interface; pass --lan-ip" >&2; exit 1; }
  lan_ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
  [ -n "$lan_ip" ] || { echo "no IPv4 address on the default interface; pass --lan-ip" >&2; exit 1; }
fi
case "$lan_ip" in
  *[!0-9.]*|'') echo "--lan-ip must be a dotted IPv4 address (never a hostname such as host.docker.internal)" >&2; exit 2 ;;
  127.*|0.*|169.254.*) echo "--lan-ip must be the Mac's real LAN address, not loopback/link-local" >&2; exit 2 ;;
esac
if [ -z "$fw_state" ]; then
  fw_state="$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | awk '/^Firewall is/ {print ($3 ~ /^enabled/) ? "enabled" : "disabled"; exit}')"
fi
case "$fw_state" in enabled|disabled) ;; *) echo "firewall state unknown; pass --firewall-state" >&2; exit 2 ;; esac
case "$fw_allow" in yes|no) ;; *) echo "--firewall-allowance must be yes or no" >&2; exit 2 ;; esac
if [ "$fw_allow" = yes ] && [ -z "$py_path" ]; then
  echo "--python-path is required with --firewall-allowance yes" >&2
  exit 2
fi
command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }

mkdir -p "$(dirname -- "$out")" || exit 1
tmp="$(mktemp "${TMPDIR:-/tmp}/lan-scan.XXXXXX")" || exit 1
trap 'rm -f "$tmp"' EXIT
docker run --rm --entrypoint nmap "$LAN_SCAN_NMAP_IMAGE" -n -Pn -p- -T4 -oG - "$lan_ip" >"$tmp" || {
  echo "docker nmap scan failed" >&2
  exit 1
}
[ -s "$tmp" ] || { echo "docker nmap produced no output" >&2; exit 1; }
{
  echo "# scanner: docker"
  echo "# control-port: $control"
  echo "# firewall-state: $fw_state"
  echo "# firewall-allowance: $fw_allow"
  [ -z "$py_path" ] || echo "# firewall-python: $py_path"
  echo "$LAN_SCAN_DOCKER_LIMITATION"
  cat "$tmp"
} >"$out" || exit 1
echo "wrote $out (still contains the LAN IP; scrub a copy before committing)"
