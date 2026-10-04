#!/bin/bash
# fleet-hub-latency.sh — how long a state change on THIS machine takes to show up
# in another machine's sidebar cache (issue #1481, EPIC #1479's 「≤ 3 秒」 metric).
#
#   fleet-hub-latency.sh --observer <ssh host> [--window <target>] [--rounds 10]
#                        [--states done,working] [--observer-bin <dir>]
#                        [--observer-loop-bin <dir>] [--observer-every <s>]
#
# Runs on the machine whose window changes (the SETTER). It opens ONE ssh to the
# observer running this script's `--watch` there, which polls that machine's
# $FLEET_C/global/remote_<sess> cache every 100 ms and prints a line the moment
# the window's row changes state. Each round flips the window's @claude_state
# (alternating between --states; a `done ⇄ working` pair by default — a window
# with no Claude under it is left alone by the needs detector in those two) the
# way the hook does: the option, its @claude_state_ts, the spinner's dirty marker
# and the hub nudge (fleet_hub_nudge: $FLEET_CONF_DIR/global/hub-nudge, when
# CCQUOTA_FLEET=1). Latency = the moment the observer's line ARRIVES minus the
# moment the option was written, both read on this machine's monotonic clock —
# no clock sync between the two machines is assumed; the ssh hop (a few ms on
# the LAN / tailnet) is counted against the fleet. The window is restored to
# its original state at the end.
#
#   --window         the setter window (`@3`, `<sess>:<idx>`, or a window name);
#                    default = the window this pane is in ($TMUX_PANE)
#   --observer-bin   where THIS script lives on the observer (default: this
#                    directory's path, assumed identical there)
#   --observer-loop-bin  which fleet-hub-sessions.sh the observer's watcher keeps
#                    running (`--ensure`): default --observer-bin. Point it at
#                    ~/.claude/fleet/bin to measure the LIVE install's loop, at a
#                    branch checkout to measure that branch's.
#   --observer-every seconds between the observer's fetches (sets
#                    FLEET_HUB_SESSIONS_EVERY on the observer's loop; unset = the
#                    loop's own rule: 2 s while a client is attached there, 10 s
#                    when nobody is looking)
#   --round-timeout  seconds to wait for one round before calling it TIMEOUT (30)
#   --observer-env   'VAR=value …' prefixed to the watcher's command on the
#                    observer (e.g. a branch hub: 'CCQUOTA_FLEET=1
#                    CCQUOTA_HUB_URL=http://127.0.0.1:18787 CCQUOTA_VIEWER_TOKEN=…')
#
#   fleet-hub-latency.sh --watch <window name> [--session <sess>] [--loop-bin <dir>]
#
# The observer half (started over ssh by the above; usable by hand). Prints
# `READY <cache> <state>` then `SEEN <state> <ms>` per change, until stdin closes.
#
# Output (the EPIC's evidence): one line per round and a `median` line:
#   round 1  done → working   2314 ms
#   …
#   median 2290 ms  (n=10, min 2101, max 4870)  nudge=on observer=m4 window=…
#
# Needs: bash + python3 + ssh on both ends, tmux on the setter.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-hub-latency: %s\n' "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# --watch: the observer half
# ---------------------------------------------------------------------------
if [ "${1:-}" = --watch ]; then
  shift; NAME="${1:-}"; [ -n "$NAME" ] || die '--watch needs the window name'; shift
  WSESS=''; LOOPBIN="$BIN"
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) WSESS="${2:-}"; shift 2 ;;
      --loop-bin) LOOPBIN="${2:-}"; shift 2 ;;
      *) die "--watch: unknown option $1" ;;
    esac
  done
  if [ -z "$WSESS" ]; then
    WSESS=$(fleet_each_conf | head -1 | cut -f1)
    [ -n "$WSESS" ] || die '--watch: no fleet conf on this machine (FLEET_CONF_DIR) — nothing the hub list is cached for'
  fi
  CACHE="$FLEET_C/global/remote_$WSESS"
  [ -x "$LOOPBIN/fleet-hub-sessions.sh" ] || die "--watch: no fleet-hub-sessions.sh in $LOOPBIN"
  # The fetch loop runs as OUR child for the whole watch — the real --loop code
  # at its real cadence, one long cycle, gone when we are. (The collector tick
  # that normally re-ensures it every 60 s may not run on this machine; a loop
  # that merely got ensured once dies after 70 s and the rounds time out.) If a
  # daemon's loop already holds the pid file ours exits at once and is retried.
  export FLEET_HUB_SESSIONS_LOOP_SECS=86400
  # The program goes through a file, NOT `python3 -` — stdin must stay the ssh
  # channel, which is how the watcher learns the driver hung up.
  WPY=$(mktemp "${TMPDIR:-/tmp}/hublat-watch.XXXXXX") || die '--watch: mktemp failed'
  cat > "$WPY" <<'PY'
