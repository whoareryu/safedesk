#!/usr/bin/env bash
# VM bootstrap (run as root, idempotent): unattended-upgrades, SSH hardening
# drop-in, systemd-timesyncd. No firewall code on purpose (inbound exposure is
# covered by the VM definition, not a host firewall) and nothing Lima-specific.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "bootstrap: must run as root" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# write_if_changed <path> <mode>: stdin becomes the file content; returns 0 if
# the file was (re)written, 1 if it was already identical (left untouched).
write_if_changed() {
  local path="$1" mode="$2" tmp rc=1
  tmp="$(mktemp)"
  cat >"$tmp"
  if [ ! -f "$path" ] || ! cmp -s "$tmp" "$path"; then
    install -m "$mode" -o root -g root "$tmp" "$path"
    rc=0
  fi
  rm -f "$tmp"
  return "$rc"
}

apt-get update -qq
apt-get install -y -qq unattended-upgrades systemd-timesyncd >/dev/null

write_if_changed /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'CONF' || true
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
systemctl enable unattended-upgrades >/dev/null 2>&1
systemctl start unattended-upgrades

ssh_changed=0
if write_if_changed /etc/ssh/sshd_config.d/99-hardening.conf 0644 <<'CONF'; then
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
CONF
  ssh_changed=1
fi
# Reload only when the configuration validates.
if [ "$ssh_changed" -eq 1 ]; then
  if sshd -t; then
    systemctl reload ssh
  else
    echo "bootstrap: sshd -t failed; not reloading ssh" >&2
    exit 1
  fi
fi

systemctl enable systemd-timesyncd >/dev/null 2>&1
systemctl start systemd-timesyncd
timedatectl set-ntp true

echo "bootstrap: done"
