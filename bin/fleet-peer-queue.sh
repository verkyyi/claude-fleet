#!/bin/bash
# fleet-peer-queue.sh — what could not be delivered NOW waits here for its
# recipient, and the sender's book says so (issue #1647, EPIC #1645 C4).
#
#   fleet-peer-queue.sh put    -L <sess> (--to-fid <fleet_id> | --to-key <key>) --kind report|message
#                              --rid <id> [--to <label>] < text      → the queue file; a QUEUED row
#   fleet-peer-queue.sh drain  -L <sess> [--fid <fleet_id>]         → deliver what can go now
#   fleet-peer-queue.sh note   -L <sess> --rid <id> --state <S> [--to <label>] [--kind <k>]
#                              [--via local|hub] [--detail <text>]   → one row in the delivery book
#   fleet-peer-queue.sh wait   -L <sess> --rid <id> [--secs <n>]    → 0 DELIVERED · 1 FAILED/EXPIRED/HANDED
#                                                                     · 3 nothing yet (prints the state)
#   fleet-peer-queue.sh status -L <sess>                            → one line per queued item: the
#                                                                     local queue AND every hub-relayed
#                                                                     send whose last row reads QUEUED
#                                                                     (those live only in the book)
#   fleet-peer-queue.sh pending -L <sess> --to <label>              → how many sends to <label>
#                                                                     still read QUEUED (issue #3520:
#                                                                     the sender's 「第 N 条」)
#   fleet-peer-queue.sh stale  -L <sess> [--secs <n>]               → one ⌘P 消息 (fleet_notice,
#                                                                     kind alert) for the sends whose
#                                                                     last row has read QUEUED longer
#                                                                     than <n> (FLEET_PEER_QUEUE_ALERT_SECS,
#                                                                     60) — each send said once; a
#                                                                     hub-relayed send QUEUED longer than
#                                                                     FLEET_PEER_QUEUE_DEAD_SECS (86400)
#                                                                     is undeliverable: EXPIRED in the book,
#                                                                     one line in logs/peer-queue-dead.log,
#                                                                     never said (again) — a REPORT is
#                                                                     HANDED to the person instead (T887,
#                                                                     bin/fleet-peer-hand.py)
#
# A child's report or a message whose recipient is on THIS machine but cannot take
# it right now — a window with no live Claude under it, an inbox that will not
# answer — used to be `not reported` on stderr and exit 0: the sender ended
# normally and nobody knew (EPIC #1645 ③④). Now it is QUEUED, addressed by the
# recipient's lifelong identity (@fleet_id, issue #1646) — never a key another
# window may answer to later — and delivered by `drain`: the cleanup daemon's tick
# (60 s) runs it. Delivery is the one path every report takes (children_send:
# the journaled delivery, the Codex queue, the peer inbox). A recipient that never comes back: after FLEET_PEER_QUEUE_TTL
# (7 days, the hub's relay TTL) the item is dropped and the book says EXPIRED — a
# report is HANDED to the person instead (T887): the reminder (global/orphan-reports.ndjson,
# ⌘P 消息), a note on its task record, one notice 「有 N 份回报没人收」. Never quietly gone.
#
# The DELIVERY BOOK, $FLEET_CONF_DIR/fleets/<sess>/delivery.ndjson, is the sender's
# record of what became of each queued send, local or through the hub:
#   {"ts", "rid", "kind", "to", "state": QUEUED|DELIVERED|FAILED|EXPIRED|HANDED, "via", "detail"[, "report"]}
# Append-only; `rid` joins the rows of one send. The hub's receipts land here too
# (fleet-hub-node.sh deliver, kind `receipt`), which is what `wait` reads.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-peer-queue: %s\n' "$2" >&2; exit "$1"; }

ACT="${1:-}"; [ $# -gt 0 ] && shift
SESS='' FID='' TKEY='' KIND='' RID='' TO='' STATE='' VIA='' DETAIL='' REPORT='' DELEGATION='' SECS=4 SECS_SET=
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
    --report) REPORT="${2:-}"; shift ;;
    --delegation) DELEGATION="${2:-}"; shift ;;
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
# A send relayed through the hub that nobody took in a day is undeliverable (T761):
# its recipient's ID closed, or its machine left the hub's map — the 2026-10-20
# book on a managed Mac kept four 6-day-old sends to sessions of a machine the hub no longer
# listed, «对方能收时自动补送» forever. 0 = never.
DEAD="${FLEET_PEER_QUEUE_DEAD_SECS:-86400}"; case "$DEAD" in ''|*[!0-9]*) DEAD=86400 ;; esac
DEADLOG="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/logs/peer-queue-dead.log"

