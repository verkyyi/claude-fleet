#!/bin/sh
# run-selftests.sh — the single aggregate gate for the fleet's hermetic selftests.
#
# Discovers every `bin/*-selftest.sh` (there is no registry to keep in sync — a
# new selftest is picked up the moment it lands), runs each in turn, prints a
# per-test PASS/FAIL line WITH ITS DURATION, lists the slowest few, and exits
# non-zero if ANY test failed. This is what CI runs
# (.github/workflows/selftests.yml) — since issue #1374 as `--changed <base>`, the
# related tests only (see below). Workers don't run it locally before pushing: CI
# is the verdict, and `run-selftests.sh <name>` reproduces one CI failure.
#
# Convention every selftest already follows: exit 0 = pass, non-zero = fail
# (a test that needs an absent tool — e.g. jq — SKIPs cleanly with exit 0). The
# runner is therefore marker-agnostic: it trusts the exit code, not the wording.
#
# SHARDING, and why not in-process parallelism (issue #681)
# ----------------------------------------------------------
# The suite had grown to 120 tests and ~9 minutes against a `timeout-minutes: 10`
# gate — one minute of margin, already spent once. The consequence is not "CI is
# slow" but that green stops meaning anything: a timeout red looks exactly like a
# real red, so people start re-running by reflex, which undoes what #660 just
# bought (a self-check you can trust).
#
# `--shard K/N` runs the K-th of N slices, so CI fans the suite out over N
# runners (each slice still SEQUENTIAL) and the wall clock drops by ~N.
#
# The tempting alternative — run the tests concurrently inside one runner — was
# built, measured and rejected. It works, 8-wide: 196s against 1428s of summed
# test time. But two tests went red on the first full parallel run and passed
# alone, and the cause was not shared state: several selftests carry a REAL-TIME
# budget that only holds on an idle box. needs-reconcile-selftest.sh was the
# exemplar — it drives the spinner with `FLEET_NEEDS_RECONCILE_SECS=1`, and the
# strike table it asserts on went stale after 3×that, so its arm-then-act pair had
# to complete inside 3 wall seconds. That one is FIXED (#691: the strike TTL became
# its own knob, so the test pins the rule by count and not by clock) — but it was
# one of ~9 tests with a window of that shape, and the rest still have theirs.
# Widening them all would mean loosening the exact assertions that make them worth
# having, to buy speed a second runner gives away for free. Sharding needs no test
# to change: every test still runs alone on its own box, under the conditions it
# was written for, so the gate cannot become flakier — which is the one thing this
# whole issue is about.
#
# The server-spawning tests isolate onto a private `-S` socket and reap it via an
# EXIT+signal trap, so a normal (even failing) run leaves no litter. A run KILLED
# outright (SIGKILL/OOM) can still orphan a socket or server — `fleet-selftest-reap.sh`
# is the backstop that sweeps that debris (dead sockets, aged `*selftest*` servers
# + temp dirs) without ever touching the shared `default` server (issue #152).
#
# Each test's own output streams through (so CI logs show what a failure printed);
# the runner adds the PASS/FAIL line, the slowest-tests list and a final summary.
# Runnable from anywhere — it resolves its own dir (the repo's bin/).
#
# Usage: run-selftests.sh [--shard K/N] [NAME ...]
#   no args     every bin/*-selftest.sh — the CI gate.
#   --shard K/N run only the K-th of N slices (1-based). The split is a stride
#               over the sorted list, so the `fleet-collect-*` family — similar
#               cost, adjacent names — lands one per shard instead of all in one,
#               and a NEW test rebalances the slices by itself.
#   NAME        run only the named tests. The `-selftest.sh` suffix is optional, and a
#               shell glob works (`run-selftests.sh 'dash-*'`), so chasing one red test
#               still goes through the same hermetic prelude CI uses. A NAME that
#               matches nothing is an error, never a silent all-green.
#
# Env: FLEET_SELFTEST_SLOWEST       how many slow tests to list (default 10, 0 = none)
#      FLEET_SELFTEST_TEST_TIMEOUT  per-test ceiling in seconds (default 600, 0 = none);
#                                   a test past it is killed, counted TIMEOUT (a
#                                   failure), and the run goes on to the next one
#      FLEET_HEAVY=0                skip the machine-wide heavy-job queue (see below)
set -u

