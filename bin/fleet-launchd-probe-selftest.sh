#!/bin/bash
# fleet-launchd-probe-selftest.sh — the launchd DOMAIN verdict and the scaled
# self-heal cooldown (issue #711). Drives the real bin/fleet-launchd-probe.sh,
# bin/fleet-daemon-lib.sh and bin/fleet-doctor.sh against a fake `launchctl` on
# PATH — no launchd, no agents registered, no wall clock beyond a 1s window.
#
# WHAT THIS PINS, AND WHY EACH PART IS EASY TO BREAK QUIETLY.
#
#   A. probe      A throwaway agent that launchd runs ≥2× in the window means the
#                 domain schedules; exactly once means RunAtLoad fired and the
#                 interval never did; zero means the domain spawns nothing at all.
#                 The three verdicts are the whole diagnostic, and the middle one
#                 is the one a naive "did it run?" check would collapse into "ok".
#   B. unknown    A probe that could not MEASURE must never write a verdict, and
#                 must never be mistaken for `ok`. This is the property the whole
#                 mechanism exists for: #711 happened because nine true per-unit
#                 statements added up to a false diagnosis, and an unmeasured
#                 "domain fine" would do exactly the same thing again.
#   C. cleanup    The probe registers a real LaunchAgent. If it leaks, it ticks for
#                 ever on the operator's machine. So the parent boots it out AND
#                 the job carries its own deadline (the #697 lesson: a trap lives
#                 in the parent, and whatever kills the parent takes the cleanup
#                 with it), AND the next probe sweeps whatever survived both.
#   D. cooldown   The kick cooldown SCALES with each unit's own interval now. The
#                 invariant worth pinning is not the number but the relation: for
#                 every registry unit the cooldown must be ≤ that unit's staleness
#                 threshold, so the already-per-unit threshold is what rate-limits
#                 kicks. A flat 600s broke that for the 15s units, which is how
#                 issue-bridge became a ten-minute daemon.
#   E. collapse   fleet-doctor prints ONE machine-level line instead of N unit
#                 lines when the probe says the domain stopped spawning — and puts
#                 the N lines back when it says the domain is fine, or when nobody
#                 measured. Plus the accounting: the summary count must match the
#                 lines printed (the per-unit warns run inside a loop that, fed by
#                 a pipe instead of a here-doc, would print nine warnings and then
#                 report "all good").
#
# Exit 0 = pass, non-zero = fail.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
FILES='fleet-launchd-probe.sh fleet-daemon-lib.sh fleet-doctor.sh fleet-lib.sh fleet-diskguard.sh'
for f in $FILES; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/launchd-probe-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"   # physical path: the scripts resolve $BIN via pwd
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/.claude-dash/global" "$WORK/conf" "$WORK/lcstate"
for f in $FILES; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh
G="$WORK/.claude-dash/global"
S="$WORK/lcstate"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }
has()  { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) ;; *) fail "$3" "$2";; esac; }
hasnt(){ CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) fail "$3" "$2";; esac; }

# --- fake launchctl -----------------------------------------------------------
# It MODELS the domain rather than canning an answer: `bootstrap` really reads the
# generated plist, really runs the generated program $FAKE_SPAWNS times, and
# `print` really fails until something has been bootstrapped. That is what makes
# the verdicts above a test of the probe's logic and not of its string formatting.
cat > "$WORK/fakepath/launchctl" <<'FAKE'
#!/bin/bash
S="${FAKE_LC_STATE:?}"
case "$1" in
  list)
    cat "$S/list" 2>/dev/null; exit 0 ;;
  bootstrap)
    plist="${3:-}"
    [ "${FAKE_BOOTSTRAP_RC:-0}" != 0 ] && exit "${FAKE_BOOTSTRAP_RC}"
    lbl=$(sed -n 's|.*<key>Label</key><string>\(.*\)</string>.*|\1|p' "$plist" 2>/dev/null | head -1)
    prog=$(sed -n 's|.*<string>\(/.*probe\.sh\)</string>.*|\1|p' "$plist" 2>/dev/null | head -1)
    printf '%s\n' "$lbl" > "$S/loaded"
    [ -n "$prog" ] && cp "$prog" "$S/captured-probe.sh" 2>/dev/null
    n=0
    while [ "$n" -lt "${FAKE_SPAWNS:-0}" ]; do /bin/sh "$prog" >/dev/null 2>&1; n=$((n + 1)); done
    exit 0 ;;
  print)
    [ -s "$S/loaded" ] || exit 113
    printf '%s = {\n\tstate = not running\n\truns = %s\n\tlast exit code = 0\n}\n' "${2:-}" "${FAKE_SPAWNS:-0}"
    exit 0 ;;
  bootout)
    printf '%s\n' "${2:-}" >> "$S/bootouts"; : > "$S/loaded"; exit 0 ;;
  kickstart) exit 0 ;;
