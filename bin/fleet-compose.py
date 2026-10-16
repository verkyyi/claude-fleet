#!/usr/bin/env python3
"""fleet-compose.py — a new task's payload and the ONE way it goes out (issue #1953,
EPIC #1949 C4; one box and three options since issue #2231, EPIC #2230 C1).

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
    fleet-compose.py payload <text-file> [--repo R | --no-repo] [--node N] [--agent A]
                                          the payload a ↵ on that text would write
                                          ({title, body, attachments, repo, node,
                                          agent}), as JSON — the selftest's view

Who writes the payload: a thin client's 派一件事 (fleet-quick-dispatch.py, the 看台's
⌘P ⚡ row) and an old session's /qd. The old client's writing area (⌘N, the
`--session` curses box, its draft and its told-file) went with that client
(issue #3008). The payload sits beside the switch state
($XDG_STATE_HOME/claude-fleet/compose-send.json; FLEET_SWITCH_STATE overrides the
directory); a send that did not open keeps it as compose-failed.json. Nothing on
the way spends a token: the issue is filed by fleet-issue-file.sh on the machine,
the worker opened by its spawn.
"""
import json
import os
import re
import socket
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


def state_dir():
    env = os.environ.get("FLEET_SWITCH_STATE")
    if env:
        return Path(env)
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return Path(base) / "claude-fleet"


def send_path():
    return state_dir() / "compose-send.json"


def failed_path():
    """compose-failed.json: the payload of the last send that did not open
    (issue #2240) — kept, never unlinked, so nothing written is lost."""
    return state_dir() / "compose-failed.json"


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


def send(path, repo="", node="", reap="", mode="", agent="", *, stdout=None, stderr=None):
    """The way out (`--send`): the payload to fleet-client-place.sh. Prints its
    line, returns its code. 2 = nothing to send / no repo to send it to. `mode`
    none (--no-repo) beats the payload's repo; a named --repo beats both. The
    machine and the agent (issue #2232, EPIC #2230 共同约定 1): a named --node /
    --agent, else the payload's `node` / `agent`; null or absent = auto / the
    fleet's default (no --agent at all). The text always travels (issue #2231:
    a send never drops what was written)."""
    errors = sys.stderr if stderr is None else stderr
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print("fleet-compose: cannot read %s: %s" % (path, error), file=errors)
        return 2
    title = data.get("title") or ""
    node = node or data.get("node") or "auto"
    agent = agent or data.get("agent") or ""
    if agent not in ("claude", "codex", ""):
        print("fleet-compose: agent is claude or codex, not %s" % agent, file=errors)
        return 2
    if not title:
        print("fleet-compose: the payload has no title", file=errors)
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
            print("fleet-compose: name the repo (owner/name) — none to go on", file=errors)
            return 2
    cid = data.get("id") or "%x" % time.time_ns()
    at = int(data.get("at") or time.time())
    t_enter = int(data.get("t_enter") or at * 1000)
    compose_log("sent", id=cid, how=send_how(data, "none" if norepo else ""), repo="" if norepo else repo, at=at,
                t_enter=t_enter)
    args = ["bash", str(BIN / "fleet-client-place.sh"), "-" if norepo else repo]
    draft = data.get("draft")
    if draft is not None and (not isinstance(draft, str) or not draft.strip() or len(draft) > MAX_BODY
                              or data.get("body") or data.get("attachments")):
        print("fleet-compose: draft must be 1-4000 characters without a submitted body or attachments", file=errors)
        return 2
    text = draft if draft is not None else data.get("body") or ""
    if draft is None and not norepo and data.get("issue", True):
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
        args += ["--draft-file" if draft is not None else "--body-file", bodyf]
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
    if draft is None and data.get("via") == "dispatch" and (norepo or data.get("issue", True)):
        # ⌘P's words (issue #3325): a person's task — the hub writes its record
        # T<n> first; a repo's is still a new issue, one with no repo the record
        # alone. No hub (or an older one) opens it as before.
        args += ["--task", "--via", "⌘P"]
    # The node's timing points come back through a file (issue #2238): the
    # place's stdout stays its one line.
    fd, timef = tempfile.mkstemp(prefix="fleet-compose-timing.", dir=str(Path(path).parent))
    os.close(fd)
    # …and the session it opened (issue #2236): a warm start's window and key.
    fd, resf = tempfile.mkstemp(prefix="fleet-compose-result.", dir=str(Path(path).parent))
    os.close(fd)
    env = dict(os.environ, FLEET_PLACE_TIMING=timef, FLEET_PLACE_RESULT=resf)
    try:
        out = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=stderr, text=True, env=env)
        timing = read_timing(timef)
        opened = read_opened(resf)
    finally:
        for f in (bodyf, timef, resf):
            if f:
                try:
                    os.unlink(f)
                except OSError:
                    pass
    (sys.stdout if stdout is None else stdout).write(out.stdout)
    # the issue a `new` filed (issue #2753 — ⌘T's 「已建 #N 并开工」), on stderr:
    # stdout stays the place's one line
    num = re.search(r"/issues/(\d+)|^#?(\d+)$|^issue-(\d+)$", opened.get("filed") or "") or \
        re.search(r"(?:^|:)issue-(\d+)$", opened.get("key") or "")
    if out.returncode == 0 and num:
        print("filed: #%s" % next(g for g in num.groups() if g), file=errors)
    # …and the window it opened on THIS machine (issue #3097 — a 看台's ⌘T goes to it)
    if out.returncode == 0 and re.fullmatch(r"@\d+", opened.get("window_id") or "") \
            and opened.get("machine") == socket.gethostname().split(".")[0]:
        print("window: %s" % opened["window_id"], file=errors)
    line = next((l for l in reversed(out.stdout.splitlines()) if l.split(" ", 1)[0] in PLACE_WORDS), "")
    words = line.partition("\t")[0].split()
    remote = words[:1] == ["REMOTE"]
    compose_log("placed", id=cid, rc=out.returncode, result=words[0] if words else "",
                machine=words[1] if len(words) > 1 else "",
                session=words[4] if remote and len(words) > 4 and "/" in words[4] else "",
                op=words[2] if remote and len(words) > 2 else "",
                secs=max(0, int(time.time()) - at),
                t_accepted=timing.get("t_accepted"), timing=timing or None,
                key=opened.get("key"), window=opened.get("window_id"), filed=opened.get("filed"),
                **({"task": opened["task"]} if opened.get("task") else {}))
    return out.returncode


# --- the text --------------------------------------------------------------------


# --- the screen ------------------------------------------------------------------

PAIR_BOX, PAIR_DIM, PAIR_ON, PAIR_GO, PAIR_TOAST = 1, 2, 3, 4, 5


def state_path():
    """compose-state.json beside the draft: the repo the last send went to."""
    return state_dir() / "compose-state.json"


def last_repo():
    try:
        return json.loads(state_path().read_text(encoding="utf-8")).get("repo") or ""
    except (OSError, ValueError, AttributeError):
        return ""


def main(argv):
    global TEXT
    if argv[:1] != ["--send"]:
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
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
