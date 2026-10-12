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
#   fleetnode-compromised     bin/fleet-node-core.py op_machine / op_sweep / op_entry /
#                             op_report / op_exec_as / op_kill + bin/fleet-node-supervisor.py
#                             seat_make (#3668): the node daemon's account _fleetnode
#                             taken over — everything but the table's start / stop /
#                             end-a-process is refused, and the account itself can do
#                             nothing more (no admin, no shell, no home)
#   root-core-seat-stage      bin/fleet-node-core.py private_copy / install_tools /
#                             sign_ccquota (#3670): the seated updater's staging steers
#                             the root tools cache at a non-artifact, or offers its own
#                             ccquota to be signed with the machine's identity
#   root-core-update-step     bin/fleet-node-core.py op_update (#3670): the seated
#                             updater's root half asked with a step outside the list,
#                             an argv, a key too many
#   node-program-seat         bin/fleet-node-core.py op_exec_as / exec_stream / op_machine
#                             + bin/fleet_node_core.py read_request (#3669): the node
#                             program on the seat — a login's job started on the
#                             caller's fds outlives the caller; the node program asked
#                             of root as a machine job; fds riding another op
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
  for f in fleet-node-core.py fleet_node_core.py fleet_ed25519.py fleet-node-supervisor.py fleet-node-update.py \
      fleet_node_codesign.py; do
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

# fleetnode-compromised (#3668): whoever runs as the node daemon's account asks the
# core for everything a root shell would give — a program outside <current>/bin, a
# machine job that is not in the table, a sweep / entry / report with an argument,
# a kill of pid 1 or of someone who is not a managed login. Each is refused and
# nothing runs; what is left is the table: a job started and stopped by its name.
# The account itself: made with no admin group, shell false / nologin, no home —
# and on a machine that has it (root here), it reads no one's home, no credential
# store, and sudo says no.
drill_fleetnode_compromised() {
  CAP=30
  local sb t0 out rc mark line sleeper
  sb="$WORK/seat"; core_sandbox "$sb"; mark="$sb/PWNED"
  printf '#!/bin/bash\ntrap "exit 0" TERM; while :; do sleep 0.2; done\n' > "$sb/root/rt/bin/fleet-loop.sh"
  chmod 755 "$sb/root/rt/bin/fleet-loop.sh"
  printf '{"children": [{"name": "looper", "cmd": ["/bin/bash", "%s"]}], "tasks": [], "account": []}\n' \
    "$sb/root/rt/bin/fleet-loop.sh" > "$sb/table.json"
  core_serve "$sb" || { WHY="the core never listened: $(cat "$sb/core.err")"; return 1; }
  t0=$(now)
  out=$(core_call "$sb" exec-as "{\"login\": \"alice\", \"argv\": [\"/bin/sh\", \"-c\", \"touch $mark\"]}"); rc=$?
  [ "$rc" = 2 ] || { WHY="exec-as of a program outside bin/ was not refused (rc $rc): $out"; return 1; }
  for line in "{\"op\": \"machine\", \"args\": {\"job\": \"/bin/sh\", \"action\": \"start\"}}" \
              '{"op": "machine", "args": {"job": "sudo", "action": "start"}}' \
              "{\"op\": \"machine\", \"args\": {\"job\": \"looper\", \"action\": \"start\", \"argv\": [\"touch\", \"$mark\"]}}" \
              '{"op": "machine", "args": {"job": "looper", "action": "exec"}}' \
              '{"op": "sweep", "args": {"path": "/etc/sudoers"}}' \
              '{"op": "entry", "args": {"keys": "ssh-ed25519 AAAA root"}}' \
              '{"op": "report", "args": {"kind": "file:/var/db/fleet-cred/.shared.json"}}' \
              '{"op": "kill", "args": {"pid": 1}}' \
              '{"op": "run-as", "args": {"login": "root", "job": "looper"}}'; do
    out=$(core_raw "$sb" "$line")
    printf '%s' "$out" | grep -q '"refused"' || { WHY="not refused: $line → $out"; return 1; }
  done
  # a process that is not a managed login's: the seat cannot end it
  sleep 60 & sleeper=$!
  printf '{}\n' > "$sb/db/accounts.json"
  out=$(core_call "$sb" kill "{\"pid\": $sleeper}"); rc=$?
  kill -0 "$sleeper" 2>/dev/null && [ "$rc" = 2 ] \
    || { kill "$sleeper" 2>/dev/null; WHY="the seat ended an unmanaged process (rc $rc): $out"; return 1; }
  kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null
  [ ! -e "$mark" ] || { WHY="a refused request RAN something ($mark exists)"; return 1; }
  # what is left: the table's start / stop by name
  out=$(core_raw "$sb" '{"op": "machine", "args": {"job": "looper", "action": "stop"}}')
  printf '%s' "$out" | grep -q '"ok": true' || { WHY="stop of a table job was not answered: $out"; return 1; }
  # the account: no admin, no shell, no home (its creation, recorded)
  printf '#!/bin/sh\necho "$*" >> %s/seat-cmds\n' "$sb" > "$sb/rec.sh"; chmod 755 "$sb/rec.sh"
  # shellcheck disable=SC2046
  env $(core_env "$sb") FLEET_NODE_SEAT_CMD="$sb/rec.sh" python3 -c '
import importlib.util, sys
sp = importlib.util.spec_from_file_location("s", sys.argv[1]); m = importlib.util.module_from_spec(sp)
sp.loader.exec_module(m); m.seat_make()' "$sb/root/rt/bin/fleet-node-supervisor.py" \
    || { WHY="seat_make did not run"; return 1; }
  grep -Eq -- '-shell /usr/bin/false .*-home /var/empty -roleAccount|--home-dir /nonexistent --shell /usr/sbin/nologin' \
    "$sb/seat-cmds" || { WHY="the account is not shell-less and homeless: $(cat "$sb/seat-cmds")"; return 1; }
  ! grep -Eqw 'admin|wheel|sudo|staff' "$sb/seat-cmds" \
    || { WHY="the account is put in an admin group: $(cat "$sb/seat-cmds")"; return 1; }
  if [ "$(id -u)" = 0 ] && id -u _fleetnode >/dev/null 2>&1; then
    local who; who=$(stat -f %Su /dev/console 2>/dev/null || echo nobody)
    ! sudo -n -u _fleetnode ls "/Users/$who" >/dev/null 2>&1 || { WHY="_fleetnode reads /Users/$who"; return 1; }
    ! sudo -n -u _fleetnode ls /var/db/fleet-cred >/dev/null 2>&1 || { WHY="_fleetnode reads /var/db/fleet-cred"; return 1; }
    ! sudo -n -u _fleetnode sudo -n true >/dev/null 2>&1 || { WHY="_fleetnode can sudo"; return 1; }
  fi
  SECS=$(since "$t0")
  WHAT="以 _fleetnode 身份：exec-as bin/ 外的程序、表外的 machine 任务、带参数的 sweep / entry / report、结束 pid 1 或非受管登录的进程——全部 refused、什么都没执行；只剩表里的按名启停；账号本身无管理员组、无 shell、无家目录"
}

