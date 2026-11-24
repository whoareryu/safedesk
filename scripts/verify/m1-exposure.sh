#!/usr/bin/env bash
# Mac. Proves inbound exposure is zero WITHOUT a host firewall in the VM: the only
# barriers are Lima `networks: []` and the 6443-only port forward (+ catch-all
# ignore). Checks Mac listeners, auto-forward leaks (with positive controls),
# guest IP reachability and the Mac LAN IP.
#
#   m1-exposure.sh [--stage base|k3s|tunnel]     (default base)
#
# Env: M1_STRICT=1 turns every SKIP into a FAIL (used by verify-m1).
#      EVIDENCE_DIR overrides docs/evidence/m1 (tests).
# Temporarily starts python http.servers on guest ports 18080/18081 and removes
# them on exit.
# shellcheck disable=SC2016  # sh -c bodies are constants; values travel as positional args
set -uo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(CDPATH='' cd -- "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$REPO/scripts/lib/assert.sh"
# shellcheck source=../lib/env.sh
. "$REPO/scripts/lib/env.sh"
# shellcheck source=lib/listeners.sh
. "$HERE/lib/listeners.sh"
# shellcheck source=lib/scrub.sh
. "$HERE/lib/scrub.sh"
# shellcheck source=lib/remote.sh
. "$HERE/lib/remote.sh"
load_env

stage=base
if [ "${1:-}" = "--stage" ]; then
  stage="${2:-}"
  shift 2
fi
case "$stage" in base|k3s|tunnel) ;; *) echo "usage: $0 [--stage base|k3s|tunnel]" >&2; exit 2 ;; esac
[ "$#" -eq 0 ] || { echo "usage: $0 [--stage base|k3s|tunnel]" >&2; exit 2; }
evdir="${EVIDENCE_DIR:-$REPO/docs/evidence/m1}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/m1-exposure.XXXXXX")"
PROBE_PORTS="18080 18081"
cleanup() {
  local p
  for p in $PROBE_PORTS; do
    # shellcheck disable=SC2016
    _vm_sh 'f=/tmp/secure-ax-probe.$1.pid; [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; rm -f "$f"; rm -rf /tmp/secure-ax-probe.??????; true' "$p" >/dev/null 2>&1
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

# skip <reason>: loud SKIP; a FAIL under M1_STRICT=1.
skip() {
  if [ "${M1_STRICT:-0}" = 1 ]; then
    assert_eq "no-skip" "SKIP($1)" "strict mode: SKIP($1) counts as FAIL"
  else
    echo "  SKIP($1)"
  fi
}

echo "stage: $stage"

# --- Lima SSH port and expected listeners -----------------------------------
assert_succeeds "limactl list --json" -- sh -c 'limactl list --json "$1" >"$2" 2>"$3"' _ "$LIMA_INSTANCE" "$tmp/inst.json" "$tmp/inst.err"
assert_succeeds "instance JSON valid" -- jq -e . "$tmp/inst.json"
ssh_port="$(jq -r '.sshLocalPort // 0' "$tmp/inst.json" 2>/dev/null)"
case "$ssh_port" in ''|0|null) ssh_port="" ;; esac
: >"$tmp/expected.txt"
[ -z "$ssh_port" ] || echo "127.0.0.1:$ssh_port" >>"$tmp/expected.txt"
if [ "$stage" != base ]; then echo "127.0.0.1:6443" >>"$tmp/expected.txt"; fi
sort -u "$tmp/expected.txt" -o "$tmp/expected.txt"

# --- scope: only processes of THIS Lima instance ------------------------------
# lima_listeners selects by COMMAND (limactl/ssh), so a second Lima user on the Mac
# (e.g. Colima) would be mixed in. Restrict the lsof output to PIDs whose command
# line references this instance's Lima directory (hostagent, ssh mux, ...).
inst_dir="$(jq -r '.dir // empty' "$tmp/inst.json" 2>/dev/null)"
assert_succeeds "instance directory known" -- test -n "$inst_dir"
ps -axww -o pid=,command= >"$tmp/ps.txt" 2>/dev/null
assert_succeeds "ps captured" -- test -s "$tmp/ps.txt"
awk -v d="$inst_dir/" 'index($0, d) > 0 {print $1}' "$tmp/ps.txt" >"$tmp/pids.txt"
assert_succeeds "instance has running processes" -- test -s "$tmp/pids.txt"
# Lima's host agent also runs its own DNS resolver on a random 127.0.0.1 TCP port
# (and a UDP one), logged in ha.stderr.log. Loopback only; it joins the expectation.
dns_tcp="$(sed -n 's/.*Start tcp DNS listening on: \(127\.0\.0\.1:[0-9]*\).*/\1/p' "$inst_dir/ha.stderr.log" 2>/dev/null | tail -n 1)"
if [ -n "$dns_tcp" ]; then
  echo "$dns_tcp" >>"$tmp/expected.txt"
  sort -u "$tmp/expected.txt" -o "$tmp/expected.txt"
