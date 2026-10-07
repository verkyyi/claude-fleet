#!/bin/bash
# fleet-compose-latency.sh — how long each send from the writing area took, per
# segment (issue #2238, EPIC #2230 C8).
#
#   fleet-compose-latency.sh [--last N] [--node <m>] [--log <file>]... [--summary]
#
# Every ↵ in the writing area leaves lines in logs/compose.ndjson (one id per
# send, fleet-compose.py's compose_log): `sent` (t_enter), `placed` (the node's
# timing points as the hub handed them on: t_accepted, t_window, …) and `ready`
# (t_ready — the task list saw the new row in a state the person can type into).
# The node keeps its own half in its operation's result (fleet_control.py):
# t_ready / t_prompt land there AFTER the place answered, so on a machine that
# is a node too, its control/state.sqlite3 fills what the client could not see,
# joined on the operation id. Names and meaning: EPIC #2230 共同约定 3; every
# point is epoch ms.
#
# Prints the last N sends (default 20; orchestrator hand-overs are no sends):
# each segment's p50 and max over the sends that have both ends, how many did,
# and the slowest send end to end. A point no side recorded (an older node sends
# no timing, an older client no t_enter) is 「—」, never an error.
#   --node <m>  only the sends placed on machine <m> (the `placed` line's name)
#   --log <f>   read this compose.ndjson (repeatable); default: $FLEET_COMPOSE_LOG,
#               else this install's logs/ and the client install's
#               (~/.local/share/claude-fleet/logs) — every one that exists
#   --summary   one line for fleet-doctor: `n=<sends> ready=<with t_ready>
#               p50=<ms|-> max=<ms|->` of ↵ → 能打字
# Exit 0; 2 = usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

LAST=20; NODE=''; SUMMARY=0; LOGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --last) LAST=${2:-}; shift 2 ;;
    --node) NODE=${2:-}; shift 2 ;;
    --log) LOGS+=("${2:-}"); shift 2 ;;
    --summary) SUMMARY=1; shift ;;
    -h|--help) sed -n '5,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'fleet-compose-latency: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$LAST" in ''|*[!0-9]*|0) printf 'fleet-compose-latency: --last takes a positive number\n' >&2; exit 2 ;; esac

if [ "${#LOGS[@]}" -eq 0 ]; then
  if [ -n "${FLEET_COMPOSE_LOG:-}" ]; then
    LOGS=("$FLEET_COMPOSE_LOG")
  else
    LOGS=("$BIN/../logs/compose.ndjson" "$HOME/.local/share/claude-fleet/logs/compose.ndjson")
  fi
fi
DB="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/control/state.sqlite3"

exec python3 - "$LAST" "$NODE" "$SUMMARY" "$DB" ${LOGS[@]+"${LOGS[@]}"} <<'PY'
import json, os, sqlite3, sys, time

last, node, summary, db = int(sys.argv[1]), sys.argv[2], sys.argv[3] == "1", sys.argv[4]
logs = []
for p in sys.argv[5:]:
    real = os.path.realpath(p)
    if os.path.isfile(real) and real not in logs:
        logs.append(real)

sends, order = {}, []
for path in logs:
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict) or not row.get("id"):
            continue
        s = sends.setdefault(row["id"], {})
        ev = row.get("ev")
        if ev == "sent":
            if row.get("how") == "orchestrate":
                sends.pop(row["id"], None)
                continue
            s["sent"] = row
            order.append((row.get("ts") or 0, row["id"]))
        elif ev in ("placed", "started", "ready"):
            s.setdefault(ev, row)


def num(v):
    return v if isinstance(v, int) and not isinstance(v, bool) and v > 0 else None


