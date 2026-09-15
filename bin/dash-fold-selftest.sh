#!/bin/bash
# dash-fold-selftest.sh — the dash's ←/→ SUBTREE FOLD, end to end.
#
# A session spawned from another nests under it (#503) and the parent reports the
# block's progress (#624). Past a couple of parents that nesting is most of the
# list, so a subtree is now COLLAPSED BY DEFAULT and ←/→ open and shut it. The
# things worth proving are the ones that make a default-on fold SAFE — i.e. that
# nothing can end up hidden with no way back, and nothing loud can be hidden at all:
#
#   A. the renderer (bin/tmux-dashboard-rows.sh)
#      · default = folded: a fresh window, with no writer having touched it, hides
#        its children — the @expand polarity;
#      · a child in `needs` (the red `!`) is EXEMPT and stays on the list;
#      · an ORPHAN (parent window gone) is never hidden — there would be no row
#        left to unfold it from;
#      · every subtree the filter can hide has a caret-marked row above it: the
#        caret is drawn exactly where a fold is governed (the ultimate root), and
#        an intermediate parent — whose own bit governs nothing, because the
#        grouping is two-level-flat — draws none;
#      · the badge keeps counting the WHOLE subtree while it is shut (that is what
#        a folded block says out loud), and the right-pinned act/PR/ctx block does
#        not move when the caret appears (its width is a constant, not a ${#}).
#   B. the toggle (bin/dash-fold-toggle.sh)
#      · a non-empty query hands ←/→ BACK to the prompt line as cursor keys and
#        folds nothing — the dash's input row is always visible (#493);
#      · `→` opens the block the cursor's row owns, `←` shuts the block the cursor
#        is IN — from the parent, from a child, or from a grandchild (it walks to
#        the root, so `←` anywhere in a block shuts that block);
#      · unfolding writes `@expand 1`, folding UNSETS it (never parks a 0 — a shut
#        block must be byte-identical to one that was never opened);
#      · `sess:idx` and the #566 handle both address a row; header / landed /
#        absent targets are silent no-ops.
#
# Needs a real tmux, on an ISOLATED socket via the PATH shim (never the live
# server — see dash-marker-selftest.sh). tmux absent → SKIP cleanly. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
FOLD="$BIN/dash-fold-toggle.sh"
for f in "$ROWS" "$FOLD"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]" "$2";; esac; }
not_contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — output unexpectedly contains [$3]" "$2";; esac; }

REAL_TMUX="$(command -v tmux 2>/dev/null)"
if [ -z "$REAL_TMUX" ]; then
  printf 'dash-fold-selftest: tmux not installed — SKIPPED\n'; exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-fold-selftest.XXXXXX")" || exit 2
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"     # keep #566's @wid allocation lock in the sandbox
mkdir -p "$WORK/conf" "$WORK/bin"

SOCK="$WORK/tmux.sock"
cat > "$WORK/bin/tmux" <<EOS
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOS
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
  *) printf 'dash-fold-selftest: this tmux octal-escapes US in -F — SKIPPED\n'; exit 0 ;;
esac

# -c "$WORK" everywhere: a pane must never inherit the INVOKING cwd — run from a
# checkout whose dir name ends `-scratch-<N>` the window would key as that scratch.
tmux new-session -d -s fleetF -x 220 -y 50 -c "$WORK" 'sleep 300' \
  || fail "could not start the 'fleetF' session"
mk_win() { # <name> [issue] [origin] [state] → window id
  local n="$1" iss="${2:-}" org="${3:-}" st="${4:-}" wid
  wid=$(tmux new-window -d -P -F '#{window_id}' -t fleetF: -n "$n" -c "$WORK" 'sleep 300')
  [ -n "$iss" ] && tmux set-window-option -t "$wid" @issue "$iss"
  [ -n "$org" ] && tmux set-window-option -t "$wid" @origin "$org"
  [ -n "$st"  ] && tmux set-window-option -t "$wid" @claude_state "$st"
  printf '%s' "$wid"
}
# root ─ kid ─ grand      the three-deep chain (root owns the fold for all of it)
#      └ red              a `needs` child — the fold exemption
# lonely                  a childless root — must never grow a caret
# orph                    @origin names a window that is gone — never hidden
W_root=$(mk_win root  100 ''          'idle')
W_kid=$(mk_win  kid   101 issue-100   'done')
W_grand=$(mk_win grand 102 issue-101  'done')
mk_win          red   103 issue-100   'needs'  >/dev/null   # referenced by NAME, not id
W_lone=$(mk_win lonely 200 ''         'idle')
W_orph=$(mk_win orph   300 issue-999  'done')

strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
raw()  { FLEET_SESSION=fleetF FZF_COLUMNS=180 bash "$ROWS" 2>/dev/null; }
# rows → the rendered DISPLAY field only (field 3), colour-stripped: field1/2 are
# targets whose own widths would pollute any column/length assertion below.
rows() { raw | awk -F"$US" 'NR>1 {print $3}' | strip; }
NAMES='root kid grand red lonely orph'
order() { printf '%s\n' "$1" | awk -v ns=" $NAMES " '{for(i=1;i<=NF;i++) if(index(ns," "$i" ")){print $i; break}}'; }
row_of() { printf '%s\n' "$2" | awk -v n="$1" '{for(i=1;i<=NF;i++) if($i==n){print; exit}}'; }
line_of() { printf '%s\n' "$2" | awk -v n="$1" '{for(i=1;i<=NF;i++) if($i==n){print NR; exit}}'; }
opt() { tmux show-options -wqv -t "$1" @expand 2>/dev/null; }
idx_of() { tmux display-message -p -t "$1" 'fleetF:#{window_index}' 2>/dev/null; }

# ============================================================================
# A. the renderer — default folded, and what refuses to fold
# ============================================================================
out=$(rows)
[ -n "$out" ] || fail "rows produced no output" "$(raw)"

# A1. DEFAULT IS FOLDED — nobody has written @expand, and the quiet children are
#     already gone. This is the polarity the whole feature rests on.
eq "no @expand was written by merely rendering" "" "$(opt "$W_root")$(opt "$W_kid")"
not_contains "default: a quiet child is folded away" "$out" "└ kid"
not_contains "default: a quiet grandchild is folded away" "$out" "grand"

# A2. the loud layer never folds — a `needs` child stays, indent intact. The
#     exemption is on the RANK, not the glyph, so it covers all three reflexes
#     #640 split the red row into (`?` question · `⊘` permission · `!` plain) —
#     the two that carry a subtype are exactly the ones you must not lose.
contains "a child in needs is EXEMPT from the fold" "$out" "└ red"
for sub in ask perm; do
  tmux set-window-option -t "fleetF:$(tmux list-windows -t fleetF -F '#{window_index} #{window_name}' | awk '$2=="red"{print $1}')" @claude_needs "$sub"
  contains "a needs child with the '$sub' subtype is exempt too" "$(rows)" "└ red"
done
tmux set-window-option -t "fleetF:$(tmux list-windows -t fleetF -F '#{window_index} #{window_name}' | awk '$2=="red"{print $1}')" -u @claude_needs
out=$(rows)

# A3. an orphan has no parent row to unfold it from, so it is never hidden.
contains "an orphan is never folded away" "$out" "orph"
contains "… and keeps its ↳ provenance tag" "$(row_of orph "$out")" "↳#999"

eq "folded list: roots, the red child, the orphan — nothing else" \
  "$(printf 'root\nred\nlonely\norph')" "$(order "$out")"

# A4. the caret marks exactly where a fold is governed.
contains "a folded parent is marked ▸" "$(row_of root "$out")" "▸"
not_contains "a childless root grows no caret" "$(row_of lonely "$out")" "▸"
not_contains "… and no ▾ either" "$(row_of lonely "$out")" "▾"
not_contains "an orphan grows no caret" "$(row_of orph "$out")" "▸"

