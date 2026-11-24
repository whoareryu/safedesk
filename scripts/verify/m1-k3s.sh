#!/usr/bin/env bash
# Mac. K3s is installed at the pinned version, the API is reachable ONLY on the
# Mac loopback (127.0.0.1:6443), anonymous access is denied, the bundled
# components are Available and Traefik 80/443 are not forwarded to the Mac.
# Needs ~/.kube/secure-ax.kubeconfig (docs/runbooks/m1-kubeconfig.md).
# shellcheck disable=SC2016  # sh -c bodies are constants; values travel as positional args
set -uo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(CDPATH='' cd -- "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$REPO/scripts/lib/assert.sh"
# shellcheck source=../lib/env.sh
. "$REPO/scripts/lib/env.sh"
# shellcheck source=lib/remote.sh
. "$HERE/lib/remote.sh"
# shellcheck source=lib/k8s.sh
. "$HERE/lib/k8s.sh"
load_env

tmp="$(mktemp -d "${TMPDIR:-/tmp}/m1-k3s.XXXXXX")"
trap 'rm -rf "$tmp" "${ASSERT_STATE:-}"' EXIT

# --- kubeconfig ---------------------------------------------------------------
assert_succeeds "kubeconfig exists" -- test -f "$M1_KUBECONFIG"
assert_eq "600" "$(stat -f %Lp "$M1_KUBECONFIG" 2>/dev/null || stat -c %a "$M1_KUBECONFIG" 2>/dev/null)" "kubeconfig mode 600"
assert_succeeds "kubeconfig server is https://127.0.0.1:6443" -- \
  sh -c 'KUBECONFIG="$1" kubectl config view --minify -o jsonpath="{.clusters[0].cluster.server}" >"$2" && test "$(cat "$2")" = "https://127.0.0.1:6443"' _ "$M1_KUBECONFIG" "$tmp/server.txt"

# --- node and version ---------------------------------------------------------
assert_succeeds "kubectl get nodes" -- sh -c 'KUBECONFIG="$1" kubectl --request-timeout=15s get nodes -o json >"$2" 2>"$3"' _ "$M1_KUBECONFIG" "$tmp/nodes.json" "$tmp/nodes.err"
assert_eq "1" "$(jq -r '.items | length' "$tmp/nodes.json" 2>/dev/null)" "exactly one node"
assert_eq "True" "$(jq -r '.items[0].status.conditions[] | select(.type=="Ready") | .status' "$tmp/nodes.json" 2>/dev/null)" "node Ready"
assert_succeeds "kubectl --request-timeout=15s version -o json" -- sh -c 'KUBECONFIG="$1" kubectl version -o json >"$2" 2>"$3"' _ "$M1_KUBECONFIG" "$tmp/version.json" "$tmp/version.err"
assert_eq "$K3S_VERSION" "$(jq -r '.serverVersion.gitVersion' "$tmp/version.json" 2>/dev/null)" "server gitVersion equals K3S_VERSION"

# --- guest-side: encryption, kubeconfig mode ----------------------------------
assert_succeeds "guest: secrets encryption enabled, k3s.yaml 600" -- vm_run --root scripts/verify/m1-k3s-guest.sh

# --- API reachable on the Mac loopback, anonymous denied ----------------------
assert_succeeds "anonymous /version request reaches the API" -- \
  sh -c 'curl -sk --max-time 5 -o /dev/null -w "%{http_code}" https://127.0.0.1:6443/version >"$1"' _ "$tmp/code.txt"
assert_eq "401" "$(cat "$tmp/code.txt" 2>/dev/null)" "anonymous /version is 401"
# kubectl itself prompts for basic-auth credentials on a 401 ("Please enter
# Username"), so the Unauthorized message of the brief never appears; an
# anonymous curl on a real API path is the equivalent request and tool-pinned
# (observed: curl 8.7.1 on the Mac exits 56, not 22, for a 401 under -f).
assert_fails_with "anonymous API request denied" --rc 56 --match '^curl: \(56\) The requested URL returned error: 401' -- \
  curl -sSkf --max-time 5 -o /dev/null https://127.0.0.1:6443/api/v1/namespaces

# --- serving certificate SAN includes 127.0.0.1 -------------------------------
assert_succeeds "serving certificate fetched" -- \
  sh -c 'openssl s_client -connect 127.0.0.1:6443 </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName >"$1"' _ "$tmp/san.txt"
assert_succeeds "SAN output not empty" -- test -s "$tmp/san.txt"
assert_succeeds "certificate SAN contains IP 127.0.0.1" -- grep -Eq 'IP Address:127\.0\.0\.1([^0-9]|$)' "$tmp/san.txt"

# --- bundled components -------------------------------------------------------
# Traefik arrives via a helm-install Job a few seconds after the node is Ready:
# wait for the Deployment object first (kubectl wait fails on NotFound).
wait_deploy() { # <name>
  local i=0
  while [ "$i" -lt 36 ]; do
    kc -n kube-system --request-timeout=15s get "deploy/$1" >/dev/null 2>&1 && break
    sleep 5
    i=$((i + 1))
  done
  kc -n kube-system --request-timeout=15s wait --for=condition=Available "deploy/$1" --timeout=180s
}
for d in traefik metrics-server coredns local-path-provisioner; do
  assert_succeeds "kube-system $d Available" -- wait_deploy "$d"
done

# --- Traefik 80/443 are not forwarded to the Mac ------------------------------
assert_fails_with "traefik 443 not forwarded to Mac" --rc 7 --match '^curl: \(7\)' -- curl -sS --max-time 3 -k https://127.0.0.1:443/
assert_fails_with "traefik 80 not forwarded to Mac" --rc 7 --match '^curl: \(7\)' -- curl -sS --max-time 3 http://127.0.0.1:80/

# --- existing verifiers keep passing (own assert state, no double counting) ----
assert_succeeds "m1-lima.sh PASS" -- env -u ASSERT_STATE "$HERE/m1-lima.sh"
assert_succeeds "m1-exposure.sh --stage k3s PASS" -- env -u ASSERT_STATE "$HERE/m1-exposure.sh" --stage k3s

assert_summary
