#!/bin/bash
# install-follow-selftest.sh — bin/fleet-install-follow.sh, and the two things
# that read it: the doctor's `install` rows and fleet-install-version.sh's
# `follow:` / `logins:` lines — from FAKED install-sync.state files (issue #1123,
# EPIC #1117 C7). No daemon runs; every state is written by hand.
#
# What is pinned:
#   A. current      OK · doctor PASS names the stable sha and the tick age
#   B. deferred     3h → OK (PASS, "deferred for 3h"); 26h → STUCK, doctor WARN
#                   names the wait and the FLEET_INSTALL_SYNC=0 opt-out
#   C. refused      STUCK · WARN carries the daemon's reason (which names the fix)
#   D. rolled-back  STUCK · WARN; `skipped` (every later tick) and `failed` too
#   E. off          conf FLEET_INSTALL_SYNC=0 → OFF, doctor INFO, never a WARN —
#                   even over a state that says stuck; the install's fleet.conf is
#                   the fallback (dual-read); state `off` + conf on → OK
#   F. no tick      no state file → STUCK ("no tick has run yet")
#   G. stale        `current` but last_check 2 days old → STUCK ("last tick 2d ago")
#   H. unseen       fetch-failed / none → UNSEEN, doctor INFO, never WARN
#   I. no daemon    an install without bin/fleet-install-sync.sh → STUCK
#   J. others       four other logins (current / off / deferred 26h / no tick) →
#                   --summary tokens, `2 stuck`, exit 1; an unreadable one (no
#                   sudo) reads `?` and is NOT stuck; the version script's
#                   `logins:` line carries the tokens; the doctor WARNs once
#   K. one login    --summary prints nothing, exit 0; no `follow:` in logins:
#   L. json         --json on both scripts
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
FL="$BIN/fleet-install-follow.sh" IV="$BIN/fleet-install-version.sh" DOC="$BIN/fleet-doctor.sh"
for f in "$FL" "$IV" "$DOC" "$BIN/fleet-sync-logins.sh" "$BIN/fleet-stable.sh"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done
command -v git >/dev/null 2>&1 || { echo 'install-follow-selftest SKIP (no git)'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/install-follow-selftest.XXXXXX")" || exit 2
WORK=$(cd "$WORK" && pwd -P)
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]:
$2";; esac; }
not_contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — output unexpectedly contains [$3]:
$2";; esac; }

export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: > "$WORK/gitconfig"

# --- sandbox: HOME, conf dir, a homes root with no other login yet ---------------
H="$WORK/home" CONF="$WORK/conf" HOMES="$WORK/homes"
mkdir -p "$H" "$CONF" "$HOMES" "$WORK/tmp"
export HOME="$H" FLEET_CONF_DIR="$CONF" TMPDIR="$WORK/tmp" FLEET_SKIP_GLOBAL_CONF=1
export FLEET_SYNC_LOGINS_HOMES="$HOMES" FLEET_SYNC_LOGINS_SUDO='' FLEET_SYNC_LOGINS_TMP="$WORK/tmp"
# a fixed name for THIS login: the table pads it to a column, and CI's `runner`
# is not the operator's name
export FLEET_SYNC_LOGINS_ME=selfme
unset FLEET_INSTALL_SYNC FLEET_INSTALL_FOLLOW_STUCK_SECS 2>/dev/null || :

# The live install: a clone of a local trunk, carrying the daemon script.
UP="$WORK/upstream"; git init -q -b master "$UP"
mkdir -p "$UP/bin"; echo one > "$UP/f"; printf '#!/bin/sh\n' > "$UP/bin/fleet-install-sync.sh"
git -C "$UP" add -A; git -C "$UP" commit -qm one
LIVE="$WORK/live"; git clone -q "$UP" "$LIVE" 2>/dev/null
export FLEET_LIVE_DIR="$LIVE"
HEADSHA=$(git -C "$LIVE" rev-parse HEAD); STABLESHA=$HEADSHA
S7=$(printf '%.7s' "$STABLESHA")
NOW=$(date +%s)
STATE="$CONF/global/install-sync.state"

