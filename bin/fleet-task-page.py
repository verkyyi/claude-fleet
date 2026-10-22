#!/usr/bin/env python3
"""fleet-task-page.py — the ONE task design page: render it, turn it into a task's
words, stamp its number (T661).

  fleet-task-page.py render <spec.json|-> [-o page.html]
      → the page: epic-page's <head> (template.html's <style>, verbatim) + the
        task layout — eyebrow · title · subtitle · number band · #problem ·
        #cause · #metrics · #charter · #members · #risks · #signoff(+#open) ·
        #evidence (上线后怎么验收). The spec's strings are HTML fragments (<code>,
        <strong> welcome); the frame is this script's, never re-typed.
  fleet-task-page.py body <page.html> [--link URL] [--nod TEXT] [--max BYTES] [--split DIR]
      → the task's words (markdown), BOTH layers: every fold written out, at any
        depth (NZP2: a 代码位置 fold inside a step's evidence or a card's 技术细节).
        The record's request is capped (16 KB with its envelope), so the words are
        measured as they travel (UTF-8 JSON, fleet-task-record.sh); over
        --max (default 13000) the folds move to the page one kind at a time —
        the 代码位置 folds (details.code), the cause's evidence, then 改法's 技术细节,
        then the rest — each replaced by 「（…：见设计页）」. Still over ⇒ exit 1,
        nothing printed, the message naming --split.
        --split DIR: one task's words per member card (DIR/NN-<key>.md), each with
        the link and every shared section, the other cards one line; over --max a
        part moves the shared folds first, its own card's 技术细节 last; prints
        「path<TAB>bytes<TAB>card」 per part. Fewer than two cards, or a part over
        --max with every fold moved ⇒ exit 1, nothing written.
  fleet-task-page.py stamp <page.html> <task id> [-o out]
      → the eyebrow's 「任务设计」 becomes 「任务 <id>」 (idempotent).
  fleet-task-page.py compare <compare.json|->
      → ONE 改前 / 改后 block (div.cmp), the same one a task card renders — the
        EPIC pages (/fleet-epic-plan, /fleet-epic-report) paste it into a card's
        upper layer; template.html carries the CSS and the state switch.
  fleet-task-page.py ids
      → the section ids a task page carries, one per line.
  fleet-task-page.py fb-body <page.html> <table> <version> [-o out]
      → the page's REAL body tag (the one a parser sees — never the tag's spelling
        inside a comment or a script) carries data-fb-table / data-fb-version.
        Refuses a page whose body is empty or whose content sits in its head.
  fleet-task-page.py check <page.html>
      → exit 0 when the body holds the content; else one line per problem, exit 1
        (T869: a 「replace the first <body>」 once hit a script comment and put the
        whole page into the head's script — the page opened blank).

The spec (plugins/fleet-epic/skills/epic-page/task-page.example.json is a whole one):
  repo · date · title (≤ 16 字) · sub (one sentence ≤ 30 字: where it stops) ·
  kind ("fix" | "feature": a feature's #cause is 「为什么要做」) · band [{n,k}] ·
  problem [li] (one fact a line, ≤ 25 字, the number first) ·
  cause {lede, steps [{step, what, evidence [li]}], other [{kind, title, ref?,
  excerpt?, text?}]} · metrics [{name, now, target, how [li] | str}] ·
  charter {do [li], dont [li]} · members [{key, name, line, what, compare?,
  tech [[label, text]]}] · risks [{head, text}] · risks_tech [li] ·
  signoff [[事项, 建议] | {q, rec, default, options [..]}] · signoff_note · evidence [{what, where, pass, status
  (pending | done | passed | failed), proof? {img | text | html | url, caption}, screenshots?
  [{url, mobile, desktop, caption?, at?}]}] ·
  evidence_note · feedback {table, version, poll} · replies_done {item: {state
  (adopted | declined), note}} · footer · css (the prototypes' own rules, one
  <style> after the frame's).
  T764: each 原因 step opens on ITS evidence and each 指标 row on how IT is
  measured — a step / row / card with nothing to open is a plain line, no ▸;
  evidence no step owns goes in `other`, grouped by kind (code · log · scene ·
  ref). The 上线证据 is the 「上线后怎么验收」 card: one item per proof, its 通过标准,
  a status and a slot the worker fills after the switch — the report's 已上线.
  A300: an item done / passed carries `screenshots` — the PRODUCTION page shot after
  the switch (Playwright on the live URL), phone 390 + desktop 1440 as a pair, each a
  path beside the page or a file of the same live page; drawn as thumbnails that open
  full size. Without them the lint WARNs task-evidence-shot.
  `feedback` makes the page answer itself (a live page): 「有意见」 under every step
  and card, 按建议 / 改成… on every 需要你定的事 row, one 点头 button — each POSTs
  {item, choice, note, version} to ./_data/<table> (members-only); item keys are
  cause-<step> · card-<key> · signoff-<n> · nod.
  Old specs still render: steps [[step, what]] + cause.evidence (one fold),
  metrics [[指标, 现在, 目标]] + metrics_how, evidence (one line) — the lint WARNs
  them (fold-row · accept).
  compare (T699) = {before: PANE, after: PANE | [STATE…], states?: [STATE…]}:
  PANE = {html | img (a path beside the page), alt?, note}; STATE = PANE + label.
  More than one 改后 state ⇒ buttons switch them (no JS: the first shows; printed:
  all). `proto` (a link to a separate prototype page) still renders, and the lint
  WARNs it.

Exit: 0 done · 1 over the cap (body) / a broken page (check, fb-body, render) · 2 usage / unreadable input.
"""
import html
import json
import os
import re
import sys
from html.parser import HTMLParser