esac
exit 0
FAKE
printf '#!/bin/bash\nexit 1\n' > "$WORK/fakepath/systemctl"
chmod +x "$WORK/fakepath/launchctl" "$WORK/fakepath/systemctl"

export PATH="$WORK/fakepath:$PATH"
export TMPDIR="$WORK"
export FLEET_LIVE_ROOT="$WORK"        # this tree IS "the live install" ⇒ shared global/
export FAKE_LC_STATE="$S"

lib()   { bash -c 'set -uo pipefail; . "$1/fleet-daemon-lib.sh"; shift; eval "$@"' _ "$WORK/bin" "$@"; }
reset() { : > "$S/loaded"; : > "$S/bootouts"; : > "$S/list"; rm -f "$S/captured-probe.sh"
          rm -f "$G/launchd-probe.verdict"; rm -rf "$G/launchd-probe.lock"; return 0; }
# `shift` rather than "${@:2}": on macOS bash 3.2 a slice of an empty tail is one
# of the unbound-variable mines issue #703 is about, and this is a plain `bin/`
# script that bash32-array-selftest.sh scans.
probe() { _sp="$1"; shift
          FAKE_SPAWNS="$_sp" bash "$WORK/bin/fleet-launchd-probe.sh" --window 1 --interval 10 "$@" 2>>"$WORK/probe.err"; }

# ============================================================================
# A. the three verdicts
# ============================================================================
reset
out=$(probe 3); rc=$?
[ "$rc" = 0 ] || fail "A: 3 spawns in the window must exit 0 (got $rc)" "$out"; ok
has "ok" "$out" "A: 3 spawns must read \`ok\`"
[ "$(lib "fleet_daemon_probe_verdict '$WORK'")" = ok ] || fail "A: \`ok\` was not cached"; ok

reset
out=$(probe 1); rc=$?
[ "$rc" = 1 ] || fail "A: exactly one spawn is NOT a healthy domain — expected exit 1, got $rc" "$out"; ok
has "no-interval" "$out" "A: one spawn (RunAtLoad only) must read \`no-interval\`, not \`ok\` — a domain that runs a job once at load and never on its interval is the pended-scheduling shape"
[ "$(lib "fleet_daemon_probe_verdict '$WORK'")" = no-interval ] || fail "A: \`no-interval\` was not cached"; ok

reset
out=$(probe 0); rc=$?
[ "$rc" = 1 ] || fail "A: zero spawns must exit 1 (got $rc)" "$out"; ok
has "no-spawn" "$out" "A: zero spawns must read \`no-spawn\`"
has "machine state, not fleet state" "$out" "A: the no-spawn line must say whose problem this is — that sentence IS the fix for #711"
has "reboot" "$out" "A: the no-spawn line must name the remedy the operator actually has"
[ "$(lib "fleet_daemon_probe_verdict '$WORK'")" = no-spawn ] || fail "A: \`no-spawn\` was not cached"; ok

