#!/usr/bin/env bash
# Tests for scripts/lib/assert.sh and scripts/lib/env.sh.
# Each case runs in a child bash; we check exit codes and printed counters.
# shellcheck disable=SC2016  # single-quoted bodies are evaluated by the child bash on purpose
set -u
ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_LIB="$ROOT/scripts/lib/assert.sh"
ENV_LIB="$ROOT/scripts/lib/env.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

T_PASS=0
T_FAIL=0
check_has() { # check_has <msg> <haystack> <needle>
  case "$2" in
    *"$3"*) T_PASS=$((T_PASS + 1)); echo "  ok   - $1" ;;
    *) T_FAIL=$((T_FAIL + 1)); echo "  FAIL - $1 (output lacks '$3': $2)" ;;
  esac
}
check_lacks() { # check_lacks <msg> <haystack> <needle>
  case "$2" in
    *"$3"*) T_FAIL=$((T_FAIL + 1)); echo "  FAIL - $1 (output has '$3')" ;;
    *) T_PASS=$((T_PASS + 1)); echo "  ok   - $1" ;;
  esac
}

# run_case <body>: source assert.sh in a fresh child bash, run body, print rc.
run_case() {
  bash -c ". '$ASSERT_LIB'; $1" 2>&1
  echo "rc=$?"
}
# run_case_strict: same, under the caller-side set -euo pipefail.
run_case_strict() {
  bash -c "set -euo pipefail; . '$ASSERT_LIB'; $1" 2>&1
  echo "rc=$?"
}

if [ ! -f "$ASSERT_LIB" ]; then
  echo "missing $ASSERT_LIB" >&2
  exit 1
fi

CNT='echo "counts=$(assert_counts)"'

# assert_eq
out=$(run_case "assert_eq a a m; $CNT")
check_has "assert_eq equal counts as pass" "$out" "counts=1/0"
out=$(run_case "assert_eq a b m; $CNT")
check_has "assert_eq differing counts as fail" "$out" "counts=0/1"

# assert_contains
out=$(run_case "assert_contains 'hello world' wor m; $CNT")
check_has "assert_contains hit passes" "$out" "counts=1/0"
out=$(run_case "assert_contains hello xyz m; $CNT")
check_has "assert_contains miss fails" "$out" "counts=0/1"
out=$(run_case "assert_contains hello '' m; $CNT")
check_has "assert_contains empty needle fails (M4)" "$out" "counts=0/1"
check_has "assert_contains empty needle says why" "$out" "empty needle"

# assert_fails / assert_succeeds
out=$(run_case "assert_fails x -- false; $CNT")
check_has "assert_fails on false passes" "$out" "counts=1/0"
out=$(run_case "assert_fails x -- true; $CNT")
check_has "assert_fails on true fails" "$out" "counts=0/1"
out=$(run_case "assert_succeeds x -- true; $CNT")
check_has "assert_succeeds on true passes" "$out" "counts=1/0"
out=$(run_case "assert_succeeds x -- false; $CNT")
check_has "assert_succeeds on false fails" "$out" "counts=0/1"

# M12: arguments with spaces survive; form without -- is a usage error
out=$(run_case "assert_succeeds x -- test 'a b' = 'a b'; $CNT")
check_has "assert_succeeds keeps args with spaces" "$out" "counts=1/0"
out=$(run_case "assert_fails x -- test 'a b' = 'a c'; $CNT")
check_has "assert_fails keeps args with spaces" "$out" "counts=1/0"
out=$(run_case "assert_succeeds x true; $CNT")
check_has "assert_succeeds without -- is FAIL" "$out" "counts=0/1"
check_has "missing -- is reported as usage error" "$out" "usage"
out=$(run_case "assert_fails x false; $CNT")
check_has "assert_fails without -- is FAIL" "$out" "counts=0/1"

