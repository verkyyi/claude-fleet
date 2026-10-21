#!/bin/bash
# peer-queue-dead-selftest.sh — a send nobody can take is called undeliverable once,
# and said at most once (claude-fleet T761). bin/fleet-peer-queue.sh on a sandbox
# delivery book (no tmux: `status` and `stale` read only the book and the queue dir):
#   A  `status` lists a hub-relayed send still QUEUED in the book (it has no queue
#      file — `status` used to print nothing for it), its age from the FIRST QUEUED row
#   B  `stale`: a hub-relayed send QUEUED past FLEET_PEER_QUEUE_DEAD_SECS gets one
#      EXPIRED row, one line in logs/peer-queue-dead.log, and no ⌘P 消息; a fresh
#      one is said once, its recipient label readable (a path-shaped key: its last
#      part); a local item of the same age stays the drain's (not dropped)
#   C  a second `stale` says nothing and drops nothing; `status` no longer lists
#      the dropped send
#   D  FLEET_PEER_QUEUE_DEAD_SECS=0: nothing is dropped (the old 7-day TTL alone)
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pq-dead.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
L=pqd
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf"
unset TMUX TMUX_PANE FLEET_PEER_QUEUE_TTL FLEET_PEER_QUEUE_DEAD_SECS FLEET_PEER_QUEUE_ALERT_SECS
D="$FLEET_CONF_DIR/fleets/$L"; mkdir -p "$D"
BOOK="$D/delivery.ndjson" NOTICES="$FLEET_CONF_DIR/logs/notices.ndjson" DEADLOG="$FLEET_CONF_DIR/logs/peer-queue-dead.log"
st_tally

U=c7d372cf-903b-5229-8e55-3e286e9c026d
NOW=$(date +%s)
row() {  # <ts> <rid> <to> <via> <detail>
  python3 -c 'import json, sys
ts, rid, to, via, det = sys.argv[1:6]
print(json.dumps({"ts": int(ts), "rid": rid, "kind": "report", "to": to, "state": "QUEUED", "via": via, "detail": det}))' "$@" >> "$BOOK"
}
pq() { bash "$BIN/fleet-peer-queue.sh" "$@" -L "$L" 2>&1; }

# a 6-day-old cross-machine send (two QUEUED rows: the age is the first's)
row $((NOW - 549143)) old-hub "$U/19b782dd-e2a1-4ef7-ba21-8fec6a707553" hub 'its machine is not in a fresh hub map'
row $((NOW - 3600))   old-hub "$U/19b782dd-e2a1-4ef7-ba21-8fec6a707553" hub 'not delivered yet'
# a fresh one to a path-shaped key
row $((NOW - 120))    new-hub "/Users/x/projects/claude-fleet-scratch-61" hub 'not delivered yet'
# a local one of the same age as the old hub send: the drain's business
row $((NOW - 549143)) old-local "$U/73726595-86b9-4ef0-a1c7-7b3ad515a4a0" local ''

# A
s=$(pq status)
st_has "A: status lists the hub-relayed send" "$s" "old-hub"
st_has "A: …its age from the first QUEUED row" "$(printf '%s\n' "$s" | grep old-hub)" "queued 9152m ago · via hub"
st_has "A: …and the fresh one" "$s" "new-hub"
st_hasnt "A: a local book row is not listed twice (its queue file is)" "$s" "old-local"

# B
o=$(pq stale)
st_has "B: stale drops the undeliverable send" "$o" "dropped 1 undeliverable"
st_eq "B: one EXPIRED row for it" "1" "$(grep -c '"rid": "old-hub".*"state": "EXPIRED"' "$BOOK")"
st_has "B: …saying why" "$(grep '"state": "EXPIRED"' "$BOOK")" "undeliverable: nobody took it in 152h"
st_eq "B: one audit line" "1" "$(grep -c 'dropped old-hub report' "$DEADLOG" 2>/dev/null)"
st_hasnt "B: the local item is not dropped by stale" "$(cat "$DEADLOG")" "old-local"
n=$(grep -c '"source":"peer-queue"' "$NOTICES" 2>/dev/null)
st_eq "B: one ⌘P 消息 — for the fresh send only" "1" "$n"
st_hasnt "B: …not naming the dropped one" "$(grep peer-queue "$NOTICES")" "19b782dd"
st_has "B: …its recipient label readable" "$(grep peer-queue "$NOTICES")" "→ claude-fleet-scratch-61"

# C
o=$(pq stale)
st_eq "C: a second stale says nothing" "" "$o"
st_eq "C: …no new ⌘P 消息" "1" "$(grep -c '"source":"peer-queue"' "$NOTICES")"
st_eq "C: …no new audit line" "1" "$(wc -l < "$DEADLOG" | tr -d ' ')"
st_hasnt "C: status no longer lists the dropped send" "$(pq status)" "old-hub"

# D
row $((NOW - 200000)) older-hub "$U/b9b8faf4-f65d-4be7-af01-bd35f168e279" hub ''
o=$(FLEET_PEER_QUEUE_DEAD_SECS=0 pq stale)
st_hasnt "D: DEAD_SECS=0 drops nothing" "$o" "dropped"
st_eq "D: …no EXPIRED row" "0" "$(grep -c '"rid": "older-hub".*"EXPIRED"' "$BOOK")"
o=$(pq stale)
st_has "D: the default drops it" "$o" "dropped 1"

st_done