# ============================================================================
# B. unknown is never a verdict, and never overwrites one
# ============================================================================
# The cache holds `no-spawn` from A. A probe that cannot measure must leave it
# exactly as it found it: silently downgrading a real finding to a stale-but-
# plausible one is how an operator ends up trusting an answer nobody measured.
before=$(lib "fleet_daemon_probe_line '$WORK'")
out=$(FAKE_BOOTSTRAP_RC=1 FAKE_SPAWNS=5 bash "$WORK/bin/fleet-launchd-probe.sh" --window 1 --interval 10 2>>"$WORK/probe.err"); rc=$?
[ "$rc" = 3 ] || fail "B: a probe that would not bootstrap must exit 3 (unknown), got $rc" "$out"; ok
has "unknown" "$out" "B: a failed bootstrap must report \`unknown\`"
[ "$(lib "fleet_daemon_probe_line '$WORK'")" = "$before" ] \
  || fail "B: an UNMEASURED probe overwrote the cached verdict"; ok

# No launchctl at all ⇒ unknown, not a guess. PATH is narrowed to a directory
# holding ONLY the few tools the script touches before that check — stripping it
# to /usr/bin:/bin would not do it, because the real launchctl lives in /bin and
# the probe would then bootstrap an agent into the OPERATOR'S live domain.
mkdir -p "$WORK/minpath"
for t in bash dirname date mkdir id; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$WORK/minpath/$t"
done
out=$(PATH="$WORK/minpath" FAKE_SPAWNS=5 bash "$WORK/bin/fleet-launchd-probe.sh" --window 1 2>&1); rc=$?
[ "$rc" = 3 ] || fail "B: no launchctl on PATH must be \`unknown\` (exit 3), got $rc" "$out"; ok
has "unknown" "$out" "B: a host without launchctl must say \`unknown\`, never assume the domain is fine"

# The master switch refuses to probe — and still does not claim a verdict.
out=$(FLEET_LAUNCHD_PROBE=0 bash "$WORK/bin/fleet-launchd-probe.sh" --window 1 2>&1); rc=$?
[ "$rc" = 3 ] || fail "B: FLEET_LAUNCHD_PROBE=0 must be \`unknown\` (exit 3), got $rc" "$out"; ok

# --cached reads without probing; an expired TTL is "no answer", not "ok".
reset; probe 0 >/dev/null
out=$(bash "$WORK/bin/fleet-launchd-probe.sh" --cached 900 2>&1); rc=$?
[ "$rc" = 1 ] || fail "B: --cached must replay the cached no-spawn (exit 1), got $rc" "$out"; ok
has "cached" "$out" "B: --cached must say the answer is cached, not freshly measured"
sleep 2
out=$(bash "$WORK/bin/fleet-launchd-probe.sh" --cached 1 2>&1); rc=$?
[ "$rc" = 4 ] || fail "B: an EXPIRED cache must exit 4 (no usable answer), got $rc" "$out"; ok

# ============================================================================
# C. the agent never outlives the probe
# ============================================================================
reset; probe 2 >/dev/null
grep -q "spawnprobe" "$S/bootouts" 2>/dev/null \
  || fail "C: the probe did not boot its own agent out" "$(cat "$S/bootouts" 2>/dev/null)"; ok
left=$(ls -d "$WORK"/.claude-fleet-spawnprobe.* 2>/dev/null)
[ -z "$left" ] || fail "C: the probe left its work dir behind: $left"; ok

# The DEADLINE lives in the job, not in the parent's trap (#697). Take the program
# launchd was actually handed, move its deadline into the past, run it: it must
# boot ITSELF out. A parent-only trap cannot survive a SIGKILLed parent, and what
# leaks here is a registered agent that would tick for ever.
[ -f "$S/captured-probe.sh" ] || fail "C: the fake launchctl captured no probe program"; ok
sed 's/-ge [0-9][0-9]*/-ge 0/' "$S/captured-probe.sh" > "$WORK/expired-probe.sh"
: > "$S/bootouts"
/bin/sh "$WORK/expired-probe.sh" >/dev/null 2>&1
grep -q "spawnprobe" "$S/bootouts" 2>/dev/null \
  || fail "C: a probe job past its own deadline did not boot itself out — the cleanup is back in the parent's trap, which is the #697 failure shape"; ok

