#!/bin/bash
# fleet-machine-sessions-selftest.sh — the machine-wide session total across
# LOGINS (issue #1301, EPIC #1312 C4). Each login's collector publishes its count
# to a machine-level dir; fleet_session_cap_ok adds them up as a third tier when
# FLEET_MACHINE_MAX_SESSIONS is set. Hermetic: the shared dir is a temp dir
# (FLEET_MACHINE_SESSIONS_DIR), three logins are three HOMEs, tmux/git/gh are
# faked on PATH — no real tmux server, nothing written under /Users/Shared.
#
#   A. publish: one `<count> <epoch>` file per login (key = basename of HOME), the
#      dir created 1777, no temp left behind.
#   B. rows/summary: self live + others from file; a file past the stale bound,
#      or a garbled one, reads 0 and is marked.
#   C. cap: 3 logins at the ceiling → the 4th spawn is refused with each login's
#      share; a stale login frees its share; default 0 = byte-identical refusal /
#      admit and never reads the dir.
#   D. dash-issue-session.sh at the ceiling → RC_CAP (2), the breakdown on stderr,
#      no window.
#   E. continuation paths (crash restore, handoff) never pass the cap.
#   F. the collector publishes after a clean socket probe; doctor states the total.
set -uo pipefail
unset FLEET_MACHINE_MAX_SESSIONS FLEET_MACHINE_SESSIONS_STALE FLEET_MACHINE_SESSIONS_DIR \
      FLEET_GLOBAL_MAX_SESSIONS FLEET_MAX_SESSIONS 2>/dev/null
export FLEET_ADMIT=0

BIN="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/machsess-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
SH="$WORK/shared/sessions"     # parent does not exist yet: publish creates the chain

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

# A fake tmux whose session windows come from $FAKE_WINDOWS (one fleet `f` with a
# dash hub + N working windows); new-window is logged.
mkdir -p "$WORK/fakebin" "$WORK/main/.git" "$WORK/conf/fleets/f"
printf 'FLEET_REPO=acme/widgets\n' > "$WORK/conf/fleets/f/conf"   # one live fleet `f` per login
NEWWIN_LOG="$WORK/newwins"
cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
while [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; do shift 2; done
case "\${1:-}" in
  list-windows)
    n="\${FAKE_WINDOWS:-0}"
    case "\$*" in *session_name*) pre='f ' ;; *) pre='' ;; esac
    printf '%sdash @L=\n' "\$pre"
    i=0; while [ "\$i" -lt "\$n" ]; do printf '%sw%s @L=\n' "\$pre" "\$i"; i=\$((i+1)); done ;;
  has-session) exit 0 ;;
  display-message) case "\$*" in *-p*) case "\$*" in *window_id*) echo @9 ;; *session_name*) echo f ;; *) echo '' ;; esac ;; esac ;;
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

# as <login> <windows> <cmd…> — run a fleet-lib snippet as that login
as() {
  local l="$1" w="$2"; shift 2
  mkdir -p "$WORK/home/$l" "$WORK/c-$l"
  env PATH="$WORK/fakebin:$PATH" HOME="$WORK/home/$l" FLEET_C="$WORK/c-$l" TMPDIR="$WORK/c-$l" \
    FLEET_CONF_DIR="$WORK/conf" FLEET_MACHINE_SESSIONS_DIR="$SH" FAKE_WINDOWS="$w" "$@"
}
lib() { local l="$1" w="$2"; shift 2; as "$l" "$w" bash -c 'source "$1/fleet-lib.sh"; shift; eval "$*"' _ "$BIN" "$@"; }

# ===== A: publish ==============================================================
lib alice 3 fleet_machine_sessions_publish || fail "A alice publish failed"
lib bob   2 fleet_machine_sessions_publish || fail "A bob publish failed"
lib carol 0 fleet_machine_sessions_publish || fail "A carol publish failed"
read -r an ats < "$SH/alice"; [ "$an" = 3 ] || fail "A alice's file must hold her live count 3 (got '$an')"
case "$ats" in ''|*[!0-9]*) fail "A the file's second field is an epoch (got '$ats')" ;; esac
[ "$(cat "$SH/bob")" != "" ] && read -r bn _ < "$SH/bob"; [ "$bn" = 2 ] || fail "A bob's count (got '$bn')"
perm=$(stat -c %a "$SH" 2>/dev/null || stat -f %Mp%Lp "$SH" 2>/dev/null)
[ "$perm" = 1777 ] || fail "A the shared dir must be 1777 like the heavy queue (got $perm)"
ls -A "$SH" | grep -q '^\.' && fail "A a publish must leave no temp file behind" "$(ls -A "$SH")"
lib alice 0 'fleet_machine_sessions_publish 7' && read -r an _ < "$SH/alice"; [ "$an" = 7 ] || fail "A an explicit count wins (got '$an')"
lib alice 0 'fleet_machine_sessions_publish x' && fail "A a non-numeric count must be refused"
lib alice 3 fleet_machine_sessions_publish
ok "A one '<count> <epoch>' file per login, dir 1777, atomic"

