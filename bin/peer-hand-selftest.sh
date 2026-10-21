#!/bin/bash
# peer-hand-selftest.sh — a report nobody takes goes to the PERSON, never quietly
# away (claude-fleet T887). bin/fleet-peer-queue.sh + bin/fleet-peer-hand.py on a
# sandbox delivery book (no tmux, no hub: the task record and the notice are seams):
#   A  the hub's EXPIRED receipt for a report (relay TTL) — `note --state EXPIRED`
#      writes no EXPIRED row: HANDED, one reminder row carrying the report's words
#      (off its QUEUED row's `report`), one note on its task record, one notice
#      「有 N 份回报没人收」; `wait` reads HANDED as not delivered (exit 1)
#   B  `stale`: a hub-relayed report QUEUED past FLEET_PEER_QUEUE_DEAD_SECS is
#      HANDED (not EXPIRED, no dead-log line); a message of the same age still EXPIRED
#   C  backfill: a report an older version let EXPIRE is handed once — a row with
#      no `report` says its words were not kept; a second stale hands nothing
#   D  a local queue item for a report past FLEET_PEER_QUEUE_TTL: drain hands it,
#      the words off its queue file
#   E  an EXPIRED receipt for a rid this book does not know stays EXPIRED
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pq-hand.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
L=pqh
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf"
unset TMUX TMUX_PANE FLEET_PEER_QUEUE_TTL FLEET_PEER_QUEUE_DEAD_SECS FLEET_PEER_QUEUE_ALERT_SECS
D="$FLEET_CONF_DIR/fleets/$L"; mkdir -p "$D"
BOOK="$D/delivery.ndjson" ORPH="$FLEET_CONF_DIR/global/orphan-reports.ndjson"
TASKLOG="$WORK/task.log" NOTELOG="$WORK/notice.py.log" DEADLOG="$FLEET_CONF_DIR/logs/peer-queue-dead.log"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\n' "$TASKLOG" > "$WORK/task.sh"
printf 'import sys\nopen(sys.argv[0] + ".log", "a").write(" ".join(sys.argv[1:]) + "\\n")\n' > "$WORK/notice.py"
export FLEET_PEER_HAND_TASK_CMD="$WORK/task.sh" FLEET_PEER_HAND_NOTICE_CMD="$WORK/notice.py"
st_tally

