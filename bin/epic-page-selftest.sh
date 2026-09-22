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
#   3. the frame honours the artifact-design contract doc-preview serves as-is:
#      a <title>, tokens on :root, the dark-mode guard, a body background.
#   4. BOTH commands point at the frame (plan renders it, report reuses it), and
#      plan re-renders a revision with --refresh instead of re-sharing.
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
ROOT="$BIN/.."
T="$ROOT/skills/epic-page/template.html"
SK="$ROOT/skills/epic-page/SKILL.md"
PLAN="$ROOT/commands/fleet-epic-plan.md"
REPORT="$ROOT/commands/fleet-epic-report.md"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
has() { CHECKS=$((CHECKS + 1)); grep -q -- "$2" "$1" || fail "$3 — [$2] not in ${1#"$ROOT"/}"; }
hasF() { CHECKS=$((CHECKS + 1)); grep -q -F -- "$2" "$1" || fail "$3 — [$2] not in ${1#"$ROOT"/}"; }

[ -f "$T" ] || fail "skills/epic-page/template.html is missing"
[ -f "$SK" ] || fail "skills/epic-page/SKILL.md is missing"

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
hasF "$REPORT" 'fleet-evidence.sh' "report: collects evidence through bin/fleet-evidence.sh"

# 3. artifact-design contract for a page doc-preview serves byte-for-byte
hasF "$T" '<title>' "template: has a <title> (doc-preview titles the entry from it)"
hasF "$T" ':root{' "template: colour tokens live on :root"
hasF "$T" ':root:not([data-theme="light"])' "template: dark mode is guarded by the light override"
hasF "$T" ':root[data-theme="dark"]' "template: explicit dark theme selector"
has  "$T" 'body{background:' "template: body has an explicit background"
hasF "$T" 'name="viewport"' "template: phone-width viewport"

# 4. both commands render into the frame; revisions refresh, never re-share
hasF "$PLAN"   'skills/epic-page/template.html' "plan renders from the shared frame"
hasF "$REPORT" 'skills/epic-page/template.html' "report reuses the shared frame"
hasF "$PLAN"   'share.sh --refresh' "plan re-renders a revision in place"
hasF "$PLAN"   'doc-preview/share.sh' "plan hosts via doc-preview"
hasF "$PLAN"   'fleet:epic-member' "plan: member write-back carries the idempotency marker"
hasF "$PLAN"   '重启即失效' "plan: the pinned URL says the tailnet page dies on reboot"

# 5. the skill registers, on both install paths
CHECKS=$((CHECKS + 1)); head -1 "$SK" | grep -q '^---$' || fail "SKILL.md has no frontmatter"
hasF "$SK" 'name: epic-page' "SKILL.md name matches its directory"
hasF "$SK" '<!-- fleet skill -->' "SKILL.md carries the copy-install marker"

# 6. the decider's view (issue #881)
# 6a. reading order = file order, for both pages
order() {  # <label> <id>... — each section starts after the previous one
  local label=$1 prev=-1 id at; shift
  for id in "$@"; do
    CHECKS=$((CHECKS + 1))
    at=$(grep -n -F "<section id=\"$id\">" "$T" | head -1 | cut -d: -f1)
    [ -n "$at" ] && [ "$at" -gt "$prev" ] || fail "template: $label order breaks at #$id"
    prev=$at
  done
}
order plan metrics charter members risks signoff preflight order
order report delivered metrics members gaps obstacles next ops
# 6b. the band in plain words; the old jargon labels are gone from it
for k in 要做的事 有空再做 要看的指标 开跑前要处理; do
  hasF "$T" "<div class=\"k\">$k</div>" "template: band label $k"
done
for k in 核心层 储备层 新建子单 预检警告; do
  CHECKS=$((CHECKS + 1))
  grep -q -F "<div class=\"k\">$k</div>" "$T" && fail "template: band still says $k"
done
# 6c. whole-card fold, one line, no key on the surface; print still opens it
hasF "$T" '<details class="card">' "template: a member card folds whole"
hasF "$T" 'details.card>summary' "template: the card fold is styled in the shared <style>"
hasF "$T" 'details.card:not([open])>*' "template: print force-opens the card fold too"
hasF "$T" '<h3 class="grp">有空再做</h3>' "template: the reserve is the last group of the same list"
CHECKS=$((CHECKS + 1))
if grep -F '<summary><span class="ct">' "$T" | grep -qE '[CR][0-9]'; then
  fail "template: a card summary shows a member key"
fi
CHECKS=$((CHECKS + 1))
grep -E '^<h[23]' "$T" | grep -qE '(^|[^A-Za-z])[CR][0-9]' && fail "template: a heading shows a member key"
hasF "$T" '<dt>编号 / 来源</dt>' "template: the key lives in 技术细节"
# 6d. metric table: numbers on the surface, 口径 folded
hasF "$T" '<thead><tr><th>指标</th><th>现在</th><th>目标</th></tr></thead>' "template: metric header 指标/现在/目标"
hasF "$T" '<summary>怎么量</summary>' "template: 读数口径 sits in the 怎么量 fold"
# 6e. decisions in one table, preflight folded, order folded whole
hasF "$T" '<thead><tr><th>事项</th><th>建议</th></tr></thead>' "template: 需要你定的事 is one 事项/建议 table"
hasF "$T" '（批后）' "template: shows the 「（批后）」 mark"
hasF "$T" '<summary>预检原文</summary>' "template: the preflight screen is folded"
CHECKS=$((CHECKS + 1))
grep -A1 -F '<section id="order">' "$T" | grep -q -F '<details class="fold">' \
  || fail "template: #order is not folded whole"
# 6f. the plan command carries the rules, and write-back is unchanged
hasF "$PLAN" '#881' "plan: step 4 cites the decider's-view issue"
hasF "$PLAN" '点头即全部按建议' "plan: the nod accepts every default"
hasF "$PLAN" 'never the issue' "plan: folds do not change the write-back"
hasF "$PLAN" '- [ ] **C1** #N — title' "plan: the Core list line /fleet-epic-run parses is unchanged"
hasF "$PLAN" '<summary>实现细节（方案 · 接口约定 · 依赖 · 完成判据 · 上线证据）</summary>' "plan: the sub-issue body keeps its fold summary"
hasF "$PLAN" '（批后）' "plan: 「（批后）」 rows also go to the parent's 待决"
hasF "$REPORT" '#881' "report: follows the decider's view"
# 6g. the concurrency caps are the operator's (issue #881 point 16): plan and run
#     state them at most — never advise a value, never ask, never change one
RUN="$ROOT/commands/fleet-epic-run.md"
hasF "$PLAN" 'The concurrency caps are not this skill' "plan: leaves the session caps alone"
hasF "$RUN" "within the fleet's existing caps" "run: refills within the caps, never changes them"
for f in "$PLAN" "$RUN" "$T"; do
  CHECKS=$((CHECKS + 1))
  grep -qE 'FLEET_(GLOBAL_)?MAX_SESSIONS=[0-9]' "$f" && fail "${f#"$ROOT"/} suggests a session-cap value"
done

printf 'epic-page-selftest OK (%d checks)\n' "$CHECKS"
