#!/bin/bash
# fleet-id-migrate-selftest.sh — the node half of the ID migration and the switch
# (EPIC T497 C6; the design page's §5 / §5.1). The hub's half — the §5 rule row
# by row, the counter-example (a silent machine moves none of its records), apply
# once and audited, the switch refusing the execution authority and flipping back —
# is pinned in Go (tokenledger/hub/store/fleet_id_migrate_test.go,
# hub/api/fleet_id_migrate_test.go). Here, against a stand-in hub
# (FLEET_ID_HUB_POST) on an isolated tmux server and a sandbox conf dir:
#   PRES     fleet_control.py's `id_presence` read lists each fleet's windows by
#            their @fleet_id (the one question the hub asks a machine)
#   MIGRATE  `fleet-id.sh migrate` prints each record's 今天 → 迁移后 and 依据,
#            the totals; --only / --apply reach the hub; --json is the hub's
#            answer; no hub ⇒ 3, a silent hub ⇒ 75 — nothing moved either way
#   SWITCH   `fleet-id.sh switch` writes the hub's word to ids/.switch; on/off
#            post it; no hub ⇒ the last word heard, rc 3
#   LAUNCH   switch on: an accepted dispatch opens unclaimed (fleet_launch.py
#            local → nothing, admit passes with no binding); off: admit still
#            demands the binding
#   GATE     a window with @launch: switch on ⇒ fleet_task_control.py answers 5 and
#            the report is a result on the window's ID (--outcome becomes its
#            state); switch off ⇒ the old road, nothing written on the ID; a window
#            with @task and no @launch takes --outcome only with the switch on —
#            twice round, the window keeps reporting
#   WIRE     the cleanup tick asks the switch; fleet-task-record.sh writes the
#            hub's ID_SWITCH refusal down; the hub's read list carries id_presence
# tmux / python3 absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { echo 'fleet-id-migrate selftest: tmux absent — SKIP'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'fleet-id-migrate selftest: python3 absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-idmig.XXXXXX")" || exit 2
L="fidmig$$"
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1 FLEET_ID_PUSH=0 FLEET_ORPHAN_ALERT_CMD=/usr/bin/true
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/ids"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_ID_HOOK FLEET_ID_SWITCH FLEET_LAUNCH

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
tf() { FLEET_ALLOW_TMUX_DESTROY=1 "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { FLEET_ALLOW_TMUX_DESTROY=1 "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
tf -f /dev/null new-session -d -s "$L" -n home 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'fleet-id-migrate selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
SOCKP=$(tf display-message -p '#{socket_path}')
SPID=$(tf display-message -p '#{pid}')
INT="TMUX=$SOCKP,$SPID,0"

# ---- the stand-in hub: args METHOD PATH, body on stdin, `<code>\n<json>` out -------
# It answers the migration with the §5 sample table as the hub's Go rule settles it
# (hub/store/fleet_id_migrate_test.go pins that rule; this pins what a node prints).
cat > "$WORK/hub.py" <<'PY'
import json, os, sys
w = os.environ["FAKE_WORK"]
if os.path.exists(w + "/down"):
    print("0"); sys.exit(0)
method, path = sys.argv[1], sys.argv[2]
body = sys.stdin.read()
open(w + "/calls.log", "a").write("%s %s %s\n" % (method, path, body.strip()))
sw = w + "/switch"
if path == "/v1/node/ids/switch":
    if method == "POST":
        on = json.loads(body)["on"]
        if os.path.exists(w + "/person"):
            print(403); print(json.dumps({"error": "the ID switch is the operator's"})); sys.exit(0)
        open(sw, "w").write("on" if on else "off")
    print(200); print(json.dumps({"on": open(sw).read() == "on" if os.path.exists(sw) else False})); sys.exit(0)
if path == "/v1/node/ids/migrate":
    req = json.loads(body)
    fid = "2a3d60d7-b6e1-4736-a744-46232728cd3c"
    items = []
    for t in ("T351", "T354", "T355", "T364"):
        items.append(dict(task=t, before="v1 · state starting · codex · cancel_request · execution_owner 挂着",
                          verdict="cancelled", label="已取消、已关闭", evidence="节点回答没有窗口带它：mac-a/alice · fleet fleet tmux 正常 · 17 个窗口"))
    for t, a in (("T478", "claude"), ("T489", "codex")):
        items.append(dict(task=t, before="v1 · state succeeded · outcome succeeded · %s · execution_owner 挂着" % a,
                          verdict="succeeded", label="已完成、已关闭", evidence="记录本身：已终态（succeeded）"))
    items.append(dict(task="T480", before="v1 · state cancelled · outcome cancelled · claude", verdict="cancelled",
                      label="已取消、已关闭", evidence="记录本身：已终态（cancelled），没有 worker"))
    items.append(dict(task="T488", before="v1 · state running · claude · execution_owner 挂着", verdict="live", label="活着",
                      id=fid, short="T-5d8p1", evidence="节点回答：窗口在（fleet:@12）"))
    items.append(dict(task="T900", before="v0 · state open · worker x", verdict="wait", label="等节点回答（不迁）",
                      evidence="mac-c/bob 没有回答（TIMEOUT）"))
    only = req.get("only") or []
    if only:
        items = [i for i in items if i["task"] in only]
    for i in items:
        if req.get("apply") and i["verdict"] != "wait":
            i["applied"] = True
    counts = {}
    for i in items:
        counts[i["verdict"]] = counts.get(i["verdict"], 0) + 1
    print(200); print(json.dumps({"apply": bool(req.get("apply")), "switch": False, "counts": counts, "items": items}, ensure_ascii=False))
    sys.exit(0)
print(404); print(json.dumps({"error": "no such road"}))
PY
export FAKE_WORK="$WORK"
export FLEET_ID_HUB_POST="python3 $WORK/hub.py"

# ---- PRES · id_presence lists each fleet's windows by @fleet_id --------------------
ok; python3 - "$BIN" <<'PY' || fail "PRES: id_presence answers each fleet's windows with their identity"
import sys
sys.path.insert(0, sys.argv[1])
import fleet_control
class C(fleet_control.Control):
    def __init__(self): pass
    def inventory(self, cache=False):
        return [dict(fleet_id="f-up", name="up"), dict(fleet_id="f-down", name="down"), dict(fleet_id="f-bad", name="bad")]
    def workers(self, fleet, window="", cache=False):
        if fleet["name"] == "down":
            return {"state": "down", "workers": [], "observed_at": 1}
        if fleet["name"] == "bad":
            raise fleet_control.Fault("UNAVAILABLE", "Cannot read fleet windows: tmux: command not found")
        return {"state": "running", "observed_at": 1, "workers": [
            dict(key="issue-9", window_id="@3", identity="2a3d60d7-b6e1-4736-a744-46232728cd3c")]}
got = C().id_presence()
f = {x["name"]: x for x in got["fleets"]}
assert f["up"]["state"] == "running" and f["up"]["windows"][0]["identity"].startswith("2a3d60d7"), got
assert f["down"]["state"] == "down" and "windows" in f["down"], got
assert f["bad"]["state"] == "unknown" and "tmux" in f["bad"]["error"], got
PY
ok; grep -q '"id_presence": *true' "$BIN/../tokenledger/shared/control/control.go" \
  || fail "PRES: the hub's read list (control.ReadMethods) carries id_presence"

# ---- MIGRATE · the dry-run prints the §5 table -------------------------------------
out=$(bash "$BIN/fleet-id.sh" migrate 2>&1); rc=$?
ok; [ "$rc" = 0 ] || fail "MIGRATE: a dry-run exits 0" "$rc · $out"
ok; printf '%s\n' "$out" | head -1 | grep -q 'dry-run（只看，不改）' || fail "MIGRATE: the header says dry-run" "$out"
for t in T351 T354 T355 T364; do
  ok; printf '%s\n' "$out" | grep -q "^$t .*→ 已取消、已关闭$" || fail "MIGRATE: $t → 已取消、已关闭" "$out"
done
for t in T478 T489; do
  ok; printf '%s\n' "$out" | grep -q "^$t .*→ 已完成、已关闭$" || fail "MIGRATE: $t → 已完成、已关闭" "$out"
done
ok; printf '%s\n' "$out" | grep -q '^T488 .*→ 活着 → T-5d8p1（别名 T488）$' || fail "MIGRATE: T488 → 活着, its short code, alias T488" "$out"
ok; printf '%s\n' "$out" | grep -q '^T900 .*→ 等节点回答（不迁）$' || fail "MIGRATE: a silent machine's record waits" "$out"
ok; printf '%s\n' "$out" | grep -q '依据：节点回答没有窗口带它' || fail "MIGRATE: each line carries its evidence" "$out"
ok; printf '%s\n' "$out" | grep -q '✓' && fail "MIGRATE: a dry-run marks nothing applied" "$out"
ok; printf '%s\n' "$out" | tail -1 | grep -q '^合计：live 1 · succeeded 2 · cancelled 5 · wait 1$' || fail "MIGRATE: the totals" "$(printf '%s\n' "$out" | tail -1)"
ok; grep -q 'POST /v1/node/ids/migrate {"apply": false}' "$WORK/calls.log" || fail "MIGRATE: dry-run posts apply false" "$(cat "$WORK/calls.log")"
out=$(bash "$BIN/fleet-id.sh" migrate --apply --only T351,T488 2>&1)
ok; grep -q '"apply": true, "only": \["T351", "T488"\]' "$WORK/calls.log" || fail "MIGRATE: --apply --only reach the hub" "$(tail -1 "$WORK/calls.log")"
ok; [ "$(printf '%s\n' "$out" | grep -c '✓$')" = 2 ] || fail "MIGRATE: applied lines are marked" "$out"
ok; bash "$BIN/fleet-id.sh" migrate --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["items"]) == 9' \
  || fail "MIGRATE: --json is the hub's answer"
