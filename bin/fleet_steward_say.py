#!/usr/bin/env python3
"""fleet_steward_say.py — the steward's plain lines: what a person reads instead
of the decision sheet's table. The `[decision]` message to the orchestrator says
one line a thing (brief()): the row's `say` (a plain line the steward session
writes: `fleet-steward-tick.sh say --row ID --text …`), else the worker's words
with code, paths, numbers and implementation nouns taken out (plain()), grouped by
what the PERSON has to do (要扫码 · 要选 · 要授权 · 要钱) and the same question
asked by several sessions merged into one line.

What is left of the steward's PAGE (issue #2735, bin/fleet_steward_page.py): the
hosted HTML page, its number band and @orch_page went with the resident seat
(issue #3118) — the decision sheet is the steward holder's panel.
"""
import re
import subprocess
from pathlib import Path

import fleet_decision as fd

BIN = Path(__file__).resolve().parent
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
