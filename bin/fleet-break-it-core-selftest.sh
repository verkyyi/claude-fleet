#!/bin/bash
# fleet-break-it-core-selftest.sh — the docs/BREAK-IT.md rows of the machine's root
# core (issue #3555, EPIC #3500 C13): each drill starts a real `fleet-node-core.py
# serve` on a sandbox socket (FLEET_NODE_TEST=1: the node daemon's uid is this
# uid unless the drill says otherwise), does the wrong thing for real, and passes
# when the core refuses it, runs nothing, and leaves its log line. Runner and
# timing helpers are bin/fleet-break-it-cred-selftest.sh's (BREAK_CRED_LIB=1);
# bin/fleet-break-it-selftest.sh's lockstep lint reads the drill names here too.
#
#   root-core-off-list        bin/fleet-node-core.py check_request + the op table:
#                             arbitrary argv, reading a file, writing sudoers, an
#                             extra key — sent as the node daemon itself
#   root-core-wrong-peer      bin/fleet-node-core.py peer_uid / allowed_peer: a login
#                             (or _fleetadmin) — any uid but the daemon's — connects
#   root-core-unsigned-switch bin/fleet-node-core.py verify_release + op_switch: a
#                             staged release signed by another key, or with a file
#                             changed after signing
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

CORE_PIDS=()
core_cleanup() { for p in ${CORE_PIDS[@]+"${CORE_PIDS[@]}"}; do kill "$p" 2>/dev/null; done; cleanup; }
trap core_cleanup EXIT

# core_sandbox <dir> — a runtime with the core's files, a managed login (this uid)
core_sandbox() {
  local sb="$1"
  mkdir -p "$sb/root/rt/bin" "$sb/db" "$sb/Users/alice"
  for f in fleet-node-core.py fleet_node_core.py fleet_ed25519.py fleet-node-supervisor.py; do
    cp "$BIN/$f" "$sb/root/rt/bin/"
  done
  printf '{"alice": {"uid": %d, "gid": %d, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '{"alice": {"managed": true}}\n' > "$sb/db/accounts.json"
  printf '{"children": [], "tasks": [], "account": []}\n' > "$sb/table.json"
}

# core_env <dir> — the seams, for `env`
core_env() {
  local sb="$1"
  printf '%s\n' FLEET_NODE_TEST=1 "FLEET_NODE_STATE=$sb/db" "FLEET_NODE_ROOT=$sb/root" \
    "FLEET_NODE_RUNTIME=$sb/root/rt" "FLEET_NODE_LOG=$sb/log" "FLEET_NODE_CORE_SOCK=$sb/core.sock" \
    "FLEET_NODE_CORE_LOG=$sb/core.log" "FLEET_NODE_PASSWD=$sb/passwd.json" "FLEET_NODE_TABLE=$sb/table.json" \
    "FLEET_NODE_CORE_PEER_UID=${PEER_UID:-$(id -u)}"
}

# core_serve <dir> — start it; returns once its socket is there
core_serve() {
  local sb="$1" i
  # shellcheck disable=SC2046  # one seam a line
  env $(core_env "$sb") python3 "$sb/root/rt/bin/fleet-node-core.py" serve >/dev/null 2>"$sb/core.err" &
  CORE_PIDS+=("$!")
  for i in $(seq 1 100); do [ -S "$sb/core.sock" ] && return 0; sleep 0.1; done
  return 1
}

# core_call <dir> <op> <args JSON> — as the node daemon's client
core_call() {
  local sb="$1"; shift
  # shellcheck disable=SC2046
  env $(core_env "$sb") python3 "$sb/root/rt/bin/fleet-node-core.py" call "$@"
}

# core_raw <dir> <line> — one raw line on the socket, the reply printed
core_raw() {
  python3 - "$1/core.sock" "$2" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode() + b"\n")