# note <rid> <state> <to> <kind> <via> <detail> [<report json>] — one row, one write
# (O_APPEND). A report's words ride its QUEUED row (`report`, T887): what the person
# is handed if nobody ever takes it (bin/fleet-peer-hand.py).
note() {
  python3 - "$BOOK" "$@" <<'PY' 2>/dev/null
import json, sys, time
book, rid, state, to, kind, via, detail = sys.argv[1:8]
row = {"ts": int(time.time()), "rid": rid, "kind": kind, "to": to, "state": state.upper(), "via": via}
if detail:
    row["detail"] = " ".join(detail.split())[:300]
if len(sys.argv) > 8 and sys.argv[8]:
    try:
        rep = json.loads(sys.argv[8])
    except ValueError:
        rep = None
    if isinstance(rep, dict):
        row["report"] = {k: (v[:2000] if isinstance(v, str) else v) for k, v in rep.items()
                         if k in ("child", "state", "pr", "summary", "title", "repo", "task")}
with open(book, "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
PY
}

# hand <rid>... — a report nobody will take goes to the person (T887): the reminder,
# its task record, one HANDED row. Prints `handed N`; nothing printed = not a report
# this book knows (the caller writes its EXPIRED as before).
hand() {
  local a=() r
  for r in "$@"; do a+=(--rid "$r"); done
  python3 "$BIN/fleet-peer-hand.py" hand --book "$BOOK" ${a[@]+"${a[@]}"} ${DETAIL:+--why "$DETAIL"} 2>/dev/null
}

case "$ACT" in
  put)
    [ -n "$RID" ] || die 2 "put needs --rid"
    case "$KIND" in report|message|delegated_report) ;; *) die 2 "put needs --kind report|message" ;; esac
    if [ -n "$FID" ]; then fleet_is_fid "$FID" || die 2 "--to-fid '$FID' is not a fleet_id"; fi
    [ -n "$FID$TKEY" ] || die 2 "put needs --to-fid or --to-key"
    if [ "$KIND" = delegated_report ]; then
      [ -n "$DELEGATION" ] || die 2 'delegated_report needs --delegation'
      _existing=$(python3 - "$BOOK" "$RID" <<'PYDONE'
import json, sys
try:
    rows = [json.loads(line) for line in open(sys.argv[1])]
except FileNotFoundError:
    rows = []
print(int(any(r.get('rid') == sys.argv[2] and r.get('state') == 'DELIVERED' for r in rows)))
PYDONE
) || die 1 'cannot read delivery receipts'
      [ "$_existing" = 1 ] && { printf 'delivered\n'; exit 0; }
    fi
    text=$(cat); [ -n "$text" ] || die 2 "empty message"
    mkdir -p "$Q" 2>/dev/null || die 1 "cannot create $Q"
    tmp=$(mktemp "$Q/.put.XXXXXX") || die 1 "cannot write in $Q"
    printf '%s' "$text" | python3 -c 'import json, sys, time
rid, kind, fid, key, to, delegation = sys.argv[1:7]
print(json.dumps({"rid": rid, "kind": kind, "to_fid": fid, "to_key": key, "to": to,
                  "created": int(time.time()), "text": sys.stdin.read(),
                  **({"delegation": json.loads(delegation)} if delegation else {})}, ensure_ascii=False))' \
      "$RID" "$KIND" "$FID" "$TKEY" "${TO:-${TKEY:-$FID}}" "$DELEGATION" > "$tmp" 2>/dev/null || { rm -f "$tmp"; die 1 "cannot encode the item"; }
    f="$Q/$(date -u +%Y%m%dT%H%M%SZ)-$$-${tmp##*.}.json"
    if [ "$KIND" = delegated_report ]; then
      _hash=$(printf '%s' "$RID" | shasum -a 256 | cut -d ' ' -f 1)
      f="$Q/delegated-$_hash.json"
      # Link is create-if-absent: concurrent replay never replaces a pending item.
      if [ -f "$f.sending" ] || ! ln "$tmp" "$f" 2>/dev/null; then
        rm -f "$tmp"; printf '%s\n' "$f"; exit 0
      fi
      rm -f "$tmp"
    else
      mv -f "$tmp" "$f" || { rm -f "$tmp"; die 1 "cannot write in $Q"; }
    fi
    _rep=''
    [ "$KIND" = report ] && _rep=$(printf '%s' "$text" | python3 -c 'import json, sys; print(json.dumps({"summary": sys.stdin.read()[:2000]}, ensure_ascii=False))' 2>/dev/null)
    note "$RID" QUEUED "${TO:-${TKEY:-$FID}}" "$KIND" local '' "$_rep"
    printf '%s\n' "$f"
    exit 0 ;;

  note)
    [ -n "$RID" ] && [ -n "$STATE" ] || die 2 "note needs --rid and --state"
    # A delegated report retains its queue policy when a hub receipt arrives.
    # Receipt kind is child_report on the wire; the producer's book owns policy.
    if python3 - "$BOOK" "$RID" <<'PYKIND'
