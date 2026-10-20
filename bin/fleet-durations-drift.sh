#!/bin/sh
# fleet-durations-drift.sh --results <dir> [--table FILE] [--name NAME] [--pct P]
#                          [--floor S] [--repo R] [--run ID] [--sha S] [--dry-run]
#   — is the durations table still right? Each shard of a full run, its tests' cost
#   off the table against what they actually took; past --pct on any shard, ONE
#   issue that asks for the table's refresh (issue #4819, EPIC #4810 C12).
#
# Why: the shards are packed by bin/selftest-durations.txt (run-selftests.sh
# --shard, issue #1390), and the table is only ever refreshed by hand. A stale one
# packs a heavy shard light: run 39219529644's shard 4 was priced 156 s and took
# ~230 s, was cut at its 1.5× budget and rerun whole — four minutes lost — and
# nothing said the table had drifted. The nightly full run (selftests-nightly.yml)
# is the one run that measures EVERY test, so it asks here after its shards.
#
# Reads every `train-times*.txt` under --results (selftests-shards.yml `record:
# true` uploads one per shard, in its train-result-<os>-<K> artifact): the shard's
# `PASS / FAIL / TIMEOUT / FLAKY <test> <secs>s` lines. A shard's PREDICTED load is
# the sum of its tests' rows in --table (a test with no row costs the table's
# median, as the runner prices it); its ACTUAL load the sum of the seconds printed.
# A shard drifts when |actual − predicted| > P% of predicted (default 20,
# FLEET_DD_PCT); a shard where both are under --floor seconds (default 30) is too
# small to judge.
#
# Drifted ⇒ it is SAID (issue #4898: the issue filer left with the ticket layer):
# bin/fleet-ci-say.sh writes the run and the one command that refreshes the table
# off it (bin/selftest-durations.sh --run <id>) to the run's summary page, under the
# key durations-<name> — a worker opens the PR; nothing here pushes.
#
# Prints a Markdown table (one row per shard) on stdout for the run's summary page.
# Env: FLEET_DD_FILER  the filer (default bin/fleet-ci-say.sh: said, not filed) — a selftest seam
# Exit: 0 judged (drifted and filed, or within bounds, or nothing to judge)
#       1 the filing failed · 2 usage.
set -u
unset CDPATH
BIN=$(cd -- "$(dirname -- "$0")" && pwd)
ME=fleet-durations-drift

die() { printf '%s: %s\n' "$ME" "$*" >&2; exit 2; }
say() { printf '%s: %s\n' "$ME" "$*" >&2; }

results='' table="$BIN/selftest-durations.txt" name=selftests
pct=${FLEET_DD_PCT:-20} floor=30 repo='' run='' sha='' dry=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --results) results=${2:-}; shift 2 ;;
    --table)   table=${2:-}; shift 2 ;;
    --name)    name=${2:-}; shift 2 ;;
    --pct)     pct=${2:-}; shift 2 ;;
    --floor)   floor=${2:-}; shift 2 ;;
    --repo)    repo=${2:-}; shift 2 ;;
    --run)     run=${2:-}; shift 2 ;;
    --sha)     sha=${2:-}; shift 2 ;;
    --dry-run|-n) dry=1; shift ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[ -n "$results" ] && [ -d "$results" ] || die "--results <dir> is required (the shards' train-result-* artifacts)"
[ -f "$table" ] || die "no durations table $table"
case "$pct" in ''|*[!0-9]*) die "--pct must be a whole number" ;; esac
case "$floor" in ''|*[!0-9]*) die "--floor must be a whole number" ;; esac
case "$name" in ''|*[!A-Za-z0-9._-]*) die "--name must be [A-Za-z0-9._-]+" ;; esac
case "$run" in *[!0-9]*) die "--run must be numeric" ;; esac

files=$(find "$results" -name 'train-times*.txt' -type f 2>/dev/null | LC_ALL=C sort)
if [ -z "$files" ]; then
  say "no train-times*.txt under $results — nothing to judge"
  exit 0
fi

