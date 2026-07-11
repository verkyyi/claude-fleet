#!/bin/bash
# dash-land-selftest.sh — hermetic tests for the dash ⌃l "land a green PR from the
# dashboard" path (issue #232). Two surfaces:
#   1. bin/tmux-dashboard.sh binds ctrl-l → dash-land.sh, and dash-land.sh hands
#      off to fleet-land.sh (the no-LLM lander from #231) — asserted structurally.
#   2. bin/dash-land.sh gates on the prmap `ready` verdict (issue #187): it lands
#      an OPEN + CI-green + ready|behind PR (calling a FAKE fleet-land.sh with the
#      right PR number and surfacing its result token), and REFUSES anything else
#      (ci ✗ / conflict / blocked / mergeability-unknown / merged / no PR) WITHOUT
#      ever invoking the lander.
#
# No network, no real repo, no tmux server: dash-land.sh + fleet-lib.sh are
# symlinked into a temp bin, a FAKE fleet-land.sh logs its args + echoes a token,
# and a hand-written prmap cache stands in for pr-refresh's output. dash-land.sh
# is driven with a BARE ISSUE NUMBER (its scriptable arg form) so no tmux is
# needed — the branch resolves to issue-<N> and matches the fake prmap directly.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LAND="$BIN/dash-land.sh"
LIB="$BIN/fleet-lib.sh"
DASH="$BIN/tmux-dashboard.sh"
KEYS="$BIN/fleet-keys.sh"
for f in "$LAND" "$LIB" "$DASH" "$KEYS"; do
  [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-land-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/main" "$WORK/tmp/.claude-dash"
LAND_LOG="$WORK/landlog"

ln -s "$LAND" "$WORK/bin/dash-land.sh"
ln -s "$LIB"  "$WORK/bin/fleet-lib.sh"

# --- FAKE fleet-land.sh: log the args, echo the (env-tunable) result token ------
cat > "$WORK/bin/fleet-land.sh" <<'FAKELAND'
#!/bin/bash
printf 'FLEETLAND %s\n' "$*" >> "$LAND_LOG"
printf '%s\n' "${LAND_TOKEN:-landed:deadbeef}"
FAKELAND
chmod +x "$WORK/bin/fleet-land.sh"

# --- hand-written prmap (branch<TAB>#num<TAB>state<TAB>ci<TAB>ready) ------------
# No sessmap exists in the temp cache, so fleet_cache's slug lookup returns empty
# and it reads the flat fallback $TMPDIR/.claude-dash/prmap — exactly this file.
{
  printf 'issue-7\t#42\tOPEN\t\xe2\x9c\x93\tready\n'      # green + ready     → LAND
  printf 'issue-8\t#43\tOPEN\t\xe2\x9c\x93\tbehind\n'     # green + behind    → LAND (update-branch)
  printf 'issue-9\t#44\tOPEN\t\xe2\x9c\x97\t\n'           # CI failing        → refuse
  printf 'issue-10\t#45\tOPEN\t\xe2\x9c\x93\tconflict\n'  # green + conflict  → refuse
  printf 'issue-11\t#46\tOPEN\t\xe2\x9c\x93\tblocked\n'   # green + blocked   → refuse
  printf 'issue-12\t#47\tOPEN\t\xe2\x9c\x93\t\n'          # green, ready unknown → refuse
  printf 'issue-13\t#48\tMERGED\t\xe2\x9c\x93\t\n'        # already merged    → refuse
} > "$WORK/tmp/.claude-dash/prmap"

# run dash-land.sh with a bare issue number. FLEET_SESSION is preset so no tmux
# call is made; FLEET_REPO/MAIN make the fleet resolve without a conf file.
run_land() {   # $1 = issue number ; env LAND_TOKEN tunes the fake's token
  : > "$LAND_LOG"
  TMPDIR="$WORK/tmp" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_SESSION=testsess FLEET_REPO=acme/widgets FLEET_MAIN="$WORK/main" \
  LAND_LOG="$LAND_LOG" LAND_TOKEN="${LAND_TOKEN:-landed:deadbeef}" \
    bash "$WORK/bin/dash-land.sh" "$1" >"$WORK/out" 2>"$WORK/err"
}
landed_pr() { grep -oE 'FLEETLAND [0-9]+' "$LAND_LOG" | awk '{print $2}'; }

# ============================ A: bind wiring ================================
grep -Eq -- '--bind "ctrl-l:.*dash-land\.sh \{1\}' "$DASH" \
  || fail "A tmux-dashboard.sh has no ctrl-l bind routing to dash-land.sh {1}" "$(grep -n ctrl-l "$DASH")"
grep -Eq -- 'display-popup .*dash-land\.sh' "$DASH" \
  || fail "A the ctrl-l bind should open dash-land.sh in a display-popup" "$(grep -n ctrl-l "$DASH")"
grep -q 'bin/fleet-land.sh' "$LAND" \
  || fail "A dash-land.sh does not hand off to fleet-land.sh"
grep -q '⌃l land' "$DASH" || fail "A the dash header (HDR) does not advertise ⌃l land"
# Capture the sheet first (pipe-free match) — `... | grep -q` can SIGPIPE the
# producer under `pipefail` when grep closes the pipe on its first match.
SHEET="$(NO_COLOR=1 bash "$KEYS" --plain)" || fail "A fleet-keys.sh --plain exited non-zero"
case "$SHEET" in *⌃l*) ;; *) fail "A the ⌃l cheatsheet row is missing from fleet-keys.sh" "$SHEET" ;; esac
ok "A ⌃l bind → dash-land.sh → fleet-land.sh is wired; header + cheatsheet document it"

