#!/bin/bash
# fleet-node-hosted-selftest.sh — the client on a MANAGED machine (issue #2720):
# nothing opens at an ssh login (#2702), but a `fleet` typed there opens the SAME
# client on the machine, for that ssh alone — the thin loop with this machine as
# home (`fleet-thin.py --local`, issue #3006; the old client's own road here went
# with it, issue #3008).
#
#   A. bin/fleet's road (a sandbox install whose fleet-client-update.sh /
#      fleet-home-session.sh / fleet-client-retire.sh only record): on a managed
#      machine (FLEET_NODE_STATE/machine.env) `fleet` says ONE line 「客户端在 <机器>
#      上运行；平时请在自己设备上用」 (no hub: 本机模式, no 入口 named) and runs the
#      RUNTIME's fleet-thin.py --local (FLEET_NODE_RUNTIME/bin), never the
#      install's, FLEET_NODE_HOSTED=1, no update asked — `fleet mac-a`, `fleet
#      --old` and FLEET_CLIENT=shell too (the last two say the old client is
#      gone); a resident old client's server still running adds the retire
#      command; `fleet quit` / `fleet status` reach fleet-client-retire.sh; `fleet
#      claude` answers one line, exit 3, `fleet claude --here` is its road as
#      before, `fleet codex …` the same one line; `--help` untouched; no runtime
#      on the machine: the line, then the install's thin loop. An unmanaged
#      machine, the hatch FLEET_NODE_CLIENT=1 and the test identity: the
#      install's own thin loop, the update asked, no FLEET_NODE_HOSTED, no line
#      (was fleet-node-shell-retire-selftest.sh's A, issue #2702).
#   D. the where: fleet-client-lease.py `device` under FLEET_NODE_HOSTED=1 over
#      ssh → via node-hosted, caps [link] (show / open print a path or a link —
#      fleet-client-actions-selftest.sh G); without it → via public, as before.
#
# Drives: bin/fleet, bin/fleet-client-lease.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
REAL_TMUX=''
_ifs=$IFS; IFS=:
for d in $PATH; do
  case "$d" in */tmux-shim) continue ;; esac
  [ -x "$d/tmux" ] && { REAL_TMUX="$d/tmux"; break; }
done
IFS=$_ifs
[ -n "$REAL_TMUX" ] || { printf 'fleet-node-hosted selftest: tmux not installed — SKIP\n'; exit 0; }
st_need python3

W="$(mktemp -d /tmp/fnh.XXXXXX)" || exit 2
st_tally count miss
eq()  { st_eq "$1" "$3" "$2"; }   # <leg> <got> <want>
cleanup() { rm -rf "$W"; }
trap cleanup EXIT INT TERM

mkdir -p "$W/node" "$W/home" "$W/tmp" "$W/conf" "$W/inst/bin" "$W/fakert/bin"
: > "$W/node/machine.env"
export HOME="$W/home" TMPDIR="$W/tmp" FLEET_CONF_DIR="$W/conf" XDG_CACHE_HOME="$W/home/.cache" \
       XDG_CONFIG_HOME="$W/home/.config" FLEET_UI_LANG=zh \
       FLEET_NODE_STATE="$W/node" FLEET_NODE_RUNTIME="$W/fakert"
unset TMUX TMUX_PANE FLEET_CLIENT_IDENTITY FLEET_NODE_CLIENT FLEET_NODE_HOSTED FLEET_SHELL_CACHE \
      FLEET_NODE_HOSTED_CACHE FLEET_CLIENT_UPDATED FLEET_CLIENT_LAYOUT SSH_CONNECTION FLEET_CLIENT FLEET_HUB_URL

# ---- A. bin/fleet's road ------------------------------------------------------
echo "A. bin/fleet on a managed machine"
cp "$BIN/fleet" "$W/inst/bin/fleet"
for n in fleet-client-update.sh fleet-home-session.sh fleet-client-retire.sh fleet-client-who.sh; do
  cat > "$W/inst/bin/$n" <<EOF
#!/bin/sh
printf 'inst %s %s|hosted=%s\n' "$n" "\$*" "\${FLEET_NODE_HOSTED:-}" >> "$W/calls"
exit 0
EOF
  chmod +x "$W/inst/bin/$n"
done
cp "$BIN/fleet-ui-lang.sh" "$W/inst/bin/"
# the thin loop: the runtime's and the install's, each saying which it is
for w in fakert inst; do
  cat > "$W/$w/bin/fleet-thin.py" <<EOF
