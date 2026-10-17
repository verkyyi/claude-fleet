#!/usr/bin/env python3
"""fleet-idle-daily.py — the idle reading in the daily check-up (issue #4361,
EPIC #4354 C7).

Once a day, while the machine is idle, take one reading with
bin/fleet-idle-cost.sh (idle = fleet_idle_now — never a second definition) and
append it to $FLEET_CONF_DIR/global/idle-cost.ndjson, one line a reading, kept
FLEET_IDLE_DAILY_KEEP_DAYS (30) days. Over FLEET_IDLE_COST_WARN (50 a second,
the doctor's own line) ⇒ ONE ordinary issue through bin/fleet-issue-file.sh
naming the three biggest sources, marked `<!-- fleet:idle-cost node=… day=… -->`
— one a machine a day: the marker is looked for on this login's record and in
the repo's issues before filing. A day that was never idle gets one 「未量」
line (state=unmeasured, the last busy reason) at the next day's first try.

  fleet-idle-daily.py tick [--repo owner/name] [--force]
        one try: measure when due (at most every FLEET_IDLE_DAILY_EVERY s, 900,
        until today has a reading), file when over. The diskguard tick runs it
        detached; it reads only the gate file until the gate opens.
  fleet-idle-daily.py show [--days N] [--json]
        the last N days' lines (default 7): TSV `day state rate|reason issue`.
  fleet-idle-daily.py summary [--days N]
        one TSV line for the doctor: measured · unmeasured · last day · last rate.

Files ($FLEET_CONF_DIR/global/): idle-cost.ndjson (the readings — the report and
the doctor read this one file), idle-cost.day.json (today's tries), idle-cost.gate
(the epoch before which the tick does nothing), idle-cost.filed (node · day · url
already filed), idle-cost.daily.lock.

Not a host (fleet-conf.sh host → 0) ⇒ nothing measured, the gate closed till
tomorrow; FLEET_IDLE_DAILY=1 forces a try, =0 is checked by the tick's caller.
Seams (tests): FLEET_IDLE_DAILY_COST_CMD (the measure), FLEET_IDLE_DAILY_FILE_CMD
(the filer), FLEET_IDLE_DAILY_GH (gh), FLEET_IDLE_DAILY_HOST_CMD (the host test),
FLEET_IDLE_DAILY_NOW (epoch), FLEET_IDLE_DAILY_NODE (machine name).
"""
import argparse
import datetime
import json
import os
import shlex
import socket
import subprocess
import sys
import time

BIN = os.path.dirname(os.path.abspath(__file__))


def env_num(name, default):
    try:
        v = float(os.environ.get(name, ""))
        return v if v >= 0 else default
    except ValueError:
        return default


CONF = os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet")
GDIR = os.path.join(CONF, "global")
NDJSON = os.path.join(GDIR, "idle-cost.ndjson")
DAYF = os.path.join(GDIR, "idle-cost.day.json")
GATE = os.path.join(GDIR, "idle-cost.gate")
FILED = os.path.join(GDIR, "idle-cost.filed")
LOCK = os.path.join(GDIR, "idle-cost.daily.lock")
EVERY = int(env_num("FLEET_IDLE_DAILY_EVERY", 900))
SECS = env_num("FLEET_IDLE_DAILY_SECS", 60)
WARN = env_num("FLEET_IDLE_COST_WARN", 50)
KEEP = int(env_num("FLEET_IDLE_DAILY_KEEP_DAYS", 30))


def now():
    v = os.environ.get("FLEET_IDLE_DAILY_NOW", "")
    return int(v) if v.isdigit() else int(time.time())


def day_of(t):
    return datetime.datetime.fromtimestamp(t).strftime("%Y-%m-%d")


def next_midnight(t):
    d = datetime.datetime.fromtimestamp(t).date() + datetime.timedelta(days=1)
    return int(time.mktime(d.timetuple()))


def node():
    return os.environ.get("FLEET_IDLE_DAILY_NODE") or socket.gethostname().split(".")[0]


def cmd(name, default):
    v = os.environ.get(name, "")
    return shlex.split(v) if v else default


def write_atomic(path, text):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def rows():
    out = []
    try:
        with open(NDJSON) as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict) and r.get("day"):
                    out.append(r)
    except OSError:
        pass
    return out


