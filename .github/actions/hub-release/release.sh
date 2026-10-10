#!/usr/bin/env bash
# hub-deploy's safety net (issue #2013, EPIC #1982): a hub release needs no
# approval any more, so the workflow checks its own work, rolls itself back and
# says what it shipped. This file holds the parts that are plain logic — the
# workflow (../../workflows/hub-deploy.yml) holds the kubectl / gh calls.
#
#   release.sh health <commit>            /healthz = 200 AND /version's commit =
#                                         <commit> on every $HUB_URLS address,
#                                         retried up to $HEALTH_SECS (120) each.
#                                         Plus the entry (issue #2060): GET
#                                         /install = 200 with a `#!` first line,
#                                         /version names `stable`, POST
#                                         /v1/fleet/login/start is not 404 — a
#                                         deploy that lost its config otherwise
#                                         looks healthy. HEALTH_ENTRY=0 skips it.
#                                         HUB_DEPLOY_SIMULATE_UNHEALTHY=true fails
#                                         it on purpose (the rollback drill).
#   release.sh changes <old> <new>        Markdown for the job summary: the
#                                         commits between the two (tokenledger
#                                         deploy/k8s), whether the store's schema
#                                         changed, the manifests' diff.
#   release.sh env <deploy.json>          one line per env / envFrom entry of the
#                                         ccquota container (sorted), for a
#                                         before/after diff. '-' = stdin.
#   release.sh hold                       the batching (issue #2052): a push's
#                                         run waits until master has been quiet
#                                         for $QUIET_MINUTES (no newer
#                                         tokenledger / deploy/k8s commit) AND
#                                         $MIN_GAP_MINUTES have passed since the
#                                         last successful release; a newer such
#                                         commit landing meanwhile supersedes it
#                                         (its own run, queued behind this one,
#                                         ships both). Prints verdict=go |
#                                         verdict=superseded + newer=<sha>.
#   release.sh shape <render>             which shape a render is (issue #2125):
#                                         `mode=sqlite` — a data disk, so one
#                                         replica + Recreate + no CCQUOTA_DB_URL
#                                         + no disruption budget — or
#                                         `mode=postgres` — no disk, ≥ 2 replicas,
#                                         RollingUpdate maxUnavailable 0, the
#                                         db-url, /readyz, a preStop, a PDB.
#                                         Anything between is refused (exit 1,
#                                         one line per fault): two pods on one
#                                         SQLite file is a corrupt database.
#                                         <render> = JSON documents (yq -o=json),
#                                         '-' = stdin.
#   release.sh probe <url> <stop> [secs]  the availability probe (probe.sh):
#                                         per second, /healthz + a write; ends
#                                         with probes= downtime_seconds= …
#   release.sh --selftest                 pure logic only; no network, no cluster.
set -euo pipefail

HEALTH_SECS=${HEALTH_SECS:-120}
HEALTH_STEP=${HEALTH_STEP:-5}

version_commit() { # the commit field of a /version body on stdin, or ""
  python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("commit",""))
except Exception: print("")'
}

version_stable() { # the stable field of a /version body on stdin, or ""
  python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("stable") or "")
except Exception: print("")'
}

# What people reach first (issue #2060): prod-e2be8bb answered /healthz and its
# commit while /install and `fleet login` were 404 and /version had dropped
# `stable` — nobody could install, and clients followed the image's own pack
# past stable. Prints the faults, one per line; nothing = the entry is whole.
entry_faults() { # <url> <version body>
  local url=$1 ver=$2 code body first
  [ "${HEALTH_ENTRY:-1}" = 0 ] && return 0
  body=$(curl -sS -m 10 -w '\n%{http_code}' "$url/install" 2>/dev/null || true)
  code=${body##*$'\n'}; first=${body%%$'\n'*}
  case "$code:$first" in 200:'#!'*) ;; *) echo "/install=${code:-none} first line '${first:0:30}' (want 200, '#!')" ;; esac
  [ -n "$(printf '%s' "$ver" | version_stable)" ] || echo "/version has no stable (CCQUOTA_FLEET_STABLE_REPO lost? clients would skip stable)"
  code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
         -d '{}' "$url/v1/fleet/login/start" 2>/dev/null || true)
  case "$code" in 4??) [ "$code" != 404 ] && [ "$code" != 405 ] ;; *) false ;; esac \
    || echo "/v1/fleet/login/start=${code:-none} (want a 4xx refusal of the empty body, not 404)"
}

