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
