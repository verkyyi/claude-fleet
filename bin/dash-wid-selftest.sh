#!/bin/bash
# dash-wid-selftest.sh — the per-fleet window handle `@wid` (issue #566).
#
# The contract under test, in the order the issue states it:
#   A. ALLOCATION POLICY (pure, no tmux) — fleet_wid_next takes the LOWEST free
#      handle, walks a1→a9→b1…, rejects garbage, and reports exhaustion.
#   B. ALLOCATION IS STATELESS + UNIQUE — against a REAL, isolated tmux server:
#      two windows never collide; reaping `a1` frees it for the next spawn (the
#      whole reason a handle can stay two characters forever); a stamp is
#      idempotent; a window that predates #566 is BACKFILLED exactly once by the
#      dash's row producer.
#   C. IT IS A WINDOW TARGET — fleet_wid_resolve finds a window by handle and
#      rejects an unknown one; fleet_wid_target passes a non-handle (`@id`, an
#      index, a name) straight through, so nothing that works today breaks.
#   D. IT SURVIVES RE-CREATION — a simulated migrate (close the window, open a
#      new one, run the re-stamp block) keeps the SAME handle; and when the
#      handle was taken in the gap, the replacement gets a different one rather
#      than two windows answering to `b3`. A /fleet-handoff cycle reuses the same
#      PANE, so the handle must survive `respawn-pane` untouched — asserted here
#      so a future change cannot silently break it.
#   E. THE ROW — the rendered dash row puts the handle in the leftmost `id`
#      column, and the `issue` column is issue-ONLY: `#<N>` for a worker, BLANK
#      for a scratch (the `~<N>` sigil moved out in #566; the landed view keeps
#      it, which dash-rows-scratch-id-selftest.sh pins).
#
# tmux is PATH-shimmed onto a private `-S` socket (never the live server, per the
# repo rail); every cache/config path lands under $WORK. No gh, gits or network.
# tmux absent → parts B/D/E SKIP cleanly; part A still runs. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
ROWS="$BIN/tmux-dashboard-rows.sh"
for f in "$LIB" "$ROWS"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dashwid-selftest.XXXXXX")" || exit 2
export TMPDIR="$WORK"                 # the dash cache ($C) lands in the sandbox
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"    # …and so does the allocation lock dir
mkdir -p "$WORK/conf" "$WORK/bin"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }
ok()   { CHECKS=$((CHECKS+1)); [ "$1" = 0 ] || fail "$2"; }
has()  { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1" "$2";; *) : ;; esac; }

# ============================================================================
# A. allocation policy — pure, no tmux, no server
# ============================================================================
# shellcheck source=/dev/null
. "$LIB"
for fn in fleet_wid_next fleet_wid_valid fleet_wid_taken fleet_wid_stamp \
          fleet_wid_resolve fleet_wid_target fleet_wid_used; do
  command -v "$fn" >/dev/null 2>&1 || fail "$fn not defined by fleet-lib.sh (issue #566)"
  CHECKS=$((CHECKS+1))
done

eq "next: nothing taken → a1"                a1 "$(fleet_wid_next '')"
eq "next: a1 taken → a2"                     a2 "$(fleet_wid_next 'a1')"
eq "next: LOWEST free, not next-after-max"   a2 "$(fleet_wid_next 'a1 a3 b7')"
eq "next: a1..a9 taken → rolls to b1"        b1 "$(fleet_wid_next 'a1 a2 a3 a4 a5 a6 a7 a8 a9')"
eq "next: newline-separated list parses"     a3 "$(printf 'a1\na2\n' | { read -r x; read -r y; fleet_wid_next "$x
$y"; })"
eq "next: blank lines (unstamped windows) are ignored" a1 "$(fleet_wid_next '

')"
# exhaustion: every one of the 234 handles taken → exit 1, print nothing
ALL=''; for L in {a..z}; do for D in {1..9}; do ALL="$ALL $L$D"; done; done
out=$(fleet_wid_next "$ALL"); rc=$?
CHECKS=$((CHECKS+1)); [ "$rc" != 0 ] || fail "next: all 234 taken must exit non-zero"
eq "next: all 234 taken prints nothing" "" "$out"
# …and the alphabet really is 234 wide (a1…z9), the count the design fixed on.
eq "alphabet: 26 letters x 9 digits = 234" 234 "$(printf '%s' "$ALL" | wc -w | tr -d ' ')"

fleet_wid_valid a1 && rc=0 || rc=1; ok "$rc" "valid: a1 is a handle"
fleet_wid_valid z9 && rc=0 || rc=1; ok "$rc" "valid: z9 is a handle"
for bad in a0 A1 aa 1a a10 '' '@5' 'a 1'; do
  CHECKS=$((CHECKS+1))
  fleet_wid_valid "$bad" && fail "valid: '$bad' must NOT be accepted as a handle"
done
fleet_wid_taken b3 'a1 b3 c2' && rc=0 || rc=1; ok "$rc" "taken: b3 is in the list"
fleet_wid_taken b3 'a1 c2'    && rc=1 || rc=0; ok "$rc" "taken: b3 is not in the list"

printf 'dash-wid-selftest: part A ok (%d checks)\n' "$CHECKS"

# ============================================================================
# B/C/D/E need a real tmux — SKIP cleanly when absent
# ============================================================================
REAL_TMUX="$(command -v tmux 2>/dev/null)"
if [ -z "$REAL_TMUX" ]; then
  printf 'dash-wid-selftest: tmux not installed — parts B/C/D/E SKIPPED, part A passed\n'
  rm -rf "$WORK"; exit 0
fi

# Isolated server via a PATH shim — never the live one (the repo rail).
SOCK="$WORK/tmux.sock"
cat > "$WORK/bin/tmux" <<SHIM
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
SHIM
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

SESS=fleetW
tmux new-session -d -s "$SESS" -x 200 -y 50 -c "$WORK" 'sleep 300' 2>/dev/null \
  || fail "could not start the isolated tmux server"

# The producer's US-separated -F output is unparseable on tmux builds that
# octal-escape 0x1f (the #208 trap) — part E only.
US=$(printf '\037')
tmux list-windows -t "$SESS" -F "a${US}b" >/dev/null 2>&1
probe_out=$(tmux list-windows -t "$SESS" -F "a${US}b" 2>/dev/null | od -An -tx1 | tr -d ' \n')
US_OK=0; case "$probe_out" in *611f62*) US_OK=1 ;; esac