health_one() { # <url> <want> → 0 when healthy within HEALTH_SECS
  local url=$1 want=$2 code ver got faults deadline
  deadline=$(( $(date +%s) + HEALTH_SECS ))
  while :; do
    code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "$url/healthz" 2>/dev/null || true)
    ver=$(curl -fsS -m 10 "$url/version" 2>/dev/null || true)
    got=$(printf '%s' "$ver" | version_commit)
    faults=''
    if [ "$code" = 200 ] && [ "$got" = "$want" ]; then
      faults=$(entry_faults "$url" "$ver")
      if [ -z "$faults" ]; then
        echo "ok   $url  /healthz=200  /version commit=$got  entry ok"
        return 0
      fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "FAIL $url  /healthz=${code:-none}  /version commit='${got}' (want '$want')"
      [ -z "$faults" ] || printf '%s\n' "$faults" | sed "s|^|FAIL $url  |"
      return 1
    fi
    sleep "$HEALTH_STEP"
  done
}

cmd_health() {
  local want=${1:?usage: health <commit>} url rc=0
  if [ "${HUB_DEPLOY_SIMULATE_UNHEALTHY:-false}" = true ]; then
    echo "FAIL simulated: workflow_dispatch input simulate_unhealthy=true (the rollback drill)"
    return 1
  fi
  for url in ${HUB_URLS:?HUB_URLS unset}; do
    health_one "$url" "$want" || rc=1
  done
  return "$rc"
}

cmd_shape() { # <render JSON | -> → mode=sqlite | mode=postgres, or the faults
  python3 -c "$SHAPE_PY" "${1:--}"
}

SHAPE_PY=$(cat <<'PY'
import json, sys
src = sys.argv[1]
raw = (sys.stdin.read() if src == '-' else open(src).read()).strip()
docs, dec, i = [], json.JSONDecoder(), 0
while i < len(raw):
    while i < len(raw) and raw[i].isspace(): i += 1
    if i >= len(raw): break
    d, i = dec.raw_decode(raw, i)
    if d: docs.extend(d.get('items', []) if d.get('kind') == 'List' else [d])
deps = [d for d in docs if d.get('kind') == 'Deployment' and d.get('metadata', {}).get('name') == 'ccquota-hub']
if len(deps) != 1:
    print('the render has %d ccquota-hub Deployment(s), want 1' % len(deps)); sys.exit(1)
dep = deps[0]; spec = dep.get('spec', {}); pod = spec.get('template', {}).get('spec', {})
hub = ([c for c in pod.get('containers', []) if c.get('name') == 'ccquota'] or [{}])[0]
env = {e.get('name') for e in hub.get('env') or []}
# The data disk is the claim mounted at /data (components/sqlite-single's
# ccquota-data); another claim — the RWX /releases volume (#2366) — is no disk.
datavols = {m.get('name') for c in pod.get('containers') or [] for m in c.get('volumeMounts') or [] if m.get('mountPath') == '/data'}
disk = any('persistentVolumeClaim' in v and (v.get('name') in datavols or v['persistentVolumeClaim'].get('claimName') == 'ccquota-data')
           for v in pod.get('volumes') or [])
pdb = any(d.get('kind') == 'PodDisruptionBudget' for d in docs)
replicas = spec.get('replicas', 1)
strat = spec.get('strategy', {}); ru = strat.get('rollingUpdate') or {}
faults = []
if disk:
    mode = 'sqlite'
    if replicas != 1: faults.append('a data disk with replicas %s (want 1: one SQLite file, one writer)' % replicas)
    if strat.get('type') != 'Recreate': faults.append('a data disk with strategy %s (want Recreate: two pods would open one SQLite file)' % strat.get('type'))
    if 'CCQUOTA_DB_URL' in env: faults.append('a data disk AND CCQUOTA_DB_URL (half switched)')
    if pdb: faults.append('a PodDisruptionBudget on one replica (it would block every node drain)')
else:
    mode = 'postgres'
    if not isinstance(replicas, int) or replicas < 2: faults.append('no data disk but replicas %s (want ≥ 2)' % replicas)
    if strat.get('type') != 'RollingUpdate' or str(ru.get('maxUnavailable')) != '0':
        faults.append('strategy %s maxUnavailable %s (want RollingUpdate, 0)' % (strat.get('type'), ru.get('maxUnavailable')))
    if 'CCQUOTA_DB_URL' not in env: faults.append('no data disk and no CCQUOTA_DB_URL (the hub would write a file nobody keeps)')
    if (hub.get('readinessProbe') or {}).get('httpGet', {}).get('path') != '/readyz': faults.append('readiness is not /readyz')
    if not (hub.get('lifecycle') or {}).get('preStop'): faults.append('no preStop (a stopping pod would refuse requests the ingress still sends it)')
    if not pdb: faults.append('no PodDisruptionBudget')
if faults:
    for f in faults: print('mode=%s: %s' % (mode, f))
    sys.exit(1)
print('mode=' + mode)
PY
)

