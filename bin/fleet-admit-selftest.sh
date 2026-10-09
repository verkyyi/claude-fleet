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
#   F. admission is the only gate by default (issue #1831): the per-session cost
#      (median agent RSS × growth, floored, or pinned), the room it leaves above
#      the kept-back floor, a RESERVATION per admission so a burst — sequential or
#      concurrent — admits exactly the room and no more, reservations + in-flight
#      markers age out, hysteresis after a hold, and the count caps default off.
#   G. a reservation is ONE spawn's (issue #2502): void once its owner is gone
#      without confirming a window, one per owner however often it is admitted,
#      confirm keeps it, release drops it, the doctor names who holds them.
set -uo pipefail
unset FLEET_ADMIT FLEET_ADMIT_MEM_FREE_PCT FLEET_ADMIT_PRESSURE FLEET_ADMIT_LOAD_PER_CORE \
      FLEET_LOADGEN_LOAD_PER_CORE FLEET_MEM_PROBE_CMD FLEET_LOAD_PROBE_CMD \
      FLEET_ADMIT_RESERVE_MB FLEET_ADMIT_HYST_MB FLEET_ADMIT_SESSION_MB FLEET_ADMIT_SESSION_MB_MIN \
      FLEET_ADMIT_SESSION_GROWTH FLEET_ADMIT_SETTLE_SECS FLEET_MEM_TOTAL_MB FLEET_MEM_PS_CMD \
      FLEET_GLOBAL_MAX_SESSIONS FLEET_MAX_SESSIONS FLEET_MACHINE_MAX_SESSIONS 2>/dev/null

BIN="$(cd "$(dirname "$0")" && pwd)"
SPAWN="$BIN/dash-issue-session.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/admit-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

# The machine every leg runs on: 16000 MB of RAM and three agents of 400/200/100 MB
# (median 200 × growth 3 ⇒ ~600 MB a session) — never this box's own ps.
U=$(id -u)
PSSTUB="printf '101 1 $U 409600 01:00 claude\\n102 1 $U 204800 01:00 claude\\n103 1 $U 102400 02:00 claude\\n'"
export FLEET_MEM_TOTAL_MB=16000 FLEET_MEM_PS_CMD="$PSSTUB"

# admit <mem-stub> <load-stub> [VAR=val …] → "<rc>|<stdout>". A fresh state dir
# each call (no hold, no reservation left from the last) unless KEEP=1.
admit() {
  local m="$1" l="$2"; shift 2
  [ "${KEEP:-0}" = 1 ] || rm -rf "$WORK/t"; mkdir -p "$WORK/t"
  env "$@" FLEET_MEM_PROBE_CMD="$m" FLEET_LOAD_PROBE_CMD="$l" TMPDIR="$WORK/t" \
    bash -c 'source "$1/fleet-lib.sh"; out=$(fleet_machine_admit ${2:+"$2"}); printf "%s|%s" "$?" "$out"' _ "$BIN" "${SHORT:-}"
}