# mk_state <conf-dir> <result> <reason> [deferred_since|-] [last_check]
mk_state() {
  mkdir -p "$1/global"
  cat > "$1/global/install-sync.state" <<EOF
last_check: ${5:-$NOW}
last_check_iso: 2026-09-24T00:00:00Z
result: $2
head: $HEADSHA
stable: $STABLESHA
from: $HEADSHA
to: $STABLESHA
reason: $3
deferred_since: ${4:--}
skip: -
apply: -
EOF
}
fself() { OUT=$(sh "$FL" --self 2>&1); RC=$?; }
fv() { printf '%s\n' "$OUT" | sed -n "s/^$1:  *//p"; }
# the doctor's install-sync rows only (PASS/WARN/FAIL/INFO), `[[:space:]]` not
# `\s` — BSD grep has no \s
doc_sync() {
  sh "$DOC" 2>&1 | grep -E '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+install[[:space:]]' | grep -E 'install-sync|other login' || true
}

# ============================================================================
# A. current
# ============================================================================
mk_state "$CONF" current "install at stable $S7"
fself
eq "A: exit 0" 0 "$RC"
eq "A: verdict OK" OK "$(fv verdict)"
eq "A: follow on" on "$(fv follow)"
eq "A: result current" current "$(fv result)"
contains "A: why names the sha" "$(fv why)" "at stable $S7"
contains "A: checked is an age" "$(fv checked)" "<1m ago"
eq "A: stable column" "$S7" "$(fv stable)"
D=$(doc_sync)
contains "A: doctor PASS" "$D" "PASS"
contains "A: doctor names install-sync" "$D" "install-sync on — at stable $S7"
contains "A: doctor names the tick age" "$D" "(last tick <1m ago)"
not_contains "A: doctor no WARN" "$D" "WARN"

# ============================================================================
# B. deferred: under a day is normal, over a day is stuck
# ============================================================================
mk_state "$CONF" deferred "busy window(s) on f1:2 — waiting for every session to go idle" "$((NOW - 3 * 3600))"
fself
eq "B: 3h deferred is OK" OK "$(fv verdict)"
contains "B: 3h named" "$(fv why)" "deferred for 3h"
contains "B: says it follows when idle" "$(fv why)" "follows when every window is idle"
mk_state "$CONF" deferred "busy window(s) on f1:2 — waiting for every session to go idle" "$((NOW - 26 * 3600))"
fself
eq "B: 26h deferred is STUCK" STUCK "$(fv verdict)"
contains "B: 26h named" "$(fv why)" "deferred for 26h"
contains "B: carries the daemon's reason" "$(fv why)" "busy window(s) on f1:2"
D=$(doc_sync)
contains "B: doctor WARN" "$D" "WARN"
contains "B: doctor says not following" "$D" "NOT following stable"
contains "B: doctor names the wait" "$D" "deferred for 26h"
contains "B: doctor names the opt-out" "$D" "FLEET_INSTALL_SYNC=0"
contains "B: opt-out names the file" "$D" "$CONF/fleet.settings"
# the knob moves the line
OUT=$(FLEET_INSTALL_FOLLOW_STUCK_SECS=$((48 * 3600)) sh "$FL" --self 2>&1)
eq "B: 26h under a 48h knob is OK" OK "$(fv verdict)"

# ============================================================================
# C. refused
# ============================================================================
mk_state "$CONF" refused "tracked local changes in $LIVE (bin/x.sh) — not touching an edited install; commit or discard them, then the next tick follows"
fself
eq "C: refused is STUCK" STUCK "$(fv verdict)"
contains "C: why starts with the result" "$(fv why)" "refused — tracked local changes"
D=$(doc_sync)
contains "C: doctor WARN" "$D" "WARN"
contains "C: doctor carries the fix from the reason" "$D" "commit or discard them"
contains "C: doctor names the opt-out" "$D" "FLEET_INSTALL_SYNC=0"

