#!/bin/bash
# fleet-train-runner.sh pick    [--runner <name>] [--repo <owner/name>] [--runners-file <json>]
# fleet-train-runner.sh lost    [--repo <owner/name>] [--run <id>] [--prefix <job name>]
# fleet-train-runner.sh is-lost [--repo <owner/name>] --job <id>
# fleet-train-runner.sh pr-pick [--runner <name>] [--repo <owner/name>] --head-repo <owner/name>
#                               --fork true|false [--status <file>] [--max-age <secs>]
#   — where one release train runs its Linux half (issue #3864, EPIC #3863 C1).
#
# pick (the train's `board` job): the Shenzhen cluster's fleet-ack runners when the
#   repo variable FLEET_TRAIN_RUNNER (--runner) says `fleet-ack` and the set is up,
#   GitHub's ubuntu-24.04 otherwise (pinned: ubuntu-24.04 moved to 26.04, where
#   playwright has no chromium and several selftests go red — task DDBQ). Up = a runner of that set is registered and
#   online right now (GitHub's runner list — ARC keeps minRunners idle ones
#   registered while the set lives, named <set>-<hash>-runner-<id> with NO label;
#   a classic runner by its label); the list is read with $FLEET_TRAIN_RUNNER_TOKEN
#   (a token that may read the repo's self-hosted runners — the runner app's
#   installation token, minted in the job; never an argv). No variable ⇒
#   ubuntu-24.04 and nothing asked: the train is byte for byte as before. Asked and
#   not up — nobody online, no token, no answer — ⇒ ubuntu-24.04, and the why says
#   「深圳不可用，退回 GitHub」. The train runs either way (BREAK-IT train-ack-down).
#   Prints, and appends to $GITHUB_OUTPUT when set, one `key=value` line each:
#     linux_runs_on  `ubuntu-24.04`, or the JSON label list `["fleet-ack"]`
#     linux_where    fleet-ack | github
#     linux_why      one line: which runners, or why GitHub's
#     linux_mirror   the cluster's git mirror ($FLEET_TRAIN_GIT_MIRROR) on fleet-ack,
#                    else empty — a shard fetches TRAIN_SHA there before GitHub
#     linux_slots    on fleet-ack, how many shards the pool runs at once (issue #3865):
#                    14 a node (a runner pod asks 1 vCPU of a 16-core spot node), the
#                    nodes counted as ceil(online runners / 14), at least 1 — GitHub
#                    names no node, and every online runner is a pod on one — at most
#                    44 (the fleet-ci pool's 3 nodes); empty on GitHub's runners
#
# lost (after the Linux shards, when they ran on fleet-ack): which shards ended red
#   because their RUNNER went away — a spot node reclaimed, a pod evicted — rather
#   than because a test failed. GitHub says so on the job: an annotation «lost
#   communication with the server» or «received a shutdown signal». Prints (and to
#   $GITHUB_OUTPUT):
#     lost    the JSON list of those shard numbers (K of `<prefix> / shard K`)
#     red     the JSON list of shards red for any other reason
#     total   how many shards the half had (N of K/N — a rescue keeps it)
#     covers  true when every red shard was a lost one (and at least one) — the
#             train reruns exactly those on GitHub's runners and stays shippable
#
# is-lost --job <id>: exit 0 when that job's runner went away (the same annotations),
#   1 when not — the train's fail-fast asks it before calling a fleet-ack shard red.
#
# pr-pick (the PR gate's plan, .github/workflows/ci.yml — issue #4821, EPIC #4810
#   C18): where THIS PR's heavy checks run. A pull request cannot read the runner
#   list (the runner app's key is master-only), so fleet-ack-status.yml asks it every
#   10 minutes with `pick` and leaves the answer in the Actions cache — `ts=<epoch>`
#   + pick's lines — which ci.yml restores as --status. `fleet-ack` only when the
#   repo variable FLEET_PR_RUNNER (--runner) names the set, the PR's head is this
#   repo's own branch (--head-repo = --repo and --fork false: a fork's PR never runs
#   on our runners) and the status is fresh (≤ --max-age, 1800 s) and «up»;
#   otherwise ubuntu-24.04 and the why says which. No variable ⇒ nothing read.
#   Prints (and to $GITHUB_OUTPUT): pr_runs_on · pr_where · pr_why.
#
# gh reads $GH_TOKEN; $FLEET_TRAIN_GH is a test seam for the gh command.
# Exit: pick / pr-pick 0 always (a choice is always made) · lost 0 (1 the jobs
#       unreadable) · is-lost 0 lost / 1 not · 2 usage
set -u
die() { printf 'fleet-train-runner: %s\n' "$*" >&2; exit 2; }
emit() {
  printf '%s\n' "$@"
  [ -z "${GITHUB_OUTPUT:-}" ] || printf '%s\n' "$@" >> "$GITHUB_OUTPUT"
}
gh=${FLEET_TRAIN_GH:-gh}
# GitHub's words for a job whose runner went away mid-job (ARC pod gone, spot node
# reclaimed): never a test's.
LOST_RE='lost communication with the server|received a shutdown signal'