# ===== B: rows / summary =======================================================
r=$(lib alice 3 fleet_machine_sessions_summary)
[ "$r" = "$(printf '5\talice 3 · bob 2 · carol 0')" ] || fail "B summary as alice (got '$r')"
# self is LIVE, not its file: alice now has 4 windows though her file says 3.
r=$(lib alice 4 fleet_machine_sessions_summary); [ "${r%%$'\t'*}" = 6 ] || fail "B self must be counted live (got '$r')"
# a login with no file yet still counts itself.
r=$(lib dave 1 fleet_machine_sessions_summary)
[ "$r" = "$(printf '6\tdave 1 · alice 3 · bob 2 · carol 0')" ] || fail "B a login with no file counts itself live (got '$r')"
# stale: bob's file 10 minutes old → 0 (stale); garbled → 0.
printf '2 %s\n' "$(( $(date +%s) - 600 ))" > "$SH/bob"
r=$(lib alice 3 fleet_machine_sessions_summary)
[ "$r" = "$(printf '3\talice 3 · bob 0 (stale) · carol 0')" ] || fail "B a stale login reads 0 (got '$r')"
r=$(lib alice 3 'FLEET_MACHINE_SESSIONS_STALE=900 fleet_machine_sessions_summary'); [ "${r%%$'\t'*}" = 5 ] || fail "B FLEET_MACHINE_SESSIONS_STALE widens the bound (got '$r')"
printf 'garbage\n' > "$SH/carol"
r=$(lib alice 3 fleet_machine_sessions_summary); [ "${r%%$'\t'*}" = 3 ] || fail "B a garbled file reads 0 (got '$r')"
lib bob 2 fleet_machine_sessions_publish; lib carol 0 fleet_machine_sessions_publish
ok "B self live, others from file; stale / garbled read 0 and are marked"

# ===== C: the cap tier =========================================================
cap() { local l="$1" w="$2"; shift 2; as "$l" "$w" env "$@" bash -c 'source "$1/fleet-lib.sh"; out=$(fleet_session_cap_ok f); printf "%s|%s" "$?" "$out"' _ "$BIN"; }
# alice 3 + bob 2 + carol 1 = 6 against a ceiling of 6: the next spawn, from any login, is refused.
lib carol 1 fleet_machine_sessions_publish
r=$(cap carol 1 FLEET_MACHINE_MAX_SESSIONS=6 FLEET_GLOBAL_MAX_SESSIONS=0)
case "$r" in "1|machine at capacity — 全机会话已满: 6/6 Claude sessions across all logins (carol 1 · alice 3 · bob 2)"*FLEET_MACHINE_MAX_SESSIONS*) ;;
  *) fail "C at the machine ceiling the 4th spawn must be refused with each login's share (got '$r')" ;; esac
C_MSG="${r#1|}"
r=$(cap alice 3 FLEET_MACHINE_MAX_SESSIONS=6 FLEET_GLOBAL_MAX_SESSIONS=0); case "$r" in 1\|*"alice 3 · bob 2 · carol 1"*) ;; *) fail "C refused from alice too (got '$r')" ;; esac
r=$(cap alice 3 FLEET_MACHINE_MAX_SESSIONS=7 FLEET_GLOBAL_MAX_SESSIONS=0); [ "$r" = "0|" ] || fail "C under the ceiling admits (got '$r')"
# bob's collector stopped: his share frees.
printf '2 %s\n' "$(( $(date +%s) - 600 ))" > "$SH/bob"
r=$(cap alice 3 FLEET_MACHINE_MAX_SESSIONS=6 FLEET_GLOBAL_MAX_SESSIONS=0); [ "$r" = "0|" ] || fail "C a stale login's share must free (got '$r')"
lib bob 2 fleet_machine_sessions_publish
# default 0: byte-identical — same admit, same at-capacity message, dir never read.
mv "$SH" "$SH.off"; mkdir -p "$SH"; chmod 000 "$SH"
r=$(cap alice 3 FLEET_GLOBAL_MAX_SESSIONS=0);             [ "$r" = "0|" ] || fail "C default 0 must admit as before (got '$r')"
r=$(cap alice 3 FLEET_GLOBAL_MAX_SESSIONS=3)
[ "$r" = "1|fleet at capacity: 3/3 Claude sessions running (global) — raise FLEET_GLOBAL_MAX_SESSIONS or close one first" ] \
  || fail "C default 0: the global refusal must be byte-identical (got '$r')"
