#!/bin/bash
# fleet-draft-selftest.sh — a draft-only ticket (issue #3715): its PR does NOT
# merge on a green gate, only after `fleet-draft.sh approve`.
#
#   A  block / scan: the mark + the PR note round-trip; approved / rejected read back
#   B  mark: adds the block once (idempotent), the old body kept
#   C  THE rule: fleet-pr-merge.sh with the gate READY on a draft-only ticket's PR
#      prints DRAFT-ONLY, exits 1, and never calls `gh pr merge`
#   D  approve: `gh pr ready`, the mark stamped approved, the worker told
#      (--to-worker); then fleet-pr-merge.sh merges → MERGED
#   E  a ticket with no mark merges as before (the gate is not this one's)
#   F  reject: the PR closed with the reason, the mark stamped rejected, merge refused
#   G  FLEET_DRAFT_GATE=0 is the hatch
#
# Hermetic: a sandbox bin/ of symlinks to the real scripts, with fleet-pr-verdict.sh
# and fleet-comment.sh replaced by stubs and `gh` faked on PATH. No network, no tmux.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/draft-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

SB="$WORK/bin"; ST="$WORK/state"; FB="$WORK/fakebin"
mkdir -p "$SB" "$ST" "$FB" "$WORK/conf"
for f in "$BIN"/*; do ln -s "$f" "$SB/$(basename "$f")"; done
rm -f "$SB/fleet-pr-verdict.sh" "$SB/fleet-comment.sh"
# The verdict: READY until the fake gh has merged, then MERGED.
cat > "$SB/fleet-pr-verdict.sh" <<EOF
#!/bin/bash
if [ -f "$ST/merged" ]; then echo MERGED; exit 1; fi
echo READY; exit 0
EOF
cat > "$SB/fleet-comment.sh" <<EOF
#!/bin/bash
{ printf 'comment %s\n' "\$*"; cat; } >> "$ST/comments"
echo https://example.invalid/c/1
EOF
chmod +x "$SB/fleet-pr-verdict.sh" "$SB/fleet-comment.sh"

# gh: issue #7's body lives in $ST/body; PR #12 is head issue-7, draft until ready.
cat > "$FB/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$ST/gh.log"
case "\$1 \$2" in
  "issue view") python3 -c 'import json,sys; print(json.dumps({"body": open(sys.argv[1]).read()}))' "$ST/body" ;;
  "issue edit") while [ "\$#" -gt 0 ]; do [ "\$1" = --body-file ] && { cp "\$2" "$ST/body"; break; }; shift; done ;;
  "pr view")    echo "\${HEAD:-issue-7}" ;;
  "pr list")    if [ -f "$ST/ready" ]; then echo "12 false"; else echo "12 true"; fi ;;
  "pr ready")   : > "$ST/ready" ;;
  "pr merge")   : > "$ST/merged" ;;
  "pr close")   : > "$ST/closed" ;;
  *)            exit 0 ;;
esac
EOF
chmod +x "$FB/gh"

export PATH="$FB:$PATH" FLEET_CONF_DIR="$WORK/conf"
unset TMUX TMUX_PANE FLEET_DRAFT_GATE
D="$SB/fleet-draft.sh"; M="$SB/fleet-pr-merge.sh"; R=acme/widgets
reset() { rm -f "$ST"/*; printf '%s\n' "${1:-the ask}" > "$ST/body"; }

# ----- A
out=$(printf 'body\n\n%s\n' "$(bash "$D" block --pr-note $'日报回复 2026-10-12#3\n<!-- daily-plan -->')" | bash "$D" scan)
[ "$(printf '%s\n' "$out" | head -1)" = draft ] || fail "A scan → draft" "$out"
printf '%s\n' "$out" | grep -qx '日报回复 2026-10-12#3' && printf '%s\n' "$out" | grep -qx '<!-- daily-plan -->' \
  || fail "A the PR note reads back verbatim" "$out"
[ "$(printf 'x\n<!-- fleet:draft-only approved=2026-10-12T00:00:00Z by=hub -->\n' | bash "$D" scan | head -1)" = approved ] \
  || fail "A approved mark"
[ "$(printf 'x\n<!-- fleet:draft-only rejected=2026-10-12T00:00:00Z by=hub -->\n' | bash "$D" scan | head -1)" = rejected ] \
  || fail "A rejected mark"
[ "$(printf 'plain body\n' | bash "$D" scan)" = none ] || fail "A no mark → none"
ok "A block / scan round-trip the mark and the PR note"

# ----- B
reset "keep this line"
bash "$D" mark 7 --repo "$R" --pr-note 'PR 附注' 2>/dev/null || fail "B mark exit"
bash "$D" mark 7 --repo "$R" 2>/dev/null || fail "B second mark exit"
[ "$(grep -c 'fleet:draft-only' "$ST/body")" = 1 ] || fail "B marked exactly once" "$(cat "$ST/body")"
grep -qx 'keep this line' "$ST/body" && grep -qx 'PR 附注' "$ST/body" || fail "B old body + note kept" "$(cat "$ST/body")"
[ "$(bash "$D" state 7 --repo "$R")" = draft ] || fail "B state → draft"
ok "B mark adds the block once and keeps the body"

# ----- C
out=$(bash "$M" 12 --repo "$R" 2>&1); rc=$?
[ "$rc" = 1 ] || fail "C exit 1 on a green draft-only PR (got $rc)" "$out"
printf '%s\n' "$out" | grep -qx 'DRAFT-ONLY' || fail "C prints DRAFT-ONLY" "$out"
grep -q '^pr merge' "$ST/gh.log" && fail "C gh pr merge must not run" "$(cat "$ST/gh.log")"
[ -f "$ST/merged" ] && fail "C nothing merged"
ok "C a green gate does not merge a draft-only ticket's PR"

# ----- D
out=$(bash "$D" approve 7 --repo "$R" --by daily 2>&1) || fail "D approve exit" "$out"
grep -q '^pr ready 12' "$ST/gh.log" || fail "D gh pr ready 12" "$(cat "$ST/gh.log")"
grep -q 'fleet:draft-only approved=.* by=daily -->' "$ST/body" || fail "D stamped approved" "$(cat "$ST/body")"
grep -q -- '--to-worker' "$ST/comments" && grep -q '批准（草稿单）' "$ST/comments" || fail "D worker told" "$(cat "$ST/comments" 2>/dev/null)"
out=$(bash "$M" 12 --repo "$R" 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx MERGED || fail "D merges once approved (rc $rc)" "$out"
ok "D approve readies the PR, tells the worker, and the merge then lands"

# ----- E
reset "an ordinary ticket"
out=$(bash "$M" 12 --repo "$R" 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx MERGED || fail "E unmarked ticket merges (rc $rc)" "$out"
reset "x"; HEAD=feature-x bash "$M" 12 --repo "$R" >/dev/null 2>&1 || fail "E a non-issue head is not this gate's"
ok "E no mark ⇒ merges as before"

# ----- F
reset "the ask"; bash "$D" mark 7 --repo "$R" 2>/dev/null
bash "$D" reject 7 --repo "$R" 2>/dev/null && fail "F reject without --reason must refuse"
out=$(bash "$D" reject 7 --repo "$R" --reason '不划算' 2>&1) || fail "F reject exit" "$out"
grep -q '^pr close 12 .*不划算' "$ST/gh.log" || fail "F PR closed with the reason" "$(cat "$ST/gh.log")"
grep -q 'fleet:draft-only rejected=' "$ST/body" || fail "F stamped rejected" "$(cat "$ST/body")"
grep -q '不划算' "$ST/comments" || fail "F reason on the issue"
bash "$M" 12 --repo "$R" >/dev/null 2>&1 && fail "F a rejected ticket's PR never merges"
reset "plain"; bash "$D" approve 7 --repo "$R" >/dev/null 2>&1; [ $? = 4 ] || fail "F approve on a plain ticket → 4"
ok "F reject closes the PR, records why, and the merge stays refused"

# ----- G
reset "the ask"; bash "$D" mark 7 --repo "$R" 2>/dev/null
FLEET_DRAFT_GATE=0 bash "$M" 12 --repo "$R" >/dev/null 2>&1 || fail "G FLEET_DRAFT_GATE=0 passes"
ok "G FLEET_DRAFT_GATE=0 is the hatch"

printf 'fleet-draft-selftest: %d passed\n' "$pass"
