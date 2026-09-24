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
if [ "\${1:-}" = -L ]; then s="$SOCKD/\$2"; shift 2; exec "$REAL_TMUX" -S "\$s" "\$@"; fi
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

[ "$FAILS" = 0 ] && { echo "fleet-one-per-login-selftest: all passed"; exit 0; }
echo "fleet-one-per-login-selftest: $FAILS failure(s)"; exit 1
