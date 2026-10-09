#!/bin/bash
# fleet-steward-stats.sh — the EPIC #2668 metrics the steward is judged by (issue
# #2670, C2). Reads only; `note` is the one writer, of its own log.
#
#   fleet-steward-stats.sh note                 the node conf's [76] hooks (a client's
#                                               window changed / a client arrived),
#                                               only while @attention_log is set
#                                               (fleet-steward.sh: FLEET_STEWARD
#                                               count | on): one line per client that
#                                               now looks at another window
#   fleet-steward-stats.sh attention [--days N] how often a person opened a worker
#   fleet-steward-stats.sh asks [--days N]      who answered the workers' questions
#   fleet-steward-stats.sh followups [--epics owner/name#N,…]
#                                               finished batches and what they
#                                               left: run · listed · neither
#   fleet-steward-stats.sh stuck                not measured here yet (C3)
#
# attention — $FLEET_CONF_DIR/logs/attention.ndjson, one JSON object a line:
#   {ts, client, ctl, session, wid, role, key, name}
# The count (EPIC #2668 读数口径): a switch onto a window whose role is `worker`,
# not within 30 s after the orchestrator or the steward opened it for you (a
# `{"open": …}` line, written by whoever opens one — none yet), the same window
# counted once a day. Per day, then the median.
#
# asks — the denominator is the workers' `ask` calls (logs/mcp-calls.log,
# `tool=ask`); the numerator the rows a PERSON answered (fleet-steward-tick.sh
# answer --by person), beside the steward's own and the ones defaulted at their
# deadline (global/steward.state.json). Neither the steward's nor a default counts
# toward the person's share.
#
# followups (issue #2672, C4) — the EPIC #2668 读数口径「做完了却没上线的批次」:
# a CLOSED EPIC whose closing comments leave something (bin/fleet_followup.py's
# parse: the `fleet:followup` markers, else the old words one version) of which
# nothing has been run and nothing is on the steward's 「待你动手」 list. Reads
# global/steward.state.json `todo`; --epics adds EPICs the steward never met
# (read through fleet-gh.sh, its cache first) — how the 2026-10-09 baseline reads.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 - "$BIN" "$@" <<'PY'
import collections, datetime as dt, json, os, re, statistics, subprocess, sys, time
from pathlib import Path

BIN = Path(sys.argv[1]); args = sys.argv[2:]
CONF = Path(os.environ.get("FLEET_CONF_DIR") or (Path.home() / ".config" / "claude-fleet"))
LOG = CONF / "logs" / "attention.ndjson"
LAST = CONF / "logs" / "attention.last"
PANELS = ("home", "plan", "dash", "backlog")

def days_arg():
    if "--days" in args:
        i = args.index("--days")
        if i + 1 < len(args) and args[i + 1].isdigit():
            return int(args[i + 1])
    return 7

def day_of(ts):
    return time.strftime("%Y-%m-%d", time.localtime(ts))

def note():
    fmt = "\t".join(("#{client_name}", "#{client_control_mode}",
                     "#{?#{session_group},#{session_group},#{session_name}}", "#{window_id}",
                     "#{@fleet_role}", "#{@issue}", "#{@repo}", "#{window_name}"))
    r = subprocess.run(["tmux", "list-clients", "-F", fmt], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, universal_newlines=True, timeout=10)
    try:
        last = json.loads(LAST.read_text())
    except (OSError, ValueError):
        last = {}
    out, now = [], int(time.time())
    for line in r.stdout.splitlines():
        p = (line.split("\t") + [""] * 8)[:8]
        client, ctl, sess, wid, role, issue, repo, name = p
        if not client or last.get(client) == wid:
            continue
        last[client] = wid
        if not role:
            role = "home" if name == "home" else ("panel" if name in PANELS else "worker")
        key = ("%s#%s" % (repo, issue)) if issue else name
        out.append(json.dumps({"ts": now, "client": client, "ctl": ctl == "1", "session": sess, "wid": wid,
                               "role": role, "key": key, "name": name}, ensure_ascii=False))
    if not out:
        return 0
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with open(str(LOG), "a", encoding="utf-8") as f:
        f.write("".join(o + "\n" for o in out))
    tmp = LAST.with_suffix(".tmp")
    tmp.write_text(json.dumps(last))
    os.replace(str(tmp), str(LAST))
    return 0

def attention():
    since = time.time() - days_arg() * 86400
    opened = collections.defaultdict(list)       # wid → [ts] the fleet opened it for you
    rows = []
    try:
        for line in open(str(LOG), encoding="utf-8"):
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("ts", 0) < since:
                continue
            if "open" in d:
                opened[d["open"]].append(d["ts"])
            else:
                rows.append(d)
    except OSError:
        pass
    per_day = collections.defaultdict(set)
    for d in rows:
        if d.get("role") != "worker":
            continue
        if any(0 <= d["ts"] - t <= 30 for t in opened.get(d.get("wid"), ())):
            continue
        per_day[day_of(d["ts"])].add(d.get("wid"))
    for day in sorted(per_day):
        print("%s\t%d" % (day, len(per_day[day])))
    counts = [len(v) for v in per_day.values()]
    print("median/day\t%s\t(days %d, target ≤ 2)" % (statistics.median(counts) if counts else 0, len(counts)))
    return 0

