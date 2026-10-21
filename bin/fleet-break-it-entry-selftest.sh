#!/bin/bash
# fleet-break-it-entry-selftest.sh — docs/dev/BREAK-IT.md's entry-* rows (issue #3070,
# EPIC #3067 C3): every way someone could get through the home machine's PUBLIC
# entry port without a key the hub registered, tried for real against the real
# entry sshd — `fleet-node-supervisor.py run` in a sandbox (its own state dir, its
# own port on 127.0.0.1, its own host key, a fake passwd), the listener its child
# exactly as on a node; the system sshd and ~/.ssh are never touched (each drill
# checks both byte for byte). Its own file, like the node drills whose runner it
# sources (BREAK_CRED_LIB=1); bin/fleet-break-it-selftest.sh's lockstep lint reads
# the drill_* names here too.
#
#   entry-password        bin/fleet-node-supervisor.py entry_config: a password /
#                         keyboard-interactive login is not even offered
#   entry-other-login     the keys files (keys/<login>, AuthorizedKeysFile …/%u): one
#                         person's key does not open another login
#   entry-revoked-key     entry_converge + entry_cut: a key the hub dropped is refused
#                         at once and the connection it holds is cut
#   entry-self-added-key  entry_config: a key a session writes for itself (its own
#                         ~/.ssh/authorized_keys) is not read by the entry port
#   entry-admin-login     entry_eligible: an admin login (or one that becomes one) is
#                         never on AllowUsers — the listener goes when nobody is left
#   entry-keys-tampered   entry_converge (the supervisor's tend_entry pass): a keys
#                         file rewritten outside the hub's list is put back
#   entry-hub-down        entry_pull: the hub away — the last list keeps working, the
#                         doctor's entry row says how far behind it is
#   entry-no-command-lands  bin/fleet-entry.sh, the ForceCommand (issue #3071, C5): no
#                         command on a terminal is the 看台 (a stand-in viewer records
#                         its argv), a command / sftp / scp / rsync runs as on port 22,
#                         no command and no terminal is the login shell; each arrival
#                         is a line in entry.ndjson (the login's and the door's)
#   entry-view-crash-drops  bin/fleet-entry.sh (EPIC T651 C4): a 看台 that ends with
#                         any code but a leave (0 · 129) — a stand-in exiting 7 —
#                         lands the person in the login shell with one line (why ·
#                         `fleet` goes back) and FLEET_NO_VIEW=1, never a closed connection
#   entry-no-lang         bin/fleet-entry.sh + entry_config's AcceptEnv (issue #3196):
#                         a phone that sends no LANG still reaches the 看台 in UTF-8 —
#                         a real tmux client draws Chinese to its terminal — and a
#                         locale the client does send wins
#   entry-public-unreachable  entry_reach + the hub's handleNodeEntryReach (#3072): an
#                         address that resolves but nothing answers at is never in
#                         reachable(machine) — the hub half's Go test dials THIS
#                         drill's real entry sshd (go test, when a toolchain is here)
#                         and a closed one; the node half reports for real and the
#                         doctor's `public` row says 连不上 + which port to forward
#   door-wrong-pod        the cluster's one door (issue #3549, EPIC #3500 C4; T647):
#                         fleet-node-supervisor.py's door mode, its jump account
#                         alone — with an empty table it still listens (its
#                         startup probe is tcp :22022, #3554) and lets nobody
#                         through; each person's key tunnels only to the ONE pod
#                         its route names, the door has no account per login, the
#                         home moving moves the tunnel, a login two pods claim goes
#                         nowhere
#   door-hostkey-pod      a pod behind the door (issue #4127): ssh lands on the DOOR's
#                         sshd, so fleet-known-hosts must hold the door's key under
#                         fleet-<pod> — the pod's own (an image's baked key) is
#                         「REMOTE HOST IDENTIFICATION HAS CHANGED」 on every connect;
#                         the client's write_known_hosts with each against a real
#                         door, and the hub half's Go test (TestDoorRouteListHandsOutTheDoorsHostKey)
#   door-reach-stale      the door's reach lapsing (issue #4149): a door image that
#                         reports `entry reach` only at its start lost every pod's
#                         door route EntryReachFresh later — the hub re-dials a
#                         pulling door's last addresses against its host key
#                         (TestDoorPullKeepsItsReachFresh, a real sshd)
#   pod-relay-loopback    the relay into a person's pod (issue #4149): the pod's
#                         agent splices it onto 127.0.0.1:2222, whose sshd once took
#                         the door's key alone — a real sshd on pod_sshd_text: a hub-CA
#                         certificate lands on loopback, not on the pod's address,
#                         and a plain key does not
#   door-jump-two-replicas  the hub with two replicas (issue #4317): a pod's pull and
#                         the door's pull land on the replica that does not hold the
#                         pod's link — the machine check reads the other replica's
#                         link, the jump readiness is in the store, and a route
#                         without the jump says which end is missing (go test)
#   door-session-no-sig   one address for everyone (A5SQ): the hub signs the door's
#                         hop home only for the person's own signature over THIS
#                         session as THIS user (go test TestDoorSessionNeedsTheirSignature)
#   door-session-replay   …and once: the same session handed in again is refused,
#                         on every replica (go test TestDoorSessionOnce)
#   door-home-not-door    the stream to a person's home: the door's token only, a
#                         machine home only, onto its entry port (go test
#                         TestDoorHomeStreamOnlyTheDoor)
#   entry-forward-out     entry_config (issue #3075, C9): -L / -W only to this machine
#                         (localhost · 127.0.0.1 · ::1) — another address is
#                         denied by the entry, -R refused — and a file the
#                         thin client drops (fleet-client-upload.py recv) lands in
#                         that login's inbox only
#
# Each prints `PASS <id> <secs>s ≤<cap>s <what came back>` like its parent.
# No sshd / ssh / ssh-keygen here, or an sshd without PerSourcePenalties
# (OpenSSH < 9.8: the entry refuses to start on it) → SKIP (exit 0).
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SSHD_BIN="${FLEET_ENTRY_SSHD:-/usr/sbin/sshd}"
for t in "$SSHD_BIN" ssh ssh-keygen; do
  command -v "$t" >/dev/null 2>&1 || { printf 'fleet-break-it-entry: %s absent — SKIP\n' "$t"; exit 0; }
done
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"
SUP="$BIN/fleet-node-supervisor.py"
ME="$(id -un)"
# The entry never starts on an sshd without per-source penalties (OpenSSH < 9.8 —
# ubuntu-24.04's 9.6, Debian bookworm's 9.2): it refuses, and the doctor says what
# is missing (fleet-node-supervisor-selftest.py Q pins that). Nothing to drill there.
_pk="$WORK/entry-probe"; mkdir -p "$_pk"
ssh-keygen -q -t ed25519 -N '' -f "$_pk/hk" && printf 'HostKey %s\nPidFile %s/pid\n' "$_pk/hk" "$_pk" > "$_pk/cfg"
if ! "$SSHD_BIN" -T -f "$_pk/cfg" -C user=nobody,host=localhost,addr=127.0.0.1 2>/dev/null \
     | grep -q '^persourcepenalties [^n]'; then
  printf 'fleet-break-it-entry: %s has no PerSourcePenalties (OpenSSH < 9.8) — the entry refuses to start on it; SKIP\n' \
    "$SSHD_BIN"
  exit 0
fi

# sshd's StrictModes refuses a keys file under a group/world-writable directory —
# /tmp is one — so the rig lives where every ancestor is root's or ours, 0755.
ebase_ok() {
  python3 - "$1" <<'PY'
import os, sys
p, uid = os.path.realpath(sys.argv[1]), os.getuid()
while True:
    st = os.stat(p)
    if st.st_uid not in (0, uid) or st.st_mode & 0o022:
        sys.exit(1)
    if p == "/":
        sys.exit(0)
    p = os.path.dirname(p)
PY
}
EB="$WORK/entry"
mkdir -p "$EB"; chmod 755 "$EB"
if ! ebase_ok "$EB"; then
  mkdir -p "$HOME/.cache"
  EB="$(mktemp -d "$HOME/.cache/fleet-entry-drill.XXXXXX")" || exit 2
  chmod 755 "$EB"
  printf '%s\n' "$EB" > "$WORK/entry-base"
fi
EB="$(cd "$EB" && pwd -P)"
entry_cleanup() {
  [ -n "${EB:-}" ] && pkill -f "$EB/" 2>/dev/null
  [ -f "$WORK/entry-base" ] && [ -z "${BREAK_KEEP:-}" ] && rm -rf "$(cat "$WORK/entry-base")"
  cleanup
}
trap entry_cleanup EXIT

# the system's own sshd config and this login's authorized_keys: never touched
sys_sig() { cat /etc/ssh/sshd_config "$HOME/.ssh/authorized_keys" 2>/dev/null | cksum; }
SYS0="$(sys_sig)"

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

