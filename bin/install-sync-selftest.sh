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
#   A. forward       HEAD behind stable → the plain-dir install is MIGRATED
#                    (moved to <root>.versions/<HEAD>/, the link in its place,
#                    logs/ + untracked files shared via .shared/), the new
#                    version checked out beside it and the link switched; the
#                    NEW version's apply --from <old> --to <stable>, doctor run
#                    before and after; .prev names the old one (issue #1894)
#   B. current       HEAD == stable → nothing runs
#   C. backward      stable behind HEAD → refused, HEAD untouched
#   D. dirty         a tracked local change → refused, names the file
#   E. busy          working / looping / waking windows no longer defer: the
#                    switch happens under them (issue #1894)
#   R. running       a script started from the old version before the switch
#                    reads its own file and its siblings (by physical path) to
#                    the end — the old ones; a fresh call reads the new
#   V. check         a new version whose bin/*.sh does not parse is rejected
#                    BEFORE the switch: nothing switched, no apply, skipped
#                    until stable moves
#   W. prune         a retired version past FLEET_INSTALL_VERSIONS_KEEP_SECS is
#                    removed (worktree + branch); the current, .prev and the
#                    repository's checkout never are
#   M. disk gate     gate closed → deferred
#   O. epic running  (issue #953; one mark per batch, #2062) a fresh mark —
#                    global/epic-running.d/<repo>-<N>, fleet-epic-heartbeat.sh —
#                    defers the tick BEFORE the disk gate and before the switch:
#                    two batches A, B on one login each keep their own mark and
#                    the reason names both; A expired + B fresh → deferred on B;
#                    --clear <N> takes one mark, never the other's (a bare
#                    --clear refuses with two, clears with one); all expired →
#                    the disk gate decides; the legacy single file is still read
#                    (never written); a fresh mark + stable moving → deferred
#                    ticks only, NEVER switched, until the batch clears its mark;
#                    the heartbeat's CLI (stamp / --status 0/1/2 / usage) pinned
#   F. rollback      a FAIL line the new doctor prints → the link back + the OLD
#                    version's apply back; that version is skipped until stable
#                    moves; the next stable move is followed
#   G. baseline      a FAIL the login already had is NOT a rollback
#   H. off           FLEET_INSTALL_SYNC=0 → no fetch, no move, state says off
#   I. not seen      a failed fetch is fetch-failed (not refused); no tag = none
#   J. dry-run       prints the move, changes nothing, writes no state
#   N. lock          a live lock skips the tick (the skip names its pid); a dead
#                    holder's lock (SIGKILL mid-tick, #1691) is taken over at once;
#                    LOCK_TTL takes over a live-pid lock as the backstop
#   L. --status      prints the state file
#   P. notify        (issue #1125) a stuck tick sends ONE FLEET_NOTIFY_CMD per
#                    (login, why, stable): the same refusal three ticks = one
#                    message naming the login, the reason and the off switch;
#                    fetch-failed keeps the episode; following again clears it
#                    and the same reason on the next stable is announced again;
#                    another reason on the same stable is its own message; a
#                    deferral past FLEET_INSTALL_FOLLOW_STUCK_SECS is one, a
#                    short one none; rolled-back once (its skipped ticks are
#                    silent); a failed send is retried; no channel / dry-run /
#                    off send nothing; the send is a `notified` log line
#   Q. node agent    (issue #1723) a fake fleet-node-upgrade.sh: stable moves and
#                    the agent is behind → ONE upgrade (--dist --rollback --logins
#                    <me>) and node: upgraded; the next tick, agent current → no
#                    upgrade call; a failure → node_upgrade_failed + ONE notify +
#                    the next tick is backoff (no call, no 2nd message), a retry
#                    after the window fails silently, a stable move retries at
#                    once; a current tick with a busy window → deferred; a
#                    LaunchDaemon login without sudo → delegated, with sudo it
#                    upgrades the others too (own first); FLEET_NODE_FOLLOW=0 →
#                    off; no agent → none; dry-run prints, calls only --dry-run;
#                    no fleet-node-upgrade.sh → no node record (the degenerate)
#   K. registry      plist StartInterval / systemd timer / daemon table agree
#
# The switch itself is bin/fleet-versions-lib.sh (fleet_versions_point /
# fleet_versions_adopt / fleet_versions_current), shared with the client (C7).
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
C1=$(commit one); C2=$(commit two); C3=$(commit three); C3a=$(commit three-a)
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

