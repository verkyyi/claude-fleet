#!/usr/bin/env bash
# fleet-job.sh — hand a heavy or untrusted run to a throwaway pod (issue #3552,
# EPIC #3500 C7). `fleet job …`:
#
#   fleet job run [--kind build|test|browser|load|untrusted] [--repo O/N]
#                 [--ref <commit>] [--detach] -- <command…>
#   fleet job status <job>
#   fleet job logs <job> [--follow]
#
# A session in a person's pod asks the hub (POST /v1/node/jobs, this login's own
# node credential — so the Job is for this pod and no other); the hub signs a
# create-job ticket and its cluster's provisioner starts render.py's Job for
# that kind: the commit fetched from the cluster's git mirror, no home disk, no
# token, no key of anyone's, not root; untrusted never reaches the public
# internet. Its output streams back here; whatever the command leaves in
# $FLEET_JOB_OUT lands in this worktree's .fleet-job/<job>/ (kept out of git by
# .git/info/exclude). The Job deletes itself ten minutes after it ends.
#
# The commit must be on the remote (the Job fetches it from the mirror): run
# defaults to HEAD and refuses one no remote branch holds. Uncommitted changes
# are not in the Job. --kind defaults to test.
#
# Exit: the command's own exit in the Job (run, logs --follow) · 0 status /
# --detach · 1 the hub refused or failed · 2 usage · 3 not applicable (no node
# token here — this is no fleet pod's login).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

die() { printf 'fleet job: %s\n' "$2" >&2; exit "$1"; }
usage() { sed -n '4,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# job <args…> → fleet_job.py with this login's node pair on its stdin (url TAB
# token TAB key file) — the token never in an argv
job() {
  local p key
  p=$(fleet_node_pair) || die 3 "no node token here — fleet job runs from a session in a fleet pod"
  key=$(fleet_node_key_file 2>/dev/null) || key=''
  printf '%s\t%s\n' "$p" "$key" | python3 -I "$BIN/fleet_job.py" "$@"
}

outbase() { # → <worktree>/.fleet-job, excluded from git
  local top ex
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { printf '%s/.fleet-job' "$PWD"; return 0; }
  ex=$(git rev-parse --git-path info/exclude 2>/dev/null)
  if [ -n "$ex" ]; then
    case $ex in /*) : ;; *) ex="$top/$ex" ;; esac
    mkdir -p "$(dirname "$ex")" 2>/dev/null
    grep -qxF '.fleet-job/' "$ex" 2>/dev/null || printf '.fleet-job/\n' >> "$ex"
  fi
  printf '%s/.fleet-job' "$top"
}

cmd=${1:-}; [ -n "$cmd" ] || usage
shift
case $cmd in
  run)
    kind=test repo='' ref='' detach=''
    while [ $# -gt 0 ]; do
      case $1 in
        --kind) kind=${2:-}; shift 2 ;;
        --repo) repo=${2:-}; shift 2 ;;
        --ref) ref=${2:-}; shift 2 ;;
        --detach) detach=--detach; shift ;;
        --) shift; break ;;
        -h|--help) usage ;;
        *) break ;;
      esac
    done
    [ $# -gt 0 ] || usage
    case $kind in build|test|browser|load|untrusted) : ;; *) die 2 "--kind is build, test, browser, load or untrusted" ;; esac
    line="$*"
    sess=$(fleet_current_session 2>/dev/null) || sess=''
    if [ -z "$sess" ] && [ -n "$repo" ]; then
      # a shell outside any fleet session: the repo it names (the hub checks it)
      repo=$(fleet_norm_repo "$repo"); rc=0
    else
      repo=$(fleet_target_repo "$sess" "$repo"); rc=$?
    fi
    case $rc in
      0) : ;;
      4) die 2 "this fleet hosts several repos — say which: --repo owner/name" ;;
      *) die 2 "no repo of this fleet${repo:+ named $repo} — --repo owner/name" ;;
    esac
    if [ -z "$ref" ]; then
      ref=$(git rev-parse HEAD 2>/dev/null) || die 2 "not in a git checkout — --ref <commit>"
      [ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] \
        || printf 'fleet job: uncommitted changes are not in the Job (it runs %s)\n' "${ref:0:12}" >&2
      [ -n "$(git branch -r --contains "$ref" 2>/dev/null)" ] \
        || die 2 "commit ${ref:0:12} is on no remote branch — push it first (the Job fetches it from the cluster's mirror)"
    fi
    printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$' || ref=$(git rev-parse --verify -q "$ref^{commit}" 2>/dev/null) \
      || die 2 "--ref names no commit"
    out=$(outbase)
    job run "$repo" "$ref" "$kind" "$line" "$out" ${detach:+"$detach"} ;;
  status)
    [ $# = 1 ] || usage
    job status "$1" ;;
  logs)
    [ $# -ge 1 ] || usage
    id=$1; shift
    out=$(outbase)
    job logs "$id" "$out" "$@" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
