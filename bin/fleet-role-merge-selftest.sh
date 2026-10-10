#!/bin/bash
# fleet-role-merge-selftest.sh — a person writes only what changes (issue #2783,
# EPIC #2781 C2). bin/fleet-role.py merges the built-in agents/<role>.md with the
# person's layer (person-bundle.json's roles.<role>) and this computer's
# ($FLEET_CONF_DIR/roles/<role>.md); render launches the merged one, `fleet role
# show` prints it with each field's source.
#
#   A  every vector in tests/role-merge/*.json gives its `expect` (the Go copy, C6,
#      runs the same set)
#   B  no layer ⇒ render / sha are byte for byte what C1 gives, show is the file
#   C  a person's layer + a local one: render launches the merge (model, effort,
#      the body appended into the system-prompt copy), show --sources names
#      你的 vN / 本机 per field, show --json carries the same
#   D  a broken layer is not used: the last good copy stands, show's first line
#      says why; no last good ⇒ the layer is left out, the launch is the built-in
#   E  locks: conf/agent-locked.list holds a worker's / driver's disallowedTools
#      and permissionMode; a layer cannot drop a built-in item or go below
#   F  a credential-shaped value refuses the layer
#   G  `fleet role show` reaches it (bin/fleet's fleet-<cmd>.py dispatch)
#   H  fleet-doctor's `roles` row: none in the degenerate case, 有本机层 with one
#   I  the person's layer is read again before a launch (issue #2784, C3): a cache
#      older than FLEET_ROLE_STALE is re-read and the launch uses the new version;
#      a fresh one is not; the hub refusing (503) or hanging leaves the cache
#      standing within FLEET_ROLE_FETCH_SECS; FLEET_ROLE_STALE=0 or no layer here
#      asks nothing
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/role-merge-st.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 HOME="$WORK/home"
unset FLEET_ORCH_MODEL FLEET_ORCH_EFFORT FLEET_ORCH_CODEX_MODEL FLEET_STEWARD_MODEL \
      FLEET_STEWARD_EFFORT FLEET_STEWARD_CODEX_MODEL FLEET_MODEL FLEET_MODEL_FALLBACK \
      FLEET_ROLE_AGENTS_DIR CLAUDE_CONFIG_DIR
mkdir -p "$HOME/.claude" "$FLEET_CONF_DIR/roles"
R() { python3 "$BIN/fleet-role.py" "$@"; }
VEC="$ROOT/tests/role-merge"

