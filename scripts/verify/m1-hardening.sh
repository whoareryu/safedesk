#!/usr/bin/env bash
# VM-side hardening checks. Run as root inside the VM:
#   vm_run --root scripts/verify/m1-hardening.sh --bootstrap <bootstrap.sh path in the VM>
# vm_run copies only scripts/lib, scripts/verify/lib and this script, so the
# idempotency check needs bootstrap.sh placed in the VM by the caller and given
# via --bootstrap (without it that check FAILS; it is never skipped).
set -uo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

bootstrap=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bootstrap) bootstrap="${2:-}"; shift 2 ;;
    *) echo "usage: m1-hardening.sh [--bootstrap <path>]" >&2; exit 2 ;;
  esac
done

assert_eq "0" "$(id -u)" "running as root"

sshd_out="$(sshd -T 2>&1)" || sshd_out="sshd -T failed: $sshd_out"
for kv in "passwordauthentication no" "permitrootlogin no" "kbdinteractiveauthentication no"; do
  assert_contains $'\n'"$sshd_out"$'\n' $'\n'"$kv"$'\n' "sshd -T: $kv"
done

assert_eq "enabled" "$(systemctl is-enabled unattended-upgrades 2>&1 || true)" "unattended-upgrades enabled"
assert_eq "yes" "$(timedatectl show -p NTPSynchronized --value 2>&1 || true)" "NTP synchronized"

hashes() {
  sha256sum /etc/ssh/sshd_config.d/99-hardening.conf /etc/apt/apt.conf.d/20auto-upgrades 2>&1
}
before="$(hashes)"
if [ -n "$bootstrap" ] && [ -f "$bootstrap" ]; then
  assert_succeeds "bootstrap re-run succeeds" -- bash "$bootstrap"
  after="$(hashes)"
  assert_eq "$before" "$after" "config files identical after bootstrap re-run (sha256)"
else
  assert_succeeds "bootstrap path given and present (--bootstrap)" -- false
fi

assert_summary