# Lines a diff of tokenledger/internal/store adds that change the schema: the
# embedded schema.sql and the ALTER list in store.go's migrate() are where it
# lives. A heuristic — it says "maybe", the diff is the truth.
schema_lines() { # git diff on stdin → the added schema-changing lines
  grep -E '^\+[^+]' | grep -iE 'CREATE (TABLE|(UNIQUE )?INDEX|VIEW|TRIGGER)|ALTER TABLE|DROP (TABLE|INDEX|COLUMN)|RENAME (TO|COLUMN)|\{ *"[a-z_]+" *, *"[a-z_]+" *, *"[A-Z]' || true
}

# cap <n>: the first n lines, then drain the rest. A bare `| head -n` closes the
# pipe early and the writer dies of SIGPIPE — under pipefail a long diff turned
# a green release's summary into exit 141 (run 37578256836).
cap() { head -n "$1"; cat >/dev/null; }

has_commit() { [ -n "$1" ] && git cat-file -e "$1^{commit}" 2>/dev/null; }

cmd_changes() {
  local old=${1:-} new=${2:?usage: changes <old> <new>} n mig
  if ! has_commit "$new"; then
    echo "_新版本 \`$new\` 不在本仓库历史里，列不出变更。_"; return 0
  fi
  if ! has_commit "$old"; then
    echo "_线上旧版本 \`${old:-?}\` 读不出提交（首次发布，或标签不是 prod-<sha>），列不出变更。_"; return 0
  fi
  if [ "$(git rev-parse "$old")" = "$(git rev-parse "$new")" ]; then
    echo "_旧版本与新版本是同一个提交 \`$new\`：重新发布，没有新提交。_"; return 0
  fi
  local range="$old..$new" back=''
  if git merge-base --is-ancestor "$new" "$old"; then
    back=1; range="$new..$old"   # a rollback to an older tag: what comes OFF
  fi
  n=$(git rev-list --count "$range" -- tokenledger deploy/k8s)
  if [ -n "$back" ]; then
    echo "### 撤下的提交（${n}，新版本比线上旧 — 回退）"
  else
    echo "### 提交（${n}，\`git log --oneline $range -- tokenledger deploy/k8s\`）"
  fi
  echo
  if [ "$n" = 0 ]; then echo "_（无 — 这之间的提交没碰 tokenledger/ 和 deploy/k8s/）_"; else
    echo '```'
    git log --oneline -n 100 "$range" -- tokenledger deploy/k8s
    [ "$n" -le 100 ] || echo "… 还有 $((n - 100)) 条"
    echo '```'
  fi
  echo
  echo "### 数据库 migration"
  echo
  mig=$(git diff "$range" -- tokenledger/internal/store | schema_lines)
  if [ -n "$mig" ]; then
    echo "⚠️ **可能有** — 这之间 \`tokenledger/internal/store\` 加了改表结构的行。回退时只回镜像，数据库不自动恢复；要恢复快照照 deploy/k8s/RUNBOOK.md 手工做。"
    echo
    echo '```diff'
    printf '%s\n' "$mig" | cap 40
    echo '```'
  else
    echo "没有 — \`tokenledger/internal/store\` 这之间没有改表结构的行。"
  fi
  echo
  echo "### 清单（deploy/k8s）"
  echo
  if git diff --quiet "$range" -- deploy/k8s; then
    echo "没变。"
  else
    echo '<details><summary>'"$(git diff --shortstat "$range" -- deploy/k8s)"'</summary>'
    echo
    echo '```diff'
    git diff "$range" -- deploy/k8s | cap 300
    echo '```'
    echo '</details>'
  fi
}