ok; bash "$BIN/fleet-id.sh" migrate --only 351 >/dev/null 2>&1; [ $? = 2 ] || fail "MIGRATE: --only takes T<n>"
touch "$WORK/down"
bash "$BIN/fleet-id.sh" migrate >/dev/null 2>&1; rc=$?
ok; [ "$rc" = 75 ] || fail "MIGRATE: a silent hub ⇒ 75" "$rc"
rm -f "$WORK/down"
rc=$(FLEET_ID_HUB_POST="sh -c 'exit 3'" bash "$BIN/fleet-id.sh" migrate >/dev/null 2>&1; echo $?)
ok; [ "$rc" = 3 ] || fail "MIGRATE: no hub ⇒ 3" "$rc"

# ---- SWITCH · the hub's word, written down -----------------------------------------
sw() { cat "$FLEET_CONF_DIR/ids/.switch" 2>/dev/null | cut -d' ' -f1; }
ok; [ "$(bash "$BIN/fleet-id.sh" switch)" = off ] && [ "$(sw)" = off ] || fail "SWITCH: status off, written down" "$(sw)"
for round in 1 2; do
  ok; [ "$(bash "$BIN/fleet-id.sh" switch on)" = on ] && [ "$(sw)" = on ] || fail "SWITCH: on (round $round)" "$(sw)"
  ok; [ "$(bash "$BIN/fleet-id.sh" switch off)" = off ] && [ "$(sw)" = off ] || fail "SWITCH: off (round $round)" "$(sw)"
