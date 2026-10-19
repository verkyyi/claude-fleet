#!/bin/bash
# fleet-train-reuse-selftest.sh — CI round two (issue #4794), hermetic: a sandbox
# git repo whose bin/ carries the REAL bin/run-selftests.sh, bin/ci-plan.sh and
# bin/fleet-train-reuse.sh, and a stub `gh` (FLEET_TRAIN_REUSE_GH). Nothing touches
# GitHub.
#
#   A. --among       run-selftests.sh --changed --list-only --among <files>: a changed
#                    entry file, an entry naming a changed basename, nothing for an
#                    unrelated change, every entry when the selector itself changed;
#                    without --list-only it refuses (exit 2)
#   B. --exact / --proven   a diff from a TREE off HEAD's history; a proven test is
#                    `REUSED` and not run, the plan prices it out (tests=0 when all
#                    are), --proven without --changed refuses
#   C. ci-plan.sh    run=false for an unrelated change, true for a named one, for a
#                    workflow glob, and for a base it cannot resolve
#   D. reuse         a merge whose PR's green run recorded its merge tree: the tests
#                    it ran that the later merge does not touch are reused, the touched
#                    one is not; a record whose tree base+head do not make reuses
#                    nothing; no `(#N)` reuses nothing; never a non-zero exit
#   E. the wiring    selftests.yml's plan job records selftests-selection and sizes the
#                    width by fleet-train-plan.sh; the release train runs
#                    fleet-train-reuse.sh and hands `proven` to the Linux shards and the
#                    rescue; selftests-shards.yml passes --proven; task-acceptance,
#                    client-e2e and fleet-hub-mcp skip through ci-plan.sh
# TR_LEG=<letter> runs one leg.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/train-reuse-selftest.XXXXXX")" || exit 2
trap 'rm -rf "${WORK:?}"' EXIT
LEG=${TR_LEG:-}
leg() { [ -z "$LEG" ] || [ "$LEG" = "$1" ]; }

CHECKS=0
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — does not contain [$3]:
$2" ;; esac; }
lacks() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — contains [$3]:
$2" ;; esac; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export FLEET_HEAVY=0 FLEET_SELFTEST_NO_SHADOW=1 FLEET_SELFTEST_SLOWEST=0

# ---- the sandbox repo ----------------------------------------------------------
R="$WORK/repo"
mkdir -p "$R/bin" "$R/conf" "$R/docs" "$R/tokenledger/hub"
cp "$BIN/run-selftests.sh" "$BIN/ci-plan.sh" "$BIN/fleet-train-reuse.sh" "$R/bin/"
printf 'ok\n' > "$R/conf/named.txt"
printf 'ok\n' > "$R/conf/steady.txt"
printf 'ok\n' > "$R/conf/other.txt"
printf 'x\n' > "$R/tokenledger/hub/go.mod"
cat > "$R/bin/named-selftest.sh" <<'SH'
#!/bin/bash
grep -qx ok "$(dirname "$0")/../conf/named.txt"
SH
cat > "$R/bin/steady-selftest.sh" <<'SH'
#!/bin/bash
grep -qx ok "$(dirname "$0")/../conf/steady.txt"
SH
# a client-e2e entry file: names conf/named.txt
cat > "$R/bin/client-e2e.sh" <<'SH'
#!/bin/bash
cat "$(dirname "$0")/../conf/named.txt"
SH
echo a > "$R/docs/a.md"
git -C "$R" init -q -b master && git -C "$R" add -A && git -C "$R" commit -qm base
S=$(git -C "$R" rev-parse HEAD)
commit() { git -C "$R" add -A && git -C "$R" commit -qm "$1" && git -C "$R" rev-parse HEAD; }
among() { (cd "$R/bin" && bash run-selftests.sh --changed "$1" --list-only --among "client-e2e.sh steady-selftest.sh" 2>&1); }

