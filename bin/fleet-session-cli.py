#!/usr/bin/env python3
"""fleet-session-cli.py — the client's sessions from the command line (issue
#2365): whatever the row menu and ⌘P can do, a command can do.

    fleet ls [--all] [--json]            every live session: 名称 · 单号 · 机器 · Agent ·
                                         剩余 · 模型 · Effort · 状态 · 在问 · PR ·
                                         回收方式 (the same rows ⌘P lists; 在问 only
                                         when one asks — issue #2538); --all adds the
                                         已结束 ones (done / exited, no issue — #2565)
    fleet ls --services [--json]         every background service and scheduled
                                         task registered on your machines: 机器 ·
                                         登录 · 名称 · 类型 · 状态 · 上次 · 下次 ·
                                         最近日志, a failed one red (fleet-services.py,
                                         issue #2526)
    fleet show <会话>                    one session, every field
    fleet open <会话>                    the client onto it (as ↵ on its ⌘P line)
    fleet rename <会话> <新名…>          its display name (the hub's worker_rename,
                                         issue #2358 — the key never changes)
    fleet close <会话> [--yes]           reap it (the hub's worker_reap; asks y/n
                                         on a terminal unless --yes)
    fleet close --test [--yes]           reap every test row at once (issue #2505)
    fleet reap <会话> <方式>             its reap policy — merged[:<dur>] ·
                                         done[:<dur>] · loop-end · at:<time> · keep
                                         (the hub's worker_reap_policy, issue #2368)
    fleet answer [<会话>] [<回答>]        answer a session that asks you — the first
                                         one waiting when none is named; the answer
                                         asked on the terminal when none is given,
                                         under the question's own words (#2538)
    fleet service stop|start|restart <名称>
    fleet task stop|start|restart <名称>
    fleet task run <名称> --now
    fleet task schedule <名称> (--at HH:MM | --cron '…') [--tz Z]
                                         your background service / scheduled task on
                                         whichever managed machine holds it (the
                                         hub's service_control, issue #2527;
                                         --machine M / --login L when the name is
                                         on more than one). The rest of fleet
                                         service|task (add · rm · ls · logs · cred)
                                         runs on that machine itself

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

WITH NO CLIENT TMUX (issue #3004, EPIC #2999 C7 — the thin client, `fleet
--thin`, has none): the same verbs run ON THE HOME MACHINE — `fleet-thin.py
--run -- python3 <bin>/fleet-session-cli.py --home <verb> …`, one ssh over the
line a connection takes. `--home` (also what a person on a fleet machine gets
when no client runs there) reads this machine's fleet: its session (the first
live one), the fleet server's environment, the same row producer — so the rows
are every machine's, as the hub's cache has them. `open` there switches the
newest thin 看台 with a client attached (fleet_view.go — the one switch road).
The road, in order: FLEET_SHELL=1 → here as before; the old client running (and
FLEET_CLIENT is not `thin`) → through it, byte for byte; a fleet live on this
machine → --home here; else → the home over --run.

Exit: 0 done · 1 the action failed, or no client running · 2 usage · 3 no such
session · 4 more than one session matches.
剩余 · 模型 · Effort (issue #2431) are each session's measurement bus as its own
header shows it (conf/statusline.sh stamps it): another machine's off the hub's
session cache (global/remote_<fleet>, the node's inventory columns 24-28), this
machine's off its window when the cache has none. 剩余 is coloured on a terminal
— >50 green, 20–50 amber, <20 or at the handoff line red — and a reading older
than 5 minutes is grey with 「(N 分钟前)」; a node too old to report it shows —.

A session the TEST identity's client placed (`fleet --test-identity`, issue
#2505: the node's @test_identity, field 26 of the cache) is no row on the list;
here it is listed with 「（测试）」 after its name, and `close --test` reaps them all.

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
VERBS = ("ls", "show", "open", "rename", "close", "reap", "answer", "service", "task")
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
        f += [""] * (28 - len(f))
        m = {"agent": f[6], "test": f[25] == "1"}
        if any(f[20:25]):
            m.update(left=f[20], band=f[21], ts=f[22], model=f[23], effort=f[24])
        if f[5] == "needs" and (f[26] or f[27]):
            m.update(ask_kind=f[26], ask=f[27])
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
           "\t#{@ctx_band}\t#{@ctx_ts}\t#{?@model,#{@model},#{?#{==:#{@cc_agent},codex},#{@cc_model},}}\t#{@effort}"
           "\t#{?#{==:#{@test_identity},1},1,}"
           "\t#{?#{==:#{@claude_state},needs},#{@claude_needs},}\t#{?#{==:#{@claude_state},needs},#{@claude_needs_detail},}")
    try:
        got = subprocess.run(["tmux", "-u", "-L", sess, "list-windows", "-t", "=" + sess, "-F", fmt],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    out = {}
    for line in got.splitlines():
        f = (line.split("\t") + [""] * 10)[:10]
        if f[0] in keys:
            m = {"agent": f[1], "test": f[7] == "1"}
            if any(f[2:7]):
                m.update(left=f[2], band=f[3], ts=f[4], model=f[5], effort=f[6])
            if f[9].strip():
                m.update(ask_kind=ASK_KIND.get(f[8], ""), ask=f[9])
            out[f[0]] = m
    return out


# @claude_needs subtype → the kind the agent says (issue #2538)
ASK_KIND = {"perm": "permission", "ask": "question", "auth": "auth"}
ASK_SAY = {"permission": "权限", "question": "问题", "auth": "登录"}
ASK_COL = 40


def attach_bus(rs):
    """Every row gets agent · left · band · ts · model · effort ('' = unknown),
    and — a session that waits on you — ask_kind · ask: what it asks, in its own
    words (issue #2538)."""
    bus = bus_cache()
    bus.update(bus_local({r["key"] for r in rs if r["key"].startswith("@") and r["key"] not in bus}))
    for r in rs:
        m = bus.get(r["key"], {})
        r["agent"] = agent_say(m.get("agent", ""))
        r["test"] = bool(m.get("test"))
        for k in ("left", "band", "ts", "model", "effort"):
            r[k] = m.get(k, "")
        ask = re.sub(r"[\x00-\x1f\x7f]+", " ", m.get("ask", "")).strip()[:200] if r["state"] == "needs" else ""
        r["ask"], r["ask_kind"] = ask, (m.get("ask_kind", "") if ask else "")
    return rs


def ask_text(r, short=False):
    """在问: `权限：Bash: git push…` — the kind's word and the words, the first
    ASK_COL characters when `short` (the ls column); "" when it asks nothing."""
    text = r.get("ask") or ""
    if not text:
        return ""
    if short and len(text) > ASK_COL:
        text = text[:ASK_COL] + "…"
    word = ASK_SAY.get(r.get("ask_kind") or "", "")
    return (word + "：" if word else "") + text


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


def fields(r, colour=False, short=True):
    """The columns `ls` prints and `show` names, in order — 在问 (issue #2538)
    clipped for `ls`, whole for `show` (short=False)."""
    return [("名称", r["name"] + ("（测试）" if r.get("test") else "")), ("进度", progress(r)), ("单号", "#" + r["issue"] if r["issue"] else ""), ("机器", r["node"]),
            ("Agent", r.get("agent") or "—"), ("剩余", left_cell(r, colour)),
            ("模型", r.get("model") or "—"), ("Effort", r.get("effort") or "—"),
            ("状态", STATE_SAY.get(r["state"], r["state"])), ("在问", ask_text(r, short)), ("PR", r["pr"]),
            ("回收方式", r["reap"])]


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
    # 在问 (issue #2538) likewise only when some row asks you something
    if not any(r.get("ask") for r in rs):
        drop.add("在问")
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
    if "--services" in args:
        rest = [a for a in args if a != "--services"]
        if rest not in ([], ["--json"]):
            return usage()
        return lib("fleet_services", "fleet-services.py").main(rest)
    if any(a not in ("--json", "--all") for a in args) or len(set(args)) != len(args):
        return usage()
    rs = rows()
    if "--all" not in args:
        # the list's own 已结束 group (issue #2565): over, so off the default list
        rs = [r for r in rs if not r.get("ended")]
    rs = attach_bus(rs)
    if "--json" in args:
        keep = ("key", "name", "state", "issue", "node", "pr", "reap", "title", "group", "repo", "test")
        derived = (("progress", progress), ("epic_url", epic_link))
        bus = (("agent", "agent"), ("ctx_left", "left"), ("ctx_band", "band"), ("ctx_ts", "ts"),
               ("model", "model"), ("effort", "effort"), ("ask_kind", "ask_kind"), ("ask", "ask"))
        print(json.dumps([dict({k: r.get(k, False if k == "test" else "") for k in keep}, **{k: r.get(v, "") for k, v in bus},
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
    lines = fields(row, sys.stdout.isatty() and not os.environ.get("NO_COLOR"), short=False) + [("标题", row.get("title") or ""), ("总单", epic_link(row)), ("仓库", row.get("repo") or ""),
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
    if HOME[0]:
        return home_open(qo, row)
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
    if rest == ["--test"]:
        return close_tests(yes)
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
    return reap_row(row)


def close_tests(yes):
    """`fleet close --test` (issue #2505): every test row, one question for all."""
    rs = [r for r in attach_bus(rows()) if r.get("test")]
    if not rs:
        print("没有测试会话")
        return 0
    table(rs)
    if not yes:
        got = ask("回收这 %d 个测试会话？它们的窗口会关掉 [y/N] " % len(rs))
        if got is None:
            say("不在终端里：确认请加 --yes")
            return 2
        if got.strip().lower() not in ("y", "yes"):
            return 1
    rc = 0
    for r in rs:
        if not remote_only(r, "回收") or reap_row(r):
            rc = 1
    return rc


def reap_row(row):
    """The hub's worker_reap on one row (fleet_hub_reap) → 0 reaped, 1 not."""
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
        attach_bus([row])
        where = ("#" + row["issue"]) if row["issue"] else row["key"]
        if row.get("ask"):
            # the question itself (issue #2538): its words are the prompt's 题干
            kind = ASK_SAY.get(row.get("ask_kind") or "", "")
            print("%s（%s）在问你%s：\n\n  %s\n" % (row["name"], row["node"] or "?",
                                              "（%s）" % kind if kind else "", row["ask"]), file=sys.stderr)
        else:
            print("%s（%s）在问你 — 到它的窗口看问题：fleet open %s" % (row["name"], row["node"] or "?", where),
                  file=sys.stderr)
        ans = ask({"permission": "回答（y 允许 / n 拒绝）：", "question": "回答（选项的编号或你的话）："}.get(
            row.get("ask_kind") or "", "回答（选项的编号，权限问题 y / n）："))
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


# --- with no client tmux (issue #3004) -----------------------------------------------

HOME = [False]


def sh_lib(snippet):
    """One line out of fleet-lib.sh (the fleet's conf first, as its scripts do)."""
    try:
        return subprocess.run(["bash", "-c", '[ -f "$1/../fleet.conf" ] && . "$1/../fleet.conf"; . "$1/fleet-lib.sh" && ' + snippet,
                               "fleet-session-cli", str(BIN)], stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, timeout=15).stdout.strip().split("\n")[0].strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def fleet_here():
    """The first fleet live on this machine (fleet_sockets), "" on a client-only computer."""
    if not (BIN / "fleet-lib.sh").exists():
        return ""
    return sh_lib("fleet_sockets 2>/dev/null")


def client_running():
    if os.environ.get("FLEET_CLIENT") == "thin" or not (BIN / "fleet-shell.sh").exists():
        return False
    try:
        return subprocess.run(["bash", str(BIN / "fleet-shell.sh"), "running"], stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def road():
    """client (the old one's environment) · here (--home on this machine) · home (over --run)."""
    seam = os.environ.get("FLEET_SESSION_CLI_ROAD")
    if seam in ("client", "here", "home"):
        return seam
    if client_running():
        return "client"
    return "here" if fleet_here() else "home"


def home_setup():
    """--home: this machine's fleet — FLEET_SESSION, the fleet server's environment
    (its TMPDIR is where the hub's cache lives) and TMUX at its socket."""
    HOME[0] = True
    if os.environ.get("FLEET_SESSION_CLI_ROWS"):
        return True
    sess = os.environ.get("FLEET_SESSION") or fleet_here()
    if not sess:
        say("这台机器上没有在跑的 fleet")
        return False
    os.environ["FLEET_SESSION"] = sess
    try:
        envs = subprocess.run(["tmux", "-L", sess, "show-environment", "-g"], stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=5).stdout
        sock = subprocess.run(["tmux", "-L", sess, "display-message", "-p", "#{socket_path}"], stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        envs, sock = "", ""
    for line in envs.splitlines():
        k, eq, v = line.partition("=")
        if eq and re.match(r"^(FLEET_|CCQUOTA_|TMPDIR$|XDG_)", k) and k not in ("FLEET_SESSION", "FLEET_SHELL"):
            os.environ[k] = v
    if sock:
        os.environ["TMUX"] = sock + ",0,0"
    return True


def views_newest():
    """The newest thin 看台 here with a client attached: kind thin, its attach alive,
    no left= (fleet-remote-view.sh attach --thin's registry row)."""
    d = Path(os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet")) / "remote-views"
    best, since = "", -1
    try:
        names = os.listdir(str(d))
    except OSError:
        return ""
    for n in names:
        if "-via-" in n or n.startswith(".") or not (d / n).is_file():
            continue
        try:
            f = (d / n).read_text().split("\n", 1)[0].split("\t")
        except OSError:
            continue
        if len(f) < 5 or f[2] != "thin" or any(c.startswith("left=") for c in f[5:]):
            continue
        try:
            os.kill(int(f[4]), 0)
            t = int(f[3])
        except (ValueError, OSError):
            continue
        if t > since:
            best, since = n, t
    return best


def home_open(qo, row):
    """`fleet open` on the home: the person's newest thin 看台 goes there."""
    vid = views_newest()
    if not vid:
        say("没有连着的 fleet --thin：先敲 fleet --thin，再 fleet open")
        return 1
    fv = lib("fleet_view", "fleet_view.py")
    target = worker_id(row) or row["key"]
    rc = fv.go(qo, vid, target, "cli", "", {"machine": row.get("node") or ""})
    if rc == 0:
        print("→ %s" % row["name"])
        return 0
    if rc == 3:
        print("→ %s（%s 正在连）" % (row["name"], row.get("node") or "?"))
        return 0
    say("切不过去（%s）" % ("会话已不在" if rc == 4 else "看台不在了"))
    return 1


def over_home(verb, args):
    """No client tmux here and no fleet: the verb on the home machine."""
    rbin = os.environ.get("FLEET_REMOTE_BIN") or ".claude/fleet/bin"
    tty = sys.stdin.isatty() and sys.stdout.isatty() and (
        (verb == "answer" and len(args) < 2) or (verb == "close" and "--yes" not in args))
    argv = [sys.executable or "python3", str(BIN / "fleet-thin.py"), "--run"] + (["--tty"] if tty else []) + \
        ["--", "python3", rbin + "/fleet-session-cli.py", "--home", verb] + list(args)
    os.execv(argv[0], argv)


# --- background services and scheduled tasks (issue #2527) ----------------------------

SVC_ACTIONS = {"stop": "stop", "start": "start", "restart": "restart", "run": "run_now", "schedule": "set_schedule"}
SVC_SAY = {"stop": "停", "start": "起", "restart": "重启", "run": "现在跑一次", "schedule": "改计划"}


def cmd_svc(kind, args):
    """fleet service|task <verb> <名称> …: the entry's (machine, login) off the one
    services table (fleet-services.py — the hub's, else this machine's daemon),
    then the hub's service_control down that login's lane. A hub write that never
    left this computer falls back to this machine's own fleet-<kind>.sh (sudo)."""
    verbs = ("stop", "start", "restart") + (("run", "schedule") if kind == "task" else ())
    if len(args) < 2 or args[0] not in verbs:
        say("用法：fleet %s %s <名称>%s" % (kind, "|".join(verbs),
                                            "（run 要 --now；schedule 要 --at HH:MM 或 --cron '…'，可加 --tz）"
                                            if kind == "task" else ""))
        return 2
    verb, name, rest = args[0], args[1], args[2:]
    opts, now_flag, i = {}, False, 0
    while i < len(rest):
        a = rest[i]
        if a == "--now" and verb == "run":
            now_flag, i = True, i + 1
        elif a in ("--machine", "--login") or (verb == "schedule" and a in ("--at", "--cron", "--tz")):
            if i + 1 >= len(rest):
                say("%s 要一个值" % a)
                return 2
            opts[a[2:]], i = rest[i + 1], i + 2
        else:
            say("fleet %s %s：不认识 %s" % (kind, verb, a))
            return 2
    if verb == "run" and not now_flag:
        say("fleet task run %s --now —— 不加 --now 就按计划跑" % name)
        return 2
    if verb == "schedule" and ("at" in opts) == ("cron" in opts):
        say("fleet task schedule %s --at HH:MM | --cron 'm h dom mon dow' [--tz Asia/Shanghai]" % name)
        return 2
    fs = lib("fleet_services", "fleet-services.py")
    rows, _, _ = fs.table_rows()
    hits = [(label, host, r) for label, host, r in rows if r.get("name") == name
            and (verb in ("stop", "start", "restart") or r.get("kind") == "task")
            and (not opts.get("machine") or fs.short(opts["machine"]) in (fs.short(host), label))
            and (not opts.get("login") or r.get("login") == opts["login"])]
    if not hits:
        say("没有叫「%s」的%s（fleet ls --services 列出你登记的；客户端刚开时稍等再试）"
            % (name, "定时任务" if kind == "task" else "后台服务"))
        return 3
    if len(hits) > 1:
        say("「%s」不止一个，用 --machine / --login 指定：" % name)
        for label, host, r in hits:
            say("  %s  %s" % (label, r.get("login")))
        return 4
    label, host, r = hits[0]
    req = {"machine": host, "login": r.get("login"), "name": name, "action": SVC_ACTIONS[verb]}
    req.update((k, v) for k, v in opts.items() if k in ("at", "cron", "tz"))
    ok, line = hub_write("service_control", req)
    local = BIN / ("fleet-%s.sh" % kind)
    if not ok and line.startswith("没发出去") and local.exists():
        say("%s（%s），改在本机做" % (line, label))
        os.execv("/bin/bash", ["bash", str(local), verb, name] + local_args(verb, opts, now_flag))
    print("%s %s/%s/%s：%s" % (SVC_SAY[verb], label, r.get("login"), name, line), file=sys.stdout if ok else sys.stderr)
    if ok and verb == "run":
        print("会话稍后出现在 fleet ls（%s-<日期>-now<时分>）" % name)
    return 0 if ok else 1


def local_args(verb, opts, now_flag):
    """The local fleet-<kind>.sh's options after `<verb> <name>`."""
    if verb == "run":
        return ["--now"] if now_flag else []
    if verb == "schedule":
        return [x for k in ("at", "cron", "tz") if k in opts for x in ("--" + k, opts[k])]
    return []


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
    home = argv[:1] == ["--home"]
    argv = argv[1:] if home else argv
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
    # (`ls --services` reads a cache file, never the client: no re-run)
    if home:
        if not home_setup():
            return 1
    elif os.environ.get("FLEET_SHELL") != "1" and not os.environ.get("FLEET_SESSION_CLI_ROWS") \
            and not (verb == "ls" and "--services" in args) and verb not in ("service", "task"):
        # the old client, byte for byte; else this machine's fleet; else the home (#3004)
        how = road()
        if how == "client":
            os.execv("/bin/bash", ["bash", str(BIN / "fleet-shell.sh"), "cli", verb] + args)
        if how == "home":
            return over_home(verb, args)
        if not home_setup():
            return 1
    # every verb sees the test identity's sessions the list hides (issue #2505)
    os.environ["FLEET_ROWS_TEST"] = "1"
    return {"ls": cmd_ls, "show": cmd_show, "open": cmd_open, "rename": cmd_rename, "close": cmd_close,
            "reap": cmd_reap, "answer": cmd_answer,
            "service": lambda a: cmd_svc("service", a), "task": lambda a: cmd_svc("task", a)}[verb](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