done
bash "$BIN/fleet-id.sh" switch on >/dev/null
out=$(FLEET_ID_HUB_POST="sh -c 'exit 3'" bash "$BIN/fleet-id.sh" switch 2>&1); rc=$?
ok; [ "$rc" = 3 ] && printf '%s' "$out" | grep -q '^on (no hub here' || fail "SWITCH: no hub ⇒ the last word, rc 3" "$rc · $out"
touch "$WORK/person"
bash "$BIN/fleet-id.sh" switch off >/dev/null 2>&1; rc=$?
ok; [ "$rc" = 1 ] && [ "$(sw)" = on ] || fail "SWITCH: a refused set changes nothing here" "$rc · $(sw)"
rm -f "$WORK/person"
bash "$BIN/fleet-id.sh" switch off >/dev/null

# ---- LAUNCH · on: no claim, no binding demanded ------------------------------------
disp='{"task":"T42","generation":1,"attempt_id":"a1","resolved_agent":"claude"}'
got=$(printf '%s' "$disp" | FLEET_ID_SWITCH=on python3 "$BIN/fleet_launch.py" local 11111111-1111-4111-8111-111111111111 2>&1); rc=$?
ok; [ "$rc" = 0 ] && [ -z "$got" ] || fail "LAUNCH: switch on ⇒ local opens unclaimed (no binding)" "$rc · $got"
printf '%s' "$disp" | FLEET_ID_SWITCH=on python3 "$BIN/fleet_launch.py" admit >/dev/null 2>&1; rc=$?
ok; [ "$rc" = 0 ] || fail "LAUNCH: switch on ⇒ admit needs no binding" "$rc"
printf '%s' "$disp" | FLEET_ID_SWITCH=off python3 "$BIN/fleet_launch.py" admit >/dev/null 2>&1; rc=$?
ok; [ "$rc" != 0 ] || fail "LAUNCH: switch off ⇒ admit still demands the binding"

