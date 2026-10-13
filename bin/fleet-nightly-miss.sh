#!/bin/bash
# fleet-nightly-miss.sh --results <dir> --sha <rev> [--since <rev>] [--repo <owner/name>]
#                       [--run <id>] [--dir <repo>] [--max <n>] [--dry-run]
#   — the nightly full run's red tests, each traced to the merge it went red at and
#   asked why the release train never selected it (issue #3871, EPIC #3863 C8).
#
# The release train tests only what a change selects (`run-selftests.sh --changed`,
# a test is picked when its source NAMES a changed file). A test that reads a file
# it never names goes red without any train running it, and ships red. The nightly
# (.github/workflows/selftests-nightly.yml) runs the WHOLE Linux suite on stable;
# this script turns each of its red tests into one issue that says:
#
#   1. since which merge it is red — the window is <since>..<sha> on the
#      first-parent line (default <since>: the first-parent commit a day before
#      <sha>'s commit time — stable as the previous night saw it). The test is run
#      again at <sha> (green ⇒ `flaky`: red at night, green when asked again), at
#      <since> (red ⇒ `old`: red before the window), and bisected over the merges
#      between (log2 n runs) to the FIRST one it is red at;
#   2. whether the train selected it there — `run-selftests.sh --changed <M^>
#      --list-only` at that merge M: not listed ⇒ `selection-miss` — the files M
#      changed, and the one-line fix (name the file in the test: the existing
#      rule b); listed ⇒ `picked` — the train ran it at M (a quarantine, a rerun
#      that passed): read that train.
#
# One issue per test, through the ONE filer road (bin/fleet-issue-file.sh
# --breakage-key nightly-<test>; a flaky one --breakage-key flaky-<test>, the
# train's own key — 共同约定 6): the same test red the next night is a
# 「同一故障」 comment (exit 5), never a second issue. Labels: selection-miss · bug ·
# flaky. Prints a Markdown table (one row per red test) on stdout for the run's
# summary page. Analyses at most --max tests (default 5, FLEET_NM_MAX); the rest are
# listed and filed without a bisect.
#
# Reads the shards' verdicts: every `FAIL <test>` / `TIMEOUT <test>` line in any
# train-result.txt under --results (selftests-shards.yml `record: true`).
#
# Env: FLEET_NM_FILER   the issue filer (default bin/fleet-issue-file.sh) — a selftest seam
#      FLEET_NM_RUN     runs ONE test in a checkout: `$FLEET_NM_RUN <checkout> <test>`,
#                       exit 0 green (default: <checkout>/bin/run-selftests.sh <test>)
# Exit: 0 analysed and filed (or nothing red) · 1 a filing failed · 2 usage.
set -uo pipefail
BIN=$(cd -- "$(dirname -- "$0")" && pwd)
ME=fleet-nightly-miss

die() { printf '%s: %s\n' "$ME" "$*" >&2; exit 2; }
say() { printf '%s: %s\n' "$ME" "$*" >&2; }

results='' sha='' since='' repo='' run='' dir=. max=${FLEET_NM_MAX:-5} dry=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --results) results=${2:-}; shift 2 ;;
    --sha)     sha=${2:-}; shift 2 ;;
    --since)   since=${2:-}; shift 2 ;;
    --repo)    repo=${2:-}; shift 2 ;;
    --run)     run=${2:-}; shift 2 ;;
    --dir)     dir=${2:-}; shift 2 ;;
    --max)     max=${2:-}; shift 2 ;;
    --dry-run|-n) dry=1; shift ;;
    -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[ -n "$results" ] && [ -d "$results" ] || die "--results <dir> is required (the shards' train-result-* artifacts)"
[ -n "$sha" ] || die "--sha <rev> is required (the commit the nightly tested)"
case "$max" in ''|*[!0-9]*) max=5 ;; esac
dir=$(cd "$dir" 2>/dev/null && pwd) || die "no such checkout: $dir"
git -C "$dir" rev-parse -q --verify "$sha^{commit}" >/dev/null || die "$sha is not a commit in $dir"
sha=$(git -C "$dir" rev-parse "$sha^{commit}")

file_issue() {
  if [ -n "${FLEET_NM_FILER:-}" ]; then "$FLEET_NM_FILER" "$@"; else bash "$BIN/fleet-issue-file.sh" "$@"; fi
}

# The red tests, by name: every FAIL / TIMEOUT line of every shard.
reds=$(find "$results" -name 'train-result*.txt' -type f -exec cat {} + 2>/dev/null \
         | awk '($1 == "FAIL" || $1 == "TIMEOUT") && $2 ~ /-selftest\.sh$/ { print $2 }' | sort -u)
