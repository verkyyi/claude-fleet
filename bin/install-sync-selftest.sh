#!/bin/bash
# install-sync-selftest.sh — bin/fleet-install-sync.sh against a local bare repo
# + a throwaway install, fully hermetic (issue #1120, EPIC #1117 C3).
#
# A local BARE repo stands in for github (its refs/tags/stable is moved with
# update-ref — the real tag and the network are never touched); a clone of it is
# the install the daemon moves. The clone's bin/ carries STUB apply / doctor /
# diskguard scripts, committed like the real ones so each VERSION brings its own
# — which is how "the new version's doctor fails" is staged: commit C4 ships a
# doctor that prints a FAIL line, C5 ships the fix. tmux is a PATH shim reading
# window states from a file; the fleet conf dir is a temp dir with one fleet.
#
# What it pins:
#   A. forward       HEAD behind stable → ff, the NEW version's apply
#                    --from <old> --to <stable>, doctor run before and after
#   B. current       HEAD == stable → nothing runs
#   C. backward      stable behind HEAD → refused, HEAD untouched
#   D. dirty         a tracked local change → refused, names the file
#   E. busy          a working window on any live fleet → deferred, with
#                    deferred_since kept across ticks; idle → the move happens
#   M. disk gate     gate closed → deferred
#   O. epic running  a fresh epic-running mark (fleet-epic-heartbeat.sh, #953) →
#                    deferred, names the epic, before the disk gate is asked; a
#                    stale (ttl passed) or --clear'ed mark → the next gate
#                    decides; a bare touch counts from mtime; --status 0/1/2
#   F. rollback      a FAIL line the new doctor prints → reset --hard + the OLD
#                    version's apply back; that version is skipped until stable
#                    moves; the next stable move is followed
#   G. baseline      a FAIL the login already had is NOT a rollback
#   H. off           FLEET_INSTALL_SYNC=0 → no fetch, no move, state says off
#   I. not seen      a failed fetch is fetch-failed (not refused); no tag = none
#   J. dry-run       prints the move, changes nothing, writes no state
#   N. lock          a live lock skips the tick
#   L. --status      prints the state file
#   K. registry      plist StartInterval / systemd timer / daemon table agree
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
IS="$BIN/fleet-install-sync.sh"
[ -f "$IS" ] || { printf 'selftest: %s not found\n' "$IS" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo 'install-sync-selftest SKIP (no git)'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/install-sync-selftest.XXXXXX")" || exit 2
WORK=$(cd "$WORK" && pwd -P)
cleanup() { rm -rf "$WORK"; }
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

# --- sandbox: HOME, conf dir with one fleet, TMPDIR, tmux shim ------------------
H="$WORK/home" CONF="$WORK/conf" LOG="$WORK/calls.log"
mkdir -p "$H" "$CONF/fleets/f1" "$WORK/tmp" "$WORK/shim" "$WORK/tmux-up" "$WORK/tmux-states"
: > "$LOG"
printf 'FLEET_REPO=o/r\n' > "$CONF/fleets/f1/conf"
touch "$WORK/tmux-up/f1"; printf 'done\n' > "$WORK/tmux-states/f1"
cat > "$WORK/shim/tmux" <<EOF
#!/bin/sh
# tmux -L <sess> has-session -t <sess> | list-windows -a -F <fmt>
sess="\$2"
case "\$3" in
  has-session)  [ -f "$WORK/tmux-up/\$sess" ] ;;
  list-windows) cat "$WORK/tmux-states/\$sess" 2>/dev/null ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/shim/tmux"
export HOME="$H" FLEET_CONF_DIR="$CONF" TMPDIR="$WORK/tmp" FLEET_SKIP_GLOBAL_CONF=1
export PATH="$WORK/shim:$PATH"
STATE="$CONF/global/install-sync.state"

