#!/bin/bash
# fleet-peerlink-selftest.sh — bin/fleet-peerlink.py, the home machine's standing
# connections (issue #3002, EPIC #2999 C5). The five ways one goes bad are
# docs/BREAK-IT.md's peerlink-* drills (bin/fleet-break-it-peerlink-selftest.sh);
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
#   G. routes   — (issue #3482) where to dial: FLEET_REMOTE_SSH alone, else the
#                 hub's routes tailnet → entry (门) → the rest → the name; a name
#                 that does not resolve is never the only way (fleet-linux-0 via
#                 its entry `<addr>:<port>`), a failing route moves to the next
#   H. standing — (issue #3482) mode all: one link to each of your logins the hub
#                 lists, no view needed, never closed for being unused; a broken one
#                 comes back with backoff; a keeper that exits hands its masters to
#                 the next (adopted, same pid); the doctor names each peer 已连上 /
#                 重连中 / 连不上 and WARNs on 连不上
#   I. switch   — FLEET_PEERLINK_MODE=demand (fleet.conf, read by the wrapper):
#                 the hub's list opens nothing, the old on-demand links only
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
  # the hub's list of your logins elsewhere (fleet-peer-cert.sh --peers): $B/peers.json, else no hub
  printf '#!/bin/bash\n[ -f "%s/peers.json" ] || exit 3\ncat "%s/peers.json"\n' "$B" "$B" > "$B/peers.sh"; chmod +x "$B/peers.sh"
  export FLEET_CONF_DIR="$B/conf" TMPDIR="$B/t" FAKESSH_DIR="$B/fs" FLEET_PEERLINK_HOME=home \
    FLEET_PEERLINK_SSH="python3 $BIN/fleet-peerlink-fake-ssh.py" FLEET_PEERLINK_CERT_CMD="$B/cert.sh" \
    FLEET_PEERLINK_PEERS_CMD="$B/peers.sh"
  unset FLEET_C
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

# --- A. want ------------------------------------------------------------------
box a 1 m4:bob m4:carol "home:$ME" home:dave m9:bob:lost "m5:-"
start
until_ok 8 sh -c '[ "$(python3 -c "import json,sys; print(sum(l[\"phase\"] == \"up\" for l in json.load(open(sys.argv[1]))[\"links\"]))" "$1" 2>/dev/null)" = 4 ]' _ "$B/conf/peerlink/state.json" \
  || fail "A: four links never came up: $(links) · $(tail -3 "$B/run.err")"
[ "$(links)" = "home@dave:up m4@bob:up m4@carol:up m5@$ME:up" ] && ok \
  || fail "A: want set: got [$(links)] — want m4@bob m4@carol (two logins on one machine), home@dave (this machine, another login), m5 as $ME (no login known); not home@$ME, not the lost m9"
grep -q "^channel m4 bob id -un" "$B/fs/log" && grep -q "^master m4 bob " "$B/fs/log" && ok || fail "A: m4@bob was not opened as bob"
grep -q "^master m9 " "$B/fs/log" && fail "A: a lost machine was dialled" || ok
stop
box a2 0 m4:bob
start; sleep 2.5
[ -s "$B/fs/log" ] && fail "A: no thin view attached, yet ssh ran: $(cat "$B/fs/log")" || ok
[ -z "$(links)" ] && ok || fail "A: links with no view: $(links)"
stop

# --- B. linger -----------------------------------------------------------------
box b 1 m4:bob m5:bob
export FLEET_PEERLINK_LINGER=2
start
until_ok 8 links_is "m4@bob:up m5@bob:up" || fail "B: links never up: $(links)"
[ "$(masters_alive)" = 2 ] && ok || fail "B: $(masters_alive) masters alive, want 2"
kill "$VP" 2>/dev/null
until_ok 10 all_closed \
  && ok || fail "B: the view gone ${FLEET_PEERLINK_LINGER}s, still links [$(links)] / $(masters_alive) masters"
ls "$B/conf/peerlink/"*.sock >/dev/null 2>&1 && fail "B: control files left: $(ls "$B/conf/peerlink/")" || ok
grep -q '关闭：没人要了' "$B/run.err" && ok || fail "B: no close record"
stop; unset FLEET_PEERLINK_LINGER

