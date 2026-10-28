#!/usr/bin/env python3
"""fleet-mcp.py — the fleet's one local tool service (issue #1807, EPIC #1813 C5).

A plain stdio MCP server (newline-delimited JSON-RPC, stdlib only — macOS ships
python 3.9 and nothing here may need a pip install). Every Claude AND every Codex
session the fleet opens mounts it under the server name `fleet`, so both agents
see the same tools (Claude shows them as mcp__fleet__<action>):

  status    read-only: this window's binding + its children + the hosted repos
  children  read-only: bin/fleet-children.sh --json
  repos     read-only: bin/fleet-repo.sh list
  agents    read-only: the live sessions of this fleet, parent/child marked
  spawn     issue [+ repo]          → bin/dash-issue-session.sh
  await     issue [+ repo, timeout] → bin/fleet-await.sh
  send      to + text               → bin/fleet-peer-send.sh
  report    state [+ pr, summary]   → bin/fleet-report-parent.sh        (报, issue #1808)
  ask       question [+ kind, suggest, default, due, class] → bin/fleet-task-record.sh + set-claude-state.sh blocked  (问)
  handoff   action [+ slug|doc]     → bin/fleet-handoff-file.sh         (记)
  pr_verdict [pr, repo, wait]       → bin/fleet-pr-verdict.sh           (合)
  pr_merge  [pr, repo]              → bin/fleet-pr-merge.sh             (合)
  brief     [kind, repo]            → bin/fleet-brief.sh | fleet-compact-resume.sh --brief  (issues #1811, #4898)
  context   [json]                  → bin/fleet-context.sh
  transfer  action [+ to, handoff, loop, …] → bin/fleet-transfer.sh | fleet-loop.py from-claude
  where / show / open               → bin/fleet-client-where.sh / fleet-show.sh / fleet-open.sh

docs/dev/FLEET-MCP.md is the one spec; later EPIC members add tools there and here.

Two groups (issue #3113, EPIC #3111 C2). The default server `fleet` LISTS the tools
a session works with; the dispatch group — spawn · await · children · answer_dialog ·
send — is listed by the same script started as `fleet-mcp.py --group orch`, the
server `fleet-orch` (conf/mcp-orch.json), which the core's launchers mount for EVERY
session (issue #4703, after #4591: any session may spawn; caps and dedup are the
bounds, in the scripts). `@agent_spawn` gates nothing. No plugin mounts it. For at least one version (#2068) `fleet`
still ANSWERS a dispatch-group call under its old name (logged road=legacy), and a
server that took over from a pre-group version keeps listing everything, so a
session that started with the old list never loses a tool mid-conversation. A session
with no `fleet-orch` beside it (FLEET_MCP_ORCH unset: launched before #4703) gets the
dispatch group listed on `fleet` itself.

The rule (EPIC #1813 decision 4, the one the retired mod tools kept): a tool only
CHECKS its arguments — an unknown or missing argument, a wrong type, a repo this
fleet does not host is refused with the reason and NOTHING runs — then runs the
existing script unchanged and hands back its exit code, stdout and stderr as they
came. Caps, dedup and guards live in the scripts, once.

  fleet-mcp.py                 serve on stdin/stdout (the server `fleet`)
  fleet-mcp.py --group orch    serve the dispatch group (the server `fleet-orch`)
  fleet-mcp.py [--group orch] --list
                               print the tools that server lists, one per line
  fleet-mcp.py --bridge-seat   exit 0 when THIS pane may spawn — any fleet pane (issue
                               #4703); 1 outside tmux (no seat by role, issue #3118)
  fleet-mcp.py --mount codex [--group orch]
                               print the `-c` value bin/fleet-codex.sh mounts it with
  fleet-mcp.py --cred mint     print a fresh worker credential for THIS pane (stdout only)
  fleet-mcp.py --cred check    verify $FLEET_WORKER_CRED; print its claims (never the credential)
  fleet-mcp.py --cred revoke   revoke $FLEET_WORKER_CRED (its nonce goes on the revoked list)
  fleet-mcp.py --probe         list the tools and exit — a running server asks a new version this
                               before it execs it (issue #1898: a new version, taken between calls)
  fleet-mcp.py --spec <tool>…  print the named tools' {name, description, inputSchema} as JSON
  fleet-mcp.py --call <tool> [<json args>]
                               ONE tool call, no MCP framing: the same identity check, argument
                               check, script run and call log as a tools/call, the result text on
                               stdout; exit 0 answered (the script's exit is in the text), 1 refused
                               or faulted (isError), 2 usage. The mod's fallback road (issue #2057):
                               a session launched before the service was mounted (--plugin-dir only,
                               no --mcp-config) still carries the mod's fleet_status / fleet_spawn /
                               fleet_await, and the mod forwards each to this — one implementation.

The worker credential (issue #1809, EPIC #1813 C7): bin/fleet-session-wrap.sh mints
one per launch and hands it to the agent — and so to this server — ONLY through the
environment ($FLEET_WORKER_CRED); every tool call verifies it first and then acts as
the session it names, refusing what is outside that session's scope. A call without
one (a person in a shell, an older session) runs as before, by the window's options,
and the call log says so. docs/dev/FLEET-MCP.md «Identity» is the spec.

The hub route (issue #1810, EPIC #1813 C8): when THIS fleet runs with the hub
(fleet_hub_on + a node token) and the call carries a credential that held, the
tools whose script may act on another machine — spawn, await, send — hand that
script a worker assertion in $FLEET_WORKER_ASSERT: who the call is for, signed by
the node (HMAC keyed with its token's hash). `ccquota place` sends it to the hub,
a hub relay carries it, and the hub audits the session by it. No hub = nothing is
minted, nothing is read, no request is made: everything stays on this machine.
"""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import threading
import time

BIN = Path(__file__).resolve().parent
SERVER = "fleet"
VERSION = "0.1.0"

# fleet-await.sh blocks: a ten-minute tool call at most, with head-room.
AWAIT_MAX_S = 570
AWAIT_DEFAULT_S = 540
AWAIT_SLACK_S = 25
SPAWN_TIMEOUT_S = 120
STATUS_TIMEOUT_S = 30
WRITE_TIMEOUT_S = 90       # a comment / a report / an evidence copy: one gh or peer round-trip
LAND_TIMEOUT_S = 595       # a repo the fleet lands itself runs its check inside the call (#3602)
VERDICT_TIMEOUT_S = 60     # the one-shot read
BRIEF_TIMEOUT_S = 90       # one gh read of the issue + its comments
FILE_TIMEOUT_S = 180       # the filer (a ticket + its parent link) + a spawn
SHOW_TIMEOUT_S = 300       # --inline holds the screen until the operator presses a key

# Codex hands an MCP server only a short env allowlist (HOME, PATH, USER, …);
# these are what the scripts need to find the pane, the fleet and the install —
# and the session's credential (issue #1809): forwarded by NAME, never its value.
CODEX_ENV = ["TMUX", "TMUX_PANE", "FLEET_CONF_DIR", "FLEET_SESSION", "FLEET_WORKER_CRED", "FLEET_MCP_BIN",
             "FLEET_MCP_ORCH"]
# A blocking await outlives Codex's 60s default per-call timeout.
CODEX_TOOL_TIMEOUT_S = AWAIT_MAX_S + AWAIT_SLACK_S + 5


class ToolFault(Exception):
    def __init__(self, message):
        super().__init__(message)
        self.message = message


class Refused(ToolFault):
    """Arguments that do not fit: said with the reason, nothing ran."""


def _descendants(pid):
    """Every live descendant of pid (one `ps` read), deepest last."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True,
                             text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    kids = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) == 2 and f[0].isdigit() and f[1].isdigit():
            kids.setdefault(int(f[1]), []).append(int(f[0]))
    seen, todo = [], [pid]
    while todo:
        for c in kids.get(todo.pop(), []):
            if c not in seen:
                seen.append(c)
                todo.append(c)
    return seen


def _kill_tree(proc):
    """Issue #4841: subprocess.run's timeout killed only the direct child, so a
    script's gh (and gh's own children) lived on past the tool's answer. Kill the
    whole tree. Not a new session: the scripts keep the pane's /dev/tty."""
    for pid in _descendants(proc.pid) + [proc.pid]:
        try:
            os.kill(pid, 9)
        except OSError:
            pass


def run(argv, *, input_text=None, check=True, timeout=None, env=None):
    try:
        # errors="replace" (issue #3129): a script's stderr can carry another
        # program's raw bytes — macOS awk echoes an illegal byte sequence it met
        # (a CJK char cut mid-sequence) — and a strict decode turned that into
        # the tool's own failure, whatever the script did.
        proc = subprocess.Popen(argv, stdin=None if input_text is None else subprocess.PIPE,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, errors="replace", env=env)
    except OSError as exc:
        raise ToolFault("%s could not start: %s" % (argv[0], exc))
    try:
        out, err = proc.communicate(input_text, timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_tree(proc)
        try:
            proc.communicate(timeout=5)
        except (subprocess.TimeoutExpired, OSError, ValueError):
            pass
        raise ToolFault("%s did not answer within %ss" % (Path(argv[0]).name, timeout))
    result = subprocess.CompletedProcess(argv, proc.returncode, out, err)
    if check and result.returncode != 0:
        msg = (result.stderr or result.stdout or "command failed").strip().replace("\n", " ")
        raise ToolFault(msg)
    return result


def tmux(*args):
    return run(["tmux", *args], timeout=STATUS_TIMEOUT_S).stdout.rstrip("\n")


def shquote(value):
    return "'" + value.replace("'", "'\\''") + "'"


def lib(script, check=True, args=()):
    return run(["bash", "-c", ". " + shquote(str(BIN / "fleet-lib.sh")) + "; " + script, "fleet-lib", *args],
               check=check, timeout=STATUS_TIMEOUT_S)


def current_session():
    pane = os.environ.get("TMUX_PANE", "")
    if not os.environ.get("TMUX") or not pane:
        raise ToolFault("not running inside a fleet tmux pane")
    sess = tmux("display-message", "-p", "-t", pane, "#{?#{session_group},#{session_group},#{session_name}}")
    if not sess:
        raise ToolFault("could not resolve the current fleet session")
    return sess


def origin_key():
    return lib("fleet_origin_key 2>/dev/null || true").stdout.strip()


def origin_option():
    pane = os.environ.get("TMUX_PANE", "")
    return tmux("display-message", "-p", "-t", pane, "#{@origin}") if pane else ""


# --- the worker credential (issue #1809, EPIC #1813 C7) -------------------------
#
# fwc1.<base64url claims JSON>.<base64url HMAC-SHA256> — signed with this login's
# key ($FLEET_CONF_DIR/worker-cred/key, 0600, made on first use). The claims name
# the session (fleet, fid = its lifelong @fleet_id, worker_id, and the key / repo /
# issue / origin it had when the credential was issued), when it expires, and a
# nonce the revoked list can name. The credential itself is never written down:
# minted to stdout, carried in the environment, renewed in this process's memory.
# Same uid, same key: this is an IDENTITY rail (a moved window, a pane that is not
# the session's), not a wall against a hostile session — the hub checks again (C8).

CRED_ENV = "FLEET_WORKER_CRED"
CRED_PREFIX = "fwc1"
CRED_TTL_S = 24 * 3600          # decision 7: at most 24h, renewed while the session lives
CRED_RENEW_S = 3600
CRED_FID_WAIT_S = 1.5           # a spawner stamps @fleet_id just after new-window
HELD = {"cred": None}           # the credential this server acts with (renewed in place)
CALLER = {"claims": None}       # the verified claims of the call being served


class CredRefused(ToolFault):
    """A credential was presented and does not hold: the call is refused."""


def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or (Path.home() / ".config" / "claude-fleet"))


def cred_dir():
    return conf_dir() / "worker-cred"


def cred_key(create=False):
    path = cred_dir() / "key"
    try:
        key = bytes.fromhex(path.read_text().strip())
        if len(key) >= 32:
            return key
    except (OSError, ValueError):
        pass
    if not create:
        raise CredRefused("this login has no worker-credential key")
    cred_dir().mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = cred_dir() / (".key.%d" % os.getpid())
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(secrets.token_hex(32) + "\n")
    try:
        os.link(str(tmp), str(path))     # first writer wins; a racing mint reads the winner's
    except FileExistsError:
        pass
    finally:
        os.unlink(str(tmp))
    return bytes.fromhex(path.read_text().strip())


