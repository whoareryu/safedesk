#!/usr/bin/env bash
# VM bootstrap (run as root, idempotent): unattended-upgrades, SSH hardening
# drop-in, time sync (chrony if present, else systemd-timesyncd). No firewall
# code on purpose (inbound exposure is covered by the VM definition, not a host
# firewall) and nothing Lima-specific.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "bootstrap: must run as root" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# write_if_changed <path> <mode>: stdin becomes the file content; returns 0 if
# the file was (re)written, 1 if content, mode and owner were already right
# (left untouched). Mode/owner drift is corrected even if content is identical.
write_if_changed() {
  local path="$1" mode="$2" tmp rc=1
  tmp="$(mktemp)"
  cat >"$tmp"
  if [ ! -f "$path" ] || ! cmp -s "$tmp" "$path"; then
    install -m "$mode" -o root -g root "$tmp" "$path" || { rm -f "$tmp"; return 2; }
    rc=0
  elif [ "$(stat -c '%a %U %G' "$path")" != "$(printf '%s root root' "${mode#0}")" ]; then
    install -m "$mode" -o root -g root "$tmp" "$path" || { rm -f "$tmp"; return 2; }
  fi
  rm -f "$tmp"
  return "$rc"
}

# Time sync: an installed/active chrony counts as the time sync service
# (installing systemd-timesyncd would remove it); otherwise use timesyncd.
use_chrony=0
if systemctl is-active --quiet chrony 2>/dev/null || dpkg -s chrony >/dev/null 2>&1; then
  use_chrony=1
fi

apt-get update -qq
apt-get install -y -qq unattended-upgrades >/dev/null
if [ "$use_chrony" -eq 0 ]; then
  apt-get install -y -qq systemd-timesyncd >/dev/null
fi

write_if_changed /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'CONF' || [ "$?" -eq 1 ]
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
systemctl enable unattended-upgrades >/dev/null 2>&1
systemctl start unattended-upgrades

# SSH hardening drop-in. If the result does not validate, put the previous
# file back (or remove the new one) so disk never holds an unvalidated config.
dropin=/etc/ssh/sshd_config.d/99-hardening.conf
backup=""
if [ -f "$dropin" ]; then
  backup="$(mktemp)"
  cp -p "$dropin" "$backup"
fi
rc=0
write_if_changed "$dropin" 0644 <<'CONF' || rc=$?
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
CONF
if [ "$rc" -eq 2 ]; then
  echo "bootstrap: could not write $dropin" >&2
  [ -z "$backup" ] || rm -f "$backup"
  exit 1
fi
if [ "$rc" -eq 0 ]; then
  if sshd -t; then
    systemctl try-reload-or-restart ssh
  else
    if [ -n "$backup" ]; then
      cp -p "$backup" "$dropin"
      echo "bootstrap: sshd -t failed; previous $dropin restored, ssh not reloaded" >&2
    else
      rm -f "$dropin"
      echo "bootstrap: sshd -t failed; new $dropin removed, ssh not reloaded" >&2
    fi
    [ -z "$backup" ] || rm -f "$backup"
    exit 1
  fi
elif ! sshd -t; then
  # Content already in place but the whole config is invalid: do not reload.
  [ -z "$backup" ] || rm -f "$backup"
  echo "bootstrap: sshd -t failed with an unchanged drop-in; ssh not reloaded" >&2
  exit 1
fi
[ -z "$backup" ] || rm -f "$backup"

if [ "$use_chrony" -eq 1 ]; then
  systemctl enable chrony >/dev/null 2>&1 || true
  systemctl start chrony
else
  systemctl enable systemd-timesyncd >/dev/null 2>&1
  systemctl start systemd-timesyncd
  timedatectl set-ntp true
fi

echo "bootstrap: done"
