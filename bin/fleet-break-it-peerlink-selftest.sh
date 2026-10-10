#!/bin/bash
# fleet-break-it-peerlink-selftest.sh — docs/BREAK-IT.md rows peerlink-* (issue
# #3002, EPIC #2999 C5): the home machine's standing connections to the other
# machines, broken the five ways a standing connection goes bad, and coming back
# on their own. Its own file, like the node drills whose runner it sources
# (BREAK_CRED_LIB=1); bin/fleet-break-it-selftest.sh's lockstep lint reads the
# drill_* names here too.
#
#   peerlink-wrong-login   bin/fleet-peerlink.py (start → `id -un` on the master):
#                          a master logged in as another login sits on the link's path
#   peerlink-sock-deleted  bin/fleet-peerlink.py's beat (file · pid · -O check): the
#                          control file is deleted while its master lives
#   peerlink-two-keepers   bin/fleet-peerlink.py run (flock + the held file IS the path):
#                          a second keeper, then one started after the lock file went
#   peerlink-cert-expiry   bin/fleet-peerlink.py + fleet-peer-cert.sh's five-minute
#                          certificate: two certificate lives pass under a live link
#   peerlink-hub-down      bin/fleet-peerlink.py start: the hub is down — the links up
#                          stay, a new one is not opened and says why
#
# No network and no sshd: bin/fleet-peerlink-fake-ssh.py plays ssh (a master is a
# process serving its -S socket), a shell script plays fleet-peer-cert.sh (its
# certificate an epoch the fake master checks at the handshake only).
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

US=$'\x1f'
PL="$BIN/fleet-peerlink.py"
# pl_box <name> <machine:login>… — a sandbox home machine `home` (login: this
# one) with a thin view attached and your sessions on each named machine; the
# exports point fleet-peerlink.py at it. The certificate lives PL_CERT_SECS (300).
pl_box() {
  local n="$1" t m l i=0 sp; shift
  B="$WORK/$n"; mkdir -p "$B/conf/remote-views" "$B/t/.claude-dash/global" "$B/fs/login" "$B/fs/down"
  sleep 600 & sp=$!; disown "$sp" 2>/dev/null; printf '%s\n' "$sp" >> "$WORK/cred-pids"
  printf '/dev/ttys0\tfleet@view-a\tthin\t%s\t%s\tcur= route=lan\n' "$(date +%s)" "$sp" > "$B/conf/remote-views/a"
  : > "$B/t/.claude-dash/global/fleet_logins"
  printf '#me%shome\n' "$US" > "$B/t/.claude-dash/global/remote_fleet"
  for t in "$@"; do pl_row "$t"; done
  cat > "$B/cert.sh" <<EOF
#!/bin/bash
[ -f "$B/hubdown" ] && { echo 'fleet-peer-cert: the hub could not be reached (https://hub.example)' >&2; exit 1; }
echo "\$1" >> "$B/cert.asked"
python3 -c 'import sys, time; print(time.time() + float(sys.argv[1]))' "\${PL_CERT_SECS:-300}" > "$B/cert-\$1"
printf '%s\n' -i "$B/key" -o "CertificateFile=$B/cert-\$1" -o IdentitiesOnly=yes -l hubsays
EOF
  chmod +x "$B/cert.sh"
  export FLEET_CONF_DIR="$B/conf" TMPDIR="$B/t" FAKESSH_DIR="$B/fs" FLEET_PEERLINK_HOME=home \
    FLEET_PEERLINK_SSH="python3 $BIN/fleet-peerlink-fake-ssh.py" FLEET_PEERLINK_CERT_CMD="$B/cert.sh"
  unset FLEET_C
}
# pl_row <machine:login> — one session of yours there (its fleet UUID → that login)
pl_row() {
  local m="${1%%:*}" l="${1#*:}" u
  u="U$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  printf '%s\t%s\n' "$u" "$l" >> "$B/t/.claude-dash/global/fleet_logins"
  printf 'wid:%s/f1%s%s%sonline%s1%so/r%sworking%sclaude%sn%s%s%s0\n' "$u" "$US" "$m" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" \
    >> "$B/t/.claude-dash/global/remote_fleet"
}
pl_start() { python3 "$PL" run 2>>"$B/run.err" & KP=$!; printf '%s\n' "$KP" >> "$WORK/cred-pids"; }
pl_stop() {
  kill "$KP" 2>/dev/null; wait "$KP" 2>/dev/null
  # the fake masters left behind
  awk '$1 == "master" { print $4 }' "$B/fs/log" 2>/dev/null | while read -r p; do kill "$p" 2>/dev/null; done
}
# pl_link <machine@login> <expr> — a python expression over the link's state dict `l`
pl_link() {
  python3 - "$B/conf/peerlink/state.json" "$1" "$2" <<'PY' 2>/dev/null
import json, sys
s = json.load(open(sys.argv[1]))
for l in s["links"]:
    if "%s@%s" % (l["machine"], l["login"]) == sys.argv[2]:
        v = eval(sys.argv[3])
        print(v if not isinstance(v, bool) else int(v))
        sys.exit(0 if v else 1)
sys.exit(1)
PY
}
pl_up() { pl_link "$1" 'l["phase"] == "up"' >/dev/null; }
pl_pid() { pl_link "$1" 'l["pid"]'; }
pl_ssh() { python3 "$BIN/fleet-peerlink-fake-ssh.py" "$@"; }

