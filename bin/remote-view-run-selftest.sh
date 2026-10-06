#!/bin/bash
# remote-view-run-selftest.sh — the proxy pane's `run` loop
# (bin/fleet-remote-view.sh run) against the two halves of one reconnect storm:
#   issue #1775 — a static `RemoteForward 2226` in ~/.ssh/config is asked again by
#                 every session on a shared master; the second ask is refused and a
#                 refused mux client never attaches → reconnect → ask → refused …
#   issue #1704 — the attach ran in the FOREGROUND, so a TERM never reached the
#                 cleanup trap (orphans needed kill -KILL); the first click raced
#                 the shell's warm master and opened a private one beside it.
#
#   A. forwards  — a session on the warm master carries ClearAllForwardings=yes
#                  (the attach AND the sidecar's watch); a private master carries
#                  ExitOnForwardFailure=no and keeps the config's forwards
#   B. warm wait — a warm master still coming up (`<sock>.pending` alive) is waited
#                  for, not raced; none coming → a private master, and warm.log
#                  says `private <node>`
#   C. words     — a refused forward drops the line with 「端口转发被拒…」, never
#                  ssh's raw `mux_client_forward: …`
#   D. TERM      — TERM to a `run` whose attach never returns ends the loop AND the
#                  attach within seconds (no kill -KILL)
#   E. pane gone — (tmux on an isolated socket) the pane killed under `run`: the
#                  loop and its attach are gone, no orphan holding a view session
# ssh is a shim (FLEET_REMOTE_SSH_CMD) that logs its argv. python3 absent → SKIP.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rvrun.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
TSOCK="rvrun$$"
cleanup() {   # a red D/E leaves exactly what it tests for: KILL it, never leak it
  local p
  for p in $(cat "$WORK/pids" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
  tmux -L "$TSOCK" kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

FAILS=0 CHECKS=0
fail() { FAILS=$((FAILS + 1)); printf 'FAIL: %s\n' "$1"; [ -n "${2:-}" ] && printf '      got: %s\n' "$2"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (must not hold '$3')" "$2" ;; esac; }
ok() { CHECKS=$((CHECKS + 1)); "${@:2}" || fail "$1"; }
alive() { kill -0 "$1" 2>/dev/null; }
gone_within() {   # <pid> <secs>
  local i=0
  while alive "$1"; do i=$((i + 1)); [ "$i" -gt $(( $2 * 10 )) ] && return 1; sleep 0.1; done
  return 0
}

mkdir -p "$WORK/tmp/warm" "$WORK/home" "$WORK/conf"
export HOME="$WORK/home" TMPDIR="$WORK/tmp" FLEET_CONF_DIR="$WORK/conf"
unset TMUX TMUX_PANE FLEET_SHELL_STAGE
cat > "$WORK/ssh" <<'EOF'
#!/bin/bash
# argv → $FAKE_LOG; -O check = is the control socket there; -O exit = rm it.
printf '%s\n' "$*" >> "$FAKE_LOG"
op='' ctl='' args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    -O) op=$2; shift 2 ;;
    -o) case "$2" in ControlPath=*) ctl=${2#ControlPath=} ;; esac; shift 2 ;;
    -S) ctl=$2; shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
if [ -n "$op" ]; then
  case "$op" in check) [ -S "$ctl" ]; exit $? ;; exit) rm -f "$ctl"; exit 0 ;; *) exit 0 ;; esac
fi
case "$*" in
  *" attach"*)
    case "${FAKE_MODE:-ok}" in
      hang) printf '%s\n' $$ > "$FAKE_DIR/hang.pid"; exec sleep 300 ;;
      refuse-once)
        if [ ! -e "$FAKE_DIR/refused" ]; then
          : > "$FAKE_DIR/refused"
          echo 'mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 2226' >&2
          echo 'muxclient: master forward request failed' >&2
          exit 255
        fi
        exit 0 ;;
      *) sleep "${FAKE_ATTACH_SECS:-0}"; exit 0 ;;
    esac ;;
  *) exit 0 ;;   # watch / serve / select: nothing to say
