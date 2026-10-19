#!/bin/bash
# fleet-train-reuse.sh --repo <owner/name> --stable <sha> [--dir <repo>] [--out <file>]
#                      [--max <N>]
#   — the selftests the release train need not run again: they already passed on
#   a PR, on a tree this train's change does not touch them from (issue #4794).
#
# The train tests `--changed <stable>` on TRAIN_SHA: every test the merges since
# stable select — and each of those merges already ran its own selection, green,
# on its PR. Run again, that is the same test on nearly the same tree. So for each
# merge in stable..HEAD (newest first, at most --max, default 30) whose PR says
# which PR it was (the squash subject's `(#N)`):
#   1. the PR's FINAL head (`pulls/N` .head.sha) has a green `selftests` run, and
#      that run uploaded `selftests-selection` (selftests.yml's plan job): the
#      merge tree it tested, the base and head it merged, the tests it selected;
#   2. `git merge-tree --write-tree <base> <head>` here gives that SAME tree — what
#      the record says was tested is what those two commits make, nothing else;
#   3. `run-selftests.sh --changed <tree> --exact --list-only` on HEAD — the one
#      selector, the train's own copy, from that tree to this one: every test it
#      lists is touched since, and runs. A test the PR ran green and this does NOT
#      list is printed `<test><TAB><why>` — the shards skip it
#      (run-selftests.sh --proven, `REUSED <test> ← <why>`).
# The same trust the PR gate already gives a test it does not select: the selector
# says the diff cannot reach it. Anything this cannot read — no `(#N)`, no green
# run of the final head, no record (a PR from before this script), a head it
# cannot fetch, a tree that does not match, a selector that falls back to the full
# suite — reuses nothing from that merge, so the train runs the test. Never an
# error: the train runs either way, exit 0. The nightly full run
# (selftests-nightly.yml) is the backstop, as for every selection.
# FLEET_TRAIN_REUSE_GH replaces `gh` (the selftest's seam).
set -uo pipefail

repo='' stable='' dir=. out='' max=30
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --stable) stable=$2; shift 2 ;;
    --dir) dir=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --max) max=$2; shift 2 ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "fleet-train-reuse: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$repo" ] && [ -n "$stable" ] || { echo "fleet-train-reuse: --repo and --stable are required" >&2; exit 2; }
case "$max" in ''|*[!0-9]*) echo "fleet-train-reuse: --max wants a whole number" >&2; exit 2 ;; esac
gh=${FLEET_TRAIN_REUSE_GH:-gh}
dir=$(cd "$dir" && pwd) || exit 2
work=$(mktemp -d "${TMPDIR:-/tmp}/train-reuse.XXXXXX") || exit 2
trap 'rm -rf "${work:?}"' EXIT
: > "$work/proven"
say() { printf 'reuse: %s\n' "$*" >&2; }

merges=$(git -C "$dir" rev-list --first-parent "$stable..HEAD" 2>/dev/null | head -n "$max")
[ -n "$merges" ] || say "no merge since ${stable:0:7} to read"
for c in $merges; do
  subj=$(git -C "$dir" log -1 --format=%s "$c")
  pr=$(printf '%s\n' "$subj" | sed -nE 's/.*\(#([0-9]+)\)$/\1/p')
  [ -n "$pr" ] || { say "${c:0:7} names no PR — nothing reused from it"; continue; }
  head=$($gh api "repos/$repo/pulls/$pr" --jq '.head.sha' 2>/dev/null)
  [ -n "$head" ] || { say "#$pr: cannot read the PR"; continue; }
  # the newest green selftests run of exactly that head, with its record
  run=$($gh api "repos/$repo/actions/workflows/selftests.yml/runs?event=pull_request&status=success&head_sha=$head&per_page=5" \
          --jq '.workflow_runs[0].id // empty' 2>/dev/null)
  [ -n "$run" ] || { say "#$pr: no green selftests run of its final head ${head:0:7}"; continue; }
  rd="$work/$pr"; mkdir -p "$rd"
  if ! $gh run download "$run" --repo "$repo" --name selftests-selection --dir "$rd" >/dev/null 2>&1 \
     || [ ! -f "$rd/selection.txt" ]; then
    say "#$pr: run $run left no selftests-selection record"; continue
  fi
  field() { awk -v k="$1" '$1 == k { print $2; exit }' "$rd/selection.txt"; }
  tree=$(field tree) base=$(field base) phead=$(field head)
  [ -n "$tree" ] && [ -n "$base" ] && [ "$phead" = "$head" ] \
    || { say "#$pr: the record of run $run is not for ${head:0:7}"; continue; }
  git -C "$dir" cat-file -e "$head^{commit}" 2>/dev/null \
    || git -C "$dir" fetch -q --no-tags origin "$head" 2>/dev/null \
    || git -C "$dir" fetch -q --no-tags origin "refs/pull/$pr/head" 2>/dev/null
  git -C "$dir" cat-file -e "$base^{commit}" 2>/dev/null \
    || git -C "$dir" fetch -q --no-tags origin "$base" 2>/dev/null
  made=$(git -C "$dir" merge-tree --write-tree "$base" "$head" 2>/dev/null | head -1)
  [ "$made" = "$tree" ] \
    || { say "#$pr: ${base:0:7} + ${head:0:7} do not make the tree run $run tested (${tree:0:7})"; continue; }
  touched=$(cd "$dir/bin" && FLEET_HEAVY=0 bash run-selftests.sh --changed "$tree" --exact --list-only 2>/dev/null) \
    || { say "#$pr: the selector could not read ${tree:0:7} → HEAD"; continue; }
  n=0
  for t in $(awk '$1 == "test" { print $2 }' "$rd/selection.txt"); do
    printf '%s\n' "$touched" | grep -qxF -- "$t" && continue
    awk -F '\t' -v t="$t" '$1 == t { f = 1 } END { exit !f }' "$work/proven" && continue
    printf '%s\tgreen on #%s (run %s, tree %s), untouched since\n' "$t" "$pr" "$run" "${tree:0:7}" >> "$work/proven"
    n=$((n + 1))
  done
  say "#$pr: $n test(s) reused from run $run"
done

say "$(awk 'END { print NR }' "$work/proven") test(s) reused in all"
if [ -n "$out" ]; then cp "$work/proven" "$out"; else cat "$work/proven"; fi
exit 0
