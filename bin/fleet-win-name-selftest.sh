#!/bin/bash
# fleet-win-name-selftest.sh — hermetic tests for fleet_win_name(), the single
# title→tmux-window-name derivation every spawn/restore/history/bind path shares
# (bin/fleet-lib.sh). Issue #579: the old filter was byte-wise, so a CJK title
# washed out to EMPTY and every worker window on a Chinese-language fleet degraded
# to `issue-<N>` — the dash became a column of numbers with no hint of what any
# worker was doing.
#
# Pins the five acceptance criteria of #579, plus the two constraints #455 left
# behind (a name that drifts, or that collides with a panel name, is worse than an
# ugly one):
#
#   A. CJK titles produce a READABLE CJK name, not empty / not issue-<N>.
#   B. DETERMINISM — same title, byte-identical name, across repeated calls AND
#      across a fresh process. bin/fleet-restore.sh reconciles a snapshot against
#      live window names with `grep -qxF`; a drifting name would make restore miss
#      a LIVE window and open a second Claude on the same worktree.
#   C. Truncation is by DISPLAY WIDTH (32 columns), never bytes/codepoints — the
#      output stays valid UTF-8 (no half-glyph tofu, #422's bug class) and fits the
#      column budget the dash / fleet-history pad against.
#   D. Emoji-only / punctuation-only titles STILL wash out to empty, so every
#      caller's slug fallback stays live.
#   E. Reserved panel names (dash/plan/backlog) are never derived — fleet_session_count
#      and the dash treat those names as panels, so a collision would hide the window
#      from the dash AND leak it out of the session cap.
#
#   F. ASCII REGRESSION GUARD — every ASCII title still derives byte-for-byte what
#      the pre-#579 pipeline derived (the reference implementation is inlined below),
#      so this change adds CJK support without renaming anything that already worked.
#   G. Degradation — no perl ⇒ the non-ASCII branch yields empty (exactly the
#      pre-#579 behaviour) rather than crashing or emitting mangled bytes.
#   H. Structural: exactly one derivation exists, and all four call sites route
#      through it, so the four "must behave consistently" call points cannot drift.
#
# Fully hermetic: sources the library, no tmux, no network, no repo.
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || { printf 'selftest: cannot source %s\n' "$LIB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/win-name-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() {  # <desc> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"
}
ok() { CHECKS=$((CHECKS + 1)); }

# ===== A: a CJK title names the window after the WORK, not its number =========
# The four titles from the #579 report (24haowan-monorepo, 2026-09-13) — all four
# spawned windows called issue-<N> before this change.
eq "A pure-CJK title"            "台账点文本跳录音" "$(fleet_win_name '台账点文本跳录音')"
eq "A pure-CJK title (2)"        "发布按钮收起来"   "$(fleet_win_name '发布按钮收起来')"
eq "A CJK title with digits"     "号码动态编排方案" "$(fleet_win_name '号码动态编排方案')"
# The one that half-worked before (leading ASCII survived, the rest was dropped):
# `sparse清单守卫` used to derive the bare `sparse`, which is what pointed at the
# byte-wise root cause in the first place.
eq "A mixed ASCII+CJK keeps BOTH halves" "sparse清单守卫" "$(fleet_win_name 'sparse清单守卫')"
eq "A mixed, with spaces + case"  "fleet-win-name-把中文标题洗成空" \
                                  "$(fleet_win_name 'fleet_win_name 把中文标题洗成空')"
# Non-CJK non-ASCII scripts are letters too, and lowercase Unicode-correctly.
eq "A Cyrillic lowercases"        "привет-мир"  "$(fleet_win_name 'Привет Мир')"
eq "A accented latin survives"    "café-münster" "$(fleet_win_name 'Café Münster')"

