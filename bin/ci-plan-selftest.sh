#!/bin/bash
# ci-plan-selftest.sh — the ONE PR-gate plan (issue #4815, EPIC #4810 C5):
# bin/ci-plan.sh decides which checks a PR runs, .github/workflows/ci.yml calls
# them and folds them into `CI 结论`.
#
#   A  lockstep: ci-plan.sh's CHECKS ⇔ ci.yml's caller jobs (each gated on its
#      plan output) ⇔ `CI 结论`'s needs ⇔ the plan job's outputs; no workflow ci.yml
#      calls carries a pull_request trigger of its own; every check has a rule;
#      no callee's concurrency group spells ${{ github.workflow }} (it is ci.yml's
#      name inside a call — siblings would cancel each other)
#   B  Go blocks in a sandbox repo: agent ⇒ agent + e2e (never hub), hub ⇒ hub +
#      e2e (never agent), shared ⇒ all four, e2e ⇒ e2e, go.work / the Go workflow
#      ⇒ all four, an unknown tokenledger/ path ⇒ all four, docs ⇒ none
#   C  packages: inside a block only those whose test binary depends on a changed
#      package (go list -test); a block none of whose packages depends ⇒ skipped;
#      the hub/api shards only when hub/api is reached (needs go; skipped without)
#   D  unsure ⇒ run: an unknown base runs every check and every block; a change to
#      ci-plan.sh / ci.yml runs everything; a docs-only change runs nothing but
#      oss-scan
#   E  `CI 结论`'s fold: selected must be success, unselected skipped, a failed plan
#      or a cancelled check is red (the job's own python, run on fixtures)
#
# CI_PLAN_UNDER_TEST=<path> runs B–D against another copy (the BREAK-IT drill
# module-skip-wrong hands it a plan whose shared rule forgot a block).
set -uo pipefail
echo "trial #4815: deliberately red"; exit 1
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
PLAN=${CI_PLAN_UNDER_TEST:-$BIN/ci-plan.sh}
CI="$ROOT/.github/workflows/ci.yml"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ci-plan-selftest.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT
CHECKS=0 FAILS=0
ok()   { CHECKS=$((CHECKS + 1)); printf 'ok   %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); printf 'FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '     %s\n' "$2"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "want [$2] got [$3]"; fi; }
leg()  { [ -z "${CI_PLAN_LEG:-}" ] || [ "$CI_PLAN_LEG" = "$1" ]; }

