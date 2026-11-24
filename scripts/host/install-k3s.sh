#!/usr/bin/env bash
# VM-side. Installs K3s at a pinned version. Run as root inside the VM:
#   vm_run --root scripts/host/install-k3s.sh <K3S_VERSION>     (e.g. v1.36.6+k3s1)
#
# Supply chain: the official install.sh is downloaded from the k3s-io/k3s
# repository at the tag equal to K3S_VERSION and refused unless its sha256
# equals INSTALL_SH_SHA256 below (recorded in k8s/VERSIONS.md). install.sh then
# downloads the k3s binary and verifies it against the release's
# sha256sum-<arch>.txt (verify_binary in install.sh; mismatch is fatal).
# Same version already installed: skip (idempotent). No Lima/OCI branch.
# Never prints the node token or kubeconfig.
set -euo pipefail

# sha256 of install.sh at tag v1.36.6+k3s1. Bump together with K3S_VERSION.
INSTALL_SH_TAG="v1.36.6+k3s1"
INSTALL_SH_SHA256="46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad"

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: install-k3s.sh <K3S_VERSION>" >&2
  exit 2
fi
version="$1"
if [ "$(id -u)" -ne 0 ]; then
  echo "install-k3s.sh must run as root (vm_run --root)" >&2
  exit 2
fi
if [ "$version" != "$INSTALL_SH_TAG" ]; then
  echo "refusing: K3S_VERSION $version has no recorded install.sh sha256 (recorded tag: $INSTALL_SH_TAG)." >&2
  echo "Fetch install.sh at the new tag, record its sha256 in this script and k8s/VERSIONS.md." >&2
  exit 1
fi

# Idempotent: same version already installed and the service is up.
if [ -x /usr/local/bin/k3s ]; then
  installed="$(/usr/local/bin/k3s --version 2>/dev/null | sed -n 's/^k3s version \([^ ]*\) .*/\1/p' | head -n 1)"
  if [ "$installed" = "$version" ] && systemctl is-active --quiet k3s; then
    echo "k3s $version already installed and active: skipping"
    exit 0
  fi
fi

work="$(mktemp -d /tmp/secure-ax-k3s-install.XXXXXX)"
trap 'rm -rf "$work"' EXIT
url="https://raw.githubusercontent.com/k3s-io/k3s/${version//+/%2B}/install.sh"
echo "downloading install.sh from tag $version"
curl -fsSL --proto '=https' --tlsv1.2 -o "$work/install.sh" "$url"
actual="$(sha256sum "$work/install.sh" | awk '{print $1}')"
echo "install.sh sha256: $actual"
if [ "$actual" != "$INSTALL_SH_SHA256" ]; then
  echo "REFUSING: install.sh sha256 mismatch (expected $INSTALL_SH_SHA256)" >&2
  exit 1
fi

INSTALL_K3S_VERSION="$version" sh "$work/install.sh" server --secrets-encryption --write-kubeconfig-mode 600

echo "waiting for the node to be Ready"
for _ in $(seq 1 60); do
  if /usr/local/bin/k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; then
    echo "node Ready"
    exit 0
  fi
  sleep 5
done
echo "node did not become Ready within 300s" >&2
exit 1
