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
for id in preflight charter members order risks open signoff; do
  hasF "$T" "<section id=\"$id\">" "template: section #$id"
  hasF "$PLAN" "\`#$id\`" "plan names section #$id"
done
hasF "$T" 'id="m-C1"' "template: a member card carries id=m-<key>"

# 2. the six member fields, 上线证据 as a single evidence line
for f in 目标 方案 '接口 / 约定' 依赖 完成判据 上线证据; do
  hasF "$T" "<dt>$f</dt>" "template: member field $f"
done
hasF "$T" 'class="evidence"' "template: 上线证据 is styled as the one-line evidence slot"
hasF "$PLAN" '上线证据' "plan: the member section defines the 上线证据 line"
hasF "$REPORT" '上线证据' "report: reads the member's 上线证据 line (the #810 seam)"

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

printf 'epic-page-selftest OK (%d checks)\n' "$CHECKS"
