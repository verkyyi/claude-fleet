#!/usr/bin/env python3
"""fleet_steward_page.py — the steward's page: what a person reads instead of the
decision sheet's table (issue #2735, EPIC #2668 follow-up). The steward's beat
(bin/fleet_steward.py) calls refresh(); `fleet-steward-tick.sh page` runs it by
hand (--print writes the HTML to stdout, --demo renders the fixed sample rows).

ONE page a day, at ONE fixed link: `$FLEET_CONF_DIR/fleets/<sess>/steward/page.html`
(the day's copy kept beside it as page-<date>.html), hosted by doc-preview — shared
once with no expiry, `share.sh --refresh` on every later change, so the URL the
orchestrator relayed and the 「新任务」 menu's 「管家页」 keep working. The URL is
kept in global/steward.state.json `page` and stamped as @orch_page on the
orchestrator's window — fleet-control-read.sh's `orchpage=` carries it to the
client (fleet-hub-sessions.sh: `page=<url>` on orch_<sess>).

The page is the epic-page frame (skills/epic-page/template.html — its <style> is
read from there, never copied) under the decider's-view rules
(`epic-page-surface.sh --lint` passes):

  - the number band: 今天问了 · 你答了 · 按默认走 · 停放 · 待你动手 — the first three
    off `fleet-steward-stats.sh asks --days 1`, the rest off the park book and the
    「待你动手」 list;
  - 要你定的事: one line per thing — 「**一句话** · 建议：… · 不答就：… · 截止 HH:MM」,
    grouped by what the PERSON has to do (要扫码 · 要选 · 要授权 · 要钱), the same
    question asked by several sessions merged into one line; where it came from,
    the worker's own words and every technical id in a fold;
  - 待你动手 and today's 已按默认走 on the same page, each 默认 with its one
    sentence to overturn it.

The surface sentence is the row's `say` (a plain line the steward session writes:
`fleet-steward-tick.sh say --row ID --text …`), else the worker's words with code,
paths, numbers and implementation nouns taken out (plain()). Seams (selftest):
FLEET_STEWARD_PAGE=0 (no page), FLEET_STEWARD_PAGE_SHARE (a share command, argv
split on spaces; `0` = write the file, share nothing — the selftest gate's
FLEET_SKIP_GLOBAL_CONF=1 means the same), FLEET_STEWARD_STATS_CMD (prints the
`asks` table: argv).
"""
import datetime as dt
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import fleet_decision as fd

BIN = Path(__file__).resolve().parent
TEMPLATE = BIN.parent / "skills" / "epic-page" / "template.html"
ACTIONS = ("scan", "choose", "grant", "money")   # the order a person reads them in

SCAN_RE = re.compile(r"扫码|二维码|验证码|扫一下|登录|登陆|手机|QR|log ?in|scan", re.I)
GRANT_RE = re.compile(r"授权|权限|允许|批准|同意|放行|token|permission|approve|sudo|密码", re.I)
MONEY_RE = re.compile("|".join(re.escape(w) for w in (fd.never_words().get("money") or fd.NEVER_WORDS["money"])), re.I)

# What a person reads instead of an implementation noun (the lint's JARGON list).
PLAIN_SUB = (("webhook", "通知"), ("worker", "执行会话"), ("daemon", "后台程序"), ("token", "凭据"),
             ("hook", "自动规则"), ("iframe", "内嵌页"), ("JSON", "数据"), ("HTML", "网页"),
             ("API", "对接"), ("SDK", "开发包"), ("CDN", "加速"), ("CSP", "安全规则"), ("conf", "设置"),
             ("PR", "改动"), ("CI", "自动检查"),
             ("配置项", "设置"), ("接口", "对接"), ("注入", "插入"), ("渲染", "显示"), ("埋点", "统计"),
             ("回执", "收到确认"), ("域名", "网址"), ("状态码", "出错代号"), ("字段", "栏目"),
             ("参数", "设置值"), ("脚本", "工具"), ("回调", "回应"), ("鉴权", "验证"), ("令牌", "凭据"),
             ("中间件", "中间层"), ("沙箱", "隔离环境"), ("缓存", "暂存"), ("数据库", "数据"),
             ("哈希", "指纹"), ("正则", "匹配规则"), ("重定向", "跳转"), ("序列化", "转换"),
             ("钩子", "自动规则"), ("进程", "程序"), ("守护", "后台"), ("子单", "小单"))
