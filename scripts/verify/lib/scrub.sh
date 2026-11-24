#!/usr/bin/env bash
# Evidence scrubbing for the public repository. Source this file (bash 3.2+).
#
#   scrub_evidence <file>          in-place replacement of private values
#   _evidence_scan check <file>    (helper for check-evidence-clean.sh) prints the
#                                  KIND of every private value found, one per line
#
# One awk engine does both jobs, so the scrubber and the checker can never
# disagree about what is private: the check reports exactly the kinds that a
# scrub would replace, plus the check-only shapes (IPv4 anywhere, see below).
#
# Private values are read at run time, never stored in the repository:
#   - Mac host names: scutil --get LocalHostName / ComputerName, hostname -s,
#     hostname (+ EVIDENCE_EXTRA_HOSTNAMES, space separated) and their variants:
#     curly/straight/dropped apostrophe, spaces as "-", "\ ", "%20", "\032" or
#     removed, URL-encoded apostrophe; matched case-insensitively.
#   - the owner's real name (id -F on macOS, the passwd GECOS name elsewhere),
#     with the same variants, and each word of it (>= 3 chars, not a stop word
#     such as MacBook/Pro/month or day names) on letter boundaries.
#   - $HOME and the user name ($USER, id -un), case-insensitive, on letter
#     boundaries (zedkim_x and zedkim2 are both caught).
#   - environment: LAN_IP, GUEST_IP, HOME_IP (also the dashed a-b-c-d form;
#     never inside a longer number), TUNNEL_ID, ZONE_ID, ACCOUNT_ID.
#   - shapes: /Users/<name>; MAC addresses (aa:bb:cc:dd:ee:ff incl. unpadded
#     a:b:c:d:e:f, AA-BB-CC-DD-EE-FF, aabb.ccdd.eeff); UUIDs; bare 32-hex ids;
#     IPv6 global (2000::/3), ULA (fc00::/7) and link-local (fe80::/10)
#     addresses -> <IPV6>. Kept: ::, ::1, ::ffff:<v4>, multicast, 2001:db8::/32,
#     link-local with an interface id below 0x10000 (fe80::1%lo0), and entries
#     of the public-IP allowlist.
# Names shorter than 3 characters, "root", "localhost", and names that occur
# (case-insensitively) inside a placeholder or in "/Users/" (host, mac, user,
# lan, ...) are never treated as private, so scrubbing stays idempotent and
# ordinary words survive. Names shorter than 6 characters only match on letter
# boundaries.
#
# Public-IP allowlist (check-evidence-clean.sh and scrub): one address or CIDR
# per line, '#' comments; IPv4 a.b.c.d[/n], IPv6 addr[/n] with n a multiple of
# 4. Private, loopback, link-local, CGNAT and ULA entries are rejected (rc 2).
# Default file: config/evidence-public-ips.txt; EVIDENCE_PUBLIC_IPS_FILE
# overrides it (tests).

_SCRUB_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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
  } | LC_ALL=C awk '
    length($0) >= 3 && tolower($0) != "localhost" && !seen[tolower($0)]++ { print }'
}

# _evidence_realnames: the owner's full name (macOS id -F, else GECOS).
_evidence_realnames() {
  {
    id -F 2>/dev/null
    if command -v getent >/dev/null 2>&1; then
      getent passwd "$(id -un 2>/dev/null)" 2>/dev/null | cut -d: -f5 | cut -d, -f1
    fi
  } | LC_ALL=C awk 'length($0) >= 3 && !seen[tolower($0)]++ { print }'
}

# _evidence_usernames: one user name per line, unique, length >= 3, no root/user.
_evidence_usernames() {
  {
    printf '%s\n' "${USER:-}"
    id -un 2>/dev/null
  } | LC_ALL=C awk 'length($0) >= 3 && $0 != "root" && $0 != "user" && !seen[tolower($0)]++ { print }'
}

# _evidence_home_prefix: prints $HOME when it is a real per-user directory.
_evidence_home_prefix() {
  case "${HOME:-}" in
    '' | / | /root | /var/root) return 1 ;;
  esac
  [ "${#HOME}" -ge 5 ] || return 1
  printf '%s\n' "$HOME"
}

