#!/bin/bash
# fleet-break-it-admin-selftest.sh — the docs/dev/BREAK-IT.md row of the admin seat's
# two root scripts (issue #3557, EPIC #3500 C15 · 共同约定 11): the drill builds
# the admin directory the way the seat's installer lays it out — the gate
# (bin/fleet-admin-gate.sh) copied under both names, admin.conf, the hub's
# account key — and a release bin/ whose fleet-login-remove.sh / -new.sh only
# record that they ran. Then it does what a compromised _fleetadmin would: run
# the remove with no ticket, a forged one, a replayed one, an expired one, one
# for another login / machine / op, and a good one with an extra flag. Every one
# must be refused before the script runs ("the login is still there"); the
# hub's own ticket, once, runs it. Runner and timing helpers are
# bin/fleet-break-it-cred-selftest.sh's (BREAK_CRED_LIB=1);
# bin/fleet-break-it-selftest.sh's lockstep lint reads the drill names here too.
#
#   fleetadmin-forged-op      bin/fleet-admin-gate.sh + bin/fleet_admin_ticket.py
#   fleetadmin-gate-tampered  bin/fleet_admin_seat.py place (the core's switch /
#                             rollback, bin/fleet-node-core.py place_admin_gate)
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

# admin_sandbox <dir> — <dir>/admin (the gate twice, admin.conf, account.pub) and
# <dir>/rel/bin (the release's scripts: each appends its argv to <dir>/ran)
admin_sandbox() {
  local sb="$1" s
  mkdir -p "$sb/admin" "$sb/rel/bin"
  for s in fleet-login-new.sh fleet-login-remove.sh; do
    cp "$BIN/fleet-admin-gate.sh" "$sb/admin/$s"
    printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> %q\n' "$s" "$sb/ran" > "$sb/rel/bin/$s"
    chmod +x "$sb/admin/$s" "$sb/rel/bin/$s"
  done
  cp "$BIN/fleet_admin_ticket.py" "$BIN/fleet_ed25519.py" "$sb/rel/bin/"
  printf 'bin=%s\nmachine=mac-a\n' "$sb/rel/bin" > "$sb/admin/admin.conf"
  tk pub "$sb/key" > "$sb/admin/account.pub"
  : > "$sb/ran"
}

# tk pub <seed-file> | tk sign <seed-file> <op> <login> <machine> <nonce> <exp> —
# the hub's side (the Go twin is control.SignAccountTicket; its test pins one
# ticket both make byte for byte)
tk() {
  python3 - "$BIN" "$@" <<'PY'
import base64, json, os, sys
sys.path.insert(0, sys.argv[1])
import fleet_ed25519 as e
cmd, keyf = sys.argv[2], sys.argv[3]
if not os.path.exists(keyf):
    open(keyf, "wb").write(os.urandom(32))
seed = open(keyf, "rb").read()
if cmd == "pub":
    print("ed25519 " + base64.b64encode(e.public_key(seed)).decode())
    sys.exit(0)
op, login, machine, nonce, exp = sys.argv[4:9]
payload = json.dumps({"op": op, "login": login, "machine": machine, "nonce": nonce, "exp": int(exp)},
                     separators=(",", ":")).encode()
enc = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
print("v1." + enc(payload) + "." + enc(e.sign(seed, b"fleet-account-ticket-v1\x00" + payload)))
PY
}

# remove <dir> <args…> — the seat's sudo of the remove script; sets RC and OUT
remove() {
  local sb="$1"; shift
  OUT=$("$sb/admin/fleet-login-remove.sh" "$@" 2>&1)
  RC=$?
}