pick() {
  local runner=${FLEET_TRAIN_RUNNER:-} repo=${GITHUB_REPOSITORY:-} file='' body='' why=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --runner)       shift; runner="${1:-}" ;;
      --repo)         shift; repo="${1:-}" ;;
      --runners-file) shift; file="${1:-}" ;;
      *) die "pick: unknown argument $1" ;;
    esac
    shift
  done
  if [ -z "$runner" ]; then
    emit 'linux_runs_on=ubuntu-24.04' 'linux_where=github' 'linux_why=FLEET_TRAIN_RUNNER 未设：GitHub 的 ubuntu-24.04' 'linux_mirror=' 'linux_slots='
    printf 'Linux: github — FLEET_TRAIN_RUNNER is empty\n' >&2
    return 0
  fi
  case "$runner" in *[!A-Za-z0-9_.-]*) die "pick: not a runner set name: $runner" ;; esac
  if [ -n "$file" ]; then
    body=$(cat -- "$file" 2>/dev/null) || why="no runners file $file"
  elif [ -z "$repo" ]; then
    why="no repo (GITHUB_REPOSITORY)"
  elif [ -z "${FLEET_TRAIN_RUNNER_TOKEN:-}" ]; then
    why="no token to read the runner list (FLEET_TRAIN_RUNNER_TOKEN)"
  else
    body=$(GH_TOKEN=$FLEET_TRAIN_RUNNER_TOKEN $gh api "repos/$repo/actions/runners?per_page=100" 2>&1) \
      || { why="GitHub did not answer the runner list: $(printf '%s' "$body" | head -1 | cut -c1-120)"; body=''; }
  fi
  local out where say labels mirror='' online slots=''
  out=$(printf '%s' "$body" | NAME=$runner WHY="$why" python3 -c '
import json, os, sys
name, why = os.environ["NAME"], os.environ["WHY"]
up = []
if not why:
    try:
        rows = json.loads(sys.stdin.read())["runners"]
        if not isinstance(rows, list):
            raise ValueError
        # the runners of an ARC scale set carry no label in this list, only a name:
        # <set>-<hash>-runner-<id>; a classic self-hosted runner carries the label
        mine = [r for r in rows if name in [l.get("name") for l in (r.get("labels") or [])]
                or (r.get("name") or "").startswith(name + "-")]
        up = [r for r in mine if r.get("status") == "online"]
        if not up:
            why = "no %s runner online (%d registered)" % (name, len(mine))
    except Exception:
        why = "the runner list is not a list of runners"
if up:
    busy = sum(1 for r in up if r.get("busy"))
    print("fleet-ack"); print("%s: %d online (%d busy)" % (name, len(up), busy)); print(len(up))
else:
    print("github"); print(why); print(0)
')
  where=$(printf '%s\n' "$out" | sed -n 1p) say=$(printf '%s\n' "$out" | sed -n 2p)
  online=$(printf '%s\n' "$out" | sed -n 3p)
  if [ "$where" = fleet-ack ]; then
    labels="[\"$runner\"]" mirror=${FLEET_TRAIN_GIT_MIRROR:-}
    slots=$(( (online + 13) / 14 * 14 ))
    [ "$slots" -ge 14 ] || slots=14
    [ "$slots" -le 44 ] || slots=44
    say="$say · $slots 个机位"
  else
    where=github labels=ubuntu-24.04 say="深圳不可用，退回 GitHub（${say:-could not decide}）"
  fi
  emit "linux_runs_on=$labels" "linux_where=$where" "linux_why=$say" "linux_mirror=$mirror" "linux_slots=$slots"
  printf 'Linux: %s — %s\n' "$where" "$say" >&2
  return 0
}

