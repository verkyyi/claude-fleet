#!/bin/bash
# fleet-peer-queue.sh — what could not be delivered NOW waits here for its
# recipient, and the sender's book says so (issue #1647, EPIC #1645 C4).
#
#   fleet-peer-queue.sh put    -L <sess> (--to-fid <fleet_id> | --to-key <key>) --kind report|message
#                              --rid <id> [--to <label>] < text      → the queue file; a QUEUED row
#   fleet-peer-queue.sh drain  -L <sess> [--fid <fleet_id>]         → deliver what can go now
#   fleet-peer-queue.sh note   -L <sess> --rid <id> --state <S> [--to <label>] [--kind <k>]
#                              [--via local|hub] [--detail <text>]   → one row in the delivery book
#   fleet-peer-queue.sh wait   -L <sess> --rid <id> [--secs <n>]    → 0 DELIVERED · 1 FAILED/EXPIRED
#                                                                     · 3 nothing yet (prints the state)
#   fleet-peer-queue.sh status -L <sess>                            → one line per queued item
#   fleet-peer-queue.sh pending -L <sess> --to <label>              → how many sends to <label>
#                                                                     still read QUEUED (issue #3520:
#                                                                     the sender's 「第 N 条」)
#   fleet-peer-queue.sh stale  -L <sess> [--secs <n>]               → one ⌘P 消息 (fleet_notice,
#                                                                     kind alert) for the sends whose
#                                                                     last row has read QUEUED longer
#                                                                     than <n> (FLEET_PEER_QUEUE_ALERT_SECS,
#                                                                     60) — each send said once
#
# A child's report or a message whose recipient is on THIS machine but cannot take
# it right now — a window with no live Claude under it, an inbox that will not
# answer — used to be `not reported` on stderr and exit 0: the sender ended
# normally and nobody knew (EPIC #1645 ③④). Now it is QUEUED, addressed by the
# recipient's lifelong identity (@fleet_id, issue #1646) — never a key another
# window may answer to later — and delivered by `drain`: the cleanup daemon's tick
# (60 s) runs it. Delivery is the one path every report takes (children_send:
# the journaled delivery, the Codex queue, the peer inbox). A recipient that never comes back: after FLEET_PEER_QUEUE_TTL
# (7 days, the hub's relay TTL) the item is dropped and the book says EXPIRED.
#
# The DELIVERY BOOK, $FLEET_CONF_DIR/fleets/<sess>/delivery.ndjson, is the sender's
# record of what became of each queued send, local or through the hub:
#   {"ts", "rid", "kind", "to", "state": QUEUED|DELIVERED|FAILED|EXPIRED, "via", "detail"}
# Append-only; `rid` joins the rows of one send. The hub's receipts land here too
# (fleet-hub-node.sh deliver, kind `receipt`), which is what `wait` reads.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-peer-queue: %s\n' "$2" >&2; exit "$1"; }

ACT="${1:-}"; [ $# -gt 0 ] && shift
SESS='' FID='' TKEY='' KIND='' RID='' TO='' STATE='' VIA='' DETAIL='' SECS=4 SECS_SET=
while [ $# -gt 0 ]; do
  case "$1" in
    -L) SESS="${2:-}"; shift ;;
    --to-fid|--fid) FID="${2:-}"; shift ;;
    --to-key) TKEY="${2:-}"; shift ;;
    --kind) KIND="${2:-}"; shift ;;
    --rid) RID="${2:-}"; shift ;;
    --to) TO="${2:-}"; shift ;;
    --state) STATE="${2:-}"; shift ;;
    --via) VIA="${2:-}"; shift ;;
    --detail) DETAIL="${2:-}"; shift ;;
    --secs) SECS="${2:-}"; SECS_SET=1; shift ;;
    *) die 2 "unknown argument $1" ;;
  esac
  shift
