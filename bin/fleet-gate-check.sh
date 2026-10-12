#!/usr/bin/env bash
# fleet-gate-check.sh — 公开前必须先完成的安全项, one line each (issue #3574,
# EPIC #3569 C4). READ-ONLY: it reads ps, users and groups, and asks the hub.
#
#   fleet-gate-check.sh            every item: PASS / FAIL  <n> <id> — why — 由 … 完成
#   fleet-gate-check.sh --json     the same as one JSON object
#   fleet-gate-check.sh --local    only the items THIS machine judges (where=node),
#                                  never the hub — what the node agent sends on its
#                                  heartbeat (control.Heartbeat.Gate); implies --json
#
# The items are conf/public-gate.tsv's rows, the ONE copy (the hub reads the same
# bytes). A `node` row is judged here by gate_<id> below; a `hub` row is the
# hub's verdict, asked once at GET <hub>/v1/node/gate with this machine's node
# token (fleet_node_pair). No token / no answer ⇒ each hub row is a FAIL saying
# so — red until proven, never skipped. A #3500 member that delivers its item
# makes its judge go green here (or in the hub's fleet_gate.go); it never edits
# the table.
#
# Exit: 0 every item PASS · 1 any FAIL · 2 usage, or the table unreadable.
# Seams (selftest): FLEET_GATE_TABLE (the table) · FLEET_GATE_PS (a file of
# `<user|uid> <command>` lines instead of ps) · FLEET_GATE_ADMINS (space-separated
# logins that hold admin rights, instead of `id -Gn`) · FLEET_GATE_HUB_JSON (the
# hub's answer, instead of asking) · FLEET_HUB_CURL / FLEET_HUB_TIMEOUT.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
table=${FLEET_GATE_TABLE:-$BIN/../conf/public-gate.tsv}
json=0 loc=0
for a in "$@"; do
  case "$a" in
    --json) json=1 ;;
    --local) loc=1 json=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) printf 'fleet-gate-check: unknown argument %s (usage: [--json] [--local])\n' "$a" >&2; exit 2 ;;
  esac
done
[ -r "$table" ] || { printf 'fleet-gate-check: no gate table at %s\n' "$table" >&2; exit 2; }

# The hub's half: its JSON on hub_json, or why there is none on hub_why.
hub_json='' hub_why=''
if [ "$loc" = 0 ]; then
  if [ -n "${FLEET_GATE_HUB_JSON+x}" ]; then
    hub_json=$FLEET_GATE_HUB_JSON
    [ -n "$hub_json" ] || hub_why='入口没答'
  else
    # shellcheck source=/dev/null
    . "$BIN/fleet-lib.sh" 2>/dev/null
    pair=$(fleet_node_pair 2>/dev/null) || pair=''
    if [ -z "$pair" ]; then
      hub_why='本机没有节点令牌，问不到入口（在接入入口的机器上跑，或看入口的 /v1/fleet/gate）'
    else
      url=${pair%%	*}; tok=${pair#*	}
      resp=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" | \
        "${FLEET_HUB_CURL:-curl}" -sS --max-time "${FLEET_HUB_TIMEOUT:-10}" -K - -o - -w '\n%{http_code}' \
          "$url/v1/node/gate" 2>/dev/null); rc=$?
      code=$(printf '%s\n' "$resp" | tail -n 1)
      case "$rc:$code" in
        0:200) hub_json=$(printf '%s\n' "$resp" | sed '$d') ;;
        0:404|0:405) hub_why='入口还没有 /v1/node/gate（入口旧于 #3574）' ;;
        0:*) hub_why="入口拒绝了（HTTP ${code}）" ;;
        *) hub_why="入口没答（curl exit ${rc}）" ;;
      esac
    fi
  fi
fi

FLEET_GATE_TABLE_PATH="$table" GATE_JSON="$json" GATE_LOCAL="$loc" \
GATE_HUB_JSON="$hub_json" GATE_HUB_WHY="$hub_why" exec python3 - <<'PY'
import json, os, re, subprocess, sys

