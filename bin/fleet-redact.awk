# fleet-redact.awk — bin/fleet_redact.py for a computer with no working Python
# (issue #2890, EPIC #2889 C1): the same table, conf/secret-shapes.list, the same
# bytes out (doctor-bundle-selftest.sh pins it). POSIX awk — BSD awk, mawk, gawk;
# run it under LC_ALL=C so it walks bytes, as the Python copy does.
#
#   LC_ALL=C awk -v table=conf/secret-shapes.list [-v stats=F] -f fleet-redact.awk [in]
#   LC_ALL=C awk -v table=… -v mode=check -f fleet-redact.awk FILE…   FILE<TAB>shape per hit; exit 1
#
# Line by line: an open `#@block` first (its lines dropped, the end line's rest
# kept; a begin whose end is not on its line opens one), then every row top to
# bottom, each over the whole line (gsub — fleet_clientlog's own semantics).
# Exit 2: the table cannot be read (fleet_redact.py --lint says what is wrong
# with a row).

function die(msg) { printf "fleet-redact.awk: %s\n", msg > "/dev/stderr"; bad = 1; exit 2 }
function cnt(name, k) { if (!(name in CNT)) { ORD[++no] = name; CNT[name] = 0 } CNT[name] += k }

BEGIN {
  if (table == "") die("no table (-v table=conf/secret-shapes.list)")
  n = 0; nb = 0; no = 0
  while ((r = (getline row < table)) > 0) {
    k = split(row, f, "\t")
    if (f[1] == "#@block") {
      if (k != 4) die(table ": bad #@block: " row)
      nb++; BNAME[nb] = f[2]; BRE[nb] = f[3]; BEND[nb] = f[4]
      continue
    }
    if (substr(row, 1, 1) == "#" || k < 2) continue
    if (k != 2) die(table ": bad row: " row)
    n++; NAME[n] = f[1]; RE[n] = f[2]; TOK[n] = "<redacted:" f[1] ">"
  }
  if (r < 0) die("cannot read " table)
  if (n == 0) die(table ": no shapes")
  close(table)
  inside = 0; rc = 0
}

mode == "check" {
  if (FNR == 1) { delete HIT }
  for (i = 1; i <= nb; i++)
    if (!(BNAME[i] in HIT) && match($0, BRE[i])) { HIT[BNAME[i]] = 1; printf "%s\t%s\n", FILENAME, BNAME[i]; rc = 1 }
  for (i = 1; i <= n; i++)
    if (!(NAME[i] in HIT) && match($0, RE[i])) { HIT[NAME[i]] = 1; printf "%s\t%s\n", FILENAME, NAME[i]; rc = 1 }
  next
}

{
  line = $0
  if (inside) {
    if (!match(line, BEND[inside])) next
    line = substr(line, RSTART + RLENGTH); inside = 0
    if (line == "") next
  }
  for (i = 1; i <= nb; i++) {
    if (!match(line, BRE[i])) continue
    s = RSTART
    if (match(substr(line, s + RLENGTH), BEND[i])) continue
    cnt(BNAME[i], 1)
    line = substr(line, 1, s - 1) "<redacted:" BNAME[i] ">"; inside = i
    break
  }
  for (i = 1; i <= n; i++) {
    k = gsub(RE[i], TOK[i], line)
    if (k) cnt(NAME[i], k)
  }
  print line
}

END {
  if (bad) exit 2
  if (mode == "check") exit rc
  if (stats != "") {
    printf "" > stats
    # the table's order, as the Python copy writes it: blocks, then rows
    for (i = 1; i <= nb; i++) if (BNAME[i] in CNT && !(BNAME[i] in DONE)) { DONE[BNAME[i]] = 1; printf "%s\t%d\n", BNAME[i], CNT[BNAME[i]] > stats }
    for (i = 1; i <= n; i++) if (NAME[i] in CNT && !(NAME[i] in DONE)) { DONE[NAME[i]] = 1; printf "%s\t%d\n", NAME[i], CNT[NAME[i]] > stats }
    close(stats)
  }
}
