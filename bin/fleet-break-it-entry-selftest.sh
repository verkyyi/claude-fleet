#!/bin/bash
# fleet-break-it-entry-selftest.sh — docs/BREAK-IT.md's entry-* rows (issue #3070,
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
  # an hour on, the doctor's row says how far behind
  python3 - "$E/db/entry/state.json" <<'PY'
import json, sys, time
b = json.load(open(sys.argv[1])); b["hub_version_at"] = time.time() - 3700
json.dump(b, open(sys.argv[1], "w"))
PY
  python3 "$SUP" entry status --check > "$E/check.out"
  [ $? = 1 ] && grep -q '入口 v5 · 本机 v4' "$E/check.out" && grep -q '落后入口一小时以上' "$E/check.out" \
    || { WHY="the doctor's entry row: $(cat "$E/check.out")"; edown; return 1; }
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
  grep -q '^func TestEntryReachUnreachableNotRecorded(' "$ROOT/tokenledger/internal/api/fleet_entry_reach_test.go" 2>/dev/null \
    || { WHY="the hub half's test TestEntryReachUnreachableNotRecorded is gone"; edown; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && FLEET_DRILL_ENTRY="$EPORT $E/db/entry/ssh_host_ed25519_key.pub" \
          GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run '^TestEntryReachUnreachableNotRecorded$' ./internal/api 2>&1); rc=$?
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

# bin/entry-e2e-selftest.sh (issue #3076) sources the rig above and runs its own legs
[ -n "${BREAK_ENTRY_LIB:-}" ] && return 0
cred_run_drills "$0"