# ===== B: determinism — the restore reconcile (#455) depends on it ============
CJK_T='统一ai模型gateway重构'
first="$(fleet_win_name "$CJK_T")"
for _ in 1 2 3 4 5; do
  eq "B repeated calls are byte-identical" "$first" "$(fleet_win_name "$CJK_T")"
done
# …and identical out of a FRESH process (no accumulated shell state, and the
# derivation must not read the ambient locale: perl decodes UTF-8 explicitly and
# `lc` is Unicode-default, not locale-sensitive).
fresh=$(LC_ALL=C LANG=C bash -c '. "$1" 2>/dev/null; fleet_win_name "$2"' _ "$LIB" "$CJK_T")
eq "B a fresh process under LC_ALL=C derives the same name" "$first" "$fresh"
fresh2=$(LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 bash -c '. "$1" 2>/dev/null; fleet_win_name "$2"' _ "$LIB" "$CJK_T")
eq "B …and so does one under a UTF-8 locale" "$first" "$fresh2"

# ===== C: truncation is by DISPLAY WIDTH, and never splits a glyph ============
LONG='很长的中文标题需要被截断到合理的显示宽度上限不然窗口名会撑爆状态栏'
cut_out="$(fleet_win_name "$LONG")"
# 32 columns ÷ 2 columns per CJK glyph = 16 glyphs. Pinned literally so a silent
# change to the budget has to be a deliberate edit to this line.
eq "C a long CJK title is cut to 16 glyphs (32 columns)" "很长的中文标题需要被截断到合理的" "$cut_out"
fleet_clip_display 999 "$cut_out"
CHECKS=$((CHECKS + 1))
[ "${clip_w:-0}" -le 32 ] || fail "C the cut name must fit 32 columns, measured ${clip_w:-?}"
eq "C …and uses the whole budget"  "32" "$clip_w"
# The real tofu guard: a byte/codepoint cut would leave a truncated UTF-8 sequence.
CHECKS=$((CHECKS + 1))
printf '%s' "$cut_out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
  || fail "C the cut name is not valid UTF-8 — a glyph was split"
# Mixed ASCII+CJK: the budget is columns, so the cut lands wherever 32 columns do.
mix_out="$(fleet_win_name 'gateway 统一模型路由与配额编排的长标题')"
fleet_clip_display 999 "$mix_out"
CHECKS=$((CHECKS + 1))
[ "${clip_w:-0}" -le 32 ] || fail "C mixed ASCII+CJK must fit 32 columns, measured ${clip_w:-?}"
CHECKS=$((CHECKS + 1))
printf '%s' "$mix_out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
  || fail "C the mixed cut name is not valid UTF-8 — a glyph was split"

# ===== D: emoji / punctuation only still washes out to the slug fallback ======
# Emoji and symbols are NOT letters, so opening the character set to Unicode must
# not start naming windows 🎉 — every caller relies on empty ⇒ take my slug.
eq "D emoji-only → empty"        "" "$(fleet_win_name '🎉🎉🎉')"
eq "D symbol-only → empty"       "" "$(fleet_win_name '★★★')"
eq "D CJK punctuation-only → empty" "" "$(fleet_win_name '、。《》——！')"
eq "D ASCII punctuation-only → empty" "" "$(fleet_win_name '  ---  ')"
eq "D empty title → empty"       "" "$(fleet_win_name '')"
eq "D no argument at all → empty" "" "$(fleet_win_name)"
# Invalid UTF-8 must neither crash nor leak raw bytes into a tmux window name.
bad_out="$(fleet_win_name $'ab\xffcd')"
CHECKS=$((CHECKS + 1))
printf '%s' "$bad_out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
  || fail "D invalid UTF-8 leaked raw bytes into the name: [$bad_out]"

# ===== E: reserved panel names are never derived ==============================
# dash/plan/backlog are how fleet_session_count, fleet_session_count_for and the
# dash tell a panel from a working session. Deriving one would delete the window
# from the dash AND uncap the fleet.
for panel in dash plan backlog; do
  eq "E a title of exactly '$panel' falls back to the slug" "" "$(fleet_win_name "$panel")"
  eq "E …case-insensitively"  "" "$(fleet_win_name "$(printf '%s' "$panel" | tr 'a-z' 'A-Z')")"
