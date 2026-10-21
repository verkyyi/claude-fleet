#!/bin/bash
# epic-page-surface-selftest.sh — bin/epic-page-surface.sh shows exactly what the
# decider sees of an EPIC page, and its --lint names the surface mistakes of
# issue #929. Hermetic: python3 only, no network.
#
#   1. the surface keeps title / subtitle / band / section text / table rows /
#      each card's ONE summary line — and drops <head>, comments, every
#      details.fold, and everything in a details.card past its summary.
#   2. a page written to the rules lints clean (exit 0).
#   3. a page carrying each of #929's six mistakes fires the matching rule
#      (key / jargon / file / metric / for-whom / decision) and exits 1.
#   3b. a visual member card (侧栏 / 状态栏 / 菜单 / 页面 …) with no upper-layer
#      改前 / 改后 block (div.cmp, fleet-task-page.py compare) — or any card linking a
#      separate prototype page — fires `compare`; one with the block, or a non-visual
#      card, does not (issue #1754).
#   3c. T764: the shared 证据 / 怎么量 folds (fold-row), a fold that opens on nothing
#      (empty-fold), a title over 16 / a subtitle over 30 or bracketed (brevity), an
#      acceptance item with no 通过标准 (accept); a div.xt row is a metric row too.
#   4. the shared template's surface still reads through it (the frame and the
#      tool agree on the fold classes), and the skill + plan command point at it.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROOT="$BIN/.."
S="$BIN/epic-page-surface.sh"
T="$ROOT/plugins/fleet-epic/skills/epic-page/template.html"
CHECKS=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eps.XXXXXX") || st_fail "mktemp"
trap 'rm -rf "$TMP"' EXIT

st_need python3

