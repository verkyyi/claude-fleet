#!/bin/sh
# go-test-durations.sh — refresh the Go tests' cost table bin/go-test-shard.sh deals
# the shards by (issue #4817, EPIC #4810 C7): tokenledger/test-durations.txt (the
# -race leg), or with --pg tokenledger/test-durations-pg.txt (the Postgres leg).
#
# Usage: go-test-durations.sh [--pg] [--table FILE] [--run RUN_ID ...] [LOG ...]
#   LOG          `go test -v` output (`-` or none = stdin, unless --run is given);
#                a CI log's per-line prefix (job, step, timestamp) is fine
#   --run ID     a GitHub Actions run that called tokenledger.yml: its logs, uploaded
#                per shard as artifacts — `go-log-<part>` (the -race leg) or, with
#                --pg, `pg-log-<part>` (`gh run download ID --pattern …`)
#   --pg         the Postgres table
#   --table FILE the table to rewrite (default: the leg's, under tokenledger/)
#
# Reads every top-level `--- PASS|FAIL: TestX (1.23s)` (a subtest's line names
# TestX/sub and is its parent's business) and gives it to the package whose
# `ok  <import path>` / `FAIL  <import path>` line closes its output — `go test -v`
# prints a package's output whole, then that line; each file is its own stream, and
# a CI log's per-line prefix keeps two jobs apart. A cached package (`ok … (cached)`)
# replays its lines with the times it was measured at, so a cached run still counts.
#   • a test seen gets the MEDIAN of its observations;
#   • a test not seen keeps its row; a test whose func is gone from its package's
#     *_test.go files is dropped;
# Rows are `<seconds>\t<package>.<Test>`, <package> the import path under
# tokenledger/ (hub/api). Prints one line: updated, added, kept, dropped.
set -u
unset CDPATH
here=$(cd -- "$(dirname -- "$0")" && pwd)
tl=$(cd -- "$here/../tokenledger" && pwd)
MODPFX=github.com/verkyyi/claude-fleet/tokenledger/
table='' runs='' pg=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --table) [ "$#" -ge 2 ] || { echo "go-test-durations: --table needs a file" >&2; exit 2; }
             table=$2; shift 2 ;;
    --pg) pg=1; shift ;;
    --run) [ "$#" -ge 2 ] || { echo "go-test-durations: --run needs a run id" >&2; exit 2; }
           runs="$runs $2"; shift 2 ;;
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0"; exit 0 ;;
    --) shift; break ;;
    -?*) echo "go-test-durations: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
if [ -z "$table" ]; then
  if [ -n "$pg" ]; then table="$tl/test-durations-pg.txt"; else table="$tl/test-durations.txt"; fi
fi
art='go-log'
[ -z "$pg" ] || art='pg-log'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/go-test-durations.XXXXXX") || exit 2
trap 'rm -rf "${tmp:?}"' EXIT
trap 'rm -rf "${tmp:?}"; exit 130' INT TERM HUP

for id in $runs; do
  case "$id" in ''|*[!0-9]*) echo "go-test-durations: run id must be numeric, got '$id'" >&2; exit 2 ;; esac
  gh run download "$id" --pattern "$art-*" --dir "$tmp/run-$id" >/dev/null 2>&1 \
    || echo "go-test-durations: could not fetch run $id's $art-* artifacts" >&2
done
if [ "$#" -gt 0 ]; then
  i=0
  for f in "$@"; do i=$((i + 1)); cat -- "$f" > "$tmp/arg-$i.log" || exit 2; done
elif [ -z "$runs" ]; then
  cat > "$tmp/stdin.log"
fi
logs=$(find "$tmp" -type f -name '*.log' | LC_ALL=C sort)
[ -n "$logs" ] || { echo "go-test-durations: no log to read" >&2; exit 1; }

# observations: "<package>.<Test> <secs>", each test given to the package line
# that closes its stream (a stream = one file, and in it the line's prefix with
# its timestamp taken out)
# shellcheck disable=SC2086  # a file list on purpose
awk -v pfx="$MODPFX" '
  function stream(l, at,    s) {
    s = substr(l, 1, at - 1)
    gsub(/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z/, "", s)
    return FILENAME SUBSEP s
  }
  FNR == 1 { split("", buf) }
  {
    if (match($0, /--- (PASS|FAIL): [A-Za-z_][A-Za-z0-9_]* \([0-9.]+s\)/)) {
      s = stream($0, RSTART)
      split(substr($0, RSTART, RLENGTH), f, /[ ()]+/)
      v = f[4]; sub(/s$/, "", v)
      buf[s] = buf[s] f[3] " " v "\n"
      next
    }
    if (match($0, /(ok|FAIL)[ \t]+github\.com\/[^ \t]+/)) {
      s = stream($0, RSTART)
      split(substr($0, RSTART, RLENGTH), f, /[ \t]+/)
      p = f[2]
      if (substr(p, 1, length(pfx)) != pfx || !(s in buf)) { delete buf[s]; next }
      p = substr(p, length(pfx) + 1)
      n = split(buf[s], ls, "\n")
      for (i = 1; i <= n; i++) if (ls[i] != "") { split(ls[i], t, " "); print p "." t[1], t[2] }
      delete buf[s]
    }
  }' $logs > "$tmp/obs"

# the tests that exist now, for every package the table or the logs name
{ awk '!/^[[:space:]]*(#|$)/ { sub(/\.[^.]*$/, "", $2); print $2 }' "$table" 2>/dev/null
  awk '{ sub(/\.[^.]*$/, "", $1); print $1 }' "$tmp/obs"; } | sort -u | while read -r p; do
  [ -d "$tl/$p" ] || continue
  for f in "$tl/$p"/*_test.go; do
    [ -f "$f" ] || continue
    sed -nE 's/^func ((Test|Fuzz|Example)[A-Za-z0-9_]*)\(.*/\1/p' "$f"
  done | sed "s|^|$p.|"
done > "$tmp/present"

[ -f "$table" ] || : > "$table"
awk -v obs="$tmp/obs" -v tbl="$table" '
  function median(t,    n, i, j, x, a) {
    n = split(seen[t], a, " ")
    for (i = 2; i <= n; i++) { x = a[i] + 0; for (j = i - 1; j >= 1 && a[j] + 0 > x; j--) a[j + 1] = a[j]; a[j + 1] = x }
    return (n % 2) ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2
  }
  BEGIN {
    while ((getline l < obs) > 0) { split(l, f, " "); seen[f[1]] = seen[f[1]] " " f[2] }
    while ((getline l < tbl) > 0) {
      if (l ~ /^[[:space:]]*(#|$)/) { if (!body) head = head l "\n"; continue }
      body = 1; split(l, f, /[ \t]+/); old[f[2]] = f[1]
    }
  }
  NF { present[$1] = 1
       if ($1 in seen) { v = sprintf("%.2f", median($1)); if ($1 in old) upd++; else add++ }
       else if ($1 in old) { v = old[$1]; kept++ }
       else next
       rows[$1] = v }
  END {
    for (t in old) if (!(t in present)) dropped++
    printf "%s", head > (tbl ".tmp")
    for (t in rows) printf "%s\t%s\n", rows[t], t | ("LC_ALL=C sort -t \"\t\" -k2 >> \"" tbl ".tmp\"")
    close("LC_ALL=C sort -t \"\t\" -k2 >> \"" tbl ".tmp\"")
    printf "go-test-durations: %d updated, %d added, %d kept, %d dropped\n", upd, add, kept, dropped
  }' "$tmp/present" || exit 1
mv -f "$table.tmp" "$table"
