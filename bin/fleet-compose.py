#!/usr/bin/env python3
"""fleet-compose.py — ⌘N: the writing area on the right (issue #1953, EPIC #1949 C4;
one box and three options since issue #2231, EPIC #2230 C1).

    fleet-compose.py [--session S]        the writing area (curses) — the pane of
                                          the client stage's `@fleet_role portal`
                                          window (fleet-shell.sh portal opens it:
                                          ⌘N / prefix c / a tap on 「新任务」)
    fleet-compose.py --send <payload.json> [--repo R | --no-repo] [--node N]
                     [--agent claude|codex] [--reap P]
                                          the ONE way out: the payload a ↵ wrote,
                                          to the machine that opens it —
                                          fleet-client-place.sh <repo> new (an
                                          issue, filed there, then its worker), or
                                          `-` scratch with the text as its seed
                                          (HOME: repo null). The payload's node /
                                          agent ride along (--node / --agent, issue
                                          #2232; null = auto / the fleet's default).
                                          Prints the place's one line and returns
                                          its code.
    fleet-compose.py --orch <session> [--client C] [--boot]
                                          ⌘N again on the writing area (issue
                                          #2146, fleet-shell.sh portal) and
                                          「新任务」's menu: the stage straight
                                          onto the orchestrating session, no
                                          draft — carry()'s own switch; with
                                          none (no orch_<session>), or no list to
                                          jump with, one line on the client C and
                                          exit 1. --boot (issue #2616, ⌘N with
                                          FLEET_COMPOSE off): with none, ask the
                                          hub to open it (orch_ensure) and go
                                          once it shows — 「正在叫起…」 meanwhile
    fleet-compose.py --steward <session> [--client C]
                                          「新任务」's 进管家会话 (issue #2735):
                                          the same jump onto the steward's
                                          window (steward_all_<session>'s first
                                          worker_id); none ⇒ one line, exit 1
    fleet-compose.py payload <text-file> [--repo R | --no-repo] [--node N] [--agent A]
                                          the payload a ↵ on that text would write
                                          ({title, body, attachments, repo, node,
                                          agent}), as JSON — the selftest's view

The writing area: several lines (⇧↵ — the `fleet` iTerm2 profile sends it as
0x0a, ⌃j — or ⌥↵ makes a new line; ↵ sends), a file dropped on the window (its
path pasted) is an attachment, esc goes back to the session that was in view.
Under the box, three options already picked, so ↵ needs none of them (Tab walks
to them, ↵ / space / ↓ opens one, ↑↓ picks):
  仓库   every repo the hub says this person's machines host, and 无仓库 · HOME
         (a session in $HOME, `@norepo`, no issue — the text is its seed).
         Default: the repo of the session that was in view, else the one the
         last send went to (compose-state.json beside the draft), else the
         first. A repo is always an issue: filed on the machine, then its worker.
  节点   every machine, by sessions running; 只协调 / 维护中 / 失联 greyed.
         Default: the one the hub's placement picks (fewest running).
  Agent  claude / codex. Default: FLEET_AGENT.
A change made by hand is for this send only: a send, esc, or ⌘N (fleet-shell.sh
portal hands the area ESC[928~) puts the defaults back. What was not changed
travels as null — the hub picks the machine, the fleet its agent (EPIC #2230
共同约定 1). The draft is on disk the whole time —
$XDG_STATE_HOME/claude-fleet/compose-draft (FLEET_SWITCH_STATE overrides the
directory, as for the switch history), so leaving and coming back, or the client
restarting, loses nothing.

↵ writes the payload (compose-send.json beside the draft: the first line is the
title, the whole text the body, every attachment's path listed under it) and
hands the task list `compose` on its @sidebar_do queue (F12 wakes it, exactly as
⌘P's pick does): the list draws 「开工中…」 under the 「新任务」 row at once, runs
--send in the background and switches to the new session's row when it appears.
No list on screen (an older client): --send runs from here. The box empties only
when the machine said done (issue #2240): the list tells the area how the send
ended (compose-result.json — {id, ok, why}), and one that did not open — the
hub out of reach, a refusal, a machine that said no — leaves the text as it was
written, its reason on the line under the options until the next key, and its
payload kept as compose-failed.json. Nothing on the way
spends a token: the issue is filed by fleet-issue-file.sh on the machine, the
worker opened by its spawn. The orchestrator is not reached from here: its own
row (and ⌘N on the writing area, #2146) is the way in.
"""
import curses
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import unicodedata
from pathlib import Path

BIN = Path(__file__).absolute().parent
MAX_TITLE = 256       # GitHub's bound — the hub's checkIssueTitle
MAX_BODY = 4000       # the hub's checkText — what a write may carry
MAX_SCRATCH = 64      # the hub's checkScratchName
PLACE_WORDS = ("REMOTE", "LOCAL", "HELD", "REFUSED", "DECLINED", "UNKNOWN")  # fleet-client-place.sh's line
PORTAL = "new"        # the portal window's @remote: the list's row key for it
SAVE_EVERY = 1.0      # the draft is written at most this often while typing
TOLD_EVERY = 0.5      # how often a send in flight looks for its answer (issue #2240)
TOLD_WAIT = 240       # no answer by then (an older list): the text stays, said so


def state_dir():
    env = os.environ.get("FLEET_SWITCH_STATE")
    if env:
        return Path(env)
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return Path(base) / "claude-fleet"


def draft_path():
    return state_dir() / "compose-draft"


def send_path():
    return state_dir() / "compose-send.json"


def result_path():
    """compose-result.json beside the draft (issue #2240): how a send ended, as
    the list (or --send from here) saw it — {id, ok, why}. Only a done start
    clears the box; anything else leaves the text and says why."""
    return state_dir() / "compose-result.json"


def failed_path():
    """compose-failed.json: the payload of the last send that did not open
    (issue #2240) — kept, never unlinked, so nothing written is lost."""
    return state_dir() / "compose-failed.json"


def compose_told(cid, ok, why=""):
    """The writing area told how its send `cid` ended (issue #2240): the list's
    words when it did not open. The area reads it on its next beat."""
    return write_atomic(result_path(), json.dumps({"id": cid, "ok": bool(ok), "why": why or ""},
                                                  ensure_ascii=False) + "\n")