# ===== A: fleet_machine_admit ==================================================
r=$(admit 'echo 1 66 5 6' 'echo 0.50');            [ "$r" = "0|" ] || fail "A normal readings must admit silently (got '$r')"
r=$(admit 'echo 4 5 97 0' 'echo 0.50')
case "$r" in 1\|*内存紧张*critical*5%\ free*) ;; *) fail "A critical pressure must hold with a readable reason (got '$r')" ;; esac
r=$(admit 'echo 2 40 5 0' 'echo 0.50');            case "$r" in 1\|*pressure\ warn*) ;; *) fail "A warn pressure holds by default (got '$r')" ;; esac
r=$(admit 'echo 1 9 5 0' 'echo 0.50');             case "$r" in 1\|*9%\ free,\ floor\ 15%*) ;; *) fail "A avail% under the floor holds (got '$r')" ;; esac
r=$(admit 'echo 1 66 5 6' 'echo 1.60')
case "$r" in 1\|*负载过高*1.60/core*FLEET_ADMIT_LOAD_PER_CORE=1.5*) ;; *) fail "A load over the default 1.5/core holds (#1831: 2 never fired) (got '$r')" ;; esac
r=$(admit 'echo 1 66 5 6' 'echo 1.30');            [ "$r" = "0|" ] || fail "A 1.3/core (a normal busy afternoon) must admit (got '$r')"
r=$(admit 'echo 1 66 5 6' 'echo 1.30' FLEET_LOADGEN_LOAD_PER_CORE=1)
case "$r" in 1\|*FLEET_ADMIT_LOAD_PER_CORE=1*) ;; *) fail "A load bound defaults to FLEET_LOADGEN_LOAD_PER_CORE when set (got '$r')" ;; esac
r=$(SHORT=--short admit 'echo 4 5 97 0' 'echo 0.5'); [ "$r" = "1|暂停开新：内存紧张" ] || fail "A --short memory tag (got '$r')"
r=$(SHORT=--short admit 'echo 1 66 5 6' 'echo 9');   [ "$r" = "1|暂停开新：负载过高" ] || fail "A --short load tag (got '$r')"
r=$(admit 'true' 'true');                          [ "$r" = "0|" ] || fail "A unreadable probes must admit (got '$r')"
r=$(admit 'echo 2 40 5 0' 'echo 0.5' FLEET_ADMIT_PRESSURE=critical); [ "$r" = "0|" ] || fail "A PRESSURE=critical admits a warn (got '$r')"
r=$(admit 'echo 4 40 5 0' 'echo 0.5' FLEET_ADMIT_PRESSURE=off);      [ "$r" = "0|" ] || fail "A PRESSURE=off ignores the level (got '$r')"
r=$(admit 'echo 1 10 5 0' 'echo 0.5' FLEET_ADMIT_MEM_FREE_PCT=0 FLEET_ADMIT_RESERVE_MB=0); [ "$r" = "0|" ] || fail "A MEM_FREE_PCT=0 + RESERVE_MB=0 turn the floor off (got '$r')"
r=$(admit 'echo 1 10 5 0' 'echo 0.5' FLEET_ADMIT_MEM_FREE_PCT=0)
case "$r" in 1\|*2048\ MB\ kept\ back*) ;; *) fail "A with the % floor off the absolute FLEET_ADMIT_RESERVE_MB still keeps 2 GB back (got '$r')" ;; esac
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

# ===== F: admission is the only gate by default (issue #1831) ==================
hr() { rm -rf "$WORK/t"; mkdir -p "$WORK/t"; env "$@" TMPDIR="$WORK/t" bash -c 'source "$1/fleet-lib.sh"; fleet_machine_headroom' _ "$BIN"; }
# cost: median 200 × 3 = 600; the 512 floor wins under it; a pin wins over both.
[ "$(hr FLEET_MEM_PROBE_CMD='echo 1 50 0 0' | awk '{print $2, $7, $8}')" = "600 200 3" ] || fail "F cost = median 200 × growth 3 over 3 agents"
[ "$(hr FLEET_MEM_PROBE_CMD='echo 1 50 0 0' FLEET_ADMIT_SESSION_GROWTH=2 | awk '{print $2}')" = 512 ] || fail "F cost never under FLEET_ADMIT_SESSION_MB_MIN (400 → 512)"
[ "$(hr FLEET_MEM_PROBE_CMD='echo 1 50 0 0' FLEET_ADMIT_SESSION_MB=1000 | awk '{print $2}')" = 1000 ] || fail "F FLEET_ADMIT_SESSION_MB pins the cost"
[ "$(hr FLEET_MEM_PROBE_CMD='echo 1 50 0 0' FLEET_MEM_PS_CMD=true | awk '{print $2, $8}')" = "512 0" ] || fail "F no agent running → the floor"
# room: 16000 × 50% = 8000 avail, floor max(15% = 2400, 2048) → (8000 − 2400) / 600 = 9.
[ "$(hr FLEET_MEM_PROBE_CMD='echo 1 50 0 0' | awk '{print $1, $3, $4}')" = "9 8000 2400" ] || fail "F room = (avail − floor) / cost"
[ -z "$(hr FLEET_MEM_PROBE_CMD=true)" ] || fail "F unreadable memory → no headroom line"
ok "F cost (median × growth, floor, pin) and room above the kept-back floor"

