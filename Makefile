.PHONY: test-scripts verify-m1 lan-scan lan-scan-guard

test-scripts:
	bash tests/scripts/run.sh

verify-m1:
	@echo "verify-m1 is a placeholder; it is filled in Task 11." >&2
	@exit 1

# Docker fallback for the LAN scan (only when no other real device is available).
# Pinned to Docker Desktop (context desktop-linux); runs the pre-scan guard first.
# make lan-scan OUT=docs/evidence/m1/raw/lan-scan-base-vm-off.gnmap [LAN_SCAN_ARGS="--firewall-state disabled"]
# make lan-scan OUT=... LAN_SCAN_ARGS=--dry-run     (all checks, prints the command, scans nothing)
lan-scan:
	@test -n "$(OUT)" || { echo "usage: make lan-scan OUT=<raw .gnmap path> [LAN_SCAN_ARGS=...]" >&2; exit 2; }
	@scripts/host/lan-scan-docker.sh --out "$(OUT)" $(LAN_SCAN_ARGS)

# Read-only pre-scan guard: fails if any limactl/ssh process (this VM, Colima,
# another Lima instance, an ssh tunnel) holds a non-loopback listener.
lan-scan-guard:
	@scripts/host/lan-scan-docker.sh --check-only
