#!/bin/bash
# fleet-client-live-update-selftest.sh — the client updates while it is in use
# (issue #1781, EPIC #1776 C5): bin/fleet-client-update.sh `tick` / `apply` /
# `start` against a RUNNING client — bin/fleet-shell.sh started for real on its
# own isolated sockets (`-L flu<pid>` and its stage), from an installed home
# whose versions are symlink farms of this bin/ (a changed file is a copy) —
# and bin/fleet-shell.sh `reload`, bin/fleet-client-badge.sh's update segment.
#
# Nothing real is reached: the hub address is a placeholder, fleet-connect.py is
# a FAKE (prints a --pick answer for m5), ssh is a shim that holds the proxy
# pane open, the lease command is `false`, the warm / actions loops are off.
#
# Legs:
#   A. idle gate   a staged client and someone typing (idle < FLEET_CLIENT_IDLE_SECS)
#                  → tick applies nothing
#   B. in place    tick on an idle client → exit 4: <home> (a plain dir) adopted as
#                  versions/v1 and switched to versions/v2 by its link; the shell's
#                  and the stage's tmux server pids unchanged; the list pane's
#                  @sidebar_version rises to v2's VIEW_VERSION; the proxy pane's pid
#                  unchanged (fleet-remote-view.sh did not change); the mirror and
#                  the conf follow the link; update.state done → the badge says
#                  ✓ 已更新到 beef002 — and not once FLEET_CLIENT_UPDATE_SHOW has passed
#   C. migration 3 a migration that needs a restart → exit 3, NOTHING switched, the
#                  state `later`, the badge says 新版已就绪 · 下次打开生效; the next
#                  tick waits (exit 3) and does not run the migration again
#   D. migration 0 a newer staged client's migration (one the old client did not
#                  have) runs once with <from> <to>, then the switch
#   E. failure     the new client's reload fails half way (its conf already
#                  rewritten) → exit 1: the link back on the old version, the conf
#                  as it was, both servers alive, the state `failed` with a reason
#   F. proxy       a client whose fleet-remote-view.sh changed → the proxy pane is
#                  respawned (new pid), the servers still the same
#   G. restart     a `later` client and nobody attached: `start` closes the
#                  client's servers and switches (exit 3)
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-client-live-update selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-client-live-update selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/flu-st.XXXXXX")" || exit 2
SESS="flu$$"
export HOME="$WORK/home"; mkdir -p "$HOME/.config/claude-fleet"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share"
export FLEET_CONF_DIR="$HOME/.config/claude-fleet"
export FLEET_SHELL_SESSION="$SESS" FLEET_SHELL_CACHE="$WORK/cache"
export FLEET_REMOTE_BIN="$BIN" FLEET_REMOTE_VIA_HUB=0 FLEET_SHELL_NO_ATTACH=1
export FLEET_HUB_SESSIONS_LOOP_SECS=8 FLEET_HUB_SESSIONS_EVERY=1 FLEET_HUB_SESSIONS_WATCHED_EVERY=1
export FLEET_SHELL_WARM=0 FLEET_CLIENT_ACTIONS=0 FLEET_CLIENT_LEASE_CMD=false FLEET_CLIENT_LEASE_EVERY=3600
export FLEET_UI_LANG=zh FLEET_CLIENT_CHECK_SECS=999999
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_SESSION FLEET_SHELL FLEET_HUB_SESSIONS_CLIENT FLEET_SIDEBAR_SOURCE
unset CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_NODE_ALIASES FLEET_CLIENT_ROOT FLEET_CLIENT_STATE
unset FLEET_CLIENT_UPDATE_STATE FLEET_CLIENT_IDLE_SECS FLEET_CLIENT_UPDATE_SHOW FLEET_CLIENT_AUTO_UPDATE
export FLEET_HUB_URL=https://hub.example
ROOT="$XDG_DATA_HOME/claude-fleet"; V="$ROOT.versions"
STATE="$XDG_CACHE_HOME/claude-fleet/client"
UST="$FLEET_SHELL_CACHE/update.state"

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (must not hold '$3')" "$2" ;; esac; }
ts() { "$REAL_TMUX" -L "$SESS" "$@"; }
tsg() { "$REAL_TMUX" -L "$SESS-stage" "$@"; }
# waitfor <secs> <cmd…> — until the command succeeds. The command is RE-RUN each
# try, so a reading goes in a function below — a "$(…)" argument is read once (#1620)
waitfor() {
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
CLIENT_PID=''
cleanup() {
  exec 7>&- 2>/dev/null
  [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null
  "$REAL_TMUX" -L "$SESS" kill-server 2>/dev/null
  "$REAL_TMUX" -L "$SESS-stage" kill-server 2>/dev/null
  pkill -f "fleet-shell.sh keeper $SESS" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- the fakes ---------------------------------------------------------------------
cat > "$WORK/fleet-connect.py" <<EOF
#!/usr/bin/env python3
import json, sys
if "--pick" in sys.argv:
    print(json.dumps({"machine": "m5", "hostname": "macmini", "reason": "last", "login": "verk",
                      "machines": [{"alias": "m5", "hostname": "macmini"}]}))
sys.exit(0)
EOF
SHIM="$WORK/shim"; mkdir -p "$SHIM"
cat > "$SHIM/ssh" <<'EOF'
#!/bin/bash
op=''
while [ $# -gt 0 ]; do
  case "$1" in -O) op=$2; shift 2 ;; -S|-o|-L) shift 2 ;; -*) shift ;; *) break ;; esac
