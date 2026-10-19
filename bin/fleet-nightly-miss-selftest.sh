#!/bin/bash
# fleet-nightly-miss-selftest.sh — the nightly full run and its miss analysis
# (issue #3871, EPIC #3863 C8), hermetic: a sandbox git repo whose bin/ carries the
# REAL bin/run-selftests.sh (so the selection is the train's own), a stub filer
# that logs its argv. Nothing touches GitHub.
#
# The sandbox history (first-parent, oldest first): A the base — B docs only —
# C changes conf/value.txt, which reader-selftest.sh reads through helper.sh but
# never names — D changes conf/named.txt, which named-selftest.sh names — E docs.
#
#   A. list-only     run-selftests.sh --list-only prints names only: nothing for C
#                    (no test names value.txt), named-selftest.sh for D; without
#                    --changed it refuses (exit 2)
#   B. miss          reader red since C, the train's selection at C did not list it
#                    ⇒ selection-miss: label selection-miss, key nightly-reader, the
#                    body names C, conf/value.txt and the one-line fix
#   C. picked        named red since D, listed at D ⇒ picked, label bug — not a miss
#   D. old           a test red at the window's start ⇒ old, no bisect
#   E. flaky         FAIL at night, green when run again at <sha> ⇒ flaky, key
#                    flaky-<test> (the train's own issue)
#   F. dedup / rc    filer exit 5 (already open) is fine; a failed filing ⇒ exit 1;
#                    --max 1 bisects one and lists the rest; no FAIL line ⇒ exit 0
#   G. the nightly   .github/workflows/selftests-nightly.yml: 06:17 Beijing on
#                    stable, the full suite (no base) through selftests-shards.yml,
#                    never retry_red / quarantine, record: true, priced by
#                    bin/fleet-train-plan.sh --full, its red traced by
#                    bin/fleet-nightly-miss.sh with issues: write
#   H. plan --full   fleet-train-plan.sh --full prices without --changed
#   I. BREAK-IT      docs/dev/BREAK-IT.md rows selection-miss-silent and
#                    selection-miss-go-silent ⇔ their drills
# Go and whole checks (issue #4816, ci-nightly.yml) — a second sandbox with the four
# tokenledger modules and the REAL bin/ci-plan.sh; history: A base — B changes
# tokenledger/agent/data.txt, which a hub/api test reads (the plan maps agent ⇒
# agent + e2e, never hub) — C docs only:
#   J. Go miss       go-log names hub/api TestReadsAgent red; bisected to B, where
#                    `ci-plan.sh go B^` selected no hub ⇒ ONE selection-miss issue,
#                    key nightly-go-hub.api.TestReadsAgent, naming B and the file
#   K. Go others     an agent test red since B ⇒ picked (agent selected); the same on
#                    the Postgres leg ⇒ nightly-pg-…; no database to re-run ⇒
#                    unanalysed; a package red with no test named ⇒ unanalysed; green
#                    again ⇒ flaky-go-…; a long name keeps the key ≤ 80
#   L. checks        a red check: the merges whose `ci-plan.sh <check> M^` said
#                    run=false are the suspects (one ⇒ named), none ⇒ picked, red the
#                    night before ⇒ old; `tokenledger` red with a named Go test is
#                    left to the test
#   M. ci-nightly    .github/workflows/ci-nightly.yml: 06:17 Beijing, calls every
#                    ci-plan check but selftests (selftests-nightly.yml) and oss_scan
#                    (a PR's diff), none of those keeps a schedule of its own, and
#                    its report runs fleet-nightly-miss.sh --go --checks with a
#                    Postgres and issues: write
# NM_LEG=<letter> runs one leg (the BREAK-IT drills run B and J).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
M="$BIN/fleet-nightly-miss.sh"
[ -f "$M" ] || { printf 'selftest: %s not found\n' "$M" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nightly-miss-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
LEG=${NM_LEG:-}
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
mkdir -p "$R/bin" "$R/conf" "$R/docs"
cp "$BIN/run-selftests.sh" "$R/bin/"
printf 'ok\n' > "$R/conf/value.txt"
printf 'ok\n' > "$R/conf/named.txt"
cat > "$R/bin/helper.sh" <<'SH'
helper_value() { cat "$(dirname "$0")/../conf/value.txt"; }
SH
cat > "$R/bin/reader-selftest.sh" <<'SH'
#!/bin/bash
# reads its value through helper.sh — and never names the file it reads
. "$(dirname "$0")/helper.sh"
[ "$(helper_value)" = ok ]
SH
cat > "$R/bin/named-selftest.sh" <<'SH'
#!/bin/bash
grep -qx ok "$(dirname "$0")/../conf/named.txt"
SH
cat > "$R/bin/old-selftest.sh" <<'SH'
#!/bin/bash
exit 1
SH
cat > "$R/bin/steady-selftest.sh" <<'SH'
#!/bin/bash
exit 0
SH
echo a > "$R/docs/a.md"
git -C "$R" init -q -b master
git -C "$R" add -A && git -C "$R" commit -qm A
A=$(git -C "$R" rev-parse HEAD)
echo b >> "$R/docs/a.md";             git -C "$R" commit -qam 'B docs'
printf 'broken\n' > "$R/conf/value.txt"; git -C "$R" commit -qam 'C value'
C=$(git -C "$R" rev-parse HEAD)
printf 'broken\n' > "$R/conf/named.txt"; git -C "$R" commit -qam 'D named'
D=$(git -C "$R" rev-parse HEAD)
echo e >> "$R/docs/a.md";             git -C "$R" commit -qam 'E docs'
E=$(git -C "$R" rev-parse HEAD)

cat > "$WORK/filer" <<SH
#!/bin/bash
printf '%s\n----\n' "\$*" >> "$WORK/filed"
n=\$(( \$(grep -c '^----\$' "$WORK/filed") + 100 ))
echo "https://github.com/o/r/issues/\$n"
exit \$(cat "$WORK/filer_rc" 2>/dev/null || echo 0)
SH
chmod +x "$WORK/filer"
export FLEET_NM_FILER="$WORK/filer"
results() {   # results <test>... — one shard's verdicts
  rm -rf "$WORK/res"; mkdir -p "$WORK/res/train-result-Linux-1"
  for t in "$@"; do printf 'FAIL  %s  (exit 1)\n' "$t"; done > "$WORK/res/train-result-Linux-1/train-result.txt"
}
nm() { rm -f "$WORK/filed"; bash "$M" --results "$WORK/res" --sha "$E" --since "$A" --repo o/r --run 77 --dir "$R" "$@"; }
filed_for() { awk -v k="--breakage-key $1 " 'BEGIN { RS = "\n----\n" } index($0, k)' "$WORK/filed" 2>/dev/null; }
nfiled() { grep -c '^----$' "$WORK/filed" 2>/dev/null || true; }

# ---- A. list-only ----------------------------------------------------------------
if leg A; then
  git -C "$R" checkout -q --detach "$C"
  out=$(cd "$R/bin" && bash run-selftests.sh --changed "$C^" --list-only); rc=$?
  eq "A list-only exits 0 for a change no test names" 0 "$rc"
  eq "A nothing names conf/value.txt — the train selects nothing for C" '' "$out"
  git -C "$R" checkout -q --detach "$D"
  out=$(cd "$R/bin" && bash run-selftests.sh --changed "$D^" --list-only)
  eq "A D's change selects named-selftest.sh, by name only" 'named-selftest.sh' "$out"
  lacks "A list-only prints no select: line" "$out" 'select:'
  (cd "$R/bin" && bash run-selftests.sh --list-only >/dev/null 2>&1); rc=$?
  eq "A --list-only without --changed refuses" 2 "$rc"
  git -C "$R" checkout -q master
fi

# ---- B. the miss ----------------------------------------------------------------
if leg B; then
  results reader-selftest.sh
  out=$(nm); rc=$?
  eq "B exits 0" 0 "$rc"
  contains "B the row says selection-miss since C" "$out" "| reader-selftest.sh | selection-miss | $(printf '%.7s' "$C") |"
  f=$(filed_for nightly-reader)
  contains "B filed once with key nightly-reader" "$f" '--breakage-key nightly-reader'
  contains "B labelled selection-miss" "$f" '--label selection-miss'
  contains "B the title says 漏选 and the merge" "$f" "自 $(printf '%.7s' "$C") 起红，列车没选中它（漏选）"
  contains "B the body names the merge's file" "$f" 'conf/value.txt'
  contains "B the body gives the one-line fix" "$f" '# reads: conf/value.txt'
  contains "B the body says why the train skipped it" "$f" "--changed $(printf '%.7s' "$C")^ --list-only"
  contains "B the body links the run" "$f" 'https://github.com/o/r/actions/runs/77'
  eq "B one filing" 1 "$(nfiled)"
  [ -z "$(git -C "$R" worktree list | sed 1d)" ] || fail "B the scratch worktree was left behind"
  CHECKS=$((CHECKS + 1))
fi

# ---- C. picked ------------------------------------------------------------------
if leg C; then
  results named-selftest.sh
  out=$(nm)
  contains "C named is red since D and the train picked it" "$out" "| named-selftest.sh | picked | $(printf '%.7s' "$D") |"
  f=$(filed_for nightly-named)
  contains "C labelled bug, not selection-miss" "$f" '--label bug '
  contains "C says the train selected it" "$f" '列车选中过它'
fi

# ---- D. old ---------------------------------------------------------------------
if leg D; then
  results old-selftest.sh
  out=$(nm)
  contains "D red at the window's start ⇒ old" "$out" '| old-selftest.sh | old | - |'
  contains "D still filed" "$(filed_for nightly-old)" '就已经红了'
fi

# ---- E. flaky -------------------------------------------------------------------
if leg E; then
  results steady-selftest.sh
  out=$(nm)
  contains "E green when run again ⇒ flaky" "$out" '| steady-selftest.sh | flaky |'
  f=$(filed_for flaky-steady)
  contains "E the train's own key and label" "$f" '--label flaky'
fi

# ---- F. dedup, failures, --max, nothing red ------------------------------------
if leg F; then
  results reader-selftest.sh
  echo 5 > "$WORK/filer_rc"; nm >/dev/null; rc=$?
  eq "F filer exit 5 (already open) is fine" 0 "$rc"
  echo 1 > "$WORK/filer_rc"; nm >/dev/null 2>&1; rc=$?
  eq "F a failed filing ⇒ exit 1" 1 "$rc"
  rm -f "$WORK/filer_rc"
  results named-selftest.sh reader-selftest.sh
  out=$(nm --max 1)
  contains "F --max 1 bisects the first" "$out" '| named-selftest.sh | picked |'
  contains "F … and lists the rest unanalysed" "$out" '| reader-selftest.sh | unanalysed |'
  eq "F both still filed" 2 "$(nfiled)"
  rm -rf "$WORK/res"; mkdir -p "$WORK/res"
  nm >/dev/null 2>&1; rc=$?
  eq "F no FAIL line ⇒ exit 0" 0 "$rc"
  [ ! -s "$WORK/filed" ] || fail "F nothing red, yet something was filed"
  results reader-selftest.sh
  out=$(nm --dry-run 2>&1)
  contains "F --dry-run names the filing" "$out" '(would file: selection-miss · nightly-reader)'
  [ ! -s "$WORK/filed" ] || fail "F --dry-run filed something"
  (bash "$M" --sha "$E" >/dev/null 2>&1); rc=$?
  eq "F --results is required" 2 "$rc"
fi

# ---- G. the nightly workflow ---------------------------------------------------
if leg G; then
  WF="$ROOT/.github/workflows/selftests-nightly.yml"
  [ -f "$WF" ] || fail "G no .github/workflows/selftests-nightly.yml"
  w=$(cat "$WF")
  contains "G scheduled 06:17 Beijing (22:17 UTC)" "$w" "cron: '17 22 * * *'"
  contains "G tests refs/tags/stable" "$w" 'refs/tags/stable'
  contains "G runs the one shared matrix" "$w" 'uses: ./.github/workflows/selftests-shards.yml'
  contains "G records each shard's verdicts" "$w" 'record: true'
  contains "G prices the whole suite" "$w" 'fleet-train-plan.sh --full'
  contains "G picks the Shenzhen pool like the train" "$w" 'fleet-train-runner.sh pick'
  contains "G traces its red" "$w" 'bin/fleet-nightly-miss.sh'
  contains "G may file issues" "$w" 'issues: write'
  for k in 'base:' retry_red quarantine prev_fails drill_red; do
    printf '%s\n' "$w" | grep -Eq "^[[:space:]]+$k" && fail "G the nightly passes $k — it must see the real red of the whole suite"
    CHECKS=$((CHECKS + 1))
  done
fi

# ---- H. fleet-train-plan.sh --full ---------------------------------------------
if leg H; then
  cat > "$WORK/plancmd" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/plan.args"
echo 'plan tests=500 total=6000 shards=1 heaviest=94'
SH
  chmod +x "$WORK/plancmd"; rm -f "$WORK/plan.args"
  out=$(FLEET_TRAIN_PLAN_CMD="$WORK/plancmd" GITHUB_OUTPUT='' GITHUB_STEP_SUMMARY='' \
          bash "$BIN/fleet-train-plan.sh" --full --slots 44 --prefix linux)
  contains "H --full prices the whole suite" "$out" 'linux_predicted=6000'
  contains "H … 44 wide in the pool" "$out" 'linux_shards=[1, 2, 3'
  lacks "H --full never passes --changed" "$(cat "$WORK/plan.args")" '--changed'
  (bash "$BIN/fleet-train-plan.sh" >/dev/null 2>&1); rc=$?
  eq "H neither --base nor --full refuses" 2 "$rc"
fi

# ---- I. BREAK-IT ----------------------------------------------------------------
if leg I; then
  grep -q '`selection-miss-silent`' "$ROOT/docs/dev/BREAK-IT.md" || fail "I no BREAK-IT row selection-miss-silent"
  grep -q '^drill_selection_miss_silent()' "$BIN/fleet-break-it-selftest.sh" || fail "I no drill_selection_miss_silent"
  grep -q '`selection-miss-go-silent`' "$ROOT/docs/dev/BREAK-IT.md" || fail "I no BREAK-IT row selection-miss-go-silent"
  grep -q '^drill_selection_miss_go_silent()' "$BIN/fleet-break-it-selftest.sh" || fail "I no drill_selection_miss_go_silent"
  CHECKS=$((CHECKS + 4))
fi

# ---- the Go sandbox (J–L) --------------------------------------------------------
if leg J || leg K || leg L; then
  G="$WORK/go"
  mkdir -p "$G/bin" "$G/docs"
  cp "$BIN/ci-plan.sh" "$BIN/run-selftests.sh" "$G/bin/"
  for m in shared agent hub e2e; do
    mkdir -p "$G/tokenledger/$m"
    printf 'module github.com/verkyyi/claude-fleet/tokenledger/%s\n\ngo 1.25\n' "$m" > "$G/tokenledger/$m/go.mod"
  done
  mkdir -p "$G/tokenledger/hub/api" "$G/tokenledger/agent/cli"
  printf 'package api\n' > "$G/tokenledger/hub/api/doc.txt"
  printf 'package cli\n' > "$G/tokenledger/agent/cli/doc.txt"
  printf 'ok\n' > "$G/tokenledger/agent/data.txt"
  echo a > "$G/docs/a.md"
  git -C "$G" init -q -b master
  git -C "$G" add -A && git -C "$G" commit -qm A
  GA=$(git -C "$G" rev-parse HEAD)
  printf 'broken\n' > "$G/tokenledger/agent/data.txt"; git -C "$G" commit -qam 'B agent data'
  GB=$(git -C "$G" rev-parse HEAD)
  echo c >> "$G/docs/a.md"; git -C "$G" commit -qam 'C docs'
  GC=$(git -C "$G" rev-parse HEAD)
  # one Go test, by name: red iff the agent's data.txt is broken (Steady: never red)
  cat > "$WORK/gorun" <<'SH'
#!/bin/bash
# <checkout> <go|pg> <pkg> <Test>
case "$4" in TestSteady) exit 0 ;; esac
grep -qx ok "$1/tokenledger/agent/data.txt"
SH
  chmod +x "$WORK/gorun"
  golog() {   # golog <leg go|pg> <part> <pkg> <Test|-> ... — one part's `go test -v` log
    local leg=$1 part=$2 d; shift 2
    d="$WORK/gores/$leg-log-$part"; mkdir -p "$d"
    while [ "$#" -ge 2 ]; do
      if [ "$2" != - ]; then printf '=== RUN   %s\n--- FAIL: %s (0.01s)\n    x_test.go:9: broken\n' "$2" "$2"; fi
      printf 'FAIL\ngithub.com/verkyyi/claude-fleet/tokenledger/%s\t0.1s\n' "$1" | sed 's/^github/FAIL\tgithub/;/^FAIL$/d'
      shift 2
    done >> "$d/$leg.log"
    printf 'ok  \tgithub.com/verkyyi/claude-fleet/tokenledger/hub/other\t0.2s\n' >> "$d/$leg.log"
  }
  gnm() { rm -f "$WORK/filed"; FLEET_NM_GO_RUN="$WORK/gorun" bash "$M" --sha "$GC" --since "$GA" --repo o/r --run 88 --dir "$G" "$@"; }