if [ -z "$reds" ]; then
  say "no FAIL / TIMEOUT line in $results — nothing to trace"
  exit 0
fi

# The window: <since>..<sha> on the first-parent line.
if [ -z "$since" ]; then
  ct=$(git -C "$dir" log -1 --format=%ct "$sha")
  since=$(git -C "$dir" rev-list -1 --first-parent --before="$((ct - 86400))" "$sha" 2>/dev/null)
fi
if [ -n "$since" ]; then
  git -C "$dir" rev-parse -q --verify "$since^{commit}" >/dev/null || die "$since is not a commit in $dir"
  since=$(git -C "$dir" rev-parse "$since^{commit}")
  # oldest first; the window's last entry is <sha>
  merges=$(git -C "$dir" rev-list --first-parent --reverse "$since..$sha")
else
  merges=''
fi
nmerges=$(printf '%s\n' "$merges" | grep -c . || true)

# One scratch checkout, moved commit to commit.
wt=$(mktemp -d "${TMPDIR:-/tmp}/fleet-nightly-miss.XXXXXX") || die "no temp dir"
rmdir "$wt"
git -C "$dir" worktree add -q --detach "$wt" "$sha" >/dev/null 2>&1 || die "could not check out $sha into a scratch worktree"
cleanup() { git -C "$dir" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
at() { git -C "$wt" checkout -q --detach --force "$1" >/dev/null 2>&1; }

# red_at <rev> <test> — 0 when <test> is RED at <rev>; a test not there yet is green.
red_at() {
  at "$1" || { say "could not check out $1"; return 1; }
  [ -f "$wt/bin/$2" ] || return 1
  if [ -n "${FLEET_NM_RUN:-}" ]; then
    "$FLEET_NM_RUN" "$wt" "$2" >/dev/null 2>&1 && return 1
  else
    (cd "$wt/bin" && FLEET_HEAVY=0 bash run-selftests.sh "$2") >/dev/null 2>&1 && return 1
  fi
  return 0
}

# picked_at <rev> <test> — 0 when the train's selection for <rev>'s own change lists <test>.
picked_at() {
  at "$1" || return 1
  (cd "$wt/bin" && FLEET_HEAVY=0 bash run-selftests.sh --changed "$1^" --list-only 2>/dev/null) \
    | grep -qxF -- "$2"
}

short() { printf '%.7s' "$1"; }
subject() { git -C "$dir" log -1 --format=%s "$1" 2>/dev/null; }
runurl=''; [ -n "$repo" ] && [ -n "$run" ] && runurl="https://github.com/$repo/actions/runs/$run"
s7=$(short "$sha")

printf '| 测试 | 结论 | 从哪次合并起红 | 列车为什么没跑它 | 单 |\n|---|---|---|---|---|\n'
rc=0 n=0
for t in $reds; do
  n=$((n + 1)); name=${t%-selftest.sh}
  verdict='' first='' files='' why=''
  if [ "$n" -gt "$max" ]; then
    verdict=unanalysed
  elif ! red_at "$sha" "$t"; then
    verdict=flaky
  elif [ -z "$since" ] || [ "$nmerges" -eq 0 ]; then
    verdict=old
  elif red_at "$since" "$t"; then
    verdict=old
  else
    # bisect: index 0 = <since> (green), index n = <sha> (red)
    lo=0 hi=$nmerges
    while [ $((hi - lo)) -gt 1 ]; do
      mid=$(( (lo + hi) / 2 ))
      m=$(printf '%s\n' "$merges" | sed -n "${mid}p")
      if red_at "$m" "$t"; then hi=$mid; else lo=$mid; fi
    done
    first=$(printf '%s\n' "$merges" | sed -n "${hi}p")
    files=$(git -C "$dir" diff --no-renames --name-only "$first^" "$first" 2>/dev/null)
    if picked_at "$first" "$t"; then verdict=picked; else verdict=selection-miss; fi
  fi
  f7=''; [ -z "$first" ] || f7=$(short "$first")
  flist=$(printf '%s\n' "$files" | grep . | head -20 | sed 's/^/- `/; s/$/`/')
  label=bug key="nightly-$name"
  case "$verdict" in
    selection-miss)
      label=selection-miss
      title="夜间全量红：${t} 自 ${f7} 起红，列车没选中它（漏选）"
      hint=$(printf '%s\n' "$files" | grep . | grep -v -- '-selftest\.sh$' | head -1)
      why="那次合并的改动没有一个是 ${t} 点名的文件"
      body="## ${t} 在夜间全量里红了，发布列车从没跑过它（issue #3871 的自动开单）

