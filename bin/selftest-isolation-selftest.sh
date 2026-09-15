#!/bin/bash
# selftest-isolation-selftest.sh — the META-test: the gate must not read the machine.
#
# It pins the invariant issue #660 was filed on: `run-selftests.sh` produces the SAME
# verdict whether or not the install root it is running from has a real `fleet.conf`.
# Without a test here the regression is silent — the suite is all-green in CI (a
# checkout never has a conf) and only goes red on an operator's live install, which
# is the one place nobody re-runs it after a change.
#
# Four parts, each a different way the isolation can break:
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

printf '\nselftest-isolation-selftest: %s checks passed (issue #660)\n' "$CHECKS"