# A5. the badge still describes the WHOLE subtree while it is shut — that is what
#     makes folding by default safe: the parent row speaks for the block.
contains "a folded parent still counts its whole subtree" "$(row_of root "$out")" "2/3 ✓"
contains "… and still says one of them is asking for you" "$(row_of root "$out")" "1!"

# ============================================================================
# A6. unfolding
# ============================================================================
tmux set-window-option -t "$W_root" @expand 1
out=$(rows)
eq "unfolded: the whole block is back, in #503 order" \
  "$(printf 'root\nred\nkid\ngrand\nlonely\norph')" "$(order "$out")"
contains "an unfolded parent is marked ▾" "$(row_of root "$out")" "▾"
not_contains "… and no longer ▸" "$(row_of root "$out")" "▸"
contains "a restored child keeps its └ indent" "$out" "└ kid"
contains "a restored grandchild keeps its └ indent" "$out" "└ grand"
# the grouping is two-level-flat: `kid` owns no fold of its own, so it draws no
# caret — otherwise the operator would press → on it and nothing would happen.
not_contains "an intermediate parent draws no caret" "$(row_of kid "$out")" "▸"
not_contains "… not even an open one" "$(row_of kid "$out")" "▾"
eq "the badge is unchanged by unfolding" \
  "$(printf '%s' "$(row_of root "$out")" | grep -c '2/3 ✓')" "1"

# A7. the caret must not shove the right-pinned act/PR/ctx block over. Its width
#     is a CONSTANT 2 (glyph + space), never a ${#} count — ▸/▾ are East-Asian
#     AMBIGUOUS width. Both rows are ASCII-named, so display width == length here.
r_open=$(row_of root "$out")
r_lone=$(row_of lonely "$out")
eq "a caret row is the same total width as a caret-less one" "${#r_lone}" "${#r_open}"
tmux set-window-option -t "$W_root" -u @expand
out=$(rows); r_shut=$(row_of root "$out")
eq "folding does not change the row's width either" "${#r_shut}" "${#r_open}"

# A8. the fold composes with the #623 pin: a pin RE-SORTS a block, it never
#     unfolds one.
tmux set-window-option -t "$W_root" @pin 1
out=$(rows)
eq "a pinned FOLDED parent floats with nothing but its exempt child" \
  "$(printf 'root\nred\nlonely\norph')" "$(order "$out")"
contains "the pinned row is still marked 📌" "$(row_of root "$out")" "📌"
contains "… and still marked folded" "$(row_of root "$out")" "▸"
tmux set-window-option -t "$W_root" -u @pin

# ============================================================================
# B. the toggle
# ============================================================================
# B1. typing wins: with a query on the prompt line the arrows are cursor keys and
#     nothing folds. (The dash's input row is always visible, #493.)
eq "query non-empty: → is forward-char"  "forward-char"  "$(bash "$FOLD" expand   "$(idx_of "$W_root")" 'my scratch')"
eq "query non-empty: ← is backward-char" "backward-char" "$(bash "$FOLD" collapse "$(idx_of "$W_root")" 'my scratch')"
eq "… and neither of them wrote @expand" "" "$(opt "$W_root")"

# B2. → opens the block the row owns.
act=$(bash "$FOLD" expand "$(idx_of "$W_root")" '')
eq "→ on a folded parent writes @expand=1" "1" "$(opt "$W_root")"
contains "… and asks fzf to repaint" "$act" "reload("
eq "→ again is a no-op (already open)" "" "$(bash "$FOLD" expand "$(idx_of "$W_root")" '')"

# B3. ← shuts it, and UNSETS rather than parking a 0 — no residue.
act=$(bash "$FOLD" collapse "$(idx_of "$W_root")" '')
eq "← on an open parent unsets @expand" "" "$(opt "$W_root")"
contains "… and asks fzf to repaint" "$act" "reload("
eq "← again is a no-op (already shut)" "" "$(bash "$FOLD" collapse "$(idx_of "$W_root")" '')"

