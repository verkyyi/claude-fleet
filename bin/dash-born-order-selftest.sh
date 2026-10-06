#!/bin/bash
# shellcheck disable=SC1010  # `done` here is a state word handed to fixture(), not the keyword
# dash-born-order-selftest.sh — a row sits where its session was born (issue #1750).
#
# tmux-dashboard-rows.sh orders the list by repo group → 置顶 → parent subtree →
# BIRTH (@born, else window_created; the WFMT's last field), never by state, so a
# turn going working → done → working, a `needs` coming and going, or a window
# closing in the middle (renumber-windows) moves no row. The rows waiting on you
# stay put; one summary line above the list counts them. FLEET_DASH_ORDER=status
# is the old order, byte for byte.
#
# Legs:
#   A. status    — FLEET_DASH_ORDER=status: needs first, then by rank and index,
#                  no summary line; the born field changes NOT ONE BYTE of it
#                  (the old producer never read one)
#   B. rotate    — born order: the states cycle working→done→working→needs→done
#                  and a middle window closes (the rest renumber): the rows' order
#                  never changes; children stay under their parent in birth order
#   C. machines  — another machine's rows (cache field 15) and this machine's share
#                  one ruler: interleaved by birth, the cache's row order changes
#                  nothing; a remote row with no birth sorts after its born siblings
#   D. summary   — a needs / failed row puts `! N 个在问你 · 点这里跳过去 ⌃K` on top (the
#                  sidebar's glyph field `!`, an inert hdr); none ⇒ no line; the hub
#                  list's has no key hint; a lost machine's row is not counted
#   E. inventory — fleet-control-read.sh's `born=` column parses (fleet_hub_common
#                  inventory_row); an adapter without it still parses, born None
#
# Hermetic: a PATH-shimmed `tmux` replays a fixture window list. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
command -v python3 >/dev/null 2>&1 || { echo 'dash-born-order selftest: python3 absent — SKIP'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dashborn-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
S="born$$"
unset CCQUOTA_FLEET FLEET_DASH_ORDER TMUX TMUX_PANE FLEET_SIDEBAR_SOURCE
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh
G="$WORK/.claude-dash/global"
mkdir -p "$G" "$WORK/conf/fleets/$S" "$WORK/bin"
printf 'FLEET_REPO=acme/app\n' > "$WORK/conf/fleets/$S/conf"

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
export WLIST_FILE="$WORK/wlist"
SHIMPATH="$WORK/bin:$PATH"

# The 26 WFMT fields: session idx name path state state_ts wid @issue @origin
# @worktree @cc_agent @wid needs @expand @pin flags reap×3 @repo @norepo sleep
# @repo_fold @loop @title_info born
# w <idx> <name> <state> <wid> <issue> <origin> <born> [expand]
w() { printf '%s\n' "$S$US$1$US$2$US/w/app-issue-$5$US$3$US$US$4$US$5$US$6$US$US$US$US$US${8:-}$US$US$US$US$US$US$US$US$US$US$US$US$7" >> "$WLIST_FILE"; }
B=1759000000
# rows: A (oldest) · P with two children C1 / C2 (C2 older than C1) · Z (newest)
fixture() {   # $1..$5 = the states of A P C1 C2 Z; $6 = drop this name (closed)
  : > "$WLIST_FILE"; local i=1 n st
  for n in A P C1 C2 Z; do
    case "$n" in A) st=$1 ;; P) st=$2 ;; C1) st=$3 ;; C2) st=$4 ;; Z) st=$5 ;; esac
    [ "$n" = "${6:-}" ] && continue
    case "$n" in
      A)  w "$i" A  "$st" @1 101 ''        $((B + 10)) ;;
      P)  w "$i" P  "$st" @2 102 ''        $((B + 20)) "${PEXP-1}" ;;
      C1) w "$i" C1 "$st" @3 103 issue-102 $((B + 40)) ;;
      C2) w "$i" C2 "$st" @4 104 issue-102 $((B + 30)) ;;
      Z)  w "$i" Z  "$st" @5 105 ''        $((B + 50)) ;;
    esac
    i=$((i + 1))
  done
}
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g' -e 's/⠋/*/g;s/⠙/*/g;s/⠹/*/g;s/⠸/*/g;s/⠼/*/g;s/⠴/*/g;s/⠦/*/g;s/⠧/*/g;s/⠇/*/g;s/⠏/*/g'; }
side() { PATH="$SHIMPATH" FLEET_SESSION=$S bash "$ROWS" --sidebar 2>/dev/null | strip; }
hub()  { PATH="$SHIMPATH" FLEET_SESSION=$S FZF_COLUMNS=140 bash "$ROWS" 2>/dev/null | strip; }
sorder(){ printf '%s\n' "$1" | LC_ALL=C awk -F"$US" '$1 != "hdr" { printf "%s;", $4 }'; }
shdrs() { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" '$1 == "hdr" { printf "%s|%s;", $3, $4 }'; }

# ============================================================================
# A. status — the old order, byte for byte
# ============================================================================
export FLEET_DASH_ORDER=status
fixture working done working needs done
s=$(side)
eq "A: status — by rank then index (done before working); children under P by rank" \
   "P;C2;C1;Z;A;" "$(sorder "$s")"
eq "A: status — no summary line" "" "$(shdrs "$s")"
withb_s=$s; withb_h=$(hub)
sed -i.bak "s/${US}[0-9]*\$/${US}/" "$WLIST_FILE"            # every born field emptied
eq "A: status — the born field changes not one byte (sidebar)" "$withb_s" "$(side)"
eq "A: status — the born field changes not one byte (hub)"     "$withb_h" "$(hub)"
unset FLEET_DASH_ORDER

# ============================================================================
# B. rotate — born order holds through every state and a close
# ============================================================================
want="A;P;C2;C1;Z;"
for states in 'working working working working working' 'done done done done done' \
              'working done working done working' 'needs working needs done failed' \
              'done needs done working needs' 'looping sleeping done needs working'; do
  # shellcheck disable=SC2086  # five words on purpose
  fixture $states
  eq "B: born order through [$states]" "$want" "$(sorder "$(side)")"
done
eq "B: an unknown order word is the born order" "$want" "$(sorder "$(FLEET_DASH_ORDER=x side)")"
fixture working needs done working done C2          # C2 closed: the rest renumber
eq "B: a window closing in the middle moves no other row" "A;P;C1;Z;" "$(sorder "$(side)")"
fixture working done working done working A
eq "B: the first window closing moves no other row" "P;C2;C1;Z;" "$(sorder "$(side)")"
fixture done done done done done
eq "B: the hub list keeps the same order" "#101 #102 #104 #103 #105" \
   "$(hub | LC_ALL=C grep -o '#10[1-5]' | tr '\n' ' ' | sed 's/ $//')"

# ============================================================================
# C. machines — one ruler for this machine's rows and the others'
# ============================================================================
export CCQUOTA_FLEET=1
F=11111111-2222-3333-4444-555555555555
NOW=$(date +%s)
cache() {   # rows in the order given: <key> <name> <born>
  { printf '#ts\037%s\n#me\037m5\n#node\037m4\037online\0372\037%s\n' "$NOW" "$NOW"
    while [ $# -ge 3 ]; do
      printf 'wid:%s/%s\037m4\037online\037\037acme/app\037working\037claude\037%s\037\037\0370\037\037hub\037\037%s\n' "$F" "$1" "$2" "$3"
      shift 3
    done
  } > "$G/remote_$S"
}
printf '%s\n' "$NOW" > "$G/hub_ok"
fixture working done working done working
cache issue-7 R1 $((B + 15)) issue-8 R2 $((B + 45)) issue-9 R0 ''
eq "C: remote rows interleave by birth; no birth sorts after the born" \
   "A;R1;P;C2;C1;R2;Z;R0;" "$(sorder "$(side)")"
cache issue-9 R0 '' issue-8 R2 $((B + 45)) issue-7 R1 $((B + 15))
eq "C: the hub's row order changes nothing" "A;R1;P;C2;C1;R2;Z;R0;" "$(sorder "$(side)")"
fixture needs working needs working working
cache issue-7 R1 $((B + 15))
eq "C: a needs row on either machine stays in place" "A;R1;P;C2;C1;Z;" "$(sorder "$(side)")"
rm -f "$G/remote_$S" "$G/hub_ok"; unset CCQUOTA_FLEET

# ============================================================================
# D. summary — the rows waiting on you, counted on top
# ============================================================================
fixture working done working done working
s=$(side)
eq "D: nobody asking — no summary line" "" "$(shdrs "$s")"
fixture needs done failed done working
s=$(side)
eq "D: two asking — the summary line first, glyph ! for the view" \
   "!|! 2 个在问你 · 点这里跳过去 ⌃K;" "$(shdrs "$s")"
eq "D: …it is the first line of the list" "hdr" "$(printf '%s\n' "$s" | head -1 | cut -d"$US" -f1)"
eq "D: …and the asking rows stay where they were born" "$want" "$(sorder "$s")"
h=$(hub)
has "D: the hub list's summary, no key hint" "$h" "! 2 个在问你"
hasnt "D: …the hub's ⌃k answers, so it names no key" "$(printf '%s\n' "$h" | grep '个在问你')" "⌃k"
eq "D: status order — no summary line" "" "$(shdrs "$(FLEET_DASH_ORDER=status side)")"
# a folded parent still shows its asking child (FOLD_KEEP), and it is counted
PEXP='' fixture done done needs done done                 # P collapsed
s=$(side)
eq "D: a folded parent: its asking child stays on the list" "A;P;C1;Z;" "$(sorder "$s")"
eq "D: …and counts" "!|! 1 个在问你 · 点这里跳过去 ⌃K;" "$(shdrs "$s")"

# ============================================================================
# E. inventory — the adapter's born= column
# ============================================================================
out=$(python3 - "$BIN" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from fleet_hub_common import inventory_row
base = ["@1", "7", "", "/w", "done", "", "", "", "", "nm", "", "", "11111111-2222-3333-4444-555555555555"]
p, x = inventory_row(base + ["busy=", "born=1759000010"])
assert x["born"] == 1759000010 and x["busy"] is None and x["name"] == "nm", x
p, x = inventory_row(base + ["busy=bg"])
assert "born" not in x and x["busy"] == "bg", x
p, x = inventory_row(base + ["busy=", "born="])
assert x["born"] is None, x
print("ok")
PY
)
eq "E: born= parses; an adapter without it still parses" "ok" "$out"

echo "dash-born-order selftest: $CHECKS checks passed"
