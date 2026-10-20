#!/bin/bash
# cross-send-selftest.sh — a message or an answer for a worker on ANOTHER machine
# reaches it, or the sender is told why not (issue #2729). On an isolated tmux
# server and a sandbox conf dir, the hub's worker map faked as the file the
# ccquota agent writes (control/hub-workers.tsv), its outbox read back as files
# and the agent's refusal played by hand (refused/<file> + .why), pins:
#   G  fleet-peer-send.sh from the ORCHESTRATOR's pane: the relay's `from` is the
#      window's identity `<fleet UUID>/<fleet_id>` — a worker_id the hub accepts —
#      never `<fleet UUID>/orchestrator` (refused INVALID_ARGUMENT, unseen, on
#      2026-10-09); a worker pane still sends as its key.
#   H  a relay the hub REFUSED (the agent moved it to refused/ with its reason):
#      exit 1, the reason on stderr, a FAILED row in the delivery book — never
#      `queued`.
#   I  a queued send from a pane: FLEET_PEER_RECEIPT_SECS later, still not
#      DELIVERED ⇒ the sending session is told (`[delivery] …`, over its own
#      inbox — here its peer queue, no Claude runs); DELIVERED by then ⇒ nothing.
#   J  fleet-answer.sh --answer on a worker elsewhere (wid:, <slug>:issue-N):
#      ONE worker_answer hub write naming the map's worker_id and the picks;
#      the node's verdict is the outcome (succeeded 0 · failed 1 · unknown 4);
#      --show refuses and says where; a machine that is offline sends nothing;
#      a target already `wid:…:issue-N` is never prefixed twice (issue #4938).
# tmux / python3 absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-repo-fixture.sh"
REAL_TMUX=$(command -v tmux) || { echo 'cross-send selftest: tmux absent — SKIP'; exit 0; }
st_need python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cross-send.XXXXXX")" || exit 2
L="xsnd$$"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
export FLEET_HISTORY_LEDGER="$WORK/landed.tsv"
: > "$FLEET_CONF_DIR/fleets/$L/conf"
fx_repo "$FLEET_CONF_DIR" "$L" acme/app FLEET_MAIN="$WORK/main"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_HUB_STATUS_CMD FLEET_HUB_CACHE_SECS FLEET_HUB_RETAIN_SECS \
  FLEET_HUB_WRITE_CMD FLEET_PEER_RECEIPT_SECS FLEET_WORKER_ASSERT

st_tally
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
lib() { bash -c '. "$1/fleet-lib.sh"; shift; "$@"' _ "$BIN" "$@"; }

tf -f /dev/null new-session -d -s "$L" -n plan 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'cross-send selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
SP=$(tf display-message -p '#{socket_path}')
wo=$(tf new-window -d -P -F '#{window_id}' -n orch 'while :; do sleep 300; done')
tf set-window-option -t "$wo" @fleet_role worker \; set-window-option -t "$wo" @norepo 1 \; \
   set-window-option -t "$wo" @fleet_id 0dbf19b9-aaaa-4bbb-8ccc-000000002729