# I2: empty command, 126/127
out=$(run_case "assert_succeeds x --; $CNT")
check_has "assert_succeeds with empty command fails" "$out" "counts=0/1"
out=$(run_case "assert_fails x --; $CNT")
check_has "assert_fails with empty command fails" "$out" "counts=0/1"
out=$(run_case "assert_fails x -- ''; $CNT")
check_has "assert_fails with empty-string command fails" "$out" "counts=0/1"
out=$(run_case "assert_fails x -- no_such_cmd_xyz_123; $CNT")
check_has "assert_fails on 127 (not found) is FAIL" "$out" "counts=0/1"
check_has "127 failure mentions not runnable" "$out" "not runnable"
out=$(run_case "assert_succeeds x -- no_such_cmd_xyz_123; $CNT")
check_has "assert_succeeds on 127 is FAIL" "$out" "counts=0/1"
: >"$TMP/notexec"
out=$(run_case "assert_fails x -- '$TMP/notexec'; $CNT")
check_has "assert_fails on 126 (not executable) is FAIL" "$out" "counts=0/1"
out=$(run_case "assert_fails x -- sh -c 'exit 3'; $CNT")
check_has "assert_fails on ordinary rc 3 passes" "$out" "counts=1/0"

# I6: strict variants stop at first failing step
FN='f(){ false; echo after; }'
out=$(run_case "$FN; assert_succeeds x -- f; $CNT")
check_has "plain assert_succeeds ignores set -e in functions (documented)" "$out" "counts=1/0"
out=$(run_case "$FN; assert_succeeds_strict x -- f; $CNT")
check_has "assert_succeeds_strict fails a function with a failing step" "$out" "counts=0/1"
check_lacks "strict stops before the step after the failure" "$out" "      | after"
out=$(run_case 'g(){ true; echo ok; }; assert_succeeds_strict x -- g; '"$CNT")
check_has "assert_succeeds_strict passes a clean function" "$out" "counts=1/0"
out=$(run_case "assert_succeeds_strict x -- test 'a b' = 'a b'; $CNT")
check_has "strict keeps args with spaces" "$out" "counts=1/0"
out=$(run_case "assert_succeeds_strict x -- no_such_cmd_xyz_123; $CNT")
check_has "strict on 127 is FAIL" "$out" "counts=0/1"
out=$(run_case "assert_succeeds_strict x; $CNT")
check_has "strict without -- is FAIL" "$out" "counts=0/1"

# assert_fails_with
FW() { run_case "$1; $CNT"; }
out=$(FW "assert_fails_with x --rc 7 -- sh -c 'exit 7'")
check_has "fails_with: right rc passes" "$out" "counts=1/0"
out=$(FW "assert_fails_with x --rc 7 -- sh -c 'exit 3'")
check_has "fails_with: wrong rc fails" "$out" "counts=0/1"
check_has "fails_with: wrong rc shows expected vs actual" "$out" "expected rc=7, got rc=3"
out=$(FW "assert_fails_with x --match 'denied|forbidden' -- sh -c 'echo access denied >&2; exit 1'")
check_has "fails_with: match on stderr passes" "$out" "counts=1/0"
out=$(FW "assert_fails_with x --match 'denied' -- sh -c 'echo something else; exit 1'")
check_has "fails_with: match missing fails" "$out" "counts=0/1"
check_has "fails_with: match failure shows output tail" "$out" "something else"
out=$(FW "assert_fails_with x --rc 7 --match nope -- sh -c 'echo nope; exit 7'")
check_has "fails_with: rc and match both hold passes" "$out" "counts=1/0"
out=$(FW "assert_fails_with x --rc 7 --match nope -- sh -c 'echo other; exit 7'")
check_has "fails_with: rc ok but match missing fails" "$out" "counts=0/1"
out=$(FW "assert_fails_with x --rc 7 --match nope -- sh -c 'echo nope; exit 2'")
check_has "fails_with: match ok but rc wrong fails" "$out" "counts=0/1"
out=$(FW "assert_fails_with x --rc 7 -- true")
check_has "fails_with: success is FAIL" "$out" "counts=0/1"
out=$(FW "assert_fails_with x --match . -- sh -c 'echo hi'")
check_has "fails_with: success with matching output is FAIL" "$out" "counts=0/1"
out=$(FW "assert_fails_with x -- false")
check_has "fails_with: no --rc/--match is FAIL" "$out" "counts=0/1"
check_has "fails_with: no condition is a usage error" "$out" "usage"
out=$(FW "assert_fails_with x --rc 0 -- false")
check_has "fails_with: --rc 0 is FAIL" "$out" "counts=0/1"
out=$(FW "assert_fails_with x --rc abc -- false")
check_has "fails_with: non-numeric --rc is FAIL" "$out" "counts=0/1"
out=$(FW "assert_fails_with x --rc 7 -- no_such_cmd_xyz_123")
check_has "fails_with: 127 with --rc 7 is FAIL" "$out" "counts=0/1"
out=$(FW "assert_fails_with x --rc 127 -- no_such_cmd_xyz_123")
check_has "fails_with: 127 never counts even if expected" "$out" "counts=0/1"
out=$(FW "assert_fails_with x --rc 7")
check_has "fails_with: missing -- is FAIL" "$out" "counts=0/1"
out=$(FW "assert_fails_with x --rc 7 --")
check_has "fails_with: empty command is FAIL" "$out" "counts=0/1"
out=$(FW "assert_fails_with x --bogus 1 -- false")
check_has "fails_with: unknown option is FAIL" "$out" "counts=0/1"
out=$(FW "assert_fails_with x --rc")
check_has "fails_with: --rc without value is FAIL" "$out" "counts=0/1"
out=$(FW "assert_fails_with x --match '' -- false")
check_has "fails_with: empty --match is FAIL" "$out" "counts=0/1"
out=$(FW "assert_fails_with x --rc 7 -- test 'a b' = 'a c'")
check_has "fails_with: args with spaces kept (rc 1 != 7 fails)" "$out" "counts=0/1"
out=$(FW "assert_fails_with x --rc 1 -- test 'a b' = 'a c'")
check_has "fails_with: args with spaces kept (rc 1 passes)" "$out" "counts=1/0"