CODE_RE = re.compile(r"`[^`]*`")
URL_RE = re.compile(r"https?://[A-Za-z0-9._~:/?#@!$&*+,;=%-]+")
REF_RE = re.compile(r"(?:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#[0-9]+|\bgh:[A-Za-z0-9._/#-]+|\b(?:issue|scratch)-[0-9]+\b",
                    re.A)
KEY_RE = re.compile(r"(?<![A-Za-z0-9])[CR][0-9]{1,2}(?![0-9])")
# ASCII only: a Chinese word next to a file name is never part of it
FILE_RE = re.compile(r"(?<![\w/])[\w.~-]*(?:/[\w.-]+)*\.(?:sh|md|json|html?|js|mjs|ts|tsx|py|ya?ml|conf|txt|log|css)(?![\w])"
                     r"|(?<![\w])[.~]?/?[\w.-]+(?:/[\w.-]+)+/?", re.A)
STATUS_RE = re.compile(r"(?<![0-9.])[45]0[0-9](?![0-9])")
# brackets left holding only the joining words of what was taken out: 「（见 和 ）」
HOLLOW_RE = re.compile(r"[（(][\s见和或及与、,，:：]*[)）]|[「『]\s*[」』]")
CJK = "\u3000-\u303f\u4e00-\u9fff\uff00-\uffef"
CJK_GAP_RE = re.compile(r"(?<=[%s]) +(?=[%s])" % (CJK, CJK))
NORM_RE = re.compile(r"[\s\W\d_]+", re.U)
MAX_SAY = 60


_TEXT = None


def tr(key, *args):
    """fleet-ui-lang.sh's strings (共同约定 11): the page's own, the todo kinds."""
    global _TEXT
    if _TEXT is None:
        try:
            out = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "steward_page_", "steward_todo_kind_"],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            out = b""
        parts = out.decode("utf-8", "replace").split("\0")
        _TEXT = dict(zip(parts[0::2], parts[1::2]))
    text = _TEXT.get(key, key)
    for arg in args:
        text = text.replace("\x01", str(arg), 1)
    return text.replace("\x01", "")


def esc(s):
    return html.escape(str(s or ""), quote=True)


# ---- the surface sentence --------------------------------------------------------

def plain(text, limit=MAX_SAY):
    """The worker's words as a person reads them: code, links, paths, issue and
    member numbers out, implementation nouns in plain words, one short line."""
    s = str(text or "").replace("\n", " ")
    for rx in (CODE_RE, URL_RE, REF_RE, FILE_RE, KEY_RE):
        s = rx.sub(" ", s)
    s = STATUS_RE.sub(tr("steward_page_status_word"), s)
    for word, say in PLAIN_SUB:
        if word.isascii():
            s = re.sub(r"(?<![A-Za-z])%s(?![A-Za-z])" % re.escape(word), say, s, flags=re.I)
        else:
            s = s.replace(word, say)
    s = HOLLOW_RE.sub("", s)
    s = re.sub(r"\s+", " ", s)
    # a token taken out of a Chinese sentence leaves a space no one would write
    s = CJK_GAP_RE.sub("", s).strip(" ：:，,；;、-—·").lstrip("的")
    if len(s) > limit:
        s = s[:limit - 1].rstrip() + "…"
    return s


def say_of(row):
    return plain(row.get("say") or row.get("item")) or tr("steward_page_untitled")


def action_of(row):
    """What the person has to DO about a row: scan · grant · money · choose."""
    text = " ".join(str(row.get(k) or "") for k in ("say", "item", "suggest"))
    kind = row.get("kind") or ""
    if kind == "never:money" or MONEY_RE.search(text):
        return "money"
    if SCAN_RE.search(text):
        return "scan"
    if kind in ("never:rule", "never:publish") or GRANT_RE.search(text):
        return "grant"
    return "choose"


def _norm(s):
    return NORM_RE.sub("", plain(s, 400)).lower()


