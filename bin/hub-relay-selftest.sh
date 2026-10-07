#!/bin/bash
# hub-relay-selftest.sh — messages, child reports and waits across machines
# (issue #1421, EPIC #1419 C2). On an isolated tmux server and a sandbox conf dir,
# with the hub's worker map faked as the file the ccquota agent writes
# (control/hub-workers.tsv) and the agent's outbox read back as files, pins:
#   A  the degenerate case: with CCQUOTA_FLEET off a map on disk changes nothing —
#      fleet_hub_put refuses, fleet_remote_children is empty, fleet-children.sh
#      prints byte for byte what it did, fleet_window_waiting_children says no.
#   B  fleet-hub-node.sh paths names the outbox + the map the agent uses, and the
#      move-in dir a session moved here through the hub lands in (#1426).
#   C  fleet-hub-node.sh deliver: a remote child's report lands in the PARENT's
#      ledger here with node + rid, exactly once however often it is pushed; a
#      silent one too; a target fleet not on this machine and a bad id/kind/JSON
#      are refused (exit 1); a message to a worker not live here is «not now»
#      (75 — the hub holds it for the recipient, issue #1647).
#   D  fleet-report-parent.sh with a parent on another machine drops ONE relay in
#      the outbox (id `<child wid>#…`, from/to worker_ids, the envelope) and
#      writes nothing to this machine's same-key ledger; @reported is stamped. No
#      agent took it, so it says `queued →`, exit 3 — never `reported` (#1647).
#   E  fleet-peer-send.sh to a remote wid drops a message relay from the pane's
#      worker_id (`queued →`, exit 3, until a receipt says delivered); with no pane
#      it goes as the operator, `<fleet UUID>/operator@<login>` (issue #1649).
#   J  a STALE map (issue #1647): report-parent and peer-send still hand a full
#      worker_id to the hub — queued, exit 3, a QUEUED row in the delivery book.
#   K  a receipt (kind `receipt`): the sender's delivery book gets DELIVERED /
#      EXPIRED, or QUEUED when the target's machine holds it; `fleet-peer-queue.sh
#      wait` reads it; a receipt for a fleet not here is refused.
#   L  a report whose parent is not live here: «not now» (75), ledgered once; the
#      push after it is back is delivered (here: queued for its identity), and a
#      third push is a no-op. An identity-form target not live here is 75 too.
#   F  fleet_window_waiting_children holds a parent whose child runs elsewhere
#      (0/1) until its report says MERGED; a lost node or a stale map holds nothing.
#   G  fleet-await.sh on a remote child of ours finishes on the report the hub
#      pushes (via deliver, end to end); another parent's child is NO-WORKER; a
#      child gone from the map is GONE.
#   H  fleet_control.py's inventory carries @origin_wid (fleet-control-read.sh's
#      last column, #1423) — the parent link the hub map is built from.
#   I  fleet-children.sh lists a remote child with its machine.
# tmux / python3 absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { echo 'hub-relay selftest: tmux absent — SKIP'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'hub-relay selftest: python3 absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hub-relay.XXXXXX")" || exit 2
L="hrel$$"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$FLEET_CONF_DIR/fleets/$L/conf"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_HUB_STATUS_CMD FLEET_HUB_CACHE_SECS FLEET_HUB_RETAIN_SECS FLEET_CHILD_REPORT

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
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
F=11111111-2222-3333-4444-555555555555          # a fleet on another machine ("m4")
CACHE="$FLEET_CONF_DIR/control/hub-workers.tsv"
OUTBOX="$FLEET_CONF_DIR/control/hub-outbox"
LEDGER="$(bash -c '. "$1/fleet-lib.sh"; . "$1/fleet-children-lib.sh"; children_dir "$2"' _ "$BIN" "$L")/acme-app:issue-7.ndjson"   # keys carry the repo (#1939)
mkdir -p "${CACHE%/*}"
nlines() { [ -f "$1" ] && grep -c . "$1" || echo 0; }

