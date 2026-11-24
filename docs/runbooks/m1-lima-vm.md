# M1 runbook: create the Lima VM (manual, on the Mac)

Local-first target (`TARGET=local`). The VM definition is `infra/lima/secure-ax.yaml`.
The instance name comes from `LIMA_INSTANCE` in the gitignored `config/cluster.env`
(example below uses `secure-ax`).

WARNING: the local VM has no host firewall (Q13). Inbound exposure is blocked only by
`networks: []` and the 6443-only `portForwards` list in the definition. Do not edit
either without re-running `scripts/verify/m1-lima.sh`.

## 1. Install and record versions

```sh
brew install lima jq shellcheck
limactl --version
```

Record the `limactl` version in `k8s/VERSIONS.md`. Lima 2.x is required.

## 2. Check the definition before creating anything

```sh
limactl tmpl validate infra/lima/secure-ax.yaml
limactl tmpl copy --embed-all infra/lima/secure-ax.yaml - | grep -E '^(mounts|networks):'
```

Expected: `mounts: []` and `networks: []`. If `mounts:` shows a `location:` entry,
stop: a base template re-added the Mac home mount (see `k8s/VERSIONS.md`).

## 3. Create and start

```sh
export LIMA_INSTANCE=secure-ax        # same value as in config/cluster.env
limactl create --name="$LIMA_INSTANCE" infra/lima/secure-ax.yaml
limactl start "$LIMA_INSTANCE"
```

## 4. Record the image

After the first `limactl create`, record in `k8s/VERSIONS.md` the Ubuntu image URL
and digest Lima actually used (from `limactl list --json "$LIMA_INSTANCE"` or the
create log). Replace the placeholder row.

## 5. Verify

```sh
scripts/verify/m1-lima.sh            # instance config, on the Mac
```

Then run `m1-host.sh` inside the VM through `vm_run` (`scripts/verify/lib/remote.sh`)
and confirm root access works: `vm_run --root` on any script, or
`limactl shell "$LIMA_INSTANCE" -- sudo -n true`.

## Notes

- The repo is not mounted in the VM; scripts are copied to `/tmp/secure-ax/` by `vm_run`.
- Never add `networks`, `mounts` or portForward rules to "fix" connectivity. Ask first.