done
# …but a title that merely CONTAINS one is a perfectly good name.
eq "E 'Plan the migration' is not a panel" "plan-the-migration" "$(fleet_win_name 'Plan the migration')"
eq "E a CJK title is not a panel either"   "重做dash的列宽"     "$(fleet_win_name '重做dash的列宽')"

# ===== F: ASCII regression guard — byte-identical to the pre-#579 pipeline =====
# The reference implementation IS the old fleet_win_name, inlined. Any ASCII title
# that named a window before must name it the same way now, or restore/history
# rows stop matching what is on screen.
old_win_name() {
  printf '%s' "$1" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C tr -c 'a-z0-9\n' '-' \
    | LC_ALL=C tr -s '-' \
    | sed -e 's/^-//' -e 's/-$//' \
    | cut -c1-32 \
    | sed -e 's/-$//'
}
while IFS= read -r t; do
  [ -n "$t" ] || continue
  eq "F ASCII '$t' derives what it always did" "$(old_win_name "$t")" "$(fleet_win_name "$t")"
done <<'ASCII_TITLES'
Fix The Widget Cache
fleet_win_name washes CJK titles to empty
dash: PR column rescans the whole prmap every row
a-very-long-ascii-title-that-goes-past-thirty-two-chars-and-then-some
UPPER CASE / punctuation!! and  repeated   spaces
123 456
--leading and trailing--
ASCII_TITLES
# The ONE deliberate ASCII divergence: the reserved-name guard (E above). Asserted
# here so it reads as a decision, not as a hole in the regression guard.
eq "F the old pipeline DID derive the panel name 'plan'" "plan" "$(old_win_name 'Plan')"
eq "F …and #579 deliberately refuses it"                 ""     "$(fleet_win_name 'Plan')"

# ===== G: no perl ⇒ pre-#579 behaviour (empty), never a crash or mangled bytes =
mkdir -p "$WORK/noperl"
printf '#!/bin/sh\nexit 127\n' > "$WORK/noperl/perl"
chmod +x "$WORK/noperl/perl"
noperl=$(PATH="$WORK/noperl:$PATH" bash -c '. "$1" 2>/dev/null; fleet_win_name "$2"' _ "$LIB" '台账点文本跳录音')
eq "G without perl a CJK title degrades to empty (caller takes its slug)" "" "$noperl"
noperl_ascii=$(PATH="$WORK/noperl:$PATH" bash -c '. "$1" 2>/dev/null; fleet_win_name "$2"' _ "$LIB" 'Fix The Widget Cache')
eq "G …while ASCII titles are unaffected" "fix-the-widget-cache" "$noperl_ascii"

# ===== H: structural — one derivation, four call sites, no second copy ========
defs=$(grep -c '^fleet_win_name()' "$LIB")
eq "H exactly one fleet_win_name definition" "1" "$defs"
# The four call points #579 lists. They must all go through the function — a
# hand-rolled slugify anywhere else would be a second, byte-wise copy that
# re-introduces the bug on whichever path grew it.
for f in dash-issue-session.sh dash-restore-session.sh fleet-history.sh fleet-bind.sh; do
  CHECKS=$((CHECKS + 1))
  grep -q 'fleet_win_name\|fleet_issue_win_name' "$BIN/$f" \
    || fail "H $f no longer derives its window name through fleet_win_name"
done
stray=$(grep -rln "tr -c 'a-z0-9" "$BIN" --include='*.sh' | grep -v -e 'fleet-lib.sh$' -e 'win-name-selftest.sh$' || true)
CHECKS=$((CHECKS + 1))
[ -z "$stray" ] || fail "H a second byte-wise slugify appeared in: $stray"