drill_peerlink_wrong_login() {
  CAP=6   # a stray on the path: checked, closed, rebuilt as the right login — a beat or two
  local t0 stray sock got
  pl_box wl m4:bob
  sock="$B/conf/peerlink/m4@bob.sock"; mkdir -p "$B/conf/peerlink"; chmod 700 "$B/conf/peerlink"
  # yesterday's way (#2987): a master on the path logged in as the DEFAULT login
  printf '%s\n' "$(python3 -c 'import time; print(time.time() + 300)')" > "$B/stray-cert"
  pl_ssh -M -N -S "$sock" -l alice -o "CertificateFile=$B/stray-cert" m4 2>/dev/null & stray=$!
  printf '%s\n' "$stray" >> "$WORK/cred-pids"
  until_ok 5 test -S "$sock" || { WHY="the stray master never came up"; return 1; }
  [ "$(pl_ssh -S "$sock" m4 id -un)" = alice ] || { WHY="the stray does not answer as alice"; return 1; }
  t0=$(now); pl_start
  until_ok 8 pl_up m4@bob || { WHY="the link never came up: $(tail -3 "$B/run.err" | tr '\n' ' ')"; pl_stop; return 1; }
  SECS=$(since "$t0")
  got=$(pl_ssh -S "$sock" m4 id -un)
  [ "$got" = bob ] || { WHY="the link answers as [$got], not bob"; pl_stop; return 1; }
  kill -0 "$stray" 2>/dev/null && { WHY="the wrong-login master was left running"; pl_stop; return 1; }
  python3 "$PL" status | grep -q '登录不符' || { WHY="the doctor's reading has no 登录不符 record: $(python3 "$PL" status)"; pl_stop; return 1; }
  # a far end that keeps answering as someone else: never up, the doctor WARNs
  printf 'alice\n' > "$B/fs/login/m4"; rm -f "$sock"
  until_ok 6 sh -c 'out=$(python3 "$1" status --check); [ $? = 1 ] && printf %s "$out" | grep -q 登录不符' _ "$PL" \
    || { WHY="a persistent wrong login did not WARN: $(python3 "$PL" status --check)"; pl_stop; return 1; }
  pl_up m4@bob && { WHY="a wrong-login master counted as up"; pl_stop; return 1; }
  rm -f "$B/fs/login/m4"
  until_ok 8 pl_up m4@bob || { WHY="the link did not come back once the login was right"; pl_stop; return 1; }
  pl_stop
  WHAT="路径上有一条用错登录（alice）的主连接：管理者核对 id -un 不符就关掉、按 bob 重建；对方一直答错登录时不算连上、doctor 报 登录不符"
}

