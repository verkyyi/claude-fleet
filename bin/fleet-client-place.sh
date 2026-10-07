#!/bin/bash
# fleet-client-place.sh — open a session on a machine, from the client (issue
# #1777, EPIC #1776 C1).
#
#   fleet-client-place.sh <repo> <issue|scratch|home|restore:<key>|new> [--node <m>|auto]
#                         [--title <t>] [--name <n>] [--agent claude|codex]
#                         [--reap <policy>] [--body-file <f>]
#
# `new` (issue #1953, the writing area ⌘N opens): an issue that does not exist
# yet — --title (required) and --body-file are its title and body; the machine
# that takes it files it (fleet-issue-file.sh) and opens its worker.
#
# <repo> `-` (issue #1956, the writing area's 「不关联仓库」): a scratch of no repo
# — opened in $HOME, `@norepo 1`, on any of this person's machines; only a
# scratch. A scratch's --body-file is its seed: the session starts working on it.
#
# `- home` (issue #2264, EPIC #2259 共同约定 2): the HOME session — `fleet claude`
# / `fleet codex`, a newcomer's first session. The same ask as `- scratch` (the
# hub's scratch + no_repo; the node takes one from its pool, #2233, or opens one
# cold): one name for the one primitive, so no caller writes a road of its own.
#
# <issue> is a number (or issue-<N>); restore:<key> resumes a /fleet-history row
# (issue-<N> / scratch-<N>, a multi-repo fleet's <slug>: prefix allowed). A
# computer that runs only the `fleet` client has no fleet to open anything in:
# this asks the hub (POST /v1/fleet/client/place), which opens it on a machine —
# the one named, or the one placement picks — through the same placement and
# node operations a node's own `ccquota place` uses.
#
# Who may ask is this client's CURRENT lease: the request carries the lease id
# and is signed (HMAC-SHA256) under the lease's action key, which
# fleet-client-lease.py keeps 0600 in FLEET_CLIENT_KEY_FILE (never on an argv);
# the person is the connection certificate (`fleet-client@claude-fleet`), or
# FLEET_HUB_TOKEN / hub.json's token. A lease taken over or lapsed opens nothing.
#
# Prints ONE line, the one fleet_hub_place prints (machine names the way a client
# names them), and returns its code:
#   0  REMOTE <m> <op> done <worker_id>\t<reason>   opened there
#   3  HELD <m>\t<message>                          the issue is leased elsewhere
#   4  REFUSED <code>\t<message>                    no machine can take it — every
#                                                   machine's reason, as the hub said it
#   5  DECLINED <m> <op> <exit>\t<line>             that machine's spawn said no
#   6  UNKNOWN <m> <op>\t<message>                  no final state within the wait
#                                                   (FLEET_CLIENT_PLACE_WAIT, 60 s)
#   1  the hub could not be asked (stderr says why)
#   2  usage
# The hub is asked in rounds of at most 20 s (a place, then status polls of its
# operation), so no request outlives a proxy's patience.
#
# No hub (no URL, or no lease to sign with): on a computer with a fleet, it opens
# here through the node's own adapter (fleet-control-read.sh — `LOCAL <host>`
# lines, the same codes); on one without, ONE line —
# 「这台电脑没有 fleet，也连不上入口」 — and exit 1.
#
# State: the lease id in $FLEET_CLIENT_DIR/client.lease (default $TMPDIR, the
# client server's), the key in FLEET_CLIENT_KEY_FILE (default <dir>/client.key).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -ge 2 ] || usage
REPO=$1; WHAT=$2; shift 2
NODE=auto; TITLE=''; NAME=''; AGENT=''; REAP=''; BODYF=''
while [ $# -gt 0 ]; do
  case "$1" in
    --node)  [ $# -ge 2 ] || usage; NODE=$2; shift 2 ;;
    --title) [ $# -ge 2 ] || usage; TITLE=$2; shift 2 ;;
    --name)  [ $# -ge 2 ] || usage; NAME=$2; shift 2 ;;
    --agent) [ $# -ge 2 ] || usage; AGENT=$2; shift 2 ;;
    # when the fleet may close it on its own (issue #1902) — the new-session
    # question's answer; canonical here, held to its shape by the hub too
    --reap)  [ $# -ge 2 ] || usage; REAP=$2; shift 2 ;;
    --body-file) [ $# -ge 2 ] || usage; BODYF=$2; shift 2 ;;
    *) usage ;;
  esac
