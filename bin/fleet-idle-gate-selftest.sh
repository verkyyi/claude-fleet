#!/bin/bash
# fleet-idle-gate-selftest.sh — the daemon IDLE GATE (issue #1077). A login with
# no live fleet used to run collect + quotawatch in full every 60s and turn the
# spinner every 2s, for nobody. Drives the REAL bin/fleet-daemon-lib.sh on a
# pinned clock, then the real collector / quotawatch / spinner snippets in a
# sandbox (fake tmux on PATH) — no launchd, no tmux server, no network.
#
#   1. grace    — a fresh idle spell works every tick for FLEET_DAEMON_IDLE_AFTER.
#   2. cadence  — past the grace, of N consecutive zero-socket ticks only the 1st
#                 and the 6th work (60s ticks, 300s gate) — and an hour of ticks
#                 does ≤ 12 real ones.
#   3. live     — any live socket works at once and forgets the spell.
#   4. wake     — a spawn's wake marker works at once and restarts the grace.
#   5. off      — FLEET_DAEMON_IDLE_AFTER=0 is the old behaviour: every tick works.
#   6. open     — no socket enumerator (fleet-lib not sourced) ⇒ work.
#   7. log      — one `fleet-idle:` line per spell, naming the off switch.
#   8. collect  — the real collector skips a gated tick before its pid guard,
#                 still stamps its scheduling tick, and works with a live socket
#                 or in targeted --issues mode.
#   9. quota    — the real quotawatch skips a gated tick before its lock.
#  10. spinner  — idle_nap: 2s in the grace, the 60s nap past it, 2s again after
#                 a wake; the no-fleet branch sleeps "$NAP".
#  11. wakers   — fleet-up and the spawn choke points all touch the wake marker.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-daemon-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/idle-gate-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK" FLEET_LIVE_ROOT="$WORK/nonexistent"
unset FLEET_DAEMON_IDLE_AFTER FLEET_DAEMON_ROOT
G="$WORK/.claude-dash/global"
CHECKS=0
ok()   { CHECKS=$((CHECKS + 1)); }
fail() { printf 'selftest FAIL: %s\n' "$*" >&2; exit 1; }

# gate <epoch> <live> — one tick of the gate at a pinned clock; prints W or S.
gate() {
  sh -c '. "$1"; _FLEET_NOW=$2; _FLEET_NOW_PID=$$; _FLEET_NOW_S0=; if fleet_idle_gate collect "" "$3" 2>>"$4"; then echo W; else echo S; fi' \
    _ "$LIB" "$1" "$2" "$WORK/gate.err"
}
# ticks <start> <count> [step] — a run of zero-socket ticks; prints e.g. WSSSSW.
ticks() { local t="$1" n="$2" st="${3:-60}" out=''
  while [ "$n" -gt 0 ]; do n=$((n - 1)); out="$out$(gate "$t" 0)"; t=$((t + st)); done; printf '%s' "$out"; }
