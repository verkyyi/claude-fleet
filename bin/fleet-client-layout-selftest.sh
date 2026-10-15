#!/bin/bash
# fleet-client-layout-selftest.sh — a session's top line (issue #1904, EPIC #1906
# C11), the one a thin client's 看台 wears (fleet-topbar.py render --node, issue
# #2763; its record is fleet-remote-view-thin-selftest.sh's).
#
#   A  pure: bin/fleet-topbar.py lays the line out at 140 / 80 / 45 columns, the
#      ⌘P panel's glyphs (issue #3194: ! x » ✓ ∙ ?, the word from 80, the PR from
#      80 and its checks from 140, the % on every width), red while the session
#      waits on you (its question in the title's place), grey with ? while its
#      machine is lost, reconnecting or on the relay — the only time it is named;
#      its words fleet-ui-lang.sh's, in English too.
# (The old client's list record, its phone layout, its full-screen switcher and
# its two tmux confs — leg B — went with that client, issue #3008.)
#
# Drives: bin/fleet-topbar.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

# --- A ---------------------------------------------------------------------------
python3 - "$BIN" <<'PY' || exit 1
import importlib.util, json, os, sys, tempfile
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, os.path.join(sys.argv[1], path))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod
tb = load("tb", "fleet-topbar.py")
errs, n = [], [0]
def eq(what, got, want):
    n[0] += 1
    if got != want:
        errs.append("%s: %r, want %r" % (what, got, want))
def has(what, text, part, yes=True):
    n[0] += 1
    if (part in text) != yes:
        errs.append("%s: %r %s %r" % (what, text, "lacks" if yes else "has", part))
rec = {"i": 3, "n": 8, "state": "working", "kind": "", "key": "#1894",
       "title": "机器上一直有会话在忙，也照样更新", "pr": "#1885✓", "repo": "claude-fleet",
       "slug": "verkyyi/claude-fleet", "node": "mac-b", "lost": False, "direct": False, "ask": 1,
       "ctx_left": 62, "ctx_band": "ok", "ctx_ts": 1000, "model": "Opus 5.5", "effort": "high"}
os.environ["FLEET_UI_LANG"] = "zh"
# the design's three widths (issue #3194): 45 · 80 · 140, the ⌘P panel's glyphs
w = {}
for cols in (140, 80, 45):
    text, bg = tb.fit(rec, cols, now=1060)
    w[cols] = text
    eq("%d: the line is exactly the width" % cols, tb.cells(text), cols)
    eq("%d: no colour while all is well" % cols, bg, None)
    for part in ("»", "#1894", "62%", "机器上"):
        has("%d: never dropped" % cols, text, part)
    for gone in ("‹", "›", "@mac-b", "mac-b", "●", "working"):
        has("%d: no %s (#3194)" % (cols, gone), text, gone, False)
eq("140: all of it", w[140].split(), ["»", "在干活", "·", "#1894", rec["title"], "·", "claude-fleet",
                                      "PR", "#1885", "✓", "·", "剩余", "62%", "·", "Opus", "5.5", "·", "high",
                                      "·", "⌘P"])
eq("80: word, PR, 62% Opus 5.5 high", w[80].split(), ["»", "在干活", "·", "#1894", rec["title"],
                                                     "PR", "#1885", "·", "62%", "Opus", "5.5", "high"])
eq("45: the glyph, #N, the title clipped, the %", w[45].split(), ["»", "#1894", "机器上一直有会话在忙，也照样更…", "62%"])
# each state, at 80
def at(cols=80, **kw):
    return tb.fit(dict(rec, **kw), cols, now=1060)
