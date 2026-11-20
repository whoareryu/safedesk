#!/usr/bin/env bash
# pre-commit hook: fail if a non-public value from config/cluster.env appears in
# staged added lines. Skips HOST_* and K3S_VERSION (public by design).
# Never prints the value, only the variable name. bash 3.2 compatible.
set -u

root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
envfile="$root/config/cluster.env"
[ -f "$envfile" ] || exit 0

added="$(git diff --cached -U0 --no-color | grep '^+' | grep -v '^+++' || true)"
[ -n "$added" ] || exit 0

rc=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '' | '#'* | ' '*'#'*) continue ;;
  esac
  line="${line#export }"
  name="${line%%=*}"
  value="${line#*=}"
  [ "$name" != "$line" ] || continue
  case "$name" in
    HOST_* | K3S_VERSION) continue ;;
    *[!A-Za-z0-9_]* | '') continue ;;
  esac
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  [ -n "$value" ] || continue
  if printf '%s\n' "$added" | grep -F -q -e "$value"; then
    echo "check-cluster-values: value of $name from config/cluster.env appears in staged changes (value not shown)" >&2
    rc=1
  fi
done <"$envfile"
exit "$rc"
