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
#   train-red-holds-lane    one Linux shard red while macOS runs on: the train's
#                       fail-fast cancels the run at once (#3143)
#   train-derived-red       a failed publish run and a failed move run on the
#                       commit: the next train moves stable anyway, no hand
#                       --ignore-check; the old auto roads are gone (#3143)
#   train-superseded-red    stable moved past TRAIN_SHA mid-run: the train's release
#                       ends green saying superseded, not red on the 409 (#3143)
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

# The release train gives its lane back the moment it cannot ship (issue #3143):
# run 38126091475 went red on a Linux shard and held the lane while macOS ran on.
drill_train_red_holds_lane() {
  CAP=30
  local t0 d out rc wf
  wf="$BIN/../.github/workflows/release-train.yml"
  grep -q 'bin/fleet-train-failfast.sh' "$wf" || { WHY="release-train.yml runs no fleet-train-failfast.sh"; return 1; }
  # after the cancel, C10's 隔离 still records the red shard (it runs if: always());
  # a quarantine drill (deliberately red) is never cut short
  sed -n '/^  record:/,/^  [a-z-]*:$/p' "$wf" | grep -q "if: always()" \
    || { WHY="the quarantine record job does not run after a cancel (if: always())"; return 1; }
  sed -n '/^  fail-fast:/,/^  gate:/p' "$wf" | grep -q "drill != 'true'" \
    || { WHY="fail-fast would cancel a quarantine drill"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-failfast.XXXXXX"); t0=$(now)
  cat > "$d/gh" <<'G'
#!/bin/bash
case "$1" in
  api) cat "$FAKE_DIR/jobs.tsv" ;;
  run) [ "$2" = cancel ] && echo "$3" >> "$FAKE_DIR/cancelled" ;;
esac
G
  chmod +x "$d/gh"
  ff() { FAKE_DIR=$d FLEET_TRAIN_GH="$d/gh" GITHUB_STEP_SUMMARY="$d/sum" \
           bash "$BIN/fleet-train-failfast.sh" --repo o/r --run 77 --every 1 --deadline "$1" 2>&1; }
  # a shard C9 cut short is rerunning in its step (job in progress): not judged
  printf 'completed\tsuccess\tboard\ncompleted\tsuccess\tprecheck\nin_progress\t\tLinux / shard 9\ncompleted\tsuccess\tmacOS / shard 1\n' > "$d/jobs.tsv"
  out=$(ff 2); rc=$?
  [ "$rc" = 0 ] && [ ! -f "$d/cancelled" ] || { WHY="a shard still rerunning was judged: exit $rc: $out"; rm -rf "$d"; return 1; }
  # Linux shard 3 red, the macOS shards still running: cancel now
  printf 'completed\tsuccess\tboard\ncompleted\tsuccess\tprecheck\ncompleted\tfailure\tLinux / shard 3\nin_progress\t\tLinux / shard 4\nin_progress\t\tmacOS / shard 1\nqueued\t\tmacOS / shard 2\n' > "$d/jobs.tsv"
  out=$(ff 30); rc=$?
  [ "$rc" = 1 ] || { WHY="a red Linux shard: failfast exit $rc, want 1: $out"; rm -rf "$d"; return 1; }
  [ "$(cat "$d/cancelled" 2>/dev/null)" = 77 ] || { WHY="the red train was not cancelled"; rm -rf "$d"; return 1; }
  grep -q '红灯即停：Linux / shard 3' "$d/sum" 2>/dev/null || { WHY="the summary does not name the red shard: $(cat "$d/sum" 2>/dev/null)"; rm -rf "$d"; return 1; }
  # all green: nothing cancelled; shards not listed yet (a called workflow not started): not green yet
  rm -f "$d/cancelled" "$d/sum"
  printf 'completed\tsuccess\tboard\ncompleted\tsuccess\tprecheck\n' > "$d/jobs.tsv"
  out=$(ff 2); rc=$?
  [ "$rc" = 0 ] && case "$out" in *'no verdict'*) true ;; *) false ;; esac \
    || { WHY="board + precheck green before any shard was listed was judged: exit $rc: $out"; rm -rf "$d"; return 1; }
  printf 'completed\tsuccess\tboard\ncompleted\tsuccess\tprecheck\ncompleted\tsuccess\tLinux / shard 1\ncompleted\tsuccess\tmacOS / shard 1\ncompleted\tcancelled\tmacOS 排队\n' > "$d/jobs.tsv"
  out=$(ff 30); rc=$?
  [ "$rc" = 0 ] && [ ! -f "$d/cancelled" ] || { WHY="an all-green train: exit $rc, cancel $(cat "$d/cancelled" 2>/dev/null): $out"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="一片 Linux 红、macOS 还在跑：列车的「红灯即停」当场取消整趟，车道让给下一趟；全绿什么都不动"
}