IDS = ["problem", "cause", "metrics", "charter", "members", "risks", "signoff", "evidence"]
HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(HERE, "..", "plugins", "fleet-epic", "skills", "epic-page", "template.html")


def die(rc, msg):
    print("fleet-task-page: " + msg, file=sys.stderr)
    sys.exit(rc)


def read(path):
    try:
        return sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()
    except OSError as e:
        die(2, "cannot read %s (%s)" % (path, e))


# ---- render -------------------------------------------------------------------

def head(title):
    t = os.environ.get("FLEET_TASK_PAGE_TEMPLATE") or TEMPLATE
    src = read(t)
    i = src.find("</head>")
    if i < 0:
        die(2, "no </head> in " + t)
    h = src[: i + len("</head>")]
    return re.sub(r"<title>.*?</title>", "<title>%s</title>" % html.escape(title), h, count=1, flags=re.S)


def ul(items):
    return "<ul>\n" + "".join("<li>%s</li>\n" % x for x in items) + "</ul>\n"


def table(head_row, rows, num_cols=()):
    out = ['<div class="scroll">\n<table>\n<thead><tr>%s</tr></thead>\n<tbody>\n'
           % "".join("<th>%s</th>" % h for h in head_row)]
    for r in rows:
        out.append("<tr>%s</tr>\n" % "".join(
            '<td class="num">%s</td>' % c if i in num_cols else "<td>%s</td>" % c for i, c in enumerate(r)))
    out.append("</tbody>\n</table>\n</div>\n")
    return "".join(out)


def xrows(kind, head_row, rows, num_cols=(), say=None):
    """A table whose every row opens on its OWN detail (T764): a row with a detail is a
    <details class="xr"> (▸ at the end), a row without one a plain <div class="xr"> — no
    arrow, nothing to tap. rows = [(cells, detail_html)]. say(i) ⇒ the row's feedback
    key: a 「有意见」 button in the row and its one-line form right under it."""
    def cells(cs, i):
        c = "".join('<span class="%s">%s</span>' % ("num" if j in num_cols else "c", x) for j, x in enumerate(cs))
        return c + (say_btn(say(i)) if say else "")
    fb = " fb" if say else ""
    out = ['<div class="xt %s%s">\n<div class="xh">%s%s<i></i></div>\n'
           % (kind, fb, "".join("<span>%s</span>" % h for h in head_row), "<span></span>" if say else "")]
    for i, (cs, det) in enumerate(rows):
        if det:
            out.append('<details class="xr"><summary>%s<i></i></summary>\n<div class="xd">\n%s</div>\n</details>\n'
                       % (cells(cs, i), det))
        else:
            out.append('<div class="xr">%s<i></i></div>\n' % cells(cs, i))
        if say:
            out.append(say_form(say(i)))
    out.append("</div>\n")
    return "".join(out)


# ---- 页内反馈 (T764) ------------------------------------------------------------
# The page is a live page: the operator answers ON it. Every form POSTs one row
# {item, choice, note, version} to the page's own data table (./_data/<table>,
# members_only — only the workspace's people); the orchestrator reads them with
# list_data_rows since=<next_since> and hands each to the session doing the work.
FB = {}


def say_btn(item):
    return '<button type="button" class="say-btn" data-say="%s">有意见</button>' % html.escape(item, quote=True)


def done_mark(item):
    """已采纳 / 未采纳 for an item, from the spec's replies_done (the page also reads the
    live `<table>_done` table on load — a mark written there needs no new version)."""
    d = (FB.get("done") or {}).get(item)
    if not d:
        return ""
    word, cls = {"adopted": ("已采纳", ""), "declined": ("未采纳", "muted")}.get(d.get("state"), (d.get("state", ""), "muted"))
    return '<p class="fb-done" data-for="%s"><span class="pill %s">%s</span> %s</p>\n' % (
        html.escape(item, quote=True), cls, word, d.get("note", ""))


def say_form(item):
    """One item's 「有意见」 (a step, a card): its state line — filled by the frame's script
    from the page's own table — and a one-line form, hidden until its button is tapped."""
    e = html.escape(item, quote=True)
    return ('<div class="fbi" data-item="%s" data-kind="say"><span class="fbs"></span>'
            '<form class="fbf say" id="say-%s" data-item="%s" hidden><input name="note" placeholder="一句话写意见" '
            'maxlength="300"><button>提交</button><span class="st"></span></form></div>\n%s' % (e, e, e, done_mark(item)))


def choose_form(item, default="按建议", options=()):
    """A 需要你定的事 row (T764 v5): its options laid out IN the row — the default first,
    marked 「默认」, then the others, then 「改成…」 (a note) — a tap picks and posts that
    one; nothing picked counts as the default. The state line says when, and 撤回."""
    e = html.escape(item, quote=True)
    opts = [default] + [x for x in options if x != default]
    btn = "".join('<button type="button" class="opt%s" data-v="%s">%s%s</button>' % (
        " dflt" if i == 0 else "", html.escape(plain(x), quote=True), x, '<span class="dm">默认</span>' if i == 0 else "")
        for i, x in enumerate(opts))
    return ('<div class="fbi" data-item="%s" data-kind="pick" data-default="%s">'
            '<form class="fbf pick" data-item="%s"><div class="opts">%s<button type="button" class="opt free" data-v="改成">改成…</button></div>'
            '<div class="freebox" hidden><input name="note" placeholder="改成什么" maxlength="300"><button>提交</button></div>'
            '<span class="st"></span></form><span class="fbs"></span></div>\n%s'
            % (e, html.escape(plain(default), quote=True), e, btn, done_mark(item)))


