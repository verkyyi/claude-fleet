#!/bin/bash
# fleet-service-takeover-selftest.sh — pins task BZGP: a registered service whose
# unix socket an old ORPHAN of the same service still answers on takes it back
# (bin/fleet-service-takeover.py, run by `fleet-webchat.sh serve`); anything else
# holding it is left alone and named (pid · command · started), exit 3.
#
#   A  nobody answers (no socket · a stale socket file) ⇒ exit 0, nothing said
#   B  an orphan of the service (PPID init, its argv the service's) ⇒ TERM'd,
#      exit 0, one line naming what it stopped; the socket answers no more
#   C  an orphan that ignores TERM ⇒ KILL after FLEET_SERVICE_TAKEOVER_WAIT
#   D  a holder that is NOT an orphan (its parent alive — a person's terminal,
#      another managed copy) ⇒ left running, exit 3, the line names its pid,
#      command and start, and the next step
#   E  an orphan whose argv is not the service's ⇒ left alone, exit 3
#   F  usage ⇒ exit 2
#   G  the alert line says the next step (fleet-services.py --alerts)
#   H  (task CVC4) the holder's parent is alive but is itself an orphan of the
#      service's shell (`fleet-webchat.sh serve`, PPID init, our uid) ⇒ both
#      stopped, exit 0, the socket answers no more
#   I  the same with a shell that is not the service's ⇒ left alone, exit 3
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/  /' >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1" "want: [$2]
 got: [$3]"; st_count; }
has() { case "$3" in *"$2"*) st_count ;; *) fail "$1" "want a substring: [$2]
 got: [$3]" ;; esac; }

# a unix socket path stays under 104 bytes: never a long TMPDIR
WORK=$(mktemp -d /tmp/fst.XXXXXX) || exit 2
PIDS=()
REAPER=1
cleanup() { local p; for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT
TK="$BIN/fleet-service-takeover.py"
SOCK="$WORK/chat.sock"; PIDF="$WORK/pid"

HOLDER='import os, signal, socket, sys
signal.alarm(60)   # never outlives the test
if sys.argv[3] == "1":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8)
open(sys.argv[2], "w").write("%d\n" % os.getpid())
while True:
    c, _ = s.accept(); c.close()'

printf '%s\n' "$HOLDER" > "$WORK/h.py"
wait_pid() { local _; for _ in $(seq 1 50); do [ -s "$PIDF" ] && return 0; sleep 0.1; done; fail "the holder did not come up"; }
# <orphan|child> <ignore TERM 0|1> <argv tail…>
holder() {
  local how=$1 ign=$2; shift 2
  rm -f "$SOCK" "$PIDF"
  if [ "$how" = orphan ]; then
    ( python3 "$WORK/h.py" "$SOCK" "$PIDF" "$ign" "$@" </dev/null >/dev/null 2>&1 & )
  else
    python3 "$WORK/h.py" "$SOCK" "$PIDF" "$ign" "$@" </dev/null >/dev/null 2>&1 & disown
  fi
  wait_pid; HP=$(cat "$PIDF"); PIDS+=("$HP")
  # where this box's orphans land (init, or a Linux subreaper)
  [ "$how" = orphan ] && REAPER=$(ps -o ppid= -p "$HP" | tr -d ' ')
  [ "$REAPER" != "$$" ] || fail "an orphan's parent is this shell"
}
alive() { kill -0 "$1" 2>/dev/null; }
tk() { FLEET_SERVICE_TAKEOVER_WAIT=${WAIT:-10} FLEET_SERVICE_TAKEOVER_REAPER=${REAPER:-1} \
       python3 -I "$TK" --name webchat --socket "$SOCK" --pidfile "$PIDF" --match extras/web-chat/server.mjs --match --socket \
       --shell-match fleet-webchat.sh --shell-match serve; }
answers() { python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX)
try: s.connect(sys.argv[1])
except OSError: sys.exit(1)' "$SOCK"; }

# ------------------------------------------------------------------------- A ----
out=$(tk 2>&1); eq "A: no socket: exit 0" 0 "$?"; eq "A: …nothing said" "" "$out"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$SOCK"
out=$(tk 2>&1); eq "A: a stale socket nobody answers on: exit 0" 0 "$?"; eq "A: …nothing said" "" "$out"

# ------------------------------------------------------------------------- B ----
holder orphan 0 /old/runtime/extras/web-chat/server.mjs --socket
answers || fail "B: the orphan does not answer"
out=$(tk 2>&1); rc=$?
eq "B: an orphan of the service is taken over: exit 0" 0 "$rc"
alive "$HP" && fail "B: the orphan still runs"; st_count
has "B: the line says what it stopped" "接管 ${SOCK}：停掉了旧孤儿（pid $HP · " "$out"
has "B: …its command" "/old/runtime/extras/web-chat/server.mjs --socket" "$out"
has "B: …TERM was enough" "，TERM）" "$out"
answers && fail "B: the socket still answers"; st_count