# erig <name>: a fresh machine — state dir, fake passwd (this login a tenant, plus
# `other`), three keys; the supervisor not started yet
erig() {
  E="$EB/$1"; ESUP=""; mkdir -p "$E/db/logins" "$E/log" "$E/rt"; chmod 755 "$E" "$E/db"
  : > "$E/db/logins/$ME.env"; : > "$E/db/logins/other.env"
  EPORT="$(free_port)"
  python3 - "$E/passwd" "$ME" "$(id -u)" "$(id -g)" "$HOME" <<'PY'
import json, sys
p, me, uid, gid, home = sys.argv[1:]
json.dump({me: {"uid": int(uid), "gid": int(gid), "home": home},
           "other": {"uid": int(uid) + 1, "gid": int(gid), "home": "/nonexistent"}}, open(p, "w"))
PY
  for k in k1 k2 k3; do ssh-keygen -q -t ed25519 -N '' -C "drill-$k" -f "$E/$k"; done
  printf '{"children":[],"tasks":[]}\n' > "$E/table.json"
  export FLEET_NODE_STATE="$E/db" FLEET_NODE_LOG="$E/log" FLEET_NODE_RUNTIME="$E/rt" FLEET_NODE_TEST=1 \
    FLEET_NODE_PASSWD="$E/passwd" FLEET_NODE_TABLE="$E/table.json" FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' \
    FLEET_NODE_TENANT_EVERY=1 FLEET_ENTRY=1 FLEET_ENTRY_PORT="$EPORT" FLEET_ENTRY_EVERY=1 FLEET_ENTRY_SSHD="$SSHD_BIN" \
    FLEET_ENTRY_DSEDITGROUP=''
}
eunset() {
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_TEST FLEET_NODE_PASSWD FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TENANT_EVERY FLEET_ENTRY FLEET_ENTRY_PORT FLEET_ENTRY_EVERY \
    FLEET_ENTRY_SSHD FLEET_ENTRY_DSEDITGROUP FLEET_ENTRY_TEST_SETENV
}
# elist <version> <login>=<key>[,<key>…] … → $E/list-<version>.json, the hub's shape
elist() {
  local v="$1"; shift
  python3 - "$E" "$v" "$@" <<'PY'
import base64, hashlib, json, sys
d, v, specs = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
out = {"version": v, "logins": {}}
for spec in specs:
    login, keys = spec.split("=", 1)
    ks = []
    for k in keys.split(","):
        t, b = open("%s/%s.pub" % (d, k)).read().split()[:2]
        fp = "SHA256:" + base64.b64encode(hashlib.sha256(base64.b64decode(b)).digest()).decode().rstrip("=")
        ks.append({"fp": fp, "type": t, "b64": b, "name": "drill-%s" % k})
    out["logins"][login] = {"person": "gh:%s" % login, "keys": ks}
json.dump(out, open("%s/list-%d.json" % (d, v), "w"))
PY
  printf '%s/list-%s.json' "$E" "$v"
}
eapply() { python3 "$SUP" entry apply "$@" >>"$E/apply.out" 2>&1; }
eup() {
  python3 -I "$SUP" run 2>>"$E/sup.err" &
  ESUP=$!; printf '%s\n' "$ESUP" >> "$WORK/cred-pids"
}
listening() { python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1).close()' "$EPORT" 2>/dev/null; }
edown() {
  [ -z "$ESUP" ] || { kill "$ESUP" 2>/dev/null; wait "$ESUP" 2>/dev/null; }
  until_ok 5 sh -c '! pgrep -f "$1" >/dev/null' _ "$E/db/entry/sshd_config"
  eunset
}
# etry <key> [login] [ssh options…] → ssh's exit; its stderr in $E/ssh.err
etry() {
  local k="$1" who="${2:-$ME}"; shift; [ $# -gt 0 ] && shift
  ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$E/known_hosts" -o ConnectTimeout=5 -o LogLevel=ERROR -p "$EPORT" -i "$E/$k" "$@" \
    "$who@127.0.0.1" true 2>"$E/ssh.err" </dev/null
}
sys_same() { [ "$(sys_sig)" = "$SYS0" ] || { WHY="the system sshd config or ~/.ssh/authorized_keys changed"; return 1; }; }

drill_entry_password() {
  CAP=15   # a converge pass + the listener's start
  local t0
  erig password
  eapply "$(elist 1 "$ME=k1")" || { WHY="entry apply failed: $(tail -2 "$E/apply.out")"; edown; return 1; }
  t0=$(now); eup
  until_ok 10 listening || { WHY="the entry sshd never listened: $(tail -3 "$E/sup.err" "$E/log/entry.log" 2>/dev/null | tr '\n' ' ')"; edown; return 1; }
  SECS=$(since "$t0")
  etry k1 || { WHY="the registered key was refused: $(cat "$E/ssh.err")"; edown; return 1; }
  etry k1 "$ME" -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
    -o NumberOfPasswordPrompts=1 && { WHY="a login with no key got in"; edown; return 1; }
  grep -q 'Permission denied (publickey)' "$E/ssh.err" || { WHY="the port offers more than publickey: $(cat "$E/ssh.err")"; edown; return 1; }
  "$SSHD_BIN" -T -f "$E/db/entry/sshd_config" -C "user=$ME,host=localhost,addr=127.0.0.1" > "$E/T" 2>&1
  grep -qx 'passwordauthentication no' "$E/T" && grep -qx 'kbdinteractiveauthentication no' "$E/T" \
    && grep -qx 'authenticationmethods publickey' "$E/T" && grep -qx 'permitrootlogin no' "$E/T" \
    && grep -q '^persourcepenalties ' "$E/T" || { WHY="sshd -T on the entry config: $(grep -E '^(password|kbd|authenticationmethods|permitroot|persource)' "$E/T" | tr '\n' ' ')"; edown; return 1; }
  sys_same || { edown; return 1; }
  edown
  WHAT="入口端口只给公钥：不带钥匙连只得 Permission denied (publickey)，密码 / 键盘交互都不提供；登记过的钥匙照常进；同一来源连续失败自动封（PerSourcePenalties 在）"
}

drill_entry_other_login() {
  CAP=15
  local t0
  erig other
  eapply "$(elist 1 "$ME=k1" "other=k2")" || { WHY="entry apply failed: $(tail -2 "$E/apply.out")"; edown; return 1; }
  t0=$(now); eup
  until_ok 10 listening || { WHY="the entry sshd never listened"; edown; return 1; }
  etry k1 || { WHY="this login's own key was refused: $(cat "$E/ssh.err")"; edown; return 1; }
  etry k2 && { WHY="other's key opened $ME"; edown; return 1; }
  SECS=$(since "$t0")
  grep -q 'Permission denied' "$E/ssh.err" || { WHY="other's key: $(cat "$E/ssh.err")"; edown; return 1; }
  grep -q "$(cut -d' ' -f2 "$E/k2.pub")" "$E/db/entry/keys/$ME" && { WHY="other's key is in $ME's keys file"; edown; return 1; }
  grep -q "$(cut -d' ' -f2 "$E/k2.pub")" "$E/db/entry/keys/other" || { WHY="other's keys file lacks its key"; edown; return 1; }
  sys_same || { edown; return 1; }
  edown
  WHAT="甲的钥匙登乙的登录被拒：每个登录只读自己那份 keys/<login>（AuthorizedKeysFile …/%u），别人的钥匙不在里面"
}

drill_entry_revoked_key() {
  CAP=10   # the batch's bar: a revoke to Permission denied ≤ 10 s
  local t0 hold
  erig revoked
  eapply "$(elist 1 "$ME=k1,k2")" || { WHY="entry apply failed: $(tail -2 "$E/apply.out")"; edown; return 1; }
  eup
  until_ok 10 listening || { WHY="the entry sshd never listened"; edown; return 1; }
  ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$E/known_hosts" -o LogLevel=ERROR -p "$EPORT" -i "$E/k1" "$ME@127.0.0.1" 'sleep 60' \
    </dev/null >/dev/null 2>&1 &
  hold=$!
  until_ok 5 grep -q 'Accepted publickey' "$E/log/entry.log" || { WHY="k1 never got in: $(tail -3 "$E/log/entry.log")"; edown; return 1; }
  sleep 0.5
  t0=$(now)
  eapply "$(elist 2 "$ME=k2")" || { WHY="entry apply v2 failed: $(tail -2 "$E/apply.out")"; kill "$hold" 2>/dev/null; edown; return 1; }
  until_ok 10 sh -c '! kill -0 "$1" 2>/dev/null' _ "$hold" || { WHY="the connection k1 holds was not cut"; kill "$hold" 2>/dev/null; edown; return 1; }
  etry k1 && { WHY="the revoked key still gets in"; edown; return 1; }
  SECS=$(since "$t0")
  etry k2 || { WHY="the key still on the list was refused: $(cat "$E/ssh.err")"; edown; return 1; }
  sys_same || { edown; return 1; }
  edown
  WHAT="入口撤掉一把钥匙：下一次拉名单（这里直接 apply）就拒它，它正连着的连接被断开（ExposeAuthInfo / 日志里的指纹对上连接），名单上剩下的钥匙照常进"
}

drill_entry_self_added_key() {
  CAP=15
  local t0 kf
  erig self
  eapply "$(elist 1 "$ME=k1")" || { WHY="entry apply failed: $(tail -2 "$E/apply.out")"; edown; return 1; }
  t0=$(now); eup
  until_ok 10 listening || { WHY="the entry sshd never listened"; edown; return 1; }
  # where would sshd read a session's own key? only the entry's keys file
  "$SSHD_BIN" -T -f "$E/db/entry/sshd_config" -C "user=$ME,host=localhost,addr=127.0.0.1" > "$E/T" 2>&1
  kf=$(sed -n 's/^authorizedkeysfile //p' "$E/T")
  [ "$kf" = "$E/db/entry/keys/%u" ] || { WHY="the entry reads keys from [$kf], not only its own file"; edown; return 1; }
  grep -Eqx 'authorizedkeyscommand none' "$E/T" || { WHY="an AuthorizedKeysCommand: $(grep -i authorizedkeyscommand "$E/T")"; edown; return 1; }
  grep -Eqx 'trustedusercakeys none' "$E/T" || { WHY="a user CA is trusted: $(grep -i trustedusercakeys "$E/T")"; edown; return 1; }
  grep -Eqx 'permituserenvironment no' "$E/T" && grep -Eqx 'permituserrc no' "$E/T" \
    || { WHY="the login's .ssh/environment or .ssh/rc honoured"; edown; return 1; }
  etry k3 && { WHY="an unregistered key got in"; edown; return 1; }
  etry k1 || { WHY="the registered key was refused: $(cat "$E/ssh.err")"; edown; return 1; }
  SECS=$(since "$t0")
  sys_same || { edown; return 1; }
  edown
  WHAT="会话自己加的钥匙打不开入口：入口只读 root 的 keys/<login>（sshd -T：authorizedkeysfile 只此一处，无 AuthorizedKeysCommand、无用户 CA、不读 ~/.ssh/environment / rc）；系统 sshd 配置与 ~/.ssh/authorized_keys 前后逐字节相同"
}

drill_entry_admin_login() {
  CAP=10   # FLEET_ENTRY_EVERY (1 s here) + a tick + the listener's stop
  local t0
  erig admin
  eapply "$(elist 1 "$ME=k1")" || { WHY="entry apply failed: $(tail -2 "$E/apply.out")"; edown; return 1; }
  eup
  until_ok 10 listening || { WHY="the entry sshd never listened"; edown; return 1; }
  etry k1 || { WHY="the tenant's key was refused: $(cat "$E/ssh.err")"; edown; return 1; }
  # the login is put in the admin group
  python3 - "$E/passwd" "$ME" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d[sys.argv[2]]["groups"] = ["staff", "admin"]
json.dump(d, open(sys.argv[1], "w"))
PY
  t0=$(now)
  # nobody left on the port: no config, so no listener
  until_ok 10 sh -c '[ ! -e "$1" ]' _ "$E/db/entry/sshd_config" \
    || { WHY="an admin login stayed on AllowUsers: $(grep AllowUsers "$E/db/entry/sshd_config")"; edown; return 1; }
  until_ok 10 eval '! listening' || { WHY="the listener stayed up with nobody left on it"; edown; return 1; }
  etry k1 && { WHY="the admin login still gets in"; edown; return 1; }
  SECS=$(since "$t0")
  python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); assert "admin" in b["refused"][sys.argv[2]], b' \
    "$E/db/entry/state.json" "$ME" 2>/dev/null || { WHY="the book does not say why the login was refused"; edown; return 1; }
  # an admin named by a fresh list: never written at all
  eapply "$(elist 2 "$ME=k1")"
  [ ! -e "$E/db/entry/keys/$ME" ] || { WHY="an admin login got a keys file"; edown; return 1; }
  sys_same || { edown; return 1; }
  edown
  WHAT="管理员登录永远不上入口：名单点名也不写 keys、不进 AllowUsers；在入口上的登录被加进 admin 组，下一拍就被拿掉，没人了入口 sshd 停掉"
}

