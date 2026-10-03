#!/bin/bash
# fleet-admit-selftest.sh — the machine-admission gate (issue #1090, EPIC #1291 C4).
# Every path that opens a new session asks fleet_session_cap_ok; since #1090 it
# also asks fleet_machine_admit whether the MACHINE has room (memory pressure,
# avail%, load/core). Hermetic: both probes are stubbed (FLEET_MEM_PROBE_CMD,
# FLEET_LOAD_PROBE_CMD), git/gh/tmux are faked on PATH — no real memory bomb, no
# tmux server.
#
#   A. fleet_machine_admit: each reading holds on its own, with a readable reason
#      (full + --short); normal readings admit; an unreadable probe admits;
#      every knob (off / 0 / critical) and FLEET_ADMIT=0.
#   B. fleet_session_cap_ok: tight → refuses with the memory reason; FLEET_ADMIT=0
#      → byte-identical to pre-#1090 (empty stdout, rc 0; the at-capacity message
#      unchanged and still first).
#   C. dash-issue-session.sh under a tight stub → exit RC_CAP (2), the reason on
#      stderr, NO window; FLEET_ADMIT=0 on the same stub spawns.
#   D. retry: the same spawn after the reading drops succeeds (what dispatch's
#      next tick does — it already treats rc 2 as "stop this tick, retry").
#   E. continuation paths never pass the gate: crash restore, handoff.
set -uo pipefail
unset FLEET_ADMIT FLEET_ADMIT_MEM_FREE_PCT FLEET_ADMIT_PRESSURE FLEET_ADMIT_LOAD_PER_CORE \
      FLEET_LOADGEN_LOAD_PER_CORE FLEET_MEM_PROBE_CMD FLEET_LOAD_PROBE_CMD 2>/dev/null

BIN="$(cd "$(dirname "$0")" && pwd)"
SPAWN="$BIN/dash-issue-session.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/admit-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

# admit <mem-stub> <load-stub> [VAR=val …] → "<rc>|<stdout>"
admit() {
  local m="$1" l="$2"; shift 2
  env "$@" FLEET_MEM_PROBE_CMD="$m" FLEET_LOAD_PROBE_CMD="$l" TMPDIR="$WORK/t" \
    bash -c 'source "$1/fleet-lib.sh"; out=$(fleet_machine_admit ${2:+"$2"}); printf "%s|%s" "$?" "$out"' _ "$BIN" "${SHORT:-}"
}

# ===== A: fleet_machine_admit ==================================================
r=$(admit 'echo 1 66 5 6' 'echo 0.50');            [ "$r" = "0|" ] || fail "A normal readings must admit silently (got '$r')"
r=$(admit 'echo 4 5 97 0' 'echo 0.50')
case "$r" in 1\|*内存紧张*critical*5%\ free*) ;; *) fail "A critical pressure must hold with a readable reason (got '$r')" ;; esac
r=$(admit 'echo 2 40 5 0' 'echo 0.50');            case "$r" in 1\|*pressure\ warn*) ;; *) fail "A warn pressure holds by default (got '$r')" ;; esac
r=$(admit 'echo 1 9 5 0' 'echo 0.50');             case "$r" in 1\|*9%\ free,\ floor\ 15%*) ;; *) fail "A avail% under the floor holds (got '$r')" ;; esac
r=$(admit 'echo 1 66 5 6' 'echo 3.10')
case "$r" in 1\|*负载过高*3.10/core*FLEET_ADMIT_LOAD_PER_CORE=2*) ;; *) fail "A load over the default 2/core holds (got '$r')" ;; esac
r=$(admit 'echo 1 66 5 6' 'echo 1.30');            [ "$r" = "0|" ] || fail "A 1.3/core (a normal busy afternoon) must admit (got '$r')"
r=$(admit 'echo 1 66 5 6' 'echo 1.30' FLEET_LOADGEN_LOAD_PER_CORE=1)
case "$r" in 1\|*FLEET_ADMIT_LOAD_PER_CORE=1*) ;; *) fail "A load bound defaults to FLEET_LOADGEN_LOAD_PER_CORE when set (got '$r')" ;; esac
r=$(SHORT=--short admit 'echo 4 5 97 0' 'echo 0.5'); [ "$r" = "1|暂停开新：内存紧张" ] || fail "A --short memory tag (got '$r')"
r=$(SHORT=--short admit 'echo 1 66 5 6' 'echo 9');   [ "$r" = "1|暂停开新：负载过高" ] || fail "A --short load tag (got '$r')"
r=$(admit 'true' 'true');                          [ "$r" = "0|" ] || fail "A unreadable probes must admit (got '$r')"
r=$(admit 'echo 2 40 5 0' 'echo 0.5' FLEET_ADMIT_PRESSURE=critical); [ "$r" = "0|" ] || fail "A PRESSURE=critical admits a warn (got '$r')"
r=$(admit 'echo 4 40 5 0' 'echo 0.5' FLEET_ADMIT_PRESSURE=off);      [ "$r" = "0|" ] || fail "A PRESSURE=off ignores the level (got '$r')"
r=$(admit 'echo 1 3 5 0' 'echo 0.5' FLEET_ADMIT_MEM_FREE_PCT=0);     [ "$r" = "0|" ] || fail "A MEM_FREE_PCT=0 turns the floor off (got '$r')"
r=$(admit 'echo 1 66 5 0' 'echo 9' FLEET_ADMIT_LOAD_PER_CORE=0);     [ "$r" = "0|" ] || fail "A LOAD_PER_CORE=0 turns the load bound off (got '$r')"
r=$(admit 'echo 4 5 97 0' 'echo 9' FLEET_ADMIT=0);                   [ "$r" = "0|" ] || fail "A FLEET_ADMIT=0 admits whatever the readings (got '$r')"
ok "A fleet_machine_admit: memory pressure / avail% / load each hold with a reason; knobs + FLEET_ADMIT=0"