# Fix round 4 (minor 1): --rc must be an integer 1..255, no junk
for bad in 256 999 1000 99999999999999999999 18446744073709551617 07 007 +7 -7 ' 7' '7 ' 7x x7 '' 0x7 1e2; do
  out=$(FW "assert_fails_with x --rc '$bad' -- sh -c 'exit 7'")
  check_has "fails_with: --rc '$bad' is FAIL" "$out" "counts=0/1"
  check_has "fails_with: --rc '$bad' is a usage error" "$out" "usage: --rc must be an integer 1-255"
done
out=$(FW "assert_fails_with x --rc 99999999999999999999 -- sh -c 'exit 3'")
check_has "fails_with: huge --rc never passes on any non-zero rc" "$out" "counts=0/1"
out=$(FW "assert_fails_with x --rc 255 -- sh -c 'exit 255'")
check_has "fails_with: --rc 255 is accepted" "$out" "counts=1/0"
out=$(FW "assert_fails_with x --rc 1 -- false")
check_has "fails_with: --rc 1 is accepted" "$out" "counts=1/0"
out=$(FW "assert_fails_with x --rc 99 -- sh -c 'exit 99'")
check_has "fails_with: --rc 99 is accepted" "$out" "counts=1/0"

# Fix round 4 (minor 5): duplicate --rc / --match are usage errors
out=$(FW "assert_fails_with x --rc 7 --rc 3 -- sh -c 'exit 3'")
check_has "fails_with: duplicate --rc is FAIL" "$out" "counts=0/1"
check_has "fails_with: duplicate --rc is a usage error" "$out" "usage: duplicate --rc"
out=$(FW "assert_fails_with x --match zzz --match denied -- sh -c 'echo denied; exit 1'")
check_has "fails_with: duplicate --match is FAIL" "$out" "counts=0/1"
check_has "fails_with: duplicate --match is a usage error" "$out" "usage: duplicate --match"
out=$(FW "assert_fails_with x --match denied --rc 1 --match denied -- sh -c 'echo denied; exit 1'")
check_has "fails_with: duplicate --match (same value) is FAIL" "$out" "counts=0/1"

# Fix round 4 (minor 4): no SIGPIPE false FAIL on large output under pipefail
BIG='big(){ echo denied; i=0; while [ $i -lt 2000 ]; do echo AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; i=$((i+1)); done; return 3; }'
out=$(run_case_strict "$BIG; assert_fails_with x --rc 3 --match '^denied' -- big; $CNT")
check_has "fails_with: early match in >64KB output passes under pipefail" "$out" "counts=1/0"
check_lacks "fails_with: no broken-pipe message" "$out" "Broken pipe"
out=$(run_case_strict "$BIG; assert_fails_with x --match '^nomatch' -- big; $CNT")
check_has "fails_with: no match in >64KB output still FAILs" "$out" "counts=0/1"
out=$(run_case_strict "$BIG; v=\$(big) || true; echo \"size=\${#v}\"")
case "$out" in
  *size=*) sz=$(printf '%s\n' "$out" | sed -n 's/^size=//p')
    if [ "${sz:-0}" -gt 65536 ]; then
      T_PASS=$((T_PASS + 1)); echo "  ok   - large-output fixture exceeds 64KB ($sz)"
    else
      T_FAIL=$((T_FAIL + 1)); echo "  FAIL - large-output fixture too small ($sz)"
    fi ;;
  *) T_FAIL=$((T_FAIL + 1)); echo "  FAIL - large-output fixture did not run" ;;
