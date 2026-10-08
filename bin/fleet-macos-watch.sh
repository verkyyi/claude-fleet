#!/bin/bash
# fleet-macos-watch.sh --repo <owner/name> [--session <fleet>] [--dry-run] [--now]
#   — a red BSD half on master becomes ONE breakage issue with its fixer (issue #2286).
#
# Since #2286 the macOS selftests no longer run on a pull request: they run on
# master after the merge (.github/workflows/selftests-macos.yml, push → the related
# tests; nightly → the full suite), and `fleet-stable.sh move` refuses a target
# whose macOS run is not green. A red master run therefore blocks every release
# until someone fixes it — and nobody watches the Actions tab. This script does:
#
#   1. reads the macOS workflow's newest COMPLETED run on master that is not a
#      pull_request and not cancelled (a newer push superseded it — no verdict);
#   2. green → forgets what it filed, prints `green`, exit 0;
#   3. red → names what is red (the failed job, the FAIL/TIMEOUT tests in its log)
#      and since which commit (the red streak walked back to the last green run),
#      and files it through the ONE filer road with `--breakage`
#      (bin/fleet-issue-file.sh, issue #2078): one issue per fingerprint across
#      every machine and login; a breakage someone already filed comes back exit 5
#      and is left alone. A fresh issue gets its worker (dash-issue-session.sh
#      --origin autofill) when --session names the fleet.
#   4. remembers the run id it filed for, so the same red run is never re-filed
#      (nor re-commented 「同一故障」) on every tick.
#
# Run from the dispatch daemon's tick (bin/fleet-dispatch.sh, ~60s) for every
# hosted repo whose base checkout carries both the macOS workflow and
# bin/fleet-stable.sh — so a business repo is never read. Throttled to one read
# per FLEET_MACOS_WATCH_SECS (default 600) per repo; --now ignores the throttle.
# FLEET_MACOS_WATCH=0 turns it off. --dry-run reads and prints the filing it
# would make, files nothing and remembers nothing.
#
# State: $FLEET_CONF_DIR/global/macos-watch/<slug>.{stamp,filed}.
# Exit: 0 green / filed / nothing to do · 1 the filing failed · 2 usage / unread.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

repo='' sess='' dry=0 now=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)    shift; repo="${1:-}" ;;
    --session) shift; sess="${1:-}" ;;
    --dry-run|-n) dry=1 ;;
    --now)     now=1 ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         printf 'fleet-macos-watch: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$repo" ] || { printf 'fleet-macos-watch: --repo owner/name is required\n' >&2; exit 2; }
[ "${FLEET_MACOS_WATCH:-1}" = 0 ] && exit 0
command -v gh >/dev/null 2>&1 || { printf 'fleet-macos-watch: gh not on PATH\n' >&2; exit 2; }

WF="${FLEET_MACOS_WORKFLOW:-selftests-macos.yml}"
BRANCH="${FLEET_MACOS_BRANCH:-master}"
slug=$(fleet_slug "$repo")
SD="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/global/macos-watch"
mkdir -p "$SD" 2>/dev/null
stamp="$SD/$slug.stamp" memo="$SD/$slug.filed"
log() { printf 'fleet-macos-watch: %s: %s\n' "$repo" "$*" >&2; }

every="${FLEET_MACOS_WATCH_SECS:-600}"; case "$every" in ''|*[!0-9]*) every=600 ;; esac
t=$(date +%s)
if [ "$now" = 0 ] && [ "$dry" = 0 ]; then
  last=$(cat "$stamp" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((t - last)) -lt "$every" ] && exit 0
fi
[ "$dry" = 1 ] || printf '%s\n' "$t" > "$stamp"

# Completed non-PR runs, newest first: id<TAB>head_sha<TAB>conclusion<TAB>event.
rows=$(gh api "repos/$repo/actions/workflows/$WF/runs?branch=$BRANCH&status=completed&per_page=50" \
         --jq '.workflow_runs[] | [(.id|tostring), .head_sha, (.conclusion // ""), .event] | @tsv' 2>/dev/null) \
  || { log "could not read the $WF runs"; exit 2; }
rows=$(printf '%s\n' "$rows" | awk -F'\t' 'NF >= 4 && $4 !~ /^pull_request/ && $3 != "cancelled" && $3 != "skipped"')
[ -n "$rows" ] || { log "no completed $WF run on $BRANCH yet"; exit 0; }