def signoff_row(i, row):
    """[事项, 建议] (old) or {q, rec, default, options}: the default is what counts when
    nobody picks — say it on the row (「默认：…」)."""
    if isinstance(row, dict):
        k, v, d, opts = row.get("q", ""), row.get("rec", ""), row.get("default") or "按建议", row.get("options") or []
    else:
        k, v, d, opts = row[0], row[1], "按建议", []
    return ('<div class="so"><div class="sk">%s</div><div class="sv">%s</div>\n%s</div>\n'
            % (k, v, choose_form("signoff-%d" % i, d, opts)))


def detail(v):
    """A row's detail: a list ⇒ <ul>, a string ⇒ one <p>, empty ⇒ nothing (no fold)."""
    if not v:
        return ""
    return ul(v) if isinstance(v, list) else "<p>%s</p>\n" % v


STATUS = {"pending": ("待取", "muted"), "done": ("已取", ""), "passed": ("已通过", ""), "failed": ("未通过", "crit")}
VIEWPORTS = (("mobile", "390", "手机 390"), ("desktop", "1440", "桌面 1440"))


def shots(items):
    """线上实拍 (A300): each item a pair {url, mobile, desktop, caption} — the production page
    shot after the switch at 390 and 1440 wide, a path beside the page or a file of the same
    live page. Each picture is a thumbnail that opens full size; a lone string is one shot."""
    if not items:
        return ""
    o = ['<div class="shots">\n']
    for s in items:
        s = {"desktop": s} if isinstance(s, str) else s
        o.append('<div class="sp">')
        for key, vp, word in VIEWPORTS:
            if s.get(key):
                src = html.escape(s[key], quote=True)
                o.append('<a class="shot" href="%s" target="_blank" rel="noopener"><img src="%s" alt="%s" data-vp="%s" loading="lazy"><span>%s</span></a>'
                         % (src, src, word, vp, word))
        cap = s.get("caption", "")
        if s.get("url"):
            cap += (" · " if cap else "") + '<a href="%s">线上地址</a>' % html.escape(s["url"], quote=True)
        if s.get("at"):
            cap += (" · " if cap else "") + html.escape(s["at"])
        o.append('<p class="scap">线上实拍%s</p></div>\n' % ("：" + cap if cap else ""))
    o.append("</div>\n")
    return "".join(o)


def proof(p):
    """The evidence slot: empty ⇒ a dashed 待回填 box; else the picture, the terminal
    output or the link the worker filled in after the switch."""
    if not p:
        return '<div class="slot">待回填：截图 / 终端输出 / 链接</div>\n'
    o = ""
    if p.get("img"):
        o += '<img src="%s" alt="%s" loading="lazy">' % (html.escape(p["img"], quote=True), html.escape(p.get("alt", ""), quote=True))
    if p.get("text"):
        o += "<pre>%s</pre>" % html.escape(p["text"])
    if p.get("html"):
        o += p["html"]
    if p.get("url"):
        o += '<a href="%s">%s</a>' % (html.escape(p["url"], quote=True), html.escape(p.get("label") or p["url"]))
    if p.get("caption"):
        o += "<figcaption>%s</figcaption>" % p["caption"]
    return '<figure class="got">%s</figure>\n' % o


def accept(items, lede, live=True):
    """上线后怎么验收 (T764): one card per piece of evidence — what · where / how · pass.
    The plan (live False) lists just those; once building / reporting (spec `phase`
    build | report) each item also wears its status and the slot the worker fills
    after the switch — the filled card IS the report's 已上线 column."""
    o = ['<h2>上线后怎么验收</h2>\n<p class="lede">%s</p>\n<div class="acc">\n' % lede]
    for i, e in enumerate(items, 1):
        word, cls = STATUS.get(e.get("status") or "pending", (e.get("status"), "muted"))
        o.append('<div class="ev"%s><div class="eh"><span class="en">%d</span><strong>%s</strong>%s</div>\n<dl class="kv">\n'
                 % (' data-status="%s"' % html.escape(e.get("status") or "pending", quote=True) if live else "",
                    i, e.get("what", ""), '<span class="pill %s">%s</span>' % (cls, word) if live else ""))
        if e.get("where"):
            o.append("  <dt>在哪取</dt><dd>%s</dd>\n" % e["where"])
        o.append('  <dt>通过标准</dt><dd>%s</dd>\n</dl>\n' % (e.get("pass") or '<span class="miss">（未写）</span>'))
        o.append((proof(e.get("proof")) + shots(e.get("screenshots")) if live else "") + "</div>\n")
    o.append("</div>\n")
    return "".join(o)


KINDS = [("code", "代码"), ("log", "日志"), ("scene", "现场"), ("ref", "外部资料")]


def other(items):
    """Evidence no step / metric / card owns (T764): grouped by kind, one title line each,
    tap for the original — a code item shows file:line and a line or two of it."""
    if not any(isinstance(x, dict) for x in items):
        return fold("其他证据", ul(items))                      # compat: a plain list
    o = ['<div class="oth"><h3>其他证据</h3>\n']
    for k, word in KINDS + [("", "其他")]:
        grp = [x for x in items if isinstance(x, dict) and (x.get("kind") or "") == k
               or (k == "" and isinstance(x, dict) and x.get("kind") not in dict(KINDS))]
        if not grp:
            continue
        o.append('<div class="og"><span class="ok">%s</span>\n' % word)
        for x in grp:
            inner = ""
            if x.get("ref"):
                inner += '<p class="oref"><code>%s</code></p>' % html.escape(x["ref"])
            if x.get("excerpt"):
                inner += "<pre>%s</pre>" % html.escape(x["excerpt"])
            if x.get("text"):
                inner += "<p>%s</p>" % x["text"]
            o.append('<details class="oi"><summary>%s</summary><div class="xd">%s</div></details>\n' % (x.get("title", ""), inner)
                     if inner else '<div class="oi">%s</div>\n' % x.get("title", ""))
        o.append("</div>\n")
    o.append("</div>\n")
    return "".join(o)