done
case "$REPO" in */*|-) ;; *) printf 'fleet-client-place: repo must be owner/name (or - for none)\n' >&2; exit 2 ;; esac
[ -n "$NODE" ] || NODE=auto
case "$AGENT" in ''|claude|codex) ;; *) printf 'fleet-client-place: --agent is claude or codex\n' >&2; exit 2 ;; esac
if [ -n "$REAP" ]; then
  REAP=$(python3 "$BIN/fleet_reap_policy.py" norm "$REAP") || exit 2
fi
KIND=''; ISSUE=''; KEY=''
case "$WHAT" in
  scratch) KIND=scratch ;;
  home) [ "$REPO" = - ] || { printf 'fleet-client-place: a home session belongs to no repo (-)\n' >&2; exit 2; }
        KIND=scratch ;;
  new) KIND=new ;;
  restore:?*) KIND=restore; KEY=${WHAT#restore:} ;;
  issue-[1-9]*) KIND=issue; ISSUE=${WHAT#issue-} ;;
  [1-9]*) KIND=issue; ISSUE=$WHAT ;;
esac
case "$ISSUE" in *[!0-9]*) KIND='' ;; esac
[ -n "$KIND" ] || { printf 'fleet-client-place: %s is not an issue number, scratch, home, restore:<key> or new\n' "$WHAT" >&2; exit 2; }
if [ "$KIND" = new ]; then
  [ -n "$TITLE" ] || { printf 'fleet-client-place: new needs --title\n' >&2; exit 2; }
fi
[ "$REPO" != - ] || [ "$KIND" = scratch ] || { printf 'fleet-client-place: only a scratch belongs to no repo (-)\n' >&2; exit 2; }
[ -z "$BODYF" ] || [ "$KIND" = new ] || [ "$KIND" = scratch ] || { printf 'fleet-client-place: --body-file is for new or scratch\n' >&2; exit 2; }
[ -z "$BODYF" ] || [ -r "$BODYF" ] || { printf 'fleet-client-place: cannot read %s\n' "$BODYF" >&2; exit 2; }

# --- the hub ----------------------------------------------------------------------
# rc 10 = not applicable here (no hub URL, or no lease / key to sign with).
python3 - "$BIN" "$REPO" "$KIND" "$ISSUE" "$KEY" "$NODE" "$TITLE" "$NAME" "$AGENT" "$REAP" "$BODYF" <<'PY'
import hashlib, hmac, importlib.util, json, os, sys, time, urllib.error, urllib.request

here, repo, kind, issue, key, node, title, name, agent, reap, bodyf = sys.argv[1:12]
body = ""
if bodyf:
    with open(bodyf, encoding="utf-8") as f:
        body = f.read()


def connect_module():
    spec = importlib.util.spec_from_file_location("fleet_connect", os.path.join(here, "fleet-connect.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


fc = connect_module()
conf = fc.load_hub_conf()
hub = os.environ.get("FLEET_HUB_URL") or fc.machine_conf_hub() or conf.get("url") or ""
token = os.environ.get("FLEET_HUB_TOKEN") or conf.get("token") or ""
d = os.environ.get("FLEET_CLIENT_DIR") or os.environ.get("TMPDIR") or "/tmp"
lease = read(os.path.join(d, "client.lease"))
akey = read(os.environ.get("FLEET_CLIENT_KEY_FILE") or os.path.join(d, "client.key"))
if not hub or not lease or not akey:
    sys.exit(10)

total = float(os.environ.get("FLEET_CLIENT_PLACE_WAIT") or 60)
deadline = time.time() + total
idem = "client-%s-%d" % (lease[:8], time.time_ns())


def ask(payload):
    payload["ts"] = int(time.time())
    p = json.dumps(payload, ensure_ascii=False)
    body = {"lease": lease, "payload": p, "mac": hmac.new(akey.encode(), p.encode(), hashlib.sha256).hexdigest()}
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    else:
        ts = int(time.time())
        cert, sig = fc.ssh_sign("fleet-client %d" % ts, "fleet-client@claude-fleet")
        body.update(cert=cert, sig=sig, ts=ts)
    req = urllib.request.Request(hub.rstrip("/") + "/v1/fleet/client/place", data=json.dumps(body).encode(),
                                 method="POST", headers=headers)
    with urllib.request.urlopen(req, timeout=(payload.get("wait") or 0) + 15) as r:
        return json.loads(r.read() or b"{}")


def rnd():
    return max(0, min(20, int(deadline - time.time())))


req = {"action": "place", "kind": kind, "node": node, "idempotency_key": idem, "wait": rnd()}
if repo == "-":
    req["no_repo"] = True   # issue #1956: a scratch of no repo
else:
    req["repo"] = repo
if issue:
    req["issue"] = int(issue)
for k, v in (("key", key), ("title", title), ("name", name), ("agent", agent), ("reap", reap), ("body", body)):
    if v:
        req[k] = v
try:
    out = ask(req)
    while out.get("state") == "pending" and out.get("operation_id") and time.time() < deadline:
        out = ask({"action": "status", "operation_id": out["operation_id"], "wait": rnd()})
except urllib.error.HTTPError as e:
    why = ""
    try:
        why = (json.loads(e.read() or b"{}").get("error") or {}).get("message") or ""
    except ValueError:
        pass
    if e.code == 404 and not why:
        why = "this hub predates client placement (#1777)"
    sys.stderr.write("fleet-client-place: hub answered HTTP %d%s\n" % (e.code, (": " + why) if why else ""))
    sys.exit(1)
except fc.Refused as e:
    sys.stderr.write("fleet-client-place: %s\n" % e)
    sys.exit(1)
except (OSError, ValueError) as e:
    sys.stderr.write("fleet-client-place: the hub could not be asked: %s\n" % e)
    sys.exit(1)
line = out.get("line") or ""
if not line:
    sys.stderr.write("fleet-client-place: the hub's answer has no line\n")
    sys.exit(1)
print(line.replace("\n", " "))
sys.exit(int(out.get("exit") or 0))
PY
rc=$?
[ "$rc" = 10 ] || exit "$rc"

# --- no hub: this computer's own fleet, if it has one -------------------------------
. "$BIN/fleet-lib.sh" 2>/dev/null
SESS=$(fleet_login_fleet 2>/dev/null) || SESS=''
if [ -z "$SESS" ] || [ ! -f "$BIN/fleet-control-read.sh" ]; then
  printf '这台电脑没有 fleet，也连不上入口\n' >&2
  exit 1
fi
HOST=$(hostname -s 2>/dev/null); HOST=${HOST%%.*}
if [ "$NODE" != auto ] && ! fleet_node_is_self "$NODE"; then
  printf 'REFUSED NO_HUB\t连不上入口，开不到 %s；这台 (%s) 可以开\n' "$NODE" "$HOST"
  exit 4
fi
ef=$(mktemp "${TMPDIR:-/tmp}/fcp-err.XXXXXX" 2>/dev/null) || ef=/dev/null
case "$KIND" in
  issue)   out=$(bash "$BIN/fleet-control-read.sh" start "$SESS" "$ISSUE" "$AGENT" "$REPO" '' '' ${REAP:+'' "$REAP"} 2>"$ef"); src=$? ;;
  scratch) out=$(bash "$BIN/fleet-control-read.sh" start "$SESS" scratch "$AGENT" "$REPO" '' '' "${NAME:-$TITLE}" ${REAP:+"$REAP"} \
                   < "${BODYF:-/dev/null}" 2>"$ef"); src=$? ;;
  restore) out=$(bash "$BIN/fleet-control-read.sh" resume "$SESS" "$KEY" 2>"$ef"); src=$? ;;
  new)     out=$(bash "$BIN/fleet-control-read.sh" start "$SESS" new "$AGENT" "$REPO" '' '' "$TITLE" ${REAP:+"$REAP"} \
                   < "${BODYF:-/dev/null}" 2>"$ef"); src=$? ;;
esac
why=$(tail -n1 "$ef" 2>/dev/null | tr '\t' ' ')
[ "$ef" = /dev/null ] || rm -f "$ef"
case "$src" in
  0) printf 'LOCAL %s\t%s\n' "$HOST" "$(printf '%s' "$out" | head -n1 | tr '\t' ' ')"; exit 0 ;;
  3) printf 'HELD %s\t%s\n' "$HOST" "$why"; exit 3 ;;
  *) printf 'DECLINED %s - %s\t%s\n' "$HOST" "$src" "$why"; exit 5 ;;
esac