unset CDPATH  # keep `cd` from echoing/jumping via a user's CDPATH
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)

# Hermetic INSTALL ROOT (issue #660) — the uniform prelude, applied once here.
# ---------------------------------------------------------------------------------
# Every fleet script reads the global config as `$BIN/../fleet.conf`, relative to its
# own bin/. Run this gate from a clean checkout and there is no such file, so every
# script takes its defaults. Run it from the LIVE install — the most natural way for
# an operator to check a machine — and `$BIN/..` is `~/.claude/fleet`, so the
# operator's REAL config loads: FLEET_REPO, FLEET_MAIN, FLEET_CTX_WINDOW,
# CCQUOTA_HUB_URL … Six tests went red that way on a commit that is all-green from a
# checkout, and a gate that is red for reasons unrelated to the code is worse than no
# gate — it teaches people to ignore the colour.
#
# The fix is ONE prelude here, not a per-test unset list (which always misses one, and
# misses every test written after it): re-run the whole suite from a SHADOW install
# root — a mirror of this one, with bin/ as a real dir of symlinks so `..` stays
# honest, an empty logs/, and NO fleet.conf — with the FLEET_*/CCQUOTA_* environment
# stripped on the way in (the conf's second route; see below). See
# bin/selftest-shadow-root.sh for why the file half is a ROOT SWAP and not an env knob
# pointing every load site at /dev/null: such a knob would also neutralise the sandbox
# bin/ + fleet.conf that several tests build on purpose.
#
# FLEET_SELFTEST_ROOT marks "already inside the shadow" and breaks the recursion.
# FLEET_SELFTEST_NO_SHADOW=1 runs in place — the escape hatch, and the control the
# meta-test (bin/selftest-isolation-selftest.sh) uses to prove the shadow is what
# does the work.
if [ -z "${FLEET_SELFTEST_ROOT:-}" ] && [ -z "${FLEET_SELFTEST_NO_SHADOW:-}" ]; then
  shadow=$("$script_dir/selftest-shadow-root.sh") || {
    echo "run-selftests: could not build the hermetic shadow root" >&2; exit 2; }
  # The temp root holds only symlinks and empty dirs, so this rm never reaches the
  # real tree. INT/TERM/HUP as well as EXIT: a ^C mid-suite must not leave litter,
  # and must stop the run rather than fall through to the summary.
  trap 'rm -rf "$shadow"' EXIT
  trap 'rm -rf "$shadow"; exit 130' INT TERM HUP

  # The conf reaches the suite by a SECOND route, and the shadow root closes only the
  # first (issue #660). A fleet conf may `export` its keys — the live one exports
  # CCQUOTA_HUB_URL / CCQUOTA_VIEWER_TOKEN — and bin/fleet-claude.sh sources the conf
  # before launching the agent, so every worker pane already HAS them in its
  # environment. Run the gate from a pane (which is where an operator runs it) and
  # they arrive without the file being read at all. Drop the whole FLEET_*/CCQUOTA_*
  # family so the suite sees the same environment in a pane, a bare login shell and
  # CI — minus the FLEET_SELFTEST_* knobs that steer this runner itself. Those are
  # runner ARGUMENTS that happen to arrive as environment variables, not fleet
  # config, so scrubbing them would mean the outer half honours a knob the inner
  # half never sees. FLEET_SELFTEST_SLOWEST was exactly that bug: set to 0, it
  # still printed the table, and only on Linux — because of the caveat below.
  #
  # TWO `-e`, never one `\|` (issue #689). `\|` alternation inside a BRE is a GNU
  # sed extension: BSD sed (macOS) neither matches it nor complains, so the older
  # one-expression form left `$scrub` EMPTY on a Mac and this whole half was a
  # SILENT no-op there — the env route was wide open on the very machine an
  # operator runs the gate from, while CI (GNU sed) scrubbed normally and showed
  # nothing. Two expressions are equivalent and portable, so keep them split; the
  # divergence is invisible until the two platforms disagree about a knob.
  # Part E of selftest-isolation-selftest.sh pins the behaviour end to end: a
  # poisoned FLEET_*/CCQUOTA_* environment must not reach the suite, and the
  # FLEET_SELFTEST_* knobs must.
  scrub=''
  for v in $(env 2>/dev/null | sed -n -e 's/^\(FLEET_[A-Za-z0-9_]*\)=.*/\1/p' \
                                      -e 's/^\(CCQUOTA_[A-Za-z0-9_]*\)=.*/\1/p'); do
    case "$v" in
      FLEET_SELFTEST_ROOT|FLEET_SELFTEST_NO_SHADOW|FLEET_SELFTEST_SLOWEST) continue ;;
      FLEET_SELFTEST_TEST_TIMEOUT) continue ;;
    esac
    scrub="$scrub -u $v"
  done
  # The whole gate queues on the MACHINE-WIDE heavy-job semaphore (issue #1150, on
  # #1295's fleet-heavy.sh): an EPIC routinely puts 3-4 workers into this gate at
  # once, and together they drove the box to load 48 — which is how one test hung
  # for 77 minutes (2026-09-24). Queuing beats refusing: a refused gate leaves a
  # worker idle with nothing to wake it, a queued one simply starts later. The hook
  # (hooks/bash-guard.py) already prefixes the wrapper onto a `run-selftests.sh`
  # typed in a pane; this covers every other route (a script, a pre-push hook, a
  # shell). Already holding a slot (FLEET_HEAVY_HELD=1, the hook's wrapper) → the
  # nested call runs straight through, so the two never deadlock. The wrapper sits
  # OUTSIDE `env $scrub`, so the FLEET_HEAVY_* it exports are scrubbed before the
  # suite sees them — all but FLEET_HEAVY_HELD=1, set back on purpose: the suite
  # runs INSIDE this slot, so a test that drives a nested gate (the isolation and
  # shard selftests do) must pass straight through rather than queue behind its own
  # parent. fleet-heavy-selftest.sh unsets it before it tests the queue. FLEET_HEAVY=0
  # or a missing wrapper runs ungated.
  # A run of NAMED tests (no glob, no option) is light (issue #1313) — the same
  # rule the hook's FLEET_HEAVY_LIGHT_RE_DEFAULT applies to a typed command — so it
  # never queues behind three full gates; no argument, a glob or --shard still does.
  light=0
  if [ "$#" -gt 0 ]; then
    light=1
    for a in "$@"; do
      case "$a" in -*|*'*'*|*'?'*|*'['*|'') light=0 ;; esac
    done
  fi
  heavy=''
  if [ "$light" = 0 ] && [ "${FLEET_HEAVY:-1}" != 0 ] && [ -x "$script_dir/fleet-heavy.sh" ]; then
    heavy="$script_dir/fleet-heavy.sh --label selftests --"
    # The list above was read from OUR environment, before the wrapper exports its
    # own keys — so name them, or they reach the suite (the slot dir among them).
    scrub="$scrub -u FLEET_HEAVY -u FLEET_HEAVY_SLOTS -u FLEET_HEAVY_WAIT -u FLEET_HEAVY_DIR -u FLEET_HEAVY_RE -u FLEET_HEAVY_LIGHT_RE"
  fi
  # shellcheck disable=SC2086  # intentional: $heavy and $scrub are argument lists
  $heavy env $scrub FLEET_HEAVY_HELD=1 FLEET_SELFTEST_ROOT="$shadow" \
    sh "$shadow/bin/run-selftests.sh" "$@"
  exit $?