# root-core-seat-stage (#3670): the updater runs as _fleetnode now and stages into
# <state>/staging; fooled, it names a non-artifact for the root tools cache, or puts
# a ccquota of its own making there for the core to sign with the machine's ONE
# identity (TCC grants follow it). The core works on its own copy, fills the cache
# only from signed artifacts by their digests and signs only the artifact's bytes:
# each refused, nothing written to <root>/tools, nothing signed, current stays. The
# release as fetched switches, its ccquota signed by the core.
drill_root_core_seat_stage() {
  CAP=20
  local sb t0 out rc cur good bad h d
  sb="$WORK/core-stage"; core_sandbox "$sb"
  good=$(printf 'a%.0s' $(seq 40)); bad=$(printf 'b%.0s' $(seq 40))
  python3 "$BIN/fleet-node-core-selftest.py" --write-pub "$sb/db/release.pub"
  python3 "$BIN/fleet-node-core-selftest.py" --make-release "$sb/root" "$good"
  ln -s "$sb/root/$good" "$sb/root/current"
  mkdir -p "$sb/cs" "$sb/db/codesign"
  printf '#!/bin/sh\nfor a; do :; done\necho "$*" >> %s/sign.log\ncase "$*" in *--force*) echo SIGNED >> "$a";; *--verify*) tail -1 "$a" | grep -q SIGNED;; esac\n' \
    "$sb" > "$sb/cs/codesign"
  printf '#!/bin/sh\nexit 0\n' > "$sb/cs/security"; cp "$sb/cs/security" "$sb/cs/openssl"
  chmod 755 "$sb/cs/"*
  printf '{"sha1": "%s"}\n' "$(printf 'f%.0s' $(seq 40))" > "$sb/db/codesign/identity.json"
  : > "$sb/db/codesign/identity.keychain-db"; echo p > "$sb/db/codesign/keychain.pass"
  FLEET_NODE_CODESIGN_FORCE=1 FLEET_NODE_CODESIGN_CODESIGN="$sb/cs/codesign" \
    FLEET_NODE_CODESIGN_SECURITY="$sb/cs/security" FLEET_NODE_CODESIGN_OPENSSL="$sb/cs/openssl" \
    core_serve "$sb" || { WHY="the core never listened: $(cat "$sb/core.err")"; return 1; }
  t0=$(now)
  h=$(python3 "$BIN/fleet-node-core-selftest.py" --make-staged "$sb/db/staging" "$bad"); d="$sb/db/staging/$bad"
  for map in "{\"claude/$h/claude\": \"../../../etc/passwd\"}" "{\"claude/../../x/claude\": \"claude-1-darwin-arm64\"}" \
             "{\"claude/$h/claude\": \"ccquota-darwin-arm64\"}"; do
    printf '{"tools": %s}\n' "$map" > "$d/.release/staged.json"
    out=$(core_call "$sb" switch "{\"sha\": \"$bad\"}"); rc=$?
    [ "$rc" = 2 ] || { WHY="a staged map $map was not refused (rc $rc): $out"; return 1; }
  done
  [ ! -e "$sb/root/tools" ] || { WHY="a refused stage wrote the root tools cache: $(find "$sb/root/tools")"; return 1; }
  printf '{}\n' > "$d/.release/staged.json"
  printf '#!/bin/sh\necho mine\n' > "$d/bin/ccquota"
  out=$(core_call "$sb" switch "{\"sha\": \"$bad\"}"); rc=$?
  cur=$(basename "$(readlink "$sb/root/current")")
  [ "$rc" = 2 ] && [ "$cur" = "$good" ] && printf '%s' "$out" | grep -q 'bin/ccquota' \
    || { WHY="the seat's own ccquota: rc $rc, current $cur: $out"; return 1; }
  ! grep -q -- --force "$sb/sign.log" 2>/dev/null || { WHY="the core signed the seat's own ccquota"; return 1; }
  [ -d "$d" ] || { WHY="the refused stage was not kept as evidence"; return 1; }
  cp "$d/.release/artifacts/ccquota-darwin-arm64" "$d/bin/ccquota"
  out=$(core_call "$sb" switch "{\"sha\": \"$bad\"}"); rc=$?
  cur=$(basename "$(readlink "$sb/root/current")")
  [ "$rc" = 0 ] && [ "$cur" = "$bad" ] && tail -1 "$sb/root/$bad/bin/ccquota" | grep -q SIGNED \
    || { WHY="the release as fetched did not switch signed (rc $rc, current $cur): $out"; return 1; }
  SECS=$(since "$t0")
  WHAT="降权更新器的 staging 把根工具缓存指向清单外、或放自制 ccquota 请核心签：都拒绝、根缓存不写、什么也不签、current 不动；原样的发布版切过去、ccquota 由核心签"
}

