#!/usr/bin/env bash
# tokenledger-flaky.sh — which Go tests make tokenledger.yml red by luck (issue #4679,
# EPIC #4810 C8). ONE command for the before / after table the issue asks for.
#
# A run of .github/workflows/tokenledger.yml that went green on a later attempt
# (run_attempt > 1, conclusion success) was red by luck on the same commit: every
# failed job of its earlier attempts is fetched (REST, never GraphQL) and its
# `--- FAIL: <Test>` lines counted, one per (job, test). A failed job with no FAIL
# line is counted under its last `panic:` / timeout line, so a whole-package
# timeout is not lost.
#
# Usage: tokenledger-flaky.sh [--days N] [--since YYYY-MM-DD] [--repo owner/name] [--top N]
#   --days N      look back N days from now (default 30)
#   --since DATE  look back to DATE instead
#   --top N       print the N most frequent (default 25)
# Prints:
#   retried-green runs: <n> (of <m> runs since <date>)
#   <count> <test>  <first>..<last>  go=<n> pg=<n>
# Job logs never change, so they are cached under ${TMPDIR:-/tmp}/tokenledger-flaky/.
set -euo pipefail

repo=verkyyi/claude-fleet
days=30
since=
top=25
while [ $# -gt 0 ]; do
  case "$1" in
    --days) days=$2; shift 2 ;;
    --since) since=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --top) top=$2; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "tokenledger-flaky: unknown argument $1" >&2; exit 2 ;;
  esac
done
if [ -z "$since" ]; then
  since=$(python3 -c 'import datetime,sys; print((datetime.date.today()-datetime.timedelta(days=int(sys.argv[1]))).isoformat())' "$days")
fi

cache=${TMPDIR:-/tmp}/tokenledger-flaky
mkdir -p "$cache/logs"
work=$(mktemp -d "${TMPDIR:-/tmp}/tokenledger-flaky.XXXXXX")
trap 'rm -rf "${work:?}"' EXIT

# The runs list is capped at 1000 per query: walk it a day at a time.
python3 - "$since" > "$work/days" <<'PY'
import datetime, sys
d = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%d").date(); end = datetime.date.today()
while d <= end:
    print(d.isoformat()); d += datetime.timedelta(days=1)
PY
: > "$work/runs"
# Since issue #4815 a PR's Go tests are the PR gate's (ci.yml) `tokenledger / …`
# jobs; tokenledger.yml's own runs are the older PRs and a dispatch. A ci run
# counts only when an earlier attempt had a failed tokenledger job.
while read -r d; do
  for wfy in tokenledger.yml ci.yml; do
    gh api --paginate "repos/$repo/actions/workflows/$wfy/runs?per_page=100&created=$d" \
      --jq '.workflow_runs[]|[.id,.run_attempt,.conclusion,(.created_at|.[0:10]),"'"$wfy"'"]|@tsv' >> "$work/runs" || true   # no ci.yml before #4815
  done
done < "$work/days"
total=$(sort -u "$work/runs" | wc -l | tr -d ' ')
sort -u "$work/runs" | awk -F'\t' '$2>1 && $3=="success"' > "$work/retried"

: > "$work/hits"
while IFS=$'\t' read -r id att _ day wfy; do
  a=1
  while [ "$a" -lt "$att" ]; do
    gh api "repos/$repo/actions/runs/$id/attempts/$a/jobs?per_page=50" \
      --jq '.jobs[]|select(.conclusion=="failure")|[.id,.name]|@tsv' |
    while IFS=$'\t' read -r jid jname; do
      [ "$wfy" != ci.yml ] || case "$jname" in "tokenledger / "*) ;; *) continue ;; esac
      echo "$id" >> "$work/hitruns"
      log="$cache/logs/$jid.log"
      [ -s "$log" ] || gh api --allow-escape-sequences "repos/$repo/actions/jobs/$jid/logs" > "$log" 2>/dev/null || true
      case "$jname" in *pg*) leg=pg ;; *) leg=go ;; esac
      tests=$(grep -oE -- '--- FAIL: [A-Za-z0-9_]+' "$log" | sed 's/^--- FAIL: //' | sort -u || true)
      if [ -z "$tests" ]; then
        tests=$(grep -oE 'panic: test timed out after [0-9a-z]+|panic: [A-Za-z ]+' "$log" | tail -1 | tr ' ' '_' || true)
        [ -n "$tests" ] || tests="(no-FAIL-line)"
      fi
      for t in $tests; do printf '%s\t%s\t%s\n' "$t" "$day" "$leg" >> "$work/hits"; done
    done
    a=$((a + 1))
  done
done < "$work/retried"
n=$({ awk -F'\t' '$5 != "ci.yml" { print $1 }' "$work/retried"; cat "$work/hitruns" 2>/dev/null; } | sort -u | wc -l | tr -d ' ')
echo "retried-green runs: $n (of $total runs since $since)"

awk -F'\t' '{
  c[$1]++; l[$1, $3]++
  if (!($1 in f) || $2 < f[$1]) f[$1] = $2
  if ($2 > z[$1]) z[$1] = $2
} END {
  for (t in c) printf "%4d %s  %s..%s  go=%d pg=%d\n", c[t], t, f[t], z[t], l[t, "go"], l[t, "pg"]
}' "$work/hits" | sort -k1,1nr -k2 | head -n "$top"