# ===== B: fleet_session_cap_ok =================================================
# A fake tmux with no windows = 0 sessions; FLEET_GLOBAL_MAX_SESSIONS decides the cap.
mkdir -p "$WORK/fakebin" "$WORK/c" "$WORK/t" "$WORK/main/.git" "$WORK/conf"
NEWWIN_LOG="$WORK/newwins"
cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; then shift 2; fi
case "\${1:-}" in
  display-message) case "\$*" in *-p*) case "\$*" in *window_id*) echo @9 ;; *session_name*) echo testsess ;; *) echo '' ;; esac ;; esac ;;
  new-window) printf '%s\n' "\$*" >> "$NEWWIN_LOG"; echo @9 ;;
  *) : ;;
esac
exit 0
TMUXFAKE
cat > "$WORK/fakebin/git" <<'GITFAKE'
#!/bin/bash
if [ "${1:-}" = "-C" ]; then shift 2; fi
case "${1:-}" in rev-parse) case "$*" in *--abbrev-ref*) echo issue-77 ;; *--show-toplevel*) pwd -P ;; *) echo deadbeef ;; esac ;; esac
exit 0
GITFAKE
printf '#!/bin/bash\nexit 0\n' > "$WORK/fakebin/gh"
chmod +x "$WORK/fakebin/tmux" "$WORK/fakebin/git" "$WORK/fakebin/gh"

