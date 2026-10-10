# fleet-redact.awk — bin/fleet_redact.py for a computer with no working Python
# (issue #2890, EPIC #2889 C1): the same table, conf/secret-shapes.list, the same
# bytes out (doctor-bundle-selftest.sh pins it). POSIX awk — BSD awk, mawk, gawk;
# run it under LC_ALL=C so it walks bytes, as the Python copy does.
#
#   LC_ALL=C awk -v table=conf/secret-shapes.list [-v stats=F] -f fleet-redact.awk [in]
#   LC_ALL=C awk -v table=… -v mode=check -f fleet-redact.awk FILE…   FILE<TAB>shape per hit; exit 1
#
# Line by line: the open block shape first (its lines dropped, the end line's rest
# kept), then each row in table order, left to right — a `value` match that
# follows [A-Za-z0-9_] is skipped and the search goes on one byte later.
# Exit 2: the table is missing or a row breaks its rules (fleet_redact.py --lint
# says which).

function die(msg) { printf "fleet-redact.awk: %s\n", msg > "/dev/stderr"; bad = 1; exit 2 }

# vsearch(i, s, from) — the leftmost match of row i in s at or after byte `from`;
# sets M_S / M_L (1-based start, length), 0 when none.
function vsearch(i, s, from,    rest, off) {
  while (from <= length(s) + 1) {
    rest = substr(s, from)
    if (!match(rest, RE[i])) return 0
    if (RLENGTH == 0) return 0
    off = from + RSTART - 1
    if (KIND[i] == "value" && off > 1 && substr(s, off - 1, 1) ~ /[A-Za-z0-9_]/) { from = off + 1; continue }
    M_S = off; M_L = RLENGTH
    return 1
  }
  return 0
}

BEGIN {
  if (table == "") die("no table (-v table=conf/secret-shapes.list)")
  n = 0
  while ((r = (getline row < table)) > 0) {
    if (row ~ /^[ \t]*$/ || substr(row, 1, 1) == "#") continue
    k = split(row, f, "\t")
    if (k < 3 || (f[2] != "value" && f[2] != "text" && f[2] != "block") || ((f[2] == "block") != (k == 4)))
      die(table ": bad row: " row)
    n++; NAME[n] = f[1]; KIND[n] = f[2]; RE[n] = f[3]; END_RE[n] = (k == 4 ? f[4] : "")
    TOK[n] = "<redacted:" f[1] ">"; CNT[n] = 0
  }
  if (r < 0) die("cannot read " table)
  if (n == 0) die(table ": no shapes")
  close(table)
  inside = 0; rc = 0
}

mode == "check" {
  if (FNR == 1) { delete HIT }
  for (i = 1; i <= n; i++) {
    if (i in HIT) continue
    if (KIND[i] == "block" ? match($0, RE[i]) : vsearch(i, $0, 1)) {
      HIT[i] = 1; printf "%s\t%s\n", FILENAME, NAME[i]; rc = 1
    }
  }
  next
}

{
  line = $0
  if (inside) {
    if (!match(line, END_RE[inside])) next
    line = substr(line, RSTART + RLENGTH); inside = 0
    if (line == "") next
  }
  for (i = 1; i <= n && !inside; i++) {
    if (KIND[i] != "block") continue
    pos = 1
    while (pos <= length(line) + 1) {
      rest = substr(line, pos)
      if (!match(rest, RE[i])) break
      s = pos + RSTART - 1; after = substr(line, s + RLENGTH)
      CNT[i]++
      if (!match(after, END_RE[i])) { line = substr(line, 1, s - 1) TOK[i]; inside = i; break }
      line = substr(line, 1, s - 1) TOK[i] substr(after, RSTART + RLENGTH)
      pos = s + length(TOK[i])
    }
  }
  for (i = 1; i <= n; i++) {
    if (KIND[i] == "block") continue
    out = ""; pos = 1; got = 0
    while (vsearch(i, line, pos)) {
      out = out substr(line, pos, M_S - pos) TOK[i]
      CNT[i]++; got = 1
      pos = M_S + M_L
    }
    if (got) line = out substr(line, pos)
  }
  print line
}

END {
  if (bad) exit 2
  if (mode == "check") exit rc
  if (stats != "") {
    printf "" > stats
    for (i = 1; i <= n; i++) if (CNT[i] > 0) printf "%s\t%d\n", NAME[i], CNT[i] > stats
    close(stats)
  }
}
