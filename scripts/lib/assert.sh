#!/usr/bin/env bash
# Minimal assertion helpers. Source this file; compatible with bash 3.2 and 5.
#
# API
#   assert_eq <expected> <actual> <msg>
#   assert_contains <haystack> <needle> <msg>          (empty needle = FAIL)
#   assert_fails <msg> -- <cmd...>                     (cmd must exit non-zero)
#   assert_succeeds <msg> -- <cmd...>                  (cmd must exit zero)
#   assert_fails_with <msg> [--rc n] [--match ERE] -- <cmd...>  (see below)
#   assert_succeeds_strict <msg> -- <cmd...>           (see below)
#   assert_counts                                      (prints "<pass>/<fail>")
#   assert_summary                                     (prints "PASS n / FAIL m")
#
# Rules and caveats
# - The `--` separator is mandatory in the command forms; without it the
#   assertion is a usage error and counts as FAIL.
# - An empty command, or a command that exits 126/127 (not runnable / not
#   found), is FAIL in both assert_fails and assert_succeeds, so a typo can
#   never make a negative check pass.
# - Results are appended to a state file (ASSERT_STATE, created on first
#   source and exported), so assertions made inside ( ), $( ) or a pipe are
#   still counted by assert_summary.
# - assert_summary RETURNS 1 (it does not exit) when anything failed or when
#   zero assertions ran. Call it as the LAST command of a verify script, or
#   use `assert_summary || exit 1`.
# - assert_fails is ONLY for simple single commands where ANY failure is
#   acceptable. Security "must be blocked/denied" checks in verify scripts
#   MUST use assert_fails_with, which passes only if the command fails for
#   the expected reason (exit code and/or output pattern):
#   assert_fails_with <msg> [--rc <n>] [--match <ERE>] -- <cmd...>
#   At least one of --rc / --match is required, each at most once (a repeated
#   option is a usage error). --rc must be a plain integer 1-255 (no sign,
#   leading zero, spaces or other junk). --match is grep -E (LC_ALL=C) on the
#   full combined stdout+stderr; if both are given both must hold. Exit 0 is
#   always FAIL, as are 126/127. Every usage error counts as FAIL.
#   Choosing the condition:
#   * PREFER --match on text only the tool itself prints, and combine it with
#     --rc where the tool's exit code is documented:
#       assert_fails_with "6443 closed" --rc 7 --match '^curl: \(7\)' -- \
#         curl -sS --max-time 3 https://host:6443
#       assert_fails_with "anon denied" --rc 1 --match 'Error from server \(Forbidden\)' -- \
#         kubectl --as=system:anonymous get pods
#   * AVOID --rc 1 alone and loose patterns such as 'denied' or 'error':
#     a script error in the caller's own function (set -u unbound variable,
#     failed `local`/assignment) also exits 1, and bash's own messages
#     (e.g. "Permission denied" from a failed redirect) can match a loose
#     pattern, so the check would pass without the tool ever denying anything.
# - Plain assert_fails/assert_succeeds run the command in the current shell
#   inside a condition context, so `set -e` does NOT apply inside a function
#   passed to them: `f(){ false; echo after; }` "succeeds". For multi-step
#   functions use assert_succeeds_strict, which runs the command in a child
#   `bash -euo pipefail` that stops at the first failing simple command,
#   plain assignment `v=$(cmd)` or pipeline. Functions are exported with
#   `export -f`; helpers they call and variables they read must be exported
#   by the caller too. There is deliberately no strict "fails" variant: a
#   script error in a child cannot be told apart from a genuine failure.
#   KNOWN LIMITATION (bash semantics, not fixed here): errors inside a
#   command substitution whose status is discarded are NOT caught, so these
#   functions still PASS:
#     echo "$(echo "$UNSET")"   # unbound var inside an argument $( )
#     echo "$(nosuch)"          # missing command inside an argument $( )
#     local v=$(false)          # `local` returns 0, hiding the status
#   Write `local v; v=$(cmd)` and assign substitutions to variables before
#   using them as arguments; those forms are caught.
# - Output on failure: values are truncated to 200 chars; command output to
#   the last 20 lines / 500 chars. Output is never printed on success.
#   When a command that must FAIL (assert_fails, assert_fails_with)
#   unexpectedly SUCCEEDS, its output is NOT printed (it may be the very
#   secret the check guards); only rc and output size (bytes, lines) are.
#   Set ASSERT_NO_OUTPUT=1 (any value other than empty or 0) to suppress the
#   command-output tail on EVERY failure path; size is still reported.
#   assert_eq/assert_contains values are not affected by this switch.
if [ -z "${ASSERT_STATE:-}" ] || [ ! -f "$ASSERT_STATE" ]; then
  ASSERT_STATE="$(mktemp "${TMPDIR:-/tmp}/assert.XXXXXX")"
  export ASSERT_STATE
  # Clean up in the creating shell unless the caller already owns an EXIT trap.
  _assert_existing_trap="$(trap -p EXIT)"
  if [ -z "$_assert_existing_trap" ]; then
    # shellcheck disable=SC2064
    trap "rm -f '$ASSERT_STATE'" EXIT
  fi
  unset _assert_existing_trap