t, bg = at(state="needs", kind="ask", q="要你确认：删掉旧分支吗？")
eq("asking: red", bg, tb.BG_ASK); has("asking: !, no word", t, " ! #1894 要你确认：删掉旧分支吗？")
has("asking: the question takes the title's place", t, "机器上", False)
t, bg = at(state="needs", kind="perm", q="Bash: git push")
eq("needs OK: red too", bg, tb.BG_ASK); has("needs OK: its words", t, "! #1894 Bash: git push")
t, _ = at(state="needs", kind="ask"); has("asking, no words: the title", t, "! #1894 机器上")
t, bg = at(state="done", pr="merged"); eq("done: no colour", bg, None)
has("done: ✓ 做完了", t, " ✓ 做完了 · #1894"); has("done: PR 已合并", t, "PR 已合并 · 62%")
t, bg = at(state="exited"); eq("exited: the line unchanged", bg, None); has("exited: x 已退出", t, " x 已退出 · #1894")
t, _ = at(state="failed"); has("failed: x 失败", t, " x 失败 · ")
eq("exited: only the glyph red", [p[1] for p in tb.layout(dict(rec, state="exited"), 80, now=1060)[0] if p[2] == "sym"],
   ["colour1"])
t, _ = at(state="idle"); has("idle: ∙ 空闲", t, " ∙ 空闲 · ")
t, _ = at(state="sleeping"); has("asleep: ∙ 空闲", t, " ∙ 空闲 · ")
for s in ("looping", "preparing", "waking"):
    has("%s: » 在干活" % s, at(state=s)[0], " » 在干活 · ")
t, bg = at(lost=True)
eq("lost: grey", bg, tb.BG_DOWN); has("lost: ?, no word", t, " ? #1894 "); has("lost: the machine", t, "· mac-b 连不上")
t, bg = at(45, lost=True); eq("lost 45: grey", bg, tb.BG_DOWN); has("lost 45: 62% mac-b 连不上", t, "62% mac-b 连不上")
eq("lost 45: still the width", tb.cells(t), 45)
t, bg = tb.fit(rec, 80, down="1000", now=1004)
eq("reconnecting: grey", bg, tb.BG_DOWN); has("reconnecting: 连不上", t, "mac-b 连不上")
t, bg = tb.fit(rec, 80, route="relay", now=1060)
eq("relay: grey", bg, tb.BG_DOWN); has("relay: ? · 经中转", t, "· mac-b 经中转"); has("relay: ?", t, " ? #1894")
t, bg = tb.fit(rec, 80, via="auto 中转", now=1060); has("auto relay: 经中转", t, "mac-b 经中转")
t, bg = tb.fit(rec, 80, via="manual Tailscale", now=1060); eq("Tailscale: all well", bg, None)
has("Tailscale: no machine", t, "mac-b", False)
t, bg = tb.fit(rec, 80, down="1000", pin="relay", tries="3", now=1004)
has("pinned, reconnecting: 第 N 次", t, "mac-b 连不上 · 第 3 次重连")
eq("grey: the ? stays yellow", [p[1] for p in tb.layout(rec, 80, route="relay", now=1060)[0] if p[2] == "sym"],
   ["colour3"])
eq("lost wins over asking: grey", tb.fit(dict(rec, state="needs", kind="ask", lost=True), 80, now=1060)[1], tb.BG_DOWN)
t, _ = at(key="", title="整理周报里的发布时间线"); has("no issue: the title alone", t, " » 在干活 · 整理周报里的发布时间线")
t, _ = at(140, pr="#7…"); has("140: checks running", t, "PR #7 …")
t, _ = at(140, pr="#7✗"); has("140: checks red", t, "PR #7 ✗")
t, _ = at(80, pr="#7✗"); has("80: no checks", t, "PR #7 ·")
eq("glyphs: the panel's table", [tb.sym_of({"state": s}) for s in ("needs", "failed", "working", "done", "idle")],
   ["needs", "fail", "work", "done", "idle"])
eq("colours: the panel's table", tb.FV.GLYPH_COLORS["work"], 2)
os.environ["FLEET_GLYPHS"] = "ascii"
t, _ = at(140); has("ascii: > and +", t, " > 在干活 · #1894"); has("ascii: PR #N +", t, "PR #1885 +")
del os.environ["FLEET_GLYPHS"]
os.environ["NO_COLOR"] = "1"
eq("NO_COLOR: the glyph uncoloured", [p[1] for p in tb.layout(rec, 80, now=1060)[0] if p[2] == "sym"], [None])
del os.environ["NO_COLOR"]
eq("» and ∙ are one cell, as the panel counts", (tb.cells("»"), tb.cells("∙"), tb.cells("中")), (1, 1, 2))
# the context reading on every width (issue #2717, #3194): its three forms
c = dict(rec)
for cols, want in ((140, "剩余 62% · Opus 5.5 · high"), (80, "62% Opus 5.5 high"), (45, "62%")):
    eq("ctx %d" % cols, "".join(p[0] for p in tb.ctx_parts(c, cols, 1060)), want)
