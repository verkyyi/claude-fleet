#!/bin/bash
# backlog-subissue-nest-selftest.sh — the "nest sub-issues under their parent"
# backlog rail (issue #335).
#
# Workers file sub-issues (issue #332), so the backlog surfaces the parent→child
# link by rendering a child INDENTED under its parent row — the "this may overlap
# live parent work" cue. The nesting is cosmetic: a child keeps its own field1
# issue number (Enter still spawns it) and pre-spawn dedup stays the real
# collision authority. This drives the REAL bin/tmux-issues-rows.sh against
# fixture caches (issues + labels + a `parents` map) with a FAKE tmux — no server
# spawns, so it can't inherit a machine's ~/.tmux.conf and never hangs:
#   • NEST        a sub-issue renders under its parent, INDENTED (a ↳ marker), and
#                 keeps its bare issue number in field1 (still spawnable via Enter).
#   • PRE-ORDER   the row order is a DFS: parent, then its children (in priority-
#                 tier order), then the next top-level row — a grandchild sits
#                 directly under its own parent, double-indented.
#   • CROSS-MS    a child whose parent is in a DIFFERENT milestone does NOT nest
#                 (you can't nest under a row that isn't in the group) — top-level.
#   • FLAT        with NO parents cache the backlog renders flat (no ↳) in the
#                 historic tier→number order — issue #335 degrades cleanly.
#   • HIDDEN PARENT  a parent bound to a live worker is hidden; its child re-roots
#                 to the nearest VISIBLE ancestor (or goes top-level if none).
#
# No external tool deps (the reader shells out only to the fake tmux) — never SKIPs.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged + the rows).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-issues-rows.sh"
LIB="$BIN/fleet-lib.sh"
[ -f "$ROWS" ] || { printf 'selftest: %s not found\n' "$ROWS" >&2; exit 2; }
[ -f "$LIB" ]  || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/subnest-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- rows ---\n%s\n' "$2" >&2; exit 1; }

TAB=$'\t'; US=$'\x1f'; NEST='↳'
mkdir -p "$WORK/bin" "$WORK/.claude-dash"
C="$WORK/.claude-dash"

# --- fake tmux: `list-windows` prints the canned bindings file (empty ⇒ nothing
# bound); every other subcommand is a no-op. The reader reads ONLY list-windows,
# so this fully isolates it from a live tmux server (and thus from ~/.tmux.conf).
WINFILE="$WORK/windows"; : > "$WINFILE"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/bash
case "\${1:-}" in
  list-windows) cat "$WINFILE" 2>/dev/null ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/tmux"

# --- fixture issues (collector's cache: milestone<TAB>#num<TAB>assignee<TAB>title).
# #100 is a parent (p1) with children #101 (p2) and #102 (p0); #103 is a grandchild
# under #101 (p2). #200 is an unrelated top-level p0. #300 lives in a DIFFERENT
# milestone but points at #100 — it must NOT nest. '·' = unassigned.
seed_issues() {
  {
    printf 'Week 1%s#100%s·%sparent task\n'    "$TAB" "$TAB" "$TAB"
    printf 'Week 1%s#101%s·%schild A\n'        "$TAB" "$TAB" "$TAB"
    printf 'Week 1%s#102%s·%schild B\n'        "$TAB" "$TAB" "$TAB"
    printf 'Week 1%s#103%s·%sgrandchild\n'     "$TAB" "$TAB" "$TAB"
    printf 'Week 1%s#200%s·%sunrelated top\n'  "$TAB" "$TAB" "$TAB"
    printf 'Week 2%s#300%s·%scross-ms child\n' "$TAB" "$TAB" "$TAB"
  } > "$C/issues"
  {
    printf '100%spriority:p1\n' "$TAB"; printf '101%spriority:p2\n' "$TAB"
    printf '102%spriority:p0\n' "$TAB"; printf '103%spriority:p2\n' "$TAB"
    printf '200%spriority:p0\n' "$TAB"
  } > "$C/labels"
}
seed_parents() {
  { printf '101%s100\n' "$TAB"; printf '102%s100\n' "$TAB"
    printf '103%s101\n' "$TAB"; printf '300%s100\n' "$TAB"; } > "$C/parents"
}

# run the REAL reader with the fakes; FLEET_SESSION scopes the bindings filter.
rows() { PATH="$WORK/bin:$PATH" TMPDIR="$WORK" FLEET_SESSION="${2:-}" bash "$ROWS" "${1:-all}" 2>/dev/null; }
# field2 (display) of the row whose field1 == the issue number; empty if absent.
disp_of()  { printf '%s\n' "$1" | awk -F"$US" -v n="$2" '$1==n{print $2; exit}'; }
# the ordered issue numbers of the NON-header rows (headers carry an empty field1).
seq_of()   { printf '%s\n' "$1" | awk -F"$US" '$1 ~ /^[0-9]+$/{printf "%s ", $1}'; }
has_nest() { printf '%s' "$1" | grep -qF "$NEST"; }

# ============================ A: nest + pre-order ============================
seed_issues; seed_parents
outA="$(rows all)"

