#!/bin/bash
# fleet-break-it-ci-selftest.sh — the docs/dev/BREAK-IT.md rows of the machine's test
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
#   train-own-mac-one-shard  one of our Macs free (or fewer than the full suite
#                       needs at 35 minutes a shard): the pick is GitHub's Macs,
#                       never the whole suite in one shard on ours (#4672)
#   train-own-runner-silent  our runner said idle but never took the shard: the
#                       train's watcher reds + cancels it at the deadline (#3145)
#   train-ack-down      FLEET_TRAIN_RUNNER=fleet-ack but no fleet-ack runner online,
#                       no token or no answer: the Linux half runs on ubuntu-latest,
#                       saying 深圳不可用; the variable empty asks nothing (#3864)
#   train-ack-reclaimed a spot node reclaimed mid-shard: the lost shard is not red,
#                       fail-fast waits for its rescue; a test's red still cancels (#3864)
#   train-shard-timeout  stable far behind, a near-full selection: the train sizes
#                       its shards by the forecast and reruns a shard cut short
#                       with no test red once — never one with a FAIL line (#3241)
#   train-shards-over-slots  the train in the Shenzhen pool cut more shards than it
#                       has free slots (or fewer than it needs): the plan sizes by the
#                       pool's slots, ≤ 44, a test over 75 s alone (#3865)
#   train-red-holds-lane    one Linux shard red while macOS runs on: the train's
#                       fail-fast cancels the run at once (#3143)
#   train-derived-red       a failed publish run and a failed move run on the
#                       commit: the next train moves stable anyway, no hand
#                       --ignore-check; the old auto roads are gone (#3143)
#   train-superseded-red    stable moved past TRAIN_SHA mid-run: the train's release
#                       ends green saying superseded, not red on the 409 (#3143)
#   train-hub-backwards     the hub was deployed by hand past TRAIN_SHA: the train's
#                       hub plan skips the deploy (superseded), never rolls it back (#3319)
#   train-prebuild-wrong-sha  the hub image built beside the tests is pushed over
#                       before the deploy (another sha's build, a hand push): the
#                       deploy phase refuses it — digest and revision (#3867)
#   hub-pause-train-queued  HUB_DEPLOY_PAUSED set while a train waited in the lane:
#                       GitHub fixed `vars` at queue time; the gate also reads an open
#                       hub-deploy-paused issue live, unreadable ⇒ red (#4621)
#   train-call-permissions  a caller job grants less than a job of the workflow it
#                       calls asks (even one its `if:` skips): GitHub refuses the
#                       whole train at parse time (startup_failure, #3908);
#                       fleet-workflow-perms.py reds it — release-train.yml,
#                       hub-deploy.yml, selftests-shards.yml and every caller
#   oss-internal-name-committed  a PR adds a line holding a private address: the
#                       oss-scan gate (the REAL rule table) reds it; `# oss-ok:` greens
#                       it; .github/workflows/oss-scan.yml runs it on every PR (#3572)
#   go-install-replace  tokenledger/go.mod replaces its shared module with ./shared
#                       (#4811), and `go install …/cmd/ccquota@<v>` refuses any module
#                       with a replace: a bin/ script still spelling it reds
#                       tokenledger-modules-selftest.sh (run in a sandbox repo, for real)
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
  wf="$BIN/../.github/workflows/mac-follow.yml"
  grep -q 'fleet-train-macos.sh pick' "$wf" && grep -q 'runs_on: ${{ needs.board.outputs.macos_runs_on }}' "$wf" \
    || { WHY="mac-follow.yml does not take the macOS runner from board's pick"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-pick.XXXXXX"); t0=$(now)
  printf '%s' '{"runners":[{"machine":"mac-c","online":true,"runner":{"state":"idle"}},{"machine":"mac-d","online":true,"runner":{"state":"busy"}}]}' > "$d/up.json"
  printf '%s' '{"runners":[{"machine":"mac-c","online":true,"runner":{"state":"paused","why":"load"}},{"machine":"mac-d","online":false,"runner":{"state":"idle"}}]}' > "$d/down.json"
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

# One of our Macs free used to be one shard of the WHOLE suite on it: run
# 39094216976 cut at 3606 s, exit 124 — mac-a runs ×6.6 the fleet-ci table
# (issue #4672). The pick wants --need runners (default 2) or it goes to GitHub's.
drill_train_own_mac_one_shard() {
  CAP=30
  local t0 d out wf
  wf="$BIN/../.github/workflows/mac-follow.yml"
  grep -q 'fleet-train-macos.sh pick --need' "$wf" && grep -q -- '--scale "$FLEET_CI_SCALE"' "$wf" \
    || { WHY="mac-follow.yml does not size our Macs' need off the forecast"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-one.XXXXXX"); t0=$(now)
  printf '%s' '{"runners":[{"machine":"mac-a","online":true,"runner":{"state":"idle"}},{"machine":"mac-b","online":true,"runner":{"state":"paused"}}]}' > "$d/one.json"
  printf '%s' '{"runners":[{"machine":"mac-c","online":true,"runner":{"state":"idle"}},{"machine":"mac-d","online":true,"runner":{"state":"busy"}}]}' > "$d/two.json"
  pick() { bash "$BIN/fleet-train-macos.sh" pick "$@" 2>/dev/null; }
  out=$(pick --runners-file "$d/one.json")
  case "$out" in *'macos_runs_on=["macos-latest"]'*'macos_shards=[1, 2]'*'macos_where=github'*'1 of ours'*) ;;
    *) WHY="one Mac of ours free, the pick was not GitHub's: $out"; rm -rf "$d"; return 1 ;; esac
  out=$(pick --runners-file "$d/two.json" --need 8)
  case "$out" in *'macos_where=github'*'need 8'*) ;;
    *) WHY="two Macs of ours but the suite needs 8, the pick was not GitHub's: $out"; rm -rf "$d"; return 1 ;; esac
  out=$(pick --runners-file "$d/two.json" --need 2)
  case "$out" in *'macos_runs_on=["self-hosted","macOS","fleet-ci"]'*'macos_shards=[1, 2]'*) ;;
    *) WHY="two Macs of ours, need 2: not fleet-ci × 2: $out"; rm -rf "$d"; return 1 ;; esac
  out=$(pick --runners-file "$d/one.json" --need 1)
  case "$out" in *'macos_shards=[1]'*'macos_where=fleet-ci'*) ;;
    *) WHY="a small selection (need 1) on one Mac of ours was not fleet-ci × 1: $out"; rm -rf "$d"; return 1 ;; esac
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="自家 Mac 只有 1 台空闲（或少于全量按每片 35 分钟要的台数）：选 GitHub 的 Mac，不再把整套塞进自家 1 片跑到 exit 124；够数才用自家"
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
  printf '%s' '{"jobs":[{"name":"macOS / shard 1","status":"in_progress","created_at":"2026-10-11T01:00:00Z","started_at":"2026-10-11T01:01:30Z","runner_name":"fleet-ci-mac-c-1"},{"name":"macOS / shard 2","status":"completed","conclusion":"success","created_at":"2026-10-11T01:00:00Z","started_at":"2026-10-11T01:00:20Z","runner_name":"fleet-ci-mac-d-1"}]}' > "$d/jobs.json"
  out=$(FAKE_DIR=$d FLEET_TRAIN_GH="$d/gh" GITHUB_STEP_SUMMARY="$d/sum" \
    bash "$BIN/fleet-train-macos.sh" watch --repo o/r --run 77 --where fleet-ci --deadline 5 --every 1 2>&1); rc=$?
  [ "$rc" = 0 ] && grep -q 'fleet-ci-mac-c-1 | 1m30s' "$d/sum" && grep -q 'fleet-ci-mac-d-1 | 0m20s' "$d/sum" \
    || { WHY="started shards: exit $rc, summary $(cat "$d/sum" 2>/dev/null)"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="自家测试机报 idle 却不接：到点这趟红、摘要写「自家测试机没接」、整趟取消；接了就记每片的机器和排队时间"
}

