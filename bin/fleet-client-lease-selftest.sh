#!/bin/bash
# fleet-client-lease-selftest.sh — one person, one connected client (issue #1715,
# EPIC #1710 C5): bin/fleet-shell.sh's lease (client_open / keeper / standby),
# bin/fleet-client-lease.py, and the standby gates in fleet-hub-sessions.sh and
# fleet-hub-write.sh.
#
# Nothing real is reached: the hub's lease is FLEET_CLIENT_LEASE_CMD — a fake
# that keeps the table in a directory, with the hub's rules (an acquire takes the
# lease over and remembers who took it; a renewal of a taken lease reads
# taken_over) — `fleet-connect.py` is a fake whose --pick finds no machine (the
# shell opens on its `wait` window, no ssh), and every tmux server is an isolated
# socket killed at the end. Two "machines" are two shell servers (their own
# session + cache) over the one fake hub; a CLIENT is a pane of an outer isolated
# server running `fleet-shell.sh` — a real attached tmux client, so the standby
# popup draws in that pane and Enter reaches it.
#   A. degenerate — no hub: fleet-client-lease.py says `nohub`, exit 0; one client
#                   opens with no popup, no lease kept, client.nohub set
#   B. same device— `fleet` twice on one machine: ONE session (the second attached
#                   to the running one), the first client's screen is the standby
#                   popup naming the second's device, the hub saw no takeover (the
#                   same lease id kept)
#   C. takeover   — a client on another machine (iPhone) takes the lease: the first
#                   machine's keeper reads taken_over → its client shows 「正在
#                   iPhone 上使用 · 按回车接回」, client.standby set, renewals stop,
#                   fleet-hub-write.sh refuses (nothing sent)
#   D. take back  — Enter on that standby screen: the lease is the MacBook's again,
#                   its popup gone, standby cleared; the iPhone's machine goes to
#                   standby naming the MacBook
#   E. release    — a shell server that ends gives its lease up (release logged),
#                   so the next client anywhere takes nothing over
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-client-lease selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-client-lease selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fcl-st.XXXXXX")" || exit 2
OUT="fclO$$"; SX="fclX$$"; SY="fclY$$"
export HOME="$WORK/home"; mkdir -p "$HOME/.config/claude-fleet"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" FLEET_CONF_DIR="$HOME/.config/claude-fleet"
export FLEET_SHELL_WARM=0 FLEET_CLIENT_LEASE_EVERY=1
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_SESSION FLEET_SHELL FLEET_HUB_SESSIONS_CLIENT FLEET_SIDEBAR_SOURCE
unset FLEET_HUB_URL CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_TOKEN FLEET_CLIENT_DEVICE SSH_CONNECTION

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (must not hold '$3')" "$2" ;; esac; }
ok() { CHECKS=$((CHECKS + 1)); "$@" || fail "$*"; }
to() { "$REAL_TMUX" -L "$OUT" "$@"; }
waitfor() {  # <secs> <cmd…>
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
cleanup() {
  for s in "$OUT" "$SX" "$SY"; do "$REAL_TMUX" -L "$s" kill-server 2>/dev/null; done
  pkill -f "fleet-shell.sh keeper $SX" 2>/dev/null; pkill -f "fleet-shell.sh keeper $SY" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- a bin/ of our own: the real scripts, a fake fleet-connect.py ----------------
SB="$WORK/sbin"; mkdir -p "$SB" "$WORK/conf"
for f in "$BIN"/*; do [ -f "$f" ] && ln -s "$f" "$SB/${f##*/}"; done
rm -f "$SB/fleet-connect.py"
ln -s "$BIN/../conf/tmux-shell.conf" "$WORK/conf/tmux-shell.conf"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(1)\n' > "$SB/fleet-connect.py"   # --pick: nothing online
chmod +x "$SB/fleet-connect.py"

# --- the fake hub: the lease table in a directory --------------------------------
H="$WORK/hub"; mkdir -p "$H/gone"; : > "$H/log"
cat > "$WORK/lease" <<EOF
#!/bin/bash
# fake client lease — the hub's rules, one person
H="$H"
act=\$1; shift; lease=''; dev=''
while [ \$# -gt 0 ]; do case "\$1" in --lease) lease=\$2; shift 2 ;; --device) dev=\$2; shift 2 ;; *) shift ;; esac; done
[ "\$act" = device ] && { printf '%s\tFakeTerm\n' "\${FLEET_CLIENT_DEVICE:-未知设备}"; exit 0; }
[ -f "\$H/nohub" ] && { printf 'nohub\t\t\t\n'; exit 0; }
cur=''; cdev=''; [ -f "\$H/cur" ] && read -r cur cdev < "\$H/cur"
printf '%s %s %s\n' "\$act" "\$lease" "\$dev" >> "\$H/log"
case "\$act" in
  acquire)
    if [ -n "\$cur" ] && [ "\$cur" = "\$lease" ]; then printf 'active\t%s\t%s\t\n' "\$cur" "\$dev"; printf '%s %s\n' "\$cur" "\$dev" > "\$H/cur"; exit 0; fi
    n=L\$RANDOM\$RANDOM; took=''
    [ -n "\$cur" ] && { printf '%s\n' "\$dev" > "\$H/gone/\$cur"; took=\$cdev; echo takeover >> "\$H/takeovers"; }
    [ -n "\$lease" ] && rm -f "\$H/gone/\$lease"
    printf '%s %s\n' "\$n" "\$dev" > "\$H/cur"
    printf 'active\t%s\t%s\t%s\n' "\$n" "\$dev" "\$took" ;;
  renew)
    if [ "\$cur" = "\$lease" ]; then printf 'active\t%s\t%s\t\n' "\$cur" "\$cdev"
    else printf 'taken_over\t\t%s\t\n' "\$cdev"; fi ;;
  release) [ "\$cur" = "\$lease" ] && rm -f "\$H/cur"; printf 'released\t\t\t\n' ;;
  get) [ -n "\$cur" ] && printf 'active\t%s\t%s\t\n' "\$cur" "\$cdev" || printf 'none\t\t\t\n' ;;
