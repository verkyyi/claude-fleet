#!/bin/bash
# landed-fold-selftest.sh — NESTING + FOLD in the dash's LANDED view.
#
# The closed list grew the live list's shape: ledger col 11 is the spawning
# session (#503), so a finished child renders under the finished parent that
# spawned it — `↳` tag, `└` indent — and the parent carries a `<landed>/<total> ✓`
# tally for the block. Blocks are FOLDED BY DEFAULT and the dash's ←/→ open and
# shut them, exactly as on the live side; what differs is only WHERE the bit
# lives, because a landed row has no tmux window to hang one on.
#
#   A. `rows` — default folded; a root, and an ORPHAN whose parent never reached
#      this list, are never hidden; the tally counts the WHOLE block (grandchild
#      included) whether it is open or shut; the caret marks exactly the rows that
#      own a block; a childless row is untouched; unfolding restores the `└`
#      indent and the chronological order WITHIN the block; the right-pinned
#      act/PR/dep columns do not move when a caret appears.
#   B. `fold` — → opens the block a row owns and ← shuts the block a row is IN
#      (from the parent, a child, or a grandchild); the expanded set is a file
#      that is REMOVED when the last block closes (no residue); a target that is
#      not on the list, and a row with no block, print nothing.
#
# Fully hermetic: no gh, no git, no tmux, no network — FLEET_HISTORY_LEDGER points
# at a fixture. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
HIST="$BIN/fleet-history.sh"
[ -f "$HIST" ] || { printf 'selftest: %s not found\n' "$HIST" >&2; exit 2; }

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]" "$2";; esac; }
not_contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — output unexpectedly contains [$3]" "$2";; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/landed-fold-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_HISTORY_LEDGER="$WORK/landed.tsv"
export FLEET_SESSION=fleetL
export TMPDIR="$WORK"          # fleet-lib.sh derives FLEET_C from TMPDIR on load,
                               # unconditionally — so scope the cache by moving TMPDIR,
                               # never by exporting FLEET_C (it would be overwritten).
FOLDFILE="$WORK/.claude-dash/global/dash_fold_landed_fleetL"
mkdir -p "$(dirname "$FOLDFILE")"

# --- the ledger fixture -------------------------------------------------------
# 11 columns: mergedAt·key·title·pr·sha·worktree·transcript·session·summary·state·origin
# Col 2 is a BARE issue number (or a `scratch-<N>` slug); col 11 is the @origin
# spelling (`issue-<N>`) — the two forms the nesting has to bridge.
# Newest first is what `rows` emits, so the timestamps below are the sort:
#   parent(10:00) ─ kidA(09:00) ─ grand(08:00)
#                 └ kidB(07:00)
#   scr-5(06:00)  ─ skid(05:00)                  a SCRATCH block (col 2 = scratch-5)
#   solo(04:00)                                  no block — must never grow a caret
#   orphan(03:00)                                col 11 names a session not in here
r() { printf '%s\t%s\t%s\t%s\tsha%s\t/w/wt-%s\t-\t-\t-\t%s\t%s\n' \
        "$1" "$2" "$3" "$4" "$2" "$2" "${6:-landed}" "${5:--}" >> "$FLEET_HISTORY_LEDGER"; }
: > "$FLEET_HISTORY_LEDGER"
r 2026-09-14T10:00:00Z 100 'the parent task'   '#900' -
r 2026-09-14T09:00:00Z 101 'child A'          '#901' issue-100
r 2026-09-14T08:00:00Z 102 'the grandchild'   '#902' issue-101
r 2026-09-14T07:00:00Z 103 'child B'          '-'    issue-100 closed-unlanded
r 2026-09-14T06:00:00Z scratch-5 'a scratch parent' '-' -
r 2026-09-14T05:00:00Z 104 'scratch kid'      '#904' scratch-5
r 2026-09-14T04:00:00Z 200 'a lone session'   '#920' -
r 2026-09-14T03:00:00Z 300 'lost its parent'  '#930' issue-999

strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
US=$(printf '\037')
raw()  { FZF_COLUMNS=180 bash "$HIST" rows 2>/dev/null; }
rows() { raw | awk -F"$US" 'NR>1 {print $3}' | strip; }
tgts() { raw | awk -F"$US" 'NR>1 {print $1}'; }
NAMES='#100 #101 #102 #103 ~5 #104 #200 #300'
order() { printf '%s\n' "$1" | awk -v ns=" $NAMES " '{for(i=1;i<=NF;i++) if(index(ns," "$i" ")){print $i; break}}'; }
row_of() { printf '%s\n' "$2" | awk -v n="$1" '{for(i=1;i<=NF;i++) if($i==n){print; exit}}'; }
# The TREE COLUMN (issue #836), shared with the live list: glyph1+sp + issue5+sp +
# tree1+sp, so the hierarchy glyph is character 8 of a rendered row and the window
# name starts at 10 — on EVERY row. Reading the cell by position is what keeps the
# two lists in lockstep; a `└ kid` substring would pass on a name-spliced indent too.
tree_of() { printf '%s' "${1:8:1}"; }
name_of() { printf '%s' "${1:10}"; }

# ============================================================================
# A. rows
# ============================================================================
out=$(rows)
[ -n "$out" ] || fail "landed rows produced no output" "$(raw)"

# A1. default folded — and no state file was created by merely rendering.
eq "rendering wrote no fold state" "0" "$( [ -e "$FOLDFILE" ] && echo 1 || echo 0 )"
eq "folded: only the rows that own or need no block" \
  "$(printf '#100\n~5\n#200\n#300')" "$(order "$out")"
not_contains "a landed child is folded away" "$out" "child A"
not_contains "a landed grandchild is folded away" "$out" "the grandchild"
not_contains "a closed-unlanded child folds too (nothing is waiting on you here)" "$out" "child B"

# A2. an orphan is never hidden — there would be no row left to open it from.
contains "an orphan stays on the list" "$out" "lost its parent"
contains "… and keeps its ↳ provenance tag" "$(row_of '#300' "$out")" "↳#999"
eq "… and its tree cell is blank — not drawn under an unrelated row" " " "$(tree_of "$(row_of '#300' "$out")")"

# A3. the tally describes the whole block while it is shut. parent's block is
#     kidA + grand + kidB = 3, of which kidB was closed-unlanded ⇒ 2 landed.
contains "a folded parent counts its whole subtree" "$(row_of '#100' "$out")" "2/3 ✓"
not_contains "… the grandchild is IN the count (3, not 2)" "$(row_of '#100' "$out")" "/2 ✓"
contains "a folded scratch parent counts its block too" "$(row_of '~5' "$out")" "1/1 ✓"

# A4. the caret marks exactly the rows that own a block.
eq "a folded block is marked ▸ in the tree cell" "▸" "$(tree_of "$(row_of '#100' "$out")")"
eq "a childless row's tree cell is blank" " " "$(tree_of "$(row_of '#200' "$out")")"
eq "an orphan's tree cell is blank too" " " "$(tree_of "$(row_of '#300' "$out")")"

# A5. the tree cell must not shove the right-pinned act/PR/dep block over — one
#     cell of source text inside a CONSTANT-width LEFTW, never a ${#} count
#     (`└`/`▸`/`▾` are East-Asian AMBIGUOUS width).
r_par=$(row_of '#100' "$out"); r_solo=$(row_of '#200' "$out")
eq "a caret row is the same total width as a caret-less one" "${#r_solo}" "${#r_par}"

# ============================================================================
# A6. unfolded
# ============================================================================
printf 'issue-100\n' > "$FOLDFILE"
out=$(rows)
eq "unfolded: the block sits under its parent, newest first inside it" \
  "$(printf '#100\n#101\n#102\n#103\n~5\n#200\n#300')" "$(order "$out")"