cmd_env() { # <deployment JSON | List JSON | ->
  python3 -c "$ENV_PY" "${1:--}"
}

ENV_PY=$(cat <<'PY'
import json, sys
src = sys.argv[1]
raw = sys.stdin.read() if src == '-' else open(src).read()
docs = []
dec = json.JSONDecoder(); i = 0; raw = raw.strip()
while i < len(raw):           # yq / kubectl may print several documents back to back
    while i < len(raw) and raw[i].isspace(): i += 1
    if i >= len(raw): break
    d, i = dec.raw_decode(raw, i); docs.append(d)
objs = []
for d in docs:
    objs.extend(d.get('items', []) if d.get('kind') == 'List' else [d])
for o in objs:
    if o.get('kind') != 'Deployment': continue
    for c in o.get('spec', {}).get('template', {}).get('spec', {}).get('containers', []):
        if c.get('name') != 'ccquota': continue
        out = []
        for e in c.get('env') or []:
            if 'value' in e: out.append('%s=%s' % (e['name'], e['value']))
            elif 'valueFrom' in e: out.append('%s=<%s>' % (e['name'], json.dumps(e['valueFrom'], sort_keys=True, separators=(',', ':'))))
            else: out.append('%s=' % e['name'])
        for e in c.get('envFrom') or []:
            out.append('envFrom ' + json.dumps(e, sort_keys=True, separators=(',', ':')))
        print('\n'.join(sorted(out)))
PY
)

# hold_verdict <now> <mine> <latest> <latest_ct> <last_release|""> <quiet_s> <gap_s>
# → "go" | "superseded <sha>" | "wait <secs> <why>". Pure: every input is an argument.
hold_verdict() {
  local now=$1 mine=$2 latest=$3 latest_ct=$4 last=$5 quiet=$6 gap=$7 q g
  # A newer relevant commit is on master (or ours is not on it any more): its
  # run is queued behind this one and ships everything up to it.
  [ "$latest" = "$mine" ] || { echo "superseded $latest"; return; }
  q=$(( latest_ct + quiet - now ))
  g=0; [ -z "$last" ] || g=$(( last + gap - now ))
  if [ "$q" -gt 0 ] && [ "$q" -ge "$g" ]; then echo "wait $q quiet"; return; fi
  if [ "$g" -gt 0 ]; then echo "wait $g gap"; return; fi
  echo go
}

iso_epoch() { python3 -c 'import sys,datetime
print(int(datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$1"; }

last_release_epoch() { # the newest successful prod deployment (the deploy job's environment), or ""
  local id t
  for id in $(gh api "repos/$GITHUB_REPOSITORY/deployments?environment=prod&per_page=10" --jq '.[].id' 2>/dev/null); do
    t=$(gh api "repos/$GITHUB_REPOSITORY/deployments/$id/statuses?per_page=30" --jq '[.[] | select(.state == "success")][0].created_at // empty' 2>/dev/null || true)
    [ -z "$t" ] || { iso_epoch "$t"; return 0; }
  done
}

cmd_hold() {
  local quiet=$(( ${QUIET_MINUTES:-10} * 60 )) gap=$(( ${MIN_GAP_MINUTES:-10} * 60 )) poll=${HOLD_POLL:-60}
  local mine=${GITHUB_SHA:?} last latest latest_ct v secs why now
  last=$(last_release_epoch || true)
  if [ -n "$last" ]; then
    echo "last successful release: $(python3 -c 'import sys,time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(int(sys.argv[1]))))' "$last")" >&2
  else
    echo "::warning::could not read the last successful release (deployments API) — only the quiet period applies" >&2
  fi
  while :; do
    git fetch -q origin master 2>/dev/null || echo "::warning::git fetch failed — deciding on the last fetched master" >&2
    read -r latest latest_ct < <(git log -1 --format='%H %ct' origin/master -- tokenledger deploy/k8s)
    now=$(date +%s)
    v=$(hold_verdict "$now" "$mine" "$latest" "$latest_ct" "$last" "$quiet" "$gap")
    case "$v" in
      go) echo "verdict=go"; return 0 ;;
      superseded*) echo "verdict=superseded"; echo "newer=${v#superseded }"; return 0 ;;
      wait*) read -r _ secs why <<<"$v"
             echo "waiting ${secs}s ($why: $( [ "$why" = quiet ] && echo "master quiet for ${QUIET_MINUTES:-10} min" || echo "${MIN_GAP_MINUTES:-10} min since the last release" ))" >&2
             [ "$secs" -le "$poll" ] || secs=$poll
             sleep "$secs" ;;
    esac
  done
}

