#!/bin/bash
# fleet-epic-backstop-selftest.sh — the step-2a backstop gate (issue #921).
#
# Pinned: a READY PR whose worker is mid-turn (working / looping / waking) or
# still owns a Bash-tool job (fleet_child_busy → bg) is SKIPPED with the literal
# tick-log line `backstop skipped: child busy`; an idle, gone, or ship-reported
# worker is CLEAR. `pr-open` / `pr-unknown` never hold a merge (the PR is open by
# construction). Issue #1110: a member the ledger has no live window for is looked
# up — this fleet's windows (seam), then the hub's session table by (repo, issue) —
# and a lookup that cannot answer holds the merge. Pure: `--children-json`
# fixtures, the busy/find seams and a hand-written global/remote_<sess>; no tmux, no gh.
# Issue #1607: a member on another machine is judged by that machine's word — its
# `busy` column (a held /loop round, a Bash-tool job), a lost machine is unseen,
# and a hub that is off cannot clear a child the ledger places elsewhere.
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
# No window answers unless a case says so (#1110's local lookup), and nothing here
# reads a live tmux server or conf.
export FLEET_EPIC_BACKSTOP_FIND_CMD=false FLEET_CONF_DIR="$WORK/conf" TMPDIR="$WORK/tmp"
mkdir -p "$WORK/conf" "$WORK/tmp"

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


# --- issue #1110: find before calling it gone -----------------------------------
# The local lookup (seam): a member missing from the ledger — a keyless hub loop
# spawned it, or a handoff lost the book — but alive in this fleet is READ, not
# assumed gone; two windows answering is a refusal, never a pick.
cat > "$WORK/find" <<'SH'
#!/bin/sh
case "$1" in issue-90) echo '@90|working' ;; issue-91) echo '@91|idle' ;; issue-92) exit 2 ;; *) exit 1 ;; esac
SH
chmod +x "$WORK/find"
export FLEET_EPIC_BACKSTOP_FIND_CMD="$WORK/find"
run issue-90; eq "#1110 not in the ledger but a live working window here → skip" 'backstop skipped: child busy (issue-90 working)' "$out"
run issue-91; eq "#1110 …an idle one → clear (and the bg seam was asked)" 'clear: issue-91 idle' "$out"
run issue-92; eq "#1110 ambiguous key → skip, never a pick" 1 "$rc"
run issue-99; eq "#1110 hub off, no window → the one-machine answer, byte for byte" 'clear: issue-99 no live window' "$out"

