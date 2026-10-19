#!/bin/bash
# fleet-id-hub-selftest.sh — the node half of the hub's ID mirror (EPIC T497 C2;
# the design page's §4.6 S10 / S12 / S13). `fleet-id.sh push` (bin/fleet_id.py
# push) is run against a stand-in hub — FLEET_ID_HUB_POST, a script that keeps
# its state in one file and answers as POST/GET /v1/node/ids does (the hub's own
# half is pinned in Go: tokenledger/hub/store/fleet_ids_test.go,
# hub/api/fleet_node_ids_test.go):
#   S10  three windows opened, reported and closed while the hub is down: each
#        push says 75 and sends nothing for good; the hub back, one push hands
#        over every event once, in (ID, seq) order — the hub holds exactly the
#        ledgers; the next push sends nothing; a hub rebuilt empty gets every
#        ledger again (the mirror is a replay)
#   S12  two machines' IDs share a 5-character code: the later's ledger takes the
#        hub's longer code (a `short` event), its window's @task_short follows,
#        and with the hub's list (.known) a 5-character code is refused naming both
#   S13  a cloned machine pushes an ID the first already holds: refused for good
#        (.hub/<ID>.refused, @id_hub_error on the window, one alert), never pushed
#        again; a new window on the clone is unaffected
#   WIRE the cleanup tick pushes; the spawn's open, result and close push
# tmux / python3 absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { echo 'fleet-id-hub selftest: tmux absent — SKIP'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'fleet-id-hub selftest: python3 absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-id-hub.XXXXXX")" || exit 2
L="fidhub$$"
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1 FLEET_ID_PUSH=0 FLEET_ID_ALERT=1
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_ID_HOOK

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { FLEET_ALLOW_TMUX_DESTROY=1 "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
tf -f /dev/null new-session -d -s "$L" -n home 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'fleet-id-hub selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }

# --- the stand-in hub: args METHOD PATH, body on stdin, `<code>\n<json>` out --------
HUB="$WORK/hub.json"; POSTS="$WORK/posts.log"
cat > "$WORK/hub.py" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["FIDBIN"])
import fleet_id
state_f, posts = os.environ["FAKE_HUB"], os.environ["FAKE_POSTS"]
if os.path.exists(state_f + ".down"):
    print("0"); sys.exit(0)
try:
    st = json.load(open(state_f))
except (OSError, ValueError):
    st = {"ids": {}}
method, path = sys.argv[1], sys.argv[2]
ep = os.environ.get("FAKE_EP", "e1")
def out(code, obj):
    print(code); print(json.dumps(obj)); json.dump(st, open(state_f, "w"))
if method == "GET":
    out(200, {"ids": [{"id": k, "short": v["short"]} for k, v in sorted(st["ids"].items())]}); sys.exit(0)
body = json.loads(sys.stdin.read())
fid, evs = body["id"], body["events"]
open(posts, "a").write("%s %s %s\n" % (ep, fid, ",".join(str(e["seq"]) for e in evs)))
r = st["ids"].get(fid)
if r and r["ep"] != ep:
    out(409, {"code": "DUPLICATE_ID", "error": "taken"}); sys.exit(0)
if not r:
    code = fleet_id.encode(fid); n = 5
    while n < 26 and any(fleet_id.encode(o)[:n] == code[:n] for o in st["ids"]):
        n += 1
    r = st["ids"][fid] = {"ep": ep, "short": "T-" + code[:n], "events": []}
for e in sorted(evs, key=lambda e: e["seq"]):
    if e["seq"] <= len(r["events"]):
        continue
    if e["seq"] != len(r["events"]) + 1:
        break
    r["events"].append(e)
out(200, {"id": fid, "seq": len(r["events"]), "short": r["short"]})
PY
export FIDBIN="$BIN" FAKE_HUB="$HUB" FAKE_POSTS="$POSTS"
export FLEET_ID_HUB_POST="python3 $WORK/hub.py"

