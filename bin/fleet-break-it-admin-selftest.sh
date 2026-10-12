#!/bin/bash
# fleet-break-it-admin-selftest.sh — the docs/BREAK-IT.md row of the admin seat's
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
#   fleetadmin-forged-op  bin/fleet-admin-gate.sh + bin/fleet_admin_ticket.py
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
  remove "$sb" --ticket "$(tk sign "$sb/key" reset alice mac-a fedcba9876543210fedcba9876543210 "$exp")" alice --recycle --keep-home --apply
  [ "$RC" = 0 ] && grep -q -- '--recycle' "$sb/ran" || { WHY="a recycle with its own ticket: rc $RC: $OUT"; return 1; }
  # and the gate under any other name runs nothing
  : > "$sb/ran"
  cp "$sb/admin/fleet-login-remove.sh" "$sb/admin/fleet-login-reset.sh"
  OUT=$("$sb/admin/fleet-login-reset.sh" --ticket "$good" alice --apply 2>&1); RC=$?
  SECS=$(since "$t0")
  [ "$RC" = 3 ] && [ ! -s "$sb/ran" ] || { WHY="the gate under another name: rc $RC: $OUT"; return 1; }
  WHAT="以 _fleetadmin 跑删号脚本：不带单 / 伪造单 / 别人的单（登录·机器·操作不对）/ 过期 / 多一个参数 / 重放用过的单，全部拒绝、脚本没跑、登录还在；入口签的单只跑一次"
}

cred_run_drills "$0"
