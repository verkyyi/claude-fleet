#!/bin/bash
# fleet-client-place.sh — open a session on a machine, from the client (issue
# #1777, EPIC #1776 C1).
#
#   fleet-client-place.sh <repo> <issue|scratch|home|restore:<key>|new> [--node <m>|auto]
#                         [--title <t>] [--name <n>] [--agent claude|codex]
#                         [--reap <policy>] [--body-file <f>] [--attach <file>]…
#                         [--new]
#
# --attach (issue #2393, EPIC #2482 C1; new or scratch, repeatable): a file the
# writing area's text names. Its bytes go with the request (≤ 10 MiB each and
# together, ≤ 5) and land on the machine that opens the session — the text
# names it there. One that cannot go (too big, unreadable, a hub or machine that
# takes none) is said: `附件没带过去：…` on stderr and after the line's tab, and
# beside its path in the text — never a path the session cannot read, silently.
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
# It is also the person's CURRENT one (issue #2564, EPIC #2563 C1): until it is
# /exit-ed, the next `- home` for the same agent — from any of their computers —
# opens nothing and answers `RESUME <m> <worker_id>` (exit 0) instead: the hub
# checks its fleet's last inventory still lists it, not exited. `--new` opens
# another anyway and makes that the current one. A hub older than #2564 ignores
# both and opens a new one each time, as before.
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
#   0  RESUME <m> <worker_id>\t<message>            `- home`: the current one (#2564)
#   3  HELD <m>\t<message>                          the issue is leased elsewhere
#   4  REFUSED <code>\t<message>                    no machine can take it — every
#                                                   machine's reason, as the hub said it
#   4  REFUSED ALL_DECLINED\t<message>              every machine tried said no (#1610)
#   5  DECLINED <m> <op> <exit>\t<line>             that machine's spawn said no
#   6  UNKNOWN <m> <op>\t<message>                  no final state within the wait
#                                                   (FLEET_CLIENT_PLACE_WAIT, 60 s)
#   1  the hub could not be asked (stderr says why)
#   2  usage
# An auto issue / scratch start a machine declines is tried by the hub on the
# next machine (issue #1610): each such machine is one stderr line, and the
# printed line carries an optional third field `after <m>:<op>:<exit>,…`.
# The hub is asked in rounds of at most 20 s (a place, then status polls of its
# operation), so no request outlives a proxy's patience.
#
# A 401 `not your client…` (issue #2464) — the lease was taken under an identity
# the hub no longer matches, e.g. right after the hub was redeployed — is not the
# end: the lease is released and acquired again ONCE (fleet-client-lease.py, the
# same identity — FLEET_CLIENT_IDENTITY — and the same device, client.where.json),
# stderr says `fleet-client-place: lease re-acquired once`, and the place is asked
# again. A second 401 exits 1 with the hub's words. FLEET_CLIENT_LEASE_CMD is the
# selftests' seam (as in fleet-shell.sh).
#
# No hub (no URL, or no lease to sign with): on a computer with a fleet, it opens
# here through the node's own adapter (fleet-control-read.sh — `LOCAL <host>`
# lines, the same codes); on one without, ONE line —
# 「这台电脑没有 fleet，也连不上入口」 — and exit 1.
#
# FLEET_PLACE_TIMING=<file> (issue #2238): a done start's node timing points —
# the hub's `timing`, epoch ms — written there as JSON; an older hub or node
# writes nothing.
#
# FLEET_PLACE_WHY=<file> (issue #2480): a start that did not open (REFUSED /
# DECLINED / UNKNOWN), why THIS computer was not chosen — its candidates in the
# hub's placement, each exclusion in a person's words with what opens it
# (compute off → fleet host on; the fleet's tmux down → fleet up) — one line per
# login here, written there; without the variable, stderr lines.
#
# FLEET_PLACE_RESULT=<file> (issue #2236): a done start's session, as JSON —
# {worker_id, window, window_id, key, filed, machine}, each only when the hub
# said it — so the caller switches to it at once instead of waiting for the
# list to carry its row. A warm start names window_id + key (#2234); an older
# hub or node, fewer fields (the line's worker_id is still there). A RESUME
# writes {worker_id, machine, resume: true, also_open: [<device>…]} — also_open
# the person's other devices that have it open now (#2564).
#
# State: the lease id in $FLEET_CLIENT_DIR/client.lease (default $TMPDIR, the
# client server's), the key in FLEET_CLIENT_KEY_FILE (default <dir>/client.key).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '5,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -ge 2 ] || usage
REPO=$1; WHAT=$2; shift 2
NODE=auto; TITLE=''; NAME=''; AGENT=''; REAP=''; BODYF=''; ATTACH=(); NEW=''
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
    --attach) [ $# -ge 2 ] || usage; ATTACH+=("$2"); shift 2 ;;
    --new)   NEW=1; shift ;;
    *) usage ;;
  esac