def fold(summary, inner):
    return '<details class="fold">\n<summary>%s</summary>\n%s</details>\n' % (summary, inner)


def plain(frag):
    """An HTML fragment as one line of text (for data-say, the words' summary)."""
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]*>", "", frag or ""))).strip()


def pane(p):
    if p.get("img"):
        inner = '<img src="%s" alt="%s" loading="lazy">' % (
            html.escape(p["img"], quote=True), html.escape(p.get("alt") or p.get("label") or "", quote=True))
    else:
        inner = p.get("html", "")
    o = '<div class="pane">%s</div>\n' % inner
    if p.get("note"):
        o += '<p class="note">%s</p>\n' % p["note"]
    return o


def compare(c):
    """The 改前 / 改后 block (T699): 改前 one pane from today, 改后 one pane or several
    states. The ONE renderer — task cards and the EPIC pages alike."""
    before = c.get("before") or {}
    after = c.get("states") or c.get("after") or {}
    states = after if isinstance(after, list) else [after]
    multi = len(states) > 1

    def say(tag, p):
        t = tag + (" · " + plain(p["label"]) if p.get("label") else "")
        n = plain(p.get("note"))
        return html.escape(t + ("：" + n if n else ""), quote=True)

    o = ['<div class="cmp">\n<div class="cols">\n']
    o.append('<div class="col" data-say="%s"><div class="tag">改前</div>\n%s</div>\n' % (say("改前", before), pane(before)))
    o.append('<div class="col"><div class="tag new">改后</div>\n')
    for i, st in enumerate(states):
        o.append('<div class="st"%s data-say="%s">\n' % ("" if i == 0 else " hidden", say("改后", st)))
        if multi:
            o.append('<div class="stl">%s</div>\n' % st.get("label", "状态 %d" % (i + 1)))
        o.append(pane(st) + "</div>\n")
    o.append("</div>\n</div>\n")
    if multi:
        o.append('<div class="tabs">%s</div>\n' % "".join(
            '<button type="button"%s aria-pressed="%s">%s</button>' % (
                ' class="on"' if i == 0 else "", "true" if i == 0 else "false", st.get("label", "状态 %d" % (i + 1)))
            for i, st in enumerate(states)))
    o.append("</div>\n")
    return "".join(o)


