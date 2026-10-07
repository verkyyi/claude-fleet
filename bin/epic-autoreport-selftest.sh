#!/bin/bash
# epic-autoreport-selftest.sh — the run→report seam (issue #852): `/fleet-epic-run`
# does not *suggest* the report, it RUNS it as the batch's closing tick.
#
# Why a selftest for a prose contract. Before #852, `/fleet-epic-run` §4 ended
# "Then hand off to `/fleet-epic-report <N>`" — one sentence, no mechanism, no
# state. A 12-hour batch whose report never ran is indistinguishable from a
# finished one: the tick log nobody reads is on the issue, the page that would
# have been read does not exist. The fix is three sentences of contract plus one
# machine-readable `report:` line on the closing tick — and three sentences are
# exactly what the next editor trims. So the checks below pin the load-bearing
# words, the way epic-page-selftest.sh pins the frame's section ids.
#
# Hermetic: reads two command docs, nothing else. No gh, no tmux, no network.
#
#   1. §4 is the closing sequence, not a handoff — the old "hand off to" wording
#      is gone and the report runs in this session.
#   2. the `report:` tick field exists on both sides: documented in the tick
#      format (step 1) and written by the closing sequence (step 4).
#   3. `pending` is written BEFORE the report runs, and is what a resumed loop
#      re-enters on — the crash window between the two is the whole point.
#   4. a failed report is a stall, never a done notification.
#   5. the report command knows it has a non-human caller and says it is
#      re-runnable, which is what makes check 3's re-entry safe.
#   6. an EPIC spanning repos (issue #1942): the trio treats a member as (repo,
#      issue) — plan files it in its own repo and writes `owner/name#N` in the
#      list, run spawns / judges / merges / reaps it in ITS repo, report reads
#      evidence and stable per repo — and the one-repo wording of #803 is gone.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$BIN/.."
RUN="$ROOT/commands/fleet-epic-run.md"
REPORT="$ROOT/commands/fleet-epic-report.md"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
hasF() { CHECKS=$((CHECKS + 1)); grep -q -F -- "$2" "$1" || fail "$3 — [$2] not in ${1#"$ROOT"/}"; }
lacksF() { CHECKS=$((CHECKS + 1)); grep -q -F -- "$2" "$1" && fail "$3 — [$2] still in ${1#"$ROOT"/}"; return 0; }

[ -f "$RUN" ] || fail "commands/fleet-epic-run.md is missing"
[ -f "$REPORT" ] || fail "commands/fleet-epic-report.md is missing"

# 1. the report is a beat of the run, not something handed off to someone else.
#    The old wording is the regression to catch: it reads as a contract and is
#    not one, so it must not come back.
lacksF "$RUN" 'hand off to `/fleet-epic-report' "run §4 must not delegate the report away again (#852)"
hasF "$RUN" '/fleet-epic-report <N>' "run §4 names the report command it runs"
hasF "$RUN" 'in this same hub session' "run §4: the report runs here, not elsewhere"
hasF "$RUN" 'is not finished' "run §4: an EPIC without a report is not finished"

# 2. the `report:` field — declared in the tick format, written by the close
hasF "$RUN" 'report: <pending | the report' "run step 1: the tick format declares the report: field"
hasF "$RUN" 'report: pending' "run §4: the closing tick writes report: pending"

# 3. ordering + resume. `pending` before the run is what survives a session that
#    dies mid-report; the resumed loop re-enters the close instead of refilling.
hasF "$RUN" 'Before running the report, not after' "run §4: pending is written BEFORE the report runs"
hasF "$RUN" 'Resuming into a' "run §4: says what a resumed loop does with a pending report"
hasF "$RUN" 'refill slots, and it does not start over' "run §4: a resumed close does not go back to refilling"

# 4. a report that did not run never produces a done notification
hasF "$RUN" 'is a stall, not a finish' "run §4: a failed report is a stall"
hasF "$RUN" 'and the report has run' "run §4: done requires the report to have run"

# 5. the other end of the seam — the report is safe for a machine to re-run
hasF "$REPORT" 'usual caller is not a human' "report: documents its run-loop caller"
hasF "$REPORT" 're-runnable' "report: states it is re-runnable (makes check 3 safe)"
hasF "$REPORT" '#852' "report: cites the seam's issue"

# 6. an EPIC spanning repos (issue #1942) — every reader keys a member on (repo,
#    issue). The regression to catch is a doc that goes back to «an EPIC lives in
#    ONE repo» and a run that spawns or merges a repo-B member in repo A.
PLAN="$ROOT/commands/fleet-epic-plan.md"
[ -f "$PLAN" ] || fail "commands/fleet-epic-plan.md is missing"
for f in "$PLAN" "$RUN" "$REPORT"; do
  lacksF "$f" 'and an EPIC lives in' "the one-repo EPIC wording (#803) is retired"
  hasF "$f" '#1942' "cites the cross-repo EPIC issue"
done
hasF "$PLAN" '**C1** owner/name#N — title' "plan: a member in another repo is listed as owner/name#N"
hasF "$PLAN" 'the one holding the MOST' "plan: the parent goes to the repo with the most members"
hasF "$PLAN" 'repos/<the member'"'"'s repo>/issues/<child>' "plan: the child's id is read from ITS repo"
hasF "$PLAN" '--member-repo' "plan: preflight checks every other member repo"
hasF "$PLAN" 'IS the member list then' "plan: a refused cross-repo link falls back to the list (ruling 4)"
hasF "$RUN" 'Members are (repo, issue)' "run: a member is (repo, issue)"
hasF "$RUN" 'fleet_member_ref "$FLEET_REPO"' "run: list lines parse through fleet_member_ref"
hasF "$RUN" 'dash-issue-session.sh <N> --repo "$MREPO"' "run: the spawn opens in the member's repo"
hasF "$RUN" 'fleet-pr-verdict.sh <PR> --repo "$MREPO"' "run: the verdict reads the member's repo"
hasF "$RUN" 'fleet-pr-merge.sh <PR> --repo "$MREPO"' "run: the merge lands in the member's repo"
hasF "$RUN" 'dash-reap.sh <slug>:issue-<N>' "run: the reap names the member's key"
lacksF "$RUN" 'fleet-pr-verdict.sh <PR> --repo "$FLEET_REPO"' "run: no member verdict on the parent's repo"
hasF "$REPORT" '--epic "$FLEET_REPO#<N>"' "report: a member in another repo names the parent with its repo"
hasF "$REPORT" 'once per repo its members landed in' "report: the stable row is asked per repo"

printf 'epic-autoreport-selftest OK (%d checks)\n' "$CHECKS"