# A leftover from a killed probe is swept by the next one.
reset
printf -- '-\t0\tcom.claude-fleet.spawnprobe.99999\n' > "$S/list"
probe 2 >/dev/null
grep -q "spawnprobe.99999" "$S/bootouts" 2>/dev/null \
  || fail "C: a leftover probe agent was not swept" "$(cat "$S/bootouts" 2>/dev/null)"; ok

# ============================================================================
# D. the cooldown scales with the unit's own interval
# ============================================================================
[ "$(lib 'fleet_daemon_kick_cooldown issue-bridge')" = 60 ] \
  || fail "D: a 15s unit must floor at 60s, not sit on a flat 600s"; ok
[ "$(lib 'fleet_daemon_kick_cooldown collect')" = 180 ] \
  || fail "D: a 60s unit must be 3×60"; ok
[ "$(lib 'fleet_daemon_kick_cooldown worktree-autoclean')" = 10800 ] \
  || fail "D: a 3600s unit must be 3×3600"; ok
# THE INVARIANT, not the numbers: the cooldown must never be the binding limit.
# The staleness threshold is already per-unit and already tuned; if the cooldown
# creeps above it, the cooldown silently becomes the daemon's period again — which
# is exactly what #711 measured (issue-bridge: 15s interval, 600s in practice).
for u in $(lib 'fleet_daemon_unit_names'); do
  c=$(lib "fleet_daemon_kick_cooldown $u"); t=$(lib "fleet_daemon_stale_secs $u")
  [ "$c" -le "$t" ] \
    || fail "D: $u cooldown ${c}s EXCEEDS its ${t}s staleness threshold — the cooldown is the rate limit again"
  ok
done
# The knobs still work, and the absolute one still wins outright.
[ "$(FLEET_DAEMON_KICK_COOLDOWN=600 lib 'fleet_daemon_kick_cooldown issue-bridge')" = 600 ] \
  || fail "D: FLEET_DAEMON_KICK_COOLDOWN must still override absolutely"; ok
[ "$(FLEET_DAEMON_KICK_COOLDOWN_ISSUE_BRIDGE=45 lib 'fleet_daemon_kick_cooldown issue-bridge')" = 45 ] \
  || fail "D: the per-unit override (dash → underscore) stopped working"; ok
[ "$(FLEET_COLLECT_KICK_COOLDOWN=900 lib 'fleet_daemon_kick_cooldown collect')" = 900 ] \
  || fail "D: #638's FLEET_COLLECT_KICK_COOLDOWN must still govern collect"; ok
[ "$(FLEET_COLLECT_KICK_COOLDOWN=900 lib 'fleet_daemon_kick_cooldown cleanup')" = 180 ] \
  || fail "D: collect's legacy knob must not leak onto other units"; ok
[ "$(FLEET_DAEMON_KICK_COOLDOWN_MULT=10 lib 'fleet_daemon_kick_cooldown collect')" = 600 ] \
  || fail "D: the multiplier knob does not scale"; ok
[ "$(FLEET_DAEMON_KICK_COOLDOWN_MULT=abc lib 'fleet_daemon_kick_cooldown collect')" = 180 ] \
  || fail "D: a garbage multiplier must fall back to the default, never to 0 (no rate limit at all)"; ok

# ============================================================================
# E. fleet-doctor: ONE machine line instead of N unit lines
# ============================================================================
# A stub probe in place of the real one, so the doctor's decision is what is under
# test and the 40-second measurement is not. It records that it was called.
cat > "$WORK/bin/fleet-launchd-probe.sh" <<STUB
#!/bin/bash
printf 'called\n' >> "$WORK/probe-calls"
[ -n "\${STUB_VERDICT:-}" ] && printf '%s\t%s\t0\t40\t15\t0\n' "\$(date +%s)" "\$STUB_VERDICT" > "$G/launchd-probe.verdict"
exit 0
STUB
chmod +x "$WORK/bin/fleet-launchd-probe.sh"