# --- the repo: bare origin + seed clone with stub bin/ ----------------------------
BARE="$WORK/origin.git" SEED="$WORK/seed" CO="$WORK/install"
git init -q --bare -b master "$BARE"
git clone -q "$BARE" "$SEED" 2>/dev/null
mkdir -p "$SEED/bin" "$SEED/logs"
cat > "$SEED/bin/fleet-install-apply.sh" <<EOF
#!/bin/bash
echo "apply \$*" >> "$LOG"
[ -f "$WORK/apply-partial" ] && { echo 'daemons: FAIL stub'; echo 'apply: PARTIAL — 1 step(s) failed'; exit 1; }
echo 'layout: ok'
echo 'apply: ok — stub'
EOF
doctor_stub() { # $1 = extra line the doctor of THIS version prints ('' = none)
  cat > "$SEED/bin/fleet-doctor.sh" <<EOF
#!/bin/sh
echo "doctor" >> "$LOG"
echo '  PASS  gh       ok'
echo '  WARN  install  behind (a WARN never counts)'
[ -f "$WORK/doctor-fail-always" ] && echo '  FAIL  quota    cache stale (pre-existing)'
${1:+echo '$1'}
exit 0
EOF
}
doctor_stub ''
cat > "$SEED/bin/fleet-diskguard.sh" <<EOF
#!/bin/sh
[ "\$1" = --gate ] && [ -f "$WORK/gate-closed" ] && exit 1
exit 0
EOF
chmod +x "$SEED"/bin/*
commit() { echo "$1" >> "$SEED/f"; git -C "$SEED" add -A; git -C "$SEED" commit -qm "$1"; git -C "$SEED" rev-parse HEAD; }
C1=$(commit one); C2=$(commit two); C3=$(commit three)
doctor_stub '  FAIL  gh       boom (this version is broken)'; C4=$(commit four-broken)
doctor_stub '';                                              C5=$(commit five-fixed)
C6=$(commit six); C7=$(commit seven)
git -C "$SEED" push -q origin master
stable() { git --git-dir="$BARE" update-ref refs/tags/stable "$1"; }
unstable() { git --git-dir="$BARE" update-ref -d refs/tags/stable; }
git clone -q "$BARE" "$CO" 2>/dev/null
git -C "$CO" reset -q --hard "$C1"
hd() { git -C "$CO" rev-parse HEAD; }
short() { printf '%.7s' "$1"; }

run() { OUT=$(bash "$IS" --root "$CO" "$@" 2>&1); RC=$?; }
st() { sed -n "s/^$1: //p" "$STATE" | head -1; }
applies() { grep -c '^apply ' "$LOG"; }
doctors() { grep -c '^doctor$' "$LOG"; }
lastlog() { tail -1 "$CO/logs/install-sync.log"; }

# --- A. forward -----------------------------------------------------------------------
stable "$C2"
run
eq "A: tick exits 0" 0 "$RC"
eq "A: result updated" updated "$(st result)"
eq "A: HEAD at stable" "$C2" "$(hd)"
eq "A: from" "$C1" "$(st from)"; eq "A: to" "$C2" "$(st to)"
eq "A: apply called once, --from old --to stable" "apply --from $C1 --to $C2 --root $CO" "$(grep '^apply ' "$LOG" | tail -1)"
eq "A: doctor ran before and after" 2 "$(doctors)"
eq "A: apply line recorded" 'ok — stub' "$(st apply)"
contains "A: log line" "$(lastlog)" "updated $(short "$C1")..$(short "$C2")"
eq "A: skip empty" - "$(st skip)"; eq "A: deferred_since empty" - "$(st deferred_since)"
eq "A: stable recorded" "$C2" "$(st stable)"

# --- B. current -------------------------------------------------------------------------
n=$(applies); run
eq "B: result current" current "$(st result)"
eq "B: no apply" "$n" "$(applies)"
contains "B: log line" "$(lastlog)" "current $(short "$C2")..$(short "$C2")"

# --- C. backward --------------------------------------------------------------------------
stable "$C1"; n=$(applies); run
eq "C: result refused" refused "$(st result)"
eq "C: HEAD untouched" "$C2" "$(hd)"
contains "C: says not a descendant" "$(st reason)" "is not a descendant of HEAD"
contains "C: says behind" "$(st reason)" "behind this install (1 commit(s))"
eq "C: no apply" "$n" "$(applies)"

# --- D. dirty -------------------------------------------------------------------------------
stable "$C3"; echo edited >> "$CO/f"; run
eq "D: result refused" refused "$(st result)"
eq "D: HEAD untouched" "$C2" "$(hd)"
contains "D: names the file" "$(st reason)" "tracked local changes in $CO (f)"
git -C "$CO" checkout -q -- f
eq "D: no apply" "$n" "$(applies)"

# --- E. busy -----------------------------------------------------------------------------------
printf 'done\nworking\n' > "$WORK/tmux-states/f1"; run
eq "E: result deferred" deferred "$(st result)"
eq "E: HEAD untouched" "$C2" "$(hd)"
contains "E: names the fleet + count" "$(st reason)" "busy window(s) on f1:1"
T1=$(st deferred_since); case "$T1" in ''|-|*[!0-9]*) fail "E: deferred_since not an epoch: [$T1]" ;; esac; CHECKS=$((CHECKS + 1))
printf 'looping\n' > "$WORK/tmux-states/f1"; sleep 1; run
eq "E: still deferred on looping" deferred "$(st result)"
eq "E: deferred_since kept across ticks" "$T1" "$(st deferred_since)"
printf 'waking\n' > "$WORK/tmux-states/f1"; run
eq "E: still deferred on waking" deferred "$(st result)"
# a busy window on a fleet whose server is DOWN is no fleet at all
rm "$WORK/tmux-up/f1"; printf 'working\n' > "$WORK/tmux-states/f1"; run
eq "E: a down fleet cannot defer" updated "$(st result)"
eq "E: moved once idle" "$C3" "$(hd)"
eq "E: deferred_since cleared" - "$(st deferred_since)"
touch "$WORK/tmux-up/f1"; printf 'done\n' > "$WORK/tmux-states/f1"

# --- M. disk gate ---------------------------------------------------------------------------------
stable "$C4"; touch "$WORK/gate-closed"; n=$(applies); run
eq "M: result deferred" deferred "$(st result)"
contains "M: says disk gate" "$(st reason)" "disk gate closed"
eq "M: HEAD untouched" "$C3" "$(hd)"; eq "M: no apply" "$n" "$(applies)"

# --- O. a running EPIC batch (issue #953) ------------------------------------------------------
# stable C4 is still ahead and M's disk gate is still closed, so WHICH reason wins
# is the assertion: a fresh mark defers for the EPIC before the disk gate is even
# asked; a stale or cleared one falls through to it — HEAD never moves either way.
HB="$BIN/fleet-epic-heartbeat.sh"
T1=$(st deferred_since)
OUT=$(bash "$HB" 1117 --tick 3 --repo o/r --session f1 2>&1); RC=$?
eq "O: stamp exits 0" 0 "$RC"; contains "O: stamp says what it wrote" "$OUT" "stamped epic=1117 session=f1 tick=3 ttl=2700s"
[ -f "$CONF/global/epic-running" ] || fail "O: no epic-running mark written"; CHECKS=$((CHECKS + 1))
eq "O: mark carries the epic" 1117 "$(sed -n 's/^epic: //p' "$CONF/global/epic-running")"
n=$(applies); run
eq "O: result deferred" deferred "$(st result)"
contains "O: names the epic, before the disk gate" "$(st reason)" "EPIC batch running on this login (epic=1117 session=f1 tick=3"
contains "O: says why" "$(st reason)" "issue #953"
not_contains "O: the disk gate was not reached" "$(st reason)" "disk gate"
eq "O: HEAD untouched" "$C3" "$(hd)"; eq "O: no apply" "$n" "$(applies)"
eq "O: deferred_since kept from the disk-gate deferral" "$T1" "$(st deferred_since)"
contains "O: log line" "$(lastlog)" "deferred $(short "$C3")..$(short "$C4") EPIC batch running"
OUT=$(bash "$HB" --status 2>&1); RC=$?
eq "O: --status fresh exits 0" 0 "$RC"; contains "O: --status prints the mark" "$OUT" "fresh epic=1117 session=f1 tick=3"
# a LEASE: written with a 1 s ttl it expires, and the tick goes on to the next gate
bash "$HB" 1117 --ttl 1 --session f1 >/dev/null 2>&1; sleep 2; run
eq "O: a stale mark still defers (the disk gate)" deferred "$(st result)"
contains "O: … for the disk gate, not the EPIC" "$(st reason)" "disk gate closed"
not_contains "O: stale mark is not the reason" "$(st reason)" "EPIC"
OUT=$(bash "$HB" --status 2>&1); RC=$?
eq "O: --status stale exits 1" 1 "$RC"; contains "O: --status says stale" "$OUT" "stale epic=1117"
# --clear lifts it outright
bash "$HB" 1117 --session f1 >/dev/null 2>&1; OUT=$(bash "$HB" --clear 2>&1); RC=$?
eq "O: --clear exits 0" 0 "$RC"; contains "O: --clear says so" "$OUT" "cleared"
[ -f "$CONF/global/epic-running" ] && fail "O: --clear left the mark"; CHECKS=$((CHECKS + 1))
run; contains "O: cleared → the disk gate decides" "$(st reason)" "disk gate closed"
OUT=$(bash "$HB" --status 2>&1); RC=$?; eq "O: --status with no mark exits 2" 2 "$RC"
# a bare touch (no epoch:) is a hand override, counted from mtime
: > "$CONF/global/epic-running"; run
contains "O: a bare touch defers too" "$(st reason)" "EPIC batch running on this login (epic=- session=- tick=-"
rm -f "$CONF/global/epic-running"
# usage
OUT=$(bash "$HB" 2>&1); RC=$?; eq "O: no epic is a usage error" 2 "$RC"
OUT=$(bash "$HB" 1117 --ttl 0 2>&1); RC=$?; eq "O: --ttl 0 is a usage error" 2 "$RC"
[ -f "$CONF/global/epic-running" ] && fail "O: a usage error must not stamp"; CHECKS=$((CHECKS + 1))
rm "$WORK/gate-closed"

# --- F. rollback ----------------------------------------------------------------------------------
: > "$LOG"; run
eq "F: result rolled-back" rolled-back "$(st result)"
eq "F: HEAD back at the previous version" "$C3" "$(hd)"
eq "F: forward apply then rollback apply" "apply --from $C3 --to $C4 --root $CO
apply --from $C4 --to $C3 --root $CO" "$(grep '^apply ' "$LOG")"
eq "F: doctor before, after, none for the rollback" 2 "$(doctors)"
contains "F: names the new FAIL tag" "$(st reason)" "doctor FAIL after update: gh"
eq "F: skip = the rejected version" "$C4" "$(st skip)"
eq "F: from/to describe the rollback" "$C4 $C3" "$(st from) $(st to)"
contains "F: log line" "$(lastlog)" "rolled-back $(short "$C4")..$(short "$C3")"
: > "$LOG"; run
eq "F: next tick skipped" skipped "$(st result)"
eq "F: nothing ran" 0 "$(applies)"
eq "F: skip kept" "$C4" "$(st skip)"
contains "F: says why" "$(st reason)" "not retried until stable moves"
stable "$C5"; : > "$LOG"; run
eq "F: the next stable is followed" updated "$(st result)"
eq "F: HEAD at the fix" "$C5" "$(hd)"
eq "F: skip cleared" - "$(st skip)"
eq "F: apply --from old --to new" "apply --from $C3 --to $C5 --root $CO" "$(grep '^apply ' "$LOG")"

# --- G. a pre-existing FAIL is not the new version's -----------------------------------------------
touch "$WORK/doctor-fail-always"; stable "$C6"; run
eq "G: updated, not rolled back" updated "$(st result)"
eq "G: HEAD at stable" "$C6" "$(hd)"
contains "G: says the FAIL predates it" "$(st reason)" "doctor FAIL already present before: quota"
rm "$WORK/doctor-fail-always"
# apply PARTIAL alone is not a rollback either — the doctor decides
touch "$WORK/apply-partial"; stable "$C7"; run
eq "G: PARTIAL apply, doctor clean → updated" updated "$(st result)"
contains "G: PARTIAL recorded" "$(st apply)" "PARTIAL"
rm "$WORK/apply-partial"
git -C "$CO" reset -q --hard "$C6"    # back one for the tests below

# --- H. off ---------------------------------------------------------------------------------------------
git --git-dir="$CO/.git" update-ref refs/tags/stable "$C6"   # a stale local tag: off must not refresh it
: > "$LOG"; OUT=$(FLEET_INSTALL_SYNC=0 bash "$IS" --root "$CO" 2>&1); RC=$?
eq "H: exits 0" 0 "$RC"
eq "H: result off" off "$(st result)"
contains "H: says how to switch on" "$(st reason)" "FLEET_INSTALL_SYNC=0"
eq "H: no fetch (local tag untouched)" "$C6" "$(git -C "$CO" rev-parse refs/tags/stable)"
eq "H: HEAD untouched" "$C6" "$(hd)"; eq "H: nothing ran" 0 "$(applies)"
contains "H: log line" "$(lastlog)" " off "

# --- I. not seen ---------------------------------------------------------------------------------------
url=$(git -C "$CO" remote get-url origin)
git -C "$CO" remote set-url origin "$WORK/nowhere.git"; run
eq "I: fetch failure is fetch-failed" fetch-failed "$(st result)"
contains "I: says not refused" "$(st reason)" "not seen, not refused"
eq "I: HEAD untouched" "$C6" "$(hd)"
git -C "$CO" remote set-url origin "$url"
unstable; run
eq "I: no tag is none" none "$(st result)"
eq "I: stable none" none "$(st stable)"
contains "I: says what to do" "$(st reason)" "fleet-stable.sh move"
stable "$C7"

# --- J. dry-run ------------------------------------------------------------------------------------------
before=$(st last_check); sleep 1; : > "$LOG"; run --dry-run
eq "J: exits 0" 0 "$RC"
contains "J: prints the move" "$OUT" "would ff $CO $(short "$C6")..$(short "$C7")"
eq "J: HEAD untouched" "$C6" "$(hd)"
eq "J: nothing ran" 0 "$(applies)"
eq "J: no state written" "$before" "$(st last_check)"
# dry-run reports a refusal too, without recording it
echo edited >> "$CO/f"; run --dry-run
contains "J: dry-run refusal printed" "$OUT" "refused: tracked local changes"
eq "J: still no state written" "$before" "$(st last_check)"
git -C "$CO" checkout -q -- f

# --- N. lock ---------------------------------------------------------------------------------------------
mkdir -p "$CONF/global/install-sync.lock"; date +%s > "$CONF/global/install-sync.lock/ts"; run
contains "N: a live lock skips the tick" "$OUT" "another tick holds"
eq "N: HEAD untouched" "$C6" "$(hd)"
printf '1\n' > "$CONF/global/install-sync.lock/ts"; run     # a dead tick's lock is taken over
eq "N: a stale lock is taken over" updated "$(st result)"
eq "N: moved" "$C7" "$(hd)"
[ -d "$CONF/global/install-sync.lock" ] && fail "N: lock left behind"; CHECKS=$((CHECKS + 1))

# --- L. --status -------------------------------------------------------------------------------------------
run --status
eq "L: exits 0" 0 "$RC"; contains "L: prints the state" "$OUT" "result: updated"
OUT=$(FLEET_CONF_DIR="$WORK/empty" bash "$IS" --root "$CO" --status 2>&1); RC=$?
eq "L: no state exits 1" 1 "$RC"; contains "L: says none" "$OUT" "no state yet"

# --- K. registry lockstep ------------------------------------------------------------------------------------
ROOT="$(cd "$BIN/.." && pwd)"
iv=$(sed -n 's|.*<key>StartInterval</key><integer>\([0-9]*\)</integer>.*|\1|p' "$ROOT/launchd/com.claude-fleet.install-sync.plist.tmpl")
eq "K: plist StartInterval 1800" 1800 "$iv"
eq "K: systemd timer 1800" 1800 "$(sed -n 's/^OnUnitActiveSec=//p' "$ROOT/systemd/claude-fleet-install-sync.timer")"
eq "K: daemon table 1800" 1800 "$( . "$BIN/fleet-daemon-lib.sh"; fleet_daemon_interval install-sync )"
grep -q '<key>ProcessType</key><string>Standard</string>' "$ROOT/launchd/com.claude-fleet.install-sync.plist.tmpl" \
  || fail "K: install-sync must be ProcessType=Standard (it rewrites bin/, issue #588)"; CHECKS=$((CHECKS + 1))
grep -q '^#FLEET_INSTALL_SYNC=1$' "$ROOT/fleet.conf.example" || fail "K: fleet.conf.example lacks #FLEET_INSTALL_SYNC=1"; CHECKS=$((CHECKS + 1))
grep -q 'FLEET_INSTALL_SYNC' "$BIN/fleet-lib.sh" || fail "K: FLEET_INSTALL_SYNC not in _FLEET_GLOBAL_ONLY"; CHECKS=$((CHECKS + 1))

printf 'install-sync-selftest OK (%d checks)\n' "$CHECKS"