# --- C. doctor -----------------------------------------------------------------
box c 1 m4:bob
out=$(python3 "$PL" status --check); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && ok || fail "C: never ran: rc $rc [$out], want rc 2 and nothing"
out=$(FLEET_CONF_DIR="$B/conf" bash "$BIN/fleet-doctor.sh" 2>/dev/null | grep peerlink)
[ -z "$out" ] && ok || fail "C: the doctor printed a peerlink row for a login it never ran on: $out"
start
until_ok 8 links_is "m4@bob:up" || fail "C: never up"
sleep 0.3
out=$(python3 "$PL" status --check); rc=$?
case "$out" in "全连 · 1 台对端：m4@bob 已连上 · 路线 m4 · "*" · 往返 "*" · 失败 0") [ "$rc" = 0 ] && ok || fail "C: healthy rc $rc" ;; *) fail "C: healthy line: [$out] rc $rc" ;; esac
out=$(bash "$BIN/fleet-doctor.sh" 2>/dev/null | grep peerlink)
case "$out" in *PASS*peerlink*m4@bob*) ok ;; *) fail "C: doctor row (healthy): [$out]" ;; esac
printf '%s\n' "doctor healthy: $out" > "$WORK/doctor-rows.txt"
stop
FLEET_PEERLINK_STALE=1 python3 "$PL" status --check >/dev/null; rc=$?
sleep 1.2
out=$(FLEET_PEERLINK_STALE=1 python3 "$PL" status --check); rc=$?
case "$out" in *管理者没在跑*) [ "$rc" = 1 ] && ok || fail "C: stopped keeper rc $rc" ;; *) fail "C: a stopped keeper reads [$out]" ;; esac
out=$(FLEET_PEERLINK_STALE=1 bash "$BIN/fleet-doctor.sh" 2>/dev/null | grep peerlink)
case "$out" in *WARN*peerlink*管理者没在跑*) ok ;; *) fail "C: doctor row (bad): [$out]" ;; esac
printf '%s\n' "doctor bad: $out" >> "$WORK/doctor-rows.txt"
[ -n "${PEERLINK_SHOW:-}" ] && cat "$WORK/doctor-rows.txt"

# --- D. sock -------------------------------------------------------------------
box d 1 m4:bob
python3 "$PL" sock m4 bob >/dev/null && fail "D: sock answered with no keeper" || ok
start
until_ok 8 links_is "m4@bob:up" || fail "D: never up"
[ "$(python3 "$PL" sock m4 bob)" = "$B/conf/peerlink/m4@bob.sock" ] && ok || fail "D: sock of a healthy link"
python3 "$PL" sock m4 carol >/dev/null && fail "D: sock for a link nobody holds" || ok
python3 "$PL" sock 'm4;x' bob >/dev/null 2>&1; [ $? = 2 ] && ok || fail "D: an unsafe name not refused"

# --- E. pane -------------------------------------------------------------------
out=$(python3 "$PL" pane m4 bob v1 </dev/null 2>&1)
case "$out" in *"ran bash .claude/fleet/bin/fleet-remote-view.sh attach --thin --view v1-via-home --resume"*) ok ;; *) fail "E: pane on a healthy link: [$out]" ;; esac
stop
box e 1
start
( python3 "$PL" pane m7 bob v1 </dev/null > "$B/pane.out" 2>&1 ) & pp=$!; PIDS="$PIDS $pp"
sleep 1.5
grep -q '正在连 m7（bob）' "$B/pane.out" && ok || fail "E: a pane before its link does not say it is connecting: $(cat "$B/pane.out")"
row m7:bob
until_ok 10 sh -c '! kill -0 "$1" 2>/dev/null' _ "$pp" && ok || fail "E: the pane did not ride the link once it came up"
grep -q 'attach --thin --view v1-via-home --resume' "$B/pane.out" && ok || fail "E: pane output: $(cat "$B/pane.out")"
stop

# --- F. units ------------------------------------------------------------------
T="$ROOT/launchd/com.claude-fleet.peerlink.plist.tmpl"
grep -q '<key>KeepAlive</key><true/>' "$T" && grep -q 'bin/fleet-peerlink.sh</string><string>run</string>' "$T" && ok \
  || fail "F: the launchd template is not a KeepAlive run of fleet-peerlink.sh"
grep -q '^ExecStart=/bin/bash __HOME__/.claude/fleet/bin/fleet-peerlink.sh run$' "$ROOT/systemd/claude-fleet-peerlink.service" \
  && grep -q '^Restart=always' "$ROOT/systemd/claude-fleet-peerlink.service" && ok || fail "F: the systemd twin"
grep -q '"$_npl" status --check' "$BIN/fleet-doctor.sh" && ok || fail "F: fleet-doctor.sh has no peerlink row"