def read_told():
    try:
        data = json.loads(result_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def keep_failed(path):
    """The payload of a send that did not open, kept as compose-failed.json."""
    try:
        os.replace(str(path), str(failed_path()))
    except OSError:
        pass


def place_why(text):
    """The reason in fleet-client-place.sh's output (the direct road, no list):
    its line's message after the tab, else the last line said."""
    line = next((l for l in reversed(text.splitlines()) if l.split(" ", 1)[0] in PLACE_WORDS), "")
    if line:
        why = line.partition("\t")[2].partition("\tafter ")[0].strip()
        return why or line.strip()
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    return lines[-1] if lines else ""


def log_path():
    """logs/compose.ndjson beside this install's bin/ (issue #1955) —
    FLEET_COMPOSE_LOG overrides it (the selftest's seam)."""
    return Path(os.environ.get("FLEET_COMPOSE_LOG") or (BIN.parent / "logs" / "compose.ndjson"))


def compose_log(ev, **fields):
    """One line of logs/compose.ndjson (issue #1955, EPIC #1949 R2): how the
    writing area is used, for /fleet-history's `drafts` and the daily brief.
      sent     a ↵ / a hand-over left the area: id, how (issue · scratch · norepo ·
               multi · orchestrate), repo; ts = the ↵'s time, t_enter its ms
      placed   the place answered: id, rc, result (the place's first word),
               machine, session (the worker_id it named), op, secs since sent;
               t_accepted + timing = the node's points (issue #2238), when it sent them;
               key · window · filed = a warm start's session (issue #2236)
      switched the list switched the stage to the new session as the place
               answered, before its row showed: id, session, t_switch (issue #2236)
      started  the new session's row appeared in the list: id, session, fid,
               state, secs since sent — the task list writes it
      ready    that row first read a state the person can type into: id, session,
               state, t_ready — the task list writes it (issue #2238)
    Every t_* is epoch ms, named by EPIC #2230 共同约定 3;
    fleet-compose-latency.sh reads them back.
    Append-only, one write per line; a failure to write never stops a send."""
    row = {"ev": ev, "ts": int(time.time())}
    row.update({k: v for k, v in fields.items() if v not in (None, "")})
    try:
        path = log_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(str(path), "a", encoding="utf-8") as out:
            out.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
        return True
    except OSError:
        return False


def read_opened(path):
    """The session fleet-client-place.sh said it opened (issue #2236), at
    `path`: its string fields; {} for none or junk."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8") or "{}")
    except (OSError, ValueError):
        return {}
    return {k: v for k, v in data.items() if isinstance(v, str)} if isinstance(data, dict) else {}


def read_timing(path):
    """The node's timing points fleet-client-place.sh left at `path` (issue
    #2238): {t_*: epoch ms} — only integer t_* fields; {} for none or junk."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8") or "{}")
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {k: v for k, v in data.items()
            if k.startswith("t_") and isinstance(v, int) and not isinstance(v, bool)}


def send_how(data, mode=""):
    """How a payload went out, as compose.ndjson spells it: issue (a repo) or
    norepo (HOME); scratch for an older area's 「记成 issue」 off."""
    if payload_norepo(data, mode):
        return "norepo"
    return "issue" if data.get("issue", True) else "scratch"


def write_atomic(path, text):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix="." + path.name)
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(text)
        os.replace(tmp, str(path))
        return True
    except OSError:
        return False


def load_text():
    try:
        out = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "compose_", "orch_"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        out = b""
    parts = out.decode("utf-8", "replace").split("\0")
    return dict(zip(parts[0::2], parts[1::2]))


TEXT = {}


def tr(key, *args):
    text = TEXT.get(key, key)
    for arg in args:
        text = text.replace("\x01", str(arg), 1)
    return text.replace("\x01", "")


# --- the payload ----------------------------------------------------------------

# A path a drop pastes: absolute or ~/, a backslash before each space (iTerm2's
# own quoting), or wrapped in quotes. Only one that exists here counts.
PATH_RE = re.compile(r"""'((?:~|/)[^'\n]+)'|"((?:~|/)[^"\n]+)"|((?:~|/)(?:\\.|[^\s\\])+)""")


def attachments(text):
    """The files a drop put in the text, in order, each once — the paths as they
    exist on this computer."""
    out = []
    for m in PATH_RE.finditer(text):
        raw = m.group(1) or m.group(2) or re.sub(r"\\(.)", r"\1", m.group(3))
        path = os.path.expanduser(raw.rstrip(".,;:，。；：)）"))
        if len(path) > 1 and os.path.isfile(path) and path not in out:
            out.append(path)
    return out


# One file the writing area can send to another machine (issue #2393): the
# hub's bound (fleet_attachment.go), said beside the name before ↵ —
# fleet-client-place.sh checks it again and says what did not go.
ATTACH_MAX = 10 << 20


def too_big(path):
    try:
        return os.path.getsize(path) > ATTACH_MAX
    except OSError:
        return False


def clean(text):
    """No control character but newline and tab; no `<!--` (the hub refuses a
    marker it did not stamp itself, so a pasted one is defused, not rejected)."""
    text = "".join(c for c in text if c in "\n\t" or unicodedata.category(c) != "Cc")
    return text.replace("<!--", "<! --")


def payload(text, prev="", repo="", node=None, agent=None):
    """What a ↵ sends (EPIC #2230 共同约定 1): {title, body, attachments, repo,
    node, agent} — the first line is the title, the whole text the body, the
    attachments listed under it. {} when there is nothing to send. `repo` is
    owner/name, None for HOME (a session in $HOME, `@norepo`, no issue — the
    text still its seed), or "" when this computer knows no repo to name (the
    list resolves it where the rows are, #1938); `node` None = the hub picks by
    load, `agent` None = the fleet's default (FLEET_AGENT). prev · at · id ride
    along for the list and compose.ndjson."""
    text = clean(text).strip("\n")
    lines = [l.strip() for l in text.split("\n")]
    title = next((l for l in lines if l), "")
    if not title:
        return {}
    files = attachments(text)
    body = text
    if files:
        body += "\n\n" + tr("compose_attach") + ":\n" + "\n".join("- " + f for f in files)
    if len(body) > MAX_BODY:
        body = body[:MAX_BODY - 1] + "…"
    title = " ".join(title.split())
    if len(title) > MAX_TITLE:
        title = title[:MAX_TITLE - 1] + "…"
    return {"title": title, "body": body, "attachments": files, "repo": repo,
            "node": node or None, "agent": agent or None, "prev": prev, "at": int(time.time()),
            "t_enter": int(time.time() * 1000), "id": "%x" % time.time_ns()}


def payload_norepo(data, mode=""):
    """HOME: the payload's repo is null (an older writing area said it as
    repo_mode none / multi — #1956 — read for one version). # compat-1v: 下一批删"""
    mode = mode or data.get("repo_mode") or ""
    return mode in ("none", "multi") or ("repo" in data and data["repo"] is None)


def scratch_name(title):
    name = " ".join(title.replace("#", " ").split())
    return name[:MAX_SCRATCH].strip()


