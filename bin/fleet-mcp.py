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
  ask       question [+ kind]       → bin/fleet-comment.sh + set-claude-state.sh blocked  (问)
  comment   issue + body [+ mode]   → bin/fleet-comment.sh              (记)
  evidence  action [+ file|text|pane, note] → bin/fleet-evidence.sh     (记)
  handoff   action [+ slug|doc]     → bin/fleet-handoff-file.sh         (记)
  pr_verdict pr [+ repo, wait]      → bin/fleet-pr-verdict.sh           (合)
  pr_merge  pr [+ repo]             → bin/fleet-pr-merge.sh             (合)
  brief     [kind, issue, repo]     → bin/fleet-claim-brief.sh | fleet-compact-resume.sh --brief  (issue #1811)
  file_issue title [+ body, parent, spawn|bind, …] → bin/fleet-issue-file.sh
  gh        kind + number [+ fields, max_age, repo] → bin/fleet-gh.sh
  context   [json]                  → bin/fleet-context.sh
  transfer  action [+ to, handoff, loop, …] → bin/fleet-transfer.sh | fleet-loop.py from-claude
  where / show / open               → bin/fleet-client-where.sh / fleet-show.sh / fleet-open.sh

docs/FLEET-MCP.md is the one spec; later EPIC members add tools there and here.

The rule (EPIC #1813 decision 4, the one the retired mod tools kept): a tool only
CHECKS its arguments — an unknown or missing argument, a wrong type, a repo this
fleet does not host is refused with the reason and NOTHING runs — then runs the
existing script unchanged and hands back its exit code, stdout and stderr as they
came. Caps, claim dedup and guards live in the scripts, once.

  fleet-mcp.py                 serve on stdin/stdout
  fleet-mcp.py --mount codex   print the `-c` value bin/fleet-codex.sh mounts it with
  fleet-mcp.py --legacy-peer   the old fleet-peer server (list_agents/send_message)
  fleet-mcp.py --cred mint     print a fresh worker credential for THIS pane (stdout only)
  fleet-mcp.py --cred check    verify $FLEET_WORKER_CRED; print its claims (never the credential)
  fleet-mcp.py --cred revoke   revoke $FLEET_WORKER_CRED (its nonce goes on the revoked list)
  fleet-mcp.py --probe         list the tools and exit — a running server asks a new version this
                               before it execs it (issue #1898: a new version, taken between calls)

The worker credential (issue #1809, EPIC #1813 C7): bin/fleet-session-wrap.sh mints
one per launch and hands it to the agent — and so to this server — ONLY through the
environment ($FLEET_WORKER_CRED); every tool call verifies it first and then acts as
the session it names, refusing what is outside that session's scope. A call without
one (a person in a shell, an older session) runs as before, by the window's options,
and the call log says so. docs/FLEET-MCP.md «Identity» is the spec.

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
MERGE_TIMEOUT_S = 180      # gate + merge + confirm
VERDICT_TIMEOUT_S = 60     # the one-shot read
BRIEF_TIMEOUT_S = 90       # one gh read of the issue + its comments
FILE_TIMEOUT_S = 180       # gh issue create + sub-issue link + a spawn
SHOW_TIMEOUT_S = 300       # --inline holds the screen until the operator presses a key

# Codex hands an MCP server only a short env allowlist (HOME, PATH, USER, …);
# these are what the scripts need to find the pane, the fleet and the install —
# and the session's credential (issue #1809): forwarded by NAME, never its value.
CODEX_ENV = ["TMUX", "TMUX_PANE", "FLEET_CONF_DIR", "FLEET_SESSION", "FLEET_WORKER_CRED", "FLEET_MCP_BIN"]
# A blocking await outlives Codex's 60s default per-call timeout.
CODEX_TOOL_TIMEOUT_S = AWAIT_MAX_S + AWAIT_SLACK_S + 5


class ToolFault(Exception):
    def __init__(self, message):
        super().__init__(message)
        self.message = message


class Refused(ToolFault):
    """Arguments that do not fit: said with the reason, nothing ran."""


def run(argv, *, input_text=None, check=True, timeout=None, env=None):
    try:
        result = subprocess.run(argv, input=input_text, text=True, capture_output=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        raise ToolFault("%s did not answer within %ss" % (Path(argv[0]).name, timeout))
    except OSError as exc:
        raise ToolFault("%s could not start: %s" % (argv[0], exc))
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
    for a warm-pool window parked in <fleet>-pool and for a view session's client."""
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
        time.sleep(0.2)
        fid = pane_opt("#{@fleet_id}")
    session = current_session()
    if not fid:   # a warm-pool window, a road that does not stamp: mint it now (fleet_window_fid)
        wid = pane_opt("#{window_id}")
        fid = lib("fleet_window_fid " + shquote(session) + " " + shquote(wid)).stdout.strip()
    if not fid:
        raise ToolFault("this window has no @fleet_id and none could be minted")
    row = pane_opt("#{@repo}\t#{@issue}\t#{@origin}").split("\t")
    row += [""] * (3 - len(row))
    now = int(time.time())
    claims = {
        "v": 1, "fleet": fleet_label(), "fid": fid,
        "fleet_uuid": lib("fleet_uuid " + shquote(session) + " 2>/dev/null || true").stdout.strip(),
        "key": origin_key(), "repo": row[0], "issue": row[1], "origin": row[2],
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
    return Path(os.environ.get("FLEET_MCP_LOG") or (BIN.parent / "logs" / "mcp-calls.log"))


# --- the hub route: a worker assertion (issue #1810, EPIC #1813 C8) ---------------
#
# fwa1.<base64url claims JSON>.<base64url HMAC-SHA256>, keyed with HashToken of the
# node's enrollment token (SHA-256 hex — the hub stores exactly that, so it checks
# the signature without a new secret). Minted per call, only for a call whose
# credential held, only when the hub is on for this fleet; handed to the script in
# its environment only. tokenledger/internal/api/fleet_worker_assert.go verifies it.

ASSERT_ENV = "FLEET_WORKER_ASSERT"
ASSERT_PREFIX = "fwa1"
ASSERT_TTL_S = 600              # a placement: the call is happening now
ASSERT_RELAY_TTL_S = 24 * 3600  # a message may wait in the hub outbox while the hub is away
SIGNED = {"assert": False}      # whether the call being served handed one out (the call log says so)


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
        (" why=" + json.dumps(why, ensure_ascii=False)) if why else "")
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


# --- agents / send (moved from fleet-peer-mcp.py, issue #1185) ------------------

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
    (<one_repo>, fleet_window_repo's fallback), and nothing when that is unknown."""
    if row["issue"].isdigit():
        key = "issue-" + row["issue"]
    else:
        key = scratch_key(row["worktree"]) or scratch_key(row["path"])
        if not key:
            return ""
    if no_repo and not row["repo"]:
        return key                      # a fleet hosting no repo: bare is its only spelling
    if row["norepo"] == "1":
        return ""
    repo = row["repo"] or one_repo
    if not repo:
        return ""
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


def list_agents():
    session = current_session()
    me = origin_key()
    parent = origin_option()
    kids = child_keys()
    one = lib("fleet_repos " + shquote(session), check=False).stdout.split()
    one_repo = one[0] if len(one) == 1 else ""
    no_repo = not one
    fmt = "#{window_id}\t#{session_name}\t#{window_name}\t#{@issue}\t#{@cc_agent}\t" \
          "#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}\t#{@claude_needs}\t" \
          "#{@origin}\t#{@repo}\t#{@norepo}\t#{@worktree}\t#{pane_current_path}"
    out = tmux("list-windows", "-a", "-F", fmt)
    agents = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 12 or parts[1] != session or parts[2] in ("dash", "plan", "backlog", "home"):
            continue
        row = dict(zip(("window_id", "session", "window_name", "issue", "agent", "state", "needs",
                        "origin", "repo", "norepo", "worktree", "path"), parts))
        key = window_key(row, one_repo, no_repo)
        state = row["needs"] or row["state"] or "unknown"
        agent = "codex" if row["agent"] == "codex" else "claude"
        agents.append({
            "window_id": row["window_id"],
            "window_name": row["window_name"],
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


def parent_window():
    parent = origin_option()
    if not re.match(r"^([A-Za-z0-9._-]+:)?(issue|scratch)-[0-9]+$", parent or ""):
        raise ToolFault("this session has no live-addressable parent")
    session = current_session()
    # The ONE resolver (fleet_win_for_key, issue #1537): rc 2 = the key is
    # ambiguous (two windows, or a bare issue key in a 2+ repo fleet) — said on
    # stderr; never a pick. A warm-pool window never answers.
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


def send_message(to, text):
    if not isinstance(to, str) or not to.strip():
        raise Refused("to is required")
    if not isinstance(text, str) or not text.strip():
        raise Refused("text is required")
    target = to.strip()
    if target != "parent" and not re.match(
            r"^(issue:[0-9]+|#[0-9]+|issue-[0-9]+|scratch-[0-9]+|[@%][A-Za-z0-9_.:-]+)$", target):
        raise Refused("to must be issue:<N>, scratch-<N> or parent")
    if target == "parent":
        target = parent_window()
    result = run(["bash", str(BIN / "fleet-peer-send.sh"), target, "-"], input_text=text, check=False,
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
                      "lifecycle=#{@worker_lifecycle} origin=#{@origin}"],
                     check=False, timeout=STATUS_TIMEOUT_S).stdout.strip() or None
    kids = script([str(BIN / "fleet-children.sh")], STATUS_TIMEOUT_S)
    repos, listed = hosted_repos()
    claims = CALLER["claims"]
    identity = ({"worker_id": worker_id(claims), "via": "credential",
                 "expires": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(int(claims["exp"])))}
                if claims else {"worker_id": None, "via": "window options (no credential)"})
    return {"window": window, "identity": identity, "children": kids, "repos": repos,
            "repo_list": listed.stdout.rstrip("\n")}


def tool_children(_args):
    return script([str(BIN / "fleet-children.sh"), "--json"], STATUS_TIMEOUT_S)


def tool_repos(_args):
    repos, listed = hosted_repos()
    return {"command": "fleet-repo.sh", "exit": listed.returncode, "repos": repos,
            "stdout": listed.stdout, "stderr": listed.stderr}


def tool_spawn(args):
    repo = check_repo(args)
    reap = ["--reap", args["reap"]] if args.get("reap") else []   # issue #1902
    return script([str(BIN / "dash-issue-session.sh"), str(args["issue"])] + repo + reap, SPAWN_TIMEOUT_S,
                  env=hub_env(ASSERT_TTL_S))


def tool_set_reap(args):
    """When the fleet may close THIS session on its own (issue #1902)."""
    return script([str(BIN / "fleet-reap-policy.sh"), "set", args["policy"]], STATUS_TIMEOUT_S)


def tool_await(args):
    repo = check_repo(args)
    t = args.get("timeout", AWAIT_DEFAULT_S)
    return script([str(BIN / "fleet-await.sh"), str(args["issue"]), "--timeout", str(t)] + repo,
                  t + AWAIT_SLACK_S, env=hub_env(ASSERT_TTL_S))


def tool_agents(_args):
    return list_agents()


def tool_send(args):
    return send_message(args.get("to"), args.get("text"))


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


def tool_report(args):
    argv = [str(BIN / "fleet-report-parent.sh"), "--state", args["state"]]
    if "pr" in args:
        argv += ["--pr", str(args["pr"])]
    if "summary" in args:
        argv += ["--summary", args["summary"]]
    if args.get("dry_run"):
        argv.append("--dry-run")
    return script(argv, WRITE_TIMEOUT_S)


ASK_HEAD = {"question": "⛔ blocked: ", "permission": "⛔ blocked — needs authorization: "}


def tool_ask(args):
    issue = str(args["issue"]) if "issue" in args else pane_issue()
    if not issue:
        raise Refused("this window has no bound issue to ask on — pass issue, or ask in your reply")
    body = ASK_HEAD[args.get("kind", "question")] + args["question"]
    said = stdin_script([str(BIN / "fleet-comment.sh"), issue, "--note", "--body-file", "-"], body,
                        WRITE_TIMEOUT_S)
    # The red stamp goes on whether or not the comment posted: the session IS
    # blocked either way, and a blocker nobody can see is the failure this exists
    # to prevent. stdin pinned shut — `blocked` reads no hook payload.
    red = stdin_script(["sh", str(BIN / "set-claude-state.sh"), "blocked"], "", STATUS_TIMEOUT_S)
    red["command"] = "set-claude-state.sh"
    return dict(said, issue=int(issue), body=body, state=red)


def tool_comment(args):
    argv = [str(BIN / "fleet-comment.sh"), str(args["issue"]),
            "--to-worker" if args.get("mode") == "to-worker" else "--note"]
    if args.get("close"):
        argv.append("--close")
    argv += check_repo(args)
    return stdin_script(argv + ["--body-file", "-"], args["body"], WRITE_TIMEOUT_S)


EVIDENCE_SOURCES = ("file", "text", "pane")


def tool_evidence(args):
    action = args["action"]
    given = [k for k in EVIDENCE_SOURCES if k in args]
    if action in ("before", "after"):
        if len(given) != 1:
            raise Refused("%s takes exactly one of file, text, pane (got %s)"
                          % (action, ", ".join(given) if given else "none"))
    else:
        extra = [k for k in EVIDENCE_SOURCES + ("name", "mv") if k in args]
        if extra:
            raise Refused("%s takes no %s" % (action, ", ".join(extra)))
    if "mv" in args and "file" not in args:
        raise Refused("mv applies to a file only")
    if "name" in args and "file" in args:
        raise Refused("name applies to text or pane only (a file keeps its own name)")
    argv = [str(BIN / "fleet-evidence.sh"), action]
    if "issue" in args:
        argv += ["--issue", str(args["issue"])]
    if "note" in args:
        argv += ["--note", args["note"]]
    if "name" in args:
        argv += ["--name", args["name"]]
    if args.get("mv"):
        argv.append("--mv")
    if "pane" in args:
        argv += ["--pane", args["pane"]]
    if "file" in args:
        return script(argv + [args["file"]], WRITE_TIMEOUT_S)
    if "text" in args:
        return stdin_script(argv + ["-"], args["text"], WRITE_TIMEOUT_S)
    return script(argv, WRITE_TIMEOUT_S)


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


def tool_pr_verdict(args):
    if not args.get("wait") and ("until_merged" in args or "timeout" in args):
        raise Refused("until_merged and timeout apply with wait only")
    argv = [str(BIN / "fleet-pr-verdict.sh"), str(args["pr"])] + check_repo(args)
    if not args.get("wait"):
        return script(argv, VERDICT_TIMEOUT_S)
    t = args.get("timeout", AWAIT_DEFAULT_S)
    argv += ["--wait", "--timeout", str(t)]
    if args.get("until_merged"):
        argv.append("--until-merged")
    return script(argv, t + AWAIT_SLACK_S)


def tool_pr_merge(args):
    return script([str(BIN / "fleet-pr-merge.sh"), str(args["pr"])] + check_repo(args), MERGE_TIMEOUT_S)


# --- the rest of a worker skill (issue #1811, EPIC #1813 C9) --------------------

def tool_brief(args):
    if args.get("kind") == "resume":
        extra = [k for k in ("issue", "repo", "no_comments") if k in args]
        if extra:
            raise Refused("resume takes no %s" % ", ".join(extra))
        return script([str(BIN / "fleet-compact-resume.sh"), "--brief"], STATUS_TIMEOUT_S)
    argv = [str(BIN / "fleet-claim-brief.sh")]
    if "issue" in args:
        argv += ["--issue", str(args["issue"])]
    argv += check_repo(args)
    if args.get("no_comments"):
        argv.append("--no-comments")
    return script(argv, BRIEF_TIMEOUT_S)


def tool_file_issue(args):
    if args.get("spawn") and args.get("bind"):
        raise Refused("spawn and bind are exclusive (bind makes THIS scratch session the worker)")
    argv = [str(BIN / "fleet-issue-file.sh"), "--title", args["title"]]
    if "body" in args:
        argv += ["--body", args["body"]]
    for label in [x.strip() for x in args.get("labels", "").split(",") if x.strip()]:
        argv += ["--label", label]
    if "priority" in args:
        argv += ["--priority", args["priority"]]
    if "parent" in args:
        argv += ["--parent", str(args["parent"])]
    argv += check_repo(args)
    if args.get("spawn"):
        argv.append("--spawn")
    if args.get("bind"):
        argv.append("--bind")
    return script(argv, FILE_TIMEOUT_S)


GH_KIND = {"issue": ["issue", "view"], "pr": ["pr", "view"], "checks": ["pr", "checks"]}


def tool_gh(args):
    argv = [str(BIN / "fleet-gh.sh")] + GH_KIND[args["kind"]] + [str(args["number"])] + check_repo(args)
    if "fields" in args:
        argv += ["--json", args["fields"]]
    if "max_age" in args:
        argv += ["--max-age", str(args["max_age"])]
    return script(argv, VERDICT_TIMEOUT_S)


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


def tool_whats_new(args):
    argv = [str(BIN / "fleet-whats-new.sh"), "--full"]
    if args.get("to") and not args.get("from"):
        raise Refused("to needs from")
    argv += [args[k] for k in ("from", "to") if args.get(k)]
    return script(argv, STATUS_TIMEOUT_S)


def tool_show(args):
    argv = [str(BIN / "fleet-show.sh")] + (["--inline"] if args.get("inline") else []) + ["--", args["file"]]
    return script(argv, SHOW_TIMEOUT_S)


def tool_open(args):
    return script([str(BIN / "fleet-open.sh"), "--", args["target"]], STATUS_TIMEOUT_S)


# A session's reap policy (issue #1902) — bin/fleet_reap_policy.py is the grammar;
# the script canonicalizes or refuses (exit 2), this is only its shape.
REAP_POLICY = {"type": "string", "maxLength": 48,
               "pattern": r"^(?:(?:merged|done)(?::[1-9][0-9]{0,6}[smhd]?)?|loop-end|keep|at:[0-9][0-9TZ:+-]{0,31})$"}
ISSUE = {"type": "integer", "minimum": 1, "description": 'The GitHub issue number (a positive integer, no "#").'}
REPO = {"type": "string", "pattern": r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$",
        "description": "owner/name of a repo THIS fleet hosts (the repos tool lists them). "
                       "Omit for the fleet's default repo."}
NO_ARGS = {"type": "object", "properties": {}, "additionalProperties": False}

TOOLS = {
    "status": (tool_status, {
        "description": "Read-only. This fleet window's binding (issue, repo, state, origin), every child session "
                       "it spawned (bin/fleet-children.sh) and the repos this fleet hosts. Changes nothing.",
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
        "description": "Start a fleet worker session on a GitHub issue (its own worktree + window; it claims, "
                       "implements and lands the issue itself). Runs bin/dash-issue-session.sh, so the session "
                       "caps and the claim dedup apply. Exit 0 spawned (or the window already exists), 2 at "
                       "capacity, 3 already claimed, 1 infrastructure. Returns at once — await waits for it.",
        "inputSchema": {"type": "object", "properties": {
            "issue": ISSUE, "repo": REPO,
            "reap": dict(REAP_POLICY, description="When the fleet may close it on its own (default merged: "
                                                  "after its PR merged) — see set_reap.")},
            "required": ["issue"], "additionalProperties": False}}),
    "set_reap": (tool_set_reap, {
        "description": "When the fleet may close THIS session on its own (bin/fleet-reap-policy.sh set; issue "
                       "#1902): merged (after its PR merged + the fleet's grace) · merged:48h (keep it 48 hours "
                       "after the merge, e.g. to wait for a read-back) · done:2h (its turn over and idle 2 hours) "
                       "· loop-end (once its /loop stops) · at:18:00 or at:<ISO time> · keep (never; it may still "
                       "sleep). Every automatic close records history first and keeps unpushed work. Exit 0 set, "
                       "2 not a policy, 1 no window.",
        "inputSchema": {"type": "object", "properties": {"policy": REAP_POLICY},
                        "required": ["policy"], "additionalProperties": False}}),
    "await": (tool_await, {
        "description": "Hand an issue to a worker (spawning one if none is live) and BLOCK until it lands, "
                       "blocks or is reaped; prints the verdict (MERGED / BLOCKED / FAILED / TIMEOUT / REAPED / "
                       "NO-WORKER), PR and summary. Runs bin/fleet-await.sh. TIMEOUT (exit 3) means still "
                       "running — call again to keep waiting (nothing spawns twice).",
        "inputSchema": {"type": "object", "properties": {
            "issue": ISSUE, "repo": REPO,
            "timeout": {"type": "integer", "minimum": 1, "maximum": AWAIT_MAX_S,
                        "description": "Seconds to wait before answering TIMEOUT (default %d, at most %d)."
                                       % (AWAIT_DEFAULT_S, AWAIT_MAX_S)}},
            "required": ["issue"], "additionalProperties": False}}),
    "send": (tool_send, {
        "description": "Send text to a live fleet peer as its next turn (bin/fleet-peer-send.sh). "
                       "to is issue:<N>, scratch-<N> or parent.",
        "inputSchema": {"type": "object", "properties": {"to": {"type": "string"}, "text": {"type": "string"}},
                        "required": ["to", "text"], "additionalProperties": False}}),
    "report": (tool_report, {
        "description": "报 — tell the session that SPAWNED this one how it ended (bin/fleet-report-parent.sh). "
                       "Exit 0 reported (or no parent to tell — a hub-spawned session), 3 queued: the parent "
                       "cannot take it now and it is delivered when it can (do not resend), 1 refused. A merged "
                       "report is checked against the PR's real state: report merged only after pr_merge says "
                       "MERGED.",
        "inputSchema": {"type": "object", "properties": {
            "state": {"type": "string", "enum": ["merged", "blocked", "failed", "stopped", "waiting"],
                      "description": "How it ended."},
            "pr": {"type": "integer", "minimum": 1, "description": "The PR number (merged / failed)."},
            "summary": {"type": "string", "description": "1-3 lines: what changed, what the parent must know."},
            "dry_run": {"type": "boolean", "description": "Print the target and the envelope; send nothing."}},
            "required": ["state"], "additionalProperties": False}}),
    "ask": (tool_ask, {
        "description": "问 — you are blocked on the operator: a question only they can answer, or an "
                       "authorization you cannot grant yourself. Posts the question on the bound issue "
                       "(bin/fleet-comment.sh --note, as `⛔ blocked: …`) and turns this window red on the dash "
                       "(set-claude-state.sh blocked) until the next prompt arrives. The answer comes back as "
                       "your next turn, by the existing channels. Then end your turn — do not spin.",
        "inputSchema": {"type": "object", "properties": {
            "question": {"type": "string", "description": "What you need, and why you cannot go on without it."},
            "kind": {"type": "string", "enum": ["question", "permission"],
                     "description": "question (default) or permission (an authorization you need)."},
            "issue": dict(ISSUE, description="Ask on this issue instead of the window's bound one.")},
            "required": ["question"], "additionalProperties": False}}),
    "comment": (tool_comment, {
        "description": "记 — comment on an issue through bin/fleet-comment.sh (the marker + sender footer). "
                       "mode note (the DEFAULT) is RECORD-ONLY: the issue's worker never sees it. mode to-worker "
                       "is relayed into that issue's worker as its next turn (to just tell a peer something, "
                       "send is direct). close closes the issue after the comment (a no-PR wrap-up).",
        "inputSchema": {"type": "object", "properties": {
            "issue": ISSUE, "body": {"type": "string", "description": "The comment, Markdown."},
            "mode": {"type": "string", "enum": ["note", "to-worker"], "description": "note (default) or to-worker."},
            "close": {"type": "boolean", "description": "Close the issue after posting."},
            "repo": REPO},
            "required": ["issue", "body"], "additionalProperties": False}}),
    "evidence": (tool_evidence, {
        "description": "记 — store before/after evidence for the EPIC report (bin/fleet-evidence.sh). "
                       "line prints the issue's 上线证据 line (exit 1 = none); before (prior to touching code) "
                       "and after (PR open, not landed) store ONE capture: a file path, text (a command's "
                       "output), or a tmux pane; post leaves ONE record-only comment listing every capture.",
        "inputSchema": {"type": "object", "properties": {
            "action": {"type": "string", "enum": ["line", "before", "after", "post"]},
            "file": {"type": "string", "description": "Path of the capture (before / after)."},
            "text": {"type": "string", "description": "The capture's text, e.g. a command's output (before / after)."},
            "pane": {"type": "string", "description": "A tmux target to capture (before / after)."},
            "name": {"type": "string", "description": "File name for a text or pane capture."},
            "note": {"type": "string", "description": "One line: what the capture shows."},
            "mv": {"type": "boolean", "description": "Move the file instead of copying (a .playwright-mcp/ shot)."},
            "issue": dict(ISSUE, description="The member issue (default: this window's).")},
            "required": ["action"], "additionalProperties": False}}),
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
            "pr": {"type": "integer", "minimum": 1, "description": "The PR number."},
            "repo": REPO,
            "wait": {"type": "boolean", "description": "Block while the verdict is PENDING."},
            "until_merged": {"type": "boolean", "description": "With wait: READY with auto-merge armed keeps "
                                                               "waiting until MERGED."},
            "timeout": {"type": "integer", "minimum": 1, "maximum": AWAIT_MAX_S,
                        "description": "With wait: seconds before TIMEOUT (default %d, at most %d)."
                                       % (AWAIT_DEFAULT_S, AWAIT_MAX_S)}},
            "required": ["pr"], "additionalProperties": False}}),
    "pr_merge": (tool_pr_merge, {
        "description": "合 — merge a READY PR with this fleet's method, branch deleted, then confirm "
                       "(bin/fleet-pr-merge.sh): MERGED exit 0; anything not READY is printed and refused (exit "
                       "1) — it never merges red. Falls back to REST when GraphQL is rate-limited.",
        "inputSchema": {"type": "object", "properties": {
            "pr": {"type": "integer", "minimum": 1, "description": "The PR number."}, "repo": REPO},
            "required": ["pr"], "additionalProperties": False}}),
    "brief": (tool_brief, {
        "description": "The one opening read (issue #1811). kind claim (default): bin/fleet-claim-brief.sh — fleet, "
                       "seat, the bound issue with every comment, the claim, the charter layers, the directive, "
                       "origin. Exit 0 go · 2 not in a fleet · 3 wrong seat · 4 no issue bound · 5 the issue read "
                       "failed. kind resume: bin/fleet-compact-resume.sh --brief — the recovery map after an "
                       "in-place compaction.",
        "inputSchema": {"type": "object", "properties": {
            "kind": {"type": "string", "enum": ["claim", "resume"], "description": "claim (default) or resume."},
            "issue": dict(ISSUE, description="claim: read this issue instead of the window's bound one."),
            "repo": REPO,
            "no_comments": {"type": "boolean", "description": "claim: skip the comment thread."}},
            "additionalProperties": False}}),
    "file_issue": (tool_file_issue, {
        "description": "File a GitHub issue through the ONE filer channel (bin/fleet-issue-file.sh): the "
                       "provenance marker, the label taxonomy, the default milestone. parent links it as a "
                       "sub-issue; spawn hands it to a new worker (caps + dedup apply; a cap refusal leaves it "
                       "filed); bind makes THIS scratch session its worker (refused from a worker). Prints the "
                       "issue URL. Exit 0 ok · 2 usage · 3 unknown label · 4 spawn with no live parent · 1 failure.",
        "inputSchema": {"type": "object", "properties": {
            "title": {"type": "string"},
            "body": {"type": "string", "description": "The issue body, Markdown."},
            "labels": {"type": "string", "description": "Comma-separated labels (the fleet's fixed taxonomy)."},
            "priority": {"type": "string", "enum": ["p0", "p1", "p2", "p3"]},
            "parent": dict(ISSUE, description="File it as a sub-issue of this issue."),
            "spawn": {"type": "boolean", "description": "Start a worker on it now."},
            "bind": {"type": "boolean", "description": "Scratch only: become its worker in place."},
            "repo": REPO},
            "required": ["title"], "additionalProperties": False}}),
    "gh": (tool_gh, {
        "description": "Read an issue, a PR or a PR's checks from the fleet's local copy first, GitHub only when "
                       "it is too old (bin/fleet-gh.sh) — one JSON object with the gh --json field names plus "
                       "_source (cache|gh|rest) and _age. Use it instead of a bare gh view; the merge gate is "
                       "pr_verdict.",
        "inputSchema": {"type": "object", "properties": {
            "kind": {"type": "string", "enum": ["issue", "pr", "checks"]},
            "number": {"type": "integer", "minimum": 1, "description": "The issue / PR number."},
            "fields": {"type": "string", "description": "Comma-separated gh --json fields, e.g. title,state."},
            "max_age": {"type": "integer", "minimum": 0,
                        "description": "Oldest cached copy to accept, seconds (0 = always ask GitHub)."},
            "repo": REPO},
            "required": ["kind", "number"], "additionalProperties": False}}),
    "context": (tool_context, {
        "description": "How full is THIS session's context window (bin/fleet-context.sh): the percentage and a "
                       "verdict on the auto-handoff bands — OK · WATCH (finish this thread, then hand off) · "
                       "HANDOFF (now). Exit 0 OK · 1 any other verdict · 2 nothing to read.",
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
    "whats_new": (tool_whats_new, {
        "description": "Read-only. What changed in the fleet since THIS session started (bin/fleet-whats-new.sh "
                       "--full): the tools added or retired, worker-skill and guard changes, the rest counted. "
                       "The same note a working session gets once at its next turn after a version move. "
                       "Exit 0 printed · 1 nothing changed (or no version to compare).",
        "inputSchema": {"type": "object", "properties": {
            "from": {"type": "string", "pattern": "^[0-9a-f]{7,40}$",
                     "description": "Old fleet version (sha); default this session's launch version."},
            "to": {"type": "string", "pattern": "^[0-9a-f]{7,40}$",
                   "description": "New fleet version (sha); default the current one."}},
            "additionalProperties": False}}),
    "show": (tool_show, {
        "description": "Show a file (image, PDF, QR code, screenshot) on the OPERATOR's terminal, never this "
                       "machine's screen (bin/fleet-show.sh): SENT (exit 0) offered as a download; PATH (exit 2) "
                       "no iTerm2 attached — tell them the path. inline draws it and holds the screen until they "
                       "press a key.",
        "inputSchema": {"type": "object", "properties": {
            "file": {"type": "string", "description": "Path of the file."},
            "inline": {"type": "boolean", "description": "Draw it in the terminal instead of a download."}},
            "required": ["file"], "additionalProperties": False}}),
    "open": (tool_open, {
        "description": "Open a URL, a page served here (:port[/path], localhost) or a file in the OPERATOR's own "
                       "browser over their SSH connection (bin/fleet-open.sh) — never `open` on this machine. "
                       "Prints sent:<how> or fallback:copied (exit 0), fallback:path (exit 2) — say the path.",
        "inputSchema": {"type": "object", "properties": {
            "target": {"type": "string", "description": "A URL, :port[/path], or a file path."}},
            "required": ["target"], "additionalProperties": False}}),
}

# The pre-#1807 fleet-peer server, for a config that still mounts it (one version).
LEGACY = {
    "list_agents": (tool_agents, dict(TOOLS["agents"][1])),
    "send_message": (tool_send, dict(TOOLS["send"][1])),
}


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
    return {"content": [{"type": "text", "text": text}], "structuredContent": data}


def tool_call(table, name, args):
    SIGNED["assert"] = False
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


def respond(request, result=None, error=None):
    if "id" not in request:
        return
    msg = {"jsonrpc": "2.0", "id": request["id"]}
    if error:
        msg["error"] = error
    else:
        msg["result"] = result
    print(json.dumps(msg, separators=(",", ":"), ensure_ascii=False), flush=True)


def handle(request, table, name):
    method = request.get("method")
    if method == "initialize":
        RELOAD["ready"] = True
        asked = (request.get("params") or {}).get("protocolVersion")
        return {"protocolVersion": asked if isinstance(asked, str) and asked else "2024-11-05",
                "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": {"name": name, "version": VERSION}}
    if method == "tools/list":
        return {"tools": [{"name": n, **spec} for n, (_, spec) in table.items()]}
    if method == "tools/call":
        params = request.get("params") or {}
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
SELF = os.path.abspath(__file__)       # the path as launched: through the version link
RELOAD = {"ready": False, "sig": None, "bad": None}


def self_sig():
    """What version SELF is right now: its real path + the file's identity."""
    try:
        real = os.path.realpath(SELF)
        st = os.stat(real)
    except OSError:
        return None
    return "%s:%d:%d:%d" % (real, st.st_ino, st.st_size, st.st_mtime_ns)


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
    state = {"from": RELOAD["sig"], "to": sig}
    if carry:
        fd, path = tempfile.mkstemp(prefix="fleet-mcp-carry.")
        with os.fdopen(fd, "wb") as fh:
            fh.write(carry)
        state["carry"] = path
    os.environ[RELOAD_ENV] = json.dumps(state)
    sys.stdout.flush()
    reload_log("exec", "%s -> %s" % (RELOAD["sig"], sig))
    try:
        os.execv(sys.executable, [sys.executable, SELF])
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
    watch = table is TOOLS
    RELOAD["sig"] = self_sig() if watch else None
    buf = reload_resume() if watch else b""
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


def mount_codex():
    """The `-c` value that mounts this server in Codex: what conf/mcp-worker.json
    says, plus the env Codex would otherwise withhold and a per-call timeout an
    await fits in."""
    conf = json.loads((BIN.parent / "conf" / "mcp-worker.json").read_text())
    srv = conf["mcpServers"][SERVER]
    fields = ["command=" + toml_str(srv["command"]),
              "args=[" + ",".join(toml_str(a) for a in srv.get("args", [])) + "]",
              "env_vars=[" + ",".join(toml_str(v) for v in CODEX_ENV) + "]",
              "tool_timeout_sec=%d" % CODEX_TOOL_TIMEOUT_S]
    return "mcp_servers.%s={%s}" % (SERVER, ",".join(fields))


def main(argv):
    if argv[:2] == ["--mount", "codex"]:
        print(mount_codex())
        return 0
    if argv[:1] == ["--cred"] and len(argv) == 2:
        return cred_main(argv[1])
    if argv[:1] == ["--probe"]:
        # A new version proves it starts before a running server execs it (#1898).
        print(json.dumps({"tools": sorted(TOOLS)}))
        return 0
    if argv[:1] == ["--legacy-peer"]:
        serve(LEGACY, "fleet-peer")
        return 0
    if argv:
        print("usage: fleet-mcp.py [--mount codex | --legacy-peer | --probe | --cred mint|check|revoke|assert]", file=sys.stderr)
        return 2
    serve(TOOLS, SERVER)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