# --- A. forward (and the migration to the versions layout, #1894) --------------------
V="$CO.versions"
cur() { r=$(readlink "$CO"); r=${r%/}; printf '%s' "${r##*/}"; }
printf 'FLEET_X=1\n' > "$CO/fleet.conf"; mkdir -p "$CO/logs"; echo old > "$CO/logs/keep.log"
stable "$C2"
run
eq "A: tick exits 0" 0 "$RC"
eq "A: result switched" switched "$(st result)"
[ -L "$CO" ] || fail "A: the install is not a link after the first switch"; CHECKS=$((CHECKS + 1))
eq "A: the link points at the new version" "$V/$C2" "$(readlink "$CO")"
[ -d "$V/$C1/.git" ] || fail "A: the old checkout (the repository) is not at $V/$C1"; CHECKS=$((CHECKS + 1))
eq "A: .prev names the old version" "$C1" "$(cat "$V/.prev")"
eq "A: the new version is a worktree on its own branch" "fleet-live/$C2" "$(git -C "$CO" symbolic-ref --short HEAD)"
eq "A: …tracking the trunk" "origin/master" "$(git -C "$CO" rev-parse --abbrev-ref '@{upstream}')"
eq "A: logs/ is shared" "../.shared/logs" "$(readlink "$CO/logs")"
eq "A: …in the old version too" "../.shared/logs" "$(readlink "$V/$C1/logs")"
eq "A: an old log survives the migration" old "$(cat "$CO/logs/keep.log")"
eq "A: an untracked fleet.conf is shared" "FLEET_X=1" "$(cat "$CO/fleet.conf")"
eq "A: …once" "../.shared/fleet.conf" "$(readlink "$CO/fleet.conf")"
contains "A: the reason says it migrated" "$(st reason)" "is now a link into $V/"
contains "A: the reason names .prev" "$(st reason)" ".prev $(short "$C1")"
eq "A: HEAD at stable" "$C2" "$(hd)"
eq "A: from" "$C1" "$(st from)"; eq "A: to" "$C2" "$(st to)"
eq "A: apply called once, --from old --to stable" "apply --from $C1 --to $C2 --root $CO" "$(grep '^apply ' "$LOG" | tail -1)"
eq "A: doctor ran before and after" 2 "$(doctors)"
eq "A: apply line recorded" 'ok — stub' "$(st apply)"
contains "A: log line" "$(lastlog)" "switched $(short "$C1")..$(short "$C2")"
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

# --- E. busy windows no longer defer (issue #1894) -----------------------------------------------
printf 'working\nlooping\nwaking\nlooping|loop|kind=cron id=j1@1 at=j1@1\n' > "$WORK/tmux-states/f1"; run
eq "E: switched under working / looping / waking windows" switched "$(st result)"
eq "E: HEAD at stable" "$C3" "$(hd)"
eq "E: deferred_since empty" - "$(st deferred_since)"
not_contains "E: busy is no reason any more" "$(st reason)" "busy window"
printf 'done\n' > "$WORK/tmux-states/f1"

# --- M. disk gate ---------------------------------------------------------------------------------
stable "$C4"; touch "$WORK/gate-closed"; n=$(applies); run
eq "M: result deferred" deferred "$(st result)"
eq "M: the link untouched" "$V/$C3" "$(readlink "$CO")"
[ -e "$V/$C4" ] && fail "M: a version was checked out under a closed disk gate"; CHECKS=$((CHECKS + 1))
contains "M: says disk gate" "$(st reason)" "disk gate closed"
eq "M: HEAD untouched" "$C3" "$(hd)"; eq "M: no apply" "$n" "$(applies)"