done
[ -n "$op" ] && exit 1
case "$*" in *" attach "*) exec sleep 600 ;; *" watch "*) exec sleep 600 ;; esac
exit 0
EOF
chmod +x "$SHIM/ssh"
export FLEET_REMOTE_SSH_CMD="$SHIM/ssh"
printf '{"sessions": [], "nodes": [{"machine_name": "macmini", "availability": "online", "sessions": 0}]}\n' > "$WORK/sessions.json"
export FLEET_HUB_SESSIONS_CMD="cat $WORK/sessions.json" FLEET_HUB_SESSIONS_USER=verk

# mkver <dir> <version> <commit> — a client: every file of this bin/ and conf/ a
# symlink (the fake connect a copy), and the mark the installer writes
mkver() {
  local d="$1" f
  rm -rf "$d"; mkdir -p "$d/bin" "$d/conf"
  for f in "$BIN"/*; do [ -f "$f" ] && ln -s "$f" "$d/bin/${f##*/}"; done
  for f in "$BIN"/../conf/*; do [ -f "$f" ] && ln -s "$f" "$d/conf/${f##*/}"; done
  rm -f "$d/bin/fleet-connect.py"; cp "$WORK/fleet-connect.py" "$d/bin/"; chmod +x "$d/bin/fleet-connect.py"
  # the two that find their home from their own path: real files, as installed
  own "$d" fleet-shell.sh; own "$d" fleet-client-update.sh
  printf 'version=%s\ncompat=1\ncommit=%s\nhub=%s\n' "$2" "$3" "$FLEET_HUB_URL" > "$d/.client-version"
}
# own <dir> <file> — that file a copy of its own (to change it)
own() { rm -f "$1/bin/$2"; cp "$BIN/$2" "$1/bin/$2"; }
# stage_ver <key> <commit> — versions/<key> built and named by .next
stage_ver() {
  mkver "$V/$1" "$1" "$2"; : > "$V/$1/.staged"; printf '%s\n' "$1" > "$V/.next"
}
upd() { bash "$ROOT/bin/fleet-client-update.sh" "$@" 2>>"$WORK/upd.err"; }
shell_pid() { ts display-message -p -t "=$SESS:" '#{pid}' 2>/dev/null; }
stage_pid() { tsg display-message -p -t "=$SESS-stage:" '#{pid}' 2>/dev/null; }
proxy_pid() { tsg list-panes -s -t "=$SESS-stage" -F '#{pane_pid} #{pane_start_command}' 2>/dev/null | awk '/fleet-remote-view.sh/ { print $1; exit }'; }
side_ver() { ts list-panes -s -t "=$SESS" -F '#{@sidebar} #{@sidebar_version}' 2>/dev/null | awk '$1 == "1" { print $2; exit }'; }
attached() { [ -n "$(ts list-clients -F x 2>/dev/null)" ]; }
not() { ! "$@"; }
side_is_any() { [ -n "$(side_ver)" ]; }
side_is() { [ "$(side_ver)" = "$1" ]; }
proxy_up() { [ -n "$(proxy_pid)" ]; }
proxy_moved() { local p; p=$(proxy_pid); [ -n "$p" ] && [ "$p" != "$1" ]; }
link_is() { [ "$(cd "$ROOT" 2>/dev/null && pwd -P)" = "$(cd "$V/$1" 2>/dev/null && pwd -P)" ]; }
badge() { FLEET_CLIENT_BADGE_WHERE_CMD='echo {}' FLEET_CLIENT_BADGE_CACHE="$WORK/badge" bash "$ROOT/bin/fleet-client-badge.sh" cw=120 2>/dev/null; }
VV=$(sed -n 's/^VIEW_VERSION = "\([^"]*\)".*/\1/p' "$BIN/fleet-sidebar.py")

