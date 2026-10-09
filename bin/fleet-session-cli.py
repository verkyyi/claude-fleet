#!/usr/bin/env python3
"""fleet-session-cli.py — the client's sessions from the command line (issue
#2365): whatever the row menu and ⌘P can do, a command can do.

    fleet ls [--json]                    every session: 名称 · 单号 · 机器 · Agent ·
                                         剩余 · 模型 · Effort · 状态 · PR · 回收方式
                                         (the same rows ⌘P lists)
    fleet show <会话>                    one session, every field
    fleet open <会话>                    the client onto it (as ↵ on its ⌘P line)
    fleet rename <会话> <新名…>          its display name (the hub's worker_rename,
                                         issue #2358 — the key never changes)
    fleet close <会话> [--yes]           reap it (the hub's worker_reap; asks y/n
                                         on a terminal unless --yes)
    fleet reap <会话> <方式>             its reap policy — merged[:<dur>] ·
                                         done[:<dur>] · loop-end · at:<time> · keep
                                         (the hub's worker_reap_policy, issue #2368)
    fleet answer [<会话>] [<回答>]        answer a session that asks you — the first
                                         one waiting when none is named; the answer
                                         asked on the terminal when none is given

<会话> is a name (a part of it is enough), `#<单号>` / `<单号>`, or the row's key
(`wid:<fleet>/<name>`). Matching is ONE resolver that refuses rather than guesses
(CLAUDE.md, issue #1537): the row's key, its issue number, its whole name or
title, else the rows whose name or title holds it — two or more is AMBIGUOUS:
the candidates on stderr and exit 4, never the first of them.

`fleet open <url | :port[/path] | file>` and `fleet show <file>` are what they
were (fleet-open.sh / fleet-show.sh): an argument that is a URL, a `:port` or an
existing file goes there, unchanged.

The rows are the client's own — `tmux-dashboard-rows.sh --sidebar`, every
folded row too (fleet-quickopen.py `full_rows`), run with the client server's
environment, so the client must be running (it keeps running after ⌃D / prefix
d). Started outside it (no FLEET_SHELL), this re-runs itself through
`fleet-shell.sh cli`, which imports that environment. Every write is a hub write
by the session's worker_id (fleet-hub-write.sh, the one write client): this
computer never acts on a window it does not have.

Exit: 0 done · 1 the action failed, or no client running · 2 usage · 3 no such
session · 4 more than one session matches.
剩余 · 模型 · Effort (issue #2431) are each session's measurement bus as its own
header shows it (conf/statusline.sh stamps it): another machine's off the hub's
session cache (global/remote_<fleet>, the node's inventory columns 24-28), this
machine's off its window when the cache has none. 剩余 is coloured on a terminal
— >50 green, 20–50 amber, <20 or at the handoff line red — and a reading older
than 5 minutes is grey with 「(N 分钟前)」; a node too old to report it shows —.

Seams (tests): FLEET_SESSION_CLI_ROWS (a switch-rows.tsv to read instead of the
producer), FLEET_SESSION_CLI_CACHE (a remote_<fleet> cache to read instead of the
client's; "" = none), FLEET_SESSION_CLI_NOW (the clock), FLEET_SESSION_CLI_WRITE (a script run in fleet-hub-write.sh's place,
same argv) and fleet-hub-write.sh's own FLEET_HUB_WRITE_CMD (close's reap).
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

BIN = Path(__file__).absolute().parent
VERBS = ("ls", "show", "open", "rename", "close", "reap", "answer")
STATE_SAY = {"needs": "在问你", "failed": "失败", "working": "在干活", "looping": "循环中",
             "done": "完成", "idle": "空闲", "exited": "已退出", "sleeping": "睡着", "landed": "已落地"}


def lib(name, file):
    spec = importlib.util.spec_from_file_location(name, str(BIN / file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def say(text):
    print("fleet · " + text, file=sys.stderr)


# --- the rows ------------------------------------------------------------------------

def rows():
    qo = lib("fleet_quickopen", "fleet-quickopen.py")
    seam = os.environ.get("FLEET_SESSION_CLI_ROWS")
    if seam:
        try:
            return qo.parse_rows(Path(seam).read_text())
        except OSError:
            return []
    got = qo.full_rows(os.environ.get("FLEET_SESSION", ""), timeout=15)
    return got if got is not None else qo.read_rows()


# --- the measurement bus (issue #2431) ---------------------------------------------

STALE_SECS = 300
AGENT_SAY = {"claude": "Claude", "codex": "Codex"}


def now():
    try:
        return int(os.environ["FLEET_SESSION_CLI_NOW"])
    except (KeyError, ValueError):
        return int(time.time())


def agent_say(agent):
    a = (agent or "").split(":", 1)[0]
    return AGENT_SAY.get(a, a)


def bus_cache():
    """{row key: {agent, left, band, ts, model, effort}} off the hub's session
    cache — a `wid:` row by its key, this machine's own (local=1) by its window id
    too. Fields 21-25 are the bus; an older node's row has only its agent."""
    seam = os.environ.get("FLEET_SESSION_CLI_CACHE")
    if seam is not None:
        path = seam
    else:
        path = os.path.join(os.environ.get("TMPDIR") or "/tmp", ".claude-dash", "global",
                            "remote_" + os.environ.get("FLEET_SESSION", ""))
    out = {}
    try:
        lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines() if path else []
    except OSError:
        lines = []
    for line in lines:
        f = line.split("\x1f")
        if not f[0].startswith("wid:"):
            continue
        f += [""] * (25 - len(f))
        m = {"agent": f[6]}
        if any(f[20:25]):
            m.update(left=f[20], band=f[21], ts=f[22], model=f[23], effort=f[24])
        out[f[0]] = m
        if f[10] == "1" and f[11].startswith("@"):
            out[f[11]] = m
    return out