IFS=$'\t' read -r rid rsha rcon _ <<EOF
$(printf '%s\n' "$rows" | head -1)
EOF
if [ "$rcon" = success ]; then
  [ "$dry" = 1 ] || rm -f "$memo"
  printf 'green\t%s\t%.7s\n' "$rid" "$rsha"; exit 0
fi
if [ "$(cat "$memo" 2>/dev/null)" = "$rid" ]; then
  printf 'filed\t%s\t%.7s\t(already, for this run)\n' "$rid" "$rsha"; exit 0
fi

# Since which commit: the oldest red run before the newest green one.
start=$(printf '%s\n' "$rows" | awk -F'\t' '$3 == "success" { exit } { s = $2 } END { print s }')
[ -n "$start" ] || start="$rsha"

# What is red: the failed jobs, and the FAIL / TIMEOUT tests in the first one's log.
jobs=$(gh api "repos/$repo/actions/runs/$rid/jobs?per_page=100" \
         --jq '.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out") | [(.id|tostring), .name] | @tsv' 2>/dev/null)
jid=$(printf '%s\n' "$jobs" | awk -F'\t' 'NF { print $1; exit }')
jnames=$(printf '%s\n' "$jobs" | cut -f2 | grep . | paste -sd ',' - | sed 's/,/, /g')
tests=''
if [ -n "$jid" ]; then
  tests=$(gh run view --job "$jid" --log-failed -R "$repo" 2>/dev/null \
            | grep -oE '(FAIL|TIMEOUT) +[A-Za-z0-9_.-]*selftest[A-Za-z0-9_.-]*' | awk '{print $2}')
  tests=$(printf '%s\n' "$tests" | grep . | awk '!seen[$0]++' | head -5 | paste -sd ',' - | sed 's/,/, /g')
fi
what="${tests:-${jnames:-$WF}}"
s7=$(printf '%.7s' "$start")
title="master 上 macOS 检查红了：${what}（${jnames:-$WF}）自 ${s7} 起"
body="## master 上的 BSD 半边红了（issue #2286 的自动开单）

- 工作流：\`$WF\` · 最新完成的一次：run ${rid}（$(printf '%.7s' "$rsha")）— https://github.com/$repo/actions/runs/$rid
- 红的检查：${jnames:-（未能读出失败的 job）}
- 红的测试：${tests:-（日志里没有读出 FAIL/TIMEOUT 行，看上面的 run）}
- 从哪个提交开始红：\`$s7\`（往回找到最后一次绿之后的第一个红）

macOS 检查在合并后跑（#2286），所以它红着时 \`fleet-stable.sh move\` 会以 \`macos:\` 拒绝移 stable：这张单修好之前，master 上的新代码到不了任何机器。
修法：在 \`bin/run-selftests.sh <name>\` 里复现那个测试（BSD sed / bash 3.2 的差别最常见，见 CLAUDE.md「The gate has a BSD half」），修好后合并，master 的下一次 macOS run 绿了即可。"

if [ "$dry" = 1 ]; then
  printf 'would-file\t%s\t%s\n' "$rid" "$title"; exit 0
fi

filer="${FLEET_MACOS_FILE_CMD:-$BIN/fleet-issue-file.sh}"
url=$(bash "$filer" --breakage --repo "$repo" --priority p1 --from macos-watch --title "$title" --body "$body"); rc=$?
case "$rc" in
  0|5) printf '%s\n' "$rid" > "$memo" ;;
  *)   log "filing failed (rc $rc) — retried next tick"; exit 1 ;;
esac
num=${url##*/}; num=${num//[^0-9]/}
if [ "$rc" = 5 ]; then
  printf 'filed\t%s\t%s\t(already open)\n' "$rid" "$url"; exit 0
fi
printf 'filed\t%s\t%s\n' "$rid" "$url"
if [ -n "$sess" ] && [ -n "$num" ]; then
  spawn="${FLEET_MACOS_SPAWN_CMD:-$BIN/dash-issue-session.sh}"
  bash "$spawn" "$num" "$sess" --repo "$repo" --title "$title" --origin autofill >/dev/null 2>&1 \
    || log "filed #$num but the spawn was refused — it is on the backlog"
fi
exit 0
