#!/bin/bash
# fleet-cn-probe-watch.sh --repo <owner/name> [--session <fleet>] [--now] [--dry-run]
#                         [--recover [--expect KEY=VALUE]… [--why TEXT]]
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
#      ({ts, verdict green|red, stuck, detail, stable, issue, class, reason_code,
#      run_id, result}) — class / reason_code / result read off the probe's ONE
#      result (runs/<run_id>/result.json, issue #4303). An ensure that FAILED is
#      the run's verdict instead: the test road is not there (class env, stuck
#      ensure:<part>), so no session is opened on it and the probe is not walked —
#      its read-only diagnosis still is (bin/fleet-cn-probe-diag.sh);
#   3. a commit status `cn path` on the stable it tested (success / failure, the
#      layer it stopped at; on red its target is the breakage issue) — the one
#      thing bin/fleet-stable.sh reads;
#   4. red → bin/fleet-issue-file.sh --breakage --breakage-key cn-path-<layer>
#      --fault-sha <stable> (one issue per stuck layer, across machines and
#      stables — exit 5 = already has one: one comment per new stable; a closed
#      one reopened only when the stable it tested contains the fix, issue #4271), and
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
# Every run that walks — tick, --now or recovery, green or red — and every reason
# a tick did NOT walk (throttled until …, a lock held by …, a dead holder's lock
# taken over) is one line of $SD/history.ndjson ({ts, ev, mode, run_id, stable,
# verdict, class, reason_code, …}; a skip once per reason, not once a tick) — the
# diskguard log only ever saw the tick's own output (issue #4304). The lock holds
# its pid: a holder that is gone is taken over at once (recorded), a live one
# after an hour as before.
#
# Recovery verification (issue #4304): `--recover` opens a bounded round in
# bin/fleet-cn-probe-recover.py (--expect pins the deployed version vector —
# stable=<sha> · hub=… · client=… · runtime=… · image=… · pod=…; start it once the
# target is really deployed, never at a merge) and walks at once; every tick then
# asks the round whether a run is due — a due one ignores the throttle, one at a
# time under the same lock — and hands its result.json to the round, which counts
# FLEET_CN_RECOVER_NEED (3) complete passes in a row on one vector inside
# FLEET_CN_RECOVER_MAX_RUNS (6) runs / FLEET_CN_RECOVER_MAX_SECS (5400) s, runs
# back to back (FLEET_CN_RECOVER_EVERY, 0 — never on the hour), then writes its evidence and steps aside:
# the patrol is back on its throttle. `fleet-cn-probe-recover.py <SD> status|stop`.
#
# Run dirs: FLEET_CN_PROBE_RUNS (default $SD/runs), the newest
# FLEET_CN_PROBE_KEEP_RUNS (60) kept.
# Seams: FLEET_CN_PROBE_CMD (the probe), FLEET_CN_PROBE_ENV_CMD (ensure),
# FLEET_CN_PROBE_FILE_CMD (the filer), FLEET_CN_PROBE_GH (gh).
# Exit: 0 green / red handled / nothing to do · 1 posting or filing failed · 2 usage.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

repo='' sess='' dry=0 now=0 recover=0 rwhy=''
rexp=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)    shift; repo="${1:-}" ;;
    --session) shift; sess="${1:-}" ;;
    --dry-run|-n) dry=1 ;;
    --now)     now=1 ;;
    --recover) recover=1 ;;
    --expect)  shift; rexp+=(--expect "${1:-}") ;;
    --why)     shift; rwhy="${1:-}" ;;
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

REC="python3 $BIN/fleet-cn-probe-recover.py $SD"
# hist key=value… — one line of history.ndjson (every walk, every distinct skip)
hist() {
  [ "$dry" = 1 ] && return 0
  python3 - "$SD/history.ndjson" "$@" <<'PY' 2>/dev/null
import json, sys, time
d = {"ts": int(time.time())}
for kv in sys.argv[2:]:
    k, _, v = kv.partition("=")
    d[k] = int(v) if v.isdigit() and k in ("ts", "start", "end", "pid", "age") else v
with open(sys.argv[1], "a") as f:
    f.write(json.dumps(d, ensure_ascii=False, sort_keys=True) + "\n")
PY
  # bounded: the newest 5000 lines
  [ "$(wc -l < "$SD/history.ndjson" 2>/dev/null || echo 0)" -le 5000 ] || {
    tail -n 4000 "$SD/history.ndjson" > "$SD/history.ndjson.tmp" && mv "$SD/history.ndjson.tmp" "$SD/history.ndjson"; }
}
# skip <key> key=value… — a skip is recorded once per key (a throttle per stamp, a lock per holder)
skip() { local k=$1; shift; [ "$(cat "$SD/skip" 2>/dev/null)" = "$k" ] && return 0
  [ "$dry" = 1 ] || printf '%s\n' "$k" > "$SD/skip"; hist ev=skip "$@"; }

