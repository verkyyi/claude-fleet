#!/usr/bin/env bash
# fleet-client-where.sh — where the person is right now: which device, which
# system, which terminal, and what it can do for a session (issue #1716, EPIC
# #1710 C6). THE one place a session, a skill or a script reads it (EPIC rule 7:
# nothing else guesses a terminal or a device).
#
#   fleet-client-where.sh           one line:  MacBook · macOS · iTerm2 3.6 · 能：打开网页、收文件、系统通知、iTerm2
#                                              verkyyi-iphone · iOS · Termius（客户端在 m5 上运行）· 能：给链接
#                                              MacBook · macOS · iTerm2 3.6 · 能：… · 也开着：verkyyi-iphone
#   fleet-client-where.sh --json    {"state","device","os","terminal","caps","since","via","host","source","hub",
#                                    "clients","primary"[,"hub_why"][,"node_token"]}
#
# A person may hold several clients at once (issue #1932, EPIC #1906 C13): where
# they are is the PRIMARY — the one typed into or tapped last (a client idle past
# FLEET_CLIENT_IDLE, 10 min, loses it to one in use). `clients` lists every one
# ({id device os terminal via host caps last_input viewing primary}), `primary`
# is its id; the line ends 「也开着：…」 when there is more than one. One client
# (or an older hub): the line and the other keys exactly as before, clients
# holding that one.
#
# Two sources, one output:
#   hub    the person's client lease (#1715) — a node asks with its own token
#          (GET /v1/node/client: its owner's client), a client machine with its
#          connection certificate (fleet-client-lease.py where)
#   local  no hub (no URL, or a hub without the lease, or one out of reach): a
#          thin client's 看台 here with a client attached (issue #3005, EPIC #2999
#          C8 — fleet_thin_lease.py where: the device its row says, via thin);
#          else (the old client, until C11) the
#          fleet-shell client attached on THIS machine — its saved where
#          (<cache>/tmp/client.where.json, written by fleet-shell.sh when a
#          client becomes the one in use), else the first attached client's
#          device + tmux client_termname
# `hub` says which: up (the hub answered) · nohub (no hub here, or one without the
# lease) · down (a hub is set but could not be asked: a timeout, DNS, a 5xx) ·
# refused (the hub answered 401: it does not accept this machine's credential —
# an orphaned key id, an expired certificate; issue #2112) — the status bar's
# 「⌂ … · 入口连不上」 / 「入口不认这台电脑 · 请重新扫码」 (fleet-client-badge.sh,
# issue #1779) reads it here. A refused hub falls back to local like a down one.
# `hub_why` (refused only) is the hub's own words for the 401; `node_token`
# ("refused: <words>") says the node token was refused and the certificate
# answered instead (issue #2665) — both also land in the doctor's `hubauth` row.
# Nothing is cached: every call reads the source afresh, so a takeover shows on
# the very next call.
#
# The where itself is worked out once, when the client opens, off the ssh
# connection (fleet-client-lease.py `device`): a tailnet source address →
# `tailscale whois`; a LAN one → the tailnet devices' LAN endpoints; a public one
# → 未知设备. Terminal: LC_TERMINAL, TERM_PROGRAM, an XTVERSION query, TERM.
#
# caps: open_url show_file notify (the client runs on the device itself) · link
# (a device at the far end of an ssh: give it a link to tap) · iterm2.
#
# Exit: 0 a client named · 3 nobody is connected · 1 could not tell.
# Seams (tests): FLEET_CLIENT_WHERE_CMD (the hub read), FLEET_SHELL_SESSION,
# FLEET_SHELL_CACHE.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

json=0
case "${1:-}" in
  --json) json=1 ;;
  '') ;;
  -h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'usage: fleet-client-where.sh [--json]\n' >&2; exit 2 ;;
esac

HUBREAD=''
hrc=0
HUBREAD=$(${FLEET_CLIENT_WHERE_CMD:-python3 "$BIN/fleet-client-lease.py" where} 2>/dev/null) || hrc=$?

# A refused credential is the doctor's `hubauth` row (issue #2665): the node
# token the hub would not take (the read then asked with the certificate), or a
# 401 to everything. fleet-lib is sourced only when there is something to note —
# a refusal, or an older refusal of ours to clear.
_haw=$(printf '%s' "$HUBREAD" | sed -n 's/.*"node_token": *"refused: \([^"]*\)".*/node token: \1/p')
[ -n "$_haw" ] || [ "$hrc" != 4 ] || _haw=$(printf '%s' "$HUBREAD" | sed -n 's/.*"why": *"\([^"]*\)".*/\1/p')
[ -n "$_haw" ] || [ "$hrc" != 4 ] || _haw='HTTP 401'
if [ -f "$BIN/fleet-lib.sh" ] && [ -z "${FLEET_CLIENT_WHERE_CMD:-}" ]; then
  if [ -n "$_haw" ]; then
    bash -c '. "$1/fleet-lib.sh" && fleet_hub_auth_note client-where fail "$2"' _ "$BIN" "$_haw" >/dev/null 2>&1
  elif [ "$hrc" = 0 ] && grep -q '^client-where	' "${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global/hub_auth_fail" 2>/dev/null; then
    bash -c '. "$1/fleet-lib.sh" && fleet_hub_auth_note client-where ok' _ "$BIN" >/dev/null 2>&1
  fi
fi

