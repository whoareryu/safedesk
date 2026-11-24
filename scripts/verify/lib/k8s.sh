#!/usr/bin/env bash
# Mac-side kubectl helpers. Source this file (bash 3.2+). Every call uses the
# repo kubeconfig; set M1_KUBECONFIG to override (tests).

M1_KUBECONFIG="${M1_KUBECONFIG:-$HOME/.kube/secure-ax.kubeconfig}"

# kc <kubectl args...>: kubectl against the secure-ax cluster only.
kc() {
  KUBECONFIG="$M1_KUBECONFIG" kubectl "$@"
}

# node_ip: InternalIP of the (single) node, runtime value, never stored.
node_ip() {
  kc get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
}
