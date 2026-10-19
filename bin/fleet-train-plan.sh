#!/bin/bash
# fleet-train-plan.sh --base <rev> | --full [--dir <repo>] [--prefix <name>] [--durations <table>]
#                     [--scale <x>] [--shards <N> | --min <N> --max <N> --target <s>]
#                     [--factor <x>] [--floor <s>] [--slots <S>] [--proven <file>]
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
#
# --slots S — the Shenzhen pool's free runner slots (issue #3865, EPIC #3863 C2;
# bin/fleet-train-runner.sh pick's linux_slots): the width follows the slots, not
# the PR's 12. N = clamp(ceil(total × scale / 75), 1, S), S at most 44 (the pool's
# 3 nodes); a shard past the free slots only queues for a second round, slower than
# cutting fewer. Except when the selection is so big that the free slots would each
# carry more than 75 s + 180 s (a node's 2–3 minutes from 0): then N goes up to 44
# at once — the pods that do not fit yet stay pending, which is what grows the pool,
# and the train never waits for the growth before it starts. A test over 75 s gets a
# shard of its own (run-selftests.sh --solo 75). One attempt's floor is 150 s
# instead of 480. Also prints <prefix>_slots and <prefix>_solo_secs (75). Without
# --slots every line is byte for byte as before.
# --proven <file> — the tests the train reuses from a PR (issue #4794,
# bin/fleet-train-reuse.sh): priced out of the selection, as the shards will skip
# them (run-selftests.sh --proven). An empty file prices as before.
# --full — price the WHOLE suite instead of a --changed selection (the nightly,
# .github/workflows/selftests-nightly.yml, issue #3871): the same widths and bounds.
# FLEET_TRAIN_PLAN_CMD replaces `bash bin/run-selftests.sh` (the drill's seam).
set -uo pipefail

dir=. base='' prefix=plan dur='' scale=1 fixed='' min=12 max=20 target=360 factor=1.5 floor=480
slots='' solo='' full=0 proven=''
# the Shenzhen pool (issue #3865): 75 s a shard, ≤ 44 wide, a node's 180 s to grow
ACK_TARGET=75 ACK_CAP=44 ACK_GROW=180 ACK_FLOOR=150
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) dir=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    --full) full=1; shift ;;
    --prefix) prefix=$2; shift 2 ;;
    --durations) dur=$2; shift 2 ;;
    --scale) scale=$2; shift 2 ;;
    --shards) fixed=$2; shift 2 ;;
    --min) min=$2; shift 2 ;;
    --max) max=$2; shift 2 ;;
    --target) target=$2; shift 2 ;;
    --factor) factor=$2; shift 2 ;;
    --floor) floor=$2; shift 2 ;;
    --slots) slots=$2; shift 2 ;;
    --proven) proven=$2; shift 2 ;;
    -h|--help) sed -n '2,47p' "$0"; exit 0 ;;
    *) echo "fleet-train-plan: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
# a relative --proven is the caller's, and plan_line runs in --dir
case "$proven" in ''|/*) ;; *) proven="$(pwd)/$proven" ;; esac
[ -z "$proven" ] || [ -s "$proven" ] || proven=''
[ "$full" = 0 ] || proven=''
[ -n "$base" ] || [ "$full" = 1 ] || { echo "fleet-train-plan: --base <rev> (or --full) is required" >&2; exit 2; }
# the selection: what changed since <base>, or every test
sel='--changed'; [ "$full" = 1 ] && sel='' && base=''
for v in "$min" "$max" "$target" "$floor" ${fixed:+"$fixed"} ${slots:+"$slots"}; do
  case "$v" in ''|*[!0-9]*|0) echo "fleet-train-plan: '$v' is not a positive whole number" >&2; exit 2 ;; esac
done

if [ -n "$slots" ]; then
  [ "$slots" -le "$ACK_CAP" ] || slots=$ACK_CAP
  min=1 max=$slots target=$ACK_TARGET floor=$ACK_FLOOR solo=$ACK_TARGET
fi

# plan_line <N> — the runner's one `plan …` line for an N-wide deal, or nothing.
plan_line() {
  local cmd
  if [ -n "${FLEET_TRAIN_PLAN_CMD:-}" ]; then cmd=$FLEET_TRAIN_PLAN_CMD
  else cmd="bash bin/run-selftests.sh"; fi
  # shellcheck disable=SC2086  # $cmd is a command and its arguments
  (cd "$dir" && FLEET_HEAVY=0 $cmd --plan ${sel:+$sel "$base"} --shard "1/$1" ${dur:+--durations "$dur"} ${solo:+--solo "$solo"} ${proven:+--proven "$proven"} 2>/dev/null) \
    | grep '^plan ' | tail -1
}
field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

why=''
first=$(plan_line 1)
if [ -z "$first" ]; then
  # `select: (none)` exits before planning: nothing related to test
  if [ "$full" = 0 ] && (cd "$dir" && FLEET_HEAVY=0 ${FLEET_TRAIN_PLAN_CMD:-bash bin/run-selftests.sh} --changed "$base" --shard 1/1 --plan 2>/dev/null) | grep -q '^select: (none)'; then
    first='plan tests=0 total=0 shards=1 heaviest=0'
  else
    why="could not price the selection against ${base:-the whole suite}"
  fi
fi

if [ -n "$why" ]; then
  n=${fixed:-$min}; tests='?'; total='?'; heavy='?'; budget=$floor
  # in the pool: every free slot, at the PR's 8 minutes — no forecast to cut it by
  [ -z "$slots" ] || { n=${fixed:-$slots}; budget=480; }
  echo "fleet-train-plan: $why — $n shard(s) at the ${budget}s floor" >&2
else
  tests=$(field "$first" tests); total=$(field "$first" total)
  if [ -n "$fixed" ]; then n=$fixed
  else
    # more than a node's growth per free slot ⇒ open the pool's whole width now
    [ -z "$slots" ] || ! awk -v t="$total" -v s="$scale" -v k="$slots" -v g="$((ACK_TARGET + ACK_GROW))" \
      'BEGIN { exit !(t * s / k > g) }' || max=$ACK_CAP
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
[ -z "$slots" ] || out=$(printf '%s\n%s_slots=%s\n%s_solo_secs=%s' "$out" "$prefix" "$slots" "$prefix" "$solo")
printf '%s\n' "$out"
[ -z "${GITHUB_OUTPUT:-}" ] || printf '%s\n' "$out" >> "$GITHUB_OUTPUT"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  if [ -n "$why" ]; then note="预测不出（${why}），按下限"
  else note="选中 ${tests} 个测试、合计约 ${total}s（×${scale}）"; fi
  [ -z "$slots" ] || note="$note · 空机位 ${slots}、单测超 ${solo}s 独占一片"
  printf '| %s | %s | %s 片 | 最重一片约 %ss | 每次上限 %ss（截断重跑一次）| 步骤 %s 分钟 |\n' \
    "$prefix" "$note" "$n" "$heavy" "$budget" "$step" >> "$GITHUB_STEP_SUMMARY"
fi
exit 0