# --- O. a running EPIC batch (issue #953; one mark per batch, #2062) -----------------------------
# stable C4 is still ahead and M's disk gate is still closed, so WHICH reason wins
# is the assertion: a fresh mark defers for the EPIC before the disk gate is even
# asked; a stale or cleared one falls through to it — HEAD never moves either way.
HB="$BIN/fleet-epic-heartbeat.sh"; EPD="$CONF/global/epic-running.d"
T1=$(st deferred_since)
OUT=$(bash "$HB" 1117 --tick 3 --repo o/r --session f1 2>&1); RC=$?
eq "O: stamp exits 0" 0 "$RC"; contains "O: stamp says what it wrote" "$OUT" "stamped epic=1117 session=f1 tick=3 ttl=2700s"
[ -f "$EPD/o-r-1117" ] || fail "O: no per-batch mark written (epic-running.d/o-r-1117)"; CHECKS=$((CHECKS + 1))
[ -e "$CONF/global/epic-running" ] && fail "O: the legacy single file was written"; CHECKS=$((CHECKS + 1))
eq "O: mark carries the epic" 1117 "$(sed -n 's/^epic: //p' "$EPD/o-r-1117")"
n=$(applies); run
eq "O: result deferred" deferred "$(st result)"
contains "O: the EPIC is the reason, before the disk gate" "$(st reason)" "EPIC batch running on this login (epic=1117 session=f1 tick=3"
not_contains "O: …not the disk gate" "$(st reason)" "disk gate"
eq "O: HEAD untouched" "$C3" "$(hd)"; eq "O: no apply" "$n" "$(applies)"
eq "O: deferred_since kept from the disk-gate deferral" "$T1" "$(st deferred_since)"
contains "O: log line" "$(lastlog)" "deferred $(short "$C3")..$(short "$C4") EPIC batch running"
# a second batch on the same login: its own file, the first one's untouched (#2062)
OUT=$(bash "$HB" 1982 --tick 10 --repo o/r --session f1 2>&1)
[ -f "$EPD/o-r-1982" ] || fail "O: the second batch has no mark of its own"; CHECKS=$((CHECKS + 1))
eq "O: the first batch's mark is untouched" 3 "$(sed -n 's/^tick: //p' "$EPD/o-r-1117")"
run
eq "O: still deferred" deferred "$(st result)"
contains "O: the reason names the first batch" "$(st reason)" "epic=1117"
contains "O: …and the second" "$(st reason)" "epic=1982"
OUT=$(bash "$HB" --status 2>&1); RC=$?
eq "O: --status fresh exits 0" 0 "$RC"; contains "O: --status lists the first" "$OUT" "fresh epic=1117 session=f1 tick=3"
contains "O: --status lists the second" "$OUT" "fresh epic=1982 session=f1 tick=10"
# a LEASE: the first, rewritten with a 1 s ttl, expires; the second still holds
bash "$HB" 1117 --ttl 1 --tick 4 --repo o/r --session f1 >/dev/null 2>&1; sleep 2
run
eq "O: one stale + one fresh = deferred" deferred "$(st result)"
contains "O: …on the fresh one" "$(st reason)" "epic=1982"
not_contains "O: …not the stale one" "$(st reason)" "epic=1117"
OUT=$(bash "$HB" --status 2>&1); RC=$?
eq "O: --status with one fresh exits 0" 0 "$RC"; contains "O: --status says stale for the first" "$OUT" "stale epic=1117"
# --clear <N> takes ONE batch's mark, never the other's (#2062)
OUT=$(bash "$HB" --clear 1982 2>&1); RC=$?
eq "O: --clear <N> exits 0" 0 "$RC"; contains "O: --clear says so" "$OUT" "cleared $EPD/o-r-1982"
[ -e "$EPD/o-r-1982" ] && fail "O: --clear 1982 left its mark"; CHECKS=$((CHECKS + 1))
[ -f "$EPD/o-r-1117" ] || fail "O: --clear 1982 took the other batch's mark"; CHECKS=$((CHECKS + 1))
OUT=$(bash "$HB" --status 2>&1); RC=$?
eq "O: --status all stale exits 1" 1 "$RC"; contains "O: --status says stale" "$OUT" "stale epic=1117"
# every mark stale → the tick falls through to the disk gate
run
eq "O: all stale = the disk gate decides" deferred "$(st result)"
contains "O: the disk gate is the reason" "$(st reason)" "disk gate closed"
not_contains "O: no EPIC in the reason" "$(st reason)" "EPIC"
# a bare --clear (the pre-#2062 form) refuses with two batches marked, clears with one
bash "$HB" 1982 --repo o/r --session f1 >/dev/null 2>&1
OUT=$(bash "$HB" --clear 2>&1); RC=$?
eq "O: a bare --clear with two batches marked refuses" 2 "$RC"; contains "O: …and says how" "$OUT" "--clear <epic> clears ONE"
{ [ -f "$EPD/o-r-1117" ] && [ -f "$EPD/o-r-1982" ]; } || fail "O: the refused --clear removed a mark"; CHECKS=$((CHECKS + 1))
bash "$HB" --clear 1117 >/dev/null 2>&1
OUT=$(bash "$HB" --clear 2>&1); RC=$?
eq "O: a bare --clear with one mark clears it" 0 "$RC"
[ -e "$EPD/o-r-1982" ] && fail "O: the bare --clear left the one mark"; CHECKS=$((CHECKS + 1))
OUT=$(bash "$HB" --status 2>&1); RC=$?; eq "O: --status with no mark exits 2" 2 "$RC"
OUT=$(bash "$HB" --clear 1117 2>&1); RC=$?; eq "O: --clear of nothing exits 0" 0 "$RC"; contains "O: …says nothing to clear" "$OUT" "nothing to clear for epic=1117"
# the pre-#2062 single file is still read for one version (compat-1v), never written
printf 'epoch: %s\nttl: 2700\nepic: 883\nsession: f1\ntick: 1\n' "$(date +%s)" > "$CONF/global/epic-running"
OUT=$(bash "$HB" --status 2>&1); RC=$?
eq "O: a legacy mark still reads fresh" 0 "$RC"; contains "O: …as its epic" "$OUT" "fresh epic=883"
run; contains "O: …and still defers" "$(st reason)" "epic=883"
bash "$HB" --clear 883 >/dev/null 2>&1
[ -e "$CONF/global/epic-running" ] && fail "O: --clear 883 left the legacy mark"; CHECKS=$((CHECKS + 1))
# usage
OUT=$(bash "$HB" 2>&1); RC=$?; eq "O: no epic is a usage error" 2 "$RC"
OUT=$(bash "$HB" 1117 --ttl 0 2>&1); RC=$?; eq "O: --ttl 0 is a usage error" 2 "$RC"
OUT=$(bash "$HB" --clear x 2>&1); RC=$?; eq "O: --clear x is a usage error" 2 "$RC"
[ -n "$(ls "$EPD" 2>/dev/null)" ] && fail "O: a usage error must not stamp"; CHECKS=$((CHECKS + 1))
# the whole point (#2062): the disk gate open, stable moving, a fresh mark → the
# tick is deferred and the version does not move — on every tick, never switched
rm "$WORK/gate-closed"; bash "$HB" 1117 --tick 5 --repo o/r --session f1 >/dev/null 2>&1; stable "$C3a"
: > "$CO/logs/install-sync.log"; run; run
eq "O: a fresh mark holds the switch" deferred "$(st result)"
eq "O: HEAD still at C3" "$C3" "$(hd)"
eq "O: the link untouched" "$V/$C3" "$(readlink "$CO")"
[ -e "$V/$C3a" ] && fail "O: a version was checked out under a fresh mark"; CHECKS=$((CHECKS + 1))
eq "O: no switched line while the mark is fresh" 0 "$(grep -c ' switched ' "$CO/logs/install-sync.log")"
eq "O: two ticks, two deferred lines" 2 "$(grep -c ' deferred ' "$CO/logs/install-sync.log")"
run --dry-run
contains "O: dry-run defers too" "$OUT" "deferred: EPIC batch running"
# the batch ends: its loop clears its own mark; the next tick switches
bash "$HB" --clear 1117 >/dev/null 2>&1; run
eq "O: switched after the clear" switched "$(st result)"
eq "O: …to stable" "$C3a" "$(hd)"
stable "$C4"