drill_peerlink_sock_deleted() {
  CAP=4   # ≤ one 2 s beat to see it + the rebuild
  local t0 old new sock
  pl_box sd m4:bob
  sock="$B/conf/peerlink/m4@bob.sock"
  pl_start
  until_ok 8 pl_up m4@bob || { WHY="the link never came up: $(tail -3 "$B/run.err" | tr '\n' ' ')"; pl_stop; return 1; }
  old=$(pl_pid m4@bob)
  rm -f "$sock"; t0=$(now)
  until_ok 6 sh -c 'test -S "$1" && [ "$(python3 "$2" sock m4 bob)" = "$1" ] && [ "$3" != "$(python3 -c "import json,sys; print([l[\"pid\"] for l in json.load(open(sys.argv[1]))[\"links\"]][0])" "$4")" ]' \
    _ "$sock" "$PL" "$old" "$B/conf/peerlink/state.json" \
    || { WHY="not rebuilt: $(python3 "$PL" status)"; pl_stop; return 1; }
  SECS=$(since "$t0")
  new=$(pl_pid m4@bob)
  kill -0 "$old" 2>/dev/null && { WHY="the old master ($old) still runs with its file gone — the very state the drill forbids"; pl_stop; return 1; }
  [ "$(pl_ssh -S "$sock" m4 id -un)" = bob ] || { WHY="the rebuilt link does not answer"; pl_stop; return 1; }
  python3 "$PL" status | grep -q '重建：控制文件没了' || { WHY="no rebuild record in the reading"; pl_stop; return 1; }
  pl_stop
  WHAT="主连接活着、控制文件被删：一拍内发现，旧主进程被杀（不留「文件没了连接还在」），按同一路径重建（pid $old → ${new}），state.json 记一条 重建：控制文件没了"
}

drill_peerlink_two_keepers() {
  CAP=5
  local t0 k1 k2 rc n
  pl_box tk m4:bob
  pl_start; k1=$KP
  until_ok 8 pl_up m4@bob || { WHY="the link never came up"; pl_stop; return 1; }
  python3 "$PL" run 2>"$B/second.err"; rc=$?
  [ "$rc" = 3 ] && grep -q 'another keeper' "$B/second.err" || { WHY="a second keeper did not refuse (rc $rc)"; pl_stop; return 1; }
  # the lock file deleted under the first: a third starts on a new file — the
  # first sees the file it holds is no longer the path's and quits
  rm -f "$B/conf/peerlink/.lock"
  pl_start; k2=$KP; t0=$(now)
  until_ok 6 sh -c '! kill -0 "$1" 2>/dev/null' _ "$k1" || { WHY="two keepers both alive (pids $k1 $k2)"; KP=$k1; pl_stop; KP=$k2; pl_stop; return 1; }
  SECS=$(since "$t0")
  kill -0 "$k2" 2>/dev/null || { WHY="the new keeper died too"; pl_stop; return 1; }
  until_ok 6 pl_up m4@bob || { WHY="the new keeper did not hold the link"; pl_stop; return 1; }
  n=$(awk '$1 == "master"' "$B/fs/log" | wc -l | tr -d ' ')
  [ "$n" = 1 ] || { WHY="the link was rebuilt ($n masters) instead of adopted"; pl_stop; return 1; }
  sleep 0.5
  python3 "$PL" status --check >/dev/null || { WHY="the doctor still sees two keepers: $(python3 "$PL" status --check)"; pl_stop; return 1; }
  pl_stop
  WHAT="第二个 run 拿不到锁立刻退出（rc 3）；锁文件被删后又起一个：旧的发现自己拿的已不是那个文件，一拍内退出，新的认领原主连接（不重连），只剩一个"
}