fi

_assert_ok() {
  echo P >>"$ASSERT_STATE"
  echo "  ok   - ${1:-}"
}

_assert_ko() {
  echo F >>"$ASSERT_STATE"
  echo "  FAIL - ${1:-}"
}

# _assert_trunc <string> [max]: first max chars (default 200), with marker.
_assert_trunc() {
  local s="${1:-}" max="${2:-200}"
  if [ "${#s}" -gt "$max" ]; then
    printf '%s...[truncated]' "${s:0:$max}"
  else
    printf '%s' "$s"
  fi
}

# _assert_size <output>: "N bytes, M lines" of captured output.
_assert_size() {
  local s="${1:-}" b l
  b=$(printf '%s' "$s" | LC_ALL=C wc -c | tr -d ' ')
  if [ -z "$s" ]; then
    l=0
  else
    l=$(printf '%s\n' "$s" | wc -l | tr -d ' ')
  fi
  printf '%s bytes, %s lines' "$b" "$l"
}

_assert_no_output() {
  case "${ASSERT_NO_OUTPUT:-}" in
    ''|0) return 1 ;;
    *) return 0 ;;
  esac
}

# _assert_tail <output>: last 20 lines, at most 500 chars, indented
# (only the size when ASSERT_NO_OUTPUT is set).
_assert_tail() {
  if _assert_no_output; then
    printf '      (output suppressed: %s)' "$(_assert_size "${1:-}")"
    return 0
  fi
  printf '%s\n' "${1:-}" | tail -n 20 | tail -c 500 | sed 's/^/      | /'
}

# _assert_unexpected_ok <msg> <output>: FAIL for a command that had to fail
# but exited 0; never prints the output itself.
_assert_unexpected_ok() {
  _assert_ko "$1 (command unexpectedly succeeded, rc=0, output: $(_assert_size "${2:-}"); output not shown)"
}

assert_counts() {
  local p f
  p=$(grep -c -x P "$ASSERT_STATE" || true)
  f=$(grep -c -x F "$ASSERT_STATE" || true)
  echo "${p:-0}/${f:-0}"
}

# assert_eq <expected> <actual> <msg>
assert_eq() {
  local msg="${3:-(no message)}"
  if [ "${1:-}" = "${2:-}" ]; then
    _assert_ok "$msg"
  else
    _assert_ko "$msg (expected '$(_assert_trunc "${1:-}")', got '$(_assert_trunc "${2:-}")')"
  fi
}

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  local msg="${3:-(no message)}"
  if [ -z "${2:-}" ]; then
    _assert_ko "$msg (empty needle)"
    return 0
  fi
  case "${1:-}" in
    *"$2"*) _assert_ok "$msg" ;;
    *) _assert_ko "$msg ('$(_assert_trunc "$2")' not found in '$(_assert_trunc "${1:-}")')" ;;
  esac
}

# _assert_run <strict: 0|1> <cmd...>: sets globals _A_OUT and _A_RC.
_assert_run() {
  local strict="$1"
  shift
  if [ "$strict" = 1 ]; then
    if declare -F "$1" >/dev/null 2>&1; then
      # shellcheck disable=SC2163  # exports the function named by $1, as intended
      export -f "$1"
    fi
    _A_OUT=$(bash -euo pipefail -c '"$@"' _ "$@" 2>&1) && _A_RC=0 || _A_RC=$?
  else
    _A_OUT=$("$@" 2>&1) && _A_RC=0 || _A_RC=$?
  fi
}

# _assert_cmd <want: succeeds|fails> <strict: 0|1> <msg> [-- cmd...]
_assert_cmd() {
  local want="$1" strict="$2" msg="${3:-(no message)}"
  shift 3
  if [ "${1:-}" != "--" ]; then
    _assert_ko "$msg (usage: missing '--' before the command)"
    return 0
  fi
  shift
  if [ "$#" -eq 0 ] || [ -z "$1" ]; then
    _assert_ko "$msg (no command given)"
    return 0
  fi
  _assert_run "$strict" "$@"
  if [ "$_A_RC" -eq 126 ] || [ "$_A_RC" -eq 127 ]; then
    _assert_ko "$msg (command not runnable, rc=$_A_RC)
$(_assert_tail "$_A_OUT")"
    return 0
  fi
  if [ "$want" = succeeds ]; then
    if [ "$_A_RC" -eq 0 ]; then
      _assert_ok "$msg"
    else
      _assert_ko "$msg (command failed, rc=$_A_RC)
$(_assert_tail "$_A_OUT")"
    fi
  else
    if [ "$_A_RC" -ne 0 ]; then
      _assert_ok "$msg"
    else
      _assert_unexpected_ok "$msg" "$_A_OUT"
    fi
  fi
}

