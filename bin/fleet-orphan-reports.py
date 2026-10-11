#!/usr/bin/env python3
"""fleet-orphan-reports.py — the ONE reader of global/orphan-reports.ndjson
(issue #3369, the follow-up of #3117).

When a session's spawner is gone, bin/fleet-report-parent.sh's orphan() files the
child's result for the PERSON: one row in $FLEET_CONF_DIR/global/orphan-reports.ndjson
({ts, child_key, state, pr, summary[, title, parent, repo]}) plus one alert. This
is what the sidebar and the entry (the hub's overview) read it through:

  list [--max N]     the unread rows, newest first, one TSV line each:
                     id  ts  repo  child  state  pr  summary(one line)
  cell [--max N]     the same as the node inventory's `orphanrep=` cell (column
                     31, bin/fleet-control-read.sh): entries
                     `id\\x1fts\\x1frepo\\x1fchild\\x1fstate\\x1fpr\\x1fsummary`,
                     \\x1e-joined; empty when there is none
  read <id>...       mark rows read — the cursor, global/orphan-reports.read
                     (one id a line); a read row is never listed again
  show <id>          the row's full result, for a person

An id is the row's own hash (ts · child · state · pr), so the same result read
anywhere is the same id. A row older than FLEET_ORPHAN_REPORT_DAYS (14) is not
listed either: a reminder nobody opened in two weeks is history. No file ⇒ every
command prints nothing and exits 0.
"""
import hashlib
import json
import os
import sys
import time

MAX_DEFAULT = 10
SUMMARY_MAX = 300


def conf_dir():
    return os.environ.get("FLEET_CONF_DIR") or os.path.join(
        os.path.expanduser("~"), ".config", "claude-fleet")


def paths():
    g = os.path.join(conf_dir(), "global")
    return os.path.join(g, "orphan-reports.ndjson"), os.path.join(g, "orphan-reports.read")


def row_id(r):
    raw = "%s|%s|%s|%s" % (r.get("ts", ""), r.get("child_key", ""), r.get("state", ""), r.get("pr", ""))
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:12]


def clean(v, cap=200):
    s = "".join(" " if (ord(c) < 32 or ord(c) == 127) else c for c in str(v if v is not None else ""))
    return " ".join(s.split())[:cap]


def read_ids():
    _, rd = paths()
    try:
        with open(rd, encoding="utf-8") as f:
            return {ln.strip() for ln in f if ln.strip()}
    except OSError:
        return set()


def rows():
    """Every well-formed row, oldest first, each with its id."""
    f, _ = paths()
    out = []
    try:
        with open(f, encoding="utf-8") as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(r, dict) or not r.get("child_key"):
                    continue
                try:
                    r["ts"] = int(r.get("ts") or 0)
                except (TypeError, ValueError):
                    r["ts"] = 0
                r["id"] = row_id(r)
                out.append(r)
    except OSError:
        pass
    return out


def unread(cap=MAX_DEFAULT, now=None):
    days = os.environ.get("FLEET_ORPHAN_REPORT_DAYS", "14")
    try:
        keep = max(0, int(days)) * 86400
    except ValueError:
        keep = 14 * 86400
    now = int(time.time()) if now is None else now
    seen = read_ids()
    out = [r for r in rows() if r["id"] not in seen and (keep == 0 or now - r["ts"] < keep)]
    out.sort(key=lambda r: -r["ts"])
    return out[:cap]


def fields(r):
    return [r["id"], str(r["ts"]), clean(r.get("repo", ""), 100), clean(r.get("child_key", ""), 100),
            clean(r.get("state", ""), 16), clean(r.get("pr", ""), 12), clean(r.get("summary", ""), SUMMARY_MAX)]


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    args = argv[2:]
    cap = MAX_DEFAULT
    if "--max" in args:
        i = args.index("--max")
        try:
            cap = max(1, int(args[i + 1]))
        except (IndexError, ValueError):
            pass
        del args[i:i + 2]
    if cmd == "list":
        for r in unread(cap):
            print("\t".join(f.replace("\t", " ") for f in fields(r)))
        return 0
    if cmd == "cell":
        print("\x1e".join("\x1f".join(f.replace("\x1e", " ").replace("\x1f", " ") for f in fields(r))
                          for r in unread(cap)))
        return 0
    if cmd == "read":
        ids = [a for a in args if a and all(c in "0123456789abcdef" for c in a)]
        if not ids:
            sys.stderr.write("fleet-orphan-reports.py read <id>...\n")
            return 2
        seen = read_ids()
        new = [i for i in ids if i not in seen]
        if new:
            _, rd = paths()
            os.makedirs(os.path.dirname(rd), exist_ok=True)
            with open(rd, "a", encoding="utf-8") as fh:
                fh.write("".join(i + "\n" for i in new))
        return 0
    if cmd == "show":
        want = args[0] if args else ""
        for r in rows():
            if r["id"] == want:
                print("%s %s%s" % (r.get("child_key", ""), r.get("state", ""),
                                   " (PR #%s)" % r["pr"] if r.get("pr") else ""))
                if r.get("title"):
                    print(r["title"])
                if r.get("parent"):
                    print("派它的会话：%s（已不在）" % r["parent"])
                print(time.strftime("%Y-%m-%d %H:%M", time.localtime(r["ts"])))
                print()
                print(r.get("summary", ""))
                return 0
        return 1
    sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