def b64e(raw):
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def b64d(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def cred_sign(claims, key):
    body = CRED_PREFIX + "." + b64e(json.dumps(claims, sort_keys=True, separators=(",", ":")).encode())
    return body + "." + b64e(hmac.new(key, body.encode(), hashlib.sha256).digest())


def revoked_path():
    return cred_dir() / "revoked"


def cred_revoked(nonce):
    try:
        lines = revoked_path().read_text().splitlines()
    except OSError:
        return False
    return any(line.split(" ", 1)[0] == nonce for line in lines)


def cred_verify(cred, now=None):
    """The claims of a credential that holds, else CredRefused with why (never the credential)."""
    parts = (cred or "").split(".")
    if len(parts) != 3 or parts[0] != CRED_PREFIX:
        raise CredRefused("credential is malformed")
    want = hmac.new(cred_key(), (parts[0] + "." + parts[1]).encode(), hashlib.sha256).digest()
    try:
        got = b64d(parts[2])
        claims = json.loads(b64d(parts[1]).decode())
    except (ValueError, UnicodeDecodeError):
        raise CredRefused("credential is malformed")
    if not hmac.compare_digest(want, got):
        raise CredRefused("credential signature does not verify (forged, or another login's)")
    if not isinstance(claims, dict) or claims.get("v") != 1 or not claims.get("fid") or not claims.get("nonce"):
        raise CredRefused("credential claims are incomplete")
    if int(claims.get("exp", 0)) <= int(now if now is not None else time.time()):
        raise CredRefused("credential expired")
    if cred_revoked(claims["nonce"]):
        raise CredRefused("credential was revoked (its session exited)")
    return claims


def worker_id(claims):
    return "%s/%s" % (claims["fleet_uuid"], claims["fid"]) if claims.get("fleet_uuid") else claims["fid"]


def fleet_label():
    """This pane's FLEET: the socket label (== the fleet session, issue #159) — the same
    for a view session's client."""
    sock = os.environ.get("TMUX", "").split(",", 1)[0]
    if "/" in sock:
        return sock.rsplit("/", 1)[-1]
    return current_session()


def pane_opt(fmt):
    return tmux("display-message", "-p", "-t", os.environ["TMUX_PANE"], fmt)


def cred_mint():
    if not os.environ.get("TMUX") or not os.environ.get("TMUX_PANE"):
        raise ToolFault("not running inside a fleet tmux pane")
    deadline = time.time() + float(os.environ.get("FLEET_CRED_FID_WAIT", CRED_FID_WAIT_S))
    fid = pane_opt("#{@fleet_id}")
    while not fid and time.time() < deadline:
        time.sleep(0.05)   # the spawner's stamp lands within ms of new-window (T683)
        fid = pane_opt("#{@fleet_id}")
    session = current_session()
    if not fid:   # a road that does not stamp: mint it now (fleet_window_fid)
        wid = pane_opt("#{window_id}")
        fid = lib("fleet_window_fid " + shquote(session) + " " + shquote(wid)).stdout.strip()
    if not fid:
        raise ToolFault("this window has no @fleet_id and none could be minted")
    row = pane_opt("#{@repo}\t#{@issue}\t#{@origin}").split("\t")
    row += [""] * (3 - len(row))
    # the fleet's UUID and this pane's key in ONE sourcing of fleet-lib.sh (T683: each
    # is a bash start on the launch's critical path)
    both = lib("printf '%s\\n' \"$(fleet_uuid " + shquote(session) + " 2>/dev/null)\" "
               "\"$(fleet_origin_key 2>/dev/null)\"").stdout.split("\n")
    both += [""] * (2 - len(both))
    now = int(time.time())
    claims = {
        "v": 1, "fleet": fleet_label(), "fid": fid,
        "fleet_uuid": both[0].strip(),
        "key": both[1].strip(), "repo": row[0], "issue": row[1], "origin": row[2],
        "iat": now, "exp": now + CRED_TTL_S, "nonce": secrets.token_hex(12),
    }
    return cred_sign(claims, cred_key(create=True))


def cred_revoke(cred):
    claims = cred_verify(cred)
    path = revoked_path()
    now = int(time.time())
    keep = []
    try:   # drop the entries whose credential has expired anyway
        keep = [l for l in path.read_text().splitlines() if l.split(" ")[-1].isdigit() and int(l.split(" ")[-1]) > now]
    except OSError:
        pass
    keep.append("%s %d" % (claims["nonce"], int(claims["exp"])))
    tmp = path.with_name(".revoked.%d" % os.getpid())
    tmp.write_text("\n".join(keep) + "\n")
    os.replace(str(tmp), str(path))
    return claims


def cred_renew():
    """Re-sign the held credential with a fresh 24h, while it still holds (decision 7)."""
    cred = HELD["cred"]
    if not cred:
        return
    try:
        claims = cred_verify(cred)
    except ToolFault:
        return
    now = int(time.time())
    claims.update(iat=now, exp=now + CRED_TTL_S)
    HELD["cred"] = cred_sign(claims, cred_key())
    os.environ[CRED_ENV] = HELD["cred"]


def renew_loop():
    while True:
        time.sleep(CRED_RENEW_S)
        cred_renew()


def identify():
    """Who is calling: the verified claims, or None for a call with no credential.
    A credential that does not hold — or is presented from a pane that is not its
    session's, or from another fleet — refuses the call (CredRefused)."""
    cred = HELD["cred"]
    if not cred:
        return None
    claims = cred_verify(cred)
    if not os.environ.get("TMUX") or not os.environ.get("TMUX_PANE"):
        raise CredRefused("credential presented outside a fleet pane")
    here = fleet_label()
    if here != claims["fleet"]:
        raise CredRefused("credential is for fleet %s, this pane is in %s" % (claims["fleet"], here))
    fid = pane_opt("#{@fleet_id}")
    if fid != claims["fid"]:
        raise CredRefused("this pane's window (%s) is not the credential's session (%s)"
                          % (fid or "no @fleet_id", claims["fid"]))
    return claims


def log_path():
    return Path(os.environ.get("FLEET_MCP_LOG") or (Path(os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet")) / "logs" / "mcp-calls.log"))


# --- the hub route: a worker assertion (issue #1810, EPIC #1813 C8) ---------------
#
# fwa1.<base64url claims JSON>.<base64url HMAC-SHA256>, keyed with HashToken of the
# node's enrollment token (SHA-256 hex — the hub stores exactly that, so it checks
# the signature without a new secret). Minted per call, only for a call whose
# credential held, only when the hub is on for this fleet; handed to the script in
# its environment only. tokenledger/hub/api/fleet_worker_assert.go verifies it.

ASSERT_ENV = "FLEET_WORKER_ASSERT"
ASSERT_PREFIX = "fwa1"
ASSERT_TTL_S = 600              # a placement: the call is happening now
ASSERT_RELAY_TTL_S = 24 * 3600  # a message may wait in the hub outbox while the hub is away
SIGNED = {"assert": False}      # whether the call being served handed one out (the call log says so)
ROAD = {"call": False,          # served through --call (the mod's fallback, issue #2057), not MCP
        "legacy": False}        # a dispatch-group call answered by `fleet` (issue #3113)


def node_token_hash():
    """HashToken of this fleet's node token when the hub is on for it, else None.
    The token is read the way _fleet_hub_env reads it (the environment, else
    node.env) and never leaves this process: only its hash is kept."""
    r = lib('fleet_hub_on "$1" || exit 10; t="${CCQUOTA_TOKEN:-}"; '
            '[ -n "$t" ] || t=$(_fleet_node_env_val CCQUOTA_TOKEN 2>/dev/null); '
            '[ -n "$t" ] || exit 11; printf %s "$t"', check=False, args=[current_session()])
    token = r.stdout.strip() if r.returncode == 0 else ""
    if token.startswith("fcpn1."):
        # separated (issue #1971): that is the broker's credential, not the node
        # token — the proxy that holds the token hands over its hash alone
        h = subprocess.run(["bash", os.path.join(BIN, "fleet-cred-proxy.sh"), "node-hash"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=15)
        token = ""
        return h.stdout.strip() if h.returncode == 0 and len(h.stdout.strip()) == 64 else None
    return hashlib.sha256(token.encode()).hexdigest() if token else None


def worker_assertion(ttl):
    """The assertion for the call being served, or None: no credential, no fleet
    UUID, or no hub for this fleet (then nothing about the hub was touched)."""
    claims = CALLER["claims"]
    if not claims or not claims.get("fleet_uuid"):
        return None
    key_hash = node_token_hash()
    if not key_hash:
        return None
    now = int(time.time())
    body = {"v": 1, "worker_id": worker_id(claims), "fleet_uuid": claims["fleet_uuid"], "fid": claims["fid"],
            # the key it has NOW: a relay's `from` names the session by it
            "key": origin_key() or claims.get("key", ""), "repo": claims.get("repo", ""),
            "issue": claims.get("issue", ""), "origin": claims.get("origin", ""),
            "node": os.uname()[1].split(".", 1)[0], "iat": now, "exp": now + ttl}
    head = ASSERT_PREFIX + "." + b64e(json.dumps(body, sort_keys=True, separators=(",", ":")).encode())
    return head + "." + b64e(hmac.new(key_hash.encode(), head.encode(), hashlib.sha256).digest())


def hub_env(ttl):
    """The environment for a script that may act on another machine: this one,
    plus $FLEET_WORKER_ASSERT when the call is a session's own and the hub is on.
    None (inherit, unchanged) otherwise."""
    a = worker_assertion(ttl)
    if not a:
        return None
    SIGNED["assert"] = True
    env = dict(os.environ)
    env[ASSERT_ENV] = a
    return env


def log_call(tool, claims, verdict, why="", via=None):
    """One line per call: who (worker_id from the credential, or the window's marker),
    how it was known (cred | marker | badcred: one was presented and refused), and the
    verdict. Never the credential."""
    if claims:
        who, via = worker_id(claims), "cred"
    else:
        via = via or "marker"
        try:
            who = pane_opt("#{?@fleet_id,#{@fleet_id},#{window_name}}") if os.environ.get("TMUX_PANE") else ""
        except ToolFault:
            who = ""
    line = "%s tool=%s via=%s who=%s verdict=%s%s%s\n" % (
        time.strftime("%Y-%m-%dT%H:%M:%S%z"), tool, via, who or "-", verdict,
        " hub=asserted" if SIGNED["assert"] else "",
        (" road=call" if ROAD["call"] else " road=legacy" if ROAD["legacy"] else "")
        + ((" why=" + json.dumps(why, ensure_ascii=False)) if why else ""))
    try:
        log_path().parent.mkdir(parents=True, exist_ok=True)
        with open(str(log_path()), "a") as fh:
            fh.write(line)
    except OSError:
        pass


def cred_main(action):
    try:
        if action == "mint":
            print(cred_mint())
            return 0
        cred = os.environ.get(CRED_ENV, "")
        if not cred:
            print("fleet-mcp: no $%s in the environment" % CRED_ENV, file=sys.stderr)
            return 1
        if action == "check":
            claims = cred_verify(cred)
            print(json.dumps(dict(claims, worker_id=worker_id(claims)), sort_keys=True))
            return 0
        if action == "revoke":
            cred_revoke(cred)
            return 0
        if action == "assert":
            # The session's OWN assertion (issue #1972): what the wrapper hands the
            # hub to borrow a session pass (POST /v1/fleet/session-cred) for it.
            CALLER["claims"] = cred_verify(cred)
            a = worker_assertion(ASSERT_TTL_S)
            if not a:
                print("fleet-mcp: no hub for this fleet (or no fleet UUID): no assertion", file=sys.stderr)
                return 1
            print(a)
            return 0
    except ToolFault as exc:
        print("fleet-mcp: " + exc.message, file=sys.stderr)
        return 1
    print("usage: fleet-mcp.py --cred mint|check|revoke|assert", file=sys.stderr)
    return 2


# --- agents / send (issue #1185) ----------------------------------------------

FID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

def slug(repo):
    return re.sub(r"[^A-Za-z0-9._-]", "", repo.replace("/", "-"))


def scratch_key(path):
    name = path.rstrip("/").rsplit("/", 1)[-1]
    if name.startswith("scratch-"):
        value = name[8:]
    elif "-scratch-" in name:
        value = name.rsplit("-scratch-", 1)[1]
    else:
        return ""
    return "scratch-" + value if value.isdigit() else ""


def window_key(row, one_repo, no_repo=False):
    """fleet_window_okey's key: `<slug>:issue-N` / `<slug>:scratch-N` in every
    fleet (issue #1939); a window with no @repo is the fleet's ONE repo's
    (<one_repo>, fleet_window_repo's fallback), and nothing when that is unknown.
    A session with no key of its own answers to its identity, @fleet_id (issue
    #4341) — home and the panels have none."""
    fid = row.get("fleet_id", "")
    if row.get("role") in ("home", "panel") or not FID_RE.match(fid):
        fid = ""
    if row["issue"].isdigit():
        key = "issue-" + row["issue"]
    else:
        key = scratch_key(row["worktree"]) or scratch_key(row["path"])
        if not key:
            return fid
    if no_repo and not row["repo"]:
        return key                      # a fleet hosting no repo: bare is its only spelling
    if row["norepo"] == "1":
        return fid
    repo = row["repo"] or one_repo
    if not repo:
        return fid
    return slug(repo) + ":" + key


def child_keys():
    result = run(["bash", str(BIN / "fleet-children.sh"), "--json"], check=False, timeout=STATUS_TIMEOUT_S)
    if result.returncode != 0:
        return set()
    try:
        data = json.loads(result.stdout)
    except ValueError:
        return set()
    keys = set()
    for child in data.get("children", []):
        if not isinstance(child, dict):
            continue
        for field in ("child", "key"):
            value = child.get(field)
            if isinstance(value, str) and value:
                keys.add(value)
    return keys


def task_code(tref):
    """A task as a person reads it (EPIC T644 C3): its code — the login's book, else
    the hub (fleet-task-record.sh code) — else its T<n> (an older hub)."""
    try:
        r = run([str(BIN / "fleet-task-record.sh"), "code", tref], check=False, timeout=STATUS_TIMEOUT_S)
        c = (r.stdout.splitlines() or [""])[0].strip()
        return c if r.returncode == 0 and c else tref
    except Exception:
        return tref


def id_code(fid):
    """A window's ID as a person reads it (EPIC T497 C11): its short code `K3F9`, or
    "" (no ID). bin/fleet_id.py is the one encoder."""
    if not FID_RE.match(fid or ""):
        return ""
    try:
        sys.path.insert(0, str(BIN))
        import fleet_id
        return fleet_id.fold(fleet_id.read(fid))["opened"].get("short") \
            or fleet_id.short_for(fid, fleet_id.known_ids([fid]))
    except Exception:
        return ""
    finally:
        sys.path.pop(0)


def list_agents():
    session = current_session()
    me = origin_key()
    parent = origin_option()
    kids = child_keys()
    one = lib("fleet_repos " + shquote(session), check=False).stdout.split()
    one_repo = one[0] if len(one) == 1 else ""
    no_repo = not one
    fmt = "#{window_id}\t#{session_name}\t#{window_name}\t#{@issue}\t#{@cc_agent}\t" \
          "#{@claude_state}\t#{@claude_needs}\t" \
          "#{@origin}\t#{@repo}\t#{@norepo}\t#{@worktree}\t#{pane_current_path}\t#{@fleet_role}\t#{@fleet_id}"
    out = tmux("list-windows", "-a", "-F", fmt)
    agents = []
    for line in out.splitlines():
        parts = line.split("\t")
        while 12 <= len(parts) < 14:
            parts.append("")            # no @fleet_role / @fleet_id column: an older reader's row
        if len(parts) != 14 or parts[1] != session or parts[2] in ("dash", "plan", "backlog", "home"):
            continue
        row = dict(zip(("window_id", "session", "window_name", "issue", "agent", "state", "needs",
                        "origin", "repo", "norepo", "worktree", "path", "role", "fleet_id"), parts))
        key = window_key(row, one_repo, no_repo)
        state = row["needs"] or row["state"] or "unknown"
        agent = "codex" if row["agent"] == "codex" else "claude"
        agents.append({
            "window_id": row["window_id"],
            "window_name": row["window_name"],
            "id": id_code(row["fleet_id"]) or None,
            "issue": int(row["issue"]) if row["issue"].isdigit() else None,
            "agent": agent,
            "state": state,
            "key": key,
            "repo": row["repo"] or None,
            "is_self": bool(me and key == me),
            "is_parent": bool(parent and key == parent),
            "is_child": bool((me and row["origin"] == me) or (key and key in kids)),
        })
    return {"session": session, "self": me or None, "parent": parent or None, "agents": agents}


def parent_remote():
    """The parent's worker_id when it lives on ANOTHER machine (issue #3439): this
    pane's @origin_wid, unless its fleet UUID is one configured here. Empty when the
    pane has none, or the parent's fleet is this machine's."""
    pane = os.environ.get("TMUX_PANE", "")
    owid = tmux("display-message", "-p", "-t", pane, "#{@origin_wid}") if pane else ""
    if not owid or not re.match(r"^[A-Za-z0-9/:._-]+$", owid):
        return ""
    home = lib("fleet_wid_home " + shquote(owid) + " " + shquote(current_session()), check=False)
    return owid if home.returncode == 1 else ""


def parent_window():
    parent = origin_option()
    if not FID_RE.match(parent or "") \
            and not re.match(r"^([A-Za-z0-9._-]+:)?(issue|scratch)-[0-9]+$", parent or ""):
        # A parent on another machine is addressed by its worker_id (issue #3439);
        # fleet-peer-send.sh carries `wid:` through the hub.
        owid = parent_remote()
        if owid:
            return "wid:" + owid
        raise ToolFault("this session has no live-addressable parent")
    owid = parent_remote()
    if owid:
        return "wid:" + owid
    session = current_session()
    # The ONE resolver (fleet_win_for_key, issue #1537): rc 2 = the key is
    # ambiguous (two windows, or a bare issue key in a 2+ repo fleet) — said on
    # stderr; never a pick.
    # By IDENTITY first (issue #1646): fleet_origin_win reads this pane's
    # @origin_fid — the parent may have changed its key since it spawned us —
    # and falls back to the key through the same resolver.
    res = lib("fleet_origin_win " + shquote(session) + " " + shquote(os.environ["TMUX_PANE"])
              if os.environ.get("TMUX_PANE") else
              "fleet_win_for_key " + shquote(parent) + " " + shquote(session), check=False)
    wid = res.stdout.strip()
    if res.returncode == 2:
        why = (res.stderr or "").strip().replace("\n", " ")
        raise ToolFault("parent %s is ambiguous in this fleet — %s" % (parent, why or "several windows answer to it"))
    if res.returncode != 0 or not wid:
        raise ToolFault("parent is not online in this fleet")
    return wid


def repo_for_slug(slug):
    """The hosted repo whose fleet_slug is <slug> (a `<slug>:issue-<N>` key), or "" — through
    fleet_repos, the one list (issue #4761)."""
    try:
        sess = current_session()
    except ToolFault:
        return ""
    r = lib('fleet_repos "$1" | while IFS= read -r r; do [ "$(fleet_slug "$r")" = "$2" ] && printf "%s\\n" "$r"; done',
            check=False, args=(sess, slug))
    hits = [l for l in r.stdout.splitlines() if l.strip()]
    return hits[0] if len(hits) == 1 else ""


def caller_repo():
    """The CALLER window's own repo when the fleet hosts 2+ repos (fleet_target_repo's
    step 2, issue #4761): an issue number a repo-bound session names without a repo is
    its own repo's. One repo, or a window with none ⇒ "" — the script's own rule, byte
    for byte (a bare key in a 2+ repo fleet still refuses there)."""
    try:
        sess = current_session()
    except ToolFault:
        return ""
    r = lib('[ "$(fleet_repos "$1" | grep -c .)" -ge 2 ] && fleet_target_repo "$1"', check=False, args=(sess,))
    return r.stdout.strip() if r.returncode == 0 else ""


def repo_or_caller(args):
    """--repo <args.repo> (checked hosted), else the caller window's repo, else nothing."""
    if args.get("repo") is not None:
        return check_repo(args)
    r = caller_repo()
    return ["--repo", r] if r else []


def send_message(to, text, repo=None):
    if not isinstance(to, str) or not to.strip():
        raise Refused("to is required")
    if not isinstance(text, str) or not text.strip():
        raise Refused("text is required")
    target = to.strip()
    if target == "parent":
        raise Refused("PARENT_RETIRED: address the intended session explicitly; nothing sent")
    # `<slug>:issue-<N>` (issue #4761): the repo-qualified key fleet_win_for_key speaks —
    # its slug picks the repo, handed to the script as --repo.
    m = re.match(r"^([A-Za-z0-9._-]+):((?:issue|scratch)-[0-9]+)$", target)
    if m:
        named = repo_for_slug(m.group(1))
        if not named:
            raise Refused('"%s" names no repo this fleet hosts (the slug is owner-name)' % m.group(1))
        if repo is not None and repo != named:
            raise Refused("to names %s but repo is %s" % (named, repo))
        repo, target = named, m.group(2)
    # A session with no key of its own answers to its identity (issue #4341): `fid:<uuid>`
    # or the bare @fleet_id goes to the script as `wid:<uuid>` (fleet_win_for_fid).
    fid = target[4:] if target.startswith("fid:") else target
    if FID_RE.match(fid):
        target = "wid:" + fid
    if not re.match(
            r"^(issue:[0-9]+|#[0-9]+|issue-[0-9]+|scratch-[0-9]+|agent:[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}|[Tt]-[0-9A-Za-z]{4,26}"
            r"|#[A-Za-z][0-9A-Za-z]{3,25}|[A-Z][0-9A-Z]{3,25}"
            r"|wid:[A-Za-z0-9][A-Za-z0-9_.:/-]{0,200}|[@%][A-Za-z0-9_.:-]+)$", target):
        raise Refused("to must be issue:<N>, <slug>:issue-<N>, scratch-<N>, an ID code (K3F9 / #K3F9), agent:<name> or fid:<uuid>")
    is_issue = re.match(r"^(issue:|#|issue-)[0-9]+$", target) is not None
    if repo is not None:
        if not is_issue and not target.startswith("scratch-"):
            raise Refused("repo narrows an issue:<N> / scratch-<N> target only")
        argv_repo = check_repo({"repo": repo})
    else:
        # An issue number with no repo is the CALLER's repo's (issue #4761).
        r = caller_repo() if is_issue else ""
        argv_repo = ["--repo", r] if r else []
    result = run(["bash", str(BIN / "fleet-peer-send.sh")] + argv_repo + [target, "-"], input_text=text, check=False,
                 timeout=STATUS_TIMEOUT_S, env=hub_env(ASSERT_RELAY_TTL_S))
    # Exit 3 = queued (issue #1647): the peer cannot take it now; it is delivered
    # when it can. Not delivered — and not an error either.
    if result.returncode == 3:
        return {"delivered": False, "queued": True, "receipt": result.stdout.strip(), "to": to}
    # Exit 2 with a stdout line = the peer has ENDED (issue #1649): when and how,
    # nothing sent. Exit 2 with only stderr is a usage refusal, raised below.
    if result.returncode == 2 and result.stdout.strip():
        return {"delivered": False, "ended": True, "receipt": result.stdout.strip(), "to": to}
    if result.returncode != 0:
        raise ToolFault((result.stderr or result.stdout or "command failed").strip().replace("\n", " "))
    return {"delivered": True, "receipt": result.stdout.strip(), "to": to}


# --- the script-backed tools ----------------------------------------------------

def script(argv, timeout, env=None):
    """Run a script unchanged; its exit code, stdout and stderr come back as they came."""
    r = run(argv, check=False, timeout=timeout, env=env)
    return {"command": Path(argv[0]).name, "exit": r.returncode, "stdout": r.stdout, "stderr": r.stderr}


def hosted_repos():
    """The repos `fleet-repo.sh list` prints (two-space-indented rows, repo first)."""
    r = run([str(BIN / "fleet-repo.sh"), "list"], check=False, timeout=STATUS_TIMEOUT_S)
    out = []
    for line in r.stdout.splitlines():
        m = re.match(r"^ {2}(\S+/\S+)\s", line)
        if m:
            out.append(m.group(1))
    return out, r


def check_repo(args):
    repo = args.get("repo")
    if repo is None:
        return []
    repos, _ = hosted_repos()
    if repo not in repos:
        raise Refused('repo "%s" is not hosted by this fleet (hosted: %s)'
                      % (repo, ", ".join(repos) if repos else "none could be read"))
    return ["--repo", repo]


def tool_status(_args):
    pane = os.environ.get("TMUX_PANE", "")
    window = None
    if os.environ.get("TMUX") and pane:
        window = run(["tmux", "display-message", "-p", "-t", pane,
                      "window #{window_name} · issue=#{@issue} repo=#{@repo} state=#{@claude_state} "
                      "origin=#{@origin}"],
                     check=False, timeout=STATUS_TIMEOUT_S).stdout.strip() or None
    task = pane_task()
    if window and task:
        window += " task=" + task_code(task)   # the task's code (EPIC T644 C3), else T<n>
    kids = {"exit": 0, "stdout": "", "stderr": ""}  # compat shape, no child lookup
    repos, listed = hosted_repos()
    claims = CALLER["claims"]
    identity = ({"worker_id": worker_id(claims), "via": "credential",
                 "expires": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(int(claims["exp"])))}
                if claims else {"worker_id": None, "via": "window options (no credential)"})
    return {"window": window, "identity": identity, "children": kids, "repos": repos,
            "repo_list": listed.stdout.rstrip("\n")}


def tool_children(_args):
    raise Refused("RETIRED: Parent/child coordination is disabled; view each Task directly.")


def tool_repos(_args):
    repos, listed = hosted_repos()
    return {"command": "fleet-repo.sh", "exit": listed.returncode, "repos": repos,
            "stdout": listed.stdout, "stderr": listed.stderr}


def tool_spawn(args):
    repo = repo_or_caller(args)   # no repo: the caller window's own (issue #4761)
    reap = ["--reap", args["reap"]] if args.get("reap") else []   # issue #1902
    as_ = ["--as", args["agent"]] if args.get("agent") else []    # issue #3122
    return script([str(BIN / "dash-issue-session.sh"), str(args["issue"])] + repo + reap + as_ + (["--agent", args["coding_agent"]] if args.get("coding_agent") else []), SPAWN_TIMEOUT_S,
                  env=hub_env(ASSERT_TTL_S))


def tool_schedule(args):
    if args.get("repo"):
        check_repo(args)
    r = run([sys.executable, str(BIN / "fleet-schedule.py")],
            input_text=json.dumps(args), check=False, timeout=WRITE_TIMEOUT_S,
            env=hub_env(ASSERT_TTL_S))
    if r.returncode:
        raise ToolFault(r.stderr.strip() or "schedule request failed")
    return json.loads(r.stdout)


def tool_set_reap(args):
    """When the fleet may close THIS session on its own (issue #1902)."""
    # --by session (T694, 回收 B): a `keep` the session sets for itself lapses
    # once its work is over — only a person's keep holds.
    return script([str(BIN / "fleet-reap-policy.sh"), "set", args["policy"], "--by", "session"], STATUS_TIMEOUT_S)


def tool_await(_args):
    raise Refused("RETIRED: Fleet await is disabled. Use the native agent for subagents; view each Task directly.")


def local_id(code):
    """Does a window's ID on this login answer to `code`? (fleet_id.resolve: one or
    several — an ambiguity is the ID road's to refuse). A full ID or an old `T-` code
    always is the ID road."""
    if FID_RE.match(code) or code[:2] in ("T-", "t-"):
        return True
    try:
        sys.path.insert(0, str(BIN))
        import fleet_id
        live = [x for x in os.environ.get("FLEET_ID_LIVE", "").split() if fleet_id.is_fid(x)]
        return fleet_id.resolve(code, live)[0] != 1
    except Exception:
        return True
    finally:
        sys.path.pop(0)


def tool_task(args):
    """A dispatch, record first (issue #3330): fleet-task-record.sh
    dispatch — the hub's T<n>, then (+ spawn) its session: a repo task's worktree
    bound to the record, or a no-repo session given the words."""
    argv = [str(BIN / "fleet-task-record.sh"), "dispatch", "--title", args["title"], "--body-file", "-"]
    if args.get("repo"):
        argv += ["--repo", args["repo"]]
    if args.get("spawn"):
        argv.append("--spawn")
    if args.get("reap"):
        argv += ["--reap", args["reap"]]
    if args.get("agent"):
        argv += ["--as", args["agent"]]
    if args.get("coding_agent"):
        argv += ["--agent", args["coding_agent"]]
    r = run(argv, input_text=args.get("body", ""), check=False, timeout=FILE_TIMEOUT_S + SPAWN_TIMEOUT_S,
            env=hub_env(ASSERT_TTL_S))
    out = {"command": "fleet-task-record.sh", "exit": r.returncode, "stdout": r.stdout, "stderr": r.stderr}
    # ONE code names it (EPIC T644 C3): stdout is the task's code, then T<n> (an older
    # hub: T<n> alone). `id` / `short` = the task's code — await / send / get take it;
    # `task` / `alias` = T<n> (compat-1v: 下一批删). An older hub: `id` = the session's
    # ID code, as before (EPIC T497 C11).
    lines = [x.strip() for x in r.stdout.splitlines()[:2]]
    task = next((x for x in lines if re.match(r"^T[1-9][0-9]{0,9}$", x)), "")
    short = lines[0] if lines and task and lines[0] != task and re.match(r"^[A-Z][0-9A-Z]{1,25}$", lines[0]) else ""
    if r.returncode == 0 and task:
        if short:
            out.update(id=short, short=short, task=task, alias=task)
        if args.get("spawn"):
            fid = task_window_fid(task)
            code = id_code(fid)
            if code:
                out.update(session_id=fid, alias=task)
                if not short:
                    out.update(id=code)
    return out


def task_window_fid(task):
    """The @fleet_id of the live window bound to hub task `task` (its @task), or ""."""
    try:
        rows = tmux("list-windows", "-a", "-F", "#{@task}\t#{@fleet_id}")
    except Exception:
        return ""
    for line in rows.splitlines():
        t, _, fid = line.partition("\t")
        if t == task and FID_RE.match(fid):
            return fid
    return ""


def tool_agents(_args):
    return list_agents()


def tool_send(args):
    return send_message(args.get("to"), args.get("text"), args.get("repo"))


# --- 报 问 记 合 (issue #1808, EPIC #1813 C6) ------------------------------------

def stdin_script(argv, text, timeout):
    """script(), with `text` on stdin (a body / a doc — never through argv)."""
    r = run(argv, input_text=text, check=False, timeout=timeout)
    return {"command": Path(argv[0]).name, "exit": r.returncode, "stdout": r.stdout, "stderr": r.stderr}


def pane_issue():
    """This window's @issue, or "" — read off THIS pane, never `-t ""` (#1537)."""
    pane = os.environ.get("TMUX_PANE", "")
    if not os.environ.get("TMUX") or not pane:
        return ""
    r = run(["tmux", "display-message", "-p", "-t", pane, "#{@issue}"], check=False, timeout=STATUS_TIMEOUT_S)
    v = r.stdout.strip()
    return v if v.isdigit() else ""


def pane_task():
    """This window's hub task record (@task, issue #3325), or "" — off THIS pane."""
    pane = os.environ.get("TMUX_PANE", "")
    if not os.environ.get("TMUX") or not pane:
        return ""
    r = run(["tmux", "display-message", "-p", "-t", pane, "#{@task}"], check=False, timeout=STATUS_TIMEOUT_S)
    v = r.stdout.strip()
    return v if re.match(r"^T[1-9][0-9]{0,9}$", v) else ""


def task_asked(task, line):
    """The question on the hub's record (issue #3330): 「问过你」. None when there is
    no record; the script's result otherwise (exit 3 = no hub here, nothing sent)."""
    if not task:
        return None
    return script([str(BIN / "fleet-task-record.sh"), "set", task, "--asked", line], WRITE_TIMEOUT_S)


def tool_report(args):
    argv = [str(BIN / "fleet-report-parent.sh"), "--state", args["state"]]
    if "pr" in args:
        argv += ["--pr", str(args["pr"])]
    if "outcome" in args:
        argv += ["--outcome", args["outcome"]]
    if "summary" in args:
        argv += ["--summary", args["summary"]]
    if args.get("dry_run"):
        argv.append("--dry-run")
    return script(argv, WRITE_TIMEOUT_S)


ASK_HEAD = {"question": "⛔ blocked: ", "permission": "⛔ blocked — needs authorization: "}


_UI = {}


def ui_t(key, arg):
    """One string off THE table (bin/fleet-ui-lang.sh dump), read once a process; a
    key it lacks shows itself, never a blank."""
    if not _UI:
        try:
            out = run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "ask_hint_"], check=False,
                      timeout=STATUS_TIMEOUT_S).stdout
        except Exception:   # any failure: the key shows itself
            out = ""
        parts = out.split("\0")
        _UI.update(zip(parts[0::2], parts[1::2]))
        _UI.setdefault("", "")
    return _UI.get(key, key + ": \x01").replace("\x01", arg, 1)


def ask_hints(args):
    """The suggestion / default / deadline lines under a question (issue #4337):
    hints for whoever answers — nobody answers at the deadline any more (EPIC #4333
    拍板 2), so they carry no marker anything acts on. `class` is accepted and unused."""
    return ["- " + ui_t("ask_hint_" + k, args[k]) for k in ("suggest", "default", "due") if args.get(k)]


def tool_ask(args):
    # The question goes on this window's hub task record (「问过你」, issue #3330);
    # with no record it is the red stamp alone — the fleet
    # writes no GitHub comment (issue #4898). `issue` is accepted from old callers
    # and unused.
    task = pane_task()
    head = ASK_HEAD[args.get("kind", "question")] + args["question"]
    hints = ask_hints(args)
    out = {"body": "\n".join([head, ""] + hints) if hints else head}
    if task:
        rec = task_asked(task, head)
        if rec["exit"] != 0:
            raise Refused("this window's record %s could not take the question (%s) — ask in your reply"
                          % (task, (rec.get("stderr") or "no hub here").strip() or "exit %d" % rec["exit"]))
        out.update(rec, task=task)
    else:
        out.update(command="ask", exit=0, stdout=out["body"] + "\n", stderr="")
    # stdin pinned shut — `blocked` reads no hook payload.
    red = stdin_script(["sh", str(BIN / "set-claude-state.sh"), "blocked"], "", STATUS_TIMEOUT_S)
    red["command"] = "set-claude-state.sh"
    out.update(state=red)
    return out


def tool_answer_dialog(args):
    """答 — the one guarded road into another session's open choice dialog (issue #2958)."""
    argv = [str(BIN / "fleet-dialog-answer.sh"), args["window"], "--fp", args["fp"],
            "--by", args.get("by", "person")]
    for p in args["picks"]:
        argv += ["--pick", p]
    for k in ("basis", "issue"):
        if args.get(k):
            argv += ["--" + k, args[k]]
    return script(argv, WRITE_TIMEOUT_S + 90)


def tool_clear(args):
    """清 — /clear another session by its ID, the guarded road (T592, bin/fleet-clear-send.sh)."""
    argv = [str(BIN / "fleet-clear-send.sh"), args["id"]]
    if args.get("timeout"):
        argv += ["--timeout", str(args["timeout"])]
    return script(argv, WRITE_TIMEOUT_S + 90)


def tool_handoff(args):
    action = args["action"]
    if action == "arm":
        extra = [k for k in ("slug",) if k in args]
        if extra:
            raise Refused("arm takes no slug")
        return tool_handoff_arm(args)
    if "repo" in args:
        raise Refused("repo applies to arm only")
    if "slug" in args and action != "path":
        raise Refused("slug applies to path only")
    if action == "check" and "doc" not in args:
        raise Refused('check needs doc (the composed handoff text)')
    if action != "check" and ("doc" in args or "issue" in args):
        raise Refused("doc and issue apply to check only")
    argv = [str(BIN / "fleet-handoff-file.sh"), action]
    if "slug" in args:
        argv += ["--slug", args["slug"]]
    if action == "check":
        argv.append("-")
        if "issue" in args:
            argv += ["--issue", str(args["issue"])]
        return stdin_script(argv, args["doc"], STATUS_TIMEOUT_S)
    return script(argv, STATUS_TIMEOUT_S)


def pr_arg(args):
    """The PR number, when given: a repo the fleet lands itself (FLEET_LAND=fleet, issue #3602)
    has no PR — there it names the issue whose branch lands, and left out the window's branch."""
    return [str(args["pr"])] if "pr" in args else []


def tool_pr_verdict(args):
    if not args.get("wait") and ("until_merged" in args or "timeout" in args):
        raise Refused("until_merged and timeout apply with wait only")
    argv = [str(BIN / "fleet-pr-verdict.sh")] + pr_arg(args) + check_repo(args)
    if not args.get("wait"):
        return script(argv, LAND_TIMEOUT_S)
    t = args.get("timeout", AWAIT_DEFAULT_S)
    argv += ["--wait", "--timeout", str(t)]
    if args.get("until_merged"):
        argv.append("--until-merged")
    return script(argv, t + AWAIT_SLACK_S)


def tool_pr_merge(args):
    return script([str(BIN / "fleet-pr-merge.sh")] + pr_arg(args) + check_repo(args), LAND_TIMEOUT_S)


# --- the rest of a worker skill (issue #1811, EPIC #1813 C9) --------------------

def tool_brief(args):
    if args.get("kind") == "resume":
        extra = [k for k in ("repo",) if k in args]
        if extra:
            raise Refused("resume takes no %s" % ", ".join(extra))
        return script([str(BIN / "fleet-compact-resume.sh"), "--brief"], STATUS_TIMEOUT_S)
    # kind task (default; `claim` is an old session's word for it): the record —
    # issue #4898. `issue` / `no_comments` are accepted from old callers, unused.
    return script([str(BIN / "fleet-brief.sh")] + check_repo(args), BRIEF_TIMEOUT_S)


# --- the dispatch group (issue #3113, EPIC #3111 C2) -------------------------------

def bridge_seat():
    """May THIS pane dispatch? (--bridge-seat) Every fleet pane may (issue #4703, after
    #4591): the dispatch group is mounted for every session and `@agent_spawn` is no
    gate — read for nothing here. Outside tmux there is no pane to dispatch from."""
    return bool(os.environ.get("TMUX") and os.environ.get("TMUX_PANE"))


def tool_context(args):
    return script([str(BIN / "fleet-context.sh")] + (["--json"] if args.get("json") else []), STATUS_TIMEOUT_S)


def tool_handoff_arm(args):
    """Arm bin/fleet-handoff-cycle.sh DETACHED: it waits for this turn to end, so
    the call returns at once — and it must outlive the tool call."""
    given = [k for k in ("doc", "issue") if k in args]
    if len(given) != 1:
        raise Refused("arm takes exactly one of doc (file storage) or issue (comment storage)")
    pane = os.environ.get("TMUX_PANE", "")
    if not os.environ.get("TMUX") or not pane:
        raise Refused("arm needs this session's tmux pane (TMUX / TMUX_PANE unset)")
    argv = [str(BIN / "fleet-handoff-cycle.sh"), "--pane", pane]
    if "doc" in args:
        argv += ["--doc", args["doc"]]
    else:
        argv += ["--issue", str(args["issue"])] + check_repo(args)
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as exc:
        raise ToolFault("fleet-handoff-cycle.sh could not start: %s" % exc)
    return {"command": "fleet-handoff-cycle.sh", "exit": 0, "pid": proc.pid,
            "stdout": "armed (pid %d): clears this pane and types the pickup after this turn ends — "
                      "end the turn now, no further tool call\n" % proc.pid, "stderr": ""}


def tool_transfer(args):
    action = args["action"]
    allowed = {"check": {"to"}, "arm": {"to", "handoff", "loop"}, "export_loop": {"transcript", "output"}}[action]
    extra = [k for k in ("to", "handoff", "loop", "transcript", "output") if k in args and k not in allowed]
    if extra:
        raise Refused("%s takes no %s" % (action, ", ".join(extra)))
    missing = [k for k in sorted(allowed - {"loop"}) if k not in args]
    if missing:
        raise Refused("%s needs %s" % (action, ", ".join(missing)))
    if action == "export_loop":
        return script(["python3", str(BIN / "fleet-loop.py"), "from-claude", "--transcript", args["transcript"],
                       "--output", args["output"]], STATUS_TIMEOUT_S)
    pane = os.environ.get("TMUX_PANE", "")
    if not pane:
        raise Refused("transfer needs this session's tmux pane (TMUX_PANE unset)")
    argv = [str(BIN / "fleet-transfer.sh"), "--session", current_session(), "--window", pane, "--to", args["to"]]
    if action == "check":
        return script(argv + ["--dry-run"], VERDICT_TIMEOUT_S)
    argv += ["--handoff", args["handoff"]]
    if "loop" in args:
        argv += ["--loop", args["loop"]]
    return script(argv + ["--after-turn"], VERDICT_TIMEOUT_S)


def tool_where(args):
    return script([str(BIN / "fleet-client-where.sh")] + (["--json"] if args.get("json") else []), STATUS_TIMEOUT_S)


def tool_show(args):
    argv = [str(BIN / "fleet-show.sh")] + (["--inline"] if args.get("inline") else []) + ["--", args["file"]]
    return script(argv, SHOW_TIMEOUT_S)


def tool_open(args):
    return script([str(BIN / "fleet-open.sh"), "--", args["target"]], STATUS_TIMEOUT_S)


def tool_preview(args):
    """The current credential's own task; no caller-supplied identity."""
    from fleet_hub_rest import api, Fail
    assertion = worker_assertion(ASSERT_TTL_S)
    task = pane_task()
    if not assertion or not task:
        raise ToolFault("preview requires a verified worker credential and its current Hub Task")
    if args["action"] in ("dev", "stop"):
        return preview_dev(args) if args["action"] == "dev" else preview_stop(args)
    SIGNED["assert"] = True
    action = args["action"]
    body = {"action": action}
    for k in ("socket", "id"):
        if k in args:
            body[k] = args[k]
    try:
        return api("GET" if action == "list" else "POST", "/previews",
                   body=None if action == "list" else body, query={"task": task},
                   root="/v1/node", headers={"X-Fleet-Worker": assertion})
    except Fail as exc:
        raise ToolFault(str(exc)) from exc


# `dev` / `stop`: a dev server run by bin/fleet-preview.py dev in the background — it
# opens the socket, forwards to the command's own loopback listener, registers and
# renews the preview (through `--call preview`, as this session) and closes it when the
# command ends. One run per name; its pid, log and command in $FLEET_CONF_DIR/preview/.
PREVIEW_NAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,34}$")
PREVIEW_DEV_WAIT_S = 30


def preview_rec(name):
    if not PREVIEW_NAME_RE.match(name):
        raise ToolFault('"name" must be letters, digits, - and _ (at most 35), got %s' % json.dumps(name))
    d = conf_dir() / "preview"
    d.mkdir(mode=0o700, parents=True, exist_ok=True)
    return d / (name + ".json"), d / (name + ".log")


def preview_running(rec):
    try:
        pid = json.loads(rec.read_text())["pid"]
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError, KeyError, TypeError):
        return None


