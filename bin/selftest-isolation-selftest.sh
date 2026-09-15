#!/bin/bash
# selftest-isolation-selftest.sh — the META-test: the gate must not read the machine.
#
# It pins the invariant issue #660 was filed on: `run-selftests.sh` produces the SAME
# verdict whether or not the install root it is running from has a real `fleet.conf`.
# Without a test here the regression is silent — the suite is all-green in CI (a
# checkout never has a conf) and only goes red on an operator's live install, which
# is the one place nobody re-runs it after a change.
#
# Five parts, each a different way the isolation can break:
#
#   A. MECHANISM — a probe script using the canonical conf-load one-liner sees the
#      fixture conf when run from the fake install root, and sees NOTHING when run
#      through the shadow. This is the load-bearing assertion, and it is written
#      against the one-liner rather than any particular test's internals, so it
#      cannot go stale when a test is rewritten.
#
#   B. `..` HONESTY — `$BIN/../fleet.conf` from inside the shadow's bin/ must not
#      resolve back to the real root's conf. This is the subtle one: `$BIN` comes
#      from a LOGICAL `cd … && pwd`, but `[ -f "$BIN/../fleet.conf" ]` is resolved
#      by the kernel, which walks symlinks PHYSICALLY. A shadow whose bin/ was a
#      symlink to the real bin/ passes every structural check in C and still reads
#      the operator's conf. Assert the file test directly.
#
#   C. STRUCTURE — the shadow mirrors every top-level entry of the root except the
#      conf and its backups; bin/ is a real directory; logs/ and conf-dir/ are real
#      and EMPTY (live STATE, not config — a suite run must not read or clobber the
#      running fleet's needs-strike table); the temp dir is named so that
#      fleet-selftest-reap.sh collects it if a run is SIGKILLed.
#
#   D. END TO END — the real runner, invoked from a fake install root that HAS a
#      populated fleet.conf, on the three tests #660 traced to three different conf
#      keys (CCQUOTA_HUB_URL, FLEET_CTX_WINDOW, FLEET_REPO/FLEET_MAIN). Green is
#      the acceptance criterion from the issue.
#
#   E. THE ENVIRONMENT ROUTE (issue #689) — A–D all cover the FILE route. The conf
#      reaches the suite a SECOND way: a fleet conf `export`s its keys and
#      fleet-claude.sh sources it before launching the agent, so every worker pane
#      already HAS CCQUOTA_HUB_URL / FLEET_REPO in its environment — no file read
#      involved. #660 wrote the scrub for that and left it untested, and the scrub
#      turned out to be a GNU-sed-only expression that BSD sed silently matches
#      nothing with — so on macOS the whole half was a no-op and no test on either
#      platform could tell. Assert the BEHAVIOUR, not the expression: a poisoned
#      environment must not reach the suite (E2), the assertion must be able to
#      fail (E1, the NO_SHADOW control), and the scrub must not eat the runner's
#      own FLEET_SELFTEST_* arguments (E3).
#
# Exit 0 = pass. Non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
MK="$BIN/selftest-shadow-root.sh"
RUNNER="$BIN/run-selftests.sh"
[ -x "$MK" ]     || { printf 'selftest: %s not found/executable\n' "$MK" >&2; exit 2; }
[ -f "$RUNNER" ] || { printf 'selftest: %s not found\n' "$RUNNER" >&2; exit 2; }

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '  %s\n' "$2" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); printf 'ok   %s\n' "$1"; }
eq()   { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; printf 'ok   %s\n' "$1"; }

CLEAN=''
cleanup() { for d in $CLEAN; do rm -rf "$d"; done; }
trap cleanup EXIT INT TERM HUP

# The inner runner must decide for itself whether to build a shadow. When the OUTER
# suite is running us, its own FLEET_SELFTEST_ROOT is already in our environment and
# would tell the inner run "you are already isolated" — which is exactly the bug this
# test exists to catch, so strip the whole family before every inner invocation.
clean_env() { env -u FLEET_SELFTEST_ROOT -u FLEET_SELFTEST_NO_SHADOW \
                  -u FLEET_CONF_DIR -u FLEET_SKIP_GLOBAL_CONF -u FLEET_ISOLATION_PROBE "$@"; }

# ============================================================================
# The fixture: a fake LIVE install — a conf-free mirror of this checkout, with a
# populated fleet.conf dropped in. Built with the shadow builder itself so the
# fixture can never drift from what the builder mirrors; from here on it is an
# install root like any other, and nothing below writes into the real tree.
# ============================================================================
FAKE="$("$MK")" || fail "shadow-root builder failed while making the fixture"
CLEAN="$CLEAN $FAKE"