fi

# ---- J. a Go test red in a block the plan never selected ---------------------------
if leg J; then
  rm -rf "$WORK/gores"; golog go api-1 hub/api TestReadsAgent
  out=$(gnm --go "$WORK/gores"); rc=$?
  eq "J exits 0" 0 "$rc"
  contains "J the row: selection-miss since B" "$out" "| go hub/api TestReadsAgent | selection-miss | $(printf '%.7s' "$GB") |"
  f=$(filed_for nightly-go-hub.api.TestReadsAgent)
  contains "J filed with key nightly-go-hub.api.TestReadsAgent" "$f" '--breakage-key nightly-go-hub.api.TestReadsAgent'
  contains "J labelled selection-miss" "$f" '--label selection-miss'
  contains "J the title names the merge and 漏选" "$f" "自 $(printf '%.7s' "$GB") 起红，PR 门没选中它（漏选）"
  contains "J the body names the merge's file" "$f" 'tokenledger/agent/data.txt'
  contains "J the body quotes the plan" "$f" 'skip: hub'
  contains "J the body says how it was bisected" "$f" "go test -run '^TestReadsAgent\$' ./api"
  eq "J exactly one filing" 1 "$(nfiled)"
  echo 5 > "$WORK/filer_rc"; gnm --go "$WORK/gores" >/dev/null; rc=$?; rm -f "$WORK/filer_rc"
  eq "J the next night: the filer's 同一故障 (exit 5) is fine" 0 "$rc"
  eq "J … and still one filing asked, same key" 1 "$(nfiled)"
