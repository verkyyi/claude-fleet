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
for id in $(python3 "$P" ids); do st_has "id $id" "$PAGE" "<section id=\"$id\">"; done
st_eq "eight ids" 8 "$(python3 "$P" ids | wc -l | tr -d ' ')"
st_has "open anchor" "$PAGE" '<span id="open"></span>'
st_has "eyebrow" "$PAGE" '<p class="eyebrow">任务设计 · verkyyi/claude-fleet'
st_has "a card per member" "$PAGE" '<div class="ob" id="m-C">'
st_has "evidence folded" "$PAGE" '<summary>证据（代码与现场）</summary>'
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
b["cause"] = {k: v for k, v in d["cause"].items() if k != "evidence"}
json.dump(b, open(sys.argv[3], "w"), ensure_ascii=False)
PY
FEAT=$(python3 "$P" render "$TMP/feat.json")
st_has "feature cause" "$FEAT" '<section id="cause">
<h2>为什么要做</h2>'
st_has "feature problem" "$FEAT" '<h2>现在的样子</h2>'
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
st_has "cause steps" "$B" '| 一步 | 发生了什么 |'
st_has "evidence written out" "$B" 'bin/fleet-report-parent.sh:300-305'
st_has "card name — line" "$B" '### 回报先按身份找人 — 退役判断放到身份路由之后'
st_has "tech written out" "$B" '**完成判据** `origin-selftest.sh` D'
st_has "上线证据 kept" "$B" '让一个演练会话 A 开 B'
st_has "nod" "$B" '操作者 2026-10-20：全部按「需要你定的事」的建议执行'
st_hasnt "no eyebrow" "$B" '任务设计 ·'
st_hasnt "no footer" "$B" '本页私密'
st_hasnt "no style" "$B" '--ground'
size() { python3 -c 'import json,sys; print(len(json.dumps(sys.stdin.read(), ensure_ascii=False).encode()))'; }
n=$(printf '%s\n' "$B" | size)
st_eq "under the default cap ($n)" yes "$([ "$n" -le 13000 ] && echo yes)"
B=$(python3 "$P" body "$TMP/page.html" --max 6500)
n=$(printf '%s\n' "$B" | size)
st_eq "under --max 6500 ($n)" yes "$([ "$n" -le 6500 ] && echo yes)"
st_has "evidence moved first" "$B" '（证据（代码与现场）：见设计页）'
st_has "tech kept at 6500" "$B" '**完成判据**'
B=$(python3 "$P" body "$TMP/page.html" --max 5500 --link L)
n=$(printf '%s\n' "$B" | size)
st_eq "under --max 5500 ($n)" yes "$([ "$n" -le 5500 ] && echo yes)"
st_has "tech moved next" "$B" '（技术细节：见设计页）'
st_has "上线证据 never moved" "$B" '让一个演练会话 A 开 B'
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

st_done
