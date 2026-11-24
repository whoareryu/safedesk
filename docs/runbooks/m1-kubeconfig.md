# M1 runbook: kubeconfig on the Mac (K3s API on 127.0.0.1:6443 only)

K3s runs inside the Lima VM (`scripts/host/install-k3s.sh`, run through `vm_run --root`).
The API reaches the Mac only through the Lima forward guest 6443 -> Mac `127.0.0.1:6443`
(Lima `portForwards`, verified by `scripts/verify/m1-lima.sh` and `m1-exposure.sh --stage k3s`).

## 1. Install K3s

```sh
. scripts/lib/env.sh && load_env && . scripts/verify/lib/remote.sh
vm_run --root scripts/host/install-k3s.sh "$K3S_VERSION"
```

The script refuses to run if the downloaded `install.sh` does not match the recorded sha256
(`k8s/VERSIONS.md`), and skips if the same version is already installed.

## 2. Fetch the kubeconfig

```sh
mkdir -p ~/.kube
(umask 077; limactl shell "$LIMA_INSTANCE" sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/secure-ax.kubeconfig)
chmod 600 ~/.kube/secure-ax.kubeconfig
```

The `server:` line is already `https://127.0.0.1:6443`, and the Lima forward connects to that same
address, so nothing is edited. Never print, commit or paste the file (it holds a client key). The repo
gitignores `*.kubeconfig`. Use it as `KUBECONFIG=~/.kube/secure-ax.kubeconfig kubectl ...`.

## 3. Serving certificate SAN

`m1-k3s.sh` checks that the API certificate contains `IP Address:127.0.0.1`. Manual check:

```sh
openssl s_client -connect 127.0.0.1:6443 </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName
```

Result on 2026-11-24 (no `--tls-san` given): DNS `kubernetes`, `kubernetes.default`,
`kubernetes.default.svc`, `kubernetes.default.svc.cluster.local`, the node name, `localhost`; IP
`10.43.0.1` (service IP), `127.0.0.1`, `<GUEST_IP>`, `::1`. So `127.0.0.1` is included by default and
kubectl verifies the certificate without `--insecure-skip-tls-verify`.

## 4. Verify

```sh
scripts/verify/m1-k3s.sh
```

Anonymous requests get 401 (`/version` and `/api/v1/namespaces`). Traefik ports 80/443 are not
forwarded to the Mac (curl rc 7).
