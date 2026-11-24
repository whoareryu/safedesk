#!/usr/bin/env bash
# Runs INSIDE the Ubuntu VM (copied there by vm_run). Checks the VM shape.
set -uo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/m1-host.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

assert_eq "aarch64" "$(uname -m)" "arch is aarch64"
assert_eq "2" "$(nproc)" "2 CPUs"

mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
mem_ok=0
# 11 GiB = 11534336 kB, 12.5 GiB = 13107200 kB
if [ -n "$mem_kb" ] && [ "$mem_kb" -ge 11534336 ] && [ "$mem_kb" -le 13107200 ]; then mem_ok=1; fi
assert_eq "1" "$mem_ok" "MemTotal between 11 and 12.5 GiB (got ${mem_kb:-none} kB)"

# shellcheck disable=SC1091
ver="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
assert_eq "24.04" "$ver" "Ubuntu 24.04"

root_kb="$(df -Pk / | awk 'NR==2 {print $2}')"
root_ok=0
# <= 100 GiB = 104857600 kB
if [ -n "$root_kb" ] && [ "$root_kb" -gt 0 ] && [ "$root_kb" -le 104857600 ]; then root_ok=1; fi
assert_eq "1" "$root_ok" "root FS <= 100 GiB (got ${root_kb:-none} kB)"

# No Mac share mounts. findmnt rc 1 means both "none" and "error", so capture
# first, assert the capture and non-empty output, then grep directly.
# shellcheck disable=SC2016
assert_succeeds "findmnt capture succeeded" -- \
  sh -c 'findmnt -rn -o FSTYPE >"$1"' _ "$tmp/fs"
assert_succeeds "fs list is not empty (root FS always exists)" -- test -s "$tmp/fs"
assert_fails_with "no Mac share mounts" --rc 1 -- grep -Eqx "virtiofs|9p|fuse\.sshfs" "$tmp/fs"

assert_summary
