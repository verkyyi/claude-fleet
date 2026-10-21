#!/bin/bash
# epic-page-surface.sh — what the DECIDER sees of an EPIC page: its surface,
# with every fold closed (issue #929).
#
#   epic-page-surface.sh [--lint] <page.html | http(s)://… | ->
#
# PRINTS the page as the 发起人 reads it before tapping anything: the title, the
# subtitle, the number band, each section's visible text, tables as `| a | b |`
# rows, and each member card as its ONE summary line. Dropped, because the
# decider does not see them without a tap: every `<details class="fold">`
# (怎么量 / 共同约定 / 技术细节 / 预检原文 / 执行安排 …), everything inside a
# `<details class="card">` except its <summary>, <head>, <style>, <script> and
# HTML comments.
#
# WHY. A page can fill every slot of the frame and still be sent back — 2026-09-22
# the 活页托管一致性 design page was, word for word against the approved #787
# page, on its SURFACE: the question the theme asked was answered only in a fold,
# the metrics were 「首跑定」「0 → > 0」「3 处 → 1 行」, the cards spoke 渲染 / 埋点
# / 回执 / 404, 为谁 read 「所有 Agent」. None of that is visible while you are
# writing the page with every fold in your head; all of it is visible here.
# Read this output before `share.sh`, and read an APPROVED page's output first
# (plugins/fleet-epic/skills/epic-page/SKILL.md, rule 0) so you know what "good" looks like.
#
# --lint also checks the surface against the decider's-view rules that a machine
# CAN see, one `WARN <rule>: <text>` line each, and exits 1 when any fires:
#   key        a member key (C1 / R2) or an issue / PR number (#123) upstairs
#   jargon     an implementation noun upstairs (接口 / 渲染 / 埋点 / SDK / 404 …)
#   file       a file name, path or inline code upstairs
#   metric     a target with no number (首跑定 / 待定), a meaningless one (> 0,
#              > 现值), or 现在 and 目标 in different units (3 处 → 1 行)
#   for-whom   a 为谁 with no count, or 「所有 …」 / 「团队」 as the person
#   decision   code inside 需要你定的事, or a 不做 row there (不做 belongs in 范围)
#   compare    a member card that changes something the user SEES (侧栏 / 状态栏 /
#              菜单 / 页面 / 界面 / 样式 …, anywhere in the card) with no 改前 / 改后
#              block (div.cmp) in its upper layer, or ANY card that still links a
#              separate prototype page (p.proto / a 「原型」 link off the page)
#              (issue #1754, T699) — the prototype lives IN the card
# A TASK page (/fleet-task-plan, T661: its eyebrow reads 任务设计 / 任务 <id>) is
# checked for its own frame too:
#   task-section   a section the task layout carries is missing (#problem #cause
#                  #metrics #charter #members #risks #signoff #evidence — since T764
#                  #cause / #charter are anchors inside 问题与原因 / 目标)
#   task-evidence  a 原因 with no folded 证据 (code lines, logs, the scene) — a cause
#                  nobody can check is a guess
#   task-signoff   需要你定的事 without 「点头即全部按建议」 under it
# and, on any page (T764):
#   brevity        a title over 16 characters, a subtitle over 30 or with brackets;
#                  on a task page a 现象 line over 25 characters, a 做 / 不做 item over 20
#   fold-row       the old shared folds — 证据（代码与现场） under 原因, 怎么量 under 指标 —
#                  instead of each step / row opening on its own
#   accept         上线证据 still one folded line, or an acceptance item with no 通过标准
#   empty-fold     a fold / card / row that opens on nothing (no ▸ without a detail)
#   task-evidence-shot  an acceptance item marked done / passed with no production
#                  screenshots — phone 390 AND desktop 1440 (A300: 验收报告要有线上真实截图)
# and one ERROR, above every rule (T869) — the page as a browser builds it:
#   ERROR body     no body tag, an empty body, or page content inside <head> (a
#                  「replace the first <body>」 that hit a script comment put the whole
#                  page into the head's script: it opened blank). fleet-task-page.py
#                  fb-body sets the feedback attributes on the real tag.
# It is a checklist aid, not a judge: a clean lint does not make a page good —
# rules like "the surface answers the theme's question" are yours to read.
#
# Exit: 0 clean (or no --lint) · 1 lint warnings / an ERROR · 2 usage / unreadable input.
set -uo pipefail

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

