#!/bin/bash
# dash-rows-nesting-selftest.sh — the session list nests by REAL depth, folds and
# counts level by level, lays the sidebar out to its width, and draws five state
# glyphs instead of ten (issue #1328).
#
#   ▶ ⠏ ▾ 系统奔溃了            · 1/7      root: its whole tree
#     ↻ └▾ EPIC1312-连跑不积…    · 0/2      a middle row: ITS subtree, own caret
#     !   └ 关窗口时连带清理…               a grandchild, under its REAL parent
#     ⠏   └ 开太久的会话自动提…
#
# Legs:
#   A. nesting   — every row sorts directly under its own parent (a subtree is
#                  contiguous), indents one level per generation in the sidebar,
#                  marks the level in the hub's 2-cell tree column, and caps the
#                  indent at 4 while the sort keeps the whole path; a broken
#                  chain sinks, still nested under what is live of it
#   B. fold      — every level folds on its own; a `!` row never folds away
#   I. reaped    — a middle window that was reaped (issue #1352): the grandchild
#                  climbs on through the child-report ledger to the nearest LIVE
#                  ancestor, at depth 1, counted in its k/N; no ledger record ⇒
#                  today's orphan sink, byte for byte
#   C. counts    — every level's badge is ITS subtree's `k/N`, nothing else: no
#                  trailing ✓, no `· n!`
#   D. glyphs    — every needs kind and failed draw `!` (the kind rides the
#                  detail field); preparing/waking spin; a sleeper is a bare `z`
#   E. widths    — at 26 / 30 / 44 columns the badge is whole, the name ends in
#                  `…` when it does not fit, a parent row carries no child state
#   F. degenerate— a one-level fleet with short names paints exactly the old
#                  `marker glyph tree label` line, and no ↳ parent tag survives
#   G. auto width— longest row, within 30–44, ≤ ¼ window, worker keeps 80
#
# Hermetic: `tmux` is PATH-shimmed to replay a fixture window list (never a live
# server). No gh, no git, no network. Exit 0 = pass.
set -uo pipefail
# The rows' order asserted here is the status order (needs/done/working by rank):
# pin it — the default born order (issue #1750) is dash-born-order-selftest.sh's.
export FLEET_DASH_ORDER=status

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
SIDEBAR_PY="$BIN/fleet-sidebar.py"
[ -f "$ROWS" ] && [ -f "$SIDEBAR_PY" ] || { printf 'selftest: rows/sidebar not found\n' >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dashnest-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh
mkdir -p "$WORK/.claude-dash/global" "$WORK/conf" "$WORK/bin"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()    { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }
has()   { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1 — no [$3]" "$2";; esac; }
hasnt() { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1 — unexpected [$3]" "$2";; *) : ;; esac; }

US=$'\x1f'
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/sh
US=$(printf '\037'); lw=0; fmt=0
for a in "$@"; do [ "$a" = list-windows ] && lw=1; case "$a" in *"$US"*) fmt=1 ;; esac; done
[ "$lw" = 1 ] && [ "$fmt" = 1 ] && cat "$WLIST_FILE"
exit 0
SHIM
chmod +x "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"; export PATH
WLIST_FILE="$WORK/wlist"; export WLIST_FILE
# Field order MUST match WFMT: session idx name path state state_ts wid @issue
# @origin @worktree @cc_agent @wid @claude_needs @expand
w() { printf '%s\n' "S$US$1$US$2$US$3$US$4$US$US$5$US$6$US$7$US$8$US$US$US${10:-}$US${9:-}" >> "$WLIST_FILE"; }
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
side() { FLEET_SESSION=S FLEET_SIDEBAR_CURRENT="${1:-}" bash "$ROWS" --sidebar 2>/dev/null | strip; }
hub()  { FLEET_SESSION=S FZF_COLUMNS=140 bash "$ROWS" 2>/dev/null | strip; }
# sidebar row → `name|tree|badge|depth` ; its order → names joined by space
srow()  { printf '%s\n' "$1" | awk -F"$US" -v n="$2" '$4 == n { print $4 "|" $5 "|" $6 "|" $7; exit }'; }
sorder(){ printf '%s\n' "$1" | awk -F"$US" '$1 != "hdr" { printf "%s ", $4 }'; }
hrow()  { printf '%s\n' "$1" | awk -F"$US" -v n=" $2 " 'index($3, n) { print $3; exit }'; }
htree() { local r; r=$(hrow "$1" "$2"); printf '%s' "${r:8:2}"; }

# --- the four-level tree, plus a fifth, an orphan and a lonely root -----------
#   root ─┬ A (scratch) ─┬ A1 ─ A1x ─ A1y ─ A1z      (A1z: depth 5, shown at 4)
#         │              └ A2 (needs/perm)
#         └ B (scratch) ── B1
#   lonely                                            a childless root
#   orph ─ orphkid                                    orph's parent is gone
: > "$WLIST_FILE"
#   idx name   cwd                   state     wid  @issue @origin    @worktree           @expand @needs
w 1  root   /w/r-scratch-1        working   @1   ''     ''         /w/r-scratch-1      1
w 2  B      /w/r-scratch-3        looping   @2   ''     scratch-1  /w/r-scratch-3      1
w 3  A      /w/r-scratch-2        looping   @3   ''     scratch-1  /w/r-scratch-2      1
w 4  B1     /w/r-issue-30         working   @4   30     scratch-3  /w/r-issue-30
w 5  A1     /w/r-issue-20         working   @5   20     scratch-2  /w/r-issue-20       1
w 6  A2     /w/r-issue-21         needs     @6   21     scratch-2  /w/r-issue-21       ''      perm
w 7  A1x    /w/r-issue-22         'done'    @7   22     issue-20   /w/r-issue-22       1
w 8  A1y    /w/r-issue-23         working   @8   23     issue-22   /w/r-issue-23       1
w 9  A1z    /w/r-issue-24         'done'    @9   24     issue-23   /w/r-issue-24
w 10 lonely /w/r-issue-40         working   @10  40     ''         /w/r-issue-40
w 11 orph   /w/r-issue-50         'done'    @11  50     issue-999  /w/r-issue-50       1
w 12 orphkid /w/r-issue-51        working   @12  51     issue-50   /w/r-issue-51

# ============================================================================
# A. nesting
# ============================================================================
s=$(side)
[ -n "$s" ] || fail "the sidebar producer printed nothing"
# siblings keep the (rank, idx) order roots always had: a needs row first, then
# working, then looping — so A2 (!) leads A's block and B (idx 2) leads A (idx 3).
eq "A: every subtree is contiguous, each row directly under its OWN parent" \
   "root B B1 A A2 A1 A1x A1y A1z lonely orph orphkid " "$(sorder "$s")"
eq "A: a root with a subtree: its caret, depth 0"     "root|▾|2/8|0"       "$(srow "$s" root)"
eq "A: a middle row: └ + its own caret, depth 1"      "A|└▾|2/5|1"         "$(srow "$s" A)"
eq "A: depth 2 indents two cells"                     "A1|  └▾|2/3|2"      "$(srow "$s" A1)"
eq "A: depth 3 indents four"                          "A1x|    └▾|1/2|3"   "$(srow "$s" A1x)"
eq "A: depth 4 indents six"                           "A1y|      └▾|1/1|4" "$(srow "$s" A1y)"
eq "A: deeper than 4 shows AT 4 (sort keeps the path)" "A1z|      └||4"    "$(srow "$s" A1z)"
eq "A: a childless root: blank tree, no badge"        "lonely| ||0"         "$(srow "$s" lonely)"
eq "A: a broken chain sinks, nested under what is live" "orphkid|└||1"     "$(srow "$s" orphkid)"
h=$(hub)
eq "A: hub tree column — a root holder"        "▾ " "$(htree "$h" root)"
eq "A: hub tree column — level 1: └ on the left" "└▾" "$(htree "$h" A)"
eq "A: hub tree column — level 1 leaf"          "└ " "$(htree "$h" orphkid)"
eq "A: hub tree column — level 2: └ on the right" " ▾" "$(htree "$h" A1)"
eq "A: hub tree column — level 2 leaf"          " └" "$(htree "$h" A2)"
eq "A: hub tree column — level 3+: ┊└"          "┊▾" "$(htree "$h" A1x)"
eq "A: hub tree column — deeper still ┊└"       "┊└" "$(htree "$h" A1z)"
eq "A: hub tree column — a lonely root: blank"  "  " "$(htree "$h" lonely)"
for v in A A1x A2 B1 orphkid; do hasnt "A: no ↳ parent tag on $v" "$(hrow "$h" "$v")" "↳"; done
# every hub row keeps its width: the 2-cell tree column is a CONSTANT, so the
# right-pinned act/PR/ctx block never moves (the `!` row's act word is CJK:
# measured in cells, the tree glyphs as the 1 cell the producer budgets them).
widths=$(printf '%s\n' "$h" | python3 -c 'import sys, unicodedata
w = lambda t: sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in t)
print("\n".join(sorted({str(w(l.split("\x1f")[2])) for l in sys.stdin.read().split("\n")[1:] if "\x1f" in l})))')
eq "A: every hub row is the same width" "136" "$widths"

# ============================================================================
# B. fold — level by level
# ============================================================================
sed -i.bak -e "s/^\(S${US}5${US}A1${US}.*\)${US}1\$/\1${US}/" "$WLIST_FILE"   # fold A1 only
s=$(side)
eq "B: folding a MIDDLE row hides only its subtree" \
   "root B B1 A A2 A1 lonely orph orphkid " "$(sorder "$s")"
eq "B: …which wears ▸ and still counts all of it" "A1|  └▸|2/3|2" "$(srow "$s" A1)"
eq "B: …the sidebar's current window is never folded away" \
   "root B B1 A A2 A1 A1y lonely orph orphkid " "$(sorder "$(side @8)")"
sed -i.bak -e "s/^\(S${US}1${US}root${US}.*\)${US}1\$/\1${US}/" "$WLIST_FILE"  # fold the root
s=$(side)
eq "B: folding the root hides the tree — but a ! row never folds away, under its real parent" \
   "root A2 lonely orph orphkid " "$(sorder "$s")"
eq "B: the exempt row keeps its depth" "A2|  └||2" "$(srow "$s" A2)"
# restore: re-expand both
sed -i.bak -e "s/^\(S${US}1${US}root${US}.*\)${US}\$/\1${US}1/" \
           -e "s/^\(S${US}5${US}A1${US}.*\)${US}\$/\1${US}1/" "$WLIST_FILE"

# ============================================================================
# C. counts — numbers only
# ============================================================================
h=$(hub)
for v in root A A1 A1x A1y B; do
  hasnt "C: $v's badge has no trailing ✓" "$(hrow "$h" "$v")" " ✓"
  hasnt "C: $v's badge carries no child state" "$(hrow "$h" "$v")" "!"
done
has "C: root sums the whole tree (8 below it, 2 done)" "$(hrow "$h" root)" "2/8"
has "C: a middle row counts ITS subtree"              "$(hrow "$h" A)"    "2/5"
has "C: …and so does the next one down"               "$(hrow "$h" A1)"   "2/3"

# ============================================================================
# D. glyphs — five, not ten
# ============================================================================
: > "$WLIST_FILE"
i=0
for kind in ask perm blocked restore other; do
  i=$((i+1)); w "$i" "n-$kind" "/w/r-issue-$i" needs "@$i" "$i" '' "/w/r-issue-$i" '' "$kind"
done
w 6 n-failed /w/r-issue-6 failed    @6 6 '' /w/r-issue-6
w 7 n-prep   /w/r-issue-7 preparing @7 7 '' /w/r-issue-7
w 8 n-wake   /w/r-issue-8 waking    @8 8 '' /w/r-issue-8
w 9 n-sleep  /w/r-issue-9 sleeping  @9 9 '' /w/r-issue-9
s=$(side); h=$(hub)
. "$BIN/fleet-ui-lang.sh"
gd() { printf '%s\n' "$s" | awk -F"$US" -v n="$1" '$4 == n { print $3 "|" $8; exit }'; }
for kind in ask perm blocked restore other; do
  eq "D: needs/$kind → ! + its kind in words" "!|$(fleet_ui_t "needs_$kind")" "$(gd "n-$kind")"
  has "D: needs/$kind → the hub's act cell names it" "$(hrow "$h" "n-$kind")" "$(fleet_ui_t "needs_$kind")"
done
eq "D: failed → ! + its kind" "!|$(fleet_ui_t needs_failed)" "$(gd n-failed)"
SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
for v in n-prep n-wake; do
  g=$(gd "$v"); g=${g%%|*}
  case "$SPIN" in *"$g"*) CHECKS=$((CHECKS+1)) ;; *) fail "D: $v spins like working (got '$g')" ;; esac