else
  echo "  note - no hostagent DNS listener line in ha.stderr.log; expecting none"
fi
# scope_lsof <in> <out>: keep the header line and rows whose PID is in pids.txt.
scope_lsof() {
  awk 'NR==FNR {pid[$1]=1; next} FNR==1 || ($2 in pid)' "$tmp/pids.txt" "$1" >"$2"
}
# note_foreign <lsof file> <label>: other limactl/ssh sockets on the Mac, informational.
note_foreign() {
  local n
  n=$(awk 'NR==FNR {pid[$1]=1; next} FNR>1 && ($1=="limactl" || $1=="ssh") && !($2 in pid)' "$tmp/pids.txt" "$1" | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ]; then
    echo "  note - $n $2 socket row(s) belong to other limactl/ssh processes (not this instance, e.g. another Lima user); not judged here"
  fi
}

# --- Mac TCP listeners -------------------------------------------------------
assert_succeeds "lsof TCP listeners captured" -- sh -c 'lsof -nP -iTCP -sTCP:LISTEN >"$1" 2>"$2"' _ "$tmp/tcp.txt" "$tmp/tcp.err"
assert_succeeds "TCP listener list not empty (macOS always has some)" -- test -s "$tmp/tcp.txt"
scope_lsof "$tmp/tcp.txt" "$tmp/tcp-inst.txt"
note_foreign "$tmp/tcp.txt" TCP
assert_succeeds "lima_listeners (tcp, this instance)" -- bash -c '. "$1"; lima_listeners "$2" >"$3"' _ "$HERE/lib/listeners.sh" "$tmp/tcp-inst.txt" "$tmp/lima-tcp.txt"
# Compare as text; both lists are sorted. File contents are not secret.
assert_eq "$(cat "$tmp/expected.txt")" "$(cat "$tmp/lima-tcp.txt")" "limactl/ssh TCP listeners equal the $stage expectation"

# --- no non-loopback limactl listener ---------------------------------------
if [ -s "$tmp/lima-tcp.txt" ]; then
  assert_fails_with "no non-loopback limactl listener" --rc 1 -- grep -Ev '^127\.0\.0\.1:' "$tmp/lima-tcp.txt"
else
  skip "no limactl listener"
fi

# --- UDP ---------------------------------------------------------------------
assert_succeeds "lsof UDP captured" -- sh -c 'lsof -nP -iUDP >"$1" 2>"$2"' _ "$tmp/udp.txt" "$tmp/udp.err"
assert_succeeds "UDP socket list not empty (mDNS etc.)" -- test -s "$tmp/udp.txt"
scope_lsof "$tmp/udp.txt" "$tmp/udp-inst.txt"
note_foreign "$tmp/udp.txt" UDP
assert_succeeds "lima_listeners (udp, this instance)" -- bash -c '. "$1"; lima_listeners "$2" >"$3"' _ "$HERE/lib/listeners.sh" "$tmp/udp-inst.txt" "$tmp/lima-udp.txt"
# Lima's own hostagent keeps a loopback DNS UDP socket and outbound (connected,
# "a->b") client sockets; neither is an inbound listener. Anything else is a leak:
# a UDP socket bound to a non-loopback address.
grep -Fv -- '->' "$tmp/lima-udp.txt" >"$tmp/lima-udp-bound.txt" || true
if [ -s "$tmp/lima-udp-bound.txt" ]; then
  assert_fails_with "no non-loopback limactl UDP socket" --rc 1 -- grep -Ev '^127\.0\.0\.1:' "$tmp/lima-udp-bound.txt"
else
  echo "  note - no bound limactl UDP socket at all (vacuously no non-loopback one)"
fi

