#!/usr/bin/env python3
"""fleet-services.py — the background services and scheduled tasks a person
registered on the managed machines (issue #2526, EPIC #2524 C2), as ONE table
for every reader: `fleet ls --services`, the doctor's `services` row and the
alert bar's `service · failed` rows.

    fleet-services.py [--json]     the table: 机器 · 登录 · 名称 · 类型 · 状态 ·
                                   上次 · 下次 · 最近日志 (a failed row red on a
                                   terminal)
    fleet-services.py --doctor     one line, `<LEVEL>\\t<text>`: FAIL when an
                                   entry is failed, PASS when all run, INFO when
                                   nothing is registered
    fleet-services.py --alerts     one TSV line per failed entry:
                                   id · subject value · since · detail

The rows come from two places, merged by machine:
  * the hub — `machines[].services` of /v1/nodes or the certificate summary,
    narrowed by the hub to this person's own (machine, login)s; the refresh
    loop (fleet-hub-sessions.sh) keeps it in $G/hub_services. Every machine.
  * this machine's daemon — fleet-node-supervisor.py's state.json (0644,
    `services`), for the machine the hub has no word for (no hub, a hub that
    has not heard the register yet). This login's own entries only; the log's
    last line read here, from the login's own log.

A failed entry is one meant to run that does not: down (exited, waiting to
restart) · failed (a task past its retries) · invalid · no_login — the same
set as the hub's service_failed alert (control.ServiceStatus.Failed).

Seams (tests): FLEET_SERVICES_CACHE (the hub_services file; "" = none),
FLEET_SERVICES_STATE (the daemon's state.json; "" = none), FLEET_SERVICES_HOST
(this machine's name), FLEET_SERVICES_LOGIN, FLEET_SERVICES_NOW (the clock).
Exit: 0 · 2 usage.
"""
import json
import os
import pwd
import socket
import sys
import time
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).absolute().parent))
import fleet_iso  # noqa: E402 — the one ISO reader (issue #2024)

FAILED = ("down", "failed", "invalid", "no_login")
STATE_SAY = {"running": "运行中", "stopped": "已停", "down": "已退出·待重启", "failed": "失败",
             "invalid": "条目无效", "no_login": "登录不存在", "unknown": "未知"}
KIND_SAY = {"service": "常驻", "task": "定时"}
LINE_MAX = 200
STALE_SECS = 300


def now():
    try:
        return int(os.environ["FLEET_SERVICES_NOW"])
    except (KeyError, ValueError):
        return int(time.time())


def me():
    return os.environ.get("FLEET_SERVICES_LOGIN") or pwd.getpwuid(os.getuid()).pw_name


def short(h):
    return (h or "").split(".", 1)[0]


def epoch(v):
    """An ISO time (the hub's) or an epoch (the daemon's) → epoch, or None."""
    if v is None or v == "":
        return None
    if isinstance(v, (int, float)):
        return int(v) if v > 0 else None
    return fleet_iso.epoch(str(v), utc=True) or None


def cache_path():
    """$G/hub_services: FLEET_STATUS_G's when set, else the newer of the client
    shell's (fleet-shell.sh's cache, TMPDIR=<cache>/tmp) and this login's own —
    so `fleet ls --services` reads without the client running."""
    g = os.environ.get("FLEET_STATUS_G")
    if g:
        return os.path.join(g, "hub_services")
    shell = os.environ.get("FLEET_SHELL_CACHE") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache"), "claude-fleet", "shell")
    own = os.environ.get("TMPDIR") or "/tmp/claude-fleet-%d" % os.getuid()
    best, at = None, -1.0
    for d in (os.path.join(shell, "tmp"), own):
        f = os.path.join(d, ".claude-dash", "global", "hub_services")
        try:
            m = os.stat(f).st_mtime
        except OSError:
            continue
        if m > at:
            best, at = f, m
    return best or ""


