#!/bin/bash
# fleet-task-page-selftest.sh — /fleet-task-plan's page and its words (T661).
# Hermetic: python3 only, no network, no hub.
#
#   A  render: the example spec (plugins/fleet-epic/skills/epic-page/
#      task-page.example.json) becomes a page carrying every id
#      `fleet-task-page.py ids` names, the #open anchor and epic-page's own
#      <style> verbatim; bin/epic-page-surface.sh --lint reads it clean.
#   B  a feature (kind=feature) titles #cause 「为什么要做」; the lint's task rules
#      fire on a page missing a section, a 原因 with no folded evidence, and a
#      需要你定的事 with no 「点头即全部按建议」.
#   C  body: both layers (every fold written out), the eyebrow / footer left
#      behind, 上线证据 kept, the nod recorded; measured as fleet-task-record.sh
#      sends it (UTF-8 JSON) and under --max; a smaller --max moves the cause's
#      evidence first, then 改法's 技术细节 — 上线证据 never; nothing fits ⇒ exit 1.
#   D  stamp: 「任务设计」 → 「任务 T<n>」, again → the new id (idempotent);
#      fleet-task-record.sh dispatch sends the words as UTF-8 (not \uXXXX).
#   E  the command and the skill point at the script and the lint.
#   F  改前 / 改后 (T699): a member's `compare` renders ONE div.cmp in the card's
#      upper layer (two columns, stacked ≤640px, buttons ≥30px, every state shown
#      in print — the frame's <style>); with no script the first state is the one
#      not hidden and the buttons stay hidden; `compare <json>` prints the same
#      block (template.html's slot IS its output); the spec's `css` follows the
#      frame's <style>; body writes the block as words, one line per state, no
#      HTML or script; an old `proto` page link draws the lint's `compare` WARN.
#   G  T764: each 原因 step opens on ITS evidence and each 指标 row on how IT is
#      measured; a step / row / card with nothing to open is a plain line (no ▸,
#      no <details>); leftover evidence is grouped by kind, each item a title that
#      opens on file:line + excerpt; 问题与原因 / 目标 / 解决方案 are the sections
#      (#cause / #charter anchors inside); the 上线后怎么验收 card shows what · 在哪取
#      · 通过标准 in the plan and adds status + slot once building (proof filled);
#      `feedback` puts the table + version on <body>; every item answers on its own
#      (a div.fbi: 需要你定的事 rows with their options in the row, the default
#      marked and drawn as what counts; 「有意见」 per step / card, one
#      全部按建议); the frame's script posts {item, choice, note, version, at}, reads
#      the table back on load (+ localStorage), draws each item's last row with 改 ·
#      撤回 (withdraw = a row) and reads <table>_done; replies_done marks it too;
#      an OLD spec still renders its shared folds and draws fold-row / accept.
#      A300: a done / passed item shows its production screenshots (phone 390 +
#      desktop 1440) as thumbnails that open full size; one without the pair draws
#      task-evidence-shot; pending / failed items need none.
#   H  T869: the frame's comments and scripts never spell a page tag (body / head /
#      html), so a text 「replace the first body tag」 cannot hit one; a frame that
#      still says it in a head script comment, assembled with `fb-body`, keeps its
#      body full (check 0, lint clean of ERROR); the same frame assembled the old
#      way — the first spelling replaced — puts the page into the head: `check`
#      exits 1 and the lint says ERROR body; an empty body is an ERROR too; render
#      refuses a frame whose head would swallow the page.
#   I  NZP2: folds nested to any depth (the 会话合一 v4 page's shape — a 代码位置
#      fold, details.code, inside a step's evidence, inside an 其他证据 item's
#      paragraph and inside a card's 技术细节 <dd>, one more fold inside that):
#      body writes every layer, keeps the words before a nested fold and its dd
#      label, never crashes at any --max (the old kind() unpacked a dropped fold's
#      third field), moves the 代码位置 folds first; over the cap the message
#      names --split; --split writes one task per member card, each with the
#      link, every shared section and only its own card; one card ⇒ exit 1; the
#      lint hides a first-layer 代码位置 fold.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROOT="$BIN/.."
P="$BIN/fleet-task-page.py"
L="$BIN/epic-page-surface.sh"
EX="$ROOT/plugins/fleet-epic/skills/epic-page/task-page.example.json"
T="$ROOT/plugins/fleet-epic/skills/epic-page/template.html"
CMD="$ROOT/plugins/fleet-epic/commands/fleet-task-plan.md"
st_tally count
st_need python3
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ftp.XXXXXX") || st_fail "mktemp"
trap 'rm -rf "$TMP"' EXIT

