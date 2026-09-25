#!/bin/bash
# dash-pin-selftest.sh — the dash PIN tier (issue #623), end to end.
#
# A pin is a sort tier ABOVE the status rank, and it rides the same @origin
# inheritance the #503 grouping uses, so the things worth proving are exactly the
# ways those two interact:
#   A. the toggle (bin/dash-pin-toggle.sh): sets @pin=1, UNSETS it on the second
#      press (never parks a 0 — an unpinned window must be byte-identical to one
#      that was never pinned), addresses a window by `sess:idx` AND by its #566
#      handle, and no-ops on a landed/header/absent target.
#   B. the ordering (bin/tmux-dashboard-rows.sh): a pinned window beats every
#      unpinned one whatever its status rank; a pinned PARENT floats its children
#      and grandchildren with it, indentation intact; a pinned CHILD of an
#      unpinned root floats with ITS OWN descendants and sheds the └ indent;
#      several pins sort among themselves by the order they'd have had anyway;
#      unpinning leaves the list byte-identical to before it was pinned (no residue).
#   C. the 置顶 group (issue #1170): the pinned rows sit under ONE `置顶 (n)`
#      heading at the very top, closed by a single rule, in a one-repo fleet too;
#      no row carries a pin mark (no 📌, no sidebar `* `) on either surface; no pin
#      ⇒ no heading, no rule, output byte-identical.
#
# Needs a real tmux, on an ISOLATED socket via the PATH shim (never the live
# server — see dash-marker-selftest.sh). tmux absent → SKIP cleanly. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
TOGGLE="$BIN/dash-pin-toggle.sh"
for f in "$ROWS" "$TOGGLE"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]" "$2";; esac; }
not_contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — output unexpectedly contains [$3]" "$2";; esac; }

REAL_TMUX="$(command -v tmux 2>/dev/null)"
if [ -z "$REAL_TMUX" ]; then
  printf 'dash-pin-selftest: tmux not installed — SKIPPED\n'; exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-pin-selftest.XXXXXX")" || exit 2
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"     # keep #566's @wid allocation lock in the sandbox
mkdir -p "$WORK/conf" "$WORK/bin"

SOCK="$WORK/tmux.sock"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
export TMPDIR="$WORK"                  # scope the dash cache under WORK
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# US round-trip probe — some Linux tmux builds octal-escape 0x1f in -F output, so
# the row producer cannot be parsed there at all (same gate as origin-selftest).
US=$(printf '\037')
tmux new-session -d -s probe -x 80 -y 24 'sleep 300' 2>/dev/null \
  || fail "could not start the isolated tmux server"
probe_out=$(tmux list-windows -t probe -F "a${US}b" 2>/dev/null | od -An -tx1 | tr -d ' \n')
tmux kill-session -t probe 2>/dev/null
case "$probe_out" in
  *611f62*) : ;;
  *) printf 'dash-pin-selftest: this tmux octal-escapes US in -F — SKIPPED\n'; exit 0 ;;
esac

# -c "$WORK" everywhere: a pane must never inherit the INVOKING cwd — run from a
# checkout whose dir name ends `-scratch-<N>` the window would key as that scratch.
tmux new-session -d -s fleetP -x 220 -y 50 -c "$WORK" 'sleep 300' \
  || fail "could not start the 'fleetP' session"
# @expand=1 on every fixture window: a subtree is COLLAPSED BY DEFAULT (the ←/→
# fold), and the whole point of this part is how a PIN moves children and
# grandchildren around — which is only observable with the blocks open. The pin
# tier and the fold are deliberately independent (a pin re-sorts, it never
# unfolds); bin/dash-fold-selftest.sh pins that they compose.
mk_win() { # <name> [issue] [origin] → window id
  local n="$1" iss="${2:-}" org="${3:-}" wid
  wid=$(tmux new-window -d -P -F '#{window_id}' -t fleetP: -n "$n" -c "$WORK" 'sleep 300')
  [ -n "$iss" ] && tmux set-window-option -t "$wid" @issue "$iss"
  [ -n "$org" ] && tmux set-window-option -t "$wid" @origin "$org"
  tmux set-window-option -t "$wid" @expand 1
  printf '%s' "$wid"
}
# pA ─ cA ─ gA      (a three-deep chain: the inheritance cases)
# pB ─ cB              (a second group, and the status-rank case)
W_pA=$(mk_win pA 100 '')
W_cA=$(mk_win  cA  102 issue-100)
W_gA=$(mk_win gA 105 issue-102)
W_pB=$(mk_win pB 101 '')
W_cB=$(mk_win  cB  103 issue-101)