def read_cache():
    """{ts, machines: [{hostname, label, services_at, services}], alerts} or None."""
    path = os.environ.get("FLEET_SERVICES_CACHE")
    if path is None:
        path = cache_path()
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def log_line(path, login):
    """The last non-blank line of a log the login owns (≤ LINE_MAX bytes)."""
    if not path:
        return ""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    except OSError:
        return ""
    with os.fdopen(fd, "rb") as f:
        try:
            st = os.fstat(f.fileno())
            if st.st_uid != pwd.getpwnam(login).pw_uid:
                return ""
        except (KeyError, OSError):
            return ""
        f.seek(max(0, st.st_size - 65536))
        lines = [l for l in f.read().decode("utf-8", "replace").splitlines() if l.strip()]
    return lines[-1].encode("utf-8")[:LINE_MAX].decode("utf-8", "ignore") if lines else ""


def local_rows():
    """This machine's daemon register, this login's entries: hub-shaped rows."""
    path = os.environ.get("FLEET_SERVICES_STATE")
    if path is None:
        path = os.path.join(os.environ.get("FLEET_NODE_STATE") or "/var/db/fleet-node", "state.json")
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as f:
            st = json.load(f)
    except (OSError, ValueError):
        return None
    svcs = st.get("services") if isinstance(st, dict) else None
    if not isinstance(svcs, list):
        return None
    login, out = me(), []
    for r in svcs:
        if not isinstance(r, dict) or r.get("login") != login:
            continue
        state = {"no such login": "no_login", "": "unknown", None: "unknown"}.get(r.get("status"), r.get("status"))
        state = str(state).replace(" ", "_")
        row = {"name": r.get("name") or "", "kind": r.get("kind") or "service", "login": login, "state": state,
               "started_at": r.get("started"), "last_run": r.get("last_run") or r.get("started"),
               "next_run": r.get("next_run") or (r.get("next_start") if state == "down" else None),
               "restarts": r.get("restarts") or 0, "last_rc": r.get("last_rc"), "why": r.get("why") or "",
               "last_log_line": log_line(r.get("log"), login)}
        out.append(row)
    return out


def table_rows():
    """[(machine label, hostname, row)] — the hub's machines, then this one's
    daemon when the hub has no word for this machine — plus (cache ts or None,
    the hub's alerts)."""
    cache = read_cache()
    out, hosts = [], set()
    if cache:
        for m in cache.get("machines") or []:
            if not isinstance(m, dict):
                continue
            hosts.add(short(m.get("hostname")))
            for r in m.get("services") or []:
                if isinstance(r, dict):
                    out.append((m.get("label") or short(m.get("hostname")), m.get("hostname") or "", r))
    here = os.environ.get("FLEET_SERVICES_HOST") or socket.gethostname()
    if short(here) not in hosts:
        for r in local_rows() or []:
            out.append((short(here), here, r))
    out.sort(key=lambda x: (x[0], x[2].get("login") or "", x[2].get("name") or ""))
    return out, (cache or {}).get("ts"), [a for a in (cache or {}).get("alerts") or [] if isinstance(a, dict)]


def failed(r):
    return r.get("state") in FAILED