# root-core-update-step (#3670): the seated updater's root half is ONE op with a
# step name. Asked with a step outside the list, an argv, a path, a key too many:
# refused, nothing runs; a listed step runs <current>/bin/fleet-node-update.py.
drill_root_core_update_step() {
  CAP=15
  local sb t0 out line mark
  sb="$WORK/core-update"; core_sandbox "$sb"; mark="$sb/PWNED"
  core_serve "$sb" || { WHY="the core never listened: $(cat "$sb/core.err")"; return 1; }
  t0=$(now)
  for line in "{\"op\": \"update\", \"args\": {\"step\": \"touch $mark\"}}" \
              '{"op": "update", "args": {"step": "../../bin/sh"}}' \
              "{\"op\": \"update\", \"args\": {\"step\": \"prune\", \"argv\": [\"touch\", \"$mark\"]}}" \
              '{"op": "update", "args": {}}' \
              '{"op": "update", "args": {"step": 1}}'; do
    out=$(core_raw "$sb" "$line")
    printf '%s' "$out" | grep -q '"refused"' || { WHY="not refused: $line → $out"; return 1; }
  done
  [ ! -e "$mark" ] || { WHY="a refused update step RAN something"; return 1; }
  out=$(core_raw "$sb" '{"op": "update", "args": {"step": "prune"}}')
  printf '%s' "$out" | grep -q '"ok": true' || { WHY="a listed step was not answered: $out"; return 1; }
  grep -q 'op=update .*refused' "$sb/core.log" || { WHY="no refused update line: $(cat "$sb/core.log")"; return 1; }
  SECS=$(since "$t0")
  WHAT="请核心做更新器的 root 一半时塞表外 step、argv、多一个键：全部 refused、什么都没执行、记一行；表里的 step 照常跑"
}

