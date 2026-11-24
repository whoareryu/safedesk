#!/usr/bin/env bash
# VM-side K3s checks. Run as root inside the VM:
#   vm_run --root scripts/verify/m1-k3s-guest.sh
# Called by m1-k3s.sh. Output never contains token or kubeconfig content.
# shellcheck disable=SC2016  # sh -c bodies are constants; values travel as positional args
set -uo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

assert_eq "0" "$(id -u)" "running as root"
assert_succeeds "k3s binary present" -- test -x /usr/local/bin/k3s
assert_succeeds "k3s secrets-encrypt status captured" -- \
  sh -c '/usr/local/bin/k3s secrets-encrypt status >"$1" 2>&1' _ /tmp/secure-ax-k3s-enc.$$
assert_succeeds "encryption status output not empty" -- test -s /tmp/secure-ax-k3s-enc.$$
assert_succeeds "Encryption Status: Enabled" -- grep -Eq '^Encryption Status: Enabled' /tmp/secure-ax-k3s-enc.$$
rm -f /tmp/secure-ax-k3s-enc.$$
assert_eq "600" "$(stat -c %a /etc/rancher/k3s/k3s.yaml 2>/dev/null)" "/etc/rancher/k3s/k3s.yaml mode 600"
assert_eq "root" "$(stat -c %U /etc/rancher/k3s/k3s.yaml 2>/dev/null)" "/etc/rancher/k3s/k3s.yaml owned by root"
assert_succeeds "k3s service active" -- systemctl is-active --quiet k3s
assert_summary