buf = b""
while b"\n" not in buf:
    got = s.recv(4096)
    if not got:
        break
    buf += got
print(buf.decode().strip())
PY
}

# root-core-off-list (#3555): the node daemon — the one peer the core takes — is
# fooled into asking for something outside the table: an arbitrary argv, a file
# read, a sudoers write, a known op with a key too many. The core answers each
# {"refused"}, runs none of it, writes one log line apiece, and past the threshold
# ONE alert — never one per request.
drill_root_core_off_list() {
  CAP=15
  local sb t0 out rc n mark
  sb="$WORK/core-off"; core_sandbox "$sb"; mark="$sb/PWNED"
  core_serve "$sb" || { WHY="the core never listened: $(cat "$sb/core.err")"; return 1; }
  t0=$(now)
  out=$(core_call "$sb" exec-as "{\"login\": \"alice\", \"argv\": [\"/bin/sh\", \"-c\", \"touch $mark\"]}"); rc=$?
  [ "$rc" = 2 ] && printf '%s' "$out" | grep -q '"refused": "exec-as"' \
    || { WHY="exec-as /bin/sh was not refused (rc $rc): $out"; return 1; }
  for line in "{\"op\": \"exec\", \"args\": {\"argv\": [\"/bin/sh\", \"-c\", \"touch $mark\"]}}" \
              '{"op": "read-file", "args": {"path": "/etc/master.passwd"}}' \
              "{\"op\": \"write-sudoers\", \"args\": {\"line\": \"alice ALL=(ALL) NOPASSWD: ALL\"}}" \
              "{\"op\": \"power\", \"args\": {\"profile\": \"spotlight-off\", \"argv\": [\"touch\", \"$mark\"]}}" \
              '{"op": "memguard", "args": {"level": "once"}, "env": {"PATH": "/tmp"}}' \
              '{"op": "kill", "args": {"pid": 1}}'; do
    out=$(core_raw "$sb" "$line")
    printf '%s' "$out" | grep -q '"refused"' || { WHY="not refused: $line → $out"; return 1; }
  done
  [ ! -e "$mark" ] || { WHY="an off-list request RAN something ($mark exists)"; return 1; }
  n=$(grep -c 'refused:' "$sb/core.log")
  [ "$n" -ge 7 ] || { WHY="$n refused lines for 7 refusals: $(cat "$sb/core.log")"; return 1; }
  grep -q 'op=read-file .*refused: not in the table' "$sb/core.log" \
    || { WHY="the log line names no op / why: $(cat "$sb/core.log")"; return 1; }
  for _ in 1 2 3 4 5 6; do core_raw "$sb" '{"op": "shell", "args": {}}' >/dev/null; done
  [ -f "$sb/db/core/alert.json" ] && [ "$(grep -c 'ALERT' "$sb/core.log")" = 1 ] \
    || { WHY="13 refusals in a minute: not exactly one alert ($(grep -c ALERT "$sb/core.log"))"; return 1; }
  SECS=$(since "$t0")
  WHAT="以节点守护身份给核心发表外动作（任意 argv、读文件、改 sudoers、多一个键）：全部 refused、什么都没执行、每条记一行，一分钟超阈值只告警一次"
}