# --- F. rollback ----------------------------------------------------------------------------------
: > "$LOG"; run
eq "F: result rolled-back" rolled-back "$(st result)"
eq "F: HEAD back at the previous version" "$C3a" "$(hd)"
eq "F: the link is back" "$V/$C3a" "$(readlink "$CO")"
eq "F: .prev names the rejected version" "$C4" "$(cat "$V/.prev")"
eq "F: forward apply then rollback apply" "apply --from $C3a --to $C4 --root $CO
apply --from $C4 --to $C3a --root $CO" "$(grep '^apply ' "$LOG")"
eq "F: doctor before, after, none for the rollback" 2 "$(doctors)"
contains "F: names the new FAIL tag" "$(st reason)" "doctor FAIL after the switch: gh"
eq "F: skip = the rejected version" "$C4" "$(st skip)"
eq "F: from/to describe the rollback" "$C4 $C3a" "$(st from) $(st to)"
contains "F: log line" "$(lastlog)" "rolled-back $(short "$C4")..$(short "$C3a")"
: > "$LOG"; run
eq "F: next tick skipped" skipped "$(st result)"
eq "F: nothing ran" 0 "$(applies)"
eq "F: skip kept" "$C4" "$(st skip)"
contains "F: says why" "$(st reason)" "not retried until stable moves"
stable "$C5"; : > "$LOG"; run
eq "F: the next stable is followed" switched "$(st result)"
eq "F: HEAD at the fix" "$C5" "$(hd)"
eq "F: skip cleared" - "$(st skip)"
eq "F: apply --from old --to new" "apply --from $C3a --to $C5 --root $CO" "$(grep '^apply ' "$LOG")"

# --- G. a pre-existing FAIL is not the new version's -----------------------------------------------
touch "$WORK/doctor-fail-always"; stable "$C6"; run
eq "G: switched, not rolled back" switched "$(st result)"
eq "G: HEAD at stable" "$C6" "$(hd)"
contains "G: says the FAIL predates it" "$(st reason)" "doctor FAIL already present before: quota"
rm "$WORK/doctor-fail-always"
# apply PARTIAL alone is not a rollback either — the doctor decides
touch "$WORK/apply-partial"; stable "$C7"; run
eq "G: PARTIAL apply, doctor clean → switched" switched "$(st result)"
contains "G: PARTIAL recorded" "$(st apply)" "PARTIAL"
rm "$WORK/apply-partial"
git -C "$CO" reset -q --hard "$C6"    # back one for the tests below

# --- H. off ---------------------------------------------------------------------------------------------
git -C "$CO" update-ref refs/tags/stable "$C6"   # a stale local tag: off must not refresh it
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
contains "J: prints the move" "$OUT" "would switch $CO $(short "$C6")..$(short "$C7")"
eq "J: HEAD untouched" "$C6" "$(hd)"
eq "J: nothing ran" 0 "$(applies)"
eq "J: no state written" "$before" "$(st last_check)"
# dry-run reports a refusal too, without recording it
echo edited >> "$CO/f"; run --dry-run
contains "J: dry-run refusal printed" "$OUT" "refused: tracked local changes"
eq "J: still no state written" "$before" "$(st last_check)"
git -C "$CO" checkout -q -- f

# --- N. lock ---------------------------------------------------------------------------------------------
LK="$CONF/global/install-sync.lock"
mkdir -p "$LK"; date +%s > "$LK/ts"; run                   # no pid yet: the TTL alone decides
contains "N: a fresh lock skips the tick" "$OUT" "another tick holds"
contains "N: no pid says so" "$OUT" "pid=?"
printf '%s' "$$" > "$LK/pid"; run                          # a live holder (this shell)
contains "N: a live lock skips the tick" "$OUT" "another tick holds"
contains "N: the skip names the live pid" "$OUT" "pid=$$ alive"
eq "N: HEAD untouched" "$C6" "$(hd)"
printf '1\n' > "$LK/ts"; touch "$WORK/gate-closed"; run   # live pid, past the TTL (the gate keeps HEAD put)
contains "N: an old lock is taken over (TTL backstop)" "$OUT" "older than 3600s (pid=$$"
eq "N: the tick ran past the lock" deferred "$(st result)"
eq "N: HEAD still put" "$C6" "$(hd)"
[ -d "$LK" ] && fail "N: lock left behind (TTL)"; CHECKS=$((CHECKS + 1))
rm -f "$WORK/gate-closed"; mkdir -p "$LK"; date +%s > "$LK/ts"
# a holder SIGKILLed mid-tick (kickstart -k) left a fresh lock: taken over at once (#1691)
bash -c 'echo $$' > "$WORK/deadpid"; dead=$(cat "$WORK/deadpid")
printf '%s' "$dead" > "$LK/pid"; run
contains "N: the takeover names the dead pid" "$OUT" "took over $LK: holder pid=$dead is dead"
not_contains "N: a dead holder is not skipped" "$OUT" "another tick holds"
eq "N: a dead holder's lock is taken over" switched "$(st result)"
eq "N: moved" "$C7" "$(hd)"
[ -d "$LK" ] && fail "N: lock left behind"; CHECKS=$((CHECKS + 1))

