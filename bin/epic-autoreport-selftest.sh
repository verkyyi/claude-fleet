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
#   6. an EPIC spanning repos (issue #1942): each member names its repo, its child
#      task opens there, the report asks stable per repo; the one-repo wording of
#      #803 is gone.
#   7. hub tasks, not GitHub (issue #4957): the parent is a task, its members child
#      tasks; no `gh issue`, sub-issue, preflight, backstop or loopers road is left.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROOT="$BIN/.."
RUN="$ROOT/plugins/fleet-epic/commands/fleet-epic-run.md"
REPORT="$ROOT/plugins/fleet-epic/commands/fleet-epic-report.md"
CHECKS=0
hasF() { CHECKS=$((CHECKS + 1)); grep -q -F -- "$2" "$1" || st_fail "$3 — [$2] not in ${1#"$ROOT"/}"; }

[ -f "$RUN" ] || st_fail "plugins/fleet-epic/commands/fleet-epic-run.md is missing"
[ -f "$REPORT" ] || st_fail "plugins/fleet-epic/commands/fleet-epic-report.md is missing"

# 1. the report is a beat of the run, not something handed off to someone else.
#    The old wording ("hand off to `/fleet-epic-report`") reads as a contract and
#    is not one: conf/gone.list keeps it out (#852).
hasF "$RUN" 'Run `/fleet-epic-report` right here' "run §4 names the report command it runs"
hasF "$RUN" 'in this session, now' "run §4: the report runs here, not elsewhere"
hasF "$RUN" 'is not the end of the run' "run §4: an EPIC without a report is not finished"

# 2. the `report:` field — declared in the tick format, written by the close
hasF "$RUN" 'report: <pending | link>' "run step 1: the tick format declares the report: field"
hasF "$RUN" 'report: pending' "run §4: the closing tick writes report: pending"

# 3. ordering + resume. `pending` before the run is what survives a session that
#    dies mid-report; the resumed loop re-enters the close instead of refilling.
hasF "$RUN" 'Before the report, not after' "run §4: pending is written BEFORE the report runs"
hasF "$RUN" 'Resuming into a' "run §4: says what a resumed loop does with a pending report"
hasF "$RUN" 'it does **not** refill' "run §4: a resumed close does not go back to refilling"

# 4. a report that did not run never closes the batch
hasF "$RUN" 'is a stall, not a finish' "run §4: a failed report is a stall"
hasF "$RUN" 'Never close the parent off a report that did not run' "run §4: done requires the report to have run"

# 5. the other end of the seam — the report is safe for a machine to re-run
hasF "$REPORT" 'usual caller is not a human' "report: documents its run-loop caller"
hasF "$REPORT" 're-runnable' "report: states it is re-runnable (makes check 3 safe)"
hasF "$REPORT" '#852' "report: cites the seam's issue"

# 6. an EPIC spanning repos (issue #1942) — each member names the repo its code
#    changes in, and its child task opens there.
PLAN="$ROOT/plugins/fleet-epic/commands/fleet-epic-plan.md"
[ -f "$PLAN" ] || st_fail "plugins/fleet-epic/commands/fleet-epic-plan.md is missing"
for f in "$PLAN" "$RUN" "$REPORT"; do   # (the one-repo wording, #803, is conf/gone.list's)
  hasF "$f" '#1942' "cites the cross-repo EPIC issue"
done
hasF "$PLAN" '**C2** owner/other — <名称> (codex)' "plan: a member in another repo names its repo in its line"
hasF "$RUN" '`repo` = its `repo`' "run: each child task opens in its member's repo"
hasF "$REPORT" 'Once per repo the members landed in' "report: the stable row is asked per repo"

# 7. hub tasks, not GitHub issues (issue #4957): the parent is a task, the members
#    its children; the trio reads and writes the hub only (the GitHub road's words
#    are conf/gone.list's).
for f in "$PLAN" "$RUN" "$REPORT"; do
  hasF "$f" '#4957' "cites the hub-task EPIC issue"
done
hasF "$PLAN" '`agent` `epic-driver`' "plan: the parent task starts the driver"
hasF "$PLAN" 'mcp__fleet-orch__task' "plan: the parent is opened with the task tool"
hasF "$RUN" 'fleet-epic-tick.py status' "run: one read of the batch off the hub"
hasF "$RUN" 'fleet_task_control.py progress' "run: the tick goes onto the parent task"
hasF "$RUN" 'outcome: succeeded' "run: the close records the parent's result"
hasF "$REPORT" 'fleet-epic-tick.py status' "report: the members come off the hub"

printf 'epic-autoreport-selftest OK (%d checks)\n' "$CHECKS"
