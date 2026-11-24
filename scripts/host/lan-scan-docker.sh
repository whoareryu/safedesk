#!/usr/bin/env bash
# Mac, FALLBACK ONLY: run the LAN scan from a Docker container (nmap image pinned
# by digest) when no other real device is available. Writes the evidence header
# (docker context/runtime, Docker limitation sentence) followed by the raw nmap
# -oG output. The output still contains the LAN IP: write it to a gitignored raw/
# directory, then copy it and run scrub_evidence on the copy (see
# docs/runbooks/m1-lima-vm.md).
#
#   lan-scan-docker.sh --out <file> [--lan-ip <ip>] [--control-port 18090]
#                      [--firewall-state enabled|disabled]
#                      [--firewall-allowance yes|no] [--python-path <path>]
#                      [--dry-run]
#   lan-scan-docker.sh --check-only
#
# Before scanning it always runs the read-only pre-scan guard: it refuses when any
# limactl/ssh process (this VM, Colima, another Lima instance, an ssh -L/-D
# tunnel) owns a non-loopback listener. --check-only runs just that guard (use it
# before a scan from another device too). --dry-run runs every check, prints the
# docker command with the address replaced by <LAN_IP>, and scans nothing.
# The Docker runtime is pinned: context $LAN_SCAN_DOCKER_CONTEXT (default
# desktop-linux), and it must report itself as Docker Desktop.
# Read-only on the Mac: no firewall change, no sudo, no VM start/stop.
set -uo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../verify/lib/listeners.sh
. "$HERE/../verify/lib/listeners.sh"
# shellcheck source=../verify/lib/lan-scan.sh
. "$HERE/../verify/lib/lan-scan.sh"

out="" lan_ip="" control="18090" fw_state="" fw_allow="no" py_path="" dry=0 check_only=0
usage() {
  echo "usage: $0 --out <file> [--lan-ip ip] [--control-port n] [--firewall-state enabled|disabled] [--firewall-allowance yes|no] [--python-path p] [--dry-run]" >&2
  echo "       $0 --check-only" >&2
  exit 2
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift; continue ;;
    --check-only) check_only=1; shift; continue ;;
  esac
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

tmpd="$(mktemp -d "${TMPDIR:-/tmp}/lan-scan.XXXXXX")" || exit 1
trap 'rm -rf "$tmpd"' EXIT

# --- pre-scan guard (read-only) -----------------------------------------------
lsof -nP -iTCP -sTCP:LISTEN >"$tmpd/tcp.txt" 2>/dev/null
[ -s "$tmpd/tcp.txt" ] || { echo "lsof TCP listener list is empty or failed" >&2; exit 1; }
lsof -nP -iUDP >"$tmpd/udp.txt" 2>/dev/null
[ -s "$tmpd/udp.txt" ] || { echo "lsof UDP socket list is empty or failed" >&2; exit 1; }
lan_scan_preflight "$tmpd/tcp.txt" "$tmpd/udp.txt" || exit 1
echo "pre-scan guard: no limactl/ssh process holds a non-loopback listener"
if [ "$check_only" -eq 1 ]; then
  [ -z "$out" ] || usage
  exit 0
fi
[ -n "$out" ] || usage
case "$control" in ''|*[!0-9]*) usage ;; esac

# --- target -------------------------------------------------------------------
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
ifconfig >"$tmpd/ifconfig.txt" 2>/dev/null
grep -Fq "inet $lan_ip " "$tmpd/ifconfig.txt" || {
  echo "--lan-ip is not an address of this Mac (ifconfig); refusing to scan another host" >&2
  exit 2
}

# --- header values --------------------------------------------------------------
if [ -z "$fw_state" ]; then
  fw_state="$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | awk '/^Firewall is/ {print ($3 ~ /^enabled/) ? "enabled" : "disabled"; exit}')"
fi
case "$fw_state" in enabled|disabled) ;; *) echo "firewall state unknown; pass --firewall-state" >&2; exit 2 ;; esac
case "$fw_allow" in yes|no) ;; *) echo "--firewall-allowance must be yes or no" >&2; exit 2 ;; esac
py_real=""
if [ "$fw_allow" = yes ]; then
  [ -n "$py_path" ] || { echo "--python-path is required with --firewall-allowance yes" >&2; exit 2; }
  # The application firewall records the resolved binary; record both paths.
  py_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$py_path" 2>/dev/null)"
  [ -n "$py_real" ] || { echo "cannot resolve --python-path" >&2; exit 2; }
fi
home_rel() { case "$1" in "$HOME"/*) printf '/Users/<user>/%s\n' "${1#"$HOME"/}" ;; *) printf '%s\n' "$1" ;; esac; }

# --- pinned Docker runtime ----------------------------------------------------------
command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }
ctx="${LAN_SCAN_DOCKER_CONTEXT:-$LAN_SCAN_DOCKER_CONTEXT_DEFAULT}"
runtime="$(docker --context "$ctx" info --format '{{.OperatingSystem}} {{.ServerVersion}}' 2>/dev/null)" || runtime=""
case "$runtime" in
  "Docker Desktop "*) ;;
  *) echo "docker context '$ctx' is not a running Docker Desktop (start Docker Desktop; Colima and other runtimes are refused)" >&2; exit 1 ;;
esac
echo "docker context: $ctx ($runtime)"

if [ "$dry" -eq 1 ]; then
  echo "dry run: would run: docker --context $ctx run --rm --entrypoint nmap $LAN_SCAN_NMAP_IMAGE -n -Pn -p- -T4 -oG - <LAN_IP>"
  echo "dry run: would write $out (header: scanner docker, control-port $control, firewall-state $fw_state, firewall-allowance $fw_allow)"
  exit 0
fi

mkdir -p "$(dirname -- "$out")" || exit 1
docker --context "$ctx" run --rm --entrypoint nmap "$LAN_SCAN_NMAP_IMAGE" -n -Pn -p- -T4 -oG - "$lan_ip" >"$tmpd/scan" || {
  echo "docker nmap scan failed" >&2
  exit 1
}
[ -s "$tmpd/scan" ] || { echo "docker nmap produced no output" >&2; exit 1; }
{
  echo "# scanner: docker"
  echo "# control-port: $control"
  echo "# firewall-state: $fw_state"
  echo "# firewall-allowance: $fw_allow"
  [ -z "$py_path" ] || echo "# firewall-python: $(home_rel "$py_path")"
  [ -z "$py_real" ] || echo "# firewall-python-resolved: $(home_rel "$py_real")"
  echo "# docker-context: $ctx"
  echo "# docker-runtime: $runtime"
  echo "# nmap-image: $LAN_SCAN_NMAP_IMAGE"
  echo "$LAN_SCAN_DOCKER_LIMITATION"
  cat "$tmpd/scan"
} >"$out" || exit 1
echo "wrote $out (still contains the LAN IP; scrub a copy before committing)"