# ---- the table ---------------------------------------------------------------
rows = []
try:
    with open(os.environ["FLEET_GATE_TABLE_PATH"], encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            c = line.split("\t")
            if len(c) < 7 or not c[0].isdigit() or c[2] not in ("node", "hub"):
                sys.stderr.write("fleet-gate-check: bad table row: %s\n" % line)
                sys.exit(2)
            rows.append(dict(n=int(c[0]), id=c[1], where=c[2], before=c[3],
                             source=c[4], title=c[5], judge=c[6]))
except OSError as e:
    sys.stderr.write("fleet-gate-check: %s\n" % e)
    sys.exit(2)

# ---- what runs here ----------------------------------------------------------
def procs():
    seam = os.environ.get("FLEET_GATE_PS")
    if seam:
        text = open(seam, encoding="utf-8", errors="replace").read()
    else:
        text = subprocess.run(["ps", "-axo", "uid=,command="], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, env=dict(os.environ, LC_ALL="C")
                              ).stdout.decode("utf-8", "replace")
    out = []
    for line in text.splitlines():
        p = line.strip().split(None, 1)
        if len(p) < 2:
            continue
        who, cmd = p
        if who.isdigit():
            try:
                import pwd
                who = pwd.getpwuid(int(who)).pw_name
            except (KeyError, ImportError):
                pass
        if "fleet-gate-check" in cmd:     # this very read
            continue
        out.append((who, cmd))
    return out

FLEET = re.compile(r"claude-fleet|ccquota|/\.claude/fleet/|fleet-node|/fleet/bin/")
CORE = re.compile(r"fleet-node-core")
MACHINE = re.compile(r"^(fleet-node-supervisor(\.py)?|ccquota agent --machine|fleet-memguard(\.sh)?|fleet-credsep\.py machine)$")
NODE_USERS = ("_fleetnode", "fleetnode")
ADMIN_USERS = ("_fleetadmin", "fleetadmin")

def short(cmd):
    """The program a command line runs, as a person names it."""
    for tok in cmd.split():
        b = tok.rsplit("/", 1)[-1]
        if b.startswith("fleet-") or b.startswith("ccquota"):
            rest = cmd.split(tok, 1)[1].split()
            if b.startswith("ccquota") and rest[:1] == ["agent"]:
                return "ccquota agent" + (" --machine" if "--machine" in rest else "")
            if b == "fleet-credsep.py" and rest[:1] == ["machine"]:
                return b + " machine"
            return b
    return cmd.split()[0].rsplit("/", 1)[-1]

def names(pairs, with_user=False):
    seen = []
    for who, cmd in pairs:
        s = ("%s: %s" % (who, short(cmd))) if with_user else short(cmd)
        if s not in seen:
            seen.append(s)
    more = "" if len(seen) <= 4 else " …（共 %d 个）" % len(seen)
    return "、".join(seen[:4]) + more

_admins = None
def is_admin(user):
    global _admins
    if user == "root":
        return True
    seam = os.environ.get("FLEET_GATE_ADMINS")
    if seam is not None:
        return user in seam.split()
    if _admins is None:
        _admins = {}
    if user not in _admins:
        r = subprocess.run(["id", "-Gn", user], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        _admins[user] = bool({"admin", "sudo", "wheel"} & set(r.stdout.decode().split()))
    return _admins[user]

PS = procs()

# ---- the node judges: (pass, why) --------------------------------------------
def gate_root_core():
    mine = [(u, c) for u, c in PS if u == "root" and FLEET.search(c)]
    extra = [(u, c) for u, c in mine if not CORE.search(c)]
    if extra:
        return False, "root 名下还跑着核心以外的 fleet 程序：%s" % names(extra)
    if mine:
        return True, "root 名下只有核心（fleet-node-core）"
    return True, "root 名下没有 fleet 程序"

def gate_node_daemon():
    svc = [(u, c) for u, c in PS if MACHINE.match(short(c))]
    bad = [(u, c) for u, c in svc if u not in NODE_USERS]
    if bad:
        return False, "整机服务没以 _fleetnode 跑：%s" % names(bad, True)
    if svc:
        return True, "整机服务都以 %s 跑" % svc[0][0]
    return True, "本机没有整机服务在跑"

def gate_admin_seat():
    bad = [(u, c) for u, c in PS if short(c) == "ccquota agent"
           and u not in ADMIN_USERS and is_admin(u)]
    if bad:
        users = sorted({u for u, _ in bad})
        return False, "有管理员权限的账号 %s 在跑 ccquota agent（开号删号还在个人账号里）" % "、".join(users)
    return True, "没有带管理员权限的个人账号在跑 ccquota agent"

# ---- the verdicts -------------------------------------------------------------
local_only = os.environ.get("GATE_LOCAL") == "1"
hub_items, hub_why = {}, os.environ.get("GATE_HUB_WHY", "")
if not local_only and not hub_why:
    try:
        for it in json.loads(os.environ.get("GATE_HUB_JSON") or "{}").get("items") or []:
            hub_items[it.get("id")] = it
    except ValueError:
        hub_why = "入口的回答读不懂"

out = []
for r in rows:
    if r["where"] == "node":
        fn = globals().get("gate_" + r["id"].replace("-", "_"))
        if fn is None:
            ok, why = False, "本机没有这一项的判据（fleet-gate-check.sh 旧于表）"
        else:
            try:
                ok, why = fn()
            except Exception as e:  # a judge that breaks is a red item, never a crash
                ok, why = False, "判据出错：%s" % e
    elif local_only:
        continue
    elif hub_why:
        ok, why = False, hub_why
    elif r["id"] in hub_items:
        ok, why = bool(hub_items[r["id"]].get("pass")), hub_items[r["id"]].get("why") or ""
    else:
        ok, why = False, "入口没判这一项（入口旧于表）"
    out.append(dict(r, **{"pass": ok, "why": why}))

npass = sum(1 for o in out if o["pass"])
if os.environ.get("GATE_JSON") == "1":
    print(json.dumps({"pass": npass, "total": len(out), "items": [
        {k: o[k] for k in ("n", "id", "where", "before", "source", "title", "pass", "why")}
        for o in out]}, ensure_ascii=False))
else:
    for o in out:
        print("%s  %d %-12s %s — %s — 由 %s 完成" % ("PASS" if o["pass"] else "FAIL", o["n"], o["id"],
              o["title"], o["why"], o["source"]))
    print("gate: %d/%d PASS" % (npass, len(out)))
sys.exit(0 if npass == len(out) else 1)
PY
