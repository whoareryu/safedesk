#!/usr/bin/env bash
# Evidence scrubbing for the public repository. Source this file (bash 3.2+).
#
#   scrub_evidence <file>     in-place replacement of private values
#   _evidence_hostnames       (helper, also used by check-evidence-clean.sh)
#   _evidence_usernames       (helper)
#
# Private values are read at run time, never stored in the repository:
#   - Mac host names: scutil --get LocalHostName / ComputerName, hostname -s, hostname
#     (+ EVIDENCE_EXTRA_HOSTNAMES, space separated, for tests and other machines)
#   - $HOME and the user name ($USER, id -un)
#   - environment: LAN_IP, GUEST_IP, HOME_IP, TUNNEL_ID, ZONE_ID, ACCOUNT_ID
#   - shapes: /Users/<name>, MAC addresses, UUIDs, bare 32-hex ids
# Values shorter than 3 characters (4 for environment ids), "root" and
# "localhost" are never treated as private, to avoid mangling ordinary text.

# _evidence_hostnames: one candidate host name per line, unique, length >= 3.
_evidence_hostnames() {
  {
    if command -v scutil >/dev/null 2>&1; then
      scutil --get LocalHostName 2>/dev/null
      scutil --get ComputerName 2>/dev/null
    fi
    hostname -s 2>/dev/null
    hostname 2>/dev/null
    # shellcheck disable=SC2086  # word splitting of the list is intended
    for _h in ${EVIDENCE_EXTRA_HOSTNAMES:-}; do printf '%s\n' "$_h"; done
  } | awk '
    length($0) >= 3 && tolower($0) != "localhost" && !seen[tolower($0)]++ { print }'
}

# _evidence_usernames: one user name per line, unique, length >= 3, no root/user.
_evidence_usernames() {
  {
    printf '%s\n' "${USER:-}"
    id -un 2>/dev/null
  } | awk 'length($0) >= 3 && $0 != "root" && $0 != "user" && !seen[$0]++ { print }'
}

# _evidence_home_prefix: prints $HOME when it is a real per-user directory.
_evidence_home_prefix() {
  case "${HOME:-}" in
    '' | / | /root | /var/root) return 1 ;;
  esac
  [ "${#HOME}" -ge 5 ] || return 1
  printf '%s\n' "$HOME"
}

# scrub_evidence <file>: replace private values in place.
scrub_evidence() {
  if [ "$#" -ne 1 ]; then
    echo "scrub_evidence: usage: scrub_evidence <file>" >&2
    return 2
  fi
  if [ ! -f "$1" ] || [ ! -r "$1" ]; then
    echo "scrub_evidence: cannot read $1" >&2
    return 2
  fi
  local file="$1" pairs="" tmp home h u var val
  local tab
  tab="$(printf '\t')"

  # mode: s = exact, i = case-insensitive, w = exact on word boundaries.
  for var in LAN_IP GUEST_IP HOME_IP TUNNEL_ID ZONE_ID ACCOUNT_ID; do
    eval "val=\${$var:-}"
    [ "${#val}" -ge 4 ] || continue
    pairs="${pairs}s${tab}${val}${tab}<${var}>
"
  done
  if home="$(_evidence_home_prefix)"; then
    pairs="${pairs}s${tab}${home}${tab}${home%/*}/<user>
"
  fi
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    pairs="${pairs}i${tab}${h}${tab}<HOSTNAME>
"
  done <<EOF
$(_evidence_hostnames)
EOF
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    pairs="${pairs}w${tab}${u}${tab}<user>
"
  done <<EOF
$(_evidence_usernames)
EOF

  tmp="$(mktemp "${TMPDIR:-/tmp}/scrub.XXXXXX")" || return 1
  SCRUB_PAIRS="$pairs" LC_ALL=C awk '
    function isalnum_ch(c) { return c ~ /^[A-Za-z0-9]$/ }
    function repl(s, val, ph, mode,    out, hay, ndl, pos, before, after, rest, off) {
      out = ""
      ndl = (mode == "i") ? tolower(val) : val
      while (length(s) > 0) {
        hay = (mode == "i") ? tolower(s) : s
        pos = index(hay, ndl)
        if (pos == 0) { out = out s; break }
        before = (pos > 1) ? substr(s, pos - 1, 1) : ""
        after = substr(s, pos + length(val), 1)
        if (mode == "w" && ((before != "" && isalnum_ch(before)) || (after != "" && isalnum_ch(after)))) {
          out = out substr(s, 1, pos + length(val) - 1)
        } else {
          out = out substr(s, 1, pos - 1) ph
        }
        s = substr(s, pos + length(val))
      }
      return out
    }
    BEGIN {
      np = split(ENVIRON["SCRUB_PAIRS"], rows, "\n")
      for (i = 1; i <= np; i++) {
        if (rows[i] == "") continue
        split(rows[i], f, "\t")
        n++; mode[n] = f[1]; val[n] = f[2]; ph[n] = f[3]
      }
    }
    {
      line = $0
      for (k = 1; k <= n; k++) line = repl(line, val[k], ph[k], mode[k])
      print line
    }' "$file" >"$tmp" || { rm -f "$tmp"; return 1; }

  # Shape-based replacements. Two passes so neighbouring matches that share a
  # boundary character are both handled.
  sed -E \
    -e 's#/Users/[A-Za-z0-9._-]+#/Users/<user>#g' \
    -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/<MAC>/g' \
    -e 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/<UUID>/g' \
    -e 's/(^|[^0-9A-Fa-f])[0-9A-Fa-f]{32}($|[^0-9A-Fa-f])/\1<ID>\2/g' \
    -e 's/(^|[^0-9A-Fa-f])[0-9A-Fa-f]{32}($|[^0-9A-Fa-f])/\1<ID>\2/g' \
    "$tmp" >"$tmp.2" || { rm -f "$tmp" "$tmp.2"; return 1; }
  cat "$tmp.2" >"$file" || { rm -f "$tmp" "$tmp.2"; return 1; }
  rm -f "$tmp" "$tmp.2"
}
