#!/bin/bash
# fleet-epic-id-selftest.sh — an EPIC batch read by window ID (EPIC T497 C5): a
# two-member drill from plan to report, one member redone once.
#
# What /fleet-epic-run reads through bin/fleet-epic-tick.py, with the parent and
# every member a window ID (docs/dev/FLEET-ID.md) — this machine's ledgers
# (bin/fleet-id.sh open/result/close, as the spawner and the report write them) and
# the hub mirror's `GET /v1/node/ids?parent=` (a stub hub, FLEET_HUB_CURL):
#   A. plan: the parent's ID is its record's worker_id; C2 waits on C1 (the
#      charter's 依赖顺序), so only C1 is due; the heartbeat's mark is its code.
#   B. C1's window reports failed and closes, its record left OPEN (the dead
#      record): the tick reads the ID and sends C1 once more, its body carrying
#      `<!-- fleet:prev <ID> -->`, which dash-raw-session.sh reads into PREV_ID.
#   C. the redo (a new ID, prev = the first) merges by its ID result alone: C1 is
#      succeeded with both IDs on its chain, and C2 is released by ID (拍板 6).
#   D. C2 opens on another machine (only the hub mirror knows its ID); its window
#      closes with no result and a 「从这一段继续」 (prev only, no record) merges:
#      C2 succeeded off the newest baton, done, and the report's read lists every
#      member's IDs and the redo's.
#   E. an older hub that lists bare ids: the records alone, as before.
#   F. the heartbeat: stamped by the ID code with --task, the record's older mark
#      replaced, cleared by the record.
#   G. the driver's progress word (EPIC T497 C12): before the switch last_tick is
#      the record's; with the switch on `fleet_task_control.py progress` writes it
#      on the driver's own ID (a retried --event writes nothing), the tick's
#      last_tick is that word, and a closing tick's `report: pending` reads back
#      as report=pending — then the link, once the report ran.
#   H. the ID switch dispatches records nobody claims (EPIC T497 C14): a child
#      record with no worker_id is the family's ID opened on it (`task`) — merged
#      there ⇒ the member succeeded with that ID, the newest of two down `prev`;
#      a record no ID was opened on stays running.
#   I. the driver continued (EPIC T497 C18): an unclaimed parent's ID is the one
#      opened for it; a 「从这一段继续」 successor (prev = it) dispatches a child
#      whose record names no parent_task — still the batch's member (its ID's
#      parent is on the driver's line), never re-sent; the newest progress word
#      is the successor's; the line's IDs are never members.
# Hermetic: a sandbox FLEET_CONF_DIR, no tmux, no network, gh denied.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/epic-id.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT
N=0 BAD=0
ok()  { N=$((N + 1)); }
bad() { N=$((N + 1)); BAD=$((BAD + 1)); printf 'FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$3] not in [$2]" ;; esac; }

mkdir -p "$WORK/conf" "$WORK/path"
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fixture\n' > "$WORK/conf/node.env"
printf '#!/bin/sh\necho "$0 $*" >> "%s/denied"\nexit 91\n' "$WORK" > "$WORK/path/gh"
chmod +x "$WORK/path/gh"
cat > "$WORK/hub" <<'PY'
#!/usr/bin/env python3
# A stub hub: the node task API and the ID mirror's family read, in $STUB_STATE.
import json, os, sys
sys.stdin.read()
args = sys.argv[1:]
url = args[-1]
meth = args[args.index("-X") + 1] if "-X" in args else "GET"
body = args[args.index("--data-binary") + 1] if "--data-binary" in args else ""
st = json.load(open(os.environ["STUB_STATE"])) if os.path.exists(os.environ["STUB_STATE"]) else {"tasks": {}, "ids": []}
def save():
    json.dump(st, open(os.environ["STUB_STATE"], "w"))
def out(obj, code=200):
    print(json.dumps(obj)); print(code); sys.exit(0)
def uid(n):
    return "%08x-0000-4000-8000-%012x" % ((n * 0x9e3779b1) & 0xffffffff, n)
if url.startswith("https://hub.test/v1/node/ids?"):
    from urllib.parse import parse_qs, urlsplit
    q = parse_qs(urlsplit(url).query)
    p, seeds = q["parent"][0], q.get("id", [])
    if os.environ.get("STUB_OLD_HUB"):
        out({"ids": [{"id": r["id"], "short": r["short"]} for r in st["ids"]]})
    fam, seen = [], {p}
    for r in st["ids"]:
        if r.get("parent") == p or r["id"] in seeds or r.get("prev") in seen:
            fam.append(r); seen.add(r["id"])
    out({"parent": p, "ids": fam})
if not url.startswith("https://hub.test/v1/node/tasks"):
    out({"error": "no route"}, 404)
path = url[len("https://hub.test/v1/node/tasks"):].strip("/")
if meth == "POST" and path == "":
    req = json.loads(body)
    for t in st["tasks"].values():
        if t["_token"] == req["token"]:
            out(t)
    k = len(st["tasks"]) + 1
    n = "T%d" % k
    parent = os.environ.get("STUB_PARENT", "")
    t = dict(id=n, authority_version=1, generation=1, attempt_id="a-" + n, title=req["title"], repo=req.get("repo", ""),
             requested_agent=req["requested_agent"], resolved_agent=req["resolved_agent"], parent_task=parent,
             worker_id="fleet/" + uid(k), execution_owner="fleet/" + uid(k), outcome="", state="running",
             request_payload=json.dumps(req.get("request_payload") or {}), _token=req["token"])
    if os.environ.get("STUB_UNCLAIMED"):   # the ID switch: a record nobody claims (C14)
        t.update(worker_id="", execution_owner="", state="accepted")
    st["tasks"][n] = t; save(); out(t)
if meth == "GET" and path.endswith("/children"):
    p = path.split("/")[0]
    out(dict(parent=p, children=[t for t in st["tasks"].values() if t.get("parent_task") == p]))
if meth == "GET" and path in st["tasks"]:
    got = dict(task=st["tasks"][path], live=None, pr_state="none")
    if path in st.get("progress", {}):
        got["progress"] = st["progress"][path]   # a tick the record kept before the switch
    out(got)
out({"error": "no route"}, 404)
PY
chmod +x "$WORK/hub"
export PATH="$WORK/path:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_HUB_CURL="$WORK/hub" \
  STUB_STATE="$WORK/state.json" FLEET_AGENT=claude FLEET_ID_PUSH=0 FLEET_REPO=o/r
unset TMUX TMUX_PANE FLEET_SESSION FLEET_LAUNCH_CONTEXT STUB_PARENT STUB_OLD_HUB STUB_UNCLAIMED FLEET_ID_LIVE FLEET_ID_LIVE_CMD

jq_() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
tick() { python3 "$BIN/fleet-epic-tick.py" status --task "$P" "$@"; }
mem() { printf '%s' "$S" | jq_ "[m for m in d['members'] if m['key']=='$1'][0]$2"; }
wid() { python3 -c 'import json,os,sys; print(json.load(open(os.environ["STUB_STATE"]))["tasks"][sys.argv[1]]["worker_id"].split("/")[1])' "$1"; }
# dispatch <title> <body> → the child's T<m> (the task tool's script, bound to the parent)
dispatch() { printf '%s' "$2" > "$WORK/body"
  STUB_PARENT="$P" bash "$BIN/fleet-task-record.sh" dispatch --title "$1" --repo o/r --body-file "$WORK/body"; }
# hub_id <json> — an ID only the hub mirror holds (another machine opened it)
hub_id() { python3 - "$1" <<'PY'
import json, os, sys
st = json.load(open(os.environ["STUB_STATE"]))
st["ids"].append(json.loads(sys.argv[1]))
json.dump(st, open(os.environ["STUB_STATE"], "w"))
PY
}

# --- A. plan ---------------------------------------------------------------------
cat > "$WORK/charter" <<'EOF'
/fleet-epic-run

<!-- fleet:epic repo=o/r short=演练 cap=2 -->
# EPIC: 演练批次

## 成员
- [ ] **C1** 加一个开关
- [ ] **C2** 用上这个开关
## 依赖顺序
| 成员 | 依赖 | 可并行 |
|---|---|---|
| C1 | — | |
| C2 | C1 | |

## C1 · 加一个开关
开关叫 demo。
EOF
P=$(bash "$BIN/fleet-task-record.sh" dispatch --title "EPIC: 演练批次" --body-file "$WORK/charter")
eq "A: the parent task" T1 "$P"
DRV=$(wid T1)
bash "$BIN/fleet-id.sh" open "$DRV" --title "EPIC: 演练批次" --task T1 >/dev/null
DSHORT=$(bash "$BIN/fleet-id.sh" short "$DRV")
S=$(tick); RC=$?
eq "A: the tick reads the batch" 0 "$RC"
eq "A: the parent's ID is its record's" "$DRV" "$(printf '%s' "$S" | jq_ 'd["parent_id"]')"
eq "A: the mark is the parent's code" "$DSHORT" "$(printf '%s' "$S" | jq_ 'd["mark"]')"
eq "A: only C1 is due — C2 waits on it" "C1" "$(printf '%s' "$S" | jq_ '" ".join(n["key"] for n in d["next"])')"
eq "A: C2 waits on C1" "waiting ['C1']" "$(mem C2 '["state"]') $(mem C2 '["waits_on"]')"
has "A: the line says it" "$(tick --line)" "等依赖 1"

# --- B. C1 fails and its window closes; its record stays open --------------------
T_A=$(dispatch "C1 · 加一个开关" "$(printf '%s' "$S" | jq_ 'd["next"][0]["body"]')")
ID_A=$(wid "$T_A")
bash "$BIN/fleet-id.sh" open "$ID_A" --parent "$DRV" --task "$T_A" --title "C1 · 加一个开关" >/dev/null
S=$(tick)
eq "B: C1 runs under its ID" "running $ID_A" "$(mem C1 '["state"]') $(mem C1 '["id"]')"
bash "$BIN/fleet-id.sh" result "$ID_A" --state failed --summary "门禁红" >/dev/null
bash "$BIN/fleet-id.sh" close "$ID_A" --reason reaped >/dev/null
S=$(tick)
eq "B: read by ID, C1 is sent once more" "retry C1 $ID_A" "$(mem C1 '["state"]') $(printf '%s' "$S" | jq_ 'd["next"][0]["key"]+" "+d["next"][0]["prev"]')"
BODY=$(printf '%s' "$S" | jq_ 'd["next"][0]["body"]')
has "B: the retry body names the ID it continues" "$BODY" "<!-- fleet:prev $ID_A -->"
has "B: and its code" "$BODY" "$(mem C1 '["short"]')"
# the spawner's read of the marker (dash-raw-session.sh, as it runs it)
sed -n '/^# An EPIC member.s redo/,/^fi$/p' "$BIN/dash-raw-session.sh" > "$WORK/prev.sh"
got=$(PROMPT=$BODY TASK_REF=T9 PREV_ID='' bash -c '. "$1"; printf %s "$PREV_ID"' _ "$WORK/prev.sh")
eq "B: dash-raw-session.sh reads it into PREV_ID" "$ID_A" "$got"
got=$(PROMPT=$BODY TASK_REF='' PREV_ID='' bash -c '. "$1"; printf %s "$PREV_ID"' _ "$WORK/prev.sh")
eq "B: only for a task's words" "" "$got"

# --- C. the redo merges by its ID alone; C2 is released by ID --------------------
T_B=$(dispatch "C1 · 加一个开关" "$BODY")
ID_B=$(wid "$T_B")
bash "$BIN/fleet-id.sh" open "$ID_B" --parent "$DRV" --prev "$ID_A" --task "$T_B" --title "C1 · 加一个开关" >/dev/null
S=$(tick)
eq "C: the redo is C1's newest baton" "running $ID_B" "$(mem C1 '["state"]') $(mem C1 '["id"]')"
bash "$BIN/fleet-id.sh" result "$ID_B" --state merged --pr 11 >/dev/null
S=$(tick)
eq "C: C1 succeeded off its ID, with its PR" "succeeded 11" "$(mem C1 '["state"]') $(mem C1 '["pr"]')"
eq "C: both IDs on C1's chain, the redo's prev the first" "$ID_A $ID_B $ID_A" \
  "$(mem C1 '["ids"][0]["id"]') $(mem C1 '["ids"][1]["id"]') $(mem C1 '["ids"][1]["prev"]')"
eq "C: C2 is released" "C2" "$(printf '%s' "$S" | jq_ '" ".join(n["key"] for n in d["next"])')"

# --- D. C2 on another machine, continued by hand ---------------------------------
T_C=$(dispatch "C2 · 用上这个开关" "$(printf '%s' "$S" | jq_ 'd["next"][0]["body"]')")
ID_C=$(wid "$T_C") ID_D=dddddddd-0000-4000-8000-00000000000d
hub_id "{\"id\":\"$ID_C\",\"short\":\"T-c2aaa\",\"parent\":\"$DRV\",\"task\":\"$T_C\",\"opened_at\":50,\"results\":[],\"closed_at\":60}"
S=$(tick)
eq "D: its window closed with no result — a failure, not running forever" "retry T-c2aaa" "$(mem C2 '["state"]') $(mem C2 '["short"]')"
hub_id "{\"id\":\"$ID_D\",\"short\":\"T-c2bbb\",\"prev\":\"$ID_C\",\"opened_at\":70,\"results\":[{\"state\":\"merged\",\"pr\":\"12\"}]}"
S=$(tick)
eq "D: the continued ID carries C2" "succeeded 12 T-c2bbb" "$(mem C2 '["state"]') $(mem C2 '["pr"]') $(mem C2 '["short"]')"
eq "D: nothing more to send" 0 "$(printf '%s' "$S" | jq_ 'len(d["next"])')"
eq "D: the batch is done" True "$(printf '%s' "$S" | jq_ 'd["done"]')"
eq "D: the report's read: every member's IDs" "C1:$(mem C1 '["ids"][0]["short"]'),$(mem C1 '["ids"][1]["short"]') C2:T-c2aaa,T-c2bbb" \
  "$(printf '%s' "$S" | jq_ '" ".join(m["key"]+":"+",".join(i["short"] for i in m["ids"]) for m in d["members"])')"
has "D: the line says write the report" "$(tick --line)" "该写报告"

# --- E. an older hub: the records alone ------------------------------------------
S=$(STUB_OLD_HUB=1 tick)
eq "E: C2's record alone is still running" "running $T_C" "$(mem C2 '["state"]') $(mem C2 '["task"]')"
eq "E: C1 still read off this machine's ledgers" "succeeded" "$(mem C1 '["state"]')"

# --- F. the heartbeat by the ID's code -------------------------------------------
bash "$BIN/fleet-epic-heartbeat.sh" "$P" --tick 1 >/dev/null
H=$(bash "$BIN/fleet-epic-heartbeat.sh" "$DSHORT" --task "$P" --tick 2 --live 0 --inflight 0)
has "F: stamped by the parent's code" "$H" "stamped epic=$DSHORT"
eq "F: one batch, one mark (the record's older one replaced)" "o-r-$DSHORT" "$(ls "$WORK/conf/global/epic-running.d")"
has "F: the record beside it" "$(cat "$WORK/conf/global/epic-running.d/o-r-$DSHORT")" "task: $P"
has "F: cleared by the record" "$(bash "$BIN/fleet-epic-heartbeat.sh" --clear "$P")" "cleared"
eq "F: nothing left" "" "$(ls "$WORK/conf/global/epic-running.d")"
bash "$BIN/fleet-epic-heartbeat.sh" "T-ab!" >/dev/null 2>&1; eq "F: a bad code is refused" 2 "$?"

# --- G. the driver's progress word, on its ID ------------------------------------
python3 - "$P" <<'PY'
import json, os, sys
st = json.load(open(os.environ["STUB_STATE"]))
st.setdefault("progress", {})[sys.argv[1]] = {"summary": "tick 28 · slots 1/2 · report: -"}
json.dump(st, open(os.environ["STUB_STATE"], "w"))
PY
S=$(tick)
eq "G: before the switch, the record's tick" "tick 28 · slots 1/2 · report: - record" \
  "$(printf '%s' "$S" | jq_ 'd["last_tick"]+" "+d["last_tick_src"]')"
# the driver's pane: a tmux that knows one window, the driver's
printf '#!/bin/sh\ncase "$*" in *"#{@fleet_id}"*) echo "%s" ;; *) exit 1 ;; esac\n' "$DRV" > "$WORK/path/tmux"
chmod +x "$WORK/path/tmux"
prog() { FLEET_ID_SWITCH=on python3 "$BIN/fleet_task_control.py" progress --pane %1 --event "$1" --summary "$2"; }
out=$(prog tick-29 "tick 29 · slots 0/2 · 合 C1 C2 · report: pending"); RC=$?
eq "G: with the switch on, the word is the ID's" "0" "$RC"
has "G: recorded on the driver's ID" "$out" "id: $DRV"
prog tick-29 "tick 29 · again" >/dev/null
eq "G: a retried tick writes nothing" 1 "$(grep -c '"ev":"progress"' "$WORK/conf/ids/$DRV.ndjson")"
S=$(tick)
eq "G: last_tick is the ID's word" "tick 29 · slots 0/2 · 合 C1 C2 · report: pending id" \
  "$(printf '%s' "$S" | jq_ 'd["last_tick"]+" "+d["last_tick_src"]')"
eq "G: the closing guard reads: core empty, report not run" "pending True" \
  "$(printf '%s' "$S" | jq_ 'd["report"]+" "+str(d["done"])')"
has "G: the line says write the report" "$(tick --line)" "该写报告"
has "G: fleet-id.sh get shows it" "$(bash "$BIN/fleet-id.sh" get "$DRV")" "进度"
prog report-1 "tick 30 · report: https://space.test/p/1" >/dev/null
S=$(tick)
eq "G: the report ran: its link" "https://space.test/p/1" "$(printf '%s' "$S" | jq_ 'd["report"]')"
has "G: and the line says so" "$(tick --line)" "报告 https://space.test/p/1"
rm -f "$WORK/path/tmux"
out=$(FLEET_ID_SWITCH=off python3 "$BIN/fleet_task_control.py" progress --pane %1 --event tick-31 --summary x)
eq "G: switch off: the ID's ledger is not written" 2 "$(grep -c '"ev":"progress"' "$WORK/conf/ids/$DRV.ndjson")"

# --- H. the ID switch: records nobody claims --------------------------------------
T_E=$(STUB_UNCLAIMED=1 dispatch "C3 · 记录没人认领" "加在范围内")
T_F=$(STUB_UNCLAIMED=1 dispatch "C4 · 还没开窗" "加在范围内")
eq "H: the records carry no worker" "" "$(python3 -c 'import json,os,sys; print(json.load(open(os.environ["STUB_STATE"]))["tasks"][sys.argv[1]]["worker_id"])' "$T_E")"
ID_E=eeeeeeee-0000-4000-8000-00000000000e ID_F=ffffffff-0000-4000-8000-00000000000f
bash "$BIN/fleet-id.sh" open "$ID_E" --parent "$DRV" --task "$T_E" --title "C3 · 记录没人认领" >/dev/null
S=$(tick)
eq "H: C3 runs under the ID opened on its record" "running $ID_E" "$(mem C3 '["state"]') $(mem C3 '["id"]')"
bash "$BIN/fleet-id.sh" result "$ID_E" --state merged --pr 13 >/dev/null
bash "$BIN/fleet-id.sh" close "$ID_E" --reason merged >/dev/null
S=$(tick)
eq "H: C3 succeeded off that ID" "succeeded 13 $ID_E" "$(mem C3 '["state"]') $(mem C3 '["pr"]') $(mem C3 '["ids"][0]["id"]')"
eq "H: one ID on C3's chain" 1 "$(mem C3 '["ids"].__len__()')"
eq "H: C4, no ID opened on it, still runs" "running $T_F 0" "$(mem C4 '["state"]') $(mem C4 '["task"]') $(mem C4 '["ids"].__len__()')"
hub_id "{\"id\":\"$ID_F\",\"short\":\"T-c4aaa\",\"parent\":\"$DRV\",\"task\":\"$T_F\",\"opened_at\":80,\"results\":[{\"state\":\"failed\"}],\"closed_at\":90}"
ID_G=99999999-0000-4000-8000-000000000009
hub_id "{\"id\":\"$ID_G\",\"short\":\"T-c4bbb\",\"parent\":\"$DRV\",\"task\":\"$T_F\",\"prev\":\"$ID_F\",\"opened_at\":95,\"results\":[{\"state\":\"merged\",\"pr\":\"14\"}]}"
S=$(tick)
eq "H: two IDs on one record: the newest down prev carries it" "succeeded 14 T-c4bbb" "$(mem C4 '["state"]') $(mem C4 '["pr"]') $(mem C4 '["short"]')"
has "H: the line counts both" "$(tick --line)" "合 4"

# --- I. the driver continued (C18): its successor's dispatches are the batch's ---
# The parent record nobody claims (the ID switch); the driver's ID was opened for
# it; it closes, a 「从这一段继续」 opens a new ID (prev = it, the same record), and
# that one dispatches C1 with parent_session only — no parent_task on the record.
cat > "$WORK/charter2" <<'EOF'
<!-- fleet:epic repo=o/r short=接续 cap=2 -->
- [ ] **C1** 接续后派的
- [ ] **C2** 还没派的
EOF
P=$(STUB_UNCLAIMED=1 bash "$BIN/fleet-task-record.sh" dispatch --title "EPIC: 接续" --body-file "$WORK/charter2")
DRV1=aaaaaaaa-1111-4000-8000-0000000000a1 DRV2=aaaaaaaa-2222-4000-8000-0000000000a2
bash "$BIN/fleet-id.sh" open "$DRV1" --title "EPIC: 接续" --task "$P" >/dev/null
bash "$BIN/fleet-id.sh" progress "$DRV1" --summary "tick 1 · report: -" >/dev/null
bash "$BIN/fleet-id.sh" close "$DRV1" --reason reaped >/dev/null
S=$(tick)
eq "I: the unclaimed parent's ID is the one opened for it" "$DRV1 unstarted" "$(printf '%s' "$S" | jq_ 'd["parent_id"]') $(mem C1 '["state"]')"
bash "$BIN/fleet-id.sh" open "$DRV2" --title "EPIC: 接续" --task "$P" --prev "$DRV1" >/dev/null
printf 'x' > "$WORK/body"   # the task tool from the successor: no STUB_PARENT
T_X=$(STUB_UNCLAIMED=1 bash "$BIN/fleet-task-record.sh" dispatch --title "C1 · 接续后派的" --repo o/r --body-file "$WORK/body")
eq "I: the successor's child record names no parent" "" \
  "$(python3 -c 'import json,os,sys; print(json.load(open(os.environ["STUB_STATE"]))["tasks"][sys.argv[1]]["parent_task"])' "$T_X")"
ID_X=bbbbbbbb-0000-4000-8000-0000000000b1
bash "$BIN/fleet-id.sh" open "$ID_X" --parent "$DRV2" --task "$T_X" --title "C1 · 接续后派的" >/dev/null
bash "$BIN/fleet-id.sh" progress "$DRV2" --summary "tick 2 · 派 C1 · report: -" >/dev/null
S=$(tick)
eq "I: the driver is its whole line" "$DRV1 $DRV2" "$(printf '%s' "$S" | jq_ '" ".join(d["lineage"])')"
eq "I: C1 is the successor's dispatch, running" "running $T_X $ID_X" "$(mem C1 '["state"]') $(mem C1 '["task"]') $(mem C1 '["id"]')"
eq "I: so it is not sent again — C2 is" "C2" "$(printf '%s' "$S" | jq_ '" ".join(n["key"] for n in d["next"])')"
eq "I: the newest progress word down the line" "tick 2 · 派 C1 · report: - id" "$(printf '%s' "$S" | jq_ 'd["last_tick"]+" "+d["last_tick_src"]')"
eq "I: the line's IDs are never members" "1" "$(mem C1 '["ids"].__len__()')"
bash "$BIN/fleet-id.sh" result "$ID_X" --state merged --pr 21 >/dev/null
S=$(tick)
eq "I: and it merges by its ID" "succeeded 21" "$(mem C1 '["state"]') $(mem C1 '["pr"]')"

[ -e "$WORK/denied" ] && bad "gh ran: $(cat "$WORK/denied")" || ok
[ "$BAD" = 0 ] && { printf 'fleet-epic-id-selftest: %d checks OK (a two-member batch by ID, one redone; unclaimed records)\n' "$N"; exit 0; }
printf 'fleet-epic-id-selftest: %d of %d FAILED\n' "$BAD" "$N"; exit 1
