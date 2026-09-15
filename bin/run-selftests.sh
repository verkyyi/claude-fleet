#!/bin/sh
# run-selftests.sh — the single aggregate gate for the fleet's hermetic selftests.
#
# Discovers every `bin/*-selftest.sh` (there is no registry to keep in sync — a
# new selftest is picked up the moment it lands), runs each in turn, prints a
# per-test PASS/FAIL line, and exits non-zero if ANY test failed. This is what
# CI runs (.github/workflows/selftests.yml), so a worker can reproduce the exact
# CI verdict locally with one command before pushing.
#
# Convention every selftest already follows: exit 0 = pass, non-zero = fail
# (a test that needs an absent tool — e.g. jq — SKIPs cleanly with exit 0). The
# runner is therefore marker-agnostic: it trusts the exit code, not the wording.
#
# The server-spawning tests isolate onto a private `-S` socket and reap it via an
# EXIT+signal trap, so a normal (even failing) run leaves no litter. A run KILLED
# outright (SIGKILL/OOM) can still orphan a socket or server — `fleet-selftest-reap.sh`
# is the backstop that sweeps that debris (dead sockets, aged `*selftest*` servers
# + temp dirs) without ever touching the shared `default` server (issue #152).
#
# Each test's own output streams through (so CI logs show what a failure printed);
# the runner adds only the PASS/FAIL line and a final summary. Runnable from
# anywhere — it resolves its own dir (the repo's bin/).
#
# Usage: run-selftests.sh [NAME ...]
#   no args  every bin/*-selftest.sh — the CI gate.
#   NAME     run only the named tests. The `-selftest.sh` suffix is optional, and a
#            shell glob works (`run-selftests.sh 'dash-*'`), so chasing one red test
#            still goes through the same hermetic prelude CI uses. A NAME that
#            matches nothing is an error, never a silent all-green.
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
  # CI — minus the two knobs that steer this runner.
  scrub=''
  for v in $(env 2>/dev/null | sed -n 's/^\(FLEET_[A-Za-z0-9_]*\|CCQUOTA_[A-Za-z0-9_]*\)=.*/\1/p'); do
    case "$v" in FLEET_SELFTEST_ROOT|FLEET_SELFTEST_NO_SHADOW) continue ;; esac
    scrub="$scrub -u $v"
  done
  # shellcheck disable=SC2086  # intentional: $scrub is a list of `-u NAME` arguments
  env $scrub FLEET_SELFTEST_ROOT="$shadow" sh "$shadow/bin/run-selftests.sh" "$@"
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

# The PER-FLEET confs are the same leak one directory over (issue #660): fleet_load_conf
# reads $FLEET_CONF_DIR/fleets/<sess>/conf, defaulting to the operator's real
# ~/.config/claude-fleet. 68 of the tests already point this at their own sandbox and
# keep winning — this only covers the rest, which would otherwise read (and, via the
# config modal, write) the live fleets' overlays. Only inside the shadow root: there
# is nowhere safe to put it when running in place.
if [ -n "${FLEET_SELFTEST_ROOT:-}" ] && [ -d "$FLEET_SELFTEST_ROOT/conf-dir" ]; then
  FLEET_CONF_DIR="$FLEET_SELFTEST_ROOT/conf-dir"; export FLEET_CONF_DIR
fi

# Which tests to run. No args = the full gate; args select, with the `-selftest.sh`
# suffix optional so `run-selftests.sh fleet-context` does the obvious thing. The
# candidates are deliberately left unquoted so a glob arg (`'dash-*'`) expands here.
if [ "$#" -gt 0 ]; then
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

total=0 passed=0 failed=0
failures=''

for t in "$@"; do
  # No matches → the glob stays literal; the -f guard skips that phantom entry.
  [ -f "$t" ] || continue
  total=$((total + 1))
  printf '\n=== %s ===\n' "$t"
  if bash "./$t"; then
    printf 'PASS  %s\n' "$t"
    passed=$((passed + 1))
  else
    rc=$?
    printf 'FAIL  %s (exit %s)\n' "$t" "$rc"
    failed=$((failed + 1))
    failures="${failures} ${t}"
  fi
done

printf '\n================ selftest summary ================\n'
if [ "$total" -eq 0 ]; then
  echo "run-selftests: no *-selftest.sh found in $script_dir" >&2
  exit 2
fi
printf '%s test(s): %s passed, %s failed\n' "$total" "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  printf 'failed:%s\n' "$failures"
  exit 1
fi
printf 'all green\n'
# Explicit success: don't let a failed final stdout write (SIGPIPE/ENOSPC on the
# CI runner) leak a non-zero status and paint an all-green suite red.
exit 0