wake_at() { sh -c '. "$1"; _FLEET_NOW=$2; _FLEET_NOW_PID=$$; _FLEET_NOW_S0=; fleet_daemon_wake ""' _ "$LIB" "$1"; }
reset() { rm -f "$G"/*.idle "$G/wake" "$WORK/gate.err"; }

T0=1000000
# 1+2. grace, then the cadence: ticks 1-5 (t0..t0+240) are the grace; from the
# 6th on the gate holds, so the next working tick is the one IDLE_AFTER after the
# last worked — tick 10 — and from there 1 in 5.
reset
seq_=$(ticks $T0 20)
[ "$seq_" = WWWWWSSSSWSSSSWSSSSW ] || fail "grace+cadence: expected WWWWWSSSSWSSSSWSSSSW, got $seq_"; ok
# The issue's own statement: of N consecutive zero-socket ticks past the grace,
# only the 1st and the 6th work.
seg=${seq_:9:6}
[ "$seg" = WSSSSW ] || fail "cadence: ticks 10-15 should be WSSSSW (1st and 6th), got $seg"; ok
# An hour of 60s ticks, well into the spell: ≤ 12 real ones (the metric).
reset; ticks $T0 5 >/dev/null
hour=$(ticks $((T0 + 300)) 60)
nw=$(printf '%s' "$hour" | tr -cd W | wc -c | tr -d ' ')
[ "$nw" -le 12 ] || fail "an idle hour must do ≤ 12 working ticks, did $nw ($hour)"; ok
[ "$nw" -ge 11 ] || fail "an idle hour must still work ~every 300s, did only $nw"; ok
# jittery launchd (61s) keeps the bound
reset; ticks $T0 5 61 >/dev/null
nw=$(ticks $((T0 + 305)) 59 61 | tr -cd W | wc -c | tr -d ' ')
[ "$nw" -le 12 ] || fail "61s ticks: ≤ 12 working in an hour, did $nw"; ok
# the counters in the idle file say what happened
read -r _s _l _w _k < "$G/collect.idle"
[ "$_w" -ge 1 ] && [ "$_k" -ge 1 ] || fail "idle file should count worked + skipped, got: $(cat "$G/collect.idle")"; ok

# 3. live socket: works at once, spell forgotten, next zero tick starts a new grace
reset; ticks $T0 12 >/dev/null
[ "$(gate $((T0 + 720)) 0)" = S ] || fail "setup: deep in the spell a tick is skipped"; ok
[ "$(gate $((T0 + 780)) 2)" = W ] || fail "live: a live socket works immediately"; ok
[ ! -f "$G/collect.idle" ] || fail "live: the idle file is removed once a fleet is live"; ok
[ "$(ticks $((T0 + 840)) 5)" = WWWWW ] || fail "live: after a live tick a new spell starts with its grace"; ok

# 4. wake marker
reset; ticks $T0 12 >/dev/null
[ "$(gate $((T0 + 720)) 0)" = S ] || fail "setup: gated before the wake"; ok
wake_at $((T0 + 730))
[ -f "$G/wake" ] || fail "wake: fleet_daemon_wake writes <state>/wake"; ok
[ "$(gate $((T0 + 780)) 0)" = W ] || fail "wake: the tick after a spawn works at once"; ok
[ "$(ticks $((T0 + 840)) 4)" = WWWW ] || fail "wake: the grace window restarts after a wake"; ok
# a wake from BEFORE the spell began does not hold the gate open
reset; wake_at $((T0 - 10))
[ "$(ticks $T0 7)" = WWWWWSS ] || fail "wake: a stale wake (older than the spell) is ignored"; ok

# 5. off
reset
seq_=$(FLEET_DAEMON_IDLE_AFTER=0 ticks $T0 12)
[ "$seq_" = WWWWWWWWWWWW ] || fail "off: IDLE_AFTER=0 works every tick, got $seq_"; ok
[ ! -f "$G/collect.idle" ] || fail "off: IDLE_AFTER=0 writes no idle state"; ok
reset
seq_=$(FLEET_DAEMON_IDLE_AFTER=junk ticks $T0 7)
[ "$seq_" = WWWWWSS ] || fail "a malformed knob falls back to the 300s default, got $seq_"; ok
reset
seq_=$(FLEET_DAEMON_IDLE_AFTER=120 ticks $T0 8)
[ "$seq_" = WWSWSWSW ] || fail "IDLE_AFTER=120 tunes both the grace and the cadence, got $seq_"; ok

# 6. fail open: no live count passed and no fleet_sockets defined
reset; ticks $T0 12 >/dev/null
r=$(sh -c '. "$1"; if fleet_idle_gate collect ""; then echo W; else echo S; fi' _ "$LIB")
[ "$r" = W ] || fail "open: without a socket enumerator the gate works"; ok
# ... and with an enumerator that sees nothing, it gates like any zero count
r=$(sh -c '. "$1"; fleet_sockets() { :; }; _FLEET_NOW=$2; _FLEET_NOW_PID=$$; _FLEET_NOW_S0=; if fleet_idle_gate collect ""; then echo W; else echo S; fi' _ "$LIB" $((T0 + 740)) 2>/dev/null)
[ "$r" = S ] || fail "enumerator: an empty fleet_sockets counts as zero live"; ok
r=$(sh -c '. "$1"; fleet_sockets() { echo a; }; _FLEET_NOW=$2; _FLEET_NOW_PID=$$; _FLEET_NOW_S0=; if fleet_idle_gate collect ""; then echo W; else echo S; fi' _ "$LIB" $((T0 + 800)))
[ "$r" = W ] || fail "enumerator: a live fleet_sockets opens the gate"; ok
# a probe that hit its timebox found a (wedged) server: that is live, so work
r=$(sh -c '. "$1"; fleet_sockets() { :; }; fleet_timebox() { return 124; }; _FLEET_NOW=$2; _FLEET_NOW_PID=$$; _FLEET_NOW_S0=; if fleet_idle_gate collect ""; then echo W; else echo S; fi' _ "$LIB" $((T0 + 1500)) 2>/dev/null)
[ "$r" = W ] || fail "timebox: a timed-out socket probe counts as live"; ok

# 7. one log line per spell
reset; ticks $T0 15 >/dev/null
n=$(grep -c '^fleet-idle: collect' "$WORK/gate.err")
[ "$n" = 1 ] || fail "log: one fleet-idle line per spell, got $n"; ok
grep -q 'FLEET_DAEMON_IDLE_AFTER=0' "$WORK/gate.err" || fail "log: the line names the off switch"; ok

# --- 8/9. the real collector and quotawatch in a sandbox -----------------------
SB="$WORK/sb"; mkdir -p "$SB/bin" "$SB/fakepath" "$SB/conf/fleets/sessA" "$SB/tmp"
for f in tmux-dash-collect.sh fleet-quotawatch.sh fleet-lib.sh usage-lib.sh fleet-daemon-lib.sh fleet-account.sh; do
  [ -f "$BIN/$f" ] && cp "$BIN/$f" "$SB/bin/"
done
printf 'FLEET_REPO="acme/widgets"\n' > "$SB/conf/fleets/sessA/conf"
mkdir -p "$SB/accounts"; printf 'tok\n' > "$SB/accounts/a"
cat > "$SB/fakepath/tmux" <<'FAKE'
#!/bin/sh
[ "${1:-}" = -L ] && shift 2
case "${1:-}" in has-session) [ "${FAKE_LIVE:-0}" = 1 ] ;; *) exit 0 ;; esac
FAKE
printf '#!/bin/sh\necho "$*" >> "$FAKE_CALLS"\nexit 0\n' > "$SB/fakepath/gh"
printf '#!/bin/sh\necho "$*" >> "$FAKE_CALLS"\nprintf "{\\"verdict\\":\\"go\\",\\"accounts\\":[]}"\n' > "$SB/fakepath/ccquota"
chmod +x "$SB/fakepath/"* "$SB/bin/"*.sh
SG=$(TMPDIR="$SB/tmp" FLEET_LIVE_ROOT="$SB/nonexistent" sh -c '. "$1"; fleet_daemon_state_dir "$2"' _ "$SB/bin/fleet-daemon-lib.sh" "$SB/bin/..")
mkdir -p "$SG"
run() {  # <script> [args] — env: FAKE_LIVE
  PATH="$SB/fakepath:$PATH" TMPDIR="$SB/tmp" HOME="$SB" FLEET_SKIP_GLOBAL_CONF=1 FLEET_LIVE_ROOT="$SB/nonexistent" \
  FLEET_CONF_DIR="$SB/conf" FLEET_ACCOUNTS_DIR="$SB/accounts" CCQUOTA_HUB_URL="http://hub.test:8787" \
  FLEET_REPO="" FLEET_REPOS="" FLEET_NOTIFY_CMD="" GH_TTL=0 FAKE_CALLS="$SB/calls" \
  bash "$SB/bin/$1" "${@:2}" 2>>"$SB/err"
}
deep_idle() {  # <unit> — an idle spell 20 min old whose last working tick was 1 min ago
  local n; n=$(date +%s); printf '%s %s 1 0\n' $((n - 1200)) $((n - 60)) > "$SG/$1.idle"; }
HB="$SB/tmp/.claude-dash/global/collect.heartbeat"

deep_idle collect; rm -f "$HB" "$SG/collect.tick"
FAKE_LIVE=0 run tmux-dash-collect.sh; rc=$?
[ "$rc" = 0 ] || fail "collect: a gated tick exits 0 (got $rc): $(tail -3 "$SB/err")"; ok
[ ! -f "$HB" ] || fail "collect: a gated tick must not run the tick (heartbeat written)"; ok
[ -f "$SG/collect.tick" ] || fail "collect: a gated tick still stamps its scheduling tick (#639)"; ok
[ ! -f "$SB/tmp/.claude-dash/global/collect.pid" ] || fail "collect: the gate sits before the pid guard"; ok
grep -q '^fleet-idle: collect' "$SB/err" || fail "collect: the first gated tick logs the fleet-idle line"; ok

deep_idle collect; rm -f "$HB"
FAKE_LIVE=1 run tmux-dash-collect.sh
[ -f "$HB" ] || fail "collect: with a live socket the tick runs: $(tail -3 "$SB/err")"; ok
[ ! -f "$SG/collect.idle" ] || fail "collect: a live socket ends the spell"; ok

deep_idle collect; rm -f "$HB" "$SB/calls"
FAKE_LIVE=0 run tmux-dash-collect.sh --issues acme/widgets
grep -q '^issue list' "$SB/calls" 2>/dev/null || fail "collect: --issues (the webhook kick) is never gated"; ok

deep_idle collect; rm -f "$HB"
FAKE_LIVE=0 FLEET_DAEMON_IDLE_AFTER=0 run tmux-dash-collect.sh
[ -f "$HB" ] || fail "collect: IDLE_AFTER=0 runs every tick"; ok

QHB="$SB/tmp/.claude-dash/global/quotawatch.heartbeat"
deep_idle quotawatch; rm -f "$QHB" "$SB/calls"
FAKE_LIVE=0 run fleet-quotawatch.sh; rc=$?
[ "$rc" = 0 ] || fail "quotawatch: a gated tick exits 0 (got $rc)"; ok
[ ! -f "$QHB" ] && [ ! -s "$SB/calls" ] || fail "quotawatch: a gated tick must not fetch or sweep"; ok
[ -f "$SG/quotawatch.tick" ] || fail "quotawatch: a gated tick still stamps its scheduling tick"; ok
deep_idle quotawatch; rm -f "$QHB"
FAKE_LIVE=0 run fleet-quotawatch.sh --caller collect
[ -f "$SG/quotawatch.idle" ] && [ "$(cut -d' ' -f4 "$SG/quotawatch.idle")" = 0 ] \
  || fail "quotawatch: --caller collect is not gated here (the collector gates itself)"; ok
touch "$SG/wake"; date +%s > "$SG/wake"; deep_idle quotawatch; rm -f "$QHB"
FAKE_LIVE=0 run fleet-quotawatch.sh
[ -f "$QHB" ] || fail "quotawatch: a fresh wake marker opens the gate: $(tail -3 "$SB/err")"; ok

# --- 10. the spinner's idle nap ------------------------------------------------
SP="$BIN/tmux-spinner.sh"
snip=$(sed -n '/^# --- idle nap (issue #1077)/,/^hb_stamp   # once at startup/p' "$SP" | sed '$d')
[ -n "$snip" ] || fail "spinner: the idle-nap block is missing"; ok
grep -q 'if \[ -z "\$SOCKETS" \]; then hb_stamp; idle_nap; sleep "\$NAP";' "$SP" \
  || fail "spinner: the no-fleet branch must sleep the idle nap"; ok
nap() {  # <now> [idle_after] — NAP after a sequence set up by the caller in $SPRE
  BIN="$BIN" TMPDIR="$WORK" FLEET_DAEMON_IDLE_AFTER="${2:-300}" sh -c "$snip
$SPRE
_now=\$1; idle_nap; printf '%s' \"\$NAP\"" _ "$1"
}
# the spinner's state dir follows ITS install root (a checkout ⇒ a private dir)
SW="$(sh -c '. "$1"; fleet_daemon_state_dir "$2"' _ "$LIB" "$BIN/..")/wake"
mkdir -p "$(dirname "$SW")"; rm -f "$SW"
SPRE='IDLE_T0=1000'
[ "$(nap 1100)" = 2 ] || fail "spinner: 2s inside the grace"; ok
[ "$(nap 1300)" = 60 ] || fail "spinner: the 60s nap past the grace"; ok
[ "$(nap 1300 0)" = 2 ] || fail "spinner: IDLE_AFTER=0 never naps"; ok
printf '1250\n' > "$SW"
[ "$(nap 1300)" = 2 ] || fail "spinner: a wake inside the spell restarts the grace"; ok
printf '900\n' > "$SW"
[ "$(nap 1300)" = 60 ] || fail "spinner: a wake older than the spell is ignored"; ok
grep -q "IDLE_T0=''   # a live fleet ends the idle spell" "$SP" || fail "spinner: a live fleet must reset the spell"; ok
sh -n "$SP" || fail "spinner: syntax"; ok

# --- 11. who wakes -------------------------------------------------------------
for f in bin/fleet-up.sh bin/dash-issue-session.sh bin/dash-raw-session.sh shell/cw.zsh; do
  grep -q 'fleet_daemon_wake' "$BIN/../$f" || fail "wakers: $f must touch the wake marker"; ok
done

printf 'selftest PASS: %s assertions (grace · cadence · live · wake · off · open · log · collect · quota · spinner · wakers)\n' "$CHECKS"
exit 0