# A thin client's 看台 here (issue #3005): the lease's own words when there is
# no hub to hold it — read only when the hub could not answer.
THINW=''
[ "$hrc" = 0 ] && case "$HUBREAD" in *'"state": "nohub"'*|*'"state":"nohub"'*) hrc=nohub ;; esac
if [ "$hrc" != 0 ]; then
  THINW=$(${FLEET_CLIENT_WHERE_THIN_CMD:-python3 "$BIN/fleet_thin_lease.py" where} 2>/dev/null) || THINW=''
  [ "$hrc" = nohub ] && hrc=0
fi

SESS="${FLEET_SHELL_SESSION:-fleet-shell}"
case "$SESS" in ''|*[!A-Za-z0-9._-]*) SESS=fleet-shell ;; esac
CL_DIR="${FLEET_SHELL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/shell}/tmp"
LOCAL_UP=0 CLIENTS=''
if tmux -L "$SESS" has-session -t "=$SESS" 2>/dev/null; then
  LOCAL_UP=1
  CLIENTS=$(tmux -L "$SESS" list-clients -t "=$SESS" -F '#{client_name}	#{client_termname}' 2>/dev/null)
fi

HUBREAD=$HUBREAD HRC=$hrc THINW=$THINW LOCAL_UP=$LOCAL_UP CLIENTS=$CLIENTS CL_DIR=$CL_DIR JSON=$json \
exec python3 - <<'PY'
import datetime, json, os, sys

CAPS = {"open_url": "打开网页", "show_file": "收文件", "notify": "系统通知", "link": "给链接", "iterm2": "iTerm2"}
KEYS = ("device", "os", "terminal", "caps", "since", "via", "host")


def key(s):
    return "".join(c if c.isalnum() or c in "._-" else "_" for c in s)


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


HUB = "up"
HUB_WHY, NODE_TOKEN = "", ""
CLIENTS, PRIMARY = [], ""
try:
    _d = json.loads(os.environ.get("HUBREAD") or "{}")
    if isinstance(_d, dict):
        # the hub's own words for a 401 (#2665): to everything (hub_why), or to
        # the node token alone while the certificate still answered (node_token)
        HUB_WHY, NODE_TOKEN = str(_d.get("why") or ""), str(_d.get("node_token") or "")
except ValueError:
    pass


def from_hub():
    """(state, where) off the hub, or None when there is no hub to ask."""
    global HUB
    if os.environ.get("HRC") != "0":
        # 4: fleet-client-lease.py where got a 401 — up, but not us (#2112)
        HUB = "refused" if os.environ.get("HRC") == "4" else "down"
        return None
    try:
        d = json.loads(os.environ.get("HUBREAD") or "{}")
    except ValueError:
        HUB = "down"
        return None
    st = d.get("state")
    if st == "nohub" or not st:
        HUB = "nohub"
        return None
    lease = d.get("lease") or {}
    if st != "active" or not lease:
        return "none", {}
    global CLIENTS, PRIMARY
    CLIENTS = [c for c in (d.get("clients") or []) if isinstance(c, dict)] or [lease]
    PRIMARY = d.get("primary") or lease.get("id") or ""
    return "active", lease


def from_local():
    try:
        t = json.loads(os.environ.get("THINW") or "null")
    except ValueError:
        t = None
    if isinstance(t, dict) and t.get("device"):
        return "active", t                    # a thin client's 看台 here (#3005)
    if os.environ.get("LOCAL_UP") != "1":
        return "none", {}
    cl = os.environ["CL_DIR"]
    clients = [l.split("\t") for l in (os.environ.get("CLIENTS") or "").splitlines() if l.strip()]
    if not clients:
        return "none", {}
    p = os.path.join(cl, "client.where.json")
    try:
        with open(p) as f:
            w = json.load(f)
        if isinstance(w, dict) and w.get("device"):
            w.setdefault("since", iso(os.path.getmtime(p)))
            return "active", w
    except (OSError, ValueError):
        pass
    # a client from before #1716 kept no where: its device, tmux's terminal word
    name, term = (clients[0] + [""])[:2]
    dev = ""
    try:
        with open(os.path.join(cl, "client.dev", key(name))) as f:
            dev = f.read().strip()
    except OSError:
        pass
    return "active", {"device": dev or "未知设备", "terminal": term}


src = "hub"
r = from_hub()
if r is None:
    src = "local"
    r = from_local()
state, w = r
out = {"state": state, "source": src}
for k in KEYS:
    v = w.get(k)
    out[k] = list(v or []) if k == "caps" else (v or "")
out["hub"] = HUB
if HUB == "refused" and HUB_WHY:
    out["hub_why"] = HUB_WHY
if NODE_TOKEN:
    out["node_token"] = NODE_TOKEN
if state == "active" and not CLIENTS:
    CLIENTS = [dict(w)]   # no hub: the client in use here
out["clients"], out["primary"] = CLIENTS, PRIMARY
if os.environ.get("JSON") == "1":
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0 if state == "active" else 3)
if state != "active":
    print("此刻没有客户端连着")
    sys.exit(3)
line = " · ".join(x for x in (out["device"] or "未知设备", out["os"], out["terminal"]) if x)
if out["via"] == "thin" and out["host"]:
    line += "（经 %s）" % out["host"]          # its home machine draws its screen (#3005)
elif out["via"] and out["via"] != "local" and out["host"]:
    line += "（客户端在 %s 上运行）" % out["host"]
caps = [CAPS.get(c, c) for c in out["caps"]]
if caps:
    line += ("· " if line.endswith("）") else " · ") + "能：" + "、".join(caps)
others = [c.get("device") or "未知设备" for c in CLIENTS if c.get("id") and c.get("id") != PRIMARY]
if others:
    line += " · 也开着：" + "、".join(others)
print(line)
PY