esac

# Fix round 4 (minor 6): unexpected success never prints the command output
LEAK="sh -c 'echo TOPSECRET-1; echo TOPSECRET-2'"
out=$(FW "assert_fails_with x --rc 7 -- $LEAK")
check_has "fails_with: unexpected success is FAIL" "$out" "counts=0/1"
check_lacks "fails_with: unexpected success hides output" "$out" "TOPSECRET"
check_has "fails_with: unexpected success reports rc" "$out" "rc=0"
check_has "fails_with: unexpected success reports size" "$out" "output: 23 bytes, 2 lines"
out=$(FW "assert_fails x -- $LEAK")
check_has "assert_fails: unexpected success is FAIL" "$out" "counts=0/1"
check_lacks "assert_fails: unexpected success hides output" "$out" "TOPSECRET"
check_has "assert_fails: unexpected success reports size" "$out" "output: 23 bytes, 2 lines"
out=$(FW "assert_fails x -- true")
check_has "assert_fails: empty output size reported" "$out" "output: 0 bytes, 0 lines"
# ASSERT_NO_OUTPUT=1 suppresses tails on every failure path
NO='export ASSERT_NO_OUTPUT=1'
out=$(FW "$NO; assert_succeeds x -- sh -c 'echo TOPSECRET; exit 1'")
check_has "NO_OUTPUT: assert_succeeds failure still FAIL" "$out" "counts=0/1"
check_lacks "NO_OUTPUT: assert_succeeds failure hides output" "$out" "TOPSECRET"
check_has "NO_OUTPUT: says output suppressed" "$out" "output suppressed: 9 bytes, 1 lines"
out=$(FW "$NO; f(){ echo TOPSECRET; false; }; assert_succeeds_strict x -- f")
check_lacks "NO_OUTPUT: assert_succeeds_strict failure hides output" "$out" "TOPSECRET"
out=$(FW "$NO; assert_fails_with x --rc 7 -- sh -c 'echo TOPSECRET; exit 3'")
check_has "NO_OUTPUT: fails_with wrong rc still FAIL" "$out" "counts=0/1"
check_lacks "NO_OUTPUT: fails_with wrong rc hides output" "$out" "TOPSECRET"
out=$(FW "$NO; assert_fails_with x --match denied -- sh -c 'echo TOPSECRET; exit 3'")
check_lacks "NO_OUTPUT: fails_with no-match hides output" "$out" "TOPSECRET"
out=$(FW "$NO; assert_fails_with x --rc 7 -- sh -c 'echo TOPSECRET; exit 127'")
check_lacks "NO_OUTPUT: 127 path hides output" "$out" "TOPSECRET"
out=$(FW "$NO; assert_fails x -- sh -c 'echo TOPSECRET; exit 126'")
check_lacks "NO_OUTPUT: 126 path hides output" "$out" "TOPSECRET"
out=$(FW "ASSERT_NO_OUTPUT=0; assert_succeeds x -- sh -c 'echo VISIBLE; exit 1'")
check_has "ASSERT_NO_OUTPUT=0 keeps the tail" "$out" "VISIBLE"
out=$(FW "assert_fails_with x --rc 7 -- sh -c 'echo VISIBLE; exit 3'")
check_has "default: wrong-rc failure still shows tail" "$out" "VISIBLE"

# Fix round 4 (minor 2): --rc 1 alone is weak (documented). A caller script
# error exits 1 and satisfies it; adding a tool-specific --match rejects it.
out=$(FW 'set -u; h(){ echo "$UNSETV"; }; assert_fails_with x --rc 1 -- h')
check_has "weak by design: --rc 1 alone accepts an unbound-var script error" "$out" "counts=1/0"
out=$(FW 'set -u; h(){ echo "$UNSETV"; }; assert_fails_with x --rc 1 --match "^curl: \(7\)" -- h')
check_has "--rc 1 + tool-specific --match rejects the script error" "$out" "counts=0/1"