pr_pick() {
  local runner=${FLEET_PR_RUNNER:-} repo=${GITHUB_REPOSITORY:-} head='' fork='' stfile='' maxage=1800
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --runner)    shift; runner="${1:-}" ;;
      --repo)      shift; repo="${1:-}" ;;
      --head-repo) shift; head="${1:-}" ;;
      --fork)      shift; fork="${1:-}" ;;
      --status)    shift; stfile="${1:-}" ;;
      --max-age)   shift; maxage="${1:-}" ;;
      *) die "pr-pick: unknown argument $1" ;;
    esac
    shift
  done
  case "$maxage" in ''|*[!0-9]*) die "pr-pick: --max-age takes seconds" ;; esac
  local why='' ts='' where='' said='' age
  if [ -z "$runner" ]; then
    emit 'pr_runs_on=ubuntu-24.04' 'pr_where=github' 'pr_why=FLEET_PR_RUNNER 未设：GitHub 的 ubuntu-24.04'
    printf 'PR checks: github — FLEET_PR_RUNNER is empty\n' >&2
    return 0
  fi
  case "$runner" in *[!A-Za-z0-9_.-]*) die "pr-pick: not a runner set name: $runner" ;; esac
  if [ -z "$repo" ] || [ "$head" != "$repo" ] || [ "$fork" != false ]; then
    why="不是本仓库自己的分支（head ${head:-?}, fork ${fork:-?}）：自建机器不跑外来的代码"
  elif [ -z "$stfile" ] || [ ! -r "$stfile" ]; then
    why="深圳不可用，退回 GitHub（没有集群的最近状态：fleet-ack-status.yml 没留下缓存）"
  else
    ts=$(sed -n 's/^ts=//p' "$stfile" | head -1)
    where=$(sed -n 's/^linux_where=//p' "$stfile" | head -1)
    said=$(sed -n 's/^linux_why=//p' "$stfile" | head -1)
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    age=$(( $(date +%s) - ts ))
    if [ "$age" -gt "$maxage" ]; then
      why="深圳不可用，退回 GitHub（集群的最近状态已过 ${age}s > ${maxage}s）"
    elif [ "$where" != fleet-ack ]; then
      why="深圳不可用，退回 GitHub（${said:-the status says ${where:-nothing}}，${age}s 前）"
    fi
  fi
  if [ -n "$why" ]; then
    emit 'pr_runs_on=ubuntu-24.04' 'pr_where=github' "pr_why=$why"
    printf 'PR checks: github — %s\n' "$why" >&2
  else
    emit "pr_runs_on=[\"$runner\"]" 'pr_where=fleet-ack' "pr_why=${runner}（${said:-up}，${age}s 前）"
    printf 'PR checks: fleet-ack — %s, %ss ago\n' "${said:-up}" "$age" >&2
  fi
  return 0
}

# annotations_lost <job id>: 0 when GitHub says the job's runner went away
annotations_lost() {
  local msgs
  msgs=$($gh api "repos/$repo/check-runs/$1/annotations" --jq '.[].message' 2>/dev/null) || return 1
  printf '%s\n' "$msgs" | grep -Eqi "$LOST_RE"
}

lost() {
  repo=${GITHUB_REPOSITORY:-}
  local run=${GITHUB_RUN_ID:-} prefix=Linux rows id k concl name lostl='' redl='' total=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)   shift; repo="${1:-}" ;;
      --run)    shift; run="${1:-}" ;;
      --prefix) shift; prefix="${1:-Linux}" ;;
      *) die "lost: unknown argument $1" ;;
    esac
    shift
  done
  [ -n "$repo" ] && [ -n "$run" ] || die "lost: needs --repo and --run (or GITHUB_REPOSITORY / GITHUB_RUN_ID)"
  rows=$($gh api --paginate "repos/$repo/actions/runs/$run/jobs?per_page=100" \
           --jq '.jobs[] | [.id, (.conclusion // ""), .name] | @tsv' 2>/dev/null) \
    || { echo "fleet-train-runner: could not read the jobs of run $run" >&2; return 1; }
  while IFS="$(printf '\t')" read -r id concl name; do
    case "$name" in "$prefix / shard "*) ;; *) continue ;; esac
    k=${name##* }
    case "$k" in ''|*[!0-9]*) continue ;; esac
    total=$((total + 1))
    case "$concl" in
      success|skipped|neutral|'') ;;
      failure)
        if annotations_lost "$id"; then lostl="$lostl $k"; else redl="$redl $k"; fi ;;
      *) redl="$redl $k" ;;   # timed_out (a hung test), cancelled: not a lost runner
    esac
  done <<EOF
$rows
EOF
  local covers=false
  # shellcheck disable=SC2086  # $1 is a space-separated list of numbers, split on purpose
  js() { printf '%s\n' $1 | awk 'NF' | sort -n | awk 'BEGIN{printf "["} {printf "%s%s", (NR>1?", ":""), $1} END{print "]"}'; }
  [ -n "$lostl" ] && [ -z "$redl" ] && covers=true
  emit "lost=$(js "$lostl")" "red=$(js "$redl")" "total=$total" "covers=$covers"
  printf '%s: %d shard(s); lost runner: %s; red: %s\n' "$prefix" "$total" "$(js "$lostl")" "$(js "$redl")" >&2
  return 0
}

is_lost() {
  repo=${GITHUB_REPOSITORY:-}
  local job=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) shift; repo="${1:-}" ;;
      --job)  shift; job="${1:-}" ;;
      *) die "is-lost: unknown argument $1" ;;
    esac
    shift
  done
  [ -n "$repo" ] || die "is-lost: needs --repo (or GITHUB_REPOSITORY)"
  case "$job" in ''|*[!0-9]*) die "is-lost: --job takes a job id" ;; esac
  annotations_lost "$job"
}

cmd=${1:-}; [ "$#" -gt 0 ] && shift
case "$cmd" in
  pick)    pick "$@" ;;
  lost)    lost "$@" ;;
  is-lost) is_lost "$@" ;;
  pr-pick) pr_pick "$@" ;;
  -h|--help) sed -n '2,59p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "usage: fleet-train-runner.sh pick|lost|is-lost|pr-pick …" ;;
esac