# The node's own half, when this machine is that node (fleet_control.py writes
# its points into the operation's result; t_ready / t_prompt come after the place).
node_timing = {}
ops = {s["placed"].get("op") for s in sends.values() if s.get("placed") and s["placed"].get("op")}
if ops and os.path.isfile(db):
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=2)
        for op in ops:
            r = con.execute("SELECT result FROM operations WHERE id=?", (op,)).fetchone()
            if r and r[0]:
                t = (json.loads(r[0]) or {}).get("timing")
                if isinstance(t, dict):
                    node_timing[op] = t
        con.close()
    except (sqlite3.Error, ValueError):
        pass

rows = []
for _, cid in sorted(set(order)):
    s = sends.get(cid) or {}
    sent, placed = s.get("sent"), s.get("placed") or {}
    if not sent:
        continue
    if node and placed.get("machine") != node:
        continue
    t = {}
    t.update({k: v for k, v in (node_timing.get(placed.get("op")) or {}).items() if num(v)})
    t.update({k: v for k, v in (placed.get("timing") or {}).items() if num(v)})
    if num(placed.get("t_accepted")):
        t["t_accepted"] = placed["t_accepted"]
    if num(sent.get("t_enter")):
        t["t_enter"] = sent["t_enter"]
    if num((s.get("ready") or {}).get("t_ready")):
        t["t_ready"] = s["ready"]["t_ready"]   # what the person saw wins over the node's
    rows.append({"id": cid, "ts": sent.get("ts") or 0, "how": sent.get("how", ""),
                 "machine": placed.get("machine", ""), "t": t})
rows = rows[-last:]

SEGMENTS = [("↵ → 入口受理", "t_enter", "t_accepted"),
            ("受理 → 窗口到手", "t_accepted", "t_window"),
            ("窗口 → 第一句送进去", "t_window", "t_prompt"),
            ("窗口 → 能打字", "t_window", "t_ready"),
            ("↵ → 能打字（总）", "t_enter", "t_ready"),
            ("↵ → 单子建好", "t_enter", "t_filed"),
            ("↵ → 换成单子身份", "t_enter", "t_bound")]


def span(r, a, b):
    x, y = r["t"].get(a), r["t"].get(b)
    return y - x if x and y and y >= x else None


def p50(v):
    v = sorted(v)
    return v[(len(v) - 1) // 2] if v else None


def secs(ms):
    return "—" if ms is None else "%.2fs" % (ms / 1000.0)


totals = [d for d in (span(r, "t_enter", "t_ready") for r in rows) if d is not None]
if summary:
    print("n=%d ready=%d p50=%s max=%s" % (len(rows), len(totals),
          "-" if not totals else p50(totals), "-" if not totals else max(totals)))
    sys.exit(0)

where = node or "全部机器"
if not rows:
    print("最近没有发任务的记录（%s）— 读的是：%s" % (where, ", ".join(logs) or "（没有 compose.ndjson）"))
    sys.exit(0)


def width(text):
    return sum(2 if ord(c) > 0x2E7F else 1 for c in text)


print("最近 %d 次发任务 · %s" % (len(rows), where))
print("%s%9s %9s %8s" % ("段" + " " * 22, "p50", "max", "有数据"))
for label, a, b in SEGMENTS:
    v = [d for d in (span(r, a, b) for r in rows) if d is not None]
    print("%s%s%9s %9s %8s" % (label, " " * (24 - width(label)), secs(p50(v)), secs(max(v) if v else None),
                                "%d/%d" % (len(v), len(rows))))
if totals:
    worst = max((r for r in rows if span(r, "t_enter", "t_ready") is not None),
                key=lambda r: span(r, "t_enter", "t_ready"))
    print("最慢一次：%s  %s  %s  %s  ↵ → 能打字 %s" % (
        time.strftime("%m-%d %H:%M", time.localtime(worst["ts"])) if worst["ts"] else "?",
        worst["machine"] or "?", worst["how"] or "?", worst["id"],
        secs(span(worst, "t_enter", "t_ready"))))
else:
    print("最慢一次：— （还没有一次记到「能打字」）")
PY
