#!/usr/bin/env bash
# hub-deploy's safety net (issue #2013, EPIC #1982): a hub release needs no
# approval any more, so the workflow checks its own work, rolls itself back and
# says what it shipped. This file holds the parts that are plain logic — the
# workflow (../../workflows/hub-deploy.yml) holds the kubectl / gh calls.
#
#   release.sh health <commit>            /healthz = 200 AND /version's commit =
#                                         <commit> on every $HUB_URLS address,
#                                         retried up to $HEALTH_SECS (120) each.
#                                         HUB_DEPLOY_SIMULATE_UNHEALTHY=true fails
#                                         it on purpose (the rollback drill).
#   release.sh changes <old> <new>        Markdown for the job summary: the
#                                         commits between the two (tokenledger
#                                         deploy/k8s), whether the store's schema
#                                         changed, the manifests' diff.
#   release.sh env <deploy.json>          one line per env / envFrom entry of the
#                                         ccquota container (sorted), for a
#                                         before/after diff. '-' = stdin.
#   release.sh --selftest                 pure logic only; no network, no cluster.
set -euo pipefail

HEALTH_SECS=${HEALTH_SECS:-120}
HEALTH_STEP=${HEALTH_STEP:-5}

version_commit() { # the commit field of a /version body on stdin, or ""
  python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("commit",""))
except Exception: print("")'
}

health_one() { # <url> <want> → 0 when healthy within HEALTH_SECS
  local url=$1 want=$2 code got deadline
  deadline=$(( $(date +%s) + HEALTH_SECS ))
  while :; do
    code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "$url/healthz" 2>/dev/null || true)
    got=$(curl -fsS -m 10 "$url/version" 2>/dev/null | version_commit || true)
    if [ "$code" = 200 ] && [ "$got" = "$want" ]; then
      echo "ok   $url  /healthz=200  /version commit=$got"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "FAIL $url  /healthz=${code:-none}  /version commit='${got}' (want '$want')"
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

# Lines a diff of tokenledger/internal/store adds that change the schema: the
# embedded schema.sql and the ALTER list in store.go's migrate() are where it
# lives. A heuristic — it says "maybe", the diff is the truth.
schema_lines() { # git diff on stdin → the added schema-changing lines
  grep -E '^\+[^+]' | grep -iE 'CREATE (TABLE|(UNIQUE )?INDEX|VIEW|TRIGGER)|ALTER TABLE|DROP (TABLE|INDEX|COLUMN)|RENAME (TO|COLUMN)|\{ *"[a-z_]+" *, *"[a-z_]+" *, *"[A-Z]' || true
}

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
    printf '%s\n' "$mig" | head -40
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
    git diff "$range" -- deploy/k8s | head -300
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

  [ "$fail" = 0 ] && echo "hub-release selftest: ok"
  return "$fail"
}

case "${1:-}" in
  health) shift; cmd_health "$@" ;;
  changes) shift; cmd_changes "$@" ;;
  env) shift; cmd_env "$@" ;;
  --selftest) selftest ;;
  *) sed -n '2,20p' "$0" >&2; exit 2 ;;
esac