fi

# ---- K. the other Go verdicts -------------------------------------------------------
if leg K; then
  rm -rf "$WORK/gores"; golog go agent agent/cli TestAgentOwn
  out=$(gnm --go "$WORK/gores")
  contains "K an agent test red since B ⇒ picked (agent was selected)" "$out" "| go agent/cli TestAgentOwn | picked | $(printf '%.7s' "$GB") |"
  contains "K picked is a bug, not a miss" "$(filed_for nightly-go-agent.cli.TestAgentOwn)" '--label bug '
  rm -rf "$WORK/gores"; golog pg api-2 hub/api TestReadsAgent
  out=$(gnm --go "$WORK/gores")
  contains "K the Postgres leg has its own key" "$out" '| pg hub/api TestReadsAgent | selection-miss |'
  contains "K … nightly-pg-…" "$(filed_for nightly-pg-hub.api.TestReadsAgent)" '--breakage-key nightly-pg-hub.api.TestReadsAgent'
  out=$(rm -f "$WORK/filed"; FLEET_NM_DB_URL='' bash "$M" --sha "$GC" --since "$GA" --repo o/r --dir "$G" --go "$WORK/gores")
  contains "K no database to re-run a Postgres test ⇒ unanalysed" "$out" '| pg hub/api TestReadsAgent | unanalysed |'
  rm -rf "$WORK/gores"; golog go rest hub/api -
  out=$(gnm --go "$WORK/gores")
  contains "K a package red with no test named ⇒ unanalysed, filed by package" "$out" '| go hub/api（整包） | unanalysed |'
  contains "K … key nightly-go-hub.api" "$(filed_for nightly-go-hub.api)" '--breakage-key nightly-go-hub.api '
  rm -rf "$WORK/gores"; golog go rest hub/api TestSteady
  out=$(gnm --go "$WORK/gores")
  contains "K green when re-run ⇒ flaky" "$out" '| go hub/api TestSteady | flaky |'
  contains "K … flaky-go-…" "$(filed_for flaky-go-hub.api.TestSteady)" '--label flaky'
  long=TestAVeryLongNameThatKeepsGoingAndGoingPastEightyCharactersOfBreakageKeyForSure
  rm -rf "$WORK/gores"; golog go rest hub/api "$long"
  gnm --go "$WORK/gores" --dry-run > "$WORK/out" 2>&1
  k=$(sed -n 's/.*would file: [a-z-]* · \([^)]*\)).*/\1/p' "$WORK/out")
  CHECKS=$((CHECKS + 1)); [ -n "$k" ] && [ "${#k}" -le 80 ] || fail "K a long test name keeps the key ≤ 80, got [$k]"
  printf '%s' "$k" | grep -Eq '^[A-Za-z0-9._-]+$' || fail "K the key is the filer's charset: [$k]"