# --- G. routes -----------------------------------------------------------------
# the order, as a unit: the operator's word alone; else tailnet → entry → the rest → the name
out=$(python3 - "$BIN" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("pl", os.path.join(sys.argv[1], "fleet-peerlink.py"))
pl = importlib.util.module_from_spec(spec); spec.loader.exec_module(pl)
peers = [{"hostname": "Fleet-Linux-0.cluster.local", "login": "fleet",
          "routes": [{"name": "lan", "host": "10.0.0.9"}, {"name": "entry", "host": "120.24.204.160", "port": 22022},
                     {"name": "tailnet", "host": "fl0.tail.ts.net"}, {"name": "entry-2", "host": "2001:db8::1", "port": 22022},
                     {"name": "bad", "host": "a;b"}]}]
print(" ".join("%s=%s:%d" % r for r in pl.routes_for("fleet-linux-0", peers)))
os.environ["FLEET_REMOTE_SSH"] = "fleet-linux-0=fl0-lan"
print(" ".join("%s=%s:%d" % r for r in pl.routes_for("fleet-linux-0", peers)))
del os.environ["FLEET_REMOTE_SSH"]
print(" ".join("%s=%s:%d" % r for r in pl.routes_for("m9", peers)))
PY
)
[ "$out" = "tailnet=fl0.tail.ts.net:0 entry=120.24.204.160:22022 entry-2=2001:db8::1:22022 lan=10.0.0.9:0 name=fleet-linux-0:0
conf=fl0-lan:0
name=m9:0" ] && ok || fail "G: route order: [$out]"

peers_json() {   # peers_json <hostname:login:route,route…>… — route = name=host[:port]
  python3 - "$@" > "$B/peers.json" <<'PY'
import json, sys
out = []
for a in sys.argv[1:]:
    h, lg, rs = (a.split(":", 2) + [""])[:3]
    routes = []
    for r in filter(None, rs.split(",")):
        n, _, hp = r.partition("=")
        host, _, port = hp.partition("/")
        routes.append({"name": n, "host": host, **({"port": int(port)} if port else {})})
    out.append({"hostname": h, "login": lg, "status": "online", "routes": routes})
print(json.dumps({"peers": out}))
PY
}
link_f() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print([l.get(sys.argv[3]) for l in s["links"] if "%s@%s" % (l["machine"], l["login"]) == sys.argv[2]][0])' "$B/conf/peerlink/state.json" "$1" "$2" 2>/dev/null; }
# fleet-linux-0 is on no tailnet and its name resolves nowhere: only its entry works
box g 0
export FLEET_NODE_ALIASES='macmini-m4=m4' FLEET_PEERLINK_PEERS_SECS=1 FLEET_PEERLINK_BACKOFF_MAX=4
mkdir -p "$B/fs/noname" "$B/fs/down"; touch "$B/fs/noname/fleet-linux-0"
touch "$B/fs/noname/m4.tail.ts.net"   # m4's tailnet name does not resolve from here today
peers_json "fleet-linux-0:fleet:entry=120.24.204.160/22022" "macmini-m4:bob:tailnet=m4.tail.ts.net,entry=203.0.113.4/22023" "home:$ME:tailnet=home.ts"
start
until_ok 10 links_is "fleet-linux-0@fleet:up m4@bob:up" && ok || fail "G: standing links: [$(links)] · $(tail -3 "$B/run.err")"
[ "$(link_f fleet-linux-0@fleet route)" = "120.24.204.160:22022" ] && ok || fail "G: fleet-linux-0 route [$(link_f fleet-linux-0@fleet route)], want its entry 120.24.204.160:22022"
grep -q "^master 120.24.204.160 fleet [0-9]* 22022$" "$B/fs/log" && ok || fail "G: no master on the entry's port: $(grep master "$B/fs/log")"
grep -q "^dial fleet-linux-0 " "$B/fs/log" && fail "G: the bare name was dialled before the entry" || ok
[ "$(link_f m4@bob route)" = "203.0.113.4:22023" ] && ok || fail "G: m4 did not fall from its tailnet name to its entry: [$(link_f m4@bob route)]"
grep -q "^dial m4.tail.ts.net " "$B/fs/log" && ok || fail "G: m4's tailnet name was not tried first"
[ "$(python3 -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("pl", sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(" ".join(m.mux_dest("fleet-linux-0", "fleet")))' "$PL")" = "-p 22022 120.24.204.160" ] \
  && ok || fail "G: a channel on fleet-linux-0's link does not name its entry"
out=$(python3 "$PL" pane fleet-linux-0 fleet v1 </dev/null 2>&1)
case "$out" in *"ran bash .claude/fleet/bin/fleet-remote-view.sh attach --thin"*) ok ;; *) fail "G: pane over the entry: [$out]" ;; esac
grep -q "^master home " "$B/fs/log" && fail "G: this very login was dialled" || ok

