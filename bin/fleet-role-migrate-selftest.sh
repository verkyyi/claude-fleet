#!/bin/bash
# fleet-role-migrate-selftest.sh — the role knobs leave fleet.conf (issue #2788,
# EPIC #2781 C7). bin/fleet-conf.sh migrate's roles step runs bin/fleet-role.py
# migrate-conf: FLEET_ORCH_MODEL / _EFFORT, FLEET_STEWARD_MODEL / _EFFORT and
# FLEET_MODEL that differ from the built-in definition are written into the
# person's layer (one PUT through bin/fleet-config.py's FLEET_PERSON_HUB_CMD seam),
# every such line is commented out (fleet.conf.bak-<time> kept), and the
# machine's own switches stay.
#
#   A  a first run: one new version (note 「从 <机器> 的 fleet.conf 迁入」), only
#      the values that differ; lines commented; Codex / switches / thresholds stay
#   B  idempotent: a second run makes no version and leaves the file byte for byte
#   C  the hub away: the lines that need it stay (they still win), the rest go;
#      fleet-conf.sh still exits 0; the hub back, the next run moves them
#   D  the person's layer already names the field: nothing written, line commented
#   E  the doctor's `roles` row WARNs while a knob is left, says nothing after
#   F  `get worker model` (a launch with no --role) reads the merged definition;
#      render reads the moved value with the conf sourced
#   G  a value that is not a plain literal is left as it is; --dry-run writes nothing
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
R="$BIN/fleet-role.py"
PY=python3
WORK=$(mktemp -d "${TMPDIR:-/tmp}/role-migrate-st.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# the fake hub (as fleet-role-write-selftest.sh's): versions in $HUBDIR/p.json;
# $HUBDIR/down makes every call fail as an unreachable hub would
cat > "$WORK/fakehub.py" <<'PY'
import json, os, sys
d = os.environ["HUBDIR"]; f = os.path.join(d, "p.json")
if os.path.exists(os.path.join(d, "down")):
    print(json.dumps({"status": 0, "error": "connection refused"})); sys.exit(0)
st = json.load(open(f)) if os.path.exists(f) else {"versions": []}
def cur():
    return st["versions"][-1] if st["versions"] else {"version": 0, "prev": 0, "bundle": {}}
m = sys.argv[1]
if m == "GET":
    print(json.dumps(dict(cur(), status=200))); sys.exit(0)
body = json.load(sys.stdin)
c = cur()
if body.get("base") != c["version"]:
    print(json.dumps({"status": 409, "error": "changed"})); sys.exit(0)
n = {"version": c["version"] + 1, "prev": c["version"], "bundle": body["bundle"], "actor": "me", "note": body.get("note", "")}
st["versions"].append(n); json.dump(st, open(f, "w"))
print(json.dumps(dict(n, status=200)))
PY

setup() {   # setup <name> — a sandbox: conf dir, home, hub dir
  S="$WORK/$1"; mkdir -p "$S/conf" "$S/home" "$S/hub"
  HUBCMD="HUBDIR='$S/hub' '$PY' '$WORK/fakehub.py'"
}
run() {     # run <cmd…> — sandboxed, outside any window
  env -i PATH="$PATH" HOME="$S/home" FLEET_CONF_DIR="$S/conf" FLEET_MACHINE_NAME=testbox \
    FLEET_PERSON_HUB_CMD="$HUBCMD \"\$@\"" "$@" 2>&1
}
migrate() { run bash "$BIN/fleet-conf.sh" migrate --quiet; }
nver() { $PY -c 'import json,sys
try: print(len(json.load(open(sys.argv[1]))["versions"]))
except Exception: print(0)' "$S/hub/p.json"; }
hubget() { $PY -c 'import json,sys
v=json.load(open(sys.argv[1]))["versions"][-1]; b=v["bundle"].get("roles",{})
r,_,f=sys.argv[2].partition(".")
o=b.get(r) or {}; fr=o.get("front",o) if isinstance(o,dict) else {}
print(v["note"] if sys.argv[2]=="note" else fr.get(f,""))' "$S/hub/p.json" "$1" 2>/dev/null; }
conf() {
  cat > "$S/conf/fleet.conf" <<CONF
# claude-fleet — this machine's ONE config file
FLEET_HOST=1
if [ "\${FLEET_SHELL:-0}" != 1 ]; then
export FLEET_ORCH_MODEL=opus
FLEET_ORCH_EFFORT=high
export FLEET_STEWARD_MODEL="${1:-sonnet}"
FLEET_STEWARD_EFFORT=medium
FLEET_MODEL=sonnet
FLEET_ORCH_CODEX_MODEL=gpt-5-codex
FLEET_ORCHESTRATOR=1
FLEET_PARK_STALL_SECS=1200
fi
CONF
  chmod 600 "$S/conf/fleet.conf"
}
active() { grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$S/conf/fleet.conf" >/dev/null; }

# A ---------------------------------------------------------------------------
setup a; conf
out=$(migrate)
[ "$(nver)" = 1 ] && ok "A one new version on the hub" || bad "A versions: $(nver) — $out"
[ "$(hubget note)" = '从 testbox 的 fleet.conf 迁入' ] && ok "A note names the machine" || bad "A note: $(hubget note)"
[ "$(hubget orchestrator.model)" = opus ] && [ "$(hubget steward.model)" = sonnet ] \
  && [ "$(hubget worker.model)" = sonnet ] && [ "$(hubget epic-driver.model)" = sonnet ] \
  && ok "A the differing values are in the layer" || bad "A layer: $(cat "$S/hub/p.json")"
[ -z "$(hubget orchestrator.effort)" ] && [ -z "$(hubget steward.effort)" ] \
  && ok "A a value equal to the built-in is not written" || bad "A wrote an equal value"
moved=1; for k in FLEET_ORCH_MODEL FLEET_ORCH_EFFORT FLEET_STEWARD_MODEL FLEET_STEWARD_EFFORT FLEET_MODEL; do active $k && moved=0; done
[ "$moved" = 1 ] && ok "A every role knob is commented out" || bad "A left: $(cat "$S/conf/fleet.conf")"
active FLEET_ORCH_CODEX_MODEL && active FLEET_ORCHESTRATOR && active FLEET_PARK_STALL_SECS \
  && ok "A Codex model, switch and threshold stay" || bad "A took a machine key: $(cat "$S/conf/fleet.conf")"
ls "$S/conf"/fleet.conf.bak-* >/dev/null 2>&1 && ok "A fleet.conf kept as .bak" || bad "A no .bak"
[ "$(stat -c '%a' "$S/conf/fleet.conf" 2>/dev/null || stat -f '%Lp' "$S/conf/fleet.conf")" = 600 ] \
  && ok "A the file keeps its mode" || bad "A mode changed"
case "$out" in *'moved into your layer (入口 v1)'*) ok "A says what moved" ;; *) bad "A output: $out" ;; esac

# B ---------------------------------------------------------------------------
cp "$S/conf/fleet.conf" "$WORK/a.before"
out=$(migrate)
[ "$(nver)" = 1 ] && cmp -s "$WORK/a.before" "$S/conf/fleet.conf" && [ -z "$out" ] \
  && ok "B a second run: no version, file byte for byte, silent" || bad "B not idempotent ($(nver)): $out"

# C ---------------------------------------------------------------------------
setup c; conf; : > "$S/hub/down"
out=$(migrate); rc=$?
[ "$rc" = 0 ] && ok "C fleet-conf.sh exits 0 with the hub away" || bad "C rc=$rc"
active FLEET_ORCH_MODEL && active FLEET_MODEL && active FLEET_STEWARD_MODEL \
  && ok "C the lines that need the hub stay" || bad "C dropped a line it could not move"
! active FLEET_ORCH_EFFORT && ! active FLEET_STEWARD_EFFORT \
  && ok "C the built-in-equal lines go anyway" || bad "C kept an equal line"
case "$out" in *'left in'*'still win here'*) ok "C says they were left" ;; *) bad "C output: $out" ;; esac
rm -f "$S/hub/down"; migrate >/dev/null
[ "$(nver)" = 1 ] && ! active FLEET_ORCH_MODEL && ! active FLEET_MODEL \
  && ok "C the hub back: the next run moves them" || bad "C not moved later ($(nver))"

