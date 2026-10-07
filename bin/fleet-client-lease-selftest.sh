#!/bin/bash
# fleet-client-lease-selftest.sh — a person's connected clients (issue #1715,
# EPIC #1710 C5; several at once since #1932, EPIC #1906 C13): bin/fleet-shell.sh's
# lease (client_open / keeper / standby), bin/fleet-client-lease.py, and the
# standby gates in fleet-hub-sessions.sh and fleet-hub-write.sh.
#
# Nothing real is reached: the hub's lease is FLEET_CLIENT_LEASE_CMD — a fake
# that keeps the table in a directory, with the hub's rules (a lease per client,
# at most FAKE_MAX; the primary = the latest input; past the limit the least
# recently used is asked to leave; a revoked lease reads taken_over revoked) —
# `fleet-connect.py` is a fake whose --pick finds no machine (the shell opens on
# its `wait` window, no ssh), and every tmux server is an isolated socket killed
# at the end. Machines are shell servers (their own session + cache) over the one
# fake hub; a CLIENT is a pane of an outer isolated server running
# `fleet-shell.sh` — a real attached tmux client, so the standby popup draws in
# that pane, Enter reaches it, and a key typed there moves its #{client_activity}.
#   A. degenerate — no hub: fleet-client-lease.py says `nohub`, exit 0; one client
#                   opens with no popup, no lease kept, client.nohub set
#   B. same device— `fleet` twice on one machine: ONE session (the second attached
#                   to the running one), NEITHER on standby, one lease (the same id)
#   C. two devices— an iPhone opens on another machine: both machines hold a
#                   lease, neither on standby, both renewing; writes still go out
#   D. primary    — typing on the iPhone: its keeper reports `input`, where (the
#                   real fleet-client-where.sh over the fake's get) = iPhone;
#                   typing on the MacBook: where = MacBook
#   E. evicted    — FAKE_MAX=2, a third machine opens: the one used least
#                   recently is asked to leave → its client shows 「客户端已开满」,
#                   client.standby set, renewals stop, fleet-hub-write.sh refuses;
#                   Enter takes a lease again
#   F. revoked    — one machine's lease disconnected from another (revoke): its
#                   keeper reads taken_over revoked → 「被断开」
#   G. release    — a shell server that ends gives its lease up (release logged)
# and, at each step, the where (issue #1716): an acquire carries the client's
# saved where (--where-file), client.where.json names the client in use, and a
# machine on standby holds none
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-client-lease selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-client-lease selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fcl-st.XXXXXX")" || exit 2
OUT="fclO$$"; SX="fclX$$"; SY="fclY$$"; SZ="fclZ$$"
export HOME="$WORK/home"; mkdir -p "$HOME/.config/claude-fleet"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" FLEET_CONF_DIR="$HOME/.config/claude-fleet"
export FLEET_SHELL_WARM=0 FLEET_CLIENT_LEASE_EVERY=1 FLEET_CLIENT_INPUT_EVERY=1
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_SESSION FLEET_SHELL FLEET_HUB_SESSIONS_CLIENT FLEET_SIDEBAR_SOURCE
unset FLEET_HUB_URL CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_TOKEN FLEET_CLIENT_DEVICE SSH_CONNECTION

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (must not hold '$3')" "$2" ;; esac; }
ok() { CHECKS=$((CHECKS + 1)); "$@" || fail "$*"; }
to() { "$REAL_TMUX" -L "$OUT" "$@"; }
waitfor() {  # <secs> <cmd…>
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
cleanup() {
  for s in "$OUT" "$SX" "$SY" "$SZ"; do "$REAL_TMUX" -L "$s" kill-server 2>/dev/null; pkill -f "fleet-shell.sh keeper $s" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- a bin/ of our own: the real scripts, a fake fleet-connect.py ----------------
SB="$WORK/sbin"; mkdir -p "$SB" "$WORK/conf"
for f in "$BIN"/*; do [ -f "$f" ] && ln -s "$f" "$SB/${f##*/}"; done
rm -f "$SB/fleet-connect.py"
ln -s "$BIN/../conf/tmux-shell.conf" "$WORK/conf/tmux-shell.conf"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(1)\n' > "$SB/fleet-connect.py"   # --pick: nothing online
chmod +x "$SB/fleet-connect.py"

# --- the fake hub: the lease table in a directory --------------------------------
H="$WORK/hub"; mkdir -p "$H/cur" "$H/gone"; : > "$H/log"
cat > "$WORK/lease" <<EOF
#!/usr/bin/env python3
# fake client leases — the hub's rules (#1932), one person
import json, os, sys, time, random
H = "$H"
args = sys.argv[1:]; act = args[0] if args else ""
o = {}
i = 1
while i < len(args):
    if args[i].startswith("--") and i + 1 < len(args):
        o[args[i][2:]] = args[i + 1]; i += 2
    else:
        i += 1
if act == "device":
    dev = os.environ.get("FLEET_CLIENT_DEVICE") or "未知设备"
    if o.get("save"):
        open(o["save"], "w").write(json.dumps({"device": dev, "terminal": "FakeTerm", "via": "local", "caps": ["open_url"]}) + "\n")
    print("%s\tFakeTerm" % dev); sys.exit(0)
if act == "acquire" and o.get("where-file"):
    open(H + "/wherefiles", "a").write(open(o["where-file"]).read())
def out(*f):
    print("\t".join((list(f) + [""] * 5)[:5])); sys.exit(0)
if os.path.exists(H + "/nohub"):
    out("nohub")
open(H + "/log", "a").write("%s %s %s\n" % (act, o.get("lease", ""), o.get("device", "")))
def load(d):
    r = {}
    for n in os.listdir(H + "/" + d):
        r[n] = json.load(open(H + "/" + d + "/" + n))
    return r
def save(d, n, v): json.dump(v, open(H + "/" + d + "/" + n, "w"))
def tick():
    n = int(open(H + "/seq").read()) + 1 if os.path.exists(H + "/seq") else 1
    open(H + "/seq", "w").write(str(n)); return n
cur = load("cur")
def primary():
    return max(cur.items(), key=lambda kv: kv[1]["used"])[0] if cur else ""
MAX = int(open(H + "/max").read()) if os.path.exists(H + "/max") else 4
lease = o.get("lease", "")
if act == "acquire":
    if lease in cur:
        cur[lease]["used"] = tick(); save("cur", lease, cur[lease]); out("active", lease, cur[lease]["dev"])
    dev = o.get("device", "")
    n = "L%d%d" % (random.randint(0, 99999), os.getpid()); evicted = ""
    if len(cur) >= MAX:
        lru = min(cur.items(), key=lambda kv: kv[1]["used"])[0]
        evicted = cur[lru]["dev"]
        save("gone", lru, {"reason": "evicted", "by": dev}); os.remove(H + "/cur/" + lru)
        open(H + "/evictions", "a").write(evicted + "\n")
    if lease and os.path.exists(H + "/gone/" + lease):
        os.remove(H + "/gone/" + lease)
    save("cur", n, {"dev": dev, "used": tick()})
    out("active", n, dev, evicted)
if act in ("renew", "input"):
    if lease in cur:
        if act == "input":
            cur[lease]["used"] = tick()
            w = o.get("where-file")
            if w and os.path.exists(w):
                cur[lease]["dev"] = json.load(open(w)).get("device") or cur[lease]["dev"]
            save("cur", lease, cur[lease])
        out("active", lease, cur[lease]["dev"])
    g = load("gone").get(lease)
    if g:
        out("taken_over", "", g.get("by", ""), "", g["reason"])
    out("taken_over", "", cur[primary()]["dev"] if cur else "")
if act == "release":
    if lease in cur:
        os.remove(H + "/cur/" + lease)
    out("released")
if act == "revoke":
    t = o.get("target", "")
    if t in cur:
        save("gone", t, {"reason": "revoked"}); os.remove(H + "/cur/" + t); out("revoked")
    sys.exit(1)
if act == "get":
    p = primary()
    out("active", p, cur[p]["dev"]) if p else out("none")
if act == "where":
    p = primary()
    print(json.dumps({"state": "active", "lease": {"id": p, "device": cur[p]["dev"]}} if p else {"state": "none"}))
    sys.exit(0)
EOF
chmod +x "$WORK/lease"
export FLEET_CLIENT_LEASE_CMD="$WORK/lease"
printf '#!/bin/bash\nFLEET_CLIENT_WHERE_CMD="%s where" FLEET_SHELL_SESSION=nosuch exec bash "%s" 2>/dev/null\n' "$WORK/lease" "$BIN/fleet-client-where.sh" > "$WORK/where_is"
chmod +x "$WORK/where_is"
where_is() { "$WORK/where_is"; }

# client <machine-session> <device> — a client: an outer pane running the shell
client() {
  local s=$1 d=$2 cmd
  cmd="env -u TMUX -u TMUX_PANE FLEET_SHELL_SESSION=$s FLEET_SHELL_CACHE=$WORK/cache-$s FLEET_CLIENT_DEVICE=$d bash $SB/fleet-shell.sh"
  if to has-session -t "=o" 2>/dev/null; then
    to new-window -d -P -F '#{pane_id}' -t "=o" "$cmd"
  else
    to new-session -d -P -F '#{pane_id}' -s o -x 120 -y 30 "$cmd"
  fi
}
screen() { to capture-pane -p -t "$1" 2>/dev/null; }
shows() { screen "$1" | grep -q "$2"; }
clients() { "$REAL_TMUX" -L "$1" list-clients -F '#{client_name}' 2>/dev/null | grep -c .; }
nclients() { [ "$(clients "$1")" = "$2" ]; }

# --- A. degenerate: no hub -------------------------------------------------------
line=$(env -u FLEET_CLIENT_LEASE_CMD python3 "$BIN/fleet-client-lease.py" get); rc=$?
eq "A: no hub → exit 0" 0 "$rc"
eq "A: no hub → nohub" "nohub" "$(printf '%s' "$line" | cut -f1)"
: > "$H/nohub"
pa=$(client "$SX" MacBook)
waitfor 10 nclients "$SX" 1 || fail "A: the client never attached"
sleep 1.5
hasnt "A: one client, no hub → no standby screen" "$(screen "$pa")" "按回车接回"
ok test -f "$WORK/cache-$SX/tmp/client.nohub"
ok test ! -f "$WORK/cache-$SX/tmp/client.lease"
"$REAL_TMUX" -L "$SX" kill-server 2>/dev/null; to kill-server 2>/dev/null
waitfor 5 sh -c "! pgrep -f 'fleet-shell.sh keeper $SX' >/dev/null"
rm -f "$H/nohub" "$WORK/cache-$SX/tmp/client.nohub"

# --- B. same device twice: one session, both working ------------------------------
p1=$(client "$SX" MacBook)
waitfor 10 nclients "$SX" 1 || fail "B: the first client never attached"
waitfor 5 test -s "$WORK/cache-$SX/tmp/client.lease" || fail "B: no lease after the first open"
id1=$(cat "$WORK/cache-$SX/tmp/client.lease" 2>/dev/null)
p2=$(client "$SX" MacBook)
waitfor 10 nclients "$SX" 2 || fail "B: the second client never attached"
eq "B: one session on the machine (attached, not another)" 1 "$("$REAL_TMUX" -L "$SX" list-sessions -F x 2>/dev/null | grep -c x)"
sleep 2
hasnt "B: the first client keeps working (no standby)" "$(screen "$p1")" "按回车接回"
hasnt "B: the second client works" "$(screen "$p2")" "按回车接回"
eq "B: the same lease kept" "$id1" "$(cat "$WORK/cache-$SX/tmp/client.lease" 2>/dev/null)"
eq "B: one lease on the hub" 1 "$(ls "$H/cur" | grep -c .)"
ok test ! -f "$WORK/cache-$SX/tmp/client.standby"
# where (#1716): each acquire carries the client's saved where; the one in use is
# client.where.json, what fleet-client-where.sh reads with no hub
has "B: the acquire carried the saved where" "$(cat "$H/wherefiles" 2>/dev/null)" '"via": "local"'
has "B: client.where.json = the client in use" "$(cat "$WORK/cache-$SX/tmp/client.where.json" 2>/dev/null)" '"device": "MacBook"'

# --- C. another device opens: nobody to standby ---------------------------------
p3=$(client "$SY" iPhone)
waitfor 10 nclients "$SY" 1 || fail "C: the iPhone client never attached"
waitfor 5 test -s "$WORK/cache-$SY/tmp/client.lease" || fail "C: the iPhone's machine holds no lease"
sleep 2.5
ok test ! -f "$WORK/cache-$SX/tmp/client.standby"
ok test ! -f "$WORK/cache-$SY/tmp/client.standby"
hasnt "C: the MacBook keeps working" "$(screen "$p2")" "按回车接回"
hasnt "C: the iPhone works" "$(screen "$p3")" "按回车接回"
eq "C: two leases on the hub" 2 "$(ls "$H/cur" | grep -c .)"
ok test ! -f "$H/evictions"
n1=$(grep -c "^renew $id1" "$H/log"); sleep 2.5; n2=$(grep -c "^renew $id1" "$H/log")
CHECKS=$((CHECKS + 1)); [ "$n2" -gt "$n1" ] || fail "C: the MacBook's machine stopped renewing" "$n1 → $n2"
has "C: the iPhone's machine holds its where" "$(cat "$WORK/cache-$SY/tmp/client.where.json" 2>/dev/null)" '"device": "iPhone"'

# --- D. the primary follows the last input ----------------------------------------
idy=$(cat "$WORK/cache-$SY/tmp/client.lease" 2>/dev/null)
sleep 1.1; FLEET_ALLOW_SENDKEYS=1 to send-keys -t "$p3" F12
waitfor 6 grep -q "^input $idy" "$H/log" || fail "D: typing on the iPhone sent no input" "$(tail -3 "$H/log")"
waitfor 3 sh -c "\"\$0\" | grep -q iPhone" "$WORK/where_is" || fail "D: where after typing on the iPhone" "$(where_is)"
sleep 1.1; FLEET_ALLOW_SENDKEYS=1 to send-keys -t "$p2" F12
waitfor 6 grep -q "^input $id1" "$H/log" || fail "D: typing on the MacBook sent no input" "$(tail -3 "$H/log")"
waitfor 3 sh -c "\"\$0\" | grep -q MacBook" "$WORK/where_is" || fail "D: where after typing on the MacBook" "$(where_is)"

# --- E. past the limit: the least recently used is asked to leave -------------------
echo 2 > "$H/max"
p4=$(client "$SZ" iPad)
waitfor 10 nclients "$SZ" 1 || fail "E: the iPad client never attached"
waitfor 5 test -s "$H/evictions" || fail "E: nobody was asked to leave"
eq "E: the iPhone (used least recently) asked to leave" iPhone "$(cat "$H/evictions" 2>/dev/null)"
waitfor 6 test -f "$WORK/cache-$SY/tmp/client.standby" || fail "E: the iPhone's machine never went to standby"
waitfor 5 shows "$p3" "客户端已开满" || fail "E: the iPhone shows no 'full' screen" "$(screen "$p3")"
ok test ! -f "$WORK/cache-$SX/tmp/client.standby"
ok test ! -f "$WORK/cache-$SY/tmp/client.where.json"
n1=$(grep -c "^renew $idy" "$H/log"); sleep 2.5; n2=$(grep -c "^renew $idy" "$H/log")
eq "E: standby renews nothing" "$n1" "$n2"
out=$(FLEET_SHELL=1 TMPDIR="$WORK/cache-$SY/tmp" FLEET_HUB_WRITE_CMD="touch $WORK/sent" bash "$BIN/fleet-hub-write.sh" worker_stop '{"worker_id":"x"}' 2>&1); rc=$?
eq "E: a write in standby → exit 1" 1 "$rc"
has "E: … saying why" "$out" "待机"
ok test ! -e "$WORK/sent"
FLEET_ALLOW_SENDKEYS=1 to send-keys -t "$p3" Enter
waitfor 6 sh -c "! test -f '$WORK/cache-$SY/tmp/client.standby'" || fail "E: Enter did not take a lease again"
waitfor 5 sh -c "! tmux -L $OUT capture-pane -p -t '$p3' | grep -q 客户端已开满" || fail "E: the popup is still up" "$(screen "$p3")"
has "E: its where is back" "$(cat "$WORK/cache-$SY/tmp/client.where.json" 2>/dev/null)" '"device": "iPhone"'
echo 4 > "$H/max"

# --- F. disconnected from another client --------------------------------------------
idz=$(cat "$WORK/cache-$SZ/tmp/client.lease" 2>/dev/null)
waitfor 5 test -n "$idz" || fail "F: the iPad holds no lease"
FLEET_CLIENT_LEASE_CMD="$WORK/lease" "$WORK/lease" revoke --target "$idz" >/dev/null
waitfor 6 test -f "$WORK/cache-$SZ/tmp/client.standby" || fail "F: the iPad's machine never went to standby"
waitfor 5 shows "$p4" "被断开" || fail "F: the iPad shows no 'disconnected' screen" "$(screen "$p4")"

# --- G. a server that ends gives the lease up -------------------------------------
idx=$(cat "$WORK/cache-$SX/tmp/client.lease" 2>/dev/null)
"$REAL_TMUX" -L "$SX" kill-server 2>/dev/null
waitfor 6 grep -q "^release $idx" "$H/log" || fail "G: no release after the server ended" "$(tail -3 "$H/log")"
ok test ! -f "$H/cur/$idx"

[ "$FAIL" = 0 ] || { printf "hub log:\n"; cat "$H/log"; } >&2
printf 'fleet-client-lease selftest: %d checks, %d failed\n' "$CHECKS" "$FAIL"
[ "$FAIL" = 0 ]
