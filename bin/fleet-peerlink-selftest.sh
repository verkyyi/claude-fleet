#!/bin/bash
# fleet-peerlink-selftest.sh — bin/fleet-peerlink.py, the home machine's standing
# connections (issue #3002, EPIC #2999 C5). The five ways one goes bad are
# docs/dev/BREAK-IT.md's peerlink-* drills (bin/fleet-break-it-peerlink-selftest.sh);
# this pins the rest:
#
#   A. want     — which (machine, login): your sessions' machines from every
#                 remote_<sess>, each row's login off fleet_logins (else this
#                 login), this machine's own login and a lost machine left out —
#                 and nothing at all while no thin view has a client
#   B. linger   — the last view gone, every link closes FLEET_PEERLINK_LINGER
#                 later: zero masters left
#   C. doctor   — status: no state ⇒ rc 2, no row; healthy ⇒ rc 0, one line per
#                 link; a keeper that stopped ⇒ rc 1; fleet-doctor.sh prints the
#                 `peerlink` row from it
#   D. sock     — rc 0 + the path for a healthy link only
#   E. pane     — C4's pane program waits for the link, then rides it with
#                 `attach --thin --view <view>-via-<home> --resume`
#   F. units    — launchd template KeepAlive + its systemd twin, both on the wrapper
#   G. routes   — (issue #3482) each link dials a route the hub lists, never a bare
#                 name it has routes for: tailnet only with a tailnet here, a LAN only
#                 on this network, then the entry port (`-p`); the next route at once
#                 after a failure; FLEET_REMOTE_SSH still wins; no routes ⇒ the name
#   H. all      — (issue #3482, the default) your logins elsewhere held with no view
#                 attached and past the linger, same master; a dead route retried
#                 with backoff (not every beat) and the doctor says 连不上 then
#                 已连上; a hub that is down closes nothing; a login the hub drops
#                 closes 「已不是你的登录」; a keeper restart hands the masters to
#                 the next keeper (adopted, same pid)
#   I. switch   — FLEET_PEERLINK_MODE=demand in fleet.conf: back to #3002's rule
#   J. list     — bin/fleet-peer-list.sh: the node token's GET /v1/node/peers — rc 0
#                 + the JSON, rc 3 with no token / an older hub, rc 1 down or refused
#   K. exec/fwd — (issue #3538) `exec` runs one command over an up link's master (rc 3
#                 for none / down); `fwd` adds `-L <port>:127.0.0.1:<rport>`, prints
#                 the port, cancels it at FLEET_OPEN_PAGE_SECS; refused → rc 1
#   L. quiet    — (issue #4359) past FLEET_PEERLINK_ACTIVE_SECS with nothing going on
#                 the keeper beats every FLEET_PEERLINK_IDLE_TICK: no `-O check`, no
#                 hub ask between; a `sock` request wakes it at once (beat back to
#                 TICK, the link checked); a master that dies while quiet is rebuilt
#                 within seconds; the links stay up throughout; the doctor stays ok
#
# No network: bin/fleet-peerlink-fake-ssh.py plays ssh, a script plays
# fleet-peer-cert.sh.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
PL="$BIN/fleet-peerlink.py"
command -v python3 >/dev/null 2>&1 || { echo 'fleet-peerlink-selftest: python3 absent — SKIP'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/plst.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
PIDS=''
cleanup() {
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  for f in "$WORK"/*/fs/log; do
    [ -f "$f" ] && awk '$1 == "master" { print $4 }' "$f" | while read -r p; do kill "$p" 2>/dev/null; done
  done
  rm -rf "$WORK"
}
trap cleanup EXIT
FAILS=0 CHECKS=0
ok() { CHECKS=$((CHECKS + 1)); }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$*"; }
until_ok() { local secs="$1" _; shift; for _ in $(seq 1 $((secs * 10))); do "$@" && return 0; sleep 0.1; done; "$@"; }

US=$'\x1f'
box() {   # box <name> <view: 1|0> <machine:login[:lost]>…
  local n="$1" v="$2" t sp; shift 2
  B="$WORK/$n"; mkdir -p "$B/conf/remote-views" "$B/t/.claude-dash/global" "$B/fs"
  if [ "$v" = 1 ]; then
    sleep 600 & sp=$!; disown "$sp" 2>/dev/null; PIDS="$PIDS $sp"; VP=$sp
    printf '/dev/ttys0\tfleet@view-a\tthin\t%s\t%s\n' "$(date +%s)" "$sp" > "$B/conf/remote-views/a"
  fi
  # a plain (not thin) view never asks for a link
  printf '/dev/ttys1\tfleet@view-b\tview\t%s\t%s\n' "$(date +%s)" "$$" > "$B/conf/remote-views/b"
  : > "$B/t/.claude-dash/global/fleet_logins"
  printf '#me%shome\n' "$US" > "$B/t/.claude-dash/global/remote_fleet"
  for t in "$@"; do row "$t"; done
  printf '#!/bin/bash\nprintf "%%s\\n" -o IdentitiesOnly=yes -l hubsays\n' > "$B/cert.sh"; chmod +x "$B/cert.sh"
  # the hub's /v1/node/peers (fleet-peer-list.sh): $B/peers.json, none ⇒ no hub (rc 3)
  cat > "$B/peers.sh" <<EOS
#!/bin/bash
[ -f "$B/peers.down" ] && { echo 'fleet-peer-list: the hub could not be reached (curl exit 7)' >&2; exit 1; }
[ -f "$B/peers.json" ] || exit 3
cat "$B/peers.json"
EOS
  chmod +x "$B/peers.sh"
  export FLEET_CONF_DIR="$B/conf" TMPDIR="$B/t" FAKESSH_DIR="$B/fs" FLEET_PEERLINK_HOME=home \
    FLEET_PEERLINK_SSH="python3 $BIN/fleet-peerlink-fake-ssh.py" FLEET_PEERLINK_CERT_CMD="$B/cert.sh" \
    FLEET_PEERLINK_PEERS_CMD="$B/peers.sh"
  unset FLEET_C
}
# peers <hostname:login[:name=host[:port]][,name=host[:port]…]>… — what the hub answers
peers() {
  python3 - "$B/peers.json" "$@" <<'PY'
import json, sys
out = []
for a in sys.argv[2:]:
    h, l, *r = a.split(":", 2)
    routes = []
    for w in (r[0].split(",") if r and r[0] else []):
        n, _, hp = w.partition("=")
        host, _, port = hp.partition("/")
        routes.append(dict({"name": n, "host": host}, **({"port": int(port)} if port else {})))
    out.append({"hostname": h, "login": l, "routes": routes})
json.dump({"hostname": "home", "login": "me", "peers": out}, open(sys.argv[1], "w"))
PY
}
row() {   # row <machine:login[:lost]>
  local m l av u
  IFS=: read -r m l av <<EOF
$1
EOF
  u="U$(printf '%s:%s' "$m" "$l" | cksum | cut -d' ' -f1)"
  [ "$l" = "-" ] || printf '%s\t%s\n' "$u" "$l" >> "$B/t/.claude-dash/global/fleet_logins"
  printf 'wid:%s/f1%s%s%s%s%s1%so/r%sworking%sclaude%sn%s%s%s0\n' "$u" "$US" "$m" "$US" "${av:-online}" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" \
    >> "$B/t/.claude-dash/global/remote_fleet"
}
start() { python3 "$PL" run 2>>"$B/run.err" & KP=$!; PIDS="$PIDS $KP"; }
stop() { kill "$KP" 2>/dev/null; wait "$KP" 2>/dev/null; }
links() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(" ".join(sorted("%s@%s:%s" % (l["machine"], l["login"], l["phase"]) for l in s["links"])))' "$B/conf/peerlink/state.json" 2>/dev/null; }
links_is() { [ "$(links)" = "$1" ]; }
all_closed() { [ -z "$(links)" ] && [ "$(masters_alive)" = 0 ]; }
masters_alive() { awk '$1 == "master" { print $4 }' "$B/fs/log" 2>/dev/null | while read -r p; do kill -0 "$p" 2>/dev/null && echo "$p"; done | wc -l | tr -d ' '; }
ME=$(id -un)
# legs A–K pin the 2 s beat; leg L the quiet one (issue #4359)
export FLEET_PEERLINK_IDLE_TICK=2

# The legs run as five groups at once — every leg builds its own box ($WORK/<leg>:
# its own conf dir, lock, state, fake-ssh log), so they share nothing — with F, J, K
# in the foreground. Inside a group the legs keep their order. Each group is a
# subshell: its exports stay in it, its counts come back in $WORK/res.<group>.
# --- A. want ------------------------------------------------------------------
leg_A() {
box a 1 mac-a:bob mac-a:carol "home:$ME" home:dave mac-n:bob:lost "mac-b:-"
start
until_ok 8 sh -c '[ "$(python3 -c "import json,sys; print(sum(l[\"phase\"] == \"up\" for l in json.load(open(sys.argv[1]))[\"links\"]))" "$1" 2>/dev/null)" = 4 ]' _ "$B/conf/peerlink/state.json" \
  || fail "A: four links never came up: $(links) · $(tail -3 "$B/run.err")"
[ "$(links)" = "home@dave:up mac-a@bob:up mac-a@carol:up mac-b@$ME:up" ] && ok \
  || fail "A: want set: got [$(links)] — want mac-a@bob mac-a@carol (two logins on one machine), home@dave (this machine, another login), mac-b as $ME (no login known); not home@$ME, not the lost mac-n"
grep -q "^channel mac-a bob id -un" "$B/fs/log" && grep -q "^master mac-a bob " "$B/fs/log" && ok || fail "A: mac-a@bob was not opened as bob"
grep -q "^master mac-n " "$B/fs/log" && fail "A: a lost machine was dialled" || ok
stop
box a2 0 mac-a:bob
export FLEET_PEERLINK_MODE=demand
start; sleep 2.5
[ -s "$B/fs/log" ] && fail "A: no thin view attached, yet ssh ran: $(cat "$B/fs/log")" || ok
[ -z "$(links)" ] && ok || fail "A: links with no view: $(links)"
stop; unset FLEET_PEERLINK_MODE
}

# --- B. linger -----------------------------------------------------------------
leg_B() {
box b 1 mac-a:bob mac-b:bob
export FLEET_PEERLINK_LINGER=2 FLEET_PEERLINK_MODE=demand
start
until_ok 8 links_is "mac-a@bob:up mac-b@bob:up" || fail "B: links never up: $(links)"
[ "$(masters_alive)" = 2 ] && ok || fail "B: $(masters_alive) masters alive, want 2"
kill "$VP" 2>/dev/null
until_ok 10 all_closed \
  && ok || fail "B: the view gone ${FLEET_PEERLINK_LINGER}s, still links [$(links)] / $(masters_alive) masters"
ls "$B/conf/peerlink/"*.sock >/dev/null 2>&1 && fail "B: control files left: $(ls "$B/conf/peerlink/")" || ok
grep -q '关闭：没人要了' "$B/run.err" && ok || fail "B: no close record"
stop; unset FLEET_PEERLINK_LINGER FLEET_PEERLINK_MODE
}

# --- C. doctor -----------------------------------------------------------------
leg_C() {
box c 1 mac-a:bob
out=$(python3 "$PL" status --check); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && ok || fail "C: never ran: rc $rc [$out], want rc 2 and nothing"
out=$(FLEET_CONF_DIR="$B/conf" bash "$BIN/fleet-doctor.sh" 2>/dev/null | grep peerlink)
[ -z "$out" ] && ok || fail "C: the doctor printed a peerlink row for a login it never ran on: $out"
start
until_ok 8 links_is "mac-a@bob:up" || fail "C: never up"
until_ok 2 sh -c 'python3 "$1" status --check | grep -q 往返' _ "$PL"
out=$(python3 "$PL" status --check); rc=$?
case "$out" in "1 条常开连接（全连）：mac-a@bob 已连上 · 路线 mac-a · "*" · 往返 "*" · 失败 0") [ "$rc" = 0 ] && ok || fail "C: healthy rc $rc" ;; *) fail "C: healthy line: [$out] rc $rc" ;; esac
out=$(bash "$BIN/fleet-doctor.sh" 2>/dev/null | grep peerlink)
case "$out" in *PASS*peerlink*mac-a@bob*) ok ;; *) fail "C: doctor row (healthy): [$out]" ;; esac
printf '%s\n' "doctor healthy: $out" >> "$WORK/doctor-rows.txt"
stop
until_ok 3 sh -c 'FLEET_PEERLINK_STALE=1 python3 "$1" status --check | grep -q 管理者没在跑' _ "$PL"
out=$(FLEET_PEERLINK_STALE=1 python3 "$PL" status --check); rc=$?
case "$out" in *管理者没在跑*) [ "$rc" = 1 ] && ok || fail "C: stopped keeper rc $rc" ;; *) fail "C: a stopped keeper reads [$out]" ;; esac
out=$(FLEET_PEERLINK_STALE=1 bash "$BIN/fleet-doctor.sh" 2>/dev/null | grep peerlink)
case "$out" in *WARN*peerlink*管理者没在跑*) ok ;; *) fail "C: doctor row (bad): [$out]" ;; esac
printf '%s\n' "doctor bad: $out" >> "$WORK/doctor-rows.txt"
[ -n "${PEERLINK_SHOW:-}" ] && cat "$WORK/doctor-rows.txt"
}

# --- D. sock -------------------------------------------------------------------
leg_D() {
box d 1 mac-a:bob
python3 "$PL" sock mac-a bob >/dev/null && fail "D: sock answered with no keeper" || ok
start
until_ok 8 links_is "mac-a@bob:up" || fail "D: never up"
[ "$(python3 "$PL" sock mac-a bob)" = "$B/conf/peerlink/mac-a@bob.sock" ] && ok || fail "D: sock of a healthy link"
python3 "$PL" sock mac-a carol >/dev/null && fail "D: sock for a link nobody holds" || ok
python3 "$PL" sock 'mac-a;x' bob >/dev/null 2>&1; [ $? = 2 ] && ok || fail "D: an unsafe name not refused"
}

# --- E. pane -------------------------------------------------------------------
leg_E() {
out=$(python3 "$PL" pane mac-a bob v1 </dev/null 2>&1)
case "$out" in *"ran bash .claude/fleet/bin/fleet-remote-view.sh attach --thin --view v1-via-home --resume"*) ok ;; *) fail "E: pane on a healthy link: [$out]" ;; esac
stop
box e 1
start
( python3 "$PL" pane mac-l bob v1 </dev/null > "$B/pane.out" 2>&1 ) & pp=$!; PIDS="$PIDS $pp"
until_ok 2 grep -q '正在连 mac-l（bob）' "$B/pane.out" && ok || fail "E: a pane before its link does not say it is connecting: $(cat "$B/pane.out")"
row mac-l:bob
until_ok 10 sh -c '! kill -0 "$1" 2>/dev/null' _ "$pp" && ok || fail "E: the pane did not ride the link once it came up"
grep -q 'attach --thin --view v1-via-home --resume' "$B/pane.out" && ok || fail "E: pane output: $(cat "$B/pane.out")"
stop
}

# --- F. units ------------------------------------------------------------------
leg_F() {
T="$ROOT/launchd/com.claude-fleet.peerlink.plist.tmpl"
grep -q '<key>KeepAlive</key><true/>' "$T" && grep -q 'bin/fleet-peerlink.sh</string><string>run</string>' "$T" && ok \
  || fail "F: the launchd template is not a KeepAlive run of fleet-peerlink.sh"
grep -q '^ExecStart=/bin/bash __HOME__/.claude/fleet/bin/fleet-peerlink.sh run$' "$ROOT/systemd/claude-fleet-peerlink.service" \
  && grep -q '^Restart=always' "$ROOT/systemd/claude-fleet-peerlink.service" && ok || fail "F: the systemd twin"
grep -q '"$_npl" status --check' "$BIN/fleet-doctor.sh" && ok || fail "F: fleet-doctor.sh has no peerlink row"
}

# --- G. routes (issue #3482) -----------------------------------------------------
leg_G() {
# the order, off route_candidates itself: the tailnet only with one here, a LAN only
# on this network, then the entry port; FLEET_REMOTE_SSH wins; nothing known ⇒ the name
cand() {   # cand <machine> <routes json> → "host:port host:port …"
  python3 - "$PL" "$1" "$2" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("pl", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(" ".join("%s:%d" % (h, p) for h, p, _ in m.route_candidates(sys.argv[2], json.loads(sys.argv[3]))))
PY
}
R='[{"name":"public","host":"203.0.113.9","port":22},{"name":"entry","host":"203.0.113.212","port":22022},{"name":"lan","host":"10.9.9.9","prefix":24},{"name":"tailnet","host":"lx0.example.ts.net"},{"name":"relay","host":"hub","kind":"relay"}]'
got=$(FLEET_CONNECT_LOCAL_ADDRS=192.168.1.5/24 cand lx0 "$R")
[ "$got" = "203.0.113.212:22022 203.0.113.9:22" ] && ok || fail "G: off the tailnet and the LAN: [$got], want the entry port, then the public line"
got=$(FLEET_CONNECT_LOCAL_ADDRS=192.168.1.5/24,100.101.2.3/32,10.9.9.4/24 cand lx0 "$R")
[ "$got" = "lx0.example.ts.net:0 10.9.9.9:0 203.0.113.212:22022 203.0.113.9:22" ] && ok || fail "G: on the tailnet and the LAN: [$got]"
got=$(FLEET_REMOTE_SSH='lx0=jump-linux' cand lx0 "$R")
[ "$got" = "jump-linux:0" ] && ok || fail "G: FLEET_REMOTE_SSH does not win: [$got]"
got=$(cand mac-a '[]')
[ "$got" = "mac-a:0" ] && ok || fail "G: no routes known is not the bare name: [$got]"
# for real: the bare name does not resolve here; the link rides the entry port
box g 0
export FLEET_CONNECT_LOCAL_ADDRS=192.168.1.5/24 FLEET_NODE_ALIASES='mac-a.local=mac-a'
mkdir -p "$B/fs/nodns" "$B/fs/down"; : > "$B/fs/nodns/lx0"; : > "$B/fs/nodns/mac-a"
: > "$B/fs/down/198.51.100.1"
peers lx0:bob:tailnet=lx0.example.ts.net,entry=203.0.113.212/22022 \
  mac-a.local:bob:entry=198.51.100.1/22022,public=198.51.100.2/22
start
until_ok 10 links_is "lx0@bob:up mac-a@bob:up" || fail "G: links never up: $(links) · $(tail -3 "$B/run.err")"
grep -q '^master 203.0.113.212 bob [0-9]* 22022$' "$B/fs/log" && ok || fail "G: lx0 not dialled at its entry port: $(cat "$B/fs/log")"
grep -q '^master lx0 ' "$B/fs/log" && fail "G: the bare name was dialled" || ok
grep -q '^master 198.51.100.2 bob [0-9]* 22$' "$B/fs/log" && ok || fail "G: mac-a did not fall to its second route: $(cat "$B/fs/log")"
out=$(python3 "$PL" status --check)
case "$out" in *"lx0@bob 已连上 · 路线 entry 203.0.113.212:22022"*) ok ;; *) fail "G: the doctor does not name the route: [$out]" ;; esac
python3 "$PL" pane lx0 bob v1 </dev/null >"$B/gp.out" 2>&1 & pp=$!
until_ok 3 sh -c '! kill -0 "$1" 2>/dev/null' _ "$pp"; kill $pp 2>/dev/null; wait $pp 2>/dev/null; out=$(cat "$B/gp.out")
case "$out" in *"ran bash .claude/fleet/bin/fleet-remote-view.sh attach --thin"*) ok ;; *) fail "G: a pane over the entry-port link: [$out]" ;; esac
stop; unset FLEET_CONNECT_LOCAL_ADDRS FLEET_NODE_ALIASES
}

# --- H. all: held, retried, never reaped (issue #3482) --------------------------
leg_H() {
box h 0
# BACKOFF_MAX=4: the dead route's tries stay at 0 · 1 · 3 · 7 s (1 → 2 → 4), only the
# 8 s gap after them is cut, so mac-l comes back sooner once its route does
export FLEET_PEERLINK_LINGER=1 FLEET_PEERLINK_PEERS_SECS=1 FLEET_PEERLINK_BAD_WARN=1 FLEET_CONNECT_LOCAL_ADDRS=192.168.1.5/24 \
  FLEET_PEERLINK_BACKOFF_MAX=4
mkdir -p "$B/fs/down"; : > "$B/fs/down/203.0.113.7"
peers mac-a:bob:entry=203.0.113.4/22022 mac-l:bob:entry=203.0.113.7/22022 "home:$ME"
start
until_ok 8 sh -c '[ "$(python3 "$1" status --json | python3 -c "import json,sys; print(json.load(sys.stdin)[\"state\"][\"mode\"])")" = all ]' _ "$PL" || fail "H: mode is not all by default"
until_ok 8 sh -c 'python3 "$1" sock mac-a bob >/dev/null' _ "$PL" && ok || fail "H: no view attached, mac-a@bob never up: $(links)"
p1=$(python3 -c 'import json,sys; print([l["pid"] for l in json.load(open(sys.argv[1]))["links"] if l["machine"] == "mac-a"][0])' "$B/conf/peerlink/state.json")
grep -q "^master home " "$B/fs/log" && fail "H: this very login was dialled" || ok
sleep 6
p2=$(python3 -c 'import json,sys; print([l["pid"] for l in json.load(open(sys.argv[1]))["links"] if l["machine"] == "mac-a"][0])' "$B/conf/peerlink/state.json")
links_is "mac-a@bob:up mac-l@bob:down" && [ "$p1" = "$p2" ] && ok || fail "H: past the linger, links [$(links)] pid $p1 → $p2 — want mac-a held on the same master"
grep -q '没人要了' "$B/run.err" && fail "H: a link closed for want of use" || ok
tries=$(python3 -c 'import json,sys; print([l["fails"] for l in json.load(open(sys.argv[1]))["links"] if l["machine"] == "mac-l"][0])' "$B/conf/peerlink/state.json")
[ "$tries" -ge 2 ] && [ "$tries" -le 6 ] && ok || fail "H: a dead route tried $tries times in ~7s — want a few (backoff 1 → 2 → 4 s), not every beat"
out=$(python3 "$PL" status --check); rc=$?
case "$out" in *"mac-l@bob 连不上已"*"Connection refused"*) [ "$rc" = 1 ] && ok || fail "H: 连不上 not a WARN (rc $rc)" ;; *) fail "H: the doctor on a dead peer: [$out]" ;; esac
printf '%s\n' "doctor all/dead: $out" >> "$WORK/doctor-rows.txt"
rm -f "$B/fs/down/203.0.113.7"
until_ok 12 links_is "mac-a@bob:up mac-l@bob:up" && ok || fail "H: mac-l did not come back once its route did: $(links)"
out=$(python3 "$PL" status --check); rc=$?
case "$out" in "2 条常开连接（全连）："*"mac-a@bob 已连上"*"mac-l@bob 已连上"*) [ "$rc" = 0 ] && ok || fail "H: rc $rc once both up" ;; *) fail "H: the doctor once both up: [$out]" ;; esac
printf '%s\n' "doctor all/up: $out" >> "$WORK/doctor-rows.txt"
# a hub that is down closes nothing
: > "$B/peers.down"; sleep 3
links_is "mac-a@bob:up mac-l@bob:up" && ok || fail "H: the hub down closed links: $(links)"
rm -f "$B/peers.down"
# the keeper restarts (an install switch): the masters stay, the next one adopts them
p1=$(python3 -c 'import json,sys; print([l["pid"] for l in json.load(open(sys.argv[1]))["links"] if l["machine"] == "mac-a"][0])' "$B/conf/peerlink/state.json")
stop
kill -0 "$p1" 2>/dev/null && ok || fail "H: the keeper's exit took mac-a's master ($p1) with it"
grep -q 'mac-a@bob 交给下一个管理者' "$B/run.err" && ok || fail "H: no handover record"
start
until_ok 8 grep -q 'mac-a@bob adopted' "$B/run.err" || fail "H: the next keeper did not adopt mac-a: $(grep mac-a@bob "$B/run.err" | tail -3 | tr '\n' ' ')"
until_ok 8 links_is "mac-a@bob:up mac-l@bob:up" || fail "H: not back up after the restart: $(links)"
p2=$(python3 -c 'import json,sys; print([l["pid"] for l in json.load(open(sys.argv[1]))["links"] if l["machine"] == "mac-a"][0])' "$B/conf/peerlink/state.json")
[ "$p1" = "$p2" ] && grep -q 'mac-a@bob adopted' "$B/run.err" && ok || fail "H: mac-a rebuilt across the restart (pid $p1 → $p2), want adopted: $(grep mac-a@bob "$B/run.err" | tail -4 | tr "\n" " ")"
# the hub no longer lists mac-l@bob as yours (and no session of yours is there)
peers mac-a:bob:entry=203.0.113.4/22022
until_ok 8 links_is "mac-a@bob:up" && ok || fail "H: a login the hub dropped is still held: $(links)"
grep -q 'mac-l@bob 关闭：已不是你的登录' "$B/run.err" && ok || fail "H: no close record for the dropped login"
stop; unset FLEET_PEERLINK_LINGER FLEET_PEERLINK_PEERS_SECS FLEET_PEERLINK_BAD_WARN FLEET_CONNECT_LOCAL_ADDRS FLEET_PEERLINK_BACKOFF_MAX
}

# --- I. switch: FLEET_PEERLINK_MODE=demand in fleet.conf -------------------------
leg_I() {
box i 0
printf '[ -n "${FLEET_SHELL:-}" ] || {\nFLEET_PEERLINK_MODE=demand\n}\n' > "$B/conf/fleet.conf"
peers mac-a:bob:entry=203.0.113.4/22022
start; sleep 2.5
[ -s "$B/fs/log" ] && fail "I: demand with no view, yet ssh ran: $(cat "$B/fs/log")" || ok
python3 "$PL" status --check | grep -q '没有常开连接（无看台）' && ok || fail "I: the doctor under demand: $(python3 "$PL" status --check)"
stop
}

# --- J. fleet-peer-list.sh: the hub's /v1/node/peers with this login's node token --
leg_J() {
J="$WORK/j"; mkdir -p "$J/conf"
cat > "$J/curl" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "$JDIR/curl.log"
case "$JCODE" in down) exit 7 ;; esac
printf '%s\n%s' "$JBODY" "$JCODE"
EOS
chmod +x "$J/curl"
pl_list() { env -u CCQUOTA_TOKEN -u CCQUOTA_HUB_URL FLEET_CONF_DIR="$J/conf" FLEET_HUB_CURL="$J/curl" JDIR="$J" "$@" bash "$BIN/fleet-peer-list.sh"; }
out=$(pl_list JCODE=200 JBODY='{}' 2>&1); rc=$?
[ "$rc" = 3 ] && [ ! -s "$J/curl.log" ] && ok || fail "J: no node token: rc $rc [$out] — want 3 and no request"
printf 'CCQUOTA_TOKEN=tok-1\nCCQUOTA_HUB_URL=https://hub.example\n' > "$J/conf/node.env"
out=$(pl_list JCODE=200 JBODY='{"peers":[{"hostname":"lx0","login":"bob","routes":[]}]}' 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = '{"peers":[{"hostname":"lx0","login":"bob","routes":[]}]}' ] && ok || fail "J: answered: rc $rc [$out]"
grep -q 'Authorization: Bearer tok-1.*https://hub.example/v1/node/peers' "$J/curl.log" && ok || fail "J: the request: $(cat "$J/curl.log")"
pl_list JCODE=404 JBODY='{}' >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && ok || fail "J: an older hub (404): rc $rc, want 3"
out=$(pl_list JCODE=down JBODY= 2>&1 >/dev/null); rc=$?
[ "$rc" = 1 ] && case "$out" in *"could not be reached"*) true ;; *) false ;; esac && ok || fail "J: the hub down: rc $rc [$out]"
pl_list JCODE=403 JBODY='{"error":"no"}' >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok || fail "J: refused (403): rc $rc, want 1"
}

# ---- K. exec · fwd (issue #3538): fleet-open's road to a thin client's HOME ---------------
leg_K() {
# A link that is up (state.json + its socket file); a stand-in ssh records each call.
K="$WORK/k"; mkdir -p "$K/conf/peerlink"
: > "$K/m2.sock"
printf '{"links":[{"machine":"mac-d","login":"%s","phase":"up","sock":"%s","host":"mac-d.lan"},{"machine":"mac-n","login":"x","phase":"down","sock":"%s","host":"mac-n"}]}\n' \
  "$(id -un)" "$K/m2.sock" "$K/m2.sock" > "$K/conf/peerlink/state.json"
cat > "$K/ssh" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >> "$K/ssh.log"
case " \$* " in *" -O forward "*|*" -O cancel "*) exit "\${K_FWD_RC:-0}" ;; esac
for a; do last=\$a; done
echo "ran: \$last"
EOS
chmod +x "$K/ssh"
kpl() { FLEET_CONF_DIR="$K/conf" FLEET_PEERLINK_SSH="$K/ssh" python3 "$BIN/fleet-peerlink.py" "$@"; }
out=$(kpl exec mac-d -- bash .claude/fleet/bin/fleet-open.sh --from-peer m:u -- 'http://127.0.0.1:1/a b'); rc=$?
[ "$rc" = 0 ] && [ "$out" = "ran: bash .claude/fleet/bin/fleet-open.sh --from-peer m:u -- 'http://127.0.0.1:1/a b'" ] && ok \
  || fail "K: exec: rc $rc [$out]"
grep -q -- "-S $K/m2.sock -o ControlMaster=no -T -l $(id -un) mac-d.lan" "$K/ssh.log" && ok || fail "K: exec rides the link's master: $(cat "$K/ssh.log")"
kpl exec mac-n -- true >/dev/null 2>&1; [ $? = 3 ] && ok || fail "K: exec to a link that is down must be rc 3"
kpl exec nowhere -- true >/dev/null 2>&1; [ $? = 3 ] && ok || fail "K: exec to no link must be rc 3"
: > "$K/ssh.log"
port=$(FLEET_OPEN_PAGE_SECS=1 kpl fwd mac-d "$(id -un)" 8765); rc=$?
[ "$rc" = 0 ] && case "$port" in ''|*[!0-9]*) false ;; *) true ;; esac && ok || fail "K: fwd: rc $rc [$port]"
grep -q -- "-S $K/m2.sock -O forward -L 127.0.0.1:$port:127.0.0.1:8765 -l $(id -un) mac-d.lan" "$K/ssh.log" && ok \
  || fail "K: fwd adds -L <port>:127.0.0.1:8765 to the master: $(cat "$K/ssh.log")"
until_ok 6 grep -q -- "-O cancel -L 127.0.0.1:$port:127.0.0.1:8765" "$K/ssh.log" && ok || fail "K: the forward was never cancelled at its deadline"
K_FWD_RC=255 kpl fwd mac-d "$(id -un)" 8765 >/dev/null 2>&1; [ $? = 1 ] && ok || fail "K: a refused forward must be rc 1"
kpl fwd mac-n x 8765 >/dev/null 2>&1; [ $? = 3 ] && ok || fail "K: fwd over a link that is down must be rc 3"
kpl fwd mac-d "$(id -un)" 99999 >/dev/null 2>&1; [ $? = 2 ] && ok || fail "K: fwd to a bad port must be rc 2"
}

# ---- L. quiet (issue #4359): the keeper looks every IDLE_TICK, a request wakes it ----------
leg_L() {
box l 0
export FLEET_PEERLINK_ACTIVE_SECS=1 FLEET_PEERLINK_IDLE_TICK=30 FLEET_PEERLINK_PEERS_SECS=1
cat > "$B/ssh" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >> "$B/ssh.calls"
exec python3 "$BIN/fleet-peerlink-fake-ssh.py" "\$@"
EOS
chmod +x "$B/ssh"
: > "$B/peers.calls"
sed -i.bak 's|^cat "|printf x >> "'"$B"'/peers.calls"; cat "|' "$B/peers.sh"
export FLEET_PEERLINK_SSH="$B/ssh"
peers mac-a:bob:entry=203.0.113.4/22022
beat() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("beat"))' "$B/conf/peerlink/state.json" 2>/dev/null; }
beat_is() { [ "$(beat)" = "$1" ]; }
checks() { grep -c -- ' -O check ' "$B/ssh.calls" 2>/dev/null || true; }
checks_over() { [ "$(checks)" -gt "$1" ]; }
link_rebuilt() {   # link_rebuilt <old pid>: up again on another master
  python3 -c 'import json,sys; l=json.load(open(sys.argv[1]))["links"][0]; sys.exit(not (l["phase"] == "up" and str(l["pid"]) != sys.argv[2]))' \
    "$B/conf/peerlink/state.json" "$1" 2>/dev/null
}
start
until_ok 10 links_is "mac-a@bob:up" || fail "L: the link never came up: $(links)"
until_ok 6 beat_is 30.0 && ok || fail "L: nothing going on, the beat is $(beat), want 30.0"
c0=$(checks); h0=$(wc -c < "$B/peers.calls" | tr -d ' ')
sleep 4
c1=$(checks); h1=$(wc -c < "$B/peers.calls" | tr -d ' ')
[ "$c1" = "$c0" ] && [ "$h1" = "$h0" ] && ok || fail "L: quiet, yet $((c1 - c0)) -O check and $((h1 - h0)) hub asks in 4 s"
links_is "mac-a@bob:up" && ok || fail "L: a quiet keeper let the link go: $(links)"
python3 "$PL" status --check >/dev/null && ok || fail "L: the doctor on a quiet keeper: $(python3 "$PL" status --check)"
# a request: the keeper looks now
python3 "$PL" sock mac-a bob >/dev/null || fail "L: sock on an up link"
c2=$(checks)
until_ok 2 beat_is 2.0 && ok || fail "L: a request did not wake the keeper (beat $(beat))"
until_ok 2 checks_over "$c2" && ok || fail "L: woken, the keeper checked nothing"
# quiet again; a master that dies is rebuilt within seconds, not at the quiet beat
until_ok 6 beat_is 30.0 || fail "L: not quiet again: $(beat)"
p1=$(python3 -c 'import json,sys; print([l["pid"] for l in json.load(open(sys.argv[1]))["links"]][0])' "$B/conf/peerlink/state.json")
kill "$p1" 2>/dev/null
until_ok 6 link_rebuilt "$p1" && ok || fail "L: a master killed while quiet was not rebuilt: $(links)"
stop; unset FLEET_PEERLINK_ACTIVE_SECS FLEET_PEERLINK_PEERS_SECS; export FLEET_PEERLINK_IDLE_TICK=2
}

group() {   # group <name> <leg>… — in the background, its result in $WORK/res.<name>
  local g="$1"; shift
  (
    trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done' EXIT
    FAILS=0 CHECKS=0
    for l in "$@"; do "leg_$l"; done
    echo "$FAILS $CHECKS" > "$WORK/res.$g"
  ) > "$WORK/out.$g" 2>&1 &
  GROUPS_PIDS="${GROUPS_PIDS:-} $!"
}
group 1 A B D E
group 2 H
group 3 G I
group 4 L
group 5 C        # three whole fleet-doctor.sh runs
leg_F; leg_J; leg_K
for p in $GROUPS_PIDS; do wait "$p"; done
for g in 1 2 3 4 5; do
  cat "$WORK/out.$g"
  if [ -s "$WORK/res.$g" ]; then
    read -r f c < "$WORK/res.$g"; FAILS=$((FAILS + f)); CHECKS=$((CHECKS + c))
  else fail "group $g ended without its result"; fi
done

[ -n "${PEERLINK_SHOW:-}" ] && cat "$WORK/doctor-rows.txt"

if [ "$FAILS" -gt 0 ]; then printf 'fleet-peerlink selftest: %d FAILED, %d passed\n' "$FAILS" "$CHECKS" >&2; exit 1; fi
printf 'selftest OK: fleet-peerlink (%d checks — want · linger · doctor · sock · pane · units · routes · all · switch · list · exec/fwd · quiet)\n' "$CHECKS"