drill_entry_keys_tampered() {
  CAP=10   # FLEET_ENTRY_EVERY (1 s here) + a tick
  local t0 m
  erig tamper
  eapply "$(elist 1 "$ME=k1")" || { WHY="entry apply failed: $(tail -2 "$E/apply.out")"; edown; return 1; }
  m=$(python3 -c 'import os,sys; print("%o %o %o" % tuple(os.stat(p).st_mode & 0o7777 for p in sys.argv[1:]))' \
        "$E/db/entry" "$E/db/entry/keys" "$E/db/entry/keys/$ME")
  [ "$m" = "755 755 644" ] || { WHY="entry dir / keys dir / keys file modes are [$m], not 755 755 644 (root's on a node)"; edown; return 1; }
  eup
  until_ok 10 listening || { WHY="the entry sshd never listened"; edown; return 1; }
  # someone (on a node: anyone but root, who cannot write it at all) adds a key
  cat "$E/k3.pub" >> "$E/db/entry/keys/$ME"; chmod 666 "$E/db/entry/keys/$ME"
  t0=$(now)
  until_ok 10 sh -c '! grep -q "$1" "$2"' _ "$(cut -d' ' -f2 "$E/k3.pub")" "$E/db/entry/keys/$ME" \
    || { WHY="the rewritten keys file was not put back"; edown; return 1; }
  SECS=$(since "$t0")
  m=$(python3 -c 'import os,sys; print("%o" % (os.stat(sys.argv[1]).st_mode & 0o7777))' "$E/db/entry/keys/$ME")
  [ "$m" = 644 ] || { WHY="the put-back file is $m, not 644"; edown; return 1; }
  etry k3 && { WHY="the planted key gets in"; edown; return 1; }
  etry k1 || { WHY="the registered key was refused after the put-back: $(cat "$E/ssh.err")"; edown; return 1; }
  grep -q "keys file(s) of $ME were changed outside" "$E/sup.err" || { WHY="the daemon did not log the put-back"; edown; return 1; }
  sys_same || { edown; return 1; }
  edown
  WHAT="名单被改（这里同一用户直接改；节点上非 root 根本写不了 root 0644 的文件）：下一拍按最后一份好名单放回、权限改回 0644 并记一行，被塞进去的钥匙进不来"
}

drill_entry_hub_down() {
  CAP=20   # one pull against a closed port + the listener
  local t0 dead
  erig hubdown
  dead=$(free_port)
  printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=tok-drill\n' "$dead" > "$E/db/machine.env"; chmod 600 "$E/db/machine.env"
  eapply "$(elist 4 "$ME=k1")" || { WHY="entry apply failed: $(tail -2 "$E/apply.out")"; edown; return 1; }
  eup
  until_ok 10 listening || { WHY="the entry sshd never listened"; edown; return 1; }
  cp "$E/db/entry/keys/$ME" "$E/keys.before"
  t0=$(now)
  FLEET_ENTRY_PULL_SECS=3 python3 "$SUP" entry pull --version 5 >"$E/pull.out" 2>&1
  [ $? = 1 ] || { WHY="a pull against a dead hub did not say so: $(cat "$E/pull.out")"; edown; return 1; }
  grep -q 'the last list (v4) stands' "$E/pull.out" || { WHY="the pull's words: $(cat "$E/pull.out")"; edown; return 1; }
  cmp -s "$E/keys.before" "$E/db/entry/keys/$ME" || { WHY="the keys file changed on a failed pull"; edown; return 1; }
  etry k1 || { WHY="the last list stopped working with the hub away: $(cat "$E/ssh.err")"; edown; return 1; }
  SECS=$(since "$t0")
  # an hour on, the doctor's row says how far behind (the running daemon rewrites the
  # same book on its beat and can put back what it read before this edit — #3703: edit, check, again)
  behind() {
    python3 - "$E/db/entry/state.json" <<'PY'
import json, sys, time
b = json.load(open(sys.argv[1])); b["hub_version_at"] = time.time() - 3700
json.dump(b, open(sys.argv[1], "w"))
PY
    python3 "$SUP" entry status --check > "$E/check.out"
    [ $? = 1 ] && grep -q '入口 v5 · 本机 v4' "$E/check.out" && grep -q '落后入口一小时以上' "$E/check.out"
  }
  until_ok 5 behind || { WHY="the doctor's entry row: $(cat "$E/check.out")"; edown; return 1; }
  grep -q 'entry status --check' "$BIN/fleet-doctor.sh" || { WHY="fleet-doctor.sh has no entry row"; edown; return 1; }
  sys_same || { edown; return 1; }
  edown
  WHAT="入口不在：拉名单失败、钥匙文件一字不动，已加的钥匙照常进；落后入口一小时，体检 entry 行 WARN「入口 v5 · 本机 v4 · 落后入口一小时以上」"
}

drill_entry_no_command_lands() {
  CAP=25   # the listener + four kinds of arrival + one audit pass
  local t0 cf fp v want out dev h; local -a eopts
  erig lands
  # the runtime carries the dispatcher (on a node: <root>/current/bin/fleet-entry.sh)
  mkdir -p "$E/rt/bin" "$E/conf" "$E/files"; ln -s "$BIN/fleet-entry.sh" "$E/rt/bin/fleet-entry.sh"
  cf="$E/conf"
  # the 看台 stand-in: records how it was called, writes the row a real attach would
  cat > "$E/view.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$(dirname "$0")/view.args"
v=''; while [ $# -gt 0 ]; do [ "$1" = --view ] && v=$2; shift; done
mkdir -p "$FLEET_CONF_DIR/remote-views"
printf 'tty\tfleet\tthin\t1\t1\tcur=uuid/fid-last\troute=entry\n' > "$FLEET_CONF_DIR/remote-views/$v"
echo VIEW-STAND-IN
SH
  chmod +x "$E/view.sh"
  export FLEET_ENTRY_TEST_SETENV="FLEET_ENTRY_VIEW=$E/view.sh FLEET_CONF_DIR=$cf"
  eapply "$(elist 1 "$ME=k1")" || { WHY="entry apply failed: $(tail -2 "$E/apply.out")"; edown; return 1; }
  grep -q "^ForceCommand /bin/bash $E/rt/bin/fleet-entry.sh\$" "$E/db/entry/sshd_config" \
    || { WHY="no ForceCommand in the entry config: $(grep -i force "$E/db/entry/sshd_config")"; edown; return 1; }
  t0=$(now); eup
  until_ok 10 listening || { WHY="the entry sshd never listened"; edown; return 1; }
  eopts=(-F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no
         -o UserKnownHostsFile="$E/known_hosts" -o ConnectTimeout=5 -o LogLevel=ERROR -i "$E/k1")
  # 1. no command, a terminal ⇒ the 看台
  out=$(ssh "${eopts[@]}" -tt -p "$EPORT" "$ME@127.0.0.1" </dev/null 2>"$E/ssh.err")
  case "$out" in *VIEW-STAND-IN*) ;; *) WHY="no command on a terminal did not reach the 看台: [$out] $(cat "$E/ssh.err")"; edown; return 1 ;; esac
  v=$(head -n 1 "$E/view.args")
  case "$v" in "attach --thin --view e-drill-k1-"[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]" --resume --device "*" --route entry --token "*) ;;
    *) WHY="the 看台 was called as [$v]"; edown; return 1 ;; esac
  dev=$(printf '%s' "$v" | sed -n 's/.* --device \([^ ]*\) .*/\1/p' | base64 -d 2>/dev/null)
  case "$dev" in *'"device": "drill-k1"'*'"via": "entry"'*) ;; *) WHY="the device it said: [$dev]"; edown; return 1 ;; esac
  # 2. the same key again: back to the session it showed last (--want <last>)
  ssh "${eopts[@]}" -tt -p "$EPORT" "$ME@127.0.0.1" </dev/null >/dev/null 2>&1
  want=$(sed -n 2p "$E/view.args")
  case "$want" in *" --resume --want uuid/fid-last "*) ;; *) WHY="the second arrival did not come back: [$want]"; edown; return 1 ;; esac
  # 3. a command ⇒ exactly what port 22 gives (the login's shell -c)
  printf 'one\ntwo\n' > "$E/files/a.txt"
  out=$(ssh "${eopts[@]}" -p "$EPORT" "$ME@127.0.0.1" "ls '$E/files'; cat '$E/files/a.txt'" </dev/null 2>"$E/ssh.err")
  [ "$out" = "$("$SHELL" -c "ls '$E/files'; cat '$E/files/a.txt'" </dev/null 2>/dev/null)" ] \
    || { WHY="ssh … ls gave [$out], the shell gives [$("$SHELL" -c "ls '$E/files'")]: $(cat "$E/ssh.err")"; edown; return 1; }
  [ "$(wc -l < "$E/view.args")" -eq 2 ] || { WHY="a command reached the 看台"; edown; return 1; }
  # 4. sftp / scp / rsync as always
  printf 'put %s %s\nget %s %s\n' "$E/files/a.txt" "$E/files/b.txt" "$E/files/b.txt" "$E/files/c.txt" > "$E/sftp.batch"
  sftp "${eopts[@]}" -P "$EPORT" -b "$E/sftp.batch" "$ME@127.0.0.1" >"$E/sftp.out" 2>&1 \
    && cmp -s "$E/files/a.txt" "$E/files/c.txt" || { WHY="sftp: $(tail -3 "$E/sftp.out")"; edown; return 1; }
  scp "${eopts[@]}" -P "$EPORT" "$E/files/a.txt" "$ME@127.0.0.1:$E/files/d.txt" >"$E/scp.out" 2>&1 \
    && cmp -s "$E/files/a.txt" "$E/files/d.txt" || { WHY="scp: $(tail -3 "$E/scp.out")"; edown; return 1; }
  if command -v rsync >/dev/null 2>&1; then
    rsync -e "ssh ${eopts[*]} -p $EPORT" "$E/files/a.txt" "$ME@127.0.0.1:$E/files/e.txt" >"$E/rsync.out" 2>&1 \
      && cmp -s "$E/files/a.txt" "$E/files/e.txt" || { WHY="rsync: $(tail -3 "$E/rsync.out")"; edown; return 1; }
  fi
  # 5. no command, no terminal ⇒ the login shell
  out=$(printf 'echo shell-$((40+2))\n' | ssh "${eopts[@]}" -T -p "$EPORT" "$ME@127.0.0.1" 2>"$E/ssh.err")
  case "$out" in *shell-42*) ;; *) WHY="no command, no terminal: [$out] $(cat "$E/ssh.err")"; edown; return 1 ;; esac
  [ "$(wc -l < "$E/view.args")" -eq 2 ] || { WHY="ssh -T reached the 看台"; edown; return 1; }
  SECS=$(since "$t0")
  # the login's line per arrival, and the door's own record (with the key) once a pass ran
  for h in view exec sftp shell; do
    grep -q "\"how\":\"$h\"" "$cf/logs/entry.ndjson" || { WHY="no $h line in the login's entry.ndjson: $(cat "$cf/logs/entry.ndjson")"; edown; return 1; }
  done
  fp=$(ssh-keygen -lf "$E/k1.pub" | awk '{ print $2 }')
  grep -q "\"fp\":\"$fp\"" "$cf/logs/entry.ndjson" || { WHY="the login's lines lack the key's fp"; edown; return 1; }
  until_ok 10 sh -c 'grep -q "$1" "$2" 2>/dev/null' _ "\"fp\": \"$fp\".*\"result\": \"ok\"" "$E/log/entry.ndjson" \
    || { WHY="the door's entry.ndjson: $(tail -2 "$E/log/entry.ndjson" 2>/dev/null)"; edown; return 1; }
  grep -q '"person": "gh:'"$ME"'"' "$E/log/entry.ndjson" || { WHY="the door's line lacks the person"; edown; return 1; }
  grep -q 'ssh-ed25519 AAAA' "$E/log/entry.ndjson" "$cf/logs/entry.ndjson" && { WHY="a key's text in an entry log"; edown; return 1; }
  sys_same || { edown; return 1; }
  edown
  WHAT="入口不带命令有终端 ⇒ 看台（--resume，第二次带回上次的会话；设备名是钥匙在入口上的名字）；带命令 / sftp / scp / rsync 与 22 端口一样；无命令无终端 ⇒ 登录 shell；每次进门登录处一行、入口 sshd 日志里的那把钥匙一行（logs/entry.ndjson，不含钥匙正文）"
}