def preview_seen(log, limit=4000):
    try:
        text = log.read_text(errors="replace")
    except OSError:
        return {"output": ""}
    m = re.search(r"(?:registered|reusing) (\S+) \((\w*)\)", text)
    return {"url": m.group(1) if m else None, "id": m.group(2) if m else None,
            "ready": "fleet preview: ready:" in text, "output": text[-limit:]}


def preview_dev(args):
    name = args.get("name") or "dev"
    rec, log = preview_rec(name)
    cmd = args.get("command")
    if not cmd:
        raise ToolFault('dev needs "command": the dev server, as you would type it (e.g. "npm run dev")')
    if preview_running(rec):
        raise ToolFault('a dev preview named "%s" is already running; stop it first, or pick another "name"' % name)
    cwd = args.get("cwd") or os.getcwd()
    if not os.path.isdir(cwd):
        raise ToolFault('"cwd" is not a directory: %s' % cwd)
    argv = [sys.executable, str(BIN / "fleet-preview.py"), "dev", "--name", name]
    argv += ["--port", str(args["port"])] if args.get("port") else []
    argv += ["--unix"] if args.get("unix") else []
    argv += ["--keep"] if args.get("keep") else []
    with open(log, "w") as fh:
        p = subprocess.Popen(argv + ["--", "/bin/sh", "-c", cmd], cwd=cwd, stdin=subprocess.DEVNULL, stdout=fh,
                             stderr=subprocess.STDOUT, start_new_session=True)
    threading.Thread(target=p.wait, daemon=True).start()
    rec.write_text(json.dumps({"pid": p.pid, "log": str(log), "cwd": cwd, "command": cmd}))
    end = time.time() + PREVIEW_DEV_WAIT_S
    while time.time() < end and p.poll() is None and not preview_seen(log)["ready"]:
        time.sleep(0.25)
    out = dict(preview_seen(log), name=name, pid=p.pid, log=str(log), running=p.poll() is None)
    if p.poll() is not None:
        out["exit"] = p.returncode
    out["next"] = ("give the person the url — it opens after they sign in as the task's owner; "
                   "stop with action stop, name %s" % name if out["running"] else "it ended; read output")
    return out


