#!/usr/bin/env bash
# check-evidence-clean.sh <file...>
# Fail (rc 1) if a text evidence file still contains a private value or a
# private-looking shape. Prints only the KIND of each leak, never the value:
#   check-evidence-clean: <kind> (<file>)
# kinds: hostname user-path user mac ip uuid email token
# rc 2 = usage error / unreadable file.  bash 3.2 compatible.
#
# Allowed on purpose (false-positive policy):
#   IPv4   127.0.0.0/8, 0.0.0.0, 255.x.x.x (masks, broadcast), K3s default pod and
#          service CIDRs 10.42.0.0/16 and 10.43.0.0/16, RFC 5737 documentation
#          ranges 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24. A dotted quad is
#          ignored when glued to letters/digits/'_'/'.'/'-' before it or followed by
#          '.digit' or a letter (version strings such as v1.2.3.4, 1.7.2.1.5).
#          Any other IPv4 is a leak. IPv6 shapes are NOT detected (only exact
#          LAN_IP/GUEST_IP/HOME_IP values from the environment are).
#   uuid   32-hex ids and 8-4-4-4-12 UUIDs, but NOT 40-hex git SHAs or 64-hex
#          sha256 digests (a 32-hex run must not touch other hex characters).
#   email  *@users.noreply.github.com and example/invalid/localhost domains.
#   hosts  the public *.whoareryu.cloud names are not private and never flagged;
#          only this Mac's names (scutil, hostname) are.
#   placeholders such as <LAN_IP>, /Users/<user>, <MAC> never match.
set -u
SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/scrub.sh
. "$SELF_DIR/lib/scrub.sh"

if [ "$#" -lt 1 ]; then
  echo "check-evidence-clean: usage: check-evidence-clean.sh <file...>" >&2
  exit 2
fi

rc=0
leak() { # <kind> <file>
  echo "check-evidence-clean: $1 ($2)" >&2
  rc=1
}

# Report every non-allowed dotted quad in a file (exit 0 if one is found).
has_foreign_ip() {
  LC_ALL=C awk '
    function allowed(a, b, c, d) {
      if (a == 127 || a == 255) return 1
      if (a == 0 && b == 0 && c == 0 && d == 0) return 1
      if (a == 10 && (b == 42 || b == 43)) return 1
      if (a == 192 && b == 0 && c == 2) return 1
      if (a == 198 && b == 51 && c == 100) return 1
      if (a == 203 && b == 0 && c == 113) return 1
      return 0
    }
    {
      s = $0; base = 0
      while (match(s, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
        q = substr(s, RSTART, RLENGTH)
        pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
        post = substr(s, RSTART + RLENGTH, 1)
        post2 = substr(s, RSTART + RLENGTH + 1, 1)
        s = substr(s, RSTART + RLENGTH)
        if (pre ~ /[A-Za-z0-9_.-]/) continue
        if (post ~ /[A-Za-z0-9_]/) continue
        if (post == "." && post2 ~ /[0-9]/) continue
        split(q, o, ".")
        if (o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255) continue
        if (!allowed(o[1] + 0, o[2] + 0, o[3] + 0, o[4] + 0)) { found = 1; exit }
      }
    }
    END { exit(found ? 0 : 1) }' "$1"
}

has_long_token() { # 40+ char mixed-case alnum run (not pure hex digests)
  LC_ALL=C grep -Eo '[A-Za-z0-9_-]{40,}' "$1" 2>/dev/null | LC_ALL=C awk '
    /[A-Z]/ && /[a-z]/ && /[0-9]/ { found = 1 }
    END { exit(found ? 0 : 1) }'
}

has_foreign_email() {
  LC_ALL=C grep -Eo '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$1" 2>/dev/null | LC_ALL=C awk '
    {
      d = tolower($0); sub(/^[^@]*@/, "", d)
      if (d == "users.noreply.github.com") next
      if (d ~ /(^|\.)example\.(com|org|net)$/) next
      if (d ~ /\.invalid$/ || d == "invalid" || d ~ /\.localhost$/) next
      found = 1
    }
    END { exit(found ? 0 : 1) }'
}

for f in "$@"; do
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    echo "check-evidence-clean: cannot read $f" >&2
    exit 2
  fi

  hit=0
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    if LC_ALL=C grep -Fiq -e "$h" "$f"; then hit=1; fi
  done <<EOF
$(_evidence_hostnames)
EOF
  [ "$hit" -eq 0 ] || leak hostname "$f"

  hit=0
  if LC_ALL=C grep -Eq '/Users/[A-Za-z0-9._-]' "$f"; then hit=1; fi
  if home="$(_evidence_home_prefix)" && LC_ALL=C grep -Fq -e "$home" "$f"; then hit=1; fi
  [ "$hit" -eq 0 ] || leak user-path "$f"

  hit=0
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    if LC_ALL=C grep -Fwq -e "$u" "$f"; then hit=1; fi
  done <<EOF
$(_evidence_usernames)
EOF
  [ "$hit" -eq 0 ] || leak user "$f"

  if LC_ALL=C grep -Eq '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' "$f"; then leak mac "$f"; fi

  hit=0
  has_foreign_ip "$f" && hit=1
  for var in LAN_IP GUEST_IP HOME_IP; do
    eval "val=\${$var:-}"
    [ "${#val}" -ge 4 ] || continue
    if LC_ALL=C grep -Fq -e "$val" "$f"; then hit=1; fi
  done
  [ "$hit" -eq 0 ] || leak ip "$f"

  hit=0
  if LC_ALL=C grep -Eiq '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$f"; then hit=1; fi
  if LC_ALL=C grep -Eq '(^|[^0-9A-Fa-f])[0-9A-Fa-f]{32}($|[^0-9A-Fa-f])' "$f"; then hit=1; fi
  for var in TUNNEL_ID ZONE_ID ACCOUNT_ID; do
    eval "val=\${$var:-}"
    [ "${#val}" -ge 4 ] || continue
    if LC_ALL=C grep -Fq -e "$val" "$f"; then hit=1; fi
  done
  [ "$hit" -eq 0 ] || leak uuid "$f"

  if has_foreign_email "$f"; then leak email "$f"; fi

  hit=0
  if LC_ALL=C grep -Eq '(ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|glpat-|xox[abprs]-|cfut_|cfk_|sk-)[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}' "$f"; then hit=1; fi
  if LC_ALL=C grep -Eq 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}' "$f"; then hit=1; fi
  if LC_ALL=C grep -Eq -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$f"; then hit=1; fi
  if LC_ALL=C grep -Eq '[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}' "$f"; then hit=1; fi
  has_long_token "$f" && hit=1
  [ "$hit" -eq 0 ] || leak token "$f"
done
exit "$rc"