drill_entry_view_crash_drops() {
  CAP=20   # the listener + four arrivals, each 看台 stand-in ending with its own code
  local t0 cf out rc n; local -a eopts
  erig crash
  mkdir -p "$E/rt/bin" "$E/conf" "$E/bin"; ln -s "$BIN/fleet-entry.sh" "$E/rt/bin/fleet-entry.sh"
  ln -s "$BIN/fleet-ui-lang.sh" "$E/rt/bin/fleet-ui-lang.sh"
  cf="$E/conf"
  # the 看台 stand-in: comes up, then ends with the code in view.rc (EPIC T651 C4's 假看台退出码 7)
  cat > "$E/view.sh" <<'SH'
#!/bin/bash
echo VIEW-UP
exit "$(cat "$(dirname "$0")/view.rc")"
SH
  # the login's shell stand-in: says how it was started, then ends (a real one would wait for you)
  cat > "$E/bin/zsh" <<'SH'
#!/bin/sh
printf 'LOGIN-SHELL noview=%s pwd=%s\n' "${FLEET_NO_VIEW-}" "$PWD"
SH
  chmod +x "$E/view.sh" "$E/bin/zsh"
  export FLEET_ENTRY_TEST_SETENV="FLEET_ENTRY_VIEW=$E/view.sh FLEET_CONF_DIR=$cf SHELL=$E/bin/zsh FLEET_UI_LANG=zh"
  eapply "$(elist 1 "$ME=k1")" || { WHY="entry apply failed: $(tail -2 "$E/apply.out")"; edown; return 1; }
  t0=$(now); eup
  until_ok 10 listening || { WHY="the entry sshd never listened"; edown; return 1; }
  eopts=(-F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no
         -o UserKnownHostsFile="$E/known_hosts" -o ConnectTimeout=5 -o LogLevel=ERROR -i "$E/k1")
  arrive() { echo "$1" > "$E/view.rc"; out=$(ssh "${eopts[@]}" -tt -p "$EPORT" "$ME@127.0.0.1" </dev/null 2>&1); rc=$?; }
  # 1. 看台 crashes with 7 ⇒ the login shell, one line why + how back, FLEET_NO_VIEW=1, the connection kept
  arrive 7
  case "$out" in *VIEW-UP*'看台意外退出（代码 7）'*'输入 fleet 回看台'*'LOGIN-SHELL noview=1 pwd='"$HOME"*) ;;
    *) WHY="a 看台 ending 7: rc=$rc [$(printf %s "$out" | tr "\r\n" "  ")] $(tail -3 "$E/sup.err" 2>/dev/null | tr "\n" " ")"; edown; return 1 ;; esac
  [ "$rc" = 0 ] || { WHY="the connection ended $rc, not the shell's 0"; edown; return 1; }
  SECS=$(since "$t0")
  # 2. one that never came up (2) ⇒ the same, its own words
  arrive 2
  case "$out" in *'看台没起来（2）'*'LOGIN-SHELL noview=1'*) ;; *) WHY="a 看台 ending 2: [$out]"; edown; return 1 ;; esac
  # 3. a leave (0, 129) ⇒ the connection ends, no shell
  for n in 0 129; do
    arrive "$n"
    case "$out" in *LOGIN-SHELL*|*回看台*) WHY="a leave ($n) landed in the shell: [$out]"; edown; return 1 ;; esac
    [ "$rc" = 0 ] || { WHY="a leave ($n) ended the connection $rc"; edown; return 1; }
  done
  grep -q '"how":"shell-viewcrash"' "$cf/logs/entry.ndjson" && grep -q '"how":"shell-noview"' "$cf/logs/entry.ndjson" \
    || { WHY="entry.ndjson lacks the shell lines: $(cat "$cf/logs/entry.ndjson")"; edown; return 1; }
  sys_same || { edown; return 1; }
  edown
  WHAT="入口上看台以代码 7 退出（起来后崩）：${SECS}s 内落到登录 shell（\$HOME，FLEET_NO_VIEW=1），先印「看台意外退出（代码 7）… 输入 fleet 回看台」，连接不断；没起来（2）同样落地；0 / 129 是正常离开，照旧断开、不落 shell"
}

drill_entry_no_lang() {
  CAP=25   # the listener + three arrivals, one with a real tmux on its own socket
  local t0 cf out row; local -a eopts
  erig lang
  mkdir -p "$E/rt/bin" "$E/conf"; ln -s "$BIN/fleet-entry.sh" "$E/rt/bin/fleet-entry.sh"
  cf="$E/conf"
  # the 看台 stand-in: the locale it was handed, then a REAL tmux client (own socket)
  # showing Chinese for a moment — what reaches the terminal is what a phone draws
  cat > "$E/view.sh" <<'SH'
#!/bin/bash
printf 'LANG=%s LC_CTYPE=%s LC_ALL=%s charmap=%s\n' "${LANG-}" "${LC_CTYPE-}" "${LC_ALL-}" \
  "$(locale charmap 2>/dev/null)" >> "$(dirname "$0")/view.args"
command -v tmux >/dev/null 2>&1 || { echo NO-TMUX; exit 0; }
L="drill-lang-$$"
tmux -L "$L" -f /dev/null new-session -d -s v -x 40 -y 4 "printf '看台中文\n'; sleep 30" || exit 0
tmux -L "$L" set-option -g status off \; run-shell -b 'sleep 1.5; tmux -L '"$L"' detach-client -s v' >/dev/null 2>&1
tmux -L "$L" attach-session -t v
tmux -L "$L" kill-server 2>/dev/null
exit 0
SH
  chmod +x "$E/view.sh"
  export FLEET_ENTRY_TEST_SETENV="FLEET_ENTRY_VIEW=$E/view.sh FLEET_CONF_DIR=$cf"
  eapply "$(elist 1 "$ME=k1")" || { WHY="entry apply failed: $(tail -2 "$E/apply.out")"; edown; return 1; }
  grep -q '^AcceptEnv LANG LC_\*$' "$E/db/entry/sshd_config" \
    || { WHY="the entry config takes no client locale: $(grep -i env "$E/db/entry/sshd_config")"; edown; return 1; }
  t0=$(now); eup
  until_ok 10 listening || { WHY="the entry sshd never listened"; edown; return 1; }
  eopts=(-F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no
         -o UserKnownHostsFile="$E/known_hosts" -o ConnectTimeout=5 -o LogLevel=ERROR -i "$E/k1")
  # 1. a phone that sends no LANG (-F /dev/null sends none; the client's own unset too)
  out=$(env -u LANG -u LC_ALL -u LC_CTYPE TERM=xterm-256color \
        ssh "${eopts[@]}" -tt -p "$EPORT" "$ME@127.0.0.1" </dev/null 2>"$E/ssh.err")
  row=$(sed -n 1p "$E/view.args")
  case "$row" in *charmap=UTF-8) ;; *) WHY="no LANG in ⇒ the 看台 got [$row]"; edown; return 1 ;; esac
  case "$out" in
    *NO-TMUX*) ;;
    *看台中文*) ;;
    *) WHY="no LANG in ⇒ tmux drew [$(printf '%s' "$out" | tr -d '\033' | tr -s '\r\n' ' ' | head -c 200)] $(cat "$E/ssh.err")"
       edown; return 1 ;;
  esac
  # 2. the client's own locale wins (AcceptEnv) — unless the login's own shell
  # startup sets one, as on port 22 (issue #3274: the macOS runner's ~/.bashrc
  # exports LC_CTYPE / LC_ALL / LANG, and sshd runs the ForceCommand through that
  # bash). A command arriving the same way says which; LC_TIME, which no rc here
  # sets, proves the client's locale was taken at all.
  local acct want
  acct=$(env -u LC_ALL -u LC_CTYPE LANG=fr_FR.UTF-8 LC_TIME=fr_FR.UTF-8 \
    ssh "${eopts[@]}" -o SendEnv=LANG -o SendEnv=LC_TIME -T -p "$EPORT" "$ME@127.0.0.1" \
    'printf "@@%s@@LANG=%s LC_CTYPE=%s LC_ALL=%s@@\n" "${LC_TIME-}" "${LANG-}" "${LC_CTYPE-}" "${LC_ALL-}"' </dev/null 2>/dev/null)
  case "$acct" in *@@fr_FR.UTF-8@@*) ;; *) WHY="LANG / LC_TIME sent ⇒ a command got [$acct]: the client's locale was not taken"; edown; return 1 ;; esac
  acct=${acct#*@@*@@}; acct=${acct%%@@*}
  want="LANG=fr_FR.UTF-8 LC_CTYPE= LC_ALL="
  [ "$acct" = "$want" ] || want="$acct"   # the account's rc set it: the 看台 must see the same
  env -u LC_ALL -u LC_CTYPE LANG=fr_FR.UTF-8 TERM=xterm-256color \
    ssh "${eopts[@]}" -o SendEnv=LANG -tt -p "$EPORT" "$ME@127.0.0.1" </dev/null >/dev/null 2>&1
  row=$(sed -n 2p "$E/view.args")
  case "$row" in "$want "*) ;; *) WHY="LANG=fr_FR.UTF-8 sent ⇒ the 看台 got [$row], a command [$acct]"; edown; return 1 ;; esac
  # 3. a client that brings a non-UTF-8 one (LC_ALL=C) still gets UTF-8
  env -u LANG -u LC_CTYPE LC_ALL=C TERM=xterm-256color \
    ssh "${eopts[@]}" -o SendEnv=LC_ALL -tt -p "$EPORT" "$ME@127.0.0.1" </dev/null >/dev/null 2>&1
  row=$(sed -n 3p "$E/view.args")
  case "$row" in *charmap=UTF-8) ;; *) WHY="LC_ALL=C sent ⇒ the 看台 got [$row]"; edown; return 1 ;; esac
  SECS=$(since "$t0")
  sys_same || { edown; return 1; }
  edown
  WHAT="入口不带 LANG 进来 ⇒ 看台拿到 UTF-8（$(sed -n 1p "$E/view.args" | awk '{ print $1 }')），真 tmux 客户端把「看台中文」原样画到终端；客户端带的 LANG 优先（AcceptEnv LANG LC_*），带 LC_ALL=C 也换成 UTF-8"
}