# The hub's session table (global/remote_<sess>, fleet-hub-sessions.sh's rows):
# a member on ANOTHER machine is found by (repo, issue).
G="$WORK/tmp/.claude-dash/global"; mkdir -p "$G"
now=$(date +%s); US=$(printf '\037')
hubrow() {  # <issue> <state> <node> [local]
  printf 'wid:u/issue-%s%s%s%sonline%s%s%sverkyyi/x%s%s%sclaude%sname%s%s%s%s%s%s%s%shub\n' \
    "$1" "$US" "$3" "$US" "$US" "$1" "$US" "$US" "$2" "$US" "$US" "$US" "$US" "$US" "$US" "${4:-0}" "$US" "$US" "$US"
}
{ printf '#ts%s%s\n#me%sm5\n' "$US" "$now" "$US"
  hubrow 99 working m4; hubrow 98 'done' m4; hubrow 96 looping m4; hubrow 95 idle m4; hubrow 95 working m6
} > "$G/remote_s"
printf '%s\n' "$now" > "$G/hub_ok"
cat > "$WORK/remote.json" <<'JSON'
{"parent":"scratch-9","session":"s","seq":1,"summary":{},"children":[
 {"child":"issue-96","bucket":"▸","live":true,"window":"m4","state":"remote","pr":"96","last":null},
 {"child":"issue-94","bucket":"▸","live":true,"window":"m4","state":"remote","pr":"94","last":null}
]}
JSON
hrun() { out=$(CCQUOTA_FLEET=1 bash "$GATE" -L s --children-json "${J2:-$J}" "$@" 2>&1); rc=$?; }
hrun issue-99; eq "#1110 working on another machine → skip (rc)" 1 "$rc"
eq "#1110 …says where" 'backstop skipped: child busy (issue-99 hub: working on m4)' "$out"
hrun issue-98; eq "#1110 done on another machine → clear" 'clear: issue-98 hub: done on m4' "$out"
hrun issue-97; eq "#1110 no hub row → clear, and says so" 'clear: issue-97 no live window (hub says gone)' "$out"
hrun issue-95; eq "#1110 a busy row beats an idle twin" 'backstop skipped: child busy (issue-95 hub: working on m6)' "$out"
hrun issue-90; eq "#1110 a window here still answers first" 'backstop skipped: child busy (issue-90 working)' "$out"
J2="$WORK/remote.json" hrun issue-96; eq "#1110 a ledger child live on another machine asks the hub" 'backstop skipped: child busy (issue-96 hub: looping on m4)' "$out"
J2="$WORK/remote.json" hrun issue-94; eq "#1110 …and is clear only when the hub says gone" 'clear: issue-94 no live window (hub says gone)' "$out"
# --- issue #1607: what only the other machine can see ---------------------------
# The node's `busy` column (fleet-control-read.sh workers → the hub → the cache's
# 14th field): a `done` member still holding a /loop round or a Bash-tool job is
# BUSY, never clear; a row on a machine the hub has lost is unseen, not idle; and
# with the hub off, a ledger that puts the child on another machine holds too.
hubrow14() {  # <issue> <state> <node> <busy> [online|lost]
  local IFS="$US"
  printf '%s\n' "wid:u/issue-$1${US}$3${US}${5:-online}${US}$1${US}verkyyi/x${US}$2${US}claude${US}name${US}${US}${US}0${US}${US}hub${US}$4"
}
{ printf '#ts%s%s\n#me%sm5\n' "$US" "$now" "$US"
  hubrow14 80 'done' m4 bg; hubrow14 81 'done' m4 looping; hubrow14 82 idle m4 '' lost
  hubrow14 83 'done' m4 ''; hubrow14 84 idle m4 '' lost; hubrow14 84 working m6 ''
  hubrow14 85 idle m4 '' lost; hubrow14 85 'done' m6 ''
} > "$G/remote_s"
hrun issue-80; eq "#1607 remote done + a Bash-tool job → skip (rc)" 1 "$rc"
eq "#1607 …the tick line names it and the machine" 'backstop skipped: child busy (issue-80 hub: bg on m4)' "$out"
hrun issue-81; eq "#1607 remote done + a held /loop round → skip" 'backstop skipped: child busy (issue-81 hub: looping on m4)' "$out"
hrun issue-82; eq "#1607 a lost machine's row → skip (rc), never its last idle" 1 "$rc"
case "$out" in *'issue-82 hub: lost on m4'*) CHECKS=$((CHECKS + 1)) ;; *) fail "#1607 lost says where" "$out" ;; esac
hrun issue-83; eq "#1607 remote ended (done, busy empty) → clear" 'clear: issue-83 hub: done on m4' "$out"; eq "…rc 0" 0 "$rc"
hrun issue-84; eq "#1607 a working twin still wins over a lost one" 'backstop skipped: child busy (issue-84 hub: working on m6)' "$out"
hrun issue-85; eq "#1607 a lost twin outranks an idle one" 1 "$rc"
cat > "$WORK/node.json" <<'JSON'
{"parent":"scratch-9","session":"s","seq":1,"summary":{},"children":[
 {"child":"issue-70","bucket":"–","live":false,"window":"","state":"gone","node":"m4","pr":"70","last":{"state":"WAITING","node":"m4"}},
 {"child":"issue-71","bucket":"▸","live":true,"window":"m4","state":"remote","node":"m4","pr":"71","last":null}
]}
JSON
out=$(CCQUOTA_FLEET=0 bash "$GATE" -L s --children-json "$WORK/node.json" issue-70 2>&1); rc=$?
eq "#1607 hub off, ledger says m4 → skip (rc)" 1 "$rc"
eq "#1607 …and says it cannot see" 'backstop skipped: child busy (issue-70 on m4, hub off: cannot see it)' "$out"
out=$(CCQUOTA_FLEET=0 bash "$GATE" -L s --children-json "$WORK/node.json" issue-71 2>&1)
eq "#1607 hub off, a remote ledger row → skip" 'backstop skipped: child busy (issue-71 on m4, hub off: cannot see it)' "$out"
out=$(CCQUOTA_FLEET=0 bash "$GATE" -L s --children-json "$J" issue-5 2>&1)
eq "#1607 degenerate: hub off, no node → the one-machine answer, byte for byte" 'clear: issue-5 no live window' "$out"
J2="$WORK/node.json" hrun issue-70; eq "#1607 hub on: a ledger m4 child no hub row names → clear (ended there)" 'clear: issue-70 no live window (hub says gone)' "$out"

printf '%s\n' "$((now - 1000))" > "$G/hub_ok"
hrun issue-80; eq "#1607 hub silent past FLEET_HUB_RETAIN_SECS → skip, whatever the row said" 1 "$rc"
hrun issue-97; eq "#1110 a hub silent past FLEET_HUB_RETAIN_SECS → skip, never idle (rc)" 1 "$rc"
case "$out" in *'cannot rule out a session elsewhere: hub silent'*) CHECKS=$((CHECKS + 1)) ;; *) fail "#1110 stale hub says why" "$out" ;; esac
rm -f "$G/remote_s" "$G/hub_ok"
hrun issue-97; eq "#1110 hub on but no session cache → skip" 'backstop skipped: child busy (issue-97 cannot rule out a session elsewhere: no hub session cache)' "$out"

# fleet_epic_parent_key: a keyless (hub) pane is REFUSED (issue #1355) — the
# EPIC's key named a parent no window answers to; spawn-origin-gate-selftest.sh B
# pins the pane cases.
pk=$(TMUX='' bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1; fleet_epic_parent_key s verkyyi/x 1585' _ "$BIN" 2>/dev/null)
eq "#1355 a pane with no key → rc 1" 1 "$?"
eq "#1355 …and never the EPIC's key" '' "$pk"

printf 'fleet-epic-backstop selftest: OK (%d checks)\n' "$CHECKS"
