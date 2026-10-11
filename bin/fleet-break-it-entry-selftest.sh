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
#
# Each prints `PASS <id> <secs>s ≤<cap>s <what came back>` like its parent.
# No sshd / ssh / ssh-keygen here → SKIP (exit 0).
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
    FLEET_ENTRY_SSHD FLEET_ENTRY_DSEDITGROUP
}
# elist <version> <login>=<key>[,<key>…] … → $E/list-<version>.json, the hub's shape
elist() {
  local v="$1"; shift
  python3 - "$E" "$v" "$@" <<'PY'
import json, sys
d, v, specs = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
out = {"version": v, "logins": {}}
for spec in specs:
    login, keys = spec.split("=", 1)
    ks = []
    for k in keys.split(","):
        t, b = open("%s/%s.pub" % (d, k)).read().split()[:2]
        ks.append({"fp": "SHA256:%s" % k, "type": t, "b64": b})
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
    || { WHY="~/.ssh/environment or ~/.ssh/rc honoured"; edown; return 1; }
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

cred_run_drills "$0"