done
case "$REPO" in */*|-) ;; *) printf 'fleet-client-place: repo must be owner/name (or - for none)\n' >&2; exit 2 ;; esac
[ -n "$NODE" ] || NODE=auto
case "$AGENT" in ''|claude|codex) ;; *) printf 'fleet-client-place: --agent is claude or codex\n' >&2; exit 2 ;; esac
if [ -n "$REAP" ]; then
  REAP=$(python3 "$BIN/fleet_reap_policy.py" norm "$REAP") || exit 2
fi
KIND=''; ISSUE=''; KEY=''; HOME_ASK=''
case "$WHAT" in
  scratch) KIND=scratch ;;
  home) [ "$REPO" = - ] || { printf 'fleet-client-place: a home session belongs to no repo (-)\n' >&2; exit 2; }
        KIND=scratch; HOME_ASK=1 ;;
  new) KIND=new ;;
  restore:?*) KIND=restore; KEY=${WHAT#restore:} ;;
  issue-[1-9]*) KIND=issue; ISSUE=${WHAT#issue-} ;;
  [1-9]*) KIND=issue; ISSUE=$WHAT ;;
esac
case "$ISSUE" in *[!0-9]*) KIND='' ;; esac
[ -n "$KIND" ] || { printf 'fleet-client-place: %s is not an issue number, scratch, home, restore:<key> or new\n' "$WHAT" >&2; exit 2; }
[ -z "$NEW" ] || [ -n "$HOME_ASK" ] || { printf 'fleet-client-place: --new goes with home\n' >&2; exit 2; }
if [ "$KIND" = new ]; then
  [ -n "$TITLE" ] || { printf 'fleet-client-place: new needs --title\n' >&2; exit 2; }
fi
[ "$REPO" != - ] || [ "$KIND" = scratch ] || { printf 'fleet-client-place: only a scratch belongs to no repo (-)\n' >&2; exit 2; }
[ -z "$BODYF" ] || [ "$KIND" = new ] || [ "$KIND" = scratch ] || { printf 'fleet-client-place: --body-file is for new or scratch\n' >&2; exit 2; }
[ -z "$BODYF" ] || [ -r "$BODYF" ] || { printf 'fleet-client-place: cannot read %s\n' "$BODYF" >&2; exit 2; }
[ "${#ATTACH[@]}" -eq 0 ] || [ "$KIND" = new ] || [ "$KIND" = scratch ] || { printf 'fleet-client-place: --attach is for new or scratch\n' >&2; exit 2; }

# --- the hub ----------------------------------------------------------------------
# ask_hub <retry 0|1> — rc 10 = not applicable here (no hub URL, or no lease / key
# to sign with); rc 11 (only with retry 1) = 401 not your client.
ask_hub() {
python3 - "$BIN" "$REPO" "$KIND" "$ISSUE" "$KEY" "$NODE" "$TITLE" "$NAME" "$AGENT" "$REAP" "$BODYF" "$1" "$HOME_ASK" "$NEW" ${ATTACH[@]+"${ATTACH[@]}"} <<'PY'
import base64, hashlib, hmac, importlib.util, json, os, re, sys, time, urllib.error, urllib.request

here, repo, kind, issue, key, node, title, name, agent, reap, bodyf, retry, home, new = sys.argv[1:15]
files = sys.argv[15:]
body = ""
if bodyf:
    with open(bodyf, encoding="utf-8") as f:
        body = f.read()

# The attachments (issue #2393): the hub's own bounds (fleet_attachment.go),
# checked here first so what cannot go is said before anything is sent.
ATTACH_FILE_MAX, ATTACH_TOTAL_MAX, ATTACH_COUNT_MAX = 10 << 20, 10 << 20, 5
attach, stayed = [], []
for f in files:
    try:
        with open(f, "rb") as fh:
            data = fh.read(ATTACH_FILE_MAX + 1)
    except OSError:
        stayed.append((f, "读不到"))
        continue
    if len(data) > ATTACH_FILE_MAX:
        stayed.append((f, "超过 10 MB"))
    elif len(attach) >= ATTACH_COUNT_MAX:
        stayed.append((f, "一条任务最多 5 个"))
    elif sum(a["size"] for a in attach) + len(data) > ATTACH_TOTAL_MAX:
        stayed.append((f, "合计超过 10 MB"))
    else:
        attach.append({"name": os.path.basename(f), "from": f, "sha256": hashlib.sha256(data).hexdigest(),
                       "data": base64.b64encode(data).decode("ascii"), "size": len(data)})
for f, why in stayed:
    # beside its path in the text: the session reads that it did not come
    body = body.replace("- " + f + "\n", "- %s（附件没带过去：%s）\n" % (f, why))
    if body.endswith("- " + f):
        body += "（附件没带过去：%s）" % why


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
if home:
    req["home"] = True      # issue #2564: back to the current one, unless --new
    if new:
        req["new"] = True
for k, v in (("key", key), ("title", title), ("name", name), ("agent", agent), ("reap", reap), ("body", body)):
    if v:
        req[k] = v
if attach:
    req["attachments"] = [{k: a[k] for k in ("name", "from", "sha256", "data")} for a in attach]
tried = []   # issue #1610: the machines that declined before the answer, as the hub said them


def note_tried(o):
    for a in o.get("attempts") or []:
        if isinstance(a, dict) and a not in tried:
            tried.append(a)
            sys.stderr.write("fleet-client-place: %s declined (exit %s): %s — the hub tried the next machine\n"
                             % (a.get("machine", "?"), a.get("exit", "?"), " ".join(str(a.get("why") or "").split())))


try:
    out = ask(req)
    note_tried(out)
    carried = out.get("attached") or 0   # a status poll does not repeat it
    carried_note = out.get("attach_note") or ""
    while out.get("state") == "pending" and out.get("operation_id") and time.time() < deadline:
        out = ask({"action": "status", "operation_id": out["operation_id"], "wait": rnd()})
except urllib.error.HTTPError as e:
    why, raw = "", e.read() or b"{}"
    # the certificate's principals are not the login the hub checks (#2457)
    hint = fc.principal_hint(raw.decode("utf-8", "replace"))
    if hint:
        sys.stderr.write("fleet-client-place: %s\n" % hint)
        sys.exit(1)
    try:
        err = json.loads(raw).get("error") or {}
        why = (err.get("message") if isinstance(err, dict) else err) or ""
    except (ValueError, AttributeError):
        pass
    if e.code == 404 and not why:
        why = "this hub predates client placement (#1777)"
    # the lease is not one the hub holds for us (#2464): the caller takes it again once
    if e.code == 401 and retry == "1" and why.startswith("not your client"):
        sys.stderr.write("fleet-client-place: hub answered HTTP 401: %s\n" % why)
        sys.exit(11)
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
# The node's timing points (issue #2238), for a caller that asked for them by
# naming a file (fleet-compose.py → compose.ndjson); the line stays ONE line.
tf = os.environ.get("FLEET_PLACE_TIMING") or ""
if tf and isinstance(out.get("timing"), dict):
    try:
        with open(tf, "w", encoding="utf-8") as f:
            json.dump(out["timing"], f)
    except OSError:
        pass
# The login the session landed under (issue #2430): the hub's `login`, else the
# chosen candidate's os_user (a hub older than #2430) — remembered against its
# fleet's UUID in the client's fleet → login map (fleet_fleet_login, the format's
# owner in fleet-lib.sh), so opening it connects as THAT login.
def placed_login(o):
    pl = o.get("placement") if isinstance(o.get("placement"), dict) else {}
    fid = pl.get("fleet_id") or (o.get("worker_id") or "").split("/", 1)[0]
    lg = o.get("login") if isinstance(o.get("login"), str) else ""
    if not lg:
        for c in pl.get("candidates") or []:
            if isinstance(c, dict) and c.get("fleet_id") == fid and isinstance(c.get("os_user"), str):
                lg = c["os_user"]
                break
    return fid, lg
if out.get("state") in ("done", "resume"):
    fid, lg = placed_login(out)
    if re.fullmatch(r"[0-9A-Za-z-]{1,64}", fid or "") and re.fullmatch(r"[a-z_][a-z0-9_.-]{0,31}", lg or ""):
        mp = os.path.join(os.environ.get("TMPDIR") or "/tmp", ".claude-dash", "global", "fleet_logins")
        try:
            os.makedirs(os.path.dirname(mp), exist_ok=True)
            with open(mp, "a", encoding="utf-8") as f:
                f.write("%s\t%s\n" % (fid, lg))
        except OSError:
            pass
rf = os.environ.get("FLEET_PLACE_RESULT") or ""
if rf and out.get("state") in ("done", "resume"):
    said = {k: out[k] for k in ("worker_id", "window", "window_id", "key", "filed", "machine")
            if isinstance(out.get(k), str) and out[k]}
    if out.get("state") == "resume":
        said["resume"] = True
        said["also_open"] = [d for d in out.get("also_open") or [] if isinstance(d, str) and d]
    try:
        with open(rf, "w", encoding="utf-8") as f:
            json.dump(said, f)
    except OSError:
        pass
# Why THIS computer was not chosen (issue #2480): a start that did not open, its
# placement's candidates on this machine said in a person's words — `你这台
# （<m>/<login>）没被选：<why>——<what opens it>`, one line per login here. To the
# file FLEET_PLACE_WHY names (fleet-shell.sh home-session says it after its
# failure line), else stderr. Nothing when the hub sent no placement.
SELF_FIX = (
    ("compute off (只协调", "compute off（只协调）——在这台运行 fleet host on 打开（即 node.env CCQUOTA_FLEET_COMPUTE=1），"
                           "或在入口打开团队策略 fleet.compute_auto"),
    ("compute off (出口地区", None),
    ("tmux 服务没在跑", "这台 fleet 的 tmux 服务没在跑——在这台运行 fleet up 拉起"),
)


def self_why(why):
    for pre, say in SELF_FIX:
        if why.startswith(pre):
            return say or (why + "——出口地区不在支持范围；确要打开：fleet host on --force")
    return why


def self_lines(o):
    pl = o.get("placement") if isinstance(o.get("placement"), dict) else None
    if not pl:
        return []
    import socket
    host = (socket.gethostname() or "").split(".")[0].lower()
    me = os.environ.get("USER") or ""
    names = {host} | {a.split("=", 1)[1].lower() for a in (os.environ.get("FLEET_NODE_ALIASES") or "").split()
                       if a.lower().startswith(host + "=")}
    whys, here = {}, False
    for c in pl.get("candidates") or []:
        if not isinstance(c, dict) or str(c.get("machine") or "").split(".")[0].lower() not in names:
            continue
        here = True
        if c.get("eligible") or not c.get("excluded"):
            continue
        w = whys.setdefault(str(c.get("os_user") or "?"), [])
        s = self_why(str(c["excluded"]))
        if s not in w:
            w.append(s)
    out = []
    for lg in sorted(whys, key=lambda u: (u != me, u)):
        who = "你这台" if lg == me else "这台的另一个登录"
        say = "；".join(whys[lg])
        if lg != me:
            say = say.replace("在这台运行", "以 %s 登录在这台运行" % lg)
        out.append("%s（%s/%s）没被选：%s" % (who, host, lg, say))
    if not here and host and node in ("auto", "") and kind != "restore" and (pl.get("candidates") or pl.get("reason")):
        out.append("你这台（%s）不在入口的候选里——没登记成节点，或没有能开它的 fleet（在这台运行 fleet host on）" % host)
    return out


if out.get("state") != "done" and int(out.get("exit") or 0) not in (0, 3):
    sl = self_lines(out)
    wf = os.environ.get("FLEET_PLACE_WHY") or ""
    if sl and wf:
        try:
            with open(wf, "w", encoding="utf-8") as f:
                f.write("\n".join(sl) + "\n")
            sl = []
        except OSError:
            pass
    for s in sl:
        sys.stderr.write("fleet-client-place: %s\n" % s)
# A status poll answers for the last machine only: the first answer's tries
# stay on the line (issue #1610).
# What did not go with it (issue #2393), said — on stderr and after the line's
# tab, so the writing area's toast shows it. A hub that predates attachments
# answers no `attached`.
if attach and int(out.get("exit") or 0) in (0, 6) and carried < len(attach):
    stayed += [(a["from"], carried_note or "入口还不收附件（升级入口）") for a in attach[carried:]]
if stayed:
    said = "附件没带过去：" + "；".join("%s（%s）" % (os.path.basename(f), why) for f, why in stayed)
    sys.stderr.write("fleet-client-place: %s\n" % said)
    line += "\t" + said
if tried and "\tafter " not in line:
    line += "\tafter " + ",".join("%s:%s:%s" % (a.get("machine", "?"), a.get("operation_id") or "-", a.get("exit", 1))
                                  for a in tried)
print(line.replace("\n", " "))
sys.exit(int(out.get("exit") or 0))
PY
}

# relet — release the lease the hub refused and acquire one again: the same
# identity (the environment) and device (the where in use here). rc 1 = no lease.
relet() {
  local d old='' wf line st id
  d=${FLEET_CLIENT_DIR:-${TMPDIR:-/tmp}}
  export FLEET_CLIENT_KEY_FILE="${FLEET_CLIENT_KEY_FILE:-$d/client.key}"
  { read -r old < "$d/client.lease"; } 2>/dev/null
  [ -s "$d/client.where.json" ] && wf="$d/client.where.json"
  # shellcheck disable=SC2086  # a command line, split as fleet-shell.sh splits it
  [ -z "$old" ] || ${FLEET_CLIENT_LEASE_CMD:-python3 $BIN/fleet-client-lease.py} release --lease "$old" >/dev/null 2>&1
  # shellcheck disable=SC2086
  line=$(${FLEET_CLIENT_LEASE_CMD:-python3 $BIN/fleet-client-lease.py} acquire ${wf:+--where-file "$wf"} 2>/dev/null) || return 1
  IFS=$'\t' read -r st id _ <<< "$line"
  [ "$st" = active ] && [ -n "$id" ] || return 1
  printf '%s\n' "$id" > "$d/client.lease.tmp" && mv -f "$d/client.lease.tmp" "$d/client.lease"
}

ef=$(mktemp "${TMPDIR:-/tmp}/fcp-err.XXXXXX" 2>/dev/null) || ef=/dev/null
ask_hub 1 2>"$ef"; rc=$?
if [ "$rc" = 11 ]; then
  if relet; then
    printf 'fleet-client-place: lease re-acquired once\n' >&2
    ask_hub 0; rc=$?
  else
    cat "$ef" >&2 2>/dev/null
    printf 'fleet-client-place: the hub no longer holds this lease and a new one could not be taken — restart the client (fleet)\n' >&2
    rc=1
  fi
else
  cat "$ef" >&2 2>/dev/null
fi
[ "$ef" = /dev/null ] || rm -f "$ef"
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