esac
EOF
chmod +x "$WORK/lease"
export FLEET_CLIENT_LEASE_CMD="$WORK/lease"

# client <machine-session> <device> — a client: an outer pane running the shell
client() {
  local s=$1 d=$2 cmd
  cmd="env -u TMUX -u TMUX_PANE FLEET_SHELL_SESSION=$s FLEET_SHELL_CACHE=$WORK/cache-$s FLEET_CLIENT_DEVICE=$d bash $SB/fleet-shell.sh"
  if to has-session -t "=o" 2>/dev/null; then
    to new-window -d -P -F '#{pane_id}' -t "=o" "$cmd"
  else
    to new-session -d -P -F '#{pane_id}' -s o -x 120 -y 30 "$cmd"
  fi
}
screen() { to capture-pane -p -t "$1" 2>/dev/null; }
shows() { screen "$1" | grep -q "$2"; }
clients() { "$REAL_TMUX" -L "$1" list-clients -F '#{client_name}' 2>/dev/null | grep -c .; }
nclients() { [ "$(clients "$1")" = "$2" ]; }

# --- A. degenerate: no hub -------------------------------------------------------
line=$(env -u FLEET_CLIENT_LEASE_CMD python3 "$BIN/fleet-client-lease.py" get); rc=$?
eq "A: no hub → exit 0" 0 "$rc"
eq "A: no hub → nohub" "nohub" "$(printf '%s' "$line" | cut -f1)"
: > "$H/nohub"
pa=$(client "$SX" MacBook)
waitfor 10 nclients "$SX" 1 || fail "A: the client never attached"
sleep 1.5
hasnt "A: one client, no hub → no standby screen" "$(screen "$pa")" "按回车接回"
ok test -f "$WORK/cache-$SX/tmp/client.nohub"
ok test ! -f "$WORK/cache-$SX/tmp/client.lease"
"$REAL_TMUX" -L "$SX" kill-server 2>/dev/null; to kill-server 2>/dev/null
waitfor 5 sh -c "! pgrep -f 'fleet-shell.sh keeper $SX' >/dev/null"
rm -f "$H/nohub" "$WORK/cache-$SX/tmp/client.nohub"