# _evidence_pairs: "phase<TAB>mode<TAB>value<TAB>placeholder<TAB>kind" lines.
# phase 1 runs before the shape replacements (exact env values), phase 3 after
# them (names, longest first). mode: s exact, i case-insensitive, w
# case-insensitive on letter boundaries, n exact on numeric boundaries.
_evidence_pairs() {
  local tab var val home
  tab="$(printf '\t')"
  for var in LAN_IP GUEST_IP HOME_IP; do
    eval "val=\${$var:-}"
    [ "${#val}" -ge 7 ] || continue
    printf '1%sn%s%s%s<%s>%sip\n' "$tab" "$tab" "$val" "$tab" "$var" "$tab"
    printf '1%sn%s%s%s<%s>%sip\n' "$tab" "$tab" "$(printf '%s' "$val" | tr . -)" "$tab" "$var" "$tab"
  done
  for var in TUNNEL_ID ZONE_ID ACCOUNT_ID; do
    eval "val=\${$var:-}"
    [ "${#val}" -ge 4 ] || continue
    printf '1%si%s%s%s<%s>%suuid\n' "$tab" "$tab" "$val" "$tab" "$var" "$tab"
  done
  if home="$(_evidence_home_prefix)"; then
    printf '1%ss%s%s%s%s/<user>%suser-path\n' "$tab" "$tab" "$home" "$tab" "${home%/*}" "$tab"
  fi
  {
    _evidence_hostnames | sed "s/^/H$tab/"
    _evidence_realnames | sed "s/^/R$tab/"
    _evidence_usernames | sed "s/^/U$tab/"
  } | LC_ALL=C awk -F'\t' '
    function rep(s, a, b,    out, p) {
      out = ""
      while ((p = index(s, a)) > 0) { out = out substr(s, 1, p - 1) b; s = substr(s, p + length(a)) }
      return out s
    }
    function reserved(v,    l) {
      l = tolower(v)
      return index(PH, l) > 0
    }
    function emit(v, mode, ph, kind) {
      if (length(v) < 3 || reserved(v) || seen[tolower(v)]++) return
      if (mode == "auto") mode = (length(v) >= 6) ? "i" : "w"
      print length(v) "\t3\t" mode "\t" v "\t" ph "\t" kind
    }
    BEGIN {
      CURLY = "\342\200\231"
      PH = "<hostname> <user> <mac> <uuid> <id> <ipv6> <lan_ip> <guest_ip> <home_ip> <tunnel_id> <zone_id> <account_id> /users/ localhost root"
      nsp = split(" |-|\\ |%20|\\032|", SP, "|")
      split("macbook pro air imac mini mac studio the and local home admin user users root jan feb mar apr may jun jul aug sep oct nov dec mon tue wed thu fri sat sun", sw, " ")
      for (k in sw) STOP[sw[k]] = 1
    }
    $1 == "U" { emit($2, "w", "<user>", "user"); next }
    {
      n = $2
      ph = ($1 == "H") ? "<HOSTNAME>" : "<user>"
      kind = ($1 == "H") ? "hostname" : "user"
      A[1] = n
      A[2] = rep(n, CURLY, "\047")
      A[3] = rep(n, "\047", CURLY)
      A[4] = rep(rep(n, CURLY, ""), "\047", "")
      A[5] = rep(rep(n, CURLY, "%E2%80%99"), "\047", "%27")
      for (a = 1; a <= 5; a++)
        for (k = 1; k <= nsp; k++) emit(rep(A[a], " ", SP[k]), "auto", ph, kind)
      if ($1 == "R") {
        nw = split(A[4], W, " ")
        for (k = 1; k <= nw; k++) if (!(tolower(W[k]) in STOP)) emit(W[k], "w", ph, kind)
      }
    }' | LC_ALL=C sort -t "$tab" -k1,1nr | cut -f2-
}