parts = tb.layout(c, 140, now=1060)[0]
eq("ctx >50: green", [p[1] for p in parts if p[0].startswith("剩余")], [tb.OK])
eq("ctx 20–50: amber", tb.ctx_parts(dict(c, ctx_left=50), 140, 1060)[0][1], tb.WARN)
eq("ctx <20: red", tb.ctx_parts(dict(c, ctx_left=19), 140, 1060)[0][1], tb.BAD)
h = tb.ctx_parts(dict(c, ctx_left=15, ctx_band="handoff"), 80, 1060)
eq("handoff: red + ⚠", h[0], ("15% ⚠", tb.BAD, ""))
has("handoff 80: 15% ⚠ Opus 5.5 high", tb.fit(dict(c, ctx_left=15, ctx_band="handoff"), 80, now=1060)[0], "15% ⚠ Opus 5.5 high")
old = tb.ctx_parts(c, 140, 1000 + 420)
eq("5 minutes old: all grey", [p[1] for p in old], [tb.DIM, tb.DIM])
has("5 minutes old: N 分钟前", old[1][0], " · 7 分钟前")
nc = {k: v for k, v in rec.items() if k not in ("ctx_left",)}
t, _ = tb.fit(nc, 140, now=0)
has("no ctx_left: no segment", t, "Opus", False)
eq("no ctx_left: no parts, no error", tb.ctx_parts(nc, 140, 0), [])
# the line's words are fleet-ui-lang.sh's (issue #3324): English under FLEET_UI_LANG=en,
# and no CJK literal left in fleet-topbar.py outside its comments and docstrings
import ast, re
os.environ["FLEET_UI_LANG"] = "en"
tb._WORDS.clear(); tb.FV._WORDS.clear()
t, _ = tb.fit(dict(rec, state="done", pr="merged"), 140, now=1060)
has("en: done", t, " ✓ done · #1894"); has("en: PR merged", t, "PR merged · 62% left · Opus 5.5 · high")
has("en: PR closed", tb.fit(dict(rec, pr="closed"), 140, now=1060)[0], "PR closed")
has("en: unreachable", tb.fit(rec, 80, down="1", now=1060, pin="direct", tries="3")[0], "mac-b unreachable · retry 3")
has("en: via relay", tb.fit(rec, 80, route="relay", now=1060)[0], "mac-b via relay")
has("en: N min ago", "".join(p[0] for p in tb.ctx_parts(rec, 140, 1420)), " · 7 min ago")
src = open(os.path.join(sys.argv[1], "fleet-topbar.py"), encoding="utf-8").read()
tree = ast.parse(src)
docs = {id(b.body[0].value) for b in ast.walk(tree)
        if isinstance(b, (ast.Module, ast.FunctionDef, ast.ClassDef)) and b.body
        and isinstance(b.body[0], ast.Expr) and isinstance(b.body[0].value, ast.Constant)}
cjk = [(c.lineno, ast.get_source_segment(src, c)) for c in ast.walk(tree)
       if isinstance(c, ast.Constant) and isinstance(c.value, str) and id(c) not in docs
       and re.search("[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]", ast.get_source_segment(src, c) or "")]
eq("fleet-topbar.py: no CJK literal outside comments (fleet-ui-lang.sh is the table)", cjk, [])
os.environ["FLEET_UI_LANG"] = "zh"
tb._WORDS.clear(); tb.FV._WORDS.clear()
if errs:
    print("FAIL A:\n  " + "\n  ".join(errs)); sys.exit(1)
print("A: top line: %d checks" % n[0])
PY

exit 0