# --- B. same device twice: one session, the first to standby ---------------------
p1=$(client "$SX" MacBook)
waitfor 10 nclients "$SX" 1 || fail "B: the first client never attached"
waitfor 5 test -s "$WORK/cache-$SX/tmp/client.lease" || fail "B: no lease after the first open"
id1=$(cat "$WORK/cache-$SX/tmp/client.lease" 2>/dev/null)
p2=$(client "$SX" MacBook)
waitfor 10 nclients "$SX" 2 || fail "B: the second client never attached"
eq "B: one session on the machine (attached, not another)" 1 "$("$REAL_TMUX" -L "$SX" list-sessions -F x 2>/dev/null | grep -c x)"
waitfor 5 shows "$p1" "正在 MacBook 上使用 · 按回车接回" || fail "B: the first client is not on standby" "$(screen "$p1")"
hasnt "B: the second client works" "$(screen "$p2")" "按回车接回"
eq "B: the same lease kept (no takeover of itself)" "$id1" "$(cat "$WORK/cache-$SX/tmp/client.lease" 2>/dev/null)"
ok test ! -f "$H/takeovers"
ok test ! -f "$WORK/cache-$SX/tmp/client.standby"

# --- C. another device takes over ------------------------------------------------
p3=$(client "$SY" iPhone)
waitfor 10 nclients "$SY" 1 || fail "C: the iPhone client never attached"
has "C: the hub saw a takeover" "$(cat "$H/takeovers" 2>/dev/null)" takeover
waitfor 6 test -f "$WORK/cache-$SX/tmp/client.standby" || fail "C: the MacBook's machine never went to standby"
waitfor 5 shows "$p2" "正在 iPhone 上使用 · 按回车接回" || fail "C: the MacBook client shows no standby screen" "$(screen "$p2")"
hasnt "C: the iPhone works" "$(screen "$p3")" "按回车接回"
n1=$(grep -c "^renew $id1" "$H/log"); sleep 2.5; n2=$(grep -c "^renew $id1" "$H/log")
eq "C: standby renews nothing" "$n1" "$n2"
out=$(FLEET_SHELL=1 TMPDIR="$WORK/cache-$SX/tmp" FLEET_HUB_WRITE_CMD="touch $WORK/sent" bash "$BIN/fleet-hub-write.sh" worker_stop '{"worker_id":"x"}' 2>&1); rc=$?
eq "C: a write in standby → exit 1" 1 "$rc"
has "C: … saying why" "$out" "待机"
ok test ! -e "$WORK/sent"

# --- D. Enter on the standby screen takes it back ---------------------------------
FLEET_ALLOW_SENDKEYS=1 to send-keys -t "$p2" Enter
waitfor 6 sh -c "! test -f '$WORK/cache-$SX/tmp/client.standby'" || fail "D: standby not cleared"
waitfor 5 sh -c "! tmux -L $OUT capture-pane -p -t '$p2' | grep -q 按回车接回" || fail "D: the popup is still up" "$(screen "$p2")"
has "D: the lease is the MacBook's" "$(cat "$H/cur" 2>/dev/null)" MacBook
waitfor 6 test -f "$WORK/cache-$SY/tmp/client.standby" || fail "D: the iPhone's machine never went to standby"
waitfor 5 shows "$p3" "正在 MacBook 上使用 · 按回车接回" || fail "D: the iPhone shows no standby screen" "$(screen "$p3")"

# --- E. a server that ends gives the lease up -------------------------------------
idx=$(cat "$WORK/cache-$SX/tmp/client.lease" 2>/dev/null)
"$REAL_TMUX" -L "$SX" kill-server 2>/dev/null
waitfor 6 grep -q "^release $idx" "$H/log" || fail "E: no release after the server ended" "$(tail -3 "$H/log")"
ok test ! -f "$H/cur"

[ "$FAIL" = 0 ] || { printf "hub log:\n"; cat "$H/log"; } >&2
printf 'fleet-client-lease selftest: %d checks, %d failed\n' "$CHECKS" "$FAIL"
[ "$FAIL" = 0 ]