def render(spec):
    g = spec.get
    FB.clear()
    if g("feedback"):
        FB.update(g("feedback"))
        FB["done"] = g("replies_done") or {}
    feature = g("kind") == "feature"
    h = head("%s" % g("title", "任务设计"))
    if g("css"):
        h = h.replace("</head>", "<style>\n%s\n</style>\n</head>" % g("css"), 1)
    body_tag = "<body>"
    if FB:      # the frame's script posts the forms to this table, stamped with this version
        body_tag = '<body data-fb-table="%s" data-fb-version="%s">' % (
            html.escape(str(FB.get("table") or "replies"), quote=True), html.escape(str(FB.get("version") or ""), quote=True))
    o = [h, "\n%s\n<div class=\"wrap\">\n\n" % body_tag]
    o.append('<p class="eyebrow">任务设计 · %s · %s</p>\n' % (g("repo", ""), g("date", "")))
    o.append("<h1>%s</h1>\n" % g("title", ""))
    o.append('<p class="sub">%s</p>\n\n' % g("sub", ""))
    if g("band"):
        o.append('<div class="verdict">\n' + "".join(
            '  <div class="v"><div class="n">%s</div><div class="k">%s</div></div>\n' % (b["n"], b["k"])
            for b in g("band")) + "</div>\n\n")
    # T764: 现象 and 原因 are ONE section (问题与原因): the symptom first — one sentence, or a few
    # short facts — then the cause step by step; #cause stays as an anchor inside it
    pb = g("problem") or []
    o.append('<section id="problem">\n<h2>%s</h2>\n%s<span id="cause"></span>\n'
             % ("现在的样子与为什么要做" if feature else "问题与原因",
                '<p class="sym">%s</p>\n' % pb if isinstance(pb, str) else ul(pb)))
    c = g("cause") or {}
    if c.get("lede"):
        o.append('<p class="lede">%s</p>\n' % c["lede"])
    if c.get("points"):
        o.append(ul(c["points"]))
    steps = c.get("steps") or []
    if any(isinstance(st, dict) for st in steps):      # T764: each step carries its own evidence
        o.append(xrows("c2", ["一步", "发生了什么"], [
            ((st.get("step", ""), st.get("what", "")), detail(st.get("evidence"))) if isinstance(st, dict)
            else (tuple(st), "") for st in steps],
            say=(lambda i: "cause-%s" % plain(steps[i]["step"] if isinstance(steps[i], dict) else steps[i][0])) if FB else None))
    elif steps:
        o.append(table(["一步", "发生了什么"], steps))
    if c.get("evidence"):                               # compat: the old one fold for every step
        o.append(fold("证据（代码与现场）" if not feature else "依据", ul(c["evidence"])))
    if c.get("other"):
        o.append(other(c["other"]))
    o.append("</section>\n\n")
    # T764: 指标 and 目标与范围 are ONE section (目标): the metric rows, then 做 / 不做
    o.append('<section id="metrics">\n<h2>目标</h2>\n')
    ms = g("metrics") or [["⟨指标⟩", "本批不量", "本批不量"]]
    if any(isinstance(m, dict) for m in ms):            # T764: each row carries how it is measured
        o.append(xrows("c3", ["指标", "现在", "目标"], [
            ((m.get("name", ""), m.get("now", ""), m.get("target", "")), detail(m.get("how"))) if isinstance(m, dict)
            else (tuple(m), "") for m in ms], (1, 2)))
    else:
        o.append(table(["指标", "现在", "目标"], ms, (1, 2)))
    if g("metrics_how"):                                # compat: the old one 怎么量 fold
        o.append(fold("怎么量", ul(g("metrics_how"))))
    ch = g("charter") or {}
    o.append('<span id="charter"></span>\n<h3>做</h3>\n%s<h3>不做</h3>\n%s</section>\n\n'
             % (ul(ch.get("do") or []), ul(ch.get("dont") or [])))
    o.append('<section id="members">\n<h2>解决方案</h2>\n\n')
    for m in g("members") or []:
        ct = '<span class="ct"><strong>%s</strong><span class="cg">%s</span></span>' % (m.get("name", ""), m.get("line", ""))
        if not any(m.get(k) for k in ("what", "compare", "proto", "tech")):   # T764: nothing to open ⇒ no ▸
            o.append('<div class="ob" id="m-%s">\n<div class="card">%s</div>\n</div>\n\n' % (m.get("key", ""), ct))
            continue
        o.append('<div class="ob" id="m-%s">\n<details class="card">\n' % m.get("key", ""))
        o.append("<summary>%s</summary>\n" % ct)
        if m.get("what"):
            o.append('<dl>\n  <dt>做什么</dt><dd>%s</dd>\n</dl>\n' % m["what"])
        if m.get("compare"):
            o.append(compare(m["compare"]))
        if m.get("proto"):
            o.append('<p class="proto"><a href="%s">▶ 打开可交互原型</a></p>\n' % html.escape(m["proto"], quote=True))
        if m.get("tech"):
            o.append(fold("技术细节", "<dl>\n" + "".join(
                "  <dt>%s</dt><dd>%s</dd>\n" % (k, v) for k, v in m["tech"]) + "</dl>\n"))
        if FB:
            o.append('<p class="say-row">%s</p>\n%s' % (say_btn("card-" + m.get("key", "")), say_form("card-" + m.get("key", ""))))
        o.append("</details>\n</div>\n\n")
    o.append("</section>\n\n")
    o.append('<section id="risks">\n<h2>可能出的问题</h2>\n')
    o.append(ul(["<strong>%s</strong> — %s" % (r.get("head", ""), r.get("text", "")) for r in g("risks") or []]))
    if g("risks_tech"):
        o.append(fold("技术风险", ul(g("risks_tech"))))
    o.append("</section>\n\n")
    o.append('<section id="signoff">\n<span id="open"></span>\n<h2>需要你定的事</h2>\n')
    if g("signoff") and FB:                              # T764: each row's options laid out in it, the default marked
        o.append('<div class="sol">\n' + "".join(signoff_row(i, r) for i, r in enumerate(g("signoff"), 1)) + "</div>\n")
    elif g("signoff"):
        o.append(table(["事项", "建议"], [[r.get("q", ""), r.get("rec", "")] if isinstance(r, dict) else r for r in g("signoff")]))
    o.append('<p class="lede" style="margin-top:14px">%s</p>\n'
             % (g("signoff_note") or "点头即全部按建议，派一个执行会话做，一个改动说明合并。"))
    if FB:      # one 全部按建议; every item answers on its own
        o.append('<div class="fbi" data-item="nod" data-kind="nod"><form class="fbf nod" data-item="nod" data-choice="全部按建议">'
                 '<button>全部按建议</button><span class="st"></span></form><span class="fbs"></span></div>\n%s' % done_mark("nod"))
        o.append('<p class="fb-note">ⓘ 每一项都能单独改、单独撤回；你的表态存在本页，编排每 %s读一次、转给做这件事的会话，'
                 '处理后在那一项上标已采纳 / 未采纳。执行会话已动手后再撤回，它会回你能不能退回。</p>\n'
                 % FB.get("poll", "12 分钟"))
    o.append("</section>\n\n")
    ev = g("evidence")
    if isinstance(ev, list):                            # T764: the acceptance card, by phase
        live = (g("phase") or "plan") != "plan"
        o.append('<section id="evidence">\n%s</section>\n\n' % accept(ev, g("evidence_note") or (
            "换版后执行会话逐条取证、回填到下面的空位；全部「已取」且达标，这一栏就是报告的「已上线」。" if live
            else "上线后逐条取这些证据；每条都达到通过标准，才算上线。"), live))
    else:                                               # compat: one line, folded
        o.append('<section id="evidence">\n%s</section>\n\n' % fold("上线证据", "<pre>%s</pre>\n" % (ev or "")))
    o.append("<footer>%s</footer>\n\n</div>\n</body>\n</html>\n" % (g("footer") or "本页私密，仅你可见。"))
    return "".join(o)


# ---- body ---------------------------------------------------------------------