cat > "$FAKE/fleet.conf" <<'CONF'
# fixture conf (selftest-isolation-selftest.sh) — the keys #660 traced its six fake
# failures to, one per affected script family, plus a marker (below) for part A.
FLEET_REPO="fixture/not-a-real-repo"
FLEET_MAIN="/nonexistent/fixture/main"
FLEET_BASE_BRANCH="fixture-base"
FLEET_CTX_WINDOW=1000000
export CCQUOTA_HUB_URL="https://fixture.invalid"
# A marker no environment can supply: FLEET_REPO/CCQUOTA_HUB_URL are also EXPORTED by
# a real conf and therefore already sit in a worker pane's environment, so they cannot
# tell "the file was sourced" from "the pane leaked it". This key only ever comes from
# the file, which is precisely what part A is asking about.
FLEET_ISOLATION_PROBE="sourced-from-file"
CONF
echo 'stale backup' > "$FAKE/fleet.conf.bak"
echo 'stale backup' > "$FAKE/fleet.conf.bak.1700000000"

# The probe: the canonical conf-load one-liner ~60 fleet scripts open with. Placed
# in the fixture's bin/, so the shadow built off the fixture mirrors it too. It is
# not named *-selftest.sh, so the runner never picks it up as a test.
cat > "$FAKE/bin/zz-conf-probe.sh" <<'PROBE'
#!/bin/sh
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
printf 'probe=%s\n' "${FLEET_ISOLATION_PROBE:-none}"
PROBE
chmod +x "$FAKE/bin/zz-conf-probe.sh"

# ============================================================================
# A. MECHANISM — the leak is real, and the shadow closes it
# ============================================================================
eq "the fixture install root leaks its conf (control: without this, A is vacuous)" \
   "probe=sourced-from-file" "$(clean_env sh "$FAKE/bin/zz-conf-probe.sh")"

SHADOW="$(clean_env "$FAKE/bin/selftest-shadow-root.sh")" \
  || fail "shadow-root builder failed against the fixture root"
CLEAN="$CLEAN $SHADOW"

eq "through the shadow the same probe sees no conf at all" \
   "probe=none" "$(clean_env sh "$SHADOW/bin/zz-conf-probe.sh")"

# ============================================================================
# B. `..` HONESTY — the assertion a symlinked bin/ would fail
# ============================================================================
CHECKS=$((CHECKS + 1))
[ -f "$FAKE/fleet.conf" ] || fail "fixture lost its conf — B cannot prove anything"
CHECKS=$((CHECKS + 1))
[ -f "$SHADOW/bin/../fleet.conf" ] \
  && fail "\$BIN/../fleet.conf resolved back to the real root — the shadow's bin/ must be a REAL dir of symlinks, not a symlink to bin/"
ok "\$BIN/../fleet.conf from the shadow's bin/ does not reach the real conf"

CHECKS=$((CHECKS + 1))
[ -L "$SHADOW/bin" ] && fail "the shadow's bin/ is a symlink — '..' escapes it"
CHECKS=$((CHECKS + 1))
[ -d "$SHADOW/bin" ] || fail "the shadow has no bin/ directory"
ok "the shadow's bin/ is a real directory"

# ============================================================================
# C. STRUCTURE — what is mirrored, what is emptied, what is left out
# ============================================================================
CHECKS=$((CHECKS + 1))
[ -e "$SHADOW/fleet.conf" ] && fail "the shadow carries a fleet.conf"
for b in fleet.conf.bak fleet.conf.bak.1700000000; do
  CHECKS=$((CHECKS + 1))
  [ -e "$SHADOW/$b" ] && fail "the shadow carries $b — a backup must not be able to resurrect a conf"
done
ok "no fleet.conf and no fleet.conf.bak* in the shadow"

# `claude plugin validate` never follows a symlink — a symlinked .claude-plugin makes
# it report "Local source './' is or traverses a symlink" and read no manifest at all,
# so fleet-plugin-selftest.sh fails having validated nothing.
CHECKS=$((CHECKS + 1))
[ -L "$SHADOW/.claude-plugin" ] && fail ".claude-plugin is a symlink in the shadow — claude plugin validate will not follow it"
CHECKS=$((CHECKS + 1))
[ -f "$SHADOW/.claude-plugin/plugin.json" ] || fail "the shadow has no real .claude-plugin/plugin.json"
ok ".claude-plugin is copied, not symlinked (the plugin validator will not follow one)"

