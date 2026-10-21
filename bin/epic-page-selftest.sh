#!/bin/bash
# epic-page-selftest.sh — the shared EPIC page frame (skills/epic-page, issue #809)
# and the two commands that render into it stay in lockstep. Hermetic: no node,
# no tailscale, no network.
#
#   1. template.html carries every section id the plan command names — the ids
#      are the contract the command text refers to, so dropping one silently
#      strands an instruction.
#   2. the member card carries the six fields, 上线证据 included — that line is
#      the seam with /fleet-epic-report (#810).
#   3. the frame honours the artifact-design contract a page served as-is needs:
#      a <title>, tokens on :root, the dark-mode guard, a body background.
#   4. BOTH commands point at the frame (plan renders it, report reuses it), and
#      plan re-renders a revision in the same file it opened (no second copy).
#   5. the skill registers: SKILL.md frontmatter name matches the dir and the
#      copy-install marker is present (fleet-plugin-selftest checks the tree
#      generically; this pins THIS skill's supporting file).
#   6. the decider's view (issue #881): both reading orders fall out of the
#      FILE order, the band speaks plain words, a member card folds to one line
#      with no key on it, the metric table is 指标/现在/目标, 需要你定的事 is one
#      事项/建议 table, and the order section is folded whole — while the
#      write-back shapes /fleet-epic-run parses stay exactly as they were.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROOT="$BIN/.."
T="$ROOT/plugins/fleet-epic/skills/epic-page/template.html"
SK="$ROOT/plugins/fleet-epic/skills/epic-page/SKILL.md"
PLAN="$ROOT/plugins/fleet-epic/commands/fleet-epic-plan.md"
REPORT="$ROOT/plugins/fleet-epic/commands/fleet-epic-report.md"
CHECKS=0
has() { CHECKS=$((CHECKS + 1)); grep -q -- "$2" "$1" || st_fail "$3 — [$2] not in ${1#"$ROOT"/}"; }
hasF() { CHECKS=$((CHECKS + 1)); grep -q -F -- "$2" "$1" || st_fail "$3 — [$2] not in ${1#"$ROOT"/}"; }

[ -f "$T" ] || st_fail "plugins/fleet-epic/skills/epic-page/template.html is missing"
[ -f "$SK" ] || st_fail "plugins/fleet-epic/skills/epic-page/SKILL.md is missing"

# 1. section ids — one per plan section, in the order the command lists them
for id in metrics charter members risks signoff preflight order; do
  hasF "$T" "<section id=\"$id\">" "template: section #$id"
  hasF "$PLAN" "\`#$id\`" "plan names section #$id"
done
# 待决 merged into 需要你定的事 (#881): #open survives as an anchor inside #signoff
hasF "$T" '<span id="open"></span>' "template: #open is an anchor inside #signoff"
hasF "$PLAN" '`#open`' "plan names the #open anchor"
hasF "$T" 'id="m-C1"' "template: a member card carries id=m-<key>"

# 2. the six member fields, 上线证据 as a single evidence line
for f in 目标 方案 '接口 / 约定' 依赖 完成判据 上线证据; do
  hasF "$T" "<dt>$f</dt>" "template: member field $f"
done
hasF "$T" 'class="evidence"' "template: 上线证据 is styled as the one-line evidence slot"
hasF "$PLAN" '上线证据' "plan: the member section defines the 上线证据 line"
hasF "$REPORT" '上线证据' "report: reads the member's 上线证据 line (the #810 seam)"
# 2b. the report-only evidence block lives IN the frame (issue #810), not in a second stylesheet
hasF "$T" 'class="proof"' "template: member card carries the report-only .proof grid"
for st in 改动前 改动后 已上线; do
  hasF "$T" "<div class=\"stage\">$st</div>" "template: .proof column $st"
done
hasF "$T" 'class="none"' "template: a stage nobody captured is a .none cell"
hasF "$REPORT" '.proof' "report: fills the frame's .proof grid, no page-local styling"
hasF "$REPORT" '无证据' "report: a missing stage is written 无证据"
hasF "$REPORT" "members' PRs" "report: collects evidence from the members' PRs (the evidence store left with #4898)"

