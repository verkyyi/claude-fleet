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
  export FLEET_CONF_DIR="$B/conf" TMPDIR="$B/t" FAKESSH_DIR="$B/fs" FLEET_PEERLINK_HOME=home \
    FLEET_PEERLINK_SSH="python3 $BIN/fleet-peerlink-fake-ssh.py" FLEET_PEERLINK_CERT_CMD="$B/cert.sh"
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
case "$out" in "1 条常开连接：m4@bob 路线 m4 · "*" · 往返 "*" · 失败 0") [ "$rc" = 0 ] && ok || fail "C: healthy rc $rc" ;; *) fail "C: healthy line: [$out] rc $rc" ;; esac
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

if [ "$FAILS" -gt 0 ]; then printf 'fleet-peerlink selftest: %d FAILED, %d passed\n' "$FAILS" "$CHECKS" >&2; exit 1; fi
printf 'selftest OK: fleet-peerlink (%d checks — want · linger · doctor · sock · pane · units)\n' "$CHECKS"