if leg A; then
  git -C "$R" checkout -qb a "$S"
  printf 'no\n' > "$R/conf/named.txt"; commit named >/dev/null
  eq "A named basename" "client-e2e.sh" "$(among "$S")"
  git -C "$R" checkout -q -B a "$S"; echo '# x' >> "$R/bin/client-e2e.sh"; commit self >/dev/null
  eq "A changed entry itself" "client-e2e.sh" "$(among "$S")"
  git -C "$R" checkout -q -B a "$S"; printf 'no\n' > "$R/conf/other.txt"; commit other >/dev/null
  eq "A unrelated change" "" "$(among "$S")"
  git -C "$R" checkout -q -B a "$S"; echo '# x' >> "$R/bin/run-selftests.sh"; commit harness >/dev/null
  eq "A harness ⇒ every entry" "client-e2e.sh steady-selftest.sh" "$(among "$S" | tr '\n' ' ' | sed 's/ $//')"
  (cd "$R/bin" && bash run-selftests.sh --changed "$S" --among x >/dev/null 2>&1); eq "A --among needs --list-only" 2 "$?"
  git -C "$R" checkout -q master
fi

if leg B; then
  git -C "$R" checkout -qb b "$S"
  printf 'ok\n' > "$R/conf/x.txt"; commit offside >/dev/null
  T=$(git -C "$R" rev-parse 'HEAD^{tree}')          # a tree, then a different HEAD
  git -C "$R" checkout -q -B b "$S"
  printf 'no\n' > "$R/conf/steady.txt"; printf 'ok\n' > "$R/conf/named.txt"; commit steady >/dev/null
  out=$(cd "$R/bin" && bash run-selftests.sh --changed "$T" --exact --list-only 2>&1)
  eq "B --exact from a tree off history" "steady-selftest.sh" "$out"
  printf 'steady-selftest.sh\tgreen on #7\n' > "$WORK/proven"
  out=$(cd "$R/bin" && bash run-selftests.sh --changed "$S" --proven "$WORK/proven" 2>&1)
  contains "B REUSED line" "$out" "REUSED steady-selftest.sh ← green on #7"
  contains "B nothing left to run" "$out" "nothing to run"
  out=$(cd "$R/bin" && bash run-selftests.sh --changed "$S" --proven "$WORK/proven" --plan --shard 1/3 2>&1)
  contains "B plan prices it out" "$out" "plan tests=0 total=0 shards=3"
  (cd "$R/bin" && bash run-selftests.sh --proven "$WORK/proven" >/dev/null 2>&1); eq "B --proven needs --changed" 2 "$?"
  git -C "$R" checkout -q master
fi

if leg C; then
  git -C "$R" checkout -qb c "$S"
  printf 'no\n' > "$R/conf/other.txt"; commit other >/dev/null
  eq "C unrelated ⇒ skipped" "run=false" "$(bash "$R/bin/ci-plan.sh" client-e2e "$S" | head -1)"
  printf 'no\n' > "$R/conf/named.txt"; commit named >/dev/null
  eq "C named ⇒ runs" "run=true" "$(bash "$R/bin/ci-plan.sh" client-e2e "$S" | head -1)"
  git -C "$R" checkout -q -B c "$S"; echo y >> "$R/tokenledger/hub/go.mod"; commit tl >/dev/null
  out=$(bash "$R/bin/ci-plan.sh" client-e2e "$S")
  eq "C glob ⇒ runs" "run=true" "$(printf '%s\n' "$out" | head -1)"
  contains "C glob named, not expanded" "$out" "(tokenledger/*)"
  eq "C unknown base ⇒ runs" "run=true" "$(bash "$R/bin/ci-plan.sh" client-e2e nope 2>/dev/null | head -1)"
  bash "$R/bin/ci-plan.sh" nosuch "$S" >/dev/null 2>&1; eq "C unknown workflow" 2 "$?"
  git -C "$R" checkout -q master
