#!/bin/bash
# sync-logins-selftest.sh — bin/fleet-sync-logins.sh against fake HOMEs, fully
# hermetic (issue #1069).
#
# One source checkout and a homes root holding several fake logins' installs, so
# there is no sudo, no launchctl, no real /Users and no network: sudo, launchctl
# and pgrep are shims that log what they were asked to do.
#
# What it pins, in order:
#   A. plan        --dry-run / --summary see a behind git checkout and a guest
#                  copy install, report drift, exit 1 — and change nothing
#   B. act         the checkout gets every tracked entry + HEAD at the source
#                  commit (clean status); the guest gets ONLY the entries it had
#                  + a marker; fleet.conf / logs / untracked caches untouched;
#                  a backup of what changed; each login's daemons kickstarted
#   C. idempotent  a second run finds everyone current and does nothing
#   D. edits       a tracked edit the source never saw blocks (exit 4); --force
#                  syncs and the backup keeps the edit; a file matching an OLD
#                  source version (an earlier sync's footprint) does not block
#   E. no downgrade a checkout newer than the source is blocked, and so is an
#                  unmarked copy install beside it
#   F. sudo        another owner goes through the sudo prefix; with no sudo,
#                  nothing changes, exit 5, the admin command is printed
#   H. unreadable .git  another login's `.git` the caller cannot read: the
#                  reads go through the owner too, so a sync that landed reports
#                  synced (not FAILED) and --summary reports current (issue #1115)
#   G. usage       --logins filter, an unknown login (exit 2), a non-git source
#                  (exit 3)
#   I. --to-git    a copy install becomes a clone at the commit its marker names
#                  (an unmarked one at the source's HEAD): origin = the source's
#                  origin as https (or --origin), fleet.conf / logs / local files
#                  carried, caches + marker left behind, the old dir kept whole as
#                  fleet.copy-<date>, daemons kicked, clean status; a checkout is
#                  skipped; local edits block (--force converts); the plain sync
#                  then moves the new checkout forward; sudo / no-sudo paths;
#                  --summary --to-git and a source without an https origin refuse
#                  (issue #1121)
#   J. off         FLEET_INSTALL_SYNC=0 (issue #1122): an off login is listed
#                  as `off`, never touched, never blocked, never an error, and
#                  counted apart in --summary / the tails; --logins <it> or
#                  --include-off syncs it; the settings file wins over the
#                  install conf (a relocated FLEET_CONF_DIR honoured); --to-git
#                  skips an off copy the same way
#   K. closed home a 0700 home owned by someone else (issue #1158): the caller's
#                  glob cannot see its install. With sudo it is found and read
#                  THROUGH the owner (discovery, drift, the act, the verify, its
#                  LaunchAgents); without, it is `unreadable` — a needs-sudo
#                  exit 5 with the admin command — never "nothing to sync".
#                  The caller's cwd closed to the owner (issue #1162) — the act
#                  still syncs; a failing owner command's own stderr is in the
#                  FAILED row, not just "N entr(ies) still differ"
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SL="$BIN/fleet-sync-logins.sh"
[ -f "$SL" ] || { printf 'selftest: %s not found\n' "$SL" >&2; exit 2; }
for t in git rsync diff; do
  command -v "$t" >/dev/null 2>&1 || { echo "sync-logins-selftest SKIP (no $t)"; exit 0; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sync-logins-selftest.XXXXXX")" || exit 2
WORK=$(cd "$WORK" && pwd -P)
KH=''   # section K's closed home — reopened first, or rm -rf cannot enter it
cleanup() { [ -n "$KH" ] && chmod 700 "$KH" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
ok() { CHECKS=$((CHECKS + 1)); eval "$2" || fail "$1 — [$2] is false${OUT:+ — output:
$OUT}"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]:
$2";; esac; }
not_contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — output unexpectedly contains [$3]:
$2";; esac; }

export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: > "$WORK/gitconfig"
g() { git -C "$1" "${@:2}"; }

# --- shims ------------------------------------------------------------------
mkdir -p "$WORK/shim" "$WORK/daemons" "$WORK/tmp"
cat > "$WORK/shim/launchctl" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/launchctl.log"
EOF
cat > "$WORK/shim/sudo" <<EOF
#!/bin/sh
# fake passwordless sudo: log, drop -n / -u <who>, run the rest as us
echo "\$*" >> "$WORK/sudo.log"
[ "\$1" = -n ] && shift
[ "\$1" = -u ] && shift 2
exec "\$@"
EOF
cat > "$WORK/shim/pgrep" <<'EOF'
#!/bin/sh
echo 4242
EOF
chmod +x "$WORK/shim/"*

export FLEET_SYNC_LOGINS_HOMES="$WORK/homes"
export FLEET_SYNC_LOGINS_SUDO=''                      # same-owner: no prefix at all
export FLEET_SYNC_LOGINS_LAUNCHCTL="$WORK/shim/launchctl"
export FLEET_SYNC_LOGINS_DAEMON_DIR="$WORK/daemons"
export FLEET_SYNC_LOGINS_PGREP="$WORK/shim/pgrep"
export FLEET_SYNC_LOGINS_TMP="$WORK/tmp"

run() { OUT=$(bash "$SL" "$@" 2>&1); RC=$?; }

# --- the source: a checkout with a guest-sized subset + full-only entries ------
SRC="$WORK/src"
git init -q -b master "$SRC"
mkdir -p "$SRC/bin" "$SRC/conf" "$SRC/hooks" "$SRC/shell" "$SRC/commands"
printf 'logs/\nfleet.conf\n__pycache__/\n' > "$SRC/.gitignore"
echo 'v1' > "$SRC/bin/a.sh"; echo 'gone soon' > "$SRC/bin/old.sh"
echo 'conf v1' > "$SRC/conf/tmux.conf"; echo 'hook v1' > "$SRC/hooks/h.py"
echo 'shell v1' > "$SRC/shell/cw.zsh"; echo 'cmd v1' > "$SRC/commands/c.md"
echo 'example' > "$SRC/fleet.conf.example"; echo 'readme v1' > "$SRC/README.md"
chmod +x "$SRC/bin/a.sh"
g "$SRC" add -A; g "$SRC" commit -qm one
C1=$(g "$SRC" rev-parse HEAD)

# alice: a full git-checkout install at C1 (clone), with operator state beside it
H="$WORK/homes"; mkdir -p "$H/alice/.claude" "$H/bob/.claude"
git clone -q "$SRC" "$H/alice/.claude/fleet"
A="$H/alice/.claude/fleet"
echo 'FLEET_REPO=alice/x' > "$A/fleet.conf"
mkdir -p "$A/logs" "$A/bin/__pycache__"; echo 'log' > "$A/logs/x.log"; echo 'c' > "$A/bin/__pycache__/m.pyc"

# bob: a guest COPY install — only bin conf hooks shell, no git
B="$H/bob/.claude/fleet"; mkdir -p "$B"
for e in bin conf hooks shell; do cp -Rp "$SRC/$e" "$B/"; done
echo 'FLEET_REPO=bob/y' > "$B/fleet.conf"; mkdir -p "$B/logs"

# the source moves on: modify, add, delete, new top-level entry
echo 'v2' > "$SRC/bin/a.sh"; echo 'new' > "$SRC/bin/b.sh"; g "$SRC" rm -q bin/old.sh
echo 'conf v2' > "$SRC/conf/tmux.conf"; mkdir -p "$SRC/skills/s"; echo 'skill' > "$SRC/skills/s/SKILL.md"
g "$SRC" add -A; g "$SRC" commit -qm two
echo 'readme v3' > "$SRC/README.md"; g "$SRC" commit -qam three
C3=$(g "$SRC" rev-parse HEAD)
# the source's UNCOMMITTED edit must never spread
echo 'uncommitted' >> "$SRC/bin/a.sh"

# daemons: alice runs system LaunchDaemons (spinner + collect); bob a gui agent
touch "$WORK/daemons/com.claude-fleet.alice.spinner.plist" "$WORK/daemons/com.claude-fleet.alice.collect.plist"
mkdir -p "$H/bob/Library/LaunchAgents"; touch "$H/bob/Library/LaunchAgents/com.claude-fleet.collect.plist"

snap() { (cd "$H" && find . -type f -exec cksum {} + | sort) ; }

# ============================================================================
# A. plan
# ============================================================================
before=$(snap)
run --source "$SRC" --dry-run
eq "dry-run: exit 1 (drift)" 1 "$RC"
contains "dry-run: alice is a git checkout, 2 behind" "$OUT" "2 commit(s) behind"
ok "dry-run: alice listed as sync" 'printf "%s\n" "$OUT" | grep -q "^alice  *git .* sync"'
ok "dry-run: bob listed as a copy to sync" 'printf "%s\n" "$OUT" | grep -q "^bob  *copy .* sync"'
contains "dry-run: says so" "$OUT" "dry run — nothing changed"
eq "dry-run: nothing changed" "$before" "$(snap)"

run --source "$SRC" --summary
eq "summary: exit 1" 1 "$RC"
eq "summary: one line" 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
contains "summary: counts" "$OUT" "2 other · 0 current · 2 drifted"

# ============================================================================
# B. act
# ============================================================================
run --source "$SRC"
eq "act: exit 0" 0 "$RC"
contains "act: final line" "$OUT" "other logins on this machine: 2 synced / 0 skipped"
# alice — every tracked entry, HEAD aligned, clean
eq "alice: HEAD at the source commit" "$C3" "$(g "$A" rev-parse HEAD)"
eq "alice: clean status" "" "$(g "$A" status --porcelain --untracked-files=no)"
eq "alice: modified file" "v2" "$(cat "$A/bin/a.sh")"
ok "alice: added file" '[ -f "$A/bin/b.sh" ]'
ok "alice: deleted file gone" '[ ! -e "$A/bin/old.sh" ]'
ok "alice: new top-level entry" '[ -f "$A/skills/s/SKILL.md" ]'
ok "alice: exec bit kept" '[ -x "$A/bin/a.sh" ]'
eq "alice: fleet.conf untouched" "FLEET_REPO=alice/x" "$(cat "$A/fleet.conf")"
ok "alice: logs untouched" '[ -f "$A/logs/x.log" ]'
ok "alice: ignored cache kept" '[ -f "$A/bin/__pycache__/m.pyc" ]'
# bob — only what it had, plus a marker
eq "bob: modified file" "v2" "$(cat "$B/bin/a.sh")"
ok "bob: deleted file gone" '[ ! -e "$B/bin/old.sh" ]'
ok "bob: no full-install entries grown" '[ ! -e "$B/commands" ] && [ ! -e "$B/skills" ] && [ ! -e "$B/README.md" ]'
eq "bob: marker records the commit" "$C3" "$(awk '{print $1}' "$B/.fleet-synced-from")"
eq "bob: fleet.conf untouched" "FLEET_REPO=bob/y" "$(cat "$B/fleet.conf")"
# backups hold the pre-sync content
bak=$(ls -d "$H"/alice/.claude/fleet.bak-* | head -1)
eq "alice: backup has the old file" "v1" "$(cat "$bak/bin/a.sh")"
eq "alice: backup records the old HEAD" "$C1" "$(cat "$bak/.fleet-prior-head")"
ok "bob: backup has the deleted file" '[ -f "$(ls -d "$H"/bob/.claude/fleet.bak-* | head -1)/bin/old.sh" ]'
# daemons
L=$(cat "$WORK/launchctl.log")
contains "daemons: alice spinner kicked" "$L" "kickstart -k system/com.claude-fleet.alice.spinner"
contains "daemons: alice collect kicked" "$L" "kickstart -k system/com.claude-fleet.alice.collect"
contains "daemons: bob gui agent kicked" "$L" "kickstart -k gui/$(id -u)/com.claude-fleet.collect"
not_contains "no spinner warning" "$OUT" "WARN"
ok "staging cleaned up" '[ -z "$(ls "$WORK/tmp")" ]'

# ============================================================================
# C. idempotent
# ============================================================================
: > "$WORK/launchctl.log"
run --source "$SRC"
eq "rerun: exit 0" 0 "$RC"
contains "rerun: nothing synced" "$OUT" "0 synced / 0 skipped · 2 already current"
eq "rerun: no daemon touched" "" "$(cat "$WORK/launchctl.log")"
run --source "$SRC" --summary
eq "rerun summary: exit 0" 0 "$RC"
eq "rerun summary" "2 other · 2 current · 0 drifted" "$OUT"

# ============================================================================
# D. local edits
# ============================================================================
echo 'v4' > "$SRC/bin/a.sh"; g "$SRC" commit -qam four   # (drops the uncommitted edit too)
echo 'my own work' > "$A/bin/b.sh"
run --source "$SRC" --logins alice
eq "edit: blocked exit 4" 4 "$RC"
contains "edit: names the file" "$OUT" "local edits: bin/b.sh"
eq "edit: not overwritten" "my own work" "$(cat "$A/bin/b.sh")"

run --source "$SRC" --logins alice --force
eq "force: exit 0" 0 "$RC"
eq "force: synced" "v4" "$(cat "$A/bin/a.sh")"
ok "force: backup keeps the edit" 'grep -rqx "my own work" "$H"/alice/.claude/fleet.bak-*/bin/b.sh'

# footprint: the tree holds a version the source KNOWS but HEAD is older — what
# a hand-run rsync leaves behind. Not local work; must not block.
g "$A" reset -q "$C1"                                   # HEAD back, tree stays at C4
ok "footprint: git calls it dirty" '[ -n "$(g "$A" status --porcelain --untracked-files=no)" ]'
run --source "$SRC" --logins alice
eq "footprint: synced, not blocked" 0 "$RC"
eq "footprint: HEAD realigned" "$(g "$SRC" rev-parse HEAD)" "$(g "$A" rev-parse HEAD)"

# ============================================================================
# E. no downgrade
# ============================================================================
git clone -q "$SRC" "$H/carol/.claude/fleet"
CR="$H/carol/.claude/fleet"
echo 'newer' > "$CR/bin/a.sh"; g "$CR" commit -qam newer
mkdir -p "$H/dave/.claude/fleet"; cp -Rp "$SRC/bin" "$H/dave/.claude/fleet/"   # unmarked copy
echo 'stale' > "$H/dave/.claude/fleet/bin/a.sh"                                  # …that drifted
run --source "$SRC" --dry-run
eq "newer: exit 4" 4 "$RC"
ok "newer: carol blocked" 'printf "%s\n" "$OUT" | grep -q "^carol .*blocked — its install is NEWER"'
ok "newer: unmarked dave blocked" 'printf "%s\n" "$OUT" | grep -q "^dave .*blocked — unversioned copy"'
ok "newer: marked bob still syncs" 'printf "%s\n" "$OUT" | grep -q "^bob .*sync"'
run --source "$SRC" --logins carol
eq "newer: act refuses" 4 "$RC"
eq "newer: carol untouched" "newer" "$(cat "$CR/bin/a.sh")"
rm -rf "$H/carol" "$H/dave"

# ============================================================================
# F. sudo
# ============================================================================
echo 'v5' > "$SRC/bin/a.sh"; g "$SRC" commit -qam five
: > "$WORK/sudo.log"
OUT=$(FLEET_SYNC_LOGINS_ME=someone-else FLEET_SYNC_LOGINS_SUDO="$WORK/shim/sudo -n" bash "$SL" --source "$SRC" --logins bob 2>&1); RC=$?
eq "sudo: exit 0" 0 "$RC"
eq "sudo: synced" "v5" "$(cat "$B/bin/a.sh")"
contains "sudo: rsync ran as the owner, with the owner's HOME" "$(cat "$WORK/sudo.log")" "-n -u $(id -un) env HOME=$H/bob rsync"

echo 'v6' > "$SRC/bin/a.sh"; g "$SRC" commit -qam six
OUT=$(FLEET_SYNC_LOGINS_ME=someone-else FLEET_SYNC_LOGINS_SUDO="false" bash "$SL" --source "$SRC" --logins bob 2>&1); RC=$?
eq "no sudo: exit 5" 5 "$RC"
contains "no sudo: prints the admin command" "$OUT" "sudo $SL --source $SRC --logins bob"
eq "no sudo: nothing changed" "v5" "$(cat "$B/bin/a.sh")"

# ============================================================================
# G. usage
# ============================================================================
run --source "$SRC" --logins nobody
eq "unknown login: exit 2" 2 "$RC"
run --source "$SRC" --bogus
eq "bad flag: exit 2" 2 "$RC"
run --source "$B"
eq "non-git source: exit 3" 3 "$RC"
run --source "$SRC" --homes "$WORK/nohomes"
eq "no other logins: exit 0" 0 "$RC"
contains "no other logins: says so" "$OUT" "nothing to sync"

# ============================================================================
# H. unreadable .git — reads as the owner (issue #1115)
# ============================================================================
# A git shim stands in for file permissions: it refuses any `-C <alice's
# install>` call unless it arrived through the owner-sudo shim (which marks it).
# Every other git call — the source, hash-object on the tree — passes through.
REALGIT=$(command -v git)
mkdir -p "$WORK/gshim"
cat > "$WORK/gshim/git" <<EOF
#!/bin/sh
if [ -z "\${AS_OWNER:-}" ]; then
  prev=''
  for a in "\$@"; do
    if [ "\$prev" = -C ]; then
      case "\$a" in "$A"|"$A"/*) echo "fatal: .git/index: index file open failed: Permission denied" >&2; exit 128 ;; esac
    fi
    prev=\$a
  done
fi
exec "$REALGIT" "\$@"
EOF
cat > "$WORK/gshim/osudo" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/sudo.log"
[ "\$1" = -n ] && shift
[ "\$1" = -u ] && shift 2
AS_OWNER=1 exec "\$@"
EOF
chmod +x "$WORK/gshim/"*
echo 'v7' > "$SRC/bin/a.sh"; g "$SRC" commit -qam seven
C7=$(g "$SRC" rev-parse HEAD)
hrun() { OUT=$(PATH="$WORK/gshim:$PATH" FLEET_SYNC_LOGINS_ME=someone-else FLEET_SYNC_LOGINS_SUDO="$WORK/gshim/osudo -n" bash "$SL" --source "$SRC" --logins alice "$@" 2>&1); RC=$?; }
ok "unreadable: the shim really refuses the caller" '! PATH="$WORK/gshim:$PATH" git -C "$A" rev-parse HEAD >/dev/null 2>&1'
hrun --summary
eq "unreadable summary: behind = drifted" "1 other · 0 current · 1 drifted (alice:1)" "$OUT"
: > "$WORK/sudo.log"
hrun
eq "unreadable: exit 0" 0 "$RC"
contains "unreadable: synced, not FAILED" "$OUT" "alice: synced to"
not_contains "unreadable: no FAILED" "$OUT" "FAILED"
eq "unreadable: HEAD aligned" "$C7" "$(g "$A" rev-parse HEAD)"
contains "unreadable: verify read HEAD as the owner" "$(cat "$WORK/sudo.log")" "-u $(id -un) git -c safe.directory=* -C $A rev-parse HEAD"
eq "unreadable: owner probed once, not per git call" 1 "$(grep -c -- '-u [^ ]* true$' "$WORK/sudo.log")"
hrun --summary
eq "unreadable summary: current" "1 other · 1 current · 0 drifted" "$OUT"
eq "unreadable summary: exit 0" 0 "$RC"
# no reachable owner (no sudo): the caller's read is all there is — unchanged
hrun_nosudo() { OUT=$(PATH="$WORK/gshim:$PATH" FLEET_SYNC_LOGINS_ME=someone-else FLEET_SYNC_LOGINS_SUDO=false bash "$SL" --source "$SRC" --logins alice --summary 2>&1); RC=$?; }
hrun_nosudo
not_contains "no sudo: does not claim current" "$OUT" "1 current"
eq "no sudo: an unread checkout is drifted, not a copy" "1 other · 0 current · 1 drifted (alice:0)" "$OUT"

# ============================================================================
# I. --to-git — a copy install becomes a clone (issue #1121)
# ============================================================================
# bob is a copy whose marker names C5 (two behind C7); give it the local state a
# real copy install carries: conf, a conf backup, logs, an untracked local file,
# caches. erin is an UNMARKED copy of the current tree. frank has a local edit
# the source never saw; gina's marker names a commit the source lacks.
C5=$(g "$SRC" rev-parse HEAD~2)
eq "to-git: bob's marker is C5" "$C5" "$(awk '{print $1}' "$B/.fleet-synced-from")"
echo 'log line' > "$B/logs/x.log"; echo 'mine' > "$B/conf/local.txt"; echo 'old conf' > "$B/fleet.conf.bak-x"
mkdir -p "$B/bin/__pycache__"; echo 'c' > "$B/bin/__pycache__/m.pyc"; echo 'ds' > "$B/bin/.DS_Store"
touch "$WORK/daemons/com.claude-fleet.bob.spinner.plist"
E="$H/erin/.claude/fleet"; mkdir -p "$E"; for e in bin conf; do cp -Rp "$SRC/$e" "$E/"; done
echo 'FLEET_REPO=erin/z' > "$E/fleet.conf"
F="$H/frank/.claude/fleet"; mkdir -p "$F"; for e in bin conf; do cp -Rp "$SRC/$e" "$F/"; done
printf '%s me now\n' "$C7" > "$F/.fleet-synced-from"; echo 'my edit' > "$F/bin/a.sh"
GI="$H/gina/.claude/fleet"; mkdir -p "$GI"; cp -Rp "$SRC/bin" "$GI/"
printf '%s me now\n' 0123456789abcdef0123456789abcdef01234567 > "$GI/.fleet-synced-from"

run --source "$SRC" --to-git --summary
eq "to-git --summary: exclusive, exit 2" 2 "$RC"
run --source "$SRC" --to-git --dry-run
eq "to-git: no https origin on the source → exit 3" 3 "$RC"
contains "to-git: says how" "$OUT" "pass --origin"
g "$SRC" remote add origin git@github.com:o/r.git

before=$(snap)
run --source "$SRC" --to-git --dry-run
eq "to-git dry-run: blocked logins → exit 4" 4 "$RC"
ok "to-git dry-run: a checkout is skipped" 'printf "%s\n" "$OUT" | grep -q "^alice  *git .* skip — already a git checkout"'
ok "to-git dry-run: bob converts at its marker, origin rewritten to https" 'printf "%s\n" "$OUT" | grep -q "^bob  *copy .* to-git — clone at $(g "$SRC" rev-parse --short "$C5") · origin https://github.com/o/r.git"'
ok "to-git dry-run: an unmarked copy converts at the source HEAD" 'printf "%s\n" "$OUT" | grep -q "^erin  *copy .* to-git — unversioned copy → clone at $(g "$SRC" rev-parse --short "$C7")"'
ok "to-git dry-run: a local edit blocks, named" 'printf "%s\n" "$OUT" | grep -q "^frank  *copy .* blocked — local edits: bin/a.sh"'
ok "to-git dry-run: a marker the source lacks blocks" 'printf "%s\n" "$OUT" | grep -q "^gina  *copy .* blocked — its marker names 0123456, a commit the source does not have"'
contains "to-git dry-run: tail counts" "$OUT" "5 · 2 to convert · 1 already git checkouts · 2 blocked (dry run — nothing changed)"
eq "to-git dry-run: nothing changed" "$before" "$(snap)"

: > "$WORK/launchctl.log"
run --source "$SRC" --to-git --logins bob,erin
ok "to-git act: exit 0" '[ "$RC" -eq 0 ]'
contains "to-git act: bob line" "$OUT" "bob: converted to a git checkout @ $(g "$SRC" rev-parse --short "$C5") · origin https://github.com/o/r.git · old copy kept at $H/bob/.claude/fleet.copy-"
contains "to-git act: final line" "$OUT" "other logins on this machine: 2 converted / 0 skipped · 0 already git checkouts"
ok "bob: is a checkout now" '[ -d "$B/.git" ]'
eq "bob: HEAD = its marker's commit" "$C5" "$(g "$B" rev-parse HEAD)"
eq "bob: on the source's branch" "master" "$(g "$B" symbolic-ref --short HEAD)"
eq "bob: origin is the public https URL" "https://github.com/o/r.git" "$(g "$B" remote get-url origin)"
eq "bob: upstream set" "origin" "$(g "$B" config branch.master.remote)"
eq "bob: tracked tree clean" "" "$(g "$B" status --porcelain --untracked-files=no)"
eq "bob: tracked file at the marker's version" "v5" "$(cat "$B/bin/a.sh")"
ok "bob: the full tree, not the copy's subset" '[ -f "$B/commands/c.md" ] && [ -f "$B/README.md" ]'
eq "bob: fleet.conf carried" "FLEET_REPO=bob/y" "$(cat "$B/fleet.conf")"
eq "bob: conf backup carried" "old conf" "$(cat "$B/fleet.conf.bak-x")"
eq "bob: logs carried" "log line" "$(cat "$B/logs/x.log")"
eq "bob: untracked local file carried" "mine" "$(cat "$B/conf/local.txt")"
ok "bob: local file is untracked, not lost" 'g "$B" status --porcelain | grep -q "^?? conf/local.txt"'
ok "bob: marker and caches left behind" '[ ! -e "$B/.fleet-synced-from" ] && [ ! -e "$B/bin/__pycache__" ] && [ ! -e "$B/bin/.DS_Store" ]'
bakc=$(ls -d "$H"/bob/.claude/fleet.copy-* | head -1)
eq "bob: old copy kept whole" "" "$(for f in bin/a.sh fleet.conf .fleet-synced-from logs/x.log bin/__pycache__/m.pyc; do [ -f "$bakc/$f" ] || echo "missing $f"; done)"
ok "bob: no half-built clone left" '[ -z "$(ls -d "$H"/bob/.claude/fleet.to-git.* 2>/dev/null)" ]'
eq "erin: HEAD = source HEAD (unmarked copy)" "$C7" "$(g "$E" rev-parse HEAD)"
eq "erin: fleet.conf carried" "FLEET_REPO=erin/z" "$(cat "$E/fleet.conf")"
ok "erin: logs dir exists even though the copy had none" '[ -d "$E/logs" ]'
contains "to-git: bob's daemons kicked" "$(cat "$WORK/launchctl.log")" "kickstart -k system/com.claude-fleet.bob.spinner"
ok "to-git: staging cleaned up" '[ -z "$(ls "$WORK/tmp")" ]'

run --source "$SRC" --to-git --dry-run --logins bob,erin
eq "to-git rerun: nothing to convert, exit 0" 0 "$RC"
contains "to-git rerun: both skipped as checkouts" "$OUT" "2 · 0 to convert · 2 already git checkouts · 0 blocked"

# the converted login is an ordinary checkout to the plain sync
run --source "$SRC" --dry-run --logins bob
eq "after to-git: plain dry-run sees a checkout behind" 1 "$RC"
ok "after to-git: bob is git, 2 behind" 'printf "%s\n" "$OUT" | grep -q "^bob  *git .* sync — 2 commit(s) behind"'
run --source "$SRC" --logins bob
eq "after to-git: plain sync lands" 0 "$RC"
eq "after to-git: bob at the source HEAD" "$C7" "$(g "$B" rev-parse HEAD)"
eq "after to-git: fleet.conf still there" "FLEET_REPO=bob/y" "$(cat "$B/fleet.conf")"

# local edits: blocked, then forced — the old copy keeps the edit
run --source "$SRC" --to-git --logins frank
eq "to-git edit: exit 4" 4 "$RC"
ok "to-git edit: untouched" '[ ! -e "$F/.git" ] && [ "$(cat "$F/bin/a.sh")" = "my edit" ]'
run --source "$SRC" --to-git --logins frank --force
ok "to-git edit forced: exit 0" '[ "$RC" -eq 0 ]'
contains "to-git edit forced: says what it left behind" "$OUT" "local edits left in the old copy (forced): bin/a.sh"
eq "to-git edit forced: the clone's file wins" "v7" "$(cat "$F/bin/a.sh")"
ok "to-git edit forced: the old copy keeps the edit" 'grep -qx "my edit" "$H"/frank/.claude/fleet.copy-*/bin/a.sh'

# another owner: through the sudo prefix; without sudo nothing changes, exit 5
HK="$H/hank/.claude/fleet"; mkdir -p "$HK"; cp -Rp "$SRC/bin" "$HK/"; printf '%s me now\n' "$C7" > "$HK/.fleet-synced-from"
: > "$WORK/sudo.log"
OUT=$(FLEET_SYNC_LOGINS_ME=someone-else FLEET_SYNC_LOGINS_SUDO="$WORK/shim/sudo -n" bash "$SL" --source "$SRC" --to-git --logins hank 2>&1); RC=$?
ok "to-git sudo: exit 0" '[ "$RC" -eq 0 ]'
eq "to-git sudo: converted" "$C7" "$(g "$HK" rev-parse HEAD)"
ok "to-git sudo: the owner-side shell ran as the owner" 'grep -q -- "-n -u $(id -un) env HOME=$H/hank sh $WORK/tmp/.*/to-git.sh" "$WORK/sudo.log"'
ok "to-git sudo: the copy was listed as the owner" 'grep -q -- "-n -u $(id -un) find $HK" "$WORK/sudo.log"'
IV="$H/ivy/.claude/fleet"; mkdir -p "$IV"; cp -Rp "$SRC/bin" "$IV/"; printf '%s me now\n' "$C7" > "$IV/.fleet-synced-from"
OUT=$(FLEET_SYNC_LOGINS_ME=someone-else FLEET_SYNC_LOGINS_SUDO="false" bash "$SL" --source "$SRC" --to-git --logins ivy 2>&1); RC=$?
eq "to-git no sudo: exit 5" 5 "$RC"
contains "to-git no sudo: prints the admin command with the mode" "$OUT" "sudo $SL --source $SRC --logins ivy --to-git --origin https://github.com/o/r.git"
ok "to-git no sudo: nothing changed" '[ ! -e "$IV/.git" ]'
# a marker the source cannot resolve: --force clones at the source HEAD
run --source "$SRC" --to-git --logins gina --force
ok "to-git unknown marker forced: exit 0" '[ "$RC" -eq 0 ]'
contains "to-git unknown marker forced: says so" "$OUT" "gina: converted to a git checkout @ $(g "$SRC" rev-parse --short "$C7")"
eq "to-git unknown marker forced: at the source HEAD" "$C7" "$(g "$GI" rev-parse HEAD)"
# --origin overrides the source's origin
run --source "$SRC" --to-git --origin https://example.com/x.git --logins ivy
ok "to-git --origin: exit 0" '[ "$RC" -eq 0 ]'
eq "to-git --origin: used as given" "https://example.com/x.git" "$(g "$IV" remote get-url origin)"

# ============================================================================
# J. auto-update off — FLEET_INSTALL_SYNC=0 (issue #1122)
# ============================================================================
# A fresh homes root, everyone one commit behind: judy is a checkout that set
# FLEET_INSTALL_SYNC=0 in its install conf, liam a checkout with it unset (on),
# mia a copy install (marker at C7) that set it, quoted, in its conf.
echo 'v8' > "$SRC/bin/a.sh"; g "$SRC" commit -qam eight
C8=$(g "$SRC" rev-parse HEAD)
H2="$WORK/homes2"; mkdir -p "$H2"
for u in judy liam; do git clone -q "$SRC" "$H2/$u/.claude/fleet"; g "$H2/$u/.claude/fleet" reset -q --hard "$C7"; done
J="$H2/judy/.claude/fleet"; LM="$H2/liam/.claude/fleet"; MI="$H2/mia/.claude/fleet"
printf 'FLEET_REPO=judy/x\nFLEET_INSTALL_SYNC=0   # my call\n' > "$J/fleet.conf"
echo 'FLEET_REPO=liam/x' > "$LM/fleet.conf"
mkdir -p "$MI"; cp -Rp "$SRC/bin" "$MI/"; echo 'v7' > "$MI/bin/a.sh"
printf '%s me now\n' "$C7" > "$MI/.fleet-synced-from"; printf 'FLEET_INSTALL_SYNC="0"\n' > "$MI/fleet.conf"
jrun() { OUT=$(bash "$SL" --source "$SRC" --homes "$H2" "$@" 2>&1); RC=$?; }
snap2() { (cd "$H2" && find . -type f -exec cksum {} + | sort) ; }

before=$(snap2)
jrun --dry-run
eq "off dry-run: exit 1 — liam drifts; off is no error" 1 "$RC"
ok "off dry-run: judy listed off, with the way in" 'printf "%s\n" "$OUT" | grep -q "^judy  *git .* off — auto-update off (FLEET_INSTALL_SYNC=0) — left alone; --logins judy or --include-off syncs it anyway"'
ok "off dry-run: a quoted 0 in a copy install's conf counts" 'printf "%s\n" "$OUT" | grep -q "^mia  *copy .* off — auto-update off"'
ok "off dry-run: liam (unset = on) still syncs" 'printf "%s\n" "$OUT" | grep -q "^liam  *git .* sync — 1 commit(s) behind"'
contains "off dry-run: tail counts off apart" "$OUT" "3 · 0 current · 1 to sync · 0 blocked · 2 off (dry run — nothing changed)"
eq "off dry-run: nothing changed" "$before" "$(snap2)"
jrun --summary
eq "off summary: off before drifted, neither current nor drifted" "3 other · 0 current · 2 off · 1 drifted (liam:1)" "$OUT"
eq "off summary: exit 1 (liam)" 1 "$RC"

: > "$WORK/launchctl.log"
jrun
eq "off act: exit 0" 0 "$RC"
ok "off act: tail" 'printf "%s\n" "$OUT" | grep -qx "other logins on this machine: 1 synced / 0 skipped · 0 already current · 2 off"'
eq "off act: liam synced" "$C8" "$(g "$LM" rev-parse HEAD)"
eq "off act: judy untouched" "$C7" "$(g "$J" rev-parse HEAD)"
eq "off act: mia untouched" "v7" "$(cat "$MI/bin/a.sh")"
ok "off act: no backup made for an off login" '[ -z "$(ls -d "$H2"/judy/.claude/fleet.bak-* "$H2"/mia/.claude/fleet.bak-* 2>/dev/null)" ]'
jrun --summary
eq "off summary, liam current: still 0 drifted" "3 other · 1 current · 2 off · 0 drifted" "$OUT"
eq "off summary, liam current: exit 0" 0 "$RC"

# off wins over blocked: judy's local edit is not this run's to report
echo 'judy work' > "$J/bin/b.sh"
jrun --dry-run
eq "off + edit: exit 0, not 4" 0 "$RC"
ok "off + edit: still off, not blocked" 'printf "%s\n" "$OUT" | grep -q "^judy  *git .* off — auto-update off"'
# named in --logins: off is overruled — and now the edit is what blocks
jrun --dry-run --logins judy
eq "named: --logins overrules off, so the edit blocks (exit 4)" 4 "$RC"
ok "named: blocked row names the file" 'printf "%s\n" "$OUT" | grep -q "^judy  *git .* blocked — local edits: bin/b.sh"'
g "$J" checkout -q -- bin/b.sh
jrun --logins judy
eq "named: synced" 0 "$RC"
eq "named: judy at the source commit" "$C8" "$(g "$J" rev-parse HEAD)"

# --include-off: every off login, named or not
g "$J" reset -q --hard "$C7"
jrun --include-off
eq "include-off: exit 0" 0 "$RC"
ok "include-off: both off logins synced, none reported off" 'printf "%s\n" "$OUT" | grep -qx "other logins on this machine: 2 synced / 0 skipped · 1 already current"'
eq "include-off: judy at the source commit" "$C8" "$(g "$J" rev-parse HEAD)"
eq "include-off: mia synced" "v8" "$(cat "$MI/bin/a.sh")"

# the settings file wins over the install conf, both ways; a relocated
# FLEET_CONF_DIR ($HOME-prefixed) is followed; `export KEY=` counts
g "$J" reset -q --hard "$C7"
mkdir -p "$H2/judy/.config/claude-fleet"; echo 'FLEET_INSTALL_SYNC=1' > "$H2/judy/.config/claude-fleet/fleet.settings"
jrun --dry-run
ok "settings 1 over conf 0: judy syncs" 'printf "%s\n" "$OUT" | grep -q "^judy  *git .* sync — 1 commit(s) behind"'
echo 'FLEET_REPO=judy/x' > "$J/fleet.conf"; echo 'FLEET_INSTALL_SYNC=0' > "$H2/judy/.config/claude-fleet/fleet.settings"
jrun --dry-run
ok "settings 0 over conf unset: judy off" 'printf "%s\n" "$OUT" | grep -q "^judy  *git .* off — auto-update off"'
rm -rf "$H2/judy/.config"
printf 'FLEET_REPO=judy/x\nFLEET_CONF_DIR="$HOME/cfg"\n' > "$J/fleet.conf"
mkdir -p "$H2/judy/cfg"; echo 'export FLEET_INSTALL_SYNC=0' > "$H2/judy/cfg/fleet.settings"
jrun --dry-run
ok "relocated FLEET_CONF_DIR: its settings file is the one read" 'printf "%s\n" "$OUT" | grep -q "^judy  *git .* off — auto-update off"'
eq "off never moves the exit code: judy + mia off, liam current → 0" 0 "$RC"

# --to-git leaves an off copy alone the same way
jrun --to-git --dry-run
eq "to-git: an off copy is not converted, exit 0" 0 "$RC"
ok "to-git: mia off" 'printf "%s\n" "$OUT" | grep -q "^mia  *copy .* off — auto-update off"'
contains "to-git: tail counts off" "$OUT" "3 · 0 to convert · 2 already git checkouts · 0 blocked · 1 off (dry run — nothing changed)"
ok "to-git: mia still a copy" '[ ! -e "$MI/.git" ]'
jrun --to-git --dry-run --logins mia
eq "to-git named: a copy to convert (dry-run exit 1)" 1 "$RC"
ok "to-git named: mia converts at its marker" 'printf "%s\n" "$OUT" | grep -q "^mia  *copy .* to-git — clone at $(g "$SRC" rev-parse --short "$C8")"'

# ============================================================================
# K. a closed (0700, someone else's) home — issue #1158
# ============================================================================
# The caller owns every file here, so "someone else's 0700 home" is a home at
# mode 000: the caller cannot enter it, and the owner-sudo shim reopens it for
# exactly the span of each command it runs as the owner (a lock per call, so
# overlapping calls do not close it under each other).
H3="$WORK/homes3"; mkdir -p "$H3/kim/.claude" "$H3/plain"   # plain: open, no install
git clone -q "$SRC" "$H3/kim/.claude/fleet"
K="$H3/kim/.claude/fleet"
g "$K" reset -q --hard HEAD~1
mkdir -p "$H3/kim/Library/LaunchAgents"; touch "$H3/kim/Library/LaunchAgents/com.claude-fleet.collect.plist"
mkdir -p "$WORK/klocks"
# KCWD stands for the caller's own 0700 home (issue #1162): a real owner cannot
# stand in it — BSD cp -R opens "." first, git dies on getcwd — so any owner
# command but the `true` probe run from there fails the way cp does. KFAIL=<cmd>
# makes that owner command fail with its own stderr.
KCWD="$WORK/kcaller"; mkdir -p "$KCWD"
cat > "$WORK/shim/ksudo" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/sudo.log"
[ "\$1" = -n ] && shift
[ "\$1" = -u ] && shift 2
case "\$PWD/" in "$KCWD/"*)
  [ "\$1" = true ] || { echo "\$1: current working directory: Permission denied" >&2; exit 1; } ;;
esac
case " \$* " in *" \${KFAIL:-//} "*) echo "\$KFAIL: boom from the owner side" >&2; exit 23 ;; esac
: > "$WORK/klocks/\$\$"; chmod 700 "$H3/kim"
"\$@"; rc=\$?
rm -f "$WORK/klocks/\$\$"
[ -n "\$(ls "$WORK/klocks")" ] || chmod 000 "$H3/kim"
exit \$rc
EOF
chmod +x "$WORK/shim/ksudo"
KH="$H3/kim"; chmod 000 "$KH"
if [ -x "$KH" ]; then
  echo "sync-logins-selftest: K skipped — running as root, a mode-000 home stays open"