machine() { export FLEET_CONF_DIR="$WORK/$1"; export FAKE_EP=$1; mkdir -p "$FLEET_CONF_DIR"; }
fid() { bash "$BIN/fleet-id.sh" "$@"; }
# hub_has <ID> → the hub's events of it, one JSON per line (seq order)
hub_has() { python3 -c 'import json,sys; [print(json.dumps(e, sort_keys=True)) for e in json.load(open(sys.argv[1]))["ids"].get(sys.argv[2], {}).get("events", [])]' "$HUB" "$1"; }
mine() { python3 -c 'import json,sys; [print(json.dumps(json.loads(l), sort_keys=True)) for l in open(sys.argv[1]) if l.strip()]' "$FLEET_CONF_DIR/ids/$1.ndjson"; }
nposts() { [ -f "$POSTS" ] && wc -l < "$POSTS" | tr -d ' ' || echo 0; }

# ---- S10 · three windows while the hub is away -----------------------------------
machine m1
I1=11111111-1111-4111-8111-111111111111 I2=22222222-2222-4222-8222-222222222222 I3=33333333-3333-4333-8333-333333333333
: > "$HUB.down"
for i in "$I1" "$I2" "$I3"; do
  fid open "$i" --agent claude --title "offline $i" >/dev/null
  fid native "$i" --agent claude --native "n-$i" --source startup >/dev/null
  fid result "$i" --state succeeded --summary 'did it' --pr 7 --issues acme/app#3
  fid close "$i" --reason reaped
done
fid push; rc=$?
ok; [ "$rc" = 75 ] || fail "S10: a push with the hub down answers 75" "rc=$rc"
ok; [ ! -s "$HUB" ] || fail "S10: the hub down stored something" "$(cat "$HUB")"
rm -f "$HUB.down"
fid push; rc=$?
ok; [ "$rc" = 0 ] || fail "S10: the push once the hub is back" "rc=$rc"
for i in "$I1" "$I2" "$I3"; do
  ok; [ "$(hub_has "$i")" = "$(mine "$i")" ] || fail "S10: the hub's $i is not the ledger, event for event" "$(hub_has "$i" | head -3)"
done
before=$(nposts)
fid push >/dev/null
ok; [ "$(nposts)" = "$before" ] || fail "S10: a second push sent again" "$(tail -n 3 "$POSTS")"
# a hub rebuilt empty: the cursor is ahead of it, the node replays from its answer
printf '{"ids":{}}' > "$HUB"
fid result "$I2" --state failed --summary later
fid push >/dev/null
ok; [ "$(hub_has "$I2")" = "$(mine "$I2")" ] || fail "S10: a rebuilt hub did not get the whole ledger of I2" "$(hub_has "$I2" | wc -l)"
ok; [ "$(mine "$I2" | wc -l | tr -d ' ')" = 5 ] || fail "S10: the ledger of I2 should hold 5 events" "$(mine "$I2" | wc -l)"