pin()   { tmux set-window-option -t "$1" @pin 1; }
unpin() { tmux set-window-option -t "$1" -u @pin; }
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g' -e $'s/\x1f/ /g'; }
rows()  { FLEET_SESSION=fleetP FZF_COLUMNS=180 bash "$ROWS" 2>/dev/null | strip; }
# order <out> → this test's window names, top to bottom, one per line. The name is
# a whitespace-delimited token in the rendered row, so pick it out by FIELD — the
# initial `sleep` window the session starts with is simply not one of ours and
# drops out. (awk, not sed: BSD sed has no `\|` alternation.)
NAMES='pA pB cA cB gA'
order() { printf '%s\n' "$1" | awk -v ns=" $NAMES " '{for(i=1;i<=NF;i++) if(index(ns," "$i" ")){print $i; break}}'; }
# line_of <name> <out> → that row's 1-based line number.
line_of() { printf '%s\n' "$2" | awk -v n="$1" '{for(i=1;i<=NF;i++) if($i==n){print NR; exit}}'; }
# The TREE COLUMN (issue #836): the hierarchy glyph is a fixed cell between issue
# and window, not an indent spliced into the name — glyph1+sp + issue5+sp + tree1+sp,
# so on a DISPLAY-field-only row it is character 8 and every name starts at 10.
# `rows()` above keeps the two target fields, so read the display field on its own.
US=$(printf '\037')
drows() { FLEET_SESSION=fleetP FZF_COLUMNS=180 bash "$ROWS" 2>/dev/null \
            | awk -F"$US" 'NR>1 {print $3}' | LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
drow_of() { printf '%s\n' "$2" | awk -v n="$1" '{for(i=1;i<=NF;i++) if($i==n){print; exit}}'; }
tree_of() { local r; r=$(drow_of "$1" "$(drows)"); printf '%s' "${r:8:1}"; }

# ============================================================================
# A. the toggle script
# ============================================================================
opt() { tmux show-options -wqv -t "$1" @pin 2>/dev/null; }

bash "$TOGGLE" "fleetP:$(tmux display-message -p -t "$W_pB" '#{window_index}')" >/dev/null 2>&1
eq "toggle: sess:idx target sets @pin=1" "1" "$(opt "$W_pB")"
bash "$TOGGLE" "fleetP:$(tmux display-message -p -t "$W_pB" '#{window_index}')" >/dev/null 2>&1
eq "toggle: a second press UNSETS @pin (no parked 0 — no residue)" "" "$(opt "$W_pB")"

# the #566 handle form: the rows producer backfills @wid, so render once, then
# drive the toggle with the handle it allocated.
rows >/dev/null
hnd=$(tmux show-options -wqv -t "$W_cB" @wid 2>/dev/null)
if [ -n "$hnd" ]; then
  bash "$TOGGLE" "$hnd" >/dev/null 2>&1
  eq "toggle: window HANDLE target ($hnd) sets @pin=1" "1" "$(opt "$W_cB")"
  bash "$TOGGLE" "$hnd" >/dev/null 2>&1
  eq "toggle: handle target unsets it again" "" "$(opt "$W_cB")"
else
  printf 'dash-pin-selftest: no @wid backfilled — handle case skipped\n' >&2
fi

# no-op targets must not error and must not pin anything
for t in '' hdr landed:412 'fleetP:9999'; do
  bash "$TOGGLE" "$t" >/dev/null 2>&1
  eq "toggle: no-op target [$t] exits 0" "0" "$?"
done
eq "toggle: a no-op target pinned nothing" "" "$(opt "$W_pA")"

# ============================================================================
# B. ordering
# ============================================================================
base_out=$(rows); base_order=$(order "$base_out")
[ -n "$base_order" ] || fail "rows produced no recognisable rows" "$base_out"
eq "baseline: #503 grouping, window order" \
  "$(printf 'pA\ncA\ngA\npB\ncB')" "$base_order"
not_contains "baseline: nothing is marked" "$base_out" "📌"
not_contains "baseline: no 置顶 heading without a pin" "$base_out" "置顶"
not_contains "baseline: no rule without a pin" "$base_out" "─"
base_raw=$(FLEET_SESSION=fleetP FZF_COLUMNS=180 bash "$ROWS" 2>/dev/null)
base_side=$(FLEET_SESSION=fleetP bash "$ROWS" --sidebar 2>/dev/null)

# --- B1. a pin beats the status rank -----------------------------------------
# pB goes RED (needs, rank 0) — it would normally head the list. pA is idle
# (rank 4) and pinned, so it must sit above it anyway.
tmux set-window-option -t "$W_pB" @claude_state needs
out=$(rows)
eq "control: an unpinned red root heads the list" "pB" "$(order "$out" | head -1)"
pin "$W_pA"
out=$(rows)
eq "pin beats the status rank: pinned idle pA above red pB" \
  "$(printf 'pA\ncA\ngA\npB\ncB')" "$(order "$out")"
not_contains "no row wears a 📌 (issue #1170 — the group says it)" "$out" "📌"
# C. the 置顶 group: heading first, then the pinned block, then ONE rule, then
# the rest — the heading counts the rows under it, the floated subtree included.
dout=$(drows)
eq "the list opens with the 置顶 heading" "置顶 (3)" "$(printf '%s\n' "$dout" | sed -n 1p)"
rule_ln=$(printf '%s\n' "$dout" | awk '/^─+$/{print NR}')
eq "exactly one rule, right after the pinned block (heading + pA cA gA)" "5" "$rule_ln"
eq "the rule spans the list width (FZF_COLUMNS 180 − 4)" "176" \
  "$(printf '%s\n' "$dout" | sed -n 5p | awk '{gsub(/─/,"x"); print length}')"
eq "an unpinned row follows the rule" "pB" "$(order "$(printf '%s\n' "$dout" | sed -n '6,$p')" | head -1)"
hdr_raw=$(FLEET_SESSION=fleetP FZF_COLUMNS=180 bash "$ROWS" 2>/dev/null | grep '置顶')
eq "the heading is inert (hdr keys) and folds as \`pin\`" "hdr hdr pin" \
  "$(printf '%s' "$hdr_raw" | awk -F"$US" '{print $1, $2, $4}')"
rule_raw=$(FLEET_SESSION=fleetP FZF_COLUMNS=180 bash "$ROWS" 2>/dev/null | grep '───')
eq "the rule is an inert hdr row with no 4th field" "hdr hdr 3" \
  "$(printf '%s' "$rule_raw" | awk -F"$US" '{print $1, $2, NF}')"
side=$(FLEET_SESSION=fleetP bash "$ROWS" --sidebar 2>/dev/null)
eq "sidebar: 置顶 heading first, keyed hdr:pin" "hdr pin 置顶 (3)" \
  "$(printf '%s\n' "$side" | sed -n 1p | awk -F"$US" '{print $1, $2, $4}')"
eq "sidebar: the pinned row's label opens with its name (no \`* \`)" "pA · 0/2 ✓" \
  "$(printf '%s\n' "$side" | sed -n 2p | awk -F"$US" '{print $4}')"
eq "sidebar: the rule closes the block, key fields hdr + empty" "hdr||200" \
  "$(printf '%s\n' "$side" | sed -n 5p | awk -F"$US" '{n=$4; gsub(/─/,"x",n); print $1 "|" $2 "|" length(n)}')"
eq "a floated child keeps its └ tree cell" "└" "$(tree_of cA)"
eq "a floated grandchild keeps its └ tree cell" "└" "$(tree_of gA)"
# C2. ←/→ on the 置顶 heading folds the group (#1037's rail, one-repo fleet
# too): the rows go, the red `needs` one would stay, the heading keeps its count.
FOLD="$BIN/dash-fold-toggle.sh"
bash "$FOLD" collapse hdr '' pin >/dev/null 2>&1
eq "collapse on the 置顶 heading writes the \`pin\` token" "pin" \
  "$(tmux show-option -t '=fleetP:' -qv @repo_fold)"
dout=$(drows)
eq "a folded 置顶 heading wears ▸ and keeps its count" "▸ 置顶 (3)" "$(printf '%s\n' "$dout" | sed -n 1p)"
eq "… and hides the pinned rows (the rule stays)" "$(printf 'pB\ncB')" "$(order "$dout")"
bash "$FOLD" expand 'hdr:pin' >/dev/null 2>&1
eq "expand (sidebar key form) unsets the option again" "" \
  "$(tmux show-option -t '=fleetP:' -qv @repo_fold)"
eq "… and the pinned rows are back" "$(printf 'pA\ncA\ngA\npB\ncB')" "$(order "$(rows)")"
tmux set-window-option -t "$W_pB" -u @claude_state

# --- B2. pinning a parent floats its whole subtree ----------------------------
unpin "$W_pA"; pin "$W_pB"
out=$(rows)
eq "pinned pB + its child float above the unpinned group" \
  "$(printf 'pB\ncB\npA\ncA\ngA')" "$(order "$out")"
eq "cB sits DIRECTLY under its pinned parent" \
  "$(( $(line_of pB "$out") + 1 ))" "$(line_of cB "$out")"
eq "cB keeps its tree cell while floated" "└" "$(tree_of cB)"

# --- B3. several pins sort among themselves by their ordinary order -----------
pin "$W_pA"
out=$(rows)
eq "two pinned roots keep their (rank, index) order between themselves" \
  "$(printf 'pA\ncA\ngA\npB\ncB')" "$(order "$out")"
unpin "$W_pA"; unpin "$W_pB"

# --- B4. a pinned CHILD of an unpinned root floats with its own descendants ---
pin "$W_cA"
out=$(rows)
eq "a pinned child floats, taking its grandchild with it" \
  "$(printf 'cA\ngA\npA\npB\ncB')" "$(order "$out")"
eq "the grandchild stays directly under it" \
  "$(( $(line_of cA "$out") + 1 ))" "$(line_of gA "$out")"
# promoted to a group root ⇒ BLANK tree cell (its parent is no longer the line
# above), but the ↳ provenance tag is never lost.
cA_line=$(printf '%s\n' "$out" | grep 'cA ')
eq "a promoted pinned child blanks its tree cell" " " "$(tree_of cA)"
contains "… but keeps its ↳ provenance tag" "$cA_line" "↳#100"
eq "… and its own child still draws └ under it" "└" "$(tree_of gA)"
unpin "$W_cA"

# --- B5. no residue ----------------------------------------------------------
after_out=$(rows)
eq "unpinning everything restores the baseline order" "$base_order" "$(order "$after_out")"
not_contains "unpinning removes the mark" "$after_out" "📌"
eq "no pin ⇒ the list is byte-identical to before (hub)" "$base_raw" \
  "$(FLEET_SESSION=fleetP FZF_COLUMNS=180 bash "$ROWS" 2>/dev/null)"
eq "no pin ⇒ the sidebar is byte-identical to before" "$base_side" \
  "$(FLEET_SESSION=fleetP bash "$ROWS" --sidebar 2>/dev/null)"
eq "unpinning leaves no @pin option behind" "" \
  "$(opt "$W_pA")$(opt "$W_pB")$(opt "$W_cA")$(opt "$W_cB")$(opt "$W_gA")"
# closing a pinned window takes its pin with it — the option lives on the window.
pin "$W_gA"; tmux kill-window -t "$W_gA" 2>/dev/null
out=$(rows)
not_contains "a reaped pinned window leaves no 📌 behind" "$out" "📌"
eq "… and the surviving rows keep their order" \
  "$(printf 'pA\ncA\npB\ncB')" "$(order "$out")"

printf 'dash-pin-selftest OK (%d checks)\n' "$CHECKS"
