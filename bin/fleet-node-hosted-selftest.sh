#!/bin/bash
# fleet-node-hosted-selftest.sh — the client on a MANAGED machine (issue #2720):
# nothing opens at an ssh login (#2702), but a `fleet` typed there opens the SAME
# client on the machine, for that ssh alone.
#
#   A. bin/fleet's road (a sandbox install whose fleet-shell.sh / fleet-client-
#      update.sh / fleet-home-session.sh only record): on a managed machine
#      (FLEET_NODE_STATE/machine.env) `fleet` says ONE line 「客户端在 <机器> 上运行；
#      平时请在自己设备上用」 and runs the RUNTIME's fleet-shell.sh (FLEET_NODE_RUNTIME
#      /bin), never the install's, with FLEET_NODE_HOSTED=1 and a temp cache
#      ($TMPDIR/fleet-node-client-<uid>) and its own tmux server
#      (`fleet-node-client`, never the resident `fleet-shell` — #2904; one of
#      those running adds the retire command), no update asked; `fleet quit` / `fleet
#      status` reach the same script with the same cache; `fleet claude` answers
#      one line, exit 3, `fleet claude --here` is its road as before. An unmanaged
#      machine, the hatch FLEET_NODE_CLIENT=1 and the test identity: the install's
#      own script, the update asked, no FLEET_NODE_HOSTED — byte for byte as before.
#   B. the real client from a sandbox runtime (every real script, a fake
#      fleet-connect.py that finds no machine online, a lease stub around the real
#      `device`), headless: up on its own tmux server, the environment says
#      FLEET_NODE_HOSTED=1, its scripts are the runtime's (no mirror: no bin/ in
#      the cache, nothing under ~/.cache/claude-fleet/shell; the stage's top line —
#      剩余 · 模型 · effort, #2717 — is the runtime's fleet-topbar.py), the where saved for
#      the lease says via node-hosted, caps link; then `fleet quit`: both servers
#      gone, the lease given back, the temp cache removed, no process left running
#      from the runtime for this client.
#   C. the ssh going without a word (no terminal attached): the keeper quits the
#      client on its own once no client has been attached for
#      FLEET_NODE_HOSTED_IDLE — servers gone, the cache removed, nothing left.
#   D. the where: fleet-client-lease.py `device` under FLEET_NODE_HOSTED=1 over
#      ssh → via node-hosted, caps [link] (show / open print a path or a link —
#      fleet-client-actions-selftest.sh G); without it → via public, as before.
#
# Every tmux server is on its own -L socket named for this run, killed at the end.
# Drives: bin/fleet, bin/fleet-shell.sh, bin/fleet-client-lease.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
REAL_TMUX=''
_ifs=$IFS; IFS=:
for d in $PATH; do
  case "$d" in */tmux-shim) continue ;; esac
  [ -x "$d/tmux" ] && { REAL_TMUX="$d/tmux"; break; }
done
IFS=$_ifs
[ -n "$REAL_TMUX" ] || { printf 'fleet-node-hosted selftest: tmux not installed — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-node-hosted selftest: python3 absent — SKIP\n'; exit 0; }

