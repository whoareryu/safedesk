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
  # This trap replaces assert.sh's own cleanup of its state file.
  rm -f "${ASSERT_STATE:-}"
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
: >"$tmp/expected-tcp.txt"
[ -z "$ssh_port" ] || echo "127.0.0.1:$ssh_port" >>"$tmp/expected-tcp.txt"
if [ "$stage" != base ]; then echo "127.0.0.1:6443" >>"$tmp/expected-tcp.txt"; fi

# --- scope: only processes of THIS Lima instance ------------------------------
# A second Lima user on the Mac (e.g. Colima) also runs limactl/ssh. Scope by
# PID: processes whose command line references this instance's Lima directory
# (hostagent, ssh mux, ...); lima_listeners keeps only rows of those PIDs.
inst_dir="$(jq -r '.dir // empty' "$tmp/inst.json" 2>/dev/null)"
assert_succeeds "instance directory known" -- test -n "$inst_dir"
ps -axww -o pid=,command= >"$tmp/ps.txt" 2>/dev/null
assert_succeeds "ps captured" -- test -s "$tmp/ps.txt"
awk -v d="$inst_dir/" 'index($0, d) > 0 {print $1}' "$tmp/ps.txt" >"$tmp/pids.txt"
assert_succeeds "instance has running processes" -- test -s "$tmp/pids.txt"
# Lima's host agent runs its own DNS resolver on a random 127.0.0.1 TCP port and a
# random 127.0.0.1 UDP port, both logged in ha.stderr.log. Loopback only; they
# are the ONLY extra sockets expected (TCP joins the list above; UDP below).
dns_line() { sed -n "s/.*Start $1 DNS listening on: \(127\.0\.0\.1:[0-9]*\).*/\1/p" "$inst_dir/ha.stderr.log" 2>/dev/null | tail -n 1; }
dns_tcp="$(dns_line tcp)"
dns_udp="$(dns_line udp)"
if [ -n "$dns_tcp" ]; then
  echo "$dns_tcp" >>"$tmp/expected-tcp.txt"
else
  echo "  note - no hostagent TCP DNS listener line in ha.stderr.log; expecting none"
fi
LC_ALL=C sort -u "$tmp/expected-tcp.txt" -o "$tmp/expected-tcp.txt"
: >"$tmp/expected-udp.txt"
if [ -n "$dns_udp" ]; then
  echo "$dns_udp" >"$tmp/expected-udp.txt"
else
  echo "  note - no hostagent UDP DNS listener line in ha.stderr.log; expecting no UDP socket"
fi

# warn_foreign <lsof file> <label>: other limactl/ssh processes' NON-loopback
# listeners (ports only; no addresses, paths or user names). Not judged here,
# but they would distort a LAN scan (see the runbook's pre-scan guard).
warn_foreign() {
  local ports
  lima_listeners "$1" >"$tmp/all-$2.txt" 2>/dev/null || return 0
  lima_listeners "$1" "$tmp/pids.txt" >"$tmp/mine-$2.txt" 2>/dev/null || return 0
  ports="$(LC_ALL=C comm -23 "$tmp/all-$2.txt" "$tmp/mine-$2.txt" | LC_ALL=C awk '
    $0 ~ /^127\./ || $0 ~ /^\[::1\]:/ { next }
    { n = split($0, p, ":"); print p[n] }' | LC_ALL=C sort -n -u | tr '\n' ' ')"
  if [ -n "$ports" ]; then
    echo "  WARN - other limactl/ssh processes (not this instance, e.g. Colima) hold non-loopback $2 listeners on port(s): ${ports% }"
  fi
}

# check_mac_sockets <round>: Mac TCP listeners and UDP sockets of this instance
# equal the expectation exactly, and none is bound off loopback.
check_mac_sockets() {
  local r="$1"
  assert_succeeds "lsof TCP listeners captured ($r)" -- sh -c 'lsof -nP -iTCP -sTCP:LISTEN >"$1" 2>"$2"' _ "$tmp/tcp-$r.txt" "$tmp/tcp-$r.err"
  assert_succeeds "TCP listener list not empty, macOS always has some ($r)" -- test -s "$tmp/tcp-$r.txt"
  assert_succeeds "lima_listeners tcp, this instance ($r)" -- \
    bash -c '. "$1"; lima_listeners "$2" "$3" >"$4"' _ "$HERE/lib/listeners.sh" "$tmp/tcp-$r.txt" "$tmp/pids.txt" "$tmp/lima-tcp-$r.txt"
  assert_eq "$(cat "$tmp/expected-tcp.txt")" "$(cat "$tmp/lima-tcp-$r.txt")" "limactl/ssh TCP listeners equal the $stage expectation ($r)"
  if [ -s "$tmp/lima-tcp-$r.txt" ]; then
    assert_fails_with "no non-loopback limactl listener ($r)" --rc 1 -- grep -Ev '^127\.0\.0\.1:' "$tmp/lima-tcp-$r.txt"
  else
    skip "no limactl listener"
  fi
  assert_succeeds "lsof UDP captured ($r)" -- sh -c 'lsof -nP -iUDP >"$1" 2>"$2"' _ "$tmp/udp-$r.txt" "$tmp/udp-$r.err"
  assert_succeeds "UDP socket list not empty, mDNS etc. ($r)" -- test -s "$tmp/udp-$r.txt"
  # Connected ("a->b") sockets, e.g. the hostagent's outbound NTP/DNS, are dropped
  # by lima_listeners: they only accept datagrams from their peer.
  assert_succeeds "lima_listeners udp, this instance ($r)" -- \
    bash -c '. "$1"; lima_listeners "$2" "$3" >"$4"' _ "$HERE/lib/listeners.sh" "$tmp/udp-$r.txt" "$tmp/pids.txt" "$tmp/lima-udp-$r.txt"
  assert_eq "$(cat "$tmp/expected-udp.txt")" "$(cat "$tmp/lima-udp-$r.txt")" \
    "bound limactl/ssh UDP sockets are exactly the hostagent DNS socket ($r)"
  warn_foreign "$tmp/tcp-$r.txt" TCP
  warn_foreign "$tmp/udp-$r.txt" UDP
}

