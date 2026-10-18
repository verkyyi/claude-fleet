#!/bin/bash
# fleet-macos-watch.sh --repo <owner/name> [--session <fleet>] [--dry-run] [--now]
#   — a red BSD half on master becomes ONE breakage issue and one alert (issues #2286, #3120).
#
# Since #2286 the macOS selftests no longer run on a pull request; since #4663 they
# hold no release either: there is one release line (#4671), every Mac follows
# stable and verifies its own install (the updater's machine
# doctor, rolled back on a new FAIL), and the BSD half is the nightly full suite
# (selftests-macos.yml) — mac-follow.yml (#3869) is a dispatch only. A red BSD half
# is a bug a Mac will meet, and nobody watches the Actions tab. This script does (issue #3143, EPIC #3139 C4):
#
#   1. walks the workflow's (FLEET_MACOS_WORKFLOW, default selftests-macos.yml)
#      completed non-pull_request runs on master, newest first, and judges each by
#      its macOS shard jobs only (`macOS / shard K`, the nightly's `macOS shard K`):
#      one failed / timed out ⇒ red, all green ⇒ green, none or cancelled ⇒ no
#      verdict (a follow with nothing to follow, one cancelled). A run red for
#      another step is not the BSD half's;
#   2. green → forgets what it filed, prints `green`, exit 0;
#   3. red → names what is red (the failed job, the FAIL/TIMEOUT tests in its log)
#      and since which commit (the red streak walked back to the last green run;
#      a run's head commit — a train boards master's head when it starts, at or
#      past it), and files it through the ONE filer road with
#      `--breakage-key macos-<the red tests>` (bin/fleet-issue-file.sh, issues
#      #2078, #4232): one issue per red test set across every machine, login and
#      new stable — no commit in the key; `--fault-sha` / `--fault-link` name the
#      run (issue #4271): one already open gets ONE 「同一故障」 comment per new
#      sha and comes back exit 5, a closed one is reopened when the red run's
#      commit contains its fix. A NEW or REOPENED issue raises ONE `breakage`
#      alert (fleet-alerts.sh event) on --session's fleet (a red run on an issue
#      already open raises none — the issue is the reminder) — and spawns NOTHING: since
#      #3120 (EPIC #3111 C9) no session starts by itself; sending a fixer is the
#      person's, or a steward holder's (the fleet-steward plugin).
#   4. remembers the run id it filed for, so the same red run is never re-filed
#      (nor re-commented 「同一故障」) on every tick;
#   5. a long red (issue #3869): when the red streak began more than
#      FLEET_MACOS_STALE_SECS ago (7200, 2 hours — the streak's first red run's
#      created_at) with nothing green since, ONE more `breakage` alert says macOS
#      has been red that long — once per streak.
#
# The walk reads at most FLEET_MACOS_WATCH_WALK (25) runs' jobs.
#
# Run from the diskguard tick (bin/fleet-diskguard.sh --watch, ~60s; the dispatch
# daemon's until #3120) for every hosted repo whose base checkout carries both the
# watched workflow and bin/fleet-stable.sh — so a business repo is never read. Throttled to one read
# per FLEET_MACOS_WATCH_SECS (default 600) per repo; --now ignores the throttle.
# FLEET_MACOS_WATCH=0 turns it off. --dry-run reads and prints the filing it
# would make, files nothing and remembers nothing.
#
# State: $FLEET_CONF_DIR/global/macos-watch/<slug>.{stamp,filed,stale}.
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
    -h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
stamp="$SD/$slug.stamp" memo="$SD/$slug.filed" stale="$SD/$slug.stale"
log() { printf 'fleet-macos-watch: %s: %s\n' "$repo" "$*" >&2; }

every="${FLEET_MACOS_WATCH_SECS:-600}"; case "$every" in ''|*[!0-9]*) every=600 ;; esac
t=$(date +%s)
if [ "$now" = 0 ] && [ "$dry" = 0 ]; then
  last=$(cat "$stamp" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((t - last)) -lt "$every" ] && exit 0
fi
[ "$dry" = 1 ] || printf '%s\n' "$t" > "$stamp"

# Completed non-PR runs, newest first: id<TAB>head_sha<TAB>conclusion<TAB>event<TAB>created_at.
rows=$(gh api "repos/$repo/actions/workflows/$WF/runs?branch=$BRANCH&status=completed&per_page=50" \
         --jq '.workflow_runs[] | [(.id|tostring), .head_sha, (.conclusion // ""), .event, (.created_at // "")] | @tsv' 2>/dev/null) \
  || { log "could not read the $WF runs"; exit 2; }