# --- L. --status -------------------------------------------------------------------------------------------
run --status
eq "L: exits 0" 0 "$RC"; contains "L: prints the state" "$OUT" "result: switched"
OUT=$(FLEET_CONF_DIR="$WORK/empty" bash "$IS" --root "$CO" --status 2>&1); RC=$?
eq "L: no state exits 1" 1 "$RC"; contains "L: says none" "$OUT" "no state yet"

# --- P. notify once per stuck episode (issue #1125) ---------------------------------------------------------
NOTE="$WORK/notify.sh" NLOG="$WORK/notify.log"
cat > "$NOTE" <<EOF
#!/bin/sh
[ -f "$WORK/notify-fail" ] && exit 1
printf '%s\n---\n' "\$1" >> "$NLOG"
EOF
chmod +x "$NOTE"; : > "$NLOG"
sends() { grep -c '^---$' "$NLOG"; }
nlog() { grep -c ' notified ' "$CO/logs/install-sync.log"; }
nrun() { OUT=$(FLEET_NOTIFY_CMD="$NOTE" bash "$IS" --root "$CO" "$@" 2>&1); RC=$?; }
me=$(id -un)
C8=$(commit eight); C9=$(commit nine); C10=$(commit ten)
doctor_stub '  FAIL  gh       boom (this version is broken)'; C11=$(commit eleven-broken)
doctor_stub '';                                              C12=$(commit twelve-fixed)
C13=$(commit thirteen)
git -C "$SEED" push -q origin master
# the same refusal three ticks → ONE message
stable "$C8"; echo edited >> "$CO/f"; nrun; nrun; nrun
eq "P: refused" refused "$(st result)"
eq "P: three ticks, one send" 1 "$(sends)"
contains "P: names the login" "$(cat "$NLOG")" "**$me**'s fleet install ($CO)"
contains "P: says the result + reason" "$(cat "$NLOG")" "**refused**: tracked local changes in $CO (f)"
contains "P: says how to silence it" "$(cat "$NLOG")" "FLEET_INSTALL_SYNC=0"
eq "P: key = login why stable" "$me refused/dirty $C8" "$(st notified)"
t=$(st notified_at); case "$t" in ''|-|*[!0-9]*) fail "P: notified_at not an epoch: [$t]" ;; esac; CHECKS=$((CHECKS + 1))
contains "P: the send log line" "$(grep ' notified ' "$CO/logs/install-sync.log" | tail -1)" " notified $(short "$C7")..$(short "$C8") $me refused/dirty $C8 via notify.sh"
eq "P: one send log line" 1 "$(nlog)"
# fetch-failed in between neither sends nor forgets
git -C "$CO" remote set-url origin "$WORK/nowhere.git"; nrun
eq "P: fetch-failed" fetch-failed "$(st result)"
eq "P: fetch-failed keeps the key" "$me refused/dirty $C8" "$(st notified)"
git -C "$CO" remote set-url origin "$url"; nrun
eq "P: still one send after fetch-failed" 1 "$(sends)"
# following again clears it; the same reason on the NEXT stable is announced again
git -C "$CO" checkout -q -- f; nrun
eq "P: followed" switched "$(st result)"; eq "P: HEAD at C8" "$C8" "$(hd)"
eq "P: key cleared" - "$(st notified)"; eq "P: notified_at cleared" - "$(st notified_at)"
eq "P: recovery sends nothing" 1 "$(sends)"
stable "$C9"; echo edited >> "$CO/f"; nrun; nrun
eq "P: stuck again → announced again" 2 "$(sends)"
eq "P: the new episode's key" "$me refused/dirty $C9" "$(st notified)"
# another reason on the SAME stable is its own episode
git -C "$CO" checkout -q -- f; git -C "$CO" fetch -q origin master; git -C "$CO" reset -q --hard "$C10"; nrun; nrun
eq "P: refused (behind)" refused "$(st result)"
contains "P: says not a descendant" "$(st reason)" "is not a descendant of HEAD"
eq "P: a different why sends once more" 3 "$(sends)"
eq "P: key names the why" "$me refused/behind $C9" "$(st notified)"
# a short deferral is normal (clears); past the threshold it is stuck (once)
git -C "$CO" reset -q --hard "$C8"; touch "$WORK/gate-closed"; nrun
eq "P: deferred" deferred "$(st result)"
eq "P: a short deferral sends nothing" 3 "$(sends)"; eq "P: a short deferral clears the key" - "$(st notified)"
sleep 2
OUT=$(FLEET_NOTIFY_CMD="$NOTE" FLEET_INSTALL_FOLLOW_STUCK_SECS=1 bash "$IS" --root "$CO" 2>&1)
OUT=$(FLEET_NOTIFY_CMD="$NOTE" FLEET_INSTALL_FOLLOW_STUCK_SECS=1 bash "$IS" --root "$CO" 2>&1)
eq "P: still deferred" deferred "$(st result)"
eq "P: a long deferral sends once" 4 "$(sends)"
eq "P: deferred key carries no why" "$me deferred $C9" "$(st notified)"
contains "P: says how long" "$(tail -6 "$NLOG")" "Waited 0h so far (since "
contains "P: says deferred + why" "$(tail -6 "$NLOG")" "**deferred**: disk gate closed"
rm -f "$WORK/gate-closed"; nrun
eq "P: gate open → followed" switched "$(st result)"; eq "P: HEAD at C9" "$C9" "$(hd)"; eq "P: key cleared after the deferral" - "$(st notified)"
# rolled-back once; the skipped ticks after it are the same episode
stable "$C11"; nrun
eq "P: rolled-back" rolled-back "$(st result)"; eq "P: rollback sends once" 5 "$(sends)"
eq "P: rollback key" "$me rolled-back $C11" "$(st notified)"
contains "P: says rolled-back + why" "$(tail -6 "$NLOG")" "**rolled-back**: doctor FAIL after the switch: gh"
nrun; nrun
eq "P: skipped" skipped "$(st result)"; eq "P: skipped ticks are silent" 5 "$(sends)"
eq "P: skipped keeps the rollback key" "$me rolled-back $C11" "$(st notified)"
stable "$C12"; nrun
eq "P: the fix is followed" switched "$(st result)"; eq "P: key cleared after the fix" - "$(st notified)"
# a send that fails is not recorded → the next tick retries
stable "$C13"; echo edited >> "$CO/f"; touch "$WORK/notify-fail"; nrun
eq "P: refused (send failed)" refused "$(st result)"
eq "P: failed send not counted" 5 "$(sends)"; eq "P: failed send not recorded" - "$(st notified)"
contains "P: says the send failed" "$OUT" "failed: $NOTE exit 1 — retried next tick"
eq "P: no send log line for a failure" 5 "$(nlog)"
rm "$WORK/notify-fail"; nrun
eq "P: retried and sent" 6 "$(sends)"; eq "P: recorded on the retry" "$me refused/dirty $C13" "$(st notified)"
# no channel → nothing to send: an announced episode stays announced (the channel
# coming back must not repeat it), a new one is not recorded
run
eq "P: no FLEET_NOTIFY_CMD → nothing sent" 6 "$(sends)"
eq "P: an announced episode is kept without a channel" "$me refused/dirty $C13" "$(st notified)"
OUT=$(FLEET_INSTALL_SYNC=0 bash "$IS" --root "$CO" 2>&1)
eq "P: off clears the key" - "$(st notified)"
run
eq "P: no channel records nothing" - "$(st notified)"; eq "P: still nothing sent" 6 "$(sends)"
contains "P: says nobody to tell" "$OUT" "no FLEET_NOTIFY_CMD"
# dry-run prints what a real tick would send, sends nothing, writes nothing
before=$(st last_check); nrun --dry-run
contains "P: dry-run says what it would send" "$OUT" "notify: would send ($me refused/dirty $C13)"
eq "P: dry-run sends nothing" 6 "$(sends)"; eq "P: dry-run writes no state" "$before" "$(st last_check)"
# off clears an announced episode (the documented way to silence it)
nrun; eq "P: armed again" "$me refused/dirty $C13" "$(st notified)"; eq "P: sent" 7 "$(sends)"
OUT=$(FLEET_NOTIFY_CMD="$NOTE" FLEET_INSTALL_SYNC=0 bash "$IS" --root "$CO" 2>&1)
eq "P: off" off "$(st result)"; eq "P: off clears an announced key" - "$(st notified)"; eq "P: off sends nothing" 7 "$(sends)"
eq "P: seven send log lines" 7 "$(nlog)"
git -C "$CO" checkout -q -- f