# --- Mac listeners before the probes -------------------------------------------
check_mac_sockets before

# --- guest IP and Mac LAN IP (needed for the checks and for scrubbing) ---------
assert_succeeds "guest global IPv4 listed" -- _vm_sh 'ip -4 -o addr show scope global >"$1"' /tmp/secure-ax-probe.addr
guest_ip="$(_vm_sh 'awk "{print \$4}" /tmp/secure-ax-probe.addr | head -n 1 | cut -d/ -f1; rm -f /tmp/secure-ax-probe.addr' 2>/dev/null)"
case "$guest_ip" in
  [0-9]*.[0-9]*.[0-9]*.[0-9]*) assert_eq "ok" "ok" "guest IPv4 found" ;;
  *) assert_eq "an IPv4 address" "none" "guest IPv4 found"; guest_ip="" ;;
esac
lan_iface="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')"
lan_ip=""
[ -z "$lan_iface" ] || lan_ip="$(ipconfig getifaddr "$lan_iface" 2>/dev/null || true)"
# scrub_evidence reads these from the environment.
[ -z "$guest_ip" ] || export GUEST_IP="$guest_ip"
[ -z "$lan_ip" ] || export LAN_IP="$lan_ip"

# --- VM listener record (documentation, not a control; taken BEFORE the probes) --
assert_succeeds "guest ss -Hltnu captured" -- sh -c 'limactl shell --workdir /tmp "$1" -- sudo -n ss -Hltnu >"$2" 2>"$3"' _ "$LIMA_INSTANCE" "$tmp/ss.txt" "$tmp/ss.err"
assert_succeeds "guest listener list not empty (sshd)" -- test -s "$tmp/ss.txt"
assert_succeeds "guest IP known before writing evidence" -- test -n "$guest_ip"
mkdir -p "$evdir"
out="$evdir/guest-listeners-$stage.txt"
{
  echo "# Guest listeners (ss -Hltnu), stage: $stage. Recorded for documentation, NOT a control."
  echo "# There is no host firewall in the VM: any non-loopback listener below is hidden from"
  echo "# the Mac and the LAN only by Lima 'networks: []' and the 6443-only port forward with"
  echo "# a catch-all ignore. m1-exposure.sh re-checks both behaviours on every run."
  echo "# Private values are replaced by placeholders (<GUEST_IP>, <IPV6>, ...)."
  guest_listeners "$tmp/ss.txt"
} >"$out"
assert_succeeds "guest listener evidence written" -- test -s "$out"
assert_succeeds "guest listener evidence scrubbed" -- scrub_evidence "$out"
assert_succeeds "guest listener evidence clean" -- "$HERE/check-evidence-clean.sh" "$out"

# --- auto-forward negative check (with positive controls) --------------------
assert_fails_with "Mac has no listener on 18080/18081 before the probe" --rc 1 -- grep -Eq ':(18080|18081)[[:space:]]+\(LISTEN\)' "$tmp/tcp-before.txt"
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
# A forward to an unexpected Mac address/port would show up as a new socket of
# this instance, which the fixed 127.0.0.1:1808x curls above would miss.
check_mac_sockets during-probes

# --- guest IP not reachable from the Mac (the Q13 proof) ---------------------
if [ -n "$guest_ip" ]; then
  assert_succeeds "positive control: guest IP:18080 answers inside the VM" -- \
    _vm_sh 'curl -sS --max-time 5 -o /dev/null "http://$1:18080/"' "$guest_ip"
  assert_fails_with "guest IP not reachable from Mac" --match '^curl: \((7|28)\)' -- \
    curl -sS --max-time 3 "http://$guest_ip:18080/"
fi

# --- Mac LAN IP --------------------------------------------------------------
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
