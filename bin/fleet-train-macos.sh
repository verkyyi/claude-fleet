#!/bin/bash
# fleet-train-macos.sh pick  [--hub <url>] [--runners-file <json>] [--max <n>]
# fleet-train-macos.sh watch [--repo <owner/name>] [--run <id>] [--where fleet-ci|github]
#                            [--deadline <s>] [--every <s>] [--prefix <job name>]
#   — where one release train runs its macOS half (issue #3145, EPIC #3139 C6).
#
# pick (the train's `board` job): our own Macs first, GitHub's when none is there.
#   It asks the hub's GET /v1/fleet/ci-runners (C5, #3144) — the machines' test
#   runners as their machine links last said — with the hub viewer token in
#   $FLEET_HUB_CI_TOKEN (a repo secret; it travels on curl's stdin config, never an
#   argv). A runner counts when the hub calls it online AND its state is idle or
#   busy (paused / error / off never). n of them ⇒ the macOS shards go to
#   `[self-hosted, macOS, fleet-ci]`, min(n, --max 2) wide; none — or no token, a
#   hub that does not answer, an answer that is not the list — ⇒ `macos-latest`,
#   2 wide: the train runs either way (拔掉两台测试机，下一趟照样发).
#   Prints, and appends to $GITHUB_OUTPUT when set, one `key=value` line each:
#     macos_runs_on  the runs-on labels, a JSON list
#     macos_shards   the shard matrix, a JSON list 1..N
#     macos_where    fleet-ci | github
#     macos_why      one line: which machines, or why GitHub's
#
# watch (a job beside the macOS shards): reads this run's jobs named
#   `<prefix> / shard *` every --every s (default 30). When every one has started it
#   writes each shard's runner and its queue time (started − created) to the step
#   summary and exits 0. A shard still queued past --deadline s (default 1200) on
#   fleet-ci means our machine took the train and never picked it up — a queued job
#   waits a day, and timeout-minutes only counts once it starts — so it writes
#   「自家测试机没接」, cancels the run (the train is red; the next board reads the
#   heartbeat that says paused / off and picks GitHub's) and exits 1. On github it
#   only reports and exits 0 at the deadline: GitHub's queue is GitHub's.
#   gh reads $GH_TOKEN; $FLEET_TRAIN_GH is a test seam for the gh command.
#
# Exit: pick 0 always (a choice is always made) · watch 0 started / reported,
#       1 our runner never took it · 2 usage
set -u
die() { printf 'fleet-train-macos: %s\n' "$*" >&2; exit 2; }
emit() {
  printf '%s\n' "$@"
  [ -z "${GITHUB_OUTPUT:-}" ] || printf '%s\n' "$@" >> "$GITHUB_OUTPUT"
}
summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat >> "$GITHUB_STEP_SUMMARY"; }

pick() {
  local hub=${FLEET_HUB_URL:-} file='' max=2 body='' why=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hub)          shift; hub="${1:-}" ;;
      --runners-file) shift; file="${1:-}" ;;
      --max)          shift; max="${1:-2}" ;;
      *) die "pick: unknown argument $1" ;;
    esac
    shift
  done
  case "$max" in ''|*[!0-9]*|0) max=2 ;; esac
  if [ -n "$file" ]; then
    body=$(cat -- "$file" 2>/dev/null) || why="no runners file $file"
  elif [ -z "$hub" ]; then
    why="no hub (FLEET_HUB_URL)"
  elif [ -z "${FLEET_HUB_CI_TOKEN:-}" ]; then
    why="no hub token (secret FLEET_HUB_VIEWER_TOKEN)"
  else
    body=$(printf 'header = "Authorization: Bearer %s"\n' "$FLEET_HUB_CI_TOKEN" \
      | curl -fsS -m 15 -K - "${hub%/}/v1/fleet/ci-runners" 2>&1) \
      || { why="the hub did not answer: $(printf '%s' "$body" | head -1 | cut -c1-120)"; body=''; }
  fi
  local out where n say labels shards i
  out=$(printf '%s' "$body" | MAX=$max WHY="$why" python3 -c '
import json, os, sys
mx, why = int(os.environ["MAX"]), os.environ["WHY"]
names = []
if not why:
    try:
        rows = json.loads(sys.stdin.read())["runners"]
        if not isinstance(rows, list):
            raise ValueError
        for r in rows:
            st = (r.get("runner") or {}).get("state", "")
            if r.get("online") and st in ("idle", "busy"):
                names.append("%s:%s" % (r.get("machine", "?"), st))
        if not names:
            seen = ["%s:%s" % (r.get("machine", "?"),
                    (r.get("runner") or {}).get("state", "?") if r.get("online") else "offline")
                    for r in rows]
            why = "no runner of ours online and idle/busy (%s)" % (", ".join(seen) or "none listed")
    except Exception:
        why = "the hub answer is not the runner list"
if names:
    print("fleet-ci"); print(min(len(names), mx)); print("ours: " + ", ".join(names))
else:
    print("github"); print(2); print(why)
')
  where=$(printf '%s\n' "$out" | sed -n 1p) n=$(printf '%s\n' "$out" | sed -n 2p)
  say=$(printf '%s\n' "$out" | sed -n 3p)
  [ "$where" = fleet-ci ] || where=github
  case "$n" in ''|*[!0-9]*|0) n=2 ;; esac
  if [ "$where" = fleet-ci ]; then
    labels='["self-hosted","macOS","fleet-ci"]'
  else
    labels='["macos-latest"]' n=2 say=${say:-could not decide}
  fi
  shards='[1' i=2
  while [ "$i" -le "$n" ]; do shards="$shards, $i"; i=$((i + 1)); done
  shards="$shards]"
  emit "macos_runs_on=$labels" "macos_shards=$shards" "macos_where=$where" "macos_why=$say"
  printf 'macOS: %s, %s shard(s) — %s\n' "$where" "$n" "$say" >&2
  return 0
}