def preview_stop(args):
    name = args.get("name") or "dev"
    rec, log = preview_rec(name)
    pid = preview_running(rec)
    if not pid:
        return dict(preview_seen(log, 1000), name=name, running=False, stopped="nothing was running")
    for sig, secs in ((signal.SIGTERM, 10), (signal.SIGKILL, 2)):
        try:
            os.killpg(pid, sig)
        except OSError:
            pass
        end = time.time() + secs
        while time.time() < end and preview_running(rec):
            time.sleep(0.2)
        if not preview_running(rec):
            break
    seen = preview_seen(log, 1000)
    if "preview closed" not in seen["output"] and "kept" not in seen["output"] and seen.get("id"):
        script([sys.executable, str(BIN / "fleet-mcp.py"), "--call", "preview",
                json.dumps({"action": "close", "id": seen["id"]})], WRITE_TIMEOUT_S)
    return dict(seen, name=name, running=bool(preview_running(rec)), stopped="sent SIGTERM to pid %d" % pid)


# A session's reap policy (issue #1902) — bin/fleet_reap_policy.py is the grammar;
# the script canonicalizes or refuses (exit 2), this is only its shape.
REAP_POLICY = {"type": "string", "maxLength": 48,
               "pattern": r"^(?:(?:merged|done|idle)(?::[1-9][0-9]{0,6}[smhd]?)?|loop-end|keep|at:[0-9][0-9TZ:+-]{0,31})$"}