fi

cd "$script_dir" || { echo "run-selftests: cannot cd to bin dir ($script_dir)" >&2; exit 2; }

# Hermetic env (issue #399): fleet-lib.sh now sources the sibling fleet.conf on load
# and EXPORTS the global-only cap keys. In CI that's a no-op (a fresh checkout has no
# repo-root fleet.conf), but a worker reproducing this gate from the LIVE install
# (~/.claude/fleet/bin/run-selftests.sh) would otherwise let the machine's real
# fleet.conf (e.g. FLEET_GLOBAL_MAX_SESSIONS=20) leak into tests that read the cap.
# Skip the auto-source and clear any inherited global-only keys so every test starts
# from the same pristine env it gets in CI, wherever the runner is invoked from.
# (Belt-and-braces since #660: inside the shadow root there IS no sibling conf. Kept
# so FLEET_SELFTEST_NO_SHADOW=1 keeps the isolation it had before.)
export FLEET_SKIP_GLOBAL_CONF=1
unset FLEET_GLOBAL_MAX_SESSIONS 2>/dev/null || true
# The machine-admission gate (issue #1090) reads the HOST's real memory + load, so
# every spawn-path test would go red on a busy box (or a busy CI runner) for a reason
# that has nothing to do with it. Off for the suite; fleet-admit-selftest.sh turns it
# back on against stubbed probes.
export FLEET_ADMIT=0
# Every collector tick publishes this login's session count to a MACHINE-level dir
# the other logins' caps read (issue #1301). A test tick counting its own fake fleet
# must never land there — it would overwrite the operator's real row for up to the
# stale bound. A throwaway dir, inside the shadow root when there is one.
FLEET_MACHINE_SESSIONS_DIR="${FLEET_SELFTEST_ROOT:-${TMPDIR:-/tmp}/fleet-selftest-$$}/machine-sessions"
export FLEET_MACHINE_SESSIONS_DIR

