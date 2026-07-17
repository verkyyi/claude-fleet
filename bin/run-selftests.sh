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
set -u

unset CDPATH  # keep `cd` from echoing/jumping via a user's CDPATH
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir" || { echo "run-selftests: cannot cd to bin dir ($script_dir)" >&2; exit 2; }

# Hermetic env (issue #399): fleet-lib.sh now sources the sibling fleet.conf on load
# and EXPORTS the global-only cap keys. In CI that's a no-op (a fresh checkout has no
# repo-root fleet.conf), but a worker reproducing this gate from the LIVE install
# (~/.claude/fleet/bin/run-selftests.sh) would otherwise let the machine's real
# fleet.conf (e.g. FLEET_GLOBAL_MAX_SESSIONS=20) leak into tests that read the cap.
# Skip the auto-source and clear any inherited global-only keys so every test starts
# from the same pristine env it gets in CI, wherever the runner is invoked from.
export FLEET_SKIP_GLOBAL_CONF=1
unset FLEET_GLOBAL_MAX_SESSIONS 2>/dev/null || true

total=0 passed=0 failed=0
failures=''

for t in *-selftest.sh; do
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