# --- A: degenerate --------------------------------------------------------------------
run bash "$BIN/fleet-children.sh" -L "$L" issue-7; base="$rc|$out"
printf '%s/issue-42\tm4\t%s/issue-7\n' "$F" "$U" > "$CACHE"
run bash "$BIN/fleet-children.sh" -L "$L" issue-7
ok; [ "$rc|$out" = "$base" ] || fail "A: CCQUOTA_FLEET off ⇒ fleet-children.sh unchanged by a map on disk" "[$out] vs [$base]"
ok; ! lib fleet_hub_put child_report "$U/issue-1" "$F/issue-7" 1 '{}' >/dev/null && [ ! -d "$OUTBOX" ] \
  || fail "A: CCQUOTA_FLEET off ⇒ fleet_hub_put refuses and makes no outbox"
ok; [ -z "$(lib fleet_remote_children "$L" issue-7)" ] || fail "A: CCQUOTA_FLEET off ⇒ no remote children"
ok; ! lib fleet_window_waiting_children "$L" "$wp" >/dev/null || fail "A: CCQUOTA_FLEET off ⇒ a remote child holds nothing"

# --- B: paths ---------------------------------------------------------------------------
run bash "$BIN/fleet-hub-node.sh" paths
ok; [ "$out" = "outbox	$OUTBOX"$'\n'"workers	$CACHE"$'\n'"movein	$FLEET_CONF_DIR/control/move-in" ] || fail "B: paths" "$out"

# --- C: deliver -------------------------------------------------------------------------
relay() { # <id-suffix> <kind> <from> <to> <payload> [<from_node>]
  python3 -c 'import json,sys; s,k,f,t,p,n=sys.argv[1:7]; print(json.dumps(dict(id=f+"#"+s, kind=k, **{"from": f}, to=t, payload=json.loads(p), from_node=n)))' "$@" "${6-m4}"
}
deliver() { out=$(printf '%s' "$1" | env -u TMUX bash "$BIN/fleet-hub-node.sh" deliver 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err"); }
R1=$(relay 1700000000.1 child_report "$F/issue-42" "$U/issue-7" '{"child":"issue-42","state":"BLOCKED","pr":"","summary":"stuck","title":"kid","tier":"loud","msg":"[child-report] issue #42\nstate: BLOCKED"}')
deliver "$R1"
ok; [ "$rc" = 0 ] && [ "$(nlines "$LEDGER")" = 1 ] || fail "C: a remote report lands in the parent's ledger" "rc=$rc lines=$(nlines "$LEDGER") $err"
ok; python3 -c 'import json,sys; e=json.loads(open(sys.argv[1]).readline()); sys.exit(0 if e["child"]=="acme-app:issue-42" and e["node"]=="m4" and e["rid"]==sys.argv[2]+"#1700000000.1" and e["state"]=="BLOCKED" else 1)' "$LEDGER" "$F/issue-42" \
  || fail "C: the row carries node + rid" "$(cat "$LEDGER")"
deliver "$R1"
ok; [ "$rc" = 0 ] && [ "$(nlines "$LEDGER")" = 1 ] || fail "C: the same relay pushed again is ONE row" "rc=$rc lines=$(nlines "$LEDGER")"
deliver "$(relay 1700000000.2 child_report "$F/issue-42" "$U/issue-7" '{"child":"issue-42","state":"WAITING","tier":"silent","msg":"x"}')"
ok; [ "$rc" = 0 ] && [ "$(nlines "$LEDGER")" = 2 ] || fail "C: a silent report is ledgered" "rc=$rc lines=$(nlines "$LEDGER") $err"
deliver "$(relay 3 child_report "$F/issue-42" "$F/issue-7" '{"child":"issue-42","state":"MERGED"}')"
ok; [ "$rc" = 1 ] || fail "C: a parent fleet not on this machine is refused" "rc=$rc $err"
deliver "$(relay 4 shell "$F/issue-42" "$U/issue-7" '{}')"
ok; [ "$rc" = 1 ] || fail "C: an unknown kind is refused" "rc=$rc"
deliver '{"id":"x#1","kind":"child_report","from":"'"$F"'/issue-42","to":"'"$U"'/issue-7","payload":{}}'
ok; [ "$rc" = 1 ] || fail "C: an id not scoped to its sender is refused" "rc=$rc"
deliver 'not json'
ok; [ "$rc" = 1 ] || fail "C: non-JSON is refused" "rc=$rc"
deliver "$(relay 5 message "$F/issue-42" "$U/issue-8" '{"text":"hello"}')"
ok; [ "$rc" = 75 ] || fail "C: a message to a worker not live here is «not now» (75)" "rc=$rc $err"

# --- I: fleet-children.sh lists the remote child with its machine -----------------------
export CCQUOTA_FLEET=1
printf '%s/issue-42\tm4\t%s/issue-7\n' "$F" "$U" > "$CACHE"
run bash "$BIN/fleet-children.sh" -L "$L" issue-7
ok; case "$out" in *"issue-42"*"m4 remote"*) true ;; *) false ;; esac || fail "I: a live remote child shows its machine" "$out"
: > "$CACHE"
run bash "$BIN/fleet-children.sh" -L "$L" issue-7
ok; case "$out" in *"issue-42"*"gone · m4"*) true ;; *) false ;; esac || fail "I: a gone remote child keeps its machine from the ledger" "$out"
run bash "$BIN/fleet-children.sh" -L "$L" issue-7 --json
ok; printf '%s' "$out" | python3 -c 'import json,sys; c=json.load(sys.stdin)["children"]; sys.exit(0 if c and c[0].get("node")=="m4" else 1)' \
  || fail "I: --json carries node" "$out"

