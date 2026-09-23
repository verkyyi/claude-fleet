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
#   4. the shared template's surface still reads through it (the frame and the
#      tool agree on the fold classes), and the skill + plan command point at it.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$BIN/.."
S="$BIN/epic-page-surface.sh"
T="$ROOT/skills/epic-page/template.html"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eps.XXXXXX") || fail "mktemp"
trap 'rm -rf "$TMP"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "epic-page-surface-selftest SKIP (no python3)"; exit 0; }

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
<details class="fold"><summary>怎么量</summary><p>FOLDED-METRIC 读 fleet.conf 的 FLEET_REPO，命令 \`gh api\`</p></details>
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
CHECKS=$((CHECKS + 1)); [ "$rc" -eq 0 ] || fail "surface of the good page exited $rc"
for want in '# 一个 hub 管几个仓库' '一个窗口看所有仓库；两个仓库的试跑通过就停。' \
  '| 已知的「做到别的仓库去」的情况 | 9 种 | 0 种 |' '## 要做的事' \
  '▸ 一个窗口装得下几个仓库 — 今天一个窗口只认一个仓库。' \
  '| 新开的会话放进哪个仓库 | 放进你正在看的仓库 |'; do
  CHECKS=$((CHECKS + 1))
  printf '%s\n' "$OUT" | grep -q -F -- "$want" || fail "surface is missing: $want"
done
for gone in FOLDED-METRIC FOLDED-CHARTER FOLDED-ORDER CARD-BODY 'background:#fff' 'a comment' '<'; do
  CHECKS=$((CHECKS + 1))
  printf '%s\n' "$OUT" | grep -q -F -- "$gone" && fail "surface leaks hidden content: $gone"
done
# stdin input reads the same page
CHECKS=$((CHECKS + 1))
[ "$("$S" - <"$GOOD")" = "$OUT" ] || fail "reading from stdin differs from reading the file"

# 2. the good page lints clean
CHECKS=$((CHECKS + 1))
ERR=$("$S" --lint "$GOOD" 2>&1 >/dev/null </dev/null); rc=$?
[ "$rc" -eq 0 ] || fail "good page should lint clean, got rc=$rc: $ERR"

# 3. each #929 mistake fires its rule
lint_fires() {  # <rule> <needle> <为谁> <metric-row> <card> <signoff-row> [extra]
  local rule=$1 needle=$2 f="$TMP/bad-$CHECKS.html" err rc; shift 2
  page "$f" "$1" "$2" "$3" "$4" "${5:-}"
  CHECKS=$((CHECKS + 1))
  err=$("$S" --lint "$f" 2>&1 >/dev/null </dev/null); rc=$?
  [ "$rc" -eq 1 ] || fail "lint should exit 1 for rule $rule ($needle), got $rc"
  printf '%s\n' "$err" | grep "^WARN $rule:" | grep -q -F -- "$needle" \
    || fail "lint did not fire $rule on [$needle]; got: $err"
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

# 4. the frame reads through the tool; the docs point at it
TS=$("$S" "$T" </dev/null) || fail "surface of template.html failed"
for want in '## 指标' '## 要做的事' '## 需要你定的事' '▸ ⟨名称⟩ — ⟨一句：解决什么⟩'; do
  CHECKS=$((CHECKS + 1))
  printf '%s\n' "$TS" | grep -q -F -- "$want" || fail "template surface is missing: $want"
done
for gone in '技术细节' '共同约定' '预检原文' '⟨R1 · 已有 #N⟩'; do
  CHECKS=$((CHECKS + 1))
  printf '%s\n' "$TS" | grep -q -F -- "$gone" && fail "template surface leaks fold content: $gone"
done
for f in "$ROOT/skills/epic-page/SKILL.md" "$ROOT/commands/fleet-epic-plan.md"; do
  CHECKS=$((CHECKS + 1))
  grep -q -F 'epic-page-surface.sh' "$f" || fail "${f#"$ROOT"/} does not point at epic-page-surface.sh"
done

printf 'epic-page-surface-selftest OK (%d checks)\n' "$CHECKS"