W="$(mktemp -d /tmp/fnh.XXXXXX)" || exit 2   # AF_UNIX paths stop at 104 bytes
SESS="fnh$$"
UIDN=$(id -u)
CHECKS=0; FAILS=0
eq()  { CHECKS=$((CHECKS + 1)); if [ "$2" = "$3" ]; then :; else FAILS=$((FAILS + 1)); printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$1" "$2" "$3"; fi; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) FAILS=$((FAILS + 1)); printf 'FAIL %s\n  got: %s\n  missing: %s\n' "$1" "$2" "$3" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) FAILS=$((FAILS + 1)); printf 'FAIL %s\n  got: %s\n  must not hold: %s\n' "$1" "$2" "$3" ;; esac; }
waitfor() {  # <secs> <cmd…> — until the command succeeds
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
T()  { "$REAL_TMUX" -L "$SESS" "$@"; }
TS() { "$REAL_TMUX" -L "$SESS-stage" "$@"; }
cleanup() {
  T kill-server 2>/dev/null
  TS kill-server 2>/dev/null
  pkill -f "$W/rt/bin/" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT INT TERM

mkdir -p "$W/node" "$W/home" "$W/tmp" "$W/conf" "$W/inst/bin" "$W/rt/bin" "$W/rt/conf"
: > "$W/node/machine.env"
export HOME="$W/home" TMPDIR="$W/tmp" FLEET_CONF_DIR="$W/conf" XDG_CACHE_HOME="$W/home/.cache" \
       XDG_CONFIG_HOME="$W/home/.config" FLEET_UI_LANG=zh FLEET_NODE_HOSTED_SESSION="$SESS" \
       FLEET_NODE_STATE="$W/node" FLEET_NODE_RUNTIME="$W/rt" TMUX_TMPDIR="$W"
unset TMUX TMUX_PANE FLEET_CLIENT_IDENTITY FLEET_NODE_CLIENT FLEET_NODE_HOSTED FLEET_SHELL_CACHE FLEET_SHELL_SESSION \
      FLEET_NODE_HOSTED_CACHE FLEET_CLIENT_UPDATED FLEET_CLIENT_LAYOUT SSH_CONNECTION
NHC="$W/tmp/fleet-node-client-$UIDN"     # the temp cache bin/fleet names

# ---- A. bin/fleet's road ------------------------------------------------------
echo "A. bin/fleet on a managed machine"
cp "$BIN/fleet" "$W/inst/bin/fleet"
for n in fleet-shell.sh fleet-client-update.sh fleet-home-session.sh; do
  cat > "$W/inst/bin/$n" <<EOF
#!/bin/sh
printf 'inst %s %s|hosted=%s|cache=%s\n' "$n" "\$*" "\${FLEET_NODE_HOSTED:-}" "\${FLEET_SHELL_CACHE:-}" >> "$W/calls"
exit 0
EOF
  chmod +x "$W/inst/bin/$n"
done
mkdir -p "$W/fakert/bin"
cat > "$W/fakert/bin/fleet-shell.sh" <<EOF
#!/bin/sh
printf 'runtime fleet-shell.sh %s|hosted=%s|cache=%s\n' "\$*" "\${FLEET_NODE_HOSTED:-}" "\${FLEET_SHELL_CACHE:-}" >> "$W/calls"
printf '%s\n' "\${FLEET_SHELL_SESSION:-}" > "$W/sess"
exit 0
EOF
chmod +x "$W/fakert/bin/fleet-shell.sh"
# fa <env…> -- <args…> → $out (stderr+stdout), $rc, $calls
fa() {
  local e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  : > "$W/calls"
  out=$(env ${e[@]+"${e[@]}"} FLEET_NODE_RUNTIME="$W/fakert" FLEET_SHELL_NO_ATTACH=1 sh "$W/inst/bin/fleet" "$@" </dev/null 2>&1); rc=$?
  calls=$(cat "$W/calls")
}
fa -- ; me=$(hostname -s); me=${me%%.*}
eq "A fleet → rc 0" "$rc" 0
eq "A … one line: the client runs on this machine" "$out" "fleet · 客户端在 $me 上运行；平时请在自己设备上用 fleet（装：curl -fsSL <入口>/install | sh）。"
eq "A … the runtime's fleet-shell.sh, hosted, the temp cache — no update asked" "$calls" "runtime fleet-shell.sh |hosted=1|cache=$NHC"
fa -- m4
eq "A fleet m4 → the runtime's, with the machine" "$calls" "runtime fleet-shell.sh m4|hosted=1|cache=$NHC"
fa -- quit
eq "A fleet quit → the runtime's quit, the same cache" "$calls" "runtime fleet-shell.sh quit|hosted=1|cache=$NHC"
fa -- status
has "A fleet status → the runtime's running --say" "$calls" "runtime fleet-shell.sh running --say|hosted=1|cache=$NHC"
fa -- claude
eq "A fleet claude → exit 3" "$rc" 3
has "A … says to type fleet or --here" "$out" "敲 fleet 在这台上开客户端，或 fleet claude --here"
fa -- claude --here
eq "A fleet claude --here → its road as before" "$calls" "inst fleet-home-session.sh claude --here|hosted=1|cache=$NHC"
fa FLEET_NODE_HOSTED_SESSION= --
eq "A … its own tmux server, never the resident client's fleet-shell (#2904)" "$(cat "$W/sess")" fleet-node-client
# a resident client from before #2702 still running here: the line says how to retire it
"$REAL_TMUX" -L fleet-shell -f /dev/null new-session -d -s fleet-shell 'sleep 30' 2>/dev/null
fa --
"$REAL_TMUX" -L fleet-shell kill-server 2>/dev/null
has "A … an old resident client's server running: the retire command (#2904)" "$out" "fleet-node-shell-retire.sh --login"
fa FLEET_NODE_HOSTED_CACHE="$W/elsewhere" --
has "A FLEET_NODE_HOSTED_CACHE moves the temp cache" "$calls" "cache=$W/elsewhere"
fa FLEET_NODE_CLIENT=1 --
eq "A the hatch: the install's own client, as before" "$calls" "inst fleet-client-update.sh start|hosted=|cache=
inst fleet-shell.sh |hosted=|cache="
fa FLEET_CLIENT_IDENTITY=test --
eq "A the test identity: as before" "$calls" "inst fleet-client-update.sh start|hosted=|cache=
inst fleet-shell.sh |hosted=|cache="
fa FLEET_NODE_STATE="$W/nowhere" --
eq "A an unmanaged machine: as before, no line" "$calls|$out" "inst fleet-client-update.sh start|hosted=|cache=
inst fleet-shell.sh |hosted=|cache=|"

# ---- B. the real client from a sandbox runtime --------------------------------
echo "B. the client up on the machine, then fleet quit"
for f in "$BIN"/*; do [ -f "$f" ] && ln -s "$f" "$W/rt/bin/${f##*/}"; done
for f in "$ROOT"/conf/*; do [ -f "$f" ] && ln -s "$f" "$W/rt/conf/${f##*/}"; done
rm -f "$W/rt/bin/fleet-connect.py"
cat > "$W/rt/bin/fleet-connect.py" <<'EOF'
#!/usr/bin/env python3
import sys
if "--pick" in sys.argv:
    sys.stderr.write("fleet connect: no machine online\n")
    sys.exit(1)
sys.exit(0)
EOF
chmod +x "$W/rt/bin/fleet-connect.py"
cat > "$W/lease.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$W/lease.log"
case "\$1" in
  device) exec python3 "$BIN/fleet-client-lease.py" "\$@" ;;
  acquire|renew|input) printf 'active\tL1\n' ;;
  release) printf 'released\tL1\n' ;;
