#!/bin/bash
# fleet-macos-watch.sh --repo <owner/name> [--session <fleet>] [--dry-run] [--now]
#   — a red BSD half on master becomes one alert (issues #2286, #3120, #4898).
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
#   2. green → a red streak it saw ends with ONE message «✓ macOS 夜检恢复全绿（红了
#      N 晚）» (fleet-alerts.sh event, i.e. 消息 — never pushed) and is forgotten;
#      green with nothing seen red prints nothing;
#   3. red → names what is red (the failed jobs, the FAIL/TIMEOUT tests in their
#      logs) and since which commit (the red streak walked back to the last green
#      run), and raises ONE `breakage` alert per red run on --session's fleet —
#      no issue is filed (issue #4898), nothing is spawned (#3120). The copy says
#      what is true since #4671: Macs still update (nothing holds them back);
#   4. a streak red FLEET_MACOS_PUSH_NIGHTS (2) nights — scheduled runs; a streak
#      of dispatches alone counts its runs — is pushed to the person ONCE
#      (FLEET_NOTIFY_CMD, zh + en: nights · tests · since · the run), keyed on the
#      commit it began at; no notifier ⇒ only the log line says so;
#   5. remembers the run it alerted for and the streak it pushed, and prints a
#      line only when something changed — a quiet tick prints nothing, so
#      diskguard's macos-watch.log grows by events, not by ticks.
#
# The walk reads at most FLEET_MACOS_WATCH_WALK (25) runs' jobs.
#
# Run from the diskguard tick (bin/fleet-diskguard.sh --watch, ~60s; the dispatch
# daemon's until #3120) for every hosted repo whose base checkout carries both the
# watched workflow and bin/fleet-stable.sh — so a business repo is never read. Throttled to one read
# per FLEET_MACOS_WATCH_SECS (default 600) per repo; --now ignores the throttle.
# FLEET_MACOS_WATCH=0 turns it off. --dry-run reads and prints the alert it
# would raise, raises nothing and remembers nothing.
#
# State: $FLEET_CONF_DIR/global/macos-watch/<slug>.{stamp,filed,pushed,streak}.
# Exit: 0 green / alerted / nothing to do · 1 the alert failed · 2 usage / unread.
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
    -h|--help) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
stamp="$SD/$slug.stamp" memo="$SD/$slug.filed" pushed="$SD/$slug.pushed" streak="$SD/$slug.streak"
rm -f "$SD/$slug.stale" 2>/dev/null   # compat-1v: 下一批删 (the held-back mark, #3869)
log() { printf 'fleet-macos-watch: %s: %s\n' "$repo" "$*" >&2; }

every="${FLEET_MACOS_WATCH_SECS:-600}"; case "$every" in ''|*[!0-9]*) every=600 ;; esac
t=$(date +%s)
if [ "$now" = 0 ] && [ "$dry" = 0 ]; then
  last=$(cat "$stamp" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((t - last)) -lt "$every" ] && exit 0
fi
# One watch per repo at a time (issue #4841): a run that is still waiting on
# GitHub keeps the lock, and the next tick leaves instead of piling up beside it.
lock="$SD/$slug.lock"
if ! mkdir "$lock" 2>/dev/null; then
  lpid=$(cat "$lock/pid" 2>/dev/null)
  if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
    log "the previous watch (pid $lpid) is still running — skip"; exit 0
  fi
  rm -rf "${lock:?}" 2>/dev/null; mkdir "$lock" 2>/dev/null || exit 0
fi
printf '%s\n' "$$" > "$lock/pid"
trap 'rm -rf "${lock:?}" 2>/dev/null' EXIT
[ "$dry" = 1 ] || printf '%s\n' "$t" > "$stamp"

# Completed non-PR runs, newest first: id<TAB>head_sha<TAB>conclusion<TAB>event<TAB>created_at.
rows=$(gh api "repos/$repo/actions/workflows/$WF/runs?branch=$BRANCH&status=completed&per_page=50" \
         --jq '.workflow_runs[] | [(.id|tostring), .head_sha, (.conclusion // ""), .event, (.created_at // "")] | @tsv' 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] || { log "could not read the $WF runs"; exit 2; }
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
rid='' rsha='' jobs='' start='' seen=0 reds=0 nights=0 gone=''
while IFS=$'\t' read -r id sha _ ev _; do
  [ -n "$id" ] || continue
  seen=$((seen + 1)); [ "$seen" -le "$walk" ] || break
  v=$(mac_verdict "$id")
  case "$v" in
    green*) [ -z "$rid" ] && { gone=$id; break; }
            break ;;                       # the streak's first red is the one before it
    red*)   if [ -z "$rid" ]; then
              rid=$id rsha=$sha jobs=$(printf '%s\n' "$v" | sed 1d)
            fi
            reds=$((reds + 1)); [ "$ev" = schedule ] && nights=$((nights + 1))
            start=$sha ;;
  esac
done <<EOF
$rows
EOF
# a night is a scheduled run; a streak of dispatches alone counts its runs
[ "$nights" -gt 0 ] || nights=$reds

alert="${FLEET_MACOS_ALERT_CMD:-$BIN/fleet-alerts.sh}"
push="${FLEET_MACOS_NOTIFY_CMD:-${FLEET_NOTIFY_CMD:-}}"
sock=''; [ -n "$sess" ] && sock=$(fleet_socket "$sess" 2>/dev/null)

