#!/usr/bin/env bash
# Shared constants for the LAN scan evidence (m1-lan-scan.sh, lan-scan-docker.sh).
# Source this file; bash 3.2 compatible.

# Docker fallback scanner image. PROVISIONAL: the user still has to confirm the
# choice. Multi-arch index digest of docker.io/instrumentisto/nmap:latest
# (nmap 7.98 at pin time); the tag is kept only for readability.
# shellcheck disable=SC2034  # used by the scripts that source this file
LAN_SCAN_NMAP_IMAGE="docker.io/instrumentisto/nmap@sha256:96f6ed194519b62421a1a1c57809e65a7f94d2aa1c8c25676f247e5e148c0827"

# Header line that must be present in a docker-scanned evidence file.
# shellcheck disable=SC2034
LAN_SCAN_DOCKER_LIMITATION="# limitation: this scan ran in a Docker container and may have gone through the Docker Desktop VM network, not the real LAN path"