# B4. ← from INSIDE the block shuts that block and moves the cursor to the parent
#     that swallowed the row — from a child AND from a grandchild (a 2-hop walk).
#
# What is actually pinned is the INVARIANT, not the shape of the action: the index
# fzf is told to jump to must be the parent's row in the very list fzf is told to
# load. And that list must be the snapshot the helper ALREADY rendered — pointing
# fzf back at the producer would make this the one keystroke that renders twice,
# which is the whole of issue #662 creeping back in.
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
  # +1: fzf consumes the producer's first line as --header-lines=1, so item N is
  # line N+1 of the file.
  got=$(awk -F"$US" -v n=$(( idx + 1 )) 'NR==n {print $1; exit}' "$path")
  [ "$got" = "$want" ] || fail "$label — pos($idx) lands on [$got], not the parent [$want]" "$(cat "$path")"
  CHECKS=$((CHECKS+1))
}

for inner in "$W_kid" "$W_grand"; do
  nm=$(tmux display-message -p -t "$inner" '#{window_name}')
  tmux set-window-option -t "$W_root" @expand 1
  act=$(bash "$FOLD" collapse "$(idx_of "$inner")" '')
  eq "← from '$nm' shuts the block it is in" "" "$(opt "$W_root")"
  assert_cursor_lands_on_parent "$act" "$(idx_of "$W_root")" "← from '$nm'"
done

# B4b. …but only when the snapshot path is safe to splice into an fzf action.
#      An action's argument ends at the matching `)` and its command is split on
#      whitespace, so a path holding a space or a paren has to fall back to the
#      plain reload — an extra render, never a truncated action or a `cat` reading
#      two files. Driven through TMPDIR, which is what FLEET_C derives from.
mkdir -p "$WORK/with space"
tmux set-window-option -t "$W_root" @expand 1
act=$(TMPDIR="$WORK/with space" bash "$FOLD" collapse "$(idx_of "$W_kid")" '')
eq "a space in the snapshot path falls back to the plain reload"   "reload(bash $ROWS)" "$act"
eq "… and the fold itself still happened" "" "$(opt "$W_root")"

# B5. → from inside a block is a no-op: the row is only on screen because its
#     block is already open, and folding something else under the cursor would be
#     a surprise.
tmux set-window-option -t "$W_root" @expand 1
eq "→ on a child does nothing" "" "$(bash "$FOLD" expand "$(idx_of "$W_kid")" '')"
eq "… and left the block open" "1" "$(opt "$W_root")"
tmux set-window-option -t "$W_root" -u @expand

# B6. a childless row and an orphan have no block to fold.
eq "→ on a childless root does nothing" "" "$(bash "$FOLD" expand "$(idx_of "$W_lone")" '')"
eq "… and wrote nothing" "" "$(opt "$W_lone")"
eq "← on an orphan does nothing" "" "$(bash "$FOLD" collapse "$(idx_of "$W_orph")" '')"
eq "… and wrote nothing" "" "$(opt "$W_orph")"

# B7. the #566 handle addresses a row just like `sess:idx` does.
raw >/dev/null   # the producer backfills @wid on render
hnd=$(tmux show-options -wqv -t "$W_root" @wid 2>/dev/null)
if [ -n "$hnd" ]; then
  bash "$FOLD" expand "$hnd" '' >/dev/null
  eq "handle target ($hnd) opens the block" "1" "$(opt "$W_root")"
  bash "$FOLD" collapse "$hnd" '' >/dev/null
  eq "handle target shuts it again" "" "$(opt "$W_root")"
else
  printf 'dash-fold-selftest: no @wid backfilled — handle case skipped\n' >&2
fi

# B8. header / landed / absent / empty targets: silent, and they fold nothing.
for t in '' hdr 'fleetF:9999'; do
  outp=$(bash "$FOLD" collapse "$t" '' 2>&1); rc=$?
  eq "no-op target [$t] exits 0" "0" "$rc"
  eq "no-op target [$t] prints nothing" "" "$outp"
done
eq "a no-op target folded nothing" "" "$(opt "$W_root")$(opt "$W_lone")"

printf 'dash-fold-selftest OK (%d checks)\n' "$CHECKS"
