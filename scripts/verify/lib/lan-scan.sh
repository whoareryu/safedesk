#!/usr/bin/env bash
# Shared constants and helpers for the LAN scan evidence (m1-lan-scan.sh,
# lan-scan-docker.sh). Source this file; bash 3.2 compatible.
# lan_scan_preflight needs lib/listeners.sh (lima_listeners) sourced first.

# Docker fallback scanner image, pinned by the multi-arch index digest of
# docker.io/instrumentisto/nmap:latest (nmap 7.98 at pin time); recorded in
# k8s/VERSIONS.md.
# shellcheck disable=SC2034  # used by the scripts that source this file
LAN_SCAN_NMAP_IMAGE="docker.io/instrumentisto/nmap@sha256:96f6ed194519b62421a1a1c57809e65a7f94d2aa1c8c25676f247e5e148c0827"

# Docker context used for the fallback scan. Pinned: the current context on a
# Mac may be another runtime (e.g. Colima), whose own listeners would distort
# the scan. lan-scan-docker.sh refuses a runtime that is not Docker Desktop.
# shellcheck disable=SC2034
LAN_SCAN_DOCKER_CONTEXT_DEFAULT="desktop-linux"

# Header line that must be present in a docker-scanned evidence file.
# shellcheck disable=SC2034
LAN_SCAN_DOCKER_LIMITATION="# limitation: this scan ran in a Docker container on this Mac (Docker Desktop VM); the packets originated inside the Mac, did not traverse the real LAN path and did not exercise the macOS application firewall"

# lan_scan_preflight <lsof_tcp_listen_file> <lsof_udp_file>
# Read-only pre-scan guard. Fails (rc 1) when ANY limactl/ssh process on the
# Mac (this project's VM, Colima or any other Lima instance, an ssh -L/-D
# tunnel) owns a non-loopback TCP listener or bound UDP socket: such a listener
# would be visible to the scan and hide or fake what the VM adds. Prints only
# the ports, never addresses or process paths. rc 2 on an unreadable input.
lan_scan_preflight() {
  if [ "$#" -ne 2 ]; then
    echo "lan_scan_preflight: usage: lan_scan_preflight <lsof_tcp_file> <lsof_udp_file>" >&2
    return 2
  fi
  local all rc=0
  all="$( { lima_listeners "$1" && lima_listeners "$2"; } )" || return 2
  local bad
  bad="$(printf '%s\n' "$all" | LC_ALL=C awk '
    $0 == "" { next }
    $0 ~ /^127\./ || $0 ~ /^\[::1\]:/ { next }
    { n = split($0, p, ":"); print p[n] }' | LC_ALL=C sort -n -u | tr '\n' ' ')"
  if [ -n "$bad" ]; then
    echo "lan_scan_preflight: limactl/ssh processes hold non-loopback listeners on port(s): ${bad% }" >&2
    echo "lan_scan_preflight: stop them (e.g. colima stop, close ssh -L/-D tunnels) for the whole scan window" >&2
    rc=1
  fi
  return "$rc"
}
