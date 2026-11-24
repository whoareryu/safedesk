# Pinned versions

| Component | Version | Notes |
|---|---|---|
| limactl | 2.2.0 | `limactl --version` |
| cloudflared | 2026.7.3 | built 2026-07-22 |
| Lima base template | `template:_images/ubuntu-24.04` | image definition only, see below |
| Ubuntu image URL + digest | recorded after the user's first `limactl create` (Step 5) | placeholder |

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
informational; the authoritative value is whatever the first `limactl create` uses.

- URL: `https://cloud-images.ubuntu.com/releases/noble/release-20260705/ubuntu-24.04-server-cloudimg-arm64.img`
- Digest: `sha256:7df0201546f75b8bcc1044594c806c35749421ad3c9bc1be2a3ab806cfae39cc`
- Fallback (no digest): `https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img`
