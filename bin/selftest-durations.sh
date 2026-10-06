#!/bin/sh
# selftest-durations.sh — refresh bin/selftest-durations.txt, the per-test cost table
# `run-selftests.sh --shard K/N` packs its shards by (issue #1390).
#
# Why a table at all: the stride split (every N-th of the sorted list) balances
# NEIGHBOURS, which is where cost used to cluster (`fleet-collect-*`), but it has no
# defense against a coincidence — six slow tests whose positions all differ by a
# multiple of N land in ONE shard. #1379 hit exactly that (458s in shard 1/6, three
# timeouts in a row against the 8-minute step bound), and #1722's full-suite run put
# 509s into shard 5/6 while greedy packing by measured time gives ~350s a shard.
# So the runner packs by cost now, and the cost comes from here.
#
# The runner already prints every test's duration (`PASS  <name>  12.3s`), so this
# script only parses runner output — a CI log, a local run — and rewrites the table:
#   • a test seen in the logs gets the MEDIAN of its observations (a run cut short or
#     re-attempted contributes what it printed; one slow sample does not dominate);
#   • a test not seen keeps its old value; a test whose file is gone is dropped;
#   • a test with no row at all is costed by the runner at the table's median, so a
#     new selftest needs no row to be scheduled — the table only has to be roughly
#     right, and it is refreshed when a shard's predicted load says so.
#
# Usage: selftest-durations.sh [--table FILE] [--run RUN_ID ...] [LOG ...]
#   LOG          a file of runner output (`-` or none = stdin, unless --run is given)
#   --run ID     fetch a GitHub Actions run's log (`gh run view ID --log`, every
#                attempt) — the ubuntu `selftests` workflow is the one to use: the
#                table is in ubuntu-runner seconds, which is the bound that matters
#   --table FILE the table to rewrite (default: bin/selftest-durations.txt beside this)
# Prints one line: how many rows were updated, kept, added and dropped.
set -u
unset CDPATH
here=$(cd -- "$(dirname -- "$0")" && pwd)
table="$here/selftest-durations.txt"
runs=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --table) [ "$#" -ge 2 ] || { echo "selftest-durations: --table needs a file" >&2; exit 2; }
             table=$2; shift 2 ;;
    --run)   [ "$#" -ge 2 ] || { echo "selftest-durations: --run needs a run id" >&2; exit 2; }
             runs="$runs $2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    --) shift; break ;;
    -?*) echo "selftest-durations: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

tmp=$(mktemp "${TMPDIR:-/tmp}/selftest-durations.XXXXXX") || exit 2
trap 'rm -f "$tmp" "$tmp.new"' EXIT
trap 'rm -f "$tmp" "$tmp.new"; exit 130' INT TERM HUP

for id in $runs; do
  case "$id" in ''|*[!0-9]*) echo "selftest-durations: run id must be numeric, got '$id'" >&2; exit 2 ;; esac
  n=$(gh api "repos/{owner}/{repo}/actions/runs/$id" --jq .run_attempt 2>/dev/null) || n=1
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  a=1
  while [ "$a" -le "$n" ]; do
    gh run view "$id" --attempt "$a" --log >> "$tmp" 2>/dev/null \
      || echo "selftest-durations: could not fetch run $id attempt $a" >&2
    a=$((a + 1))
  done
done
if [ "$#" -gt 0 ]; then
  cat -- "$@" >> "$tmp" || exit 2
elif [ -z "$runs" ]; then
  cat >> "$tmp"
fi

# The tests that exist now: the table never keeps a row for a deleted test.
present=$(cd "$here" && ls ./*-selftest.sh 2>/dev/null | sed 's|^\./||')

# Observations: `PASS  name  12.3s`, `FAIL  name  4.0s (exit 1)`, `TIMEOUT name 240.0s
# (limit 240s)` — anywhere on the line, so a CI log's job/step/timestamp prefix is fine.
grep -oE '(PASS|FAIL|TIMEOUT) +[A-Za-z0-9_.+-]+-selftest\.sh +[0-9]+(\.[0-9]+)?s' "$tmp" \
  | awk '{ v = $3; sub(/s$/, "", v); print $2, v }' > "$tmp.new"

[ -f "$table" ] || : > "$table"
printf '%s\n' "$present" | awk -v obs="$tmp.new" -v tbl="$table" '
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
       if ($1 in seen) { v = sprintf("%.1f", median($1)); if ($1 in old) upd++; else add++ }
       else if ($1 in old) { v = old[$1]; kept++ }
       else next
       rows[$1] = v }
  END {
    for (t in old) if (!(t in present)) dropped++
    printf "%s", head > (tbl ".tmp")
    for (t in rows) printf "%s %s\n", rows[t], t | ("LC_ALL=C sort -k2 >> \"" tbl ".tmp\"")
    close("LC_ALL=C sort -k2 >> \"" tbl ".tmp\"")
    printf "selftest-durations: %d updated, %d added, %d kept, %d dropped\n", upd, add, kept, dropped
  }' || exit 1
mv -f "$table.tmp" "$table"
