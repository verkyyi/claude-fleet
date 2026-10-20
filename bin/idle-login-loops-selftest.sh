#!/bin/bash
# idle-login-loops-selftest.sh — a login nobody uses runs no per-login loop for
# nobody, and the loops that do run fork little (issue #4261: a shared 15-core node at load ~20
# with ~970 forks/s, most of them each login's polling scripts).
#
#   A. fleet_login_unused   0 sessions awake + 0 asleep, a fresh row, no client on
#      any fleet socket (tmux keeps a socket u+x while one is attached) ⇒ unused;
#      a session, an asleep worker, a client, a stale / missing row, or
#      FLEET_HUBSESS_IDLE_SKIP=0 ⇒ in use (never a reason to stop anything)
#   B. the collector        ph_hubsess asks fleet_login_unused before --ensure
#      (bin/tmux-dash-collect.sh) — the hub-sessions loop is not kept alive on an
#      unused login
#   C. the node's table     the spinner is a `session` unit (conf/node-tasks.tsv):
#      the root daemon (bin/fleet-node-supervisor.py no_session) does not run it
#      for a login with no session — fleet-node-supervisor-selftest.py drives that gate
#   D. hub-sessions idle    an unwatched node loop (no client) refreshes every
#      FLEET_HUB_SESSIONS_IDLE_EVERY, not EVERY; an explicit
#      FLEET_HUB_SESSIONS_EVERY is its idle pace too; a client attaching (socket
#      u+x) ends the nap at once (bin/fleet-hub-sessions.sh idle_nap)
#   E. no fork per id       fleet_is_fid (bin/fleet-lib.sh) is a `case`: right on
#      the shape, wrong on upper case / length, and 2,000 asks fork nothing — the
#      restore snapshot asked it of every retired mark (~4,000) every minute
#   F. one tmux a window    fleet-cleanup-idle.py's snapshot reads a window's
#      options in ONE display-message (it was one per option, 28)
# The spinner's half (no frames for nobody) is spinner-rate-selftest.sh UNWATCHED.
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/idleloops.XXXXXX")" || exit 2
LOOPPID=''
WATCHSOCK=''
REAL_TMUX="$(command -v tmux)"
cleanup() { [ -z "$WATCHSOCK" ] || "$REAL_TMUX" -S "$WATCHSOCK" kill-server 2>/dev/null; [ -n "$LOOPPID" ] && kill "$LOOPPID" 2>/dev/null; pkill -f "$WORK/" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

st_tally
ok()   { CHECKS=$((CHECKS + 1)); printf '  ok   %s\n' "$1"; }

# --- A: fleet_login_unused -----------------------------------------------------
lib_ask() {   # lib_ask <row|-> [env...] -- [sockets...] → "unused" | "used"
  local row="$1"; shift
  local envs=() socks=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  socks=("$@")
  rm -f "$WORK/sess/u1"
  [ "$row" = - ] || printf '%s\n' "$row" > "$WORK/sess/u1"
  env ${envs[@]+"${envs[@]}"} HOME="$WORK/home/u1" FLEET_MACHINE_SESSIONS_DIR="$WORK/sess" TMUX_TMPDIR="$WORK/tt" \
    bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1; shift; if fleet_login_unused "$@"; then echo unused; else echo used; fi' \
    _ "$BIN" ${socks[@]+"${socks[@]}"}
}
mkdir -p "$WORK/sess" "$WORK/home/u1" "$WORK/tt/tmux-$(id -u)"
SD="$WORK/tt/tmux-$(id -u)"
: > "$SD/fa"; chmod 600 "$SD/fa"; : > "$SD/fb"; chmod 600 "$SD/fb"
now=$(date +%s)
expect() { if [ "$2" = "$3" ]; then ok "A: $1 → $3"; else st_miss "A: $1 → $3, want $2"; fi; }
expect "0 sessions, 0 asleep, no client"        unused "$(lib_ask "0 $now 0" -- fa fb)"
expect "0 sessions (an older row, no asleep)"   unused "$(lib_ask "0 $now" -- fa)"
expect "a live session"                          used   "$(lib_ask "1 $now 0" -- fa)"
expect "an asleep worker"                        used   "$(lib_ask "0 $now 2" -- fa)"
expect "a stale row (10 min)"                    used   "$(lib_ask "0 $((now - 600)) 0" -- fa)"
expect "no row at all"                           used   "$(lib_ask - -- fa)"
expect "a garbled row"                           used   "$(lib_ask "x $now 0" -- fa)"
expect "FLEET_HUBSESS_IDLE_SKIP=0"               used   "$(lib_ask "0 $now 0" FLEET_HUBSESS_IDLE_SKIP=0 -- fa)"
chmod u+x "$SD/fb"
expect "a client on one fleet socket (u+x)"      used   "$(lib_ask "0 $now 0" -- fa fb)"
expect "…a client on a socket not ours"          unused "$(lib_ask "0 $now 0" -- fa)"

# --- B: the collector asks it ----------------------------------------------------
if awk '/^ph_hubsess\(\) \{/{f=1} f&&/fleet_login_unused/{found=1} f&&/^\}/{exit} END{exit !found}' "$BIN/tmux-dash-collect.sh"; then
  ok "B: tmux-dash-collect.sh ph_hubsess asks fleet_login_unused before --ensure"
else st_miss "B: ph_hubsess keeps the hub-sessions loop alive on a login nobody uses"; fi

# --- C: the node's table -----------------------------------------------------------
cls() { awk -F'\t' -v u="$1" '$1 == u && $2 == "unit" { print $3 }' "$BIN/../conf/node-tasks.tsv"; }
if [ "$(cls spinner)" = session ]; then ok "C: spinner runs only while its login has a session"
else st_miss "C: spinner is a '$(cls spinner)' unit — it runs on a login with no session"; fi

# --- D: the hub-sessions loop's idle pace --------------------------------------------
S="idl$$"
G="$WORK/.claude-dash/global"
mkdir -p "$G" "$WORK/conf/fleets/$S" "$WORK/bin" "$WORK/main"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$WORK/conf/fleets/$S/conf"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/tmux"; chmod +x "$WORK/bin/tmux"   # no client anywhere
printf '{"machines": [], "sessions": [], "nodes": []}\n' > "$WORK/sessions.json"
printf '#!/bin/sh\necho r >> "%s/rounds"\ncat "%s/sessions.json"\n' "$WORK" "$WORK" > "$WORK/hubcmd"; chmod +x "$WORK/hubcmd"
rounds_in() {   # rounds_in <secs> [env...] → the loop's rounds over <secs>
  local secs="$1"; shift
  : > "$WORK/rounds"
  ( unset CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_NODE_ALIASES FLEET_HUB_SESSIONS_USER FLEET_HUB_SESSIONS_STALE \
          FLEET_HUB_SESSIONS_CLIENT TMUX TMUX_PANE FLEET_HUB_URL FLEET_CERT XDG_CONFIG_HOME FLEET_ACCOUNTS_DIR \
          FLEET_HUB_SESSIONS_EVERY FLEET_HUB_SESSIONS_IDLE_EVERY
    export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" PATH="$WORK/bin:$PATH" \
           CCQUOTA_FLEET=1 FLEET_HUB_SESSIONS_CMD="$WORK/hubcmd" FLEET_HUB_SESSIONS_WATCHED_EVERY=1 \
           FLEET_HUB_SESSIONS_LOOP_SECS=60 TMUX_TMPDIR="$WORK/tt"
    for kv in "$@"; do export "${kv?}"; done
    exec bash "$BIN/fleet-hub-sessions.sh" --loop ) </dev/null >/dev/null 2>&1 &
  LOOPPID=$!
  sleep "$secs"
  kill "$LOOPPID" 2>/dev/null; wait "$LOOPPID" 2>/dev/null; LOOPPID=''
  pkill -f "$BIN/fleet-hub-sessions.sh --loop" 2>/dev/null
  rm -f "$G/hubsess.pid" "$G/hubsess.lock"
  grep -c . "$WORK/rounds" 2>/dev/null || echo 0
}
n=$(rounds_in 7 FLEET_HUB_SESSIONS_IDLE_EVERY=4)
if [ "$n" -ge 1 ] && [ "$n" -le 2 ]; then ok "D: unwatched node, IDLE_EVERY=4 → $n rounds in 7s"
else st_miss "D: unwatched node, IDLE_EVERY=4 → $n rounds in 7s, want 1-2"; fi
n=$(rounds_in 6 FLEET_HUB_SESSIONS_EVERY=1)
if [ "$n" -ge 4 ]; then ok "D: an explicit FLEET_HUB_SESSIONS_EVERY=1 is the idle pace too → $n rounds in 6s"
else st_miss "D: an explicit FLEET_HUB_SESSIONS_EVERY=1 → $n rounds in 6s, want ≥ 4 (its own pace)"; fi
# A real list request with a client wakes the shared event wait (#4357).
# An attached socket alone is no longer a list request; keep the original time
# and count bounds, exercise the production broadcast on a PRIVATE server.
WATCHSOCK="$SD/$S"
chmod 700 "$SD"
TMUX_TMPDIR="$WORK/tt" "$REAL_TMUX" -L "$S" -f /dev/null new-session -d -s "$S" 'sleep 30'
printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_TMUX" > "$WORK/bin/tmux"
python3 - "$REAL_TMUX" "$WATCHSOCK" "$G/hubsess.view" <<'PY_VIEW' &
import pathlib, subprocess, sys, time
time.sleep(3)
client = subprocess.Popen([sys.argv[1], '-S', sys.argv[2], '-C', 'attach'],
                          stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
try:
    pathlib.Path(sys.argv[3]).touch()
    subprocess.run([sys.argv[1], '-S', sys.argv[2], 'wait-for', '-S', 'fleet-state-changed'], check=True)
    time.sleep(4)
finally:
    client.terminate()
    client.wait()
PY_VIEW
VIEWPID=$!
n=$(rounds_in 6 FLEET_HUB_SESSIONS_IDLE_EVERY=30)
wait "$VIEWPID"
"$REAL_TMUX" -S "$WATCHSOCK" kill-server 2>/dev/null; WATCHSOCK=''
if [ "$n" -ge 2 ]; then ok "D: a client opens the list mid-wait → $n rounds in 6s"
else st_miss "D: a real list request slept on → $n rounds in 6s, want ≥ 2"; fi

# --- E: fleet_is_fid forks nothing -----------------------------------------------------
out=$(bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1
  for x in 39a7bf15-6049-4271-9528-b4760415b544 39A7BF15-6049-4271-9528-b4760415b544 \
           39a7bf15-6049-4271-9528-b4760415b5444 x39a7bf15-6049-4271-9528-b4760415b544 "" 39a7bf15604942719528b4760415b544; do
    fleet_is_fid "$x" && printf 1 || printf 0
  done' _ "$BIN")
if [ "$out" = 100000 ]; then ok "E: fleet_is_fid — the canonical shape only ($out)"
else st_miss "E: fleet_is_fid answered $out, want 100000"; fi
cnt=$(bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1
  PATH=/nonexistent   # a fork of grep / printf-pipe would have nothing to run
  i=0; n=0; while [ "$i" -lt 2000 ]; do fleet_is_fid 39a7bf15-6049-4271-9528-b4760415b544 && n=$((n + 1)); i=$((i + 1)); done
  echo "$n"' _ "$BIN" 2>&1)
if [ "$cnt" = 2000 ]; then ok "E: 2,000 asks with no PATH at all — answered in the shell, no fork"
else st_miss "E: fleet_is_fid needs a program on PATH (got '$cnt')"; fi

# --- F: one tmux call a window ------------------------------------------------------------
fout=$(python3 - "$BIN" <<'PY'
import importlib.util, sys, types
from pathlib import Path
b = Path(sys.argv[1])
sys.path.insert(0, str(b))
spec = importlib.util.spec_from_file_location("idle", b / "fleet-cleanup-idle.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
calls = []
opts = {"@issue": "12", "window_name": "w a", "@claude_state": "done"}
def tm(*a):
    calls.append(a)
    names = [f[2:-1] for f in a[-1].split("\x1f")]
    return "\x1f".join(opts.get(n, "") for n in names)
c = m.Cleaner.__new__(m.Cleaner); c.tm = tm
snap = c.snapshot("@1")
print(len(calls), snap["@issue"], snap["window_name"], snap["@claude_state"], snap["@reap_policy"] == "", len(snap))
PY
)
case "$fout" in "1 12 w a done True "*) ok "F: snapshot reads ${fout##* } options in 1 tmux call" ;;
  *) st_miss "F: snapshot made more than one tmux call, or read wrong values" "$fout" ;; esac

printf '%d/%d checks passed\n' $((CHECKS - FAIL)) "$CHECKS"
st_done