LINT=0
case "${1:-}" in
  --lint) LINT=1; shift ;;
  -h|--help) usage ;;
esac
[ $# -eq 1 ] || usage
SRC=$1

command -v python3 >/dev/null 2>&1 || { echo "epic-page-surface: python3 not found" >&2; exit 2; }

case "$SRC" in
  http://*|https://*)
    HTML=$(curl -fsSL --max-time 20 "$SRC") || { echo "epic-page-surface: cannot fetch $SRC" >&2; exit 2; } ;;
  -) HTML=$(cat) ;;
  *) [ -r "$SRC" ] || { echo "epic-page-surface: cannot read $SRC" >&2; exit 2; }
     HTML=$(cat "$SRC") ;;
esac

EPS_LINT=$LINT python3 -c '
import os, re, sys
from html.parser import HTMLParser

LINT = os.environ.get("EPS_LINT") == "1"
BLOCK = {"h1","h2","h3","h4","p","li","tr","summary","dt","dd","pre","figcaption","div"}
# a member that changes something the user SEES needs its 改前 / 改后 block in the card (issue #1754, T699)
VISUAL = re.compile(r"侧栏|状态栏|顶栏|菜单|页面|网页|界面|样式|弹窗|小程序")
VOID = {"br","img","hr","meta","link","input","wbr","source"}

