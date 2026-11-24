#!/usr/bin/env bash
# VM-side hardening checks. Run as root inside the VM:
#   vm_run --root scripts/verify/m1-hardening.sh [--bootstrap <path in the VM>]
# vm_run ships scripts/host/ next to this script, so the idempotency check runs
# the repo's bootstrap.sh ($HERE/../host/bootstrap.sh). --bootstrap overrides
# that path; a missing bootstrap.sh makes the check FAIL (never skipped).
set -uo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

bootstrap="$HERE/../host/bootstrap.sh"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bootstrap)
      if [ "$#" -lt 2 ]; then
        echo "usage: m1-hardening.sh [--bootstrap <path>] (missing value)" >&2
        exit 2
      fi
      bootstrap="$2"
      shift 2
      ;;
    *) echo "usage: m1-hardening.sh [--bootstrap <path>]" >&2; exit 2 ;;
  esac
done

assert_eq "0" "$(id -u)" "running as root"

# A non-root login user for Match-aware checks and the live login probe.
probe_user="${SUDO_USER:-}"
[ "$probe_user" != root ] || probe_user=""
[ -n "$probe_user" ] || probe_user="$(getent passwd | awk -F: '$3 >= 500 && $3 < 65534 && $7 !~ /(nologin|false)$/ {print $1; exit}')"
if [ -z "$probe_user" ]; then
  assert_succeeds "found a non-root login user for probes" -- false
  probe_user="nobody"
fi

check_sshd() { # <label> [sshd -T -C spec]
  local out
  if [ -n "${2:-}" ]; then
    out="$(sshd -T -C "$2" 2>&1)" || out="sshd -T failed: $out"
  else
    out="$(sshd -T 2>&1)" || out="sshd -T failed: $out"
  fi
  for kv in "passwordauthentication no" "permitrootlogin no" "kbdinteractiveauthentication no"; do
    assert_contains $'\n'"$out"$'\n' $'\n'"$kv"$'\n' "sshd -T ($1): $kv"
  done
}
check_sshd "global"
check_sshd "user=$probe_user" "user=$probe_user,host=localhost,addr=127.0.0.1"
check_sshd "user=root" "user=root,host=localhost,addr=127.0.0.1"

# Live daemon: password / keyboard-interactive logins must be refused and only
# publickey offered, for a normal user and for root.
for u in "$probe_user" root; do
  assert_fails_with "live sshd refuses password login for $u (publickey only)" --rc 255 \
    --match 'Permission denied \(publickey\)' -- \
    ssh -o BatchMode=yes -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 "$u@127.0.0.1" true
done

assert_eq "enabled" "$(systemctl is-enabled unattended-upgrades 2>&1 || true)" "unattended-upgrades enabled"
for t in apt-daily.timer apt-daily-upgrade.timer; do
  assert_eq "enabled" "$(systemctl is-enabled "$t" 2>&1 || true)" "$t enabled"
done
apt_cfg="$(apt-config dump 2>&1 || true)"
for kv in 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";'; do
  assert_contains $'\n'"$apt_cfg"$'\n' $'\n'"$kv"$'\n' "apt-config dump: $kv"
done
assert_eq "yes" "$(timedatectl show -p NTPSynchronized --value 2>&1 || true)" "NTP synchronized"

hashes() {
  sha256sum /etc/ssh/sshd_config.d/99-hardening.conf /etc/apt/apt.conf.d/20auto-upgrades 2>&1
}
before="$(hashes)"
if [ -f "$bootstrap" ]; then
  assert_succeeds "bootstrap re-run succeeds" -- bash "$bootstrap"
  after="$(hashes)"
  assert_eq "$before" "$after" "config files identical after bootstrap re-run (sha256)"
else
  assert_succeeds "bootstrap.sh present" -- false
fi

assert_summary