# A burst against room for exactly 3: 10000 MB × 40% = 4000, floor 2048 → 1952 / 600 = 3.
capf() { env PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/t" FLEET_LOAD_PROBE_CMD='echo 0.5' FLEET_MEM_TOTAL_MB=10000 \
           FLEET_MEM_PROBE_CMD='echo 1 40 0 0' \
           bash -c 'source "$1/fleet-lib.sh"; out=$(fleet_session_cap_ok testsess); rc=$?
             [ "$rc" = 0 ] && [ "${NOCONFIRM:-0}" != 1 ] && fleet_admit_confirm >/dev/null   # the spawn opened its window
             printf "%s|%s" "$rc" "$out"' _ "$BIN"; }
rm -rf "$WORK/t"; mkdir -p "$WORK/t"; seq_rc=''
for i in 1 2 3 4 5; do r=$(capf); seq_rc="$seq_rc${r%%|*}"; done
[ "$seq_rc" = 00011 ] || fail "F a sequential burst admits exactly the room (3), then holds (got $seq_rc)"
r=$(capf); case "$r" in 1\|*room\ for\ 0\ more*3\ admitted\ not\ yet\ counted*) ;; *) fail "F the hold names the reservations (got '$r')" ;; esac
ok "F sequential burst: 3 admitted into room for 3, the 4th held — reason names the 3 reserved"
rm -rf "$WORK/t"; mkdir -p "$WORK/t"
for i in 1 2 3 4 5 6 7 8; do capf > "$WORK/par.$i" & done; wait
npass=0; for f in "$WORK"/par.*; do case "$(cat "$f")" in 0\|*) npass=$((npass + 1)) ;; esac; done
[ "$npass" = 3 ] || fail "F 8 CONCURRENT spawns into room for 3 must admit exactly 3 (got $npass)" "$(cat "$WORK"/par.*)"
ok "F concurrent burst: 8 at once into room for 3 → exactly 3 admitted (read + reserve under one lock)"
# Reservations age out after FLEET_ADMIT_SETTLE_SECS (the session now shows in avail).
touch -t 202001010000 "$WORK"/t/.claude-dash/global/admit-reserve/* 2>/dev/null
r=$(capf); [ "${r%%|*}" = 0 ] || fail "F a settled reservation no longer counts (got '$r')"
# In-flight spawn markers (#531) count when they outnumber the reservations.
rm -rf "$WORK/t"; mkdir -p "$WORK/t/.claude-dash/global/spawn-inflight"
for i in 1 2 3; do : > "$WORK/t/.claude-dash/global/spawn-inflight/x.$i"; done
r=$(capf); case "$r" in 1\|*3\ admitted\ not\ yet\ counted*) ;; *) fail "F 3 in-flight spawns fill room for 3 (got '$r')" ;; esac
ok "F reservations settle out; in-flight markers count when more"
# Hysteresis: after a hold, FLEET_ADMIT_HYST_MB more must free up before it reopens.
rm -rf "$WORK/t"; mkdir -p "$WORK/t"
r=$(KEEP=1 admit 'echo 4 5 0 0' 'echo 0.5' FLEET_MEM_TOTAL_MB=10000); [ "${r%%|*}" = 1 ] || fail "F setup: hold"
r=$(KEEP=1 admit 'echo 1 40 0 0' 'echo 0.5' FLEET_MEM_TOTAL_MB=10000 FLEET_ADMIT_HYST_MB=1500)
case "$r" in 1\|*1500\ MB\ until\ it\ recovers*) ;; *) fail "F after a hold, room for 3 minus the hysteresis stays held (got '$r')" ;; esac
r=$(KEEP=1 admit 'echo 1 50 0 0' 'echo 0.5' FLEET_MEM_TOTAL_MB=10000 FLEET_ADMIT_HYST_MB=1500); [ "$r" = "0|" ] || fail "F past the recovery line it reopens (got '$r')"
r=$(KEEP=1 admit 'echo 1 40 0 0' 'echo 0.5' FLEET_MEM_TOTAL_MB=10000 FLEET_ADMIT_HYST_MB=1500); [ "$r" = "0|" ] || fail "F once reopened the plain line applies again (got '$r')"
ok "F hysteresis: held until the recovery line, then the plain line"
# The count caps default OFF: nothing set ⇒ no count refusal, only admission.
r=$(env TMPDIR="$WORK/t" bash -c 'source "$1/fleet-lib.sh"; fleet_session_count() { printf 50; }; fleet_inflight_count() { printf 0; }
  FLEET_ADMIT=0 fleet_session_cap_ok s; printf "%s|" "$?"; fleet_cap_full s; printf "%s" "$?"' _ "$BIN")
[ "$r" = "0|1" ] || fail "F 50 sessions and no cap set: neither cap_ok nor cap_full binds (got '$r')"
ok "F FLEET_GLOBAL_MAX_SESSIONS defaults to 0: 50 sessions, no count refusal"

# ===== G: a reservation is one spawn's, and dies with a spawn that opened nothing (#2502)
RD="$WORK/t/.claude-dash/global/admit-reserve"
rm -rf "$WORK/t"; mkdir -p "$WORK/t"; seq_rc=''
for i in 1 2 3 4 5; do r=$(NOCONFIRM=1 capf); seq_rc="$seq_rc${r%%|*}"; done
[ "$seq_rc" = 00000 ] || fail "G admissions whose spawns exited without a window must not fill the room (got $seq_rc)"
r=$(env TMPDIR="$WORK/t" bash -c 'source "$1/fleet-lib.sh"; fleet_admit_reserved' _ "$BIN")
[ "$r" = 0 ] || fail "G five unconfirmed admissions by gone owners count 0 (got $r)"
[ -z "$(ls "$RD" 2>/dev/null)" ] || fail "G a void reservation is deleted on sight" "$(ls "$RD")"
ok "G an admission whose spawn exits without confirming a window is void (5 in a row, room for 3: all admitted)"
# A LIVE owner's reservation counts; once it is gone unconfirmed, it does not.
rm -rf "$WORK/t"; mkdir -p "$RD"; sleep 30 & SP=$!
: > "$RD/x.$SP.1"
r=$(env TMPDIR="$WORK/t" bash -c 'source "$1/fleet-lib.sh"; fleet_admit_reserved; fleet_admit_holders' _ "$BIN")
case "$r" in 1*"live "*"s pid $SP sleep 30"*) ;; *) fail "G a running spawn's reservation counts, and the holders line names its command (got '$r')" ;; esac
kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
r=$(env TMPDIR="$WORK/t" bash -c 'source "$1/fleet-lib.sh"; fleet_admit_reserved' _ "$BIN")
[ "$r" = 0 ] || fail "G the same reservation after its owner died unconfirmed counts 0 (got $r)"
ok "G a running spawn holds its reservation (holders: pid + command); dead + unconfirmed ⇒ void"
# One owner, one cost: a second admission in the same process (dash-new-session's
# exec into dash-issue-session) neither counts its own nor takes a second.
rm -rf "$WORK/t"; mkdir -p "$WORK/t"
r=$(env PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/t" FLEET_LOAD_PROBE_CMD='echo 0.5' FLEET_MEM_TOTAL_MB=10000 FLEET_MEM_PROBE_CMD='echo 1 40 0 0' \
  bash -c 'source "$1/fleet-lib.sh"; a=$(fleet_session_cap_ok s); x=$?; b=$(fleet_session_cap_ok s); y=$?
    printf "%s%s|%s|" "$x" "$y" "$(ls "$2" | wc -l | tr -d " ")"
    k=$(fleet_admit_confirm); printf "%s|" "$(ls "$2" | grep -c "\.ok\.")"
    fleet_admit_release "$k"; ls "$2" | wc -l | tr -d " "' _ "$BIN" "$RD")
[ "$r" = "00|1|1|0" ] || fail "G same owner: two admissions, one reservation; confirm → .ok; release by path (got '$r')"
ok "G one owner holds one reservation however often it is admitted; confirm keeps it, release drops it"
# The doctor lists who holds them (the row named a bare number before #2502).
grep -q 'fleet_admit_holders' "$BIN/fleet-doctor.sh" || fail "G the doctor's admit row must list the holders"
# Every spawner confirms the window it opened.
for f in dash-raw-session.sh dash-issue-session.sh dash-restore-session.sh scratch-pool.sh; do
  grep -q 'fleet_admit_confirm' "$BIN/$f" || fail "G $f opens windows but never confirms its admission"
done
ok "G every spawner confirms its window; the doctor names the holders"

# ===== E: continuation paths do not pass the gate ==============================
for f in fleet-restore.sh fleet-handoff-cycle.sh; do
  [ -f "$BIN/$f" ] || continue
  grep -vE '^[[:space:]]*#' "$BIN/$f" \
    | grep -qE 'fleet_session_cap_ok|fleet_machine_admit|dash-issue-session\.sh|dash-raw-session\.sh' \
    && fail "E $f re-houses a RUNNING session and must not pass the admission gate"
done
ok "E crash restore / handoff never reach the admission gate"

printf '\nselftest OK: %s assertions passed (machine admission, issues #1090 #1831)\n' "$pass"
exit 0