# ------------------------------------------------------------------------- C ----
holder orphan 1 /old/extras/web-chat/server.mjs --socket
t0=$(date +%s)
out=$(WAIT=1 tk 2>&1); rc=$?
eq "C: an orphan that ignores TERM: exit 0" 0 "$rc"
alive "$HP" && fail "C: it still runs"; st_count
has "C: …KILLed" "，KILL）" "$out"
[ $(( $(date +%s) - t0 )) -lt 9 ] || fail "C: the wait was not bounded by FLEET_SERVICE_TAKEOVER_WAIT"; st_count

# ------------------------------------------------------------------------- D ----
holder child 0 /x/extras/web-chat/server.mjs --socket
out=$(tk 2>&1); rc=$?
eq "D: a holder whose parent is alive: exit 3" 3 "$rc"
alive "$HP" || fail "D: it was stopped"; st_count
has "D: the line names the holder" "被占着：pid ${HP} · " "$out"
has "D: …and when it started" " · 起于 " "$out"
has "D: …and the next step" "fleet service stop webchat" "$out"
kill -9 "$HP" 2>/dev/null

# ------------------------------------------------------------------------- E ----
holder orphan 0 some-other-server --socket
out=$(tk 2>&1); rc=$?
eq "E: an orphan of something else: exit 3" 3 "$rc"
alive "$HP" || fail "E: it was stopped"; st_count
has "E: …named, not the service's" "不是本服务的孤儿" "$out"
kill -9 "$HP" 2>/dev/null

# ------------------------------------------------------------------------- F ----
python3 -I "$TK" --name webchat >/dev/null 2>&1; eq "F: usage: exit 2" 2 "$?"

# ------------------------------------------------------------------------- G ----
cat > "$WORK/state.json" <<EOF
{"services": [{"name": "webchat", "kind": "service", "login": "$(id -un)", "status": "down", "last_rc": 3}]}
EOF
a=$(FLEET_SERVICES_CACHE='' FLEET_SERVICES_STATE="$WORK/state.json" FLEET_SERVICES_HOST=box python3 "$BIN/fleet-services.py" --alerts)
has "G: the alert says the daemon retries and where the reason is" "守护每 30 s 重起一次；原因看 fleet service logs webchat" "$a"

# ------------------------------------------------------------------------- H ----
# <script name> — an orphaned shell (PPID init) running the holder as its child
shell_holder() {
  rm -f "$SOCK" "$PIDF"
  printf '#!/bin/bash\npython3 "%s" "%s" "%s" 0 /old/extras/web-chat/server.mjs --socket\n: done\n' \
    "$WORK/h.py" "$SOCK" "$PIDF" > "$WORK/$1"
  ( bash "$WORK/$1" serve </dev/null >/dev/null 2>&1 & )
  wait_pid; HP=$(cat "$PIDF"); PIDS+=("$HP")
  SP=$(ps -o ppid= -p "$HP" | tr -d ' '); PIDS+=("$SP")
  REAPER=$(ps -o ppid= -p "$SP" | tr -d ' ')
  [ "$REAPER" != "$$" ] || fail "the shell's parent is this shell"
  case "$(ps -o args= -p "$SP")" in *"$1"*) ;; *) fail "the holder's parent is not the shell";; esac
}
shell_holder fleet-webchat.sh
out=$(tk 2>&1); rc=$?
eq "H: a holder whose shell is an orphan of the service: exit 0" 0 "$rc"
alive "$HP" && fail "H: the holder still runs"; st_count
for _ in $(seq 1 25); do alive "$SP" || break; sleep 0.2; done
alive "$SP" && fail "H: the orphaned shell still runs"; st_count
has "H: the line says what it stopped" "接管 ${SOCK}：停掉了旧孤儿（pid $HP · " "$out"
answers && fail "H: the socket still answers"; st_count

# ------------------------------------------------------------------------- I ----
shell_holder other-launcher.sh
out=$(tk 2>&1); rc=$?
eq "I: a holder under an orphaned shell that is not the service's: exit 3" 3 "$rc"
alive "$HP" || fail "I: the holder was stopped"; st_count
alive "$SP" || fail "I: the shell was stopped"; st_count
has "I: …named, not the service's" "不是本服务的孤儿" "$out"
kill -9 "$HP" "$SP" 2>/dev/null

echo "fleet-service-takeover-selftest: PASS ($CHECKS checks)"