# The release train's Linux half in the Shenzhen cluster (issue #3864, EPIC #3863
# C1): fleet-ack when asked and up, ubuntu-latest otherwise — the train runs either way.
drill_train_ack_down() {
  CAP=30
  local t0 d out wf
  [ -x "$BIN/fleet-train-runner.sh" ] || { WHY="no bin/fleet-train-runner.sh"; return 1; }
  wf="$BIN/../.github/workflows/release-train.yml"
  grep -q "runs_on: \${{ needs.linux-pick.outputs.linux_runs_on || 'ubuntu-latest' }}" "$wf" \
    || { WHY="release-train.yml's Linux half does not fall back to ubuntu-latest without a pick"; return 1; }
  sed -n '/^  linux-pick:/,/^  linux:/p' "$wf" | grep -q "vars.FLEET_TRAIN_RUNNER != ''" \
    || { WHY="linux-pick runs with FLEET_TRAIN_RUNNER empty"; return 1; }
  # a job after `train` reads train's verdict, never the implicit success(): train
  # runs under always() beside jobs skipped on most trains (run 38375663311 went
  # green and its hub plan / release were skipped)
  out=$(awk 'function judge() { if (cond != "" && nd ~ /[[ ,]train[],]/ && cond !~ /always\(\)|cancelled\(\)/) print job; cond = "" }
             /^  [a-z-]+:$/ { judge(); job = $1; nd = "" } /^    needs:/ { nd = $0 }
             /^    if:/ { cond = $0; inif = 1; next } inif && /^      / { cond = cond $0; next } { inif = 0 }
             END { judge() }' "$wf")
  [ -z "$out" ] || { WHY="jobs after train with an implicit success(): $out"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-ack.XXXXXX"); t0=$(now)
  printf '%s' '{"runners":[{"name":"fleet-ack-cpvr9-runner-lflzh","status":"online","busy":true,"labels":[]},{"name":"mac","status":"online","labels":[{"name":"fleet-ci"}]}]}' > "$d/up.json"
  printf '%s' '{"runners":[{"name":"fleet-ack-cpvr9-runner-lflzh","status":"offline","labels":[]},{"name":"fleet-acker-1","status":"online","labels":[{"name":"other"}]},{"name":"mac","status":"online","labels":[{"name":"fleet-ci"}]}]}' > "$d/down.json"
  printf '%s' '{"total_count":0,"runners":[]}' > "$d/zero.json"
  pick() { GITHUB_OUTPUT="$d/out" FLEET_TRAIN_GIT_MIRROR=git://mirror/claude-fleet.git bash "$BIN/fleet-train-runner.sh" pick "$@" 2>/dev/null; }
  out=$(FLEET_TRAIN_RUNNER='' pick --runners-file "$d/up.json")
  case "$out" in *'linux_runs_on=ubuntu-latest'*'linux_where=github'*'linux_mirror='|*'linux_mirror='$'\n'*) ;;
    *) WHY="the variable empty, the pick was not ubuntu-latest: $out"; rm -rf "$d"; return 1 ;; esac
  out=$(FLEET_TRAIN_RUNNER=fleet-ack pick --runners-file "$d/up.json")
  case "$out" in *'linux_runs_on=["fleet-ack"]'*'linux_where=fleet-ack'*'linux_mirror=git://mirror/claude-fleet.git'*) ;;
    *) WHY="a fleet-ack runner online, the pick was not fleet-ack + the mirror: $out"; rm -rf "$d"; return 1 ;; esac
  for c in down zero notoken; do
    case "$c" in
      down)    out=$(FLEET_TRAIN_RUNNER=fleet-ack pick --runners-file "$d/down.json") ;;
      zero)    out=$(FLEET_TRAIN_RUNNER=fleet-ack pick --runners-file "$d/zero.json") ;;
      notoken) out=$(FLEET_TRAIN_RUNNER=fleet-ack FLEET_TRAIN_RUNNER_TOKEN='' pick --repo o/r) ;;
    esac
    case "$out" in *'linux_runs_on=ubuntu-latest'*'linux_where=github'*'深圳不可用，退回 GitHub'*) ;;
      *) WHY="($c) the train did not fall back to ubuntu-latest saying 深圳不可用: $out"; rm -rf "$d"; return 1 ;; esac
    case "$out" in *'linux_mirror=git'*) WHY="($c) a GitHub runner was handed the cluster mirror"; rm -rf "$d"; return 1 ;; esac
  done
  grep -q '^linux_runs_on=' "$d/out" || { WHY="the pick wrote nothing to GITHUB_OUTPUT"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="fleet-ack 缩到 0 / 离线 / 没令牌：Linux 退回 ubuntu-latest、摘要写深圳不可用；有在线的才排 fleet-ack + 集群镜像；变量空什么都不问"
}

