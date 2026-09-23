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
# (skills/epic-page/SKILL.md, rule 0) so you know what "good" looks like.
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
# It is a checklist aid, not a judge: a clean lint does not make a page good —
# rules like "the surface answers the theme's question" are yours to read.
#
# Exit: 0 clean (or no --lint) · 1 lint warnings · 2 usage / unreadable input.
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
        if tag == "section": self.section = a.get("id", "")
        if tag in ("head","style","script","template"): self.hidden += 1
        elif tag == "details" and "fold" in cls: self.hidden += 1
        elif tag == "details" and "card" in cls: self.card.append(False)
        if tag == "summary" and self.card and not self.card[-1] and self.stack and self.stack[-1][0] == "details":
            self.card[-1] = True
            self.stack.append((tag, hid, "cardsum")); self.flush(); return
        if tag in ("code","kbd") and not self.hidden:
            self.code += 1; self.buf.append("`")
        if tag == "tr": self.flush(); self.cells = []; self.head_row = False
        if tag == "th": self.head_row = True
        elif tag in ("td","th"): self.buf = []
        elif tag in BLOCK: self.flush()
        if tag == "dt": self.dt = ""; self.raw = []
        if tag == "dd" and self.dt == "为谁": self.whom_buf = []
        kind = "card" if (tag == "details" and "card" in cls) else "eyebrow" if "eyebrow" in cls else ""
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
        if t in ("td","th") and self.cells is not None:
            self.cells.append(re.sub(r"\s+", " ", "".join(self.buf)).strip()); self.buf = []
        elif t == "tr":
            if self.cells and not self.hidden:
                self.lines.append(("th" if self.head_row else "tr", "| " + " | ".join(self.cells) + " |", self.section))
            self.cells = None; self.buf = []
        elif kind == "cardsum":
            self.flush("card")
            self.hidden += 1        # the rest of the card is one tap away
        elif t in BLOCK:
            k = "eyebrow" if kind == "eyebrow" else t if t in ("h1","h2","h3","h4","li","dt","dd","summary") else "p"
            if t == "dt": self.dt = re.sub(r"\s+", "", "".join(self.raw))
            if t == "dd" and self.whom_buf is not None:
                self.whom.append(re.sub(r"\s+", " ", "".join(self.whom_buf)).strip()); self.whom_buf = None
            self.flush(k)
        if t == "strong" and any(k == "cardsum" for _, _, k in self.stack):
            self.buf.append(" — ")   # 名称 — 一句
        if kind == "card" and self.card: self.card.pop()
        # a fold, a card and <head>/<style>/<script> each end their own hiding
        if t in ("details","head","style","script","template"): self.hidden = hid
    def handle_data(self, d):
        if not self.hidden: self.buf.append(d)   # hidden text never reaches the surface
        self.raw.append(d)
        if self.whom_buf is not None: self.whom_buf.append(d)
    def handle_comment(self, d): pass

p = Surface()
p.feed(sys.stdin.read()); p.close(); p.flush()

PFX = {"th":"","h1":"# ","h2":"\n## ","h3":"### ","h4":"#### ","li":"- ","card":"▸ ","summary":"▸ ","dt":"","dd":"  "}
for kind, text, sec in p.lines:
    print(PFX.get(kind, "") + text)

if not LINT: sys.exit(0)

warns = []
def warn(rule, text): warns.append((rule, text))

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

seen = set()
for rule, text in warns:
    if (rule, text) in seen: continue
    seen.add((rule, text))
    print("WARN %s: %s" % (rule, text), file=sys.stderr)
sys.exit(1 if warns else 0)
' <<<"$HTML"