- 夜间全量：stable \`${s7}\`${runurl:+ · $runurl}
- **从哪次合并开始红**：\`${f7}\` $(subject "$first")（在 \`$(short "$since")\`..\`${s7}\` 的 ${nmerges} 次合并里二分得出：它之前绿、它起红）
- **列车为什么没选中它**：\`run-selftests.sh --changed ${f7}^ --list-only\` 在 \`${f7}\` 上没有列出 ${t}——列车只跑源里**点名**了改动文件（基名）的测试，而这次合并改的文件 ${t} 一个都没点名：

${flist:-（没有读出改动的文件）}

## 修法
1. 修好 ${t}（它现在在 stable 上是红的，只是没有列车跑它）；
2. 在 \`bin/${t}\` 里点名它读的那个文件，以后改它时列车就会选中这个测试——一行注释即可（规则 b 按基名匹配），例如：
   \`\`\`
   # reads: ${hint:-<被漏的文件>}
   \`\`\`
   修它的 PR 里写上 \`Closes #<本单>\`，这张单就是这次漏选和它的补上之间的关联。"
      ;;
    picked)
      title="夜间全量红：${t} 自 ${f7} 起红（列车选中过它）"
      why="列车选中了它：去看 ${f7} 之后那趟列车——隔离（QUARANTINED）或重跑才过（FLAKY）"
      body="## ${t} 在夜间全量里红了（issue #3871 的自动开单）

- 夜间全量：stable \`${s7}\`${runurl:+ · $runurl}
- **从哪次合并开始红**：\`${f7}\` $(subject "$first")（\`$(short "$since")\`..\`${s7}\` 的 ${nmerges} 次合并里二分得出）
- **列车选中过它**：\`run-selftests.sh --changed ${f7}^ --list-only\` 列出了 ${t}，所以这不是漏选——那趟列车跑过它：看它是不是被隔离（\`QUARANTINED\`）、或红了一次重跑才过（\`FLAKY\`）后照发。

这次合并改的文件：
${flist:-（没有读出改动的文件）}"
      ;;
    old)
      title="夜间全量红：${t} 在 $( [ -n "$since" ] && short "$since" || echo "${s7} 之前") 就已经红了"
      why="窗口之前就红（\`$( [ -n "$since" ] && short "$since" || echo '?')\` 上也红）"
      body="## ${t} 在夜间全量里红了（issue #3871 的自动开单）

- 夜间全量：stable \`${s7}\`${runurl:+ · $runurl}
- 在窗口起点 \`$( [ -n "$since" ] && short "$since" || echo '（没有窗口：stable 前一天没有提交）')\` 上它也是红的：这不是今天的合并改坏的，往前找更早的那次（\`git bisect\` 在 \`bin/run-selftests.sh ${t}\` 上）。"
      ;;
    flaky)
      label=flaky key="flaky-$name"
      title="夜间全量里 ${t} 时好时坏：夜里红，复跑绿"
      why="不确定：在 \`${s7}\` 上复跑是绿的"
      body="${t} 在夜间全量（stable \`${s7}\`${runurl:+ · $runurl}）里红了，事后在同一提交上单独复跑一次是绿的——它时好时坏（issue #3871 的自动开单；和列车「重跑才过」用同一张单，\`flaky-${name}\`）。修好它，这张单就关。"
      ;;
    unanalysed)
      title="夜间全量红：${t}"
      why="没分析（本晚只分析前 ${max} 个红测试）"
      body="${t} 在夜间全量（stable \`${s7}\`${runurl:+ · $runurl}）里红了。这一晚红得太多，只二分了前 ${max} 个；在 \`bin/run-selftests.sh ${t}\` 上复现。"
      ;;
  esac
  url='-'
  if [ "$dry" = 1 ] || [ -z "$repo" ]; then
    url="(would file: $label · $key)"
  else
    url=$(file_issue --repo "$repo" --breakage-key "$key" --label "$label" --priority p1 \
            --title "$title" --body "$body"); frc=$?
    case "$frc" in
      0|5) url=$(printf '%s\n' "$url" | tail -1) ;;
      *)   say "could not file $t (filer exit $frc)"; rc=1; url="(filing failed, exit $frc)" ;;
    esac
  fi
  printf '| %s | %s | %s | %s | %s |\n' "$t" "$verdict" "${f7:--}" "${why:--}" "$url"
done
exit "$rc"