# fleetadmin-forged-op (#3557): with _fleetadmin in hand, run the remove script
# with no ticket, a forged one (another key), one for another login / machine /
# op, an expired one, a good one with a flag the agent never sends — each
# refused (3) before the script runs, the login still there. The hub's ticket
# runs it once; the same ticket again is a replay, refused.
drill_fleetadmin_forged_op() {
  CAP=30
  local sb t0 exp n good
  sb="$WORK/admin"; admin_sandbox "$sb"
  exp=$(( $(date +%s) + 600 ))
  n=0123456789abcdef0123456789abcdef
  good=$(tk sign "$sb/key" remove alice mac-a "$n" "$exp")
  t0=$(now)
  local why ticket
  while IFS='|' read -r why ticket; do
    remove "$sb" --ticket "$ticket" alice --keep-home --apply
    [ "$RC" = 3 ] && [ ! -s "$sb/ran" ] || { WHY="$why: rc $RC, ran: $(cat "$sb/ran"): $OUT"; return 1; }
  done <<EOF
forged|$(tk sign "$sb/other" remove alice mac-a "$n" "$exp")
another login|$(tk sign "$sb/key" remove bob mac-a "$n" "$exp")
another machine|$(tk sign "$sb/key" remove alice mac-b "$n" "$exp")
a create's ticket|$(tk sign "$sb/key" create alice mac-a "$n" "$exp")
a recycle's ticket|$(tk sign "$sb/key" reset alice mac-a "$n" "$exp")
expired|$(tk sign "$sb/key" remove alice mac-a "$n" "$(( $(date +%s) - 1 ))")
not a ticket|--pub
EOF
  remove "$sb" alice --keep-home --apply
  [ "$RC" = 2 ] && [ ! -s "$sb/ran" ] || { WHY="no ticket at all: rc $RC: $OUT"; return 1; }
  remove "$sb" --ticket "$good" alice --keep-home --archive-dir /tmp/x --apply
  [ "$RC" = 3 ] && [ ! -s "$sb/ran" ] || { WHY="a good ticket with an extra flag: rc $RC: $OUT"; return 1; }
  # the refusals spent nothing: the hub's ticket still runs it — once
  remove "$sb" --ticket "$good" alice --keep-home --apply
  [ "$RC" = 0 ] && [ "$(cat "$sb/ran")" = 'fleet-login-remove.sh alice --keep-home --apply' ] \
    || { WHY="the hub's own ticket: rc $RC, ran: $(cat "$sb/ran"): $OUT"; return 1; }
  : > "$sb/ran"
  remove "$sb" --ticket "$good" alice --keep-home --apply
  [ "$RC" = 3 ] && [ ! -s "$sb/ran" ] && printf '%s' "$OUT" | grep -q 'already used' \
    || { WHY="a replay of the used ticket: rc $RC, ran: $(cat "$sb/ran"): $OUT"; return 1; }
  # the recycle mode is the same script; its own ticket says reset
  remove "$sb" --ticket "$(tk sign "$sb/key" reset alice mac-a fedcba9876543210fedcba9876543210 "$exp")" alice --recycle --keep-home --apply </dev/null
  [ "$RC" = 0 ] && grep -q -- '--recycle' "$sb/ran" || { WHY="a recycle with its own ticket: rc $RC: $OUT"; return 1; }
  # a create (#3696): the script gets a clean environment the gate makes — the
  # ticket's nonce as its op id, admin.conf's hub, the join code from stdin —
  # never the caller's; a second stdin line or a non-code is refused
  printf '#!/bin/bash\nprintf "new %%s op=%%s code=%%s hub=%%s evil=%%s\\n" "$*" "$FLEET_LOGIN_OP_ID" "${FLEET_LOGIN_JOIN_CODE:-}" "${FLEET_LOGIN_HUB:-}" "${EVIL:-}" >> %q\n' "$sb/ran" > "$sb/rel/bin/fleet-login-new.sh"
  printf 'hub=https://hub.example\n' >> "$sb/admin/admin.conf"
  local cn=11111111111111111111111111111111 code=fj_abcdefghijklmnopqrstuvwxyz
  : > "$sb/ran"
  OUT=$(printf 'FLEET_LOGIN_JOIN_CODE=%s\nFLEET_LOGIN_HUB=https://evil\n' "$code" | "$sb/admin/fleet-login-new.sh" \
        --ticket "$(tk sign "$sb/key" create carol mac-a "$cn" "$exp")" carol --full-name Carol --share-pool --apply 2>&1); RC=$?
  [ "$RC" = 3 ] && [ ! -s "$sb/ran" ] || { WHY="a second stdin line: rc $RC: $OUT"; return 1; }
  OUT=$(printf 'FLEET_LOGIN_JOIN_CODE=nope\n' | "$sb/admin/fleet-login-new.sh" \
        --ticket "$(tk sign "$sb/key" create carol mac-a "$cn" "$exp")" carol --full-name Carol --share-pool --apply 2>&1); RC=$?
  [ "$RC" = 3 ] && [ ! -s "$sb/ran" ] || { WHY="a non-code on stdin: rc $RC: $OUT"; return 1; }
  OUT=$(printf 'FLEET_LOGIN_JOIN_CODE=%s\n' "$code" | EVIL=1 FLEET_LOGIN_OP_ID=ffff "$sb/admin/fleet-login-new.sh" \
        --ticket "$(tk sign "$sb/key" create carol mac-a "$cn" "$exp")" carol --full-name Carol --share-pool --apply 2>&1); RC=$?
  [ "$RC" = 0 ] && [ "$(cat "$sb/ran")" = "new carol --full-name Carol --share-pool --apply op=$cn code=$code hub=https://hub.example evil=" ] \
    || { WHY="a create's environment: rc $RC, ran: $(cat "$sb/ran"): $OUT"; return 1; }
  # a create that fails after making the login (#3696): the gate rolls it back
  # itself — only when the login's mark names THIS op — and keeps the create's exit
  local me rn=22222222222222222222222222222222
  me=$(id -un)
  printf '#!/bin/bash\nmkdir -p "$FLEET_LOGIN_ADMIN_DIR/$1-onboard"\nprintf "op=%%s\\n" "${MARKOP:-$FLEET_LOGIN_OP_ID}" > "$FLEET_LOGIN_ADMIN_DIR/$1-onboard/op"\nexit 1\n' > "$sb/rel/bin/fleet-login-new.sh"
  : > "$sb/ran"
  OUT=$("$sb/admin/fleet-login-new.sh" --ticket "$(tk sign "$sb/key" create "$me" mac-a "$rn" "$exp")" "$me" --full-name X --share-pool --apply </dev/null 2>&1); RC=$?
  [ "$RC" = 1 ] && [ "$(cat "$sb/ran")" = "fleet-login-remove.sh $me --keep-home --apply" ] && printf '%s' "$OUT" | grep -q "rolled back: login $me" \
    || { WHY="a failed create the gate should roll back: rc $RC, ran: $(cat "$sb/ran"): $OUT"; return 1; }
  : > "$sb/ran"
  printf 'op=33333333333333333333333333333333\n' > "$sb/admin/$me-onboard/op"
  sed -i.bak 's/^printf "op=.*/:/' "$sb/rel/bin/fleet-login-new.sh"
  OUT=$("$sb/admin/fleet-login-new.sh" --ticket "$(tk sign "$sb/key" create "$me" mac-a 44444444444444444444444444444444 "$exp")" "$me" --full-name X --share-pool --apply </dev/null 2>&1); RC=$?
  [ "$RC" = 1 ] && [ ! -s "$sb/ran" ] || { WHY="a failed create whose mark is another op's was rolled back: rc $RC, ran: $(cat "$sb/ran")"; return 1; }
  # and the gate under any other name runs nothing
  : > "$sb/ran"
  cp "$sb/admin/fleet-login-remove.sh" "$sb/admin/fleet-login-reset.sh"
  OUT=$("$sb/admin/fleet-login-reset.sh" --ticket "$good" alice --apply 2>&1); RC=$?
  SECS=$(since "$t0")
  [ "$RC" = 3 ] && [ ! -s "$sb/ran" ] || { WHY="the gate under another name: rc $RC: $OUT"; return 1; }
  WHAT="以 _fleetadmin 跑删号脚本：不带单 / 伪造单 / 别人的单（登录·机器·操作不对）/ 过期 / 多一个参数 / 重放用过的单，全部拒绝、脚本没跑、登录还在；入口签的单只跑一次"
}

