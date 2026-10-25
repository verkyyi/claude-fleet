#!/bin/bash
# fleet-start-drill.sh — open real new sessions the way a person does and read how
# long each took to an agent the person can type into (T716, bin/fleet_timing.py).
#
#   fleet-start-drill.sh [--road box|dispatch] [--agent claude|codex] [-n N]
#                        [--concurrent K] [--repo owner/name] [--node here|auto]
#                        [--wait SECS] [--keep] [--force]
#
#   --road box       the 「新会话」 box's road: a blank task record, its session
#                    opened (fleet-task-record.sh dispatch --spawn --blank) — the
#                    default; no first turn, so no quota is spent
#   --road panel     the box's own road under ⌘P (T992): the record made in-process
#                    (bin/fleet_blank_start.py), then the spawner — no screen
#   --road dispatch  a dispatch with words (--body-file): its first turn is a
#                    one-line「回一句 OK」, so each run spends one short turn
#   -n N             runs (default 20), K at once (--concurrent, default 1)
#   --node here      open on this machine (FLEET_SPAWN_NODE=local) — the default:
#                    a baseline is one machine's; `auto` lets the hub place it
#   --wait SECS      how long one run may take to its input box (default 60)
#   --keep           leave the sessions open (default: each is closed the moment
#                    it is measured — its own `stopped` report ends its record,
#                    fleet-worker-stop.sh ends the session; nothing is left on
#                    the person's list)
#
# Each run is the fleet's own clock (FLEET_TIMING_T0 = the drill's ↵ for it): the
# stages land in timing/session.ndjson like any other start's, so `fleet_timing.py
# table` and the doctor count them too. The drill also watches the window itself
# for the agent's first word (@agent_status — the relay writes it the moment it
# writes `input`; Codex: @codex_session_id), so a start whose road carries no clock
# (one the hub sent back through this machine's node) is still timed: `drill` in
# the table, ↵ to input box, 0.1 s grain. A window named by the hub's answer
# (「已开窗 @N」) is followed when it is on this server. At the end one table: per
# stage the p50 and p90 over THIS drill's runs. A run placed on another machine is
# counted `remote`, not measured. The sessions report to the session that runs the
# drill (their parent) — run it from a session that may receive them.
#
# A drill is load on the machine: it refuses (exit 3) when the CPU is already
# over 80 % busy (admission's reading, _fleet_cpu_busy); --force runs anyway.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROAD=box AGENT=claude N=20 K=1 REPO='' WAIT=60 KEEP=0 FORCE=0 NODE=here
while [ $# -gt 0 ]; do
  case "$1" in
    --road) ROAD="${2:-}"; shift ;;
    --agent) AGENT="${2:-}"; shift ;;
    -n) N="${2:-}"; shift ;;
    --concurrent) K="${2:-}"; shift ;;
    --repo) REPO="${2:-}"; shift ;;
    --wait) WAIT="${2:-}"; shift ;;
    --node) NODE="${2:-}"; shift ;;
    --keep) KEEP=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fleet-start-drill: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$ROAD" in box|dispatch|panel) ;; *) echo "fleet-start-drill: --road box|dispatch|panel" >&2; exit 2 ;; esac
case "$AGENT" in claude|codex) ;; *) echo "fleet-start-drill: --agent claude|codex" >&2; exit 2 ;; esac
case "$NODE" in here) export FLEET_SPAWN_NODE=local ;; auto) ;; *) echo "fleet-start-drill: --node here|auto" >&2; exit 2 ;; esac
case "$N$K$WAIT" in *[!0-9]*) echo "fleet-start-drill: -n / --concurrent / --wait take numbers" >&2; exit 2 ;; esac
[ "$N" -ge 1 ] && [ "$K" -ge 1 ] || { echo "fleet-start-drill: -n and --concurrent are at least 1" >&2; exit 2; }

if [ "$FORCE" = 0 ]; then
  # the CPU's own reading, admission's (BREAK-IT mac-admit-load-not-busy): a Mac's
  # load average counts I/O waiters and reads 3/core on a machine 40 % busy
  over=$(bash -c '. "$1/fleet-lib.sh"; b=$(_fleet_cpu_busy) && awk -v b="$b" "BEGIN { print (b > 0.8) ? 1 : 0 }"' _ "$BIN" 2>/dev/null)
  [ "$over" = 1 ] && { echo "fleet-start-drill: the host CPU is over 80 % busy — not adding to it (--force)" >&2; exit 3; }
fi
if [ -z "$REPO" ]; then
  REPO=$(bash -c '. "$1/fleet-lib.sh"; fleet_repos 2>/dev/null | head -n 1' _ "$BIN")