esac
EOF
chmod +x "$W/lease.sh"
printf '{"sessions": [], "nodes": []}\n' > "$W/sessions.json"
# the client's environment: a hub address (the stubs stand in for it), headless
cenv() {
  env FLEET_NODE_RUNTIME="$W/rt" FLEET_HUB_URL=https://hub.example FLEET_HUB_SESSIONS_CMD="cat $W/sessions.json" \
      FLEET_CLIENT_LEASE_CMD="$W/lease.sh" FLEET_CERT_RENEW_CMD=true FLEET_SHELL_WARM=0 FLEET_CLIENT_ACTIONS=0 \
      FLEET_SHELL_NO_ATTACH=1 FLEET_SHELL_NO_FIRST=1 FLEET_SIDEBAR_HOST=selftest-host \
      SSH_CONNECTION='203.0.113.9 50000 10.0.0.3 22' "$@"
}
up() { cenv FLEET_NODE_HOSTED_IDLE="${1:-600}" sh "$W/inst/bin/fleet" </dev/null >"$W/up.out" 2>&1; }
gone() { ! T has-session 2>/dev/null && ! TS has-session 2>/dev/null; }
left() { pgrep -f "$W/rt/bin/" 2>/dev/null | grep -v "^$$\$" | wc -l | tr -d ' '; }
cp "$BIN/fleet" "$W/inst/bin/fleet"; rm -f "$W/inst/bin/fleet-shell.sh"   # the runtime's must be what runs
: > "$W/lease.log"
up; urc=$?
eq "B fleet → the client up (rc 0)" "$urc" 0
has "B … its one line first" "$(cat "$W/up.out")" "客户端在 $me 上运行"
eq "B its server is up" "$(T has-session -t "=$SESS" 2>/dev/null; echo $?)" 0
eq "B … FLEET_NODE_HOSTED=1 in its environment" "$(T show-environment -g FLEET_NODE_HOSTED 2>/dev/null)" "FLEET_NODE_HOSTED=1"
eq "B … its cache is the temp one" "$(T show-environment -g TMPDIR 2>/dev/null)" "TMPDIR=$NHC/tmp"
has "B … its scripts are the runtime's, no mirror" "$(T show-environment -g FLEET_REMOTE_SSH_CMD 2>/dev/null)" "$W/rt/bin/fleet-shell.sh ssh"
has "B … its top line (剩余 · 模型 · effort, #2717) is the runtime's fleet-topbar.py" "$(TS show-options -gv status-left 2>/dev/null)" "$W/rt/bin/fleet-topbar.py render"
eq "B … no bin/ copied into the cache" "$(ls -d "$NHC/bin" 2>/dev/null)" ""
eq "B … nothing under ~/.cache/claude-fleet/shell" "$(ls -d "$W/home/.cache/claude-fleet/shell" 2>/dev/null)" ""
eq "B … no iTerm2 profile written for the machine's person" "$(ls "$W/home/Library/Application Support/iTerm2" 2>/dev/null)" ""
waitfor 5 test -s "$NHC/tmp/client.where.json"
has "B the where it leases with: via node-hosted" "$(cat "$NHC/tmp/client.where.json" 2>/dev/null)" '"via": "node-hosted"'
has "B … caps link only" "$(cat "$NHC/tmp/client.where.json" 2>/dev/null)" '"caps": ["link"]'
waitfor 5 test -s "$NHC/tmp/keeper.pid"
eq "B a keeper runs (for this client only)" "$(test -s "$NHC/tmp/keeper.pid" && echo yes)" yes
qout=$(cenv sh "$W/inst/bin/fleet" quit </dev/null 2>&1)
waitfor 5 gone
eq "B fleet quit: both servers gone" "$(gone && echo gone)" gone
has "B … the lease given back" "$(cat "$W/lease.log")" "release --lease L1"
waitfor 5 test ! -e "$NHC"
eq "B … the temp cache removed" "$(ls -d "$NHC" 2>/dev/null; find "$NHC" 2>/dev/null | head -20)" ""
waitfor 5 sh -c "[ \"\$(pgrep -f '$W/rt/bin/' | wc -l | tr -d ' ')\" = 0 ]"
eq "B … no process left running from the runtime" "$(left)" 0
[ "$(left)" = 0 ] || ps -o pid,ppid,command -p "$(pgrep -f "$W/rt/bin/" | paste -sd, -)" >&2
hasnt "B … quit says nothing went wrong" "$qout" "unknown"

