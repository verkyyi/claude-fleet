#!/bin/bash
# fleet-train-superseded.sh <train sha> [--dir <checkout>] [--remote <name>] [--hub <url>]
#   — is this train already overtaken? (issue #3143, EPIC #3139 C4; BREAK-IT
#   `train-superseded-red`)
#
# A train boards master's head and spends most of an hour testing it. Meanwhile
# stable may move past TRAIN_SHA — by hand, or by a later train. Run 38139898013
# (5e11587) passed every test, the precheck and the hub deploy, then went red on
# the hub's 409 「5e11587 is not forward of 15d87a1」: nothing was wrong with it,
# it was simply late. A late train has nothing left to ship, so it should end
# green, not red.
#
# Superseded = the stable tag on <remote> (refs/tags/stable) OR the hub's stable
# (GET <hub>/v1/fleet/release/stable) equals TRAIN_SHA or descends from it. Then
# it prints `superseded: stable is at <sha7>, already ahead of <train7>` (and the
# same line to $GITHUB_STEP_SUMMARY), appends `superseded=true` to $GITHUB_OUTPUT,
# and exits 0. Otherwise it exits 1 (and writes `superseded=false`). A stable
# that cannot be read is not "ahead" — that side simply does not count.
#
# The release job asks it before publishing, and again when the publish answers
# 409 (not forward) or the move refuses on a stable that no longer is TRAIN_SHA's
# ancestor.
#
# Exit: 0 superseded · 1 not · 2 usage
set -u
die() { printf 'fleet-train-superseded: %s\n' "$*" >&2; exit 2; }
sha='' dir=. remote=origin hub=${FLEET_HUB_URL:-}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)    shift; dir="${1:-}" ;;
    --remote) shift; remote="${1:-}" ;;
    --hub)    shift; hub="${1:-}" ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$sha" ] || die "one train sha only"; sha="$1" ;;
  esac
  shift
done
[ -n "$sha" ] || die "usage: fleet-train-superseded.sh <train sha> [--dir <checkout>] [--hub <url>]"
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "$dir is not a git checkout"
sha=$(git -C "$dir" rev-parse -q --verify "$sha^{commit}") || die "unknown commit $sha"

out() { [ -z "${GITHUB_OUTPUT:-}" ] || printf 'superseded=%s\n' "$1" >> "$GITHUB_OUTPUT"; }

# ahead <stable sha> — stable equals TRAIN_SHA or descends from it
ahead() {
  [ -n "$1" ] || return 1
  git -C "$dir" cat-file -e "$1^{commit}" 2>/dev/null || git -C "$dir" fetch -q "$remote" "$1" 2>/dev/null || return 1
  git -C "$dir" merge-base --is-ancestor "$sha" "$1"
}

tag=$(git -C "$dir" ls-remote "$remote" refs/tags/stable 'refs/tags/stable^{}' 2>/dev/null |
  awk '$2 ~ /\^\{\}$/ { p = $1 } NF && !t { t = $1 } END { print (p != "" ? p : t) }')
hubsha=''
if [ -n "$hub" ]; then
  hubsha=$(curl -fsS -m 30 "${hub%/}/v1/fleet/release/stable" 2>/dev/null |
    sed -n 's/^.*"sha": *"\([0-9a-f]\{40\}\)".*$/\1/p' | head -1)
fi

for s in "$tag" "$hubsha"; do
  if ahead "$s"; then
    if [ "$s" = "$tag" ]; then where="the stable tag"; else where="the hub's stable"; fi
    line="superseded: stable is at ${s:0:7}, already ahead of ${sha:0:7} ($where) — nothing left for this train to ship"
    printf '%s\n' "$line"
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '### ⏭ %s\n' "$line" >> "$GITHUB_STEP_SUMMARY"
    out true
    exit 0
  fi
done
out false
exit 1