def merge(rows):
    """[(action, [rows…])] — the same question (its plain words and its
    suggestion, numbers aside) asked by several sessions is ONE line."""
    groups = {}
    order = []
    by_id = {r.get("id"): r for r in rows}
    # the open asks on ONE ticket are one thing first (fleet_decision.group, the
    # rule the orchestrator's panel draws — issue #2832), then the same words
    for g in fd.group(rows):
        rs = [by_id[i] for i in g["ids"] if i in by_id]
        head = rs[-1]
        key = (action_of(head), _norm(head.get("say") or head.get("item")), _norm(head.get("suggest")),
               fd.default_text(head))
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].extend(rs)
    out = []
    for a in ACTIONS:
        lines = [groups[k] for k in order if k[0] == a]
        if lines:
            out.append((a, lines))
    return out


def due_text(row, now_t):
    if fd.row_default(row) is fd.WAIT or fd.never(row) or not row.get("due"):
        return ""
    t = fd.parse_time(row["due"]).astimezone(now_t.tzinfo)
    return t.strftime("%H:%M") if t.date() == now_t.date() else t.strftime("%m-%d %H:%M")


# ---- the numbers -----------------------------------------------------------------

def numbers(st, now_t):
    """{asked, person, defaulted, parked, todo} for the band."""
    day = now_t.strftime("%Y-%m-%d")
    n = {"asked": 0, "person": 0, "defaulted": 0, "parked": 0, "todo": 0}
    cmd = os.environ.get("FLEET_STEWARD_STATS_CMD")
    argv = cmd.split() if cmd else ["bash", str(BIN / "fleet-steward-stats.sh"), "asks", "--days", "1"]
    try:
        out = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             universal_newlines=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    for line in out.splitlines():
        f = line.split("\t")
        if len(f) >= 5 and f[0] == day and all(x.isdigit() for x in f[1:5]):
            n["asked"], n["person"], n["defaulted"] = int(f[1]), int(f[2]), int(f[4])
    # a question the beat met today counts even when the call log is elsewhere
    met = sum(1 for r in st.d["rows"].values() if (r.get("asked") or "")[:10] == day and not r.get("followup"))
    n["asked"] = max(n["asked"], met)
    n["defaulted"] = max(n["defaulted"], len(decided_today(st, now_t)))
    try:
        n["parked"] = len((json.loads((fd_conf() / "global" / "park.json").read_text()).get("parked") or {}))
    except (OSError, ValueError, AttributeError):
        pass
    items = ((st.d.get("todo") or {}).get("items") or {}).values()
    n["todo"] = sum(1 for i in items if i.get("state") not in ("done", "skipped"))
    return n


HANDOFF_FAIL_SECS = 86400   # a stored-not-cleared handoff stays on the page a day


