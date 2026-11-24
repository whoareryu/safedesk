# Pinned versions

| Component | Version | Notes |
|---|---|---|
| limactl | 2.2.0 | `limactl --version` |
| cloudflared | 2026.7.3 | built 2026-07-22 |
| Lima base template | `template:_images/ubuntu-24.04` | image definition only, see below |
| Ubuntu 24.04 server image (aarch64) | `release-20260705` | `sha256:7df0201546f75b8bcc1044594c806c35749421ad3c9bc1be2a3ab806cfae39cc`; used by `limactl create` on 2026-11-24 (guest `/etc/cloud/build.info` serial 20260705, kernel 6.8.0-134-generic) |
| nmap scanner image (LAN-scan Docker fallback) | `docker.io/instrumentisto/nmap` (nmap 7.98) | `sha256:96f6ed194519b62421a1a1c57809e65a7f94d2aa1c8c25676f247e5e148c0827` (multi-arch index of `:latest` at pin time, arm64 verified with `nmap --version`); run only through `scripts/host/lan-scan-docker.sh` on Docker Desktop (context `desktop-linux`); constant `LAN_SCAN_NMAP_IMAGE` in `scripts/verify/lib/lan-scan.sh` |

## Why `template:_images/ubuntu-24.04` and not `template:ubuntu-24.04`

`template:ubuntu-24.04` expands (Lima 2.2.0, `limactl tmpl copy template:ubuntu-24.04 -`) to
`base: [template:_images/ubuntu-24.04, template:_default/mounts]`. `_default/mounts` adds a
`location: "~"` mount. With `base: template:ubuntu-24.04` the merged result of
`limactl tmpl copy --embed-all infra/lima/secure-ax.yaml -` contained
`mounts: - location: "~"`, so the child's `mounts: []` did not clear it.
With `base: template:_images/ubuntu-24.04` the merged result has `mounts: []` and
`networks: []`.

## Image the base template currently resolves to (aarch64, server variant)

Seen in `limactl tmpl copy template:_images/ubuntu-24.04 -` on 2026-11-24. This is
informational; the first `limactl create` (2026-11-24) used the digest-pinned entry above, confirmed by the guest build serial.

- URL: `https://cloud-images.ubuntu.com/releases/noble/release-20260705/ubuntu-24.04-server-cloudimg-arm64.img`
- Digest: `sha256:7df0201546f75b8bcc1044594c806c35749421ad3c9bc1be2a3ab806cfae39cc`
- Fallback (no digest): `https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img`

## K3s (installed 2026-11-24)

| Component | Version | Notes |
|---|---|---|
| K3s | `v1.36.6+k3s1` | `K3S_VERSION` in `config/cluster.env`; installed by `scripts/host/install-k3s.sh` with `server --secrets-encryption --write-kubeconfig-mode 600` |
| K3s `install.sh` | tag `v1.36.6+k3s1` of k3s-io/k3s | sha256 `46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad`; constants `INSTALL_SH_TAG` / `INSTALL_SH_SHA256` in `scripts/host/install-k3s.sh` (the script refuses to run on a mismatch) |
| Bundled Traefik chart | `traefik-40.1.7+up40.1.0` | HelmChart `traefik` in `kube-system`; `traefik-crd` chart is the same version |
| Bundled Traefik image | `rancher/mirrored-library-traefik:3.7.15` | from the Deployment spec; digest not pinned yet (Task 6 owns Traefik config) |

### How the `install.sh` sha256 was obtained (2026-11-24)

URL: `https://raw.githubusercontent.com/k3s-io/k3s/v1.36.6%2Bk3s1/install.sh` (37118 bytes).
1. Fetched it twice with curl on the Mac, and once streamed to `shasum -a 256`: identical hash.
2. Cross-checked through a different route, the GitHub contents API at the same tag (`gh api repos/k3s-io/k3s/contents/install.sh?ref=v1.36.6%2Bk3s1`, raw media type): identical hash (git blob `9820742ef7074c24bac8993b3e45a0230dcde123`).
3. The VM downloaded it again at install time and computed the same hash before running it.

The hash anchors only the installer. The installer verifies the k3s binary itself:
`download_hash` fetches the release file `sha256sum-arm64.txt` from github.com/k3s-io/k3s releases and
`verify_binary` aborts (`Download sha256 does not match ...`) if the downloaded `k3s-arm64` differs. Both files come from the same GitHub release, so this
detects corruption and a swapped binary only if the checksum file is not swapped too; it is not an independent signature.
