#!/usr/bin/env python3
"""fleet-task-page.py — the ONE task design page: render it, turn it into a task's
words, stamp its number (T661).

  fleet-task-page.py render <spec.json|-> [-o page.html]
      → the page: epic-page's <head> (template.html's <style>, verbatim) + the
        task layout — eyebrow · title · subtitle · number band · #problem ·
        #cause · #metrics · #charter · #members · #risks · #signoff(+#open) ·
        #evidence (folded). The spec's strings are HTML fragments (<code>,
        <strong> welcome); the frame is this script's, never re-typed.
  fleet-task-page.py body <page.html> [--link URL] [--nod TEXT] [--max BYTES]
      → the task's words (markdown), BOTH layers: every fold written out. The
        record's request is capped (16 KB with its envelope), so the words are
        measured as they travel (UTF-8 JSON, fleet-task-record.sh); over
        --max (default 13000) the folds move to the page one kind at a time —
        the cause's evidence, then 改法's 技术细节, then the rest — each replaced
        by 「（…：见设计页）」. Still over ⇒ exit 1, nothing printed.
  fleet-task-page.py stamp <page.html> <task id> [-o out]
      → the eyebrow's 「任务设计」 becomes 「任务 <id>」 (idempotent).
  fleet-task-page.py ids
      → the section ids a task page carries, one per line.

The spec (plugins/fleet-epic/skills/epic-page/task-page.example.json is a whole one):
  repo · date · title · sub · kind ("fix" | "feature": a feature's #cause is
  「为什么要做」) · band [{n,k}] · problem [li] · cause {lede, steps [[step, what]],
  evidence [li]} · metrics [[指标, 现在, 目标]] · metrics_how [li] ·
  charter {do [li], dont [li]} · members [{key, name, line, what, proto?,
  tech [[label, text]]}] · risks [{head, text}] · risks_tech [li] ·
  signoff [[事项, 建议]] · signoff_note · evidence (one line) · footer.

Exit: 0 done · 1 over the cap (body) · 2 usage / unreadable input.
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


def fold(summary, inner):
    return '<details class="fold">\n<summary>%s</summary>\n%s</details>\n' % (summary, inner)


def render(spec):
    g = spec.get
    feature = g("kind") == "feature"
    o = [head("%s" % g("title", "任务设计")), "\n<body>\n<div class=\"wrap\">\n\n"]
    o.append('<p class="eyebrow">任务设计 · %s · %s</p>\n' % (g("repo", ""), g("date", "")))
    o.append("<h1>%s</h1>\n" % g("title", ""))
    o.append('<p class="sub">%s</p>\n\n' % g("sub", ""))
    if g("band"):
        o.append('<div class="verdict">\n' + "".join(
            '  <div class="v"><div class="n">%s</div><div class="k">%s</div></div>\n' % (b["n"], b["k"])
            for b in g("band")) + "</div>\n\n")
    o.append('<section id="problem">\n<h2>%s</h2>\n%s</section>\n\n'
             % ("现在的样子" if feature else "现象", ul(g("problem") or [])))
    c = g("cause") or {}
    o.append('<section id="cause">\n<h2>%s</h2>\n' % ("为什么要做" if feature else "原因"))
    if c.get("lede"):
        o.append('<p class="lede">%s</p>\n' % c["lede"])
    if c.get("points"):
        o.append(ul(c["points"]))
    if c.get("steps"):
        o.append(table(["一步", "发生了什么"], c["steps"]))
    if c.get("evidence"):
        o.append(fold("证据（代码与现场）" if not feature else "依据", ul(c["evidence"])))
    o.append("</section>\n\n")
    o.append('<section id="metrics">\n<h2>指标</h2>\n')
    o.append(table(["指标", "现在", "目标"], g("metrics") or [["⟨指标⟩", "本批不量", "本批不量"]], (1, 2)))
    if g("metrics_how"):
        o.append(fold("怎么量", ul(g("metrics_how"))))
    o.append("</section>\n\n")
    ch = g("charter") or {}
    o.append('<section id="charter">\n<h2>目标与范围</h2>\n<h3>做</h3>\n%s<h3>不做</h3>\n%s</section>\n\n'
             % (ul(ch.get("do") or []), ul(ch.get("dont") or [])))
    o.append('<section id="members">\n<h2>改法</h2>\n\n')
    for m in g("members") or []:
        o.append('<div class="ob" id="m-%s">\n<details class="card">\n' % m.get("key", ""))
        o.append('<summary><span class="ct"><strong>%s</strong><span class="cg">%s</span></span></summary>\n'
                 % (m.get("name", ""), m.get("line", "")))
        o.append('<dl>\n  <dt>做什么</dt><dd>%s</dd>\n</dl>\n' % m.get("what", ""))
        if m.get("proto"):
            o.append('<p class="proto"><a href="%s">▶ 打开可交互原型</a></p>\n' % html.escape(m["proto"], quote=True))
        if m.get("tech"):
            o.append(fold("技术细节", "<dl>\n" + "".join(
                "  <dt>%s</dt><dd>%s</dd>\n" % (k, v) for k, v in m["tech"]) + "</dl>\n"))
        o.append("</details>\n</div>\n\n")
    o.append("</section>\n\n")
    o.append('<section id="risks">\n<h2>可能出的问题</h2>\n')
    o.append(ul(["<strong>%s</strong> — %s" % (r.get("head", ""), r.get("text", "")) for r in g("risks") or []]))
    if g("risks_tech"):
        o.append(fold("技术风险", ul(g("risks_tech"))))
    o.append("</section>\n\n")
    o.append('<section id="signoff">\n<span id="open"></span>\n<h2>需要你定的事</h2>\n')
    if g("signoff"):
        o.append(table(["事项", "建议"], g("signoff")))
    o.append('<p class="lede" style="margin-top:14px">%s</p>\n</section>\n\n'
             % (g("signoff_note") or "点头即全部按建议，派一个执行会话做，一个改动说明合并。"))
    o.append('<section id="evidence">\n%s</section>\n\n' % fold("上线证据", "<pre>%s</pre>\n" % g("evidence", "")))
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

    def kind(self):
        kinds = [k for k, _ in self.stack]
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
        if tag in ("head", "style", "script"):
            self.skip += 1
            return
        if tag == "section":
            self.section = a.get("id", "")
        if not self.skip and ((tag == "p" and "eyebrow" in cls) or tag == "footer"):
            self.skip += 1; self.unskip = tag; return
        if tag == "div":
            self.divs.append(cls[0] if cls else "")
            if self.divs[-1] in ("n", "k"):
                self.buf = []
        if tag == "details":
            k = "card" if "card" in cls else self.kind()
            if self.skip:
                self.stack.append([k, False]); self.skip += 1; return
            self.stack.append([k, True])
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

    def handle_endtag(self, tag):
        if self.unskip == tag:
            self.unskip = ""; self.skip -= 1; return
        if tag == "div":
            c = self.divs.pop() if self.divs else ""
            if self.skip:
                return
            if c in ("n", "k"):
                self.band.append(self.text())
            elif c == "verdict" and self.band:
                b = self.band
                self.emit(" · ".join("%s %s" % (b[i + 1], b[i]) for i in range(0, len(b) - 1, 2)))
                self.band = []
            return
        if tag in ("head", "style", "script"):
            self.skip = max(0, self.skip - 1)
            return
        if tag == "details":
            d = self.stack.pop() if self.stack else ["", False]
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
            t = self.text()
            top = self.stack[-1] if self.stack else None
            if top and top[0] == "card":
                self.emit("### " + re.sub(r"^\*\*(.*?)\*\*\s*(?=.)", r"\1 — ", t))
            elif top and len(top) > 2:       # a dropped fold: its name, then nothing
                self.emit("（%s：见设计页）" % t)
                self.skip += 1
            elif t:
                self.emit("**%s**" % t)
        elif tag == "pre":
            self.pre -= 1
            self.emit("```\n" + self.text().strip("\n") + "\n```")
        elif tag == "dt":
            self.dt = self.text()
        elif tag == "dd":
            self.emit("**%s** %s" % (self.dt, self.text()) if self.dt else self.text())
            self.dt = ""
        elif tag == "h1":
            self.title = self.text()
            self.emit("# " + self.title)
        elif tag == "h2":
            self.emit("\n## " + self.text())
        elif tag == "h3":
            self.emit("### " + self.text())
        elif tag == "li":
            self.emit("- " + self.text())
        elif tag in ("p", "footer"):
            t = self.text()
            if t:
                self.emit(t)

    def handle_data(self, d):
        if not self.skip:
            self.buf.append(d)


def words(page, drop, link, nod):
    p = Words(drop)
    p.feed(page)
    p.close()
    lines = p.out
    # the eyebrow and band are the frame's; the words start at the title
    body = "\n".join(lines)
    body = re.sub(r"\n{3,}", "\n\n", body).strip() + "\n"
    pre = ""
    if link:
        pre = "> 设计页：%s（私密；%s）\n\n" % (
            link, "本文是它的两层全文，标「见设计页」的几段只在页面上" if drop else "本文是它的两层全文")
    if nod:
        body += "\n## 拍板\n%s：全部按「需要你定的事」的建议执行，执行会话照做，不再讨论方向。\n" % nod
    return pre + body


def size(text):
    # as it travels: fleet-task-record.sh sends the words as UTF-8 JSON
    return len(json.dumps(text, ensure_ascii=False).encode("utf-8"))


def body(page, link, nod, cap):
    for drop in ((), ("evidence",), ("evidence", "tech"), ("evidence", "tech", "other")):
        w = words(page, set(drop), link, nod)
        if size(w) <= cap:
            return w
    die(1, "the words stay over %d bytes with every fold on the page (%d) — shorten the page's surface" % (cap, size(w)))


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
    elif cmd == "render" and len(rest) == 1:
        try:
            spec = json.loads(read(rest[0]))
        except ValueError as e:
            die(2, "spec is not JSON (%s)" % e)
        write(render(spec))
    elif cmd == "body" and rest:
        link = nod = ""
        cap = 13000
        page = None
        it = iter(rest)
        for a in it:
            if a == "--link": link = next(it, "")
            elif a == "--nod": nod = next(it, "")
            elif a == "--max":
                try: cap = int(next(it, ""))
                except ValueError: die(2, "--max needs a number")
            elif page is None: page = a
            else: die(2, "one page only")
        if page is None:
            die(2, "body <page.html>")
        write(body(read(page), link, nod, cap))
    elif cmd == "stamp" and len(rest) == 2:
        write(stamp(read(rest[0]), rest[1]))
    else:
        die(2, "usage: render <spec> | body <page> | stamp <page> <id> | ids")


if __name__ == "__main__":
    main(sys.argv[1:])