drill_train_ack_reclaimed() {
  CAP=30
  local t0 d out rc wf
  wf="$BIN/../.github/workflows/release-train.yml"
  # the job's own lines only, read to the end: a `grep -q` leaving a 35 KB sed
  # mid-write is SIGPIPE, red under pipefail on a Mac's small pipe (#4152)
  awk '/^  linux-rescue:/{f=1;next} f&&/^  [A-Za-z0-9_-]+:/{f=0} f' "$wf" \
    | grep -F 'of: ${{ needs.linux-rescue-plan.outputs.total }}' >/dev/null \
    || { WHY="release-train.yml has no Linux rescue keeping K/N"; return 1; }
  grep -q -- '--lost-ok "$LOST_OK"' "$wf" || { WHY="fail-fast is not told a lost Linux runner is no red"; return 1; }
  grep -q -- '--ignore-check "Linux / shard $k"' "$wf" || { WHY="the move does not pass over a rescued shard"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-reclaim.XXXXXX"); t0=$(now)
  # a fake gh: jobs from $d/jobs.tsv, annotations by job id, `run cancel` recorded
  cat > "$d/gh" <<'G'
#!/bin/bash
case "$*" in
  *check-runs/12/annotations*) echo 'The self-hosted runner: fleet-ack-8x2kq-runner-p4 lost communication with the server. Verify the machine is running and has a healthy network connection.' ;;
  *check-runs/*/annotations*)  echo 'Process completed with exit code 1.' ;;
  run\ cancel*) echo "$3" >> "$FAKE_DIR/cancelled" ;;
  *'[.id,'*jobs*|*jobs*'[.id,'*) awk -F'\t' 'NF >= 4 { print $4 "\t" $2 "\t" $3 }' "$FAKE_DIR/jobs.tsv" ;;   # lost's columns
  *jobs*) cat "$FAKE_DIR/jobs.tsv" ;;
esac
G
  chmod +x "$d/gh"
  ff() { FAKE_DIR=$d FLEET_TRAIN_GH="$d/gh" GITHUB_STEP_SUMMARY="$d/sum" \
           bash "$BIN/fleet-train-failfast.sh" --repo o/r --run 77 --every 1 --deadline "$1" --lost-ok Linux 2>&1; }
  # shard 2's node was reclaimed: not red — the rescue is awaited, nothing cancelled
  printf 'completed\tsuccess\tboard\t1\ncompleted\tsuccess\tprecheck\t2\ncompleted\tsuccess\tLinux / shard 1\t11\ncompleted\tfailure\tLinux / shard 2\t12\ncompleted\tsuccess\tmacOS / shard 1\t21\n' > "$d/jobs.tsv"
  out=$(ff 2); rc=$?
  [ "$rc" = 0 ] && [ ! -f "$d/cancelled" ] && case "$out" in *'no verdict'*) true ;; *) false ;; esac \
    || { WHY="a shard whose runner went away was judged (exit $rc, cancel $(cat "$d/cancelled" 2>/dev/null)): $out"; rm -rf "$d"; return 1; }
  # its rescue green: the train is green
  printf 'completed\tsuccess\tLinux rescue / shard 2\t31\n' >> "$d/jobs.tsv"
  out=$(ff 30); rc=$?
  [ "$rc" = 0 ] && [ ! -f "$d/cancelled" ] && case "$out" in *'finished green'*) true ;; *) false ;; esac \
    || { WHY="lost + rescued green: exit $rc, cancel $(cat "$d/cancelled" 2>/dev/null): $out"; rm -rf "$d"; return 1; }
  # `lost` names exactly the lost shard, and covers
  out=$(FAKE_DIR=$d FLEET_TRAIN_GH="$d/gh" bash "$BIN/fleet-train-runner.sh" lost --repo o/r --run 77 2>/dev/null)
  case "$out" in *'lost=[2]'*'red=[]'*'total=2'*'covers=true'*) ;;
    *) WHY="lost did not name shard 2 of 2 as covered: $out"; rm -rf "$d"; return 1 ;; esac
  # a test's red on another shard: cancelled as ever, and the rescue does not cover it
  printf 'completed\tsuccess\tboard\t1\ncompleted\tfailure\tLinux / shard 2\t12\ncompleted\tfailure\tLinux / shard 3\t13\nin_progress\t\tmacOS / shard 1\t21\n' > "$d/jobs.tsv"
  out=$(ff 30); rc=$?
  [ "$rc" = 1 ] && [ "$(cat "$d/cancelled" 2>/dev/null)" = 77 ] && grep -q '红灯即停：Linux / shard 3' "$d/sum" \
    || { WHY="a test red beside a lost runner: exit $rc, cancel $(cat "$d/cancelled" 2>/dev/null): $out"; rm -rf "$d"; return 1; }
  out=$(FAKE_DIR=$d FLEET_TRAIN_GH="$d/gh" bash "$BIN/fleet-train-runner.sh" lost --repo o/r --run 77 2>/dev/null)
  case "$out" in *'lost=[2]'*'red=[3]'*'covers=false'*) ;;
    *) WHY="a test red was counted as a lost runner: $out"; rm -rf "$d"; return 1 ;; esac
  # without --lost-ok (the variable empty) a lost runner is red as before
  rm -f "$d/cancelled"
  printf 'completed\tsuccess\tboard\t1\ncompleted\tfailure\tLinux / shard 2\t12\n' > "$d/jobs.tsv"
  out=$(FAKE_DIR=$d FLEET_TRAIN_GH="$d/gh" GITHUB_STEP_SUMMARY="$d/sum" \
    bash "$BIN/fleet-train-failfast.sh" --repo o/r --run 77 --every 1 --deadline 5 2>&1); rc=$?
  [ "$rc" = 1 ] || { WHY="without --lost-ok a lost shard was not red: exit $rc: $out"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="抢占回收一台：丢 runner 的那片不算红、等它在 ubuntu-latest 上按原 K/N 补跑，补跑绿列车照发；旁边有真红照旧取消；变量空一切照旧"
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
  grep -q 'fleet-shard-run.sh --budget "$SHARD_BUDGET_SECS"' "$sh" && grep -q "inputs.step_minutes != ''" "$sh" \
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

# The Shenzhen pool's width (issue #3865, EPIC #3863 C2): the train in the pool sizes
# its Linux half by the free runner slots — ceil(total / 75 s), ≤ the slots, ≤ 44 —
# not the PR's 12..20: a shard past the slots only queues for a second round, and 12
# shards on 14 slots leave the slowest at 6 minutes.
drill_train_shards_over_slots() {
  CAP=60
  local t0 d out wf sh n c
  [ -x "$BIN/fleet-train-plan.sh" ] && [ -x "$BIN/fleet-train-runner.sh" ] \
    || { WHY="no bin/fleet-train-plan.sh / bin/fleet-train-runner.sh"; return 1; }
  wf="$BIN/../.github/workflows/release-train.yml"; sh="$BIN/../.github/workflows/selftests-shards.yml"
  sed -n '/^  plan:/,/^  linux-pick:/p' "$wf" | grep -q 'needs: \[board, linux-pick\]' \
    && grep -q 'fleet-train-plan.sh --base "$STABLE" --prefix linux ${SLOTS:+--slots "$SLOTS"}' "$wf" \
    && [ "$(grep -c 'solo_secs: ${{ needs.plan.outputs.linux_solo_secs }}' "$wf")" = 2 ] \
    || { WHY="release-train.yml does not size the Linux half by the pick's slots (plan ← linux-pick, --slots, solo on linux + rescue)"; return 1; }
  grep -q 'set -- --solo "$SHARD_SOLO_SECS"' "$sh" \
    || { WHY="selftests-shards.yml does not pass --solo"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-slots.XXXXXX"); t0=$(now)
  # 1) the pick counts the slots: 14 a node, nodes = ceil(online / 14) ≥ 1, ≤ 44
  for c in 1:14 15:28 100:44; do
    n=${c%%:*}
    python3 -c 'import json,sys; n=int(sys.argv[1]); print(json.dumps({"runners":[{"name":"a%d"%i,"status":"online","busy":i>1,"labels":[{"name":"fleet-ack"}]} for i in range(n)]}))' "$n" > "$d/r.json"
    out=$(FLEET_TRAIN_RUNNER=fleet-ack bash "$BIN/fleet-train-runner.sh" pick --runners-file "$d/r.json" 2>/dev/null)
    case "$out" in *"linux_slots=${c#*:}"*) ;;
      *) WHY="$n online fleet-ack runners were not ${c#*:} slots: $out"; rm -rf "$d"; return 1 ;; esac
  done
  out=$(FLEET_TRAIN_RUNNER='' bash "$BIN/fleet-train-runner.sh" pick 2>/dev/null)
  case "$out" in *'linux_slots='|*'linux_slots='$'\n'*) ;;
    *) WHY="GitHub's runners were given slots: $out"; rm -rf "$d"; return 1 ;; esac
  # 2) the plan: N = clamp(ceil(total / 75), 1, slots ≤ 44); past 75 + 180 s a slot the pool's 44
  cat > "$d/rs" <<'R'
#!/bin/bash
n=1 solo=''; while [ $# -gt 0 ]; do case $1 in --shard) n=${2#1/} ;; --solo) solo=$2 ;; esac; shift; done
[ -n "$solo" ] || [ -z "$WANT_SOLO" ] || exit 9
echo "plan tests=$T total=$TOT shards=$n heaviest=$(( TOT / n ))"
R
  chmod +x "$d/rs"
  plan() { T=$1 TOT=$2 WANT_SOLO=${4:+1} FLEET_TRAIN_PLAN_CMD="$d/rs" bash "$BIN/fleet-train-plan.sh" --base x --prefix linux ${4:+--slots "$4"} 2>&1; }
  for c in '10 120 2 14' '60 900 12 14' '175 2100 14 14' '175 2100 28 42' '496 5830 28 28' '496 5830 44 14' '496 5830 44 60' '0 0 1 14'; do
    set -- $c
    out=$(plan "$1" "$2" x "$4")
    n=$(printf '%s\n' "$out" | sed -n 's/^linux_shards=\[\(.*\)\]$/\1/p' | tr ',' '\n' | grep -c .)
    [ "$n" = "$3" ] && printf '%s\n' "$out" | grep -q '^linux_solo_secs=75$' \
      && printf '%s\n' "$out" | grep -q "^linux_slots=$(( $4 > 44 ? 44 : $4 ))$" \
      || { WHY="$2 s on $4 slots was not $3 shards with --solo 75 (got $n): $(printf '%s' "$out" | tr '\n' ' ')"; rm -rf "$d"; return 1; }
  done
  out=$(plan 10 120 x 14)
  printf '%s\n' "$out" | grep -q '^linux_budget_secs=150$' && printf '%s\n' "$out" | grep -q '^linux_step_minutes=7$' \
    || { WHY="a small train in the pool did not get 150 s an attempt: $(printf '%s' "$out" | tr '\n' ' ')"; rm -rf "$d"; return 1; }
  # 3) GitHub's runners: no --slots, the PR's width and every line as before
  out=$(plan 10 120 x '')
  [ "$out" = "$(printf 'linux_shards=[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]\nlinux_tests=10\nlinux_predicted=120\nlinux_heaviest=10\nlinux_budget_secs=480\nlinux_step_minutes=18\nlinux_job_minutes=28')" ] \
    || { WHY="without --slots the plan changed: $(printf '%s' "$out" | tr '\n' ' ')"; rm -rf "$d"; return 1; }
  # 4) a forecast that cannot be made in the pool: every slot, the PR's 8 minutes
  printf '#!/bin/bash\nexit 3\n' > "$d/rs"
  out=$(FLEET_TRAIN_PLAN_CMD="$d/rs" bash "$BIN/fleet-train-plan.sh" --base x --prefix p --slots 28 2>&1)
  printf '%s\n' "$out" | grep -q '^p_budget_secs=480$' && [ "$(printf '%s\n' "$out" | sed -n 's/^p_shards=//p' | tr -cd , | wc -c | tr -d ' ')" = 27 ] \
    || { WHY="an unpriceable train in the pool was not 28 × 480 s: $(printf '%s' "$out" | tr '\n' ' ')"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="深圳池里：片数 = ⌈合计÷75⌉、不超空机位（14/台、≤44），一机位压过 255 s 才开满 44 让池子扩；单测超 75 s 独占一片、每次上限 150 s；GitHub 上一字不变"
}

# A near-full selection on GitHub's 2 Macs is slow, not hung (issue #3412): runs
# 38155516543 / 38159508733 ran 505 tests on 2 macOS shards, ~90 minutes each, and
# were cancelled as "hung" while every test was still finishing. GitHub's Macs now
# take the plan's width (2..4, ≤ 40 minutes a shard), and a test that does hang is a
# TIMEOUT line by name that the train records as red.
drill_train_macos_slow_not_hung() {
  CAP=30
  local t0 d out wf sh
  wf="$BIN/../.github/workflows/mac-follow.yml"; sh="$BIN/../.github/workflows/selftests-shards.yml"
  grep -q -- '--prefix macos --min "$n" --max 4 --target 2400' "$wf" \
    && grep -q 'shards: ${{ needs.plan.outputs.macos_shards || needs.board.outputs.macos_shards }}' "$wf" \
    || { WHY="mac-follow.yml's GitHub Macs do not take their width from the plan"; return 1; }
  grep -q "grep -E '^(FAIL|TIMEOUT|QUARANTINE|FLAKY) ' selftests.log > train-result.txt" "$sh" \
    || { WHY="selftests-shards.yml does not record a TIMEOUT line for the train"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-macos.XXXXXX"); t0=$(now)
  cat > "$d/rs" <<'R'
#!/bin/bash
n=1; while [ $# -gt 0 ]; do [ "$1" = --shard ] && n=${2#1/}; shift; done
echo "select: * ← full suite"; echo "plan tests=505 total=${TOTAL:-4900} shards=$n heaviest=$(( ${TOTAL:-4900} / n + 120 ))"
R
  chmod +x "$d/rs"
  # the full suite (the ubuntu table's 4900 s, ×2.3): 4 shards, not 2
  out=$(FLEET_TRAIN_PLAN_CMD="$d/rs" bash "$BIN/fleet-train-plan.sh" --base x --prefix macos --min 2 --max 4 --target 2400 --scale 2.3 --floor 3000 2>&1)
  case "$out" in *'macos_shards=[1, 2, 3, 4]'*'macos_budget_secs=4641'*) ;;
    *) WHY="a full-suite selection on GitHub's Macs was not planned 4 wide: $out"; rm -rf "$d"; return 1 ;; esac
  # a small selection keeps board's 2
  out=$(TOTAL=300 FLEET_TRAIN_PLAN_CMD="$d/rs" bash "$BIN/fleet-train-plan.sh" --base x --prefix macos --min 2 --max 4 --target 2400 --scale 2.3 --floor 3000 2>&1)
  case "$out" in *'macos_shards=[1, 2]'*'macos_budget_secs=3000'*) ;;
    *) WHY="a small selection did not keep 2 × 3000 s: $out"; rm -rf "$d"; return 1 ;; esac
  # a hung test is a TIMEOUT line by name; the train's record counts it red
  printf 'PASS  a-selftest.sh  1s\nTIMEOUT hung-selftest.sh  600.0s (limit 600s)\n' > "$d/selftests.log"
  (cd "$d" && grep -E '^(FAIL|TIMEOUT|QUARANTINE|FLAKY) ' selftests.log > train-result.txt)
  mkdir -p "$d/res/train-result-macOS-1" && mv "$d/train-result.txt" "$d/res/train-result-macOS-1/"
  grep -q '^TIMEOUT hung-selftest.sh' "$d/res/train-result-macOS-1/train-result.txt" \
    && grep -q 'awk .$1 == "FAIL" || $1 == "TIMEOUT"' "$BIN/fleet-train-quarantine.sh" \
    || { WHY="a TIMEOUT line does not reach the train's record"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="近全量 505 个测试在 GitHub 的 Mac 上：排 4 片（每片 ≤ 40 分钟），不是 2 片 × 90 分钟；小选择照旧 2 片；单条挂住的测试是带名字的 TIMEOUT 行，列车记成红"
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

# The hub deploy only moves forward (issue #3319): run 38139898013 (5e11587) rolled
# the hub back from a hand-deployed prod-15d87a1 to prod-5e11587, and #3297 fell
# off it. fleet-train-hub.sh reads the hub's /version `commit` first: TRAIN_SHA ⇒
# skip · a descendant or not an ancestor ⇒ skip, "hub superseded" · an ancestor ⇒
# deploy as before · unreadable / unknown ⇒ red, no blind deploy.
drill_train_hub_backwards() {
  CAP=30
  local t0 d out rc wf c1 c2 c3 c4 c5 s1 tr
  wf="$BIN/../.github/workflows/release-train.yml"
  grep -q 'bin/fleet-train-hub.sh "$SHA"' "$wf" || { WHY="release-train.yml's hub plan does not run fleet-train-hub.sh"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-hubb.XXXXXX")
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/seed" 2>/dev/null || exit 1
    mkdir -p "$d/seed/tokenledger/internal/x" "$d/seed/deploy/k8s"
    printf 'module x\n' > "$d/seed/tokenledger/go.mod"; printf 'a: 1\n' > "$d/seed/deploy/k8s/k.yaml"
    for i in 1 2 3; do printf 'package x\n\nconst Y = %s\n' "$i" > "$d/seed/tokenledger/internal/x/x.go"
      git -C "$d/seed" add -A && git -C "$d/seed" commit -qm "c$i" || exit 1
      git -C "$d/seed" rev-parse HEAD > "$d/c$i"
      [ "$i" != 1 ] || { git -C "$d/seed" branch side
        git -C "$d/seed" checkout -q side && printf 'package x\n\nconst Y = 9\n' > "$d/seed/tokenledger/internal/x/x.go" \
          && git -C "$d/seed" commit -qam side && git -C "$d/seed" rev-parse HEAD > "$d/s1" && git -C "$d/seed" push -q origin side \
          && git -C "$d/seed" checkout -q master || exit 1; }
    done
    # c4 changes only the console (packed into the image), c5 only the retired chat page
    mkdir -p "$d/seed/extras/web-console/dist" "$d/seed/extras/web-chat/ui"
    printf 'console\n' > "$d/seed/extras/web-console/dist/index.html"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm c4 && git -C "$d/seed" rev-parse HEAD > "$d/c4" || exit 1
    printf 'chat\n' > "$d/seed/extras/web-chat/ui/index.html"
    git -C "$d/seed" add -A && git -C "$d/seed" commit -qm c5 && git -C "$d/seed" rev-parse HEAD > "$d/c5" || exit 1
    git -C "$d/seed" push -q origin HEAD:master && git clone -q "$d/origin.git" "$d/co" 2>/dev/null
  ) || { WHY="could not build the rig repo"; rm -rf "$d"; return 1; }
  c1=$(cat "$d/c1"); c2=$(cat "$d/c2"); c3=$(cat "$d/c3"); c4=$(cat "$d/c4"); c5=$(cat "$d/c5"); s1=$(cat "$d/s1"); mkdir -p "$d/hub"; t0=$(now)
  live() { printf '{"commit":"%.7s","version":"prod-%.7s"}\n' "$1" "$1" > "$d/hub/version"; }
  tr=$c2
  plan() { out=$(env -u RELEASE_TRAIN_HUB GITHUB_OUTPUT="$d/out" bash "$BIN/fleet-train-hub.sh" "$tr" --dir "$d/co" --hub "file://$d/hub" --timeout 5 2>&1); rc=$?; : > "$d/out"; }
  dep() { printf '%s\n' "$out" | sed -n 's/^deploy=//p' | head -1; }
  # the hub already runs TRAIN_SHA: skip
  live "$c2"; plan
  [ "$rc" = 0 ] && [ "$(dep)" = false ] || { WHY="a hub already on TRAIN_SHA was not skipped: $rc $(printf '%s' "$out" | tr '\n' '|')"; rm -rf "$d"; return 1; }
  # deployed by hand past it, or onto a fork: never rolled back, the step stays green
  for s in "$c3" "$s1"; do
    live "$s"; plan
    [ "$rc" = 0 ] && [ "$(dep)" = false ] && printf '%s' "$out" | grep -q "hub superseded: live is ${s:0:7}" \
      || { WHY="a hub on ${s:0:7} (not behind TRAIN_SHA) would be redeployed backwards: $rc $(printf '%s' "$out" | tr '\n' '|')"; rm -rf "$d"; return 1; }
  done
  # behind TRAIN_SHA (its ancestor, Go changed since): deployed as before
  live "$c1"; plan
  [ "$rc" = 0 ] && [ "$(dep)" = true ] || { WHY="a hub behind TRAIN_SHA was not deployed: $rc $(printf '%s' "$out" | tr '\n' '|')"; rm -rf "$d"; return 1; }
  # only the console changed since the hub's commit (issue #4105): deployed
  tr=$c4; live "$c3"; plan
  [ "$rc" = 0 ] && [ "$(dep)" = true ] || { WHY="a console-only change was not deployed: $rc $(printf '%s' "$out" | tr '\n' '|')"; rm -rf "$d"; return 1; }
  # only extras/web-chat/ui (no longer in the image): skipped
  tr=$c5; live "$c4"; plan
  [ "$rc" = 0 ] && [ "$(dep)" = false ] || { WHY="a web-chat/ui-only change still redeployed the hub: $rc $(printf '%s' "$out" | tr '\n' '|')"; rm -rf "$d"; return 1; }
  tr=$c2
  # /version unreadable, or a commit nobody here knows: red, no blind deploy
  rm -f "$d/hub/version"; plan
  [ "$rc" != 0 ] && [ "$(dep)" != true ] || { WHY="an unreadable /version still decided ($rc): $(printf '%s' "$out" | tr '\n' '|')"; rm -rf "$d"; return 1; }
  printf '{"commit":"abcdef1","version":"prod-abcdef1"}\n' > "$d/hub/version"; plan
  [ "$rc" != 0 ] && [ "$(dep)" != true ] || { WHY="a hub commit the checkout cannot place still decided ($rc): $(printf '%s' "$out" | tr '\n' '|')"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="入口已在 TRAIN_SHA 跳过；入口被手动部署到它之后或分叉的提交：不部署、写 hub superseded、这步绿；入口落后照常部署；只改控制台照常部署、只改 web-chat/ui 不部署；读不到 /version 或认不出提交：红，不盲部署"
}

# The pause switch must hold a train that is ALREADY queued (issue #4621): run
# 39036174481 was queued 13:20:46, HUB_DEPLOY_PAUSED=1 set 13:22:33, and its gate
# (13:34) read the variable empty — GitHub fixes `vars` when a run is queued — and
# deployed the hub. fleet-hub-pause.sh check also reads an open issue labelled
# hub-deploy-paused when the gate runs; that read failing is red.
drill_hub_pause_train_queued() {
  CAP=30
  local t0 d out rc wf
  wf="$BIN/../.github/workflows/hub-deploy.yml"
  awk '/^  gate:/{g=1} g&&/^  [a-z]/&&!/^  gate:/{g=0} g' "$wf" > "${TMPDIR:-/tmp}/hubgate.$$"
  grep -q 'bin/fleet-hub-pause.sh check --repo "$GITHUB_REPOSITORY" --sha "$INPUT_SHA" --var "$PAUSED"' "${TMPDIR:-/tmp}/hubgate.$$" \
    && grep -q 'issues: read' "${TMPDIR:-/tmp}/hubgate.$$" \
    || { WHY="hub-deploy.yml's gate does not run fleet-hub-pause.sh check with issues: read"; rm -f "${TMPDIR:-/tmp}/hubgate.$$"; return 1; }
  rm -f "${TMPDIR:-/tmp}/hubgate.$$"
  d=$(mktemp -d "${TMPDIR:-/tmp}/hub-pause.XXXXXX"); t0=$(now)
  # a fake gh: the open issues labelled hub-deploy-paused are $d/issues, $d/down = the API is down
  printf '#!/bin/bash\n[ ! -e "%s/down" ] || exit 1\ncat "%s/issues" 2>/dev/null\n' "$d" "$d" > "$d/gh"; chmod +x "$d/gh"
  chk() { out=$(GH="$d/gh" FLEET_HUB_PAUSE_RETRY_SECS=0 GITHUB_OUTPUT='' bash "$BIN/fleet-hub-pause.sh" check --repo o/r "$@" 2>&1); rc=$?; }
  # the variable reached the run (set before it was queued): paused
  chk --sha abc1234 --var 1
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^paused=true$' || { WHY="HUB_DEPLOY_PAUSED=1 did not pause: $rc $out"; rm -rf "$d"; return 1; }
  # the train already queued (variable empty in its snapshot), a pause issue open: paused
  printf '#4700 入口自动部署已暂停\n' > "$d/issues"; chk --sha abc1234 --var ''
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^paused=true$' && printf '%s' "$out" | grep -q '#4700' \
    || { WHY="a queued train with a hub-deploy-paused issue open was not paused: $rc $out"; rm -rf "$d"; return 1; }
  # a person's dispatch (no train sha) is never paused
  chk --var 1
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^paused=false$' || { WHY="a person's dispatch was paused: $rc $out"; rm -rf "$d"; return 1; }
  # nothing open, variable empty: deploys
  : > "$d/issues"; chk --sha abc1234 --var ''
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^paused=false$' || { WHY="no pause still paused: $rc $out"; rm -rf "$d"; return 1; }
  # the switch unreadable: red, never a blind deploy
  : > "$d/down"; chk --sha abc1234 --var ''
  [ "$rc" = 1 ] && ! printf '%s' "$out" | grep -q '^paused=true$' || { WHY="an unreadable pause switch did not go red: $rc $out"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="变量在列车排队后才设（vars 排队时就定了）：门在运行时读到开着的 hub-deploy-paused 单 ⇒ 暂停、不部署入口；变量排队前设了也暂停；手动 dispatch 不受影响；读不到暂停开关 ⇒ 红，不盲部署"
}

# The repo is public (EPIC #3569): a PR that adds an internal address used to merge
# like any other line. bin/oss-scan.sh --gate (issue #3572) reds it, read off the
# REAL conf/oss-scan.rules + conf/oss-scan.allow, on every PR (oss-scan.yml, no paths).
# The hub image built BESIDE the tests (issue #3867, EPIC #3863 C4): the deploy
# phase deploys only the digest its build phase reported, of TRAIN_SHA's revision.
drill_train_prebuild_wrong_sha() {
  CAP=30
  local t0 d out rc wf hd sha other good bad
  wf="$BIN/../.github/workflows/release-train.yml" hd="$BIN/../.github/workflows/hub-deploy.yml"
  sed -n '/^  hub:/,/^  hub-build:/p' "$wf" | grep -q 'digest: ${{ needs.hub-build.outputs.digest }}' \
    && sed -n '/^  hub:/,/^  hub-build:/p' "$wf" | grep -q 'phase: deploy' \
    && sed -n '/^  hub-build:/,/^  release-stage:/p' "$wf" | grep -q 'phase: build' \
    || { WHY="release-train.yml does not build the hub in one phase and deploy that digest in the other"; return 1; }
  [ "$(awk '/fleet-train-prebuild.sh verify/{print NR; exit}' "$hd")" -lt "$(awk '/- name: Apply$/{print NR; exit}' "$hd")" ] 2>/dev/null \
    || { WHY="hub-deploy.yml's deploy does not verify the prebuilt image before Apply"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-prebuild.XXXXXX"); t0=$(now)
  sha=$(printf 'a%.0s' $(seq 40)) other=$(printf 'b%.0s' $(seq 40))
  good="sha256:$(printf '1%.0s' $(seq 64))" bad="sha256:$(printf '2%.0s' $(seq 64))"
  # a fake `docker buildx imagetools`: the tag's digest + revision from $d/{digest,rev}
  cat > "$d/it" <<'IT'
#!/bin/bash
[ -s "$FAKE/digest" ] || exit 1
case "$*" in
  *'.Manifest'*) printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s"}\n' "$(cat "$FAKE/digest")" ;;
  *'.Image'*)    printf '{"architecture":"amd64","config":{"Labels":{"org.opencontainers.image.revision":"%s"}}}\n' "$(cat "$FAKE/rev")" ;;
esac
IT
  chmod +x "$d/it"
  pb() { out=$(FAKE=$d FLEET_IMAGETOOLS="$d/it" GITHUB_OUTPUT='' bash "$BIN/fleet-train-prebuild.sh" "$@" 2>&1); rc=$?; }
  echo "$good" > "$d/digest"; echo "$sha" > "$d/rev"
  pb verify r/hub prod-aaaaaaa "$sha" "$good"
  [ "$rc" = 0 ] || { WHY="the image this run built was refused ($rc): $out"; rm -rf "$d"; return 1; }
  echo "$bad" > "$d/digest"; echo "$other" > "$d/rev"
  pb verify r/hub prod-aaaaaaa "$sha" "$good"
  [ "$rc" = 1 ] && case "$out" in *'overtook'*) true ;; *) false ;; esac \
    || { WHY="another sha's build pushed over the tag was not refused ($rc): $out"; rm -rf "$d"; return 1; }
  echo "$good" > "$d/digest"
  pb verify r/hub prod-aaaaaaa "$sha" "$good"
  [ "$rc" = 1 ] && case "$out" in *"not the train's $sha"*) true ;; *) false ;; esac \
    || { WHY="an image of another revision was not refused ($rc): $out"; rm -rf "$d"; return 1; }
  : > "$d/digest"
  pb verify r/hub prod-aaaaaaa "$sha" "$good"
  [ "$rc" = 1 ] || { WHY="a tag that is gone was not refused ($rc): $out"; rm -rf "$d"; return 1; }
  # the next train on the same sha reuses its image — never another revision's
  echo "$good" > "$d/digest"; echo "$sha" > "$d/rev"
  pb look r/hub prod-aaaaaaa "$sha"
  case "$out" in *'reuse=true'*"digest=$good"*) ;; *) WHY="the same sha's image was not reused: $out"; rm -rf "$d"; return 1 ;; esac
  echo "$other" > "$d/rev"
  pb look r/hub prod-aaaaaaa "$sha"
  case "$out" in *'reuse=false'*) ;; *) WHY="another revision's image was reused: $out"; rm -rf "$d"; return 1 ;; esac
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="测试期间预构建的入口镜像被别的提交 / 手动推送盖掉：部署段核对 digest 与 revision 不符即停、什么都不动；同一 sha 的镜像下趟直接复用，别的 revision 不复用"
}

drill_train_call_permissions() {
  CAP=30
  local t0 d out rc wfd
  wfd="$BIN/../.github/workflows"; t0=$(now)
  out=$(python3 "$BIN/fleet-workflow-perms.py" 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="the repo's own workflows ask more than their callers grant ($rc): $out"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/train-perms.XXXXXX"); mkdir -p "$d/.github/workflows"
  cp "$wfd/release-train.yml" "$wfd/hub-deploy.yml" "$wfd/selftests-shards.yml" "$d/.github/workflows/"
  # #3893's grant: hub-build without issues: write (hub-deploy's deploy asks it)
  awk '/^  hub-build:/{b=1} /^  release-stage:/{b=0} !(b && /^      issues: write/)' \
    "$wfd/release-train.yml" > "$d/.github/workflows/release-train.yml"
  out=$(python3 "$BIN/fleet-workflow-perms.py" --root "$d" 2>&1); rc=$?
  [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q 'job hub-build → hub-deploy.yml job deploy: asks issues: write, granted none' \
    || { WHY="#3893's short grant was not red ($rc): $out"; rm -rf "$d"; return 1; }
  # a whole-workflow grant (no job permissions) counts too; the token's default is not judged
  printf 'permissions:\n  contents: read\njobs:\n  t:\n    uses: ./.github/workflows/hub-deploy.yml\n' > "$d/.github/workflows/c.yml"
  out=$(python3 "$BIN/fleet-workflow-perms.py" --root "$d" "$d/.github/workflows/c.yml" 2>&1); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'asks id-token: write, granted none' \
    || { WHY="a top-level grant too short was not red ($rc): $out"; rm -rf "$d"; return 1; }
  printf 'jobs:\n  t:\n    uses: ./.github/workflows/hub-deploy.yml\n' > "$d/.github/workflows/c.yml"
  python3 "$BIN/fleet-workflow-perms.py" --root "$d" "$d/.github/workflows/c.yml" >/dev/null 2>&1 \
    || { WHY="a caller with the token's default grant was judged"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="调用方 job 少给被调工作流某个 job 要的权限（#3893 的 hub-build 缺 issues: write）：fleet-workflow-perms.py 报出调用行与缺的那一项、exit 1；仓库自己的工作流全部通过"
}

drill_oss_internal_name_committed() {
  CAP=60
  local t0 d out rc wf ip
  wf="$BIN/../.github/workflows/oss-scan.yml"
  grep -q 'bin/oss-scan.sh --gate "origin/${{ github.base_ref }}"' "$wf" 2>/dev/null \
    && ! grep -q '^ *paths:' "$wf" \
    || { WHY="oss-scan.yml does not run the gate on every PR"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/oss-gate.XXXXXX"); t0=$(now)
  ip="10.$((20)).30.40"   # spelled so this file never holds one
  ( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q "$d/r" && git -C "$d/r" symbolic-ref HEAD refs/heads/master
    printf 'PORT = 80\n' > "$d/r/net.py"; git -C "$d/r" add -A && git -C "$d/r" commit -qm base
    git -C "$d/r" checkout -qb pr
    printf 'PORT = 80\nHOST = "%s"\n' "$ip" > "$d/r/net.py"; git -C "$d/r" commit -qam 'add a host'
  ) || { WHY="could not build the rig repo"; rm -rf "$d"; return 1; }
  bash "$BIN/oss-scan.sh" --root "$d/r" --baseline > "$d/base"
  gate() { out=$(bash "$BIN/oss-scan.sh" --root "$d/r" --baseline-file "$d/base" --gate master 2>&1); rc=$?; }
  gate
  [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q '^net.py:2 private-ipv4 — ' \
    || { WHY="a PR adding a private address was not red ($rc): $(printf '%s' "$out" | tr '\n' '|')"; rm -rf "$d"; return 1; }
  printf 'PORT = 80\nHOST = "%s"  # oss-ok: 演练用的假地址\n' "$ip" > "$d/r/net.py"
  ( GIT_CONFIG_GLOBAL=/dev/null git -C "$d/r" -c user.name=t -c user.email=t@t commit -qam exempt )
  gate
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '豁免 1 处' \
    || { WHY="the same line with # oss-ok: was not green ($rc): $(printf '%s' "$out" | tr '\n' '|')"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="PR 新增一行私网地址：门禁红，报 文件:行 规则；同一行写上 # oss-ok: <理由> 转绿并计入豁免；oss-scan.yml 每个 PR 都跑、不设路径过滤"
}

# ---- go-install-replace (#4811): the developer road built ccquota with `go install
# …/cmd/ccquota@latest`; a replace in tokenledger/go.mod makes Go refuse that. The
# modules selftest is copied into a sandbox repo with the real layout's shape and run:
# a planted `go install …@latest` is red, the checkout build the node-join uses is green.
drill_go_install_replace() {
  CAP=60
  local t0 d out rc p M=github.com/verkyyi/claude-fleet/tokenledger
  grep -qE "^replace $M/shared => \./shared$" "$BIN/../tokenledger/go.mod" 2>/dev/null \
    || { WHY="tokenledger/go.mod has no replace for shared (the premise of this row)"; return 1; }
  grep -nE "go[[:space:]]+install[[:space:]]+[^ ]*$M/[^ ]*@" "$BIN/fleet-node-join.sh" | grep -vE '^[0-9]+:[[:space:]]*#' \
    && { WHY="fleet-node-join.sh still runs go install …@<v>"; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/goinst.XXXXXX"); t0=$(now)
  mkdir -p "$d/bin" "$d/tokenledger/shared"
  cp "$BIN/tokenledger-modules-selftest.sh" "$BIN/tokenledger-split-shared.sh" "$d/bin/"
  printf 'module %s\n\ngo 1.25.0\n\nrequire %s/shared v0.0.0\n\nreplace %s/shared => ./shared\n' "$M" "$M" "$M" > "$d/tokenledger/go.mod"
  printf 'go 1.25.0\n\nuse (\n\t.\n\t./shared\n)\n' > "$d/tokenledger/go.work"
  printf 'module %s/shared\n\ngo 1.25.0\n' "$M" > "$d/tokenledger/shared/go.mod"
  for p in $(sed -n 's/^PKGS="\(.*\)"$/\1/p' "$BIN/tokenledger-split-shared.sh"); do
    mkdir -p "$d/tokenledger/shared/$p"; printf 'package %s\n' "$p" > "$d/tokenledger/shared/$p/x.go"
  done
  printf '#!/bin/sh\n(cd tokenledger && GOWORK=off go build -o x ./cmd/ccquota)\n' > "$d/bin/fleet-x.sh"
  out=$(bash "$d/bin/tokenledger-modules-selftest.sh" 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="the sandbox's checkout build was not green ($rc): $(printf '%s' "$out" | grep FAIL | head -2 | tr '\n' '|')"; rm -rf "$d"; return 1; }
  printf '#!/bin/sh\nGOBIN=x go install %s/cmd/ccquota@latest\n' "$M" > "$d/bin/fleet-x.sh"
  out=$(bash "$d/bin/tokenledger-modules-selftest.sh" 2>&1); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'fleet-x.sh:2:.*go install' \
    || { WHY="a planted go install …@latest was not red ($rc): $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; rm -rf "$d"; return 1; }
  SECS=$(since "$t0"); rm -rf "$d"
  WHAT="tokenledger/go.mod 带 replace：bin/ 里一行 go install …/cmd/ccquota@latest 让模块自测红（点名文件:行）；节点开发路改成克隆后 go build，自测绿"
}

cred_run_drills "$0"
