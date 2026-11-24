#!/usr/bin/env bash
# Test scripts/verify/m1-lima.sh (and vm_run) against a FAKE limactl on PATH
# emitting synthetic Lima 2.2 JSON. No VM is created or started.
set -u
ROOT="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/assert.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/m1lima-test.XXXXXX")"
trap 'rm -rf "$tmp"; rm -f "${ASSERT_STATE:-}"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/env" <<'ENV'
TARGET=local
HOST_SAFEDESK=safedesk.example.invalid
HOST_MINISHOP=minishop.example.invalid
HOST_RELAY=relay.example.invalid
CF_ZONE=example.invalid
LIMA_INSTANCE=test-vm
TUNNEL_NAME=test-tunnel
ACME_EMAIL=test@example.invalid
K3S_VERSION=v1.99.0+k3s1
ENV

# Good instance (filled form, as Lima 2.2 prints it).
cat >"$tmp/good.json" <<'JSON'
{"name":"test-vm","status":"Running","vmType":"vz","cpus":2,"memory":12884901888,"disk":107374182400,
 "config":{"vmType":"vz","cpus":2,"memory":"12GiB","disk":"100GiB",
  "ssh":{"localPort":0,"loadDotSSHPubKeys":false,"forwardAgent":false,"forwardX11":false,"forwardX11Trusted":false},
  "portForwards":[
   {"guestIPMustBeZero":false,"guestIP":"127.0.0.1","guestPort":6443,"guestPortRange":[6443,6443],"hostIP":"127.0.0.1","hostPort":6443,"hostPortRange":[6443,6443],"proto":"any"},
   {"guestIPMustBeZero":false,"guestIP":"0.0.0.0","guestPortRange":[1,65535],"hostIP":"127.0.0.1","hostPortRange":[1,65535],"proto":"any","ignore":true}]}}
JSON
jq '.config' "$tmp/good.json" >"$tmp/repo.json"

# Fake limactl: `list --json` prints $FAKE_INST, `tmpl yq` prints $FAKE_REPO;
# everything else is logged (one line per call, args joined by '|') to $FAKE_LOG.
cat >"$tmp/bin/limactl" <<'FAKE'
#!/bin/sh
case "$1" in
  list) cat "$FAKE_INST" ;;
  tmpl) cat "$FAKE_REPO" ;;
  *)
    a=""
    for x in "$@"; do a="$a|$x"; done
    echo "$a" >>"$FAKE_LOG"
    if [ "$1" = shell ] && [ -n "${FAKE_DEST:-}" ]; then
      case " $* " in *" mktemp "*|*mktemp*) echo "$FAKE_DEST" ;; esac
    fi
    exit "${FAKE_RC:-0}"
    ;;
esac
FAKE
chmod +x "$tmp/bin/limactl"
export FAKE_INST="$tmp/inst.json" FAKE_REPO="$tmp/repo.json" FAKE_LOG="$tmp/log"

# run_lima <inst-jq-filter>: run m1-lima.sh against good.json modified by the filter.
run_lima() {
  jq "$1" "$tmp/good.json" >"$tmp/inst.json"
  env -u ASSERT_STATE PATH="$tmp/bin:$PATH" CLUSTER_ENV_FILE="$tmp/env" bash "$ROOT/scripts/verify/m1-lima.sh" 2>&1
}

echo "-- good instance"
out="$(run_lima '.')"
assert_contains "$out" "PASS 23 / FAIL 0" "good instance passes all checks"

echo "-- bad edits"
out="$(run_lima '.config.portForwards[1].guestPortRange=[1,1024]')"
assert_contains "$out" "FAIL - rule 2 is the catch-all ignore for guest ports 1-65535" "rule 2 limited to 1-1024 fails the rule check"
assert_contains "$out" "FAIL - no drift" "rule 2 limited to 1-1024 is reported as drift"