drill_entry_public_unreachable() {
  CAP=150   # the listener + one report + the hub half's go test
  local t0 hp hpid gohalf out rc
  erig reach
  eapply "$(elist 2 "$ME=k1")" || { WHY="entry apply failed: $(tail -2 "$E/apply.out")"; edown; return 1; }
  eup
  until_ok 10 listening || { WHY="the entry sshd never listened"; edown; return 1; }
  t0=$(now)
  # The hub half, for real: the handler dials this drill's entry sshd (its own host
  # key — the only address that counts) and an address that resolves but where
  # nothing listens; reachable(machine) holds the first alone, and drops it once
  # the host key no longer matches or the check goes stale.
  gohalf="hub half: no go toolchain here — the Go gate (tokenledger.yml) runs TestEntryReachUnreachableNotRecorded"
  grep -q '^func TestEntryReachUnreachableNotRecorded(' "$ROOT/tokenledger/hub/api/fleet_entry_reach_test.go" 2>/dev/null \
    || { WHY="the hub half's test TestEntryReachUnreachableNotRecorded is gone"; edown; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && FLEET_DRILL_ENTRY="$EPORT $E/db/entry/ssh_host_ed25519_key.pub" \
          GOFLAGS='' GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run '^TestEntryReachUnreachableNotRecorded$' ./hub/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go test did not run"; edown; return 1 ;;
      0:*) gohalf="hub half: go test against this entry sshd ok" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | grep -v '^20' | head -6 | tr '\n' ' ')"
         edown; return 1 ;;
    esac
  fi
  # The node half, for real: `entry reach` reads the listener, the host key and the
  # addresses and posts them; the hub (a stub giving the hub's answer for a home whose
  # address resolves but where nothing answers) says unreachable, and the doctor says so.
  hp=$(free_port)
  python3 - "$hp" "$E/posted.json" <<'PY' &
import http.server, json, sys
port, out = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        open(out, "wb").write(body)
        rep = json.loads(body)
        ans = json.dumps({"checked_at": "2026-10-10T00:00:00Z", "source": "203.0.114.7", "addrs": [
            {"addr": "203.0.114.7", "family": "ipv4", "port": rep["port"], "via": "source",
             "reachable": False, "reason": "timeout"}]}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(ans))); self.end_headers()
        self.wfile.write(ans)
        H.done = True
    def log_message(self, *a): pass
H.done = False
srv = http.server.HTTPServer(("127.0.0.1", port), H)
srv.timeout = 60
while not H.done:
    srv.handle_request()
PY
  hpid=$!; printf '%s\n' "$hpid" >> "$WORK/cred-pids"
  until_ok 5 python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1).close()' "$hp" 2>/dev/null \
    || { WHY="the stub hub never listened"; edown; return 1; }
  printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=tok-drill\nFLEET_ENTRY_PORTMAP=off\n' "$hp" > "$E/db/machine.env"
  chmod 600 "$E/db/machine.env"
  printf 'en0 192.168.1.249/24\nutun4 100.101.2.3/32\n' > "$E/ifaddrs"
  FLEET_ENTRY_IFADDRS="$E/ifaddrs" python3 "$SUP" entry reach >"$E/reach.out" 2>&1
  [ $? = 0 ] || { WHY="entry reach: $(cat "$E/reach.out")"; kill "$hpid" 2>/dev/null; edown; return 1; }
  wait "$hpid" 2>/dev/null
  python3 - "$E/posted.json" "$EPORT" "$E/db/entry/ssh_host_ed25519_key.pub" <<'PY' || { WHY="the report: $(cat "$E/posted.json")"; edown; return 1; }
import json, sys
r = json.load(open(sys.argv[1]))
key = " ".join(open(sys.argv[3]).read().split()[:2])
assert r["listening"] is True and r["port"] == int(sys.argv[2]) and r["host_key"] == key, r
assert r["lan"] == ["192.168.1.249"] and r["v6"] == [] and "portmap" not in r, r
PY
  python3 "$SUP" entry reach --check > "$E/check.out"
  [ $? = 1 ] && grep -q "外面连不上：203.0.114.7:$EPORT 超时" "$E/check.out" \
    && grep -q "公网 TCP $EPORT 转发到 192.168.1.249:$EPORT" "$E/check.out" \
    || { WHY="the doctor's public row: $(cat "$E/check.out")"; edown; return 1; }
  grep -q 'entry reach --check' "$BIN/fleet-doctor.sh" || { WHY="fleet-doctor.sh has no public row"; edown; return 1; }
  etry k1 || { WHY="the entry stopped taking its key after a reach check: $(cat "$E/ssh.err")"; edown; return 1; }
  SECS=$(since "$t0")
  sys_same || { edown; return 1; }
  edown
  WHAT="地址可解析但没人应、或应的是别的钥匙：不进 reachable（只剩真入口 sshd 那一个）；体检 public 行 WARN「外面连不上：… 超时 · 在路由器上把 TCP 端口转发到 192.168.1.249」；入口照常进；$gohalf"
}

drill_entry_forward_out() {
  CAP=20   # the listener + four forwards + one drop
  local t0 dst lp fwd out wid got; local -a eopts
  erig fwd
  eapply "$(elist 1 "$ME=k1")" || { WHY="entry apply failed: $(tail -2 "$E/apply.out")"; edown; return 1; }
  t0=$(now); eup
  until_ok 10 listening || { WHY="the entry sshd never listened"; edown; return 1; }
  eopts=(-F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no
         -o UserKnownHostsFile="$E/known_hosts" -o ConnectTimeout=5 -o LogLevel=ERROR -i "$E/k1" -p "$EPORT")
  # a service on this machine: echoes one line back
  dst=$(free_port)
  python3 -c '
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(4)
while True:
    c, _ = s.accept(); c.sendall(c.recv(64)); c.close()
' "$dst" 2>/dev/null & printf '%s\n' "$!" >> "$WORK/cred-pids"
  until_ok 5 python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1).close()' "$dst" 2>/dev/null \
    || { WHY="the echo service never listened"; edown; return 1; }
  # 1. -W to this machine: through
  out=$(printf 'ping-entry\n' | ssh "${eopts[@]}" -W "127.0.0.1:$dst" "$ME@127.0.0.1" 2>"$E/ssh.err")
  [ "$out" = "ping-entry" ] || { WHY="-W 127.0.0.1:$dst gave [$out]: $(cat "$E/ssh.err")"; edown; return 1; }
  # 2. -L to this machine (fleet open's shape): through
  lp=$(free_port)
  ssh "${eopts[@]}" -N -o ExitOnForwardFailure=yes -L "127.0.0.1:$lp:127.0.0.1:$dst" "$ME@127.0.0.1" 2>"$E/fwd.err" </dev/null &
  fwd=$!; printf '%s\n' "$fwd" >> "$WORK/cred-pids"
  until_ok 5 python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1).close()' "$lp" 2>/dev/null \
    || { WHY="-L never listened: $(cat "$E/fwd.err")"; kill "$fwd" 2>/dev/null; edown; return 1; }
  out=$(python3 -c '
import socket, sys
c = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 3); c.settimeout(3); c.sendall(b"ping-L\n"); print(c.recv(64).decode().strip())
' "$lp" 2>&1)
  kill "$fwd" 2>/dev/null; wait "$fwd" 2>/dev/null
  [ "$out" = "ping-L" ] || { WHY="-L to 127.0.0.1:$dst gave [$out]"; edown; return 1; }
  # 3. anywhere else (a LAN address, a public one): prohibited
  for h in 192.0.2.1 10.255.255.1; do
    ssh "${eopts[@]}" -W "$h:22" "$ME@127.0.0.1" </dev/null >/dev/null 2>"$E/ssh.err" \
      && { WHY="-W $h:22 was let through"; edown; return 1; }
    until_ok 3 grep -q "to connect to host $h port 22, but the request was denied" "$E/log/entry.log" \
      || { WHY="-W $h:22 not denied by the entry: $(cat "$E/ssh.err") $(grep -i "$h" "$E/log/entry.log")"; edown; return 1; }
  done
  # 4. -R: refused
  ssh "${eopts[@]}" -N -o ExitOnForwardFailure=yes -R "127.0.0.1:0:127.0.0.1:$dst" "$ME@127.0.0.1" </dev/null \
    >/dev/null 2>"$E/ssh.err" && { WHY="-R was let through"; edown; return 1; }
  grep -qi 'forwarding failed' "$E/ssh.err" || { WHY="-R: $(cat "$E/ssh.err")"; edown; return 1; }
  SECS=$(since "$t0")
  # 5. a drop over the entry (the thin client's recv): that login's inbox, nowhere else
  mkdir -p "$E/home"; printf 'dropped\n' > "$E/drop.txt"; wid="00000000-0000-4000-8000-000000000001/fid-drop"
  got=$(ssh "${eopts[@]}" "$ME@127.0.0.1" "HOME='$E/home' python3 '$BIN/fleet-client-upload.py' recv - - '$wid' --name drop.txt" \
          <"$E/drop.txt" 2>"$E/ssh.err")
  case "$got" in "$E/home/.cache/claude-fleet/inbox/fid-drop/"*-drop.txt) ;; *) WHY="recv over the entry printed [$got]: $(cat "$E/ssh.err")"; edown; return 1 ;; esac
  cmp -s "$got" "$E/drop.txt" || { WHY="the dropped file differs"; edown; return 1; }
  [ "$(find "$E" -name '*-drop.txt' | wc -l | tr -d ' ')" = 1 ] || { WHY="the drop landed more than once: $(find "$E" -name '*-drop.txt')"; edown; return 1; }
  sys_same || { edown; return 1; }
  edown
  WHAT="入口只放到本机的转发：-W / -L 到 127.0.0.1 通，到 192.0.2.1 / 10.255.255.1 被入口拒（request was denied），-R 被拒；经入口拖进来的文件（fleet-client-upload.py recv）只落进那个登录的 inbox"
}