def save_rows(rs, t):
    cut = day_of(t - KEEP * 86400)
    rs = [r for r in rs if r.get("day", "") > cut]
    write_atomic(NDJSON, "".join(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n" for r in rs))


def append_row(row, t):
    rs = [r for r in rows() if not (r.get("day") == row["day"] and r.get("node") == row["node"])]
    rs.append(row)
    save_rows(rs, t)


def set_gate(epoch):
    write_atomic(GATE, "%d\n" % epoch)


def is_host():
    if os.environ.get("FLEET_IDLE_DAILY") == "1":
        return True
    c = cmd("FLEET_IDLE_DAILY_HOST_CMD", ["bash", os.path.join(BIN, "fleet-conf.sh"), "host"])
    try:
        p = subprocess.run(c, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return False
    return p.stdout.decode(errors="replace").strip() == "1"


def measure():
    """→ ("idle", reading) | ("busy", reason) | ("error", reason)."""
    c = cmd("FLEET_IDLE_DAILY_COST_CMD", ["bash", os.path.join(BIN, "fleet-idle-cost.sh")])
    c = c + ["--json", "--secs", ("%g" % SECS)]
    try:
        p = subprocess.run(c, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=SECS + 300)
    except (OSError, subprocess.SubprocessError) as e:
        return "error", "量不出来：%s" % e
    r = None
    for line in reversed(p.stdout.decode(errors="replace").splitlines()):
        try:
            r = json.loads(line)
            break
        except ValueError:
            continue
    if p.returncode == 3 or (isinstance(r, dict) and r.get("state") == "busy"):
        return "busy", (r or {}).get("reason") or "busy"
    if p.returncode != 0 or not isinstance(r, dict):
        err = p.stderr.decode(errors="replace").strip().splitlines()
        return "error", "量不出来：rc=%d %s" % (p.returncode, err[-1] if err else "")
    if r.get("state") != "idle":
        return "busy", "读数未确认空闲（%s）" % r.get("state")
    return "idle", r


def marker(nd, day):
    return "<!-- fleet:idle-cost node=%s day=%s -->" % (nd, day)


def filed_url(nd, day):
    try:
        with open(FILED) as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 3 and p[0] == nd and p[1] == day:
                    return p[2]
    except OSError:
        pass
    return ""


def remote_url(repo, nd, day, t):
    """An issue already carrying the marker (another login on this machine filed
    it) → its URL; '' for none or an unreadable list."""
    since = datetime.datetime.fromtimestamp(t - 2 * 86400, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    c = cmd("FLEET_IDLE_DAILY_GH", ["gh"]) + [
        "api", "repos/%s/issues?state=all&per_page=100&since=%s" % (repo, since)]
    try:
        p = subprocess.run(c, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60)
        items = json.loads(p.stdout.decode(errors="replace") or "[]")
    except (OSError, subprocess.SubprocessError, ValueError):
        return ""
    m = marker(nd, day)
    for it in items if isinstance(items, list) else []:
        if isinstance(it, dict) and m in (it.get("body") or ""):
            return it.get("html_url") or ""
    return ""


def file_issue(repo, row, t):
    nd, day = row["node"], row["day"]
    url = filed_url(nd, day)
    if url:
        return url, "already"
    if not repo:
        return "", "no repo"
    url = remote_url(repo, nd, day, t)
    how = "found"
    if not url:
        top = row.get("top") or []
        lines = "\n".join("%d. `%s` — %s 个/秒" % (i + 1, x.get("who", "?"), x.get("rate", "?"))
                          for i, x in enumerate(top[:3])) or "（排名为空：来源都太短命，`ps` 没看见）"
        title = "空闲开销超标：%s %s 每秒新起 %s 个进程（阈值 %g）" % (nd, day, row["rate"], WARN)
        body = """`bin/fleet-idle-daily.py`（#4361）在 %s 空闲时量了 %s 秒：**每秒新起 %s 个进程**，超过 `FLEET_IDLE_COST_WARN` = %g；fleet 自己的 CPU %s%%，负载 %s（%s 核）。

最多的来源（按最近的长寿祖先记账）：

%s

空闲 = `fleet_idle_now`（没有 working 的执行会话、CI 没有作业）。全表：在这台机器空闲时 `bash bin/fleet-idle-cost.sh`；每天的读数在 `$FLEET_CONF_DIR/global/idle-cost.ndjson`（`python3 bin/fleet-idle-daily.py show`）。同一台机器一天最多一张。

%s""" % (nd, row.get("secs", "?"), row["rate"], WARN, row.get("fleet_cpu_pct", "?"),
         ",".join(str(x) for x in row.get("load") or []) or "?", row.get("cores", "?"), lines, marker(nd, day))
        c = cmd("FLEET_IDLE_DAILY_FILE_CMD", ["bash", os.path.join(BIN, "fleet-issue-file.sh")])
        c = c + ["--repo", repo, "--from", "idle-cost", "--title", title, "--body", body]
        try:
            p = subprocess.run(c, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=300)
            out = p.stdout.decode(errors="replace").split()
        except (OSError, subprocess.SubprocessError):
            out = []
        url = next((w for w in reversed(out) if w.startswith("http")), "")
        if not url:
            return "", "filing failed"
        how = "filed"
    with open(FILED, "a") as f:
        f.write("%s\t%s\t%s\n" % (nd, day, url))
    return url, how


def lock():
    try:
        os.mkdir(LOCK)
        return True
    except FileExistsError:
        try:
            if time.time() - os.stat(LOCK).st_mtime > SECS + 600:
                os.rmdir(LOCK)
                os.mkdir(LOCK)
                return True
        except OSError:
            pass
        return False
    except OSError:
        return False


def tick(a):
    os.makedirs(GDIR, exist_ok=True)
    if not lock():
        print("idle-daily\tlocked")
        return 0
    try:
        return _tick(a)
    finally:
        try:
            os.rmdir(LOCK)
        except OSError:
            pass


def _tick(a):
    t, nd = now(), node()
    today = day_of(t)
    st = load_json(DAYF, {})
    if st.get("day") and st["day"] != today:
        # yesterday (or the last day tried) never got a reading ⇒ one 「未量」 line
        if not st.get("done") and not any(r.get("day") == st["day"] and r.get("node") == nd for r in rows()):
            append_row({"day": st["day"], "node": nd, "ts": t, "state": "unmeasured",
                        "reason": st.get("reason") or "一直不空闲", "tries": st.get("tries", 0)}, t)
        st = {}
    st.setdefault("day", today)
    if st.get("done") and not st.get("file_pending"):
        set_gate(next_midnight(t))
        print("idle-daily\tdone\t%s" % today)
        return 0
    if st.get("file_pending"):
        row = next((r for r in rows() if r.get("day") == today and r.get("node") == nd), None)
        if row:
            url, how = file_issue(a.repo, row, t)
            if url:
                row["issue"] = url
                append_row(row, t)
                st["file_pending"] = False
                set_gate(next_midnight(t))
            else:
                set_gate(min(t + EVERY, next_midnight(t)))
            write_atomic(DAYF, json.dumps(st))
            print("idle-daily\tfile\t%s\t%s" % (how, url))
            return 0
        st["file_pending"] = False
    if not a.force and t - int(st.get("last_try", 0)) < EVERY:
        return 0
    st["last_try"] = t
    st["tries"] = int(st.get("tries", 0)) + 1
    if not is_host():
        st.update(done=True, reason="不承载")
        write_atomic(DAYF, json.dumps(st))
        set_gate(next_midnight(t))
        print("idle-daily\tnot-host")
        return 0
    kind, r = measure()
    if kind != "idle":
        st["reason"] = r
        write_atomic(DAYF, json.dumps(st, ensure_ascii=False))
        set_gate(min(t + EVERY, next_midnight(t)))
        print("idle-daily\t%s\t%s" % (kind, r))
        return 0
    row = {"day": today, "node": nd, "ts": int(r.get("ts") or t), "state": "idle",
           "rate": r.get("rate"), "secs": r.get("secs"), "new": r.get("new"), "method": r.get("method"),
           "fleet_cpu_pct": r.get("fleet_cpu_pct"), "load": r.get("load"), "cores": r.get("cores"),
           "top": [{"who": x.get("who"), "rate": x.get("rate")} for x in (r.get("spawn_top") or [])[:3]],
           "warn": WARN}
    try:
        over = float(row["rate"]) > WARN
    except (TypeError, ValueError):
        over = False
    row["over"] = over
    st["done"] = True
    msg = "idle-daily\tidle\t%s/s" % row["rate"]
    if over:
        url, how = file_issue(a.repo, row, t)
        if url:
            row["issue"] = url
        elif how == "filing failed":
            st["file_pending"] = True
        msg += "\tover\t%s\t%s" % (how, url)
    append_row(row, t)
    write_atomic(DAYF, json.dumps(st, ensure_ascii=False))
    set_gate(min(t + EVERY, next_midnight(t)) if st.get("file_pending") else next_midnight(t))
    print(msg)
    return 0


def recent(days):
    cut = day_of(now() - days * 86400)
    return [r for r in rows() if r.get("day", "") > cut]


def show(a):
    rs = recent(a.days)
    for r in rs:
        if a.json:
            print(json.dumps(r, ensure_ascii=False, sort_keys=True))
        elif r.get("state") == "idle":
            print("\t".join([r["day"], "idle", "%s/s" % r.get("rate"), r.get("issue") or "-"]))
        else:
            print("\t".join([r["day"], r.get("state", "?"), r.get("reason") or "-", "-"]))
    return 0


def summary(a):
    rs = recent(a.days)
    idle = [r for r in rs if r.get("state") == "idle"]
    un = [r for r in rs if r.get("state") == "unmeasured"]
    last = idle[-1] if idle else {}
    print("\t".join([str(len(idle)), str(len(un)), last.get("day", "-"), str(last.get("rate", "-"))]))
    return 0 if rs else 1


def main():
    ap = argparse.ArgumentParser(prog="fleet-idle-daily.py")
    sub = ap.add_subparsers(dest="cmd")
    t = sub.add_parser("tick")
    t.add_argument("--repo", default="")
    t.add_argument("--force", action="store_true")
    for n in ("show", "summary"):
        s = sub.add_parser(n)
        s.add_argument("--days", type=int, default=7)
        if n == "show":
            s.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if a.cmd == "tick":
        return tick(a)
    if a.cmd == "show":
        return show(a)
    if a.cmd == "summary":
        return summary(a)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