watch() {
  local repo=${GITHUB_REPOSITORY:-} run=${GITHUB_RUN_ID:-} where=fleet-ci deadline=1200 every=30 prefix=macOS
  local gh=${FLEET_TRAIN_GH:-gh} t0 now js verdict
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)     shift; repo="${1:-}" ;;
      --run)      shift; run="${1:-}" ;;
      --where)    shift; where="${1:-}" ;;
      --deadline) shift; deadline="${1:-1200}" ;;
      --every)    shift; every="${1:-30}" ;;
      --prefix)   shift; prefix="${1:-macOS}" ;;
      *) die "watch: unknown argument $1" ;;
    esac
    shift
  done
  [ -n "$repo" ] && [ -n "$run" ] || die "watch: needs --repo and --run (or GITHUB_REPOSITORY / GITHUB_RUN_ID)"
  case "$deadline" in ''|*[!0-9]*) deadline=1200 ;; esac
  case "$every" in ''|*[!0-9]*|0) every=30 ;; esac
  t0=$(date +%s)
  while :; do
    js=$($gh api "repos/$repo/actions/runs/$run/jobs?per_page=100" 2>/dev/null) || js=''
    now=$(date +%s)
    verdict=$(printf '%s' "$js" | PREFIX="$prefix" python3 -c '
import json, os, sys
from datetime import datetime
def ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ") if s else None
try:
    jobs = json.loads(sys.stdin.read()).get("jobs") or []
except Exception:
    print("unread"); sys.exit()
pre = os.environ["PREFIX"] + " / shard"
mine = [j for j in jobs if (j.get("name") or "").startswith(pre)]
if not mine:
    print("none"); sys.exit()
rows, waiting = [], 0
for j in sorted(mine, key=lambda j: j.get("name") or ""):
    c, s = ts(j.get("created_at")), ts(j.get("started_at"))
    started = j.get("status") not in ("queued", "waiting", "pending", "requested")
    if not started:
        waiting += 1
    q = int((s - c).total_seconds()) if (started and c and s) else None
    rows.append("| %s | %s | %s | %s |" % (j.get("name"), j.get("runner_name") or "—",
                "%dm%02ds" % divmod(q, 60) if q is not None else "还在排",
                j.get("conclusion") or j.get("status")))
print("waiting" if waiting else "started")
print("\n".join(rows))
')
    case "$verdict" in
      started*)
        { echo "### macOS 测试排队（${where}）"; echo; echo "| shard | runner | 排队 | 状态 |"; echo "|---|---|---|---|"
          printf '%s\n' "$verdict" | sed 1d; } | summary
        printf '%s\n' "$verdict" | sed 1d >&2
        return 0 ;;
    esac
    if [ $((now - t0)) -ge "$deadline" ]; then
      case "$verdict" in
        waiting*) ;;
        *) # no shard job to judge (macOS skipped) or the jobs list unreadable: never red on that
          echo "::warning::fleet-train-macos watch: no verdict after ${deadline}s (${verdict:-no answer}) — not judging" >&2
          return 0 ;;
      esac
      if [ "$where" = fleet-ci ]; then
        { echo "### ⛔ 自家测试机没接"; echo
          echo "macOS 分片排给了自家测试机（fleet-ci），$((deadline / 60)) 分钟没开始：这趟车红，不发版本。"
          echo "下一趟 \`board\` 读到心跳 paused / off 就改用 GitHub 的机器。"; echo
          echo "| shard | runner | 排队 | 状态 |"; echo "|---|---|---|---|"
          printf '%s\n' "$verdict" | sed 1d; } | summary
        echo "::error::自家测试机没接: the macOS shards sat queued on fleet-ci for ${deadline}s — cancelling this train" >&2
        $gh run cancel "$run" --repo "$repo" >/dev/null 2>&1 \
          || echo "::warning::could not cancel run $run" >&2
        return 1
      fi
      { echo "### macOS 测试排队（github）"; echo
        echo "GitHub 的机器 $((deadline / 60)) 分钟内没全部开始；只记录，不拦。"; echo
        printf '%s\n' "$verdict" | sed 1d; } | summary
      return 0
    fi
    sleep "$every"
  done
}

cmd=${1:-}; [ "$#" -gt 0 ] && shift
case "$cmd" in
  pick)  pick "$@" ;;
  watch) watch "$@" ;;
  -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "usage: fleet-train-macos.sh pick|watch …" ;;
esac