t=$(date +%s)
mode=tick; [ "$now" = 1 ] && mode=now
if [ "$recover" = 1 ] && [ "$dry" = 0 ]; then
  $REC start ${rexp[@]+"${rexp[@]}"} ${rwhy:+--why "$rwhy"} >&2 || exit 1
fi
due=0
if [ "$dry" = 0 ] && [ -f "$SD/recover.json" ]; then
  dline=$($REC due 2>&1) && due=1
  case "$dline" in *abandoned*|exhausted*) printf '%s\n' "$dline" | while IFS= read -r l; do hist ev=recover line="$l"; done ;; esac
fi
[ "$due" = 1 ] && mode=recover
if [ "$now" = 0 ] && [ "$dry" = 0 ] && [ "$due" = 0 ]; then
  last=$(sed -n 1p "$SD/stamp" 2>/dev/null); last=$(secs "$last" 0)
  if [ -f "$SD/red" ]; then every=$(secs "${FLEET_CN_PROBE_RED_SECS:-}" 3600); else every=$(secs "${FLEET_CN_PROBE_SECS:-}" 21600); fi
  if [ $((t - last)) -lt "$every" ]; then
    [ "$last" -le "$t" ] || { skip "clock:$last" why=clock_behind_stamp stamp="$last"; exit 0; }
    skip "throttle:$last" why=throttle stamp="$last" next="$((last + every))"; exit 0
  fi
fi
# one run at a time: the lock holds its pid — a holder that is gone is taken over
# at once, a live one after an hour (a run that hangs)
if ! mkdir "$SD/lock" 2>/dev/null; then
  hp=$(sed -n 1p "$SD/lock/pid" 2>/dev/null | awk '{print $1}'); hp=$(secs "$hp" '')
  if [ -n "$hp" ] && ! kill -0 "$hp" 2>/dev/null; then
    hist ev=lock_reclaimed why=holder_gone pid="$hp" mode="$mode"
  elif [ -n "$(find "$SD/lock" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
    hist ev=lock_reclaimed why=older_than_60m pid="${hp:-0}" mode="$mode"
  else
    skip "lock:${hp:-?}" why=lock_held pid="${hp:-0}" mode="$mode"; exit 0
  fi
  rm -rf "$SD/lock" 2>/dev/null; mkdir "$SD/lock" 2>/dev/null || exit 0
fi
trap 'rm -rf "$SD/lock" 2>/dev/null' EXIT
printf '%s %s\n' "$$" "$t" > "$SD/lock/pid"
[ "$dry" = 1 ] || { printf '%s\n' "$t" > "$SD/stamp"; rm -f "$SD/skip"; }

# the stable this run tests: what every client, login and pod follows now
stable=$($GH api "repos/$repo/commits/stable" --jq .sha 2>/dev/null)
case "$stable" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *) stable='' ;; esac

# one run id for the whole run: the probe's run dir, the ensure stage, the diagnosis
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -dc 0-9a-f)
RUNS=${FLEET_CN_PROBE_RUNS:-$SD/runs}
export FLEET_CN_PROBE_RUN_ID=$RUN_ID FLEET_CN_PROBE_RUNS=$RUNS
if [ "$due" = 1 ]; then
  $REC begin "$RUN_ID" "$$" >/dev/null 2>&1 || { due=0; mode=now; }
fi
hist ev=start mode="$mode" run_id="$RUN_ID" stable="$stable" pid="$$"
ens='' ens_rc=0
if [ "$dry" = 0 ]; then
  e0=$(date +%s)
  ens=$($ENSURE --repo "$repo" ${stable:+--stable "$stable"} 2>&1); ens_rc=$?
  ens=$(printf '%s\n' "$ens" | sed '/^$/d; s/^/ENSURE /')
