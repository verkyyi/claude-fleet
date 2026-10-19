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
#   fleetadmin-token-misissued bin/fleet_admin_seat.py agent + the hub's
#                             /v1/node/admin-token (Go TestNodeAdminToken)
#   admin-handover-cut-op     bin/fleet-node-supervisor.py admin-handover (the
#                             sweep's) + bin/fleet_admin_seat.py seat_connected —
#                             the cases of bin/fleet-admin-handover-selftest.py
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

# fleetadmin-token-misissued (#3724): the seat's own token. The machine half —
# the token lands root:<role> 0640, never in the unit; a world-readable or linked
# token file is drift and is not used — then the hub half (Go TestNodeAdminToken):
# a login's token, a person's login name, a name the hub does not count as admin
# are refused; a machine named in the body is ignored; one audit line each.
drill_fleetadmin_token_misissued() {
  CAP=120
  local sb st root units tok t0 out rc unit gohalf me
  sb="$WORK/token"; st="$sb/state"; root="$sb/root"; units="$sb/units"; me="$(id -un)"
  mkdir -p "$st/admin" "$root/agent" "$units"
  printf '#!/bin/sh\nexit 0\n' > "$root/agent/ccquota"; chmod 755 "$root/agent/ccquota"
  printf '#!/bin/sh\nexit 0\n' > "$sb/svc"; chmod 755 "$sb/svc"
  tok="ccq_$(python3 -c 'print("B" * 43)')"
  t0=$(now)
  seat() {
    FLEET_NODE_TEST=1 FLEET_NODE_STATE="$st" FLEET_NODE_ROOT="$root" FLEET_ADMIN_ROLE="$me" \
      FLEET_ADMIN_UNIT_DIR="$units" FLEET_ADMIN_SVC_CMD="$sb/svc" python3 -I "$BIN/fleet_admin_seat.py" "$@"
  }
  out=$(printf '%s\n' "$tok" | seat agent --hub http://127.0.0.1:9 --token-stdin 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="agent: rc $rc: $out"; return 1; }
  unit=$(ls "$units"/* | head -n 1)
  ! grep -q "$tok" "$unit" || { WHY="the token is in the unit $unit"; return 1; }
  grep -q "CCQUOTA_TOKEN_FILE" "$unit" || { WHY="the unit names no token file"; return 1; }
  [ "$(python3 -c 'import os,sys; print(oct(os.lstat(sys.argv[1]).st_mode & 0o777))' "$st/admin/agent.token")" = 0o640 ] \
    || { WHY="token file mode: $(ls -l "$st/admin/agent.token")"; return 1; }
  # someone makes it world-readable, then a link to it: drift, and it is not used
  chmod 644 "$st/admin/agent.token"
  seat status --check >/dev/null 2>&1 && { WHY="a world-readable token file is not drift"; return 1; }
  out=$(seat agent --hub http://127.0.0.1:9 --check 2>&1); rc=$?
  [ "$rc" = 4 ] || { WHY="a world-readable token was still used (rc $rc: $out)"; return 1; }
  mv "$st/admin/agent.token" "$sb/elsewhere.token"; chmod 640 "$sb/elsewhere.token"
  ln -s "$sb/elsewhere.token" "$st/admin/agent.token"
  out=$(seat agent --hub http://127.0.0.1:9 --check 2>&1); rc=$?
  [ "$rc" = 4 ] || { WHY="a linked token file was used (rc $rc: $out)"; return 1; }
  # the hub half
  gohalf="入口一半：此处没有 Go 工具链，由 Go 门（tokenledger.yml）跑 TestNodeAdminToken"
  grep -q '^func TestNodeAdminToken(' "$ROOT/tokenledger/internal/api/fleet_admin_token_test.go" 2>/dev/null \
    || { WHY="the hub half's test TestNodeAdminToken is gone"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOWORK=off GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run '^TestNodeAdminToken$' ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go test did not run"; return 1 ;;
      0:*) gohalf="入口一半：go test 登录的令牌 · 个人登录名 · 没认作管理员的名字都拒、请求体里的机器名不认、一次一行审计" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | grep -v '^20' | head -6 | tr '\n' ' ')"
         return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
  WHAT="座位的令牌落成 root:角色组 0640、单元里只有文件路径；改成人人可读、换成链接都报 DRIFT 且不再被用；${gohalf}"
}

# admin-handover-cut-op (#3725): hand the admin login's old agent over at the wrong
# moment — before the seat's own agent is connected (the hub says not connected,
# refuses its token, there is none), while its book holds an op (inflight, a result
# not yet acked in its outbox, a book that cannot be read), and with an op landing
# between the read and the bootout. Each must leave the old agent running (put back
# in the last case); only a connected seat and an empty book hand it over, into the
# attic, and `attic restore` brings it back.
drill_admin_handover_cut_op() {
  CAP=90
  local t0 out rc
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-admin-handover-selftest.py" \
        Handover.test_b_seat_not_connected Handover.test_c_book_not_empty_or_unreadable \
        Handover.test_e_op_arrives_while_stopping Handover.test_d_handed_over_and_restored 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="$(printf '%s' "$out" | grep -E '^(FAIL|ERROR|AssertionError)' | head -4 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="座位 agent 没连上（入口说没连、拒令牌、没令牌）、旧 agent 的 account-ops.json 还有单（进行中 / 没确认的结果 / 读不了）都不动它；停的那一刻来了单就放回；连上且簿子空了才 bootout 进 attic，attic restore 能回去"
}

cred_run_drills "$0"
