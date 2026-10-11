#!/bin/bash
# fleet-break-it-ci-selftest.sh — the docs/BREAK-IT.md rows of the machine's test
# runner (issue #3144, EPIC #3139 C5 · 共同约定 6). Each drill builds the sandbox
# machine of bin/fleet-ci-runner-selftest.py (`drill <name>`: a fake GitHub API on
# 127.0.0.1, a fake runner archive, a fake test login) and runs bin/fleet-ci-runner.py
# for real. Runner and timing helpers are bin/fleet-break-it-cred-selftest.sh's
# (BREAK_CRED_LIB=1); bin/fleet-break-it-selftest.sh's lockstep lint reads the drill
# names here too.
#
#   ci-runner-hogs      the machine is busy (fleet-loadgen.sh 2 120): no runner is
#                       minted, the doctor's check says paused
#   ci-runner-pr-code   a pull_request job aimed at the fleet-ci label reaches the
#                       runner: none of its steps runs
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"
trap cleanup EXIT
PY="$BIN/fleet-ci-runner-selftest.py"

drill_ci_runner_hogs() {
  CAP=150
  local t0 out rc
  t0=$(now)
  out=$(bash "$BIN/fleet-loadgen.sh" 2 120 -- python3 -W ignore "$PY" drill hogs 90 2>&1); rc=$?
  if [ "$rc" = 3 ] && ! printf '%s' "$out" | grep -q '^FAIL'; then
    # the load generator refused: the box is already above 1 load/core — that is the load
    out=$(python3 -W ignore "$PY" drill hogs-already 2>&1); rc=$?
    WHAT="（机器本已忙，负载器拒绝加压，用现成负载）"
  fi
  SECS=$(since "$t0")
  [ "$rc" = 0 ] || { WHY="${out##*FAIL }"; return 1; }
  WHAT="机器忙（fleet-loadgen.sh 2 120）：测试机不铸下一趟，体检说 $(printf '%s' "$out" | sed -n 's/^SAID //p')${WHAT:-}"
}

drill_ci_runner_pr_code() {
  CAP=60
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore "$PY" drill pr-code 2>&1) || { WHY="${out##*FAIL }"; return 1; }
  SECS=$(since "$t0")
  WHAT="一个 pull_request 任务落到 fleet-ci 标签的测试机上：任务开始钩子拒绝，任务的步骤一步都没跑"
}

cred_run_drills "$0"