rows=$(printf '%s\n' "$rows" | awk -F'\t' 'NF >= 4 && $4 !~ /^pull_request/ && $3 != "skipped" && $3 != "cancelled"')
[ -n "$rows" ] || { log "no completed $WF run on $BRANCH yet"; exit 0; }

# A run's BSD verdict from its macOS shard jobs: prints `green`, or `red` and then
# one "<job id><TAB><name>" line per failed shard; nothing = no verdict.
mac_verdict() {
  gh api "repos/$repo/actions/runs/$1/jobs?per_page=100" \
      --jq '.jobs[] | [(.id|tostring), (.conclusion // ""), .name] | @tsv' 2>/dev/null |
    awk -F'\t' 'NF >= 3 && $3 ~ /^macOS( \/)? shard / {
        n++
        if ($2 == "failure" || $2 == "timed_out") bad = bad $1 "\t" $3 "\n"
        else if ($2 == "success") ok++
      }
      END { if (bad != "") printf "red\n%s", bad; else if (n && ok == n) print "green" }'
}

walk="${FLEET_MACOS_WATCH_WALK:-25}"; case "$walk" in ''|*[!0-9]*|0) walk=25 ;; esac
rid='' rsha='' jobs='' start='' since='' seen=0
while IFS=$'\t' read -r id sha _ _ created; do
  [ -n "$id" ] || continue
  seen=$((seen + 1)); [ "$seen" -le "$walk" ] || break
  v=$(mac_verdict "$id")
  case "$v" in
    green*) [ -z "$rid" ] && { [ "$dry" = 1 ] || rm -f "$memo" "$stale"; printf 'green\t%s\t%.7s\n' "$id" "$sha"; exit 0; }
            break ;;                       # the streak's first red is the one before it
    red*)   if [ -z "$rid" ]; then
              rid=$id rsha=$sha jobs=$(printf '%s\n' "$v" | sed 1d)
            fi
            start=$sha since=$created ;;
  esac
done <<EOF
$rows
EOF
[ -n "$rid" ] || { log "no macOS verdict in the newest $walk $WF run(s) on $BRANCH"; exit 0; }
[ -n "$start" ] || start="$rsha"

alert="${FLEET_MACOS_ALERT_CMD:-$BIN/fleet-alerts.sh}"
sock=''; [ -n "$sess" ] && sock=$(fleet_socket "$sess" 2>/dev/null)

# 5. Held back too long (issue #3869): the streak's first red run is older than
# FLEET_MACOS_STALE_SECS — one alert per streak (keyed on the commit it began at).
held=${FLEET_MACOS_STALE_SECS:-7200}; case "$held" in ''|*[!0-9]*) held=7200 ;; esac
t0=''; [ -z "$since" ] || t0=$(fleet_epoch_from_iso "$since" 2>/dev/null)
case "$t0" in ''|*[!0-9]*) t0='' ;; esac
if [ -n "$t0" ] && [ $((t - t0)) -ge "$held" ] && [ "$(cat "$stale" 2>/dev/null)" != "$start" ]; then
  hrs=$(( (t - t0) / 3600 ))
  if [ "$dry" = 1 ]; then
    printf 'would-alert\tstale\t%sh\t%.7s\n' "$hrs" "$start"
  else
    printf '%s\n' "$start" > "$stale"
    printf 'stale\t%sh\t%.7s\n' "$hrs" "$start"
    bash "$alert" event ${sock:+-L "$sock"} breakage \
      "fleet: macOS has been red for ${hrs}h+ — since $(printf '%.7s' "$start"); every Mac runs it (the lane moves with stable since #4663)" \
      >/dev/null 2>&1 || log "the stale-lane alert failed"
  fi
fi

[ "$(cat "$memo" 2>/dev/null)" = "$rid" ] && { printf 'filed\t%s\t%.7s\t(already, for this run)\n' "$rid" "$rsha"; exit 0; }

# What is red: the failed shards, and the FAIL / TIMEOUT tests in the first one's log.
jid=$(printf '%s\n' "$jobs" | awk -F'\t' 'NF { print $1; exit }')
jnames=$(printf '%s\n' "$jobs" | cut -f2 | grep . | paste -sd ',' - | sed 's/,/, /g')
tests=''
if [ -n "$jid" ]; then
  # over REST (#4238): `gh run view --log-failed` printed nothing for these jobs,
  # so every filing said «no FAIL line» — and the key below needs the names
  u="repos/$repo/actions/jobs/$jid/logs"
  tests=$({ gh api "$u" --allow-escape-sequences 2>/dev/null || gh api "$u" 2>/dev/null; } \
            | grep -aoE '(FAIL|TIMEOUT) +[A-Za-z0-9_.-]*selftest[A-Za-z0-9_.-]*' | awk '{print $2}')
  tests=$(printf '%s\n' "$tests" | grep . | awk '!seen[$0]++' | head -5 | paste -sd ',' - | sed 's/,/, /g')