# ============================================================================
# D. rolled-back, then skipped on every later tick; failed
# ============================================================================
mk_state "$CONF" rolled-back "doctor FAIL after update: quota — back at $S7; stable abc1234 is not retried until it moves"
fself
eq "D: rolled-back is STUCK" STUCK "$(fv verdict)"
contains "D: why names the FAIL" "$(fv why)" "rolled-back — doctor FAIL after update: quota"
D=$(doc_sync)
contains "D: doctor WARN" "$D" "WARN"
contains "D: doctor says rolled back" "$D" "rolled-back"
contains "D: doctor says not retried" "$D" "not retried until it moves"
mk_state "$CONF" skipped "stable abc1234 failed the doctor after the last update and was rolled back — not retried until stable moves (fleet-stable.sh move)"
fself
eq "D: skipped is STUCK" STUCK "$(fv verdict)"
contains "D: skipped names the way out" "$(fv why)" "fleet-stable.sh move"
mk_state "$CONF" failed "doctor FAIL (x) at abc1234 and git reset --hard $S7 FAILED — fix by hand"
fself
eq "D: failed is STUCK" STUCK "$(fv verdict)"
contains "D: failed says fix by hand" "$(fv why)" "fix by hand"

# ============================================================================
# E. off — a choice, never a warning; beats a stuck state; dual-read; state off
# ============================================================================
mk_state "$CONF" refused "would be a WARN if on"
printf 'FLEET_INSTALL_SYNC="0"\n' > "$CONF/fleet.settings"
fself
eq "E: conf off is OFF" OFF "$(fv verdict)"
eq "E: follow off" off "$(fv follow)"
contains "E: why names the key" "$(fv why)" "FLEET_INSTALL_SYNC=0"
contains "E: why says how to switch on" "$(fv why)" "set it to 1"
D=$(doc_sync)
contains "E: doctor INFO" "$D" "INFO"
contains "E: doctor says off" "$D" "install-sync off"
not_contains "E: doctor never WARNs an opted-out login" "$D" "WARN"
rm -f "$CONF/fleet.settings"
printf 'FLEET_INSTALL_SYNC=0\n' > "$LIVE/fleet.conf"
fself
eq "E: the install's fleet.conf is the fallback" OFF "$(fv verdict)"
rm -f "$LIVE/fleet.conf"
printf 'FLEET_INSTALL_SYNC=1\n' > "$CONF/fleet.settings"
mk_state "$CONF" off "FLEET_INSTALL_SYNC=0 — this login does not follow stable"
fself
eq "E: state off + conf on is OK (next tick follows)" OK "$(fv verdict)"
contains "E: says switched on since" "$(fv why)" "switched on since the last tick"
rm -f "$CONF/fleet.settings"

# ============================================================================
# F. no tick yet
# ============================================================================
rm -f "$STATE"
fself
eq "F: no state is STUCK" STUCK "$(fv verdict)"
eq "F: result no-tick" no-tick "$(fv result)"
eq "F: checked never" never "$(fv checked)"
contains "F: why names the daemon" "$(fv why)" "com.claude-fleet.install-sync"
D=$(doc_sync)
contains "F: doctor WARN" "$D" "WARN"
contains "F: doctor says no tick" "$D" "no tick has run yet"

# ============================================================================
# G. stale — the daemon stopped ticking
# ============================================================================
mk_state "$CONF" current "install at stable $S7" - "$((NOW - 2 * 86400 - 60))"
fself
eq "G: 2d-old current is STUCK" STUCK "$(fv verdict)"
contains "G: why names the age" "$(fv why)" "last tick 2d ago"
contains "G: why keeps the last result" "$(fv why)" "before it stopped: at stable $S7"
contains "G: checked shows the age" "$(fv checked)" "2d ago"

