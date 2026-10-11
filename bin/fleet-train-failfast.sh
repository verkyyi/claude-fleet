#!/bin/bash
# fleet-train-failfast.sh [--repo <owner/name>] [--run <id>] [--every <s>] [--deadline <s>]
#                         [--jobs-re <ERE>] [--need <prefix|prefix…>]
#   — a red train gives the lane back at once (issue #3143, EPIC #3139 C4; BREAK-IT
#   `train-red-holds-lane`).
#
# The release train is ONE lane (concurrency `release-train`, never cancelled by a
# push), and its verdict job waits for every stage. So the first real train
# (run 38126091475) went red on one Linux shard in minutes and then held the lane
# for the better part of an hour while its macOS shards ran on — a train that can
# no longer ship anything, and every merge behind it waiting. This watcher runs
# beside the stages: it reads this run's jobs every --every s (default 20) and,
# the moment one whose name matches --jobs-re (default the stages that decide a
# train: `board`, `plan`, `quarantine`, `precheck`, `Linux / shard *`,
# `macOS / shard *`) concludes
# failure or timed_out, writes 「红灯即停」 + the job to the step summary, cancels
# the run and exits 1 — the train is red either way, the next one boards now.
# When every such job has finished green — and each of --need's stages (default
# `precheck`, `Linux / shard`, `macOS / shard`: a called workflow's shards are
# listed only once it starts) has shown up — it exits 0; with nothing to judge by
# --deadline s (default 7200) it exits 0 too — it never reds a train on its own.
# Only a job's CONCLUSION counts: a shard the release train's C9 cut short reruns
# inside its own step (bin/fleet-shard-run.sh), so the job is still in progress
# until its last attempt — never cancelled mid-rerun; a quarantined test (C10)
# leaves its shard green. A cancelled job is no verdict (a newer push does not cancel a running train;
# macOS 排队 cancels a run itself). gh reads $GH_TOKEN; $FLEET_TRAIN_GH is a test
# seam for the gh command.
#
# Exit: 0 every stage green / nothing to judge · 1 a stage went red, run cancelled
#       · 2 usage
set -u
die() { printf 'fleet-train-failfast: %s\n' "$*" >&2; exit 2; }
summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat >> "$GITHUB_STEP_SUMMARY"; }

repo=${GITHUB_REPOSITORY:-} run=${GITHUB_RUN_ID:-} every=20 deadline=7200
re='^(board|plan|quarantine|precheck|Linux / shard [0-9]+|macOS / shard [0-9]+)$'
need='precheck|Linux / shard|macOS / shard'
gh=${FLEET_TRAIN_GH:-gh}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)     shift; repo="${1:-}" ;;
    --run)      shift; run="${1:-}" ;;
    --every)    shift; every="${1:-20}" ;;
    --deadline) shift; deadline="${1:-7200}" ;;
    --jobs-re)  shift; re="${1:-}" ;;
    --need)     shift; need="${1:-}" ;;
    -h|--help)  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
  shift
done
[ -n "$repo" ] && [ -n "$run" ] || die "needs --repo and --run (or GITHUB_REPOSITORY / GITHUB_RUN_ID)"
[ -n "$re" ] || die "--jobs-re is empty"
case "$every" in ''|*[!0-9]*|0) every=20 ;; esac
case "$deadline" in ''|*[!0-9]*) deadline=7200 ;; esac

t0=$(date +%s)
while :; do
  # one "<status>\t<conclusion>\t<name>" line per job; unread = nothing to judge yet
  rows=$($gh api --paginate "repos/$repo/actions/runs/$run/jobs?per_page=100" \
           --jq '.jobs[] | [.status, (.conclusion // ""), .name] | @tsv' 2>/dev/null) || rows=''
  verdict=$(printf '%s\n' "$rows" | awk -F'\t' -v re="$re" -v need="$need" '
    BEGIN { k = split(need, want, "|") }
    NF >= 3 { for (i = 1; i <= k; i++) if (want[i] != "" && index($3, want[i]) == 1) got[i] = 1 }
    NF >= 3 && $3 ~ re {
      n++
      if ($2 == "failure" || $2 == "timed_out") { if (red == "") red = $3 " (" $2 ")" }
      else if ($1 != "completed") open++
    }
    END {
      if (red != "") print "red\t" red
      else if (n && !open) {
        for (i = 1; i <= k; i++) if (want[i] != "" && !(i in got)) { print "open"; exit }
        print "green"
      }
      else print "open"
    }')
  case "$verdict" in
    red*)
      job=${verdict#red?}
      { echo "### 🛑 红灯即停：${job}"
        echo
        echo "这一趟已经发不出去了：取消整趟，把车道让给下一趟（BREAK-IT \`train-red-holds-lane\`）。"
      } | summary
      echo "::error::${job} is red — this train ships nothing; cancelling it so the next train boards now"
      $gh run cancel "$run" --repo "$repo" >/dev/null 2>&1 \
        || echo "::warning::could not cancel run $run — the train still ends red when its stages finish"
      exit 1 ;;
    green) echo "every stage of train run $run finished green — nothing to stop"; exit 0 ;;
  esac
  if [ $(( $(date +%s) - t0 )) -ge "$deadline" ]; then
    echo "::warning::fleet-train-failfast: no verdict after ${deadline}s — not judging"
    exit 0
  fi
  sleep "$every"
done