# ---- I. EPIC members wear their batch's 简称 (issue #2355) -------------------
epic_theme=''   # fleet_epic_theme_v's OUTPUT global
fleet_epic_theme_v 'EPIC: 托管节点：一条命令、一个守护、自己更新'
eq "I theme: EPIC: prefix and 「：…」 cut" "托管节点" "$epic_theme"
fleet_epic_theme_v 'EPIC: 新任务 3 秒开工'
eq "I theme: a title with no cut keeps itself" "新任务 3 秒开工" "$epic_theme"
fleet_epic_theme_v 'EPIC: Sidebar names — the long tail'
eq "I theme: ` — ` cuts too" "Sidebar names" "$epic_theme"
eq "I short: the body's short= marker wins" "托管" \
   "$(fleet_epic_short 'EPIC: 托管节点：一条命令' $'x\n<!-- fleet:epic repo=acme/app short=托管 -->\ny')"
eq "I short: no marker ⇒ the theme's first 4 letters/digits" "托管节点" "$(fleet_epic_short 'EPIC: 托管节点：一条命令')"
eq "I short: …spaces and punctuation are not letters" "新任务3" "$(fleet_epic_short 'EPIC: 新任务 3 秒开工')"
eq "I member ref: a bare number = the member's own repo" $'\t2329' \
   "$(fleet_epic_member_ref $'body\n<!-- fleet:epic-member epic=2329 key=C3 -->')"
eq "I member ref: another repo's EPIC" $'acme/app\t12' \
   "$(fleet_epic_member_ref '<!-- fleet:epic-member epic=acme/app#12 key=C2 -->')"
eq "I member ref: no marker ⇒ nothing" "" "$(fleet_epic_member_ref 'an ordinary issue')"
eq "I member name: 简称·title" "托管·一个节点程序服务" \
   "$(fleet_member_win_name '一个节点程序服务' '托管')"
long='一个节点程序服务机器上所有账号的事情都由它来管而且标题非常非常长'
got=$(fleet_member_win_name "$long" '托管')
case "$got" in 托管·*) ok ;; *) fail "I member name: a long title must not cut the 简称 (got '$got')" ;; esac
eq "I member name: still within 32 columns" "31" "$(printf '%s' "$got" | perl -CS -ne 'my $w=0; for (split //) { $w += (ord($_) >= 0x1100 ? 2 : 1) } print $w')"
eq "I member name: no 简称 ⇒ fleet_win_name byte for byte" "$(fleet_win_name "$long")" "$(fleet_member_win_name "$long" '')"
eq "I member name: an ASCII non-EPIC title unchanged" "fix-the-widget-cache" "$(fleet_member_win_name 'Fix The Widget Cache' '')"
eq "I member name: an empty title part ⇒ empty (caller's slug)" "" "$(fleet_member_win_name '🎉🎉' '托管')"
# fleet_issue_win_name: a member whose EPIC gh cannot read takes its title off
# the local issue cache; a non-member is never sent to gh for a parent
mkdir -p "$WORK/c/fleets/acme-app" "$WORK/gh"
printf '\t#12\t\tEPIC: 托管节点：一条命令\n' > "$WORK/c/fleets/acme-app/issues"
printf '#!/bin/sh\nexit 1\n' > "$WORK/gh/gh"; chmod +x "$WORK/gh/gh"
eq "I issue name: a member, gh down ⇒ the cache's EPIC title" "托管节点·节点程序" \
   "$(PATH="$WORK/gh:$PATH" FLEET_C="$WORK/c" bash -c '. "$1"; FLEET_C="$2"; fleet_issue_win_name acme/app 13 "节点程序" "<!-- fleet:epic-member epic=12 key=C1 -->"' _ "$LIB" "$WORK/c")"