# ---- S12 · two machines, one 5-character code ------------------------------------
rm -f "$HUB" "$POSTS"
A=3fa85f64-5717-4562-b3fc-2c963f66afa6 B=3fa85f74-5717-4562-b3fc-2c963f66afa6   # 7ym5ys… / 7ym5yx…
machine m1; fid open "$A" --agent claude >/dev/null; fid push >/dev/null
machine m2
WB=$(tf new-window -d -P -F '#{window_id}' -t "$L:" 'while :; do sleep 300; done')
tf set-window-option -t "$WB" @fleet_id "$B"
sb=$(fid open "$B" --agent claude --window "$WB" --socket "$L")
ok; [ "$sb" = T-7ym5y ] || fail "S12: offline, m2 sees no collision" "$sb"
FLEET_ID_WINDOWS="$B	$L	$WB" python3 "$BIN/fleet_id.py" push "$B"
ok; [ "$(fid short "$B")" = T-7ym5yx ] || fail "S12: the later ID takes the hub's 6-character code" "$(fid short "$B")"
ok; [ "$(tf show-options -wqv -t "$WB" @task_short)" = T-7ym5yx ] || fail "S12: @task_short follows the hub" "$(tf show-options -wqv -t "$WB" @task_short)"
ok; grep -q '"ev":"short"' "$FLEET_CONF_DIR/ids/$B.ndjson" || fail "S12: the hub's code is not written down in the ledger"
fid push >/dev/null   # the `short` event goes up too; and the hub's list comes down
ok; [ "$(hub_has "$B")" = "$(mine "$B")" ] || fail "S12: the hub's B is not the ledger"
ok; grep -qx "$A" "$FLEET_CONF_DIR/ids/.known" || fail "S12: the hub's list did not reach .known" "$(cat "$FLEET_CONF_DIR/ids/.known" 2>/dev/null)"
err=$(fid resolve T-7ym5y 2>&1 >/dev/null); rc=$?
ok; { [ "$rc" = 2 ] && printf '%s' "$err" | grep -q "$A" && printf '%s' "$err" | grep -q "$B"; } \
  || fail "S12: a 5-character code naming both IDs is refused with both" "rc=$rc $err"

# ---- S13 · a cloned machine -----------------------------------------------------
machine m3
mkdir -p "$FLEET_CONF_DIR/ids"; cp "$WORK/m1/ids/$A.ndjson" "$FLEET_CONF_DIR/ids/"
WA=$(tf new-window -d -P -F '#{window_id}' -t "$L:" 'while :; do sleep 300; done')
FLEET_ALERTS_EVENTS="$WORK/alerts.events" FLEET_ID_WINDOWS="$A	$L	$WA" python3 "$BIN/fleet_id.py" push "$A"
ok; [ -s "$FLEET_CONF_DIR/ids/.hub/$A.refused" ] || fail "S13: the clone's push is not kept as refused"
ok; tf show-options -wqv -t "$WA" @id_hub_error | grep -q '另一台机器' || fail "S13: the window is not told" "$(tf show-options -wqv -t "$WA" @id_hub_error)"
before=$(nposts)
fid native "$A" --agent claude --native later --source clear >/dev/null
fid push "$A" >/dev/null
ok; [ "$(nposts)" = "$before" ] || fail "S13: a refused ID was pushed again"
C=44444444-4444-4444-8444-444444444444
fid open "$C" --agent claude >/dev/null; fid push "$C"; rc=$?
ok; { [ "$rc" = 0 ] && [ "$(hub_has "$C")" = "$(mine "$C")" ]; } || fail "S13: a new window on the clone is affected" "rc=$rc"
ok; [ "$(hub_has "$A" | wc -l | tr -d ' ')" = 1 ] || fail "S13: the first machine's record changed"

# ---- no hub here: nothing sent, exit 3 ------------------------------------------
( unset FLEET_ID_HUB_POST; FLEET_CONF_DIR="$WORK/nohub"; export FLEET_CONF_DIR; mkdir -p "$FLEET_CONF_DIR"; bash "$BIN/fleet-id.sh" push ); rc=$?
ok; [ "$rc" = 3 ] || fail "no node token: push exits 3" "rc=$rc"

# ---- WIRE ------------------------------------------------------------------------
ok; grep -q 'fleet-id.sh" push' "$BIN/fleet-cleanup-daemon.sh" || fail "WIRE: the cleanup tick does not push"
ok; grep -q 'fleet-id.sh" push "$1"' "$BIN/fleet-id.sh" || fail "WIRE: the spawn's open does not push"
ok; [ "$(grep -c 'push_later(' "$BIN/fleet_id.py")" -ge 4 ] || fail "WIRE: the hook / result / close do not push"

if [ "$FAIL" -gt 0 ]; then echo "fleet-id-hub selftest: $FAIL of $CHECKS checks FAILED"; exit 1; fi
echo "fleet-id-hub selftest: all $CHECKS checks passed"