# The PER-FLEET confs are the same leak one directory over (issue #660): fleet_load_conf
# reads $FLEET_CONF_DIR/fleets/<sess>/conf, defaulting to the operator's real
# ~/.config/claude-fleet. 68 of the tests already point this at their own sandbox and
# keep winning — this only covers the rest, which would otherwise read (and, via the
# config modal, write) the live fleets' overlays. Only inside the shadow root: there
# is nowhere safe to put it when running in place.
if [ -n "${FLEET_SELFTEST_ROOT:-}" ] && [ -d "$FLEET_SELFTEST_ROOT/conf-dir" ]; then
  FLEET_CONF_DIR="$FLEET_SELFTEST_ROOT/conf-dir"; export FLEET_CONF_DIR
fi

# --shard K/N — take the K-th of N slices. Parsed off the FRONT of the arg list (a
# selftest name never starts with `-`), so `run-selftests.sh --shard 1/4 'dash-*'`
# works. Forwarded verbatim through the shadow re-exec above, so it is only ever
# parsed here, in the inner run.
shard_k=1 shard_n=1 changed_base=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --shard) [ "$#" -ge 2 ] || { echo "run-selftests: --shard needs K/N" >&2; exit 2; }
             shard_spec=$2; shift 2 ;;
    --shard=*) shard_spec=${1#--shard=}; shift ;;
    --changed) [ "$#" -ge 2 ] && [ -n "$2" ] \
                 || { echo "run-selftests: --changed needs a base revision" >&2; exit 2; }
               changed_base=$2; shift 2; continue ;;
    --changed=*) changed_base=${1#--changed=}
               [ -n "$changed_base" ] \
                 || { echo "run-selftests: --changed needs a base revision" >&2; exit 2; }
               shift; continue ;;
    --)      shift; break ;;
    -*)      echo "run-selftests: unknown option '$1'" >&2; exit 2 ;;
    *)       break ;;
  esac
  # Shape first, so the range test below can never be handed a non-number. The
  # digit classes are what reject '', '1', '1/', '/4', '1/x' and '1/4/5'.
  case "$shard_spec" in
    *[!0-9/]*|*/*/*) shard_ok=0 ;;
    [0-9]*/[0-9]*)   shard_ok=1 ;;
    *)               shard_ok=0 ;;
  esac
  [ "$shard_ok" = 1 ] \
    || { echo "run-selftests: --shard wants K/N (e.g. 2/4), got '$shard_spec'" >&2; exit 2; }
  shard_k=${shard_spec%%/*}; shard_n=${shard_spec##*/}
  [ "$shard_n" -ge 1 ] && [ "$shard_k" -ge 1 ] && [ "$shard_k" -le "$shard_n" ] \
    || { echo "run-selftests: --shard K must be 1..N, got '$shard_spec'" >&2; exit 2; }
done