ISSUE = {"type": "integer", "minimum": 1, "description": 'The GitHub issue number (a positive integer, no "#").'}
PR_NUM = {"type": "integer", "minimum": 1,
          "description": "The PR number. In a repo the fleet lands itself (FLEET_LAND=fleet, issue #3602): the "
                         "issue whose branch issue-<N> lands; left out, the window's branch."}
REPO = {"type": "string", "pattern": r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$",
        "description": "owner/name of a repo THIS fleet hosts (the repos tool lists them). "
                       "Omit for your own window's repo, else the fleet's only one."}
NO_ARGS = {"type": "object", "properties": {}, "additionalProperties": False}
# A hub task record (issue #3325) by its code (K5H0, #k5 — EPIC T644 C3), its full ID,
# or the old T<n> (read one more version; compat-1v: 下一批删).
TASK_REF = {"type": "string",
            "pattern": r"^(?:T[1-9][0-9]{0,9}|#?[A-Za-z][0-9A-Za-z]{1,25}"
                       r"|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$",
            "description": "A task by its code (K5H0 — the task tool's `id`), its full ID, or the old T<n>."}

TOOLS = {
    "schedule": (tool_schedule, {
        "description": "Manage this user's recurring Tokenman tasks on THIS login: create/list/update/pause/resume/delete/run-now/runs. "
                       "Reuse the existing node task scheduler. Default timezone Asia/Shanghai; explain the timezone and next run. "
                       "Never choose another user's login. list returns stable ids and revisions; send revision on edits. "
                       "Limits: 10 tasks, minimum hourly, 24 scheduled slots and 30 total starts/day, one running at a time. "
                       "A pending registration is not yet scheduled. Results stay private; delivery may opt into the user's own WeChat/live page.",
        "inputSchema": {"type": "object", "properties": {
            "action": {"type": "string", "enum": ["create", "list", "update", "pause", "resume", "delete", "run-now", "runs"]},
            "id": {"type": "string"}, "revision": {"type": "integer", "minimum": 1},
            "idempotency_key": {"type": "string", "description": "Reuse the same key when retrying the same write."},
            "adopt": {"type": "string", "description": "create only: adopt a paused, finished existing CLI task by name; preserve its exact prompt, time and timezone. No duplicate registry entry."},
            "name": {"type": "string", "maxLength": 120}, "prompt": {"type": "string", "maxLength": 16000},
            "at": {"type": "string", "description": "Daily local HH:MM; mutually exclusive with cron."},
            "cron": {"type": "string", "description": "Five cron fields; minimum one-hour interval."},
            "timezone": {"type": "string", "description": "IANA zone, default Asia/Shanghai."},
            "agent": {"type": "string", "enum": ["", "claude", "codex"], "description": "Agent type. Omitted on create uses the fleet default; omitted on update keeps the choice; empty resets to fleet default."},
            "repo": dict(REPO, description="Optional owner/name of a repo this login hosts; omitted runs without a repository."),
            "delivery": {"type": "object", "properties": {"wechat": {"type": "boolean"}, "livepage": {"type": "boolean"}}, "additionalProperties": False}},
            "required": ["action"], "additionalProperties": False}}),

    "preview": (tool_preview, {
        "description": "A private live HTTP/WebSocket preview of this verified worker's own Task, opened by its owner after sign-in. "
                       "dev: run a dev server (npm run dev, next dev, vite, uvicorn …) in the background and preview it — "
                       "its loopback TCP port is forwarded only while the command's own processes hold it, HMR included; "
                       "the lease renews while it runs and closes when it ends; returns url, log, output. stop: end it. "
                       "register/list/renew/close: a Unix socket you serve yourself (basename in ~/.fleet-preview 0700, socket 0600). "
                       "Lease 2h. Static deliverables still use Space/活页.",
        "inputSchema": {"type": "object", "properties": {
            "action": {"type": "string", "enum": ["dev", "stop", "register", "list", "renew", "close"]},
            "command": {"type": "string", "description": "dev: the dev server command, run by /bin/sh in cwd. "
                                                         "It gets PORT and HOST=127.0.0.1; {port} in it is replaced."},
            "name": {"type": "string", "description": "dev/stop: which run (default dev); one socket ~/.fleet-preview/<name>.sock."},
            "cwd": {"type": "string", "description": "dev: directory to run in (default this session's)."},
            "port": {"type": "integer", "minimum": 1, "maximum": 65535,
                     "description": "dev: the port it listens on when it ignores PORT (default: found from its processes)."},
            "unix": {"type": "boolean", "description": "dev: it listens on $FLEET_PREVIEW_SOCKET itself (uvicorn --uds, gunicorn unix:)."},
            "keep": {"type": "boolean", "description": "dev: keep the preview at exit so the next run with this name gets the same URL."},
            "socket": {"type": "string", "description": "Socket basename, e.g. app.sock; register only."},
            "id": {"type": "string", "description": "Preview ID for renew/close."}},
            "required": ["action"], "additionalProperties": False}}),
    "status": (tool_status, {
        "description": "Read-only. This fleet window's binding and the hosted repos. Changes nothing.",
        "inputSchema": NO_ARGS}),
    "children": (tool_children, {
        "description": "Read-only. Every child session this one spawned — ledger outcome, live state, PR — "
                       "as bin/fleet-children.sh --json prints it.",
        "inputSchema": NO_ARGS}),
    "repos": (tool_repos, {
        "description": "Read-only. The GitHub repos this fleet hosts (bin/fleet-repo.sh list).",
        "inputSchema": NO_ARGS}),
    "agents": (tool_agents, {
        "description": "Read-only. The live sessions in this fleet: issue, agent (claude/codex), state, and "
                       "whether each is this session, its parent or its child.",
        "inputSchema": NO_ARGS}),
    "spawn": (tool_spawn, {
        "description": "Start a fleet worker session on an existing GitHub issue (its own worktree + window; "
                       "the issue's words are its first turn, it implements and lands a PR that closes it — "
                       "nothing claims or comments on the issue, issue #4898). New work: the task tool. Runs "
                       "bin/dash-issue-session.sh, so the session caps apply. Exit 0 spawned (or the window "
                       "already exists), 2 at capacity, 3 closed or already has a PR, 1 infrastructure. "
                       "Returns at once. "
                       "Any session may start an independent task; use native subagents for internal orchestration.",
        "inputSchema": {"type": "object", "properties": {
            "issue": ISSUE, "repo": REPO,
            "coding_agent": {"type": "string", "enum": ["claude", "codex"], "description": "CLI provider; overrides template, labels and fleet defaults."},
            "reap": dict(REAP_POLICY, description="When the fleet may close it on its own (default merged: "
                                                  "after its PR merged) — see set_reap."),
            "agent": {"type": "string", "pattern": "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$",
                      "description": "The agent file it starts as (issue #3122): a standard Claude Code agent "
                                     "— the repo's .claude/agents > ~/.claude/agents > a plugin; its model, "
                                     "tools and body. Default: fleet-worker when it is there. Not found = "
                                     "refused, naming where it looked."},
},
            "required": ["issue"], "additionalProperties": False}}),
    "set_reap": (tool_set_reap, {
        "description": "When the fleet may close THIS session on its own (bin/fleet-reap-policy.sh set; issue "
                       "#1902): merged (after its PR merged + the fleet's grace) · merged:48h (keep it 48 hours "
                       "after the merge, e.g. to wait for a read-back) · done:15m (its turn over and idle 15 minutes) "
                       "· idle:15m (idle 15 minutes, done or not — e.g. waiting on a person's call) "
                       "· loop-end (once its /loop stops) · at:18:00 or at:<ISO time> · keep (not while its "
                       "work is open — a keep you set yourself lapses once your work is over; only a person's holds). "
                       "Every automatic close records history first and keeps unpushed work. Exit 0 set, "
                       "2 not a policy, 1 no window.",
        "inputSchema": {"type": "object", "properties": {"policy": REAP_POLICY},
                        "required": ["policy"], "additionalProperties": False}}),
    "await": (tool_await, {
        "description": "RETIRED: Fleet await returns immediately without spawning or waiting. Use native subagents and view independent Tasks directly.",
        "inputSchema": {"type": "object", "properties": {
            "issue": ISSUE, "repo": REPO,
            "id": {"type": "string", "pattern": "^#?[A-Za-z0-9-]{4,40}$",
                   "description": "Wait on it by its code instead: a task's code K3F9 (the task tool's `id`) "
                                  "until the task is closed, or a session's code / full ID until it has a "
                                  "result or closes (MERGED / SUCCEEDED / FAILED / EXITED)."},
            "task": dict(TASK_REF, description="Wait on a task by its code (K3F9), its ID or the old T<n>: "
                                               "until it is closed — SUCCEEDED / FAILED / CANCELLED (a dispatched "
                                               "task, issue #4897); the verdict names it by its code. One whose "
                                               "agent never came up or went down answers NOT-STARTED / DROPPED at "
                                               "once (exit 1) with a hint that restarts it on the same record."),
            "timeout": {"type": "integer", "minimum": 1, "maximum": AWAIT_MAX_S,
                        "description": "Seconds to wait before answering TIMEOUT (default %d, at most %d)."
                                       % (AWAIT_DEFAULT_S, AWAIT_MAX_S)}},
            "additionalProperties": False}}),
    "task": (tool_task, {
        "description": "派 — dispatch a piece of work RECORD FIRST (issue #3330, bin/fleet-task-record.sh "
                       "dispatch): the hub writes the task record and the answer names it by ONE code, `id` "
                       "(K3F9 — the first stdout line; send / get take it); with repo — a "
                       "development task — the record is its ticket, no issue (issue #4897): + spawn, its "
                       "session opens in a worktree of that repo bound to the task, reads the record, opens its "
                       "PR, merges it on a green gate and summarizes the result; without repo + "
                       "spawn a no-repo session is opened with the words. No hub here: exit 3, nothing made "
                       "(issue #4898). The old T<n> rides only as `alias` (one more version).",
        "inputSchema": {"type": "object", "properties": {
            "title": {"type": "string", "description": "The task in one line (the person's words)."},
            "body": {"type": "string", "description": "The rest of the words (the issue body / the session's "
                                                      "first message)."},
            "repo": REPO,
            "spawn": {"type": "boolean", "description": "Start its session now."},
            "reap": dict(REAP_POLICY, description="When the fleet may close a no-repo session on its own."),
            "coding_agent": {"type": "string", "enum": ["claude", "codex"], "description": "CLI provider; independent of the agent definition."},
            "agent": {"type": "string", "pattern": "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$",
                      "description": "The agent file a no-repo session starts as (issue #3122)."},
},
            "required": ["title"], "additionalProperties": False}}),
    "send": (tool_send, {
        "description": "Send text to a live fleet peer as its next turn (bin/fleet-peer-send.sh). "
                       "to is issue:<N> (in a fleet of several repos: narrowed by repo, else your own "
                       "window's repo), <slug>:issue-<N>, scratch-<N>, agent:<name> (the session started "
                       "from that agent file; no matching session is a refusal), "
                       "K3F9 / #k3f9 (a window by its ID's short code — bare in capitals, any case after #; the old T-<code> "
                       "for one version), "
                       "fid:<uuid> (a session by its identity — one with no issue). Parent addressing is retired.",
        "inputSchema": {"type": "object", "properties": {"to": {"type": "string"}, "text": {"type": "string"},
                                                         "repo": REPO},
                        "required": ["to", "text"], "additionalProperties": False}}),
    "report": (tool_report, {
        "description": "RETIRED compatibility entry. Saves only the caller session result; no Parent delivery or queue. A merged result still requires PR evidence.",
        "inputSchema": {"type": "object", "properties": {
            "state": {"type": "string", "enum": ["merged", "blocked", "failed", "stopped", "waiting"],
                      "description": "Workflow status; failed alone is progress, not terminal failure."},
            "outcome": {"type": "string", "enum": ["succeeded", "failed"],
                        "description": "Explicit final work result for an accepted task, including no-PR tasks. Needs summary; does not stop its native session."},
            "pr": {"type": "integer", "minimum": 1, "description": "The PR number (merged / failed)."},
            "summary": {"type": "string", "description": "1-3 lines. Line 1 (≤120 chars): result · PR · what the person must do · where the screenshots / evidence are; detail after. The envelope keeps ≤200 chars a line and points at the full text."},
            "dry_run": {"type": "boolean", "description": "Print the target and the envelope; send nothing."}},
            "required": ["state"], "additionalProperties": False}}),
    "ask": (tool_ask, {
        "description": "问 — you are blocked on the operator: a question only they can answer, or an "
                       "authorization you cannot grant yourself. Puts the question on this window's hub task "
                       "record (「问过你」, bin/fleet-task-record.sh — issue #3330) and turns this window red on "
                       "the dash (set-claude-state.sh blocked) until the next prompt arrives; no GitHub comment "
                       "is written (issue #4898). The answer comes back as "
                       "your next turn, by the existing channels. The question stays on this Task and waits "
                       "for the person. Then "
                       "end your turn — do not spin. suggest / default / due are written under the question as "
                       "hints; nobody answers at a deadline by itself (EPIC #4333).",
        "inputSchema": {"type": "object", "properties": {
            "question": {"type": "string", "description": "What you need, and why you cannot go on without it."},
            "kind": {"type": "string", "enum": ["question", "permission"],
                     "description": "question (default) or permission (an authorization you need)."},
            "suggest": {"type": "string", "description": "What you would decide, and why."},
            "default": {"type": "string",
                        "description": "A hint: what you would do if nobody answers (nothing does it by itself)."},
            "due": {"type": "string",
                    "description": "A hint: by when you need the answer (written as given; nothing fires at it)."},
            "class": {"type": "string", "enum": ["normal", "never:rule", "never:money", "never:publish"],
                      "description": "Accepted for old callers and unused: nothing is decided by default any more."},
            "issue": dict(ISSUE, description="Accepted for old callers and unused (issue #4898).")},
            "required": ["question"], "additionalProperties": False}}),
    "clear": (tool_clear, {
        "description": "清 — run /clear in ANOTHER session, by its ID (bin/fleet-clear-send.sh, T592; the same as "
                       "`fleet-id.sh clear`): only a session on THIS machine whose turn is over (done / idle — "
                       "never working, a dialog open, a loop pending), never over a person typing there; through "
                       "the mod's command inbox, else keystrokes (Claude and Codex alike); confirmed by a new "
                       "native segment on the ID's ledger; one audit line in logs/clear-send.log. Exit 0 cleared "
                       "· 1 no such ID / not on this machine · 2 ambiguous · 3 refused, not idle (nothing typed) "
                       "· 4 sent, unconfirmed (never typed twice) · 5 a person is typing there.",
        "inputSchema": {"type": "object", "properties": {
            "id": {"type": "string", "pattern": "^#?[A-Za-z0-9-]{4,40}$",
                   "description": "The session's ID: the full ID or its short code K3F9 (any case; the old T-<code> for one version)."},
            "timeout": {"type": "integer", "minimum": 1, "maximum": 120,
                        "description": "Seconds to wait for the new segment (default 30)."}},
            "required": ["id"], "additionalProperties": False}}),
    "answer_dialog": (tool_answer_dialog, {
        "description": "答 — answer another session's open choice dialog (AskUserQuestion) for its person, through "
                       "the one guarded road (bin/fleet-dialog-answer.sh; issue #2958): only a window waiting on "
                       "a dialog (needs/ask), only the dialog whose fingerprint you read (fp, from "
                       "`fleet_needs_detail.py dialog <transcript>`), only its own labels verbatim — "
                       "never a free-text answer, never over a person typing there, pressed once and confirmed in "
                       "the transcript, the trail left in the answer log (代答记录) and on the batch's issue. Exit 0 answered "
                       "· 3 refused, nothing sent (changed / answered / not waiting) · 4 pressed but unconfirmed "
                       "(left for a person, never pressed again) · 5 a person is typing there.",
        "inputSchema": {"type": "object", "properties": {
            "window": {"type": "string", "pattern": "^[@%][0-9]+$",
                       "description": "The window (@<id>) or pane (%<id>) holding the dialog."},
            "fp": {"type": "string", "pattern": "^[0-9a-f]{16}$", "description": "The dialog's fingerprint."},
            "picks": {"type": "array", "minItems": 1, "items": {"type": "string"},
                      "description": "One option label per question, verbatim; N=<label> when it has several "
                                     "questions; several labels for one multiSelect question."},
            "by": {"type": "string", "enum": ["person", "session", "default"],
                   "description": "Whose answer this is (default person): session = a session answering on "
                                  "the charter's word."},
            "basis": {"type": "string", "description": "Why: the charter's rule, the sheet, the deadline."},
            "issue": {"type": "string", "pattern": "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$",
                      "description": "Where the trail goes (default: the window's @epic, else its issue)."}},
            "required": ["window", "fp", "picks"], "additionalProperties": False}}),
    "handoff": (tool_handoff, {
        "description": "记 — where a file handoff goes and which one a pickup resumes (bin/fleet-handoff-file.sh). "
                       "path: the file to write (slug optional); find: the one to resume (exit 1 none, 4 "
                       "ambiguous — candidates listed, ask); repo: the doc's Repo: line; check: is the composed "
                       "doc short enough to hand on (exit 3 = findings, advice only); arm: start the detached "
                       "clear+resume helper (bin/fleet-handoff-cycle.sh) for a stored handoff — the LAST tool call "
                       "of the turn.",
        "inputSchema": {"type": "object", "properties": {
            "action": {"type": "string", "enum": ["path", "find", "repo", "check", "arm"]},
            "slug": {"type": "string", "description": "A short name for the handoff file (path)."},
            "doc": {"type": "string", "description": "check: the composed handoff text. arm: the stored doc's PATH "
                                                     "(file storage)."},
            "issue": dict(ISSUE, description="check: compare the doc against this issue's body. arm: the issue the "
                                             "marked handoff comment is on (comment storage)."),
            "repo": dict(REPO, description="arm with issue: the issue's repo (owner/name, hosted by this fleet).")},
            "required": ["action"], "additionalProperties": False}}),
    "pr_verdict": (tool_pr_verdict, {
        "description": "合 — the ONE merge-gate read (bin/fleet-pr-verdict.sh): READY (exit 0) · PENDING · BEHIND · "
                       "FAILING · CONFLICT · BLOCKED · DRAFT · MERGED · CLOSED (exit 1), 2 error. wait blocks "
                       "while PENDING and answers the first settled verdict; TIMEOUT (exit 3) is undetermined, "
                       "never red — call again.",
        "inputSchema": {"type": "object", "properties": {
            "pr": PR_NUM,
            "repo": REPO,
            "wait": {"type": "boolean", "description": "Block while the verdict is PENDING."},
            "until_merged": {"type": "boolean", "description": "With wait: READY with auto-merge armed keeps "
                                                               "waiting until MERGED."},
            "timeout": {"type": "integer", "minimum": 1, "maximum": AWAIT_MAX_S,
                        "description": "With wait: seconds before TIMEOUT (default %d, at most %d)."
                                       % (AWAIT_DEFAULT_S, AWAIT_MAX_S)}},
            "additionalProperties": False}}),
    "pr_merge": (tool_pr_merge, {
        "description": "合 — merge a READY PR with this fleet's method, branch deleted, then confirm "
                       "(bin/fleet-pr-merge.sh): MERGED exit 0; anything not READY is printed and refused (exit "
                       "1) — it never merges red. Falls back to REST when GraphQL is rate-limited.",
        "inputSchema": {"type": "object", "properties": {
            "pr": PR_NUM, "repo": REPO},
            "additionalProperties": False}}),
    "brief": (tool_brief, {
        "description": "The one opening read (issues #1811, #4898). kind task (default): bin/fleet-brief.sh — "
                       "fleet, repo, base, merge method, origin, this window's hub task record (or the issue "
                       "number it was opened on), the flow and the directive. Exit 0 go · 2 not in a fleet · 4 "
                       "nothing bound · 5 the record could not be read. kind resume: bin/fleet-compact-resume.sh "
                       "--brief — the recovery map after an in-place compaction.",
        "inputSchema": {"type": "object", "properties": {
            "kind": {"type": "string", "enum": ["task", "claim", "resume"],
                     "description": "task (default; claim is its old name) or resume."},
            "issue": dict(ISSUE, description="Accepted for old callers and unused (issue #4898)."),
            "repo": REPO,
            "no_comments": {"type": "boolean", "description": "Accepted for old callers and unused."}},
            "additionalProperties": False}}),
    "context": (tool_context, {
        "description": "How full is THIS session's context window (bin/fleet-context.sh): the percentage and "
                       "context bands — OK · WATCH · HANDOFF. With auto_handoff_pct=0 (default), bands are "
                       "advisory: native Agent compaction owns context; do not automatically hand off. "
                       "Exit 0 OK · 1 any other verdict · 2 nothing to read.",
        "inputSchema": {"type": "object", "properties": {
            "json": {"type": "boolean", "description": "The machine-readable form."}},
            "additionalProperties": False}}),
    "transfer": (tool_transfer, {
        "description": "Hand THIS session's task to the named coding agent in the same pane and worktree "
                       "(bin/fleet-transfer.sh). check: resolve the exact source (--dry-run), refused = stop. "
                       "arm: the LAST tool call of the turn, with the private handoff note's path — the switch "
                       "happens after the turn ends; it prints the request directory. export_loop: write an "
                       "active ScheduleWakeup loop as the private JSON arm's loop takes (bin/fleet-loop.py "
                       "from-claude).",
        "inputSchema": {"type": "object", "properties": {
            "action": {"type": "string", "enum": ["check", "arm", "export_loop"]},
            "to": {"type": "string", "enum": ["claude", "codex"]},
            "handoff": {"type": "string", "description": "arm: path of the private handoff note."},
            "loop": {"type": "string", "description": "arm: path of the private loop JSON (optional)."},
            "transcript": {"type": "string", "description": "export_loop: the exact source transcript."},
            "output": {"type": "string", "description": "export_loop: where to write the loop JSON."}},
            "required": ["action"], "additionalProperties": False}}),
    "where": (tool_where, {
        "description": "Read-only. Where the operator is right now — device, system, terminal and what it can do "
                       "(open a page, take a file, a link only) — bin/fleet-client-where.sh. The one reader; "
                       "never guess a terminal. Exit 0 a client named · 3 nobody connected · 1 could not tell.",
        "inputSchema": {"type": "object", "properties": {
            "json": {"type": "boolean", "description": "The machine-readable form."}},
            "additionalProperties": False}}),
    "show": (tool_show, {
        "description": "Show a file (image, PDF, QR code, screenshot) on the OPERATOR's computer, never this "
                       "machine's screen (bin/fleet-show.sh) — one receipt line per file: saved:<path> (exit 0: "
                       "their side saved it there — tell them where) · unconfirmed (exit 0: handed over, no answer) "
                       "· failed:<why> (exit 4); PATH + failed: (exit 2) not sent — tell them the path. inline "
                       "draws it and holds the screen until they press a key.",
        "inputSchema": {"type": "object", "properties": {
            "file": {"type": "string", "description": "Path of the file."},
            "inline": {"type": "boolean", "description": "Draw it in the terminal instead of a download."}},
            "required": ["file"], "additionalProperties": False}}),
    "open": (tool_open, {
        "description": "Open a URL, a page served here (:port[/path], localhost) or a file in the OPERATOR's own "
                       "browser over their SSH connection (bin/fleet-open.sh) — never `open` on this machine. "
                       "Waits for the far side's receipt and prints opened (exit 0), unconfirmed (exit 0: handed "
                       "over, no receipt — stderr gives the link) or failed:<why> (exit 4; exit 2 for a file "
                       "it could not send — say the path).",
        "inputSchema": {"type": "object", "properties": {
            "target": {"type": "string", "description": "A URL, :port[/path], or a file path."}},
            "required": ["target"], "additionalProperties": False}}),
}