eq "a restored child draws └ in the tree cell" "└" "$(tree_of "$(row_of '#101' "$out")")"
eq "a restored grandchild too" "└" "$(tree_of "$(row_of '#102' "$out")")"
# …and every name starts at the same column — the point of the column (#836).
for k in '#100' '#101' '#102' '#103' '~5' '#200' '#300'; do
  r=$(row_of "$k" "$out")
  case "$(name_of "$r")" in ' '*|'') fail "the window name does not start at the fixed column on $k" "$r" ;; esac
  CHECKS=$((CHECKS + 1))
done
# The ↳ tag survives only where the tree cell cannot say the same thing.
not_contains "a direct child drops its ↳ tag — the └ cell says it" "$(row_of '#101' "$out")" "↳"
contains "a GRANDCHILD keeps its tag: it names ITS OWN parent, which the indent cannot — the grouping is two-level-flat, so it is drawn under the root beside its own parent" "$(row_of '#102' "$out")" "↳#101"
contains "an orphan keeps its tag too" "$(row_of '#300' "$out")" "↳#999"
eq "an open block is marked ▾ in the tree cell" "▾" "$(tree_of "$(row_of '#100' "$out")")"
contains "the tally is unchanged by unfolding" "$(row_of '#100' "$out")" "2/3 ✓"
# the grouping is two-level-flat, so the middle node owns no fold of its own
eq "an intermediate parent draws no caret — it is a child, not a holder" \
  "└" "$(tree_of "$(row_of '#101' "$out")")"
# one block open must not open the other
not_contains "opening one block leaves the other shut" "$out" "scratch kid"
r_par2=$(row_of '#100' "$out")
eq "unfolding does not change the parent row's width" "${#r_par}" "${#r_par2}"
rm -f "$FOLDFILE"

# ============================================================================
# B. fold
# ============================================================================
# the row targets, as the dash hands them to the toggle
t_par=$(printf '%s\n' "$(tgts)" | head -1)
eq "the parent's dash target is its PR" "landed:900" "$t_par"

# B0. the REAL entry point: the dash binds ←/→ to bin/dash-fold-toggle.sh, which
#     hands every `landed:*` target to us. Pin that seam — including the query
#     guard, which lives on that side and must fire before anything reaches here.
TOGGLE="$BIN/dash-fold-toggle.sh"
if [ -f "$TOGGLE" ]; then
  eq "toggle: a typed query keeps ← as the prompt line's cursor key"     "backward-char" "$(bash "$TOGGLE" collapse landed:900 'my scratch')"
  eq "toggle: … and a typed query keeps → as one too"     "forward-char" "$(bash "$TOGGLE" expand landed:900 'my scratch')"
  eq "toggle: neither of them folded anything" "0" "$( [ -e "$FOLDFILE" ] && echo 1 || echo 0 )"
  contains "toggle: → on a landed row reaches the ledger fold"     "$(bash "$TOGGLE" expand landed:900 '')" "reload("
  eq "toggle: … and opened the block" "issue-100" "$(cat "$FOLDFILE" 2>/dev/null)"
  bash "$TOGGLE" collapse landed:900 '' >/dev/null
  eq "toggle: ← shut it again" "0" "$( [ -e "$FOLDFILE" ] && echo 1 || echo 0 )"
else
  printf 'landed-fold-selftest: dash-fold-toggle.sh absent — seam case skipped\n' >&2
fi

# B1. → opens the block a row owns; a second press is a no-op.
act=$(bash "$HIST" fold expand landed:900)
contains "→ asks fzf to repaint" "$act" "reload("
eq "→ wrote the block open" "issue-100" "$(cat "$FOLDFILE" 2>/dev/null)"
eq "→ again is a no-op" "" "$(bash "$HIST" fold expand landed:900)"
contains "the list now shows the block" "$(rows)" "child A"