# Fix round 4 (minor 3): KNOWN LIMITATIONS of assert_succeeds_strict. Script
# errors inside command substitutions used as arguments or in `local v=$(..)`
# are not caught by bash -e; these currently PASS. If bash or the helper ever
# starts catching them, these tests flip and the header must be updated.
out=$(run_case 'h(){ echo "$(echo "$UNSETV_XYZ")"; }; assert_succeeds_strict x -- h; '"$CNT")
check_has "KNOWN LIMITATION: unbound var in argument \$( ) is not caught (PASS)" "$out" "counts=1/0"
out=$(run_case 'h(){ local v=$(false); echo "v=$v"; }; assert_succeeds_strict x -- h; '"$CNT")
check_has "KNOWN LIMITATION: local v=\$(false) is not caught (PASS)" "$out" "counts=1/0"
out=$(run_case 'h(){ echo "$(no_such_cmd_xyz_123)"; }; assert_succeeds_strict x -- h; '"$CNT")
check_has "KNOWN LIMITATION: missing command in argument \$( ) is not caught (PASS)" "$out" "counts=1/0"
out=$(run_case 'h(){ local v; v=$(false); echo "v=$v"; }; assert_succeeds_strict x -- h; '"$CNT")
check_has "workaround: separate local + assignment IS caught (FAIL)" "$out" "counts=0/1"

# Reviewer probes A-D, reframed: script errors (unbound var under set -u) in
# nested contexts must NOT satisfy an expected reason they do not produce.
out=$(FW 'set -u; h(){ x=$(echo "$UNSETV"); echo after; }; assert_fails_with x --rc 7 -- h')
check_has "probe A (unbound in \$( )) does not satisfy --rc 7" "$out" "counts=0/1"
out=$(FW 'set -u; h(){ echo "$UNSETV" | cat; }; assert_fails_with x --match "denied" -- h')
check_has "probe B (unbound in pipe) does not satisfy --match" "$out" "counts=0/1"
out=$(FW 'set -u; h(){ x=$(false; echo hi); echo "$UNSETV"; }; assert_fails_with x --rc 7 -- h')
check_has "probe C (tolerated nested failure, later unbound) does not satisfy --rc 7" "$out" "counts=0/1"
out=$(FW 'set -u; h(){ ( false; true ); echo "$UNSETV"; }; assert_fails_with x --rc 7 --match denied -- h')
check_has "probe D (subshell failure, later unbound) does not satisfy rc+match" "$out" "counts=0/1"

# assert_succeeds_strict: nested script errors are FAIL
out=$(run_case 'h(){ x=$(echo "$UNEXPORTED_VAR_XYZ"); echo after; }; assert_succeeds_strict x -- h; '"$CNT")
check_has "strict: unbound var inside \$( ) is FAIL" "$out" "counts=0/1"
out=$(run_case 'h(){ echo "$UNEXPORTED_VAR_XYZ" | cat; }; assert_succeeds_strict x -- h; '"$CNT")
check_has "strict: unbound var inside pipe is FAIL" "$out" "counts=0/1"
out=$(run_case 'h(){ ( false; true ); echo "$UNEXPORTED_VAR_XYZ"; }; assert_succeeds_strict x -- h; '"$CNT")
check_has "strict: unbound var after subshell is FAIL" "$out" "counts=0/1"
out=$(run_case 'h(){ echo "$UNEXPORTED_VAR_XYZ"; }; assert_succeeds_strict x -- h; '"$CNT")
check_has "strict: top-level unbound var is FAIL" "$out" "counts=0/1"
out=$(run_case 'inner(){ false; }; outer(){ inner; echo after; }; assert_succeeds_strict x -- outer; '"$CNT")
check_has "strict: non-exported helper is FAIL" "$out" "counts=0/1"
out=$(run_case 'k(){ eval "if then"; }; assert_succeeds_strict x -- k; '"$CNT")
check_has "strict: syntax error in function is FAIL" "$out" "counts=0/1"
out=$(run_case 'export UNEXPORTED_VAR_XYZ=1; k(){ echo "$UNEXPORTED_VAR_XYZ"; }; assert_succeeds_strict x -- k; '"$CNT")
check_has "strict: exported var + success passes" "$out" "counts=1/0"

