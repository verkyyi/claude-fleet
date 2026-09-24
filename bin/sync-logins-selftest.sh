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
cleanup() { rm -rf "$WORK"; }
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
contains "sudo: rsync ran as the owner" "$(cat "$WORK/sudo.log")" "-n -u $(id -un) rsync"

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

echo "sync-logins-selftest OK ($CHECKS checks)"