UNITS="$(lib 'fleet_daemon_unit_names')"
stale_all() { for u in $UNITS; do printf '%s\n' "$(( $(date +%s) - 99999 ))" > "$G/$u.tick"; done; }
fresh_all() { for u in $UNITS; do date +%s > "$G/$u.tick"; done; }
nokicks()   { for u in $UNITS; do rm -f "$G/$u.kick.ts"; done; }
kicked_all(){ for u in $UNITS; do printf '%s\n' "$(( $(date +%s) - ${1:-110} ))" > "$G/$u.kick.ts"; done; }
run_doctor() {
  : > "$WORK/stderr"; : > "$WORK/probe-calls"
  PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
  FLEET_CONF_DIR="$WORK/conf" FLEET_LIVE_ROOT="$WORK" \
    sh "$WORK/bin/fleet-doctor.sh" 2>"$WORK/stderr"
}
warns_of() { printf '%s\n' "$1" | grep -acE "^[[:space:]]+WARN[[:space:]]+$2([[:space:]]|\$)" | head -1; }
survived() { printf '%s\n' "$1" | grep -qaE '^[[:space:]]+(PASS|WARN)[[:space:]]+perl'; }

# E1. every unit stalled + the probe says the domain spawns nothing ⇒ ONE line.
rm -f "$G/launchd-probe.verdict"; nokicks; stale_all
out=$(STUB_VERDICT=no-spawn run_doctor)
[ "$(warns_of "$out" launchd)" = 1 ] \
  || fail "E1: expected exactly ONE \`WARN launchd\` line" "$out"; ok
[ "$(warns_of "$out" daemons)" = 0 ] \
  || fail "E1: the per-unit \`WARN daemons\` lines must be HELD BACK when the domain is the cause — printing all ten is the #711 misdiagnosis" "$out"; ok
has "issue-bridge" "$out" "E1: the collapsed line must still NAME the stalled units"
has "MACHINE state, not fleet state" "$out" "E1: the collapsed line must say whose problem this is"
has "reboot" "$out" "E1: the collapsed line must name the remedy"
[ -s "$WORK/probe-calls" ] || fail "E1: the doctor never ran the probe on a domain-shaped stall"; ok
survived "$out" || fail "E1: the doctor did not reach its last check — the daemons section aborted the run" "$out"; ok
[ ! -s "$WORK/stderr" ] || fail "E1: the doctor printed to stderr" "$(cat "$WORK/stderr")"; ok

# E2. same stall, but the probe says the DOMAIN is fine ⇒ the per-unit lines are
#     the right answer and must come back.
rm -f "$G/launchd-probe.verdict"; nokicks; stale_all
out=$(STUB_VERDICT=ok run_doctor)
[ "$(warns_of "$out" launchd)" = 0 ] \
  || fail "E2: a healthy domain must not produce a \`launchd\` warning" "$out"; ok
n=$(warns_of "$out" daemons)
[ "$n" -ge 9 ] \
  || fail "E2: with the domain ruled out, every stalled unit must be reported (got $n)" "$out"; ok

# E3. nobody could measure ⇒ per-unit lines PLUS a pointer at the probe. An
#     unmeasured domain must never read as a healthy one.
rm -f "$G/launchd-probe.verdict"; nokicks; stale_all
out=$(run_doctor)      # stub writes no verdict
[ "$(warns_of "$out" launchd)" = 0 ] || fail "E3: an unmeasured domain must not be WARNed about as a fact" "$out"; ok
[ "$(warns_of "$out" daemons)" -ge 9 ] || fail "E3: the per-unit detail must survive an unmeasured probe" "$out"; ok
has "fleet-launchd-probe.sh" "$out" "E3: an unmeasured domain-shaped stall must point at the probe"

# E4. ONE stalled unit is that unit's problem: no probe, no domain line, no hint.
nokicks; fresh_all; printf '%s\n' "$(( $(date +%s) - 99999 ))" > "$G/cleanup.tick"
out=$(STUB_VERDICT=no-spawn run_doctor)
[ "$(warns_of "$out" launchd)" = 0 ] || fail "E4: a single stalled unit is not a domain stall" "$out"; ok
[ "$(warns_of "$out" daemons)" = 1 ] || fail "E4: the one stalled unit must still be reported" "$out"; ok
[ ! -s "$WORK/probe-calls" ] || fail "E4: the doctor spent 40s probing over ONE stalled unit"; ok

