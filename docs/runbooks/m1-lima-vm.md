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
limactl tmpl copy --embed-all infra/lima/secure-ax.yaml - | grep -E -A3 '^(mounts|networks):|location:'
```

Expected: exactly `mounts: []` and `networks: []`, and no `location:` line anywhere.
Anything else (a `location:` entry, or a non-empty `mounts:` / `networks:`) means stop:
a base template re-added the Mac home mount (see `k8s/VERSIONS.md`).

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

Then run `m1-host.sh` inside the VM through `vm_run` (`scripts/verify/lib/remote.sh`),
from the repo root, both as the default user and as root:

```sh
bash -c '. scripts/lib/env.sh; load_env; . scripts/verify/lib/remote.sh; vm_run scripts/verify/m1-host.sh && vm_run --root scripts/verify/m1-host.sh'
```

The second call also confirms passwordless sudo (`limactl shell "$LIMA_INSTANCE" -- sudo -n true`).

## Notes

- The repo is not mounted in the VM; `vm_run` copies `scripts/lib/`, `scripts/verify/lib/` and the target script to a per-run `/tmp/secure-ax.XXXXXX` and removes it afterwards.
- Never add `networks`, `mounts` or portForward rules to "fix" connectivity. Ask first.