# --- H. standing ---------------------------------------------------------------
# never closed for being unused (no view, linger 1 s)
p0=$(link_f m4@bob pid)
stop; export FLEET_PEERLINK_LINGER=1; start
until_ok 8 grep -q 'm4@bob adopted' "$B/run.err" || fail "H: m4 not adopted by the next keeper: $(tail -4 "$B/run.err")"
until_ok 8 links_is "fleet-linux-0@fleet:up m4@bob:up" || fail "H: not up after a keeper restart: $(links)"
[ "$(link_f m4@bob pid)" = "$p0" ] && ok || fail "H: the keeper's restart rebuilt m4 (pid $(link_f m4@bob pid), was $p0) — not handed over"
grep -q 'm4@bob 交给下一个管理者' "$B/run.err" && ok || fail "H: no hand-over record: $(tail -5 "$B/run.err")"
sleep 3.5
links_is "fleet-linux-0@fleet:up m4@bob:up" && ok || fail "H: a standing link was closed with no view: $(links)"
grep -q '关闭：没人要了' "$B/run.err" && fail "H: a standing link was reaped for being unused" || ok
out=$(python3 "$PL" status --check); rc=$?
case "$out" in "全连 · 2 台对端："*"fleet-linux-0@fleet 已连上 · 路线 120.24.204.160:22022"*"m4@bob 已连上"*) [ "$rc" = 0 ] && ok || fail "H: doctor rc $rc" ;; *) fail "H: doctor line [$out]" ;; esac
# it breaks and the entry is gone for a while: 重连中, a backoff (not a dial per beat), then 连不上 + WARN, then back
touch "$B/fs/down/120.24.204.160"
n0=$(grep -c '^dial 120.24.204.160 ' "$B/fs/log")
kill "$(link_f fleet-linux-0@fleet pid)"
until_ok 5 sh -c 'python3 "$1" status --check | grep -q "fleet-linux-0@fleet 重连中"' _ "$PL" && ok || fail "H: a broken link does not read 重连中: $(python3 "$PL" status --check)"
sleep 6
n1=$(grep -c '^dial 120.24.204.160 ' "$B/fs/log")
[ $((n1 - n0)) -ge 2 ] && [ $((n1 - n0)) -le 6 ] && ok || fail "H: $((n1 - n0)) dials in ~6 s to a dead entry — want a retry with backoff (2..6)"
out=$(FLEET_PEERLINK_BAD_WARN=2 python3 "$PL" status --check); rc=$?
case "$out" in *"fleet-linux-0@fleet 连不上"*"Connection refused（120.24.204.160:22022）"*"Could not resolve hostname fleet-linux-0"*) [ "$rc" = 1 ] && ok || fail "H: 连不上 rc $rc" ;; *) fail "H: a dead peer reads [$out]" ;; esac
rm -f "$B/fs/down/120.24.204.160"
until_ok 35 sh -c '[ "$(python3 -c "import json,sys; print([l[\"phase\"] for l in json.load(open(sys.argv[1]))[\"links\"] if l[\"machine\"] == \"fleet-linux-0\"][0])" "$1")" = up ]' _ "$B/conf/peerlink/state.json" \
  && ok || fail "H: never came back once the entry did: $(links)"
# a login the hub no longer lists goes (linger), the rest stay
peers_json "macmini-m4:bob:tailnet=m4.tail.ts.net,entry=203.0.113.4/22023"
until_ok 10 links_is "m4@bob:up" && ok || fail "H: a login the hub dropped still linked: $(links)"
grep -q 'fleet-linux-0@fleet 关闭：不再是你的登录' "$B/run.err" && ok || fail "H: no record of the dropped login"
stop; unset FLEET_PEERLINK_LINGER FLEET_NODE_ALIASES FLEET_PEERLINK_PEERS_SECS FLEET_PEERLINK_BACKOFF_MAX
awk '$1 == "master" { print $4 }' "$B/fs/log" | while read -r p; do kill "$p" 2>/dev/null; done

# --- I. switch -----------------------------------------------------------------
box i 0
mkdir -p "$B/conf"; printf 'FLEET_PEERLINK_MODE=demand\n' > "$B/conf/fleet.conf"
peers_json "macmini-m4:bob:entry=203.0.113.4/22023"
bash "$BIN/fleet-peerlink.sh" run 2>>"$B/run.err" & KP=$!; PIDS="$PIDS $KP"
sleep 3
[ -s "$B/fs/log" ] && fail "I: demand mode dialled the hub's list: $(cat "$B/fs/log")" || ok
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mode"])' "$B/conf/peerlink/state.json")" = demand ] && ok || fail "I: fleet.conf's switch did not reach the keeper"
out=$(python3 "$PL" status --check)
case "$out" in "按需 · 没有常开连接（无看台）") ok ;; *) fail "I: demand doctor line [$out]" ;; esac
stop

if [ "$FAILS" -gt 0 ]; then printf 'fleet-peerlink selftest: %d FAILED, %d passed\n' "$FAILS" "$CHECKS" >&2; exit 1; fi
printf 'selftest OK: fleet-peerlink (%d checks — want · linger · doctor · sock · pane · units · routes · standing · switch)\n' "$CHECKS"
