#!/bin/bash
# fleet-train-board.sh [--dir <checkout>] [--remote <name>] [--branch <trunk>]
#                      [--timeout <s>] [--limit <n>]
#   — what one release train carries (issue #3141, EPIC #3139 C2).
#
# The train (.github/workflows/release-train.yml) runs in ONE concurrency lane:
# one train running, the newest one waiting. A waiting train may have been queued
# by a push long gone, so it never trusts the commit that queued it (GITHUB_SHA):
# at the moment it starts it fetches <remote>/<branch> and boards THAT head —
# every merge since stable rides along (EPIC #3139 共同约定 1).
#
# Prints, and appends to $GITHUB_OUTPUT when set, one `key=value` line each:
#   train_sha     the head of <remote>/<branch> right now (TRAIN_SHA)
#   stable_sha    refs/tags/stable on <remote> (empty: no tag yet)
#   skip          true when stable already IS the head — the train has nothing to
#                 carry and ends here; false otherwise
#   merges_json   the first-parent commits stable..TRAIN_SHA, newest first, as a
#                 JSON list of {sha, subject, committed (ISO 8601)} — the merges
#                 this train carries (C1's book); at most --limit (default 200)
#   merges        how many that is
# A stable that is not an ancestor of the head (moved off trunk by hand) is
# refused: stable only moves forward, so no train could ever release.
#
# Exit: 0 boarded (or nothing to carry) · 1 stable off trunk · 2 usage / read error
set -u
dir=. remote=origin branch=master timeout=15 limit=200
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)     shift; dir="${1:-}" ;;
    --remote)  shift; remote="${1:-}" ;;
    --branch)  shift; branch="${1:-}" ;;
    --timeout) shift; timeout="${1:-15}" ;;
    --limit)   shift; limit="${1:-200}" ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         printf 'fleet-train-board: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
case "$timeout" in ''|*[!0-9]*|0) timeout=15 ;; esac
case "$limit" in ''|*[!0-9]*|0) limit=200 ;; esac
die() { printf 'fleet-train-board: %s\n' "$*" >&2; exit 2; }
g() { git -C "$dir" -c http.lowSpeedLimit=1000 -c "http.lowSpeedTime=$timeout" "$@"; }

g rev-parse --git-dir >/dev/null 2>&1 || die "$dir is not a git checkout (--dir)"
g fetch --no-tags -q "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" 2>/dev/null \
  || die "could not fetch $remote/$branch"
train=$(g rev-parse --verify -q "refs/remotes/$remote/$branch^{commit}") || die "no $remote/$branch"

ls=$(g ls-remote "$remote" "refs/tags/stable" "refs/tags/stable^{}" 2>/dev/null) \
  || die "could not read refs/tags/stable from $remote"
stable=$(printf '%s\n' "$ls" | awk '$2 ~ /\^\{\}$/ {print $1; exit}')
[ -n "$stable" ] || stable=$(printf '%s\n' "$ls" | awk 'NF {print $1; exit}')
if [ -n "$stable" ] && ! g cat-file -e "$stable^{commit}" 2>/dev/null; then
  g fetch --no-tags -q "$remote" "$stable" 2>/dev/null
  g cat-file -e "$stable^{commit}" 2>/dev/null || die "could not fetch the stable commit $stable"
fi

skip=false range=$train
if [ -n "$stable" ]; then
  if [ "$stable" = "$train" ]; then
    skip=true
  elif g merge-base --is-ancestor "$stable" "$train"; then
    range="$stable..$train"
  else
    printf 'fleet-train-board: stable %.7s is not an ancestor of %s/%s %.7s — stable only moves forward; no train can release from here\n' \
      "$stable" "$remote" "$branch" "$train" >&2
    exit 1
  fi
fi
if [ "$skip" = true ]; then
  merges='[]'
else
  merges=$(g log --first-parent -n "$limit" --format='%H%x09%cI%x09%s' "$range" | python3 -c '
import json, sys
out = []
for line in sys.stdin:
    sha, when, subj = (line.rstrip("\n").split("\t", 2) + ["", ""])[:3]
    if sha:
        out.append({"sha": sha, "subject": subj, "committed": when})
print(json.dumps(out, ensure_ascii=False, separators=(",", ":")))') || die "could not list $range"
fi
n=$(printf '%s' "$merges" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')

emit() {
  printf 'train_sha=%s\nstable_sha=%s\nskip=%s\nmerges=%s\nmerges_json=%s\n' "$train" "$stable" "$skip" "$n" "$merges"
}
emit
[ -z "${GITHUB_OUTPUT:-}" ] || emit >> "$GITHUB_OUTPUT"
if [ "$skip" = true ]; then
  printf 'board: stable is already %.7s, the head of %s/%s — nothing to carry, this train is empty\n' "$train" "$remote" "$branch" >&2
else
  printf 'board: TRAIN_SHA %.7s (queued by %.7s) carries %s merge(s) since stable %.7s\n' \
    "$train" "${GITHUB_SHA:-?}" "$n" "${stable:-none}" >&2
fi
exit 0