class Words(HTMLParser):
    """The page as markdown, both layers. A fold whose kind is in `drop` becomes
    one 「（…：见设计页）」 line instead of its content."""
    BLOCK = {"p", "li", "dd", "dt", "pre", "h1", "h2", "h3", "summary", "tr", "footer"}

    def __init__(self, drop):
        super().__init__(convert_charrefs=True)
        self.drop = drop
        self.out = []
        self.buf = []
        self.section = ""
        self.skip = 0          # inside <head>/<style>/<script> or a dropped fold
        self.stack = []        # open details: [kind, summary-pending]
        self.cells = None
        self.rows = 0
        self.title = ""
        self.pre = 0
        self.dt = ""
        self.unskip = ""       # the eyebrow / footer: the frame's stamp, not the task's words
        self.divs = []         # open <div>s' first class
        self.band = []         # the number band's n, k, n, k …
        self.cmp = 0           # inside a 改前 / 改后 block: its <div> depth
        self.xrow = False      # inside a div.xt row (T764): its spans are cells, joined by ·
        self.xd = 0            # inside a row's own detail: its lines are indented
        self.spans = []        # open <span>s' first class
        self.ob = ""           # the member card's key (its div.ob id, m-<key>)
        self.cards = []        # each member card as [first line, end line, key, title] of self.out

    def kind(self):
        kinds = [s[0] for s in self.stack]    # an entry is [kind, summary-pending(, "drop")]
        if "card" in kinds:
            return "tech"
        if self.section == "evidence":
            return "keep"          # 上线证据 is the worker's own line: never moved off
        return "evidence" if self.section == "cause" else "other"

    def emit(self, line):
        self.out.append(line)

    def text(self):
        t = "".join(self.buf)
        self.buf = []
        return t if self.pre else re.sub(r"\s+", " ", t).strip()

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = (a.get("class") or "").split()
        if tag in ("head", "style", "script", "button", "form"):   # a page control is not words
            self.skip += 1
            return
        if tag == "section" or (tag == "span" and a.get("id") in ("cause", "charter")):
            self.section = a.get("id", "")     # T764: #cause / #charter are anchors inside a merged section
        if not self.skip and ((tag == "p" and "eyebrow" in cls) or tag == "footer"):
            self.skip += 1; self.unskip = tag; return
        if tag == "div":
            self.divs.append(cls[0] if cls else "")
            if self.divs[-1] == "ob":
                self.ob = re.sub(r"^m-", "", a.get("id") or "")
            if self.divs[-1] in ("n", "k"):
                self.buf = []
            d = self.divs[-1]
            if d == "xh":                          # the head row: the words carry no header
                self.skip += 1
            elif not self.skip and d in ("xr", "eh", "sk", "sv", "slot"):
                self.buf = []; self.xrow = d == "xr"
            elif d == "xd" and not self.skip:
                drop = ("evidence" if self.section == "cause" else "other") in self.drop
                if drop:                            # moved off: one line says where it is
                    self.emit("  （%s：见设计页）" % ("证据" if self.section == "cause" else "细节"))
                    self.divs[-1] = "xd-drop"; self.skip += 1
                else:
                    self.xd += 1
            if self.divs[-1] == "cmp" and not self.skip:
                self.emit("**改前 / 改后**")      # the block as words: one line per state
                self.cmp = len(self.divs)
                self.skip += 1
        if self.cmp and a.get("data-say"):
            self.emit("- " + a["data-say"])
        if tag == "span":
            self.spans.append(cls[0] if cls else "")
            if not self.skip and self.spans[-1] == "ok" and self.divs and self.divs[-1] == "og":
                self.buf = []
            if not self.skip and self.spans[-1] == "pill" and self.divs and self.divs[-1] == "eh":
                self.buf.append(" · ")
        if tag == "details" and "xr" in cls:      # a row that opens on its own detail (T764)
            self.stack.append(["xr", True])
            if self.skip: self.skip += 1
            return
        if tag == "details":
            # a fold at any depth (NZP2): 代码位置 is folded inside a step's evidence or a
            # card's 技术细节 — its own kind, the first to move to the page
            k = "card" if "card" in cls else ("code" if "code" in cls and self.section != "evidence" else self.kind())
            if self.skip:
                self.stack.append([k, False]); self.skip += 1; return
            t = self.text()                     # a fold inside a paragraph / dd: the words before it are its own
            if t:
                ind = "  " if self.xd or "ev" in self.divs else ""
                self.emit(ind + ("**%s** %s" % (self.dt, t) if self.dt else t))
                self.dt = ""
            self.stack.append([k, True])
            if k == "card":
                self.cards.append([len(self.out), None, self.ob, ""])
            if k != "card" and k in self.drop:
                self.stack[-1].append("drop")
            return
        if self.skip:
            return
        if tag == "br":
            self.buf.append(" ")
        elif tag in ("code", "kbd"):
            self.buf.append("`")
        elif tag == "strong":
            self.buf.append("**")
        elif tag == "pre":
            self.pre += 1
        elif tag == "tr":
            self.cells = []
        elif tag in ("td", "th"):
            self.buf = []
        elif tag in self.BLOCK:
            self.buf = []
            if tag == "summary" and self.stack and self.stack[-1][0] == "xr":
                self.xrow = True

    def handle_endtag(self, tag):
        if self.unskip == tag:
            self.unskip = ""; self.skip -= 1; return
        if tag == "div":
            if self.cmp and len(self.divs) == self.cmp:
                self.cmp = 0
                self.skip -= 1
            c = self.divs.pop() if self.divs else ""
            if c in ("xh", "xd-drop"):
                self.skip -= 1
                return
            if c == "xd" and not self.skip:
                self.xd -= 1
                return
            if self.skip:
                return
            if c in ("xr", "eh"):
                self.emit("- " + self.text().strip(" ·"))
                self.xrow = False
                return
            if c == "sk":
                self.emit("- **%s**" % self.text()); return
            if c in ("sv", "slot"):
                self.emit("  " + self.text()); return
            if c in ("n", "k"):
                self.band.append(self.text())
            elif c == "verdict" and self.band:
                b = self.band
                self.emit(" · ".join("%s %s" % (b[i + 1], b[i]) for i in range(0, len(b) - 1, 2)))
                self.band = []
            return
        if tag in ("head", "style", "script", "button", "form"):
            self.skip = max(0, self.skip - 1)
            return
        if tag == "span":
            c = self.spans.pop() if self.spans else ""
            if self.skip:
                return
            if self.xrow and c in ("c", "num"):
                self.buf.append(" · ")
            elif c == "en":
                self.buf.append(". ")
            elif c == "ok" and self.divs and self.divs[-1] == "og":
                self.emit("*%s*" % self.text())
            return
        if tag == "details":
            d = self.stack.pop() if self.stack else ["", False]
            if d[0] == "card" and d[1] and self.cards:
                self.cards[-1][1] = len(self.out)
            if self.skip:
                self.skip -= 1
            return
        if self.skip:
            return
        if tag in ("code", "kbd"):
            self.buf.append("`")
        elif tag == "strong":
            self.buf.append("**")
        elif tag in ("td", "th") and self.cells is not None:
            self.cells.append(self.text().replace("|", "\\|"))
        elif tag == "tr":
            if self.cells:
                self.emit("| " + " | ".join(self.cells) + " |")
                if self.rows == 0:
                    self.emit("|" + "---|" * len(self.cells))
                self.rows += 1
            self.cells = None
        elif tag in ("table",):
            self.rows = 0
            self.emit("")
        elif tag == "summary":
            t = re.sub(r"\s*（展开）$", "", self.text())   # a fold's 「（展开）」 means nothing in words
            top = self.stack[-1] if self.stack else None
            if top and top[0] == "xr":
                self.emit("- " + t.strip(" ·"))
                self.xrow = False
            elif top and top[0] == "card":
                self.emit("### " + re.sub(r"^\*\*(.*?)\*\*\s*(?=.)", r"\1 — ", t))
                if self.cards:
                    self.cards[-1][3] = re.sub(r"^\*\*(.*?)\*\*.*", r"\1", t)
            elif top and len(top) > 2:       # a dropped fold: its name, then nothing
                self.emit("（%s：见设计页）" % t)
                self.skip += 1
            elif t:
                self.emit("**%s**" % t)
        elif tag == "pre":
            t = self.text()                   # read while still inside: a <pre> keeps its lines
            self.pre -= 1
            self.emit("```\n" + t.strip("\n") + "\n```")
        elif tag == "dt":
            self.dt = self.text()
        elif tag == "dd":
            ind = "  " if "ev" in self.divs else ""     # an acceptance item's fields sit under it
            t = self.text()
            if t or self.dt:                            # a dd whose words went out before its fold: nothing left
                self.emit(ind + ("**%s** %s" % (self.dt, t) if self.dt else t))
            self.dt = ""
        elif tag == "h1":
            self.title = self.text()
            self.emit("# " + self.title)
        elif tag == "h2":
            self.emit("\n## " + self.text())
        elif tag == "h3":
            self.emit("### " + self.text())
        elif tag == "li":
            self.emit(("  - " if self.xd else "- ") + self.text())
        elif tag in ("p", "footer"):
            t = self.text()
            if t:
                self.emit(("  " if self.xd or "ev" in self.divs else "") + t)

    def handle_data(self, d):
        if not self.skip:
            self.buf.append(d)