U=c7d372cf-903b-5229-8e55-3e286e9c026d
P="$U/598b0309-961d-4fde-b7d4-5440a0228155"
NOW=$(date +%s)
row() {  # <ts> <rid> <kind> <state> <via> [report json]
  python3 -c 'import json, sys
ts, rid, kind, st, via = sys.argv[1:6]
r = {"ts": int(ts), "rid": rid, "kind": kind, "to": sys.argv[7], "state": st, "via": via, "detail": "its machine is not in a fresh hub map"}
if sys.argv[6]:
    r["report"] = json.loads(sys.argv[6])
print(json.dumps(r))' "$1" "$2" "$3" "$4" "$5" "${6:-}" "$P" >> "$BOOK"
}
pq() { bash "$BIN/fleet-peer-queue.sh" "$@" -L "$L" 2>&1; }
last() { python3 -c 'import json, sys
st = ""
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["rid"] == sys.argv[2]:
        st = r["state"]
print(st)' "$BOOK" "$1"; }

# A — the sender's own QUEUED note carries the words (as fleet-report-parent.sh writes it)
R1="$U/verkyyi-claude-fleet:scratch-56#1792622849.1"
pq note --rid "$R1" --state QUEUED --to "$P" --kind report --via hub --detail 'its machine is not in a fresh hub map' \
  --report '{"child":"scratch-56","state":"MERGED","pr":"5150","summary":"做完了 · PR #5150","task":"T761","repo":"verkyyi/claude-fleet"}' >/dev/null
st_has "A: the QUEUED row keeps the report's words" "$(cat "$BOOK")" '"summary": "做完了 · PR #5150"'
pq note --rid "$R1" --state EXPIRED --to "$P" --kind child_report --via hub --detail 'no node took it within the relay TTL' >/dev/null
st_eq "A: the hub's EXPIRED receipt ends HANDED" "HANDED" "$(last "$R1")"
st_eq "A: …no EXPIRED row" "0" "$(grep -c '"state": "EXPIRED"' "$BOOK")"
st_eq "A: one reminder row" "1" "$(grep -c "$R1" "$ORPH")"
st_has "A: …the child's words in it" "$(cat "$ORPH")" '"summary": "做完了 · PR #5150"'
st_has "A: …its task" "$(cat "$ORPH")" '"task": "T761"'
st_has "A: …why" "$(cat "$ORPH")" 'relay TTL'
st_has "A: a note on its task record" "$(cat "$TASKLOG")" "set T761 --note 回报没送到上层"
st_has "A: one notice 「有 N 份回报没人收」" "$(cat "$NOTELOG")" "有 1 份回报没人收"
st_has "A: …the reminder reader lists it" "$(python3 "$BIN/fleet-orphan-reports.py" list)" "scratch-56"
o=$(pq wait --rid "$R1" --secs 0); rc=$?
st_eq "A: wait reads HANDED as not delivered" "1:HANDED" "$rc:$o"
pq note --rid "$R1" --state EXPIRED --to "$P" --kind child_report --via hub --detail 'again' >/dev/null
st_eq "A: a second receipt hands nothing more" "1" "$(grep -c "$R1" "$ORPH")"

# B — the one-day bound
row $((NOW - 200000)) rep-old report QUEUED hub '{"child":"issue-4431","state":"MERGED","summary":"done"}'
row $((NOW - 200000)) msg-old message QUEUED hub
o=$(pq stale)
st_has "B: stale hands the report" "$o" "handed 1 undeliverable report"
st_eq "B: …HANDED" "HANDED" "$(last rep-old)"
st_has "B: …the message still EXPIRED" "$(last msg-old)" "EXPIRED"
st_hasnt "B: …no dead-log line for the report" "$(cat "$DEADLOG" 2>/dev/null)" "rep-old"
st_eq "B: two reminder rows now" "2" "$(wc -l < "$ORPH" | tr -d ' ')"

# C — backfill
row $((NOW - 3000)) "$U/issue-4431#1792246664.1" report QUEUED hub
row $((NOW - 2000)) "$U/issue-4431#1792246664.1" report EXPIRED hub
row $((NOW - 40 * 86400)) ancient report EXPIRED hub
o=$(pq stale)
st_has "C: backfill hands an old EXPIRED report" "$o" "handed 1"
st_has "C: …its words were not kept, it says so" "$(grep 1792246664 "$ORPH")" "没留在本机"
st_has "C: …child from its rid" "$(grep 1792246664 "$ORPH")" '"child_key": "issue-4431"'
st_hasnt "C: …a report older than the reminder's window is left" "$(cat "$ORPH")" "ancient"
o=$(pq stale)
st_eq "C: a second stale hands nothing" "" "$o"

# D — the local queue
o=$(printf 'parent-gone envelope words' | pq put --to-fid 9f7c2a8e-1111-4222-8333-444455556666 --kind report --rid loc1 --to mine)
f=$(printf '%s\n' "$o" | tail -1)
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["created"] -= 9 * 86400; json.dump(d, open(sys.argv[1], "w"))' "$f"
pq drain >/dev/null
st_eq "D: an expired local report is HANDED" "HANDED" "$(last loc1)"
st_has "D: …its words off the queue file" "$(grep loc1 "$ORPH")" "parent-gone envelope words"

# E
pq note --rid nobody-knows --state EXPIRED --kind child_report --via hub --detail x >/dev/null
st_eq "E: an unknown rid stays EXPIRED" "EXPIRED" "$(last nobody-knows)"

st_done