# ---- C. the ssh gone without a word: the keeper quits it ----------------------
echo "C. no terminal on it: the keeper quits the client"
: > "$W/lease.log"
up 1
eq "C the client up" "$(T has-session -t "=$SESS" 2>/dev/null; echo $?)" 0
waitfor 20 gone
eq "C … no client attached past FLEET_NODE_HOSTED_IDLE: servers gone" "$(gone && echo gone)" gone
waitfor 5 test ! -e "$NHC"
eq "C … the temp cache removed" "$(ls -d "$NHC" 2>/dev/null)" ""
has "C … the lease given back" "$(cat "$W/lease.log")" "release --lease L1"
waitfor 5 sh -c "[ \"\$(pgrep -f '$W/rt/bin/' | wc -l | tr -d ' ')\" = 0 ]"
eq "C … no process left" "$(left)" 0

# ---- D. the where -------------------------------------------------------------
echo "D. the where"
w=$(cd "$W" && FLEET_NODE_HOSTED=1 SSH_CONNECTION='203.0.113.9 5 10.0.0.3 22' python3 "$BIN/fleet-client-lease.py" device --save "$W/w1.json" </dev/null >/dev/null 2>&1; cat "$W/w1.json")
has "D node-hosted: via" "$w" '"via": "node-hosted"'
has "D … caps link only" "$w" '"caps": ["link"]'
w=$(cd "$W" && SSH_CONNECTION='203.0.113.9 5 10.0.0.3 22' python3 "$BIN/fleet-client-lease.py" device --save "$W/w2.json" </dev/null >/dev/null 2>&1; cat "$W/w2.json")
has "D without it: as before (via public)" "$w" '"via": "public"'

if [ "$FAILS" -gt 0 ]; then
  printf 'fleet-node-hosted selftest: %d of %d checks FAILED\n' "$FAILS" "$CHECKS"
  exit 1
fi
printf 'fleet-node-hosted selftest: %d checks passed\n' "$CHECKS"