class Surface(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []        # (tag, hidden_before, kind)
        self.hidden = 0        # >0 while inside something the decider cannot see
        self.lines = []        # (kind, text, section)
        self.buf = []
        self.cells = None
        self.section = ""
        self.card = []         # stack of "in card, summary seen?" flags
        self.code = 0
        self.whom = []         # 为谁 values (card tap-1 layer; hidden on the surface)
        self.dt = None
        self.whom_buf = None
        self.raw = []
        self.head_row = False
        self.cards = []        # per open card: base hidden level, all its text, has-compare, links-a-proto-page, name
        self.visual = []       # names of visual member cards with no 改前 / 改后 block
        self.protopage = []    # names of member cards that still link a separate prototype page
        self.a_card = None     # [card, href, looks-like-a-prototype-link] while a card <a> is open
        self.in_proto = False  # inside a p.proto (the retired prototype-page link)
        self.sections = set()  # every <section id>, for the frame check of a task page
        self.folds = {}        # section id → folds in it
    def flush(self, kind="p"):
        t = re.sub(r"\s+", " ", "".join(self.buf)).strip()
        self.buf = []
        if t and not self.hidden:
            self.lines.append((kind, t, self.section))
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = (a.get("class") or "").split()
        if tag in VOID:
            if tag == "br": self.buf.append(" ")
            if tag == "img" and not self.hidden: self.buf.append("[图:" + (a.get("alt") or "") + "]")
            return
        hid = self.hidden
        if tag == "section" or (tag == "span" and a.get("id") in ("cause", "charter")):   # T764: anchors of a merged section
            self.section = a.get("id", ""); self.sections.add(self.section)
        if tag == "details" and "fold" in cls: self.folds[self.section] = self.folds.get(self.section, 0) + 1
        if tag == "div" and "xd" in cls:       # a row own detail (T764): one tap away, like a fold
            self.folds[self.section] = self.folds.get(self.section, 0) + 1
        if tag in ("head","style","script","template","button","form"): self.hidden += 1   # page controls are not words
        elif tag == "details" and "fold" in cls: self.hidden += 1
        elif tag == "div" and "xd" in cls: self.hidden += 1
        elif tag == "details" and "card" in cls:
            self.card.append(False)
            self.cards.append({"base": hid, "text": [], "cmp": False, "page": False, "name": "", "sec": self.section})
        if tag == "div" and "cmp" in cls and self.cards and self.hidden == self.cards[-1]["base"] + 1:
            self.cards[-1]["cmp"] = True       # the 改前 / 改后 block in the card upper layer (tap 1), not in a fold
        if tag == "a" and self.cards:
            self.a_card = [self.cards[-1], a.get("href") or "", "proto" in cls or self.in_proto]
        if tag == "p" and "proto" in cls: self.in_proto = True
        if tag == "summary" and self.card and not self.card[-1] and self.stack and self.stack[-1][0] == "details":
            self.card[-1] = True
            self.stack.append((tag, hid, "cardsum")); self.flush(); return
        if tag in ("code","kbd") and not self.hidden:
            self.code += 1; self.buf.append("`")
        xrow = (tag == "div" and ("xr" in cls or "xh" in cls)) or \
               (tag == "summary" and self.stack and self.stack[-1][2] == "xr")
        if xrow:                               # a row of a div.xt (T764): its spans are its cells
            self.flush(); self.cells = []; self.head_row = "xh" in cls
            self.stack.append((tag, hid, "xrow")); return
        if tag == "span" and self.cells is not None and self.stack and self.stack[-1][2] == "xrow":
            self.buf = []; self.stack.append((tag, hid, "xcell")); return
        if tag == "tr": self.flush(); self.cells = []; self.head_row = False
        if tag == "th": self.head_row = True
        elif tag in ("td","th"): self.buf = []
        elif tag in BLOCK: self.flush()
        if tag == "dt": self.dt = ""; self.raw = []
        if tag == "dd" and self.dt == "为谁": self.whom_buf = []
        kind = "card" if (tag == "details" and "card" in cls) else "eyebrow" if "eyebrow" in cls else "xd" if (tag == "div" and "xd" in cls) \
            else "xr" if (tag == "details" and "xr" in cls) else ""
        self.stack.append((tag, hid, kind))
    def handle_endtag(self, tag):
        if tag in VOID: return
        # pop to the matching open tag (tolerates sloppy nesting)
        idx = next((i for i in range(len(self.stack)-1, -1, -1) if self.stack[i][0] == tag), None)
        if idx is None: return
        while len(self.stack) > idx:
            t, hid, kind = self.stack.pop()
            self._end(t, hid, kind)
    def _end(self, t, hid, kind):
        if t in ("code","kbd") and self.code:
            self.code -= 1; self.buf.append("`")
        if kind == "xcell" and self.cells is not None:
            self.cells.append(re.sub(r"\s+", " ", "".join(self.buf)).strip()); self.buf = []; return
        if kind == "xrow":
            if self.cells and not self.hidden:
                self.lines.append(("th" if self.head_row else "tr", "| " + " | ".join(self.cells) + " |", self.section))
            self.cells = None; self.buf = []; return
        if t in ("td","th") and self.cells is not None:
            self.cells.append(re.sub(r"\s+", " ", "".join(self.buf)).strip()); self.buf = []
        elif t == "tr":
            if self.cells and not self.hidden:
                self.lines.append(("th" if self.head_row else "tr", "| " + " | ".join(self.cells) + " |", self.section))
            self.cells = None; self.buf = []
        elif kind == "cardsum":
            self.flush("card")
            if self.cards and self.lines and self.lines[-1][0] == "card": self.cards[-1]["name"] = self.lines[-1][1]
            self.hidden += 1        # the rest of the card is one tap away
        elif t in BLOCK:
            k = "eyebrow" if kind == "eyebrow" else t if t in ("h1","h2","h3","h4","li","dt","dd","summary") else "p"
            if t == "dt": self.dt = re.sub(r"\s+", "", "".join(self.raw))
            if t == "dd" and self.whom_buf is not None:
                self.whom.append(re.sub(r"\s+", " ", "".join(self.whom_buf)).strip()); self.whom_buf = None
            self.flush(k)
        if t == "strong" and any(k == "cardsum" for _, _, k in self.stack):
            self.buf.append(" — ")   # 名称 — 一句
        if t == "p": self.in_proto = False
        if t == "a" and self.a_card is not None:
            c, href, proto = self.a_card
            if proto and not href.startswith("#"): c["page"] = True
            self.a_card = None
        if kind == "card" and self.card:
            self.card.pop()
            c = self.cards.pop() if self.cards else None
            if c and c["sec"] == "members":
                if not c["cmp"] and VISUAL.search("".join(c["text"])):
                    self.visual.append(c["name"] or "（未命名成员）")
                if c["page"]: self.protopage.append(c["name"] or "（未命名成员）")
        # a fold, a card and <head>/<style>/<script> each end their own hiding
        if t in ("details","head","style","script","template","button","form") or kind == "xd": self.hidden = hid
    def handle_data(self, d):
        if not self.hidden: self.buf.append(d)   # hidden text never reaches the surface
        self.raw.append(d)
        for c in self.cards: c["text"].append(d)
        if self.a_card is not None and "原型" in d: self.a_card[2] = True
        if self.whom_buf is not None: self.whom_buf.append(d)
    def handle_comment(self, d): pass

RAW = sys.stdin.read()
p = Surface()
p.feed(RAW); p.close(); p.flush()

PFX = {"th":"","h1":"# ","h2":"\n## ","h3":"### ","h4":"#### ","li":"- ","card":"▸ ","summary":"▸ ","dt":"","dd":"  "}
for kind, text, sec in p.lines:
    print(PFX.get(kind, "") + text)

if not LINT: sys.exit(0)

warns = []
def warn(rule, text): warns.append((rule, text))

# T869 — the body holds the page (the same shape fleet-task-page.py check reads)
class Shape(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.body, self.children, self.where, self.leak = False, 0, [], False
    def handle_starttag(self, tag, attrs):
        if tag == "head": self.where.append("head")
        elif tag == "body" and not self.body: self.body, self.where = True, ["body"]
        elif "body" in self.where: self.children += 1
        elif "head" in self.where and tag in ("section","h1","h2","main","article"): self.leak = True
    handle_startendtag = handle_starttag
    def handle_endtag(self, tag):
        if tag == "head" and "head" in self.where: self.where.remove("head")
    def handle_data(self, d):
        if "head" in self.where and re.search(r"<(?:section|h1|h2|main|article)[\s>]", d): self.leak = True
sh = Shape(); sh.feed(RAW); sh.close()
errors = []
if not sh.body: errors.append("页面没有 body 标签")
elif not sh.children: errors.append("body 是空的：正文没进 body，打开是空白")
if sh.leak: errors.append("正文落在 <head> 里（脚本或注释吞掉了它）：用 fleet-task-page.py fb-body 改真正的 body 标签")
for e in errors: print("ERROR body: " + e, file=sys.stderr)

JARGON = ["接口","注入","渲染","埋点","回执","域名","状态码","字段","参数","脚本","配置项","回调",
          "鉴权","令牌","中间件","沙箱","缓存","数据库","哈希","正则","重定向","序列化","钩子",
          "进程","守护","子单","worker","hook","daemon","CSP","SDK","API","CDN","JSON","HTML","iframe",
          "token","webhook","conf","PR","CI"]
JRE = re.compile("|".join(
    (r"(?<![A-Za-z])" + re.escape(w) + r"(?![A-Za-z])") if w.isascii() else re.escape(w) for w in JARGON))
KEY = re.compile(r"(?<![A-Za-z0-9])[CR][0-9]{1,2}(?![0-9])|(?<![&\w])#[0-9]+")
FILE = re.compile(r"`[^`]+`|(?<![\w/])[\w.-]+\.(?:sh|md|json|html?|js|mjs|ts|tsx|py|ya?ml|conf|txt|log|css)(?![\w])|(?:^|\s)[.~]?/[\w.-]+/[\w./-]*")
STATUS = re.compile(r"(?<![0-9.])[45]0[0-9](?![0-9])")

for kind, text, sec in p.lines:
    if kind == "eyebrow": continue    # EPIC #N · owner/repo · date is the frame own stamp, not content
    for m in KEY.finditer(text): warn("key", m.group(0) + "  ← " + text)
    for m in JRE.finditer(text): warn("jargon", m.group(0) + "  ← " + text)
    if sec != "metrics":
        for m in STATUS.finditer(text): warn("jargon", m.group(0) + "  ← " + text)
    for m in FILE.finditer(text): warn("file", m.group(0).strip() + "  ← " + text)
    if sec == "metrics" and kind == "tr":
        cells = [c.strip() for c in text.strip("| ").split(" | ")]
        if len(cells) >= 3:
            now, goal = cells[-2], cells[-1]
            if re.search(r"首跑|待定|全部|TBD|\?|？", goal) or not re.search(r"[0-9０-９]|本批不量", goal):
                warn("metric", "目标没有数  ← " + text)
            if re.search(r"^[>＞≥]\s*(0|现值|当前)\s*$", goal):
                warn("metric", "目标无意义（> 0 / > 现值）  ← " + text)
            def unit(v):    # the word right after the first number: 「3 处」→ 处, 「5–13 秒」→ 秒
                m = re.search(r"[0-9０-９.]+(?:\s*[–~\-]\s*[0-9０-９.]+)?\s*([^\s0-9０-９（(，,;；/]*)", v)
                return m.group(1) if m else ""
            if unit(now) and unit(goal) and unit(now) != unit(goal):
                warn("metric", "现在和目标单位不一致  ← " + text)
    if sec == "signoff":
        if kind == "tr" and re.search(r"^\|\s*不做", text):
            warn("decision", "「不做」应放在范围，不进拍板表  ← " + text)
        if "`" in text or re.search(r"[./]\w+\.(?:json|sh|md|js|ts)\b|\./", text):
            warn("decision", "拍板表里有代码或路径  ← " + text)
for w in p.whom:
    if w.strip("⟨…⟩ ") == "": continue
    if not re.search(r"[0-9０-９一二两三四五六七八九十百千万]", w) or re.search(r"所有|全体|维护团队|团队$", w):
        warn("for-whom", "为谁要写具体的人或角色，并给出数量  ← " + w)
for name in p.visual:
    warn("compare", "界面有变化，卡片里却没有「改前 / 改后」对比  ← " + name)
for name in p.protopage:
    warn("compare", "还链到单独的原型页；原型应内嵌成卡片里的「改前 / 改后」对比  ← " + name)

# a task page (/fleet-task-plan, T661) — its eyebrow says so
if any(k == "eyebrow" and t.startswith("任务") for k, t, _ in p.lines):
    for sid in ("problem","cause","metrics","charter","members","risks","signoff","evidence"):
        if sid not in p.sections: warn("task-section", "任务页缺少 #" + sid)
    if any(k == "h2" and t in ("原因", "问题与原因") for k, t, s in p.lines) and not p.folds.get("cause"):
        warn("task-evidence", "原因没有折叠的证据（代码行、日志、现场）")
    if "signoff" in p.sections and not any(s == "signoff" and "点头即全部按建议" in t for _, t, s in p.lines):
        warn("task-signoff", "需要你定的事下面没有「点头即全部按建议」")

# T764 — the decider reads the top of a page first, and opens only what has something in it
def txt(h): return re.sub(r"\s+", " ", re.sub(r"<[^>]*>", "", h)).strip()
def heading(rx):
    m = re.search(rx, RAW, re.S)
    return txt(m.group(1)) if m else ""
TASK = any(k == "eyebrow" and t.startswith("任务") for k, t, _ in p.lines)
h1, sub = heading(r"<h1>(.*?)</h1>"), heading(r"<p class=\"sub\">(.*?)</p>")
if h1 and "⟨" not in h1 and len(h1) > 16:
    warn("brevity", "标题 %d 字，超过 16 字  ← %s" % (len(h1), h1))
if sub and "⟨" not in sub and (len(sub) > 30 or re.search(r"[（(]", sub)):
    warn("brevity", "副标题一句话 ≤ 30 字、不带括号，只说做到什么就停（现在 %d 字）  ← %s" % (len(sub), sub))
if TASK:
    m = re.search(r"<section id=\"problem\">(.*?)(?:<span id=\"cause\">|</section>)", RAW, re.S)
    for li in re.findall(r"<li>(.*?)</li>", m.group(1), re.S) if m else []:
        if len(txt(li)) > 25: warn("brevity", "现象一行一个事实、≤ 25 字（现在 %d 字）  ← %s" % (len(txt(li)), txt(li)))
    m2 = re.search(r"<span id=\"charter\"></span>(.*?)</section>", RAW, re.S)
    for li in re.findall(r"<li>(.*?)</li>", m2.group(1), re.S) if m2 else []:
        if len(txt(li)) > 20: warn("brevity", "做 / 不做一项一句、≤ 20 字，细节进解决方案卡片（现在 %d 字）  ← %s" % (len(txt(li)), txt(li)))
    for sym in re.findall(r"<p class=\"sym\">(.*?)</p>", m.group(1), re.S) if m else []:
        if len(txt(sym)) > 40: warn("brevity", "现象一句话、≤ 40 字（现在 %d 字）  ← %s" % (len(txt(sym)), txt(sym)))
for sid, summ, what in (("cause", "证据（代码与现场）", "证据没挂到步骤：每一步自带它的证据（cause.steps[].evidence），对不上的进分组的「其他证据」"),
                        ("metrics", "怎么量", "量法没挂到行：每一行指标自带怎么量（metrics[].how）")):
    m = re.search(r"id=\"%s\">(.*?)(?:<span id=\"charter\">|</section>)" % sid, RAW, re.S)
    if m and re.search(r"<summary>%s</summary>" % re.escape(summ), m.group(1)):
        warn("fold-row", what)
m = re.search(r"<section id=\"evidence\">(.*?)</section>", RAW, re.S)
if TASK and m and re.search(r"<summary>上线证据</summary>", m.group(1)):
    warn("accept", "上线证据还是一行折叠：改成「上线后怎么验收」卡（evidence: [{what, where, pass, status, proof}]）")
for ev in re.findall(r"<div class=\"ev\"[^>]*>(.*?<dl class=\"kv\">.*?</dl>)", RAW, re.S):
    if "class=\"miss\"" in ev or "通过标准" not in ev:
        warn("accept", "验收项缺通过标准  ← " + txt(re.sub(r"<dl.*", "", ev, flags=re.S)))
# A300 — an acceptance item that passed carries the production page as shot after the switch,
# phone 390 + desktop 1440 (fleet-task-page.py evidence[].screenshots)
for st, ev in re.findall(r"<div class=\"ev\"(?: data-status=\"([^\"]*)\")?>(.*?)(?=<div class=\"ev\"|</section>|\Z)", RAW, re.S):
    done = st in ("done", "passed") or (not st and re.search(r"<span class=\"pill [^\"]*\">(已取|已通过)</span>", ev))
    vps = set(re.findall(r"<img[^>]*data-vp=\"(390|1440)\"", ev))
    if done and vps != {"390", "1440"}:
        name = txt(re.search(r"<strong>(.*?)</strong>", ev, re.S).group(1)) if "<strong>" in ev else "（未命名）"
        warn("task-evidence-shot", "已通过的验收项没有线上实拍（手机 390 + 桌面 1440 成对，缺 %s）  ← %s"
             % (" / ".join(v for v in ("390", "1440") if v not in vps), name))
for cls, summ, inner in re.findall(r"<details class=\"(fold|card|xr|oi)\"[^>]*>\s*<summary>(.*?)</summary>(.*?)</details>", RAW, re.S):
    if not txt(inner) and "<img" not in inner:
        warn("empty-fold", "点开是空的：没有可展开的内容就不放 ▸  ← " + (txt(summ) or cls))

seen = set()
for rule, text in warns:
    if (rule, text) in seen: continue
    seen.add((rule, text))
    print("WARN %s: %s" % (rule, text), file=sys.stderr)
sys.exit(1 if warns or errors else 0)
' <<<"$HTML"
