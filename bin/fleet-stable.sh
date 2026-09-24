#!/bin/sh
# fleet-stable.sh show | move [<sha>] [--dry-run] [--allow-no-checks]
#                 [--dir <checkout>] [--remote <name>] [--branch <trunk>]
#                 [--repo <owner/name>] [--timeout <s>]
#   — the "stable" mark every install follows (issue #1118, EPIC #1117 C1).
#
# Merging to master used to be the same event as "this reaches all my machines"
# — or nothing did. There was no place that said "this version, I vouch for it".
# `refs/tags/stable` on the public repo is that place: the operator moves it with
# ONE command, and every login/machine follows the tag (C3, #1120), never master.
#
#   show   where `stable` points and how many commits it trails origin/<trunk>.
#          A missing tag is said out loud (`stable: none`), never read as 0.
#   move   move `stable` to <sha> (default: origin/<trunk>). Refuses unless ALL of:
#            1. the target is a commit on origin/<trunk> (no PR branch, no
#               local-only commit — every install fast-forwards along trunk);
#            2. FORWARD ONLY — the old stable is an ancestor of the target
#               (moving back, or sideways, is refused; the same target is a no-op);
#            3. the target's CI is all green: every check run on it (gh api
#               repos/<repo>/commits/<sha>/check-runs) is completed with
#               success / neutral / skipped. Pending = not green. ZERO check runs
#               is refused too — push CI is path-filtered, so a docs-only commit
#               has none; `--allow-no-checks` accepts that deliberately.
#          Then pushes <sha>:refs/tags/stable with --force-with-lease pinned to
#          the value it read, so two concurrent moves cannot both win — the
#          loser's push is rejected and nothing is overwritten.
#          --dry-run runs every check and prints the push, without pushing.
#
# The tag is lightweight. The source of truth is the REMOTE ref (read with
# `git ls-remote`, https, no credentials); no local `stable` tag is written, so
# the checkout this runs in is never changed beyond a remote-tracking fetch.
#
# `show` prints line-anchored `key: value` lines (fleet-doctor parses them):
#   stable:  <sha>|none      subject: <first line>     trunk: origin/<b> <sha>
#   behind:  <n>|?           verdict: CURRENT|BEHIND|NONE|OFFTRUNK|UNKNOWN
#
# Exit codes:
#   show  0 tag read (CURRENT/BEHIND/OFFTRUNK) · 1 NONE · 2 UNKNOWN / usage
#   move  0 moved (or already there, or dry-run passed) · 2 usage / read error
#         3 refused (not on trunk / backward / CI not green) · 4 push failed
#           (lease lost to a concurrent move, or no push rights)
set -u

BIN_DIR=$(cd "$(dirname "$0")" && pwd)
dir="$(cd "$BIN_DIR/.." && pwd)"
remote=origin branch=master repo="" timeout=15 dry=0 allow_nochecks=0
cmd="" target=""
TAG=stable

die() { printf 'fleet-stable: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'fleet-stable: REFUSED — %s\n' "$*" >&2; exit 3; }

[ "$#" -gt 0 ] || { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    show|move)         [ -z "$cmd" ] || die "one subcommand only"; cmd="$1" ;;
    --dry-run|-n)      dry=1 ;;
    --allow-no-checks) allow_nochecks=1 ;;
    --dir)             shift; dir="${1:-}" ;;
    --remote)          shift; remote="${1:-}" ;;
    --branch)          shift; branch="${1:-}" ;;
    --repo)            shift; repo="${1:-}" ;;
    --timeout)         shift; timeout="${1:-15}" ;;
    -h|--help)         sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)                die "unknown flag $1" ;;
    *)                 [ "$cmd" = move ] && [ -z "$target" ] || die "unexpected argument $1"
                       target="$1" ;;
  esac
  shift
done
[ -n "$cmd" ] || die "usage: fleet-stable.sh show | move [<sha>] [--dry-run]"
case "$timeout" in ''|*[!0-9]*|0) timeout=15 ;; esac
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "$dir is not a git checkout (--dir)"

# git's own stall abort bounds every network call — macOS has no timeout(1).
g() { git -C "$dir" -c http.lowSpeedLimit=1000 -c "http.lowSpeedTime=$timeout" "$@"; }

# The remote tag's commit. Prints the sha, or nothing when the tag is absent;
# returns 2 when the remote could not be read (which is NOT "absent").
remote_stable() {
  _ls=$(g ls-remote "$remote" "refs/tags/$TAG" "refs/tags/$TAG^{}" 2>/dev/null) || return 2
  # An annotated tag lists its peeled commit as ^{}; prefer that line.
  _peeled=$(printf '%s\n' "$_ls" | awk '$2 ~ /\^\{\}$/ {print $1; exit}')
  [ -n "$_peeled" ] && { printf '%s\n' "$_peeled"; return 0; }
  printf '%s\n' "$_ls" | awk 'NF {print $1; exit}'
}

fetch_trunk() {
  g fetch --no-tags -q "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" 2>/dev/null
}

# Make sure <sha> exists locally (a tag may point at a commit this clone lacks).
have_commit() {
  git -C "$dir" cat-file -e "$1^{commit}" 2>/dev/null && return 0
  g fetch --no-tags -q "$remote" "$1" 2>/dev/null
  git -C "$dir" cat-file -e "$1^{commit}" 2>/dev/null
}

short() { git -C "$dir" rev-parse --short "$1" 2>/dev/null || printf '%.7s' "$1"; }
subject() { git -C "$dir" log -1 --format=%s "$1" 2>/dev/null; }