# 3. artifact-design contract for a page served byte-for-byte
hasF "$T" '<title>' "template: has a <title> (the tab is titled from it)"
hasF "$T" ':root{' "template: colour tokens live on :root"
hasF "$T" ':root:not([data-theme="light"])' "template: dark mode is guarded by the light override"
hasF "$T" ':root[data-theme="dark"]' "template: explicit dark theme selector"
has  "$T" 'body{background:' "template: body has an explicit background"
hasF "$T" 'name="viewport"' "template: phone-width viewport"

# 4. both commands render into the frame; revisions refresh, never re-share
hasF "$PLAN"   'plugins/fleet-epic/skills/epic-page/template.html' "plan renders from the shared frame"
hasF "$REPORT" 'plugins/fleet-epic/skills/epic-page/template.html' "report reuses the shared frame"
hasF "$PLAN"   'edit the same file' "plan re-renders a revision in place"
hasF "$PLAN"   'http.server --bind 127.0.0.1' "plan: with no 活页 tools, the page is served on loopback"
# issue #4957: the pages go to 活页, private, pushed to the operator's WeChat
for f in "$PLAN" "$REPORT" "$SK"; do
  hasF "$f" 'mcp__space__publish_file' "${f##*/}: publishes the page to 活页"
  hasF "$f" 'mcp__space__push_to_wechat' "${f##*/}: pushes it to the operator's WeChat"
  # T765: an automatic push already on (page + include_me) is not doubled by hand
  hasF "$f" 'mcp__space__set_publish_notify' "${f##*/}: asks the push state before pushing by hand"
done
hasF "$PLAN"   'starts **private**' "plan: the page starts private"
hasF "$REPORT" 'starts **private**' "report: the page starts private"
hasF "$PLAN"   'again to the same page' "plan: a revision keeps the same link"

# 5. the skill registers, on both install paths
CHECKS=$((CHECKS + 1)); head -1 "$SK" | grep -q '^---$' || st_fail "SKILL.md has no frontmatter"
hasF "$SK" 'name: epic-page' "SKILL.md name matches its directory"
hasF "$SK" '<!-- fleet skill -->' "SKILL.md carries the copy-install marker"

# 6. the decider's view (issue #881)
# 6a. reading order = file order, for both pages
order() {  # <label> <id>... — each section starts after the previous one
  local label=$1 prev=-1 id at; shift
  for id in "$@"; do
    CHECKS=$((CHECKS + 1))
    at=$(grep -n -F "<section id=\"$id\">" "$T" | head -1 | cut -d: -f1)
    [ -n "$at" ] && [ "$at" -gt "$prev" ] || st_fail "template: $label order breaks at #$id"
    prev=$at
  done
}
order plan metrics charter members risks signoff preflight order
order report delivered metrics members gaps ops
# 6h. the report tail (issue #929): #gaps + #next are one two-column table, #next an
#     anchor inside it, no obstacles section, no lede / trailing note in it
hasF "$T" '<span id="next"></span>' "template: #next is an anchor inside #gaps"
hasF "$T" '<thead><tr><th>还差什么</th><th>建议下一步</th></tr></thead>' "template: #gaps is one 还差什么/建议下一步 table"
# (no <section id="next|obstacles">, no 不算欠 / 建议，不是决定: conf/gone.list #929)
CHECKS=$((CHECKS + 1))
awk '/<section id="next">|<span id="next">/{f=1} f&&/<\/section>/{exit} f' "$T" | grep -q 'class="lede"' \
  && st_fail "template: 还差什么 · 下一步 has a lede"
hasF "$REPORT" '还差什么 | 建议下一步' "report: step 2 describes the merged table"
hasF "$SK" '<span id="next">' "SKILL.md sections table: #next is an anchor"
# 6i. #preflight renders only with something to handle (issue #929); the screen then
#     lives in the #order fold, so write-back loses nothing
hasF "$PLAN" 'only when there is something to handle' "plan: #preflight is conditional"
hasF "$SK" 'only when there is something to handle' "SKILL.md: #preflight is conditional"
hasF "$T" 'ONLY WHEN THERE IS' "template: the preflight comment says when to drop it"
CHECKS=$((CHECKS + 1))
awk '/<section id="order">/{f=1} f' "$T" | grep -q -F '<h3>预检原文</h3>' \
  || st_fail "template: the #order fold has no home for 预检原文"
