#!/usr/bin/env bash
# Runs on the Mac. Checks the Lima instance CONFIG only (behaviour checks live
# in m1-exposure.sh). JSON paths are Lima 2.2 `limactl list --json` fields:
# top level: status, vmType, cpus, memory, disk (bytes), network (instance
# networks); config (LimaYAML) holds mounts / networks / portForwards, which
# are omitted from the JSON when empty (omitempty), hence the `// []` below.
set -uo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(CDPATH='' cd -- "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$REPO/scripts/lib/assert.sh"
# shellcheck source=../lib/env.sh
. "$REPO/scripts/lib/env.sh"
load_env

tmp="$(mktemp -d "${TMPDIR:-/tmp}/m1-lima.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# shellcheck disable=SC2016
assert_succeeds "limactl list --json $LIMA_INSTANCE" -- \
  sh -c 'limactl list --json "$1" >"$2" 2>"$3"' _ "$LIMA_INSTANCE" "$tmp/inst.json" "$tmp/inst.err"
assert_succeeds "instance JSON is not empty" -- test -s "$tmp/inst.json"
assert_succeeds "instance JSON is valid" -- jq -e . "$tmp/inst.json"

q() { jq -r "$1" "$tmp/inst.json" 2>/dev/null; }

assert_eq "Running" "$(q '.status')" "status Running"
assert_eq "vz" "$(q '.vmType')" "vmType vz"
assert_eq "2" "$(q '.cpus')" "2 CPUs"
assert_eq "12884901888" "$(q '.memory')" "memory 12 GiB"
assert_eq "107374182400" "$(q '.disk')" "disk 100 GiB"
assert_eq "0" "$(q '(.config.mounts // []) | length')" "no mounts"
assert_eq "0" "$(q '(.config.networks // []) | length')" "no extra networks (config)"
assert_eq "0" "$(q '(.network // []) | length')" "no extra networks (instance)"

assert_eq "6443/127.0.0.1/6443/null" \
  "$(q '.config.portForwards[0] | "\(.guestPort)/\(.hostIP)/\(.hostPort)/\(.ignore // null)"')" \
  "rule 1 forwards guest 6443 to 127.0.0.1:6443 (not ignore)"
assert_eq "0.0.0.0/false/any/true" \
  "$(q '.config.portForwards[1] | "\(.guestIP)/\(.guestIPMustBeZero // false)/\(.proto // "any")/\(.ignore)"')" \
  "rule 2 is the catch-all ignore"

# Drift: repo definition vs instance config (portForwards limited to the first
# two rules and to the fields the repo file sets explicitly).
proj='{vmType, cpus, memory, disk, mounts: (.mounts // []), networks: (.networks // []),
  pf: [(.portForwards // [])[0:2][] | {guestPort, hostPort, hostIP, ignore}]}'
# shellcheck disable=SC2016
assert_succeeds "repo definition rendered" -- \
  sh -c 'limactl tmpl yq "$1" ". | @json" >"$2" 2>"$3"' _ "$REPO/infra/lima/secure-ax.yaml" "$tmp/repo.json" "$tmp/repo.err"
assert_succeeds "repo definition JSON is not empty" -- test -s "$tmp/repo.json"
assert_succeeds "repo definition JSON is valid" -- jq -e . "$tmp/repo.json"
jq -S "(if type == \"string\" then fromjson else . end) | $proj" "$tmp/repo.json" >"$tmp/repo.norm" 2>/dev/null
jq -S ".config | $proj" "$tmp/inst.json" >"$tmp/inst.norm" 2>/dev/null
assert_succeeds "repo normalized form is not empty" -- test -s "$tmp/repo.norm"
assert_succeeds "instance normalized form is not empty" -- test -s "$tmp/inst.norm"
assert_succeeds "no drift between infra/lima/secure-ax.yaml and the instance" -- \
  cmp -s "$tmp/repo.norm" "$tmp/inst.norm"

assert_summary