# node-program-seat (#3669): the node program runs as the seat and hands each
# login's command to the core with its own stdin / stdout / stderr. Three ways that
# goes wrong: its helper killed and the login's job runs on with no one to stop it;
# the seat (or whoever holds it) asking root to start the node program as root
# again; descriptors riding an op that takes none. The core stops a streamed job
# the moment its caller's connection goes, refuses `machine start` of the "seat_agent" job while
# the switch is on (stop only), refuses fds on anything but exec-as.
drill_node_program_seat() {
  CAP=30
  local sb t0 out pid
  sb="$WORK/seatagent"; core_sandbox "$sb"
  printf '#!/bin/bash\ntrap "exit 0" TERM; while :; do sleep 0.2; done\n' > "$sb/root/rt/bin/fleet-loop.sh"
  chmod 755 "$sb/root/rt/bin/fleet-loop.sh"
  printf '{"children": [{"name": "node-agent", "cmd": ["/bin/bash", "%s"], "seat_agent": true}], "tasks": [], "account": []}\n' \
    "$sb/root/rt/bin/fleet-loop.sh" > "$sb/table.json"
  # the switch on: root's marker, the seat account there (this uid)
  printf '{"alice": {"uid": %d, "gid": %d, "home": "%s"}, "_fleetnode": {"uid": %d, "gid": %d, "home": "/var/empty"}, "fleetnode": {"uid": %d, "gid": %d, "home": "/var/empty"}}\n' \
    "$(id -u)" "$(id -g)" "$sb/Users/alice" "$(id -u)" "$(id -g)" "$(id -u)" "$(id -g)" > "$sb/passwd.json"
  printf '{}\n' > "$sb/db/seat-agent"
  core_serve "$sb" || { WHY="the core never listened: $(cat "$sb/core.err")"; return 1; }
  t0=$(now)
  # the caller goes: ask, read the pid, drop the connection
  pid=$(python3 - "$sb/core.sock" "$sb/root/rt/bin/fleet-loop.sh" <<'PY'
import json, os, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sys.argv[1])
fds = [os.open(os.devnull, os.O_RDWR) for _ in range(3)]
line = (json.dumps({"op": "exec-as", "args": {"login": "alice", "argv": [sys.argv[2]]}}) + "\n").encode()
s.sendmsg([line], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, b"".join(f.to_bytes(4, sys.byteorder) for f in fds))])
buf = b""
while b"\n" not in buf:
    buf += s.recv(4096)
print(json.loads(buf.split(b"\n")[0]).get("pid", ""))
s.close()
PY
)
  [ -n "$pid" ] || { WHY="exec-as on the caller's fds did not start: $(tail -n 3 "$sb/core.log" 2>/dev/null)"; return 1; }
  local i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  ! kill -0 "$pid" 2>/dev/null || { kill "$pid" 2>/dev/null; WHY="the login's job $pid outlived its caller"; return 1; }
  # the node program as root: refused; stop of a root copy: answered
  out=$(core_raw "$sb" '{"op": "machine", "args": {"job": "node-agent", "action": "start"}}')
  printf '%s' "$out" | grep -q '"refused"' || { WHY="root started the seat's node program: $out"; return 1; }
  out=$(core_raw "$sb" '{"op": "machine", "args": {"job": "node-agent", "action": "stop"}}')
  printf '%s' "$out" | grep -q '"ok": true' || { WHY="stop of the root copy was not answered: $out"; return 1; }
  # descriptors on an op that takes none
  out=$(python3 - "$sb/core.sock" <<'PY'
import json, os, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sys.argv[1])
fds = [os.open(os.devnull, os.O_RDWR) for _ in range(3)]
line = (json.dumps({"op": "kill", "args": {"pid": 1}}) + "\n").encode()
s.sendmsg([line], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, b"".join(f.to_bytes(4, sys.byteorder) for f in fds))])
print(s.recv(4096).decode().strip())
PY
)
  printf '%s' "$out" | grep -q '"refused"' && printf '%s' "$out" | grep -q descriptor \
    || { WHY="fds on kill were not refused: $out"; return 1; }
  SECS=$(since "$t0")
  WHAT="节点程序以 _fleetnode 跑：它的 core-exec 被杀，登录身份的活随连接断开即停；请 root 把节点程序当 machine 任务起——拒绝（只许停 root 那份）；描述符搭在别的动作上——拒绝"
}

cred_run_drills "$0"