mk() { # <name> [cwd] → window id
  tmux new-window -d -P -F '#{window_id}' -t "$SESS:" -n "$1" -c "${2:-$WORK}" 'sleep 300'
}
wid_of() { tmux display-message -p -t "$1" '#{@wid}' 2>/dev/null; }

# ============================================================================
# B. stateless allocation: lowest free, never a collision, freed on reap
# ============================================================================
# The initial window of the session is unstamped too — stamp it first so the
# handles below are predictable.
w0=$(tmux list-windows -t "$SESS" -F '#{window_id}' | head -n1)
eq "stamp: the first window gets a1" a1 "$(fleet_wid_stamp "$w0" "")"
w1=$(mk one); w2=$(mk two); w3=$(mk three)
eq "stamp: lowest free → a2" a2 "$(fleet_wid_stamp "$w1" "")"
eq "stamp: lowest free → a3" a3 "$(fleet_wid_stamp "$w2" "")"
eq "stamp: lowest free → a4" a4 "$(fleet_wid_stamp "$w3" "")"
eq "stamp: the option really landed on the window" a3 "$(wid_of "$w2")"
# idempotent: a window that already carries one keeps it, and allocates nothing.
eq "stamp: idempotent (same handle, no re-allocation)" a3 "$(fleet_wid_stamp "$w2" "")"
eq "stamp: … and the neighbour is untouched"          a4 "$(wid_of "$w3")"
# uniqueness across every live window
handles=$(tmux list-windows -a -F '#{@wid}' | grep -c .)
uniq_h=$(tmux list-windows -a -F '#{@wid}' | grep . | sort -u | wc -l | tr -d ' ')
eq "unique: no two live windows share a handle" "$handles" "$uniq_h" \
   "$(tmux list-windows -a -F '#{window_id} #{@wid}')"
