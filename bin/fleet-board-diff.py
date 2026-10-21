#!/usr/bin/env python3
"""fleet-board-diff.py — how far the ⌘P panel is from the hub's one session list,
right now (claude-fleet A4G2). `fleet board diff` runs it.

The console's 会话 draws the hub's list (fleet_sessions' `board`); the panel lays
its own entries on the same list (fleet_view.board_apply). This reads both at one
moment — the list the hub last answered (global/hubsess.body, refreshed first) and
the entries the panel draws for a 看台 — and prints the difference over the counted
groups (置顶 · 等你 · 在干活 · 排队中): rows only the hub has, rows only the panel
has, rows in another group, the order, the two counts.

  fleet-board-diff.py [--view <看台 id>] [--json]

Exit: 0 diff 0 · 1 a difference · 3 no list to compare (no hub here, an older hub,
the hub silent past FLEET_HUB_SESSIONS_STALE)."""
import argparse
import json
import os
from pathlib import Path
import sys
import time

BIN = Path(__file__).absolute().parent
sys.path.insert(0, str(BIN))
import fleet_view as v  # noqa: E402

COUNTED = ("pin", "ask", "work", "queue")


def newest_view():
    try:
        rows = [p for p in v.views_dir().iterdir()
                if p.is_file() and not p.name.startswith(".") and "." not in p.name and not p.name.startswith("epic-")]
    except OSError:
        return ""
    rows.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return rows[0].name if rows else ""


def compare(board, items):
    hub = [(r["id"], r.get("group"), r.get("title") or "") for r in board.get("rows") or [] if r.get("group") in COUNTED]
    panel = []
    for e in items:
        if e.get("kind") != "sess" or e.get("gone") or e.get("sec") == "gone" or e.get("group") not in COUNTED:
            continue
        key = e.get("board") or e.get("fid") or e.get("target")
        panel.append((key, e.get("group"), e.get("text") or ""))
    hk, pk = [k for k, _, _ in hub], [k for k, _, _ in panel]
    hg, pg = {k: g for k, g, _ in hub}, {k: g for k, g, _ in panel}
    out = {
        "only_hub": [{"id": k, "group": g, "title": t} for k, g, t in hub if k not in pg],
        "only_panel": [{"id": k, "group": g, "title": t} for k, g, t in panel if k not in hg],
        "group": [{"id": k, "hub": hg[k], "panel": pg[k]} for k in hk if k in pg and hg[k] != pg[k]],
        "order": [k for k in hk if k in pg] != [k for k in pk if k in hg],
        "count_hub": board.get("count"),
        "count_panel": sum(1 for e in v.counted_rows(items).values() if not e.get("lost")),
    }
    out["diff"] = len(out["only_hub"]) + len(out["only_panel"]) + len(out["group"]) + (1 if out["order"] else 0)
    return out


def main():
    ap = argparse.ArgumentParser(prog="fleet board diff")
    ap.add_argument("--view", default="")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    vid = a.view or newest_view()
    items = v.entries(vid) if vid else []
    board = v.board_read(time.time())
    if not board:
        print("no list to compare: no hub here, an older hub, or the hub silent — the panel draws its own")
        return 3
    out = compare(board, items)
    out["view"], out["at"] = vid, time.strftime("%Y-%m-%d %H:%M:%S")
    if a.json:
        print(json.dumps(out, ensure_ascii=False))
    else:
        print("%s · %s · hub %s · panel %s · diff %d" % (out["at"], vid or "-", out["count_hub"], out["count_panel"], out["diff"]))
        for x in out["only_hub"]:
            print("  only on the hub   %-8s %s  %s" % (x["group"], x["id"][:12], x["title"][:40]))
        for x in out["only_panel"]:
            print("  only on the panel %-8s %s  %s" % (x["group"], str(x["id"])[:12], x["title"][:40]))
        for x in out["group"]:
            print("  group differs     %s  hub %s · panel %s" % (x["id"][:12], x["hub"], x["panel"]))
        if out["order"]:
            print("  the order differs")
    return 0 if out["diff"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
