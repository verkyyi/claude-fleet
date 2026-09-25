#!/bin/bash
# fleet-one-per-login-selftest.sh — one fleet per login (issue #979), in a sandbox
# login (its own HOME, FLEET_CONF_DIR, install root and tmux sockets):
#   1. a login with no fleet: `fleet-up o/a` creates the fleet, named "fleet".
#   2. `fleet-up o/b` with that fleet up ADDS o/b (repos/ overlay), makes it the
#      current repo, and opens no second server; the fleet conf keeps o/a.
#   3. a second fleet is refused: `fleet-up o/c --name other` exits 1, writes no
#      conf and starts no server.
#   4. an existing fleet keeps its name: a down `fleet-cf` comes back up as
#      fleet-cf on its OWN repo when `fleet-up o/d` names another, then adds o/d.
#   5. degenerate: a one-fleet, one-repo login re-running `fleet-up o/a` on the
#      live fleet is a no-op attach — conf byte-identical, no repo filter written.
#   6. settings: the old two-file config (install fleet.conf + fleet conf) loads as
#      it always has; fleet-settings.sh merge folds it into fleet.settings with
#      every value unchanged, drops the fleet conf's (never-read) global-only key,
#      and the settings file is never listed as a fleet.
#   7. the first fleet on a login opens the onboarding guide (issue #1169): ONE
#      `guide` window seeded /fleet-onboard, @pin=1, and global/onboarded written.
#      A later new fleet (marker present), an existing fleet coming back up, and
#      FLEET_ONBOARD=0 open none — and a later new fleet prints exactly what
#      FLEET_ONBOARD=0 does. Legs 1-6 run with FLEET_ONBOARD=0: their old outputs.
#   8. a failed guide stays unmarked; a cooled-down collector tick restarts it
#      once in the same scratch, then records onboarded after the agent runs.
#   9. cf --guide opens/focuses one guide, reuses a live guide, and respawns a
#      guide that fell back to a bare shell.
# The hub, collector, disk gate and trust check are stubbed in a sandbox bin/;
# tmux: a PATH shim maps every `-L <label>` to a private socket under $SOCKD.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-one-per-login-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
mkdir -p "$WORK/shim" "$WORK/root/bin" "$WORK/home" "$WORK/tmp"
# Sockets in a SHORT dir: a unix socket path is capped at ~104 bytes, and macOS's
# $TMPDIR alone eats half of it.
SOCKD="$(mktemp -d /tmp/f979.XXXXXX)" || exit 2
cat > "$WORK/shim/tmux" <<EOF
#!/bin/bash
if [ "\${1:-}" = -L ]; then
  s="$SOCKD/\$2"; shift 2
  if [ "\${1:-}" = attach ] && [ -n "\${FLEET_TEST_ATTACH_LOG:-}" ]; then
    printf '%s\n' "\$*" > "\$FLEET_TEST_ATTACH_LOG"
    exit 0
  fi
  exec "$REAL_TMUX" -S "\$s" "\$@"
fi
if [ -n "\${TMUX:-}" ]; then exec "$REAL_TMUX" "\$@"; fi
exec "$REAL_TMUX" -S "$SOCKD/none" "\$@"
EOF
printf '#!/bin/sh\nexit 1\n' > "$WORK/shim/gh"
chmod +x "$WORK/shim/tmux" "$WORK/shim/gh"
export PATH="$WORK/shim:$PATH"

