#!/bin/bash
# pr-refresh-jq-selftest.sh — the prmap fold (FLEET_PRMAP_JQ in fleet-lib.sh) folds
# `gh pr list --json` into the dash's PR cell the SAME way the worker's merge gate
# (fleet-pr-verdict.sh → land_verdict) reads the PR (issue #533).
#
# The bug this pins: the program used to be inlined in bin/tmux-pr-refresh.sh and
# drifted from the verdict — only `FAILURE` was red (a CANCELLED run next to one
# green check rendered ✓), the StatusContext rollup shape (`.state`) was never
# looked at, `isDraft` wasn't fetched, and CLEAN vs UNKNOWN mergeability both
# rendered as a bare ✓ ("land-ready"). The operator glanced at green; the worker's
# verdict said DRAFT / FAILING / PENDING.
#
# Fully hermetic: fixture JSON in the exact shape `gh pr list --json number,
# headRefName,state,mergeable,mergeStateStatus,isDraft,statusCheckRollup` returns,
# fed through the byte-identical program with the system `jq -r` (gh's built-in
# jq prints raw strings the same way). No gh, no tmux, no network. Needs `jq`;
# SKIPs cleanly (exit 0) without it, like fleet-context-selftest.sh. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'pr-refresh-jq-selftest: jq absent — SKIP\n'; exit 0; }

export FLEET_SKIP_GLOBAL_CONF=1
# shellcheck source=/dev/null
. "$LIB"
[ -n "${FLEET_PRMAP_JQ:-}" ] || { printf 'selftest FAIL: FLEET_PRMAP_JQ not defined by fleet-lib.sh (issue #533)\n' >&2; exit 1; }

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }

# fold <json-array> → the prmap lines (branch<TAB>#num<TAB>state<TAB>ci<TAB>ready)
fold() { printf '%s' "$1" | jq -r "$FLEET_PRMAP_JQ"; }
# the ci / ready fields of the ONE line a single-PR fixture folds to
ci_of()    { fold "$1" | cut -f4; }
ready_of() { fold "$1" | cut -f5; }

# --- rollup fixtures (the two shapes GitHub mixes in statusCheckRollup) --------
ok='{"__typename":"CheckRun","name":"selftests","status":"COMPLETED","conclusion":"SUCCESS"}'
red='{"__typename":"CheckRun","name":"selftests","status":"COMPLETED","conclusion":"FAILURE"}'
cancelled='{"__typename":"CheckRun","name":"selftests","status":"COMPLETED","conclusion":"CANCELLED"}'
timedout='{"__typename":"CheckRun","name":"selftests","status":"COMPLETED","conclusion":"TIMED_OUT"}'
actionreq='{"__typename":"CheckRun","name":"deploy","status":"COMPLETED","conclusion":"ACTION_REQUIRED"}'
running='{"__typename":"CheckRun","name":"selftests","status":"IN_PROGRESS","conclusion":null}'
skipped='{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SKIPPED"}'
ctx_ok='{"__typename":"StatusContext","context":"ci/external","state":"SUCCESS"}'
ctx_err='{"__typename":"StatusContext","context":"ci/external","state":"ERROR"}'
ctx_fail='{"__typename":"StatusContext","context":"ci/external","state":"FAILURE"}'
ctx_pend='{"__typename":"StatusContext","context":"ci/external","state":"PENDING"}'

# pr <branch> <num> <state> <mergeable> <mss> <isDraft> <rollup-elements…> → one-PR array
pr() {
  local br="$1" n="$2" st="$3" mg="$4" ms="$5" dr="$6"; shift 6
  local roll="" e
  for e in "$@"; do roll="${roll:+$roll,}$e"; done
  printf '[{"headRefName":"%s","number":%s,"state":"%s","mergeable":"%s","mergeStateStatus":"%s","isDraft":%s,"statusCheckRollup":[%s]}]' \
    "$br" "$n" "$st" "$mg" "$ms" "$dr" "$roll"
}

# --- ci: the colour of a check is the verdict's fail|pending|pass ---------------
eq "no checks → ·"                          "·" "$(ci_of "$(pr b 1 OPEN MERGEABLE CLEAN false)")"
eq "all green → ✓"                          "✓" "$(ci_of "$(pr b 1 OPEN MERGEABLE CLEAN false "$ok" "$ok")")"
eq "FAILURE → ✗"                            "✗" "$(ci_of "$(pr b 1 OPEN MERGEABLE CLEAN false "$ok" "$red")")"
eq "CANCELLED next to a green → ✗ (was ✓)"  "✗" "$(ci_of "$(pr b 1 OPEN MERGEABLE CLEAN false "$cancelled" "$ok")")"
eq "TIMED_OUT → ✗"                          "✗" "$(ci_of "$(pr b 1 OPEN MERGEABLE CLEAN false "$ok" "$timedout")")"
eq "ACTION_REQUIRED → ✗"                    "✗" "$(ci_of "$(pr b 1 OPEN MERGEABLE CLEAN false "$actionreq" "$ok")")"
eq "StatusContext ERROR → ✗ (was ignored)"  "✗" "$(ci_of "$(pr b 1 OPEN MERGEABLE CLEAN false "$ok" "$ctx_err")")"
eq "StatusContext FAILURE → ✗"              "✗" "$(ci_of "$(pr b 1 OPEN MERGEABLE CLEAN false "$ctx_fail")")"
eq "a check still running → …"              "…" "$(ci_of "$(pr b 1 OPEN MERGEABLE CLEAN false "$ok" "$running")")"
eq "StatusContext PENDING → …"              "…" "$(ci_of "$(pr b 1 OPEN MERGEABLE CLEAN false "$ok" "$ctx_pend")")"
eq "red beats pending (fail first)"         "✗" "$(ci_of "$(pr b 1 OPEN MERGEABLE CLEAN false "$running" "$red")")"
eq "SKIPPED + StatusContext SUCCESS → ✓"    "✓" "$(ci_of "$(pr b 1 OPEN MERGEABLE CLEAN false "$skipped" "$ctx_ok" "$ok")")"