# B2. ← shuts it, and REMOVES the file when the last block closes — no residue.
act=$(bash "$HIST" fold collapse landed:900)
contains "← asks fzf to repaint" "$act" "reload("
eq "← left no fold file behind" "0" "$( [ -e "$FOLDFILE" ] && echo 1 || echo 0 )"
eq "← again is a no-op" "" "$(bash "$HIST" fold collapse landed:900)"

# B3. ← from INSIDE the block shuts that block — from a child AND a grandchild
#     (a 2-hop walk) — and moves the cursor to the parent that swallowed the row.
# As on the live side, what is pinned is the INVARIANT: the index fzf jumps to must
# be the parent's row in the very list fzf is told to load, and that list must be
# the snapshot already rendered — pointing fzf back at the producer would render
# twice (issue #662).
assert_cursor_lands_on_parent() { # <action> <expected field1> <label>
  local act="$1" want="$2" label="$3" path idx got
  case "$act" in
    "reload-sync(cat "*")+pos("*")") ;;
    *) fail "$label — expected a snapshot reload + pos(), got" "$act" ;;
  esac
  CHECKS=$((CHECKS+1))
  case "$act" in
    *tmux-dashboard-rows.sh*) fail "$label — the action re-runs the producer, so the keystroke renders TWICE (issue #662)" "$act" ;;
  esac
  CHECKS=$((CHECKS+1))
  path=${act#reload-sync(cat }; path=${path%%)*}
  idx=${act##*+pos(}; idx=${idx%)}
  [ -s "$path" ] || fail "$label — the snapshot fzf is pointed at is missing or empty: $path"
  CHECKS=$((CHECKS+1))
  got=$(awk -F"$US" -v n=$(( idx + 1 )) 'NR==n {print $1; exit}' "$path")
  [ "$got" = "$want" ] || fail "$label — pos($idx) lands on [$got], not the parent [$want]" "$(cat "$path")"
  CHECKS=$((CHECKS+1))
}

for inner in landed:901 landed:902; do
  bash "$HIST" fold expand landed:900 >/dev/null
  act=$(bash "$HIST" fold collapse "$inner")
  eq "← from $inner shuts the block it is in" "0" "$( [ -e "$FOLDFILE" ] && echo 1 || echo 0 )"
  assert_cursor_lands_on_parent "$act" "landed:900" "← from $inner"
done

# B4. → from inside a block is a no-op: the row is only on screen because the
#     block is already open.
bash "$HIST" fold expand landed:900 >/dev/null
eq "→ on a child does nothing" "" "$(bash "$HIST" fold expand landed:901)"
eq "… and left the block open" "issue-100" "$(cat "$FOLDFILE" 2>/dev/null)"
bash "$HIST" fold collapse landed:900 >/dev/null

# B5. two blocks are independent, and the scratch block folds by its own key.
bash "$HIST" fold expand landed:issue:scratch-5 >/dev/null 2>&1 || :
eq "a scratch parent is addressed by its scratch target" "scratch-5" "$(bash "$HIST" fold expand landed:scratch:scratch-5 >/dev/null; cat "$FOLDFILE" 2>/dev/null)"
out=$(rows)
contains "the scratch block opened" "$out" "scratch kid"
not_contains "… and the issue block stayed shut" "$out" "child A"
bash "$HIST" fold collapse landed:scratch:scratch-5 >/dev/null

# B6. nothing to fold: a childless row, an orphan, a target not on the list.
for t in landed:920 landed:930 landed:issue:9999 '' hdr; do
  outp=$(bash "$HIST" fold collapse "$t" 2>&1); rc=$?
  eq "no-op target [$t] exits 0" "0" "$rc"
  eq "no-op target [$t] prints nothing" "" "$outp"
done
eq "no-op targets wrote no fold state" "0" "$( [ -e "$FOLDFILE" ] && echo 1 || echo 0 )"

printf 'landed-fold-selftest OK (%d checks)\n' "$CHECKS"
