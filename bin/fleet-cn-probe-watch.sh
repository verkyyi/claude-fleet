#!/bin/bash
# fleet-cn-probe-watch.sh --repo <owner/name> [--session <fleet>] [--now] [--dry-run]
#   — the China real-user path, walked by a machine every few hours; a red one is
#     ONE breakage issue, one alert, and a red light on the stable it tested that
#     holds `stable` where it is (issue #4180).
#
# Why here and not in the release train: the probe's client is a machine in China
# (bin/fleet-cn-probe.sh — oss-drill, Shenzhen) whose security group admits only
# this computer's egress, and the train runs on GitHub's runners and the cluster's
# own; and a candidate's node image is built only after its release (the train's
# `node image` job), so the pod the path ends on can never run the candidate
# before stable moves. So the path is walked against what is LIVE — the hub, the
# client and the pod image that stable shipped — and its verdict gates the NEXT
# move (bin/fleet-stable.sh gate `cn:`).
#
# Each run (the diskguard tick, ~60 s; throttled inside):
#   1. ensure the test road is there (bin/fleet-cn-probe-env.sh ensure — the
#      test identity re-made when it expired, the test pod's image following
#      stable's node image); what it did prints as `ENSURE …` lines;
#   2. bin/fleet-cn-probe.sh, every layer — its whole output kept in
#      $FLEET_CONF_DIR/global/cn-probe/last.txt, its verdict in last.json
#      ({ts, verdict green|red, stuck, detail, stable, issue});
#   3. a commit status `cn path` on the stable it tested (success / failure, the
#      layer it stopped at; on red its target is the breakage issue) — the one
#      thing bin/fleet-stable.sh reads;
#   4. red → bin/fleet-issue-file.sh --breakage --breakage-key cn-path-<layer>
#      (one issue per stuck layer, across machines — exit 5 = already open), and
#      ONE `breakage` alert per issue (fleet-alerts.sh event) — nobody is spawned
#      (issue #3120); green → forgets what it filed.
#
# Throttle: FLEET_CN_PROBE_SECS (21600, 6 h) after a green run,
# FLEET_CN_PROBE_RED_SECS (3600) after a red one — a repair outside a release
# turns the light green within the hour. --now ignores it. One run at a time
# (a lock dir; a run takes ~5 min). Off: FLEET_CN_PROBE=0, or no client key here
# (FLEET_CN_PROBE_KEY, the probe's own default) — so every other machine and login
# skips it. --dry-run runs the probe and prints what it would post / file,
# changing nothing (no ensure, no status, no issue, no state).
#
# Seams: FLEET_CN_PROBE_CMD (the probe), FLEET_CN_PROBE_ENV_CMD (ensure),
# FLEET_CN_PROBE_FILE_CMD (the filer), FLEET_CN_PROBE_GH (gh).
# Exit: 0 green / red handled / nothing to do · 1 posting or filing failed · 2 usage.
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
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *)         printf 'fleet-cn-probe-watch: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
case "$repo" in */*) ;; *) printf 'fleet-cn-probe-watch: --repo owner/name is required\n' >&2; exit 2 ;; esac
[ "${FLEET_CN_PROBE:-1}" = 0 ] && exit 0
[ -r "${FLEET_CN_PROBE_KEY:-$HOME/fleet-secrets/oss-drill/id_oss_drill}" ] || exit 0

GH=${FLEET_CN_PROBE_GH:-gh}
PROBE=${FLEET_CN_PROBE_CMD:-bash $BIN/fleet-cn-probe.sh}
ENSURE=${FLEET_CN_PROBE_ENV_CMD:-bash $BIN/fleet-cn-probe-env.sh ensure}
FILER=${FLEET_CN_PROBE_FILE_CMD:-bash $BIN/fleet-issue-file.sh}
CONTEXT="cn path"
SD="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/global/cn-probe"
mkdir -p "$SD" 2>/dev/null
log() { printf 'fleet-cn-probe-watch: %s\n' "$*" >&2; }
secs() { case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

t=$(date +%s)
if [ "$now" = 0 ] && [ "$dry" = 0 ]; then
  last=$(sed -n 1p "$SD/stamp" 2>/dev/null); last=$(secs "$last" 0)
  if [ -f "$SD/red" ]; then every=$(secs "${FLEET_CN_PROBE_RED_SECS:-}" 3600); else every=$(secs "${FLEET_CN_PROBE_SECS:-}" 21600); fi
  [ $((t - last)) -lt "$every" ] && exit 0
fi
# one run at a time; a lock older than an hour is a run that died
if ! mkdir "$SD/lock" 2>/dev/null; then
  [ -n "$(find "$SD/lock" -maxdepth 0 -mmin +60 2>/dev/null)" ] || exit 0
  rmdir "$SD/lock" 2>/dev/null; mkdir "$SD/lock" 2>/dev/null || exit 0
fi
trap 'rmdir "$SD/lock" 2>/dev/null' EXIT
[ "$dry" = 1 ] || printf '%s\n' "$t" > "$SD/stamp"

# the stable this run tests: what every client, login and pod follows now
stable=$($GH api "repos/$repo/commits/stable" --jq .sha 2>/dev/null)
case "$stable" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *) stable='' ;; esac

out=$( { [ "$dry" = 1 ] || $ENSURE --repo "$repo" ${stable:+--stable "$stable"} 2>&1 | sed 's/^/ENSURE /'
         $PROBE 2>&1; } )
[ "$dry" = 1 ] || printf '%s\n' "$out" > "$SD/last.txt"
vline=$(printf '%s\n' "$out" | grep -E '^(通|不通)：' | tail -n 1)
stuck='' detail=''
case "$vline" in
  通：*)   verdict=green ;;
  不通：*) verdict=red
           stuck=$(printf '%s' "$vline" | sed -n 's/^不通：卡在 \([^ ]*\) — .*/\1/p')
           detail=$(printf '%s' "$vline" | sed 's/^不通：卡在 [^ ]* — //') ;;
  *)       verdict=red stuck=probe detail="the probe printed no verdict: $(printf '%s\n' "$out" | tail -n 1)" ;;