# 6b. the band in plain words; the old jargon labels are gone from it
for k in 要做的事 有空再做 要看的指标 开跑前要处理; do
  hasF "$T" "<div class=\"k\">$k</div>" "template: band label $k"
done
# (the old labels 核心层 储备层 新建子单 预检警告 are conf/gone.list's)
# 6c. whole-card fold, one line, no key on the surface; print still opens it
hasF "$T" '<details class="card">' "template: a member card folds whole"
hasF "$T" 'details.card>summary' "template: the card fold is styled in the shared <style>"
hasF "$T" 'details.card:not([open])>*' "template: print force-opens the card fold too"
hasF "$T" '<h3 class="grp">有空再做</h3>' "template: the reserve is the last group of the same list"
CHECKS=$((CHECKS + 1))
if grep -F '<summary><span class="ct">' "$T" | grep -qE '[CR][0-9]'; then
  st_fail "template: a card summary shows a member key"
fi
CHECKS=$((CHECKS + 1))
grep -E '^<h[23]' "$T" | grep -qE '(^|[^A-Za-z])[CR][0-9]' && st_fail "template: a heading shows a member key"
hasF "$T" '<dt>编号 / 来源</dt>' "template: the key lives in 技术细节"
# 6d. metric rows: numbers on the surface, each row opens on ITS 口径 (T764), 范围 under them
hasF "$T" '<div class="xh"><span>指标</span><span>现在</span><span>目标</span><i></i></div>' "template: metric header 指标/现在/目标"
hasF "$T" '<dt>读数口径</dt>' "template: 读数口径 sits in the row's own detail"
hasF "$T" '<div class="xr"><span class="c">' "template: a row with nothing to open is a plain row"
hasF "$T" '<h2>目标</h2>' "template: 指标 + 范围 are one section 目标"
hasF "$T" '<h2>解决方案</h2>' "template: the member list is 解决方案"
# 6e. decisions in one table, preflight folded, order folded whole
hasF "$T" '<thead><tr><th>事项</th><th>建议</th></tr></thead>' "template: 需要你定的事 is one 事项/建议 table"
hasF "$T" '（批后）' "template: shows the 「（批后）」 mark"
hasF "$T" '<summary>预检原文</summary>' "template: the preflight screen is folded"
CHECKS=$((CHECKS + 1))
grep -A1 -F '<section id="order">' "$T" | grep -q -F '<details class="fold">' \
  || st_fail "template: #order is not folded whole"
# 6f. the plan command carries the rules, and write-back is unchanged
hasF "$PLAN" '#881' "plan: step 4 cites the decider's-view issue"
hasF "$PLAN" '点头即全部按建议' "plan: the nod accepts every default"
hasF "$PLAN" 'never the record' "plan: folds do not change the write-back"
hasF "$PLAN" '- [ ] **C1** <名称>' "plan: the member line fleet-epic-tick.py parses"
hasF "$PLAN" '<!-- fleet:epic repo=<owner/name> short=<简称> cap=4 -->' "plan: the charter marker the tick reads"
hasF "$PLAN" '## C1 · <名称>' "plan: each member's charter section, both layers"
hasF "$PLAN" '上线证据：<the one line, verbatim from the page>' "plan: 上线证据 stays one labelled line"
hasF "$PLAN" '（批后）' "plan: 「（批后）」 rows also go to the parent's 待决"
hasF "$REPORT" '#881' "report: follows the decider's view"
# 6g. the concurrency caps are the operator's (issue #881 point 16): plan and run
#     state them at most — never advise a value, never ask, never change one
RUN="$ROOT/plugins/fleet-epic/commands/fleet-epic-run.md"
hasF "$PLAN" 'The concurrency caps are not this skill' "plan: leaves the session caps alone"
hasF "$RUN" "never changed or questioned" "run: refills within the caps, never changes them"
for f in "$PLAN" "$RUN" "$T"; do
  CHECKS=$((CHECKS + 1))
  grep -qE 'FLEET_(GLOBAL_)?MAX_SESSIONS=[0-9]' "$f" && st_fail "${f#"$ROOT"/} suggests a session-cap value"
done

printf 'epic-page-selftest OK (%d checks)\n' "$CHECKS"