# fleet.conf.example IS tracked and IS read (fcfg_default / fcfg_validate) — the
# exclusion must be the conf, not everything conf-shaped.
CHECKS=$((CHECKS + 1))
[ -e "$SHADOW/fleet.conf.example" ] || fail "the shadow dropped fleet.conf.example — the config modal reads it"
ok "fleet.conf.example survives the mirror"

missing=''
for e in "$FAKE"/* "$FAKE"/.[!.]*; do
  [ -e "$e" ] || [ -L "$e" ] || continue
  b="${e##*/}"
  case "$b" in fleet.conf|fleet.conf.bak*) continue ;; esac
  [ -e "$SHADOW/$b" ] || missing="$missing $b"
done
eq "every other top-level entry is mirrored (dotfiles included)" "" "$missing"

# bin/ has dotfiles of its own — `.fleet-restore-resolve.py`, resolved by
# dash-raw-session.sh as `$BIN/.fleet-restore-resolve.py`. A `*`-only mirror drops
# them and the test that needs one dies in setup: fake red, by a different route.
missing=''
for e in "$FAKE"/bin/* "$FAKE"/bin/.[!.]*; do
  [ -e "$e" ] || [ -L "$e" ] || continue
  b="${e##*/}"
  [ -e "$SHADOW/bin/$b" ] || missing="$missing $b"
done
eq "every bin/ entry is mirrored, dotfiles included" "" "$missing"

for d in logs conf-dir; do
  CHECKS=$((CHECKS + 1))
  [ -d "$SHADOW/$d" ] && [ ! -L "$SHADOW/$d" ] \
    || fail "$d/ must be a real directory in the shadow, not a symlink to the install's live state"
  CHECKS=$((CHECKS + 1))
  [ -z "$(ls -A "$SHADOW/$d" 2>/dev/null)" ] \
    || fail "$d/ must start EMPTY — a suite run must never read or clobber the running fleet's state"
done
ok "logs/ and conf-dir/ are real and empty (live state, not config)"

# fleet-selftest-reap.sh sweeps aged `*selftest*` mktemp dirs; a run killed outright
# leaves the shadow behind, and only this naming gets it collected.
CHECKS=$((CHECKS + 1))
case "${SHADOW##*/}" in *selftest*) ;; *) fail "shadow temp dir '${SHADOW##*/}' has no 'selftest' in its name — fleet-selftest-reap.sh cannot collect an orphan" ;; esac
ok "the shadow temp dir is named for the reaper"

# ============================================================================
# D. END TO END — the runner, from an install root that HAS a conf
# ============================================================================
# The three tests #660 traced to three different conf keys. Named explicitly (not
# the whole suite) so this stays a bounded check and never recurses into itself.
SUBSET='fleet-quotaguard fleet-context fleet-claim-brief'
out=''
# shellcheck disable=SC2086  # intentional: $SUBSET is a list of arguments
if ! out="$(clean_env sh "$FAKE/bin/run-selftests.sh" $SUBSET </dev/null 2>&1)"; then
  fail "run-selftests.sh went red from an install root with a fleet.conf — the conf is leaking again (#660)" \
       "$(printf '%s\n' "$out" | tail -20)"
fi
CHECKS=$((CHECKS + 1))
printf 'ok   %s\n' "run-selftests.sh is green from an install root that HAS a fleet.conf"

eq "…and it really ran the three tests" "3 test(s): 3 passed, 0 failed" \
   "$(printf '%s\n' "$out" | grep -m1 'test(s):')"