# The engine. ENVIRON: EV_MODE (scrub|check), EV_PAIRS, EV_ALLOW (allowlist path).
# scrub: prints the scrubbed text. check: prints the kinds found, one per line.
# Exit 2 (with a message on stderr) on a bad allowlist entry.
# shellcheck disable=SC2016  # awk program text
_EVIDENCE_AWK='
function ch(s, i) { return (i >= 1 && i <= length(s)) ? substr(s, i, 1) : "" }
function isletter(c) { return c != "" && c ~ /^[A-Za-z]$/ }
function isdigit(c) { return c != "" && c ~ /^[0-9]$/ }
function hexval(h,    i, v) {
  v = 0; h = tolower(h)
  for (i = 1; i <= length(h); i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
  return v
}
function pad4(g) { while (length(g) < 4) g = "0" g; return g }
# expand6: 32 lowercase nibbles, or "" if t is not an IPv6 address.
function expand6(t,    d, left, right, nl, nr, L, R, i, out, k) {
  if (t ~ /:::/) return ""
  d = index(t, "::")
  if (d > 0 && index(substr(t, d + 2), "::") > 0) return ""
  if (d > 0) { left = substr(t, 1, d - 1); right = substr(t, d + 2) } else { left = t; right = "" }
  nl = (left == "") ? 0 : split(left, L, ":")
  nr = (right == "") ? 0 : split(right, R, ":")
  if (d == 0 && nl != 8) return ""
  if (d > 0 && nl + nr > 7) return ""
  out = ""
  for (i = 1; i <= nl; i++) { if (L[i] !~ /^[0-9A-Fa-f]+$/ || length(L[i]) > 4) return ""; out = out pad4(L[i]) }
  if (d > 0) for (k = 0; k < 8 - nl - nr; k++) out = out "0000"
  for (i = 1; i <= nr; i++) { if (R[i] !~ /^[0-9A-Fa-f]+$/ || length(R[i]) > 4) return ""; out = out pad4(R[i]) }
  return tolower(out)
}
function v4num(q,    o) {
  if (split(q, o, ".") != 4) return -1
  if (o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255) return -1
  return ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
}
function inv4(x, net, len,    div) { div = 2 ^ (32 - len); return int(x / div) == int(net / div) }
function v4private(x) {
  return inv4(x, v4num("10.0.0.0"), 8) || inv4(x, v4num("172.16.0.0"), 12) || inv4(x, v4num("192.168.0.0"), 16) ||
    inv4(x, v4num("127.0.0.0"), 8) || inv4(x, v4num("169.254.0.0"), 16) || inv4(x, v4num("100.64.0.0"), 10) ||
    inv4(x, 0, 8)
}
function badallow(n, line) {
  printf "check-evidence-clean: bad public-IP allowlist entry (line %d of the allowlist)\n", n > "/dev/stderr"
  BAD = 1
  exit 2
}
function loadallow(path,    line, n, e, a, len, x, g1) {
  if (path == "") return
  n = 0
  while ((getline line < path) > 0) {
    n++
    sub(/#.*/, "", line); gsub(/[ \t\r]+/, "", line)
    if (line == "") continue
    len = -1
    if (index(line, "/") > 0) { split(line, a, "/"); e = a[1]; len = a[2]; if (len !~ /^[0-9]+$/) badallow(n) } else e = line
    if (e ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
      x = v4num(e)
      if (x < 0) badallow(n)
      if (len == -1) len = 32
      if (len + 0 < 8 || len + 0 > 32 || v4private(x)) badallow(n)
      NA4++; A4NET[NA4] = x; A4LEN[NA4] = len + 0
    } else {
      x = expand6(e)
      if (x == "") badallow(n)
      if (len == -1) len = 128
      if (len % 4 != 0 || len + 0 < 16 || len + 0 > 128) badallow(n)
      g1 = hexval(substr(x, 1, 4))
      if (g1 < 8192 || g1 > 16383) badallow(n)   # only global unicast 2000::/3
      NA6++; A6PRE[NA6] = substr(x, 1, len / 4)
    }
  }
  close(path)
}
function allowed4(x,    i) {
  for (i = 1; i <= NA4; i++) if (inv4(x, A4NET[i], A4LEN[i])) return 1
  return 0
}
function allowed6(x,    i) {
  for (i = 1; i <= NA6; i++) if (substr(x, 1, length(A6PRE[i])) == A6PRE[i]) return 1
  return 0
}
# v6kind: "" when the address is not private, else "ip" or "mac" (EUI-64).
function v6kind(x,    g1) {
  g1 = hexval(substr(x, 1, 4))
  if (substr(x, 1, 8) == "20010db8" || allowed6(x)) return ""
  if (g1 >= 65152 && g1 <= 65215) {                # fe80::/10
    if (substr(x, 17, 12) == "000000000000") return ""
  } else if (!((g1 >= 8192 && g1 <= 16383) || (g1 >= 64512 && g1 <= 65023))) return ""
  if (substr(x, 23, 2) == "ff" && substr(x, 25, 2) == "fe") return "mac"
  return "ip"
}
# repl: literal replacement of val (mode s/i/w/n); records the kind.
function repl(s, val, ph, mode, kind,    L, ndl, hay, out, start, pos, ok, b, a) {
  L = length(val); if (L == 0) return s
  ndl = (mode == "s") ? val : tolower(val)
  hay = (mode == "s") ? s : tolower(s)
  out = ""; start = 1
  while ((pos = index(substr(hay, start), ndl)) > 0) {
    pos = start + pos - 1
    ok = 1
    if (mode == "w") ok = !(isletter(ch(s, pos - 1)) || isletter(ch(s, pos + L)))
    else if (mode == "n") {
      b = ch(s, pos - 1); a = ch(s, pos + L)
      if (isdigit(b) || (b == "." && isdigit(ch(s, pos - 2))) || isdigit(a) || (a == "." && isdigit(ch(s, pos + L + 1)))) ok = 0
    }
    if (ok) { out = out substr(s, start, pos - start) ph; start = pos + L; FOUND[kind] = 1 }
    else { out = out substr(s, start, pos - start + 1); start = pos + 1 }
  }
  return out substr(s, start)
}
# rxrepl: regex replacement; a match touching a char of class badb (before) or
# bada (after) is not replaced.
function rxrepl(s, re, ph, badb, bada, kind,    out, b, a, ok) {
  out = ""
  while (match(s, re)) {
    b = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ch(out, length(out))
    a = ch(s, RSTART + RLENGTH)
    ok = !((badb != "" && b != "" && b ~ badb) || (bada != "" && a != "" && a ~ bada))
    if (ok) { out = out substr(s, 1, RSTART - 1) ph; s = substr(s, RSTART + RLENGTH); FOUND[kind] = 1 }
    else { out = out substr(s, 1, RSTART); s = substr(s, RSTART + 1) }
  }
  return out s
}
# v6repl: every maximal [0-9A-Fa-f:] run with a colon that parses as a private
# IPv6 address (plus an optional %zone) becomes <IPV6>.
function v6repl(s,    out, t, b, a, x, k, st, end) {
  out = ""
  while (match(s, /[0-9A-Fa-f:]*:[0-9A-Fa-f:]*/)) {
    st = RSTART
    t = substr(s, RSTART, RLENGTH)
    b = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ch(out, length(out))
    end = RSTART + RLENGTH
    a = ch(s, end)
    k = ""
    if (!(b ~ /[G-Zg-z_]/ || a ~ /[G-Zg-z_]/ || (a == "." && isdigit(ch(s, end + 1))))) {
      x = expand6(t)
      if (x != "") k = v6kind(x)
    }
    if (k != "") {
      if (a == "%" && match(substr(s, end + 1), /^[A-Za-z0-9_.]+/)) end = end + 1 + RLENGTH
      out = out substr(s, 1, st - 1) "<IPV6>"; s = substr(s, end); FOUND[k] = 1
    } else { out = out substr(s, 1, end - 1); s = substr(s, end) }
  }
  return out s
}
# v4check (check mode only): any IPv4 (dotted or dashed) that is not allowed.
function v4ok(x) {
  if (x < 0) return 1
  if (inv4(x, v4num("127.0.0.0"), 8) || inv4(x, v4num("255.0.0.0"), 8) || x == 0) return 1
  if (inv4(x, v4num("10.42.0.0"), 16) || inv4(x, v4num("10.43.0.0"), 16)) return 1
  if (inv4(x, v4num("192.0.2.0"), 24) || inv4(x, v4num("198.51.100.0"), 24) || inv4(x, v4num("203.0.113.0"), 24)) return 1
  return allowed4(x)
}
function v4check(line,    s, off, q, pre, pre2, post, post2) {
  s = line; off = 0
  while (match(s, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
    q = substr(s, RSTART, RLENGTH)
    pre = substr(line, 1, off + RSTART - 1)
    post = ch(s, RSTART + RLENGTH); post2 = ch(s, RSTART + RLENGTH + 1)
    off += RSTART + RLENGTH - 1; s = substr(s, RSTART + RLENGTH)
    if (pre ~ /(^|[^A-Za-z])[vV]$/) continue                       # v1.2.3.4
    # 6.8.0-1.2.3.4: a 1-3 part version before a dash (a 4-part one is an IP range)
    if (pre ~ /(^|[^0-9.])[0-9]+-$/ || pre ~ /(^|[^0-9.])[0-9]+\.[0-9]+-$/ || pre ~ /(^|[^0-9.])[0-9]+\.[0-9]+\.[0-9]+-$/) continue
    if (post == "." && isdigit(post2)) continue                     # 1.7.2.1.5
    if (!v4ok(v4num(q))) FOUND["ip"] = 1
  }
  s = line; off = 0
  while (match(s, /[0-9]+-[0-9]+-[0-9]+-[0-9]+/)) {
    q = substr(s, RSTART, RLENGTH)
    pre = ch(line, off + RSTART - 1); pre2 = ch(line, off + RSTART - 2)
    post = ch(s, RSTART + RLENGTH)
    off += RSTART + RLENGTH - 1; s = substr(s, RSTART + RLENGTH)
    # ip-a-b-c-d is an address; 1.2-3-4-5-6 or 9-1-2-3-4-5 are not one
    if (isdigit(pre) || pre == "." || (pre == "-" && (isdigit(pre2) || pre2 == ".")) || post ~ /[0-9-]/) continue
    gsub(/-/, ".", q)
    if (!v4ok(v4num(q))) FOUND["ip"] = 1
  }
}
BEGIN {
  loadallow(ENVIRON["EV_ALLOW"])
  np = split(ENVIRON["EV_PAIRS"], rows, "\n")
  for (i = 1; i <= np; i++) {
    if (rows[i] == "") continue
    split(rows[i], f, "\t")
    n++; PHASE[n] = f[1]; MODE[n] = f[2]; VAL[n] = f[3]; PH[n] = f[4]; KIND[n] = f[5]
  }
  H = "[0-9A-Fa-f]"
  RE_UUID = H H H H H H H H "-" H H H H "-" H H H H "-" H H H H "-" H H H H H H H H H H H H
  RE_HEX32 = ""; for (i = 0; i < 32; i++) RE_HEX32 = RE_HEX32 H
  G = H H "?"
  RE_MACC = G ":" G ":" G ":" G ":" G ":" G
  RE_MACD = H H "-" H H "-" H H "-" H H "-" H H "-" H H
  RE_MACP = H H H H "\\." H H H H "\\." H H H H
  check = (ENVIRON["EV_MODE"] == "check")
}
{
  line = $0
  if (check) v4check(line)
  for (k = 1; k <= n; k++) if (PHASE[k] == 1) line = repl(line, VAL[k], PH[k], MODE[k], KIND[k])
  line = rxrepl(line, "/Users/[A-Za-z0-9._-]+", "/Users/<user>", "", "", "user-path")
  line = rxrepl(line, RE_UUID, "<UUID>", "", "", "uuid")
  line = v6repl(line)
  line = rxrepl(line, RE_MACC, "<MAC>", "[0-9A-Za-z:_]", "[0-9A-Za-z:_]", "mac")
  line = rxrepl(line, RE_MACD, "<MAC>", "[0-9A-Za-z_-]", "[0-9A-Za-z_-]", "mac")
  line = rxrepl(line, RE_MACP, "<MAC>", "[0-9A-Za-z_.]", "[0-9A-Za-z_.]", "mac")
  line = rxrepl(line, RE_HEX32, "<ID>", "[0-9A-Fa-f]", "[0-9A-Fa-f]", "uuid")
  for (k = 1; k <= n; k++) if (PHASE[k] == 3) line = repl(line, VAL[k], PH[k], MODE[k], KIND[k])
  if (!check) print line
}
END {
  if (BAD) exit 2
  if (check) {
    split("hostname user-path user mac ip uuid", order, " ")
    for (i = 1; i <= 6; i++) if (order[i] in FOUND) print order[i]
  }
}'

# _evidence_allowlist: path of the public-IP allowlist (may not exist).
_evidence_allowlist() {
  printf '%s\n' "${EVIDENCE_PUBLIC_IPS_FILE:-$_SCRUB_LIB_DIR/../../../config/evidence-public-ips.txt}"
}

# _evidence_scan <scrub|check> <file>: run the engine on a file (stdout).
_evidence_scan() {
  local allow
  allow="$(_evidence_allowlist)"
  if [ -n "${EVIDENCE_PUBLIC_IPS_FILE:-}" ] && [ ! -r "$allow" ]; then
    echo "check-evidence-clean: cannot read public-IP allowlist" >&2
    return 2
  fi
  [ -r "$allow" ] || allow=""
  EV_MODE="$1" EV_PAIRS="$(_evidence_pairs)" EV_ALLOW="$allow" LC_ALL=C awk "$_EVIDENCE_AWK" "$2"
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
  local file="$1" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/scrub.XXXXXX")" || return 1
  _evidence_scan scrub "$file" >"$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" >"$file" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}
