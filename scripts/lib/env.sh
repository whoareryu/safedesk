#!/usr/bin/env bash
# Load cluster config. Source this file; compatible with bash 3.2 and 5.
# CLUSTER_ENV_FILE overrides the default <repo>/config/cluster.env.

_ENV_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_ENV_REQUIRED_VARS="PUBLIC_IP TS_IP HOST_SAFEDESK HOST_MINISHOP HOST_RELAY ACME_EMAIL K3S_VERSION"

# load_env: source the env file; exit 2 naming any unset, empty or
# whitespace-only required var, or if the file is missing or has a syntax
# error. Only the required vars are exported to child processes.
load_env() {
  local file="${CLUSTER_ENV_FILE:-$_ENV_LIB_DIR/../../config/cluster.env}"
  local v val missing="" had_e src_rc
  if [ ! -f "$file" ]; then
    echo "env file not found: $file" >&2
    exit 2
  fi
  if ! bash -n "$file" 2>/dev/null; then
    echo "env file has a syntax error: $file" >&2
    exit 2
  fi
  for v in $_ENV_REQUIRED_VARS; do unset "$v"; done
  # Source with errexit off so a failing line cannot kill the caller with
  # some other exit code; restore the caller's setting afterwards.
  case $- in *e*) had_e=1 ;; *) had_e=0 ;; esac
  set +e
  # shellcheck disable=SC1090
  . "$file"
  src_rc=$?
  if [ "$had_e" -eq 1 ]; then set -e; fi
  if [ "$src_rc" -ne 0 ]; then
    echo "env file failed to load (rc=$src_rc): $file" >&2
    exit 2
  fi
  for v in $_ENV_REQUIRED_VARS; do
    val="${!v:-}"
    case "$val" in
      *[![:space:]]*) export "${v?}" ;;
      *) missing="$missing $v" ;;
    esac
  done
  if [ -n "$missing" ]; then
    echo "missing required variables:$missing" >&2
    exit 2
  fi
}