# --- VM listener record (documentation, not a control; taken BEFORE the probes) --
assert_succeeds "guest ss -Hltnu captured" -- sh -c 'limactl shell --workdir /tmp "$1" -- sudo -n ss -Hltnu >"$2" 2>"$3"' _ "$LIMA_INSTANCE" "$tmp/ss.txt" "$tmp/ss.err"
assert_succeeds "guest listener list not empty (sshd)" -- test -s "$tmp/ss.txt"
mkdir -p "$evdir"
out="$evdir/guest-listeners-$stage.txt"
{
  echo "# Guest listeners (ss -Hltnu), stage: $stage. Recorded for documentation, NOT a control."
  echo "# There is no host firewall in the VM: any non-loopback listener below is hidden from"
  echo "# the Mac and the LAN only by Lima 'networks: []' and the 6443-only port forward with"
  echo "# a catch-all ignore. m1-exposure.sh re-checks both behaviours on every run."
  guest_listeners "$tmp/ss.txt"
} >"$out"
assert_succeeds "guest listener evidence written" -- test -s "$out"
scrub_evidence "$out"
assert_succeeds "guest listener evidence scrubbed" -- test -s "$out"


# --- auto-forward negative check (with positive controls) --------------------
assert_fails_with "Mac has no listener on 18080 before the probe" --rc 1 -- grep -Eq ':(18080|18081)[[:space:]]+\(LISTEN\)' "$tmp/tcp.txt"
# The probe servers serve an empty scratch directory, never the VM home.
start_probe() {
  # $1 port, $2 bind address
  _vm_sh 'd=$(mktemp -d /tmp/secure-ax-probe.XXXXXX) && cd "$d" && { nohup python3 -m http.server "$1" --bind "$2" </dev/null >/dev/null 2>&1 & echo $! >/tmp/secure-ax-probe.$1.pid; }' "$1" "$2"
}
assert_succeeds "guest probe 0.0.0.0:18080 started" -- start_probe 18080 0.0.0.0
assert_succeeds "guest probe 127.0.0.1:18081 started" -- start_probe 18081 127.0.0.1
sleep 2
assert_succeeds "positive control: guest 127.0.0.1:18080 answers inside the VM" -- \
  _vm_sh 'curl -sS --max-time 5 -o /dev/null "$1"' http://127.0.0.1:18080/
assert_succeeds "positive control: guest 127.0.0.1:18081 answers inside the VM" -- \
  _vm_sh 'curl -sS --max-time 5 -o /dev/null "$1"' http://127.0.0.1:18081/
sleep 5
assert_fails_with "guest 0.0.0.0:18080 not forwarded" --rc 7 --match '^curl: \(7\)' -- \
  curl -sS --max-time 3 http://127.0.0.1:18080/
assert_fails_with "guest 127.0.0.1:18081 not forwarded" --rc 7 --match '^curl: \(7\)' -- \
  curl -sS --max-time 3 http://127.0.0.1:18081/

# --- guest IP not reachable from the Mac (the Q13 proof) ---------------------
assert_succeeds "guest global IPv4 listed" -- _vm_sh 'ip -4 -o addr show scope global >"$1"' /tmp/secure-ax-probe.addr
guest_ip="$(_vm_sh 'awk "{print \$4}" /tmp/secure-ax-probe.addr | head -n 1 | cut -d/ -f1; rm -f /tmp/secure-ax-probe.addr' 2>/dev/null)"
case "$guest_ip" in
  [0-9]*.[0-9]*.[0-9]*.[0-9]*) assert_eq "ok" "ok" "guest IPv4 found" ;;
  *) assert_eq "an IPv4 address" "none" "guest IPv4 found"; guest_ip="" ;;
esac
if [ -n "$guest_ip" ]; then
  assert_succeeds "positive control: guest IP:18080 answers inside the VM" -- \
    _vm_sh 'curl -sS --max-time 5 -o /dev/null "http://$1:18080/"' "$guest_ip"
  assert_fails_with "guest IP not reachable from Mac" --match '^curl: \((7|28)\)' -- \
    curl -sS --max-time 3 "http://$guest_ip:18080/"
fi

# --- Mac LAN IP --------------------------------------------------------------
lan_iface="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')"
lan_ip=""
[ -z "$lan_iface" ] || lan_ip="$(ipconfig getifaddr "$lan_iface" 2>/dev/null || true)"
if [ -z "$lan_iface" ]; then
  skip "no LAN interface: no default route"
elif [ -z "$lan_ip" ]; then
  skip "no LAN interface: no IPv4 address on $lan_iface"
else
  assert_fails_with "6443 not on Mac LAN IP" --rc 7 --match '^curl: \(7\)' -- \
    curl -sS --max-time 3 -k "https://$lan_ip:6443/"
  assert_fails_with "443 not on Mac LAN IP" --rc 7 --match '^curl: \(7\)' -- \
    curl -sS --max-time 3 -k "https://$lan_ip:443/"
fi

assert_summary