def asks():
    since = dt.datetime.now() - dt.timedelta(days=days_arg())
    asked = collections.Counter()
    log = Path(os.environ.get("FLEET_MCP_LOG") or (BIN.parent / "logs" / "mcp-calls.log"))
    try:
        for line in open(str(log), encoding="utf-8"):
            if " tool=ask " not in line:
                continue
            day = line[:10]
            if re.match(r"\d{4}-\d{2}-\d{2}$", day) and day >= since.strftime("%Y-%m-%d"):
                asked[day] += 1
    except OSError:
        pass
    try:
        st = json.loads((CONF / "global" / "steward.state.json").read_text())
    except (OSError, ValueError):
        st = {}
    by = st.get("counts") or {}
    defaulted = collections.Counter()
    for r in (st.get("rows") or {}).values():
        if r.get("state") == "defaulted" and (r.get("due") or "")[:10]:
            defaulted[r["due"][:10]] += 1
    days = sorted(set(asked) | {d for d in by if d >= since.strftime("%Y-%m-%d")})
    tot_a = tot_p = 0
    print("day\tasked\tperson\tsteward\tdefaulted")
    for d in days:
        p = (by.get(d) or {}).get("person", 0)
        print("%s\t%d\t%d\t%d\t%d" % (d, asked[d], p, (by.get(d) or {}).get("steward", 0), defaulted[d]))
        tot_a += asked[d]; tot_p += p
    print("person share\t%s\t(target ≤ 30%%)" % ("%d%%" % (100 * tot_p // tot_a) if tot_a else "—"))
    return 0

def followups():
    sys.path.insert(0, str(BIN))
    import fleet_followup as fu
    try:
        t = (json.loads((CONF / "global" / "steward.state.json").read_text()).get("todo") or {})
    except (OSError, ValueError):
        t = {}
    items = t.get("items") or {}
    per = collections.OrderedDict()
    for ref in sorted(t.get("epics") or {}):
        per[ref] = {"closed": bool((t["epics"][ref] or {}).get("closed")), "left": 0, "run": 0, "listed": 0}
    for i in items.values():
        for s in i.get("sources") or []:
            e = per.setdefault(s["epic"], {"closed": True, "left": 0, "run": 0, "listed": 0})
            e["left"] += 1
            if i.get("state") == "done":
                e["run"] += 1
            elif i.get("state") != "skipped":
                e["listed"] += 1
    extra = []
    if "--epics" in args:
        i = args.index("--epics")
        extra = [x for x in (args[i + 1] if i + 1 < len(args) else "").split(",") if x]
    for ref in extra:
        if ref in per:
            continue
        repo, _, n = ref.partition("#")
        r = subprocess.run(["bash", str(BIN / "fleet-gh.sh"), "issue", "view", n, "--repo", repo, "--json",
                            "state,comments", "--max-age", "3600"], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, universal_newlines=True, timeout=120)
        try:
            d = json.loads(r.stdout or "{}")
        except ValueError:
            d = {}
        left = fu.parse(d.get("comments") or [])
        per[ref] = {"closed": str(d.get("state", "")).upper() == "CLOSED", "left": len(left), "run": 0,
                    "listed": 0}
    print("epic\tclosed\tleft\trun\tlisted")
    unlive = 0
    for ref, e in per.items():
        print("%s\t%s\t%d\t%d\t%d" % (ref, "yes" if e["closed"] else "no", e["left"], e["run"], e["listed"]))
        if e["closed"] and e["left"] and not e["run"] and not e["listed"]:
            unlive += 1
    open_n = sum(1 for i in items.values() if i.get("state") not in ("done", "skipped"))
    ran = sum(1 for i in items.values() if i.get("state") == "done" and i.get("by") == "steward")
    print("todo\t%d open · %d run by the steward · desk %s" % (open_n, ran, t.get("desk") or "—"))
    print("done-not-live\t%d\t(target 0)" % unlive)
    return 0

cmd = args[0] if args else ""
if cmd == "note":
    sys.exit(note())
if cmd == "attention":
    sys.exit(attention())
if cmd == "asks":
    sys.exit(asks())
if cmd == "followups":
    sys.exit(followups())
if cmd == "stuck":
    print("stuck: not measured here yet — C3 #2671")
    sys.exit(0)
sys.stderr.write("usage: fleet-steward-stats.sh note | attention [--days N] | asks [--days N] | stuck | followups [--epics R#N,…]\n")
sys.exit(2)
PY
