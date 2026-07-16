#!/bin/bash
# backlog-preflight-selftest.sh — the backlog renders every issue state WITHOUT
# the owner column (issue #389) + the "slots N/8" chip (issue #331).
#
# Issue #389 dropped the backlog's owner column, and with it the pre-flight
# "will-refuse" cues it carried: the ◦ foreign-claim marker + assignee, the ⇡
# in-flight marker + PR number (from the prmap cache), and the ▶ live-worker
# marker. This drives the REAL bin/tmux-issues-rows.sh against a REAL isolated
# tmux server (own socket, torn down at exit) with fixture issues + a fixture
# prmap cache, and pins that NONE of those cues survive — plus it unit-tests
# fleet_slots_chip directly (that chip is unrelated to the column and stays):
#   • FREE          an unassigned issue with no PR renders plain (no marker glyph).
#   • CLAIMED       a foreign-assigned issue renders plain — NO ◦ marker, and its
#                   assignee name is no longer shown.
#   • IN-FLIGHT     an issue whose issue-<N> has an OPEN PR renders plain — NO ⇡
#                   marker and no PR number, even with a prmap hit.
#   • PR + CLAIM    assigned AND an open PR still renders plain — no marker, no
#                   assignee, no PR number.
#   • MERGED PR     a MERGED/closed issue-<N> PR renders plain (as it always did).
#   • HIDE-BOUND    a locally-bound row stays hidden by default (unchanged).
#   • COUNTS        milestone counts track the VISIBLE rows (the bound one hidden).
#   • SLOTS CHIP    fleet_slots_chip colors dim with headroom, orange at the last
#                   slot, red at/over the cap, and drops the denominator when the
#                   cap is disabled (gmax=0).
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-issues-rows.sh"
LIB="$BIN/fleet-lib.sh"
[ -f "$ROWS" ] || { printf 'selftest: %s not found\n' "$ROWS" >&2; exit 2; }
[ -f "$LIB" ]  || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/preflight-selftest.XXXXXX")" || exit 2

# Isolate every tmux call (rows reads @issue bindings via `tmux list-windows`)
# onto a private socket via a PATH shim so we never touch the user's live server.
# TMPDIR points the dash state dir ($C / FLEET_C) at our sandbox; with no sessmap
# fleet_cache falls back to the flat $C/issues + $C/prmap files we write below.
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
export TMPDIR="$WORK"
C="$WORK/.claude-dash"
mkdir -p "$C"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- rows ---\n%s\n' "$2" >&2; exit 1; }
TAB=$'\t'

# --- fixture issues (collector's $C/issues: milestone<TAB>#num<TAB>assignee<TAB>title)
# The assignee field is '·' for unassigned — the collector never writes it empty.
{
  printf 'Week 1%s#40%s·%salpha\n'     "$TAB" "$TAB" "$TAB"   # free
  printf 'Week 1%s#41%salice%sbravo\n' "$TAB" "$TAB" "$TAB"   # foreign claim
  printf 'Week 1%s#42%s·%scharlie\n'   "$TAB" "$TAB" "$TAB"   # locally bound → hidden
  printf 'Week 1%s#43%s·%sdelta\n'     "$TAB" "$TAB" "$TAB"   # open PR, no assignee
  printf 'Week 1%s#44%sbob%secho\n'    "$TAB" "$TAB" "$TAB"   # assigned + open PR
  printf 'Week 1%s#45%s·%sfoxtrot\n'   "$TAB" "$TAB" "$TAB"   # merged PR only → free
} > "$C/issues"

# --- fixture prmap (branch<TAB>#num<TAB>state<TAB>ci<TAB>ready) ---------------
{
  printf 'issue-43%s#500%sOPEN%s✓%sready\n' "$TAB" "$TAB" "$TAB" "$TAB"
  printf 'issue-44%s#501%sOPEN%s…%s\n'      "$TAB" "$TAB" "$TAB" "$TAB"
  printf 'issue-45%s#502%sMERGED%s✓%s\n'    "$TAB" "$TAB" "$TAB" "$TAB"
} > "$C/prmap"

# a fleet session "t" with a worker window bound to issue #42 (locally bound)
tmux new-session -d -s t -x 200 -y 50 2>/dev/null || fail "could not start isolated tmux server"
tmux rename-window -t t "wrk"
tmux set-option -w -t t:wrk @issue 42

rows() { FLEET_SESSION=t bash "$ROWS" "${1:-all}" 2>/dev/null; }
# field2 (colored display) of the row whose field1 == the issue number. Split on a
# LITERAL US byte — macOS awk doesn't interpret a '\x1f' escape in -F.
US=$'\x1f'
disp_of() { printf '%s\n' "$1" | awk -F"$US" -v n="$2" '$1==n{print $2; exit}'; }

out="$(rows all)"

# --- FREE: #40 plain — no claim/PR marker glyph -----------------------------
r40="$(disp_of "$out" 40)"
[ -n "$r40" ]                          || fail "free issue #40 should be listed" "$out"
printf '%s' "$r40" | grep -qF '◦'      && fail "free #40 must NOT carry a claim marker" "$r40"
printf '%s' "$r40" | grep -qF '⇡'      && fail "free #40 must NOT carry a PR marker" "$r40"