# ---- A. lockstep -------------------------------------------------------------
if leg A && [ -z "${CI_PLAN_UNDER_TEST:-}" ]; then
  keys=$(bash "$PLAN" checks)
  [ -n "$keys" ] && ok "A ci-plan.sh lists its checks" || fail "A ci-plan.sh checks printed nothing"
  needs=$(sed -n 's/^    needs: \[plan, \(.*\)\]$/\1/p' "$CI" | tr -d ' ' | tr ',' '\n')
  for k in $keys; do
    job=$(printf '%s' "$k" | tr _ -)
    [ "$k" = fleet_hub_mcp ] && wf=fleet-hub || wf=$job
    grep -q "^  $job:\$" "$CI" || { fail "A ci.yml has no caller job for $k"; continue; }
    v=$(awk -v j="  $job:" '$0 == j {o=1; next} o && /^  [a-z]/{o=0} o' "$CI")
    case "$v" in *"if: needs.plan.outputs.$k == 'true'"*) ;; *) fail "A ci.yml's $job is not gated on the plan's $k" ;; esac
    case "$v" in *"uses: ./.github/workflows/$wf.yml"*) ;; *) fail "A ci.yml's $job does not call $wf.yml" ;; esac
    printf '%s\n' "$needs" | grep -qx "$job" || fail "A CI 结论 does not need $job"
    grep -q "^      $k: \${{ steps.plan.outputs.$k }}\$" "$CI" || fail "A the plan job does not output $k"
    y="$ROOT/.github/workflows/$wf.yml"
    [ -f "$y" ] || { fail "A no $wf.yml"; continue; }
    awk '/^on:/{o=1; next} o && /^[^ #]/{o=0} o' "$y" | grep -q '^  workflow_call:' || fail "A $wf.yml has no workflow_call"
    awk '/^on:/{o=1; next} o && /^[^ #]/{o=0} o' "$y" | grep -q '^  pull_request' && fail "A $wf.yml still runs on pull_request by itself (ci.yml calls it)"
    grep -q 'group: \${{ github.workflow }}' "$y" && fail "A $wf.yml's concurrency group spells github.workflow (ci.yml's name in a call)"
  done
  n=$(printf '%s\n' "$needs" | grep -c .)
  eq "A CI 结论 needs exactly the checks" "$(printf '%s\n' $keys | wc -l | tr -d ' ')" "$n"
  grep -q '^    name: CI 结论$' "$CI" && grep -q '^    if: always()$' "$CI" && ok "A CI 结论 is named so and runs always" || fail "A CI 结论 is not \`name: CI 结论\` + \`if: always()\`"
  for y in "$ROOT"/.github/workflows/*.yml; do
    b=$(basename "$y")
    case "$b" in ci.yml) continue ;; esac
    if awk '/^on:/{o=1; next} o && /^[^ #]/{o=0} o' "$y" | grep -q '^  pull_request'; then
      fail "A $b runs on pull_request outside ci.yml — add it to bin/ci-plan.sh and ci.yml"
    fi
  done
  ok "A no PR check runs outside ci.yml"
fi

# ---- the sandbox repo -----------------------------------------------------------
G="$WORK/repo"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$G/bin" "$G/.github/workflows" "$G/docs"
cp "$PLAN" "$G/bin/ci-plan.sh"
cp "$BIN/run-selftests.sh" "$G/bin/" 2>/dev/null
P=github.com/verkyyi/claude-fleet/tokenledger
mod() {  # mod <name> <requires…>
  local m=$1; shift
  mkdir -p "$G/tokenledger/$m"
  { printf 'module %s/%s\n\ngo 1.21\n' "$P" "$m"
    for r in "$@"; do printf '\nrequire %s/%s v0.0.0\nreplace %s/%s => ../%s\n' "$P" "$r" "$P" "$r" "$r"; done
  } > "$G/tokenledger/$m/go.mod"
}
gof() { mkdir -p "$(dirname "$G/$1")"; printf '%s\n' "$2" > "$G/$1"; }
mod shared; mod agent shared; mod hub shared; mod e2e shared agent hub
gof tokenledger/shared/a/a.go 'package a
const A = 1'
gof tokenledger/shared/b/b.go 'package b
const B = 1'
gof tokenledger/shared/b/b_test.go 'package b
import "testing"
func TestB(t *testing.T) {}'
gof tokenledger/agent/node/node.go "package node
import \"$P/shared/a\"
const N = a.A"
gof tokenledger/agent/node/node_test.go 'package node
import "testing"
func TestN(t *testing.T) {}'
gof tokenledger/agent/cli/cli.go 'package cli
const C = 1'
gof tokenledger/agent/cli/cli_test.go 'package cli
import "testing"
func TestC(t *testing.T) {}'
gof tokenledger/hub/api/api.go "package api
import \"$P/shared/a\"
const X = a.A"
gof tokenledger/hub/api/api_test.go 'package api
import "testing"
func TestX(t *testing.T) {}'
gof tokenledger/hub/store/store.go "package store
import \"$P/shared/b\"
const S = b.B"
gof tokenledger/hub/store/store_test.go 'package store
import "testing"
func TestS(t *testing.T) {}'
gof tokenledger/hub/store/testdata/x.json '{}'
gof tokenledger/e2e/e2e.go 'package e2e'
gof tokenledger/e2e/e2e_test.go "package e2e
import (\"testing\"; \"$P/agent/node\"; \"$P/hub/api\")
func TestE(t *testing.T) { _ = node.N; _ = api.X }"
gof tokenledger/go.work 'go 1.21'
gof tokenledger/README.md 'readme'
gof docs/a.md 'doc'
gof .github/workflows/tokenledger.yml 'name: tokenledger'
( cd "$G" && git init -q -b master && git add -A && git commit -qm base ) || { echo "ci-plan-selftest: no sandbox repo" >&2; exit 2; }
BASE=$(git -C "$G" rev-parse HEAD)

# change <file…> → a branch off BASE with those files touched
change() {
  git -C "$G" checkout -q -f "$BASE" 2>/dev/null
  git -C "$G" checkout -q -B "t$RANDOM" 2>/dev/null
  local f
  for f in "$@"; do mkdir -p "$(dirname "$G/$f")"; printf '\n// touched\n' >> "$G/$f"; done
  git -C "$G" add -A && git -C "$G" commit -qm change
}
blocks() {  # blocks [--no-pkgs] → the selected Go blocks, space-separated
  (cd "$G" && GOWORK=off GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local bash bin/ci-plan.sh go "$BASE" "$@" 2>/dev/null) \
    | sed -n 's/^go_modules=//p'
}
gout() { (cd "$G" && GOWORK=off GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local bash bin/ci-plan.sh go "$BASE" 2>/dev/null) | sed -n "s/^$1=//p"; }

# ---- B. blocks ------------------------------------------------------------------
if leg B; then
  change tokenledger/agent/cli/cli.go;           eq "B agent ⇒ agent + e2e, never hub" "agent e2e" "$(blocks --no-pkgs)"
  change tokenledger/hub/store/store.go;         eq "B hub ⇒ hub + e2e, never agent" "hub e2e" "$(blocks --no-pkgs)"
  change tokenledger/shared/b/b.go;              eq "B shared ⇒ all four" "shared agent hub e2e" "$(blocks --no-pkgs)"
  change tokenledger/e2e/e2e_test.go;            eq "B e2e ⇒ e2e" "e2e" "$(blocks --no-pkgs)"
  change tokenledger/go.work;                    eq "B go.work ⇒ all four" "shared agent hub e2e" "$(blocks)"
  change .github/workflows/tokenledger.yml;      eq "B the Go workflow ⇒ all four" "shared agent hub e2e" "$(blocks)"
  change tokenledger/brand-new/x.go;             eq "B an unknown tokenledger/ path ⇒ all four (unsure)" "shared agent hub e2e" "$(blocks)"
  change tokenledger/README.md docs/a.md;        eq "B docs ⇒ no block" "" "$(blocks)"
fi

# ---- C. packages ----------------------------------------------------------------
if leg C; then
  if command -v go >/dev/null 2>&1 && (cd "$G/tokenledger/hub" && GOWORK=off GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local go list ./... >/dev/null 2>&1); then
    change tokenledger/agent/cli/cli.go
    eq "C agent/cli: e2e (imports agent/node only) skipped" "agent" "$(blocks)"
    eq "C agent/cli: only the cli package" "$P/agent/cli" "$(gout go_pkgs_agent)"
    change tokenledger/shared/b/b.go
    eq "C shared/b: only store's dependents — agent and e2e skipped" "shared hub" "$(blocks)"
    eq "C shared/b: hub store, no api shard" '["rest", "shared"]' "$(gout go_parts)"
    eq "C shared/b: Postgres store only" '["store"]' "$(gout go_pg_parts)"
    change tokenledger/hub/api/api.go
    eq "C hub/api: hub + e2e (e2e imports api)" "hub e2e" "$(blocks)"
    eq "C hub/api: the api shards, no rest" '["api-1", "api-2", "api-3", "e2e"]' "$(gout go_parts)"
    change tokenledger/hub/store/testdata/x.json
    eq "C testdata belongs to its package" "$P/hub/store" "$(gout go_pkgs_hub)"
    change tokenledger/shared/go.mod
    eq "C a module's go.mod ⇒ all its packages and their dependents" "shared agent hub e2e" "$(blocks)"
  else
    ok "C skipped (no go toolchain here)"
  fi
fi

# ---- D. unsure ⇒ run; docs ⇒ nothing ---------------------------------------------
if leg D; then
  change docs/a.md
  out=$(cd "$G" && bash bin/ci-plan.sh all "$BASE" 2>/dev/null)
  eq "D docs-only runs oss-scan alone" "oss_scan" "$(printf '%s\n' "$out" | sed -n 's/=true$//p' | grep -v '^go_' | tr '\n' ' ' | sed 's/ $//')"
  out=$(cd "$G" && bash bin/ci-plan.sh all no-such-base 2>/dev/null)
  eq "D unknown base: no check skipped" "" "$(printf '%s\n' "$out" | grep -E '^[a-z_]+=false$' | grep -v '^go_' | tr '\n' ' ')"
  eq "D unknown base: every block" "shared agent hub e2e" "$(printf '%s\n' "$out" | sed -n 's/^go_modules=//p')"
  change bin/ci-plan.sh
  out=$(cd "$G" && bash bin/ci-plan.sh all "$BASE" 2>/dev/null)
  eq "D the plan itself changed: no check skipped" "" "$(printf '%s\n' "$out" | grep -E '^[a-z_]+=false$' | tr '\n' ' ')"
  rec="$WORK/rec.txt"
  (cd "$G" && bash bin/ci-plan.sh all "$BASE" --out "$rec" >/dev/null 2>&1)
  grep -q '^check tokenledger true ' "$rec" && grep -q '^go select: hub ← ' "$rec" \
    && ok "D the record says each check and block, and why" || fail "D the ci-plan record" "$(head -5 "$rec" 2>/dev/null)"
fi

# ---- E. CI 结论's fold -----------------------------------------------------------
if leg E && [ -z "${CI_PLAN_UNDER_TEST:-}" ]; then
  py=$(awk '/python3 - <<.PY./{o=1; next} o && /^ *PY$/{o=0} o' "$CI" | sed 's/^          //')
  verdict() { NEEDS="$1" GITHUB_STEP_SUMMARY='' python3 -c "$py" >/dev/null 2>&1 && echo green || echo red; }
  eq "E selected success + unselected skipped ⇒ green" green \
    "$(verdict '{"plan":{"result":"success","outputs":{"selftests":"true","shellcheck":"false"}},"selftests":{"result":"success"},"shellcheck":{"result":"skipped"}}')"
  eq "E a selected check skipped ⇒ red" red \
    "$(verdict '{"plan":{"result":"success","outputs":{"selftests":"true"}},"selftests":{"result":"skipped"}}')"
  eq "E a failed check ⇒ red" red \
    "$(verdict '{"plan":{"result":"success","outputs":{"task_acceptance":"true"}},"task-acceptance":{"result":"failure"}}')"
  eq "E a cancelled check ⇒ red" red \
    "$(verdict '{"plan":{"result":"success","outputs":{"selftests":"true"}},"selftests":{"result":"cancelled"}}')"
  eq "E a failed plan ⇒ red" red \
    "$(verdict '{"plan":{"result":"failure","outputs":{}},"selftests":{"result":"skipped"}}')"
fi

[ "$FAILS" = 0 ] && { echo "ci-plan-selftest: $CHECKS checks passed"; exit 0; }
echo "ci-plan-selftest: $FAILS of $CHECKS failed"; exit 1