import os, sys
open("$W/calls", "a").write("$w fleet-thin.py %s|hosted=%s\\n" % (" ".join(sys.argv[1:]), os.environ.get("FLEET_NODE_HOSTED", "")))
EOF
done
# fa <env…> -- <args…> → $out (stderr+stdout), $rc, $calls
fa() {
  local e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  : > "$W/calls"
  out=$(env ${e[@]+"${e[@]}"} sh "$W/inst/bin/fleet" "$@" </dev/null 2>&1); rc=$?
  calls=$(cat "$W/calls")
}
me=$(hostname -s); me=${me%%.*}
# this login connects to no hub (本机模式, fleet-install.sh --no-hub — issue #4074):
# the line names no 入口 to install from
fa --
eq "A0 fleet, no hub → rc 0" "$rc" 0
eq "A0 … one line: runs here, 本机模式 — no 入口 named" "$out" "fleet · 客户端在 $me 上运行（本机模式，不连入口）。"
printf '# [common]\nFLEET_HUB_URL=https://hub.example\n' > "$W/conf/fleet.conf"
fa --
eq "A fleet → rc 0" "$rc" 0
eq "A … one line: the client runs on this machine" "$out" "fleet · 客户端在 $me 上运行；平时请在自己设备上用 fleet（装：curl -fsSL <入口>/install | sh）。"
eq "A … the runtime's thin loop, --local, hosted — no update asked" "$calls" "fakert fleet-thin.py --local|hosted=1"
rm -f "$W/conf/fleet.conf"
fa -- mac-a
eq "A fleet mac-a → the runtime's thin loop" "$calls" "fakert fleet-thin.py --local --home mac-a|hosted=1"
fa -- --old
eq "A fleet --old → the runtime's thin loop" "$calls" "fakert fleet-thin.py --local|hosted=1"
st_has "A … saying the old client is gone" "$out" "旧客户端已删除（#3008）"
fa FLEET_CLIENT=shell --
eq "A FLEET_CLIENT=shell → the runtime's thin loop all the same" "$calls" "fakert fleet-thin.py --local|hosted=1"
st_has "A … and says so" "$out" "FLEET_CLIENT=shell"
fa SSH_CONNECTION='203.0.113.9 50000 10.0.0.3 22' --
eq "A over ssh (a phone, #3006): the same" "$calls" "fakert fleet-thin.py --local|hosted=1"
fa -- quit
eq "A fleet quit → fleet-client-retire.sh stop" "$calls" "inst fleet-client-retire.sh stop|hosted=1"
fa -- status
st_has "A fleet status → fleet-client-retire.sh running" "$calls" "inst fleet-client-retire.sh running|hosted=1"
st_has "A … then the who line" "$calls" "inst fleet-client-who.sh |hosted=1"
fa -- claude
eq "A fleet claude → exit 3" "$rc" 3
st_has "A … says to type fleet or --here" "$out" "敲 fleet 在这台上开客户端，或 fleet claude --here"
fa -- claude --here
eq "A fleet claude --here → its road as before" "$calls" "inst fleet-home-session.sh claude --here|hosted=1"
fa -- codex hello
eq "A fleet codex hello → exit 3, one line" "$rc|$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "3|1"
fa -- --help
eq "A fleet --help untouched" "$rc" 0
fa FLEET_NODE_RUNTIME="$W/no-runtime" -- mac-a
eq "A no runtime here: the line, then the install's thin loop" "$out|$calls" \
  "fleet · 客户端在 $me 上运行（本机模式，不连入口）。|inst fleet-thin.py --local --home mac-a|hosted=1"
# nr <calls> — without the client start's background retire (its line lands in
# any order, issue #4827; fleet-client-retire-selftest.sh D pins that it is asked)
nr() { printf '%s\n' "$1" | grep -v '^inst fleet-client-retire.sh stop --quiet --if-unattached|'; }
# a resident client from before #2702 still running here: the line says how to retire it
mkdir -p "$W/home/.cache/claude-fleet/shell/bin"
fa --
rm -rf "$W/home/.cache/claude-fleet/shell"
st_has "A … an old resident client's files still here: the retire command (#2904)" "$out" "fleet-node-shell-retire.sh --login"
fa FLEET_NODE_CLIENT=1 --
eq "A the hatch: the install's own thin loop, the update asked, no line" "$(nr "$calls")|$out" "inst fleet-client-update.sh start|hosted=
inst fleet-thin.py |hosted=|"
fa FLEET_CLIENT_IDENTITY=test --
eq "A the test identity: the same" "$(nr "$calls")|$out" "inst fleet-client-update.sh start|hosted=
inst fleet-thin.py |hosted=|"
fa FLEET_NODE_STATE="$W/nowhere" --
eq "A an unmanaged machine: the install's, no line" "$(nr "$calls")|$out" "inst fleet-client-update.sh start|hosted=
inst fleet-thin.py |hosted=|"

# ---- D. the where -------------------------------------------------------------
echo "D. the where"
w=$(cd "$W" && FLEET_NODE_HOSTED=1 SSH_CONNECTION='203.0.113.9 5 10.0.0.3 22' python3 "$BIN/fleet-client-lease.py" device --save "$W/w1.json" </dev/null >/dev/null 2>&1; cat "$W/w1.json")
st_has "D node-hosted: via" "$w" '"via": "node-hosted"'
st_has "D … caps link only" "$w" '"caps": ["link"]'
w=$(cd "$W" && SSH_CONNECTION='203.0.113.9 5 10.0.0.3 22' python3 "$BIN/fleet-client-lease.py" device --save "$W/w2.json" </dev/null >/dev/null 2>&1; cat "$W/w2.json")
st_has "D without it: as before (via public)" "$w" '"via": "public"'

st_done
