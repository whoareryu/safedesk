#!/usr/bin/env bash
# Run repo scripts inside the Lima VM. Source this file; bash 3.2 compatible.
# Requires load_env to have exported LIMA_INSTANCE. The repo is NOT mounted in
# the VM, so every file in scripts/lib/ and scripts/verify/lib/ plus the target
# script are copied to a fresh per-run directory /tmp/secure-ax.XXXXXX in the
# VM (same relative layout, so `source "$HERE/../lib/x.sh"` paths still work).
# The directory is removed after the run; parallel vm_run calls do not clash.
# Only those two lib directories are copied: a VM-side script that sources
# anything else fails with "No such file" (FAIL, never a false PASS).
#
#   vm_run [--root] <script path relative to repo root> [args...]
#
# --root runs the script through `sudo -n` (Lima's default user has
# passwordless sudo; a password prompt makes sudo fail with rc 1).
# The remote exit code is returned unchanged.

_REMOTE_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_REMOTE_REPO_ROOT="$(CDPATH='' cd -- "$_REMOTE_LIB_DIR/../../.." && pwd)"

# _vm_sh <sh script using $1..> [args...]: run `sh -c` in the VM. The script is a
# constant; values travel as positional parameters (limactl shell quotes each
# argument), so spaces, quotes and $ in them are never interpreted.
_vm_sh() {
  local code="$1"
  shift
  limactl shell --workdir /tmp "$LIMA_INSTANCE" -- sh -c "$code" _ "$@"
}

vm_run() {
  local use_root=0 script rel f dest rc=0 copied=0
  local libs=() verifylibs=()
  if [ "${1:-}" = "--root" ]; then
    use_root=1
    shift
  fi
  if [ "$#" -lt 1 ]; then
    echo "usage: vm_run [--root] <script> [args...]" >&2
    return 2
  fi
  if [ -z "${LIMA_INSTANCE:-}" ]; then
    echo "LIMA_INSTANCE is not set (call load_env first)" >&2
    return 2
  fi
  script="$1"
  shift
  rel="${script#"$_REMOTE_REPO_ROOT"/}"
  if [ ! -f "$_REMOTE_REPO_ROOT/$rel" ]; then
    echo "script not found: $rel" >&2
    return 2
  fi
  for f in "$_REMOTE_REPO_ROOT"/scripts/lib/* ; do
    [ -f "$f" ] && libs+=("$f")
  done
  for f in "$_REMOTE_REPO_ROOT"/scripts/verify/lib/* ; do
    [ -f "$f" ] && verifylibs+=("$f")
  done
  # shellcheck disable=SC2016
  dest="$(_vm_sh 'd=$(mktemp -d /tmp/secure-ax.XXXXXX) && mkdir -p "$d/scripts/lib" "$d/scripts/verify/lib" "$d/$1" && printf "%s\n" "$d"' \
    "$(dirname -- "$rel")" | tail -n 1)" || return $?
  case "$dest" in
    /tmp/secure-ax.??????*) ;;
    *)
      echo "could not create remote directory (got: ${dest:-nothing})" >&2
      return 1
      ;;
  esac
  if limactl copy "${libs[@]}" "$LIMA_INSTANCE:$dest/scripts/lib/" &&
    limactl copy "${verifylibs[@]}" "$LIMA_INSTANCE:$dest/scripts/verify/lib/" &&
    limactl copy "$_REMOTE_REPO_ROOT/$rel" "$LIMA_INSTANCE:$dest/$rel"; then
    copied=1
  else
    rc=$?
  fi
  if [ "$copied" -eq 1 ]; then
    if [ "$use_root" -eq 1 ]; then
      limactl shell --workdir /tmp "$LIMA_INSTANCE" -- sudo -n bash "$dest/$rel" "$@"
    else
      limactl shell --workdir /tmp "$LIMA_INSTANCE" -- bash "$dest/$rel" "$@"
    fi
    rc=$?
  fi
  # shellcheck disable=SC2016
  _vm_sh 'rm -rf "$1" 2>/dev/null || sudo -n rm -rf "$1"' "$dest" >/dev/null 2>&1 || echo "warning: could not remove $dest in the VM" >&2
  return "$rc"
}