fi
what="${tests:-${jnames:-$WF}}"
s7=$(printf '%.7s' "$start")
title="macOS 检查红了、Mac 停在上一版：${what}（${jnames:-$WF}）自 ${s7} 起"
body="## master 上的 BSD 半边红了（issue #2286 的自动开单）

- 工作流：\`$WF\` · 最新完成的一次：run ${rid}（$(printf '%.7s' "$rsha")）— https://github.com/$repo/actions/runs/$rid
- 红的检查：${jnames:-（未能读出失败的 job）}
- 红的测试：${tests:-（日志里没有读出 FAIL/TIMEOUT 行，看上面的 run）}
- 从哪个提交开始红：\`$s7\`（往回找到最后一次绿之后的第一个红）

macOS 全量检查每晚跑（\`selftests-macos.yml\`）。#4663 起它不再挡发布：Mac 通道随 stable 一起移动，每台 Mac 装上新版后由自己的 machine doctor 验证，新出现 FAIL 就整机回滚。所以这里的红，是 Mac 上会遇到的问题，要尽快修。
修法：在 \`bin/run-selftests.sh <name>\` 里复现那个测试（最常见的是 BSD sed / bash 3.2 的差别，见 CLAUDE.md「The gate has a BSD half」），修好后合并，下一趟列车就把修复带到 Mac。"

if [ "$dry" = 1 ]; then
  printf 'would-file\t%s\t%s\n' "$rid" "$title"; exit 0
fi

# ONE issue per red test (issue #4232): the filer's own fingerprint carries the
# commit, so every new stable with the same red test opened another issue (21 for
# one red, #3975 … #4191). The key is the red tests (else the red shards) — the
# filer finds the open issue under it, comments 「同一故障」 there and exits 5.
bkey=$(printf '%s\n' "${tests:-$jnames}" | tr ',' '\n' | sed 's/^ *//; s/\.sh$//; s/[^A-Za-z0-9._-]\{1,\}/-/g' \
         | grep . | LC_ALL=C sort -u | paste -sd '_' -)
case "$bkey" in ''|*[!A-Za-z0-9._-]*) bkey=$(printf '%s' "$what" | cksum | cut -d' ' -f1) ;; esac
bkey="macos-$bkey"
[ "${#bkey}" -le 80 ] || bkey="macos-$(printf '%s' "$bkey" | cksum | cut -d' ' -f1)"
filer="${FLEET_MACOS_FILE_CMD:-$BIN/fleet-issue-file.sh}"
ferr=$(mktemp "${TMPDIR:-/tmp}/fleet-macos-file.XXXXXX") || ferr=/dev/null
url=$(bash "$filer" --breakage-key "$bkey" --fault-sha "$rsha" --fault-link "https://github.com/$repo/actions/runs/$rid" \
        --repo "$repo" --priority p1 --from macos-watch --title "$title" --body "$body" 2>"$ferr"); rc=$?
reopened=0; grep -q ': reopened ' "$ferr" 2>/dev/null && reopened=1
[ "$ferr" = /dev/null ] || { cat "$ferr" >&2; rm -f "$ferr"; }
case "$rc" in
  0|5) printf '%s\n' "$rid" > "$memo" ;;
  *)   log "filing failed (rc $rc) — retried next tick"; exit 1 ;;
esac
if [ "$reopened" = 1 ]; then
  printf 'filed\t%s\t%s\t(reopened)\n' "$rid" "$url"
elif [ "$rc" = 5 ]; then
  printf 'filed\t%s\t%s\t(already open)\n' "$rid" "$url"
else
  printf 'filed\t%s\t%s\n' "$rid" "$url"
fi
# The reminder: one alert when the issue is NEW or REOPENED (issue #4271) — a
# red run on an issue already open is one comment there, not another alert: the
# open issue is the reminder, and the stale-lane alert (5.) still fires once per
# streak. Nobody is spawned for it (issue #3120).
if [ "$rc" = 0 ] || [ "$reopened" = 1 ]; then
  bash "$alert" event ${sock:+-L "$sock"} breakage \
    "fleet: macOS is red since ${s7}, and every Mac runs it — ${url:-$repo} (nobody fixes it on their own; open a session on it)" \
    >/dev/null 2>&1 || log "filed ${url:-the breakage} but the alert failed"
fi
exit 0