po=$(tf display-message -p -t "$wo" '#{pane_id}')
w7=$(tf new-window -d -P -F '#{window_id}' -n issue-7 'while :; do sleep 300; done')
tf set-window-option -t "$w7" @issue 7
p7=$(tf display-message -p -t "$w7" '#{pane_id}')
(cd "$BIN" && python3 -c 'import sys, fleet_control as c; c.Control(sys.argv[1]).inventory()' "$FLEET_CONF_DIR") >/dev/null 2>&1
U=$(lib fleet_uuid "$L")
[ -n "$U" ] || { echo 'cross-send selftest: no fleet UUID could be minted' >&2; exit 1; }
F=11111111-2222-3333-4444-555555555555          # a fleet on another machine ("mac-a")
CACHE="$FLEET_CONF_DIR/control/hub-workers.tsv"
OUTBOX="$FLEET_CONF_DIR/control/hub-outbox"
BOOK="$FLEET_CONF_DIR/fleets/$L/delivery.ndjson"
QDIR="$FLEET_CONF_DIR/fleets/$L/peer-queue"
mkdir -p "${CACHE%/*}"
printf '%s/issue-42\tmac-a\t\n%s/acme-app:issue-43\tmac-a\t\n%s/issue-44\tmac-b:lost\t\n' "$F" "$F" "$F" > "$CACHE"
export CCQUOTA_FLEET=1
# The map is written once, here; every leg after must still trust it — on a slow
# runner leg J came >30s later and the 30s default called it stale (issue #3782).
export FLEET_HUB_CACHE_SECS=86400
outbox() { ls "$OUTBOX"/*.json 2>/dev/null; }
jget() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); v=r
for k in sys.argv[2].split("."): v=v.get(k) if isinstance(v, dict) else None
print("" if v is None else v)' "$1" "$2"; }
# from_pane <pane> <args…> → out / err / rc: fleet-peer-send.sh as that pane's session
from_pane() {
  local p="$1"; shift
  out=$(TMUX="$SP,0,0" TMUX_PANE="$p" bash "$BIN/fleet-peer-send.sh" "$@" 2>"$WORK/err"); rc=$?
  err=$(cat "$WORK/err")
}
# The hub's worker_id grammar, the claude-fleet copy of fleetid.workerIDRE.
hub_ok() { (cd "$BIN" && python3 -c 'import sys, fleet_hub_common as h; sys.exit(0 if h.WORKER_ID_RE.fullmatch(sys.argv[1]) else 1)' "$1"); }

# --- G: a keyless session sends as its identity (its key, issue #4341) ----------------------------------------------
export FLEET_PEER_RECEIPT_SECS=0
# No agent takes the outbox file in G or I, so a send's wait for it (3 s) only
# ever times out — the same «not handed over yet» queue either way; 0 skips the
# wait. H, where a stand-in agent DOES take it, waits as the default does.
export FLEET_HUB_SENT_WAIT=0
from_pane "$po" "wid:$F/issue-42" 'hello from the orchestrator'
f=$(outbox | head -1)
fid=$(tf display-message -p -t "$wo" '#{@fleet_id}')
st_count; [ "$rc" = 3 ] && [ -n "$f" ] || st_miss "G: the orchestrator's message is queued at the hub" "rc=$rc out=$out err=$err"
st_count; [ -n "$fid" ] && [ -n "$f" ] && [ "$(jget "$f" from)" = "$U/$fid" ] \
  || st_miss "G: from = <fleet UUID>/<the window's fleet_id>" "fid=$fid $(cat "$f" 2>/dev/null)"
st_count; [ -n "$f" ] && hub_ok "$(jget "$f" from)" && case "$(jget "$f" id)" in "$U/$fid#"*) true ;; *) false ;; esac \
  || st_miss "G: the hub's worker_id grammar accepts it, the id scoped to it" "$(cat "$f" 2>/dev/null)"
st_count; ! hub_ok "$U/orchestrator" || st_miss "G: (premise) <uuid>/orchestrator is no worker_id the hub accepts"
rm -f "$OUTBOX"/*.json
from_pane "$p7" "wid:$F/issue-42" 'hello from a worker'
f=$(outbox | head -1)
st_count; [ "$rc" = 3 ] && [ -n "$f" ] && [ "$(jget "$f" from)" = "$U/acme-app:issue-7" ] \
  || st_miss "G: a worker pane still sends as its key" "rc=$rc $(cat "$f" 2>/dev/null)"
rm -f "$OUTBOX"/*.json

# --- H: the hub refused it ----------------------------------------------------------------
unset FLEET_HUB_SENT_WAIT
# The agent's half, by hand: take the relay out of the outbox into refused/, then
# write its reason (the agent renames first, writes .why after).
( for _ in $(seq 1 40); do
    g=$(ls "$OUTBOX"/*.json 2>/dev/null | head -1)
    if [ -n "$g" ]; then
      mkdir -p "$OUTBOX/refused"; mv "$g" "$OUTBOX/refused/"; sleep 0.3
      printf 'INVALID_ARGUMENT: from: worker_id must be …\n' > "$OUTBOX/refused/${g##*/}.why"; exit 0
    fi
    sleep 0.1
  done ) &