import os, select, subprocess, sys, time
cache, name, loop = sys.argv[1:4]
US = "\x1f"
child = None
def keep_loop():
    global child
    if child is None or child.poll() is not None:
        child = subprocess.Popen(["bash", loop, "--loop"], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
keep_loop()
def state():
    try:
        with open(cache, encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split(US)
                if len(p) >= 8 and p[7] == name:
                    return p[5]
    except OSError:
        pass
    return None
last = state()
print("READY %s %s" % (cache, last if last is not None else "-"), flush=True)
t_keep = time.monotonic()
try:
    while True:
        if time.monotonic() - t_keep > 5:
            keep_loop()
            t_keep = time.monotonic()
        r, _, _ = select.select([sys.stdin], [], [], 0.1)
        if r and not sys.stdin.readline():
            break                                   # the driver hung up
        s = state()
        if s != last:
            last = s
            print("SEEN %s %d" % (s if s is not None else "-", int(time.time() * 1000)), flush=True)
finally:
    if child is not None and child.poll() is None:
        child.terminate()
PY
  python3 -u "$WPY" "$CACHE" "$NAME" "$LOOPBIN/fleet-hub-sessions.sh"; rc=$?
  rm -f "$WPY"; exit $rc
fi

# ---------------------------------------------------------------------------
# the driver (setter) half
# ---------------------------------------------------------------------------
OBS=''; WIN=''; ROUNDS=10; STATES='done,working'; OBIN="$BIN"; OLOOPBIN=''; OEVERY=''; OENV=''; RTO=30
while [ $# -gt 0 ]; do
  case "$1" in
    --observer) OBS="${2:-}"; shift 2 ;;
    --window) WIN="${2:-}"; shift 2 ;;
    --rounds) ROUNDS="${2:-}"; shift 2 ;;
    --states) STATES="${2:-}"; shift 2 ;;
    --observer-bin) OBIN="${2:-}"; shift 2 ;;
    --observer-loop-bin) OLOOPBIN="${2:-}"; shift 2 ;;
    --observer-every) OEVERY="${2:-}"; shift 2 ;;
    --observer-env) OENV="${2:-}"; shift 2 ;;
    --round-timeout) RTO="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done
[ -n "$OBS" ] || die '--observer <ssh host> is required (the machine whose sidebar cache we read)'
case "$ROUNDS" in ''|*[!0-9]*|0) die "--rounds must be a positive number" ;; esac
case "$STATES" in *,*) : ;; *) die "--states needs two states, e.g. done,working" ;; esac
[ -n "$OLOOPBIN" ] || OLOOPBIN="$OBIN"

SESS=$(fleet_current_session 2>/dev/null) || SESS=''
[ -n "$SESS" ] || SESS="${FLEET_SESSION:-}"
[ -n "$SESS" ] || die 'not inside a fleet pane and FLEET_SESSION is unset'
SOCK=$(fleet_socket "$SESS")
if [ -z "$WIN" ]; then
  [ -n "${TMUX_PANE:-}" ] || die '--window <target> is required outside a fleet pane'
  WIN=$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null) || die 'cannot resolve this pane'"'"'s window'
fi
read -r WID NAME CUR <<EOF
$(tmux -L "$SOCK" display-message -p -t "$WIN" '#{window_id} #{window_name} #{@claude_state}' 2>/dev/null)
EOF
[ -n "${WID:-}" ] || die "no window $WIN in fleet $SESS"
NUDGE=''
[ "${CCQUOTA_FLEET:-0}" = 1 ] && NUDGE="$FLEET_CONF_DIR/global/hub-nudge"
DIRTY="$(tmux -L "$SOCK" display-message -p -t "$WID" '#{socket_path}' 2>/dev/null).dirty"

printf 'fleet-hub-latency: setter=%s window=%s (%s, state=%s) observer=%s rounds=%s states=%s nudge=%s\n' \
  "$(hostname -s 2>/dev/null || hostname)" "$WID" "$NAME" "${CUR:--}" "$OBS" "$ROUNDS" "$STATES" "${NUDGE:+on}${NUDGE:-off}" >&2