# 2. green: a streak this watcher saw ends with ONE message (never pushed) and is
# forgotten; nothing seen red ⇒ nothing said.
if [ -n "$gone" ]; then
  was=$(cut -f2 "$streak" 2>/dev/null); case "$was" in ''|*[!0-9]*) was='' ;; esac
  if [ "$dry" = 1 ]; then
    [ -n "$was" ] && printf 'would-say\tgreen\t%s\n' "$was"
    exit 0
  fi
  rm -f "$memo" "$pushed"
  [ -n "$was" ] || exit 0
  rm -f "$streak"
  printf 'green\t%s\twas red %s nights\n' "$gone" "$was"
  bash "$alert" event ${sock:+-L "$sock"} macos-green \
    "✓ macOS 夜检恢复全绿（红了 ${was} 晚） · ✓ macOS nightly green again (was red ${was} nights)" \
    >/dev/null 2>&1 || log "the green-again message failed"
  exit 0
fi
[ -n "$rid" ] || { log "no macOS verdict in the newest $walk $WF run(s) on $BRANCH"; exit 0; }
[ -n "$start" ] || start="$rsha"
s7=$(printf '%.7s' "$start")
[ "$dry" = 1 ] || printf '%s\t%s\n' "$start" "$nights" > "$streak"

# What is red: the failed shards, and the FAIL / TIMEOUT tests in their logs.
red_tests() {
  local jid u
  for jid in $(printf '%s\n' "$jobs" | awk -F'\t' 'NF { print $1 }' | head -10); do
    # over REST (#4238): `gh run view --log-failed` printed nothing for these jobs
    u="repos/$repo/actions/jobs/$jid/logs"
    { gh api "$u" --allow-escape-sequences 2>/dev/null || gh api "$u" 2>/dev/null; } \
      | grep -aoE '(FAIL|TIMEOUT) +[A-Za-z0-9_.#-]*selftest[A-Za-z0-9_.#-]*' | awk '{print $2}'
  done | grep . | awk '!seen[$0]++'
}
jnames=$(printf '%s\n' "$jobs" | cut -f2 | grep . | paste -sd ',' - | sed 's/,/, /g')
url="https://github.com/$repo/actions/runs/$rid"

# 3. one message per red run (the memo): what is red, since when — never a push
if [ "$(cat "$memo" 2>/dev/null)" != "$rid" ]; then
  tl=$(red_tests)
  what=$(printf '%s\n' "$tl" | grep . | head -5 | paste -sd ',' - | sed 's/,/, /g')
  what="${what:-${jnames:-$WF}}"
  title="macOS 夜检红了：${what}（${jnames:-$WF}）自 ${s7} 起；Mac 照常更新"
  if [ "$dry" = 1 ]; then
    printf 'would-alert\t%s\t%s\n' "$rid" "$title"
  else
    printf '%s\n' "$rid" > "$memo"
    printf 'alerted\t%s\t%s\n' "$rid" "$title"
    bash "$alert" event ${sock:+-L "$sock"} breakage \
      "fleet: macOS nightly is red since ${s7} ($what); Macs still update — $url (nobody fixes it on their own; open a session on it)" \
      >/dev/null 2>&1 || { log "the alert for run $rid failed — retried next tick"; rm -f "$memo"; exit 1; }
  fi
fi

# 4. red FLEET_MACOS_PUSH_NIGHTS nights (2) ⇒ ONE push to the person
# (FLEET_NOTIFY_CMD) per streak, keyed on the commit it began at.
need=${FLEET_MACOS_PUSH_NIGHTS:-2}; case "$need" in ''|*[!0-9]*|0) need=2 ;; esac
[ "$nights" -ge "$need" ] || exit 0
[ "$(cat "$pushed" 2>/dev/null)" = "$start" ] && exit 0
[ -n "${tl+x}" ] || tl=$(red_tests)
k=$(printf '%s\n' "$tl" | grep -c .); first=$(printf '%s\n' "$tl" | grep . | head -1)
if [ "$k" -gt 1 ]; then
  zt=" · ${k} 个测试" et=" · ${k} tests" zw="${first} 等，" ew="${first} and $((k - 1)) more, "
elif [ "$k" = 1 ]; then
  zt=" · 1 个测试" et=" · 1 test" zw="${first}，" ew="${first}, "
else
  zt='' et='' zw='' ew=''
fi
msg="【fleet】macOS 夜检连红 ${nights} 晚${zt}
${zw}自 ${s7} 起；Mac 照常更新
要修就开一个会话：${url}

[fleet] macOS nightly red ${nights} nights${et}
${ew}since ${s7}; Macs still update
To fix it, open a session: ${url}"
if [ "$dry" = 1 ]; then
  printf 'would-push\t%s\t%s\n' "$nights" "$s7"; exit 0
fi
if [ -z "$push" ]; then
  log "red ${nights} nights since ${s7} and no FLEET_NOTIFY_CMD — nobody to push it to"
  printf '%s\n' "$start" > "$pushed"; exit 0
fi
"$push" "$msg" >/dev/null 2>&1 || { log "the push for the streak since ${s7} failed — retried next tick"; exit 1; }
printf '%s\n' "$start" > "$pushed"
printf 'pushed\t%s nights\t%s\n' "$nights" "$s7"
bash "$alert" event ${sock:+-L "$sock"} breakage "$(printf '%s\n' "$msg" | sed -n 1,3p | paste -sd ' ' -)" >/dev/null 2>&1 || :
exit 0