# --- the running client, v1 (a plain-dir home, as the installer leaves it) -----------
mkver "$ROOT" v1 c0ffee1
mkdir -p "$STATE"; date +%s > "$STATE/checked"     # the hourly ask: done, nothing to fetch
PATH="$SHIM:$PATH" bash "$ROOT/bin/fleet-shell.sh" >"$WORK/start.out" 2>&1 || { cat "$WORK/start.out" >&2; fail 'the client did not start'; }
# a client attached (control mode, fed through a fifo): the list is drawn only for one
mkfifo "$WORK/client.fifo"
"$REAL_TMUX" -L "$SESS" -C attach-session -t "=$SESS" < "$WORK/client.fifo" >/dev/null 2>&1 &
CLIENT_PID=$!
exec 7> "$WORK/client.fifo"
waitfor 5 attached || fail 'no client attached'
ts resize-window -t "=$SESS:" -x 200 -y 50 2>/dev/null
# the list pane: the call the hooks (and reload) make
ts set-option -g @popup_open 0 2>/dev/null
ts run-shell -t "=$SESS:" "bash '$FLEET_SHELL_CACHE/bin/fleet-sidebar.sh' sync '#{session_id}' >>'$WORK/sync.err' 2>&1 || :"
waitfor 10 side_is_any || fail 'no list pane after the start' "$(ts list-panes -s -F '#{pane_id} #{@sidebar}' 2>&1; cat "$WORK/sync.err")"
waitfor 10 proxy_up || fail 'no proxy pane on the stage' "$(tsg list-panes -s -F '#{pane_start_command}' 2>&1)"
eq 'start: the list runs this VIEW_VERSION' "$VV" "$(side_ver)"
SP=$(shell_pid); GP=$(stage_pid); PP=$(proxy_pid)

# --- A. someone is typing ------------------------------------------------------------
stage_ver v2 beef002
own "$V/v2" fleet-sidebar.py
sed -i.bak "s/^VIEW_VERSION = \"$VV\"/VIEW_VERSION = \"${VV}u1781\"/" "$V/v2/bin/fleet-sidebar.py"; rm -f "$V/v2/bin/fleet-sidebar.py.bak"
FLEET_CLIENT_IDLE_SECS=99999999 upd tick "$SESS"; rc=$?
eq 'A: not idle long enough → tick applies nothing (exit 0)' 0 "$rc"
CHECKS=$((CHECKS + 1)); [ -L "$ROOT" ] && fail 'A: <home> switched while not idle'