# Two groups (issue #3113). TOOLS stays every handler: `fleet` answers all of them
# (a dispatch-group call it does not list is logged road=legacy) but LISTS only
# CORE; `fleet-orch` lists and answers ORCH.
ORCH_SERVER = "fleet-orch"
ORCH_GROUP = ("spawn", "await", "children", "answer_dialog", "send", "task", "clear")
CORE = {n: e for n, e in TOOLS.items() if n not in ORCH_GROUP}
ORCH = {n: TOOLS[n] for n in ORCH_GROUP}
# What `fleet` lists: CORE, unless this process took over (#1898) from a server of a
# version before the groups — its session met the full list and Claude Code re-lists
# on the takeover's tools/list_changed, so it keeps the full list (#2068).
SERVING = {"list_all": False}


RETIRED_TOOLS = {"await", "children", "report"}


def listing(table, served=False):
    """What a server lists. `fleet` served to a session that has no `fleet-orch` beside
    it (FLEET_MCP_ORCH is not 1 — one launched before issue #4703, when the group was
    mounted only on @agent_spawn 1) lists the dispatch group too, so that session can
    spawn after the next takeover's tools/list_changed, no reopen. `--list` stays the
    static core list."""
    if table is TOOLS and not (SERVING["list_all"] or served and os.environ.get("FLEET_MCP_ORCH") != "1"):
        table = CORE
    return {name: item for name, item in table.items() if name not in RETIRED_TOOLS}


