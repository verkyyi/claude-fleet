#!/bin/bash
# dash-arm-merge-selftest.sh — hermetic tests for the dash ⌃l "arm auto-merge from
# the dashboard" path (issue #277, replaces the retired dash-land ⌃l). Two surfaces:
#   1. bin/tmux-dashboard.sh binds ctrl-l → dash-arm-merge.sh, the header + the
#      fleet-keys cheatsheet advertise it — asserted structurally.
#   2. bin/dash-arm-merge.sh arms auto-merge (`gh pr merge --auto --squash`) on an
#      OPEN PR, surfaces a repo-has-auto-merge-disabled failure WITHOUT forcing,
#      and REFUSES a merged / closed / no-PR row without calling gh at all.
#
# No network, no real repo, no tmux server: dash-arm-merge.sh + fleet-lib.sh are
# symlinked into a temp bin, a FAKE gh logs its merge args (and can simulate the
# auto-merge-disabled error), and a hand-written prmap cache stands in for
# pr-refresh's output. Driven with a BARE ISSUE NUMBER (its scriptable arg form).
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ARM="$BIN/dash-arm-merge.sh"
LIB="$BIN/fleet-lib.sh"
DASH="$BIN/tmux-dashboard.sh"
KEYS="$BIN/fleet-keys.sh"
for f in "$ARM" "$LIB" "$DASH" "$KEYS"; do
  [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-arm-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/main" "$WORK/tmp/.claude-dash" "$WORK/fakepath"
MERGE_LOG="$WORK/mergelog"

ln -s "$ARM" "$WORK/bin/dash-arm-merge.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"

# --- FAKE gh: log `pr merge` args; simulate auto-merge-disabled with GH_MERGE_FAIL
cat > "$WORK/fakepath/gh" <<'FAKEGH'
#!/bin/bash
if [ "${1:-}" = pr ] && [ "${2:-}" = merge ]; then
  printf 'MERGE %s\n' "$*" >> "$MERGE_LOG"
  if [ "${GH_MERGE_FAIL:-0}" = 1 ]; then
    echo "GraphQL: Auto-merge is not allowed for this repository (enablePullRequestAutoMerge)"
    exit 1
  fi
  exit 0
fi
exit 0
FAKEGH
chmod +x "$WORK/fakepath/gh"

# --- hand-written prmap (branch<TAB>#num<TAB>state<TAB>ci<TAB>ready) ------------
{
  printf 'issue-7\t#42\tOPEN\t\xe2\x9c\x93\tready\n'    # open   → arm
  printf 'issue-8\t#43\tMERGED\t\xe2\x9c\x93\t\n'       # merged → refuse
  printf 'issue-9\t#44\tCLOSED\t\xc2\xb7\t\n'           # closed → refuse
} > "$WORK/tmp/.claude-dash/prmap"

run_arm() {   # $1 = issue number ; env GH_MERGE_FAIL tunes the fake
  : > "$MERGE_LOG"
  TMPDIR="$WORK/tmp" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_SESSION=testsess FLEET_REPO=acme/widgets FLEET_MAIN="$WORK/main" \
  MERGE_LOG="$MERGE_LOG" GH_MERGE_FAIL="${GH_MERGE_FAIL:-0}" \
  PATH="$WORK/fakepath:$PATH" \
    bash "$WORK/bin/dash-arm-merge.sh" "$1" >"$WORK/out" 2>"$WORK/err"
}
armed_pr() { grep -oE 'pr merge [0-9]+' "$MERGE_LOG" | awk '{print $3}'; }

# ============================ A: bind wiring ================================
grep -Eq -- '--bind "ctrl-l:.*dash-arm-merge\.sh \{1\}' "$DASH" \
  || fail "A tmux-dashboard.sh has no ctrl-l bind routing to dash-arm-merge.sh {1}" "$(grep -n ctrl-l "$DASH")"
grep -Eq -- 'display-popup .*dash-arm-merge\.sh' "$DASH" \
  || fail "A the ctrl-l bind should open dash-arm-merge.sh in a display-popup" "$(grep -n ctrl-l "$DASH")"
grep -q 'gh pr merge' "$ARM" \
  || fail "A dash-arm-merge.sh does not arm auto-merge via gh pr merge --auto"
grep -q '⌃l arm' "$DASH" || fail "A the dash header (HDR) does not advertise ⌃l arm"
SHEET="$(NO_COLOR=1 bash "$KEYS" --plain)" || fail "A fleet-keys.sh --plain exited non-zero"
case "$SHEET" in *⌃l*) ;; *) fail "A the ⌃l cheatsheet row is missing from fleet-keys.sh" "$SHEET" ;; esac
ok "A ⌃l bind → dash-arm-merge.sh → gh pr merge --auto is wired; header + cheatsheet document it"

# ============================ B: arms an OPEN PR ============================
run_arm 7
[ "$(armed_pr)" = 42 ] || fail "B an open row should arm PR 42 (gh pr merge --auto --squash 42)" "$(cat "$MERGE_LOG" "$WORK/out")"
grep -q -- '--auto' "$MERGE_LOG" || fail "B the arm must pass --auto (queue, not merge now)" "$(cat "$MERGE_LOG")"
grep -qi 'armed' "$WORK/out" || fail "B success should report 'auto-merge armed'" "$(cat "$WORK/out")"
ok "B open row arms: gh pr merge --auto --squash 42 invoked, success surfaced"

# ============================ C: auto-merge disabled → warn, never force =====
GH_MERGE_FAIL=1 run_arm 7
[ "$(armed_pr)" = 42 ] || fail "C should still ATTEMPT the arm on PR 42" "$(cat "$MERGE_LOG")"
grep -qi 'could not arm' "$WORK/out" || fail "C a disabled-auto-merge repo should warn, not crash" "$(cat "$WORK/out")"
grep -qi 'force' "$WORK/out" || fail "C the warning should reassure nothing was force-merged" "$(cat "$WORK/out")"
ok "C auto-merge-disabled → warns without forcing"

# ============================ D: refuses already-merged =====================
run_arm 8
[ -s "$MERGE_LOG" ] && fail "D an already-merged row must NOT call gh pr merge" "$(cat "$MERGE_LOG")"
grep -qi 'already merged' "$WORK/out" || fail "D a merged row should refuse with a reason" "$(cat "$WORK/out")"
ok "D already-merged row refused, gh not called"

# ============================ E: refuses closed ============================
run_arm 9
[ -s "$MERGE_LOG" ] && fail "E a closed row must NOT call gh pr merge" "$(cat "$MERGE_LOG")"
grep -qi 'closed' "$WORK/out" || fail "E a closed row should refuse with a reason" "$(cat "$WORK/out")"
ok "E closed row refused, gh not called"

# ============================ F: refuses no-PR row ==========================
run_arm 99   # no issue-99 line in the prmap
[ -s "$MERGE_LOG" ] && fail "F a row with no PR must NOT call gh pr merge" "$(cat "$MERGE_LOG")"
grep -qi 'no open PR' "$WORK/out" || fail "F a row with no PR should refuse clearly" "$(cat "$WORK/out")"
ok "F row with no open PR refused, gh not called"

printf '\nselftest OK: %s assertions passed (dash ⌃l arm-auto-merge, #277)\n' "$pass"
exit 0