cap() { # [VAR=val …] → "<rc>|<stdout>"
  env PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/t" FLEET_LOAD_PROBE_CMD='echo 0.5' "$@" \
    bash -c 'source "$1/fleet-lib.sh"; out=$(fleet_session_cap_ok testsess); printf "%s|%s" "$?" "$out"' _ "$BIN"
}
r=$(cap FLEET_MEM_PROBE_CMD='echo 4 5 97 0')
case "$r" in 1\|*内存紧张*) ;; *) fail "B cap_ok must refuse on tight memory (got '$r')" ;; esac
r=$(cap FLEET_MEM_PROBE_CMD='echo 4 5 97 0' FLEET_ADMIT=0); [ "$r" = "0|" ] || fail "B FLEET_ADMIT=0 → cap_ok as before #1090 (got '$r')"
r=$(cap FLEET_MEM_PROBE_CMD='echo 1 66 5 6');               [ "$r" = "0|" ] || fail "B normal readings → cap_ok admits silently (got '$r')"
a=$(cap FLEET_MEM_PROBE_CMD='echo 4 5 97 0' FLEET_GLOBAL_MAX_SESSIONS=0 FLEET_MAX_SESSIONS=0 FLEET_ADMIT=0)
[ "$a" = "0|" ] || fail "B unlimited caps + FLEET_ADMIT=0 admit (got '$a')"
# At capacity, the count's message wins and is byte-identical with the gate on or off.
# One fresh in-flight marker = one session against a global cap of 1.
mkdir -p "$WORK/t/.claude-dash/global/spawn-inflight"; : > "$WORK/t/.claude-dash/global/spawn-inflight/x.1"
on=$(cap FLEET_MEM_PROBE_CMD='echo 4 5 97 0' FLEET_GLOBAL_MAX_SESSIONS=1)
off=$(cap FLEET_MEM_PROBE_CMD='echo 4 5 97 0' FLEET_GLOBAL_MAX_SESSIONS=1 FLEET_ADMIT=0)
case "$on" in 1\|fleet\ at\ capacity:*) ;; *) fail "B at the cap the count's message comes first (got '$on')" ;; esac
[ "$on" = "$off" ] || fail "B at the cap the refusal must not change with the gate" "on=$on
off=$off"
rm -f "$WORK/t/.claude-dash/global/spawn-inflight/x.1"
ok "B fleet_session_cap_ok: refuses on a tight machine; FLEET_ADMIT=0 and the at-capacity message unchanged"

# ===== C/D: dash-issue-session.sh — the one spawn choke point ==================
run_spawn() { # <mem-stub> [VAR=val …]
  local m="$1"; shift
  : > "$NEWWIN_LOG"
  env PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/c" FLEET_CONF_DIR="$WORK/conf" FLEET_C="$WORK/c" \
    FLEET_REPO=acme/widgets FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH=master FLEET_PRESPAWN_DEDUP=0 \
    FLEET_MEM_PROBE_CMD="$m" FLEET_LOAD_PROBE_CMD='echo 0.5' "$@" \
    "$SPAWN" 77 --title "Admission probe" >"$WORK/spawn.out" 2>"$WORK/spawn.err"
}
run_spawn 'echo 4 5 97 0'; rc=$?
[ "$rc" = 2 ] || fail "C a tight machine must refuse with RC_CAP=2 (got rc=$rc)" "$(cat "$WORK/spawn.err")"
grep -q '暂停开新：内存紧张' "$WORK/spawn.err" || fail "C the refusal must say why on stderr" "$(cat "$WORK/spawn.err")"
[ -s "$NEWWIN_LOG" ] && fail "C a refused spawn must not open a window" "$(cat "$NEWWIN_LOG")"
ok "C dash-issue-session.sh refuses with RC_CAP + a readable reason: $(head -1 "$WORK/spawn.err" | cut -c1-90)…"

run_spawn 'echo 4 5 97 0' FLEET_ADMIT=0; rc=$?
[ "$rc" = 0 ] && [ -s "$NEWWIN_LOG" ] || fail "C FLEET_ADMIT=0 must spawn as before (rc=$rc)" "$(cat "$WORK/spawn.err")"
ok "C FLEET_ADMIT=0 spawns on the same tight reading"

run_spawn 'echo 1 66 5 6'; rc=$?
[ "$rc" = 0 ] && [ -s "$NEWWIN_LOG" ] || fail "D once the reading drops the retried spawn must go through (rc=$rc)" "$(cat "$WORK/spawn.err")"
grep -q 'rc" = 3' "$BIN/fleet-dispatch.sh" && grep -q 'stop this tick' "$BIN/fleet-dispatch.sh" \
  || fail "D dispatch must still treat a non-claim refusal as 'stop this tick, retry next'"
ok "D the next attempt after the reading drops spawns (dispatch retries rc 2 on its next tick)"

# ===== E: continuation paths do not pass the gate ==============================
for f in fleet-restore.sh fleet-handoff-cycle.sh; do
  [ -f "$BIN/$f" ] || continue
  grep -vE '^[[:space:]]*#' "$BIN/$f" \
    | grep -qE 'fleet_session_cap_ok|fleet_machine_admit|dash-issue-session\.sh|dash-raw-session\.sh' \
    && fail "E $f re-houses a RUNNING session and must not pass the admission gate"
done
ok "E crash restore / handoff never reach the admission gate"

printf '\nselftest OK: %s assertions passed (machine admission, issue #1090)\n' "$pass"
exit 0