# ---- GATE · the report's road follows the switch, twice round ----------------------
F=$(python3 -c 'import uuid; print(uuid.uuid4())')
W=$(tf new-window -d -P -F '#{window_id}' -t "$L:" 'while :; do sleep 300; done')
P=$(tf display-message -p -t "$W" '#{pane_id}')
tf set-window-option -t "$W" @fleet_id "$F"
tf set-window-option -t "$W" @task T42
tf set-window-option -t "$W" @launch '{"version":1}'
env "$INT" bash "$BIN/fleet-id.sh" open "$F" --window "$W" --socket "$L" --agent claude --title gate --task T42 >/dev/null
nres() { python3 "$BIN/fleet_id.py" get "$F" --json | python3 -c 'import json,sys; r=json.load(sys.stdin)["results"]; print(len(r), r[-1]["state"] if r else "-")'; }
rep() { env "$INT" TMUX_PANE="$P" bash "$BIN/fleet-report-parent.sh" "$@" 2>&1; }
n=0
for round in 1 2; do
  out=$(FLEET_ID_SWITCH=off rep --state waiting --outcome succeeded --summary "off $round"); rc=$?
  ok; [ "$rc" != 5 ] && [ "$(nres)" = "$n $( [ $n = 0 ] && echo - || echo succeeded)" ] \
    || fail "GATE: switch off ⇒ the old road (round $round), nothing on the ID" "$rc · $(nres) · $out"
  out=$(FLEET_ID_SWITCH=on rep --state waiting --outcome succeeded --summary "on $round"); rc=$?
  n=$((n + 1))
  ok; [ "$(nres)" = "$n succeeded" ] || fail "GATE: switch on ⇒ a result on the ID (round $round)" "$rc · $(nres) · $out"
done
out=$(FLEET_ID_SWITCH=on env "$INT" TMUX_PANE="$P" python3 "$BIN/fleet_task_control.py" report --pane "$P" --state waiting --summary x 2>&1); rc=$?
ok; [ "$rc" = 5 ] && printf '%s' "$out" | grep -q '^ID_SWITCH' || fail "GATE: fleet_task_control.py answers 5 with the switch on" "$rc · $out"
tf set-window-option -u -t "$W" @launch
out=$(FLEET_ID_SWITCH=off rep --state waiting --outcome succeeded --summary nolaunch); rc=$?
ok; [ "$rc" = 2 ] || fail "GATE: no @launch, switch off ⇒ --outcome refused as before" "$rc · $out"
out=$(FLEET_ID_SWITCH=on rep --state waiting --outcome failed --summary nolaunch); rc=$?
ok; [ "$(nres)" = "$((n + 1)) failed" ] || fail "GATE: no @launch, switch on ⇒ the outcome is the ID's result" "$rc · $(nres) · $out"

# ---- WIRE ----------------------------------------------------------------------------
ok; grep -q 'fleet-id.sh" switch' "$BIN/fleet-cleanup-daemon.sh" || fail "WIRE: the cleanup tick asks the switch"
# T604: asked on a login with no ids/ yet too — its guard is not the push's
awk '/^if / { guard = $0 } /fleet-id.sh" switch/ { print guard }' "$BIN/fleet-cleanup-daemon.sh" | grep -q 'FLEET_CONF_DIR/ids' \
  && fail "WIRE: the switch is asked only where ids/ exists — a login with no ID never hears it (T604)"
ok; grep -q 'ID_SWITCH' "$BIN/fleet-task-record.sh" || fail "WIRE: fleet-task-record.sh writes the hub's ID_SWITCH down"
ok; grep -q 'id_switch_on()' "$BIN/fleet_launch.py" || fail "WIRE: the launch reads the switch"

if [ "$FAIL" -gt 0 ]; then
  printf 'fleet-id-migrate selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2
  exit 1
fi
printf 'fleet-id-migrate selftest: PASS (%d checks)\n' "$CHECKS"