done
[ -n "$SESS" ] || SESS=$(fleet_current_session 2>/dev/null)
[ -n "$SESS" ] || die 2 "no fleet (-L <sess>)"
case "$SECS" in ''|*[!0-9]*) SECS=4 ;; esac
DIR="$(fleet_state_dir "$SESS")"
Q="$DIR/peer-queue"
BOOK="$DIR/delivery.ndjson"
TTL="${FLEET_PEER_QUEUE_TTL:-604800}"; case "$TTL" in ''|*[!0-9]*) TTL=604800 ;; esac

# note <rid> <state> <to> <kind> <via> <detail> — one row, one write (O_APPEND).
note() {
  python3 - "$BOOK" "$@" <<'PY' 2>/dev/null
import json, sys, time
book, rid, state, to, kind, via, detail = sys.argv[1:8]
row = {"ts": int(time.time()), "rid": rid, "kind": kind, "to": to, "state": state.upper(), "via": via}
if detail:
    row["detail"] = " ".join(detail.split())[:300]
with open(book, "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
PY
}

case "$ACT" in
  put)
    [ -n "$RID" ] || die 2 "put needs --rid"
    case "$KIND" in report|message) ;; *) die 2 "put needs --kind report|message" ;; esac
    if [ -n "$FID" ]; then fleet_is_fid "$FID" || die 2 "--to-fid '$FID' is not a fleet_id"; fi
    [ -n "$FID$TKEY" ] || die 2 "put needs --to-fid or --to-key"
    text=$(cat); [ -n "$text" ] || die 2 "empty message"
    mkdir -p "$Q" 2>/dev/null || die 1 "cannot create $Q"
    tmp=$(mktemp "$Q/.put.XXXXXX") || die 1 "cannot write in $Q"
    printf '%s' "$text" | python3 -c 'import json, sys, time
rid, kind, fid, key, to = sys.argv[1:6]
print(json.dumps({"rid": rid, "kind": kind, "to_fid": fid, "to_key": key, "to": to,
                  "created": int(time.time()), "text": sys.stdin.read()}, ensure_ascii=False))' \
      "$RID" "$KIND" "$FID" "$TKEY" "${TO:-${TKEY:-$FID}}" > "$tmp" 2>/dev/null || { rm -f "$tmp"; die 1 "cannot encode the item"; }
    f="$Q/$(date -u +%Y%m%dT%H%M%SZ)-$$-${tmp##*.}.json"
    mv -f "$tmp" "$f" || { rm -f "$tmp"; die 1 "cannot write in $Q"; }
    note "$RID" QUEUED "${TO:-${TKEY:-$FID}}" "$KIND" local ''
    printf '%s\n' "$f"
    exit 0 ;;

  note)
    [ -n "$RID" ] && [ -n "$STATE" ] || die 2 "note needs --rid and --state"
    note "$RID" "$STATE" "$TO" "$KIND" "${VIA:-local}" "$DETAIL" || die 1 "cannot write $BOOK"
    exit 0 ;;

  wait)
    [ -n "$RID" ] || die 2 "wait needs --rid"
    # ONE interpreter polls the book every 0.2 s up to a real deadline (issue T756:
    # a python start per poll on a loaded machine stretched «4 s» to 20+, and a
    # loop counted in polls, not seconds, is no bound at all). --secs 0 = one look.
    python3 - "$BOOK" "$RID" "$SECS" <<'PY' 2>/dev/null
import json, sys, time
book, rid, secs = sys.argv[1], sys.argv[2], int(sys.argv[3])
end = time.monotonic() + secs
while True:
    st = ""
    try:
        for line in open(book, encoding="utf-8"):
            if rid not in line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("rid") == rid and r.get("state") != "QUEUED":
                st = r.get("state", "")
    except OSError:
        pass
    if st == "DELIVERED":
        print(st); sys.exit(0)
    if st in ("FAILED", "EXPIRED"):
        print(st); sys.exit(1)
    if time.monotonic() >= end:
        print("QUEUED"); sys.exit(3)
    time.sleep(0.2)
