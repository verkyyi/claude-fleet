#!/bin/bash
# fleet-train-plan.sh --base <rev> [--dir <repo>] [--prefix <name>] [--durations <table>]
#                     [--scale <x>] [--shards <N> | --min <N> --max <N> --target <s>]
#                     [--factor <x>] [--floor <s>]
#   — how wide one release train's test half runs, and how long a shard may take
#   (issue #3241, EPIC #3139 C9).
#
# The train tests what changed since stable (拍板 2). With stable 20+ commits behind
# that set is close to the whole suite, and the matrix still had the PR's shape —
# 12 shards, an 8-minute step: run 38131987956's Linux shards 9 and 12 were cut off
# mid-suite (no test red), and the first macOS trains ran ~50 minutes a shard.
#
# So the train asks first: `run-selftests.sh --changed <base> --plan` prices the
# selection off bin/selftest-durations.txt (or --durations), and this picks
#   N       = ceil(total × scale / target), clamped to [min, max] — or --shards N
#             when the width is not the train's to choose (the macOS runners);
#   budget  = max(heaviest shard × scale × factor, floor) seconds — ONE attempt of
#             a shard (bin/fleet-shard-run.sh enforces it, and reruns a shard it
#             cut short once);
#   step    = minutes for the step: two attempts + 2 minutes;
#   job     = step + 10 minutes (checkout, tmux, the summary steps) — both held
#             under GitHub's 360-minute job ceiling (step ≤ 345, job ≤ 355: a
#             long macOS shard then gets its one attempt, maybe not the rerun).
# Prints, and appends to $GITHUB_OUTPUT when set, `<prefix>_<key>=<value>` for
# shards (a JSON list 1..N) · tests · predicted (total seconds) · heaviest ·
# budget_secs · step_minutes · job_minutes, and one table row to
# $GITHUB_STEP_SUMMARY. A plan that cannot be made (no git base, a runner error)
# prints why on stderr and answers --min shards at the floor — the train runs
# either way, it never stops on its own forecast.
#
# Defaults (ubuntu): target 360 s (≤ 6 minutes a shard), min 12 — the PR's width —
# max 20, factor 1.5, floor 480 s (the PR's 8 minutes), scale 1.
# FLEET_TRAIN_PLAN_CMD replaces `bash bin/run-selftests.sh` (the drill's seam).
set -uo pipefail

dir=. base='' prefix=plan dur='' scale=1 fixed='' min=12 max=20 target=360 factor=1.5 floor=480
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) dir=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    --prefix) prefix=$2; shift 2 ;;
    --durations) dur=$2; shift 2 ;;
    --scale) scale=$2; shift 2 ;;
    --shards) fixed=$2; shift 2 ;;
    --min) min=$2; shift 2 ;;
    --max) max=$2; shift 2 ;;
    --target) target=$2; shift 2 ;;
    --factor) factor=$2; shift 2 ;;
    --floor) floor=$2; shift 2 ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "fleet-train-plan: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$base" ] || { echo "fleet-train-plan: --base <rev> is required" >&2; exit 2; }
for v in "$min" "$max" "$target" "$floor" ${fixed:+"$fixed"}; do
  case "$v" in ''|*[!0-9]*|0) echo "fleet-train-plan: '$v' is not a positive whole number" >&2; exit 2 ;; esac
done

# plan_line <N> — the runner's one `plan …` line for an N-wide deal, or nothing.
plan_line() {
  local cmd
  if [ -n "${FLEET_TRAIN_PLAN_CMD:-}" ]; then cmd=$FLEET_TRAIN_PLAN_CMD
  else cmd="bash bin/run-selftests.sh"; fi
  # shellcheck disable=SC2086  # $cmd is a command and its arguments
  (cd "$dir" && FLEET_HEAVY=0 $cmd --plan --changed "$base" --shard "1/$1" ${dur:+--durations "$dur"} 2>/dev/null) \
    | grep '^plan ' | tail -1
}
field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

why=''
first=$(plan_line 1)
if [ -z "$first" ]; then
  # `select: (none)` exits before planning: nothing related to test
  if (cd "$dir" && FLEET_HEAVY=0 ${FLEET_TRAIN_PLAN_CMD:-bash bin/run-selftests.sh} --changed "$base" --shard 1/1 --plan 2>/dev/null) | grep -q '^select: (none)'; then
    first='plan tests=0 total=0 shards=1 heaviest=0'
  else
    why="could not price the selection against $base"
  fi
fi

if [ -n "$why" ]; then
  n=${fixed:-$min}; tests='?'; total='?'; heavy='?'; budget=$floor
  echo "fleet-train-plan: $why — $n shard(s) at the ${floor}s floor" >&2
else
  tests=$(field "$first" tests); total=$(field "$first" total)
  if [ -n "$fixed" ]; then n=$fixed
  else
    n=$(awk -v t="$total" -v s="$scale" -v g="$target" 'BEGIN { x = t * s / g; n = int(x); if (n < x) n++; print n }')
    [ "$n" -ge "$min" ] || n=$min
    [ "$n" -le "$max" ] || n=$max
  fi
  line=$(plan_line "$n")
  heavy=$(field "$line" heaviest); [ -n "$heavy" ] || heavy=$total
  budget=$(awk -v h="$heavy" -v s="$scale" -v f="$factor" -v fl="$floor" 'BEGIN { b = h * s * f; b = (b == int(b)) ? b : int(b) + 1; print (b > fl) ? b : fl }')
fi
step=$(( (2 * budget + 120 + 59) / 60 ))
[ "$step" -le 345 ] || step=345
job=$(( step + 10 ))
shards=$(awk -v n="$n" 'BEGIN { printf "["; for (i = 1; i <= n; i++) printf "%s%d", (i > 1 ? ", " : ""), i; print "]" }')

out=$(cat <<EOF
${prefix}_shards=$shards
${prefix}_tests=$tests
${prefix}_predicted=$total
${prefix}_heaviest=$heavy
${prefix}_budget_secs=$budget
${prefix}_step_minutes=$step
${prefix}_job_minutes=$job
EOF
)
printf '%s\n' "$out"
[ -z "${GITHUB_OUTPUT:-}" ] || printf '%s\n' "$out" >> "$GITHUB_OUTPUT"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  if [ -n "$why" ]; then note="预测不出（${why}），按下限"
  else note="选中 ${tests} 个测试、合计约 ${total}s（×${scale}）"; fi
  printf '| %s | %s | %s 片 | 最重一片约 %ss | 每次上限 %ss（截断重跑一次）| 步骤 %s 分钟 |\n' \
    "$prefix" "$note" "$n" "$heavy" "$budget" "$step" >> "$GITHUB_STEP_SUMMARY"
fi
exit 0