esac
EOF
chmod +x "$WORK/ssh"
export FLEET_REMOTE_SSH_CMD="$WORK/ssh" FAKE_LOG="$WORK/ssh.log" FAKE_DIR="$WORK"
export FLEET_REMOTE_VIA_HUB=0
RV="$BIN/fleet-remote-view.sh"
WID="00000000-0000-0000-0000-000000000000/issue-1"
bindsock() { python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$1"; }

# --- A + B. a warm master still coming up is waited for, and ridden clean -------------
: > "$WORK/ssh.log"
WS="$WORK/tmp/warm/m9.sock"
sleep 3 & pend=$!
printf '%s\n' "$pend" > "$WS.pending"
( sleep 0.8; bindsock "$WS" ) &
FAKE_ATTACH_SECS=2 bash "$RV" run --shell m9 "$WID" > "$WORK/a.out" 2>&1 < /dev/null
kill "$pend" 2>/dev/null
att=$(grep ' attach' "$WORK/ssh.log")
has 'B: the attach rides the warm master that came up a moment later' "$att" "-S $WS"
hasnt 'B: …no private master opened beside it' "$att" 'ControlMaster=yes'
has 'A: a session on the warm master clears the config forwards' "$att" '-o ClearAllForwardings=yes'
has "A: …so does the sidecar's watch" "$(grep ' watch ' "$WORK/ssh.log")" '-o ClearAllForwardings=yes'
hasnt 'B: warm.log has no private line' "$(cat "$WORK/tmp/warm/warm.log" 2>/dev/null)" 'private'

: > "$WORK/ssh.log"; rm -f "$WS" "$WS.pending"
bash "$RV" run --shell m9 "$WID" > "$WORK/b.out" 2>&1 < /dev/null
att=$(grep ' attach' "$WORK/ssh.log")
has 'B: nothing warm coming → a private master' "$att" 'ControlMaster=yes'
has 'A: …which never dies of a forward it cannot get' "$att" '-o ExitOnForwardFailure=no'
hasnt "A: …and keeps the config's forwards (it is the one that holds them)" "$att" 'ClearAllForwardings'
has 'B: …and warm.log says so' "$(cat "$WORK/tmp/warm/warm.log" 2>/dev/null)" 'private m9'

# --- C. a refused forward is said in words -------------------------------------------
: > "$WORK/ssh.log"; rm -f "$WORK/refused"
FAKE_MODE=refuse-once bash "$RV" run m9 "$WID" > "$WORK/c.out" 2>&1 < /dev/null
out=$(cat "$WORK/c.out")
has 'C: the drop says 端口转发被拒' "$out" '端口转发被拒'
hasnt "C: …never ssh's raw words" "$out" 'mux_client_forward'
eq_attaches=$(grep -c ' attach' "$WORK/ssh.log")
CHECKS=$((CHECKS + 1)); [ "$eq_attaches" = 2 ] || fail 'C: one refused round, one good one' "$eq_attaches"
CHECKS=$((CHECKS + 1)); ls "$WORK/tmp"/frv.* >/dev/null 2>&1 && fail 'C: nothing of the connection left in tmp/' "$(ls "$WORK/tmp")"

# --- D. TERM reaches the cleanup ------------------------------------------------------
rm -f "$WORK/hang.pid"
FAKE_MODE=hang bash "$RV" run m9 "$WID" > "$WORK/d.out" 2>&1 < /dev/null &
run=$!
for _ in $(seq 1 50); do [ -s "$WORK/hang.pid" ] && break; sleep 0.1; done
hang=$(cat "$WORK/hang.pid" 2>/dev/null)
printf '%s %s\n' "$run" "$hang" >> "$WORK/pids"
ok 'D: the attach is up' test -n "$hang"
kill -TERM "$run" 2>/dev/null
ok 'D: TERM ends the run loop within 3s' gone_within "$run" 3
ok 'D: …and its attach with it' gone_within "${hang:-0}" 3
rm -f "$WORK/hang.pid"

# --- E. a pane killed under `run` takes it with it -------------------------------------
if command -v tmux >/dev/null 2>&1; then
  rm -f "$WORK/hang.pid"
  tmux -L "$TSOCK" -f /dev/null new-session -d -s e -x 80 -y 20 \
    "FLEET_REMOTE_SSH_CMD=$WORK/ssh FAKE_LOG=$WORK/ssh.log FAKE_DIR=$WORK FAKE_MODE=hang HOME=$HOME TMPDIR=$TMPDIR FLEET_CONF_DIR=$FLEET_CONF_DIR FLEET_REMOTE_VIA_HUB=0 exec bash $RV run m9 $WID"
  tmux -L "$TSOCK" new-window -d -t e: 'sleep 600'   # the server outlives the pane
  for _ in $(seq 1 50); do [ -s "$WORK/hang.pid" ] && break; sleep 0.1; done
  hang=$(cat "$WORK/hang.pid" 2>/dev/null)
  run=$(tmux -L "$TSOCK" display-message -p -t e:0 '#{pane_pid}' 2>/dev/null)
  printf '%s %s\n' "$run" "$hang" >> "$WORK/pids"
  ok 'E: the attach is up in the pane' test -n "$hang"
  tmux -L "$TSOCK" kill-pane -t e:0 2>/dev/null
  ok 'E: the pane gone → the run loop gone within 4s' gone_within "${run:-0}" 4
  ok 'E: …and its attach with it' gone_within "${hang:-0}" 4
  rm -f "$WORK/hang.pid"
else
  echo 'skip E: no tmux'
fi

if [ "$FAILS" -gt 0 ]; then printf '%d/%d checks FAILED\n' "$FAILS" "$CHECKS"; exit 1; fi
printf 'PASS: %d checks\n' "$CHECKS"
