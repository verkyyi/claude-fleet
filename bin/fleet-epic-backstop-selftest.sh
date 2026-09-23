#!/bin/bash
# fleet-epic-backstop-selftest.sh — the step-2a backstop gate (issue #921).
#
# Pinned: a READY PR whose worker is mid-turn (working / looping / waking) or
# still owns a Bash-tool job (fleet_child_busy → bg) is SKIPPED with the literal
# tick-log line `backstop skipped: child busy`; an idle, gone, or ship-reported
# worker is CLEAR. `pr-open` / `pr-unknown` never hold a merge (the PR is open by
# construction). Pure: `--children-json` fixtures + the busy-cmd seam, no tmux, no gh.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
GATE="$BIN/fleet-epic-backstop.sh"
[ -f "$GATE" ] || { printf 'selftest: %s missing\n' "$GATE" >&2; exit 2; }

CHECKS=0
fail() { printf 'fleet-epic-backstop selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()   { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1" "expected: [$2]"$'\n'"got:      [$3]"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-epic-backstop.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
J="$WORK/children.json"
cat > "$J" <<'JSON'
{"parent":"scratch-9","session":"s","seq":5,"summary":{},"children":[
 {"child":"issue-1","bucket":"▸","live":true,"window":"@1","state":"working","pr":"11","last":null},
 {"child":"issue-2","bucket":"▸","live":true,"window":"@2","state":"looping","pr":"12","last":{"state":"WAITING"}},
 {"child":"issue-3","bucket":"✓","live":true,"window":"@3","state":"done","pr":"13","last":{"state":"WAITING"}},
 {"child":"issue-4","bucket":"✓","live":true,"window":"@4","state":"done","pr":"14","last":null},
 {"child":"issue-5","bucket":"–","live":false,"window":"","state":"gone","pr":"15","last":{"state":"REAPED"}},
 {"child":"issue-6","bucket":"✓","live":true,"window":"@6","state":"working","pr":"16","last":{"state":"MERGED"}},
 {"child":"issue-7","bucket":"✓","live":true,"window":"@7","state":"waking","pr":"17","last":null},
 {"child":"issue-8","bucket":"✓","live":true,"window":"@8","state":"idle","pr":"18","last":null}
]}
JSON
# The busy seam: @4 still owns a background job, @8's reason is only pr-open.
cat > "$WORK/busy" <<'SH'
#!/bin/sh
case "$2" in @4) echo bg ;; @8) echo pr-open ;; *) exit 1 ;; esac
SH
chmod +x "$WORK/busy"
export FLEET_EPIC_BACKSTOP_BUSY_CMD="$WORK/busy"

run() { out=$(bash "$GATE" --children-json "$J" "$@" 2>&1); rc=$?; }

run issue-1;  eq "working → skip (rc)" 1 "$rc"; eq "working → the tick-log line" 'backstop skipped: child busy (issue-1 working)' "$out"
run issue-2;  eq "looping (the #875 case) → skip" 'backstop skipped: child busy (issue-2 looping)' "$out"
run issue-7;  eq "waking → skip" 'backstop skipped: child busy (issue-7 waking)' "$out"
run issue-4;  eq "turn over but a bg job → skip" 'backstop skipped: child busy (issue-4 bg job)' "$out"; eq "bg → rc 1" 1 "$rc"
run issue-3;  eq "done, no bg → clear" 0 "$rc"; eq "…and says why" 'clear: issue-3 done' "$out"
run issue-8;  eq "pr-open alone never holds a READY merge" 0 "$rc"
run issue-5;  eq "window gone → clear" 'clear: issue-5 no live window' "$out"
run issue-6;  eq "own ship report beats a stuck working state" 0 "$rc"; eq "…named" 'clear: issue-6 ship report MERGED' "$out"
run issue-99; eq "not in the ledger → clear" 0 "$rc"
run issue-99 --pr '#12'; eq "--pr falls back to the ledger row by PR" 'backstop skipped: child busy (issue-99 looping)' "$out"
out=$(bash "$GATE" 2>&1); eq "no child key → usage" 2 "$?"
out=$(bash "$GATE" --bogus issue-1 2>&1); eq "unknown flag → usage" 2 "$?"
printf 'not json' > "$WORK/bad.json"
out=$(bash "$GATE" --children-json "$WORK/bad.json" issue-1 2>&1); eq "unreadable ledger read → clear (the pre-#921 behaviour)" 0 "$?"

printf 'fleet-epic-backstop selftest: OK (%d checks)\n' "$CHECKS"
