# Future: OCI VM (TARGET=oci)

**Unverified, not executed.** Before moving to OCI, introduce a host firewall BEFORE
opening any inbound port (Q13). The local Lima VM has no host firewall and relies only on
`networks: []` and the 6443-only forward; an OCI VM with a public IP has neither.

Moved from the original M1 plan (`docs/superpowers/plans/2026-11-11-m1-infra-foundation.md`,
Tasks 2 and 3). Details there may need updating for the Cloudflare Tunnel design.

## Cost guardrails (CG1-CG4, parked until TARGET=oci)

- CG1: no upgrade to pay-as-you-go; only shapes marked "Always Free eligible".
- CG2: budget alert of 1 USD.
- CG3: no OCI Load Balancer, no extra reserved public IP, no resources outside the home region.
- CG4: block volumes total 200 GB or less, 5 backups or fewer.

## VM creation

1. Sign up for Free Tier.
2. Confirm the home region.
3. Create the 1 USD budget alert (CG2).
4. Create a public subnet with the VCN wizard.
5. Security List ingress: TCP 22 (temporary), 80, 443 only.
6. Ampere A1 Flex, 2 OCPU / 12 GB, Ubuntu 24.04 aarch64, 100 GB boot volume,
   "Always Free eligible" shown.
7. Register your SSH public key.
8. On "Out of capacity", retry another availability domain; if it keeps failing, use the
   local target (`k8s/overlays/local`).
9. Check the fallback console connection works.

Host check: `scripts/verify/m1-host.sh` (arch aarch64, 2 CPUs, 11-12.5 GiB RAM, Ubuntu 24.04,
root FS at most 100 GiB).

Cost evidence: save screenshots of the instance shape (Always Free), budget alert and
block volume totals under `docs/cost/`, with public IP, email and tenancy OCID masked.

## Host firewall (from the old Task 3, introduce first)

- Only TCP 80 and 443 open externally, enforced in both OCI Security List/NSG and host
  iptables (nftables is fine). Insert ACCEPT for 80/443 before the OCI default REJECT rule
  and persist it (`netfilter-persistent save`).
- sshd hardening: `PasswordAuthentication no`, `PermitRootLogin no`,
  `KbdInteractiveAuthentication no`; enable `unattended-upgrades`.
- Tailscale for SSH and the K3s API (6443 only via the Tailscale address,
  `--tls-san <tailscale IPv4>`); auth key passed as an argument at run time, never stored.
- Close public 22 only after `tailscale ssh` is confirmed from another terminal
  (guard: `tailscale status` Online and `CONFIRM_TS_SSH=yes`), then remove the Security List
  rule for 22.
- Verify from outside with `nmap -n -Pn -p-`: open ports must equal `80 443` (or none before
  Traefik is up). Re-running the bootstrap must not duplicate iptables rules.