# --- Q. node agent follows (issue #1723) ---------------------------------------------------------
# The fake: --dry-run prints the plan line for each login in $WORK/node-logins
# ("<name> <domain>"), behind unless $WORK/node-ver says prod-<short sha>; an
# upgrade writes node-ver, or fails when $WORK/node-fail exists.
NU="$WORK/fake-node-upgrade.sh"
cat > "$NU" <<EOF
#!/bin/bash
echo "nodeup \$*" >> "$LOG"
sha=\$1; ver=prod-\$(printf '%.7s' "\$sha")
[ -f "$WORK/node-none" ] && { echo "fleet-node-upgrade: no ccquota agent service on testhost (looked in x)" >&2; exit 1; }
case " \$* " in
  *" --dry-run "*)
    while read -r n d; do
      [ "\$(cat "$WORK/node-ver" 2>/dev/null)" = "\$ver" ] && act="current — skip" || act=upgrade
      echo "  \$n  \$d/com.ccquota.agent  /p  disk x · hub x  → \$act"
    done < "$WORK/node-logins"
    exit 0 ;;
esac
[ -f "$WORK/node-fail" ] && { echo "fleet-node-upgrade: FAIL — me: restarted, but no control channel on \$ver within 90s; rolled back: /p" >&2; exit 1; }
echo "\$ver" > "$WORK/node-ver"
echo "done: 1/1 login(s) on \$ver"
EOF
chmod +x "$NU"
printf '%s gui\n' "$me" > "$WORK/node-logins"; echo prod-0000000 > "$WORK/node-ver"
rm -f "$WORK/notify-fail" "$WORK/gate-closed" "$WORK/apply-partial" "$WORK/doctor-fail-always"
printf 'done\n' > "$WORK/tmux-states/f1"
nodeups() { grep -c '^nodeup .*--rollback' "$LOG"; }
qrun() { OUT=$(FLEET_INSTALL_NODE_UPGRADE="$NU" FLEET_INSTALL_NODE_SUDO_CHECK=false FLEET_NOTIFY_CMD="$NOTE" bash "$IS" --root "$CO" "$@" 2>&1); RC=$?; }
C20=$(commit twenty); C21=$(commit twentyone); C22=$(commit twentytwo); C23=$(commit twentythree)
git -C "$SEED" push -q origin master
stable "$C20"; n0=$(sends); qrun
eq "Q: switched" switched "$(st result)"
eq "Q: node upgraded" upgraded "$(st node)"
eq "Q: one upgrade, own login, hub first, rollback armed" "nodeup $C20 --dist --rollback --logins $me" "$(grep '^nodeup .*--rollback' "$LOG" | tail -1)"
eq "Q: reason = the done line" "done: 1/1 login(s) on prod-$(short "$C20")" "$(st node_reason)"
contains "Q: node log line after the tick's" "$(lastlog)" "node-upgraded "
contains "Q: tick line still there" "$(tail -2 "$CO/logs/install-sync.log" | head -1)" " switched "
n=$(nodeups); qrun
eq "Q: current" current "$(st result)"; eq "Q: node current" current "$(st node)"
eq "Q: current agent → no upgrade call" "$n" "$(nodeups)"
contains "Q: no node log line when nothing to do" "$(lastlog)" " current "
# failure: alarm once, back off, never loop
touch "$WORK/node-fail"; stable "$C21"; qrun
eq "Q: fail result" node_upgrade_failed "$(st node)"
contains "Q: fail reason" "$(st node_reason)" "no control channel on prod-$(short "$C21")"
eq "Q: fail stable" "$C21" "$(st node_fail_stable)"
eq "Q: one alert" $((n0 + 1)) "$(sends)"
contains "Q: alert names it" "$(tail -4 "$NLOG")" "node agent upgrade failed — $me@"
eq "Q: notified key" "$me node_upgrade_failed $C21" "$(st node_notified)"
eq "Q: the install itself still followed" switched "$(st result)"
n=$(nodeups); qrun
eq "Q: backoff" backoff "$(st node)"; eq "Q: backoff → no call" "$n" "$(nodeups)"
eq "Q: backoff → no 2nd alert" $((n0 + 1)) "$(sends)"
OUT=$(FLEET_NODE_FOLLOW_RETRY_SECS=0 FLEET_INSTALL_NODE_UPGRADE="$NU" FLEET_INSTALL_NODE_SUDO_CHECK=false FLEET_NOTIFY_CMD="$NOTE" bash "$IS" --root "$CO" 2>&1)
eq "Q: retry after the window" $((n + 1)) "$(nodeups)"; eq "Q: still failing" node_upgrade_failed "$(st node)"
eq "Q: same episode → no 2nd alert" $((n0 + 1)) "$(sends)"
rm -f "$WORK/node-fail"; stable "$C22"; qrun
eq "Q: a stable move retries at once" upgraded "$(st node)"
eq "Q: failure cleared" - "$(st node_fail_stable)"; eq "Q: key cleared" - "$(st node_notified)"
# a current tick waits for idle
echo prod-0000000 > "$WORK/node-ver"; printf 'working\n' > "$WORK/tmux-states/f1"; n=$(nodeups); qrun
eq "Q: busy → deferred" deferred "$(st node)"; eq "Q: busy → no call" "$n" "$(nodeups)"
contains "Q: deferred says why" "$(st node_reason)" "busy window(s) on f1:1"
printf 'done\n' > "$WORK/tmux-states/f1"
# LaunchDaemon logins: sudo decides
printf '%s system\nzz system\n' "$me" > "$WORK/node-logins"; qrun
eq "Q: no sudo → delegated" delegated "$(st node)"; eq "Q: delegated → no call" "$n" "$(nodeups)"
OUT=$(FLEET_INSTALL_NODE_SUDO_CHECK=true FLEET_INSTALL_NODE_UPGRADE="$NU" bash "$IS" --root "$CO" 2>&1)
eq "Q: sudo → own first, then the others" "nodeup $C22 --dist --rollback --logins $me zz" "$(grep '^nodeup .*--rollback' "$LOG" | tail -1)"
printf '%s gui\n' "$me" > "$WORK/node-logins"
# off / none / dry-run / degenerate
echo prod-0000000 > "$WORK/node-ver"; n=$(nodeups)
OUT=$(FLEET_NODE_FOLLOW=0 FLEET_INSTALL_NODE_UPGRADE="$NU" bash "$IS" --root "$CO" 2>&1)
eq "Q: FLEET_NODE_FOLLOW=0 → off" off "$(st node)"; eq "Q: off → no call" "$n" "$(nodeups)"
touch "$WORK/node-none"; qrun; rm -f "$WORK/node-none"
eq "Q: no agent → none" none "$(st node)"
before=$(st last_check); qrun --dry-run
contains "Q: dry-run says it would" "$OUT" "node: would upgrade $me to prod-$(short "$C22")"
eq "Q: dry-run → no upgrade" "$n" "$(nodeups)"; eq "Q: dry-run writes no state" "$before" "$(st last_check)"
stable "$C23"; ln=$(grep -c '' "$LOG"); run
not_contains "Q: degenerate: no node call" "$(tail -n +$((ln + 1)) "$LOG")" "nodeup"
contains "Q: degenerate: tick line last" "$(lastlog)" " switched "