eq "I issue name: a non-member ⇒ the plain name" "节点程序" \
   "$(PATH="$WORK/gh:$PATH" bash -c '. "$1"; fleet_issue_win_name acme/app 13 "节点程序" "plain body"' _ "$LIB")"

# J. an ordinary worker is named by its USE (issue #2545): the part before the
#    first 「：」/「，」/`: `, no parenthesised aside, no technical token, no hyphen
#    beside a CJK glyph, clipped to 24 columns — the sidebar's ~18 cells for a
#    name then read as something, not 「托管机器上旧版-fleet-host-on-以」.
eq "J use: only the part before 「：」" "常备会话预热把机器锁死" \
   "$(fleet_issue_plain_name '常备会话预热把机器锁死：scratch-pool ensure 每拍过准入就预留名额')"
eq "J use: …and before an ASCII ': '" "fix-the-cache" "$(fleet_issue_plain_name 'Fix the cache: fleet_lw drops rows')"
eq "J use: a （aside） is dropped" "测试身份开出来的home会话" \
   "$(fleet_issue_plain_name '测试身份（fleet --test-identity claude）开出来的 home 会话落在人的侧栏里当 norepo，没有回收策略')"
eq "J use: no hyphen beside a CJK glyph" "入口把home会话放进macmin" \
   "$(fleet_issue_plain_name '入口把 home 会话放进 macmini 上另一个登录（verkyyi）的旧 fleet')"
eq "J use: fleet- prefix, .sh suffix, --flag, under_score come off" "issue-file对超长标题给提" \
   "$(fleet_issue_plain_name 'fleet-issue-file.sh --hint 对超长标题给提示 fleet_title_use')"
eq "J use: an ASCII-only title still slugs" "add-a-hint" "$(fleet_issue_plain_name 'Add a hint --flag fleet_x')"
eq "J use: a short plain title is itself" "每日推送没跑成" "$(fleet_issue_plain_name '每日推送没跑成')"
got=$(fleet_issue_plain_name '托管机器上旧版 fleet host on 以登录身份重登记：入口换发令牌')
eq "J use: clipped to 24 columns" "托管机器上旧版fleet-host" "$got"
eq "J use: FLEET_ISSUE_NAME_COLS moves the clip" "托管机器" \
   "$(FLEET_ISSUE_NAME_COLS=8 fleet_issue_plain_name '托管机器上旧版 fleet host on')"
eq "J use: a title that cleans to nothing keeps fleet_win_name's name" "fleet-x-y" \
   "$(fleet_issue_plain_name 'fleet_x: --y')"
eq "J use: still never a panel name" "" "$(fleet_issue_plain_name 'Plan')"
eq "J use: deterministic across processes" "$(fleet_issue_plain_name '入口把 home 会话放进 macmini 上')" \
   "$(bash -c '. "$1"; fleet_issue_plain_name "入口把 home 会话放进 macmini 上"' _ "$LIB")"
eq "J issue name: a non-member goes through it" "常备会话预热把机器锁死" \
   "$(PATH="$WORK/gh:$PATH" bash -c '. "$1"; fleet_issue_win_name acme/app 13 "常备会话预热把机器锁死：scratch-pool" "plain body"' _ "$LIB")"
eq "J issue name: a member keeps its 简称·title, byte for byte" "托管节点·节点程序-fleet-x" \
   "$(PATH="$WORK/gh:$PATH" FLEET_C="$WORK/c" bash -c '. "$1"; FLEET_C="$2"; fleet_issue_win_name acme/app 13 "节点程序 fleet_x" "<!-- fleet:epic-member epic=12 key=C1 -->"' _ "$LIB" "$WORK/c")"

printf 'selftest OK: fleet_win_name (%s assertions — #579 CJK names, determinism for restore #455, 32-column UTF-8-safe cut, emoji/punct slug fallback, reserved-panel guard, ASCII regression guard, no-perl degradation, #2355 EPIC 简称, #2545 a worker named by its use)\n' "$CHECKS"