# --changed <base> — run only the tests RELATED to what changed since <base>
# (issue #1374). Every PR used to run the full 270-test suite three times (branch
# push, pull_request, master push) plus once more on the worker's own box; this is
# what lets CI run only the tests a change can actually break. A test is selected
# when ANY of these hits, and the reason is printed as `select: <test> ← <reason>`:
#   a) it is itself a changed *-selftest.sh;
#   b) its source names a changed file's BASENAME (a file under one of the shipped
#      trees below — `docs/` and the READMEs select nothing of their own); an
#      extensionless one (bin/fleet) only as a path, `/<name>` (issue #1734);
#   c) for a shared LIBRARY (bin/*lib.sh), where the basename is in nearly every
#      test: its source names a FUNCTION whose body the diff touched (old or new
#      side, so a removed function still selects its callers' tests);
#   d) it is in SELFTEST_ALWAYS — the lint-type tests that scan the whole tree, so
#      no filename rule could ever pick them.
# A change to the harness itself (SELFTEST_HARNESS) — or a base that does not
# resolve — falls back to the FULL suite: never trust a selector to vet its own
# edit. The diff is base...HEAD (from the merge base), committed changes only.
SELFTEST_ALWAYS='portability bash32-array fleet-keys conf-surface fleet-plugin selftest-isolation'
SELFTEST_HARNESS='bin/run-selftests.sh bin/selftest-shadow-root.sh .github/workflows/selftests*.yml'

# lib_funcs <rev> <path> <ranges> — the functions of <path>@<rev> whose bodies cover
# any of <ranges> ("first-last ..."). A function's body runs from its definition
# line to the next definition: top-level code between two functions is charged to
# the one above it, which over-selects — the safe direction. A touched line above
# the FIRST function (a library default like `FLEET_CONF_DIR=...`) yields the
# variable it assigns instead, so a changed default still selects its readers.
lib_funcs() {
  git -C "$repo_dir" show "$1:$2" 2>/dev/null | awk -v ranges="$3" '
    BEGIN { n = split(ranges, r, " ") ; for (i = 1; i <= n; i++) { split(r[i], ab, "-"); lo[i] = ab[1]; hi[i] = ab[2] } }
    {
      if (match($0, /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/)) {
        f = substr($0, RSTART, RLENGTH)
        sub(/^[[:space:]]*(function[[:space:]]+)?/, "", f); sub(/[[:space:]]*\(\)$/, "", f)
        cur = f
      }
      hit = 0
      for (i = 1; i <= n; i++) if (NR >= lo[i] && NR <= hi[i]) { hit = 1; break }
      if (!hit) next
      if (cur != "") { print cur; next }
      # Above the first function: name the VARIABLE the line assigns, if any.
      if (match($0, /^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+|:[[:space:]]+"?\$\{)?[A-Za-z_][A-Za-z0-9_]*[:]?=/)) {
        v = substr($0, RSTART, RLENGTH)
        sub(/^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+|:[[:space:]]+"?\$\{)?/, "", v); sub(/[:]?=$/, "", v)
        print v
      }
    }' | sort -u
}

# hunk_ranges <old|new> — read `git diff -U0` and print the touched line ranges of
# one side ("first-last", one per hunk; a pure insert/delete has none on its empty side).
hunk_ranges() {
  awk -v side="$1" '/^@@ / {
      spec = (side == "old") ? $2 : $3; sub(/^[-+]/, "", spec)
      c = split(spec, p, ","); start = p[1]; len = (c > 1) ? p[2] : 1
      if (len > 0) printf "%d-%d ", start, start + len - 1
    }'
}

if [ -n "$changed_base" ]; then
  [ "$#" -eq 0 ] \
    || { echo "run-selftests: --changed picks the tests itself — drop the test names" >&2; exit 2; }
  repo_dir=$(cd .. && pwd)
  full_reason=''
  if ! mb=$(git -C "$repo_dir" merge-base "$changed_base" HEAD 2>/dev/null) || [ -z "$mb" ]; then
    full_reason="base '$changed_base' does not resolve to a commit with a merge base"
  else
    changed_files=$(git -C "$repo_dir" diff --no-renames --name-only "$mb" HEAD 2>/dev/null) \
      || full_reason="git diff $mb..HEAD failed"
  fi
  if [ -z "$full_reason" ]; then
    for f in $changed_files; do
      for h in $SELFTEST_HARNESS; do
        # shellcheck disable=SC2254  # intentional: $h is a glob pattern
        case "$f" in $h) full_reason="harness changed: $f"; break 2 ;; esac
      done
    done
  fi
  if [ -n "$full_reason" ]; then
    printf 'select: * ← full suite (%s)\n' "$full_reason"
    set -- *-selftest.sh
  else
    picks=''   # "test<TAB>reason" lines; the first reason per test wins
    nl='