assert_fails() { _assert_cmd fails 0 "$@"; }
assert_succeeds() { _assert_cmd succeeds 0 "$@"; }
assert_succeeds_strict() { _assert_cmd succeeds 1 "$@"; }

# assert_fails_with <msg> [--rc <n>] [--match <ERE>] -- <cmd...>
assert_fails_with() {
  local msg="${1:-(no message)}" want_rc="" have_rc=0 pattern="" have_match=0 reason=""
  [ "$#" -gt 0 ] && shift
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
      --rc)
        if [ "$#" -lt 2 ]; then _assert_ko "$msg (usage: --rc needs a value)"; return 0; fi
        if [ "$have_rc" -eq 1 ]; then _assert_ko "$msg (usage: duplicate --rc)"; return 0; fi
        want_rc="$2"; have_rc=1; shift 2 ;;
      --match)
        if [ "$#" -lt 2 ]; then _assert_ko "$msg (usage: --match needs a value)"; return 0; fi
        if [ "$have_match" -eq 1 ]; then _assert_ko "$msg (usage: duplicate --match)"; return 0; fi
        pattern="$2"; have_match=1; shift 2 ;;
      *)
        _assert_ko "$msg (usage: unknown option '$1')"; return 0 ;;
    esac
  done
  if [ "${1:-}" != "--" ]; then
    _assert_ko "$msg (usage: missing '--' before the command)"
    return 0
  fi
  shift
  if [ "$have_rc" -eq 0 ] && [ "$have_match" -eq 0 ]; then
    _assert_ko "$msg (usage: need --rc and/or --match)"
    return 0
  fi
  if [ "$have_rc" -eq 1 ]; then
    # 1-3 digits, no leading zero, then <= 255 (keeps `[ -ne ]` in range).
    local rc_ok=0
    case "$want_rc" in
      [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) [ "$want_rc" -le 255 ] && rc_ok=1 ;;
    esac
    if [ "$rc_ok" -ne 1 ]; then
      _assert_ko "$msg (usage: --rc must be an integer 1-255, got '$(_assert_trunc "$want_rc" 40)')"
      return 0
    fi
  fi
  if [ "$have_match" -eq 1 ] && [ -z "$pattern" ]; then
    _assert_ko "$msg (usage: empty --match pattern)"
    return 0
  fi
  if [ "$#" -eq 0 ] || [ -z "$1" ]; then
    _assert_ko "$msg (no command given)"
    return 0
  fi
  _assert_run 0 "$@"
  if [ "$_A_RC" -eq 0 ]; then
    _assert_unexpected_ok "$msg" "$_A_OUT"
    return 0
  fi
  if [ "$_A_RC" -eq 126 ] || [ "$_A_RC" -eq 127 ]; then
    _assert_ko "$msg (command not runnable, rc=$_A_RC)
$(_assert_tail "$_A_OUT")"
    return 0
  fi
  if [ "$have_rc" -eq 1 ] && [ "$_A_RC" -ne "$want_rc" ]; then
    reason="expected rc=$want_rc, got rc=$_A_RC"
  fi
  # Here-string, not a pipe: grep -q may exit early, and a pipe writer would
  # then die of SIGPIPE (false FAIL under the caller's pipefail).
  if [ "$have_match" -eq 1 ] && ! LC_ALL=C grep -E -q -e "$pattern" <<<"$_A_OUT"; then
    reason="${reason:+$reason; }output does not match /$pattern/ (rc=$_A_RC)"
  fi
  if [ -n "$reason" ]; then
    _assert_ko "$msg ($reason)
$(_assert_tail "$_A_OUT")"
  else
    _assert_ok "$msg"
  fi
}

# assert_summary: print totals; return 1 on any failure or zero assertions.
assert_summary() {
  local c p f
  c=$(assert_counts)
  p="${c%/*}"
  f="${c#*/}"
  echo "PASS $p / FAIL $f"
  if [ $((p + f)) -eq 0 ]; then
    echo "no assertions ran" >&2
    return 1
  fi
  [ "$f" -eq 0 ]
}
