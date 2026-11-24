#!/usr/bin/env bash
# Parsers for listener / port-scan output. Source this file (bash 3.2+, awk only).
# All functions print one item per line, sorted in the C locale and de-duplicated.
# Exit 2 on a usage error or an unreadable file, so a caller can never mistake a
# missing input for "no listeners".

# lima_listeners <lsof_file>
# Input: `lsof -nP -iTCP -sTCP:LISTEN` or `lsof -nP -iUDP` output. Prints the
# NAME column (e.g. 127.0.0.1:6443, *:443) of rows whose COMMAND is limactl or ssh.
# Note: C-locale sort puts 127.0.0.1:60022 before 127.0.0.1:6443.
lima_listeners() {
  if [ "$#" -ne 1 ]; then
    echo "lima_listeners: usage: lima_listeners <lsof_file>" >&2
    return 2
  fi
  if [ ! -r "$1" ] || [ -d "$1" ]; then
    echo "lima_listeners: cannot read $1" >&2
    return 2
  fi
  LC_ALL=C awk '
    NR > 1 || $1 != "COMMAND" {
      if ($1 != "limactl" && $1 != "ssh") next
      name = $NF
      if (name ~ /^\(/ && NF > 1) name = $(NF - 1)   # TCP rows end in "(LISTEN)"
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
  LC_ALL=C awk -F'\t' '
    /^Host: / {
      for (i = 1; i <= NF; i++) {
        if (substr($i, 1, 7) != "Ports: ") continue
        list = substr($i, 8)
        n = split(list, ent, /, */)
        for (j = 1; j <= n; j++) {
          split(ent[j], f, "/")
          if (f[2] == "open" && f[3] == "tcp" && f[1] ~ /^[0-9]+$/) print f[1]
        }
      }
    }' "$1" | LC_ALL=C sort -n -u
}