# D ---------------------------------------------------------------------------
setup d; conf sonnet
printf '{"versions": [{"version": 4, "prev": 3, "note": "", "bundle": {"roles": {"steward": {"front": {"model": "haiku"}, "body": ""}}}}]}\n' > "$S/hub/p.json"
out=$(migrate)
[ "$(hubget steward.model)" = haiku ] && ! active FLEET_STEWARD_MODEL \
  && ok "D the person's own value stands, line commented" || bad "D steward: $(hubget steward.model) — $out"
case "$out" in *'steward.model — 入口上已有你的设定'*) ok "D says so" ;; *) bad "D output: $out" ;; esac

# E ---------------------------------------------------------------------------
setup e; conf
row=$(run $PY "$R" doctor)
case "$row" in WARN*'本机还有角色变量：FLEET_MODEL FLEET_ORCH_EFFORT FLEET_ORCH_MODEL'*) ok "E doctor WARNs on a left knob" ;; *) bad "E row: $row" ;; esac
migrate >/dev/null
row=$(run $PY "$R" doctor)
case "$row" in *'本机还有角色变量'*) bad "E still WARNs after: $row" ;; *) ok "E no WARN once moved" ;; esac

# F ---------------------------------------------------------------------------
[ "$(run $PY "$R" get worker model)" = sonnet ] && ok "F get reads the merged definition" || bad "F get: $(run $PY "$R" get worker model)"
kv=$(run bash -c ". '$S/conf/fleet.conf'; . '$BIN/fleet-lib.sh' >/dev/null 2>&1; fleet_role_render orchestrator claude")
printf '%s\n' "$kv" | grep -qx 'model	opus' && ok "F render after the move: the layer's opus" || bad "F render: $kv"

# G ---------------------------------------------------------------------------
setup g
printf 'FLEET_MODEL="${X:-sonnet}"\nFLEET_ORCH_MODEL=haiku\n' > "$S/conf/fleet.conf"
cp "$S/conf/fleet.conf" "$WORK/g.before"
out=$(run $PY "$R" migrate-conf "$S/conf/fleet.conf" --dry-run)
cmp -s "$WORK/g.before" "$S/conf/fleet.conf" && [ "$(nver)" = 0 ] \
  && ok "G --dry-run writes nothing" || bad "G dry-run wrote"
case "$out" in *'would move into your layer'*'haiku'*) ok "G --dry-run says what it would do" ;; *) bad "G dry output: $out" ;; esac
out=$(run $PY "$R" migrate-conf "$S/conf/fleet.conf")
grep -q '^FLEET_MODEL="${X:-sonnet}"$' "$S/conf/fleet.conf" && ! active FLEET_ORCH_MODEL \
  && ok "G a non-literal value is left, the rest moves" || bad "G: $(cat "$S/conf/fleet.conf")"
case "$out" in *'not a plain value'*) ok "G says so" ;; *) bad "G output: $out" ;; esac

[ "$fails" = 0 ] && { echo "fleet-role-migrate-selftest: all passed"; exit 0; }
echo "fleet-role-migrate-selftest: $fails failed"; exit 1