page() {  # <file> <为谁> <metric-row> <card-summary> <signoff-row> <extra-surface-line>
  cat >"$1" <<EOF
<!doctype html><html lang="zh"><head><title>T</title><style>body{background:#fff}</style></head><body>
<!-- a comment the decider never sees: 渲染 CSP C9 #999 -->
<p class="eyebrow">EPIC #787 · o/r · 2026-09-22</p>
<h1>一个 hub 管几个仓库</h1>
<p class="sub">一个窗口看所有仓库；两个仓库的试跑通过就停。</p>
<section id="metrics"><h2>指标</h2><table>
<thead><tr><th>指标</th><th>现在</th><th>目标</th></tr></thead>
<tbody>$3</tbody></table>
<div class="xt c3"><div class="xh"><span>指标</span><span>现在</span><span>目标</span><i></i></div>
<details class="xr"><summary><span class="c">切仓库的次数</span><span class="num">5 次</span><span class="num">0 次</span><i></i></summary>
<div class="xd"><p>FOLDED-METRIC 读 fleet.conf 的 FLEET_REPO，命令 \`gh api\`</p></div></details>
<div class="xr"><span class="c">要等的人</span><span class="num">2 个</span><span class="num">0 个</span><i></i></div></div>
</section>
<section id="charter"><h2>范围</h2><h3>做</h3><ul><li>一个窗口看所有仓库</li></ul>$6
<details class="fold"><summary>共同约定</summary><ol><li>FOLDED-CHARTER 不改 conf 格式</li></ol></details></section>
<section id="members"><h2>要做的事</h2><h3 class="grp">打地基</h3>
<div class="ob" id="m-C1"><details class="card">
<summary><span class="ct"><strong>$4</strong><span class="cg">今天一个窗口只认一个仓库。</span></span></summary>
<dl class="kv"><dt>目标</dt><dd>CARD-BODY 能装几个仓库</dd><dt>为谁</dt><dd>$2</dd></dl>
<details class="fold"><summary>技术细节</summary><dl class="kv"><dt>编号 / 来源</dt><dd>C1 · 已有 #12</dd></dl></details>
</details></div></section>
<section id="signoff"><span id="open"></span><h2>需要你定的事</h2><table>
<thead><tr><th>事项</th><th>建议</th></tr></thead><tbody>$5</tbody></table></section>
<section id="order"><details class="fold"><summary>执行安排</summary><table><tbody><tr><td>FOLDED-ORDER C1</td></tr></tbody></table></details></section>
</body></html>
EOF
}

GOOD="$TMP/good.html"
page "$GOOD" '你，一个人管 3 个仓库，多数时候用 iPad' \
  '<tr><td>已知的「做到别的仓库去」的情况</td><td>9 种</td><td>0 种</td></tr><tr><td>要看的窗口</td><td>3 个</td><td>1 个</td></tr>' \
  '一个窗口装得下几个仓库' \
  '<tr><td>新开的会话放进哪个仓库</td><td>放进你正在看的仓库</td></tr>' ''

# 1. surface shape
OUT=$("$S" "$GOOD" </dev/null); rc=$?
CHECKS=$((CHECKS + 1)); [ "$rc" -eq 0 ] || st_fail "surface of the good page exited $rc"
for want in '# 一个 hub 管几个仓库' '一个窗口看所有仓库；两个仓库的试跑通过就停。' \
  '| 已知的「做到别的仓库去」的情况 | 9 种 | 0 种 |' '## 要做的事' \
  '| 切仓库的次数 | 5 次 | 0 次 |' '| 要等的人 | 2 个 | 0 个 |' \
  '▸ 一个窗口装得下几个仓库 — 今天一个窗口只认一个仓库。' \
  '| 新开的会话放进哪个仓库 | 放进你正在看的仓库 |'; do
  CHECKS=$((CHECKS + 1))
  printf '%s\n' "$OUT" | grep -q -F -- "$want" || st_fail "surface is missing: $want"
done
for gone in FOLDED-METRIC FOLDED-CHARTER FOLDED-ORDER CARD-BODY 'background:#fff' 'a comment' '<'; do
  CHECKS=$((CHECKS + 1))
  printf '%s\n' "$OUT" | grep -q -F -- "$gone" && st_fail "surface leaks hidden content: $gone"
done
# stdin input reads the same page
CHECKS=$((CHECKS + 1))
[ "$("$S" - <"$GOOD")" = "$OUT" ] || st_fail "reading from stdin differs from reading the file"

# 2. the good page lints clean
CHECKS=$((CHECKS + 1))
ERR=$("$S" --lint "$GOOD" 2>&1 >/dev/null </dev/null); rc=$?
[ "$rc" -eq 0 ] || st_fail "good page should lint clean, got rc=$rc: $ERR"

# 3. each #929 mistake fires its rule
lint_fires() {  # <rule> <needle> <为谁> <metric-row> <card> <signoff-row> [extra]
  local rule=$1 needle=$2 f="$TMP/bad-$CHECKS.html" err rc; shift 2
  page "$f" "$1" "$2" "$3" "$4" "${5:-}"
  CHECKS=$((CHECKS + 1))
  err=$("$S" --lint "$f" 2>&1 >/dev/null </dev/null); rc=$?
  [ "$rc" -eq 1 ] || st_fail "lint should exit 1 for rule $rule ($needle), got $rc"
  printf '%s\n' "$err" | grep "^WARN $rule:" | grep -q -F -- "$needle" \
    || st_fail "lint did not fire $rule on [$needle]; got: $err"
}
OKW='你，一个人管 3 个仓库'
OKM='<tr><td>要看的窗口</td><td>3 个</td><td>1 个</td></tr>'
OKC='一个窗口装得下几个仓库'
OKD='<tr><td>新开的会话放哪</td><td>你正在看的仓库</td></tr>'
lint_fires metric   '目标没有数'   "$OKW" '<tr><td>示例页</td><td>0</td><td>首跑定</td></tr>' "$OKC" "$OKD"
lint_fires metric   '无意义'       "$OKW" '<tr><td>用了新写法的页面</td><td>0</td><td>&gt; 0</td></tr>' "$OKC" "$OKD"
lint_fires metric   '单位不一致'   "$OKW" '<tr><td>要改的地方</td><td>3 处</td><td>1 行</td></tr>' "$OKC" "$OKD"
lint_fires jargon   '渲染'         "$OKW" "$OKM" '换一种渲染方式' "$OKD"
lint_fires jargon   'SDK'          "$OKW" "$OKM" '页面里的 SDK 本地也能用' "$OKD"
lint_fires jargon   '404'          "$OKW" "$OKM" '偶发 404 不再出现' "$OKD"
lint_fires key      'C3'           "$OKW" "$OKM" 'C3 一个窗口装得下几个仓库' "$OKD"
lint_fires key      '#881'         "$OKW" "$OKM" '按 #881 的规则' "$OKD"
lint_fires file     'fleet.conf'   "$OKW" "$OKM" '改 fleet.conf 就能装几个仓库' "$OKD"
lint_fires for-whom '所有 Agent'   '所有 Agent' "$OKM" "$OKC" "$OKD"
lint_fires for-whom '维护团队'     '维护团队' "$OKM" "$OKC" "$OKD"
lint_fires decision '代码或路径'   "$OKW" "$OKM" "$OKC" '<tr><td>数据放哪</td><td><code>./_data/表名.json</code></td></tr>'
lint_fires decision '不做'         "$OKW" "$OKM" "$OKC" '<tr><td>不做：视频预览</td><td>这批不碰</td></tr>'

# 3c. T764: the old shared folds, a fold with nothing in it, a long title / subtitle, an
#     acceptance item with no 通过标准 — and a metric row of a div.xt is still a metric row
t764() {  # <rule> <needle> <file>
  CHECKS=$((CHECKS + 1))
  local err; err=$("$S" --lint "$3" 2>&1 >/dev/null </dev/null)
  printf '%s\n' "$err" | grep "^WARN $1:" | grep -q -F -- "$2" || st_fail "lint did not fire $1 on [$2]; got: $err"
}
sed 's#<div class="xt c3">#<details class="fold"><summary>怎么量</summary><p>口径</p></details>&#' "$GOOD" >"$TMP/old-how.html"
t764 fold-row '量法没挂到行' "$TMP/old-how.html"
sed 's#</section>#<details class="fold"><summary>技术细节</summary>  </details>&#' "$GOOD" >"$TMP/empty.html"
t764 empty-fold '技术细节' "$TMP/empty.html"
sed 's#<h1>一个 hub 管几个仓库</h1>#<h1>一个 hub 管几个仓库，再也不用来回切换窗口了</h1>#' "$GOOD" >"$TMP/long.html"
t764 brevity '标题 24 字' "$TMP/long.html"
sed 's#<p class="sub">[^<]*</p>#<p class="sub">一个窗口看所有仓库（两个仓库试跑通过就停）</p>#' "$GOOD" >"$TMP/sub.html"
t764 brevity '副标题' "$TMP/sub.html"
sed 's#</body>#<section id="evidence"><div class="ev"><div class="eh"><strong>窗口截图</strong></div><dl class="kv"><dt>在哪取</dt><dd>手机</dd></dl></div></section>&#' "$GOOD" >"$TMP/acc.html"
t764 accept '验收项缺通过标准' "$TMP/acc.html"
sed 's#<span class="num">0 次</span>#<span class="num">首跑定</span>#' "$GOOD" >"$TMP/xmetric.html"
t764 metric '目标没有数' "$TMP/xmetric.html"

# 3b. a visual member with no 改前 / 改后 block, or any card linking a prototype page, fires `compare` (#1754, T699)
vpage() {  # <file> <card-name> <upper-extra> <fold-extra>
  cat >"$1" <<EOF
<!doctype html><html lang="zh"><body><h1>客户端新建与位置</h1>
<section id="members"><h2>要做的事</h2>
<div class="ob" id="m-C1"><details class="card">
<summary><span class="ct"><strong>$2</strong><span class="cg">今天看不出会话在哪台电脑上。</span></span></summary>
$3<dl class="kv"><dt>为谁</dt><dd>你，一个人用 3 台电脑</dd></dl>
<details class="fold"><summary>技术细节</summary>$4<dl class="kv"><dt>编号 / 来源</dt><dd>C1 · 新建</dd></dl></details>
</details></div></section></body></html>
EOF
}
CMPB=$(printf '%s' '{"before":{"html":"<pre>旧侧栏</pre>","note":"看不出电脑"},"after":{"html":"<pre>新侧栏 · mac-a</pre>","note":"每行带电脑名"}}' \
  | python3 "$BIN/fleet-task-page.py" compare -) || st_fail "fleet-task-page.py compare"
PROTO='<p class="proto"><a href="proto-sidebar.html">▶ 打开可交互原型</a></p>'
vlint() {  # <want-rc> <what> <card-name> <upper-extra> <fold-extra> [want-text]
  local want=$1 what=$2 f="$TMP/vis-$CHECKS.html" err rc; shift 2
  vpage "$f" "$1" "$2" "$3"
  CHECKS=$((CHECKS + 1))
  err=$("$S" --lint "$f" 2>&1 >/dev/null </dev/null); rc=$?
  [ "$rc" -eq "$want" ] || st_fail "compare: $what — want rc=$want, got $rc: $err"
  if [ "$want" -eq 1 ]; then
    printf '%s\n' "$err" | grep '^WARN compare:' | grep -F -- "${4:-}" | grep -q -F -- "$1" \
      || st_fail "compare: $what — no WARN naming the card; got: $err"
  fi
}
vlint 1 'visual card, no block'         '侧栏每行标出所在电脑' '' '' '没有「改前 / 改后」'
vlint 1 'visual word only in the fold'  '每行标出所在电脑' '' '<p>改侧栏的行</p>' '没有「改前 / 改后」'
vlint 1 'block only inside the fold'    '侧栏每行标出所在电脑' '' "$CMPB" '没有「改前 / 改后」'
vlint 1 'a prototype page, no block'    '侧栏每行标出所在电脑' "$PROTO" '' '单独的原型页'
vlint 1 'block AND a prototype page'    '侧栏每行标出所在电脑' "$CMPB$PROTO" '' '单独的原型页'
vlint 1 'a 原型 link, not visual'        '新会话启动更快' '<p><a href="https://h/p.html">看原型</a></p>' '' '单独的原型页'
vlint 0 'upper-layer 改前 / 改后 block'   '侧栏每行标出所在电脑' "$CMPB" ''
vlint 0 'an in-page anchor is no page'  '顶栏只管会话' "$CMPB"'<p class="proto"><a href="#m-C1">▶ 看对比</a></p>' ''
vlint 0 'upper link that is no prototype' '新会话启动更快' '<p><a href="https://h/x">相关单</a></p>' ''
vlint 0 'not a visual member'           '新会话启动更快' '' ''

# 4. the frame reads through the tool; the docs point at it
TS=$("$S" "$T" </dev/null) || st_fail "surface of template.html failed"
for want in '## 目标' '## 解决方案' '## 需要你定的事' '▸ ⟨名称⟩ — ⟨一句：解决什么⟩'; do
  CHECKS=$((CHECKS + 1))
  printf '%s\n' "$TS" | grep -q -F -- "$want" || st_fail "template surface is missing: $want"
done
for gone in '技术细节' '共同约定' '预检原文' '⟨R1 · 已有 #N⟩'; do
  CHECKS=$((CHECKS + 1))
  printf '%s\n' "$TS" | grep -q -F -- "$gone" && st_fail "template surface leaks fold content: $gone"
done
for f in "$ROOT/plugins/fleet-epic/skills/epic-page/SKILL.md" "$ROOT/plugins/fleet-epic/commands/fleet-epic-plan.md"; do
  CHECKS=$((CHECKS + 1))
  grep -q -F 'epic-page-surface.sh' "$f" || st_fail "${f#"$ROOT"/} does not point at epic-page-surface.sh"
done
for f in "$ROOT/plugins/fleet-epic/skills/epic-page/SKILL.md" "$ROOT/plugins/fleet-epic/commands/fleet-epic-plan.md" "$T"; do
  CHECKS=$((CHECKS + 1))
  grep -q -F '改前 / 改后' "$f" || st_fail "${f#"$ROOT"/} does not carry the 改前 / 改后 rule (issue #1754, T699)"
  grep -q -F '▶ 打开可交互原型' "$f" && st_fail "${f#"$ROOT"/} still asks for a separate prototype page (T699)"
done

printf 'epic-page-surface-selftest OK (%d checks)\n' "$CHECKS"
