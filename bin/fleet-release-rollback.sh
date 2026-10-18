#!/bin/bash
# fleet-release-rollback.sh <PR number | merge sha> [--repo <owner/name>] [--remote <url>]
#                           [--hub-tag prod-<sha7>] [--no-merge] [--dry-run]
#   — take a bad change back out of production in ONE command (issue #4663).
#
# Since #4663 no check holds a release on a Mac or on the China probe's test road:
# a problem shows in production and is fixed fast. This is the fast part. It
#   1. resolves the change: a PR number → its merge commit (it must be MERGED), or
#      a commit on the base branch;
#   2. in a throwaway clone (never the caller's checkout — a base checkout is
#      read-only), branches `rollback-<sha7>` off the base, `git revert`s that
#      one commit (a squash merge has one parent) and pushes it;
#   3. opens the PR 「回滚 #N：<title>」 and merges it at once (squash, branch
#      deleted) — a revert of code that already shipped needs no fresh review, and
#      the release train ships it like any merge (Linux and every Mac follow);
#      --no-merge leaves the PR open instead;
#   4. --hub-tag prod-<sha7>: also puts the hub back on that image now
#      (`hub-deploy.yml` dispatched with tag=…, the existing rollback road), without
#      waiting for the train.
# A revert that does not apply cleanly stops before anything is pushed, saying so.
#
# Env: GH_TOKEN / gh's own login. FLEET_ROLLBACK_GH is a test seam for gh.
# Exit: 0 reverted (and merged unless --no-merge) · 1 a step failed · 2 usage ·
#       3 refused (not merged, not on the base, the revert conflicts)
set -u
GH=${FLEET_ROLLBACK_GH:-gh}
die()    { printf 'fleet-release-rollback: %s\n' "$*" >&2; exit 2; }
fail()   { printf 'fleet-release-rollback: %s\n' "$*" >&2; exit 1; }
refuse() { printf 'fleet-release-rollback: REFUSED — %s\n' "$*" >&2; exit 3; }
say()    { printf 'rollback: %s\n' "$*"; }

what='' repo='' remote='' hub_tag='' merge=1 dry=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)     shift; repo="${1:-}" ;;
    --remote)   shift; remote="${1:-}" ;;
    --hub-tag)  shift; hub_tag="${1:-}"
                case "$hub_tag" in prod-[0-9a-f]*) ;; *) die "--hub-tag takes prod-<sha7> (an image hub-deploy built)" ;; esac ;;
    --no-merge) merge=0 ;;
    --dry-run)  dry=1 ;;
    -h|--help)  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         die "unknown flag $1" ;;
    *)          [ -z "$what" ] || die "one change at a time (got $what and $1)"; what="$1" ;;
  esac
  shift
done
[ -n "$what" ] || die "usage: fleet-release-rollback.sh <PR number | merge sha> [--repo owner/name] [--hub-tag prod-<sha7>] [--no-merge] [--dry-run]"
if [ -z "$repo" ]; then
  repo=$($GH repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || repo=''
  [ -n "$repo" ] || die "cannot tell the repo — pass --repo owner/name"
fi
base=$($GH api "repos/$repo" --jq .default_branch 2>/dev/null) || base=''
[ -n "$base" ] || base=master
[ -n "$remote" ] || remote="https://github.com/$repo.git"

# 1. the change
pr='' title=''
case "$what" in
  *[!0-9]*) sha=$what ;;
  *)  pr=$what
      row=$($GH pr view "$pr" --repo "$repo" --json state,mergeCommit,title \
              --jq '"\(.state)\t\(.mergeCommit.oid // "")\t\(.title)"' 2>/dev/null) || fail "could not read PR #$pr on $repo"
      st=$(printf '%s' "$row" | cut -f1) sha=$(printf '%s' "$row" | cut -f2) title=$(printf '%s' "$row" | cut -f3-)
      [ "$st" = MERGED ] && [ -n "$sha" ] || refuse "PR #$pr is $st, not merged — nothing shipped to take back" ;;
esac

# 2. the revert, in a clone of its own
T=$(mktemp -d "${TMPDIR:-/tmp}/fleet-rollback.XXXXXX") || fail "no temp dir"
trap 'rm -rf "$T"' EXIT
g() { git -C "$T/co" -c user.name="${GIT_AUTHOR_NAME:-fleet rollback}" -c user.email="${GIT_AUTHOR_EMAIL:-fleet-rollback@users.noreply.github.com}" "$@"; }
git clone -q --no-tags --branch "$base" "$remote" "$T/co" 2>"$T/err" || fail "could not clone $remote: $(tail -1 "$T/err")"
full=$(g rev-parse -q --verify "$sha^{commit}") || refuse "$sha is not a commit of $repo"
g merge-base --is-ancestor "$full" HEAD || refuse "$(printf '%.7s' "$full") is not on $base — only a change that shipped is rolled back"
s7=$(printf '%.7s' "$full")
[ -n "$title" ] || title=$(g log -1 --format=%s "$full")
[ -n "$pr" ] || pr=$(printf '%s' "$title" | sed -n 's/.*(#\([0-9][0-9]*\))$/\1/p')
br="rollback-$s7"
g switch -q -c "$br" || fail "could not branch $br"
if ! g revert --no-edit "$full" >"$T/rev" 2>&1; then
  g revert --abort >/dev/null 2>&1
  refuse "the revert of $s7 does not apply cleanly on $base (a later change builds on it) — revert by hand: $(tail -1 "$T/rev")"
fi
ref=${pr:+#$pr}; ref=${ref:-$s7}
ptitle="回滚 ${ref}：$title"
pbody="回滚 ${pr:+#${pr}（}$s7${pr:+）}：问题在生产上暴露，先撤回（#4663 · \`bin/fleet-release-rollback.sh\`）。合并后列车会把这次撤回发出去，Linux 和每台 Mac 都会跟上。${hub_tag:+
hub 已直接切回镜像 \`$hub_tag\`。}

${pr:+Reverts #$pr}"
if [ "$dry" = 1 ]; then
  say "would push $br (revert of $s7) and open: $ptitle"
  [ "$merge" = 0 ] || say "would merge it at once (squash)"
  [ -z "$hub_tag" ] || say "would dispatch hub-deploy.yml with tag=$hub_tag"
  exit 0
fi
g push -q origin "$br" 2>"$T/err" || fail "could not push $br: $(tail -1 "$T/err")"
url=$($GH pr create --repo "$repo" --base "$base" --head "$br" --title "$ptitle" --body "$pbody" 2>"$T/err" | tail -1) \
  || fail "pushed $br but could not open its PR: $(tail -1 "$T/err")"
say "opened $url"

# 4. the hub, now (before the merge: the train takes minutes, the dispatch seconds)
if [ -n "$hub_tag" ]; then
  $GH workflow run hub-deploy.yml --repo "$repo" -f tag="$hub_tag" >/dev/null 2>"$T/err" \
    && say "hub-deploy dispatched with tag=$hub_tag" \
    || printf 'fleet-release-rollback: WARN could not dispatch hub-deploy tag=%s: %s\n' "$hub_tag" "$(tail -1 "$T/err")" >&2
fi

# 3. merge it
if [ "$merge" = 1 ]; then
  $GH pr merge "$url" --repo "$repo" --squash --delete-branch >/dev/null 2>"$T/err" \
    || fail "opened $url but could not merge it: $(tail -1 "$T/err") — merge it by hand"
  say "merged — the release train ships the revert (Linux and every Mac follow on their next update)"
fi
exit 0