# ============================================================================
# E. THE ENVIRONMENT ROUTE (issue #689) — the conf's second way in
# ============================================================================
# The probe: a fixture-only selftest that REPORTS rather than asserts, printing every
# FLEET_*/CCQUOTA_* name it can see on one line. Reporting is what keeps it alive —
# the runner sets FLEET_SKIP_GLOBAL_CONF / FLEET_CONF_DIR / FLEET_SELFTEST_ROOT of its
# own accord, and a probe that asserted "none of this family is present" would have to
# carry an exemption list that goes stale the next time the runner adds one. Part E
# below names the exact variables it cares about instead.
#
# Pure shell — no sed, no grep, no awk. The bug this part exists to catch is a regex
# that silently matched nothing; a probe written with the same tool could be blind in
# the same way and report a clean environment either way.
cat > "$FAKE/bin/zz-env-probe-selftest.sh" <<'PROBE'
#!/bin/sh
# Fixture-only (built by selftest-isolation-selftest.sh part E) — never in the repo.
set -u
# Printed straight out, never captured into a variable: bash 3.2 (macOS /bin/sh)
# matches the parens of `$( … )` naively, so the `)` ending a case PATTERN inside one
# closes the substitution early and the script dies on a syntax error.
printf 'zzprobe: '
env | { while IFS='=' read -r k _rest; do
          case "$k" in ''|*[!A-Za-z0-9_]*) continue ;; esac   # a multi-line value's tail
          case "$k" in FLEET_*|CCQUOTA_*) printf '%s\n' "$k" ;; esac
        done; } | sort | tr '\n' ' '
printf '\n'
PROBE
chmod +x "$FAKE/bin/zz-env-probe-selftest.sh"

# The poison. Two that a live conf really does export into every worker pane, and two
# synthetic ones — so a pass cannot come from some test happening to unset the real
# pair, and the CCQUOTA_ prefix is covered as well as FLEET_ (the one-expression sed
# dropped BOTH, but a half-fixed one would drop only the first).
POISON='FLEET_REPO CCQUOTA_HUB_URL FLEET_ZZ_POISON CCQUOTA_ZZ_POISON'
poison_env() {
  clean_env env FLEET_REPO='poison/not-a-real-repo' CCQUOTA_HUB_URL='https://poison.invalid' \
                FLEET_ZZ_POISON=1 CCQUOTA_ZZ_POISON=1 "$@"
}
probe_line() { printf '%s\n' "$1" | grep -m1 '^zzprobe:'; }

# E1 CONTROL — running in place (no shadow, no scrub) the poison MUST arrive. Without
# this E2 is vacuous: a probe that never sees anything passes for the wrong reason.
ctl="$(poison_env env FLEET_SELFTEST_NO_SHADOW=1 sh "$FAKE/bin/run-selftests.sh" zz-env-probe </dev/null 2>&1)"
ctl_line="$(probe_line "$ctl")"
[ -n "$ctl_line" ] || fail "E1 the probe never ran in place" "$(printf '%s\n' "$ctl" | tail -20)"
for v in $POISON; do
  CHECKS=$((CHECKS + 1))
  case " $ctl_line " in
    *" $v "*) ;;
    *) fail "E1 control: $v did not reach the suite even with the scrub disabled — the probe is blind, so E2 would prove nothing" "$ctl_line" ;;
  esac
done
ok "without the shadow, a poisoned environment reaches the suite (control: E2 is not vacuous)"

# E2 THE ASSERTION — through the real prelude, none of it may arrive. This is the
# check that is red on macOS with the one-expression `\|` sed of #689, and green on
# Linux with the same source: the platform divergence the whole issue is about.
env_out="$(poison_env sh "$FAKE/bin/run-selftests.sh" zz-env-probe </dev/null 2>&1)"
env_line="$(probe_line "$env_out")"
[ -n "$env_line" ] || fail "E2 the probe never ran through the shadow" "$(printf '%s\n' "$env_out" | tail -20)"
leaked=''
for v in $POISON; do
  case " $env_line " in *" $v "*) leaked="$leaked $v" ;; esac
done
eq "the FLEET_*/CCQUOTA_* environment is stripped on the way into the suite (#689)" "" "$leaked"

# E3 THE OTHER HALF — FLEET_SELFTEST_* are runner ARGUMENTS that happen to travel as
# environment variables. Scrub them and the outer half honours a knob the inner half
# never sees, which is how FLEET_SELFTEST_SLOWEST=0 still printed the table.
knob_out="$(clean_env env FLEET_SELFTEST_SLOWEST=3 sh "$FAKE/bin/run-selftests.sh" zz-env-probe </dev/null 2>&1)"
knob_line="$(probe_line "$knob_out")"
CHECKS=$((CHECKS + 1))
case " $knob_line " in
  *" FLEET_SELFTEST_SLOWEST "*) ;;
  *) fail "E3 FLEET_SELFTEST_SLOWEST was scrubbed — the runner's own knobs must survive into the inner run" "$knob_line" ;;
esac
ok "FLEET_SELFTEST_* knobs survive the scrub (they steer the runner, they are not fleet config)"

printf '\nselftest-isolation-selftest: %s checks passed (issues #660, #689)\n' "$CHECKS"