fi
if [ "$ens_rc" != 0 ]; then
  # the test road is not there: say so as the run's result, open no session on it
  efail=$(printf '%s\n' "$ens" | grep -E '^ENSURE (ENSURE )?[a-z]+ fail ' | head -n 1 | sed 's/^ENSURE //; s/^ENSURE //')
  epart=$(printf '%s' "$efail" | awk '{print $1}'); epart=${epart:-ensure}
  rd="$RUNS/$RUN_ID"; (umask 077; mkdir -p "$rd/ev"); chmod 700 "$rd" 2>/dev/null
  printf '%s\n' "$ens" | python3 "$BIN/fleet-cn-probe-result.py" redact > "$rd/ev/ensure.txt"
  printf 'fail\tensure:%s\tenv\tensure_%s_failed\t%s\t%s\tev/ensure.txt\t%s\n' "$epart" "$epart" "$e0" "$(date +%s)" \
    "$(printf '%s' "${efail:-the ensure step exited $ens_rc}" | tr '\t' ' ')" > "$rd/stages.tsv"
  [ "${FLEET_CN_PROBE_DIAG:-1}" = 0 ] || ${FLEET_CN_PROBE_DIAG_CMD:-bash $BIN/fleet-cn-probe-diag.sh} --run-dir "$rd" >/dev/null 2>&1
  out=$(printf '%s\n' "$ens"; printf 'INFO probe not walked: the test road is not there (ensure exited %s)\n' "$ens_rc"
        python3 "$BIN/fleet-cn-probe-result.py" render "$rd")
else
  out=$( { [ -z "$ens" ] || printf '%s\n' "$ens"; $PROBE 2>&1; } )
fi
[ "$dry" = 1 ] || printf '%s\n' "$out" > "$SD/last.txt"
# keep the newest FLEET_CN_PROBE_KEEP_RUNS run dirs (60 — ten days of hourly reds)
keep=$(secs "${FLEET_CN_PROBE_KEEP_RUNS:-}" 60)
if [ "$dry" = 0 ] && [ -d "$RUNS" ] && [ "$keep" -gt 0 ]; then
  find "$RUNS" -mindepth 1 -maxdepth 1 -type d -name '2*' 2>/dev/null | sort -r | sed -n "$((keep + 1)),\$p" |
    while IFS= read -r old; do rm -rf -- "$old"; done
fi
vline=$(printf '%s\n' "$out" | grep -E '^(通|不通)：' | tail -n 1)
cls=$(printf '%s\n' "$out" | sed -n 's/^CLASS //p' | tail -n 1)
reason=${cls#* }; cls=${cls%% *}
result=$(printf '%s\n' "$out" | sed -n 's/^RESULT //p' | tail -n 1)
stuck='' detail=''
case "$vline" in
  通：*)   verdict=green ;;
  不通：*) verdict=red
           stuck=$(printf '%s' "$vline" | sed -n 's/^不通：卡在 \([^ ]*\) — .*/\1/p')
           detail=$(printf '%s' "$vline" | sed 's/^不通：卡在 [^ ]* — //') ;;
  *)       verdict=red stuck=probe detail="the probe printed no verdict: $(printf '%s\n' "$out" | tail -n 1)"
           cls=probe reason=no_verdict ;;
esac
case "$cls" in product|env|probe|none) ;; *) [ "$verdict" = green ] && cls=none || cls=product ;; esac
case "$reason" in ''|*[!A-Za-z0-9_]*) [ "$verdict" = green ] && reason=ok || reason=unknown ;; esac
# the class says whose failure it is: the product, the test road, the probe itself
case "$cls" in env) word='国内探针环境无效' ;; probe) word='国内探针检测出错' ;; *) word='国内真实用户路径不通' ;; esac
layer=${stuck%%:*}; layer=$(printf '%s' "${layer:-probe}" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')
detail=$(printf '%s' "$detail" | sed 's/__CNP_EXIT=[0-9]*//g; s/[[:space:]][[:space:]]*/ /g' | cut -c1-300)

if [ "$verdict" = green ]; then desc="通：$(printf '%s' "$vline" | sed 's/^通：//')"
else
  case "$cls" in env) desc="环境无效（${reason}）：卡在 $stuck — $detail" ;; probe) desc="检测出错（${reason}）：卡在 $stuck — $detail" ;;
    *) desc="不通（${reason}）：卡在 $stuck — $detail" ;; esac