# --- F: a parent waiting on a child elsewhere --------------------------------------------
printf '%s/issue-42\tm4\t%s/issue-7\n' "$F" "$U" > "$CACHE"
out=$(lib fleet_window_waiting_children "$L" "$wp"); rc=$?
ok; [ "$rc" = 0 ] && [ "$out" = 0/1 ] || fail "F: a live remote child holds its parent (0/1)" "rc=$rc $out"
printf '%s/issue-42\tm4:lost\t%s/issue-7\n' "$F" "$U" > "$CACHE"
ok; ! lib fleet_window_waiting_children "$L" "$wp" >/dev/null || fail "F: a child on a lost node holds nothing"
printf '%s/issue-42\tm4\t%s/issue-7\n' "$F" "$U" > "$CACHE"; touch -t 202001010000 "$CACHE"
ok; ! lib fleet_window_waiting_children "$L" "$wp" >/dev/null || fail "F: a stale map holds nothing"
printf '%s/issue-42\tm4\t%s/issue-7\n' "$F" "$U" > "$CACHE"
deliver "$(relay 1700000000.6 child_report "$F/issue-42" "$U/issue-7" '{"child":"issue-42","state":"MERGED","pr":"9","tier":"quiet","msg":"m"}')"
ok; ! lib fleet_window_waiting_children "$L" "$wp" >/dev/null || fail "F: a MERGED report releases the parent"