# NEST: children carry the ↳ marker; the parent + unrelated top-level do NOT.
has_nest "$(disp_of "$outA" 101)" || fail "A child #101 must render INDENTED (↳) under its parent" "$outA"
has_nest "$(disp_of "$outA" 102)" || fail "A child #102 must render INDENTED (↳) under its parent" "$outA"
has_nest "$(disp_of "$outA" 103)" || fail "A grandchild #103 must render INDENTED (↳)" "$outA"
has_nest "$(disp_of "$outA" 100)" && fail "A parent #100 must NOT be indented" "$(disp_of "$outA" 100)"
has_nest "$(disp_of "$outA" 200)" && fail "A unrelated top-level #200 must NOT be indented" "$(disp_of "$outA" 200)"

# SPAWNABLE: every child still owns its bare issue number in field1 (Enter → {1}).
[ "$(disp_of "$outA" 101)" ]      || fail "A child #101 must appear as its own field1 row (spawnable)" "$outA"
[ "$(disp_of "$outA" 103)" ]      || fail "A grandchild #103 must appear as its own field1 row (spawnable)" "$outA"

# PRE-ORDER (DFS): #200(p0) then the #100 subtree — #102(p0) before #101(p2),
# with #103 directly under #101 — then Week 2's #300. Parent precedes its kids;
# a grandchild sits immediately under its own parent.
seqA="$(seq_of "$outA")"
[ "$seqA" = "200 100 102 101 103 300 " ] \
  || fail "A row order must be a pre-order DFS (got: $seqA)" "$outA"

# CROSS-MS: #300 stays un-nested (its parent #100 is in Week 1, a DIFFERENT
# milestone) and carries 'Week 2' in its own milestone column; #100 carries 'Week 1'.
has_nest "$(disp_of "$outA" 300)" && fail "A cross-milestone #300 must NOT nest under a Week 1 parent" "$(disp_of "$outA" 300)"
printf '%s' "$(disp_of "$outA" 300)" | grep -qF 'Week 2' || fail "A #300 must show its 'Week 2' milestone in the column" "$outA"
printf '%s' "$(disp_of "$outA" 100)" | grep -qF 'Week 1' || fail "A #100 must show its 'Week 1' milestone in the column" "$outA"
# FLAT (issue #377): milestone grouping is gone — NO ' ▾ <name> (count) ' header
# rows. The ONLY empty-field1 line is the column-title header, whose field2 names
# the columns ('# … milestone title'), never a milestone VALUE like 'Week N'.
printf '%s\n' "$outA" | awk -F"$US" '$1=="" && $2 ~ /Week [0-9]/{found=1} END{exit !found}' \
  && fail "A milestone grouping dropped — there must be NO ' ▾ Week N ' group-header rows" "$outA"
ok "A sub-issues nest under their parent (↳), pre-order DFS, cross-ms stays top-level w/ its own milestone column, still spawnable"

# ============================ B: flat degrade (no parents) ==================
seed_issues; rm -f "$C/parents"
outB="$(rows all)"
printf '%s' "$outB" | grep -qF "$NEST" && fail "B with NO parents cache the backlog must render FLAT (no ↳)" "$outB"
# historic tier→number order within Week 1 (issue #235): p0 #102,#200 · p1 #100 · p2 #101,#103.
seqB="$(seq_of "$outB")"
[ "$seqB" = "102 200 100 101 103 300 " ] \
  || fail "B flat order must be tier→number (got: $seqB)" "$outB"
ok "B absent parents cache ⇒ flat backlog in the historic tier→number order"

# ============================ C: hidden (bound) parent ======================
# Bind #100 to a live worker in session 't' → it hides by default; #101 re-roots to
# top-level (its parent is gone) while #103 nests under the now-visible #101.
seed_issues; seed_parents
printf 't%s100%swrk\n' "$TAB" "$TAB" > "$WINFILE"
outC="$(rows all t)"
: > "$WINFILE"                                   # reset bindings for any later run
printf '%s\n' "$outC" | grep -qF 'parent task' && fail "C bound parent #100 must be HIDDEN by default" "$outC"
[ "$(disp_of "$outC" 101)" ]      || fail "C child #101 must still be listed when its parent is hidden" "$outC"
has_nest "$(disp_of "$outC" 101)" && fail "C child #101 must go TOP-LEVEL when its parent is hidden (no ↳)" "$(disp_of "$outC" 101)"
has_nest "$(disp_of "$outC" 103)" || fail "C grandchild #103 must re-root and nest under the visible #101 (↳)" "$(disp_of "$outC" 103)"
seqC="$(seq_of "$outC")"
[ "$seqC" = "102 200 101 103 300 " ] \
  || fail "C order with #100 hidden must be 102 200 101 103 300 (got: $seqC)" "$outC"
ok "C a hidden (bound) parent re-roots its subtree to the nearest visible ancestor"

printf '\nselftest PASS: backlog nests sub-issues under their parent (↳ pre-order DFS), keeps them spawnable, and degrades flat when the parents cache / parent row is absent (%s assertions)\n' "$pass"
exit 0