# "<shard> <predicted> <actual> <tests> <drift%> <verdict>" per shard. The shard is
# the artifact's directory name (train-result-Linux-4 → Linux-4).
rows=$(for f in $files; do
         d=$(dirname -- "$f"); s=${d##*/}; s=${s#train-result-}
         grep -oE '(PASS|FAIL|TIMEOUT|FLAKY) +[A-Za-z0-9_.+-]+-selftest\.(sh|py)(#[0-9]+)? +[0-9]+(\.[0-9]+)?s' "$f" \
           | awk -v s="$s" '{ v = $3; sub(/s$/, "", v); print s, $2, v }'
       done | awk -v tbl="$table" -v pct="$pct" -v floor="$floor" '
  BEGIN {
    while ((getline l < tbl) > 0) {
      if (l ~ /^[[:space:]]*(#|$)/) continue
      split(l, f, /[ \t]+/); cost[f[2]] = f[1] + 0; v[++nv] = f[1] + 0
    }
    for (i = 2; i <= nv; i++) { x = v[i]; for (j = i - 1; j >= 1 && v[j] > x; j--) v[j + 1] = v[j]; v[j + 1] = x }
    dflt = nv ? ((nv % 2) ? v[(nv + 1) / 2] : (v[nv / 2] + v[nv / 2 + 1]) / 2) : 1
  }
  # a test seen twice in one shard (a cut-short attempt and its rerun) counts once: its last
  !(($1 SUBSEP $2) in got) { order[++m] = $1 }
  { if (($1 SUBSEP $2) in got) act[$1] -= got[$1, $2]
    else { n[$1]++; pred[$1] += ($2 in cost) ? cost[$2] : dflt }
    got[$1, $2] = $3 + 0; act[$1] += $3 + 0; sh[$1] = 1 }
  END {
    for (i = 1; i <= m; i++) {
      s = order[i]; if (done[s]++) continue
      p = pred[s]; a = act[s]
      d = p > 0 ? (a - p) * 100 / p : 0
      if (p < floor && a < floor) verdict = "small"
      else if (d > pct || d < -pct) verdict = "drift"
      else verdict = "ok"
      printf "%s %.0f %.0f %d %+.0f %s\n", s, p, a, n[s], d, verdict
    }
  }' | LC_ALL=C sort -t- -k2,2n)

ndrift=$(printf '%s\n' "$rows" | awk '$6 == "drift" { n++ } END { print n + 0 }')
nshard=$(printf '%s\n' "$rows" | awk 'NF { n++ } END { print n + 0 }')
worst=$(printf '%s\n' "$rows" | awk '$6 != "small" { d = $5 + 0; if (d < 0) d = -d; if (d > w) { w = d; at = $1 } } END { printf "%s %d", at, w }')

tblname=${table##*/}
summary=$(printf '| 片 | 预测 | 实际 | 测试数 | 偏差 | |\n|---|---|---|---|---|---|\n'
          printf '%s\n' "$rows" | awk 'NF { mark = ($6 == "drift") ? "⚠️ 超出" : ($6 == "small") ? "太小不判" : "✓"
                                            printf "| %s | %ss | %ss | %s | %s%% | %s |\n", $1, $2, $3, $4, $5, mark }')
echo "### 耗时表偏差（${tblname}，阈值 ±${pct}%）：${nshard} 片，${ndrift} 片超出，最大 ${worst#* }%（${worst% *}）"
echo
printf '%s\n' "$summary"

[ "$ndrift" -gt 0 ] || { say "every shard within ±${pct}% of $tblname — nothing to file"; exit 0; }

runurl=''
[ -z "$run" ] || [ -z "$repo" ] || runurl="https://github.com/$repo/actions/runs/$run"
s7=$(printf '%.7s' "${sha:-?}")
title="耗时表过时：${tblname} 有 ${ndrift} 片偏差超过 ${pct}%"
refresh="bin/selftest-durations.sh${run:+ --run $run}"
[ "$tblname" = selftest-durations.txt ] || refresh="$refresh --table bin/$tblname"
body="夜间全量${runurl:+（${runurl}）}在 \`${s7}\` 上量了每个测试的实际耗时，按 \`bin/${tblname}\` 预测的分片负载有 ${ndrift} 片偏差超过 ±${pct}%（最大 ${worst#* }%，${worst% *}）。表过时了，分片就会不均：重的那片会撞上预算被截断重跑（#4907：run 39219529644 的 shard 4 预测 156s、实际 ~230s，白花 4 分钟）。

## 怎么修
在这次运行的日志上刷新表，开一个 PR，只改这张表：

\`\`\`
${refresh}
git add bin/${tblname}
\`\`\`

刷新后下一晚的偏差回到 ±${pct}% 内即可；合并即关单。之后再超出，这张单会被重新打开（issue #4819 的自动开单，\`--breakage-key durations-${name}\`）。

## 各片读数
${summary}"

if [ "$dry" = 1 ] || [ -z "$repo" ]; then
  say "would file: durations-$name — $title"
  exit 0
fi
if [ -n "${FLEET_DD_FILER:-}" ]; then
  url=$("$FLEET_DD_FILER" --repo "$repo" --breakage-key "durations-$name" ${sha:+--fault-sha "$sha"} \
          ${runurl:+--fault-link "$runurl"} --label ci --priority p2 --title "$title" --body "$body"); frc=$?
else
  url=$(bash "$BIN/fleet-ci-say.sh" --repo "$repo" --breakage-key "durations-$name" ${sha:+--fault-sha "$sha"} \
          ${runurl:+--fault-link "$runurl"} --label ci --priority p2 --title "$title" --body "$body"); frc=$?
fi
case "$frc" in
  0|5) url=$(printf '%s\n' "$url" | tail -1)
       echo
       echo "更新单：${url:-（没开单：写在本次运行的摘要页里）}"
       exit 0 ;;
  *)   say "could not file the refresh (filer exit $frc)"; exit 1 ;;
esac