'
    tab=$(printf '\t')
    for f in $changed_files; do
      b=${f##*/}
      case "$f" in
        bin/*-selftest.sh)
          [ -f "$b" ] && picks="$picks$b${tab}changed itself$nl" ;;
      esac
      case "$f" in
        bin/*-selftest.sh) ;;
        bin/*lib.sh)
          diff_u0=$(git -C "$repo_dir" diff -U0 "$mb" HEAD -- "$f" 2>/dev/null)
          funcs=$( { lib_funcs "$mb" "$f" "$(printf '%s\n' "$diff_u0" | hunk_ranges old)"
                     lib_funcs HEAD "$f" "$(printf '%s\n' "$diff_u0" | hunk_ranges new)"; } | sort -u)
          for fn in $funcs; do
            for t in $(grep -lwF -- "$fn" *-selftest.sh 2>/dev/null); do
              case "$fn" in
                [A-Z]*) picks="$picks$t${tab}mentions \$$fn ($f)$nl" ;;
                *)      picks="$picks$t${tab}mentions $fn() ($f)$nl" ;;
              esac
            done
          done
          continue ;;
      esac
      case "$f" in
        bin/*|hooks/*|conf/*|commands/*|skills/*|launchd/*|systemd/*|mod/*|shell/*|extras/*|.claude-plugin/*|fleet.conf.example) ;;
        *) continue ;;
      esac
      # An EXTENSIONLESS basename (bin/fleet) is an ordinary word — `fleet` is in
      # 330 of the tests — so it selects only where a test names it as a PATH:
      # `/fleet` not followed by a name character or another `/` (issue #1734).
      case "$b" in
        *.*) hits=$(grep -lF -- "$b" *-selftest.sh 2>/dev/null) ;;
        *)   hits=$(grep -lE -- "/$b([^A-Za-z0-9_./-]|\$)" *-selftest.sh 2>/dev/null) ;;
      esac
      for t in $hits; do
        picks="$picks$t${tab}mentions $b$nl"
      done
    done
    for a in $SELFTEST_ALWAYS; do
      [ -f "$a-selftest.sh" ] && picks="$picks$a-selftest.sh${tab}always (lint group)$nl"
    done
    picks=$(printf '%s' "$picks" | awk -F '\t' 'NF && !seen[$1]++' | sort)
    if [ -z "$picks" ]; then
      echo 'select: (none) ← no change maps to a selftest'
      exit 0
    fi
    printf '%s\n' "$picks" | awk -F '\t' '{ printf "select: %s ← %s\n", $1, $2 }'
    # shellcheck disable=SC2046  # intentional: test names carry no whitespace
    set -- $(printf '%s\n' "$picks" | cut -f1)
  fi
fi

# Which tests to run. No args = the full gate; args select, with the `-selftest.sh`
# suffix optional so `run-selftests.sh fleet-context` does the obvious thing. The
# candidates are deliberately left unquoted so a glob arg (`'dash-*'`) expands here.
if [ -n "$changed_base" ]; then
  :   # already settled above
elif [ "$#" -gt 0 ]; then
  selected=''
  for a in "$@"; do
    hit=0
    # shellcheck disable=SC2086  # intentional: $a may be a glob the caller passed
    for t in $a $a-selftest.sh; do
      case "$t" in *-selftest.sh) ;; *) continue ;; esac   # never run a non-test
      [ -f "$t" ] || continue
      case " $selected " in *" $t "*) continue ;; esac     # dedup overlapping args
      selected="$selected $t"; hit=1
    done
    [ "$hit" -eq 1 ] || { echo "run-selftests: no selftest matches '$a'" >&2; exit 2; }
  done
  # shellcheck disable=SC2086  # intentional: re-split the space-separated list
  set -- $selected
else
  set -- *-selftest.sh
fi

# Settle the work list, applying the shard STRIDE. Striding (every N-th) rather than
# slicing into contiguous blocks matters because the list is sorted and cost clusters
# by name: the eight `fleet-collect-*` tests are adjacent AND among the slowest, so a
# contiguous split would pile them into one shard. A stride deals them round-robin,
# and a test landing anywhere in the list re-deals the rest for free — no table of
# durations to keep in sync, which is the thing that always drifts.
tests='' ntests=0 discovered=0
for t in "$@"; do
  # No matches → the glob stays literal; the -f guard drops that phantom entry.
  [ -f "$t" ] || continue
  discovered=$((discovered + 1))
  [ $(( (discovered - 1) % shard_n + 1 )) -eq "$shard_k" ] || continue
  tests="$tests $t"; ntests=$((ntests + 1))
done
if [ "$discovered" -eq 0 ]; then
  echo "run-selftests: no *-selftest.sh found in $script_dir" >&2
  exit 2
fi
# A shard that runs nothing (N wider than what was selected) is a misconfiguration,
# and the one outcome it must never produce is a green.
# Under --changed it is the normal case — three related tests across a six-wide
# matrix — so there the spare shard passes having run nothing, and says so.
if [ "$ntests" -eq 0 ] && [ -n "$changed_base" ]; then
  echo "run-selftests: shard $shard_k/$shard_n has nothing to run — only $discovered related test(s)"
  exit 0
fi
if [ "$ntests" -eq 0 ]; then
  echo "run-selftests: shard $shard_k/$shard_n is empty — only $discovered test(s) to split" >&2
  exit 2
fi
[ "$shard_n" -eq 1 ] \
  || printf 'run-selftests: shard %s/%s — %s of %s test(s)\n' "$shard_k" "$shard_n" "$ntests" "$discovered"

# Milliseconds since the epoch. BSD `date` has no %N/%3N, so perl (already a fleet
# dependency), then python3, then whole seconds ×1000 as a coarse last resort.
# Mirrors fleet-lib.sh's fleet_now_ms, inlined on purpose: this runner must not
# source fleet-lib.sh, which would load the very conf the shadow root excludes.
now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null && return
  python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null && return
  echo $(( $(date +%s 2>/dev/null || echo 0) * 1000 ))
}

# ms → seconds with one decimal, in shell arithmetic (no bc/awk dependency).
secs() { printf '%d.%d' $(( $1 / 1000 )) $(( ($1 % 1000) / 100 )); }

# PER-TEST CEILING (issue #1150). One test that never ends used to be a gate that
# never ends: on 2026-09-24 auto-handoff-selftest.sh sat on a `cat` of an open,
# never-closed stdin for 77 minutes, nothing after it ran, and the worker waiting on
# the backgrounded gate was never woken. So every test now runs under a supervisor:
#
#   • its own PROCESS GROUP, so a timeout kills the whole tree it started — the hung
#     hook three levels down, not just the `bash` at the top;
#   • stdin is /dev/null — a test that reads stdin gets EOF, never the runner's
#     (possibly open-forever) pipe, which is exactly what hung the 9-24 run;
#   • on the deadline it PRINTS what is still running in that group (pid, age,
#     argv), then TERM → grace → KILL, and exits 124, which the loop counts as
#     TIMEOUT (a failure) before moving on to the next test;
#   • the deadline also lives IN THE TEST (fleet-loadgen.sh's principle, issue
#     #697): the child arms alarm(2) before it execs, and that survives execve —
#     so a SIGKILLed supervisor or runner still cannot leave a test running forever.
#
# perl (already this runner's clock) hosts it; with no perl, tests run unsupervised
# exactly as before. FLEET_SELFTEST_TEST_TIMEOUT=0 turns the ceiling off.
test_timeout=${FLEET_SELFTEST_TEST_TIMEOUT:-600}
case "$test_timeout" in ''|*[!0-9]*) test_timeout=600 ;; esac
supervise=0
[ "$test_timeout" -gt 0 ] && command -v perl >/dev/null 2>&1 && supervise=1
# shellcheck disable=SC2016  # a perl program: its $vars are perl's, not the shell's
SUPERVISOR='
use strict; use POSIX ();
my ($limit, $t) = @ARGV; my $grace = 5;
my $pid = fork(); defined $pid or die "run-selftests: fork: $!\n";
if ($pid == 0) {
  setpgrp(0, 0);
  alarm($limit + 3 * $grace);          # the in-test backstop: survives execve
  exec("bash", $t) or POSIX::_exit(127);
}
setpgrp($pid, $pid);                   # from both sides: no window where it is unset
sub group_alive { waitpid($pid, POSIX::WNOHANG()); kill(0, -$pid) }   # reap first: a zombie still answers kill 0
sub stop_group {
  kill("TERM", -$pid);
  for (1 .. $grace * 10) { last unless group_alive(); select(undef, undef, undef, 0.1) }
  kill("KILL", -$pid) if group_alive();
}
for my $s (qw(INT TERM HUP)) {        # the runner is going away: take the test along
  $SIG{$s} = sub { stop_group(); exit 128 + ($s eq "INT" ? 2 : $s eq "TERM" ? 15 : 1) };
}
my $r = eval {
  local $SIG{ALRM} = sub { die "timeout\n" };
  alarm($limit); my $w = waitpid($pid, 0); alarm(0); $w;
};
if (defined $r) { exit($? & 127 ? 128 + ($? & 127) : $? >> 8) }
print STDERR "run-selftests: TIMEOUT — $t still running after ${limit}s; its process group:\n";
for (`ps -A -o pid= -o ppid= -o pgid= -o etime= -o command= 2>/dev/null`) {
  my @f = split " ", $_, 5;
  printf STDERR "  pid %-6s ppid %-6s up %-11s %s", @f[0, 1, 3, 4] if @f == 5 && $f[2] == $pid;
}
stop_group(); waitpid($pid, 0);
exit 124;
'

total=0 passed=0 failed=0
failures='' timings=''
run_start=$(now_ms)

# shellcheck disable=SC2086  # intentional: $tests is a space-separated list
for t in $tests; do
  total=$((total + 1))
  printf '\n=== %s ===\n' "$t"
  start_ms=$(now_ms)
  if [ "$supervise" -eq 1 ]; then
    if perl -e "$SUPERVISOR" "$test_timeout" "./$t" </dev/null; then rc=0; else rc=$?; fi
  else
    if bash "./$t" </dev/null; then rc=0; else rc=$?; fi
  fi
  ms=$(( $(now_ms) - start_ms ))
  timings="$timings$ms $t
"
  if [ "$rc" -eq 0 ]; then
    printf 'PASS  %-46s %6ss\n' "$t" "$(secs "$ms")"
    passed=$((passed + 1))
  elif [ "$supervise" -eq 1 ] && [ "$rc" -eq 124 ] && [ "$ms" -ge $((test_timeout * 1000)) ]; then
    printf 'TIMEOUT %-44s %6ss (limit %ss)\n' "$t" "$(secs "$ms")" "$test_timeout"
    failed=$((failed + 1))
    failures="${failures} ${t}"
  else
    printf 'FAIL  %-46s %6ss (exit %s)\n' "$t" "$(secs "$ms")" "$rc"
    failed=$((failed + 1))
    failures="${failures} ${t}"
  fi
done

# The slowest tests (issue #681). Without this number, the next time the suite
# approaches its CI budget the only way to find out WHY is to time the whole suite
# by hand — the same reason collect grew `over=` in #653. Sharded, each shard reports
# its own slice; GitHub stacks every matrix job's summary on one page, so the slow
# ones still surface together.
slow_n=${FLEET_SELFTEST_SLOWEST:-10}
case "$slow_n" in ''|*[!0-9]*) slow_n=10 ;; esac
if [ "$slow_n" -gt 0 ]; then
  [ "$slow_n" -gt "$total" ] && slow_n=$total
  printf '\n---------------- slowest %s of %s ----------------\n' "$slow_n" "$total"
  printf '%s' "$timings" | sort -rn | head -n "$slow_n" | while read -r ms t; do
    printf '  %6ss  %s\n' "$(secs "$ms")" "$t"
  done
fi

printf '\n================ selftest summary ================\n'
printf '%s test(s): %s passed, %s failed\n' "$total" "$passed" "$failed"
printf 'wall %ss\n' "$(secs "$(( $(now_ms) - run_start ))")"
if [ "$failed" -ne 0 ]; then
  printf 'failed:%s\n' "$failures"
  exit 1
fi
printf 'all green\n'
# Explicit success: don't let a failed final stdout write (SIGPIPE/ENOSPC on the
# CI runner) leak a non-zero status and paint an all-green suite red.
exit 0