# root-core-wrong-peer (#3555): a login — or the admin account — connects to the
# core's socket. The kernel says who it is (getpeereid); the core cuts it off
# before reading the request and logs the uid. The socket itself is 0660.
drill_root_core_wrong_peer() {
  CAP=10
  local sb t0 out rc mode
  sb="$WORK/core-peer"; core_sandbox "$sb"
  PEER_UID=$(( $(id -u) + 4242 )) core_serve "$sb" || { WHY="the core never listened"; return 1; }
  mode=$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$sb/core.sock")
  [ "$mode" = 0o660 ] || { WHY="the socket is $mode, not 0660"; return 1; }
  t0=$(now)
  out=$(PEER_UID=$(( $(id -u) + 4242 )) core_call "$sb" rollback '{}' 2>&1); rc=$?
  [ "$rc" = 1 ] && ! printf '%s' "$out" | grep -q '"ok"' \
    || { WHY="a stranger got an answer (rc $rc): $out"; return 1; }
  local i; for i in $(seq 1 50); do grep -q "peer=$(id -u) .*is not the node daemon's" "$sb/core.log" 2>/dev/null && break; sleep 0.1; done
  grep -q "peer=$(id -u) .*is not the node daemon's" "$sb/core.log" \
    || { WHY="no log line for the wrong peer: $(cat "$sb/core.log")"; return 1; }
  SECS=$(since "$t0")
  WHAT="别的 uid（某个登录或 _fleetadmin）连核心 socket：socket 0660，连上即断、一句不答，日志记下对端 uid"
}

# root-core-unsigned-switch (#3555): a release in staging whose signature is
# another key's, then one whose file was changed after signing — asked to switch.
# The core re-checks with its OWN key and every digest: refused, current never
# moves, the staged copy stays as evidence. A correctly signed one switches.
drill_root_core_unsigned_switch() {
  CAP=15
  local sb t0 out rc cur good bad
  sb="$WORK/core-switch"; core_sandbox "$sb"
  good=$(printf 'a%.0s' $(seq 40)); bad=$(printf 'b%.0s' $(seq 40))
  python3 "$BIN/fleet-node-core-selftest.py" --write-pub "$sb/db/release.pub"
  python3 "$BIN/fleet-node-core-selftest.py" --make-release "$sb/root" "$good"
  ln -s "$sb/root/$good" "$sb/root/current"
  core_serve "$sb" || { WHY="the core never listened"; return 1; }
  t0=$(now)
  python3 "$BIN/fleet-node-core-selftest.py" --make-release "$sb/db/staging" "$bad" other
  out=$(core_call "$sb" switch "{\"sha\": \"$bad\"}"); rc=$?
  cur=$(basename "$(readlink "$sb/root/current")")
  [ "$rc" = 2 ] && [ "$cur" = "$good" ] && printf '%s' "$out" | grep -q 'signature' \
    || { WHY="another key's release: rc $rc, current $cur: $out"; return 1; }
  [ -d "$sb/db/staging/$bad" ] || { WHY="the refused release was not kept as evidence"; return 1; }
  rm -rf "$sb/db/staging/$bad"
  python3 "$BIN/fleet-node-core-selftest.py" --make-release "$sb/db/staging" "$bad"
  printf 'tampered\n' >> "$sb/db/staging/$bad/bin/x"
  out=$(core_call "$sb" switch "{\"sha\": \"$bad\"}"); rc=$?
  cur=$(basename "$(readlink "$sb/root/current")")
  [ "$rc" = 2 ] && [ "$cur" = "$good" ] && printf '%s' "$out" | grep -q 'digest' \
    || { WHY="a file changed after signing: rc $rc, current $cur: $out"; return 1; }
  grep -q "op=switch .*refused: ${bad:0:12}" "$sb/core.log" || { WHY="no refused switch line: $(cat "$sb/core.log")"; return 1; }
  rm -rf "$sb/db/staging/$bad"
  python3 "$BIN/fleet-node-core-selftest.py" --make-release "$sb/db/staging" "$bad"
  out=$(core_call "$sb" switch "{\"sha\": \"$bad\"}"); rc=$?
  cur=$(basename "$(readlink "$sb/root/current")")
  [ "$rc" = 0 ] && [ "$cur" = "$bad" ] || { WHY="a correctly signed release did not switch (rc $rc): $out"; return 1; }
  SECS=$(since "$t0")
  WHAT="staging 里放别的钥匙签的版本、签完又改了文件的版本，请核心 switch：都拒绝、current 不动、staging 留作证据；签对的才切过去"
}

cred_run_drills "$0"