def check_args(schema, args):
    """The reason `args` does not fit `schema`, or None when it does."""
    if not isinstance(args, dict):
        return "arguments must be an object"
    props = schema.get("properties", {})
    for key in args:
        if key not in props:
            return 'unknown argument "%s" (takes %s)' % (key, ", ".join(props) if props else "no arguments")
    for key in schema.get("required", []):
        if args.get(key) is None:
            return 'missing required argument "%s"' % key
    for key, p in props.items():
        if key not in args:
            continue
        v = args[key]
        if p["type"] == "integer":
            if not isinstance(v, int) or isinstance(v, bool):
                return '"%s" must be an integer, got %s' % (key, json.dumps(v))
            if "minimum" in p and v < p["minimum"]:
                return '"%s" must be ≥ %d, got %d' % (key, p["minimum"], v)
            if "maximum" in p and v > p["maximum"]:
                return '"%s" must be ≤ %d, got %d' % (key, p["maximum"], v)
        elif p["type"] == "boolean":
            if not isinstance(v, bool):
                return '"%s" must be true or false, got %s' % (key, json.dumps(v))
        elif p["type"] == "string":
            if not isinstance(v, str) or v.strip() == "":
                return '"%s" must be a non-empty string, got %s' % (key, json.dumps(v))
            if "enum" in p and v not in p["enum"]:
                return '"%s" must be one of %s, got %s' % (key, " · ".join(p["enum"]), json.dumps(v))
            if "pattern" in p and not re.match(p["pattern"], v):
                return '"%s" must be owner/name, got %s' % (key, json.dumps(v))
    return None


def report(data):
    """A script run, as the model reads it: exit code, stdout, stderr."""
    if not isinstance(data, dict) or "exit" not in data or "command" not in data:
        return json.dumps(data, ensure_ascii=False, sort_keys=True)
    parts = ["exit %s · %s" % (data["exit"], data["command"])]
    if (data.get("stdout") or "").strip():
        parts.append(data["stdout"].rstrip())
    if (data.get("stderr") or "").strip():
        parts.append("[stderr]\n" + data["stderr"].rstrip())
    return "\n".join(parts)


def ask_text(data):
    return report(data) + "\n\n" + report(data["state"])


def status_text(data):
    head = "window: " + (data["window"] or "(not in tmux)")
    ident = data.get("identity") or {}
    head += "\nidentity: " + ("%s (credential, expires %s)" % (ident["worker_id"], ident["expires"])
                              if ident.get("worker_id") else "(no credential — known by the window's options)")
    return "\n\n".join([head, report(data["children"]), data["repo_list"]])


def tool_result(name, data, error=False):
    if error:
        return {"content": [{"type": "text", "text": data}], "isError": True}
    text = status_text(data) if name == "status" else ask_text(data) if name == "ask" else report(data)
    # A complete short create receipt survives the conversation viewer's 160
    # character tool preview. The full result remains available to the agent.
    if name == "schedule" and isinstance(data, dict) and data.get("action") == "create":
        sid = data.get("schedule", {}).get("spec", {}).get("id")
        if isinstance(sid, str) and re.fullmatch(r"schedule-[a-zA-Z0-9-]+", sid):
            text = json.dumps({"action": "create", "schedule_id": sid}, separators=(",", ":")) + "\n" + text
    return {"content": [{"type": "text", "text": text}], "structuredContent": data}


def tool_call(table, name, args):
    SIGNED["assert"] = False
    ROAD["legacy"] = (table is TOOLS and not ROAD["call"] and name in ORCH_GROUP
                     and name not in listing(table, served=True))
    entry = table.get(name)
    if entry is None:
        log_call(str(name), None, "refused", "unknown tool")
        return tool_result(name, "%s.%s: unknown tool. Nothing ran." % (SERVER, name), error=True)
    fn, spec = entry
    # Identity first (issue #1809): a credential that does not hold — or a pane that
    # is not its session's — refuses every tool, read-only ones included.
    try:
        claims = identify()
    except ToolFault as exc:
        log_call(name, None, "refused", exc.message, via="badcred")
        return tool_result(name, "%s.%s: %s. Nothing ran." % (SERVER, name, exc.message), error=True)
    CALLER["claims"] = claims
    bad = check_args(spec["inputSchema"], args if args is not None else {})
    if bad is not None:
        log_call(name, claims, "refused", bad)
        return tool_result(name, "%s.%s: %s. Nothing ran." % (SERVER, name, bad), error=True)
    try:
        data = fn(args or {})
    except Refused as exc:
        log_call(name, claims, "refused", exc.message)
        return tool_result(name, "%s.%s: %s. Nothing ran." % (SERVER, name, exc.message), error=True)
    except ToolFault as exc:
        log_call(name, claims, "fault", exc.message)
        return tool_result(name, "%s.%s: %s" % (SERVER, name, exc.message), error=True)
    log_call(name, claims, "ok" if not isinstance(data, dict) or "exit" not in data else "exit=%s" % data["exit"])
    return tool_result(name, data)


OUT_LOCK = threading.Lock()   # one writer at a time: a gateway reopen notifies from a thread (T716)


def emit(msg):
    with OUT_LOCK:
        print(json.dumps(msg, separators=(",", ":"), ensure_ascii=False), flush=True)


def respond(request, result=None, error=None):
    if "id" not in request:
        return
    msg = {"jsonrpc": "2.0", "id": request["id"]}
    if error:
        msg["error"] = error
    else:
        msg["result"] = result
    emit(msg)


# The MCP servers a session opens when it needs them (T716 F, bin/fleet_mcp_gateway.py):
# the core server serves mcp_list / mcp_enable / mcp_disable and every opened
# server's tools as <server>__<tool>. FLEET_MCP_GATEWAY=0 serves none of it.
GATEWAY = {"gw": None}


def gateway(table):
    if table is not TOOLS or os.environ.get("FLEET_MCP_GATEWAY", "1") == "0":
        return None
    if GATEWAY["gw"] is None:
        try:
            sys.path.insert(0, str(BIN))
            import fleet_mcp_gateway
        except ImportError:
            return None
        GATEWAY["gw"] = fleet_mcp_gateway.Gateway(
            notify=lambda method: emit({"jsonrpc": "2.0", "method": method}))
    return GATEWAY["gw"]


def handle(request, table, name):
    method = request.get("method")
    if method == "initialize":
        RELOAD["ready"] = True
        asked = (request.get("params") or {}).get("protocolVersion")
        return {"protocolVersion": asked if isinstance(asked, str) and asked else "2024-11-05",
                "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": {"name": name, "version": VERSION}}
    if method == "tools/list":
        gw = gateway(table)
        return {"tools": [{"name": n, **spec} for n, (_, spec) in listing(table, served=True).items()]
                + (gw.tools() if gw else [])}
    if method == "tools/call":
        params = request.get("params") or {}
        gw = gateway(table)
        if gw and params.get("name") not in table and gw.owns(params.get("name") or ""):
            return gw.call(params.get("name"), params.get("arguments"))
        return tool_call(table, params.get("name"), params.get("arguments"))
    if method == "ping":
        return {}
    if isinstance(method, str) and method.startswith("notifications/") or method == "$/cancelRequest":
        return None
    raise ToolFault("unsupported MCP method: " + str(method))