agent=$!
from_pane "$po" "wid:$F/issue-42" 'this one is refused'
wait "$agent" 2>/dev/null
st_count; [ "$rc" = 1 ] && [ -z "$out" ] || st_miss "H: a refused relay is exit 1, nothing on stdout" "rc=$rc out=$out err=$err"
st_count; case "$err" in *"refused"*"INVALID_ARGUMENT: from: worker_id must be"*) true ;; *) false ;; esac \
  || st_miss "H: stderr carries the hub's reason" "$err"
st_count; tail -1 "$BOOK" 2>/dev/null | grep -q '"state": "FAILED".*refused by the hub: INVALID_ARGUMENT' \
  || st_miss "H: the delivery book says FAILED, with the reason" "$(tail -1 "$BOOK" 2>/dev/null)"
rm -rf "$OUTBOX"/*.json "$OUTBOX/refused"

# --- I: a send still queued after the receipt window is told to its sender -------------------
export FLEET_HUB_SENT_WAIT=0
notices() { grep -l -F '[delivery]' "$QDIR"/*.json 2>/dev/null | wc -l | tr -d ' '; }
FLEET_PEER_RECEIPT_SECS=1 from_pane "$p7" "wid:$F/issue-42" 'ping that never lands'
st_count; [ "$rc" = 3 ] || st_miss "I: queued (exit 3)" "rc=$rc out=$out err=$err"
for _ in $(seq 1 60); do [ "$(notices)" -ge 1 ] && break; sleep 0.2; done
st_count; [ "$(notices)" = 1 ] || st_miss "I: after the window, the sender is told it was not delivered" "$(ls "$QDIR" 2>/dev/null)"
st_count; grep -q -F 'ping that never lands' "$QDIR"/*.json 2>/dev/null && grep -q 'issue-42' "$QDIR"/*.json 2>/dev/null \
  || st_miss "I: the notice names the recipient and the message" "$(cat "$QDIR"/*.json 2>/dev/null | head -c 400)"
rm -rf "$QDIR" "$OUTBOX"/*.json
FLEET_PEER_RECEIPT_SECS=2 from_pane "$p7" "wid:$F/issue-42" 'ping that lands'
f=$(outbox | head -1)
[ -n "$f" ] && bash "$BIN/fleet-peer-queue.sh" note -L "$L" --rid "$(jget "$f" id)" --state DELIVERED \
  --to "$F/issue-42" --kind receipt --via hub --detail sent
sleep 4
st_count; [ "$(notices)" = 0 ] || st_miss "I: delivered within the window ⇒ no notice" "$(cat "$QDIR"/*.json 2>/dev/null | head -c 300)"
rm -rf "$QDIR" "$OUTBOX"/*.json
unset FLEET_PEER_RECEIPT_SECS

# --- J: fleet-answer.sh on a worker elsewhere ----------------------------------------------
WRITES="$WORK/writes"
export FLEET_HUB_WRITE_CMD='printf "%s\t%s\n" "$1" "$2" >> '"$WRITES"'; cat "$FLEET_CONF_DIR/answer" 2>/dev/null'
answer() { printf '%s\n' "$1" > "$FLEET_CONF_DIR/answer"; }
nwrites() { [ -f "$WRITES" ] && grep -c . "$WRITES" || echo 0; }
OPID='"operation_id":"00000000-0000-4000-8000-000000000042"'
fa() { out=$(env -u TMUX -u TMUX_PANE bash "$BIN/fleet-answer.sh" --session "$L" "$@" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err"); }
answer '{'"$OPID"',"status":"succeeded","result":{"answered":"2 1,3","how":"confirmed"}}'
fa --answer "wid:$F/issue-42" 2 1,3
st_count; [ "$rc" = 0 ] && case "$out" in "answered → $F/issue-42 on mac-a"*) true ;; *) false ;; esac \
  || st_miss "J: succeeded ⇒ answered, exit 0" "rc=$rc out=$out err=$err"
st_count; [ "$(nwrites)" = 1 ] && [ "$(cut -f1 "$WRITES")" = worker_answer ] \
  && python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["worker_id"]==sys.argv[2] and d["answer"]=="2 1,3" else 1)' \
       "$(cut -f2 "$WRITES")" "$F/issue-42" \
  || st_miss "J: ONE worker_answer naming the map's worker_id and the picks" "$(cat "$WRITES" 2>/dev/null)"
fa --answer acme-app:issue-43 1
st_count; [ "$rc" = 0 ] && tail -1 "$WRITES" | grep -q "$F/acme-app:issue-43" \
  || st_miss "J: <slug>:issue-N goes through the hub as its worker_id" "rc=$rc $err $(tail -1 "$WRITES")"
# issue #4938: a target already `wid:` that ends in `<slug>:issue-N` is NOT a key to
# prefix again — the caller's full worker_id, and the node adapter's own call
# (fleet-control-read.sh: `--answer "wid:$key"`, key `<slug>:issue-N`), never `wid:wid:`.
fa --answer "wid:$F/acme-app:issue-43" 1
st_count; [ "$rc" = 0 ] && tail -1 "$WRITES" | grep -q "\"worker_id\":\"$F/acme-app:issue-43\"" \
  || st_miss "J: wid:<uuid>/<slug>:issue-N goes through the hub once, unprefixed" "rc=$rc $err $(tail -1 "$WRITES")"
tf set-window-option -t "$w7" @repo acme/app
n0=$(nwrites)
fa --answer wid:acme-app:issue-7 1
st_count; [ "$(nwrites)" = "$n0" ] && case "$err" in *"wid:wid:"*|*"bad worker id"*|*"no live worker"*) false ;; *) true ;; esac \
  || st_miss "J: the node's wid:<slug>:issue-N resolves to its window here" "rc=$rc err=$err"
answer '{'"$OPID"',"status":"failed","result":{"error":{"code":"INVALID_STATE","message":"nothing is pending on the pane"}}}'
fa --answer "wid:$F/issue-42" 1
st_count; [ "$rc" = 1 ] && case "$err" in *"nothing is pending on the pane"*) true ;; *) false ;; esac \
  || st_miss "J: a refusal is exit 1, the node's reason verbatim" "rc=$rc err=$err"
answer '{'"$OPID"',"status":"unknown","result":{"error":{"code":"UNKNOWN_OUTCOME","message":"Keys were sent but not confirmed"}}}'
fa --answer "wid:$F/issue-42" 1
st_count; [ "$rc" = 4 ] || st_miss "J: unknown ⇒ exit 4 (sent, not confirmed)" "rc=$rc err=$err"
n0=$(nwrites)
fa --show "wid:$F/issue-42"
st_count; [ "$rc" = 1 ] && [ "$(nwrites)" = "$n0" ] && case "$err" in *"lives on mac-a"*--answer*) true ;; *) false ;; esac \
  || st_miss "J: --show elsewhere refuses, says where, writes nothing" "rc=$rc err=$err"
fa --answer "wid:$F/issue-44" 1
st_count; [ "$rc" = 1 ] && [ "$(nwrites)" = "$n0" ] && case "$err" in *offline*) true ;; *) false ;; esac \
  || st_miss "J: a machine that is offline: nothing sent" "rc=$rc err=$err"

st_done