LADDER = ((), ("code",), ("code", "evidence"), ("code", "evidence", "tech"), ("code", "evidence", "tech", "other"))
# a part of --split is ONE card's task: the shared folds go before the card's own 技术细节
SPLIT_LADDER = ((), ("code",), ("code", "evidence"), ("code", "evidence", "other"), ("code", "evidence", "other", "tech"))


def parse(page, drop):
    p = Words(drop)
    p.feed(page)
    p.close()
    return p


def words(page, drop, link, nod, part=None):
    """The words. part = (i, p): only member card i of p.cards, the others one line
    saying where they are (NZP2: one task per card, the shared sections in each)."""
    if part is None:
        lines = parse(page, drop).out
    else:
        i, p = part
        cards, lines, at = p.cards, [], 0
        for j, (a, b, _, _) in enumerate(cards):
            lines += p.out[at:a]
            if j == i:
                lines += p.out[a:b]
            elif j == 0 or (i == 0 and j == 1):
                lines.append("（解决方案共 %d 张成员卡；本份只做「%s」，其余 %d 张各是一份任务——见设计页）"
                             % (len(cards), cards[i][3], len(cards) - 1))
            at = b
        lines += p.out[at:]
    # the eyebrow and band are the frame's; the words start at the title
    body = "\n".join(lines)
    body = re.sub(r"\n{3,}", "\n\n", body).strip() + "\n"
    pre = ""
    if link:
        pre = "> 设计页：%s（私密；%s）\n\n" % (
            link, "本文是它的两层全文，标「见设计页」的几段只在页面上" if drop else "本文是它的两层全文")
        if part is not None:
            pre = pre.replace("本文是它的两层全文", "本文是它按成员卡拆开的第 %d/%d 份" % (part[0] + 1, len(part[1].cards)), 1)
    if nod:
        body += "\n## 拍板\n%s：全部按「需要你定的事」的建议执行，执行会话照做，不再讨论方向。\n" % nod
    return pre + body


def size(text):
    # as it travels: fleet-task-record.sh sends the words as UTF-8 JSON
    return len(json.dumps(text, ensure_ascii=False).encode("utf-8"))


def body(page, link, nod, cap):
    for drop in LADDER:
        w = words(page, set(drop), link, nod)
        if size(w) <= cap:
            return w
    n = len(parse(page, set()).cards)
    die(1, "the words stay over %d bytes with every fold on the page (%d) — %s" % (
        cap, size(w), "split them, one task per member card: body <page> --split <dir> (%d cards)" % n
        if n > 1 else "shorten the page's surface"))