# --- CLAIMED: #41 renders plain — no ◦ marker, no assignee name (issue #389) --
r41="$(disp_of "$out" 41)"
[ -n "$r41" ]                          || fail "foreign-claim #41 should still be listed" "$out"
printf '%s' "$r41" | grep -qF '◦'      && fail "foreign-claim #41 must NOT carry a ◦ claim marker" "$r41"
printf '%s' "$r41" | grep -qF 'alice'  && fail "foreign-claim #41 must NOT show its assignee (owner column dropped)" "$r41"

# --- IN-FLIGHT: #43 renders plain — no ⇡ marker, no PR number (issue #389) ----
r43="$(disp_of "$out" 43)"
[ -n "$r43" ]                          || fail "open-PR #43 should still be listed" "$out"
printf '%s' "$r43" | grep -qF '⇡'      && fail "open-PR #43 must NOT carry a ⇡ PR marker (owner column dropped)" "$r43"
printf '%s' "$r43" | grep -qF '#500'   && fail "open-PR #43 must NOT surface the PR number" "$r43"

# --- PR + CLAIM: #44 assigned AND open PR still renders plain (issue #389) ----
r44="$(disp_of "$out" 44)"
[ -n "$r44" ]                          || fail "assigned+PR #44 should still be listed" "$out"
printf '%s' "$r44" | grep -qF '⇡'      && fail "assigned+PR #44 must NOT carry a ⇡ PR marker" "$r44"
printf '%s' "$r44" | grep -qF '◦'      && fail "assigned+PR #44 must NOT carry a ◦ claim marker" "$r44"
printf '%s' "$r44" | grep -qF '#501'   && fail "assigned+PR #44 must NOT surface the PR number" "$r44"
printf '%s' "$r44" | grep -qF 'bob'    && fail "assigned+PR #44 must NOT show its assignee" "$r44"

# --- MERGED PR: #45 renders plain, as it always did (issue #389) -------------
r45="$(disp_of "$out" 45)"
[ -n "$r45" ]                          || fail "merged-PR issue #45 should still be listed" "$out"
printf '%s' "$r45" | grep -qF '⇡'      && fail "merged-PR #45 must NOT carry a ⇡ marker" "$r45"
printf '%s' "$r45" | grep -qF '◦'      && fail "merged-PR #45 must NOT carry a ◦ marker" "$r45"

# --- HIDE-BOUND: #42 stays hidden by default (unchanged) --------------------
printf '%s\n' "$out" | grep -qF 'charlie' && fail "locally-bound #42 must remain HIDDEN by default"

# --- COUNTS: 5 rows visible (#40/#41/#43/#44/#45); the bound #42 is hidden -----
# Flat list (issue #377): no ' Week 1 (N) ' group header — tally the DATA rows
# (numeric field1) directly to count what's visible.
nvis=$(printf '%s\n' "$out" | awk -F"$US" '$1 ~ /^[0-9]+$/{n++} END{print n+0}')
[ "$nvis" = 5 ] \
  || fail "expected 5 visible (free+flagged) rows, got $nvis — bound #42 must stay hidden" "$out"

# --- SLOTS CHIP: fleet_slots_chip colors + denominator ----------------------
. "$LIB"
DIM='86;95;137'; ORANGE='224;175;104'; RED='247;118;142'
chip() { fleet_slots_chip "$@"; }

c3="$(FLEET_GLOBAL_MAX_SESSIONS=8 chip 3)"
printf '%s' "$c3" | grep -qF 'slots 3/8' || fail "chip should render 'slots 3/8' (n=3,max=8)"
printf '%s' "$c3" | grep -qF "$DIM"       || fail "chip with headroom (3/8) should be DIM"

c7="$(FLEET_GLOBAL_MAX_SESSIONS=8 chip 7)"
printf '%s' "$c7" | grep -qF 'slots 7/8' || fail "chip should render 'slots 7/8'"
printf '%s' "$c7" | grep -qF "$ORANGE"    || fail "chip at the LAST slot (7/8) should be ORANGE"

c8="$(FLEET_GLOBAL_MAX_SESSIONS=8 chip 8)"
printf '%s' "$c8" | grep -qF 'slots 8/8' || fail "chip should render 'slots 8/8'"
printf '%s' "$c8" | grep -qF "$RED"       || fail "chip AT the cap (8/8) should be RED"

c9="$(FLEET_GLOBAL_MAX_SESSIONS=8 chip 9)"
printf '%s' "$c9" | grep -qF "$RED"       || fail "chip OVER the cap (9/8) should be RED"

c0="$(FLEET_GLOBAL_MAX_SESSIONS=0 chip 5)"
printf '%s' "$c0" | grep -qF 'slots 5'   || fail "unlimited cap should render a bare 'slots 5'"
printf '%s' "$c0" | grep -qF '/'          && fail "unlimited cap must drop the denominator"
printf '%s' "$c0" | grep -qF "$DIM"       && fail "unlimited cap must not color the chip"

printf 'selftest PASS: backlog renders every issue state plain (no ◦/⇡/▶ owner cues, issue #389), keeps bound hidden, counts track; slots chip colors + degrades\n'
exit 0