# dlist <version> <login>=<key>@<pod>[ …] → $E/list-<version>.json, the door's
# table (GET /v1/node/entry-routes): routes + each login's keys
dlist() {
  local v="$1"; shift
  python3 - "$E" "$v" "$@" <<'PY'
import base64, hashlib, json, sys
d, v, specs = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
out = {"version": v, "routes": [], "logins": {}}
for spec in specs:
    login, rest = spec.split("=", 1)
    k, pod = rest.split("@", 1)
    t, b = open("%s/%s.pub" % (d, k)).read().split()[:2]
    fp = "SHA256:" + base64.b64encode(hashlib.sha256(base64.b64decode(b)).digest()).decode().rstrip("=")
    out["routes"].append({"login": login, "principal": "gh:%s" % login, "service": pod})
    out["logins"].setdefault(login, {"person": "gh:%s" % login, "keys": []})["keys"].append(
        {"fp": fp, "type": t, "b64": b, "name": "drill-%s" % k})
json.dump(out, open("%s/list-%d.json" % (d, v), "w"))
PY
  printf '%s/list-%s.json' "$E" "$v"
}
# ddown: the stand-in pods and the door down, the door's variables gone
ddown() {
  pkill -f "$E/u-" 2>/dev/null
  edown
  unset FLEET_DOOR FLEET_DOOR_SECRET FLEET_DOOR_JUMP_USER FLEET_DOOR_TEST_TARGETS
}

drill_door_wrong_pod() {
  CAP=30   # the door on an empty table, two stand-in pods, seven tunnels
  local t0 out; local -a eopts
  erig door
  mkdir -p "$E/rt/bin" "$E/door"; ln -s "$BIN/fleet-door-keys.py" "$E/rt/bin/fleet-door-keys.py"
  # the door's Secret: its host key (and no key to the pods: T647)
  ssh-keygen -q -t ed25519 -N '' -f "$E/door/host_ed25519_key"
  # two stand-in pods that both take alice's key (k1): only the door picks which she reaches
  jpod u-aaaa1 k1 || { jdown; return 1; }; JPA=$PODPORT
  jpod u-bbbb2 k1 || { jdown; return 1; }; JPB=$PODPORT
  export FLEET_DOOR=1 FLEET_DOOR_SECRET="$E/door" FLEET_DOOR_JUMP_USER="$ME" \
    FLEET_DOOR_TEST_TARGETS="u-aaaa1=127.0.0.1:$JPA,u-bbbb2=127.0.0.1:$JPB"
  # 0. nobody's home is a pod yet: the door still listens (its startup probe is tcp),
  #    on its one account, the jump — and lets nobody through
  eapply "$(dlist 1)" || { WHY="door apply failed: $(tail -2 "$E/apply.out")"; jdown; return 1; }
  [ -f "$E/db/entry/sshd_config" ] \
    || { WHY="an empty table took the door's config away — no sshd, the startup probe fails, the pod restarts forever"; jdown; return 1; }
  grep -q "^AllowUsers $ME\$" "$E/db/entry/sshd_config" && grep -q "^Match User $ME\$" "$E/db/entry/sshd_config" \
    || { WHY="the empty door is not the jump account alone: $(grep -E 'AllowUsers|Match' "$E/db/entry/sshd_config")"; jdown; return 1; }
  ! grep -qE 'fleet-door\.sh|FLEET_DOOR_|AcceptEnv|SetEnv|/keys/%u' "$E/db/entry/sshd_config" \
    || { WHY="the door's old per-login road is still in its config: $(grep -E 'fleet-door|FLEET_DOOR|AcceptEnv|SetEnv|keys/' "$E/db/entry/sshd_config")"; jdown; return 1; }
  t0=$(now); eup
  until_ok 10 listening || { WHY="the empty door never listened on its port"; jdown; return 1; }
  out=$(jssh k1 "$JPA") && { WHY="0: the empty door let a key through: [$out]"; jdown; return 1; }
  # 1. alice's route: her key tunnels to her own pod — and the door has no account of hers
  eapply "$(dlist 2 "alice=k1@u-aaaa1")" || { WHY="1: apply: $(tail -2 "$E/apply.out")"; jdown; return 1; }
  out=$(jssh k1 "$JPA")
  [ "$out" = "pod=u-aaaa1" ] || { WHY="1: alice to her pod: [$out] $(cat "$E/ssh.err")"; jdown; return 1; }
  out=$(jssh k1 "$JPB") && { WHY="1: alice's key reached the other pod: [$out]"; jdown; return 1; }
  [ -z "$(ls -A "$E/db/entry/keys" 2>/dev/null)" ] || { WHY="1: the door wrote a per-login keys file: $(ls "$E/db/entry/keys")"; jdown; return 1; }
  out=$(jtry k1 "alice@127.0.0.1" hostname) && { WHY="1: alice logged in at the door itself: [$out]"; jdown; return 1; }
  # 2. the home moves ⇒ the tunnel follows
  eapply "$(dlist 3 "alice=k1@u-bbbb2")" || { WHY="2: apply: $(tail -2 "$E/apply.out")"; jdown; return 1; }
  out=$(jssh k1 "$JPB")
  [ "$out" = "pod=u-bbbb2" ] || { WHY="2: alice to her new pod: [$out] $(cat "$E/ssh.err")"; jdown; return 1; }
  out=$(jssh k1 "$JPA") && { WHY="2: alice still reached her old pod: [$out]"; jdown; return 1; }
  # 3. a login two pods claim ⇒ neither: the door lets it nowhere
  eapply "$(dlist 4 "alice=k1@u-aaaa1" "alice=k1@u-bbbb2")" || :
  for pp in "$JPA" "$JPB"; do
    out=$(jssh k1 "$pp") && { WHY="3: a login two pods claim got in: [$out]"; jdown; return 1; }
  done
  SECS=$(since "$t0")
  sys_same || { jdown; return 1; }
  jdown
  WHAT="门表空时照样监听、只有跳转账号、谁都过不去；alice 的钥匙只能开到她自己的 pod（u-aaaa1），门上没有她的账号、也没写 keys/<登录>；家搬到 u-bbbb2 隧道跟着走、旧 pod 去不了；两个 pod 认领同一登录则哪个也不去"
}

drill_door_hostkey_pod() {
  CAP=60   # the door, two client connects, the hub half's go test
  local t0 out rc kh gohalf
  erig doorkey
  mkdir -p "$E/rt/bin" "$E/door"; ln -s "$BIN/fleet-door-keys.py" "$E/rt/bin/fleet-door-keys.py"
  ssh-keygen -q -t ed25519 -N '' -f "$E/door/host_ed25519_key"
  ssh-keygen -q -t rsa -b 2048 -N '' -C root@buildkitsandbox -f "$E/baked"
  export FLEET_DOOR=1 FLEET_DOOR_SECRET="$E/door" FLEET_DOOR_JUMP_USER="$ME"
  eapply "$(dlist 1)" || { WHY="door apply failed: $(tail -2 "$E/apply.out")"; jdown; return 1; }
  t0=$(now); eup
  until_ok 10 listening || { WHY="the door never listened"; ddown; return 1; }
  kh="$E/fleet-known-hosts"
  # the client writes what the hub lists for u-aaaa1, then ssh checks it under fleet-u-aaaa1
  connect() {  # connect <host key line the hub lists>
    FLEET_KNOWN_HOSTS="$kh" python3 -I - "$BIN/fleet-connect.py" "$1" <<'PY' || return 1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fc", sys.argv[1])
fc = importlib.util.module_from_spec(spec); spec.loader.exec_module(fc)
sys.exit(0 if fc.write_known_hosts({"alias": "u-aaaa1", "host_keys": [sys.argv[2]]}) else 1)
PY
    ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -i "$E/k1" \
        -o HostKeyAlias=fleet-u-aaaa1 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$kh" \
        -o ConnectTimeout=5 -p "$EPORT" "$ME@127.0.0.1" true </dev/null 2>&1
  }
  # the bug: the pod's own (baked) key listed — the door's key is a stranger
  out=$(connect "$(cut -d' ' -f1-2 "$E/baked.pub")")
  case $out in *'HAS CHANGED'*|*'verification failed'*) ;;
    *) WHY="the pod's baked key did not trip ssh's host check — the drill tests nothing: [$out]"; ddown; return 1 ;; esac
  # the fix: the door's key listed — the line under fleet-u-aaaa1 replaced, ssh past the host check
  out=$(connect "$(cut -d' ' -f1-2 "$E/door/host_ed25519_key.pub")")
  case $out in *'HAS CHANGED'*|*'verification failed'*)
    WHY="with the door's key listed ssh still refuses the host: [$out]"; ddown; return 1 ;; esac
  [ "$(grep -c '^fleet-u-aaaa1 ' "$kh")" = 1 ] && ! grep -q ssh-rsa "$kh" \
    || { WHY="the old line was not replaced: $(cat "$kh")"; ddown; return 1; }
  gohalf="hub half: no go toolchain here — the Go gate runs TestDoorRouteListHandsOutTheDoorsHostKey"
  grep -q '^func TestDoorRouteListHandsOutTheDoorsHostKey(' "$ROOT/tokenledger/hub/api/fleet_door_test.go" 2>/dev/null \
    || { WHY="the hub half's test TestDoorRouteListHandsOutTheDoorsHostKey is gone"; ddown; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS='' GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run '^TestDoorRouteListHandsOutTheDoorsHostKey$' ./hub/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go test did not run"; ddown; return 1 ;;
      0:*) gohalf="hub half: go test ok" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"
         ddown; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
  ddown
  WHAT="pod 在门后：fleet-known-hosts 里 fleet-u-aaaa1 记 pod 自己（镜像里）的钥匙 ⇒ 撞「HAS CHANGED」；记门的钥匙 ⇒ 过主机核对、旧行被换掉；$gohalf"
}