fi
[ -n "$REPO" ] || { echo "fleet-start-drill: no repo (--repo owner/name)" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-start-drill.XXXXXX") || exit 1
WORDS="$WORK/words"
printf '启动演练（T716）：只回一句「OK」，别的什么都不做。\n' > "$WORDS"
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time()'; }

# one run: its ↵, the start, the wait for `input`, then (unless --keep) the close
one() {
  local i="$1" t0 out win
  t0=$(now); out="$WORK/run.$i"
  printf '%s\n' "$t0" > "$out.t0"
  if [ "$ROAD" = panel ]; then
    # ⌘P 「新会话」's own road (T992): the record in-process, then the spawner
    FLEET_TIMING_T0=$t0 python3 "$BIN/fleet_blank_start.py" start --repo "$REPO" --agent "$AGENT" \
      --fleet "$(bash -c '. "$1/fleet-lib.sh"; fleet_current_session' _ "$BIN" 2>/dev/null)" --title "启动演练 $i" \
      --default "$AGENT" --reap done:1m > "$out" 2> "$out.err"
  elif [ "$ROAD" = box ]; then
    FLEET_TIMING_T0=$t0 bash "$BIN/fleet-task-record.sh" dispatch --title "启动演练 $i" --repo "$REPO" \
      --spawn --agent "$AGENT" --reap done:1m --print --blank > "$out" 2> "$out.err"
  else
    FLEET_TIMING_T0=$t0 bash "$BIN/fleet-task-record.sh" dispatch --title "启动演练 $i" --repo "$REPO" \
      --spawn --agent "$AGENT" --reap done:1m --print --body-file "$WORDS" > "$out" 2> "$out.err"
  fi
  printf '%s\n' "$?" > "$out.rc"
  win=$(sed -n 's/^\(@[0-9][0-9]*\).*/\1/p' "$out" | head -n 1)
  [ -n "$win" ] || win=$(sed -n 's/.*已开窗 \(@[0-9][0-9]*\).*/\1/p' "$out.err" | head -n 1)
  if [ -z "$win" ] || ! tmux display-message -p -t "$win" '#{window_id}' >/dev/null 2>&1; then
    grep -q 'scratch → ' "$out.err" && echo remote > "$out.where"
    return 0
  fi
  printf '%s\n' "$win" > "$out.win"
  # the agent's first word of its own: the input box is up (fleet_timing.input_once's moment)
  local mark='#{@agent_status}' left=$((WAIT * 10)) ms=''
  [ "$AGENT" = codex ] && mark='#{@codex_session_id}'
  while [ "$left" -gt 0 ]; do
    if [ -n "$(tmux display-message -p -t "$win" "$mark" 2>/dev/null)" ]; then
      ms=$(perl -MTime::HiRes=time -e 'printf "%.0f", (time() - $ARGV[0]) * 1000' "$t0"); break
    fi
    sleep 0.1; left=$((left - 1))
  done
  [ -n "$ms" ] && printf '%s\n' "$ms" > "$out.input"
  [ "$KEEP" = 1 ] && return 0
  # closed at once, never left on the person's list: its record ends (its own
  # `stopped` report), then the session itself (fleet-worker-stop.sh, by identity)
  local pane fid sess
  pane=$(tmux display-message -p -t "$win" '#{pane_id}' 2>/dev/null)
  fid=$(tmux display-message -p -t "$win" '#{@fleet_id}' 2>/dev/null)
  sess=$(tmux display-message -p -t "$win" '#{?#{session_group},#{session_group},#{session_name}}' 2>/dev/null)
  [ -n "$pane" ] && TMUX_PANE=$pane bash "$BIN/fleet-report-parent.sh" --state stopped --outcome failed \
    --summary "启动演练（T716）：只量开窗到能打字，不是活" > /dev/null 2>&1
  [ -n "$fid" ] && [ -n "$sess" ] && bash "$BIN/fleet-worker-stop.sh" "$sess" "fid:$fid" > /dev/null 2>&1
  return 0
}

i=0
while [ "$i" -lt "$N" ]; do
  pids=''
  j=0
  while [ "$j" -lt "$K" ] && [ "$i" -lt "$N" ]; do
    i=$((i + 1)); j=$((j + 1))
    one "$i" &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p"; done
done

python3 - "$BIN" "$WORK" "$N" "$ROAD" "$AGENT" "$K" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import fleet_timing as t
work, n, road, agent, k = sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]
runs, remote, failed = [], 0, 0
for i in range(1, n + 1):
    base = os.path.join(work, "run.%d" % i)
    try:
        t0 = float(open(base + ".t0").read())
    except (OSError, ValueError):
        continue
    if os.path.exists(base + ".where"):
        remote += 1
        continue
    if not os.path.exists(base + ".win"):
        failed += 1
        continue
    r = t.run_of("session", t0)
    try:
        r["drill"] = float(open(base + ".input").read())
    except (OSError, ValueError):
        pass
    runs.append(r)
segs = [s for s in t.STAGES + ("drill",) if any(s in r for r in runs)]
got = sum(1 for r in runs if "drill" in r or "input" in r)
print("启动演练 · %s · %s · %d 次（每次 %s 个同开）· 到能打字 %d · 开到别处 %d · 没开出来 %d"
      % (road, agent, n, k, got, remote, failed))
print("| 段 | p50 秒 | p90 秒 | 次数 |")
print("|---|---|---|---|")
for s in segs:
    xs = [r[s] for r in runs if s in r]
    print("| %s | %.2f | %.2f | %d |" % (s, t.median(xs) / 1000, t.p90(xs) / 1000, len(xs)))
PY
rm -rf "$WORK"