# ============================================================================
# H. unseen — not seen is not not-following
# ============================================================================
mk_state "$CONF" fetch-failed "could not read refs/tags/stable from origin (offline? timeout 30s)"
fself
eq "H: fetch-failed is UNSEEN" UNSEEN "$(fv verdict)"
D=$(doc_sync)
contains "H: doctor INFO" "$D" "INFO"
contains "H: doctor says not seen" "$D" "stable not seen at the last tick"
not_contains "H: doctor no WARN" "$D" "WARN"
mk_state "$CONF" none "no refs/tags/stable on origin yet"
fself
eq "H: none is UNSEEN" UNSEEN "$(fv verdict)"
mk_state "$CONF" wat "a token from the future"
fself
eq "H: unknown token is UNKNOWN" UNKNOWN "$(fv verdict)"
contains "H: unknown names the token" "$(fv why)" "unrecognised result 'wat'"

# ============================================================================
# I. an install from before the daemon
# ============================================================================
OLD="$WORK/old"; mkdir -p "$OLD/bin"
OUT=$(sh "$FL" --self --dir "$OLD" 2>&1)
eq "I: no daemon script is STUCK" STUCK "$(fv verdict)"
eq "I: result no-daemon" no-daemon "$(fv result)"
contains "I: why names the fix" "$(fv why)" "fleet-sync-logins.sh --logins"
OUT=$(sh "$FL" --self --dir "$WORK/nowhere" 2>&1)
eq "I: no install is UNKNOWN" UNKNOWN "$(fv verdict)"

# ============================================================================
# K. one login — nothing about others
# ============================================================================
mk_state "$CONF" current "install at stable $S7"
OUT=$(sh "$FL" --summary 2>&1); RC=$?
eq "K: no other login → exit 0" 0 "$RC"
eq "K: no other login → no line" "" "$OUT"
OUT=$(sh "$IV" --dir "$LIVE" --no-fetch 2>&1)
contains "K: version follow line" "$OUT" "follow:   on · current · at stable $S7 · last tick <1m ago [OK]"
not_contains "K: version has no logins line" "$OUT" "logins:"
D=$(doc_sync)
not_contains "K: doctor says nothing about others" "$D" "other login"

# ============================================================================
# J. other logins, read from their homes
# ============================================================================
# other <login> <state-result|none> [reason] [deferred_since]  — a daemon-carrying
# install plus a conf dir under $HOMES/<login>
other() {
  mkdir -p "$HOMES/$1/.claude/fleet/bin" "$HOMES/$1/.config/claude-fleet"
  printf '#!/bin/sh\n' > "$HOMES/$1/.claude/fleet/bin/fleet-install-sync.sh"
  [ "$2" = none ] || mk_state "$HOMES/$1/.config/claude-fleet" "$2" "${3:-r}" "${4:--}"
}
other alice current "install at stable $S7"
other bob current "install at stable $S7"; printf 'FLEET_INSTALL_SYNC=0\n' > "$HOMES/bob/.config/claude-fleet/fleet.settings"
other carol deferred "busy window(s) on f9:1 — waiting" "$((NOW - 26 * 3600))"
other dave none
OUT=$(sh "$FL" --summary 2>&1); RC=$?
eq "J: stuck → exit 1" 1 "$RC"
contains "J: alice token" "$OUT" "alice on/current <1m"
contains "J: bob token" "$OUT" "bob off"
contains "J: carol token" "$OUT" "carol on/deferred <1m ⚠"
contains "J: dave token" "$OUT" "dave on/no-tick ⚠"
contains "J: stuck count" "$OUT" "· 2 stuck"
not_contains "J: bob (off) never stuck" "$OUT" "bob off ⚠"
eq "J: one line" 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
OUT=$(sh "$FL" 2>&1)
contains "J: table header" "$OUT" "login        follow result"
contains "J: table self first" "$OUT" "selfme       on     current"
contains "J: table carol" "$OUT" "carol        on     deferred"
# an unreadable state (no passwordless sudo here) reads `?`, and is NOT stuck
if [ "$(id -u)" != 0 ]; then
  other erin current "install at stable $S7"
  chmod 000 "$HOMES/erin/.config/claude-fleet/global"
  OUT=$(sh "$FL" --summary 2>&1); RC=$?
  contains "J: unreadable reads ?" "$OUT" "erin ?"
  contains "J: unreadable does not add to stuck" "$OUT" "· 2 stuck"
  OUT=$(sh "$FL" --others 2>&1)
  contains "J: unreadable names the command" "$OUT" "sudo -n -u $(id -un) cat $HOMES/erin/.config/claude-fleet/global/install-sync.state"
  chmod 700 "$HOMES/erin/.config/claude-fleet/global"; rm -rf "$HOMES/erin"