cleanup() {
  local s; for s in "$SOCKD"/*; do [ -S "$s" ] && "$REAL_TMUX" -S "$s" kill-server 2>/dev/null; done
  rm -rf "$WORK" "$SOCKD"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" TMPDIR="$WORK/tmp" FLEET_C="$WORK/cache"
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_SESSION FLEET_SKIP_GLOBAL_CONF
unset _FLEET_GLOBAL_CONF_SOURCED FLEET_GLOBAL_MAX_SESSIONS
export FLEET_ONBOARD=0     # legs 1-6: no guide (#1169) — leg 7 turns it back on

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
eq()   { [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }
has()  { case "$2" in *"$3"*) ;; *) fail "$1: [$3] not in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) fail "$1: [$3] unexpectedly in: $2" ;; esac; }
leg()  { if [ "$FAILS" = "${_legf:-0}" ]; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fi; _legf=$FAILS; }

# ---- sandbox install root: the real scripts, hub/collector/gates stubbed ----
# (a REAL root dir holding bin/, so fleet-lib's <bin>/../fleet.conf is $WORK/root/)
SB="$WORK/root/bin"
for f in "$BIN"/*; do ln -s "$f" "$SB/$(basename "$f")"; done
mkdir -p "$WORK/root/shell"
cp "$BIN/../shell/cw.zsh" "$WORK/root/shell/cw.zsh"
rm -f "$SB/hub-session.sh" "$SB/tmux-dash-collect.sh" "$SB/fleet-diskguard.sh" "$SB/fleet-trust.sh"
cat > "$SB/hub-session.sh" <<'EOF'
#!/bin/bash
tmux -L "$HUB_SESSION" new-window -d -t "$HUB_SESSION:" -n plan -c "$HUB_CWD" 'sleep 3600'
EOF
printf '#!/bin/sh\nexit 0\n' > "$SB/tmux-dash-collect.sh"
printf '#!/bin/sh\nexit 0\n' > "$SB/fleet-diskguard.sh"
printf '#!/bin/sh\necho trusted\n' > "$SB/fleet-trust.sh"
chmod +x "$SB"/hub-session.sh "$SB"/tmux-dash-collect.sh "$SB"/fleet-diskguard.sh "$SB"/fleet-trust.sh
UP="$SB/fleet-up.sh"

mkrepo() { git init -q "$1" && git -C "$1" remote add origin "https://github.com/$2.git"; }
for r in a b c d; do mkrepo "$WORK/src/$r" "o/$r"; done
up()   { bash "$UP" "$@" --base master </dev/null 2>&1; }
live() { local s n=0; for s in "$SOCKD"/*; do [ -S "$s" ] && "$REAL_TMUX" -S "$s" has-session 2>/dev/null && n=$((n+1)); done; echo "$n"; }
val()  { ( . "$1" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\"" ); }
lib()  { bash -c ". '$SB/fleet-lib.sh'; $1"; }

# ---- 1. a login with no fleet: the new fleet is called "fleet" ----
out=$(up o/a "$WORK/src/a"); rc=$?
eq "1 rc" "$rc" 0
has "1 up" "$out" "fleet 'fleet' is up (repo=o/a"
[ -f "$FLEET_CONF_DIR/fleets/fleet/conf" ] || fail "1: no fleets/fleet/conf"
eq "1 conf repo" "$(val "$FLEET_CONF_DIR/fleets/fleet/conf" FLEET_REPO)" o/a
eq "1 servers" "$(live)" 1
leg "1 new login → fleet named 'fleet'"

# ---- 2. a new repo with the fleet up: added to it; a stale repo filter dropped ----
printf 'o/a\n' > "$FLEET_CONF_DIR/fleets/fleet/current-repo"   # left by the old picker (#1034)
out=$(up o/b "$WORK/src/b"); rc=$?
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-up o/b\n%s\n' "$out"
eq "2 rc" "$rc" 0
has "2 added" "$out" "added o/b to fleet 'fleet'"
hasnt "2 no current-repo pick" "$out" "current repo →"
[ -e "$FLEET_CONF_DIR/fleets/fleet/current-repo" ] && fail "2: fleet-up left the stale current-repo file (#1034)"
eq "2 hosts" "$(lib 'fleet_repos fleet' | tr '\n' ' ')" "o/a o/b "
eq "2 conf keeps its repo" "$(val "$FLEET_CONF_DIR/fleets/fleet/conf" FLEET_REPO)" o/a
eq "2 overlay main" "$(val "$(lib 'fleet_repo_conf_file fleet o/b')" FLEET_MAIN)" "$WORK/src/b"
eq "2 servers" "$(live)" 1
out=$(up o/b "$WORK/src/b"); rc=$?
eq "2 re-add rc" "$rc" 0
has "2 re-add" "$out" "already hosts o/b"
leg "2 new repo → added to the fleet, stale filter dropped"

# ---- 3. a second fleet is refused ----
out=$(up o/c "$WORK/src/c" --name other); rc=$?
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-up o/c --name other\n%s\n' "$out"
eq "3 rc" "$rc" 1
has "3 refused" "$out" "refusing a second fleet 'other'"
has "3 names the fleet" "$out" "already has 'fleet'"
[ -e "$FLEET_CONF_DIR/fleets/other/conf" ] && fail "3: a conf was written for 'other'"
eq "3 servers" "$(live)" 1
leg "3 second fleet refused"

# ---- 5. degenerate: one fleet, one repo — a re-run is a no-op attach ----
"$REAL_TMUX" -S "$SOCKD/fleet" kill-server 2>/dev/null
export FLEET_CONF_DIR="$WORK/conf5"
out=$(up o/a "$WORK/src/a"); eq "5 first rc" "$?" 0
c5="$FLEET_CONF_DIR/fleets/fleet/conf"; before=$(cat "$c5")
out=$(up o/a "$WORK/src/a"); rc=$?
eq "5 rc" "$rc" 0
has "5 already up" "$out" "fleet 'fleet' is already up"
hasnt "5 no add" "$out" "added"
eq "5 conf unchanged" "$(cat "$c5")" "$before"
[ -e "$FLEET_CONF_DIR/fleets/fleet/current-repo" ] && fail "5: a repo filter was written for a one-repo fleet"
[ -d "$FLEET_CONF_DIR/fleets/fleet/repos" ] && fail "5: a repos/ overlay appeared"
"$REAL_TMUX" -S "$SOCKD/fleet" kill-server 2>/dev/null
leg "5 degenerate one-fleet one-repo unchanged"

# ---- 4. an existing fleet keeps its name, even when down ----
export FLEET_CONF_DIR="$WORK/conf4"
mkdir -p "$FLEET_CONF_DIR/fleets/fleet-cf"
printf 'FLEET_REPO="o/a"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="trunk"\nFLEET_MODEL="opus"\n' \
  "$WORK/src/a" > "$FLEET_CONF_DIR/fleets/fleet-cf/conf"
out=$(cd "$WORK/src/d" && bash "$UP" </dev/null 2>&1); rc=$?
eq "4 rc" "$rc" 0
has "4 own name" "$out" "fleet 'fleet-cf' is up (repo=o/a base=trunk"
has "4 added" "$out" "added o/d to fleet 'fleet-cf'"
[ -S "$SOCKD/fleet-cf" ] || fail "4: fleet-cf's server is not up"
eq "4 conf keeps repo" "$(val "$FLEET_CONF_DIR/fleets/fleet-cf/conf" FLEET_REPO)" o/a
eq "4 conf keeps its keys" "$(val "$FLEET_CONF_DIR/fleets/fleet-cf/conf" FLEET_MODEL)" opus
[ -d "$FLEET_CONF_DIR/fleets/fleet" ] && fail "4: a fleet named 'fleet' was created"
out=$(cd "$WORK/tmp" && bash "$UP" </dev/null 2>&1); rc=$?
eq "4 outside a checkout rc" "$rc" 0
has "4 outside a checkout" "$out" "fleet 'fleet-cf' is already up"
"$REAL_TMUX" -S "$SOCKD/fleet-cf" kill-server 2>/dev/null
out=$(cd "$WORK/tmp" && bash "$UP" </dev/null 2>&1); rc=$?
eq "4 down, outside a checkout rc" "$rc" 0
has "4 down, outside a checkout" "$out" "fleet 'fleet-cf' is up (repo=o/a base=trunk"
eq "4 base kept" "$(val "$FLEET_CONF_DIR/fleets/fleet-cf/conf" FLEET_BASE_BRANCH)" trunk
leg "4 existing fleet keeps its name"

# ---- 6. one settings file per login ----
export FLEET_CONF_DIR="$WORK/conf6"
mkdir -p "$FLEET_CONF_DIR/fleets/fleet-cf"
printf 'FLEET_GLOBAL_MAX_SESSIONS=7\nFLEET_X=install\nFLEET_Y=install\n' > "$WORK/root/fleet.conf"
cat > "$FLEET_CONF_DIR/fleets/fleet-cf/conf" <<EOF
# claude-fleet: fleet 'fleet-cf' — written by fleet-up.sh 2026-09-22 00:00:00
FLEET_REPO="o/a"
FLEET_MAIN="$WORK/src/a"
FLEET_BASE_BRANCH="master"
FLEET_X=fleet
FLEET_GLOBAL_MAX_SESSIONS=99
EOF
probe='fleet_load_conf fleet-cf; printf "%s %s %s %s %s" "$FLEET_REPO" "$FLEET_X" "$FLEET_Y" "$FLEET_GLOBAL_MAX_SESSIONS" "$(bash -c "echo \$FLEET_GLOBAL_MAX_SESSIONS")"'
want="o/a fleet install 7 7"
eq "6 two-file loads" "$(lib "$probe")" "$want"
eq "6 not a fleet" "$(lib 'fleet_each_conf | cut -f1 | tr "\n" " "')" "fleet-cf "
out=$(bash "$SB/fleet-settings.sh" merge --dry-run 2>&1); rc=$?
eq "6 dry rc" "$rc" 0
[ -e "$FLEET_CONF_DIR/fleet.settings" ] && fail "6: --dry-run wrote the settings file"
out=$(bash "$SB/fleet-settings.sh" merge 2>&1); rc=$?
eq "6 merge rc" "$rc" 0
has "6 dropped" "$out" "FLEET_GLOBAL_MAX_SESSIONS"
[ -f "$FLEET_CONF_DIR/fleet.settings" ] || fail "6: no fleet.settings"
[ -e "$WORK/root/fleet.conf" ] && fail "6: the install fleet.conf was not moved aside"
[ -f "$WORK/root/fleet.conf.pre-merge" ] || fail "6: no fleet.conf.pre-merge"
eq "6 merged loads the same" "$(lib "$probe")" "$want"
eq "6 conf is identity" "$(grep -c '^FLEET_' "$FLEET_CONF_DIR/fleets/fleet-cf/conf")" 3
eq "6 still not a fleet" "$(lib 'fleet_each_conf | cut -f1 | tr "\n" " "')" "fleet-cf "
eq "6 hook resolver" "$(bash "$SB/fleet-hook-conf.sh" --session fleet-cf FLEET_X FLEET_GLOBAL_MAX_SESSIONS | tr '\n' ' ')" "fleet 7 "
out=$(bash "$SB/fleet-settings.sh" merge 2>&1); rc=$?
eq "6 re-merge rc" "$rc" 1
has "6 re-merge" "$out" "already merged"
# the settings file wins over an install fleet.conf that reappears (dual-read)
printf 'FLEET_Y=reinstalled\nFLEET_GLOBAL_MAX_SESSIONS=3\n' > "$WORK/root/fleet.conf"
eq "6 settings win" "$(lib "$probe")" "o/a fleet install 7 7"
# the config modal writes a global key to the settings file once it exists
eq "6 modal target" "$(bash -c ". '$SB/fleet-config-lib.sh'; fcfg_target_conf fleet-cf global")" "$FLEET_CONF_DIR/fleet.settings"
rm -f "$WORK/root/fleet.conf"
mkdir -p "$FLEET_CONF_DIR/fleets/two"; printf 'FLEET_REPO="o/b"\n' > "$FLEET_CONF_DIR/fleets/two/conf"
rm -f "$FLEET_CONF_DIR/fleet.settings"
out=$(bash "$SB/fleet-settings.sh" merge 2>&1); rc=$?
eq "6 two fleets rc" "$rc" 1
has "6 two fleets" "$out" "several fleets"
leg "6 one settings file per login (dual-read)"

# ---- 7. the first fleet on a login opens the guide, pinned (issue #1169) ----
export FLEET_CONF_DIR="$WORK/conf7"; unset FLEET_ONBOARD
# The guide is a real scratch: it needs a checkout with a commit + origin/master,
# and its agent is a stub that records its seed and sleeps.
g="$WORK/src/g"; mkrepo "$g" o/g
git -C "$g" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$g" update-ref refs/remotes/origin/master HEAD
rm -f "$SB/fleet-claude.sh"
cat > "$SB/fleet-claude.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" > "$WORK/guide-seed"; exec sleep 3600
EOF
chmod +x "$SB/fleet-claude.sh"
wins() { "$REAL_TMUX" -S "$SOCKD/fleet" list-windows -t fleet -F "$1" 2>/dev/null; }
nohms() { sed 's/[0-9][0-9]:[0-9][0-9]:[0-9][0-9]//'; }
marker="$FLEET_CONF_DIR/global/onboarded"
out=$(up o/g "$g"); rc=$?
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-up o/g (first fleet)\n%s\n' "$out"
eq "7 rc" "$rc" 0
has "7 says so" "$out" "opened the onboarding guide"
eq "7 one guide" "$(wins '#{window_name}' | grep -cx guide)" 1
eq "7 guide pinned" "$(wins '#{window_name} #{@pin} #{@raw}' | grep '^guide ')" "guide 1 1"
[ -f "$marker" ] || fail "7: global/onboarded not written"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WORK/guide-seed" ] && break; sleep 0.3; done
eq "7 seeded" "$(cat "$WORK/guide-seed" 2>/dev/null)" "/fleet-onboard"
"$REAL_TMUX" -S "$SOCKD/fleet" kill-server 2>/dev/null
# an existing fleet coming back up never reads the marker — even with none
rm -f "$marker"
out=$(up o/g "$g"); eq "7 existing rc" "$?" 0
eq "7 existing: no guide" "$(wins '#{window_name}' | grep -cx guide)" 0
[ -e "$marker" ] && fail "7: an existing fleet wrote the marker"
"$REAL_TMUX" -S "$SOCKD/fleet" kill-server 2>/dev/null
# a second NEW fleet on an onboarded login vs FLEET_ONBOARD=0: same bytes, no guide
date > "$marker"; rm -rf "$FLEET_CONF_DIR/fleets"
out2=$(up o/g "$g" | nohms)
eq "7 second: no guide" "$(wins '#{window_name}' | grep -cx guide)" 0
"$REAL_TMUX" -S "$SOCKD/fleet" kill-server 2>/dev/null
rm -f "$marker"; rm -rf "$FLEET_CONF_DIR/fleets"
out3=$(FLEET_ONBOARD=0 up o/g "$g" | nohms)
eq "7 off: no guide" "$(wins '#{window_name}' | grep -cx guide)" 0
[ -e "$marker" ] && fail "7: FLEET_ONBOARD=0 wrote the marker"
has "7 off: up" "$out3" "fleet 'fleet' is up (repo=o/g"
eq "7 second == off, byte for byte" "$out2" "$out3"
hasnt "7 off: silent" "$out3" "guide"
"$REAL_TMUX" -S "$SOCKD/fleet" kill-server 2>/dev/null
leg "7 first fleet opens the pinned guide, once"

# ---- 8. failed agent stays unmarked; one cooled-down tick restarts it ----
export FLEET_CONF_DIR="$WORK/conf8"; unset FLEET_ONBOARD
launches="$WORK/guide-launches"
cat > "$SB/fleet-claude.sh" <<EOF
#!/bin/bash
printf 'attempt\n' >> "$launches"
exit 7
EOF
chmod +x "$SB/fleet-claude.sh"
out=$(FLEET_GUIDE_WAIT_SECS=2 up o/g "$g"); rc=$?
eq "8 rc" "$rc" 0
has "8 failure explained" "$out" "collector will retry"
marker="$FLEET_CONF_DIR/global/onboarded"
[ ! -e "$marker" ] || fail "8: failed agent wrote onboarded"
[ -f "$FLEET_CONF_DIR/global/onboard.pending" ] || fail "8: missing retry marker"
eq "8 first attempt" "$(wc -l < "$launches" | tr -d ' ')" 1
eq "8 one guide window" "$(wins '#{window_name}' | grep -cx guide)" 1

# A tick inside the cooldown leaves the failed window alone. After the clock
# advances, respawn reuses that window and its scratch worktree.
FLEET_GUIDE_COOLDOWN=3600 lib 'fleet_guide_tick fleet'
eq "8 cooldown" "$(wc -l < "$launches" | tr -d ' ')" 1
cat > "$SB/fleet-claude.sh" <<EOF
#!/bin/bash
printf 'attempt\n' >> "$launches"
exec sleep 3600
EOF
chmod +x "$SB/fleet-claude.sh"
printf '0\n' > "$FLEET_CONF_DIR/global/onboard.retry"
FLEET_GUIDE_COOLDOWN=3600 lib 'fleet_guide_tick fleet'
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(wc -l < "$launches" | tr -d ' ')" = 2 ] && break
  sleep 0.2
done
eq "8 restarted once" "$(wc -l < "$launches" | tr -d ' ')" 2
eq "8 reused guide window" "$(wins '#{window_name}' | grep -cx guide)" 1
FLEET_GUIDE_COOLDOWN=3600 lib 'fleet_guide_tick fleet'
[ -f "$marker" ] || fail "8: recovered agent not marked onboarded"
[ ! -e "$FLEET_CONF_DIR/global/onboard.pending" ] || fail "8: pending marker not cleared"
eq "8 no extra restart" "$(wc -l < "$launches" | tr -d ' ')" 2
"$REAL_TMUX" -S "$SOCKD/fleet" kill-server 2>/dev/null
leg "8 failed guide restarts once after cooldown"

# ---- 9. cf --guide recalls the existing or failed guide (issue #1171) ----
export FLEET_CONF_DIR="$WORK/conf9" FLEET_ONBOARD=0
: > "$launches"
out=$(up o/g "$g"); eq "9 up rc" "$?" 0
eq "9 starts without guide" "$(wins '#{window_name}' | grep -cx guide)" 0
guide() {
  local pane
  pane=$(tmux -L fleet list-panes -t fleet:plan -F '#{pane_id}' | head -n1)
  if command -v zsh >/dev/null 2>&1; then
    TMUX="$SOCKD/fleet,0,0" TMUX_PANE="$pane" zsh -f -c ". '$WORK/root/shell/cw.zsh'; cf --guide" 2>&1
  else
    TMUX="$SOCKD/fleet,0,0" TMUX_PANE="$pane" bash "$SB/fleet-guide.sh" 2>&1
  fi
}
tmux -L fleet select-window -t fleet:plan
out=$(guide); eq "9 open rc" "$?" 0
eq "9 one guide" "$(wins '#{window_name}' | grep -cx guide)" 1
eq "9 guide pinned" "$(wins '#{window_name} #{@pin}' | grep '^guide ')" "guide 1"
eq "9 focused" "$(wins '#{window_name} #{window_active}' | grep ' 1$')" "guide 1"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(wc -l < "$launches" | tr -d ' ')" = 1 ] && break
  sleep 0.2
done
eq "9 first launch" "$(wc -l < "$launches" | tr -d ' ')" 1
tmux -L fleet select-window -t fleet:plan
out=$(guide); eq "9 live rc" "$?" 0
eq "9 live reused" "$(wc -l < "$launches" | tr -d ' ')" 1
eq "9 live focused" "$(wins '#{window_name} #{window_active}' | grep ' 1$')" "guide 1"

# From an ordinary login shell, select the guide before attaching to the fleet.
tmux -L fleet select-window -t fleet:plan
out=$(FLEET_TEST_ATTACH_LOG="$WORK/attach" bash "$SB/fleet-guide.sh" 2>&1)
eq "9 outside rc" "$?" 0
eq "9 outside attach" "$(cat "$WORK/attach")" "attach -t fleet"
eq "9 outside focused" "$(wins '#{window_name} #{window_active}' | grep ' 1$')" "guide 1"
eq "9 outside reused" "$(wc -l < "$launches" | tr -d ' ')" 1

# The launched agent exits while its original pane shell stays open.
pane_pid=$(tmux -L fleet display-message -p -t fleet:guide '#{pane_pid}')
child=$(pgrep -P "$pane_pid" | head -n1)
[ -n "$child" ] && kill "$child"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  lib 'fleet_guide_alive fleet' || break
  sleep 0.2
done
lib 'fleet_guide_alive fleet' && fail "9: killed agent still considered alive"
tmux -L fleet select-window -t fleet:plan
out=$(guide); eq "9 bare-shell rc" "$?" 0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(wc -l < "$launches" | tr -d ' ')" = 2 ] && break
  sleep 0.2
done
eq "9 respawned once" "$(wc -l < "$launches" | tr -d ' ')" 2
eq "9 reused window" "$(wins '#{window_name}' | grep -cx guide)" 1
eq "9 respawn focused" "$(wins '#{window_name} #{window_active}' | grep ' 1$')" "guide 1"
"$REAL_TMUX" -S "$SOCKD/fleet" kill-server 2>/dev/null
leg "9 cf --guide opens, focuses, and repairs the guide"

[ "$FAILS" = 0 ] && { echo "fleet-one-per-login-selftest: all passed"; exit 0; }
echo "fleet-one-per-login-selftest: $FAILS failure(s)"; exit 1