# fleetadmin-gate-tampered (#3696): someone got at <state>/admin/ — the remove
# copy is a link to their script, the new copy is theirs at 0777, admin.conf's
# bin= names their dir, used/ is a link. The next switch (the core's place step,
# from the release it just verified) puts every one back: both names the
# release's gate, regular files 0755, admin.conf bin=<root>/current/bin, used/ a
# real 0700 dir — and the hub's ticket then runs the RELEASE's script, never
# theirs. A machine that never set the seat up gets nothing.
drill_fleetadmin_gate_tampered() {
  CAP=30
  local sb st root rel evil t0 exp mode
  sb="$WORK/gate"; st="$sb/state"; root="$sb/root"; rel="$root/$(printf 'a%.0s' $(seq 40))"
  mkdir -p "$st/admin" "$rel/bin" "$sb/evil" "$sb/elsewhere"
  ln -s "$rel" "$root/current"
  cp "$BIN/fleet-admin-gate.sh" "$BIN/fleet_admin_ticket.py" "$BIN/fleet_ed25519.py" "$rel/bin/"
  for s in fleet-login-new.sh fleet-login-remove.sh; do
    printf '#!/bin/bash\nprintf "%%s %%s\\n" release-%s "$*" >> %q\n' "$s" "$sb/ran" > "$rel/bin/$s"
    printf '#!/bin/bash\necho pwned >> %q\n' "$sb/ran" > "$sb/evil/$s"
    chmod +x "$rel/bin/$s" "$sb/evil/$s"
  done
  cp "$BIN/fleet_ed25519.py" "$BIN/fleet_admin_ticket.py" "$sb/evil/"
  tk pub "$sb/key" > "$st/admin/account.pub"
  : > "$sb/ran"
  export FLEET_NODE_TEST=1
  # the tampering
  ln -s "$sb/evil/fleet-login-remove.sh" "$st/admin/fleet-login-remove.sh"
  cp "$sb/evil/fleet-login-new.sh" "$st/admin/fleet-login-new.sh"; chmod 777 "$st/admin/fleet-login-new.sh"
  printf 'bin=%s\nmachine=mac-a\n' "$sb/evil" > "$st/admin/admin.conf"
  ln -s "$sb/elsewhere" "$st/admin/used"
  t0=$(now)
  OUT=$(FLEET_NODE_STATE="$st" FLEET_NODE_ROOT="$root" python3 -I "$BIN/fleet_admin_seat.py" place --release "$rel" 2>&1) \
    || { WHY="place: $OUT"; return 1; }
  for s in fleet-login-new.sh fleet-login-remove.sh; do
    [ -f "$st/admin/$s" ] && [ ! -L "$st/admin/$s" ] && cmp -s "$st/admin/$s" "$BIN/fleet-admin-gate.sh" \
      || { WHY="$s is not the release's gate after the switch: $(ls -l "$st/admin/$s")"; return 1; }
    mode=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode)))' "$st/admin/$s")
    [ "$mode" = 0o755 ] || { WHY="$s mode $mode"; return 1; }
  done
  [ "$(cat "$st/admin/admin.conf")" = "bin=$root/current/bin" ] || { WHY="admin.conf: $(cat "$st/admin/admin.conf")"; return 1; }
  [ -d "$st/admin/used" ] && [ ! -L "$st/admin/used" ] || { WHY="used/ is still a link"; return 1; }
  # the hub's ticket now runs the release's script (machine = this host: admin.conf names none)
  exp=$(( $(date +%s) + 600 ))
  OUT=$("$st/admin/fleet-login-remove.sh" --ticket "$(tk sign "$sb/key" remove alice "$(python3 -c 'import socket; print(socket.gethostname())')" \
        0123456789abcdef0123456789abcdef "$exp")" alice --keep-home --apply 2>&1); RC=$?
  [ "$RC" = 0 ] && [ "$(cat "$sb/ran")" = 'release-fleet-login-remove.sh alice --keep-home --apply' ] \
    || { WHY="after the switch the ticket ran: $(cat "$sb/ran") (rc $RC: $OUT)"; return 1; }
  # a machine that never set the seat up gets nothing
  mkdir -p "$sb/bare"
  FLEET_NODE_STATE="$sb/bare" FLEET_NODE_ROOT="$root" python3 -I "$BIN/fleet_admin_seat.py" place --release "$rel" >/dev/null 2>&1
  SECS=$(since "$t0")
  [ ! -e "$sb/bare/admin" ] || { WHY="place made admin/ on a machine with no seat"; return 1; }
  WHAT="admin/ 下的两个名字被换成链接 / 别人的脚本 / 0777、admin.conf 指到别处、used/ 换成链接：下一次切换都按刚验过签的发布版放回，入口的单只跑发布版的脚本；没设座位的机器什么都不放"
}

cred_run_drills "$0"