fi
desc=$(printf '%s' "$desc" | cut -c1-130)
hist ev=run mode="$mode" run_id="$RUN_ID" stable="$stable" verdict="$verdict" class="$cls" reason_code="$reason" \
  stuck="$stuck" start="$t" end="$(date +%s)" result="$result"
rline=''
if [ "$due" = 1 ]; then
  rline=$($REC finish "$RUN_ID" "${result:--}" 2>&1)
  printf '%s\n' "$rline" | while IFS= read -r l; do [ -z "$l" ] || hist ev=recover run_id="$RUN_ID" line="$l"; done
fi

issue=''
if [ "$verdict" = red ]; then
  title="${word}：卡在 $layer"
  body="\`bin/fleet-cn-probe-watch.sh\`（#4180）在 $(hostname -s 2>/dev/null || echo ?) 上走国内真实用户路径（深圳客户端 → 门 / 中转 → 测试 pod：裸 \`fleet\` 进界面、新开 Codex 会话问一句、pod 上建任务），对着 stable \`${stable:0:7}\` 走到 **$stuck** 卡住：

> $detail

类别 **$cls**（product = 产品失败 · env = 测试环境无效 · probe = 探针自己出错，后两者也不算通过），原因码 \`$reason\`，本轮 \`$RUN_ID\`——阶段耗时、证据和只读诊断（版本、镜像 digest、身份、准入读数、凭据路由、开号器）在这台机器的 \`${result:-$RUNS/$RUN_ID/result.json}\`。

<details><summary>探针完整输出</summary>

\`\`\`
$(printf '%s\n' "$out" | tail -n 60)
\`\`\`
</details>

这台机器上的 stable 前移因此被拦（\`bin/fleet-stable.sh\` 的 \`cn:\` 门，读 stable 上的提交状态 \`$CONTEXT\`）——修好合并后关掉这张单，列车就能前移；巡检每小时复测一次，绿了状态自己变回 success。复测：\`bin/fleet-cn-probe.sh\`（一次）或 \`bin/fleet-cn-probe-watch.sh --repo $repo --now\`。"
  if [ "$dry" = 1 ]; then
    printf 'would-file\tcn-path-%s\t%s\n' "$layer" "$title"
  else
    issue=$($FILER --breakage --breakage-key "cn-path-$layer" ${stable:+--fault-sha "$stable"} --repo "$repo" --priority p1 --from cn-probe \
              --title "$title" --body "$body" 2>/dev/null | grep -E '^https?://' | tail -n 1); rc=$?
    [ -n "$issue" ] || { log "filing the red path failed — retried next run"; rc=1; }
  fi
fi

if [ "$dry" = 1 ]; then
  printf 'would-post\t%s\t%s\t%s\n' "${stable:-?}" "$verdict" "$desc"; exit 0
fi

python3 - "$SD/last.json" "$t" "$verdict" "$stuck" "$detail" "$stable" "$issue" "$cls" "$reason" "$RUN_ID" "$result" <<'PY'
import json, sys, os
p, ts, v, stuck, detail, stable, issue, cls, reason, run_id, result = sys.argv[1:12]
d = {"ts": int(ts), "verdict": v, "stuck": stuck, "detail": detail, "stable": stable, "issue": issue,
     "class": cls, "reason_code": reason, "run_id": run_id, "result": result}
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
  [ -z "$rline" ] || printf '%s\n' "$rline" | awk '{print "recover\t" $0}'
  exit "$rc"
fi
: > "$SD/red"
printf 'red\t%s\t%s\t%s\n' "${stable:0:7}" "$stuck" "${issue:--}"
[ -z "$rline" ] || printf '%s\n' "$rline" | awk '{print "recover\t" $0}'
# the reminder: one alert per breakage issue (the memo keeps it to one)
if [ -n "$issue" ] && [ "$(cat "$SD/filed" 2>/dev/null)" != "$issue" ]; then
  printf '%s\n' "$issue" > "$SD/filed"
  sock=''; [ -z "$sess" ] || sock=$(fleet_socket "$sess" 2>/dev/null)
  bash "$BIN/fleet-alerts.sh" event ${sock:+-L "$sock"} breakage \
    "fleet: ${word}（卡在 ${stuck} · ${reason}），stable 前移被拦 — $issue" >/dev/null 2>&1 \
    || log "filed $issue but the alert failed"
fi
[ -n "$issue" ] || rc=1
exit "$rc"
