#!/bin/bash
# operator-send-selftest.sh — a message from anywhere, and an answer for a worker
# that has ended (issue #1649, EPIC #1645 C10). On an isolated tmux server and a
# sandbox conf dir, the hub's worker map faked as the file the ccquota agent
# writes (control/hub-workers.tsv) and its outbox read back as files, pins:
#   A  fleet-peer-send.sh with NO pane to a worker on another machine: the relay's
#      `from` is `<fleet UUID>/operator@<login>` (fleet_operator_sender) — queued,
#      exit 3, never refused. The hub off: refused as before, nothing queued.
#   B  a pane-less `issue:<N>` not live here but in the hub map goes through the
#      hub too, its payload naming the repo it meant.
#   C  a target that has ENDED: `<target> 已于 <时间> 结束：<结果>`, exit 2, from
#      fleet-history.sh ended; a target that never lived: exit 1, nothing on stdout.
#   D  fleet-hub-node.sh deliver: a message from an operator sender reaches the
#      worker with `[from operator@<login> on <node>]`; an operator child report
#      is refused; a receipt TO an operator sender lands in the sender's book.
#   E  the repo rail: a message naming another repo than the target window works
#      is refused for good (exit 1).
#   F  an issue comment whose worker lives on another machine: the bridge
#      forwards it through the hub ONCE (relay id `bridge-<cid>`, the hub's
#      idempotency key) and marks it seen — a redelivery is `dup`; on the
#      worker's machine `--apply-forward` (via deliver) hands it over once and a
#      second push of it is a dup.
# tmux / python3 absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { echo 'operator-send selftest: tmux absent — SKIP'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'operator-send selftest: python3 absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/operator-send.XXXXXX")" || exit 2
L="opsd$$"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
export FLEET_ISSUE_BRIDGE_STATE_DIR="$WORK/bridge" FLEET_DISPATCH_LEASE_DIR="$WORK/leases"
export FLEET_HISTORY_LEDGER="$WORK/landed.tsv"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$FLEET_CONF_DIR/fleets/$L/conf"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_HUB_STATUS_CMD FLEET_HUB_CACHE_SECS FLEET_HUB_RETAIN_SECS

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
lib() { bash -c '. "$1/fleet-lib.sh"; shift; "$@"' _ "$BIN" "$@"; }
run() { out=$(env -u TMUX -u TMUX_PANE "$@" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err"); }

tf -f /dev/null new-session -d -s "$L" -n plan 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'operator-send selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
w7=$(tf new-window -d -P -F '#{window_id}' -n issue-7 'while :; do sleep 300; done')
tf set-window-option -t "$w7" @issue 7
(cd "$BIN" && python3 -c 'import sys, fleet_control as c; c.Control(sys.argv[1]).inventory()' "$FLEET_CONF_DIR") >/dev/null 2>&1
U=$(lib fleet_uuid "$L")
[ -n "$U" ] || { echo 'operator-send selftest: no fleet UUID could be minted' >&2; exit 1; }
ME=$(id -un)
OP="$U/operator@$ME"
F=11111111-2222-3333-4444-555555555555          # a fleet on another machine ("m4")
CACHE="$FLEET_CONF_DIR/control/hub-workers.tsv"
OUTBOX="$FLEET_CONF_DIR/control/hub-outbox"
BOOK="$FLEET_CONF_DIR/fleets/$L/delivery.ndjson"
mkdir -p "${CACHE%/*}"
printf '%s/issue-42\tm4\t\n' "$F" > "$CACHE"
outbox() { ls "$OUTBOX"/*.json 2>/dev/null; }
jget() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); v=r
for k in sys.argv[2].split("."): v=v.get(k) if isinstance(v, dict) else None
print("" if v is None else v)' "$1" "$2"; }

# --- A: no pane ⇒ the operator sends ------------------------------------------------------
ok; [ "$(lib fleet_operator_sender "$L")" = "$OP" ] || fail "A: fleet_operator_sender" "$(lib fleet_operator_sender "$L")"
ok; lib fleet_is_operator_sender "$OP" && ! lib fleet_is_operator_sender "$F/issue-42" \
  || fail "A: fleet_is_operator_sender tells an operator from a worker"
run bash "$BIN/fleet-peer-send.sh" "wid:$F/issue-42" 'hello from a shell'
ok; [ "$rc" = 1 ] && [ -z "$(outbox)" ] || fail "A: hub off ⇒ refused, nothing queued (as before)" "rc=$rc $err"
export CCQUOTA_FLEET=1
run bash "$BIN/fleet-peer-send.sh" "wid:$F/issue-42" 'hello from a shell'
f=$(outbox | head -1)
ok; [ "$rc" = 3 ] && [ -n "$f" ] && case "$out" in "queued → issue-42 on m4"*) true ;; *) false ;; esac \
  || fail "A: no pane ⇒ queued at the hub, exit 3" "rc=$rc out=$out err=$err"
ok; [ -n "$f" ] && [ "$(jget "$f" from)" = "$OP" ] && [ "$(jget "$f" to)" = "$F/issue-42" ] \
  && case "$(jget "$f" id)" in "$OP#"*) true ;; *) false ;; esac && [ "$(jget "$f" payload.text)" = 'hello from a shell' ] \
  || fail "A: from = <fleet UUID>/operator@<login>, id scoped to it" "$(cat "$f" 2>/dev/null)"
rm -f "$OUTBOX"/*.json

# --- B: a pane-less issue:<N> that lives elsewhere ----------------------------------------
run bash "$BIN/fleet-peer-send.sh" issue:42 'ping by number'
f=$(outbox | head -1)
ok; [ "$rc" = 3 ] && [ -n "$f" ] && [ "$(jget "$f" to)" = "$F/issue-42" ] && [ "$(jget "$f" from)" = "$OP" ] \
  && [ "$(jget "$f" payload.repo)" = acme/app ] \
  || fail "B: issue:42 not live here, in the map ⇒ through the hub, naming acme/app" "rc=$rc out=$out err=$err $(cat "$f" 2>/dev/null)"
rm -f "$OUTBOX"/*.json

# --- C: a target that has ended -----------------------------------------------------------
printf '2026-10-05T02:30:00Z\t99\tFix the thing\t#55\tdef\t/w\t-\ts2\tadded the X\tlanded\t-\n' > "$FLEET_HISTORY_LEDGER"
run bash "$BIN/fleet-peer-send.sh" issue:99 'are you there?'
ok; [ "$rc" = 2 ] && [ -z "$(outbox)" ] && case "$out" in "issue:99 已于 2026-10-0"*" 结束：已合并 PR #55 — added the X") true ;; *) false ;; esac \
  || fail "C: an ended worker ⇒ when + how, exit 2, nothing sent" "rc=$rc out=$out err=$err"
run bash "$BIN/fleet-peer-send.sh" issue:98 'anyone?'
ok; [ "$rc" = 1 ] && [ -z "$out" ] && [ -z "$(outbox)" ] || fail "C: never lived ⇒ refused (1), nothing on stdout" "rc=$rc out=$out err=$err"
run bash "$BIN/fleet-peer-send.sh" "wid:$F/issue-99" 'are you there?'
ok; [ "$rc" = 3 ] || fail "C: a full worker_id elsewhere still goes to the hub (it may be live there)" "rc=$rc out=$out"
rm -f "$OUTBOX"/*.json

# --- D: deliver from an operator sender ----------------------------------------------------
relay() { # <id-suffix> <kind> <from> <to> <payload> [<from_node>]
  python3 -c 'import json,sys; s,k,f,t,p,n=sys.argv[1:7]; print(json.dumps(dict(id=f+"#"+s, kind=k, **{"from": f}, to=t, payload=json.loads(p), from_node=n), ensure_ascii=False))' "$@" "${6-m4}"
}
deliver() { out=$(printf '%s' "$1" | env -u TMUX bash "$BIN/fleet-hub-node.sh" deliver 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err"); }
FOP="$F/operator@alice"
queued_with() { grep -l -F "$1" "$FLEET_CONF_DIR/fleets/$L/peer-queue/"*.json 2>/dev/null | wc -l | tr -d ' '; }
deliver "$(relay 1 message "$FOP" "$U/issue-7" '{"text":"from the operator"}')"
ok; [ "$rc" = 0 ] && [ "$(queued_with 'from operator@alice on m4')" = 1 ] \
  || fail "D: an operator message reaches the worker, labelled operator@<login>" "rc=$rc $err"
deliver "$(relay 2 child_report "$FOP" "$U/issue-7" '{"child":"issue-42","state":"MERGED"}')"
ok; [ "$rc" = 1 ] || fail "D: an operator child report is refused" "rc=$rc $err"
deliver "$(python3 -c 'import json,sys; t=sys.argv[1]; rid=t+"#1"; print(json.dumps(dict(id=rid, kind="receipt", **{"from": sys.argv[2]}, to=t, payload=dict(rid=rid, kind="message", to=sys.argv[2], status="delivered", detail="sent"))))' "$OP" "$F/issue-42")"
ok; [ "$rc" = 0 ] && grep -q "\"rid\": \"$OP#1\".*\"state\": \"DELIVERED\"" "$BOOK" \
  || fail "D: a receipt to an operator sender lands in its book" "rc=$rc $err $(tail -1 "$BOOK" 2>/dev/null)"

# --- E: the repo rail ----------------------------------------------------------------------
deliver "$(relay 3 message "$FOP" "$U/issue-7" '{"text":"wrong repo","repo":"other/app"}')"
ok; [ "$rc" = 1 ] && [ "$(queued_with 'wrong repo')" = 0 ] || fail "E: another repo's #7 is refused for good" "rc=$rc $err"
deliver "$(relay 4 message "$FOP" "$U/issue-7" '{"text":"right repo","repo":"acme/app"}')"
ok; [ "$rc" = 0 ] && [ "$(queued_with 'right repo')" = 1 ] || fail "E: the named repo matches ⇒ delivered" "rc=$rc $err"

# --- F: an issue comment forwarded to the worker's machine, once ---------------------------
SHIM="$WORK/shim"; mkdir -p "$SHIM"
# The webhook path checks `tmux info` on the default server; nothing else here
# talks to it (every lookup passes -L). The shim answers that one call.
printf '#!/bin/sh\n[ "$1" = info ] && exit 0\nexec %s "$@"\n' "$REAL_TMUX" > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
hook() { # <cid> <issue> <author> <body>
  python3 -c 'import json,sys; c,i,a,b=sys.argv[1:5]; print(json.dumps({"action":"created","comment":{"id":int(c),"author_association":"OWNER","user":{"login":a},"body":b},"issue":{"number":int(i)},"repository":{"full_name":"acme/app"}}))' "$@"
}
bdeliver() { # <payload>
  sig="sha256=$(printf '%s' "$1" | python3 -c 'import hmac,hashlib,sys; print(hmac.new(b"s3", sys.stdin.buffer.read(), hashlib.sha256).hexdigest())')"
  out=$(printf '%s' "$1" | env -u TMUX PATH="$SHIM:$PATH" FLEET_ISSUE_BRIDGE_SECRET=s3 FLEET_DELIVERY_SIG="$sig" \
        bash "$BIN/fleet-issue-bridge.sh" --deliver 2>&1); rc=$?
}
P=$(hook 900001 42 bob 'please rebase')
bdeliver "$P"
f=$(outbox | head -1)
ok; [ "$rc" = 0 ] && [ "$(outbox | wc -l | tr -d ' ')" = 1 ] && case "$out" in *"forwarded(#42->m4)"*) true ;; *) false ;; esac \
  || fail "F: a comment for a worker elsewhere is forwarded through the hub" "rc=$rc $out"
ok; [ -n "$f" ] && [ "$(jget "$f" id)" = "$OP#bridge-900001" ] && [ "$(jget "$f" to)" = "$F/issue-42" ] \
  && [ "$(jget "$f" payload.bridge.cid)" = 900001 ] && [ "$(jget "$f" payload.repo)" = acme/app ] \
  && case "$(jget "$f" payload.text)" in *"[issue #42 — comment from @bob]"*"please rebase"*) true ;; *) false ;; esac \
  || fail "F: relay id bridge-<cid>, payload names repo + comment" "$(cat "$f" 2>/dev/null)"
bdeliver "$P"
ok; [ "$rc" = 0 ] && [ "$(outbox | wc -l | tr -d ' ')" = 1 ] && case "$out" in *"dup"*) true ;; *) false ;; esac \
  || fail "F: the same comment again is a dup — forwarded once" "rc=$rc $out"
rm -f "$OUTBOX"/*.json
# The worker's machine (here, for #7): applied through the bridge, once.
FW=$(relay bridge-900002 message "$FOP" "$U/issue-7" '{"text":"[issue #7 — comment from @bob]\n\nship it","repo":"acme/app","bridge":{"issue":7,"cid":900002}}')
deliver "$FW"
ok; [ "$rc" = 0 ] && [ "$(queued_with 'ship it')" = 1 ] || fail "F: --apply-forward hands the comment to #7's window" "rc=$rc $err"
deliver "$FW"
ok; [ "$rc" = 0 ] && [ "$(queued_with 'ship it')" = 1 ] && case "$err" in *dup*) true ;; *) false ;; esac \
  || fail "F: pushed again ⇒ dup, still one delivery" "rc=$rc $err"
deliver "$(relay bridge-900003 message "$FOP" "$U/issue-7" '{"text":"x","repo":"acme/app","bridge":{"issue":"7; rm -rf /","cid":1}}')"
ok; [ "$rc" = 1 ] || fail "F: a malformed bridge forward is refused" "rc=$rc $err"

if [ "$FAIL" -eq 0 ]; then printf 'operator-send selftest: PASS (%d checks)\n' "$CHECKS"; exit 0; fi
printf 'operator-send selftest: %d FAILED of %d\n' "$FAIL" "$CHECKS" >&2; exit 1