# the hub half of a drill: one Go test, when a toolchain is here (else the note)
gotest() {  # gotest <TestName> <file under hub/api> → GOHALF, rc 1 = red
  GOHALF="hub half: no go toolchain here — the Go gate runs $1"
  grep -q "^func $1(" "$ROOT/tokenledger/hub/api/$2" 2>/dev/null \
    || { WHY="the hub half's test $1 is gone"; return 1; }
  [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1 || return 0
  local out rc
  out=$(cd "$ROOT/tokenledger" && GOFLAGS='' GOPROXY=off GOTOOLCHAIN=local \
        go test -count=1 -run "^$1\$" ./hub/api 2>&1); rc=$?
  case "$rc:$out" in
    0:*'no tests to run'*) WHY="the hub half's Go test $1 did not run"; return 1 ;;
    0:*) GOHALF="hub half: go test $1 ok" ;;
    *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
    *) WHY="the hub half (go test $1) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"
       return 1 ;;
  esac
}

drill_door_reach_stale() {
  CAP=60   # the Go test dials a real in-process sshd
  local t0; t0=$(now)
  grep -q 's.doorReachKeep(host, time.Now())' "$ROOT/tokenledger/hub/api/fleet_door.go" \
    || { WHY="handleNodeEntryRoutes no longer re-checks the pulling door"; return 1; }
  gotest TestDoorPullKeepsItsReachFresh fleet_door_reach_test.go || return 1
  SECS=$(since "$t0")
  WHAT="门只在启动时报一次可达：20 分钟后入口里门的地址过期 ⇒ pod 没有门的路由；门来拉表 ⇒ 入口照门的钥匙重拨、路由回来，换了钥匙的不算；$GOHALF"
}

drill_pod_relay_loopback() {
  CAP=30   # one sshd, three logins
  local t0 d port out1 out2 out3 sp
  t0=$(now); d="$EB/podrelay"; rm -rf "$d"; mkdir -p "$d"; chmod 755 "$d"
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  ssh-keygen -q -t ed25519 -N '' -f "$d/host"; ssh-keygen -q -t ed25519 -N '' -f "$d/ca"
  ssh-keygen -q -t ed25519 -N '' -f "$d/user"; ssh-keygen -q -s "$d/ca" -I drill -n "$ME" -V +5m "$d/user.pub"
  ssh-keygen -q -t ed25519 -N '' -f "$d/plain"
  # pod_sshd_text as the pod writes it, its paths moved into the sandbox
  podcfg() {  # podcfg <out> [ca path]
    python3 -I - "$BIN/fleet-node-linux.py" "$d" "$ME" "$port" "$1" "${2:-}" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("lin", sys.argv[1])
lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)
d, me, port, out, ca = sys.argv[2:7]
t = lin.pod_sshd_text(me, "/rt")
for a, b in (("/run/sshd-key/host", d + "/host"), ("Port %d" % lin.POD_SSHD_PORT, "Port " + port),
             ("PidFile none", "PidFile none\nStrictModes no\nListenAddress 127.0.0.1"),
             (lin.POD_KEYS, d + "/authorized_keys"),
             ("/bin/bash /rt/current/bin/fleet-entry.sh", "/bin/echo LANDED"),
             (lin.POD_USER_CA, ca or d + "/ca.pub")):
    t = t.replace(a, b)
t = t.replace("Subsystem sftp /usr/lib/openssh/sftp-server\n", "")
open(out, "w").write(t)
PY
  }
  login() {  # login <cfg> <key> → its last line
    "$SSHD_BIN" -D -e -f "$1" >"$d/sshd.log" 2>&1 & sp=$!
    until_ok 5 python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1",int(sys.argv[1])),1)' "$port" 2>/dev/null
    ssh -F /dev/null -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes -o IdentityAgent=none -o LogLevel=ERROR -o ConnectTimeout=5 -i "$2" "$ME@127.0.0.1" 2>&1 </dev/null | tail -1
    kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  }
  # the bug: the pod's sshd before #4149 (the CA trusted nowhere) — a relayed certificate is refused
  podcfg "$d/old" && sed -i.bak 's/^TrustedUserCAKeys .*/TrustedUserCAKeys none/' "$d/old"
  out1=$(login "$d/old" "$d/user")
  case $out1 in *LANDED*) WHY="a certificate landed on the pod's old sshd — the drill tests nothing: [$out1]"; return 1 ;; esac
  podcfg "$d/new"
  out2=$(login "$d/new" "$d/user")
  case $out2 in *LANDED*) ;; *) WHY="a hub-CA certificate on 127.0.0.1 was refused: [$out2] $(tail -3 "$d/sshd.log")"; return 1 ;; esac
  out3=$(login "$d/new" "$d/plain")
  case $out3 in *LANDED*) WHY="a plain key with no certificate landed on the pod: [$out3]"; return 1 ;; esac
  # one rule on every address (#4193): the pod's own address (the jump's) takes the CA too
  "$SSHD_BIN" -T -f "$d/new" -C "user=$ME,host=x,addr=10.0.0.9,laddr=10.0.0.5,lport=$port" 2>/dev/null \
    | grep -qx "trustedusercakeys $d/ca.pub" \
    || { WHY="the pod's own address does not take the hub's CA"; return 1; }
  SECS=$(since "$t0")
  WHAT="pod 的 sshd：旧配置不认证书（中转永远进不去）；新配置认入口 CA 的证书、不认无证书也不在名单的钥匙，回环和 pod 自己的地址同一条规则（#4193）"
}

# ── the door's jump account (issue #4193, design #4181 A2) ──────────────────
# jrig: the door with its jump account (this login — a non-root sshd lets only
# itself in), alice=k1 → u-aaaa1 and bob=k2 → u-bbbb2, two stand-in pods that
# take their person's OWN key (the new pod rule) and say which pod they are
jpod() {  # jpod <u-nonce> <key> → $PODPORT
  local pod="$1" d="$E/$1"
  mkdir -p "$d"; ssh-keygen -q -t ed25519 -N '' -f "$d/hk"
  cp "$E/$2.pub" "$d/keys"; chmod 644 "$d/keys"
  PODPORT="$(free_port)"
  {
    printf 'Port %s\nListenAddress 127.0.0.1\nHostKey %s/hk\nPidFile %s/pid\nAuthorizedKeysFile %s/keys\n' \
      "$PODPORT" "$d" "$d" "$d"
    printf 'UsePAM no\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n'
    printf 'ForceCommand echo pod=%s\n' "$pod"
  } > "$d/cfg"
  "$SSHD_BIN" -D -e -f "$d/cfg" 2>>"$d/log" &
  printf '%s\n' "$!" >> "$WORK/cred-pids"
  until_ok 10 python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1).close()' "$PODPORT" \
    || { WHY="the stand-in pod $pod never listened: $(tail -2 "$d/log")"; return 1; }
}
jrig() {  # jrig <name>
  erig "$1"
  mkdir -p "$E/rt/bin" "$E/door"
  ln -s "$BIN/fleet-door-keys.py" "$E/rt/bin/fleet-door-keys.py"
  ssh-keygen -q -t ed25519 -N '' -f "$E/door/host_ed25519_key"
  jpod u-aaaa1 k1 || return 1; JPA=$PODPORT
  jpod u-bbbb2 k2 || return 1; JPB=$PODPORT
  export FLEET_DOOR=1 FLEET_DOOR_SECRET="$E/door" FLEET_DOOR_JUMP_USER="$ME" \
    FLEET_DOOR_TEST_TARGETS="u-aaaa1=127.0.0.1:$JPA,u-bbbb2=127.0.0.1:$JPB"
  eapply "$(dlist 1 "alice=k1@u-aaaa1" "bob=k2@u-bbbb2")" || { WHY="door apply failed: $(tail -2 "$E/apply.out")"; return 1; }
  grep -q "^Match User $ME\$" "$E/db/entry/sshd_config" && grep -q '^AuthorizedKeysCommand .*fleet-door-keys.py' "$E/db/entry/sshd_config" \
    || { WHY="the door's config has no jump block: $(tail -3 "$E/apply.out") $(tail -15 "$E/db/entry/sshd_config" 2>/dev/null)"; return 1; }
  eup
  until_ok 10 listening || { WHY="the door's sshd never listened: $(tail -3 "$E/log/entry.log" 2>/dev/null)"; return 1; }
}
jdown() { ddown; unset FLEET_DOOR_JUMP_USER FLEET_DOOR_TEST_TARGETS; }
# jssh <key> <pod port> [cmd] → stdout; ssh's stderr in $E/ssh.err — the client's own
# road: ProxyCommand `ssh -W` through the jump account, the key on both hops
jssh() {
  local k="$1" pp="$2"; shift 2
  local o="-F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
  # shellcheck disable=SC2086  # $o is its own words
  ssh $o -i "$E/$k" -p "$pp" -o "ProxyCommand=ssh $o -i $E/$k -p $EPORT -W %h:%p $ME@127.0.0.1" \
    "$ME@127.0.0.1" "${1:-hostname}" </dev/null 2>"$E/ssh.err"
}
# jtry <key> [ssh args…] → stdout; straight at the door as the jump account
jtry() {
  local k="$1"; shift
  ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR -o ExitOnForwardFailure=yes \
    -i "$E/$k" -p "$EPORT" "$@" </dev/null 2>"$E/ssh.err"
}
jrecord() {  # jrecord <login> <pod>: the door's record has a jump line for it
  python3 -c '
import json, sys
rows = []
for l in open(sys.argv[1]):
    try:
        rows.append(json.loads(l))
    except ValueError:
        pass
sys.exit(0 if any(r.get("kind") == "jump" and r.get("login") == sys.argv[2] and r.get("target") == sys.argv[3]
                  and r.get("fp") for r in rows) else 1)' "$E/log/entry.ndjson" "$1" "$2" 2>/dev/null
}