drill_peerlink_cert_expiry() {
  CAP=4
  local t0 pid sock
  export PL_CERT_SECS=1
  pl_box ce m4:bob
  sock="$B/conf/peerlink/m4@bob.sock"
  pl_start
  until_ok 8 pl_up m4@bob || { WHY="the link never came up: $(tail -3 "$B/run.err" | tr '\n' ' ')"; pl_stop; unset PL_CERT_SECS; return 1; }
  pid=$(pl_pid m4@bob); t0=$(now)
  sleep 2.3   # two certificate lives
  pl_ssh -M -N -S "$B/probe.sock" -o "CertificateFile=$B/cert-m4" -l bob m4 2>/dev/null \
    && { WHY="the certificate did not expire (a new handshake was let in)"; pl_stop; unset PL_CERT_SECS; return 1; }
  [ "$(python3 "$PL" sock m4 bob)" = "$sock" ] || { WHY="the link is not healthy after the certificate expired"; pl_stop; unset PL_CERT_SECS; return 1; }
  [ "$(pl_ssh -S "$sock" -o ControlMaster=no m4 echo still)" = "ran echo still" ] \
    || { WHY="a new channel did not open on the link"; pl_stop; unset PL_CERT_SECS; return 1; }
  SECS=$(python3 -c 'import sys,time; print("%.1f" % (time.time() - float(sys.argv[1]) - 2.3))' "$t0")
  [ "$(pl_pid m4@bob)" = "$pid" ] || { WHY="the master was rebuilt across the expiry"; pl_stop; unset PL_CERT_SECS; return 1; }
  pl_stop; unset PL_CERT_SECS
  WHAT="证书 1 秒有效、过了两次：新握手被拒，但常开连接还是同一条（pid ${pid}），其上照样开新通道 —— 证书只在建立时看"
}

drill_peerlink_hub_down() {
  CAP=4
  local t0 pid
  pl_box hd m4:bob
  pl_start
  until_ok 8 pl_up m4@bob || { WHY="the link never came up"; pl_stop; return 1; }
  pid=$(pl_pid m4@bob)
  touch "$B/hubdown"
  pl_row m5:bob   # a new machine shows up while the hub is away
  until_ok 6 sh -c 'python3 "$1" status --check | grep -q "m5@bob 开不了新连接：入口"' _ "$PL" \
    || { WHY="the doctor does not say why m5 is not opened: $(python3 "$PL" status --check)"; pl_stop; return 1; }
  python3 "$PL" status --check >/dev/null && { WHY="hub down with a link wanted read OK"; pl_stop; return 1; }
  awk '$1 == "master" && $2 == "m5"' "$B/fs/log" | grep -q . && { WHY="a master to m5 was opened without a certificate (a standing key)"; pl_stop; return 1; }
  pl_up m4@bob && [ "$(pl_pid m4@bob)" = "$pid" ] || { WHY="the link already up was dropped"; pl_stop; return 1; }
  pl_ssh -S "$B/conf/peerlink/m4@bob.sock" m4 true >/dev/null || { WHY="m4's link does not carry a channel"; pl_stop; return 1; }
  rm -f "$B/hubdown"; t0=$(now)
  until_ok 6 pl_up m5@bob || { WHY="m5 was not opened once the hub came back"; pl_stop; return 1; }
  SECS=$(since "$t0")
  python3 "$PL" status --check >/dev/null || { WHY="still WARN after the hub came back: $(python3 "$PL" status --check)"; pl_stop; return 1; }
  pl_stop
  WHAT="入口不在：已有的 m4 照用（同一 pid），新来的 m5 不开、不退回长期钥匙，doctor 写明 入口不在；入口回来后退避内开好 m5"
}

cred_run_drills "$0"