r=$(cap alice 3 FLEET_MACHINE_MAX_SESSIONS=0 FLEET_GLOBAL_MAX_SESSIONS=0); [ "$r" = "0|" ] || fail "C explicit 0 = unlimited (got '$r')"
chmod 755 "$SH"; rmdir "$SH"; mv "$SH.off" "$SH"
# the per-login tiers still come first.
r=$(cap alice 3 FLEET_MACHINE_MAX_SESSIONS=6 FLEET_GLOBAL_MAX_SESSIONS=2); case "$r" in "1|fleet at capacity: 3/2"*) ;; *) fail "C the global tier is checked first (got '$r')" ;; esac
ok "C machine ceiling refuses with each login's share; stale frees; default 0 unchanged"

# ===== D: dash-issue-session.sh ================================================
: > "$NEWWIN_LOG"
as carol 1 env FLEET_MACHINE_MAX_SESSIONS=6 FLEET_GLOBAL_MAX_SESSIONS=0 \
  FLEET_REPO=acme/widgets FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH=master FLEET_PRESPAWN_DEDUP=0 \
  "$BIN/dash-issue-session.sh" 77 --title "Machine cap probe" >"$WORK/spawn.out" 2>"$WORK/spawn.err"; rc=$?
[ "$rc" = 2 ] || fail "D at the machine ceiling dash-issue-session.sh must exit RC_CAP=2 (got $rc)" "$(cat "$WORK/spawn.err")"
grep -q '全机会话已满: 6/6.*carol 1 · alice 3 · bob 2' "$WORK/spawn.err" || fail "D the refusal must list every login's share" "$(cat "$WORK/spawn.err")"
[ -s "$NEWWIN_LOG" ] && fail "D a refused spawn must not open a window" "$(cat "$NEWWIN_LOG")"
ok "D dash-issue-session.sh: $(grep -m1 '全机' "$WORK/spawn.err" | cut -c1-110)…"

# ===== E: continuation paths ===================================================
for f in fleet-restore.sh fleet-handoff-cycle.sh fleet-move.sh; do
  [ -f "$BIN/$f" ] || continue
  grep -vE '^[[:space:]]*#' "$BIN/$f" | grep -qE 'fleet_session_cap_ok|fleet_machine_sessions_summary' \
    && fail "E $f re-houses a RUNNING session and must not pass the machine cap"
done
ok "E crash restore / handoff / move never reach the machine cap"

# ===== F: collector + doctor ===================================================
grep -q 'fleet_machine_sessions_publish' "$BIN/tmux-dash-collect.sh" || fail "F the collector must publish this login's count"
out=$(env HOME="$WORK/home/alice" FLEET_CONF_DIR="$WORK/conf" FLEET_MACHINE_SESSIONS_DIR="$SH" sh "$BIN/fleet-doctor.sh" 2>&1)
printf '%s\n' "$out" | grep -q 'sessions across logins: 6 across 3 login(s): alice 3 · bob 2 · carol 1 — no machine cap' \
  || fail "F doctor must state the machine-wide total with each login's share" "$(printf '%s\n' "$out" | grep machine)"
out=$(env HOME="$WORK/home/alice" FLEET_CONF_DIR="$WORK/conf" FLEET_MACHINE_SESSIONS_DIR="$WORK/none" sh "$BIN/fleet-doctor.sh" 2>&1)
printf '%s\n' "$out" | grep -q 'sessions across logins: no login has published' || fail "F doctor with no files says so" "$(printf '%s\n' "$out" | grep machine)"
ok "F collector publishes; doctor: $(printf '%s\n' "$out" | grep -m1 'across logins' | sed 's/^ *//' | cut -c1-80)…"

printf '\nselftest OK: %s groups passed (machine-wide session total, issue #1301)\n' "$pass"
exit 0
