#!/usr/bin/env bash
# fleet-client-where.sh — where the person is right now: which device, which
# system, which terminal, and what it can do for a session (issue #1716, EPIC
# #1710 C6). THE one place a session, a skill or a script reads it (EPIC rule 7:
# nothing else guesses a terminal or a device).
#
#   fleet-client-where.sh           one line:  MacBook · macOS · iTerm2 3.6 · 能：打开网页、收文件、系统通知、iTerm2
#                                              verkyyi-iphone · iOS · Termius（客户端在 m5 上运行）· 能：给链接
#   fleet-client-where.sh --json    {"state","device","os","terminal","caps","since","via","host","source"}
#
# Two sources, one output:
#   hub    the person's client lease (#1715) — a node asks with its own token
#          (GET /v1/node/client: its owner's client), a client machine with its
#          connection certificate (fleet-client-lease.py where)
#   local  no hub (no URL, or a hub without the lease, or one out of reach): the
#          fleet-shell client attached on THIS machine — its saved where
#          (<cache>/tmp/client.where.json, written by fleet-shell.sh when a
#          client becomes the one in use), else the first attached client's
#          device + tmux client_termname
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
  -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'usage: fleet-client-where.sh [--json]\n' >&2; exit 2 ;;
esac

HUBREAD=''
hrc=0
HUBREAD=$(${FLEET_CLIENT_WHERE_CMD:-python3 "$BIN/fleet-client-lease.py" where} 2>/dev/null) || hrc=$?

SESS="${FLEET_SHELL_SESSION:-fleet-shell}"
case "$SESS" in ''|*[!A-Za-z0-9._-]*) SESS=fleet-shell ;; esac
CL_DIR="${FLEET_SHELL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/shell}/tmp"
LOCAL_UP=0 CLIENTS=''
if tmux -L "$SESS" has-session -t "=$SESS" 2>/dev/null; then
  LOCAL_UP=1
  CLIENTS=$(tmux -L "$SESS" list-clients -t "=$SESS" -F '#{client_name}	#{client_termname}' 2>/dev/null)
fi

HUBREAD=$HUBREAD HRC=$hrc LOCAL_UP=$LOCAL_UP CLIENTS=$CLIENTS CL_DIR=$CL_DIR JSON=$json \
exec python3 - <<'PY'
import datetime, json, os, sys

CAPS = {"open_url": "打开网页", "show_file": "收文件", "notify": "系统通知", "link": "给链接", "iterm2": "iTerm2"}
KEYS = ("device", "os", "terminal", "caps", "since", "via", "host")


def key(s):
    return "".join(c if c.isalnum() or c in "._-" else "_" for c in s)


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def from_hub():
    """(state, where) off the hub, or None when there is no hub to ask."""
    if os.environ.get("HRC") != "0":
        return None
    try:
        d = json.loads(os.environ.get("HUBREAD") or "{}")
    except ValueError:
        return None
    st = d.get("state")
    if st == "nohub" or not st:
        return None
    lease = d.get("lease") or {}
    if st != "active" or not lease:
        return "none", {}
    return "active", lease


def from_local():
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
if os.environ.get("JSON") == "1":
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0 if state == "active" else 3)
if state != "active":
    print("此刻没有客户端连着")
    sys.exit(3)
line = " · ".join(x for x in (out["device"] or "未知设备", out["os"], out["terminal"]) if x)
if out["via"] and out["via"] != "local" and out["host"]:
    line += "（客户端在 %s 上运行）" % out["host"]
caps = [CAPS.get(c, c) for c in out["caps"]]
if caps:
    line += ("· " if line.endswith("）") else " · ") + "能：" + "、".join(caps)
print(line)
PY