out="$(run_lima '.config.portForwards[0].guestPortRange=[6443,10250] | .config.portForwards[0].hostPortRange=[6443,10250]')"
assert_contains "$out" "FAIL - rule 1 forwards only guest 127.0.0.1:6443" "rule 1 widened to 6443-10250 fails the rule check"
assert_contains "$out" "FAIL - no drift" "rule 1 widened is reported as drift"

out="$(run_lima '.config.portForwards[0].reverse=true')"
assert_contains "$out" "FAIL - rule 1 forwards only" "rule 1 reverse forward fails"
out="$(run_lima '.config.ssh.forwardAgent=true')"
assert_contains "$out" "FAIL - ssh agent is not forwarded" "forwardAgent=true fails"
assert_contains "$out" "FAIL - no drift" "forwardAgent=true is reported as drift"
out="$(run_lima '.config.ssh.forwardX11=true')"
assert_contains "$out" "FAIL - X11 is not forwarded" "forwardX11=true fails"

# Each bad edit must make the SCRIPT itself exit non-zero for the right reason.
jq '.config.portForwards[1].guestPortRange=[1,1024]' "$tmp/good.json" >"$tmp/inst.json"
assert_fails_with "m1-lima.sh rejects rule 2 limited to 1-1024" --rc 1 --match 'FAIL - rule 2 is the catch-all ignore' -- \
  env -u ASSERT_STATE PATH="$tmp/bin:$PATH" CLUSTER_ENV_FILE="$tmp/env" bash "$ROOT/scripts/verify/m1-lima.sh"
jq '.config.portForwards[0].guestPortRange=[6443,10250] | .config.portForwards[0].hostPortRange=[6443,10250]' "$tmp/good.json" >"$tmp/inst.json"
assert_fails_with "m1-lima.sh rejects rule 1 widened to 6443-10250" --rc 1 --match 'FAIL - rule 1 forwards only' -- \
  env -u ASSERT_STATE PATH="$tmp/bin:$PATH" CLUSTER_ENV_FILE="$tmp/env" bash "$ROOT/scripts/verify/m1-lima.sh"

echo "-- vm_run"
awkward="a b'c\"d \$HOME;x"
vmrun() {
  : >"$FAKE_LOG"
  PATH="$tmp/bin:$PATH" LIMA_INSTANCE=test-vm bash -c '. "$1"; shift; vm_run "$@"' _ \
    "$ROOT/scripts/verify/lib/remote.sh" "$@"
}
FAKE_DEST=/tmp/secure-ax.AbC123 vmrun --root scripts/verify/m1-host.sh "$awkward"
rc=$?
assert_eq "0" "$rc" "vm_run rc 0"
log="$(cat "$FAKE_LOG")"
assert_contains "$log" "|sudo|-n|bash|/tmp/secure-ax.AbC123/scripts/verify/m1-host.sh|$awkward" "args with spaces, quotes and \$ reach the VM verbatim"
assert_contains "$log" "/tmp/secure-ax.AbC123/scripts/verify/lib/" "scripts/verify/lib is copied"
assert_contains "$log" "/tmp/secure-ax.AbC123/scripts/lib/" "scripts/lib is copied"
assert_contains "$log" "/tmp/secure-ax.AbC123/scripts/host/" "top-level scripts/host files are copied"
assert_contains "$log" "scripts/host/bootstrap.sh|" "bootstrap.sh is among the host files"
assert_eq "0" "$(printf %s "$log" | grep -c "scripts/host/systemd")" "scripts/host/systemd is not copied"
assert_contains "$log" "|rm -rf \"\$1\"" "per-run directory is removed after the run"
FAKE_DEST=/tmp/secure-ax.AbC123 FAKE_RC=7 vmrun scripts/verify/m1-host.sh
assert_eq "7" "$?" "remote rc is returned unchanged"
# shellcheck disable=SC2016
assert_fails_with "bogus remote dir is refused" --rc 1 --match 'could not create remote directory' -- \
  env FAKE_DEST=/etc PATH="$tmp/bin:$PATH" LIMA_INSTANCE=test-vm bash -c '. "$1"; vm_run scripts/verify/m1-host.sh' _ "$ROOT/scripts/verify/lib/remote.sh"

assert_summary
