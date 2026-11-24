#!/usr/bin/env bash
# check-evidence-clean.sh <file...>
# Fail (rc 1) if a text evidence file still contains a private value or a
# private-looking shape. Prints only the KIND of each leak, never the value:
#   check-evidence-clean: <kind> (<file>)
# kinds: hostname user-path user mac ip uuid email token
# rc 2 = usage error / unreadable file.  bash 3.2 compatible.
#
# What counts as private is defined ONCE in lib/scrub.sh (_evidence_scan): this
# script reports exactly the kinds a scrub_evidence run would replace, plus
# IPv4 addresses, e-mail addresses and token shapes, which scrub never invents.
#
# Allowed on purpose (false-positive policy):
#   IPv4   127.0.0.0/8, 0.0.0.0, 255.x.x.x (masks, broadcast), K3s default pod and
#          service CIDRs 10.42.0.0/16 and 10.43.0.0/16, RFC 5737 documentation
#          ranges 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, and the public
#          addresses listed in config/evidence-public-ips.txt, multicast 224/4.
#          Dotted (a.b.c.d), dashed (ip-a-b-c-d) and netstat/tcpdump addr.port
#          (a.b.c.d.53412) forms are checked. Version strings are skipped only when
#          the quad is glued directly to a letter (v1.2.3.4, 0ubuntu0.24.04.1),
#          follows a 2-3 part version at a word start and a dash (6.8.0-1.2.3.4), or
#          is followed by two or more ".digits" groups (1.7.2.1.5.6). A quad after a
#          separator is an IP: host-a.b.c.d, a_a.b.c.d, eth0-a.b.c.d, node-1-a.b.c.d,
#          the second address of a range a.b.c.d-e.f.g.h.
#   IPv6   ::, ::1, multicast, 2001:db8::/32, fe80::<small id> and allowlisted
#          prefixes; global, ULA and other link-local addresses are "ip", EUI-64
#          ones (ff:fe in the interface id) "mac". IPv4-mapped (::ffff:, hex or
#          dotted) and NAT64 (64:ff9b::/96) addresses are judged by their IPv4;
#          an embedded IPv4 tail and a trailing ".port" are handled.
#   allowlist  entries must be IPv4 >= /16 or global IPv6 >= /32 and must not
#          overlap any private/reserved range (RFC 1918, 100.64/10, 169.254/16,
#          127/8, 0/8, docs, 224/4, 240/4; 2001::/23, 2001:db8::/32, 2002::/16).
#   uuid   32-hex ids and 8-4-4-4-12 UUIDs, but NOT 40-hex git SHAs or 64-hex
#          sha256 digests (a 32-hex run must not touch other hex characters).
#   email  *@users.noreply.github.com and example/invalid/localhost domains.
#   hosts  the public *.whoareryu.cloud names are not private and never flagged;
#          only this Mac's names (scutil, hostname, id -F, user names) are.
#   placeholders such as <LAN_IP>, /Users/<user>, <MAC>, <IPV6> never match.
set -u
SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/scrub.sh
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

  kinds="$(_evidence_scan check "$f")" || exit 2
  for k in $kinds; do leak "$k" "$f"; done

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