import json, sys
try:
    found = any((r.get('rid') == sys.argv[2] and r.get('kind') == 'delegated_report')
                for r in (json.loads(line) for line in open(sys.argv[1])))
except FileNotFoundError:
    found = False
sys.exit(0 if found else 1)
PYKIND
    then KIND=delegated_report; fi
    # The hub's EXPIRED receipt for a report (its relay TTL ran out): the person is
    # handed it instead (T887) — HANDED is its last row, never EXPIRED.
    case "$(printf '%s' "$STATE" | tr '[:lower:]' '[:upper:]'):$KIND" in
      EXPIRED:report|EXPIRED:child_report)
        [ -n "$(hand "$RID")" ] && exit 0 ;;
    esac
    note "$RID" "$STATE" "$TO" "$KIND" "${VIA:-local}" "$DETAIL" "$REPORT" || die 1 "cannot write $BOOK"
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
    if st in ("FAILED", "EXPIRED", "HANDED"):
        print(st); sys.exit(1)
    if time.monotonic() >= end:
        print("QUEUED"); sys.exit(3)
    time.sleep(0.2)
PY
    rc=$?
    case "$rc" in 0|1|3) exit "$rc" ;; *) echo QUEUED; exit 3 ;; esac ;;

  status)
    # The local queue, then every hub-relayed send still QUEUED in the book (T761: a
    # cross-machine send has no queue file, so `status` listed nothing for it).
    if [ -d "$Q" ]; then
      for f in "$Q"/*.json; do
        [ -f "$f" ] || continue
        python3 -c 'import json, sys, time
d = json.load(open(sys.argv[1], encoding="utf-8"))
print("%s\t%s → %s\tqueued %dm ago" % (d.get("rid", "?"), d.get("kind", "?"), d.get("to", "?"), (time.time() - d.get("created", 0)) // 60))' "$f" 2>/dev/null
      done
    fi
    [ -f "$BOOK" ] || exit 0
    python3 - "$BOOK" "$TTL" <<'PY' 2>/dev/null
import json, sys, time
last, first = {}, {}
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if r.get("rid") and (r.get("state") != "QUEUED" or last.get(r["rid"], {}).get("state", "QUEUED") == "QUEUED"):
        last[r["rid"]] = r
    if r.get("rid") and r.get("state") == "QUEUED":     # its age counts from the first QUEUED row
        first.setdefault(r["rid"], r.get("ts") or 0)
now = time.time()
for rid, r in last.items():
    age = now - (first.get(rid) or r.get("ts") or now)
    if r.get("state") == "QUEUED" and r.get("via") != "local" and age <= int(sys.argv[2]):
        print("%s\t%s → %s\tqueued %dm ago · via %s%s" % (rid, r.get("kind", "?"), r.get("to", "?"), age // 60,
              r.get("via") or "?", (" · " + r["detail"]) if r.get("detail") else ""))
PY
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
    python3 - "$BOOK" "$DIR/delivery.alerted" "$_as" "$TTL" "$BIN" "$DEAD" "$DEADLOG" <<'PY'
import json, os, subprocess, sys, time
book, alerted, secs, ttl, bindir = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
dead_secs, deadlog = int(sys.argv[6]), sys.argv[7]
last, first = {}, {}
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
            if r.get("state") == "QUEUED":        # a send's age counts from its first QUEUED row
                first.setdefault(r["rid"], r.get("ts") or 0)
except OSError:
    sys.exit(0)
try:
    done = set(open(alerted, encoding="utf-8").read().split())
except OSError:
    done = set()
now = time.time()
def since(r):
    return now - (first.get(r["rid"]) or r.get("ts") or now)
# Undeliverable first (T761): a hub-relayed send nobody took in DEAD seconds is
# EXPIRED in the book with one audit line, and never said — the local queue's
# items stay the drain's (their window may still come back).
dead = [r for rid, r in last.items() if dead_secs > 0 and r.get("state") == "QUEUED"
        and r.get("via") != "local" and since(r) > dead_secs and r.get("kind") != "delegated_report"]
# A REPORT nobody took is the person's (T887): handed (the reminder, its task
# record, a HANDED row) — never EXPIRED. Then every report an older version let
# expire within the reminder's window, once.
gone = [r for r in dead if r.get("kind") in ("report", "child_report")]
dead = [r for r in dead if r not in gone]
hand_runs = [[]]
if gone:
    hand_runs.insert(0, [a for r in gone for a in ("--rid", r["rid"])]
                     + ["--why", "nobody took it in %dh" % (dead_secs // 3600)])
for args in hand_runs:
    try:
        out = subprocess.run(["python3", bindir + "/fleet-peer-hand.py", "hand", "--book", book] + args,
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             universal_newlines=True, timeout=120).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        out = ""
    if out:
        print("peer-queue: " + out + " undeliverable report(s) to the person")
done.update(r["rid"] for r in gone)
if dead:
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    with open(book, "a", encoding="utf-8") as f:
        for r in dead:
            f.write(json.dumps({"ts": int(now), "rid": r["rid"], "kind": r.get("kind", ""), "to": r.get("to", ""),
                                "state": "EXPIRED", "via": r.get("via", ""),
                                "detail": "undeliverable: nobody took it in %dh (%s)" % (
                                    since(r) // 3600, r.get("detail") or "no receipt")},
                               ensure_ascii=False) + "\n")
    try:
        os.makedirs(os.path.dirname(deadlog), exist_ok=True)
        with open(deadlog, "a", encoding="utf-8") as f:
            for r in dead:
                f.write("%s dropped %s %s → %s queued %ds via %s: %s\n" % (
                    stamp, r["rid"], r.get("kind", "?"), r.get("to", "?"), int(since(r)),
                    r.get("via") or "?", " ".join(str(r.get("detail") or "no receipt").split())[:200]))
    except OSError:
        pass
    print("peer-queue: dropped %d undeliverable send(s) older than %ds" % (len(dead), dead_secs))
    done.update(r["rid"] for r in dead)
bound = min(ttl, dead_secs) if dead_secs > 0 else ttl
hits = [r for rid, r in last.items() if r.get("state") == "QUEUED" and rid not in done
        and secs <= since(r) <= bound and r.get("kind") != "delegated_report"]
if not hits:
    sys.exit(0)
def who(r):
    t = str(r.get("to") or "?")
    if t.startswith("/"):                                 # a path-shaped key: its last part
        t = t.rstrip("/").rsplit("/", 1)[-1] or t
    elif "/" in t and len(t.split("/", 1)[0]) == 36:      # <fleet UUID>/<fleet_id|key>
        t = t.split("/", 1)[1]
    return t[:8] if len(t) == 36 else t[:40]
kinds = sorted({"回报" if r.get("kind") in ("report", "child_report") else "消息" for r in hits})
oldest = max(int(since(r)) for r in hits)
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
  if [ "$kind" = delegated_report ]; then
    bash "$BIN/fleet-report-delivery.sh" drain "$c" "$SESS"; _rc=$?
    if [ "$_rc" = 0 ]; then
      if note "$rid" DELIVERED "$to" "$kind" local ''; then
        rm -f "$c"; sent=$((sent + 1))
      else
        mv -f "$c" "$f"; waiting=$((waiting + 1))
      fi
    else
      mv -f "$c" "$f"; waiting=$((waiting + 1))
    fi
    continue
  fi
  case "$created" in ''|*[!0-9]*) created=0 ;; esac
  if [ $((now - created)) -gt "$TTL" ]; then
    rm -f "$c"
    _w="the recipient took nothing for $((TTL / 86400)) days"
    if [ "$kind" != report ] || [ -z "$(DETAIL="$_w" hand "$rid")" ]; then note "$rid" EXPIRED "$to" "$kind" local "$_w"; fi
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
  FLEET_REPORT_FROM="$from" children_send "$SESS" "$sock" "$w" "$text" "$rid"; rc=$?
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