def when(t, n):
    """「3 分钟前」/「12 秒后」/ — ."""
    t = epoch(t)
    if t is None:
        return "—"
    d = t - n
    a = abs(d)
    if a < 60:
        s = "%d 秒" % a
    elif a < 3600:
        s = "%d 分钟" % (a // 60)
    elif a < 86400:
        s = "%d 小时" % (a // 3600)
    else:
        s = "%d 天" % (a // 86400)
    return s + ("后" if d > 0 else "前")


def state_say(r):
    s = STATE_SAY.get(r.get("state"), r.get("state") or "?")
    if r.get("state") == "down" and r.get("last_rc") not in (None, 0):
        s += "（rc=%s）" % r["last_rc"]
    if r.get("state") == "invalid" and r.get("why"):
        s += "：" + r["why"]
    return s


def cells(text):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)


def pad(text, width):
    return text + " " * max(0, width - cells(text))


def show_table(rows, ts, n, out=sys.stdout):
    colour = out.isatty() and not os.environ.get("NO_COLOR")
    head = ["机器", "登录", "名称", "类型", "状态", "上次", "下次", "最近日志"]
    body = []
    for label, _h, r in rows:
        body.append(([label, r.get("login") or "", r.get("name") or "", KIND_SAY.get(r.get("kind"), r.get("kind") or ""),
                      state_say(r), when(r.get("last_run") or r.get("started_at"), n), when(r.get("next_run"), n),
                      (r.get("last_log_line") or "").replace("\t", " ")], failed(r)))
    widths = [max(cells(x[i]) for x in [head] + [b for b, _ in body]) for i in range(len(head) - 1)]
    for cols, bad in [(head, False)] + body:
        line = "  ".join(pad(v, w) for v, w in zip(cols, widths)) + "  " + cols[-1]
        line = line.rstrip()
        print(("\033[31m%s\033[0m" % line) if bad and colour else line, file=out)
    if isinstance(ts, (int, float)) and n - ts > STALE_SECS:
        print("（入口读数是 %s的）" % when(ts, n), file=out)


def cmd_table(as_json):
    rows, ts, _ = table_rows()
    n = now()
    if as_json:
        print(json.dumps([dict(r, machine=label, hostname=h, failed=failed(r)) for label, h, r in rows],
                         ensure_ascii=False))
        return 0
    if not rows:
        print("fleet · 没有登记的后台服务或定时任务（fleet service add 登记一个）", file=sys.stderr)
        return 0
    show_table(rows, ts, n)
    return 0


def cmd_doctor():
    rows, ts, _ = table_rows()
    n = now()
    age = ""
    if isinstance(ts, (int, float)) and n - ts > STALE_SECS:
        age = "（入口读数 %s）" % when(ts, n)
    if not rows:
        print("INFO\t无登记 — no background service or scheduled task registered (fleet service add)")
        return 0
    bad = [(label, r) for label, _h, r in rows if failed(r)]
    def name(label, r):
        return "%s/%s@%s" % (r.get("login") or "?", r.get("name") or "?", label)
    if bad:
        what = " · ".join("%s %s%s" % (name(label, r), state_say(r),
                                       ("「%s」" % r["last_log_line"]) if r.get("last_log_line") else "")
                          for label, r in bad)
        print("FAIL\t%d/%d failed: %s%s — fleet ls --services · fleet service logs <name>"
              % (len(bad), len(rows), what, age))
        return 0
    print("PASS\t%d registered, none failed: %s%s"
          % (len(rows), ", ".join("%s %s" % (name(label, r), STATE_SAY.get(r.get("state"), r.get("state")))
                                  for label, _h, r in rows), age))
    return 0


def cmd_alerts():
    rows, _ts, alerts = table_rows()
    since = {}
    for a in alerts:   # the hub's word on when it started failing
        since[a.get("subject") or ""] = epoch(a.get("raised_at")) or 0
    for label, h, r in rows:
        if not failed(r):
            continue
        sub = "%s/%s/%s" % (h, r.get("login") or "", r.get("name") or "")
        aid = "service-" + "-".join(x.replace("/", "_") for x in (short(h), r.get("login") or "", r.get("name") or ""))
        value = "%s@%s %s" % (r.get("name") or "?", label, STATE_SAY.get(r.get("state"), r.get("state")))
        detail = (r.get("last_log_line") or r.get("why") or "").replace("\t", " ").replace("\n", " ")
        print("\t".join((aid, value, str(since.get(sub, 0)), detail[:120])))
    return 0


def main(argv):
    if argv in ([], ["--json"]):
        return cmd_table(argv == ["--json"])
    if argv == ["--doctor"]:
        return cmd_doctor()
    if argv == ["--alerts"]:
        return cmd_alerts()
    if argv[:1] in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