else
  # from the caller's closed cwd, as /fleet-sync-install runs it from a worktree
  krun() { OUT=$(cd "$KCWD" && FLEET_SYNC_LOGINS_HOMES="$H3" FLEET_SYNC_LOGINS_ME=someone-else bash "$SL" --source "$SRC" "$@" 2>&1); RC=$?; }
  ok "closed cwd: the shim really refuses an owner command there" '! (cd "$KCWD" && "$WORK/shim/ksudo" -n -u x cp -Rp "$SRC/bin" "$WORK/kcp" 2>/dev/null)'

  ok "closed: the caller really cannot see the install" '[ ! -d "$K" ]'

  # no sudo: unreadable, never "nothing to sync"
  FLEET_SYNC_LOGINS_SUDO=false krun --summary
  eq "closed no-sudo summary: counted unreadable" "0 other · 0 current · 0 drifted · 1 login(s) unreadable: kim" "$OUT"
  eq "closed no-sudo summary: exit 5 (needs sudo)" 5 "$RC"
  FLEET_SYNC_LOGINS_SUDO=false krun --dry-run
  eq "closed no-sudo dry-run: exit 5" 5 "$RC"
  not_contains "closed no-sudo: never nothing to sync" "$OUT" "nothing to sync"
  ok "closed no-sudo: kim's row says unreadable" 'printf "%s\n" "$OUT" | grep -q "^kim  *? .* unreadable — "'
  not_contains "closed no-sudo: an open home without an install is not unreadable" "$OUT" "plain"
  contains "closed no-sudo: the tail counts it" "$OUT" "other logins on this machine: 0 readable · 1 login(s) unreadable: kim — needs sudo"
  contains "closed no-sudo: the admin command" "$OUT" "sudo $SL --source $SRC --logins kim"
  FLEET_SYNC_LOGINS_SUDO=false krun --dry-run --logins kim
  eq "closed no-sudo --logins kim: needs sudo, not an unknown login" 5 "$RC"
  FLEET_SYNC_LOGINS_SUDO=false krun --dry-run --logins plain
  eq "closed no-sudo --logins plain: still no install (exit 2)" 2 "$RC"

  # with sudo: found and read through the owner
  : > "$WORK/sudo.log"; : > "$WORK/launchctl.log"
  FLEET_SYNC_LOGINS_SUDO="$WORK/shim/ksudo -n" krun --summary
  eq "closed sudo summary: kim is planned, behind" "1 other · 0 current · 1 drifted (kim:1)" "$OUT"

  # a failing owner command: the FAILED row carries ITS stderr (issue #1162)
  KFAIL=rsync FLEET_SYNC_LOGINS_SUDO="$WORK/shim/ksudo -n" krun
  eq "closed act failure: exit 6 (a login failed)" 6 "$RC"
  ok "closed act failure: the row names the step and its stderr" 'printf "%s\n" "$OUT" | grep -q "^kim: FAILED — rsync [^ ]* failed: rsync: boom from the owner side"'
  eq "closed act failure: nothing moved" "$(g "$SRC" rev-parse HEAD~1)" "$(chmod 700 "$KH"; g "$K" rev-parse HEAD; chmod 000 "$KH")"
  contains "closed sudo: discovery asked the owner" "$(cat "$WORK/sudo.log")" "-u $(id -un) test -d $K"
  FLEET_SYNC_LOGINS_SUDO="$WORK/shim/ksudo -n" krun
  eq "closed sudo act: exit 0" 0 "$RC"
  contains "closed sudo act: synced" "$OUT" "kim: synced to"
  not_contains "closed sudo act: no FAILED" "$OUT" "FAILED"
  contains "closed sudo act: its LaunchAgent (listed as the owner) was kicked" "$(cat "$WORK/launchctl.log")" "com.claude-fleet.collect"
  ok "closed: the shim closed the home again" '[ ! -x "$KH" ]'
  FLEET_SYNC_LOGINS_SUDO="$WORK/shim/ksudo -n" krun --summary
  eq "closed sudo: current after the sync" "1 other · 1 current · 0 drifted" "$OUT"
  chmod 700 "$KH"
  eq "closed sudo: HEAD at the source commit" "$(g "$SRC" rev-parse HEAD)" "$(g "$K" rev-parse HEAD)"
fi

echo "sync-logins-selftest OK ($CHECKS checks)"