# ---- A ------------------------------------------------------------------------
export ST_LEG=A
python3 "$P" render "$EX" -o "$TMP/page.html" || st_fail "render the example"
PAGE=$(cat "$TMP/page.html")
for id in $(python3 "$P" ids); do st_has "id $id" "$PAGE" " id=\"$id\">"; done
st_eq "eight ids" 8 "$(python3 "$P" ids | wc -l | tr -d ' ')"
st_has "open anchor" "$PAGE" '<span id="open"></span>'
st_has "eyebrow" "$PAGE" '<p class="eyebrow">任务设计 · verkyyi/claude-fleet'
st_has "a card per member" "$PAGE" '<div class="ob" id="m-C">'
st_has "a step opens on its own evidence" "$PAGE" '<div class="xd">'
st_hasnt "no shared evidence fold" "$PAGE" '<summary>证据（代码与现场）</summary>'
STYLE=$(python3 - "$T" "$TMP/page.html" <<'PY'
import re, sys
a, b = (re.search(r"<style>\s*:root.*?</style>", open(f, encoding="utf-8").read(), re.S).group(0) for f in sys.argv[1:])
print("same" if a == b else "differs")
PY
)
st_eq "epic-page's <style> verbatim" same "$STYLE"
out=$(bash "$L" --lint "$TMP/page.html" 2>&1); rc=$?
st_eq "the example lints clean" 0 "$rc" "$out"
echo '{"title":"x"' > "$TMP/bad.json"
python3 "$P" render "$TMP/bad.json" >/dev/null 2>&1; st_eq "bad spec → 2" 2 $?

# ---- B ------------------------------------------------------------------------
ST_LEG=B
python3 - "$EX" "$TMP/feat.json" "$TMP/broken.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
f = dict(d, kind="feature", cause={"lede": "你今天得自己拼这一页。", "points": ["每次排查都要从头讲一遍"]})
json.dump(f, open(sys.argv[2], "w"), ensure_ascii=False)
b = dict(d, signoff_note="好的")
b["cause"] = {"lede": d["cause"]["lede"], "steps": [{"step": x["step"], "what": x["what"]} for x in d["cause"]["steps"]]}
json.dump(b, open(sys.argv[3], "w"), ensure_ascii=False)
PY
FEAT=$(python3 "$P" render "$TMP/feat.json")
st_has "feature: one section, its own name" "$FEAT" '<section id="problem">
<h2>现在的样子与为什么要做</h2>'
st_has "fix: 问题与原因" "$PAGE" '<h2>问题与原因</h2>'
st_has "目标 = 指标 + 做 / 不做" "$PAGE" '<span id="charter"></span>
<h3>做</h3>'
st_has "解决方案" "$PAGE" '<h2>解决方案</h2>'
printf '%s' "$FEAT" | bash "$L" --lint - >/dev/null 2>&1; st_eq "a feature needs no evidence fold" 0 $?
python3 "$P" render "$TMP/broken.json" | sed 's/<section id="risks">/<section id="r">/' > "$TMP/broken.html"
w=$(bash "$L" --lint "$TMP/broken.html" 2>&1 >/dev/null); rc=$?
st_eq "broken page → 1" 1 "$rc"
st_has "task-section" "$w" 'WARN task-section: 任务页缺少 #risks'
st_has "task-evidence" "$w" 'WARN task-evidence:'
st_has "task-signoff" "$w" 'WARN task-signoff:'
w=$(bash "$L" --lint "$T" 2>&1 >/dev/null)
st_hasnt "an EPIC page is not held to the task frame" "$w" 'task-'