done
eq "D: a sleeper is a bare z in the sidebar" "z|" "$(gd n-sleep)"
for g in '?' '⊘' '⊠' '↺'; do
  hasnt "D: the retired $g glyph appears nowhere in the sidebar" "$(printf '%s\n' "$s" | awk -F"$US" '{print $3}')" "$g"
done

# ============================================================================
# E/F/G. the view: widths, the degenerate frame, the auto width
# ============================================================================
: > "$WLIST_FILE"
w 1 小助理小程序邀请码 /w/r-scratch-1 'done'  @1 '' ''        /w/r-scratch-1 ''
w 2 阿里云月成本评估-ack-节点合并 /w/r-scratch-2 working @2 '' '' /w/r-scratch-2 ''
w 3 k1 /w/r-issue-31 'done' @3 31 scratch-2 /w/r-issue-31
w 4 k2 /w/r-issue-32 needs  @4 32 scratch-2 /w/r-issue-32 '' ask
w 5 k3 /w/r-issue-33 working @5 33 scratch-1 /w/r-issue-33
side > "$WORK/wide"
: > "$WLIST_FILE"
w 1 alpha /w/r-issue-1 working  @1 1 '' /w/r-issue-1
w 2 beta  /w/r-issue-2 'done'   @2 2 '' /w/r-issue-2
w 3 gamma /w/r-issue-3 sleeping @3 3 '' /w/r-issue-3
w 4 delta /w/r-issue-4 needs    @4 4 '' /w/r-issue-4 '' ask
side > "$WORK/flat"
out=$(python3 - "$SIDEBAR_PY" "$WORK/wide" "$WORK/flat" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sidebar", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def load(path):
    return [m.row_fields(l) for l in open(path, encoding="utf-8").read().split("\n") if l.count("\x1f") >= 4]
fails = []
def check(ok, what):
    if not ok: fails.append(what)
wide = load(sys.argv[2])
# E. widths
for cols in (26, 30, 44):
    for r in wide:
        wid, state, glyph, name, tree, badge = r[:6]
        if wid == "hdr":
            continue
        t = m.row_text(" ", glyph, tree, name, badge, cols - 1)
        check(m.width_of(t) <= cols - 1, "E%d: %s overflows: %r" % (cols, name, t))
        if badge:
            check(t.endswith("· " + badge), "E%d: %s lost its badge: %r" % (cols, name, t))
            check("!" not in t.split(name[:1], 1)[-1].replace(badge, "") or glyph == "!",
                  "E%d: %s parent row carries child state: %r" % (cols, name, t))
        if m.width_of(m.row_left(" ", glyph, tree, name)) + (len(badge) + 3 if badge else 0) > cols - 1:
            check("…" in t, "E%d: a clipped name must end in …: %r" % (cols, t))
        else:
            check("…" not in t and name in t, "E%d: a name that fits must be whole: %r" % (cols, t))
parent = [r for r in wide if r[3].startswith("阿里云")][0]
check(parent[5] == "1/2", "E: the parent's badge is just k/N: %r" % parent[5])
t30 = m.row_text(" ", parent[2], parent[4], parent[3], parent[5], 29)
check(t30.endswith("· 1/2") and "…" in t30, "E30: the long parent keeps 1/2 and clips its name: %r" % t30)
# F. degenerate: one level, short names, no badge → the old line, byte for byte
flat = load(sys.argv[3])
check(len(flat) == 4, "F: a one-level fleet lost rows: %r" % flat)
for r in flat:
    wid, state, glyph, name, tree, badge = r[:6]
    old = " " + " " + glyph + " " + (tree or " ") + " " + name
    check(m.row_text(" ", glyph, tree, name, badge, 29) == old,
          "F: %s differs from the old frame: %r vs %r" % (name, m.row_text(" ", glyph, tree, name, badge, 29), old))
    check("↳" not in name and not badge, "F: %s grew a tag/badge: %r" % (name, r))
# G. auto width
check(m.auto_width(flat, 200, 30, 44) == 30, "G: short rows keep the 30 floor")
need = max(m.row_need(r) for r in wide)
check(m.auto_width(wide, 200, 30, 44) == min(44, max(30, need)), "G: widens to the longest row")
check(m.auto_width(wide + [["@9", "", "·", "x" * 80, "", "", "0", ""]], 200, 30, 44) == 44, "G: capped at 44")
check(m.auto_width(wide, 140, 30, 44) <= 35, "G: never past a quarter of the window")
check(m.auto_width(wide, 115, 30, 44) == 30, "G: never under the floor, never into the worker's 80")
k2 = [r for r in wide if r[3] == "k2"][0]
check(m.detail_line(k2).split(" · ")[0] == "k2" and (not k2[7] or k2[7] not in m.detail_line(k2)),
      "G: the bar's line leads with the whole name — the kind of ! is @title_info's (#1377): %r" % m.detail_line(k2))
print("\n".join(fails) if fails else "ok")
PY
)
eq "E/F/G: the view lays rows out right" "ok" "$out" "$out"
CHECKS=$((CHECKS+20))

