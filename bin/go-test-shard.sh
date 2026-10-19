#!/bin/sh
# go-test-shard.sh — deal one Go package's tests into N shards by their recorded
# cost, and say how many shards a package needs (issue #4817, EPIC #4810 C7).
#
#   go-test-shard.sh deal  --table F --pkg P --shard K/N   < test names
#       the K-th shard's tests, one per line; a `predicted:` line on stderr
#   go-test-shard.sh loads --table F --pkg P --shards N    < test names
#       every shard's predicted load and test count, one `K/N <secs>s <n>` line each
#   go-test-shard.sh count --table F --pkg P [--per S] [--min A] [--max B] [--default D]
#       how many shards: ⌈the package's recorded seconds ÷ S⌉ (default 240 — four
#       minutes a shard), clamped to A..B (1..8); D (3) when the table has no row
#       for the package
#   go-test-shard.sh sum   --table F --pkg "P1 P2 …"
#       the packages' recorded seconds together — a whole-package part's prediction
#
# Why: hub/api's tests were split round-robin by name (every API_SHARDS-th of
# `go test -list`), which balances counts, not seconds — one shard dragged the PR.
# Now the split is the selftests' (run-selftests.sh --shard, issue #1390): longest
# first, each into the lightest shard so far (ties → the lowest K), so every shard
# computes the same deal from the same list and the N shards partition it.
#
# The table (tokenledger/test-durations.txt for the -race leg,
# tokenledger/test-durations-pg.txt for the Postgres leg) is one row per test,
# `<seconds>\t<package>.<Test>` where <package> is the import path under
# tokenledger/ (hub/api); `#` lines are comments. A test with no row costs the
# median of the package's rows (else of the whole table; an empty table ⇒ 1 each,
# which is exactly a round-robin by name). Refresh it with bin/go-test-durations.sh.
set -u
ME=go-test-shard
die() { printf '%s: %s\n' "$ME" "$*" >&2; exit 2; }

cmd=${1:-}
case "$cmd" in
  '') awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0" >&2; exit 2 ;;
  -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0"; exit 0 ;;
esac
shift
table='' pkg='' shard='' shards='' per=240 min=1 max=8 dflt=3
while [ "$#" -gt 0 ]; do
  case "$1" in
    --table) table=${2:-}; shift 2 ;;
    --pkg) pkg=${2:-}; shift 2 ;;
    --shard) shard=${2:-}; shift 2 ;;
    --shards) shards=${2:-}; shift 2 ;;
    --per) per=${2:-}; shift 2 ;;
    --min) min=${2:-}; shift 2 ;;
    --max) max=${2:-}; shift 2 ;;
    --default) dflt=${2:-}; shift 2 ;;
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0"; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[ -n "$pkg" ] || die "--pkg is required"
[ -z "$table" ] || [ -f "$table" ] || table=''   # no table ⇒ every test costs the same

case "$cmd" in
  sum)
    awk -v pkgs=" $pkg " '
      /^[[:space:]]*(#|$)/ { next }
      { p = $2; sub(/\.[^.]*$/, "", p); if (index(pkgs, " " p " ")) s += $1 }
      END { printf "%.0f\n", s }' "${table:-/dev/null}"
    exit 0 ;;
  count)
    for v in "$per" "$min" "$max" "$dflt"; do
      case "$v" in ''|*[!0-9]*) die "--per/--min/--max/--default want whole numbers" ;; esac
    done
    [ "$per" -ge 1 ] || die "--per must be at least 1"
    awk -v pkg="$pkg" -v per="$per" -v lo="$min" -v hi="$max" -v d="$dflt" '
      /^[[:space:]]*(#|$)/ { next }
      { p = $2; sub(/\.[^.]*$/, "", p); if (p == pkg) { s += $1; n++ } }
      END {
        if (!n) k = d; else { k = int(s / per); if (k * per < s) k++ }
        if (k < lo) k = lo; if (k > hi) k = hi
        print k
      }' "${table:-/dev/null}"
    exit 0 ;;
  deal)
    case "$shard" in
      [0-9]*/[0-9]*) k=${shard%%/*} n=${shard##*/} ;;
      *) die "--shard wants K/N, got '$shard'" ;;
    esac
    case "$k$n" in *[!0-9]*) die "--shard wants K/N, got '$shard'" ;; esac
    [ "$n" -ge 1 ] && [ "$k" -ge 1 ] && [ "$k" -le "$n" ] || die "--shard K must be 1..N, got '$shard'" ;;
  loads)
    case "$shards" in ''|*[!0-9]*) die "--shards wants N" ;; esac
    [ "$shards" -ge 1 ] || die "--shards wants N ≥ 1"
    k=0 n=$shards ;;
  *) die "unknown command '$cmd' (deal · loads · count)" ;;
esac

# names on stdin → "<cost> <name>" (the package's rows, a median for the rest),
# longest first (ties by name), then the greedy deal
tmp=$(mktemp "${TMPDIR:-/tmp}/$ME.XXXXXX") || exit 2
trap 'rm -f "$tmp"' EXIT
grep -E '^[A-Za-z_][A-Za-z0-9_]*$' > "$tmp" || :
awk -v pkg="$pkg" -v tbl="${table:-/dev/null}" '
  function med(a, n,    i, j, x) {
    for (i = 2; i <= n; i++) { x = a[i]; for (j = i - 1; j >= 1 && a[j] > x; j--) a[j + 1] = a[j]; a[j + 1] = x }
    return (n % 2) ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2
  }
  BEGIN {
    while ((getline l < tbl) > 0) {
      if (l ~ /^[[:space:]]*(#|$)/) continue
      split(l, f, /[ \t]+/)
      all[++na] = f[1] + 0
      p = pkg "."
      if (substr(f[2], 1, length(p)) == p) { cost[substr(f[2], length(p) + 1)] = f[1] + 0; mine[++nm] = f[1] + 0 }
    }
    if (nm) m = med(mine, nm); else if (na) m = med(all, na); else m = 1
    if (m <= 0) m = 0.01
  }
  { c = ($1 in cost) ? cost[$1] : m; printf "%.3f %s\n", c, $1 }' "$tmp" \
  | LC_ALL=C sort -k1,1nr -k2,2 \
  | awk -v n="$n" -v k="$k" -v cmd="$cmd" '
      BEGIN { for (i = 1; i <= n; i++) load[i] = 0 }
      { best = 1; for (i = 2; i <= n; i++) if (load[i] < load[best]) best = i
        load[best] += $1; cnt[best]++
        if (best == k) print $2; tot += $1 }
      END {
        if (cmd == "loads") { for (i = 1; i <= n; i++) printf "%d/%d %.0fs %d\n", i, n, load[i], cnt[i] }
        else printf "predicted: shard %d/%d %d of %d tests, ~%.0fs (all %d shards ~%.0fs)\n", k, n, cnt[k], NR, load[k], n, tot > "/dev/stderr"
      }' \
  | { if [ "$cmd" = deal ]; then LC_ALL=C sort; else cat; fi; }