# A red derived run (a publish, a move, an old auto road) on the commit no longer
# blocks the next train's move (issue #3143): the move's CI gate passes over the
# release workflows' own runs, and the old roads that left them are retired.
drill_train_derived_red() {
  CAP=60
  local t0 d out wfs c1 c2 c3
  wfs="$BIN/../.github/workflows"
  [ ! -e "$wfs/stable-auto.yml" ] || { WHY="stable-auto.yml still moves stable on its own"; return 1; }
  awk '/^on:/{o=1; next} o && /^[^ ]/{o=0} o' "$wfs/hub-deploy.yml" | grep -q '^[[:space:]]*push:' \
    && { WHY="hub-deploy.yml is still triggered by push"; return 1; }
  awk '/^on:/{o=1; next} o && /^[^ ]/{o=0} o' "$wfs/stable-publish.yml" | grep -v '^[[:space:]]*#' | grep -Eq '^  (push|workflow_run|schedule):' \
    && { WHY="stable-publish.yml is triggered by more than a dispatch"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-derived.XXXXXX"); mkdir -p "$d/shim" "$d/conf"
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/seed" 2>/dev/null || exit 1
    for i in 1 2 3; do echo "$i" >> "$d/seed/f"; git -C "$d/seed" add -A && git -C "$d/seed" commit -qm "c$i" || exit 1
      git -C "$d/seed" rev-parse HEAD > "$d/c$i"; done
    git -C "$d/seed" push -q origin HEAD:master || exit 1
    git --git-dir="$d/origin.git" update-ref refs/tags/stable "$(cat "$d/c1")" && git clone -q "$d/origin.git" "$d/co" 2>/dev/null
  ) || { WHY="could not build the rig repo"; rm -rf "$d"; return 1; }
  c1=$(cat "$d/c1"); c2=$(cat "$d/c2"); c3=$(cat "$d/c3")
  # GitHub: on the commits a failed publish (suite 802) and a failed move (803) beside
  # the green tests (801); the train run 77's own jobs are all green.
  cat > "$d/shim/gh" <<SH
#!/bin/sh
case "\$*" in
  *'actions/runs?head_sha='*) printf '801 .github/workflows/selftests.yml\n802 .github/workflows/stable-publish.yml\n803 .github/workflows/stable-auto.yml\n' ;;
  *actions/runs/77/jobs*) printf 'completed success board\ncompleted success Linux / shard 1\ncompleted success macOS / shard 1\ncompleted success 红灯即停\nin_progress null release\n' ;;
  *check-runs*) printf '801 completed success shard 1\n802 completed failure publish stable\n803 completed failure move stable\n' ;;
  *actions/workflows/*) printf '%s\tcompleted\tsuccess\tschedule\t9\tselftests (macOS)\n' "$c3" ;;
esac
SH
  chmod +x "$d/shim/gh"
  t0=$(now)
  mv1() { env -u FLEET_HUB_URL -u CCQUOTA_HUB_URL PATH="$d/shim:$PATH" FLEET_CONF_DIR="$d/conf" XDG_CONFIG_HOME="$d/conf" \
            sh "$BIN/fleet-stable.sh" move "$@" --dir "$d/co" --repo o/r 2>&1; }
  # the train's own move: its run's jobs, never the commit's red derived runs
  out=$(mv1 "$c2" --train 77 --ignore-check release) || { WHY="the train's move refused past derived reds: $(printf '%s' "$out" | tail -3 | tr '\n' '|')"; rm -rf "$d"; return 1; }
  [ "$(git --git-dir="$d/origin.git" rev-parse refs/tags/stable)" = "$c2" ] || { WHY="stable did not move to the train's commit"; rm -rf "$d"; return 1; }
  # a move by hand on the next commit: the failed publish + move are passed over and named
  out=$(mv1 "$c3") || { WHY="a move by hand refused on a failed publish / move run: $(printf '%s' "$out" | tail -3 | tr '\n' '|')"; rm -rf "$d"; return 1; }
  case "$out" in *'passed over (a release workflow'*'publish stable'*) ;; *) WHY="the passed-over publish is not named: $out"; rm -rf "$d"; return 1 ;; esac
  [ "$(git --git-dir="$d/origin.git" rev-parse refs/tags/stable)" = "$c3" ] || { WHY="stable did not move past the derived reds"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="提交上留着一次失败的发布和一次失败的挪动：下一趟列车照常挪 stable，手挪也不再要逐个 --ignore-check；旧的自动三条路已退"
}

# A late train is not a red one (issue #3143): run 38139898013 went red on the
# hub's 409 because stable had been moved past its TRAIN_SHA by hand mid-run.
drill_train_superseded_red() {
  CAP=30
  local t0 d out rc wf c1 c2 c3
  wf="$BIN/../.github/workflows/release-train.yml"
  grep -q 'fleet-train-superseded.sh "$TRAIN_SHA"' "$wf" || { WHY="release-train.yml never asks fleet-train-superseded.sh"; return 1; }
  [ "$(grep -c 'fleet-train-superseded.sh' "$wf")" -ge 3 ] || { WHY="release-train.yml asks before publishing but not again on a 409 / a refused move"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-sup.XXXXXX")
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/seed" 2>/dev/null || exit 1
    for i in 1 2 3; do echo "$i" >> "$d/seed/f"; git -C "$d/seed" add -A && git -C "$d/seed" commit -qm "c$i" || exit 1
      git -C "$d/seed" rev-parse HEAD > "$d/c$i"; done
    git -C "$d/seed" push -q origin HEAD:master && git clone -q "$d/origin.git" "$d/co" 2>/dev/null
  ) || { WHY="could not build the rig repo"; rm -rf "$d"; return 1; }
  c1=$(cat "$d/c1"); c2=$(cat "$d/c2"); c3=$(cat "$d/c3"); t0=$(now)
  sup() { env -u FLEET_HUB_URL GITHUB_OUTPUT="$d/out" GITHUB_STEP_SUMMARY="$d/sum" bash "$BIN/fleet-train-superseded.sh" "$@" --dir "$d/co" 2>&1; }
  # stable behind the train: not superseded — the train ships
  git --git-dir="$d/origin.git" update-ref refs/tags/stable "$c1"
  out=$(sup "$c2"); rc=$?
  [ "$rc" = 1 ] && grep -q '^superseded=false$' "$d/out" || { WHY="stable behind TRAIN_SHA was called superseded: $rc $out"; rm -rf "$d"; return 1; }
  # moved by hand past it (the 409 case), or exactly onto it: superseded, green
  for s in "$c3" "$c2"; do
    git --git-dir="$d/origin.git" update-ref refs/tags/stable "$s"; : > "$d/out"
    out=$(sup "$c2"); rc=$?
    [ "$rc" = 0 ] && grep -q '^superseded=true$' "$d/out" && case "$out" in "superseded: stable is at ${s:0:7}, already ahead"*) true ;; *) false ;; esac \
      || { WHY="stable at ${s:0:7} (≥ TRAIN_SHA) was not superseded: $rc $out"; rm -rf "$d"; return 1; }
  done
  grep -q 'superseded: stable is at' "$d/sum" || { WHY="the summary does not say superseded"; rm -rf "$d"; return 1; }
  # the hub's stable ahead while the tag lags (a publish landed, the tag push did not)
  git --git-dir="$d/origin.git" update-ref refs/tags/stable "$c1"
  mkdir -p "$d/hub/v1/fleet/release"; printf '{"sha": "%s"}\n' "$c3" > "$d/hub/v1/fleet/release/stable"
  out=$(sup "$c2" --hub "file://$d/hub"); rc=$?
  [ "$rc" = 0 ] && case "$out" in *"the hub's stable"*) true ;; *) false ;; esac || { WHY="the hub's stable ahead was not superseded: $rc $out"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="stable 被手动挪过了 TRAIN_SHA（或入口 stable 已在前面）：release 写 superseded、以成功收场，不再被 409 打红；stable 落后则照常发"
}

cred_run_drills "$0"
