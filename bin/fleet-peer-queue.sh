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
#
# A child's report or a message whose recipient is on THIS machine but cannot take
# it right now — a window with no live Claude under it, an inbox that will not
# answer — used to be `not reported` on stderr and exit 0: the sender ended
# normally and nobody knew (EPIC #1645 ③④). Now it is QUEUED, addressed by the
# recipient's lifelong identity (@fleet_id, issue #1646) — never a key another
# window may answer to later — and delivered by `drain`: the cleanup daemon's tick
# (60 s) and a sleeper's wake (fleet-sleep.py) run it. Delivery is the one path
# every report takes (children_send: wake-delivery for a sleeper, the Codex queue,
# the peer inbox). A recipient that never comes back: after FLEET_PEER_QUEUE_TTL
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
SESS='' FID='' TKEY='' KIND='' RID='' TO='' STATE='' VIA='' DETAIL='' SECS=4
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
    --secs) SECS="${2:-}"; shift ;;
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
    i=0
    while :; do
      st=$(python3 - "$BOOK" "$RID" <<'PY' 2>/dev/null
import json, sys
st = ""
try:
    for line in open(sys.argv[1], encoding="utf-8"):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("rid") == sys.argv[2] and r.get("state") != "QUEUED":
            st = r.get("state", "")
except OSError:
    pass
print(st)
PY
)
      case "$st" in
        DELIVERED) echo DELIVERED; exit 0 ;;
        FAILED|EXPIRED) echo "$st"; exit 1 ;;
      esac
      [ "$i" -ge $((SECS * 5)) ] && { echo QUEUED; exit 3; }
      sleep 0.2; i=$((i + 1))
    done ;;

  status)
    [ -d "$Q" ] || exit 0
    for f in "$Q"/*.json; do
      [ -f "$f" ] || continue
      python3 -c 'import json, sys, time
d = json.load(open(sys.argv[1], encoding="utf-8"))
print("%s\t%s → %s\tqueued %dm ago" % (d.get("rid", "?"), d.get("kind", "?"), d.get("to", "?"), (time.time() - d.get("created", 0)) // 60))' "$f" 2>/dev/null
    done
    exit 0 ;;

  drain) ;;
  *) die 2 "usage: fleet-peer-queue.sh put|drain|note|wait|status -L <sess> …" ;;
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
  # 3 = a sleeper at a full fleet: fleet-sleep holds it now and delivers when a
  # slot frees — handed over, so it leaves this queue.
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
    rm -f "$c"
    _d=''; [ "$rc" -eq 3 ] && _d='held by the sleeper until a slot frees'
    note "$rid" DELIVERED "$to" "$kind" local "$_d"
    [ "$kind" = report ] && { _pk=$(fleet_window_okey "$SESS" "$w" 2>/dev/null) && [ -n "$_pk" ] && children_cursor_set "$_pk" "$SESS"; }
    sent=$((sent + 1))
  else
    mv -f "$c" "$f"; waiting=$((waiting + 1))
  fi
done
[ $((sent + expired)) -gt 0 ] && printf 'peer-queue: delivered %d · expired %d · waiting %d\n' "$sent" "$expired" "$waiting"
exit 0
