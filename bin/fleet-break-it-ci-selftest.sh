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
#   train-shard-timeout  stable far behind, a near-full selection: the train sizes
#                       its shards by the forecast and reruns a shard cut short
#                       with no test red once — never one with a FAIL line (#3241)
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

# The release train's forecast and its cut-short rerun (issue #3241, EPIC #3139 C9).
drill_train_shard_timeout() {
  CAP=60
  local t0 d out rc wf sh
  [ -x "$BIN/fleet-train-plan.sh" ] && [ -x "$BIN/fleet-shard-run.sh" ] \
    || { WHY="no bin/fleet-train-plan.sh / bin/fleet-shard-run.sh"; return 1; }
  wf="$BIN/../.github/workflows/release-train.yml"; sh="$BIN/../.github/workflows/selftests-shards.yml"
  grep -q 'fleet-train-plan.sh --base' "$wf" && grep -q 'shards: ${{ needs.plan.outputs.linux_shards }}' "$wf" \
    && grep -q 'budget_secs: ${{ needs.plan.outputs.linux_budget_secs }}' "$wf" \
    || { WHY="release-train.yml's Linux half does not take its width / budget from the plan"; return 1; }
  grep -q 'fleet-shard-run.sh --budget "$BUDGET"' "$sh" && grep -q "inputs.step_minutes != ''" "$sh" \
    || { WHY="selftests-shards.yml does not run a budgeted shard under fleet-shard-run.sh"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-shard.XXXXXX"); t0=$(now)
  # 1) the real runner prices a selection
  out=$(cd "$BIN/.." && FLEET_HEAVY=0 bash bin/run-selftests.sh --plan --shard 1/3 portability bash32-array 2>/dev/null | tail -1)
  case "$out" in 'plan tests=2 total='*' shards=3 heaviest='*) ;;
    *) WHY="run-selftests.sh --plan did not price two tests: $out"; rm -rf "$d"; return 1 ;; esac
  # 2) a near-full selection (the ubuntu table's 4600 s): wider than 12, a bound past 8 minutes
  cat > "$d/rs" <<'R'
#!/bin/bash
n=1; while [ $# -gt 0 ]; do [ "$1" = --shard ] && n=${2#1/}; shift; done
echo "select: * ← full suite"; echo "plan tests=470 total=4600 shards=$n heaviest=$(( 4600 / n + 120 ))"
R
  chmod +x "$d/rs"
  out=$(FLEET_TRAIN_PLAN_CMD="$d/rs" GITHUB_OUTPUT="$d/out" bash "$BIN/fleet-train-plan.sh" --base x --prefix linux 2>&1)
  case "$out" in *'linux_shards=[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]'*'linux_budget_secs=710'*'linux_step_minutes=26'*) ;;
    *) WHY="a 4600 s selection was not planned as 13 shards × 710 s (step 26): $out"; rm -rf "$d"; return 1 ;; esac
  grep -q '^linux_job_minutes=36$' "$d/out" || { WHY="the plan wrote no job bound to GITHUB_OUTPUT"; rm -rf "$d"; return 1; }
  # a small selection keeps the PR's floor; a forecast that cannot be made falls back
  printf '#!/bin/bash\necho "plan tests=6 total=30 shards=1 heaviest=10"\n' > "$d/rs"
  out=$(FLEET_TRAIN_PLAN_CMD="$d/rs" bash "$BIN/fleet-train-plan.sh" --base x --prefix p 2>&1)
  case "$out" in *'p_shards=[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]'*'p_budget_secs=480'*) ;;
    *) WHY="a small selection did not keep 12 × 480 s: $out"; rm -rf "$d"; return 1 ;; esac
  printf '#!/bin/bash\nexit 3\n' > "$d/rs"
  out=$(FLEET_TRAIN_PLAN_CMD="$d/rs" bash "$BIN/fleet-train-plan.sh" --base x --prefix p 2>&1); rc=$?
  [ "$rc" = 0 ] && case "$out" in *'p_budget_secs=480'*) true ;; *) false ;; esac \
    || { WHY="an unpriceable selection stopped the train (exit $rc): $out"; rm -rf "$d"; return 1; }
  # 3) cut short, no test red ⇒ the same shard once more, green
  cat > "$d/shard" <<'S'
#!/bin/bash
echo "run-selftests: shard 9/12 — predicted ~300s"; echo "=== zsh-local-selftest.sh ==="; echo "PASS  zsh-local-selftest.sh"
echo "=== multirepo-e2e-selftest.sh ==="
[ -f "$FAKE_DIR/once" ] || { touch "$FAKE_DIR/once"; sleep 30; }
echo "PASS  multirepo-e2e-selftest.sh"
S
  chmod +x "$d/shard"
  out=$(cd "$d" && FAKE_DIR=$d GITHUB_STEP_SUMMARY="$d/sum" bash "$BIN/fleet-shard-run.sh" --budget 1 --log s.log -- ./shard 2>&1); rc=$?
  [ "$rc" = 0 ] && [ -f "$d/s.log.cut-1" ] && grep -q 'rerunning the same shard once' "$d/sum" \
    && grep -q 'attempt 2 — predicted ~300s' "$d/sum" \
    || { WHY="a shard cut short with no test red: exit $rc, not rerun green: $out"; rm -rf "$d"; return 1; }
  # a FAIL line before the cut never reruns
  printf '#!/bin/bash\necho "FAIL  a-selftest.sh"; touch "$FAKE_DIR/ran.$$"; sleep 30\n' > "$d/shard"
  out=$(cd "$d" && FAKE_DIR=$d bash "$BIN/fleet-shard-run.sh" --budget 1 --log f.log -- ./shard 2>&1); rc=$?
  [ "$rc" = 124 ] && [ "$(ls "$d"/ran.* | wc -l | tr -d ' ')" = 1 ] \
    || { WHY="a cut shard with a FAIL line: exit $rc, ran $(ls "$d"/ran.* 2>/dev/null | wc -l) time(s): $out"; rm -rf "$d"; return 1; }
  # cut short on both attempts ⇒ red, and nothing of it left running
  printf '#!/bin/bash\nsleep 31\n' > "$d/shard"
  out=$(cd "$d" && bash "$BIN/fleet-shard-run.sh" --budget 1 --log h.log -- ./shard 2>&1); rc=$?
  [ "$rc" = 124 ] && printf '%s' "$out" | grep -q 'on every attempt (2)' \
    || { WHY="a shard cut short twice: exit $rc: $out"; rm -rf "$d"; return 1; }
  ! pgrep -f 'sleep 31' >/dev/null || { WHY="the cut shard's process group was left running"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="stable 落后、近全量 4600 s：列车排 13 片、每次上限 710 s；截断且无红 ⇒ 同一片重跑一次变绿，有 FAIL 行不重跑，两次截断才红"
}

cred_run_drills "$0"
