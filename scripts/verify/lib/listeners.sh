#!/usr/bin/env bash
# Parsers for listener / port-scan output. Source this file (bash 3.2+, awk only).
# All functions print one item per line, sorted in the C locale and de-duplicated.
# Exit 2 on a usage error or an unreadable file, so a caller can never mistake a
# missing input for "no listeners".

# lima_listeners <lsof_file> [<pid_file>]
# Input: `lsof -nP -iTCP -sTCP:LISTEN` or `lsof -nP -iUDP` output. Prints the
# NAME column (e.g. 127.0.0.1:6443, *:443, [::1]:6443) of rows whose COMMAND is
# limactl or ssh. Bound/listening sockets only:
#   - rows whose NAME contains "->" (connected sockets, e.g. outbound UDP
#     a->b; a connected socket only accepts datagrams from its peer) are dropped,
#     so peer addresses never reach the output;
#   - TCP rows whose state is not "(LISTEN)" (ESTABLISHED, CLOSE_WAIT, ...) are
#     dropped.
# With <pid_file> (one PID per line) only rows whose PID column is listed are
# kept, in addition to the COMMAND condition; an empty pid file gives empty
# output. Without it every limactl/ssh row on the Mac is reported.
# Note: C-locale sort puts 127.0.0.1:60022 before 127.0.0.1:6443, and *: before
# 127. before [ ; callers that build an expected list must sort with LC_ALL=C.
lima_listeners() {
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "lima_listeners: usage: lima_listeners <lsof_file> [<pid_file>]" >&2
    return 2
  fi
  local f
  for f in "$@"; do
    if [ ! -r "$f" ] || [ -d "$f" ]; then
      echo "lima_listeners: cannot read $f" >&2
      return 2
    fi
  done
  LC_ALL=C awk -v pidf="${2:-}" '
    BEGIN {
      usepid = (pidf != "")
      if (usepid) {
        while ((getline l < pidf) > 0) { sub(/[ \t\r]+$/, "", l); sub(/^[ \t]+/, "", l); if (l ~ /^[0-9]+$/) want[l] = 1 }
        close(pidf)
      }
    }
    NR > 1 || $1 != "COMMAND" {
      if ($1 != "limactl" && $1 != "ssh") next
      if (usepid && !($2 in want)) next
      name = $NF
      if (name ~ /^\(/ && NF > 1) {          # TCP rows end in "(STATE)"
        if (name != "(LISTEN)") next
        name = $(NF - 1)
      }
      if (index(name, "->") > 0) next        # connected socket, not a listener
      if (name != "") print name
    }' "$1" | LC_ALL=C sort -u
}

# guest_listeners <ss_file>
# Input: `ss -Hltnu` output (no header). Prints "proto addr:port"; the %iface
# suffix of a local address (127.0.0.53%lo:53) is dropped.
guest_listeners() {
  if [ "$#" -ne 1 ]; then
    echo "guest_listeners: usage: guest_listeners <ss_file>" >&2
    return 2
  fi
  if [ ! -r "$1" ] || [ -d "$1" ]; then
    echo "guest_listeners: cannot read $1" >&2
    return 2
  fi
  LC_ALL=C awk '
    NF >= 5 && ($1 == "tcp" || $1 == "udp") {
      addr = $5
      sub(/%[^:]*:/, ":", addr)
      print $1 " " addr
    }' "$1" | LC_ALL=C sort -u
}

# _gnmap_field <line> <name>: awk helper source. Fields of a -oG Host line are
# normally tab separated; an editor may have expanded the tabs, so a field
# ends at a tab, at the next known field name, or at the end of the line.
_GNMAP_AWK_FIELD='
  function gfield(line, name,    p, rest, q, cut, k) {
    p = index(line, name ": ")
    if (p == 0) return ""
    rest = substr(line, p + length(name) + 2)
    cut = length(rest) + 1
    q = index(rest, "\t"); if (q > 0 && q < cut) cut = q
    split("Ignored State:|Status:|Ports:|Protocols:|OS:|Seq Index:|IP ID Seq:", stop, "|")
    for (k in stop) { q = index(rest, stop[k]); if (q > 0 && q < cut) cut = q }
    rest = substr(rest, 1, cut - 1)
    sub(/[ \t\r]+$/, "", rest)
    return rest
  }'

# open_tcp_ports <gnmap_file>
# Input: `nmap -oG` output. Prints the TCP ports whose state is exactly "open",
# ascending and unique (filtered, closed, open|filtered and UDP are excluded).
open_tcp_ports() {
  if [ "$#" -ne 1 ]; then
    echo "open_tcp_ports: usage: open_tcp_ports <gnmap_file>" >&2
    return 2
  fi
  if [ ! -r "$1" ] || [ -d "$1" ]; then
    echo "open_tcp_ports: cannot read $1" >&2
    return 2
  fi
  LC_ALL=C awk "$_GNMAP_AWK_FIELD"'
    /^Host: / {
      list = gfield($0, "Ports")
      if (list == "") next
      n = split(list, ent, /,/)
      for (j = 1; j <= n; j++) {
        e = ent[j]; gsub(/^[ \t]+|[ \t]+$/, "", e)
        split(e, f, "/")
        if (f[2] == "open" && f[3] == "tcp" && f[1] ~ /^[0-9]+$/) print f[1]
      }
    }' "$1" | LC_ALL=C sort -n -u
}

# nmap_port_totals <gnmap_file>
# Prints, for every Host line that carries a Ports or Ignored State field, the
# number of ports nmap accounted for: listed entries + the "Ignored State" count.
# A full-range TCP scan (-p-) of one host prints exactly 65535.
nmap_port_totals() {
  if [ "$#" -ne 1 ]; then
    echo "nmap_port_totals: usage: nmap_port_totals <gnmap_file>" >&2
    return 2
  fi
  if [ ! -r "$1" ] || [ -d "$1" ]; then
    echo "nmap_port_totals: cannot read $1" >&2
    return 2
  fi
  LC_ALL=C awk "$_GNMAP_AWK_FIELD"'
    /^Host: / {
      list = gfield($0, "Ports"); ign = gfield($0, "Ignored State")
      if (list == "" && ign == "") next
      total = 0
      if (list != "") total += split(list, ent, /,/)
      if (match(ign, /\([0-9]+\)/)) total += substr(ign, RSTART + 1, RLENGTH - 2) + 0
      print total
    }' "$1"
}