drill_door_jump_other_pod() {
  CAP=30   # two stand-in pods, the door, four tunnels
  local t0 out; t0=$(now)
  jrig jump-other-pod || { jdown; return 1; }
  # 1. alice's key through the jump ⇒ her own pod, logged in with her own key
  out=$(jssh k1 "$JPA")
  [ "$out" = "pod=u-aaaa1" ] || { WHY="1: alice to her pod: [$out] $(cat "$E/ssh.err")"; jdown; return 1; }
  # 2. alice's key asking for bob's pod ⇒ the door refuses the tunnel
  out=$(jssh k1 "$JPB") && { WHY="2: alice's key reached bob's pod: [$out]"; jdown; return 1; }
  case "$out" in *pod=*) WHY="2: a pod answered [$out]"; jdown; return 1 ;; esac
  grep -qiE 'prohibited|denied|refused|forwarding failed' "$E/ssh.err" || { WHY="2: not the door's refusal: $(cat "$E/ssh.err")"; jdown; return 1; }
  # 3. a tunnel anywhere else (the door's own port) ⇒ refused
  out=$(jtry k1 -W "127.0.0.1:$EPORT" "$ME@127.0.0.1") && { WHY="3: a tunnel to the door's own port: [$out]"; jdown; return 1; }
  # 4. bob ⇒ bob's pod; the record names whose key went where
  out=$(jssh k2 "$JPB")
  [ "$out" = "pod=u-bbbb2" ] || { WHY="4: bob to his pod: [$out] $(cat "$E/ssh.err")"; jdown; return 1; }
  until_ok 10 jrecord bob u-bbbb2 || { WHY="4: the door's record: $(tail -3 "$E/log/entry.ndjson" 2>/dev/null)"; jdown; return 1; }
  SECS=$(since "$t0")
  sys_same || { jdown; return 1; }
  jdown
  WHAT="门的跳转账号：alice 的钥匙只能开到 u-aaaa1:22 的隧道（经 ProxyCommand ssh -W 用她自己的钥匙登进她的 pod），要 bob 的 pod / 门自己的端口被门拒；bob 到 u-bbbb2；门的记录写 指纹 → 谁 → 哪个 pod"
}

drill_door_jump_shell() {
  CAP=25   # the door, four asks
  local t0 out; t0=$(now)
  jrig jump-shell || { jdown; return 1; }
  # a session, a terminal, a command, a remote forward — none of them gets anything
  out=$(jtry k1 "$ME@127.0.0.1") && { WHY="a session ran: [$out]"; jdown; return 1; }
  [ -z "$out" ] || { WHY="a session answered: [$out]"; jdown; return 1; }
  out=$(jtry k1 -tt "$ME@127.0.0.1") && { WHY="a terminal ran: [$out]"; jdown; return 1; }
  case "$out" in *[a-z]*pod*|*Last*) WHY="a terminal answered: [$out]"; jdown; return 1 ;; esac
  out=$(jtry k1 "$ME@127.0.0.1" hostname) && { WHY="a command ran: [$out]"; jdown; return 1; }
  [ -z "$out" ] || { WHY="a command answered: [$out]"; jdown; return 1; }
  out=$(jtry k1 -N -R 0:127.0.0.1:22 "$ME@127.0.0.1") && { WHY="a remote forward held: [$out]"; jdown; return 1; }
  SECS=$(since "$t0")
  sys_same || { jdown; return 1; }
  jdown
  WHAT="门的跳转账号：要会话 / 要终端 / 跑命令 / 反向转发 一律没有输出、非零退出（ForceCommand /usr/bin/false + restrict）"
}

drill_door_jump_unlisted() {
  CAP=25   # the door, an unlisted key, a removed key
  local t0 out n; t0=$(now)
  jrig jump-unlisted || { jdown; return 1; }
  # a key the book does not list ⇒ 0 Accepted for it
  out=$(jssh k3 "$JPA") && { WHY="an unlisted key went through: [$out]"; jdown; return 1; }
  n=$(grep -c "Accepted publickey for $ME .*$(ssh-keygen -l -f "$E/k3.pub" | awk '{ print $2 }')" "$E/log/entry.log" 2>/dev/null)
  [ "${n:-0}" = 0 ] || { WHY="the unlisted key was accepted $n time(s)"; jdown; return 1; }
  # alice's key leaves the list ⇒ her jump is gone at the next pass
  eapply "$(dlist 2 "bob=k2@u-bbbb2")" || { WHY="apply v2: $(tail -2 "$E/apply.out")"; jdown; return 1; }
  out=$(jssh k1 "$JPA") && { WHY="a key gone from the list still jumps: [$out]"; jdown; return 1; }
  [ ! -e "$E/db/entry/jump-keys/alice" ] || { WHY="alice's jump keys file stayed"; jdown; return 1; }
  SECS=$(since "$t0")
  sys_same || { jdown; return 1; }
  jdown
  WHAT="门的跳转账号：书里没有的钥匙 0 次放行；钥匙从入口的名单上撤下，下一轮门上的跳转钥匙文件就没了、再也开不了隧道"
}

drill_pod_foreign_key() {
  CAP=25   # one sshd, six logins
  local t0 d port sp k out bad=""; t0=$(now); d="$EB/podforeign"; rm -rf "$d"; mkdir -p "$d"; chmod 755 "$d"
  port=$(free_port)
  ssh-keygen -q -t ed25519 -N '' -f "$d/host"; ssh-keygen -q -t ed25519 -N '' -f "$d/ca"
  for k in mine other door certme certother; do ssh-keygen -q -t ed25519 -N '' -f "$d/$k"; done
  ssh-keygen -q -s "$d/ca" -I drill -n "$ME" -V +5m "$d/certme.pub"
  ssh-keygen -q -s "$d/ca" -I drill -n someoneelse -V +5m "$d/certother.pub"
  cp "$d/mine.pub" "$d/authorized_keys"; chmod 644 "$d"/*.pub "$d/authorized_keys"
  python3 -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("lin", sys.argv[1])
lin = importlib.util.module_from_spec(spec); spec.loader.exec_module(lin)
d, me, port = sys.argv[2:5]
t = lin.pod_sshd_text(me, "/rt")
for a, b in (("/run/sshd-key/host", d + "/host"), ("Port %d" % lin.POD_SSHD_PORT, "Port " + port),
             ("PidFile none", "PidFile none\nStrictModes no\nListenAddress 127.0.0.1"),
             (lin.POD_KEYS, d + "/authorized_keys"),
             ("/bin/bash /rt/current/bin/fleet-entry.sh", "/bin/echo LANDED"), (lin.POD_USER_CA, d + "/ca.pub"),
             # a non-root sshd cannot become nobody to run the keys command
             ("AuthorizedKeysCommandUser nobody", "AuthorizedKeysCommandUser " + me)):
    t = t.replace(a, b)
open(d + "/cfg", "w").write(t.replace("Subsystem sftp /usr/lib/openssh/sftp-server\n", ""))' \
    "$BIN/fleet-node-linux.py" "$d" "$ME" "$port"
  "$SSHD_BIN" -D -e -f "$d/cfg" >"$d/sshd.log" 2>&1 & sp=$!
  printf '%s\n' "$sp" >> "$WORK/cred-pids"
  until_ok 5 python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1",int(sys.argv[1])),1)' "$port" 2>/dev/null
  plog() {  # plog <key> [login] → its last line
    ssh -F /dev/null -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes -o IdentityAgent=none -o LogLevel=ERROR -o ConnectTimeout=5 -i "$d/$1" "${2:-$ME}@127.0.0.1" \
        2>&1 </dev/null | tail -1
  }
  for k in mine certme; do
    out=$(plog "$k"); case $out in *LANDED*) ;; *) bad="$bad $k refused [$out]" ;; esac
  done
  # the door's old key is a stranger now (T647): the door logs in nowhere
  for k in other certother door; do
    out=$(plog "$k"); case $out in *LANDED*) bad="$bad $k LANDED" ;; esac
  done
  out=$(plog mine root); case $out in *LANDED*) bad="$bad root LANDED" ;; esac
  kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  [ -z "$bad" ] || { WHY="the pod's sshd:$bad — $(tail -3 "$d/sshd.log")"; return 1; }
  SECS=$(since "$t0")
  WHAT="pod 的 sshd（#4193 一条规则）：本人钥匙、本人主体名的入口证书能进；别人的钥匙、别人主体名的证书、门的旧钥匙、本人钥匙换 root 一律进不来"
}

drill_door_jump_two_replicas() {
  CAP=150   # the hub half's go tests: two replicas over one store
  local t0 out rc f gohalf t
  local tests='TestDoorJumpReadinessAcrossReplicas|TestEntryMachineAuthorizationAcrossReplicas|TestDoorJumpSaysWhichEndIsMissing'
  t0=$(now)
  f="$ROOT/tokenledger/hub/api/fleet_door_jump_replica_test.go"
  for t in TestDoorJumpReadinessAcrossReplicas TestEntryMachineAuthorizationAcrossReplicas TestDoorJumpSaysWhichEndIsMissing; do
    grep -q "^func $t(" "$f" 2>/dev/null || { WHY="the hub half's test $t is gone"; return 1; }
  done
  gohalf="no go toolchain here — the Go gate (tokenledger.yml) runs the two-replica tests"
  go_half "^($tests)\$" ./hub/api; case $? in 0) gohalf="go test ok" ;; 1) return 1 ;; esac
  SECS=$(since "$t0")
  WHAT="入口两副本：pod 的链路在 A，它拉钥匙落到 B 照样 200、普通登录两边都 403；门和 pod 的就绪两副本都看得到、过期不算、重启不丢；路线不带 jump 时说出缺哪一头；$gohalf"
}

# The door-session drills (A5SQ): the hub half is the whole of them for now —
# the door's own SSH server lands in a later PR and adds its legs here.
door_session_go() {  # door_session_go <Go test> <what it proves>
  local t0 gohalf; t0=$(now)
  grep -q "^func $1(" "$ROOT/tokenledger/hub/api/fleet_door_home_test.go" 2>/dev/null \
    || { WHY="the hub half's test $1 is gone"; return 1; }
  gohalf="no go toolchain here — the Go gate (tokenledger.yml) runs $1"
  go_half "^$1\$" ./hub/api; case $? in 0) gohalf="go test $1 ok" ;; 1) return 1 ;; esac
  SECS=$(since "$t0")
  WHAT="$2；$gohalf"
}

drill_door_session_no_sig() {
  CAP=150
  door_session_go TestDoorSessionNeedsTheirSignature \
    "门会话证书只凭本人这次登录的签名：门用自己的钥匙签、签名换会话、换用户名、没有签名、不是门的令牌都拒；证书只一个主体名、两分钟、只许回环、门会话 CA 签"
}

drill_door_session_replay() {
  CAP=150
  door_session_go TestDoorSessionOnce "同一份签名第二次（换一把临时钥匙也一样）409，落库的会话标识两副本共用"
}

drill_door_home_not_door() {
  CAP=150
  door_session_go TestDoorHomeStreamOnlyTheDoor "接到家的流只认门的令牌、只到家在机器上的人，落在家的本机入口端口（target=entry）"
}

# bin/entry-e2e-selftest.sh (issue #3076) sources the rig above and runs its own legs
[ -n "${BREAK_ENTRY_LIB:-}" ] && return 0
cred_run_drills "$0"