esac
layer=${stuck%%:*}; layer=$(printf '%s' "${layer:-probe}" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')
detail=$(printf '%s' "$detail" | sed 's/__CNP_EXIT=[0-9]*//g; s/[[:space:]][[:space:]]*/ /g' | cut -c1-300)

if [ "$verdict" = green ]; then desc="通：$(printf '%s' "$vline" | sed 's/^通：//')"
else desc="不通：卡在 $stuck — $detail"; fi
desc=$(printf '%s' "$desc" | cut -c1-130)

issue=''
if [ "$verdict" = red ]; then
  title="国内真实用户路径不通：卡在 $layer"
  body="\`bin/fleet-cn-probe-watch.sh\`（#4180）在 $(hostname -s 2>/dev/null || echo ?) 上走国内真实用户路径（深圳客户端 → 门 / 中转 → 测试 pod：裸 \`fleet\` 进界面、新开 Codex 会话问一句、pod 上建任务），对着 stable \`${stable:0:7}\` 走到 **$stuck** 卡住：

> $detail

<details><summary>探针完整输出</summary>

\`\`\`
$(printf '%s\n' "$out" | tail -n 60)
\`\`\`
</details>

这台机器上的 stable 前移因此被拦（\`bin/fleet-stable.sh\` 的 \`cn:\` 门，读 stable 上的提交状态 \`$CONTEXT\`）——修好合并后关掉这张单，列车就能前移；巡检每小时复测一次，绿了状态自己变回 success。复测：\`bin/fleet-cn-probe.sh\`（一次）或 \`bin/fleet-cn-probe-watch.sh --repo $repo --now\`。"
  if [ "$dry" = 1 ]; then
    printf 'would-file\tcn-path-%s\t%s\n' "$layer" "$title"
  else
    issue=$($FILER --breakage --breakage-key "cn-path-$layer" --repo "$repo" --priority p1 --from cn-probe \
              --title "$title" --body "$body" 2>/dev/null | grep -E '^https?://' | tail -n 1); rc=$?
    [ -n "$issue" ] || { log "filing the red path failed — retried next run"; rc=1; }
  fi
fi

if [ "$dry" = 1 ]; then
  printf 'would-post\t%s\t%s\t%s\n' "${stable:-?}" "$verdict" "$desc"; exit 0
fi

python3 - "$SD/last.json" "$t" "$verdict" "$stuck" "$detail" "$stable" "$issue" <<'PY'
import json, sys, os
p, ts, v, stuck, detail, stable, issue = sys.argv[1:8]
d = {"ts": int(ts), "verdict": v, "stuck": stuck, "detail": detail, "stable": stable, "issue": issue}
tmp = p + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, ensure_ascii=False)
os.replace(tmp, p)
PY

rc=0
if [ -n "$stable" ]; then
  state=success; [ "$verdict" = green ] || state=failure
  $GH api -X POST "repos/$repo/statuses/$stable" -f state="$state" -f context="$CONTEXT" \
      -f description="$desc" ${issue:+-f target_url="$issue"} >/dev/null 2>&1 \
    || { log "could not post the $CONTEXT status on ${stable:0:7}"; rc=1; }
else
  log "could not read stable on $repo — no status posted"; rc=1
fi

if [ "$verdict" = green ]; then
  rm -f "$SD/red" "$SD/filed"
  printf 'green\t%s\t%s\n' "${stable:0:7}" "$desc"
  exit "$rc"
fi
: > "$SD/red"
printf 'red\t%s\t%s\t%s\n' "${stable:0:7}" "$stuck" "${issue:--}"
# the reminder: one alert per breakage issue (the memo keeps it to one)
if [ -n "$issue" ] && [ "$(cat "$SD/filed" 2>/dev/null)" != "$issue" ]; then
  printf '%s\n' "$issue" > "$SD/filed"
  sock=''; [ -z "$sess" ] || sock=$(fleet_socket "$sess" 2>/dev/null)
  bash "$BIN/fleet-alerts.sh" event ${sock:+-L "$sock"} breakage \
    "fleet: 国内真实用户路径不通（卡在 ${stuck}），stable 前移被拦 — $issue" >/dev/null 2>&1 \
    || log "filed $issue but the alert failed"
fi
[ -n "$issue" ] || rc=1
exit "$rc"