# ============================================================================
# H. why a ↻ row waits (issue #1370): on a `looping` window WFMT carries
#    @claude_wait in the needs field, and the sidebar's detail says it — its own
#    subtree badge for `children`; nothing for a Loop-only or reason-less ↻
# ============================================================================
: > "$WLIST_FILE"
w 1 par   /w/r-issue-1  looping @1 1 ''      /w/r-issue-1 1 children
w 2 kid1  /w/r-issue-2  'done'  @2 2 issue-1 /w/r-issue-2
w 3 kid2  /w/r-issue-3  working @3 3 issue-1 /w/r-issue-3
w 4 bgw   /w/r-issue-4  looping @4 4 ''      /w/r-issue-4 '' bg
w 5 lpw   /w/r-issue-5  looping @5 5 ''      /w/r-issue-5 '' loop
w 6 both  /w/r-issue-6  looping @6 6 ''      /w/r-issue-6 '' loop,bg
s=$(side)
det() { printf '%s\n' "$1" | awk -F"$US" -v n="$2" '$4 == n { print $8; exit }'; }
eq "H: waiting on children → 等子任务 + its own k/N" "等子任务 1/2" "$(det "$s" par)"
eq "H: a background command → 后台命令在跑" "后台命令在跑" "$(det "$s" bgw)"
eq "H: a Loop alone needs no words (the ↻ says it)" "" "$(det "$s" lpw)"
eq "H: loop,bg → the bg words" "后台命令在跑" "$(det "$s" both)"
eq "H: a child's own row carries nothing" "" "$(det "$s" kid2)"
h=$(hub)
hasnt "H: the hub's red act cell never shows a ↻ reason" "$h" "等子任务"