def bus_local(keys):
    """This machine's windows the cache did not cover (no hub): their own stamps,
    read the way the node's inventory reads them."""
    sess = os.environ.get("FLEET_SESSION", "")
    if not keys or not sess:
        return {}
    fmt = ("#{window_id}\t#{@cc_agent}\t#{?@ctx_left,#{@ctx_left},#{?@ctx_pct,#{e|-:100,#{@ctx_pct}},}}"
           "\t#{@ctx_band}\t#{@ctx_ts}\t#{?@model,#{@model},#{?#{==:#{@cc_agent},codex},#{@cc_model},}}\t#{@effort}")
    try:
        got = subprocess.run(["tmux", "-u", "-L", sess, "list-windows", "-t", "=" + sess, "-F", fmt],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    out = {}
    for line in got.splitlines():
        f = (line.split("\t") + [""] * 7)[:7]
        if f[0] in keys:
            m = {"agent": f[1]}
            if any(f[2:7]):
                m.update(left=f[2], band=f[3], ts=f[4], model=f[5], effort=f[6])
            out[f[0]] = m
    return out


def attach_bus(rs):
    """Every row gets agent · left · band · ts · model · effort ('' = unknown)."""
    bus = bus_cache()
    bus.update(bus_local({r["key"] for r in rs if r["key"].startswith("@") and r["key"] not in bus}))
    for r in rs:
        m = bus.get(r["key"], {})
        r["agent"] = agent_say(m.get("agent", ""))
        for k in ("left", "band", "ts", "model", "effort"):
            r[k] = m.get(k, "")
    return rs


def left_cell(r, colour):
    """剩余: `62%`, `47% (8 分钟前)` when stale; — when the node never said."""
    left = r.get("left", "")
    if not re.fullmatch(r"[0-9]{1,3}", left or ""):
        return "—"
    text = left + "%"
    age = now() - int(r["ts"]) if re.fullmatch(r"[0-9]+", r.get("ts") or "") else -1
    stale = age >= STALE_SECS
    if stale:
        text += " (%d 分钟前)" % (age // 60)
    if not colour:
        return text
    n = int(left)
    code = "90" if stale else "31" if r.get("band") == "handoff" or n < 20 else "33" if n <= 50 else "32"
    return "\x1b[%sm%s\x1b[0m" % (code, text)


def cells(text):
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)


def pad(text, width):
    return text + " " * max(0, width - cells(text))


def progress(r):
    """The row's badge when it is a count (issue #2544): an EPIC driver's core
    members merged / core members, a parent's sub-tasks done / total; "" else."""
    b = (r.get("badge") or "").strip()
    return b if re.fullmatch(r"[0-9]{1,4}/[0-9]{1,4}", b) else ""


def epic_link(r):
    """An EPIC driver's 总单 (issue #2544) — its row is named `<简称>·批次`,
    titled `EPIC: …`, or a scratch (no issue of its own) wearing an issue cell,
    which is the parent's — as a GitHub URL."""
    repo, issue = r.get("repo") or "", r.get("issue") or ""
    if not issue or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        return ""
    if not (r["name"].endswith("·批次") or re.search(r"(^|[:/])scratch-[0-9]+$", r["key"])
            or re.match(r"EPIC\s*[:：]", r.get("title") or "", re.I)):
        return ""
    return "https://github.com/%s/issues/%s" % (repo, issue)


def fields(r, colour=False):
    """The columns `ls` prints and `show` names, in order."""
    return [("名称", r["name"]), ("进度", progress(r)), ("单号", "#" + r["issue"] if r["issue"] else ""), ("机器", r["node"]),
            ("Agent", r.get("agent") or "—"), ("剩余", left_cell(r, colour)),
            ("模型", r.get("model") or "—"), ("Effort", r.get("effort") or "—"),
            ("状态", STATE_SAY.get(r["state"], r["state"])), ("PR", r["pr"]), ("回收方式", r["reap"])]


# --- ONE resolver: refuses rather than guesses ---------------------------------------

def resolve(all_rows, query):
    """(rows, how) — exactly one row, or every candidate. Tried in order, the
    first step that matches anything decides: the key, the issue number, the
    whole name / title (any case), then name / title holding the query."""
    q = query.strip()
    if not q:
        return [], ""
    by_key = [r for r in all_rows if r["key"] == q]
    if by_key:
        return by_key, "key"
    if re.fullmatch(r"#?\d+", q):
        return [r for r in all_rows if r["issue"] == q.lstrip("#")], "issue"
    low = q.casefold()
    exact = [r for r in all_rows if low in (r["name"].casefold(), (r.get("title") or "").casefold())]
    if exact:
        return exact, "name"
    return [r for r in all_rows if low in r["name"].casefold() or low in (r.get("title") or "").casefold()], "part"


def one(all_rows, query):
    """The one row `query` names, or None after saying why (rc set on it)."""
    hit, _ = resolve(all_rows, query)
    if len(hit) == 1:
        return hit[0], 0
    if not hit:
        say("没有叫「%s」的会话（fleet ls 列出全部）" % query)
        return None, 3
    say("「%s」对上了 %d 个会话，请说得更准（用 #单号 或整名）：" % (query, len(hit)))
    table(hit, sys.stderr)
    return None, 4


def table(rs, out=sys.stdout):
    colour = out.isatty() and not os.environ.get("NO_COLOR")
    # 进度 (issue #2544) only when some row has a count: a list without one
    # prints byte for byte as before
    drop = set() if any(progress(r) for r in rs) else {"进度"}
    cols = [[name for name, _ in fields(rs[0]) if name not in drop]] if rs else []
    body = [[v for k, v in fields(r, colour) if k not in drop] for r in rs]
    widths = [max(cells(row[i]) for row in cols + body) for i in range(len(cols[0]))] if rs else []
    for row in cols + body:
        print("  ".join(pad(v, w) for v, w in zip(row, widths)).rstrip(), file=out)


# --- writes --------------------------------------------------------------------------

def worker_id(row):
    return row["key"][4:] if row["key"].startswith("wid:") else ""


def hub_write(tool, args, wait=30):
    """fleet-hub-write.sh <tool> → (ok, one line for a person)."""
    try:
        writer = os.environ.get("FLEET_SESSION_CLI_WRITE") or str(BIN / "fleet-hub-write.sh")
        out = subprocess.run(["bash", writer, tool, json.dumps(args, ensure_ascii=False),
                              "--wait", str(wait)], stdin=subprocess.DEVNULL,
                             capture_output=True, text=True, timeout=wait + 30)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, "没发出去 — %s" % e
    try:
        o = json.loads(out.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        why = (out.stderr.strip().splitlines() or ["入口没有回答"])[-1].replace("fleet-hub-write: ", "")
        return False, "没发出去 — " + why
    if "error" in o and not o.get("operation_id"):
        e = o["error"] if isinstance(o["error"], dict) else {"message": str(o["error"])}
        return False, "入口拒绝 — %s%s" % ((e.get("code") + ": ") if e.get("code") else "", e.get("message", ""))
    st = o.get("status", "?")
    res = o.get("result") if isinstance(o.get("result"), dict) else {}
    err = res.get("error") if isinstance(res.get("error"), dict) else {}
    if st == "succeeded":
        how = res.get("how") or res.get("delivery") or ""
        return True, "已完成" + (" · " + str(how) if how else "")
    if st in ("accepted", "running", "pending"):
        return True, "入口已受理，那台机器处理中"
    if st == "failed":
        return False, "被拒绝 — %s: %s" % (err.get("code", "?"), err.get("message", ""))
    return False, "未确认（%s）— %s" % (st, err.get("message", "op=" + str(o.get("operation_id", "?"))))


def remote_only(row, what):
    if worker_id(row):
        return True
    say("%s：「%s」不是入口上的会话（%s），在它所在的机器上用侧栏做" % (what, row["name"], row["key"]))
    return False


def ask(prompt):
    if not sys.stdin.isatty():
        return None
    try:
        return input(prompt)
    except (EOFError, KeyboardInterrupt):
        print(file=sys.stderr)
        return None


# --- the verbs -----------------------------------------------------------------------

def cmd_ls(args):
    if args not in ([], ["--json"]):
        return usage()
    rs = attach_bus(rows())
    if args == ["--json"]:
        keep = ("key", "name", "state", "issue", "node", "pr", "reap", "title", "group", "repo")
        derived = (("progress", progress), ("epic_url", epic_link))
        bus = (("agent", "agent"), ("ctx_left", "left"), ("ctx_band", "band"), ("ctx_ts", "ts"),
               ("model", "model"), ("effort", "effort"))
        print(json.dumps([dict({k: r.get(k, "") for k in keep}, **{k: r.get(v, "") for k, v in bus},
                               **{k: f(r) for k, f in derived})
                          for r in rs], ensure_ascii=False))
        return 0
    if not rs:
        say("没有会话（客户端还没拿到列表时也是这样：稍等再试）")
        return 0
    table(rs)
    return 0


def cmd_show(args):
    if len(args) != 1:
        return usage()
    row, rc = one(rows(), args[0])
    if row is None:
        return rc
    attach_bus([row])
    lines = fields(row, sys.stdout.isatty() and not os.environ.get("NO_COLOR")) + [("标题", row.get("title") or ""), ("总单", epic_link(row)), ("仓库", row.get("repo") or ""),
                           ("分组", row.get("group") or ""), ("key", row["key"])]
    w = max(cells(k) for k, _ in lines)
    for k, v in lines:
        if v:
            print("%s  %s" % (pad(k, w), v))
    return 0


def cmd_open(args):
    if len(args) != 1:
        return usage()
    row, rc = one(rows(), args[0])
    if row is None:
        return rc
    qo = lib("fleet_quickopen", "fleet-quickopen.py")
    if not qo.hand(qo.list_pane(), "jump=" + row["key"]):
        say("客户端的列表不在屏幕上，切不过去（先敲 fleet 打开客户端）")
        return 1
    print("→ %s" % row["name"])
    return 0


def cmd_rename(args):
    if len(args) < 2:
        return usage()
    new = " ".join(args[1:]).strip()
    row, rc = one(rows(), args[0])
    if row is None:
        return rc
    if not new:
        return usage()
    if not remote_only(row, "改名"):
        return 1
    ok, line = hub_write("worker_rename", {"worker_id": worker_id(row), "name": new})
    print("改名 %s → %s：%s" % (row["name"], new, line), file=sys.stdout if ok else sys.stderr)
    return 0 if ok else 1


def cmd_close(args):
    yes = "--yes" in args or "-y" in args
    rest = [a for a in args if a not in ("--yes", "-y")]
    if len(rest) != 1:
        return usage()
    row, rc = one(rows(), rest[0])
    if row is None:
        return rc
    if not remote_only(row, "回收"):
        return 1
    if not yes:
        got = ask("回收「%s」（%s）？它的窗口会关掉 [y/N] " % (row["name"], row["node"] or "?"))
        if got is None:
            say("不在终端里：确认请加 --yes")
            return 2
        if got.strip().lower() not in ("y", "yes"):
            return 1
    try:
        out = subprocess.run(["bash", "-c", '. "$1/fleet-lib.sh" && fleet_hub_reap "$2" 90', "fleet-close",
                              str(BIN), worker_id(row)], stdin=subprocess.DEVNULL, capture_output=True,
                             text=True, timeout=150)
        token = (out.stdout.strip().splitlines() or [""])[-1]
        # fleet_hub_reap's own `reap: <why>` line carries the writer's reason whole
        # (issue #2506); anything else on stderr is noise around it
        errs = [ln.strip() for ln in out.stderr.splitlines() if ln.strip()]
        reap = [ln[len("reap: "):] for ln in errs if ln.startswith("reap: ")]
        why = reap[-1] if reap else (errs[-1] if errs else "")
    except (OSError, subprocess.TimeoutExpired) as e:
        token, why = "", str(e)
    if token.startswith("reaped:"):
        print("已回收 %s（%s）" % (row["name"], token))
        return 0
    say("回收 %s：%s%s" % (row["name"], token or "没有回答", (" — " + why) if why else ""))
    return 1


def cmd_reap(args):
    if len(args) != 2:
        return usage()
    try:
        pol = lib("fleet_reap_policy", "fleet_reap_policy.py").norm(args[1])
    except Exception:
        pol = None
    if not pol:
        say("不认识的回收方式「%s」：merged[:<时长>] · done[:<时长>] · loop-end · at:<时间> · keep" % args[1])
        return 2
    row, rc = one(rows(), args[0])
    if row is None:
        return rc
    if not remote_only(row, "改回收方式"):
        return 1
    ok, line = hub_write("worker_reap_policy", {"worker_id": worker_id(row), "policy": pol})
    print("回收方式 %s → %s：%s" % (row["name"], pol, line), file=sys.stdout if ok else sys.stderr)
    return 0 if ok else 1


def cmd_answer(args):
    all_rows = rows()
    if len(args) > 2:
        return usage()
    if args:
        row, rc = one(all_rows, args[0])
        if row is None:
            return rc
    else:
        waiting = [r for r in all_rows if r["state"] == "needs"]
        if not waiting:
            say("没有在问你的会话")
            return 3
        row = waiting[0]
    if not remote_only(row, "回答"):
        return 1
    ans = args[1] if len(args) == 2 else None
    if ans is None:
        print("%s（%s）在问你 — 到它的窗口看问题：fleet open %s" % (row["name"], row["node"] or "?",
                                                         ("#" + row["issue"]) if row["issue"] else row["key"]),
              file=sys.stderr)
        ans = ask("回答（选项的编号，权限问题 y / n）：")
        if ans is None:
            say("不在终端里：回答写在命令里 — fleet answer <会话> <回答>")
            return 2
    ans = ans.strip()
    if not ans:
        return 1
    ans = {"y": "yes", "Y": "yes", "n": "no", "N": "no"}.get(ans, ans)
    ok, line = hub_write("worker_answer", {"worker_id": worker_id(row), "answer": ans}, wait=90)
    print("回答 %s：%s" % (row["name"], line), file=sys.stdout if ok else sys.stderr)
    return 0 if ok else 1


def usage():
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


def passthrough(verb, args):
    """`fleet open <url|:port|file>` / `fleet show <file>`: the scripts they were."""
    if len(args) != 1:
        return None
    a = args[0]
    if verb == "open" and (re.match(r"^[a-z][a-z0-9+.-]*://", a) or re.match(r"^:\d+(/|$)", a) or os.path.exists(a)):
        return "fleet-open.sh"
    if verb == "show" and os.path.isfile(a):
        return "fleet-show.sh"
    return None


def main(argv):
    if not argv or argv[0] not in VERBS:
        return usage()
    verb, args = argv[0], argv[1:]
    if args[:1] in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    old = passthrough(verb, args)
    if old:
        os.execv(str(BIN / old), [str(BIN / old)] + args)
    # outside the client's environment: through fleet-shell.sh, which imports it
    # and runs this again (FLEET_SHELL=1 then) — the seam reads a file instead
    if os.environ.get("FLEET_SHELL") != "1" and not os.environ.get("FLEET_SESSION_CLI_ROWS"):
        os.execv("/bin/bash", ["bash", str(BIN / "fleet-shell.sh"), "cli", verb] + args)
    return {"ls": cmd_ls, "show": cmd_show, "open": cmd_open, "rename": cmd_rename, "close": cmd_close,
            "reap": cmd_reap, "answer": cmd_answer}[verb](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