# E5. a healthy host never probes at all.
nokicks; fresh_all
out=$(STUB_VERDICT=no-spawn run_doctor)
[ ! -s "$WORK/probe-calls" ] || fail "E5: the doctor probed a host with nothing stale"; ok
[ "$(warns_of "$out" daemons)" = 0 ] || fail "E5: nothing stale must produce no daemon warning" "$out"; ok

# E6. the accounting. The per-unit warns are emitted from a loop; fed by a PIPE
#     instead of a here-doc that loop runs in a subshell, where every line prints
#     and $warns dies with the subshell — nine warnings on screen under a cheerful
#     "all good." So the summary must agree with what was printed.
rm -f "$G/launchd-probe.verdict"; nokicks; stale_all
out=$(STUB_VERDICT=ok run_doctor)
printed=$(printf '%s\n' "$out" | grep -acE '^[[:space:]]+WARN[[:space:]]' | head -1)
claimed=$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\) warn .*/\1/p;s/^[0-9][0-9]* fail[^,]*, \([0-9][0-9]*\) warn.*/\1/p' | tail -1)
[ -n "$claimed" ] && [ "$printed" = "$claimed" ] \
  || fail "E6: the doctor printed $printed WARN line(s) but its summary claims '${claimed:-none}'" "$out"; ok

# E7. THE SIGNATURE THAT SURVIVES A WORKING SELF-HEAL. This is the state the real
#     wedged host is in most of the time: the kicks land, so almost nothing reads
#     stale — and the fleet is still crippled, because every daemon now runs once
#     per self-heal cooldown instead of once per StartInterval. A doctor keyed
#     only on "how many are overdue right now" goes QUIET here, which is worse
#     than the nine-line misdiagnosis #711 was filed about: at least that one was
#     on screen.
rm -f "$G/launchd-probe.verdict"; fresh_all; kicked_all 110
out=$(STUB_VERDICT=no-spawn run_doctor)
[ -s "$WORK/probe-calls" ] \
  || fail "E7: 10 units kicked inside the hour is the domain signature — the doctor did not probe" "$out"; ok
[ "$(warns_of "$out" launchd)" = 1 ] \
  || fail "E7: a wedged domain masked by a working self-heal must still produce the machine line" "$out"; ok
has "self-heal cooldown" "$out" "E7: the line must say WHY nothing looks stale — the daemons are running at the cooldown, not their interval"
hasnt "PASS  daemons" "$out" "E7: \"10 units ticking inside 5x their StartInterval\" is true and misleading while the domain is down — it must not print under the machine line"
survived "$out" || fail "E7: the doctor did not reach its last check" "$out"; ok
[ ! -s "$WORK/stderr" ] || fail "E7: the doctor printed to stderr" "$(cat "$WORK/stderr")"; ok

# E8. …and one old kick is not a signature. A single self-healed unit is ordinary.
rm -f "$G/launchd-probe.verdict"; nokicks; fresh_all
printf '%s\n' "$(( $(date +%s) - 110 ))" > "$G/cleanup.kick.ts"
out=$(STUB_VERDICT=no-spawn run_doctor)
[ ! -s "$WORK/probe-calls" ] || fail "E8: one recent kick must not cost 40s of probing" "$out"; ok
[ "$(warns_of "$out" launchd)" = 0 ] || fail "E8: one recent kick is not a domain stall" "$out"; ok
# …nor is a kick from yesterday, on every unit.
kicked_all 99999
out=$(STUB_VERDICT=no-spawn run_doctor)
[ ! -s "$WORK/probe-calls" ] || fail "E8: kicks older than the window must not trigger a probe" "$out"; ok

printf 'selftest PASS: %s assertions (probe · unknown · cleanup · cooldown · doctor collapse · healed-together)\n' "$CHECKS"
exit 0