# ---- C ------------------------------------------------------------------------
ST_LEG=C
B=$(python3 "$P" body "$TMP/page.html" --link https://p/s/x --nod "操作者 2026-10-20"); rc=$?
st_eq "body → 0" 0 "$rc"
st_has "link first" "$B" '> 设计页：https://p/s/x（私密；本文是它的两层全文）'
st_has "title" "$B" '# 批次报告送不到你手里'
st_has "band" "$B" '根本原因 1 · 要改的地方 3'
st_has "cause steps" "$B" '- 1 · 编排开出「计划页会话」'
st_has "a step's own evidence under it" "$B" '  - `bin/fleet-report-parent.sh:300-305`'
st_has "a metric row and its how" "$B" '- 上一层还有活着的会话、回报却成了无主 · 今天 3 次 · 0 次
  无主回报文件里'
st_has "an acceptance item" "$B" '- 1. **三层演练：上一层关掉后回报照样送到**
  **在哪取**'
st_hasnt "no page controls in the words" "$B" '我要逐条改'
st_hasnt "no form labels" "$B" '改成…'
st_has "evidence written out" "$B" 'bin/fleet-report-parent.sh:300-305'
st_has "card name — line" "$B" '### 回报先按身份找人 — 退役判断放到身份路由之后'
st_has "tech written out" "$B" '**完成判据** `origin-selftest.sh` D'
st_has "上线证据 kept" "$B" '演练会话 A 开 B、B 开 C'
st_has "nod" "$B" '操作者 2026-10-20：全部按「需要你定的事」的建议执行'
st_hasnt "no eyebrow" "$B" '任务设计 ·'
st_hasnt "no footer" "$B" '本页私密'
st_hasnt "no style" "$B" '--ground'
size() { python3 -c 'import json,sys; print(len(json.dumps(sys.stdin.read(), ensure_ascii=False).encode()))'; }
n=$(printf '%s\n' "$B" | size)
st_eq "under the default cap ($n)" yes "$([ "$n" -le 13000 ] && echo yes)"
B=$(python3 "$P" body "$TMP/page.html" --max 7000)
n=$(printf '%s\n' "$B" | size)
st_eq "under --max 7000 ($n)" yes "$([ "$n" -le 7000 ] && echo yes)"
st_has "evidence moved first" "$B" '  （证据：见设计页）'
st_has "tech kept at 7000" "$B" '**完成判据**'
B=$(python3 "$P" body "$TMP/page.html" --max 6000 --link L)
n=$(printf '%s\n' "$B" | size)
st_eq "under --max 6000 ($n)" yes "$([ "$n" -le 6000 ] && echo yes)"
st_has "tech moved next" "$B" '（技术细节：见设计页）'
st_has "上线证据 never moved" "$B" '演练会话 A 开 B、B 开 C'
st_has "the note says so" "$B" '标「见设计页」的几段只在页面上'
python3 "$P" body "$TMP/page.html" --max 300 >/dev/null 2>&1; st_eq "nothing fits → 1" 1 $?

# ---- D ------------------------------------------------------------------------
ST_LEG=D
python3 "$P" stamp "$TMP/page.html" T661 -o "$TMP/s1.html"
st_has "stamped" "$(cat "$TMP/s1.html")" '<p class="eyebrow">任务 T661 · verkyyi/claude-fleet'
st_has "restamped" "$(python3 "$P" stamp "$TMP/s1.html" K3F9)" '<p class="eyebrow">任务 K3F9 · '
st_has "dispatch sends UTF-8" "$(cat "$BIN/fleet-task-record.sh")" 'ensure_ascii=False))   # the hub reads 16 KB'

# ---- E ------------------------------------------------------------------------
ST_LEG=E
for s in fleet-task-page.py epic-page-surface.sh task-page.example.json 'fleet-task-record.sh dispatch' push_to_wechat; do
  st_has "command names $s" "$(cat "$CMD")" "$s"
done
st_has "skill names the task page" "$(cat "$ROOT/plugins/fleet-epic/skills/epic-page/SKILL.md")" 'fleet-task-page.py'

# ---- F ------------------------------------------------------------------------
ST_LEG=F
st_has "a block in the example's card" "$PAGE" '<div class="cmp">'
CARD=$(python3 - "$TMP/page.html" <<'PY2'
import re, sys
p = open(sys.argv[1], encoding="utf-8").read()
c = re.search(r'<div class="ob" id="m-C">.*?</div>\n\n', p, re.S).group(0)
up = c.split('<details class="fold">')[0]
print("upper" if '<div class="cmp">' in up else "folded")
sts = re.findall(r'<div class="st"( hidden)?', c)
print("states=%d first=%s rest=%s" % (len(sts), "shown" if not sts[0] else "hidden", "hidden" if all(sts[1:]) else "shown"))
tabs = re.search(r'<div class="tabs">.*?</div>', c, re.S).group(0)
print("buttons=%d on=%d" % (tabs.count("<button"), tabs.count('class="on"')))
PY2
)
st_has "block in the upper layer" "$CARD" upper
st_has "no-JS: the first state shows, the rest are hidden" "$CARD" 'states=3 first=shown rest=hidden'
st_has "one button per state, the first on" "$CARD" 'buttons=3 on=1'
TPL=$(cat "$T")
st_has "narrow: the columns stack" "$TPL" '@media (max-width:640px){ .cmp .cols{grid-template-columns:1fr} }'
st_has "buttons ≥30px" "$TPL" 'min-height:32px'
st_has "buttons hidden until the script runs" "$TPL" '.cmp .tabs{display:none;'
st_has "the script shows them" "$TPL" '.js .cmp .tabs{display:flex}'
st_has "print: every state" "$TPL" '.cmp .st[hidden]{display:block!important}'
st_has "改前 grey, 改后 accent" "$TPL" '.cmp .tag.new{color:var(--accent)'
st_has "the switch rides the frame's head" "$PAGE" 'closest(".cmp .tabs button")'
cat > "$TMP/ph.json" <<'EOF'
{"before":{"html":"⟨现在的样子 — 取自现状（截图写 img）⟩","note":"⟨一句：现在哪里不好⟩"},
 "states":[{"label":"⟨状态 1⟩","html":"⟨上线后的样子 — 真样式、真文案⟩","note":"⟨一句：这一态怎么样⟩"},
           {"label":"⟨状态 2⟩","html":"⟨另一个场景：出错 / 空态 / 手机⟩","note":"⟨…⟩"}]}
EOF
BLK=$(python3 "$P" compare "$TMP/ph.json") || st_fail "compare"
st_has "template's slot is the renderer's output" "$TPL" "$BLK"
ONE=$(printf '%s' '{"before":{"img":"shots/a b.png","note":"旧"},"after":{"img":"shots/new.png","alt":"新的","note":"新"}}' | python3 "$P" compare -)
st_has "an image beside the page" "$ONE" '<img src="shots/a b.png"'
st_hasnt "one 改后: no buttons" "$ONE" '<button'
st_hasnt "one 改后: nothing hidden" "$ONE" 'hidden'
printf '{"before":{"html":"x"}}' | python3 "$P" compare - >/dev/null 2>&1; st_eq "no after → 2" 2 $?
python3 - "$EX" "$TMP/css.json" "$TMP/old.json" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
json.dump(dict(d, css=".tm{background:#1a1b26}"), open(sys.argv[2], "w"), ensure_ascii=False)
m = [dict(x) for x in d["members"]]
m[2].pop("compare"); m[2]["proto"] = "proto-c.html"
json.dump(dict(d, members=m), open(sys.argv[3], "w"), ensure_ascii=False)
PY2
st_has "the spec's css after the frame's" "$(python3 "$P" render "$TMP/css.json")" '</script>
<style>
.tm{background:#1a1b26}
</style>
</head>'
w=$(python3 "$P" render "$TMP/old.json" | bash "$L" --lint - 2>&1 >/dev/null)
st_has "an old proto page link warns" "$w" 'WARN compare: 还链到单独的原型页'
st_has "and a visual card with no block" "$w" 'WARN compare: 界面有变化，卡片里却没有「改前 / 改后」对比  ← 真没人收时提醒你'
B=$(python3 "$P" body "$TMP/page.html")
st_has "body: the block as words" "$B" '**改前 / 改后**
- 改前：批次报告没人收时'
st_has "body: one line per state" "$B" '- 改后 · 微信：同一批次只推一次'
st_hasnt "body: no block HTML" "$B" 'class="cmp"'
st_hasnt "body: no script" "$B" 'addEventListener'
st_hasnt "body: no pane content" "$B" '点开看全文 ›'
st_has "the command says compare" "$(cat "$CMD")" '"states"'

# ---- G ------------------------------------------------------------------------
ST_LEG=G
python3 - "$EX" "$TMP/g.json" "$TMP/gold.json" <<'PY3'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
g = dict(d, phase="build", replies_done={"signoff-1": {"state": "declined", "note": "先不推微信"}})
g["members"] = d["members"] + [{"key": "Z", "name": "只有一句", "line": "没有可展开的"}]
ev = [dict(e) for e in d["evidence"]]
ev[0].update(status="done", proof={"text": "A 收到：C 完成", "caption": "04:52Z"})
ev[1]["status"] = "failed"
ev[2].update(status="passed", screenshots=[{"mobile": "shots/3-390.png"}])
g["evidence"] = ev
json.dump(g, open(sys.argv[2], "w"), ensure_ascii=False)
o = {k: v for k, v in d.items() if k != "feedback"}
o["cause"] = {"lede": "x", "steps": [[x["step"], x["what"]] for x in d["cause"]["steps"]], "evidence": ["<code>a.sh:1</code> 现场"]}
o["metrics"] = [[m["name"], m["now"], m["target"]] for m in d["metrics"]]
o["metrics_how"] = ["数一下"]
o["evidence"] = "换版后贴 A 窗口收到的回报"
json.dump(o, open(sys.argv[3], "w"), ensure_ascii=False)
PY3
STEPS=$(python3 - "$TMP/page.html" <<'PY3'
import re, sys
p = open(sys.argv[1], encoding="utf-8").read()
sec = re.search(r'<span id="cause"></span>(.*?)</section>', p, re.S).group(1)
print("open=%d plain=%d" % (sec.count('<details class="xr">'), len(re.findall(r'<div class="xr">', sec))))
m = re.search(r'<section id="metrics">(.*?)</section>', p, re.S).group(1)
print("mopen=%d" % m.count('<details class="xr">'))
PY3
)
st_has "steps with evidence open, the rest are plain rows" "$STEPS" 'open=3 plain=3'
st_has "each metric row opens on its how" "$STEPS" 'mopen=2'
st_has "a plain row has no arrow" "$(cat "$T")" '.xt details.xr>summary i::before{content:"▸"'
st_has "leftover evidence, grouped" "$PAGE" '<div class="og"><span class="ok">外部资料</span>'
st_has "a grouped item opens on its original" "$PAGE" '<details class="oi"><summary>为什么以前没事'
st_has "plan: what · where · pass" "$PAGE" '<dt>通过标准</dt><dd>A 窗口收到 C 的完成回报'
st_hasnt "plan: no status" "$PAGE" '待取'
st_hasnt "plan: no slot" "$PAGE" 'class="slot"'
st_has "feedback: the table on <body>" "$PAGE" '<body data-fb-table="replies" data-fb-version="v1">'
st_has "feedback: a step's entry" "$PAGE" 'data-say="cause-1"'
st_has "feedback: a card answers on its own" "$PAGE" '<div class="fbi" data-item="card-A" data-kind="say"><span class="fbs"></span><form class="fbf say" id="say-card-A" data-item="card-A" hidden>'
st_has "feedback: a decision row, its options in it, the default marked" "$PAGE" '<div class="fbi" data-item="signoff-1" data-kind="pick" data-default="顶栏一行 + 微信一条"><form class="fbf pick" data-item="signoff-1"><div class="opts"><button type="button" class="opt dflt" data-v="顶栏一行 + 微信一条">顶栏一行 + 微信一条<span class="dm">默认</span></button><button type="button" class="opt" data-v="只在顶栏">只在顶栏</button>'
st_has "feedback: an old [事项, 建议] row defaults to 按建议" "$PAGE" 'data-item="signoff-2" data-kind="pick" data-default="按建议"'
st_has "feedback: 改成… opens a note on the row" "$PAGE" '<button type="button" class="opt free" data-v="改成">改成…</button></div><div class="freebox" hidden>'
st_has "nothing picked: the default is drawn as what counts" "$(cat "$T")" 'o.classList.toggle("idle",!got&&v===dv)'
st_has "a non-default pick is highlighted" "$(cat "$T")" 'o.classList.toggle("alt",!!got&&v===got.choice&&v!==dv)'
st_has "feedback: one nod" "$PAGE" '<div class="fbi" data-item="nod" data-kind="nod"><form class="fbf nod" data-item="nod" data-choice="全部按建议"><button>全部按建议</button>'
st_hasnt "feedback: no global switch" "$PAGE" 'fb-more'
st_has "feedback: the route is one small line" "$PAGE" '<p class="fb-note">ⓘ 每一项都能单独改、单独撤回'
TPL=$(cat "$T")
st_has "the frame posts to the page's own table, stamped" "$TPL" 'version:D().fbVersion||"",at:new Date().toISOString()'
st_has "it reads the table back on load" "$TPL" 'fetch("./_data/"+t+".json",{credentials:"include"})'
st_has "this device's unsynced rows from localStorage" "$TPL" 'localStorage.getItem(KEY())'
st_has "each item's LAST row wins" "$TPL" 'function last(rows)'
st_has "a withdraw is a row" "$TPL" 'post(null,item,"withdraw","",'
st_has "a submitted nod hides its button" "$TPL" '.fbi.done form.nod{display:none}'
st_has "已采纳 / 未采纳 from the live _done table" "$TPL" 'fetch("./_data/"+t+"_done.json"'
G=$(python3 "$P" render "$TMP/g.json") || st_fail "render the build-phase spec"
st_has "build: status" "$G" '<span class="pill ">已取</span>'
st_has "build: a failed item" "$G" '<span class="pill crit">未通过</span>'
st_has "build: an empty slot" "$G" '<div class="slot">待回填：截图 / 终端输出 / 链接</div>'
st_has "build: the proof filled in" "$G" '<figure class="got"><pre>A 收到：C 完成</pre><figcaption>04:52Z</figcaption></figure>'
# A300 — a passed item carries the production page, phone 390 + desktop 1440, as thumbnails
st_has "build: the item says its status" "$G" '<div class="ev" data-status="done">'
st_has "build: a phone shot opens full size" "$G" '<a class="shot" href="shots/1-390.png" target="_blank" rel="noopener"><img src="shots/1-390.png" alt="手机 390" data-vp="390" loading="lazy">'
st_has "build: and its desktop pair" "$G" '<img src="shots/1-1440.png" alt="桌面 1440" data-vp="1440"'
st_has "build: the shot's caption and live URL" "$G" '<p class="scap">线上实拍：A 窗口收到的那一条 · <a href="https://⟨线上地址⟩">线上地址</a></p>'
st_has "the frame styles the thumbnails" "$(cat "$T")" '.ev a.shot img{'
st_hasnt "plan: no shots" "$PAGE" 'class="shots"'
w=$(printf '%s' "$G" | bash "$L" --lint - 2>&1 >/dev/null)
st_has "a passed item with half a pair warns" "$w" 'WARN task-evidence-shot: 已通过的验收项没有线上实拍（手机 390 + 桌面 1440 成对，缺 1440）  ← 今天丢的 3 份补送到了'
st_hasnt "a done item with the pair is clean" "$w" '← 三层演练'
st_hasnt "a failed item needs no shot" "$w" '← 无主回报不再增加'
w=$(python3 - "$TMP/g.json" <<'PY3' | python3 "$P" render - | bash "$L" --lint - 2>&1 >/dev/null
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for e in d["evidence"]:
    e.pop("screenshots", None)
d["evidence"][1]["status"] = "pending"
print(json.dumps(d, ensure_ascii=False))
PY3
)
st_has "a done item with no shot warns" "$w" 'WARN task-evidence-shot: 已通过的验收项没有线上实拍（手机 390 + 桌面 1440 成对，缺 390 / 1440）  ← 三层演练'
st_hasnt "a pending item needs no shot yet" "$w" '← 无主回报不再增加'
st_has "replies_done marks the row" "$G" '<p class="fb-done" data-for="signoff-1"><span class="pill muted">未采纳</span> 先不推微信'
st_has "a card with nothing to open has no fold" "$G" '<div class="ob" id="m-Z">
<div class="card">'
OLD=$(python3 "$P" render "$TMP/gold.json") || st_fail "render an old spec"
st_has "old spec: the shared evidence fold" "$OLD" '<summary>证据（代码与现场）</summary>'
st_has "old spec: the shared 怎么量" "$OLD" '<summary>怎么量</summary>'
st_hasnt "old spec: no feedback" "$OLD" '<body data-fb-table'
w=$(printf '%s' "$OLD" | bash "$L" --lint - 2>&1 >/dev/null)
st_has "old spec: lint says move evidence to the steps" "$w" 'WARN fold-row: 证据没挂到步骤'
st_has "old spec: lint says move how to the rows" "$w" 'WARN fold-row: 量法没挂到行'
st_has "old spec: lint says make the acceptance card" "$w" 'WARN accept: 上线证据还是一行折叠'
w=$(python3 - "$EX" <<'PY3' | python3 "$P" render - | bash "$L" --lint - 2>&1 >/dev/null
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["charter"]["do"].append("真正没人可送时提醒你（面板一行 + 微信），不再只写进文件")
print(json.dumps(d, ensure_ascii=False))
PY3
)
st_has "a long 做 item draws brevity" "$w" 'WARN brevity: 做 / 不做一项一句、≤ 20 字'

# ---- H ------------------------------------------------------------------------
export ST_LEG=H
TAGS=$(python3 - "$T" <<'PY3'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
# comments and script / style bodies: where a text replace could land by mistake
inner = re.findall(r"<!--.*?-->", s, re.S) + re.findall(r"<(script|style)[^>]*>(.*?)</\1>", s, re.S)
inner = [x if isinstance(x, str) else x[1] for x in inner]
print(sum(len(re.findall(r"</?(?:body|head|html)\b", x, re.I)) for x in inner))
PY3
)
st_eq "the frame's comments and scripts spell no page tag" "0" "$TAGS"
# a frame that still carries the 2026-10-21 comment in its head script
python3 - "$T" "$TMP/bad-frame.html" <<'PY3'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
s = s.replace("<script>", "<script>\n/* on a page whose <body> says data-fb-table, every item answers */", 1)
open(sys.argv[2], "w", encoding="utf-8").write(s)
PY3
st_has "fixture carries the comment" "$(cat "$TMP/bad-frame.html")" 'page whose <body> says'
python3 "$P" fb-body "$TMP/bad-frame.html" replies v1 -o "$TMP/fb.html" || st_fail "fb-body"
FB=$(cat "$TMP/fb.html")
st_has "fb-body set the real tag" "$FB" $'</head>\n<body data-fb-table="replies" data-fb-version="v1">'
st_has "fb-body left the comment alone" "$FB" 'page whose <body> says'
python3 "$P" check "$TMP/fb.html"; st_eq "fb-body page: check 0" "0" "$?"
w=$(bash "$L" --lint "$TMP/fb.html" 2>&1 >/dev/null)
st_hasnt "fb-body page: no ERROR" "$w" 'ERROR body'
# the old assembly: the first spelling replaced and the page put after it
python3 - "$TMP/bad-frame.html" "$TMP/old.html" <<'PY3'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
s = s.replace("<body>", '<body data-fb-table="replies" data-fb-version="v1">\n<div class="wrap"><h1>标题</h1><section id="problem"><p>正文</p></section></div>', 1)
open(sys.argv[2], "w", encoding="utf-8").write(s)
PY3
python3 "$P" check "$TMP/old.html" 2>/dev/null; st_eq "old assembly: check 1" "1" "$?"
w=$(bash "$L" --lint "$TMP/old.html" 2>&1 >/dev/null); rc=$?
st_eq "old assembly: lint exits 1" "1" "$rc"
st_has "old assembly: lint says ERROR body" "$w" 'ERROR body: 正文落在 <head> 里'
python3 "$P" fb-body "$TMP/old.html" replies v2 >/dev/null 2>&1; st_eq "fb-body refuses a swallowed page" "1" "$?"
w=$(printf '<html><head><title>x</title></head><body></body></html>' | bash "$L" --lint - 2>&1 >/dev/null)
st_has "an empty body is an ERROR" "$w" 'ERROR body: body 是空的'
FLEET_TASK_PAGE_TEMPLATE="$TMP/bad-frame.html" python3 "$P" render "$EX" >/dev/null 2>&1
st_eq "render through a comment-carrying frame stays whole" "0" "$?"
printf '<html><head><script>/* ends at </head> */</script></head><body></body></html>\n' > "$TMP/swallow.html"
FLEET_TASK_PAGE_TEMPLATE="$TMP/swallow.html" python3 "$P" render "$EX" >/dev/null 2>&1
st_eq "render refuses a frame whose head swallows the page" "1" "$?"

# ---- I ------------------------------------------------------------------------
ST_LEG=I
python3 - "$EX" "$TMP/nest.json" <<'PYI'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
code = lambda inner: '<details class="code"><summary>代码位置（展开）</summary>%s</details>' % inner
d["cause"]["steps"][3]["evidence"].append("实测：16/16 通过" + code(
    '取自 <code>bin/nest-a-selftest.sh</code><details class="code"><summary>原始输出</summary>第三层原文</details>'))
d["cause"]["other"].append({"kind": "scene", "title": "实测二：接回要多久",
                            "text": "中位 1.28 秒" + code("<code>tmux -L parkbench</code>") + "，远在 5 秒内"})
d["members"][0]["tech"].append(["完成判据二", "判据先说" + code("<code>bin/nest-b.sh:12</code>")])
d["problem"].append('一处表层折叠' + code("<code>bin/nest-first.sh</code>"))
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
PYI
python3 "$P" render "$TMP/nest.json" -o "$TMP/nest.html" || st_fail "render the nested spec"
st_has "two layers of code fold in the page" "$(cat "$TMP/nest.html")" '<summary>原始输出</summary>'
B=$(python3 "$P" body "$TMP/nest.html" --max 99999 2>&1); rc=$?
st_eq "nested body → 0" 0 "$rc"
st_hasnt "no traceback" "$B" 'Traceback'
st_has "the words before a nested fold" "$B" '实测：16/16 通过'
st_has "layer 2 written out" "$B" '取自 `bin/nest-a-selftest.sh`'
st_has "layer 3 written out" "$B" '第三层原文'
st_has "a paragraph's words around its fold" "$B" '中位 1.28 秒'
st_has "…and after it" "$B" '，远在 5 秒内'
st_has "a dd keeps its label before its fold" "$B" '**完成判据二** 判据先说'
st_has "no 「（展开）」 in words" "$B" '**代码位置**'
for m in 13000 9000 7000 6000 4000 300; do
  e=$(python3 "$P" body "$TMP/nest.html" --max $m 2>&1 >/dev/null); rc=$?
  st_hasnt "--max $m: no traceback" "$e" 'Traceback'
  st_eq "--max $m: 0 or over" yes "$([ $rc -le 1 ] && echo yes)"
done
full=$(python3 "$P" body "$TMP/nest.html" --max 99999 | python3 -c 'import json,sys; print(len(json.dumps(sys.stdin.read(), ensure_ascii=False).encode()))')
B=$(python3 "$P" body "$TMP/nest.html" --max $((full - 1)))
st_has "代码位置 moved first" "$B" '（代码位置：见设计页）'
st_has "…while the evidence stays" "$B" '实测：16/16 通过'
st_hasnt "…its inner layer with it" "$B" '第三层原文'
e=$(python3 "$P" body "$TMP/nest.html" --max 300 2>&1 >/dev/null)
st_has "over the cap names --split" "$e" 'body <page> --split <dir> (3 cards)'
out=$(python3 "$P" body "$TMP/nest.html" --link https://p/s/n --split "$TMP/parts"); rc=$?
st_eq "split → 0" 0 "$rc"
st_eq "one part per card" 3 "$(printf '%s\n' "$out" | grep -c .)"
st_has "a part line: path, bytes, card" "$out" "$TMP/parts/02-B.md	"
for k in A B C; do
  f=$(ls "$TMP/parts/"*-$k.md 2>/dev/null)
  st_eq "part $k written" yes "$([ -s "$f" ] && echo yes)"
  W=$(cat "$f")
  st_has "part $k: the link" "$W" '> 设计页：https://p/s/n（私密；本文是它按成员卡拆开的第'
  st_has "part $k: the shared problem" "$W" '## 问题与原因'
  st_has "part $k: the shared acceptance" "$W" '演练会话 A 开 B、B 开 C'
  st_has "part $k: says where the others are" "$W" '张各是一份任务——见设计页）'
  st_eq "part $k: only its own card" 1 "$(grep -c '^### .* — ' "$f")"
done
st_has "part A is card A" "$(cat "$TMP/parts/01-A.md")" '### 回报先按身份找人'
st_hasnt "part B is not card A" "$(cat "$TMP/parts/02-B.md")" '### 回报先按身份找人'
python3 - "$TMP/nest.json" "$TMP/one.json" <<'PYO'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8")); d["members"] = d["members"][:1]
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
PYO
python3 "$P" render "$TMP/one.json" -o "$TMP/one.html"
python3 "$P" body "$TMP/one.html" --split "$TMP/oneparts" >/dev/null 2>&1; st_eq "one card: nothing to split → 1" 1 $?
st_eq "one card: nothing written" no "$([ -e "$TMP/oneparts" ] && echo yes || echo no)"
w=$(bash "$L" --lint "$TMP/nest.html" 2>&1 >/dev/null)
st_hasnt "lint: a first-layer 代码位置 fold stays folded" "$w" 'nest-first.sh'
st_hasnt "lint: nested folds are not empty" "$w" 'empty-fold'
st_hasnt "surface: no 代码位置 upstairs" "$(bash "$L" "$TMP/nest.html" 2>/dev/null)" '代码位置'

st_done