# I1: failures in subshell, command substitution and pipe are counted
out=$(run_case "( assert_eq 1 2 sub ); $CNT")
check_has "failure inside ( ) is counted" "$out" "counts=0/1"
out=$(run_case 'x=$(assert_eq 1 2 cs); '"$CNT")
check_has "failure inside \$( ) is counted" "$out" "counts=0/1"
out=$(run_case 'printf "a\nb\n" | while read -r l; do assert_eq 1 2 "p $l"; done; assert_summary')
check_has "two failures inside a pipe are counted" "$out" "PASS 0 / FAIL 2"
check_has "summary after piped failures returns 1" "$out" "rc=1"
out=$(run_case 'printf "a\n" | while read -r l; do assert_eq 1 1 "p $l"; done; assert_eq 1 1 top; assert_summary')
check_has "passes inside a pipe are counted" "$out" "PASS 2 / FAIL 0"

# assert_summary
out=$(run_case 'assert_eq a a m; assert_summary')
check_has "summary prints counts" "$out" "PASS 1 / FAIL 0"
check_has "summary exit 0 when no failures" "$out" "rc=0"
out=$(run_case 'assert_eq a b m; assert_summary')
check_has "summary prints failure counts" "$out" "PASS 0 / FAIL 1"
check_has "summary exit 1 on one failure" "$out" "rc=1"
out=$(run_case 'assert_summary')
check_has "zero assertions: summary fails (M2)" "$out" "rc=1"
check_has "zero assertions: says so" "$out" "no assertions ran"

# M3: missing args under set -u do not abort
out=$(run_case_strict 'assert_eq a a; assert_eq a; assert_contains x; echo alive; '"$CNT")
check_has "missing msg/args under set -euo pipefail do not crash" "$out" "alive"
check_has "missing args are counted" "$out" "counts=1/2"

# M5: re-sourcing does not reset counters
out=$(run_case "assert_eq 1 2 m; . '$ASSERT_LIB'; $CNT")
check_has "re-source keeps earlier failure" "$out" "counts=0/1"

# state file cleanup in the creating shell; caller's EXIT trap is respected
out=$(bash -c ". '$ASSERT_LIB'; echo \"state=\$ASSERT_STATE\"" 2>&1)
sf="${out#state=}"
if [ -e "$sf" ]; then
  T_FAIL=$((T_FAIL + 1)); echo "  FAIL - state file removed on exit ($sf)"; rm -f "$sf"
else
  T_PASS=$((T_PASS + 1)); echo "  ok   - state file removed on exit"
fi
out=$(bash -c "trap 'echo mytrap' EXIT; . '$ASSERT_LIB'; echo \"state=\$ASSERT_STATE\"" 2>&1)
rm -f "$(printf '%s\n' "$out" | sed -n 's/^state=//p')"
check_has "caller's EXIT trap is not overridden" "$out" "mytrap"

# M6 / I5: output truncated and only on failure
out=$(run_case 'assert_succeeds x -- sh -c "i=0; while [ \$i -lt 100 ]; do i=\$((i+1)); echo L\$i; done; exit 1"')
check_has "failing command shows tail of output" "$out" "L100"
check_lacks "failing command output is limited to the tail" "$out" "L1
"
out=$(run_case 'assert_succeeds x -- sh -c "printf %2000s | tr \" \" Z; exit 1"')
if [ "${#out}" -lt 1000 ]; then
  T_PASS=$((T_PASS + 1)); echo "  ok   - command output limited to ~500 chars"
else
  T_FAIL=$((T_FAIL + 1)); echo "  FAIL - command output not truncated (${#out} chars)"
fi
out=$(run_case 'assert_succeeds x -- sh -c "echo SECRETOUT"')
check_lacks "passing command output is not printed" "$out" "SECRETOUT"
out=$(run_case 'v=$(printf %1000s | tr " " Q); assert_eq a "$v" m')
if [ "${#out}" -lt 600 ]; then
  T_PASS=$((T_PASS + 1)); echo "  ok   - assert_eq actual value truncated"
else
  T_FAIL=$((T_FAIL + 1)); echo "  FAIL - assert_eq actual not truncated (${#out} chars)"