PY
    rc=$?
    case "$rc" in 0|1|3) exit "$rc" ;; *) echo QUEUED; exit 3 ;; esac ;;

  status)
    [ -d "$Q" ] || exit 0
    for f in "$Q"/*.json; do
      [ -f "$f" ] || continue
      python3 -c 'import json, sys, time
d = json.load(open(sys.argv[1], encoding="utf-8"))
print("%s\t%s → %s\tqueued %dm ago" % (d.get("rid", "?"), d.get("kind", "?"), d.get("to", "?"), (time.time() - d.get("created", 0)) // 60))' "$f" 2>/dev/null
    done
    exit 0 ;;

  pending)
    # Every send to --to whose LAST row is QUEUED and younger than the TTL — the
    # queue that send joined, counted from the book (local and hub alike).
    [ -n "$TO" ] || die 2 "pending needs --to"
    python3 - "$BOOK" "$TO" "$TTL" <<'PY' 2>/dev/null || echo 0
import json, sys, time
last = {}
try:
    for line in open(sys.argv[1], encoding="utf-8"):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("to") == sys.argv[2] and r.get("rid"):
            # settled once ANY row says so (a receipt may precede the QUEUED note)
            if r.get("state") != "QUEUED" or last.get(r["rid"], {}).get("state", "QUEUED") == "QUEUED":
                last[r["rid"]] = r
except OSError:
    pass
cut = time.time() - int(sys.argv[3])
print(sum(1 for r in last.values() if r.get("state") == "QUEUED" and (r.get("ts") or 0) >= cut))
PY
    exit 0 ;;

  stale)
    # A send that stays QUEUED is SAID (issue T756): the sender's one line is easy to
    # miss and a cross-machine report sat «queued» with nobody told. The cleanup tick
    # runs this for every fleet with a book; each rid is said once
    # (delivery.alerted beside the book), one notice per tick for all of them.
    [ -f "$BOOK" ] || exit 0
    _as="${FLEET_PEER_QUEUE_ALERT_SECS:-60}"; case "$_as" in ''|*[!0-9]*) _as=60 ;; esac
    [ -n "$SECS_SET" ] && _as=$SECS
    [ "$_as" -gt 0 ] || exit 0
    python3 - "$BOOK" "$DIR/delivery.alerted" "$_as" "$TTL" "$BIN" <<'PY'
import json, subprocess, sys, time
book, alerted, secs, ttl, bindir = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
last = {}
try:
    for line in open(book, encoding="utf-8"):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("rid"):
            # settled once ANY row says so: the hub's receipt can land before the
            # sender's own QUEUED note (its wait gave up a moment too early)
            if r.get("state") != "QUEUED" or last.get(r["rid"], {}).get("state", "QUEUED") == "QUEUED":
                last[r["rid"]] = r
except OSError:
    sys.exit(0)
try:
    done = set(open(alerted, encoding="utf-8").read().split())
except OSError:
    done = set()
now = time.time()
hits = [r for rid, r in last.items() if r.get("state") == "QUEUED" and rid not in done
        and secs <= now - (r.get("ts") or now) <= ttl]
if not hits:
    sys.exit(0)
def who(r):
    t = str(r.get("to") or "?")
    t = t.split("/", 1)[-1] if "/" in t else t
    return t[:8] if len(t) == 36 else t[:40]
kinds = sorted({"回报" if r.get("kind") in ("report", "child_report") else "消息" for r in hits})
oldest = max(int(now - (r.get("ts") or now)) for r in hits)
text = "%d 条%s排队 %d 秒还没送达：→ %s" % (len(hits), "/".join(kinds), oldest,
                                     "、".join(sorted({who(r) for r in hits}))[:160])
detail = sorted({str(r.get("detail") or "") for r in hits} - {""})
nxt = (detail[0] + " · " if detail else "") + "对方能收时自动补送；fleet-peer-queue.sh status 看队列"
rc = subprocess.run(["python3", bindir + "/fleet_notice.py", "notify", "warn", text, "--next", nxt,
                     "--kind", "alert", "--source", "peer-queue", "--tag", "peerq-stale", "--no-draw"],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    timeout=20).returncode
if rc == 0:
    with open(alerted, "a", encoding="utf-8") as f:
        f.write("".join(r["rid"] + "\n" for r in hits))
    print("peer-queue: said %d queued send(s) older than %ds" % (len(hits), secs))
PY
    exit 0 ;;

  drain) ;;
  *) die 2 "usage: fleet-peer-queue.sh put|drain|note|wait|status|pending|stale -L <sess> …" ;;
esac

# --- drain -------------------------------------------------------------------------
[ -d "$Q" ] || exit 0
# shellcheck source=/dev/null
. "$BIN/fleet-children-lib.sh"
sock=$(fleet_socket "$SESS")
now=$(date +%s)
sent=0 expired=0 waiting=0
# A claim a crashed drain left behind goes back in the queue after 10 minutes.
find "$Q" -maxdepth 1 -name '*.json.sending' -mmin +10 2>/dev/null | while IFS= read -r c; do mv -f "$c" "${c%.sending}"; done
for f in "$Q"/*.json; do
  [ -f "$f" ] || continue
  # Claim it: a rename is atomic, so two drains (the tick and a wake) never
  # deliver one item twice.
  c="$f.sending"
  mv "$f" "$c" 2>/dev/null || continue
  meta=$(python3 -c 'import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print("\x1f".join(str(d.get(k, "")).replace("\x1f", " ").replace("\n", " ") for k in ("rid", "kind", "to_fid", "to_key", "to", "created")))' "$c" 2>/dev/null) \
    || { mv -f "$c" "$Q/bad-$(basename "$f")" 2>/dev/null; continue; }
  # \037, not a tab: tab is IFS whitespace, and an empty field would collapse.
  IFS=$'\037' read -r rid kind fid key to created <<EOF
$meta
EOF
  [ -n "$FID" ] && [ "$fid" != "$FID" ] && { mv -f "$c" "$f"; continue; }
  case "$created" in ''|*[!0-9]*) created=0 ;; esac
  if [ $((now - created)) -gt "$TTL" ]; then
    rm -f "$c"; note "$rid" EXPIRED "$to" "$kind" local "the recipient took nothing for $((TTL / 86400)) days"
    expired=$((expired + 1)); continue
  fi
  # The recipient by IDENTITY when the item names one — never the key's current
  # holder, which may be someone else by now; a key only for a recipient that had
  # no identity when it was queued.
  if [ -n "$fid" ]; then w=$(fleet_win_for_fid "$fid" "$sock" 2>/dev/null) || w=''
  else w=$(fleet_win_for_key "$key" "$sock" 2>/dev/null) || w=''; fi
  if [ -z "$w" ]; then mv -f "$c" "$f"; waiting=$((waiting + 1)); continue; fi
  text=$(python3 -c 'import json, sys; sys.stdout.write(json.load(open(sys.argv[1], encoding="utf-8"))["text"])' "$c" 2>/dev/null)
  from=fleet-report; [ "$kind" = message ] && from=fleet-peer
  FLEET_REPORT_FROM="$from" children_send "$SESS" "$sock" "$w" "$text"; rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$c"
    note "$rid" DELIVERED "$to" "$kind" local ""
    [ "$kind" = report ] && { _pk=$(fleet_window_okey "$SESS" "$w" 2>/dev/null) && [ -n "$_pk" ] && children_cursor_set "$_pk" "$SESS"; }
    sent=$((sent + 1))
  else
    mv -f "$c" "$f"; waiting=$((waiting + 1))
  fi
done
[ $((sent + expired)) -gt 0 ] && printf 'peer-queue: delivered %d · expired %d · waiting %d\n' "$sent" "$expired" "$waiting"
exit 0