# ============================ B: lands a green (ready) row ==================
LAND_TOKEN='landed:abc123' run_land 7
[ "$(landed_pr)" = 42 ] || fail "B a green+ready row should call fleet-land.sh with PR 42" "$(cat "$LAND_LOG" "$WORK/out")"
grep -q 'landed:abc123' "$WORK/out" || fail "B the landed: token should be surfaced in the popup" "$(cat "$WORK/out")"
ok "B green+ready row lands: fleet-land.sh 42 invoked, token surfaced"

# ============================ C: lands a green (behind) row =================
# behind IS landable — fleet-land.sh update-branches it while holding the lease.
run_land 8
[ "$(landed_pr)" = 43 ] || fail "C a green+behind row should call fleet-land.sh with PR 43" "$(cat "$LAND_LOG" "$WORK/out")"
ok "C green+behind row lands (fleet-land.sh 43 invoked)"

# ============================ D: refuses CI-failing =========================
run_land 9
[ -s "$LAND_LOG" ] && fail "D a CI-failing row must NOT invoke fleet-land.sh" "$(cat "$LAND_LOG")"
grep -qi 'not CI-green' "$WORK/out" || fail "D a CI-failing row should refuse with a reason" "$(cat "$WORK/out")"
ok "D CI-failing row refused, lander not called"

# ============================ E: refuses conflict ===========================
run_land 10
[ -s "$LAND_LOG" ] && fail "E a conflicting row must NOT invoke fleet-land.sh" "$(cat "$LAND_LOG")"
grep -qi 'conflict' "$WORK/out" || fail "E a conflicting row should refuse with a reason" "$(cat "$WORK/out")"
ok "E conflicting row refused, lander not called"

# ============================ F: refuses blocked ============================
run_land 11
[ -s "$LAND_LOG" ] && fail "F a blocked row must NOT invoke fleet-land.sh" "$(cat "$LAND_LOG")"
grep -qi 'blocked' "$WORK/out" || fail "F a blocked row should refuse with a reason" "$(cat "$WORK/out")"
ok "F blocked row refused, lander not called"

# ============================ G: refuses ready-unknown ======================
# green but mergeability not yet computed (ready="") — the #187 trap: NOT landable.
run_land 12
[ -s "$LAND_LOG" ] && fail "G a mergeability-unknown row must NOT invoke fleet-land.sh" "$(cat "$LAND_LOG")"
grep -qi "isn't computed" "$WORK/out" || fail "G ready-unknown should refuse (mergeability not computed)" "$(cat "$WORK/out")"
ok "G green-but-mergeability-unknown row refused (issue #187 gate), lander not called"

# ============================ H: refuses already-merged =====================
run_land 13
[ -s "$LAND_LOG" ] && fail "H an already-merged row must NOT invoke fleet-land.sh" "$(cat "$LAND_LOG")"
grep -qi 'already merged' "$WORK/out" || fail "H a merged row should refuse with a reason" "$(cat "$WORK/out")"
ok "H already-merged row refused, lander not called"

# ============================ I: refuses no-PR row ==========================
run_land 99   # no issue-99 line in the prmap
[ -s "$LAND_LOG" ] && fail "I a row with no PR must NOT invoke fleet-land.sh" "$(cat "$LAND_LOG")"
grep -qi 'no open PR' "$WORK/out" || fail "I a row with no PR should refuse clearly" "$(cat "$WORK/out")"
ok "I row with no open PR refused, lander not called"

printf '\nselftest OK: %s assertions passed (dash ⌃l land-a-green-PR, #232)\n' "$pass"
exit 0
