#!/bin/bash
# Cross-node report retirement and ordinary message transport, on an isolated socket.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-repo-fixture.sh"
REAL_TMUX=$(command -v tmux) || { echo 'hub-relay selftest: tmux absent — SKIP'; exit 0; }
st_need python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hub-relay.XXXXXX")" || exit 2
L="hrel$$"
export FLEET_SKIP_GLOBAL_CONF=1
# no agent takes the outbox here: every send is queued — after 0 s, not the 3 s wait
export FLEET_HUB_SENT_WAIT=0
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
: > "$FLEET_CONF_DIR/fleets/$L/conf"
fx_repo "$FLEET_CONF_DIR" "$L" acme/app FLEET_MAIN="$WORK/main"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_HUB_STATUS_CMD FLEET_HUB_CACHE_SECS FLEET_HUB_RETAIN_SECS FLEET_CHILD_REPORT

st_tally
ok() { CHECKS=$((CHECKS + 1)); }
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
lib() { bash -c '. "$1/fleet-lib.sh"; shift; "$@"' _ "$BIN" "$@"; }
run() { out=$(env -u TMUX "$@" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err"); }

tf -f /dev/null new-session -d -s "$L" -n plan 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'hub-relay selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
wp=$(tf new-window -d -P -F '#{window_id}' -n issue-7 'while :; do sleep 300; done')
tf set-window-option -t "$wp" @issue 7
# A control db (fleet_control mints the machine id) ⇒ this fleet has a UUID.
(cd "$BIN" && python3 -c 'import sys, fleet_control as c; c.Control(sys.argv[1]).inventory()' "$FLEET_CONF_DIR") >/dev/null 2>&1
U=$(lib fleet_uuid "$L")
[ -n "$U" ] || { echo 'hub-relay selftest: no fleet UUID could be minted' >&2; exit 1; }
F=11111111-2222-3333-4444-555555555555          # a fleet on another machine ("mac-a")
CACHE="$FLEET_CONF_DIR/control/hub-workers.tsv"
OUTBOX="$FLEET_CONF_DIR/control/hub-outbox"
LEDGER="$(bash -c '. "$1/fleet-lib.sh"; . "$1/fleet-children-lib.sh"; children_dir "$2"' _ "$BIN" "$L")/acme-app:issue-7.ndjson"   # keys carry the repo (#1939)
mkdir -p "${CACHE%/*}"
nlines() { [ -f "$1" ] && grep -c . "$1" || echo 0; }

# Paths retain the existing capabilities; additive entries do not break old nodes.
run bash "$BIN/fleet-hub-node.sh" paths
ok; printf '%s\n' "$out" | python3 -c 'import sys
rows=dict(line.split("\t",1) for line in sys.stdin.read().splitlines())
want={"outbox":sys.argv[1],"workers":sys.argv[2],"movein":sys.argv[3]+"/control/move-in","attach":sys.argv[3]+"/attachments","test":"1","task":"1","launch_v1":"1","repo_authority_v1":"1","repo_authority_sync":"1","execution_sync":"1","execution_exit_retry":"1"}
assert all(rows.get(k)==v for k,v in want.items()), rows' "$OUTBOX" "$CACHE" "$FLEET_CONF_DIR" || st_miss 'paths preserve capabilities' "$out"
relay() { # <id-suffix> <kind> <from> <to> <payload> [<from_node>]
  python3 -c 'import json,sys; s,k,f,t,p,n=sys.argv[1:7]; print(json.dumps(dict(id=f+"#"+s, kind=k, **{"from": f}, to=t, payload=json.loads(p), from_node=n)))' "$@" "${6-mac-a}"
}
deliver() { out=$(printf '%s' "$1" | env -u TMUX bash "$BIN/fleet-hub-node.sh" deliver 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err"); }
# Pre-existing historical result stays byte for byte, even during replays.
mkdir -p "${LEDGER%/*}"
printf '%s\n' '{"child":"acme-app:issue-42","state":"MERGED","pr":"7","node":"mac-a","rid":"historical"}' > "$LEDGER"
cp "$LEDGER" "$WORK/history"
export CCQUOTA_FLEET=1
for payload in \
  '{"child":"issue-42","state":"MERGED","tier":"loud","msg":"old report"}' \
  '{"child":"issue-42","state":"WAITING","tier":"silent"}' \
  '{"task_report":true,"state":"SUCCEEDED"}' \
  '{"report_delegation":{"target":"old-parent"}}'; do
  for target in "$U/issue-7" "$U/issue-8" "$U/0e0e0e0e-1111-4222-8333-444444444444" "$F/issue-7"; do
    for _replay in 1 2; do
      deliver "$(relay retired child_report "$F/issue-42" "$target" "$payload")"
      ok; [ "$rc" = 1 ] && case "$err" in *PARENT_REPORT_RETIRED*) true ;; *) false ;; esac \
        || st_miss 'report permanently refused, live/offline/foreign/identity/replay' "rc=$rc $err"
    done
  done
done
ok; cmp -s "$LEDGER" "$WORK/history" || st_miss 'historical ledger changed'
ok; [ ! -d "$OUTBOX" ] && [ ! -e "${LEDGER%/*}/.relay-sent" ] && [ ! -d "$FLEET_CONF_DIR/fleets/$L/peer-queue" ] \
  || st_miss 'retired report created delivery artifacts'
deliver 'not json'
ok; [ "$rc" = 1 ] || st_miss 'invalid JSON permanently refused' "$rc"
deliver "$(relay bad shell "$F/issue-42" "$U/issue-7" '{}')"
ok; [ "$rc" = 1 ] || st_miss 'unknown relay permanently refused' "$rc"
for target in "$U/issue-8" "$U/0e0e0e0e-1111-4222-8333-444444444444"; do
  deliver "$(relay ordinary message "$F/issue-42" "$target" '{"text":"hello"}')"
  ok; [ "$rc" = 75 ] || st_miss 'ordinary missing recipient remains retryable' "rc=$rc $err"
done

# Old hook and await entries remain callable but cannot orchestrate or report.
wc=$(tf new-window -d -P -F '#{window_id}' -n issue-20 'while :; do sleep 300; done')
tf set-window-option -t "$wc" @issue 20
tf set-window-option -t "$wc" @origin issue-7
tf set-window-option -t "$wc" @origin_wid "$F/issue-7"
printf '%s/issue-7\tmac-a\t\n' "$F" > "$CACHE"
run bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wc" --state blocked --summary 'old hook'
ok; [ "$rc" = 0 ] && [ ! -d "$OUTBOX" ] && cmp -s "$LEDGER" "$WORK/history" \
  || st_miss 'old hook is inert, history retained' "rc=$rc $out $err"
run bash "$BIN/fleet-await.sh" "wid:$F/issue-42" -L "$L" --parent issue-7 --timeout 20
ok; [ "$rc" = 2 ] && case "$out" in *RETIRED*) true ;; *) false ;; esac || st_miss 'old await returns retirement immediately' "rc=$rc $out"
# --- E: peer-send to a worker elsewhere ---------------------------------------------------
sockpath=$(tf display-message -p '#{socket_path}')
pane=$(tf display-message -p -t "$wc" '#{pane_id}')
out=$(TMUX="$sockpath,1,0" TMUX_PANE="$pane" bash "$BIN/fleet-peer-send.sh" "wid:$F/issue-7" 'ping from mac-b' 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err")
f=$(ls "$OUTBOX"/*.json 2>/dev/null | head -1)
ok; [ "$rc" = 3 ] && [ -n "$f" ] && case "$out" in *"queued → issue-7 on mac-a"*) true ;; *) false ;; esac \
  && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r["kind"]=="message" and r["from"]==sys.argv[2] and r["to"]==sys.argv[3] and r["payload"]["text"]=="ping from mac-b" else 1)' "$f" "$U/acme-app:issue-20" "$F/issue-7" \
  || st_miss "E: a message relay from the pane's worker_id" "rc=$rc out=$out err=$err $(cat "$f" 2>/dev/null)"
rm -f "$OUTBOX"/*.json
run bash "$BIN/fleet-peer-send.sh" -L "$L" "wid:$F/issue-7" hi
f=$(ls "$OUTBOX"/*.json 2>/dev/null | head -1)
ok; [ "$rc" = 3 ] && [ -n "$f" ] && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r["from"]==sys.argv[2] else 1)' "$f" "$U/operator@$(id -un)" \
  || st_miss "E: no pane ⇒ sent as the operator (issue #1649), queued" "rc=$rc $err"
rm -f "$OUTBOX"/*.json

BOOK="$FLEET_CONF_DIR/fleets/$L/delivery.ndjson"
touch -t 202001010000 "$CACHE"
out=$(TMUX="$sockpath,1,0" TMUX_PANE="$pane" bash "$BIN/fleet-peer-send.sh" "wid:$F/issue-7" 'ping, stale' 2>"$WORK/err"); rc=$?
ok; [ "$rc" = 3 ] && [ -n "$(ls "$OUTBOX"/*.json 2>/dev/null)" ] && case "$out" in "queued → issue-7"*) true ;; *) false ;; esac \
  || st_miss "J: peer-send through a stale map ⇒ queued at the hub" "rc=$rc out=$out $(cat "$WORK/err")"
rm -f "$OUTBOX"/*.json
unset CCQUOTA_FLEET
run bash "$BIN/fleet-peer-send.sh" -L "$L" "wid:$F/issue-7" hi
ok; [ "$rc" = 1 ] && [ -z "$(ls "$OUTBOX"/*.json 2>/dev/null)" ] || st_miss "J: hub off ⇒ a stale map is no route (refused, nothing queued)" "rc=$rc $err"
export CCQUOTA_FLEET=1
printf '%s/issue-7\tmac-a\t\n' "$F" > "$CACHE"

# --- K: receipts land in the sender's delivery book ---------------------------------------
rcpt() { # <rid-suffix> <status> [<detail>]
  python3 -c 'import json,sys; f,t,s,st,d=sys.argv[1:6]; rid=t+"#"+s
print(json.dumps(dict(id=rid, kind="receipt", **{"from": f}, to=t, from_node="", payload=dict(rid=rid, kind="message", to=f, status=st, detail=d))))' \
    "$F/issue-7" "$U/issue-20" "$1" "$2" "${3-}"
}
deliver "$(rcpt 1800000000.1 delivered 'reported')"
ok; [ "$rc" = 0 ] && grep -q "\"rid\": \"$U/issue-20#1800000000.1\", \"kind\": \"message\", \"to\": \"$F/issue-7\", \"state\": \"DELIVERED\"" "$BOOK" \
  || st_miss "K: a delivered receipt ⇒ DELIVERED in the sender's book" "rc=$rc $err $(tail -2 "$BOOK")"
bash "$BIN/fleet-peer-queue.sh" wait -L "$L" --rid "$U/issue-20#1800000000.1" --secs 0 >/dev/null; rc=$?
ok; [ "$rc" = 0 ] || st_miss "K: wait reads DELIVERED (0)" "rc=$rc"
deliver "$(rcpt 1800000000.2 expired 'no node took it within the relay TTL')"
bash "$BIN/fleet-peer-queue.sh" wait -L "$L" --rid "$U/issue-20#1800000000.2" --secs 0 >/dev/null; rc=$?
ok; [ "$rc" = 1 ] && grep -q '"state": "EXPIRED"' "$BOOK" || st_miss "K: an expired receipt ⇒ EXPIRED, wait 1" "rc=$rc"
deliver "$(rcpt 1800000000.3 delivered 'queued at mac-a: parent issue-7 cannot take it now')"
out=$(bash "$BIN/fleet-peer-queue.sh" wait -L "$L" --rid "$U/issue-20#1800000000.3" --secs 0); rc=$?
ok; [ "$rc" = 3 ] && [ "$out" = QUEUED ] || st_miss "K: held by the target's machine ⇒ QUEUED, never DELIVERED" "rc=$rc $out"
deliver "$(python3 -c 'import json,sys; t=sys.argv[2]+"/issue-20"; rid=t+"#1"; print(json.dumps(dict(id=rid, kind="receipt", **{"from": sys.argv[1]+"/issue-7"}, to=t, payload=dict(rid=rid, status="delivered"))))' "$F" "$F")"
ok; [ "$rc" = 1 ] || st_miss "K: a receipt for a fleet not on this machine is refused" "rc=$rc $err"

# An obsolete delivered report receipt must never create a success notice.
deliver "$(rcpt old-report delivered 'reported' | python3 -c 'import json,sys; r=json.load(sys.stdin); r["payload"]["kind"]="child_report"; print(json.dumps(r))')"
out=$(bash "$BIN/fleet-peer-queue.sh" wait -L "$L" --rid "$U/issue-20#old-report" --secs 0); rc=$?
ok; [ "$rc" = 1 ] && [ "$out" = FAILED ] || st_miss 'old report receipt cannot claim delivered' "rc=$rc $out"
ok; cmp -s "$LEDGER" "$WORK/history" || st_miss 'ordinary traffic mutated historical parent data'
# --- H: the inventory carries @origin_wid -------------------------------------------------
inv=$(cd "$BIN" && python3 -c 'import json, sys, fleet_control as c
ctl = c.Control(sys.argv[1]); f = [x for x in ctl.inventory() if x["name"] == sys.argv[2]][0]
print(json.dumps({w["key"]: w.get("origin_wid") for w in ctl.workers(f)["workers"]}))' "$FLEET_CONF_DIR" "$L" 2>&1)
ok; printf '%s' "$inv" | python3 -c 'import json,sys; m=json.load(sys.stdin); sys.exit(0 if m.get("acme-app:issue-20")==sys.argv[1] and m.get("acme-app:issue-7") is None else 1)' "$F/issue-7" \
  || st_miss "H: origin_wid on the child, absent on a window without one" "$inv"

st_done