def split(page, link, nod, cap, out):
    """One task's words per member card, each carrying the link and every shared
    section; each part takes the fewest folds off it needs. → [(path, bytes, title)]."""
    n = len(parse(page, set()).cards)
    if n < 2:
        die(1, "nothing to split: the page has %d member card%s" % (n, "" if n == 1 else "s"))
    parts = []
    for i in range(n):
        for drop in SPLIT_LADDER:
            p = parse(page, set(drop))
            w = words(page, set(drop), link, nod, (i, p))
            if size(w) <= cap:
                break
        else:
            die(1, "part %d (%s) stays over %d bytes (%d) — the shared sections alone are too long; shorten the page's surface"
                % (i + 1, p.cards[i][3], cap, size(w)))
        key = re.sub(r"[^A-Za-z0-9_-]+", "", p.cards[i][2]) or str(i + 1)
        parts.append(("%s/%02d-%s.md" % (out, i + 1, key), w, p.cards[i][3]))
    os.makedirs(out, exist_ok=True)
    for path, w, _ in parts:
        with open(path, "w", encoding="utf-8") as f:
            f.write(w)
    return [(path, size(w), t) for path, w, t in parts]


# ---- shape (T869) --------------------------------------------------------------

class Shape(HTMLParser):
    """Where the real body tag is, how many elements it holds, and whether page
    content leaked into the head (a script there swallowing the page)."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.body = None       # (line, col, start tag text) of the real body tag
        self.children = 0      # elements opened inside it
        self.where = []        # open head / body
        self.leak = False      # page content inside the head
    def handle_starttag(self, tag, attrs):
        if tag == "head":
            self.where.append("head")
        elif tag == "body" and self.body is None:
            self.body = self.getpos() + (self.get_starttag_text(),)
            self.where = ["body"]
        elif "body" in self.where:
            self.children += 1
        elif "head" in self.where and tag in ("section", "h1", "h2", "main", "article"):
            self.leak = True
    handle_startendtag = handle_starttag
    def handle_endtag(self, tag):
        if tag == "head" and "head" in self.where:
            self.where.remove("head")
    def handle_data(self, d):
        if "head" in self.where and re.search(r"<(?:section|h1|h2|main|article)[\s>]", d):
            self.leak = True


def shape(page):
    sh = Shape()
    sh.feed(page)
    sh.close()
    return sh


def problems(page):
    sh, out = shape(page), []
    if sh.body is None:
        out.append("no body tag a parser can see")
    elif sh.children == 0:
        out.append("the body is empty — its content is not inside it")
    if sh.leak:
        out.append("page content sits inside the head (a script or comment there swallowed it)")
    return out


def fb_body(page, table, version):
    bad = problems(page)
    if bad:
        die(1, "; ".join(bad))
    line, col, tag = shape(page).body
    lines = page.split("\n")
    at = sum(len(x) + 1 for x in lines[:line - 1]) + col
    if page[at:at + len(tag)] != tag:
        die(2, "cannot place the body tag")
    attrs = re.sub(r"\s+data-fb-(?:table|version)=(\"[^\"]*\"|'[^']*'|\S+)", "", tag[len("<body"):-1])
    new = '<body%s data-fb-table="%s" data-fb-version="%s">' % (
        attrs, html.escape(table, quote=True), html.escape(version, quote=True))
    return page[:at] + new + page[at + len(tag):]


# ---- stamp --------------------------------------------------------------------

def stamp(page, tid):
    new, n = re.subn(r'(<p class="eyebrow">)任务(?:设计| [^ ·<]+)', r"\g<1>任务 " + tid, page, count=1)
    if not n:
        die(2, "no 任务设计 eyebrow to stamp")
    return new


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        sys.exit(2)
    cmd, rest = argv[0], argv[1:]
    out = None
    if "-o" in rest:
        i = rest.index("-o")
        out = rest[i + 1] if i + 1 < len(rest) else die(2, "-o needs a path")
        del rest[i:i + 2]

    def write(text):
        if out:
            with open(out, "w", encoding="utf-8") as f:
                f.write(text)
        else:
            sys.stdout.write(text)

    if cmd == "ids":
        print("\n".join(IDS))
    elif cmd == "compare" and len(rest) == 1:
        try:
            c = json.loads(read(rest[0]))
        except ValueError as e:
            die(2, "compare is not JSON (%s)" % e)
        if not isinstance(c, dict) or not c.get("before") or not (c.get("after") or c.get("states")):
            die(2, "compare needs before and after (or states)")
        write(compare(c))
    elif cmd == "render" and len(rest) == 1:
        try:
            spec = json.loads(read(rest[0]))
        except ValueError as e:
            die(2, "spec is not JSON (%s)" % e)
        page = render(spec)
        bad = problems(page)
        if bad:
            die(1, "rendered page is broken: " + "; ".join(bad))
        write(page)
    elif cmd == "body" and rest:
        link = nod = split_to = ""
        cap = 13000
        page = None
        it = iter(rest)
        for a in it:
            if a == "--link": link = next(it, "")
            elif a == "--nod": nod = next(it, "")
            elif a == "--split": split_to = next(it, "") or die(2, "--split needs a directory")
            elif a == "--max":
                try: cap = int(next(it, ""))
                except ValueError: die(2, "--max needs a number")
            elif page is None: page = a
            else: die(2, "one page only")
        if page is None:
            die(2, "body <page.html>")
        if split_to:
            for path, n, t in split(read(page), link, nod, cap, split_to):
                print("%s\t%d\t%s" % (path, n, t))
        else:
            write(body(read(page), link, nod, cap))
    elif cmd == "fb-body" and len(rest) == 3:
        write(fb_body(read(rest[0]), rest[1], rest[2]))
    elif cmd == "check" and len(rest) == 1:
        bad = problems(read(rest[0]))
        for b in bad:
            print("fleet-task-page: " + b, file=sys.stderr)
        sys.exit(1 if bad else 0)
    elif cmd == "stamp" and len(rest) == 2:
        write(stamp(read(rest[0]), rest[1]))
    else:
        die(2, "usage: render <spec> | body <page> [--split DIR] | stamp <page> <id> | compare <json> | fb-body <page> <table> <version> | check <page> | ids")


if __name__ == "__main__":
    main(sys.argv[1:])