# --- B. idle: in place -----------------------------------------------------------------
FLEET_CLIENT_IDLE_SECS=0 upd tick "$SESS"; rc=$?
eq 'B: idle → applied (exit 4)' 4 "$rc"
CHECKS=$((CHECKS + 1)); link_is v2 || fail 'B: <home> is not the link to versions/v2' "$(ls -la "$XDG_DATA_HOME")"
CHECKS=$((CHECKS + 1)); [ -f "$V/v1/.client-version" ] || fail 'B: the plain-dir home was not adopted as versions/v1' "$(ls -a "$V")"
eq 'B: .prev names the old one' v1 "$(cat "$V/.prev" 2>/dev/null)"
CHECKS=$((CHECKS + 1)); [ ! -e "$V/.next" ] || fail 'B: .next left behind'
eq "B: the shell's tmux server: same pid" "$SP" "$(shell_pid)"
eq "B: the stage's tmux server: same pid" "$GP" "$(stage_pid)"
waitfor 10 side_is "${VV}u1781"
eq 'B: the list redrawn on the new VIEW_VERSION' "${VV}u1781" "$(side_ver)"
eq 'B: the proxy pane untouched (fleet-remote-view.sh unchanged): same pid' "$PP" "$(proxy_pid)"
has 'B: the mirror follows the link' "$(readlink "$FLEET_SHELL_CACHE/bin/fleet-sidebar.py")" "${ROOT#"$WORK"}/bin/fleet-sidebar.py"
has 'B: the conf is the new one, paths on the mirror' "$(grep -m1 'fleet-client-badge.sh' "$FLEET_SHELL_CACHE/tmux.conf")" "$FLEET_SHELL_CACHE/bin/fleet-client-badge.sh"
st=$(cat "$UST" 2>/dev/null)
has 'B: update.state done' "$st" '"phase": "done"'
has 'B: update.state names the new commit' "$st" '"commit": "beef002"'
has 'B: the badge says ✓ 已更新到 beef002' "$(FLEET_CLIENT_UPDATE_SHOW=600 badge)" '✓ 已更新到 beef002'
hasnt 'B: … and not once FLEET_CLIENT_UPDATE_SHOW has passed' "$(FLEET_CLIENT_UPDATE_SHOW=0 badge)" '已更新到'
SP=$(shell_pid); GP=$(stage_pid); PP=$(proxy_pid)

# --- C. a migration that needs a restart ---------------------------------------------
stage_ver v3 beef003
mkdir -p "$V/v3/bin/client-migrations"
printf '#!/bin/bash\necho run >> %s/mig3.count\nexit 3\n' "$WORK" > "$V/v3/bin/client-migrations/0001-restart.sh"
FLEET_CLIENT_IDLE_SECS=0 upd tick "$SESS"; rc=$?
eq 'C: migration exit 3 → exit 3' 3 "$rc"
CHECKS=$((CHECKS + 1)); link_is v2 || fail 'C: switched although a restart was needed'
has 'C: update.state later' "$(cat "$UST" 2>/dev/null)" '"phase": "later"'
has 'C: the badge says 新版已就绪 · 下次打开生效' "$(FLEET_CLIENT_UPDATE_SHOW=0 badge)" '新版已就绪 · 下次打开生效'
FLEET_CLIENT_IDLE_SECS=0 upd tick "$SESS"; rc=$?
eq 'C: the next tick waits (exit 3)' 3 "$rc"
eq 'C: … without running the migration again' 1 "$(grep -c run "$WORK/mig3.count" 2>/dev/null)"
eq "C: the shell's server: same pid" "$SP" "$(shell_pid)"

# --- D. a migration that is done --------------------------------------------------------
rm -rf "$V/v3"
stage_ver v4 beef004
mkdir -p "$V/v4/bin/client-migrations"
printf '#!/bin/bash\necho "$1 $2 $FLEET_SHELL_SESSION" >> %s/mig4.args\nexit 0\n' "$WORK" > "$V/v4/bin/client-migrations/0002-ok.sh"
FLEET_CLIENT_IDLE_SECS=0 upd tick "$SESS"; rc=$?
eq 'D: migration exit 0 → applied (exit 4)' 4 "$rc"
eq 'D: the migration ran once with <from> <to> and the session' "v2 v4 $SESS" "$(cat "$WORK/mig4.args" 2>/dev/null)"
CHECKS=$((CHECKS + 1)); link_is v4 || fail 'D: not switched to v4'
eq "D: the shell's server: same pid" "$SP" "$(shell_pid)"