# REUSE: reaping a2 frees it for the next spawn — this is what keeps a handle 2 chars.
tmux kill-window -t "$w1" 2>/dev/null
w4=$(mk four)
eq "reuse: the reaped a2 is handed to the next spawn" a2 "$(fleet_wid_stamp "$w4" "")"

printf 'dash-wid-selftest: part B ok (%d checks)\n' "$CHECKS"

# ============================================================================
# C. the handle is a window target
# ============================================================================
eq "resolve: a handle finds its window"    "$w2" "$(fleet_wid_resolve a3 '')"
eq "resolve: another one, another window"  "$w3" "$(fleet_wid_resolve a4 '')"
out=$(fleet_wid_resolve z9 ''); rc=$?
CHECKS=$((CHECKS+1)); [ "$rc" != 0 ] || fail "resolve: an UNKNOWN handle must exit non-zero"
eq "resolve: an unknown handle prints nothing" "" "$out"
out=$(fleet_wid_resolve 'not-a-handle' ''); rc=$?
CHECKS=$((CHECKS+1)); [ "$rc" != 0 ] || fail "resolve: garbage must exit non-zero"
# target(): handle → window_id; anything else passes straight through
eq "target: a handle resolves"                  "$w2"      "$(fleet_wid_target a3 '')"
eq "target: a tmux window-id passes through"    "$w3"      "$(fleet_wid_target "$w3" '')"
eq "target: an index passes through"            "2"        "$(fleet_wid_target 2 '')"
eq "target: sess:idx passes through"            "$SESS:2"  "$(fleet_wid_target "$SESS:2" '')"
eq "target: a window NAME passes through"       "three"    "$(fleet_wid_target three '')"
eq "target: an UNSTAMPED handle passes through" "z9"       "$(fleet_wid_target z9 '')"

printf 'dash-wid-selftest: part C ok (%d checks)\n' "$CHECKS"

# ============================================================================
# D. it survives re-creation (migrate) and a same-pane handoff cycle
# ============================================================================
# D1. a /fleet-handoff cycle reuses the SAME pane — nothing re-stamps, so the
#     handle must simply still be there afterwards.
before=$(wid_of "$w3")
tmux respawn-pane -k -t "$w3" 'sleep 300' 2>/dev/null
eq "handoff: a same-pane respawn keeps the handle" "$before" "$(wid_of "$w3")"

# D2. a migrate: read the handle, close the window, open a new one, re-stamp —
#     exactly fleet-migrate.sh's re-stamp block, which is the whole reason @wid
#     exists (21 windows were re-created in one night).
old_h=$(wid_of "$w3")
tmux kill-window -t "$w3" 2>/dev/null
nw=$(mk three)
eq "migrate: the replacement window keeps the SAME handle" "$old_h" \
   "$(fleet_wid_stamp "$nw" "" "$old_h")"
eq "migrate: … and it really landed"                       "$old_h" "$(wid_of "$nw")"
# static guard: the re-stamp block is actually IN fleet-migrate.sh (a future
# refactor that drops it would otherwise pass every dynamic check above).
CHECKS=$((CHECKS+1))
grep -q 'fleet_wid_stamp "$nw" "$SOCK" "$hnd"' "$BIN/fleet-migrate.sh" \
  || fail "fleet-migrate.sh no longer re-stamps @wid onto the re-created window"

# D3. the handle was CLAIMED in the gap → the replacement must NOT collide.
taken=$(wid_of "$w2")                 # a live window's handle
tmux kill-window -t "$nw" 2>/dev/null
nw2=$(mk three-again)
got=$(fleet_wid_stamp "$nw2" "" "$taken")
CHECKS=$((CHECKS+1))
[ "$got" != "$taken" ] || fail "migrate: a WANTED handle that is already live must not be re-issued (got '$got')"
eq "migrate: … it falls back to a free handle instead" "$got" "$(wid_of "$nw2")"
eq "migrate: … and the incumbent keeps its own"        "$taken" "$(wid_of "$w2")"

printf 'dash-wid-selftest: part D ok (%d checks)\n' "$CHECKS"

