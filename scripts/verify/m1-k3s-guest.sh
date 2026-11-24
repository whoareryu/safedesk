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
enc="$(mktemp /tmp/secure-ax-k3s-enc.XXXXXX)"
trap 'rm -f "$enc" "${ASSERT_STATE:-}"' EXIT
assert_succeeds "k3s secrets-encrypt status captured" -- \
  sh -c '/usr/local/bin/k3s secrets-encrypt status >"$1" 2>&1' _ "$enc"
assert_succeeds "encryption status output not empty" -- test -s "$enc"
assert_succeeds "Encryption Status: Enabled" -- grep -Eq '^Encryption Status: Enabled' "$enc"
assert_eq "600" "$(stat -c %a /etc/rancher/k3s/k3s.yaml 2>/dev/null)" "/etc/rancher/k3s/k3s.yaml mode 600"
assert_eq "root" "$(stat -c %U /etc/rancher/k3s/k3s.yaml 2>/dev/null)" "/etc/rancher/k3s/k3s.yaml owned by root"
assert_succeeds "k3s service active" -- systemctl is-active --quiet k3s

# Positive control for the Mac-side "not forwarded" checks: Traefik really
# answers on 80/443 in the guest (ServiceLB uses iptables DNAT, no socket, so
# ss cannot show it). 404 = Traefik with no routes.
for target in http://127.0.0.1:80/ https://127.0.0.1:443/ ; do
  assert_succeeds "guest answers $target" -- \
    sh -c 'curl -sk --max-time 5 -o /dev/null -w "%{http_code}" "$1" >"$2"' _ "$target" "$enc"
  assert_eq "404" "$(cat "$enc")" "traefik 404 on guest $target"
done
node_ip="$(/usr/local/bin/k3s kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
assert_succeeds "node InternalIP known" -- test -n "$node_ip"
for target in "http://$node_ip:80/" "https://$node_ip:443/" ; do
  assert_succeeds "guest answers node-IP listener" -- \
    sh -c 'curl -sk --max-time 5 -o /dev/null -w "%{http_code}" "$1" >"$2"' _ "$target" "$enc"
  assert_eq "404" "$(cat "$enc")" "traefik 404 on guest node-IP port ${target##*:}"
done
assert_eq "LoadBalancer" "$(/usr/local/bin/k3s kubectl -n kube-system get svc traefik -o jsonpath='{.spec.type}' 2>/dev/null)" "traefik Service is LoadBalancer"
assert_succeeds "traefik Service has an ingress address" -- \
  sh -c 'test -n "$(/usr/local/bin/k3s kubectl -n kube-system get svc traefik -o jsonpath="{.status.loadBalancer.ingress[0].ip}")"'
assert_summary
