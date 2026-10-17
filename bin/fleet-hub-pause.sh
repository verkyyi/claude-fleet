#!/bin/bash
# fleet-hub-pause.sh — the release train's hub-deploy pause switch (issues #2013, #4621).
#
#   fleet-hub-pause.sh check --repo <owner/name> [--sha <train sha>] [--var <value>]
#       hub-deploy.yml's `gate` job: prints paused=true|false (+ why=…) and appends
#       them to $GITHUB_OUTPUT when set. Not the train (no --sha: a person's
#       workflow_dispatch) ⇒ never paused — that is how you deploy by hand while
#       automatic releases are off.
#   fleet-hub-pause.sh on [--repo R] [--why <words>] · off [--repo R] · status [--repo R]
#       a person's switch: on opens ONE issue labelled hub-deploy-paused, off closes
#       every open one, status says which.
#
# Two sources, either one pauses:
#   * --var: the repo variable HUB_DEPLOY_PAUSED as the workflow read it. GitHub
#     fixes `vars` when a run is QUEUED (measured for #4621: a variable set while
#     the run waited reached neither a later job nor a called workflow) — so it
#     stops only the trains queued after it was set. Run 39036174481 was queued
#     13:20:46, the variable set 13:22:33, its gate ran 13:34 with PAUSED empty and
#     the hub was deployed.
#   * an OPEN issue carrying the label `hub-deploy-paused`, read when the gate RUNS
#     (the job's own GITHUB_TOKEN, issues: read — that token cannot read variables,
#     403). This one also stops a train already in the lane.
# The label read failing (three tries) is RED, exit 1 — a pause switch that cannot
# be read never deploys blind. GH (default gh) is the seam the drill replaces.
set -uo pipefail
LABEL=hub-deploy-paused
GH=${GH:-gh}

die() { echo "fleet-hub-pause: $*" >&2; exit 2; }

open_issues() {  # <repo> → "#N title" lines; rc 1 when the API cannot be read
  local n out
  for n in 1 2 3; do
    if out=$("$GH" api "repos/$1/issues?state=open&labels=$LABEL&per_page=20" \
        --jq '.[] | select(.pull_request == null) | "#\(.number) \(.title)"' 2>/dev/null); then
      printf '%s' "$out"; return 0
    fi
    [ "$n" = 3 ] || sleep "${FLEET_HUB_PAUSE_RETRY_SECS:-3}"
  done
  return 1
}

emit() {  # <paused> <why>
  printf 'paused=%s\nwhy=%s\n' "$1" "$2"
  [ -z "${GITHUB_OUTPUT:-}" ] || printf 'paused=%s\nwhy=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

cmd=${1:-}; [ -n "$cmd" ] && shift
repo=${GITHUB_REPOSITORY:-}; sha=''; var=''; why=''
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --sha) sha=${2:-}; shift 2 ;;
    --var) var=${2:-}; shift 2 ;;
    --why) why=${2:-}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$cmd" in
  check)
    [ -n "$repo" ] || die "check needs --repo"
    if [ -z "$sha" ]; then emit false "not the train (a person's dispatch is never paused)"; exit 0; fi
    if [ "$var" = 1 ]; then emit true "repo variable HUB_DEPLOY_PAUSED=1"; exit 0; fi
    if ! found=$(open_issues "$repo"); then
      emit false "label $LABEL unreadable"
      echo "::error::fleet-hub-pause: could not read open issues labelled $LABEL — red, never a blind deploy" >&2
      exit 1
    fi
    if [ -n "$found" ]; then emit true "open issue labelled $LABEL: $(printf '%s' "$found" | head -1)"
    else emit false "no pause (variable empty when queued, no open $LABEL issue)"; fi
    ;;
  on)
    [ -n "$repo" ] || repo=$("$GH" repo view --json nameWithOwner --jq .nameWithOwner) || die "no repo"
    found=$(open_issues "$repo") || die "cannot read $repo's issues"
    if [ -n "$found" ]; then echo "already paused: $(printf '%s' "$found" | head -1)"; exit 0; fi
    "$GH" label create "$LABEL" --repo "$repo" --color B60205 \
      --description "open = the release train deploys no hub (fleet-hub-pause.sh)" >/dev/null 2>&1 || true
    "$GH" issue create --repo "$repo" --label "$LABEL" --title "入口自动部署已暂停" \
      --body "$(printf '只要这张单开着（带 `%s` 标签），发布列车的 `hub / gate` 就不部署入口——连已经在车道里排着的那趟也算。\n\n原因：%s\n\n恢复：关掉这张单（`bin/fleet-hub-pause.sh off`）。手动部署：Actions → hub-deploy → Run workflow（不受暂停影响）。' "$LABEL" "${why:-（未写）}")"
    ;;
  off)
    [ -n "$repo" ] || repo=$("$GH" repo view --json nameWithOwner --jq .nameWithOwner) || die "no repo"
    found=$(open_issues "$repo") || die "cannot read $repo's issues"
    [ -n "$found" ] || { echo "not paused"; exit 0; }
    printf '%s\n' "$found" | while read -r num _; do
      "$GH" issue close "${num#\#}" --repo "$repo" --comment "恢复入口自动部署（fleet-hub-pause.sh off）。" >/dev/null && echo "closed $num"
    done
    ;;
  status)
    [ -n "$repo" ] || repo=$("$GH" repo view --json nameWithOwner --jq .nameWithOwner) || die "no repo"
    found=$(open_issues "$repo") || die "cannot read $repo's issues"
    if [ -n "$found" ]; then echo "paused: $found"; else echo "not paused (by label; the repo variable HUB_DEPLOY_PAUSED stops only trains queued after it)"; fi
    ;;
  *) die "usage: fleet-hub-pause.sh check|on|off|status [--repo R] [--sha S] [--var V] [--why W]" ;;
esac