# --- A the vectors -------------------------------------------------------------
n=0
for f in "$VEC"/*.json; do
  n=$((n + 1))
  d=$(R merge --vector "$f" | python3 -c '
import json, sys
got = json.load(sys.stdin); want = json.load(open(sys.argv[1]))["expect"]
print("" if got == want else "got %s" % json.dumps(got, ensure_ascii=False, sort_keys=True))' "$f" 2>&1)
  [ -z "$d" ] && ok "A: ${f##*/}" || bad "A: ${f##*/} — $d"
done
[ "$n" -ge 15 ] && ok "A: $n vectors" || bad "A: only $n vectors in tests/role-merge"
python3 - "$VEC" <<'PY' && ok "A: the vectors cover add · remove · replace · delete · lock for every kind of field" || bad "A: a kind of field lacks a case"
import json, os, sys
seen = set()
for f in os.listdir(sys.argv[1]):
    if not f.endswith('.json'):
        continue
    v = json.load(open(os.path.join(sys.argv[1], f)))
    for l in v['layers']:
        fr = l.get('front') or {}
        for k, x in fr.items():
            if isinstance(x, list):
                if x[:1] == ['!replace']: seen.add('list-replace')
                if any(isinstance(i, str) and i.startswith('-') for i in x): seen.add('list-remove')
                if any(isinstance(i, str) and not i.startswith('-') for i in x): seen.add('list-add')
            elif isinstance(x, dict):
                seen.add('dict-merge')
                if any(i is None for i in x.values()): seen.add('dict-delete')
            elif k == 'body':
                seen.add('body-replace')
            else:
                seen.add('scalar')
        if (l.get('body') or '').strip(): seen.add('body-append')
    if v['locks']: seen.add('lock')
    if v['expect']['refused']: seen.add('refused')
need = {'scalar', 'list-add', 'list-remove', 'list-replace', 'dict-merge', 'dict-delete',
        'body-append', 'body-replace', 'lock', 'refused'}
sys.exit(0 if need <= seen else 1)
PY

# --- B no layer = C1 ------------------------------------------------------------
for role in orchestrator steward worker epic-driver; do
  a=$(R render "$role" --kv 2>&1); s=$(R show "$role")
  b=$(FLEET_ROLE_AGENTS_DIR="$ROOT/agents" R render "$role" --kv 2>&1)
  [ "$a" = "$b" ] && [ "$(R render "$role" --kv | sed -n 's/^sha\t//p')" = "$(R sha "$role")" ] \
    && ok "B: $role — no layer, the launch and sha are the definition's" || bad "B: $role: [$a] vs [$b]"
  [ "$s" = "$(cat "$ROOT/agents/$role.md")" ] && ok "B: $role — show is agents/$role.md byte for byte" \
    || bad "B: $role: show differs from agents/$role.md"
done
[ "$(R show worker | awk 'f; /^---$/ && ++n == 2 { f = 1 }')" = "$(R body worker)" ] \
  && ok "B: show's body is the definition's body" || bad "B: show's body differs from the definition's"

# --- C a person's layer + a local one ------------------------------------------
cat > "$FLEET_CONF_DIR/person-bundle.json" <<'JSON'
{"version": 7, "bundle": {"roles": {"steward": "---\nmodel: sonnet\nskills: [+fleet-steward]\n---\n每次巡完写一句总结。\n"}}}
JSON
printf -- '---\neffort: low\n---\n' > "$FLEET_CONF_DIR/roles/steward.md"
kv=$(R render steward --kv)
bodyf=$(printf '%s\n' "$kv" | sed -n 's/^body\t//p')
printf '%s\n' "$kv" | grep -qx 'model	sonnet' && printf '%s\n' "$kv" | grep -qx 'effort	low' \
  && grep -q '^## （你加的）$' "$bodyf" && grep -q '每次巡完写一句总结' "$bodyf" \
  && [ "$(printf '%s\n' "$kv" | sed -n 's/^sha\t//p')" != "$(R sha steward)" ] \
  && ok "C: render launches the merge — model from the person, effort from this computer, the body appended, a new sha" \
  || bad "C: render: $kv"
sh=$(R show steward --sources)
printf '%s\n' "$sh" | grep -q '^model: sonnet *# 你的 v7$' && printf '%s\n' "$sh" | grep -q '^effort: low *# 本机$' \
  && printf '%s\n' "$sh" | grep -q '^skills: *# 你的 v7$' && printf '%s\n' "$sh" | grep -q '^name: steward *# 自带$' \
  && printf '%s\n' "$sh" | grep -q '^# 正文：自带 + 你的 v7$' \
  && ok "C: show --sources names 自带 / 你的 v7 / 本机 per field and for the body" || bad "C: show --sources: $sh"
R show steward --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["front"]["model"] == "sonnet" and d["sources"]["model"] == ["person:v7"], d
assert d["sources"]["effort"] == ["local"] and d["layers"] == ["person:v7", "local"], d' \
  && ok "C: show --json carries the fields, the sources and the layers" || bad "C: show --json"
R render steward --agent codex --kv | grep -qx 'effort	low' \
  && ok "C: a Codex launch takes the merged effort too" || bad "C: codex effort"

# --- D a broken layer -----------------------------------------------------------
printf -- '---\neffort: turbo\n---\n' > "$FLEET_CONF_DIR/roles/steward.md"
sh=$(R show steward --sources)
printf '%s\n' "$sh" | head -1 | grep -q '^# ⚠ 本机 .*不用：effort: turbo.*用上一份好的' \
  && printf '%s\n' "$sh" | grep -q '^effort: low *# 本机$' \
  && R render steward --kv | grep -qx 'effort	low' \
  && ok "D: a broken local layer is not used — its last good copy stands, show's first line says why" \
  || bad "D: broken local layer: $sh"
rm -f "$FLEET_CONF_DIR/roles/steward.local.good.json"
sh=$(R show steward --sources)
printf '%s\n' "$sh" | head -1 | grep -q '没有上一份好的，这一层不算' && printf '%s\n' "$sh" | grep -q '^effort: medium *# 自带$' \
  && ok "D: no last good copy ⇒ the layer is left out, the built-in's effort" || bad "D: no good copy: $sh"
rm -f "$FLEET_CONF_DIR/roles/steward.md"
printf '{"version": 8, "bundle": {"roles": {"steward": "---\\nmodel: sonnet\\nmaxTurns: 3\\n---\\n"}}}\n' > "$FLEET_CONF_DIR/person-bundle.json"
sh=$(R show steward --sources)
printf '%s\n' "$sh" | head -1 | grep -q '^# ⚠ 你的 v8 不用：maxTurns .*用上一份好的（person:v7）' \
  && printf '%s\n' "$sh" | grep -q '^model: sonnet *# 你的 v7$' \
  && ok "D: a broken person layer (v8) gives way to the last good one (v7)" || bad "D: broken person layer: $sh"
rm -f "$FLEET_CONF_DIR/roles/steward.person.good.json"
printf '{"version": 7, "bundle": {"roles": {"steward": "---\\nmodel: haiku\\n---\\n"}}}\n' > "$FLEET_CONF_DIR/person-bundle.good.json"
R show steward --sources | grep -q '^model: haiku *# 你的 v7$' \
  && ok "D: with no copy of its own, person-bundle.good.json's layer is the last good one" || bad "D: person-bundle.good.json not read"
rm -f "$FLEET_CONF_DIR/person-bundle.json" "$FLEET_CONF_DIR/person-bundle.good.json" "$FLEET_CONF_DIR"/roles/*.good.json

# --- E locks --------------------------------------------------------------------
for p in role.worker.disallowedTools role.worker.permissionMode role.epic-driver.disallowedTools role.epic-driver.permissionMode; do
  grep -q "^$p\\b" "$ROOT/conf/agent-locked.list" && ok "E: agent-locked.list holds $p" || bad "E: agent-locked.list lacks $p"
done
mkdir -p "$WORK/ag"; cp "$ROOT"/agents/*.md "$WORK/ag/"
python3 - "$WORK/ag/worker.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('mcpServers:\n', 'permissionMode: default\ndisallowedTools: [Agent(general-purpose)]\nmcpServers:\n', 1)
open(p, 'w').write(s)
PY
printf -- '---\ndisallowedTools: [!replace, WebFetch]\npermissionMode: bypassPermissions\n---\n' > "$FLEET_CONF_DIR/roles/worker.md"
sh=$(FLEET_ROLE_AGENTS_DIR="$WORK/ag" R show worker --sources)
args=$(FLEET_ROLE_AGENTS_DIR="$WORK/ag" R render worker | paste -sd' ' -)
case "$args" in *'--disallowedTools=WebFetch,Agent(general-purpose)'*'--permission-mode default'*)
  printf '%s\n' "$sh" | grep -q '^disallowedTools: *# 本机 + 🔒$' && printf '%s\n' "$sh" | grep -q '^permissionMode: default *# 本机 + 🔒$' \
    && ok "E: a layer cannot drop a locked built-in item nor go below the built-in permissionMode; show marks 🔒" \
    || bad "E: show: $sh" ;;
  *) bad "E: render under a lock: $args" ;;
esac
rm -f "$FLEET_CONF_DIR/roles/worker.md"

# --- F credentials ----------------------------------------------------------------
printf -- '---\nmcpServers:\n  - {"x": {"command": "x", "env": {"API_KEY": "abcd1234efgh"}}}\n---\n' > "$FLEET_CONF_DIR/roles/worker.md"
R show worker --sources | head -1 | grep -q 'credential-shaped' && ! R render worker --json | grep -q abcd1234 \
  && ok "F: a credential-shaped value refuses the layer" || bad "F: $(R show worker --sources | head -1)"
printf -- '---\nmcpServers:\n  - {"x": {"command": "x", "env": {"API_KEY": "${MY_KEY}"}}}\n---\n' > "$FLEET_CONF_DIR/roles/worker.md"
R show worker --sources | grep -q '^# ⚠' && bad "F: an env-name reference was refused" \
  || ok "F: an env-name reference (\${MY_KEY}) passes"
rm -f "$FLEET_CONF_DIR/roles/worker.md"

# --- H the doctor's row -----------------------------------------------------------
[ -z "$(R doctor)" ] && ok "H: no local layer, every layer used ⇒ no doctor row" || bad "H: a row with nothing to say: $(R doctor)"
printf -- '---\neffort: low\n---\n' > "$FLEET_CONF_DIR/roles/steward.md"
R doctor | grep -q '^WARN	有本机层：steward' && grep -q 'fleet-role.py" doctor' "$BIN/fleet-doctor.sh" \
  && ok "H: a local layer ⇒ fleet-doctor's roles row says 有本机层" || bad "H: doctor: $(R doctor)"
rm -f "$FLEET_CONF_DIR/roles/steward.md"

# --- G the command ----------------------------------------------------------------
[ -x "$BIN/fleet-role.py" ] && sh "$BIN/fleet" role show steward --sources 2>/dev/null | grep -q '^model: opus *# 自带$' \
  && ok "G: fleet role show reaches fleet-role.py" || bad "G: fleet role show: $(sh "$BIN/fleet" role show steward 2>&1 | head -3)"
grep -q 'fleet role show' "$BIN/fleet" && ok "G: fleet --help names it" || bad "G: fleet --help lacks fleet role show"

# --- I the person's layer, read again before a launch (#2784) ---------------------
rm -f "$FLEET_CONF_DIR"/roles/*.good.json "$FLEET_CONF_DIR"/roles/*.last.json
asked="$WORK/asked"
pb() {   # pb <version> <model> <age secs> — this login's cached personal layer
  python3 - "$FLEET_CONF_DIR/person-bundle.json" "$1" "$2" "$3" <<'PY'
import json, sys, time
p, v, m, age = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
json.dump({"version": v, "fetched": int(time.time()) - age,
           "bundle": {"roles": {"steward": "---\nmodel: %s\n---\n" % m}}}, open(p, "w"))
PY
  rm -f "$FLEET_CONF_DIR/person-sync.json" "$FLEET_CONF_DIR/roles/person-refresh.at" "$asked"
}
printf '{"version":2,"bundle":{"roles":{"steward":"---\\nmodel: haiku\\n---\\n"}}}\n' > "$WORK/hub-v2.json"
model() { R render steward --kv 2>/dev/null | sed -n 's/^model	//p'; }
pb 1 sonnet 3600
[ "$(FLEET_PERSON_BUNDLE_CMD="touch $asked; cat $WORK/hub-v2.json" model)" = haiku ] && [ -e "$asked" ] \
  && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$FLEET_CONF_DIR/person-bundle.json")" = 2 ] \
  && ok "I: a cache older than FLEET_ROLE_STALE is read again; the launch uses v2 (haiku)" || bad "I: stale not refreshed: $(model)"
[ "$(FLEET_PERSON_BUNDLE_CMD="touch $asked.2; exit 1" model)" = haiku ] && [ ! -e "$asked.2" ] \
  && ok "I: a fresh cache asks nothing" || bad "I: a fresh cache was read again"
pb 1 sonnet 3600
t0=$(date +%s)
[ "$(FLEET_PERSON_BUNDLE_CMD="touch $asked; echo 503 >&2; exit 1" model)" = sonnet ] && [ -e "$asked" ] \
  && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rc"])' "$FLEET_CONF_DIR/person-sync.json")" = 1 ] \
  && ok "I: the hub refusing → the launch uses the cached v1, the failure recorded" || bad "I: 503: $(model)"
pb 1 sonnet 3600
t0=$(date +%s)
m=$(FLEET_ROLE_FETCH_SECS=2 FLEET_PERSON_BUNDLE_CMD="touch $asked; sleep 20" model); t1=$(date +%s)
[ "$m" = sonnet ] && [ $((t1 - t0)) -le 8 ] && [ -e "$asked" ] \
  && ok "I: the hub hanging → the launch waits FLEET_ROLE_FETCH_SECS, then uses the cache ($((t1 - t0))s)" || bad "I: hang: $m in $((t1 - t0))s"
[ "$(FLEET_PERSON_BUNDLE_CMD="touch $asked.3; cat $WORK/hub-v2.json" model)" = sonnet ] && [ ! -e "$asked.3" ] \
  && ok "I: a refresh that just failed is not tried again for a minute" || bad "I: retried at once"
pb 1 sonnet 3600
[ "$(FLEET_ROLE_STALE=0 FLEET_PERSON_BUNDLE_CMD="touch $asked; cat $WORK/hub-v2.json" model)" = sonnet ] && [ ! -e "$asked" ] \
  && ok "I: FLEET_ROLE_STALE=0 → nothing asked" || bad "I: STALE=0 asked"
rm -f "$FLEET_CONF_DIR/person-bundle.json" "$FLEET_CONF_DIR/person-sync.json" "$FLEET_CONF_DIR"/roles/*.good.json "$FLEET_CONF_DIR"/roles/person-refresh.at
[ "$(FLEET_PERSON_BUNDLE_CMD="touch $asked; cat $WORK/hub-v2.json" model)" = opus ] && [ ! -e "$asked" ] \
  && [ ! -e "$FLEET_CONF_DIR/person-bundle.json" ] && ok "I: no personal layer here → nothing asked, the built-in launch" || bad "I: degenerate asked"

[ "$fails" = 0 ] && { echo "fleet-role-merge selftest: all green"; exit 0; }
echo "fleet-role-merge selftest: $fails FAILED"; exit 1
