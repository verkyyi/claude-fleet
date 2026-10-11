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
#   train-own-runners-gone   both Macs paused / offline, the hub away or no token:
#                       the train's board picks macos-latest, 2 shards (#3145)
#   train-own-runner-silent  our runner said idle but never took the shard: the
#                       train's watcher reds + cancels it at the deadline (#3145)
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

# The release train's pick (issue #3145, EPIC #3139 C6): our Macs when the hub says
# one is there, GitHub's otherwise — the train runs either way.
drill_train_own_runners_gone() {
  CAP=30
  local t0 d out wf
  [ -x "$BIN/fleet-train-macos.sh" ] || { WHY="no bin/fleet-train-macos.sh"; return 1; }
  wf="$BIN/../.github/workflows/release-train.yml"
  grep -q 'fleet-train-macos.sh pick' "$wf" && grep -q 'runs_on: ${{ needs.board.outputs.macos_runs_on }}' "$wf" \
    || { WHY="release-train.yml does not take the macOS runner from board's pick"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-pick.XXXXXX"); t0=$(now)
  printf '%s' '{"runners":[{"machine":"macmini","online":true,"runner":{"state":"idle"}},{"machine":"mini2","online":true,"runner":{"state":"busy"}}]}' > "$d/up.json"
  printf '%s' '{"runners":[{"machine":"macmini","online":true,"runner":{"state":"paused","why":"load"}},{"machine":"mini2","online":false,"runner":{"state":"idle"}}]}' > "$d/down.json"
  pick() { GITHUB_OUTPUT="$d/out" bash "$BIN/fleet-train-macos.sh" pick "$@" 2>/dev/null; }
  out=$(pick --runners-file "$d/up.json")
  case "$out" in *'macos_runs_on=["self-hosted","macOS","fleet-ci"]'*'macos_shards=[1, 2]'*) ;;
    *) WHY="two runners up, the pick was not fleet-ci × 2: $out"; rm -rf "$d"; return 1 ;; esac
  for c in down nohub notoken; do
    case "$c" in
      down)    out=$(pick --runners-file "$d/down.json") ;;
      nohub)   out=$(FLEET_HUB_CI_TOKEN=x pick --hub http://127.0.0.1:1) ;;
      notoken) out=$(FLEET_HUB_CI_TOKEN='' pick --hub http://127.0.0.1:1) ;;
    esac
    case "$out" in *'macos_runs_on=["macos-latest"]'*'macos_shards=[1, 2]'*'macos_where=github'*) ;;
      *) WHY="($c) the train did not fall back to macos-latest × 2: $out"; rm -rf "$d"; return 1 ;; esac
  done
  grep -q '^macos_runs_on=' "$d/out" || { WHY="the pick wrote nothing to GITHUB_OUTPUT"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="两台测试机 paused / 离线、入口不通、没令牌：列车选 macos-latest 2 片照发；两台在：fleet-ci 2 片"
}

drill_train_own_runner_silent() {
  CAP=30
  local t0 d out rc
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-watch.XXXXXX"); t0=$(now)
  # a fake gh: the jobs list from $d/jobs.json, `run cancel` recorded
  cat > "$d/gh" <<'G'
#!/bin/bash
case "$1" in
  api) cat "$FAKE_DIR/jobs.json" ;;
  run) [ "$2" = cancel ] && echo "$3" >> "$FAKE_DIR/cancelled" ;;
esac
G
  chmod +x "$d/gh"
  printf '%s' '{"jobs":[{"name":"macOS / shard 1","status":"queued","created_at":"2026-10-11T01:00:00Z"},{"name":"macOS / shard 2","status":"queued","created_at":"2026-10-11T01:00:00Z"},{"name":"Linux / shard 1","status":"completed","created_at":"2026-10-11T01:00:00Z","started_at":"2026-10-11T01:00:05Z"}]}' > "$d/jobs.json"
  out=$(FAKE_DIR=$d FLEET_TRAIN_GH="$d/gh" GITHUB_STEP_SUMMARY="$d/sum" \
    bash "$BIN/fleet-train-macos.sh" watch --repo o/r --run 77 --where fleet-ci --deadline 2 --every 1 2>&1); rc=$?
  [ "$rc" = 1 ] || { WHY="a shard left queued on fleet-ci past the deadline: watch exit $rc, want 1: $out"; rm -rf "$d"; return 1; }
  grep -q '自家测试机没接' "$d/sum" 2>/dev/null || { WHY="the summary does not say 自家测试机没接: $(cat "$d/sum" 2>/dev/null)"; rm -rf "$d"; return 1; }
  [ "$(cat "$d/cancelled" 2>/dev/null)" = 77 ] || { WHY="the run was not cancelled"; rm -rf "$d"; return 1; }
  # on GitHub's machines the same queue is only reported
  rm -f "$d/cancelled" "$d/sum"
  out=$(FAKE_DIR=$d FLEET_TRAIN_GH="$d/gh" GITHUB_STEP_SUMMARY="$d/sum" \
    bash "$BIN/fleet-train-macos.sh" watch --repo o/r --run 77 --where github --deadline 1 --every 1 2>&1); rc=$?
  [ "$rc" = 0 ] && [ ! -f "$d/cancelled" ] || { WHY="GitHub's queue was judged (exit $rc, cancel $(cat "$d/cancelled" 2>/dev/null))"; rm -rf "$d"; return 1; }
  # started: each shard's runner and queue time on the summary
  rm -f "$d/sum"
  printf '%s' '{"jobs":[{"name":"macOS / shard 1","status":"in_progress","created_at":"2026-10-11T01:00:00Z","started_at":"2026-10-11T01:01:30Z","runner_name":"fleet-ci-macmini-1"},{"name":"macOS / shard 2","status":"completed","conclusion":"success","created_at":"2026-10-11T01:00:00Z","started_at":"2026-10-11T01:00:20Z","runner_name":"fleet-ci-mini2-1"}]}' > "$d/jobs.json"
  out=$(FAKE_DIR=$d FLEET_TRAIN_GH="$d/gh" GITHUB_STEP_SUMMARY="$d/sum" \
    bash "$BIN/fleet-train-macos.sh" watch --repo o/r --run 77 --where fleet-ci --deadline 5 --every 1 2>&1); rc=$?
  [ "$rc" = 0 ] && grep -q 'fleet-ci-macmini-1 | 1m30s' "$d/sum" && grep -q 'fleet-ci-mini2-1 | 0m20s' "$d/sum" \
    || { WHY="started shards: exit $rc, summary $(cat "$d/sum" 2>/dev/null)"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="自家测试机报 idle 却不接：到点这趟红、摘要写「自家测试机没接」、整趟取消；接了就记每片的机器和排队时间"
}

cred_run_drills "$0"