fi
# through the version script: one `logins:` line, drift first, then the tokens
OUT=$(sh "$IV" --dir "$LIVE" --no-fetch 2>&1)
contains "J: version logins line has drift" "$OUT" "logins:   4 other"
contains "J: version logins line has the tokens" "$OUT" "· follow: alice on/current <1m · bob off · carol on/deferred <1m ⚠ · dave on/no-tick ⚠ · 2 stuck"
OUT=$(sh "$IV" --dir "$LIVE" --no-fetch --no-logins 2>&1)
not_contains "J: --no-logins drops the tokens" "$OUT" "follow: alice"
contains "J: --no-logins keeps this login's follow line" "$OUT" "follow:   on · current"
# the doctor: one WARN for the others, naming the stuck ones and the fix
D=$(doc_sync)
contains "J: doctor WARNs about others" "$D" "WARN  install  other login(s) on this machine NOT following stable: alice on/current"
contains "J: doctor names carol" "$D" "carol on/deferred <1m ⚠"
contains "J: doctor names the fix" "$D" "fleet-sync-logins.sh --logins <login>"
contains "J: doctor says off is never warned" "$D" "FLEET_INSTALL_SYNC=0) reads \`off\`"
# no stuck other → INFO, not WARN
rm -rf "$HOMES/carol" "$HOMES/dave"
D=$(doc_sync)
contains "J: no stuck other → INFO" "$D" "INFO  install  other logins on this machine: alice on/current <1m · bob off"
not_contains "J: no stuck other → no WARN about others" "$D" "other login(s) on this machine NOT"

# ============================================================================
# L. json
# ============================================================================
OUT=$(sh "$FL" --self --json 2>&1)
contains "L: self json verdict" "$OUT" '"verdict":"OK"'
contains "L: self json self" "$OUT" '"self":true'
contains "L: self json stable" "$OUT" "\"stable\":\"$S7\""
OUT=$(sh "$FL" --json 2>&1)
contains "L: all json is an array" "$OUT" '[{"login":"'
contains "L: all json has bob off" "$OUT" '"login":"bob","self":false,"follow":"off","result":"off","age":null'
OUT=$(sh "$IV" --dir "$LIVE" --no-fetch --json 2>&1)
contains "L: version json follow" "$OUT" '"follow":"on · current · at stable'
contains "L: version json follow_verdict" "$OUT" '"follow_verdict":"OK"'
contains "L: version json logins tokens" "$OUT" 'follow: alice on/current'
rm -f "$STATE"
OUT=$(sh "$IV" --dir "$LIVE" --no-fetch --json 2>&1)
contains "L: version json no-tick verdict" "$OUT" '"follow_verdict":"STUCK"'
OUT=$(sh "$IV" --dir "$WORK/nowhere" --no-fetch --json 2>&1)
contains "L: version json null without a checkout" "$OUT" '"follow":null,"follow_verdict":null'

# --- usage ----------------------------------------------------------------------
sh "$FL" --bogus >/dev/null 2>&1; eq "usage: unknown flag exits 2" 2 "$?"
OUT=$(sh "$FL" --help 2>&1); contains "usage: --help prints the header" "$OUT" "following refs/tags/stable"

printf 'install-follow-selftest OK (%d checks)\n' "$CHECKS"
