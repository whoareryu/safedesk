.PHONY: test-scripts verify-m1 lan-scan

test-scripts:
	bash tests/scripts/run.sh

verify-m1:
	@echo "verify-m1 is a placeholder; it is filled in Task 11." >&2
	@exit 1

# Docker fallback for the LAN scan (only when no other real device is available).
# make lan-scan OUT=docs/evidence/m1/raw/lan-scan-base-vm-off.gnmap [LAN_SCAN_ARGS="--firewall-state disabled"]
lan-scan:
	@test -n "$(OUT)" || { echo "usage: make lan-scan OUT=<raw .gnmap path> [LAN_SCAN_ARGS=...]" >&2; exit 2; }
	@scripts/host/lan-scan-docker.sh --out "$(OUT)" $(LAN_SCAN_ARGS)
