#!/usr/bin/env bash
# Run repo scripts inside the Lima VM. Source this file; bash 3.2 compatible.
# Requires load_env to have exported LIMA_INSTANCE. The repo is NOT mounted in
# the VM, so scripts/lib/*.sh and the target script are copied to
# /tmp/secure-ax/ (same relative layout, so `$(dirname)/../lib` still works).
#
#   vm_run [--root] <script path relative to repo root> [args...]
#
# --root runs the script through `sudo -n` (Lima's default user has
# passwordless sudo; a password prompt makes sudo fail with rc 1).
# The remote exit code is returned unchanged.

_REMOTE_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_REMOTE_REPO_ROOT="$(CDPATH='' cd -- "$_REMOTE_LIB_DIR/../../.." && pwd)"
_REMOTE_DEST=/tmp/secure-ax

vm_run() {
  local use_root=0 script rel f
  local libs=()
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
  for f in "$_REMOTE_REPO_ROOT"/scripts/lib/*.sh; do
    libs+=("$f")
  done
  limactl shell --workdir /tmp "$LIMA_INSTANCE" -- \
    sh -c "rm -rf $_REMOTE_DEST && mkdir -p $_REMOTE_DEST/scripts/lib $_REMOTE_DEST/$(dirname -- "$rel")" || return $?
  limactl copy "${libs[@]}" "$LIMA_INSTANCE:$_REMOTE_DEST/scripts/lib/" || return $?
  limactl copy "$_REMOTE_REPO_ROOT/$rel" "$LIMA_INSTANCE:$_REMOTE_DEST/$rel" || return $?
  if [ "$use_root" -eq 1 ]; then
    limactl shell --workdir /tmp "$LIMA_INSTANCE" -- sudo -n bash "$_REMOTE_DEST/$rel" "$@"
  else
    limactl shell --workdir /tmp "$LIMA_INSTANCE" -- bash "$_REMOTE_DEST/$rel" "$@"
  fi
}