# --- D: report-parent to a parent elsewhere ---------------------------------------------
wc=$(tf new-window -d -P -F '#{window_id}' -n issue-20 'while :; do sleep 300; done')
tf set-window-option -t "$wc" @issue 20; tf set-window-option -t "$wc" @origin issue-7
tf set-window-option -t "$wc" @origin_wid "$F/issue-7"
printf '%s/issue-7\tm4\t\n' "$F" > "$CACHE"
before=$(nlines "$LEDGER")
run bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wc" --state blocked --summary 'need a key'
f=$(ls "$OUTBOX"/*.json 2>/dev/null | head -1)
ok; [ "$rc" = 3 ] && [ -n "$f" ] && [ "$(ls "$OUTBOX"/*.json | wc -l | tr -d ' ')" = 1 ] \
  && case "$out" in *"queued → issue-7 on m4"*) true ;; *) false ;; esac \
  || fail "D: one relay in the outbox; no agent took it ⇒ queued, exit 3" "rc=$rc out=$out err=$err"
ok; python3 - "$f" "$U/acme-app:issue-20" "$F/issue-7" <<'PY' || fail "D: the relay's id/from/to/payload" "$(cat "$f" 2>/dev/null)"
import json, sys
r = json.load(open(sys.argv[1]))
p = r["payload"]
ok = (r["kind"] == "child_report" and r["from"] == sys.argv[2] and r["to"] == sys.argv[3]
      and r["id"].startswith(sys.argv[2] + "#") and p["child"] == "issue-20" and p["state"] == "BLOCKED"
      and p["tier"] == "loud" and "[child-report] issue #20" in p["msg"] and "need a key" in p["msg"])
sys.exit(0 if ok else 1)
PY
ok; [ "$(nlines "$LEDGER")" = "$before" ] || fail "D: nothing written to this machine's same-key ledger"
ok; [ "$(tf show-options -wqv -t "$wc" @reported)" = 1 ] || fail "D: @reported stamped"
rm -f "$OUTBOX"/*.json
unset CCQUOTA_FLEET
run bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wc" --state failed --summary 'x'
ok; [ "$rc" = 0 ] && [ -z "$(ls "$OUTBOX"/*.json 2>/dev/null)" ] && case "$err" in *"not sent"*) true ;; *) false ;; esac \
  || fail "D: hub off ⇒ C1's answer (not sent), no relay" "rc=$rc err=$err"
export CCQUOTA_FLEET=1

# --- E: peer-send to a worker elsewhere ---------------------------------------------------
sockpath=$(tf display-message -p '#{socket_path}')
pane=$(tf display-message -p -t "$wc" '#{pane_id}')
out=$(TMUX="$sockpath,1,0" TMUX_PANE="$pane" bash "$BIN/fleet-peer-send.sh" "wid:$F/issue-7" 'ping from m5' 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err")
f=$(ls "$OUTBOX"/*.json 2>/dev/null | head -1)
ok; [ "$rc" = 3 ] && [ -n "$f" ] && case "$out" in *"queued → issue-7 on m4"*) true ;; *) false ;; esac \
  && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r["kind"]=="message" and r["from"]==sys.argv[2] and r["to"]==sys.argv[3] and r["payload"]["text"]=="ping from m5" else 1)' "$f" "$U/acme-app:issue-20" "$F/issue-7" \
  || fail "E: a message relay from the pane's worker_id" "rc=$rc out=$out err=$err $(cat "$f" 2>/dev/null)"
rm -f "$OUTBOX"/*.json
run bash "$BIN/fleet-peer-send.sh" -L "$L" "wid:$F/issue-7" hi
f=$(ls "$OUTBOX"/*.json 2>/dev/null | head -1)
ok; [ "$rc" = 3 ] && [ -n "$f" ] && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r["from"]==sys.argv[2] else 1)' "$f" "$U/operator@$(id -un)" \
  || fail "E: no pane ⇒ sent as the operator (issue #1649), queued" "rc=$rc $err"
rm -f "$OUTBOX"/*.json

# --- J: a stale map still hands it to the hub (issue #1647) -----------------------------
BOOK="$FLEET_CONF_DIR/fleets/$L/delivery.ndjson"
printf '%s/issue-7\tm4\t\n' "$F" > "$CACHE"; touch -t 202001010000 "$CACHE"
run bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wc" --state blocked --summary 'stale map'
f=$(ls "$OUTBOX"/*.json 2>/dev/null | head -1)
ok; [ "$rc" = 3 ] && [ -n "$f" ] && case "$out" in "queued → issue-7（"*) true ;; *) false ;; esac \
  && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r["to"]==sys.argv[2] and r["kind"]=="child_report" else 1)' "$f" "$F/issue-7" \
  || fail "J: a stale map ⇒ the relay goes to the hub all the same, queued" "rc=$rc out=$out err=$err"
ok; grep -q '"state": "QUEUED"' "$BOOK" 2>/dev/null && grep -q '"via": "hub"' "$BOOK" \
  || fail "J: a QUEUED row in the delivery book" "$(cat "$BOOK" 2>/dev/null)"
rm -f "$OUTBOX"/*.json
out=$(TMUX="$sockpath,1,0" TMUX_PANE="$pane" bash "$BIN/fleet-peer-send.sh" "wid:$F/issue-7" 'ping, stale' 2>"$WORK/err"); rc=$?
ok; [ "$rc" = 3 ] && [ -n "$(ls "$OUTBOX"/*.json 2>/dev/null)" ] && case "$out" in "queued → issue-7"*) true ;; *) false ;; esac \
  || fail "J: peer-send through a stale map ⇒ queued at the hub" "rc=$rc out=$out $(cat "$WORK/err")"
rm -f "$OUTBOX"/*.json
unset CCQUOTA_FLEET
run bash "$BIN/fleet-peer-send.sh" -L "$L" "wid:$F/issue-7" hi
ok; [ "$rc" = 1 ] && [ -z "$(ls "$OUTBOX"/*.json 2>/dev/null)" ] || fail "J: hub off ⇒ a stale map is no route (refused, nothing queued)" "rc=$rc $err"
export CCQUOTA_FLEET=1
printf '%s/issue-7\tm4\t\n' "$F" > "$CACHE"

# --- K: receipts land in the sender's delivery book ---------------------------------------
rcpt() { # <rid-suffix> <status> [<detail>]
  python3 -c 'import json,sys; f,t,s,st,d=sys.argv[1:6]; rid=t+"#"+s
print(json.dumps(dict(id=rid, kind="receipt", **{"from": f}, to=t, from_node="", payload=dict(rid=rid, kind="child_report", to=f, status=st, detail=d))))' \
    "$F/issue-7" "$U/issue-20" "$1" "$2" "${3-}"
}
deliver "$(rcpt 1800000000.1 delivered 'reported')"
ok; [ "$rc" = 0 ] && grep -q "\"rid\": \"$U/issue-20#1800000000.1\", \"kind\": \"child_report\", \"to\": \"$F/issue-7\", \"state\": \"DELIVERED\"" "$BOOK" \
  || fail "K: a delivered receipt ⇒ DELIVERED in the sender's book" "rc=$rc $err $(tail -2 "$BOOK")"
bash "$BIN/fleet-peer-queue.sh" wait -L "$L" --rid "$U/issue-20#1800000000.1" --secs 0 >/dev/null; rc=$?
ok; [ "$rc" = 0 ] || fail "K: wait reads DELIVERED (0)" "rc=$rc"
deliver "$(rcpt 1800000000.2 expired 'no node took it within the relay TTL')"
bash "$BIN/fleet-peer-queue.sh" wait -L "$L" --rid "$U/issue-20#1800000000.2" --secs 0 >/dev/null; rc=$?
ok; [ "$rc" = 1 ] && grep -q '"state": "EXPIRED"' "$BOOK" || fail "K: an expired receipt ⇒ EXPIRED, wait 1" "rc=$rc"
deliver "$(rcpt 1800000000.3 delivered 'queued at m4: parent issue-7 cannot take it now')"
out=$(bash "$BIN/fleet-peer-queue.sh" wait -L "$L" --rid "$U/issue-20#1800000000.3" --secs 0); rc=$?
ok; [ "$rc" = 3 ] && [ "$out" = QUEUED ] || fail "K: held by the target's machine ⇒ QUEUED, never DELIVERED" "rc=$rc $out"
deliver "$(python3 -c 'import json,sys; t=sys.argv[2]+"/issue-20"; rid=t+"#1"; print(json.dumps(dict(id=rid, kind="receipt", **{"from": sys.argv[1]+"/issue-7"}, to=t, payload=dict(rid=rid, status="delivered"))))' "$F" "$F")"
ok; [ "$rc" = 1 ] || fail "K: a receipt for a fleet not on this machine is refused" "rc=$rc $err"

# --- L: a parent not live here is «not now», delivered once it is back --------------------
L8="$(dirname "$LEDGER")/acme-app:issue-8.ndjson"
R8=$(relay 1700000001.1 child_report "$F/issue-43" "$U/issue-8" '{"child":"issue-43","state":"MERGED","pr":"5","tier":"quiet","msg":"[child-report] issue #43\nstate: MERGED"}')
deliver "$R8"
ok; [ "$rc" = 75 ] && [ "$(nlines "$L8")" = 1 ] || fail "L: parent not live ⇒ 75, ledgered" "rc=$rc lines=$(nlines "$L8") $err"
q8() { grep -l "$F/issue-43#1700000001.1" "$FLEET_CONF_DIR/fleets/$L/peer-queue/"*.json 2>/dev/null | wc -l | tr -d ' '; }
w8=$(tf new-window -d -P -F '#{window_id}' -n issue-8 'while :; do sleep 300; done')
tf set-window-option -t "$w8" @issue 8
deliver "$R8"
ok; [ "$rc" = 0 ] && [ "$(nlines "$L8")" = 1 ] && case "$err" in *queued*) true ;; *) false ;; esac \
  && [ "$(q8)" = 1 ] \
  || fail "L: pushed again once the parent is back ⇒ handed over (its inbox is down: queued here), still one ledger row" "rc=$rc lines=$(nlines "$L8") $err"
deliver "$R8"
ok; [ "$rc" = 0 ] && [ "$(q8)" = 1 ] || fail "L: a third push is a no-op" "rc=$rc $err"
deliver "$(relay 1700000001.2 child_report "$F/issue-43" "$U/0e0e0e0e-1111-4222-8333-444444444444" '{"child":"issue-43","state":"MERGED","tier":"quiet","msg":"m"}')"
ok; [ "$rc" = 75 ] || fail "L: an identity-form parent not live here ⇒ 75" "rc=$rc $err"
deliver "$(relay 1700000001.3 message "$F/issue-43" "$U/0e0e0e0e-1111-4222-8333-444444444444" '{"text":"hi"}')"
ok; [ "$rc" = 75 ] || fail "L: a message to an identity not live here ⇒ 75" "rc=$rc $err"

# --- G: await a child elsewhere -----------------------------------------------------------
printf '%s/issue-55\tm4\t%s/issue-7\n%s/issue-56\tm4\t%s/issue-9\n' "$F" "$U" "$F" "$U" > "$CACHE"
( sleep 2
  printf '%s' "$(relay 1700000000.7 child_report "$F/issue-55" "$U/issue-7" '{"child":"issue-55","state":"MERGED","pr":"11","summary":"done","tier":"quiet","msg":"m"}')" \
    | env -u TMUX bash "$BIN/fleet-hub-node.sh" deliver >/dev/null 2>&1 ) &
run bash "$BIN/fleet-await.sh" "wid:$F/issue-55" -L "$L" --parent issue-7 --timeout 20 --interval 1
wait
ok; [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | head -1)" = MERGED ] && case "$out" in *"pr: #11"*) true ;; *) false ;; esac \
  || fail "G: await a remote child → MERGED off the pushed report" "rc=$rc out=$out err=$err"
run bash "$BIN/fleet-await.sh" "wid:$F/issue-56" -L "$L" --parent issue-7 --timeout 5 --interval 1
ok; [ "$rc" = 5 ] && case "$out" in *"reports to $U/issue-9"*) true ;; *) false ;; esac \
  || fail "G: another parent's child → NO-WORKER" "rc=$rc out=$out"
printf '%s/issue-57\tm4\t%s/issue-7\n' "$F" "$U" > "$CACHE"
( sleep 2; printf '%s/issue-1\tm4\t\n' "$F" > "$CACHE" ) &
run bash "$BIN/fleet-await.sh" "wid:$F/issue-57" -L "$L" --parent issue-7 --timeout 20 --interval 1
wait
ok; [ "$rc" = 4 ] && [ "$(printf '%s\n' "$out" | head -1)" = GONE ] || fail "G: a child gone from the map → GONE" "rc=$rc out=$out err=$err"

# --- H: the inventory carries @origin_wid -------------------------------------------------
inv=$(cd "$BIN" && python3 -c 'import json, sys, fleet_control as c
ctl = c.Control(sys.argv[1]); f = [x for x in ctl.inventory() if x["name"] == sys.argv[2]][0]
print(json.dumps({w["key"]: w.get("origin_wid") for w in ctl.workers(f)["workers"]}))' "$FLEET_CONF_DIR" "$L" 2>&1)
ok; printf '%s' "$inv" | python3 -c 'import json,sys; m=json.load(sys.stdin); sys.exit(0 if m.get("acme-app:issue-20")==sys.argv[1] and m.get("acme-app:issue-7") is None else 1)' "$F/issue-7" \
  || fail "H: origin_wid on the child, absent on a window without one" "$inv"

if [ "$FAIL" -eq 0 ]; then printf 'hub-relay selftest: PASS (%d checks)\n' "$CHECKS"; exit 0; fi
printf 'hub-relay selftest: %d FAILED of %d\n' "$FAIL" "$CHECKS" >&2; exit 1