# --- R. a script running across the switch (issue #1894) -----------------------------------------
# It resolves its own dir physically, waits for $1, then sources a sibling: the
# OLD version's, because the switch moved only the link.
cat > "$SEED/bin/slow.sh" <<'EOS'
#!/bin/bash
B="$(cd "$(dirname "$0")" && pwd -P)"
while [ ! -f "$1" ]; do sleep 0.1; done
. "$B/ver.sh"
echo "$VER"
EOS
echo 'VER=old' > "$SEED/bin/ver.sh"; R1=$(commit r-old)
echo 'VER=new' > "$SEED/bin/ver.sh"; R2=$(commit r-new)
printf 'if then fi (\n' > "$SEED/bin/broken.sh"; R3=$(commit r-broken)
git -C "$SEED" rm -q bin/broken.sh; R4=$(commit r-fixed)
W1=$(commit w-one)
git -C "$SEED" push -q origin master
stable "$R1"; run
eq "R: at the old version" switched "$(st result)"
GO="$WORK/go"; rm -f "$GO"
bash "$CO/bin/slow.sh" "$GO" > "$WORK/slow.out" 2>&1 & SP=$!
sleep 0.5
stable "$R2"; run
eq "R: switched while the script runs" switched "$(st result)"
touch "$GO"; wait "$SP"; RC=$?
eq "R: the running script exits clean" 0 "$RC"
eq "R: …having read the OLD version to the end" old "$(cat "$WORK/slow.out")"
eq "R: a fresh call reads the new version" new "$(bash "$CO/bin/slow.sh" "$GO" 2>&1)"
[ -d "$V/$R1" ] || fail "R: the old version is gone right after the switch"; CHECKS=$((CHECKS + 1))