# --- E. the new client fails to load -----------------------------------------------------
cp "$FLEET_SHELL_CACHE/tmux.conf" "$WORK/conf.before"
stage_ver v5 beef005
rm -f "$V/v5/bin/fleet-shell.sh"
cat > "$V/v5/bin/fleet-shell.sh" <<EOF
#!/bin/bash
# a client whose reload breaks half way: its conf already written
if [ "\${1:-}" = reload ]; then echo '# broken' > "\$FLEET_SHELL_CACHE/tmux.conf"; echo boom >&2; exit 1; fi
exec bash "$BIN/fleet-shell.sh" "\$@"
EOF
FLEET_CLIENT_IDLE_SECS=0 upd tick "$SESS"; rc=$?
eq 'E: reload fails → exit 1' 1 "$rc"
CHECKS=$((CHECKS + 1)); link_is v4 || fail 'E: the link is not back on v4' "$(cd "$ROOT" && pwd -P)"
CHECKS=$((CHECKS + 1)); cmp -s "$WORK/conf.before" "$FLEET_SHELL_CACHE/tmux.conf" || fail 'E: the conf is not the old one' "$(head -n 2 "$FLEET_SHELL_CACHE/tmux.conf")"
st=$(cat "$UST" 2>/dev/null)
has 'E: update.state failed' "$st" '"phase": "failed"'
has 'E: … with the reason' "$st" '退回旧版'
has 'E: the badge says why' "$(FLEET_CLIENT_UPDATE_SHOW=600 badge)" '更新没成功'
eq "E: the shell's server: same pid" "$SP" "$(shell_pid)"
eq "E: the stage's server: same pid" "$GP" "$(stage_pid)"
FLEET_CLIENT_IDLE_SECS=0 upd tick "$SESS"; rc=$?
eq 'E: the same version is not tried again every tick (exit 1)' 1 "$rc"
rm -rf "$V/v5"

# --- F. fleet-remote-view.sh changed: the proxy is respawned ---------------------------
stage_ver v6 beef006
own "$V/v6" fleet-remote-view.sh
printf '\n# v6\n' >> "$V/v6/bin/fleet-remote-view.sh"
FLEET_CLIENT_IDLE_SECS=0 upd tick "$SESS"; rc=$?
eq 'F: applied (exit 4)' 4 "$rc"
waitfor 5 proxy_moved "$PP"
CHECKS=$((CHECKS + 1)); [ -n "$(proxy_pid)" ] && [ "$(proxy_pid)" != "$PP" ] || fail 'F: the proxy pane was not respawned' "$PP → $(proxy_pid)"
eq "F: the shell's server: same pid" "$SP" "$(shell_pid)"
eq "F: the stage's server: same pid" "$GP" "$(stage_pid)"
CHECKS=$((CHECKS + 1)); [ -d "$V/v4" ] && [ ! -d "$V/v2" ] || fail 'F: prune keeps the current + .prev only' "$(ls "$V")"

# --- G. a restart-needing client, nobody attached: the next `fleet` takes it -------------
exec 7>&-; kill "$CLIENT_PID" 2>/dev/null; CLIENT_PID=''
waitfor 5 not attached
stage_ver v7 beef007
mkdir -p "$V/v7/bin/client-migrations"
printf '#!/bin/bash\nexit 3\n' > "$V/v7/bin/client-migrations/0003-restart.sh"
FLEET_CLIENT_IDLE_SECS=0 upd tick "$SESS"; rc=$?
eq 'G: later (exit 3)' 3 "$rc"
upd start; rc=$?
eq 'G: start with nobody attached → switched (exit 3)' 3 "$rc"
CHECKS=$((CHECKS + 1)); link_is v7 || fail 'G: not switched to v7'
CHECKS=$((CHECKS + 1)); ts has-session -t "=$SESS" 2>/dev/null && fail "G: the old client's server is still up"

if [ "$FAIL" -eq 0 ]; then printf 'PASS fleet-client-live-update-selftest (%d checks)\n' "$CHECKS"; exit 0; fi
printf 'FAIL fleet-client-live-update-selftest: %d of %d\n' "$FAIL" "$CHECKS"
[ -s "$WORK/upd.err" ] && sed 's/^/  upd: /' "$WORK/upd.err" >&2
[ -f "$STATE/update.log" ] && sed 's/^/  log: /' "$STATE/update.log" >&2
exit 1
