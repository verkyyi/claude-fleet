#!/usr/bin/env python3
"""fleet-peer-hand.py — a report nobody took goes to the PERSON, never quietly away
(T887, card B of the error-research page; after issue #3117 and T761).

A child's report relayed through the hub waits for its parent's machine; when the
parent never comes back — the hub's relay TTL ran out (a receipt `EXPIRED`), the
sender's one-day bound passed (fleet-peer-queue.sh stale, T761), or a local queue
item outlived FLEET_PEER_QUEUE_TTL — it used to end as one EXPIRED row in the
sender's delivery book, which nobody reads. Now it ends HANDED:

  * one row in $FLEET_CONF_DIR/global/orphan-reports.ndjson — the person's reminder,
    the same book fleet-report-parent.sh's orphan() writes (read by
    bin/fleet-orphan-reports.py, listed in ⌘P's 消息), carrying `rid` and
    `via: undelivered`; never twice for one rid
  * the report's task record, when it names one: one `--note` on it
    (fleet-task-record.sh set <task> --note …; FLEET_PEER_HAND_TASK_CMD is the seam)
  * one HANDED row in the delivery book (the send's last word)
  * one notice for the batch: 「有 N 份回报没人收，已转到你的提醒」
    (bin/fleet_notice.py; FLEET_PEER_HAND_NOTICE_CMD is the seam)

    fleet-peer-hand.py hand --book <delivery.ndjson> [--rid <rid>]... [--why <text>]
                            [--backfill-days N]

--rid names the sends to hand now; with none, every report whose last row reads
EXPIRED (and was never handed) within --backfill-days (14 — the reminder's own
window) is handed — what an older version let expire. The report's words come off
its QUEUED row's `report` field (fleet-report-parent.sh writes it there); a row
from before that has none, so the reminder says the words were not kept. A
message (kind message) is never handed: it is the sender's to retry. Prints
`handed N` when it handed any; exit 0 always unless the book cannot be written.
"""
import argparse
import json
import os
import subprocess
import sys
import time

REPORT_KINDS = ("report", "child_report")


def conf_dir():
    return os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet")


def read_book(book):
    rows = []
    try:
        with open(book, encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict) and r.get("rid"):
                    rows.append(r)
    except OSError:
        pass
    return rows


def sends(rows):
    """rid → {last, first_ts, report, kind, to, via, handed}"""
    out = {}
    for r in rows:
        s = out.setdefault(r["rid"], {"last": None, "first": None, "report": None, "kind": "", "to": "",
                                      "via": "", "handed": False})
        st = r.get("state")
        if st == "HANDED":
            s["handed"] = True
        # settled once ANY row says so (a receipt can precede the sender's QUEUED note)
        if st != "QUEUED" or (s["last"] or {}).get("state", "QUEUED") == "QUEUED":
            s["last"] = r
        if st == "QUEUED" and s["first"] is None:
            s["first"] = r.get("ts") or 0
        if isinstance(r.get("report"), dict):
            s["report"] = r["report"]
        if r.get("kind") and s["kind"] not in REPORT_KINDS:
            s["kind"] = r["kind"]
        for k in ("to", "via"):
            if r.get(k) and not s[k]:
                s[k] = r[k]
    return out


def child_of(rid):
    # <fleet UUID>/<child key or ID>#<suffix>
    head = rid.split("#", 1)[0]
    return head.split("/", 1)[1] if "/" in head else head


def who(to):
    t = str(to or "?")
    if "/" in t and len(t.split("/", 1)[0]) == 36:
        t = t.split("/", 1)[1]
    return t[:8] if len(t) == 36 else t[:40]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("act", choices=["hand"])
    ap.add_argument("--book", required=True)
    ap.add_argument("--rid", action="append", default=[])
    ap.add_argument("--why", default="")
    ap.add_argument("--backfill-days", type=int, default=14)
    a = ap.parse_args()

    all_sends = sends(read_book(a.book))
    now = int(time.time())
    if a.rid:
        picked = [rid for rid in a.rid if rid in all_sends]
    else:
        cut = now - a.backfill_days * 86400
        picked = [rid for rid, s in all_sends.items()
                  if (s["last"] or {}).get("state") == "EXPIRED" and ((s["last"] or {}).get("ts") or 0) >= cut]
    picked = [rid for rid in picked
              if not all_sends[rid]["handed"] and all_sends[rid]["kind"] in REPORT_KINDS]
    if not picked:
        return 0

    orphans = os.path.join(conf_dir(), "global", "orphan-reports.ndjson")
    filed = set()
    try:
        with open(orphans, encoding="utf-8") as f:
            for line in f:
                try:
                    filed.add(json.loads(line).get("rid"))
                except ValueError:
                    pass
    except OSError:
        pass
    os.makedirs(os.path.dirname(orphans), exist_ok=True)
    bindir = os.path.dirname(os.path.abspath(__file__))
    handed = []
    for rid in picked:
        s = all_sends[rid]
        rep = s["report"] or {}
        last = s["last"] or {}
        why = a.why or str(last.get("detail") or "nobody took it")
        why = " ".join(why.split())[:200]
        if rid not in filed:
            row = {"ts": now, "child_key": rep.get("child") or child_of(rid),
                   "state": rep.get("state") or "?", "pr": str(rep.get("pr") or ""),
                   "summary": (rep.get("summary") or "（回报的原话没留在本机：发出它的版本还不记）")[:600],
                   "parent": who(s["to"]), "via": "undelivered", "rid": rid, "why": why}
            for k in ("title", "repo", "task"):
                if rep.get(k):
                    row[k] = rep[k]
            with open(orphans, "a", encoding="utf-8") as f:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
            task = rep.get("task")
            if task:
                cmd = os.environ.get("FLEET_PEER_HAND_TASK_CMD") or os.path.join(bindir, "fleet-task-record.sh")
                note = "回报没送到上层 %s（%s），已转给你：%s%s" % (
                    who(s["to"]), why, row["state"], (" — " + row["summary"].splitlines()[0][:160]) if row["summary"] else "")
                try:
                    subprocess.run(["bash", cmd, "set", task, "--note", note], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
                except (OSError, subprocess.SubprocessError):
                    pass
        with open(a.book, "a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": now, "rid": rid, "kind": s["kind"], "to": s["to"], "state": "HANDED",
                                "via": s["via"] or last.get("via", ""),
                                "detail": "handed to the person: " + why}, ensure_ascii=False) + "\n")
        handed.append(rid)

    text = "有 %d 份回报没人收，已转到你的提醒：→ %s" % (
        len(handed), "、".join(sorted({who(all_sends[r]["to"]) for r in handed}))[:160])
    cmd = os.environ.get("FLEET_PEER_HAND_NOTICE_CMD") or os.path.join(bindir, "fleet_notice.py")
    try:
        subprocess.run(["python3", cmd, "notify", "warn", text, "--next", "⌘P 消息里看每一份",
                        "--all", "--kind", "alert", "--source", "peer-queue", "--tag", "peerq-handed", "--no-draw"],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    except (OSError, subprocess.SubprocessError):
        pass
    print("handed %d" % len(handed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