fi

# ---- L. whole checks ---------------------------------------------------------------
if leg L; then
  printf 'task_acceptance failure\nweb_console success\n' > "$WORK/checks"
  out=$(gnm --checks "$WORK/checks"); rc=$?
  eq "L exits 0" 0 "$rc"
  # B touches tokenledger/ (task-acceptance runs), C only docs (skipped): C is the one suspect
  contains "L the one merge that skipped it is named" "$out" "| 检查 task_acceptance | selection-miss | $(printf '%.7s' "$GC") |"
  f=$(filed_for nightly-check-task_acceptance)
  contains "L key nightly-check-task_acceptance, label selection-miss" "$f" '--label selection-miss'
  contains "L the body lists the suspect with the plan's words" "$f" 'task_acceptance: skipped'
  lacks "L a green check is not filed" "$(cat "$WORK/filed")" 'nightly-check-web_console'
  printf 'oss_scan failure\n' > "$WORK/checks"
  out=$(gnm --checks "$WORK/checks")
  contains "L run by every merge's PR ⇒ picked" "$out" '| 检查 oss_scan | picked |'
  printf 'task_acceptance failure\n' > "$WORK/prev"
  printf 'task_acceptance failure\n' > "$WORK/checks"
  out=$(gnm --checks "$WORK/checks" --prev-checks "$WORK/prev")
  contains "L red the night before ⇒ old" "$out" '| 检查 task_acceptance | old |'
  rm -rf "$WORK/gores"; golog go api-1 hub/api TestReadsAgent
  printf 'tokenledger failure\n' > "$WORK/checks"
  out=$(gnm --checks "$WORK/checks" --go "$WORK/gores")
  lacks "L tokenledger's red is its named test's" "$out" '检查 tokenledger'
  contains "L … the test is traced" "$out" '| go hub/api TestReadsAgent |'
  rm -rf "$WORK/gores"; mkdir -p "$WORK/gores"
  out=$(gnm --checks "$WORK/checks" --go "$WORK/gores")
  contains "L tokenledger red with no test named (lint, build) is the check's" "$out" '| 检查 tokenledger |'