def handoff_failed(now_t):
    """Handoffs stored but never cleared (issue #2937): a pane whose newest
    `handoff-complete` / `handoff-failed` row on the context-ladder ledger
    (bin/fleet-ladder-log.sh, where fleet-handoff-cycle.sh writes both) is a
    failure younger than a day — the session goes on in the conversation it meant
    to leave, and only grows. Oldest first; [] when none or no ledger."""
    d = os.environ.get("FLEET_HANDOFF_LOG_DIR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "logs")
    try:
        with open(os.path.join(d, "context-ladder.log"), encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    last = {}
    for ln in lines:
        f = ln.split("\t")
        if ln.startswith("#") or len(f) < 9 or f[2] not in ("handoff-complete", "handoff-failed"):
            continue
        try:
            t = int(f[0])
        except ValueError:
            continue
        last[(f[3], f[4])] = {"t": t, "step": f[2], "session": f[3], "pane": f[4], "window": f[5],
                              "ctx": f[6], "reason": f[8]}
    now = now_t.timestamp()
    return sorted((r for r in last.values() if r["step"] == "handoff-failed" and now - r["t"] <= HANDOFF_FAIL_SECS),
                  key=lambda r: r["t"])


def stalled_drivers(st):
    """Batches whose heartbeat stopped a TTL ago while their driver's window is
    still here and waits on no one (issue #2958): [{epic, mins, window, wid}]."""
    return sorted((st.d.get("stalled") or {}).values(), key=lambda r: r.get("epic") or "")


def fd_conf():
    return Path(os.environ.get("FLEET_CONF_DIR") or (Path.home() / ".config" / "claude-fleet"))


def decided_today(st, now_t):
    day = now_t.date()
    out = []
    for r in st.d["rows"].values():
        if r.get("state") != "defaulted":
            continue
        at = r.get("closed_at") or r.get("due") or ""
        try:
            t = fd.parse_time(at).astimezone(now_t.tzinfo)
        except (ValueError, TypeError):
            continue
        if t.date() == day:
            out.append((t, r))
    out.sort(key=lambda x: x[0])
    return out


# ---- the page --------------------------------------------------------------------

def style():
    try:
        # the element, at a line's start — the template's comments say "<style>" too
        m = re.search(r"^<style>$.*?^</style>$", TEMPLATE.read_text(encoding="utf-8"), re.S | re.M)
        return m.group(0) if m else ""
    except OSError:
        return ""


def kv(pairs):
    return "<dl class=\"kv\">%s</dl>" % "".join(
        "<dt>%s</dt><dd>%s</dd>" % (esc(k), v) for k, v in pairs if v)


def link(url, text):
    return "<a href=\"%s\">%s</a>" % (esc(url), esc(text)) if url else esc(text)


def line_parts(rows, now_t):
    """One merged line's four parts: (what, suggestion, if unanswered, due or "")."""
    # one ticket asked again: its latest ask speaks (fleet_decision.group); several
    # tickets with the same words: the nearest deadline
    if len({r.get("src") for r in rows}) == 1:
        r0 = max(rows, key=lambda r: r.get("asked") or "")
    else:
        r0 = min(rows, key=lambda r: r.get("due") or "9")
    return (say_of(r0), plain(r0.get("suggest")) or tr("steward_page_no_suggest"),
            plain(fd.default_text(r0)) or fd.default_text(r0), due_text(r0, now_t))


def open_rows(st):
    # a driver that is not moving (issue #2958) is the person's to look at: its
    # line is under 待你动手 (stalled_drivers), not a thing to decide
    rows = [r for r in st.d["rows"].values() if r.get("state") == "open" and not r.get("followup")
            and r.get("local") != "stalled"]
    rows.sort(key=lambda r: (not fd.never(r), r.get("due") or "9", r.get("asked") or ""))
    return rows


def merged_text(rows):
    """How a line that stands for several asks says so: one ticket asked again
    (fleet_decision.group's words), else several sessions asking the same."""
    if len({r.get("src") for r in rows}) == 1:
        return fd.group(rows)[0]["from"]
    return tr("steward_page_merged_fmt", len(rows))


def brief(rows, now_t):
    """The page's decision lines as plain text, for the orchestrator to say to the
    person word for word: [(line, [row ids])], numbered as on the page."""
    out, n = [], 0
    for action, lines in merge(rows):
        for rs in lines:
            n += 1
            what, sug, dflt, due = line_parts(rs, now_t)
            text = "%s · %s · %s%s · %s%s" % (tr("steward_page_nth_fmt", n), what, tr("steward_page_suggest"), sug,
                                              tr("steward_page_default"), dflt)
            text += (" · " + tr("steward_page_due_fmt", due)) if due else ""
            text += "（%s）" % tr("steward_page_act_" + action)
            if len(rs) > 1:
                text += " · " + merged_text(rs)
            out.append((text, [r["id"] for r in rs]))
    return out


def decision_block(n, rows, now_t):
    what, sug, dflt, due = line_parts(rows, now_t)
    parts = ["<strong>%s</strong>" % esc(what),
             "%s<strong>%s</strong>" % (esc(tr("steward_page_suggest")), esc(sug)),
             "%s%s" % (esc(tr("steward_page_default")), esc(dflt))]
    if due:
        parts.append(esc(tr("steward_page_due_fmt", due)))
    merged = (" <span class=\"pill muted\">%s</span>" % esc(merged_text(rows))
              if len(rows) > 1 else "")
    fold = []
    for r in rows:
        fold.append(kv([(tr("steward_page_kv_src"), link(r.get("url"), r.get("src", ""))),
                        (tr("steward_page_kv_said"), esc(r.get("item", ""))),
                        (tr("steward_page_kv_suggest"), esc(r.get("suggest", ""))),
                        (tr("steward_page_kv_kind"), esc(r.get("kind", ""))),
                        (tr("steward_page_kv_asked"), esc(r.get("asked", ""))),
                        (tr("steward_page_kv_id"), esc(r.get("id", "")))]))
    return ("<div class=\"ob\" id=\"d-%d\"><p><span class=\"pill new\">%s</span> %s%s</p>\n"
            "<details class=\"fold\"><summary>%s</summary>%s</details></div>"
            % (n, esc(tr("steward_page_nth_fmt", n)), " · ".join(parts), merged,
               esc(tr("steward_page_fold")), "".join(fold)))


def render(st, sess, now_t, nums=None):
    """The page's HTML (str). Pure but for the numbers it reads."""
    nums = nums if nums is not None else numbers(st, now_t)
    groups = merge(open_rows(st))
    n_lines = sum(len(lines) for _, lines in groups)
    todo = [i for i in ((st.d.get("todo") or {}).get("items") or {}).values()
            if i.get("state") not in ("done", "skipped")]
    todo.sort(key=lambda i: (i.get("due") or "9", i.get("id") or ""))
    # a followup row on the sheet (a refused release, a hub deploy) is the person's to do, too
    todo_rows = [r for r in st.d["rows"].values() if r.get("state") == "open" and r.get("followup")]
    # a handoff that stored its doc but never cleared the conversation (issue #2937)
    stuck = handoff_failed(now_t)
    stalled = stalled_drivers(st)
    decided = decided_today(st, now_t)
    out = ["<!doctype html>", "<html lang=\"%s\">" % ("zh" if tr("steward_page_lang") == "zh" else "en"),
           "<head>", "<meta charset=\"utf-8\">",
           "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">",
           "<title>%s</title>" % esc(tr("steward_page_title_fmt", now_t.strftime("%m-%d"))),
           "<!-- fleet:steward-page v=1 session=%s day=%s -->" % (esc(sess), now_t.strftime("%Y-%m-%d")),
           style(), "</head>", "<body>", "<div class=\"wrap\">",
           "<p class=\"eyebrow\">%s</p>" % esc(tr("steward_page_eyebrow_fmt", now_t.strftime("%Y-%m-%d"),
                                                     fd.show_time(now_t))),
           "<h1>%s</h1>" % esc(tr("steward_page_h1")),
           "<p class=\"sub\">%s</p>" % esc(tr("steward_page_sub_fmt", n_lines, nums["todo"] + len(todo_rows) + len(stuck) + len(stalled))),
           "<div class=\"verdict\">"]
    for key, cls in (("asked", ""), ("person", ""), ("defaulted", ""), ("parked", "warn" if nums["parked"] else ""),
                     ("todo", "warn" if nums["todo"] + len(todo_rows) + len(stuck) + len(stalled) else "")):
        val = nums[key] + (len(todo_rows) + len(stuck) + len(stalled) if key == "todo" else 0)
        out.append("  <div class=\"v%s\"><div class=\"n\">%d</div><div class=\"k\">%s</div></div>"
                   % (" " + cls if cls else "", val, esc(tr("steward_page_k_" + key))))
    out.append("</div>")

    out += ["<section id=\"signoff\">", "<span id=\"open\"></span>",
            "<h2>%s</h2>" % esc(tr("steward_page_decide_h"))]
    if not groups:
        out.append("<p class=\"lede\">%s</p>" % esc(tr("steward_page_decide_none")))
    else:
        out.append("<p class=\"lede\">%s</p>" % esc(tr("steward_page_nod")))
        n = 0
        for action, lines in groups:
            out.append("<h3 class=\"grp\">%s</h3>" % esc(tr("steward_page_act_" + action)))
            for rs in lines:
                n += 1
                out.append(decision_block(n, rs, now_t))
    out.append("</section>")

    out += ["<section id=\"todo\">", "<h2>%s</h2>" % esc(tr("steward_page_todo_h"))]
    if not todo and not todo_rows and not stuck and not stalled:
        out.append("<p class=\"lede\">%s</p>" % esc(tr("steward_page_todo_none")))
    else:
        out.append("<ul>")
        for i in todo:
            due = (" · " + esc(tr("steward_page_todo_due_fmt", i["due"]))) if i.get("due") else ""
            srcs = "、".join(s.get("epic", "") for s in i.get("sources") or [])
            out.append("<li><p><strong>%s</strong>：%s%s</p><details class=\"fold\"><summary>%s</summary>%s</details></li>"
                       % (esc(tr("steward_todo_kind_" + (i.get("kind") or "human").replace("-", "_"))),
                          esc(plain(i.get("what"), 120)), due, esc(tr("steward_page_fold")),
                          kv([(tr("steward_page_kv_src"), esc(srcs)), (tr("steward_page_kv_said"), esc(i.get("what"))),
                              (tr("steward_page_kv_id"), esc(i.get("id")))])))
        for r in todo_rows:
            out.append("<li><p><strong>%s</strong> · %s<strong>%s</strong></p><details class=\"fold\"><summary>%s</summary>%s"
                       "</details></li>" % (esc(say_of(r)), esc(tr("steward_page_suggest")),
                                            esc(plain(r.get("suggest")) or tr("steward_page_no_suggest")),
                                            esc(tr("steward_page_fold")),
                                            kv([(tr("steward_page_kv_src"), link(r.get("url"), r.get("src", ""))),
                                                (tr("steward_page_kv_said"), esc(r.get("item"))),
                                                (tr("steward_page_kv_id"), esc(r.get("id")))])))
        for r in stuck:
            t = dt.datetime.fromtimestamp(r["t"])
            out.append("<li><p><strong>%s</strong> · %s</p><details class=\"fold\"><summary>%s</summary>%s</details></li>"
                       % (esc(tr("steward_page_handoff_fmt", r["window"], t.strftime("%H:%M"), r["ctx"])),
                          esc(tr("steward_page_handoff_do")), esc(tr("steward_page_fold")),
                          kv([(tr("steward_page_kv_src"), esc("%s · %s" % (r["session"], r["pane"]))),
                              (tr("steward_page_kv_said"), esc(r["reason"]))])))
        for r in stalled:
            out.append("<li><p><strong>%s</strong> · %s</p></li>"
                       % (esc(tr("steward_page_stalled_fmt", "#" + (r.get("epic") or "").rsplit("#", 1)[-1],
                                 r.get("mins", ""))), esc(tr("steward_page_stalled_do", r.get("window", "")))))
        out.append("</ul>")
    out.append("</section>")

    out += ["<section id=\"decided\">", "<h2>%s</h2>" % esc(tr("steward_page_decided_h"))]
    if not decided:
        out.append("<p class=\"lede\">%s</p>" % esc(tr("steward_page_decided_none")))
    else:
        out.append("<ul>")
        for t, r in decided:
            short = say_of(r)
            out.append("<li><p>%s<br><span class=\"layer\">%s</span></p><details class=\"fold\"><summary>%s</summary>%s"
                       "</details></li>"
                       % (esc(tr("steward_page_decided_line_fmt", t.strftime("%H:%M"), short,
                                 plain(r.get("default")) or fd.default_text(r))),
                          esc(tr("steward_page_undo_fmt", plain(short, 16))), esc(tr("steward_page_fold")),
                          kv([(tr("steward_page_kv_src"), link(r.get("url"), r.get("src", ""))),
                              (tr("steward_page_kv_said"), esc(r.get("item"))),
                              (tr("steward_page_kv_default"), esc(r.get("default"))),
                              (tr("steward_page_kv_id"), esc(r.get("id")))])))
        out.append("</ul>")
    out.append("</section>")

    out += ["<section id=\"ops\">", "<details class=\"fold\"><summary>%s</summary>" % esc(tr("steward_page_how_h")),
            "<p>%s</p>" % esc(tr("steward_page_how")),
            "<pre>fleet-steward-stats.sh asks --days 1\nfleet-steward-stats.sh stuck\n"
            "fleet-steward-tick.sh followups\nfleet-steward-tick.sh answer --row &lt;id&gt; --text &lt;决定&gt; --by person"
            "</pre></details>", "</section>",
            "<footer>%s</footer>" % esc(tr("steward_page_foot_fmt", fd.show_time(now_t))),
            "</div>", "</body>", "</html>", ""]
    return "\n".join(out)


# ---- keep, host, stamp ------------------------------------------------------------

def on():
    return (os.environ.get("FLEET_STEWARD_PAGE") or fd._conf_val("FLEET_STEWARD_PAGE") or "1") != "0"


def share_argv():
    v = os.environ.get("FLEET_STEWARD_PAGE_SHARE")
    if v == "0" or (v is None and os.environ.get("FLEET_SKIP_GLOBAL_CONF") == "1"):
        return None
    if v:
        return v.split()
    s = Path.home() / ".claude" / "skills" / "doc-preview" / "share.sh"
    return [str(s)] if s.exists() else None


def host(path, st):
    """Share the page once (no expiry), refresh it after — the URL never changes.
    Returns the URL, "" when nothing hosts it."""
    argv = share_argv()
    page = st.d.setdefault("page", {})
    if not argv:
        return page.get("url", "")
    try:
        if page.get("url") and page.get("path") == str(path):
            r = subprocess.run(argv + ["--refresh"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               universal_newlines=True, timeout=120)
            if r.returncode == 0:
                return page["url"]
        r = subprocess.run(argv + ["--ttl", "0", str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return page.get("url", "")
    m = re.search(r"^READY (\S+)", r.stdout or "", re.M)
    if r.returncode == 0 and m:
        page["url"], page["path"] = m.group(1), str(path)
    return page.get("url", "")


def refresh(sess, st, now_t, force=False):
    """Render, keep and host today's page when it changed → its URL ("" none).
    The caller holds the state lock and saves."""
    if not on():
        return ""
    body = render(st, sess, now_t)
    # the footer's time changes on every render; the page changed only when the rest did
    sha = hashlib.sha1(re.sub(r"<footer>.*?</footer>", "", body).encode()).hexdigest()
    page = st.d.setdefault("page", {})
    d = fd_conf() / "fleets" / sess / "steward"
    path = d / "page.html"
    if not force and page.get("sha") == sha and page.get("day") == now_t.strftime("%Y-%m-%d") and path.exists():
        return page.get("url", "")
    d.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(body, encoding="utf-8")
    os.replace(str(tmp), str(path))
    try:
        shutil.copyfile(str(path), str(d / ("page-%s.html" % now_t.strftime("%Y-%m-%d"))))
    except OSError:
        pass
    page["sha"], page["day"], page["at"] = sha, now_t.strftime("%Y-%m-%d"), fd.iso(now_t)
    return host(path, st)


def demo_state(now_t):
    """Six rows like the 2026-10-09 sheet: five drill leftovers asking the same
    thing (one line on the page), one money question."""
    class S:
        d = {"rows": {}, "todo": {"items": {}}}
    base = now_t.replace(hour=9, minute=40, second=0, microsecond=0)
    for i, n in enumerate((2690, 2693, 2694, 2697, 2699)):
        _, row = fd.ask_body("演练留下的 `scratch-%d` 窗口和 worktree 要不要现在回收？" % (40 + i),
                             "回收：演练已经结束，留着只占位置", "回收", None, None,
                             now=fd.iso(base + dt.timedelta(minutes=i)), row_id="demo-drill-%d" % n)
        row.update(src="gh:verkyyi/claude-fleet#%d" % n, state="open",
                   url="https://github.com/verkyyi/claude-fleet/issues/%d#issuecomment-%d" % (n, 1000 + n))
        S.d["rows"][row["id"]] = row
    _, row = fd.ask_body("要不要开一台云机器跑 #2701 的 SDK 兼容测试？", "不开，用 mini2 跑", None, None, None,
                         now=fd.iso(base + dt.timedelta(minutes=30)), row_id="demo-money")
    row.update(src="gh:verkyyi/claude-fleet#2701", state="open",
               url="https://github.com/verkyyi/claude-fleet/issues/2701#issuecomment-1")
    S.d["rows"][row["id"]] = row
    _, row = fd.ask_body("合并后要不要先扫码登录 m4 的 Claude 账号？", "现在扫，晚上不跑批", "等明早再扫", None, None,
                         now=fd.iso(base - dt.timedelta(hours=3)), row_id="demo-done")
    row.update(src="gh:verkyyi/claude-fleet#2688", state="defaulted", closed_at=fd.iso(base + dt.timedelta(minutes=50)),
               url="https://github.com/verkyyi/claude-fleet/issues/2688#issuecomment-2")
    S.d["rows"][row["id"]] = row
    S.d["todo"]["items"]["demo-stable"] = {"id": "demo-stable", "kind": "stable", "state": "open",
                                           "what": "把今天合进来的 4 个改动发到各台机器",
                                           "sources": [{"epic": "gh:verkyyi/claude-fleet#2668"}]}
    return S()