do_show() {
  old=$(remote_stable); rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'stable:  ?\nverdict: UNKNOWN\nnote:    could not read refs/tags/%s from %s\n' "$TAG" "$remote"
    exit 2
  fi
  if fetch_trunk; then tip=$(git -C "$dir" rev-parse -q --verify "refs/remotes/$remote/$branch^{commit}"); else tip=""; fi
  if [ -z "$old" ]; then
    printf 'stable:  none\ntrunk:   %s/%s %s\nverdict: NONE\nnote:    no refs/tags/%s on %s yet — nothing to follow; set it with: fleet-stable.sh move <sha>\n' \
      "$remote" "$branch" "$(short "${tip:-?}")" "$TAG" "$remote"
    exit 1
  fi
  printf 'stable:  %s\n' "$(short "$old")"
  if [ -z "$tip" ] || ! have_commit "$old"; then
    printf 'behind:  ?\nverdict: UNKNOWN\nnote:    could not fetch %s/%s or the stable commit — behind count unknown, NOT 0\n' "$remote" "$branch"
    exit 2
  fi
  printf 'subject: %s\ntrunk:   %s/%s %s\n' "$(subject "$old")" "$remote" "$branch" "$(short "$tip")"
  behind=$(git -C "$dir" rev-list --count "$old..$tip")
  printf 'behind:  %s\n' "$behind"
  if ! git -C "$dir" merge-base --is-ancestor "$old" "$tip"; then
    printf 'verdict: OFFTRUNK\nnote:    stable is not on %s/%s — the next move must come from trunk and descend from it\n' "$remote" "$branch"
  elif [ "$behind" -eq 0 ]; then
    printf 'verdict: CURRENT\n'
  else
    printf 'verdict: BEHIND\n'
  fi
  exit 0
}

# owner/name from the remote URL, unless --repo said so.
repo_slug() {
  [ -n "$repo" ] && { printf '%s\n' "$repo"; return; }
  git -C "$dir" remote get-url "$remote" 2>/dev/null |
    sed -n 's#^.*github\.com[:/]\([^/]*/[^/]*\)$#\1#p' | sed 's#\.git$##'
}

# Every check run on <sha>, one "status conclusion name" line each.
check_runs() {
  gh api --paginate "repos/$1/commits/$2/check-runs?per_page=100" \
    --jq '.check_runs[] | "\(.status) \(.conclusion) \(.name)"'
}

do_move() {
  old=$(remote_stable) || die "could not read refs/tags/$TAG from $remote — not moving blind"
  fetch_trunk || die "could not fetch $remote/$branch"
  tip=$(git -C "$dir" rev-parse --verify "refs/remotes/$remote/$branch^{commit}") || die "no $remote/$branch"
  if [ -z "$target" ]; then new="$tip"
  else
    have_commit "$target" || :
    new=$(git -C "$dir" rev-parse -q --verify "$target^{commit}") || die "unknown commit $target"
  fi

  git -C "$dir" merge-base --is-ancestor "$new" "$tip" ||
    refuse "$(short "$new") is not on $remote/$branch — stable only ever names a trunk commit"
  if [ -n "$old" ]; then
    have_commit "$old" || die "could not fetch the current stable commit $(short "$old")"
    if [ "$old" = "$new" ]; then
      printf 'stable already at %s — nothing to move\n' "$(short "$new")"; exit 0
    fi
    git -C "$dir" merge-base --is-ancestor "$old" "$new" ||
      refuse "$(short "$new") does not descend from the current stable $(short "$old") — stable only moves FORWARD"
  fi

  slug=$(repo_slug); [ -n "$slug" ] || die "cannot tell the GitHub repo from $remote — pass --repo owner/name"
  runs=$(check_runs "$slug" "$new") || die "could not read check runs for $(short "$new") on $slug (gh auth?)"
  bad=$(printf '%s\n' "$runs" | awk 'NF && !($1=="completed" && ($2=="success" || $2=="neutral" || $2=="skipped"))')
  total=$(printf '%s\n' "$runs" | awk 'NF' | wc -l | tr -d ' ')
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad" | sed 's/^/  not green: /' >&2
    refuse "$(short "$new") has check runs that are not green — CI must be all green to move stable"
  fi
  if [ "$total" -eq 0 ] && [ "$allow_nochecks" -ne 1 ]; then
    refuse "$(short "$new") has NO check runs (path-filtered CI?) — no evidence it is green; pick a commit CI ran on, or pass --allow-no-checks"
  fi

  # Lease: the tag must still hold exactly what we read ("" = must not exist).
  lease="refs/tags/$TAG:$old"
  printf 'stable: %s -> %s  (%s)\n' "${old:+$(short "$old")}${old:-none}" "$(short "$new")" "$(subject "$new")"
  printf 'checks: %s green on %s\n' "$total" "$slug"
  if [ "$old" ]; then printf 'forward: +%s commit(s)\n' "$(git -C "$dir" rev-list --count "$old..$new")"; fi
  if [ "$dry" -eq 1 ]; then
    printf 'dry-run: would run: git push --force-with-lease=%s %s %s:refs/tags/%s\n' "$lease" "$remote" "$new" "$TAG"
    exit 0
  fi
  if ! g push -q "--force-with-lease=$lease" "$remote" "$new:refs/tags/$TAG"; then
    printf 'fleet-stable: push FAILED — stable moved under us (lease lost) or no push rights; re-run show and try again\n' >&2
    exit 4
  fi
  printf 'moved: refs/tags/%s = %s\n' "$TAG" "$(short "$new")"
}

case "$cmd" in
  show) do_show ;;
  move) do_move ;;
esac