# --- a new version, taken between calls (issue #1898, EPIC #1906 C5) -------------
#
# The install is a LINK to one version (#1894): ~/.claude/fleet → fleet.versions/<sha>/.
# Before each request — and every RELOAD_POLL_S while the client is quiet — the server
# compares the file it was launched as (the link path, never resolved) with the one it
# is running: another real path, inode, size or mtime means a new version. Requests are
# served one at a time, so "between calls" is simply here: a call in flight finishes on
# the old code first. The new file must answer `--probe` (it lists its tools) before the
# server os.execv's it — same pid, same stdin/stdout, so the MCP connection never drops;
# the credential rides in the environment as it is (renewed in place, #1809). Request
# bytes already read but not served go to the new process through a 0600 carry file.
# The new process then sends notifications/tools/list_changed: Claude Code re-lists at
# once (it does so only because initialize declared tools.listChanged — a session that
# met an older server keeps its list until it is reopened); Codex only logs the
# notification today, so a Codex session keeps its first tool list and the C4 notice +
# C3 idle reopen cover it — the exec still moves its tools' scripts onto the new version.
# FLEET_MCP_RELOAD=0 turns all of this off.

RELOAD_ENV = "FLEET_MCP_EXEC"          # old → new process handover (never inherited further)
RELOAD_POLL_S = float(os.environ.get("FLEET_MCP_RELOAD_POLL_S") or 30)
PROBE_TIMEOUT_S = 20
RELEASE_DIR_RE = re.compile(r"[0-9a-f]{7,64}")


def follow_link(path):
    """The version link a release's own copy of this file is reached through (T598).

    A server launched by its RELEASE path (<root>/<sha>/bin/fleet-mcp.py — a window
    a tool call spawned inherits the resolved path of its parent's server) never saw
    its file change, so it kept that release's tools and scripts for its whole life:
    a driver opened between two releases dispatched through a half-switched road
    (EPIC T497 C19). Such a path is watched through the link that names the live
    release instead — <root>/current (a managed machine) or ~/.claude/fleet beside
    fleet.versions/ (#1894) — a path through that link already maps to the same link.
    Not a release's tree, or no such link beside it: as is.
    """
    real = os.path.realpath(path)
    bindir = os.path.dirname(real)
    ver = os.path.dirname(bindir)
    root = os.path.dirname(ver)
    if os.path.basename(bindir) != "bin" or not RELEASE_DIR_RE.fullmatch(os.path.basename(ver)):
        return path
    links = [os.path.join(root, "current")]
    if os.path.basename(root) == "fleet.versions":
        links.append(os.path.join(os.path.dirname(root), "fleet"))
    for link in links:
        cand = os.path.join(link, "bin", os.path.basename(real))
        if os.path.islink(link) and os.path.isfile(cand):
            return cand
    return path


SELF = follow_link(os.path.abspath(__file__))   # the path watched: through the version link
RELOAD = {"ready": False, "sig": None, "bad": None}


def file_sig(path):
    """A file's version: its real path + the file's identity."""
    try:
        real = os.path.realpath(path)
        st = os.stat(real)
    except OSError:
        return None
    return "%s:%d:%d:%d" % (real, st.st_ino, st.st_size, st.st_mtime_ns)


def self_sig():
    """What version SELF is right now."""
    return file_sig(SELF)


def reload_log(verdict, why):
    line = "%s tool=(reload) via=- who=pid%d verdict=%s why=%s\n" % (
        time.strftime("%Y-%m-%dT%H:%M:%S%z"), os.getpid(), verdict, json.dumps(why, ensure_ascii=False))
    try:
        log_path().parent.mkdir(parents=True, exist_ok=True)
        with open(str(log_path()), "a") as fh:
            fh.write(line)
    except OSError:
        pass


def reload_due():
    """The new version's signature when one is in place and passes its probe, else None."""
    if os.environ.get("FLEET_MCP_RELOAD", "1") == "0" or not RELOAD["ready"] or RELOAD["sig"] is None:
        return None
    sig = self_sig()
    if sig is None or sig == RELOAD["sig"] or sig == RELOAD["bad"]:
        return None
    try:
        probe = subprocess.run([sys.executable, SELF, "--probe"], stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=PROBE_TIMEOUT_S)
        ok = probe.returncode == 0 and isinstance(json.loads(probe.stdout).get("tools"), list)
        why = "" if ok else (probe.stderr or probe.stdout or "exit %d" % probe.returncode).strip()[-300:]
    except (OSError, ValueError, AttributeError, subprocess.TimeoutExpired) as exc:
        ok, why = False, str(exc) or type(exc).__name__
    if not ok:
        RELOAD["bad"] = sig
        reload_log("refused", "new version failed its probe, staying on this one: " + why)
        return None
    return sig


def reload_exec(sig, carry):
    """Become the new version: same pid, same stdin/stdout. Returns only on failure."""
    import tempfile
    state = {"from": RELOAD["sig"], "to": sig, "list": "all" if SERVING["list_all"] else "group",
             "mcp": GATEWAY["gw"].names() if GATEWAY["gw"] else []}
    if carry:
        fd, path = tempfile.mkstemp(prefix="fleet-mcp-carry.")
        with os.fdopen(fd, "wb") as fh:
            fh.write(carry)
        state["carry"] = path
    os.environ[RELOAD_ENV] = json.dumps(state)
    sys.stdout.flush()
    if GATEWAY["gw"]:
        GATEWAY["gw"].close()   # the new process opens the same ones again (state "mcp")
    reload_log("exec", "%s -> %s" % (RELOAD["sig"], sig))
    try:
        os.execv(sys.executable, [sys.executable, SELF] + sys.argv[1:])   # --group rides along
    except OSError as exc:
        os.environ.pop(RELOAD_ENV, None)
        if state.get("carry"):
            os.unlink(state["carry"])
        RELOAD["bad"] = sig
        reload_log("refused", "exec failed, staying on this one: %s" % exc)


def reload_resume():
    """In the new process: take the handover, hand back the unserved bytes, tell the client."""
    raw = os.environ.pop(RELOAD_ENV, None)
    if not raw:
        return b""
    carry = b""
    try:
        state = json.loads(raw)
        if state.get("carry"):
            with open(state["carry"], "rb") as fh:
                carry = fh.read()
            os.unlink(state["carry"])
    except (OSError, ValueError, AttributeError):
        state = {}
    # No "list" in the handover = the old process predates the groups (issue #3113):
    # its session was handed every tool, so it keeps them.
    SERVING["list_all"] = (state.get("list") if isinstance(state, dict) else None) != "group"
    if isinstance(state, dict) and state.get("mcp"):
        GATEWAY["reopen"] = state["mcp"]
    RELOAD["ready"] = True
    print(json.dumps({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"},
                     separators=(",", ":")), flush=True)
    reload_log("resumed", "now %s" % RELOAD["sig"])
    return carry


def read_lines(buf, watch):
    """Lines off fd 0, unbuffered by Python (an exec must not lose what it read ahead).
    Yields (line, rest-of-buffer); with `watch`, yields (None, buf) after each quiet
    RELOAD_POLL_S so the caller can look for a new version while nothing is asked."""
    import select
    while True:
        while b"\n" not in buf:
            if watch:
                ready, _, _ = select.select([0], [], [], RELOAD_POLL_S)
                if not ready:
                    yield None, buf
                    continue
            chunk = os.read(0, 65536)
            if not chunk:
                if buf.strip():
                    yield buf, b""
                return
            buf += chunk
        line, buf = buf.split(b"\n", 1)
        yield line, buf


def serve(table, name):
    # The credential this session was launched with (issue #1809): taken once, renewed
    # in memory while it holds — the environment never hands the server a new one.
    HELD["cred"] = os.environ.get(CRED_ENV) or None
    if HELD["cred"]:
        threading.Thread(target=renew_loop, daemon=True).start()
    watch = table is TOOLS or table is ORCH
    # the version RUNNING, not the one SELF names now: a server launched by an older
    # release's own path takes the live one at its first request (T598)
    RELOAD["sig"] = file_sig(os.path.abspath(__file__)) if watch else None
    buf = reload_resume() if watch else b""
    # the servers this session had opened (T716): carried by a reload-exec, else
    # remembered for its window across a relaunch of the same conversation —
    # opened off the request loop, the client told when they are up
    gw = gateway(table)
    if gw is not None:
        names = GATEWAY.get("reopen")
        if names is None:
            import fleet_mcp_gateway
            names = fleet_mcp_gateway.remembered()
        if names:
            threading.Thread(target=gw.reopen, args=(names,), daemon=True).start()
    for raw, rest in read_lines(buf, watch):
        if watch:
            sig = reload_due()
            if sig is not None:
                reload_exec(sig, rest if raw is None else raw + b"\n" + rest)
        if raw is None:
            continue
        line = raw.decode("utf-8", "replace")
        if not line.strip():
            continue
        request = {}
        try:
            request = json.loads(line)
            result = handle(request, table, name)
            if result is not None:
                respond(request, result=result)
        except ToolFault as exc:
            respond(request, error={"code": -32601, "message": exc.message})
        except Exception as exc:
            respond(request, error={"code": -32603, "message": str(exc)})


def toml_str(value):
    return json.dumps(value, ensure_ascii=False)   # a JSON string is a TOML basic string


def mount_codex(group="core"):
    """The `-c` value that mounts this server in Codex: what conf/mcp-worker.json
    (the dispatch group: conf/mcp-orch.json) says, plus the env Codex would otherwise
    withhold and a per-call timeout an await fits in."""
    name, fname = (ORCH_SERVER, "mcp-orch.json") if group == "orch" else (SERVER, "mcp-worker.json")
    conf = json.loads((BIN.parent / "conf" / fname).read_text())
    srv = conf["mcpServers"][name]
    fields = ["command=" + toml_str(srv["command"]),
              "args=[" + ",".join(toml_str(a) for a in srv.get("args", [])) + "]",
              "env_vars=[" + ",".join(toml_str(v) for v in CODEX_ENV) + "]",
              "tool_timeout_sec=%d" % CODEX_TOOL_TIMEOUT_S]
    return "mcp_servers.%s={%s}" % (name, ",".join(fields))


def call_main(name, raw):
    """One tool call from a command line (the mod's fallback road, issue #2057).
    Exactly tool_call: the credential from the environment (one shot — no renewal),
    identity, check_args, the script, the call log (road=call). The result text goes
    to stdout as the model would read it; exit 0 answered, 1 isError, 2 usage."""
    try:
        args = json.loads(raw) if raw.strip() else {}
    except ValueError as exc:
        print("fleet-mcp: --call %s: arguments are not JSON (%s)" % (name, exc), file=sys.stderr)
        return 2
    if not isinstance(args, dict):
        print("fleet-mcp: --call %s: arguments must be a JSON object" % name, file=sys.stderr)
        return 2
    HELD["cred"] = os.environ.get(CRED_ENV) or None
    ROAD["call"] = True
    result = tool_call(TOOLS, name, args)
    text = "".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
    print(text)
    return 1 if result.get("isError") else 0


def spec_main(names):
    """The named tools' {name, description, inputSchema}, as tools/list carries them —
    what the mod registers its fallback tools from, so a schema lives once."""
    unknown = [n for n in names if n not in TOOLS]
    if not names or unknown:
        print("fleet-mcp: --spec: unknown tool%s %s" % ("s" if len(unknown) != 1 else "", ", ".join(unknown))
              if unknown else "usage: fleet-mcp.py --spec <tool>…", file=sys.stderr)
        return 2
    print(json.dumps([{"name": n, **TOOLS[n][1]} for n in names], ensure_ascii=False))
    return 0


def main(argv):
    group = "core"
    if "--group" in argv:
        i = argv.index("--group")
        group = argv[i + 1] if i + 1 < len(argv) else ""
        if group not in ("core", "orch"):
            print("fleet-mcp: --group core|orch, got %r" % group, file=sys.stderr)
            return 2
        argv = argv[:i] + argv[i + 2:]
    table, name = (ORCH, ORCH_SERVER) if group == "orch" else (TOOLS, SERVER)
    if argv[:2] == ["--mount", "codex"]:
        print(mount_codex(group))
        return 0
    if argv == ["--list"]:
        print("\n".join(listing(table)))
        return 0
    if argv[:1] == ["--bridge-seat"] and len(argv) <= 2:   # a role name is ignored (issue #3118)
        return 0 if bridge_seat() else 1
    if argv[:1] == ["--spec"]:
        return spec_main(argv[1:])
    if argv[:1] == ["--call"] and len(argv) in (2, 3):
        return call_main(argv[1], argv[2] if len(argv) == 3 else "")
    if argv[:1] == ["--cred"] and len(argv) == 2:
        return cred_main(argv[1])
    if argv[:1] == ["--probe"]:
        # A new version proves it starts before a running server execs it (#1898).
        print(json.dumps({"tools": sorted(TOOLS)}))
        return 0
    if argv:
        print("usage: fleet-mcp.py [--group core|orch] [--list | --mount codex] | --probe | "
              "--spec <tool>… | --call <tool> [<json args>] | --bridge-seat | "
              "--cred mint|check|revoke|assert", file=sys.stderr)
        return 2
    serve(table, name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