# ============================================================================
# E. the rendered row — handle in column 1, issue column is issue-ONLY
# ============================================================================
if [ "$US_OK" != 1 ]; then
  printf 'dash-wid-selftest: this tmux octal-escapes US in -F — part E SKIPPED\n'
  printf 'dash-wid-selftest: OK (%d checks)\n' "$CHECKS"
  exit 0
fi

mkdir -p "$WORK/wt/repo-issue-77" "$WORK/wt/repo-scratch-4" "$WORK/.claude-dash/global"
rw_w=$(mk worker-row  "$WORK/wt/repo-issue-77")
tmux set-window-option -t "$rw_w" @issue 77
rs_w=$(mk scratch-row "$WORK/wt/repo-scratch-4")
tmux set-window-option -t "$rs_w" @raw 1
tmux set-window-option -t "$rs_w" @worktree "$WORK/wt/repo-scratch-4"
# Deliberately UNSTAMPED — these two stand in for every window that predates
# #566; the producer must backfill them on the render.
CHECKS=$((CHECKS+1))
[ -z "$(wid_of "$rw_w")" ] && [ -z "$(wid_of "$rs_w")" ] \
  || fail "fixture: the two new rows must start with NO handle (to prove the backfill)"

GN=$'\033[38;2;158;206;106m'; GY=$'\033[38;2;86;95;137m'; IN=$'\033[38;2;187;154;247m'; R=$'\033[0m'
rows=$(FLEET_SESSION="$SESS" FZF_COLUMNS=140 bash "$ROWS" 2>&1) \
  || fail "rows producer exited non-zero" "$rows"

h_w=$(wid_of "$rw_w"); h_s=$(wid_of "$rs_w")
CHECKS=$((CHECKS+1))
{ [ -n "$h_w" ] && [ -n "$h_s" ]; } || fail "backfill: an unstamped window must get a handle on the render" "$rows"
CHECKS=$((CHECKS+1))
[ "$h_w" != "$h_s" ] || fail "backfill: two windows were backfilled to the SAME handle ($h_w)"

# backfill is EXACTLY once: a second render must not re-allocate.
rows2=$(FLEET_SESSION="$SESS" FZF_COLUMNS=140 bash "$ROWS" 2>&1) || fail "second render exited non-zero" "$rows2"
eq "backfill: the handle is stable across renders (worker)"  "$h_w" "$(wid_of "$rw_w")"
eq "backfill: the handle is stable across renders (scratch)" "$h_s" "$(wid_of "$rs_w")"

row_w=$(printf '%s\n' "$rows2" | grep -F "$US$rw_w$US")
row_s=$(printf '%s\n' "$rows2" | grep -F "$US$rs_w$US")
{ [ -n "$row_w" ] && [ -n "$row_s" ]; } || fail "rows: expected a row per fixture window" "$rows2"

# the id cell: muted grey, 3 wide (2-char handle + 1 pad), leftmost data column.
# Anchored on the colour escape + the exact cell, never a byte offset — the row's
# leading state glyph is multi-byte UTF-8 and a positional read miscounts under C.
has "row: the worker's handle is in a 3-wide muted id cell"  "$row_w" "${GY}${h_w} ${R}"
has "row: the scratch's handle is in a 3-wide muted id cell" "$row_s" "${GY}${h_s} ${R}"
# it sits FIRST: glyph, space, then the id cell.
has "row: the id cell is the leftmost data column" "$row_w" " ${GY}${h_w} ${R} "
# the header names it, before `issue`.
hdr=$(printf '%s\n' "$rows2" | grep -F "hdr${US}hdr")
has "header: an 'id' column precedes 'issue'" "$hdr" "id  issue"

# the issue column is ISSUE-ONLY now (#566): `#77` for the worker, BLANK for the
# scratch — the `~4` sigil moved out, its slot number still names the worktree.
has   "row: the worker's issue cell is GREEN #77"       "$row_w" "${GN}#77  ${R}"
has   "row: the scratch's issue cell is 5 blanks"       "$row_s" "${GN}     ${R}"
hasnt "row: the scratch no longer renders a ~N sigil"   "$row_s" "~4"
hasnt "row: … and never in indigo either"               "$row_s" "${IN}~4"

printf 'dash-wid-selftest: OK (%d checks)\n' "$CHECKS"