# ============================================================================
# I. a reaped middle layer (issue #1352): gp ─ [issue-12, reaped] ─ gk, and a
#    two-deep gap gp ─ [12] ─ [14, reaped] ─ gk2. The ledger (children/<parent>.ndjson,
#    #937) still says who each reaped key's parent was.
# ============================================================================
: > "$WLIST_FILE"
w 1 gp     /w/r-issue-10 working @1 10 ''       /w/r-issue-10 1
w 2 sib    /w/r-issue-11 'done'  @2 11 issue-10 /w/r-issue-11
w 3 gk     /w/r-issue-13 'done'  @3 13 issue-12 /w/r-issue-13
w 4 gk2    /w/r-issue-15 working @4 15 issue-14 /w/r-issue-15
w 5 lonely /w/r-issue-20 working @5 20 ''       /w/r-issue-20
# the working spinner is clock-driven: fold its frame out before comparing frames
nospin() { perl -CSD -pe 's/[\x{2800}-\x{28FF}]/*/g'; }
s0=$(side); h0=$(hub | nospin)
eq "I: no ledger — the grandchildren sink as orphans (today's rule)" \
   "gp sib lonely gk gk2 " "$(sorder "$s0")"
eq "I: no ledger — gp counts only its live child" "gp|▾|1/1|0" "$(srow "$s0" gp)"
LD="$FLEET_CONF_DIR/fleets/S/children"; mkdir -p "$LD"
printf '{"seq": 1, "child": "issue-12", "state": "MERGED", "pr": "99"}\n' > "$LD/issue-10.ndjson"
printf '{"seq": 1, "child": "issue-14", "state": "MERGED"}\n'           > "$LD/issue-12.ndjson"
# a relayed row is not a parent link: it must not re-parent gk2 onto lonely
printf '{"seq": 1, "child": "issue-15", "state": "BLOCKED", "relayed_from": "issue-14"}\n' > "$LD/issue-20.ndjson"
s=$(side)
eq "I: the grandchildren nest under the nearest live ancestor" \
   "gp sib gk gk2 lonely " "$(sorder "$s")"
eq "I: …at depth 1, no label"                 "gk|└||1"     "$(srow "$s" gk)"
eq "I: …through a two-deep gap too"           "gk2|└||1"    "$(srow "$s" gk2)"
eq "I: …and they count in gp's k/N"           "gp|▾|2/3|0"  "$(srow "$s" gp)"
eq "I: a relayed_from row parents nothing"    "lonely| ||0" "$(srow "$s" lonely)"
hasnt "I: no ↳ tag names the reaped parent"   "$(hub)" "↳"
# a ledger that does not know the reaped key ⇒ exactly today's frame
printf '{"seq": 1, "child": "issue-77", "state": "MERGED"}\n' > "$LD/issue-10.ndjson"
rm -f "$LD/issue-12.ndjson" "$LD/issue-20.ndjson"
eq "I: an unknown key in the ledger — sidebar unchanged" "$(printf '%s' "$s0" | nospin)" "$(side | nospin)"
eq "I: an unknown key in the ledger — hub unchanged"     "$h0" "$(hub | nospin)"

printf 'dash-rows-nesting-selftest: OK (%d checks)\n' "$CHECKS"