fi
check_has "truncation is marked" "$out" "[truncated]"

# load_env
full="$TMP/full.env"
cat > "$full" <<'EOE'
TARGET=local
CF_ZONE=zone.example.test
LIMA_INSTANCE=vm-test
TUNNEL_NAME=tunnel-test
HOST_SAFEDESK=safedesk.example.test
HOST_MINISHOP=minishop.example.test
HOST_RELAY=relay.example.test
ACME_EMAIL=ops@example.test
K3S_VERSION=v1.30.0+k3s1
EXTRA_SECRET=shouldnotleak
EOE
out=$(CLUSTER_ENV_FILE="$full" bash -c ". '$ENV_LIB'; load_env; echo \"ok \$CF_ZONE\"" 2>&1; echo "rc=$?")
check_has "load_env succeeds when all set" "$out" "ok zone.example.test"
check_has "load_env rc 0 when all set" "$out" "rc=0"

out=$(CLUSTER_ENV_FILE="$full" bash -c ". '$ENV_LIB'; load_env; sh -c 'echo zone=\$CF_ZONE extra=\${EXTRA_SECRET-unset}'" 2>&1)
check_has "required vars are exported to children" "$out" "zone=zone.example.test"
check_has "extra vars are not exported (M8)" "$out" "extra=unset"

missing="$TMP/missing.env"
grep -v '^ACME_EMAIL=' "$full" > "$missing"
out=$(ACME_EMAIL=from-ambient CLUSTER_ENV_FILE="$missing" bash -c ". '$ENV_LIB'; load_env" 2>&1; echo "rc=$?")
check_has "load_env missing var exits 2 (ambient value ignored)" "$out" "rc=2"
check_has "load_env prints missing var name" "$out" "ACME_EMAIL"

empty="$TMP/empty.env"
sed 's/^LIMA_INSTANCE=.*/LIMA_INSTANCE=/' "$full" > "$empty"
out=$(CLUSTER_ENV_FILE="$empty" bash -c ". '$ENV_LIB'; load_env" 2>&1; echo "rc=$?")
check_has "load_env empty var exits 2" "$out" "rc=2"
check_has "load_env prints empty var name" "$out" "LIMA_INSTANCE"

ws="$TMP/ws.env"
sed 's/^CF_ZONE=.*/CF_ZONE="   "/' "$full" > "$ws"
out=$(CLUSTER_ENV_FILE="$ws" bash -c ". '$ENV_LIB'; load_env" 2>&1; echo "rc=$?")
check_has "load_env whitespace-only exits 2 (M9)" "$out" "rc=2"
check_has "load_env prints whitespace-only var name" "$out" "CF_ZONE"

bad="$TMP/bad.env"
{ cat "$full"; echo 'BROKEN="unterminated'; } > "$bad"
out=$(CLUSTER_ENV_FILE="$bad" bash -c "set -e; . '$ENV_LIB'; load_env" 2>&1; echo "rc=$?")
check_has "load_env syntax-broken file exits 2 (M8)" "$out" "rc=2"
failing="$TMP/failing.env"
{ cat "$full"; echo 'false'; } > "$failing"
out=$(CLUSTER_ENV_FILE="$failing" bash -c "set -e; . '$ENV_LIB'; load_env" 2>&1; echo "rc=$?")
check_has "load_env failing line under set -e exits 2" "$out" "rc=2"

out=$(CLUSTER_ENV_FILE="$TMP/nope.env" bash -c ". '$ENV_LIB'; load_env" 2>&1; echo "rc=$?")
check_has "load_env missing file exits 2" "$out" "rc=2"

# M10: CDPATH must not corrupt the lib dir
out=$(cd "$ROOT" && CDPATH="$ROOT" bash -c '. scripts/lib/env.sh; echo "dir=$_ENV_LIB_DIR"' 2>&1)
check_has "CDPATH does not corrupt _ENV_LIB_DIR (M10)" "$out" "dir=$ROOT/scripts/lib"
out=$(cd "$ROOT" && CDPATH="$ROOT" bash tests/scripts/run.sh 2>&1 | head -1)
check_has "run.sh works with CDPATH set" "$out" "=== test_"

echo "PASS $T_PASS / FAIL $T_FAIL"
[ "$T_FAIL" -eq 0 ]
