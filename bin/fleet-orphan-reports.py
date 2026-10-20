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
  count              how many are unread (the top line's 「有 N 条无主回报」, T660)
  once <key>         exit 0 the first time <key> (the gone parent — one batch) is
                     asked within FLEET_ORPHAN_NOTIFY_SECS (86400), recording it in
                     global/orphan-reports.notified; exit 1 after — orphan()'s ONE
                     push per batch over FLEET_NOTIFY_CMD
  redeliver --to <ID> [--since <epoch>] [--apply]
                     hand the unread rows filed since <epoch> (default: today's
                     local midnight) to the live session <ID> (fleet-peer-send.sh
                     fid:<ID>), one envelope each, and mark each delivered one read
                     and `redelivered` (global/orphan-reports.redelivered) so it is
                     never sent twice. Without --apply: list only (T660)
  clear --before <epoch> [--apply]
                     mark every unread row older than <epoch> read — listed first;
                     without --apply: list only (T660)

An id is the row's own hash (ts · child · state · pr), so the same result read
anywhere is the same id. A row older than FLEET_ORPHAN_REPORT_DAYS (14) is not
listed either: a reminder nobody opened in two weeks is history. No file ⇒ every
command prints nothing and exits 0.
"""
import hashlib
import json
import os
import subprocess
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


def notified_path():
    return os.path.join(conf_dir(), "global", "orphan-reports.notified")


def once(key, now=None):
    """True the first time `key` is asked within FLEET_ORPHAN_NOTIFY_SECS."""
    now = int(time.time()) if now is None else now
    try:
        win = max(0, int(os.environ.get("FLEET_ORPHAN_NOTIFY_SECS", "86400")))
    except ValueError:
        win = 86400
    key = clean(key, 200) or "-"
    f = notified_path()
    try:
        with open(f, encoding="utf-8") as fh:
            for line in fh:
                k, _, ts = line.rstrip("\n").rpartition("\t")
                if k == key and ts.isdigit() and now - int(ts) < win:
                    return False
    except OSError:
        pass
    os.makedirs(os.path.dirname(f), exist_ok=True)
    with open(f, "a", encoding="utf-8") as fh:
        fh.write("%s\t%d\n" % (key, now))
    return True


def redelivered_path():
    return os.path.join(conf_dir(), "global", "orphan-reports.redelivered")


def redelivered_ids():
    try:
        with open(redelivered_path(), encoding="utf-8") as fh:
            return {ln.split("\t", 1)[0].strip() for ln in fh if ln.strip()}
    except OSError:
        return set()


def mark_read(ids):
    seen = read_ids()
    new = [i for i in ids if i not in seen]
    if new:
        _, rd = paths()
        os.makedirs(os.path.dirname(rd), exist_ok=True)
        with open(rd, "a", encoding="utf-8") as fh:
            fh.write("".join(i + "\n" for i in new))


def envelope(r):
    """The child-report envelope's shape (fleet-report-parent.sh), its stand-in note
    saying where it was."""
    st = r.get("state", "") + (" (PR #%s)" % r["pr"] if r.get("pr") else "")
    head = "[child-report] %s%s" % (r.get("child_key", ""), ' "%s"' % clean(r["title"], 120) if r.get("title") else "")
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(r["ts"]))
    lines = [head, "state: %s · 原 parent %s 已不在，无主回报补送（%s）" % (st, r.get("parent", "?"), when)]
    sm = "\n".join(l[:200] for l in str(r.get("summary", "")).replace("<", "").replace(">", "").splitlines()[:3])
    if sm:
        lines.append("summary: " + sm)
    lines.append("no reply needed")
    return "\n".join(lines)


def midnight(now=None):
    t = time.localtime(time.time() if now is None else now)
    return int(time.mktime((t.tm_year, t.tm_mon, t.tm_mday, 0, 0, 0, 0, 0, -1)))


def opt(args, name, default=""):
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return default


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
        if "--us" in args:
            # 0x1f between fields (T493): a tab is IFS white space to `read`, so an
            # empty repo merged into its neighbour and every column after it slid;
            # agent and issue ride last
            for r in unread(cap):
                print("\x1f".join(f.replace("\x1f", " ").replace("\n", " ") for f in
                                   fields(r) + [clean(r.get("agent", ""), 16), clean(str(r.get("issue", "")), 12)]))
            return 0
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
        mark_read(ids)
        return 0
    if cmd == "count":
        print(len(unread(10 ** 6)))
        return 0
    if cmd == "once":
        return 0 if args and once(args[0]) else 1
    if cmd in ("redeliver", "clear"):
        apply = "--apply" in args
        if cmd == "redeliver":
            to = opt(args, "--to")
            if not (len(to) == 36 and to.count("-") == 4):
                sys.stderr.write("fleet-orphan-reports.py redeliver --to <ID> [--since <epoch>] [--apply]\n")
                return 2
            since = opt(args, "--since")
            since = int(since) if since.isdigit() else midnight()
            done = redelivered_ids()
            pick = [r for r in unread(10 ** 6) if r["ts"] >= since and r["id"] not in done]
        else:
            before = opt(args, "--before")
            if not before.isdigit():
                sys.stderr.write("fleet-orphan-reports.py clear --before <epoch> [--apply]\n")
                return 2
            pick = [r for r in unread(10 ** 6) if r["ts"] < int(before)]
        rc = 0
        for r in sorted(pick, key=lambda r: r["ts"]):
            tag = "%s\t%s\t%s\t%s\tparent=%s" % (r["id"], time.strftime("%m-%d %H:%M", time.localtime(r["ts"])),
                                                 clean(r.get("child_key", ""), 80), clean(r.get("state", ""), 16),
                                                 clean(r.get("parent", ""), 80))
            if not apply:
                print("would %s\t%s" % (cmd, tag))
                continue
            if cmd == "clear":
                mark_read([r["id"]])
                print("cleared\t" + tag)
                continue
            send = os.environ.get("FLEET_ORPHAN_SEND") or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                       "fleet-peer-send.sh")
            try:
                ok = subprocess.run(["bash", send, "fid:" + to, envelope(r)], stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=60).returncode == 0
            except (OSError, subprocess.TimeoutExpired):
                ok = False
            if not ok:
                print("FAILED\t" + tag)
                rc = 1
                continue
            os.makedirs(os.path.dirname(redelivered_path()), exist_ok=True)
            with open(redelivered_path(), "a", encoding="utf-8") as fh:
                fh.write("%s\t%s\t%d\n" % (r["id"], to, int(time.time())))
            mark_read([r["id"]])
            print("redelivered\t" + tag)
        return rc
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