# --- ready: land-readiness, only for an OPEN + ✓ PR ------------------------------
eq "draft + CLEAN → draft (was bare ✓)"     "draft"    "$(ready_of "$(pr b 1 OPEN MERGEABLE CLEAN true  "$ok")")"
eq "draft wins over BEHIND"                 "draft"    "$(ready_of "$(pr b 1 OPEN MERGEABLE BEHIND true "$ok")")"
eq "CLEAN → ready"                          "ready"    "$(ready_of "$(pr b 1 OPEN MERGEABLE CLEAN false "$ok")")"
eq "HAS_HOOKS → ready"                      "ready"    "$(ready_of "$(pr b 1 OPEN MERGEABLE HAS_HOOKS false "$ok")")"
eq "UNSTABLE → ready (as land_classify)"    "ready"    "$(ready_of "$(pr b 1 OPEN MERGEABLE UNSTABLE false "$ok")")"
eq "BEHIND → behind"                        "behind"   "$(ready_of "$(pr b 1 OPEN MERGEABLE BEHIND false "$ok")")"
eq "DIRTY → conflict"                       "conflict" "$(ready_of "$(pr b 1 OPEN MERGEABLE DIRTY false "$ok")")"
eq "mergeable CONFLICTING → conflict"       "conflict" "$(ready_of "$(pr b 1 OPEN CONFLICTING UNKNOWN false "$ok")")"
eq "BLOCKED → blocked"                      "blocked"  "$(ready_of "$(pr b 1 OPEN MERGEABLE BLOCKED false "$ok")")"
eq "UNKNOWN mss → unknown (was bare ✓)"     "unknown"  "$(ready_of "$(pr b 1 OPEN UNKNOWN UNKNOWN false "$ok")")"
eq "empty mss → unknown"                    "unknown"  "$(ready_of "$(pr b 1 OPEN MERGEABLE '' false "$ok")")"
eq "red PR → ready empty (ci carries it)"   ""         "$(ready_of "$(pr b 1 OPEN MERGEABLE CLEAN false "$red")")"
eq "pending PR → ready empty"               ""         "$(ready_of "$(pr b 1 OPEN MERGEABLE CLEAN false "$running")")"
eq "no checks → ready empty"                ""         "$(ready_of "$(pr b 1 OPEN MERGEABLE CLEAN false)")"
eq "MERGED → ready empty"                   ""         "$(ready_of "$(pr b 1 MERGED UNKNOWN UNKNOWN false "$ok")")"
eq "CLOSED → ready empty"                   ""         "$(ready_of "$(pr b 1 CLOSED UNKNOWN UNKNOWN false "$ok")")"

# --- the line contract: 5 tab-separated fields, newest PR per branch -------------
line=$(fold "$(pr issue-42 77 OPEN MERGEABLE CLEAN false "$ok")")
eq "line = branch<TAB>#num<TAB>state<TAB>ci<TAB>ready" \
   "$(printf 'issue-42\t#77\tOPEN\t✓\tready')" "$line"
line=$(fold "$(pr b 1 MERGED UNKNOWN UNKNOWN false "$ok")")
eq "MERGED line keeps 5 fields (empty ready)" \
   "$(printf 'b\t#1\tMERGED\t✓\t')" "$line"
two='[{"headRefName":"issue-9","number":10,"state":"CLOSED","mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","isDraft":false,"statusCheckRollup":[]},
      {"headRefName":"issue-9","number":12,"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","isDraft":false,"statusCheckRollup":['"$ok"']}]'
eq "same branch twice → the newest PR wins" \
   "$(printf 'issue-9\t#12\tOPEN\t✓\tready')" "$(fold "$two")"
# an older gh that doesn't return isDraft: the key is absent → never a draft
nodraft='[{"headRefName":"b","number":1,"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":['"$ok"']}]'
eq "isDraft absent (older gh) → ready, not draft" "ready" "$(fold "$nodraft" | cut -f5)"

# --- the program in fleet-lib.sh IS the one tmux-pr-refresh.sh runs ---------------
grep -q -- '--jq "\$FLEET_PRMAP_JQ"' "$BIN/tmux-pr-refresh.sh" \
  || fail "tmux-pr-refresh.sh must feed FLEET_PRMAP_JQ to gh --jq (not an inline copy)"
grep -q 'isDraft' "$BIN/tmux-pr-refresh.sh" \
  || fail "tmux-pr-refresh.sh must fetch isDraft (issue #533)"
CHECKS=$((CHECKS+2))

printf 'selftest PASS: prmap fold matches the merge-gate taxonomy — %d checks (issue #533)\n' "$CHECKS"