selftest() {
  local fail=0 t
  ok() { echo "ok   $1"; }
  no() { echo "FAIL $1"; fail=1; }

  t=$(printf '{"version":"prod-abc1234","commit":"abc1234"}' | version_commit)
  [ "$t" = abc1234 ] && ok "version_commit reads the commit" || no "version_commit: '$t'"
  t=$(printf 'not json' | version_commit)
  [ -z "$t" ] && ok "version_commit: garbage → empty" || no "version_commit garbage: '$t'"

  t=$(printf '%s\n' '+CREATE TABLE IF NOT EXISTS foo (' '+		{"fleet_nodes", "kind", "TEXT NOT NULL DEFAULT '"''"'"},' \
        '+// nothing here' '-ALTER TABLE gone' '+++ b/schema.sql' | schema_lines)
  [ "$(printf '%s\n' "$t" | grep -c .)" = 2 ] && ok "schema_lines: CREATE + migrate() row, not removals/headers" || no "schema_lines: $t"
  t=$(printf '%s\n' '+	x := 1' | schema_lines)
  [ -z "$t" ] && ok "schema_lines: plain code is not a migration" || no "schema_lines plain: $t"

  t=$(cmd_env - <<'J'
{"kind":"List","items":[{"kind":"Service"},{"kind":"Deployment","spec":{"template":{"spec":{"containers":[
 {"name":"sidecar","env":[{"name":"X","value":"1"}]},
 {"name":"ccquota","env":[{"name":"B","value":"2"},{"name":"A","valueFrom":{"secretKeyRef":{"name":"s","key":"k"}}}],
  "envFrom":[{"secretRef":{"name":"hub"}}]}]}}}}]}
J
)
  [ "$t" = 'A=<{"secretKeyRef":{"key":"k","name":"s"}}>
B=2
envFrom {"secretRef":{"name":"hub"}}' ] && ok "env: ccquota only, sorted, secret refs by name" || no "env: $t"
  t=$(printf '{"kind":"Deployment","spec":{"template":{"spec":{"containers":[{"name":"ccquota","env":[{"name":"Z","value":"9"}]}]}}}}\n{"kind":"Service"}\n' | cmd_env -)
  [ "$t" = 'Z=9' ] && ok "env: several documents back to back" || no "env multi-doc: $t"

  t=$(printf '{"commit":"abc1234","stable":"644641e"}' | version_stable)
  [ "$t" = 644641e ] && ok "version_stable reads stable" || no "version_stable: '$t'"
  t=$(printf '{"commit":"abc1234"}' | version_stable)
  [ -z "$t" ] && ok "version_stable: none → empty" || no "version_stable none: '$t'"
  t=$(entry_faults http://127.0.0.1:9 '{"commit":"abc1234"}')
  [ "$(printf '%s\n' "$t" | grep -c .)" = 3 ] && ok "entry_faults: an unreachable entry names all three" || no "entry_faults: $t"
  t=$(HEALTH_ENTRY=0 entry_faults http://127.0.0.1:9 '{}')
  [ -z "$t" ] && ok "entry_faults: HEALTH_ENTRY=0 skips" || no "entry_faults skip: $t"

  t=$(HUB_DEPLOY_SIMULATE_UNHEALTHY=true HUB_URLS=http://127.0.0.1:9 cmd_health abc1234 2>&1) && no "simulated health passed" || ok "health: simulate_unhealthy fails at once"
  t=$(HEALTH_SECS=0 HUB_URLS=http://127.0.0.1:9 cmd_health abc1234 2>&1) && no "unreachable health passed" || ok "health: an unreachable address fails"

  if git rev-parse --verify -q HEAD~1 >/dev/null; then
    t=$(cmd_changes HEAD~1 HEAD)
    printf '%s' "$t" | grep -q '### 数据库 migration' && ok "changes: forward range renders" || no "changes forward: $t"
    t=$(cmd_changes HEAD HEAD~1)
    printf '%s' "$t" | grep -q '撤下的提交' && ok "changes: a rollback lists what comes off" || no "changes back: $t"
  fi
  t=$(cmd_changes deadbee HEAD)
  printf '%s' "$t" | grep -q '读不出提交' && ok "changes: unknown old commit says so" || no "changes unknown: $t"
  t=$(cmd_changes HEAD HEAD)
  printf '%s' "$t" | grep -q '同一个提交' && ok "changes: same commit says so" || no "changes same: $t"

  # A long change list: >100 commits, a manifest diff and a schema diff far
  # past their caps — the summary must still exit 0 under pipefail.
  # Run as the workflow runs it — the script itself, errexit on (a function
  # inside $(…) would not inherit it, and the failure would hide).
  local repo self
  self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  repo=$(mktemp -d)
  if (
    set -euo pipefail
    cd "$repo"
    git init -q . && git config user.email t@t && git config user.name t
    mkdir -p deploy/k8s tokenledger/internal/store
    echo base > deploy/k8s/a.yaml; git add -A; git commit -qm base
    for i in $(seq 1 120); do echo "c$i" >> tokenledger/x; git add -A; git commit -qm "c$i"; done
    seq 1 20000 | sed 's/^/line: /' > deploy/k8s/a.yaml
    seq 1 500 | sed 's/^/CREATE TABLE t/' > tokenledger/internal/store/s.sql
    git add -A; git commit -qm big
    out=$(bash "$self" changes HEAD~121 HEAD) || exit   # an `if` ignores errexit: check by hand
    printf '%s' "$out" | grep -q '还有 21 条' && printf '%s' "$out" | grep -q '### 清单'
  ); then ok "changes: a long change list exits 0 under pipefail (no SIGPIPE)"; else no "changes: long list failed (exit $?)"; fi
  rm -rf "$repo"

  # hold_verdict: now=10000, quiet 600, gap 1800
  t=$(hold_verdict 10000 aaa aaa 9900 "" 600 1800); [ "$t" = "wait 500 quiet" ] && ok "hold: a fresh commit waits out the quiet period" || no "hold quiet: $t"
  t=$(hold_verdict 10000 aaa aaa 9000 "" 600 1800); [ "$t" = go ] && ok "hold: quiet + no known release ⇒ go" || no "hold go: $t"
  t=$(hold_verdict 10000 aaa aaa 9000 9000 600 1800); [ "$t" = "wait 800 gap" ] && ok "hold: a release 1000s ago waits for the 30 min gap" || no "hold gap: $t"
  t=$(hold_verdict 10000 aaa aaa 9900 8500 600 1800); [ "$t" = "wait 500 quiet" ] && ok "hold: the longer of the two waits" || no "hold both: $t"
  t=$(hold_verdict 10000 aaa aaa 9000 7000 600 1800); [ "$t" = go ] && ok "hold: quiet + gap passed ⇒ go" || no "hold go2: $t"
  t=$(hold_verdict 10000 aaa bbb 9990 "" 600 1800); [ "$t" = "superseded bbb" ] && ok "hold: a newer commit supersedes" || no "hold superseded: $t"
  t=$(iso_epoch 2026-10-07T00:00:00Z); [ "$t" = 1791331200 ] && ok "iso_epoch" || no "iso_epoch: $t"

  # shape: the two good shapes and the mixes between them
  local sq pg
  sq='{"kind":"Deployment","metadata":{"name":"ccquota-hub"},"spec":{"replicas":1,"strategy":{"type":"Recreate"},"template":{"spec":{"containers":[{"name":"ccquota","env":[{"name":"A","value":"1"}],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"d"}}]}}}}'
  pg='{"kind":"Deployment","metadata":{"name":"ccquota-hub"},"spec":{"replicas":2,"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxUnavailable":0,"maxSurge":1}},"template":{"spec":{"containers":[{"name":"ccquota","env":[{"name":"CCQUOTA_DB_URL"}],"readinessProbe":{"httpGet":{"path":"/readyz"}},"lifecycle":{"preStop":{"sleep":{"seconds":5}}}}]}}}}
{"kind":"PodDisruptionBudget"}'
  t=$(printf '%s\n' "$sq" | cmd_shape -); [ "$t" = mode=sqlite ] && ok "shape: one replica on a disk is sqlite" || no "shape sqlite: $t"
  t=$(printf '%s\n' "$pg" | cmd_shape -); [ "$t" = mode=postgres ] && ok "shape: two rolling replicas on Postgres" || no "shape postgres: $t"
  t=$(printf '%s\n' "${sq/\"replicas\":1/\"replicas\":2}" | cmd_shape -) && no "shape: two replicas on a disk passed" || ok "shape: two replicas on one SQLite disk refused"
  t=$(printf '%s\n' "${sq/Recreate/RollingUpdate}" | cmd_shape -) && no "shape: a rolling disk passed" || ok "shape: RollingUpdate on a disk refused"
  t=$(printf '%s\n' "${pg/CCQUOTA_DB_URL/X}" | cmd_shape -) && no "shape: no db-url passed" || ok "shape: two replicas without CCQUOTA_DB_URL refused"
  t=$(printf '%s\n' "${pg/\"maxUnavailable\":0/\"maxUnavailable\":1}" | cmd_shape -) && no "shape: maxUnavailable 1 passed" || ok "shape: maxUnavailable 1 refused"
  t=$(printf '%s\n' "${pg%%$'\n'*}" | cmd_shape -) && no "shape: no PDB passed" || ok "shape: rolling without a PDB refused"
  # #2384: another claim (the RWX /releases volume) is no data disk
  local px sx
  px=${pg/'}]}}}}'/'}],"volumes":[{"name":"releases","persistentVolumeClaim":{"claimName":"ccquota-releases"}}]}}}}'}
  sx=${sq/'"claimName":"d"}}]'/'"claimName":"d"}},{"name":"releases","persistentVolumeClaim":{"claimName":"r"}}]'}
  t=$(printf '%s\n' "$px" | cmd_shape -) || true; [ "$t" = mode=postgres ] && ok "shape: Postgres + an RWX extra claim is still postgres" || no "shape postgres+rwx: $t"
  t=$(printf '%s\n' "$sx" | cmd_shape -) || true; [ "$t" = mode=sqlite ] && ok "shape: sqlite + an extra claim is still sqlite" || no "shape sqlite+extra: $t"

  # probe: nothing listens ⇒ every second down; the verdict is the last line
  local stop; stop=$(mktemp -u)
  t=$(sh "$(dirname "$0")/probe.sh" http://127.0.0.1:9 "$stop" 2 | tail -1)
  case "$t" in "probes="*" downtime_seconds="[1-9]*" write_unsupported=0") ok "probe: an unreachable hub is down, verdict last" ;; *) no "probe: $t" ;; esac

  [ "$fail" = 0 ] && echo "hub-release selftest: ok"
  return "$fail"
}

case "${1:-}" in
  health) shift; cmd_health "$@" ;;
  shape) shift; cmd_shape "$@" ;;
  probe) shift; exec sh "$(dirname "$0")/probe.sh" "$@" ;;
  changes) shift; cmd_changes "$@" ;;
  env) shift; cmd_env "$@" ;;
  hold) shift; cmd_hold "$@" ;;
  --selftest) selftest ;;
  *) sed -n '2,50p' "$0" >&2; exit 2 ;;
esac