def status_dir():
    """The refresh loop's cache dir (fleet-status-lib.sh FLEET_STATUS_G)."""
    return os.environ.get("FLEET_STATUS_G") or os.path.join(os.environ.get("TMPDIR") or f"/tmp/claude-fleet-{os.getuid()}",
                                                             ".claude-dash", "global")


def hub_repos():
    """The repos the hub says this person's machines host (the sidebar's
    hub_repos cache) — None when it was never read."""
    try:
        with open(os.path.join(status_dir(), "hub_repos"), encoding="utf-8") as f:
            return [r for r in f.read().splitlines() if r and not r.startswith("#") and "/" in r]
    except OSError:
        return None


def send(path, repo="", node="", reap="", mode="", agent=""):
    """The way out (`--send`): the payload to fleet-client-place.sh. Prints its
    line, returns its code. 2 = nothing to send / no repo to send it to. `mode`
    none (--no-repo) beats the payload's repo; a named --repo beats both. The
    machine and the agent (issue #2232, EPIC #2230 共同约定 1): a named --node /
    --agent, else the payload's `node` / `agent`; null or absent = auto / the
    fleet's default (no --agent at all). The text always travels (issue #2231:
    a send never drops what was written)."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print("fleet-compose: cannot read %s: %s" % (path, error), file=sys.stderr)
        return 2
    title = data.get("title") or ""
    node = node or data.get("node") or "auto"
    agent = agent or data.get("agent") or ""
    if agent not in ("claude", "codex", ""):
        print("fleet-compose: agent is claude or codex, not %s" % agent, file=sys.stderr)
        return 2
    if not title:
        print("fleet-compose: the payload has no title", file=sys.stderr)
        return 2
    if repo:
        mode = "repo"
    norepo = mode != "repo" and payload_norepo(data, mode)
    if not norepo:
        # The one rule (#1938): named → the payload's → the only one → ask.
        repo = repo or data.get("repo") or ""
        if not repo:
            repos = hub_repos() or []
            if len(repos) == 1:
                repo = repos[0]
        if "/" not in repo:
            print("fleet-compose: name the repo (owner/name) — none to go on", file=sys.stderr)
            return 2
    cid = data.get("id") or "%x" % time.time_ns()
    at = int(data.get("at") or time.time())
    t_enter = int(data.get("t_enter") or at * 1000)
    compose_log("sent", id=cid, how=send_how(data, "none" if norepo else ""), repo="" if norepo else repo, at=at,
                t_enter=t_enter)
    args = ["bash", str(BIN / "fleet-client-place.sh"), "-" if norepo else repo]
    text = data.get("body") or ""
    if not norepo and data.get("issue", True):
        args += ["new", "--title", title]
    else:
        # HOME (issue #1956): a session of no repo — never an issue, which
        # belongs to one repo — that starts working on the text. (An older
        # area's repo scratch, 「记成 issue」 off, lands here too — and keeps
        # its text now, #2231.)
        args += ["scratch"]
        name = scratch_name(title)
        if name:
            args += ["--name", name]
    bodyf = ""
    if text:
        fd, bodyf = tempfile.mkstemp(prefix="fleet-compose-body.", dir=str(Path(path).parent))
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(text)
        args += ["--body-file", bodyf]
    # The files themselves go with it (issue #2393): the session may run on
    # another machine, where the paths in the text do not exist.
    for f in data.get("attachments") or []:
        if isinstance(f, str) and os.path.isfile(f):
            args += ["--attach", f]
    args += ["--node", node]
    if agent:
        args += ["--agent", agent]
    if reap:
        args += ["--reap", reap]
    # The node's timing points come back through a file (issue #2238): the
    # place's stdout stays its one line.
    fd, timef = tempfile.mkstemp(prefix="fleet-compose-timing.", dir=str(Path(path).parent))
    os.close(fd)
    # …and the session it opened (issue #2236): a warm start's window and key.
    fd, resf = tempfile.mkstemp(prefix="fleet-compose-result.", dir=str(Path(path).parent))
    os.close(fd)
    env = dict(os.environ, FLEET_PLACE_TIMING=timef, FLEET_PLACE_RESULT=resf)
    try:
        out = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True, env=env)
        timing = read_timing(timef)
        opened = read_opened(resf)
    finally:
        for f in (bodyf, timef, resf):
            if f:
                try:
                    os.unlink(f)
                except OSError:
                    pass
    sys.stdout.write(out.stdout)
    # the issue a `new` filed (issue #2753 — ⌘T's 「已建 #N 并开工」), on stderr:
    # stdout stays the place's one line
    num = re.search(r"/issues/(\d+)|^#?(\d+)$|^issue-(\d+)$", opened.get("filed") or "") or \
        re.search(r"(?:^|:)issue-(\d+)$", opened.get("key") or "")
    if out.returncode == 0 and num:
        print("filed: #%s" % next(g for g in num.groups() if g), file=sys.stderr)
    line = next((l for l in reversed(out.stdout.splitlines()) if l.split(" ", 1)[0] in PLACE_WORDS), "")
    words = line.partition("\t")[0].split()
    remote = words[:1] == ["REMOTE"]
    compose_log("placed", id=cid, rc=out.returncode, result=words[0] if words else "",
                machine=words[1] if len(words) > 1 else "",
                session=words[4] if remote and len(words) > 4 and "/" in words[4] else "",
                op=words[2] if remote and len(words) > 2 else "",
                secs=max(0, int(time.time()) - at),
                t_accepted=timing.get("t_accepted"), timing=timing or None,
                key=opened.get("key"), window=opened.get("window_id"), filed=opened.get("filed"))
    return out.returncode


# --- the orchestrating session (issue #1957) ----------------------------------------

def orchestrator(session):
    """The fleet's one orchestrating session, as fleet-hub-sessions.sh's
    orch_<session> says: {wid, node, av, state, needs, detail} — the first line
    (online first, then by machine), None when no machine runs one."""
    try:
        with open(os.path.join(status_dir(), "orch_" + (session or "")), encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\x1f")
                if len(p) >= 4 and "/" in p[0] and p[1]:
                    p += [""] * (6 - len(p))
                    return dict(zip(("wid", "node", "av", "state", "needs", "detail"), p[:6]))
    except OSError:
        pass
    return None


def carry(shell, o, text, wait=None):
    """⌘N on the writing area: the stage onto the orchestrator (the list's own jump), and
    the half-written text into its input — pasted, never sent: ↵ there is the
    person's. The paste waits until the stage shows that session with an agent
    reading bracketed paste (a line break must never send half of it), at most
    FLEET_COMPOSE_CARRY_SECS (8 s). A tmux too old to say (no
    `bracket_paste_flag`, < 3.5): the stage on it and a beat to settle — the
    paste is still bracketed when the agent asked (`paste-buffer -p`).
    Returns (switched, carried)."""
    if not o or not shell.hand("jump=wid:" + o["wid"]):
        return False, False
    if not text.strip():
        return True, True
    want = o["node"] + ":" + o["wid"]
    wait = float(os.environ.get("FLEET_COMPOSE_CARRY_SECS") or 8) if wait is None else wait
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        for line in shell.stage("list-windows", "-F",
                                "#{window_id}\t#{window_active}\t#{@remote}\t#{@remote_down}\t#{bracket_paste_flag}"
                                ).splitlines():
            w = (line.split("\t") + [""] * 5)[:5]
            known = w[4] in ("0", "1")
            if w[1] == "1" and w[2] == want and not w[3] and w[4] != "0":
                if not known:
                    time.sleep(1.0)
                buf = "fleet-compose-carry"
                try:
                    subprocess.run(shell.stage_cmd + ["load-buffer", "-b", buf, "-"], input=text.encode("utf-8"),
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=True)
                    subprocess.run(shell.stage_cmd + ["paste-buffer", "-p", "-d", "-b", buf, "-t", w[0]],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=True)
                except (OSError, subprocess.SubprocessError):
                    return True, False
                return True, True
        time.sleep(0.2)
    return True, False


# --- where the writing area came from ----------------------------------------------

def switch_lib():
    import importlib.util
    spec = importlib.util.spec_from_file_location("fleet_quickopen", str(BIN / "fleet-quickopen.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def previous():
    """(key, repo heading) of the session that was in view before this one —
    the history's most recent row that is not the portal."""
    try:
        lib = switch_lib()
        mru = [k for k in lib.load()["mru"] if k != PORTAL]
        rows = {r["key"]: r for r in lib.read_rows()}
    except Exception:
        return "", ""
    key = mru[0] if mru else ""
    group = (rows.get(key) or {}).get("group", "")
    return key, re.sub(r"\s*\(\d+\)$", "", group).strip()


class Shell:
    """The client's own tmux server (`-L <session>`, the list's), seen from the
    stage: FLEET_COMPOSE_SHELL_SOCK names a socket path instead (the selftest)."""

    def __init__(self, session):
        sock = os.environ.get("FLEET_COMPOSE_SHELL_SOCK", "")
        self.cmd = ["tmux", "-S", sock] if sock else (["tmux", "-L", session] if session else [])
        # the stage — the server this pane is on (its $TMUX); the selftest's
        # FLEET_COMPOSE_STAGE_SOCK names its socket
        stage = os.environ.get("FLEET_COMPOSE_STAGE_SOCK", "")
        self.stage_cmd = ["tmux", "-S", stage] if stage else ["tmux"]

    def stage(self, *args):
        try:
            return subprocess.run(self.stage_cmd + list(args), stdin=subprocess.DEVNULL, capture_output=True,
                                  text=True, timeout=5).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return ""

    def run(self, *args):
        if not self.cmd:
            return ""
        try:
            return subprocess.run(self.cmd + list(args), stdin=subprocess.DEVNULL, capture_output=True,
                                  text=True, timeout=5).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return ""

    def list_pane(self):
        for line in self.run("list-panes", "-a", "-F", "#{pane_id} #{@sidebar}").splitlines():
            pid, _, flag = line.partition(" ")
            if flag == "1":
                return pid
        return ""

    def hand(self, verb):
        pane = self.list_pane()
        if not pane:
            return False
        self.run("set-option", "-pa", "-t", pane, "@sidebar_do", verb + " ", ";", "send-keys", "-t", pane, "F12")
        return True


def to_orch(session, client="", boot=False):
    """⌘N on the writing area / 进编排会话 (issue #2146): carry() with no text — the list's jump to
    orch_<session>'s window, the road ⇧⇥ takes. Nothing to go to says so on
    the client's line instead (never an error). 0 switched, 1 not.
    boot (issue #2616 — ⌘N itself, FLEET_COMPOSE off): with no orch_<session>,
    ask for it first (boot_orch) and go once it shows; the line says why not."""
    shell = Shell(session)
    o = orchestrator(session)
    if not o and boot:
        o, why = boot_orch(session, shell, client)
        if not o:
            msg = tr("orch_boot_timeout", why)
            shell.run("display-message", *(["-c", client] if client else []), msg)
            print(msg)
            return 1
    if o and carry(shell, o, "")[0]:
        stamp_role(shell, o, agent=orch_agent(session, o))
        return 0
    msg = tr("compose_orch_nolist") if o else tr("compose_orch_none")
    shell.run("display-message", *(["-c", client] if client else []), msg)
    print(msg)
    return 1


def to_steward(session, client=""):
    """进管家会话 (issue #2735): the list's jump onto the steward's window — the
    first worker_id of fleet-hub-sessions.sh's steward_all_<session>. The steward
    draws no row (#2670); this and the menu are its door. 0 switched, 1 not."""
    shell = Shell(session)
    wid = ""
    try:
        with open(os.path.join(status_dir(), "steward_all_" + (session or "")), encoding="utf-8") as f:
            wid = next((x.strip() for x in f if "/" in x), "")
    except OSError:
        pass
    if wid and shell.hand("jump=wid:" + wid):
        return 0
    msg = tr("compose_orch_nolist") if wid else tr("compose_steward_none")
    shell.run("display-message", *(["-c", client] if client else []), msg)
    print(msg)
    return 1


def boot_orch(session, shell, client="", secs=None):
    """No orchestrating session anywhere (issue #2616): one line on the client's
    bar — 「正在叫起编排会话…」 — while the hub is asked to open it on the machine
    that holds it (fleet-hub-write.sh orch_ensure: fleet-orchestrator.sh ensure
    there), and orch_<session> is watched until it shows, at most
    FLEET_ORCH_BOOT_SECS (75 — an older node refuses the write, and its next
    home_watch tick, ≤ 60 s, opens it anyway). Returns (orchestrator, why)."""
    secs = float(os.environ.get("FLEET_ORCH_BOOT_SECS") or 75) if secs is None else secs
    try:
        ask = subprocess.Popen(["bash", str(BIN / "fleet-hub-write.sh"), "orch_ensure", "{}"],
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except OSError:
        ask = None
    why, said = "", 0.0
    deadline = time.monotonic() + secs
    while True:
        o = orchestrator(session)
        if o:
            break
        if time.monotonic() >= said:
            # re-said every 2 s for 2.5 s: gone within a moment of the switch
            shell.run("display-message", *(["-c", client] if client else []), "-d", "2500", tr("orch_booting"))
            said = time.monotonic() + 2
        if ask is not None and ask.poll() is not None:
            if ask.returncode:
                lines = (ask.stderr.read() or b"").decode("utf-8", "replace").strip().splitlines()
                why = lines[-1] if lines else ""
            ask = None
        if time.monotonic() >= deadline:
            break
        time.sleep(0.5)
    if ask is not None:
        ask.kill()
    return o, ("" if o else why or tr("orch_boot_waited", int(secs)))


def orch_agent(session, o):
    """The orchestrator's agent (claude · codex) — its row in the list's cache
    (remote_<session>, field 7: every orchestrator's row stays there), "" when
    the cache does not say."""
    try:
        with open(os.path.join(status_dir(), "remote_" + (session or "")), encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\x1f")
                if len(p) >= 7 and p[0] == "wid:" + o["wid"] and p[1] == o["node"]:
                    return p[6] if re.fullmatch(r"[a-z][a-z0-9-]{0,15}", p[6]) else ""
    except OSError:
        pass
    return ""


def stamp_role(shell, o, wait=3.0, agent=""):
    """The stage window carry() switched to is the orchestrator's (issue #2616):
    `@fleet_role orchestrator` on it, as the node's own window says — so the
    client tells it by its role, never its name. Only a window with no role.
    Its agent too (issue #2619 — `@cc_agent`, as the node's window says: a
    Codex orchestrator reads codex), when the list's cache names one."""
    want = o["node"] + ":" + o["wid"]
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        for line in shell.stage("list-windows", "-F", "#{window_id}\t#{@remote}\t#{@fleet_role}\t#{@cc_agent}").splitlines():
            w = (line.split("\t") + ["", "", ""])[:4]
            if w[1] == want:
                if not w[2]:
                    shell.stage("set-window-option", "-t", w[0], "@fleet_role", "orchestrator")
                if agent and w[3] != agent:
                    shell.stage("set-window-option", "-t", w[0], "@cc_agent", agent)
                return True
        time.sleep(0.1)
    return False


def go_back(shell, prev):
    """esc: the session that was in view — the list's own jump (`jump=<key>`),
    else the stage's window before this one."""
    if prev and prev.startswith(("@", "wid:")) and shell.hand("jump=" + prev):
        return
    subprocess.run(["tmux", "last-window"], stdin=subprocess.DEVNULL, capture_output=True)


# --- the text --------------------------------------------------------------------

def cells(text):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 0 if unicodedata.combining(c) else 1
               for c in text)


def wrap(line, width):
    """A logical line as screen rows of at most `width` cells: [(start, end)]."""
    out, start, used = [], 0, 0
    for i, c in enumerate(line):
        w = cells(c)
        if used + w > width and i > start:
            out.append((start, i))
            start, used = i, 0
        used += w
    out.append((start, len(line)))
    return out


class Editor:
    def __init__(self, text=""):
        self.lines = text.split("\n") if text else [""]
        self.row = len(self.lines) - 1
        self.col = len(self.lines[self.row])

    def text(self):
        return "\n".join(self.lines)

    def clear(self):
        self.lines, self.row, self.col = [""], 0, 0

    def insert(self, s):
        for part in re.split(r"(\n)", s.replace("\r\n", "\n").replace("\r", "\n")):
            if part == "\n":
                self.newline()
            elif part:
                line = self.lines[self.row]
                self.lines[self.row] = line[:self.col] + part + line[self.col:]
                self.col += len(part)

    def newline(self):
        line = self.lines[self.row]
        self.lines[self.row:self.row + 1] = [line[:self.col], line[self.col:]]
        self.row, self.col = self.row + 1, 0

    def backspace(self):
        if self.col:
            line = self.lines[self.row]
            self.lines[self.row] = line[:self.col - 1] + line[self.col:]
            self.col -= 1
        elif self.row:
            prev = self.lines[self.row - 1]
            self.lines[self.row - 1:self.row + 1] = [prev + self.lines[self.row]]
            self.row, self.col = self.row - 1, len(prev)

    def delete(self):
        line = self.lines[self.row]
        if self.col < len(line):
            self.lines[self.row] = line[:self.col] + line[self.col + 1:]
        elif self.row + 1 < len(self.lines):
            self.lines[self.row:self.row + 2] = [line + self.lines[self.row + 1]]

    def move(self, dr=0, dc=0):
        if dc:
            self.col += dc
            if self.col < 0 and self.row:
                self.row -= 1
                self.col = len(self.lines[self.row])
            elif self.col > len(self.lines[self.row]) and self.row + 1 < len(self.lines):
                self.row, self.col = self.row + 1, 0
            self.col = max(0, min(self.col, len(self.lines[self.row])))
        if dr:
            self.row = max(0, min(len(self.lines) - 1, self.row + dr))
            self.col = min(self.col, len(self.lines[self.row]))

    def kill_bol(self):
        self.lines[self.row] = self.lines[self.row][self.col:]
        self.col = 0

    def kill_eol(self):
        self.lines[self.row] = self.lines[self.row][:self.col]

    def kill_word(self):
        line = self.lines[self.row]
        i = self.col
        while i and line[i - 1] == " ":
            i -= 1
        while i and line[i - 1] != " ":
            i -= 1
        self.lines[self.row] = line[:i] + line[self.col:]
        self.col = i


# --- the screen ------------------------------------------------------------------

PAIR_BOX, PAIR_DIM, PAIR_ON, PAIR_GO, PAIR_TOAST = 1, 2, 3, 4, 5


def read_key(screen):
    """One key as ("text", s) | ("key", name): a CSI the terminal sent (⇧↵ as
    CSI-u, bracketed paste's markers) or ⌥↵ (ESC CR) read here, curses' own names
    for the rest. ("none", "") when nothing came."""
    k = screen.get_wch() if hasattr(screen, "get_wch") else screen.getch()
    if isinstance(k, int):
        if k == -1:
            return "none", ""
        names = {curses.KEY_BACKSPACE: "bs", curses.KEY_DC: "del", curses.KEY_LEFT: "left",
                 curses.KEY_RIGHT: "right", curses.KEY_UP: "up", curses.KEY_DOWN: "down",
                 curses.KEY_HOME: "home", curses.KEY_END: "end", curses.KEY_RESIZE: "resize",
                 curses.KEY_BTAB: "btab", curses.KEY_ENTER: "enter"}
        return "key", names.get(k, "")
    if k == "\x1b":
        screen.nodelay(True)
        seq = ""
        try:
            while len(seq) < 16:
                try:
                    c = screen.get_wch()
                except curses.error:
                    break
                if isinstance(c, int):
                    break
                seq += c
                if seq in ("\r", "\n") or (seq[:1] == "[" and len(seq) > 1 and seq[-1].isalpha() or seq[-1:] == "~"):
                    break
        finally:
            screen.nodelay(False)
        if seq in ("\r", "\n", "[13;2u", "[27;2;13~"):
            return "key", "newline"
        if seq == "[200~":
            return "key", "paste_on"
        if seq == "[201~":
            return "key", "paste_off"
        if seq == "[928~":
            return "key", "portal"   # ⌘N brought the area up (fleet-shell.sh portal)
        if seq == "":
            return "key", "esc"
        return "key", ""
    codes = {"\r": "enter", "\n": "newline", "\t": "tab", "\x7f": "bs", "\x08": "bs", "\x01": "home",
             "\x05": "end", "\x15": "kill_bol", "\x0b": "kill_eol", "\x17": "kill_word", "\x04": "del"}
    if k in codes:
        return "key", codes[k]
    if unicodedata.category(k) == "Cc":
        return "key", ""
    return "text", k


def state_path():
    """compose-state.json beside the draft: the repo the last send went to."""
    return state_dir() / "compose-state.json"


def last_repo():
    try:
        return json.loads(state_path().read_text(encoding="utf-8")).get("repo") or ""
    except (OSError, ValueError, AttributeError):
        return ""


def short(repo):
    return repo.rsplit("/", 1)[-1]


def repo_of_group(group, repos):
    """The heading the session in view sat under (its short name, as the list
    paints it) → that repo, when exactly one of `repos` answers to it."""
    hit = [r for r in repos if group and group in (r, short(r))]
    return hit[0] if len(hit) == 1 else ""


def repo_default(group, repos=None, last=None):
    """仓库's default (issue #2231): the repo of the session that was in view;
    else the one the last send went to; else the first the hub names. "" =
    this computer knows no repo (the list resolves it, #1938)."""
    repos = hub_repos() if repos is None else repos
    last = last_repo() if last is None else last
    if not repos:
        return last
    return repo_of_group(group, repos) or (last if last in repos else "") or repos[0]


def repo_menu(group, repos=None, last=None):
    """The 「仓库」 menu: (value, label, note, greyed) — every repo the hub says
    this person's machines host, then 无仓库 · HOME (value None)."""
    repos = hub_repos() if repos is None else repos
    last = last_repo() if last is None else last
    here = repo_of_group(group, repos or [])
    items = []
    if not repos:
        items.append(("", tr("compose_repo_auto"), "", False))
    for r in repos or []:
        note = tr("compose_repo_here") if r == here else tr("compose_repo_last") if r == last and not here else \
            r.split("/", 1)[0]
        items.append((r, short(r), note, False))
    items.append((None, tr("compose_repo_home"), tr("compose_repo_home_note"), False))
    return items


def node_menu():
    """The 「节点」 menu, off the hub's /v1/nodes as the refresh loop cached it
    (global/hub_nodes, the sidebar's 「开在哪」 too): (host, label, note, greyed)
    — the machines that can take a session, fewest running first (the first is
    what the hub's own placement picks), then the ones that cannot, greyed
    (只协调 · 维护中 · 失联). No machine known: 自动 alone (value "")."""
    try:
        with open(os.path.join(status_dir(), "hub_nodes"), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []
    can, cannot = [], []
    for line in lines:
        f = line.split("\x1f")
        if not f[0] or f[0].startswith("#") or len(f) < 6:
            continue
        f += [""] * (13 - len(f))
        label, av, sess, word, host = f[0], f[1], f[5], f[11], f[12] or f[0]
        if word in ("coord", "maint"):
            cannot.append((0 if word == "coord" else 1, (host, label, tr("compose_node_" + word), True)))
        elif av != "online":
            cannot.append((2, (host, label, tr("compose_node_lost"), True)))
        else:
            n = int(sess) if sess.isdigit() else 1 << 30   # `?`: unknown, last
            can.append((n, sess, host, label))
    can.sort(key=lambda c: c[0])
    can = [(host, label, tr("compose_node_rec_fmt" if i == 0 else "compose_node_running_fmt", sess), False)
           for i, (_, sess, host, label) in enumerate(can)] or [("", tr("compose_node_auto"), "", False)]
    return can + [item for _, item in sorted(cannot, key=lambda c: c[0])]


AGENTS = ("claude", "codex")


def agent_default():
    agent = os.environ.get("FLEET_AGENT") or "claude"
    return agent if agent in AGENTS else "claude"


def agent_menu():
    dflt = agent_default()
    return [(a, a, tr("compose_agent_default") if a == dflt else "", False) for a in AGENTS]


OPTIONS = ("repo", "node", "agent")


def menu_for(kind, group):
    return {"repo": lambda: repo_menu(group), "node": node_menu, "agent": agent_menu}[kind]()


def defaults(group):
    """The three options as ⌘N shows them (issue #2231): 仓库 — the repo of the
    session in view, else the last send's; 节点 — the machine the hub picks by
    load; Agent — FLEET_AGENT. A change made by hand is for this send only."""
    return {"repo": repo_default(group), "node": node_menu()[0][0], "agent": agent_default()}


def pick_label(kind, value, group):
    for v, label, _, _ in menu_for(kind, group):
        if v == value:
            return label
    return tr("compose_node_auto") if kind == "node" else (value or tr("compose_repo_auto"))


def ui(screen, session):
    os.write(1, b"\x1b[?2004h")   # bracketed paste: a drop is one insert, never a send
    try:
        curses.curs_set(1)
    except curses.error:
        pass
    curses.use_default_colors()
    curses.raw()
    curses.nonl()               # ↵ is CR (send), ⌃j / ⇧↵ is LF (a new line)
    for number, fg in ((PAIR_BOX, curses.COLOR_BLUE), (PAIR_DIM, 8 if curses.COLORS > 8 else curses.COLOR_WHITE),
                       (PAIR_ON, curses.COLOR_BLACK), (PAIR_GO, curses.COLOR_BLUE),
                       (PAIR_TOAST, curses.COLOR_YELLOW)):
        try:
            curses.init_pair(number, fg, curses.COLOR_BLUE if number == PAIR_ON else -1)
        except curses.error:
            pass
    screen.keypad(True)
    shell = Shell(session)
    try:
        draft = draft_path().read_text(encoding="utf-8")
    except OSError:
        draft = ""
    ed = Editor(draft)
    focus, pasting = "body", False
    menu, menu_at = None, 0            # the open option's menu: menu_for() rows
    saved_text, saved_at, dirty_at = draft, (time.strftime("%H:%M") if draft else ""), None
    toast = ""
    sending = None                     # the send in flight (issue #2240): {id, text, at}
    prev, group = previous()
    pick, touched = defaults(group), set()

    def fresh():
        """Back to the defaults (⌘N, esc, a send): what was in view now."""
        nonlocal prev, group, pick, touched, menu, focus
        prev, group = previous()
        pick, touched, menu, focus = defaults(group), set(), None, "body"

    def save(force=False):
        nonlocal saved_text, saved_at, dirty_at
        text = ed.text()
        if text == saved_text:
            dirty_at = None
            return
        if not force and dirty_at is not None and time.monotonic() - dirty_at < SAVE_EVERY:
            return
        if text.strip():
            write_atomic(draft_path(), text)
        else:
            try:
                draft_path().unlink()
            except OSError:
                pass
        saved_text, saved_at, dirty_at = text, time.strftime("%H:%M") if text.strip() else "", None

    def hangup(signum, frame):
        # a respawn (the shell's portal / reload on a new client, issue #2113)
        # or a closed window: what was typed since the last beat goes to disk first
        try:
            save(force=True)
        finally:
            raise SystemExit(0)

    for sig in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, hangup)

    def told():
        """The send in flight, ended? Done: the box empties and the options go
        back to their defaults. Anything else: the text stays as it was written
        and the toast says why and what next, until the next key (issue #2240)."""
        nonlocal sending, toast
        data = read_told()
        if data is not None and data.get("id") == sending["id"]:
            try:
                result_path().unlink()
            except OSError:
                pass
            if data.get("ok"):
                if ed.text() == sending["text"]:
                    ed.clear()
                    save(force=True)
                fresh()
                toast = ""
            else:
                toast = tr("compose_failed_fmt", data.get("why") or tr("compose_failed_unknown"))
            sending = None
        elif time.monotonic() - sending["at"] >= TOLD_WAIT:
            toast = tr("compose_failed_fmt", tr("compose_failed_silent"))
            sending = None

    def put(y, x, text, attr=0):
        h, w = screen.getmaxyx()
        if 0 <= y < h and x < w - 1:
            try:
                screen.addstr(y, x, clip(text, w - 1 - x), attr)
            except curses.error:
                pass

    def open_menu(kind):
        nonlocal menu, menu_at, focus
        focus, menu = kind, menu_for(kind, group)
        menu_at = next((n for n, m in enumerate(menu) if m[0] == pick[kind]), 0)

    def step(d):
        nonlocal menu_at
        for _ in menu:
            menu_at = (menu_at + d) % len(menu)
            if not menu[menu_at][3]:
                return

    while True:
        h, w = screen.getmaxyx()
        screen.erase()
        x0, bw = 3, max(10, w - 7)
        dim = curses.color_pair(PAIR_DIM)
        put(1, x0, tr("compose_head"), curses.A_BOLD)
        if saved_at and ed.text().strip():
            note = tr("compose_saved_fmt", saved_at)
            put(1, max(x0, x0 + bw - cells(note)), note, dim)
        inner = bw - 4
        rows = []
        for i, line in enumerate(ed.lines):
            for s, e in wrap(line, inner):
                rows.append((i, s, e))
        box_h = max(6, min(len(rows), max(6, h - 10)))
        cur = next((n for n, (i, s, e) in enumerate(rows)
                    if i == ed.row and s <= ed.col <= e and (ed.col < e or e == len(ed.lines[i]) or
                                                              n + 1 == len(rows) or rows[n + 1][0] != i)), 0)
        top = max(0, cur - box_h + 1)
        put(2, x0, "╭" + "─" * (bw - 2) + "╮", curses.color_pair(PAIR_BOX))
        for y in range(box_h):
            put(3 + y, x0, "│", curses.color_pair(PAIR_BOX))
            put(3 + y, x0 + bw - 1, "│", curses.color_pair(PAIR_BOX))
            n = top + y
            if n < len(rows):
                i, s, e = rows[n]
                put(3 + y, x0 + 2, ed.lines[i][s:e])
        if not ed.text():
            put(3, x0 + 3, tr("compose_placeholder"), dim)
        put(3 + box_h, x0, "╰" + "─" * (bw - 2) + "╯", curses.color_pair(PAIR_BOX))
        y = 4 + box_h
        files = attachments(ed.text())
        if files:
            put(y, x0 + 2, tr("compose_attach") + " ", dim)
            put(y, x0 + 3 + cells(tr("compose_attach")),
                ", ".join(os.path.basename(f) + (tr("compose_attach_big") if too_big(f) else "") for f in files))
            y += 1
        # the three options (issue #2231): picked already, ↵ sends as they are
        x, at_x = x0 + 2, {}
        for kind in OPTIONS:
            put(y, x, tr("compose_" + kind) + " ", dim)
            x += cells(tr("compose_" + kind)) + 1
            field = " " + pick_label(kind, pick[kind], group) + " ▾ "
            put(y, x, field, curses.color_pair(PAIR_ON) | curses.A_BOLD if focus == kind else curses.A_BOLD)
            at_x[kind] = x
            x += cells(field) + 3
        go = tr("compose_go_issue")
        put(y, max(x, x0 + bw - cells(go)), go, curses.color_pair(PAIR_GO) | curses.A_BOLD)
        put(y + 3 + len(menu) if menu else y + 1, x0 + 2, tr("compose_menu_keys") if menu else tr("compose_keys"), dim)
        if toast and not menu:
            put(y + 2, x0 + 2, toast, curses.color_pair(PAIR_TOAST))
        if menu:
            # the open option's menu, a box under its field
            mx = at_x[focus]
            lw = max(cells(m[1]) for m in menu) + 4
            mw = min(bw - (mx - x0), max(lw + 3 + max(cells(m[2]) for m in menu) + 3, 24))
            put(y + 1, mx, "╭" + "─" * (mw - 2) + "╮", curses.color_pair(PAIR_BOX))
            for n, (value, label, note, grey) in enumerate(menu):
                row = ("› " if n == menu_at else "  ") + ("✓ " if value == pick[focus] else "  ") + label
                line = row + " " * max(1, lw + 2 - cells(row)) + note
                put(y + 2 + n, mx, "│" + " " * (mw - 2) + "│", curses.color_pair(PAIR_BOX))
                put(y + 2 + n, mx + 1, clip(line, mw - 2),
                    curses.color_pair(PAIR_ON) | curses.A_BOLD if n == menu_at else dim if grey else 0)
            put(y + 2 + len(menu), mx, "╰" + "─" * (mw - 2) + "╯", curses.color_pair(PAIR_BOX))
        # the cursor: in the box on the body, on the option in focus otherwise
        if focus == "body":
            i, s, e = rows[cur] if rows else (0, 0, 0)
            cy, cx = 3 + cur - top, x0 + 2 + cells(ed.lines[i][s:ed.col])
        elif menu:
            cy, cx = y + 2 + menu_at, at_x[focus] + 1
        else:
            cy, cx = y, at_x[focus] + 1
        try:
            screen.move(min(cy, h - 1), min(cx, w - 2))
        except curses.error:
            pass
        screen.refresh()

        # a beat while typing: the draft; while a send is in flight: its answer
        screen.timeout(int(TOLD_EVERY * 1000) if sending is not None else
                       int(SAVE_EVERY * 1000) if dirty_at is not None else -1)
        try:
            kind, k = read_key(screen)
        except curses.error:
            kind, k = "none", ""
        except KeyboardInterrupt:
            kind, k = "key", "esc"
        if kind != "none" and k != "resize" and sending is None:
            toast = ""         # a failure's words stay until the next key (issue #2240)
        if sending is not None:
            told()
        if kind == "none":
            save(force=True)   # idle a beat: the draft is on disk
            continue
        if k == "portal":
            fresh()            # ⌘N: the defaults for what was in view now
            toast = ""
            continue
        if menu is not None:
            # the open menu has the keys
            if k in ("up", "down"):
                step(1 if k == "down" else -1)
            elif k == "enter" or (kind == "text" and k == " "):
                if not menu[menu_at][3]:
                    pick[focus] = menu[menu_at][0]
                    touched.add(focus)
                    menu = None
            elif k in ("esc", "tab", "btab"):
                menu = None
            continue
        if kind == "text":
            if focus != "body" and k == " " and not pasting:
                open_menu(focus)
                continue
            focus = "body"
            ed.insert(k)
            toast = ""
        elif k == "paste_on":
            pasting, focus = True, "body"
        elif k == "paste_off":
            pasting = False
        elif k in ("newline",) or (k == "enter" and pasting):
            focus = "body"
            ed.newline()
        elif k in ("enter", "down") and focus != "body":
            open_menu(focus)
        elif k == "enter":
            # what was not changed by hand travels as «the default» (null): the
            # hub picks the machine, the fleet its agent (共同约定 1)
            data = payload(ed.text(), prev, pick["repo"],
                           pick["node"] if "node" in touched else None,
                           pick["agent"] if "agent" in touched else None)
            if not data:
                toast = tr("compose_empty")
                continue
            if sending is not None:
                toast = tr("compose_sent_fmt", sending["title"])   # one send at a time
                continue
            if not write_atomic(send_path(), json.dumps(data, ensure_ascii=False) + "\n"):
                toast = "✗ " + str(send_path())
                continue
            if data["repo"]:
                write_atomic(state_path(), json.dumps({"repo": data["repo"]}) + "\n")
            # The box empties only once the machine said done (issue #2240): until
            # then the text stays, and a send that does not open says why, here.
            save(force=True)
            try:
                result_path().unlink()
            except OSError:
                pass
            if shell.hand("compose"):
                toast = tr("compose_sent_fmt", data["title"])
                sending = {"id": data["id"], "text": ed.text(), "title": data["title"], "at": time.monotonic()}
            else:
                out = subprocess.run([sys.executable, str(Path(__file__).absolute()), "--send", str(send_path())],
                                     stdin=subprocess.DEVNULL, capture_output=True, text=True)
                if out.returncode == 0:
                    toast = tr("compose_result_fmt", place_why(out.stdout or out.stderr))
                    ed.clear()
                    save(force=True)
                    fresh()
                else:
                    keep_failed(send_path())
                    toast = tr("compose_failed_fmt", place_why((out.stdout or "") + "\n" + (out.stderr or ""))
                               or tr("compose_failed_unknown"))
        elif k == "tab" or k == "btab":
            ring = ["body"] + list(OPTIONS)
            at = ring.index(focus) if focus in ring else 0
            focus = ring[(at + (1 if k == "tab" else -1)) % len(ring)]
        elif k == "esc":
            save(force=True)
            go_back(shell, prev)
            fresh()
            continue
        elif k == "resize":
            continue
        elif focus == "body":
            {"bs": ed.backspace, "del": ed.delete, "left": lambda: ed.move(dc=-1),
             "right": lambda: ed.move(dc=1), "up": lambda: ed.move(dr=-1), "down": lambda: ed.move(dr=1),
             "home": lambda: setattr(ed, "col", 0), "end": lambda: setattr(ed, "col", len(ed.lines[ed.row])),
             "kill_bol": ed.kill_bol, "kill_eol": ed.kill_eol, "kill_word": ed.kill_word}.get(k, lambda: None)()
        if dirty_at is None and ed.text() != saved_text:
            dirty_at = time.monotonic()


def clip(text, width):
    out, used = [], 0
    for c in text:
        w = cells(c)
        if used + w > width:
            break
        out.append(c)
        used += w
    return "".join(out)


def main(argv):
    global TEXT
    TEXT = load_text()
    if argv[:1] in (["--send"], ["payload"]) and len(argv) >= 2:
        opts = {"--repo": "", "--node": "", "--agent": "", "--reap": ""}
        mode, chosen = "", 0
        rest = argv[2:]
        while rest:
            if rest[0] in opts and len(rest) >= 2:
                chosen += rest[0] == "--repo"
                opts[rest[0]] = rest[1]
                rest = rest[2:]
            elif rest[0] in ("--no-repo", "--multi"):   # --multi: an older list's word for it  # compat-1v: 下一批删
                mode = "none"
                chosen += 1
                rest = rest[1:]
            else:
                print("fleet-compose: unknown argument %s" % rest[0], file=sys.stderr)
                return 2
        if chosen > 1:
            print("fleet-compose: --repo and --no-repo are one choice", file=sys.stderr)
            return 2
        if argv[0] == "payload":
            text = Path(argv[1]).read_text(encoding="utf-8")
            data = payload(text, repo=None if mode else opts["--repo"],
                           node=None if opts["--node"] in ("", "auto") else opts["--node"], agent=opts["--agent"])
            print(json.dumps(data, ensure_ascii=False, sort_keys=True))
            return 0
        return send(argv[1], opts["--repo"], opts["--node"], opts["--reap"], mode, opts["--agent"])
    boot = argv[-1:] == ["--boot"]
    if boot:
        argv = argv[:-1]
    if argv[:1] == ["--orch"] and len(argv) in (2, 4) and (len(argv) == 2 or argv[2] == "--client"):
        return to_orch(argv[1], argv[3] if len(argv) == 4 else "", boot=boot)
    if argv[:1] == ["--steward"] and len(argv) in (2, 4) and (len(argv) == 2 or argv[2] == "--client"):
        return to_steward(argv[1], argv[3] if len(argv) == 4 else "")
    session = ""
    if argv[:1] == ["--session"] and len(argv) >= 2:
        session = argv[1]
    elif argv:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    os.environ.setdefault("ESCDELAY", "25")
    curses.wrapper(ui, session)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