# The observer's watcher over one ssh; its stdout is our fd 3, its stdin our fd 4.
WFIFO=$(mktemp -u "${TMPDIR:-/tmp}/hublat.XXXXXX") && mkfifo "$WFIFO" || die 'cannot create a fifo'
trap 'rm -f "$WFIFO"' EXIT
wcmd="'$OBIN/fleet-hub-latency.sh' --watch '$NAME' --loop-bin '$OLOOPBIN'"
[ -n "$OEVERY" ] && wcmd="FLEET_HUB_SESSIONS_EVERY=$OEVERY $wcmd"
[ -n "$OENV" ] && wcmd="$OENV $wcmd"
exec 4> >(ssh -o BatchMode=yes -o ConnectTimeout=15 "$OBS" "bash -lc \"$wcmd\"" > "$WFIFO" 2>&2)
exec 3< "$WFIFO"
if ! IFS= read -r -t 60 ready <&3; then die "the observer's watcher did not start (ssh $OBS; is $OBIN there?)"; fi
case "$ready" in READY*) printf '%s\n' "observer: $ready" >&2 ;; *) die "observer: $ready" ;; esac
OSTATE=${ready##* }    # what the observer's cache shows for this window right now

export SOCK WID NUDGE DIRTY STATES ROUNDS CUR NAME OBS OSTATE RTO
# exec: the driver IS the python from here on, so a signal to this pid ends the
# run (and closing fd 4 hangs up the watcher) instead of orphaning a flipper.
rm -f "$WFIFO"; trap - EXIT
exec python3 -u - <<'PY' 3<&3 4>&4
import os, select, subprocess, sys, time
sock, wid, nudge, dirty = os.environ["SOCK"], os.environ["WID"], os.environ["NUDGE"], os.environ["DIRTY"]
a, b = os.environ["STATES"].split(",", 1)
rounds, cur, name, obs = int(os.environ["ROUNDS"]), os.environ["CUR"], os.environ["NAME"], os.environ["OBS"]
out = os.fdopen(3, "r", buffering=1)

def write(state):
    ts = str(int(time.time()))
    subprocess.run(["tmux", "-L", sock, "set-window-option", "-t", wid, "@claude_state", state], check=True)
    subprocess.run(["tmux", "-L", sock, "set-window-option", "-t", wid, "@claude_state_ts", ts])
    try:
        open(dirty, "w").close()
    except OSError:
        pass
    if nudge:
        try:
            os.makedirs(os.path.dirname(nudge), exist_ok=True)
            open(nudge, "w").close()                # what fleet_hub_nudge does: `: > file`
        except OSError:
            pass

def wait_seen(state, timeout):
    deadline = time.monotonic() + timeout
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            return None
        r, _, _ = select.select([out], [], [], left)
        if not r:
            return None
        line = out.readline()
        if not line:
            return None
        p = line.split()
        if len(p) >= 2 and p[0] == "SEEN" and p[1] == state:
            return time.monotonic()

# Settle: round 1 must be a CHANGE for the observer, so start from the state
# its cache shows now (the watcher reports changes only). If that is neither
# of ours, write one and wait until it shows up there.
ostate = os.environ["OSTATE"]
if ostate in (a, b):
    start = ostate
    write(start)                 # make the setter agree with what the observer sees
    time.sleep(1.0)
else:
    start = a
    write(start)
    if wait_seen(start, 60) is None:
        print("fleet-hub-latency: the observer never saw the starting state %r (it shows %r) — is the hub listing this window there?" % (start, ostate), file=sys.stderr)
        sys.exit(1)
lat = []
prev = start
for i in range(1, rounds + 1):
    nxt = b if prev == a else a
    t0 = time.monotonic()
    write(nxt)
    t1 = wait_seen(nxt, float(os.environ["RTO"]))
    if t1 is None:
        print("round %-2d %s → %s   TIMEOUT" % (i, prev, nxt))
        lat.append(None)
    else:
        ms = int((t1 - t0) * 1000)
        print("round %-2d %s → %s   %d ms" % (i, prev, nxt, ms))
        lat.append(ms)
    prev = nxt
    time.sleep(1.0)     # let the hub settle between rounds (a beat per round, not a burst)
# Put the window back the way we found it.
if cur and cur != prev:
    write(cur)
ok = sorted(x for x in lat if x is not None)
if ok:
    n = len(ok)
    med = ok[n // 2] if n % 2 else (ok[n // 2 - 1] + ok[n // 2]) // 2
    print("median %d ms  (n=%d, min %d, max %d, timeouts %d)  nudge=%s observer=%s window=%s" %
          (med, n, ok[0], ok[-1], lat.count(None), "on" if nudge else "off", obs, name))
else:
    print("median -  (every round timed out)  observer=%s window=%s" % (obs, name))
    sys.exit(1)
PY
