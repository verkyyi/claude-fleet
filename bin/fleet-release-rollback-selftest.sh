#!/bin/bash
# fleet-release-rollback-selftest.sh — bin/fleet-release-rollback.sh (issue #4663): one
# command takes a shipped change back out, in a clone of its own.
#
#   A  a merged PR → `rollback-<sha7>` pushed with exactly the revert of its merge
#      commit, a PR 「回滚 #N：…」 opened on the base and merged at once; the
#      caller's own checkout is never touched
#   B  --no-merge opens the PR and leaves it; --hub-tag dispatches hub-deploy.yml
#      with tag=… ; --dry-run pushes nothing and opens nothing
#   C  refusals (exit 3, nothing pushed): a PR not merged; a commit not on the
#      base; a revert that does not apply (a later change builds on it)
#   D  usage (exit 2): no change named; a --hub-tag that is not prod-<sha7>
set -u
BIN=$(cd -- "$(dirname -- "$0")" && pwd)
RB="$BIN/fleet-release-rollback.sh"
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

FAILS=0 CHECKS=0
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
eq()   { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1: want [$2] got [$3]"; }
has()  { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1: no [$3] in: $2" ;; esac; }

T=$(mktemp -d "${TMPDIR:-/tmp}/fleet-rollback-selftest.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
git init -q --bare -b master "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
c() { printf '%s\n' "$2" > "$T/seed/$1"; git -C "$T/seed" add -A; git -C "$T/seed" commit -qm "$3"; git -C "$T/seed" rev-parse HEAD; }
c a.txt one 'base' >/dev/null
BAD=$(c b.txt bad 'bad change (#41)')
C3=$(c c.txt three 'unrelated (#42)')
DEP=$(c d.txt dep 'needs a reshape (#43)')
LATER=$(c d.txt dep2 'builds on it (#44)')
git -C "$T/seed" push -q origin HEAD:master
git -C "$T/seed" switch -q -c side; OFF=$(c e.txt side 'never merged'); git -C "$T/seed" push -q origin side
git -C "$T/seed" switch -q master
git clone -q "$T/origin.git" "$T/mine" 2>/dev/null; MINE=$(git -C "$T/mine" rev-parse HEAD)

# gh: records every call; a PR's state and merge commit come from $T/pr.<N>
cat > "$T/gh" <<SH
#!/bin/sh
echo "\$*" >> "$T/calls"
case "\$*" in
  'repo view'*) echo o/r ;;
  'api repos/o/r --jq .default_branch') echo master ;;
  'pr view '*) n=\$(echo "\$*" | awk '{print \$3}'); cat "$T/pr.\$n" 2>/dev/null || exit 1 ;;
  'pr create'*) echo "https://github.com/o/r/pull/99" ;;
  'pr merge'*) : ;;
  'workflow run'*) : ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/gh"
printf 'MERGED\t%s\tbad change (#41)\n' "$BAD" > "$T/pr.41"
printf 'OPEN\t\tstill open\n' > "$T/pr.50"
printf 'MERGED\t%s\tneeds a reshape (#43)\n' "$DEP" > "$T/pr.43"
run() { : > "$T/calls"; OUT=$(cd "$T/mine" && FLEET_ROLLBACK_GH="$T/gh" bash "$RB" "$@" --repo o/r --remote "$T/origin.git" 2>&1); RC=$?; }
b7=$(printf '%.7s' "$BAD")

# ── A ──
run 41
eq "A: a merged PR rolls back" 0 "$RC"
git --git-dir="$T/origin.git" rev-parse -q --verify "refs/heads/rollback-$b7" >/dev/null && R=$(git --git-dir="$T/origin.git" rev-parse "rollback-$b7") || R=''
eq "A: rollback-<sha7> pushed" 1 "$([ -n "$R" ] && echo 1 || echo 0)"
eq "A: …onto the base's head" "$LATER" "$(git --git-dir="$T/origin.git" rev-parse "$R^" 2>/dev/null)"
eq "A: …and it removes exactly the bad change" "b.txt" "$(git --git-dir="$T/origin.git" diff --name-only "$R^" "$R" 2>/dev/null)"
eq "A: b.txt is gone there" "" "$(git --git-dir="$T/origin.git" ls-tree --name-only "$R" b.txt 2>/dev/null)"
has "A: the PR is opened on master from it" "$(cat "$T/calls")" "pr create --repo o/r --base master --head rollback-$b7 --title 回滚 #41：bad change (#41)"
has "A: …and merged at once" "$(cat "$T/calls")" "pr merge https://github.com/o/r/pull/99 --repo o/r --squash --delete-branch"
eq "A: the caller's checkout untouched" "$MINE" "$(git -C "$T/mine" rev-parse HEAD)"
eq "A: …and clean" "" "$(git -C "$T/mine" status --porcelain)"

# ── B ──
git --git-dir="$T/origin.git" update-ref -d "refs/heads/rollback-$b7"
run 41 --no-merge --hub-tag prod-1234abc
eq "B: --no-merge exits 0" 0 "$RC"
case "$(cat "$T/calls")" in *'pr merge'*) fail "B: --no-merge merged" ;; esac
has "B: --hub-tag dispatches hub-deploy" "$(cat "$T/calls")" "workflow run hub-deploy.yml --repo o/r -f tag=prod-1234abc"
git --git-dir="$T/origin.git" update-ref -d "refs/heads/rollback-$b7"
run 41 --dry-run
eq "B: --dry-run exits 0" 0 "$RC"; has "B: says what it would do" "$OUT" "would push rollback-$b7"
eq "B: --dry-run pushed nothing" "" "$(git --git-dir="$T/origin.git" rev-parse -q --verify "refs/heads/rollback-$b7")"
case "$(cat "$T/calls")" in *'pr create'*|*'pr merge'*) fail "B: --dry-run opened or merged" ;; esac

# ── C ──
run 50
eq "C: an open PR is refused" 3 "$RC"; has "C: says not merged" "$OUT" "not merged"
run "$OFF"
eq "C: a commit off the base is refused" 3 "$RC"; has "C: says not on master" "$OUT" "is not on master"
run 43
eq "C: a revert that does not apply is refused" 3 "$RC"; has "C: says it does not apply" "$OUT" "does not apply cleanly"
eq "C: nothing pushed for it" "" "$(git --git-dir="$T/origin.git" rev-parse -q --verify "refs/heads/rollback-$(printf '%.7s' "$DEP")")"
case "$(cat "$T/calls")" in *'pr create'*) fail "C: a refused rollback opened a PR" ;; esac
run "$C3"
eq "C: a merge sha (not a PR number) rolls back too" 0 "$RC"
has "C: …its PR number read off the title" "$(cat "$T/calls")" "--title 回滚 #42：unrelated (#42)"

# ── D ──
run
eq "D: no change named is usage" 2 "$RC"
run 41 --hub-tag latest
eq "D: a --hub-tag not prod-<sha7> is usage" 2 "$RC"

[ "$FAILS" -eq 0 ] && { printf 'fleet-release-rollback-selftest OK (%d checks)\n' "$CHECKS"; exit 0; }
printf 'fleet-release-rollback-selftest: %d of %d checks failed\n' "$FAILS" "$CHECKS"; exit 1