# --- V. pre-switch check (issue #1894) ---------------------------------------------------------------
stable "$R3"; : > "$LOG"; run
eq "V: rejected before the switch" rolled-back "$(st result)"
contains "V: names the broken file" "$(st reason)" "bin/broken.sh does not parse"
contains "V: says nothing switched" "$(st reason)" "nothing switched"
eq "V: the link untouched" "$V/$R2" "$(readlink "$CO")"
eq "V: HEAD untouched" "$R2" "$(hd)"
eq "V: no apply" 0 "$(applies)"
eq "V: skip = the rejected version" "$R3" "$(st skip)"
run; eq "V: next tick skipped" skipped "$(st result)"
stable "$R4"; run
eq "V: the fix is followed" switched "$(st result)"; eq "V: HEAD at the fix" "$R4" "$(hd)"

# --- W. prune (issue #1894) -----------------------------------------------------------------------------
ndirs() { find "$V" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' '; }
[ "$(ndirs)" -gt 3 ] || fail "W: the default keep (7 days) pruned versions already ($(ndirs) left)"; CHECKS=$((CHECKS + 1))
stable "$W1"; OUT=$(FLEET_INSTALL_VERSIONS_KEEP_SECS=0 bash "$IS" --root "$CO" 2>&1)
eq "W: switched" switched "$(st result)"
eq "W: left: the current, .prev and the repository" 3 "$(ndirs)"
[ -d "$V/$W1" ] && [ -d "$V/$R4" ] && [ -d "$V/$C1/.git" ] || fail "W: wrong versions kept: $(ls "$V")"; CHECKS=$((CHECKS + 1))
eq "W: .prev" "$R4" "$(cat "$V/.prev")"
eq "W: the pruned branches are gone" 2 "$(git -C "$CO" branch --list 'fleet-live/*' | wc -l | tr -d ' ')"
eq "W: no stale worktree records" 3 "$(git -C "$CO" worktree list | wc -l | tr -d ' ')"
contains "W: says what it pruned" "$OUT" "pruned version"
eq "W: the shared logs survive" old "$(cat "$CO/logs/keep.log")"

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