fi

# ---- M. the ci nightly workflow ------------------------------------------------------
if leg M; then
  WF="$ROOT/.github/workflows/ci-nightly.yml"
  [ -f "$WF" ] || fail "M no .github/workflows/ci-nightly.yml"
  w=$(cat "$WF")
  contains "M scheduled 06:17 Beijing (22:17 UTC)" "$w" "cron: '17 22 * * *'"
  for k in $(bash "$BIN/ci-plan.sh" checks); do
    wf=$(printf '%s' "$k" | tr _ -); [ "$k" = fleet_hub_mcp ] && wf=fleet-hub
    case "$k" in
      selftests|oss_scan)
        CHECKS=$((CHECKS + 1)); case "$w" in *"uses: ./.github/workflows/$wf.yml"*) fail "M ci-nightly calls $wf.yml — it has its own nightly / is a PR's diff" ;; esac ;;
      *)
        contains "M calls $wf.yml" "$w" "uses: ./.github/workflows/$wf.yml"
        y="$ROOT/.github/workflows/$wf.yml"
        CHECKS=$((CHECKS + 1))
        awk '/^on:/{o=1; next} o && /^[^ #]/{o=0} o' "$y" | grep -q '^  schedule:' && fail "M $wf.yml keeps a schedule of its own — ci-nightly.yml runs it" ;;
    esac
  done
  contains "M traces its red" "$w" 'bin/fleet-nightly-miss.sh'
  contains "M … Go logs and checks" "$w" '--go '
  contains "M … the checks' results" "$w" '--checks '
  contains "M … against last night's" "$w" '--prev-checks'
  contains "M a Postgres to re-run the pg leg" "$w" 'FLEET_NM_DB_URL'
  contains "M may file issues" "$w" 'issues: write'
  CHECKS=$((CHECKS + 1))
  printf '%s\n' "$w" | grep -Eq '^  pull_request' && fail "M ci-nightly runs on pull_request"
fi

printf 'PASS fleet-nightly-miss-selftest (%s checks)\n' "$CHECKS"