fi

if leg D; then
  # PR #11 changes named.txt; its gate ran named + steady green on merge(S, P)
  git -C "$R" checkout -qb pr11 "$S"
  printf 'ok\n\n' > "$R/conf/named.txt"; P=$(commit "pr head")
  TREE=$(git -C "$R" merge-tree --write-tree "$S" "$P" | head -1)
  git -C "$R" checkout -q master
  printf 'ok\n\n' > "$R/conf/named.txt"; commit "named a blank line (#11)" >/dev/null
  # then #12 touches what steady reads, and a merge with no PR number
  printf 'ok\n\n' > "$R/conf/steady.txt"; commit "steady too (#12)" >/dev/null
  echo b > "$R/docs/b.md"; commit "docs, no number" >/dev/null
  rec="$WORK/rec"; mkdir -p "$rec"
  printf 'commit 0\ntree %s\nbase %s\nhead %s\ntest named-selftest.sh\ntest steady-selftest.sh\n' "$TREE" "$S" "$P" > "$rec/good"
  printf 'commit 0\ntree %s\nbase %s\nhead %s\ntest named-selftest.sh\n' "$S" "$S" "$P" > "$rec/badtree"
  cat > "$WORK/gh" <<SH
#!/bin/bash
case "\$*" in
  *pulls/11*) echo "$P" ;;
  *pulls/12*) echo "" ;;
  *workflows/selftests.yml/runs*) echo 4242 ;;
  "run download 4242 "*) d=\${@: -1}; cp "\$REC" "\$d/selection.txt" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$WORK/gh"
  out=$(cd "$R" && REC="$rec/good" FLEET_TRAIN_REUSE_GH="$WORK/gh" bash bin/fleet-train-reuse.sh --repo o/r --stable "$S" 2>"$WORK/err"); rc=$?
  eq "D exit 0" 0 "$rc"
  contains "D named reused" "$out" "named-selftest.sh	green on #11 (run 4242, tree ${TREE:0:7})"
  lacks "D steady touched since ⇒ runs" "$out" "steady-selftest.sh"
  contains "D says why for no number" "$(cat "$WORK/err")" "names no PR"
  out=$(cd "$R" && REC="$rec/badtree" FLEET_TRAIN_REUSE_GH="$WORK/gh" bash bin/fleet-train-reuse.sh --repo o/r --stable "$S" 2>"$WORK/err"); rc=$?
  eq "D bad tree exit 0" 0 "$rc"
  eq "D bad tree reuses nothing" "" "$out"
  contains "D bad tree said" "$(cat "$WORK/err")" "do not make the tree"
fi

if leg E; then
  W="$ROOT/.github/workflows"
  y=$(cat "$W/selftests.yml")
  contains "E PR plan sizes the width" "$y" "fleet-train-plan.sh --base \"\$BASE\" --prefix pr"
  contains "E PR plan records the selection" "$y" "name: selftests-selection"
  contains "E PR shards take the plan" "$y" "needs.plan.outputs.shards"
  y=$(cat "$W/release-train.yml")
  contains "E train runs reuse" "$y" "bin/fleet-train-reuse.sh --repo"
  contains "E train prices it out" "$y" "--proven proven.txt"
  eq "E linux + rescue get proven" 2 "$(grep -c 'proven: \${{ needs.plan.outputs.proven }}' "$W/release-train.yml")"
  contains "E shards pass --proven" "$(cat "$W/selftests-shards.yml")" '--proven "$RUNNER_TEMP/proven"'
  for wf in task-acceptance:task-acceptance client-e2e:client-e2e fleet-hub:fleet-hub-mcp; do
    contains "E ${wf%%:*} skips through ci-plan" "$(cat "$W/${wf%%:*}.yml")" "bin/ci-plan.sh ${wf#*:} "
  done
fi

printf 'fleet-train-reuse-selftest: %d checks passed\n' "$CHECKS"
