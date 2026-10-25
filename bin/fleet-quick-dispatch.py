#!/usr/bin/env python3
"""fleet-quick-dispatch.py — 派一件事 (issue #2753). One line, ↵, and a worker is on
it — from any window of a thin client's 看台: a worker's, a no-repo session's
(Claude or Codex), a bare shell, a session on another machine.

    fleet-quick-dispatch.py --view V [--client C]
                                          the popup in a thin client's 看台, on its
                                          home machine (issue #3004, EPIC #2999 C7) —
                                          no key opens it since issue #3328: ⌘P's ⚡
                                          row runs `send` / `grid` / `pick` (the old
                                          client's own ⌘T popup went with it, #3008)
    fleet-quick-dispatch.py payload --title T [--repo R] [--codex | --agent A]
                                          the payload a ↵ would write, as JSON
                                          (the selftest's view)
    fleet-quick-dispatch.py send --title T [--repo R] [--codex | --agent A] [--view V]
                                          the ↵ without the screen: write it, hand
                                          it on; prints 「已发出：…」 or why not
                                          (⌘P's 「新任务」 row, issue #3180, sends
                                          through it — no second dialog)
    fleet-quick-dispatch.py send --blank --repo R [--agent A] [--view V]
                                          a BLANK session of R under hub authority
                                          (T652, EPIC T651 C1): its record opens on
                                          the placeholder 「新会话」 with no first
                                          turn; the first prompt renames both, once
    fleet-quick-dispatch.py pick          the repo ⌘P's 「新任务」 sends to: line 1
                                          the pick (empty = ask), then every repo
    fleet-quick-dispatch.py grid [--view V] [--repo R]
                                          the 「新会话」 box's two values (issue #3327,
                                          T670), one JSON line: repos · last (the box's
                                          repo: R — the session in view's — else the
                                          last new session's, defaults()) · agent (the
                                          fleet's default) · agents {repo: its last
                                          agent, else the default} · missing {agent:
                                          why} — not installed here, or 「管理员暂未开放」
                                          (the hub's allowlists, issue #3826)
    fleet-quick-dispatch.py remember --repo R [--agent A]
                                          a new session opened on R ("" = none) with
                                          A: the next box's defaults (compose-state.json)
    fleet-quick-dispatch.py authority --repo R [--view V]
                                          the task authority a start of R meets:
                                          hub · legacy · frozen, or an empty line
                                          (issue #4965 — ⌘P's ⚡ row asks it)
    fleet-quick-dispatch.py agent [--view V]
                                          the agent ⌘N opens with: {agent, why} —
                                          the default, else the one usable agent
    … send … --toast                      the outcome also goes on the client as a
                                          message (⌘P's ⚡ runs send detached: esc
                                          closes the panel, the send still says how
                                          it ended)

The popup: 标题 (one line), 仓库 (every repo the hub says this person's machines
host — the one the last send went to first; ←→ picks, shown only when there is
more than one) and 用哪个 Coding Agent (issue #1834: ←→ / ⌃X picks; the default
is the fleet's effective FLEET_AGENT — fleet_load_conf's, the one
resolution — and ↵ on it sends with no --agent at all; another one rides the
send as `--agent` for this one session only). In a 看台 (--view) the session
opens on this machine, so an agent it has not installed is grey with why
(「mac-b 这台没装 codex」) and cannot be picked. ↵ sends, esc closes, Tab walks.

There is no second road (EPIC #2230 共同约定 1, issue #2618's rule): a ↵ writes
the payload fleet-compose.py payload() makes — its compose-send.json, its
compose-state.json for 「上次用的仓库」 — and calls fleet-compose.py's send() →
fleet-client-place.sh <repo> new (the machine that takes it opens the session
bound to the hub's task record; with no lease it opens through this machine's own
adapter), and the result goes on the 看台's client as a
message. Nothing on the way calls a model or waits behind another session's
turn.

FLEET_DISPATCH_SEND_CMD (tests): replaces `fleet-compose.py --send <payload>`.
FLEET_DISPATCH_GO_CMD (tests): replaces `fleet-view-go.sh` — a 看台's send that
opened a window here goes to it (`window: @N` from fleet-compose.py --send).
FLEET_DISPATCH_AGENTS_HERE (tests): the agents installed here, comma-separated,
in place of looking (FLEET_CLAUDE_BIN / PATH / FLEET_TOOL_DIRS, fleet_find_tool's rule).

Under hub authority (issue #4965, #4830 step 6) a repo's start needs an accepted
launch, which only the record-first road makes: a send that names a repo goes
through `fleet-task-record.sh dispatch --repo R --spawn` instead — the hub writes
T<n>, the session opens on this machine bound to it (the top bar shows T<n>), and
the words are its first turn (a hub task has no unsubmitted draft). A repo this
machine does not host is said, never tried here. Legacy authority: as above.
FLEET_DISPATCH_AUTHORITY_CMD (tests): prints the authority mode for <repo> <fleet>.
FLEET_DISPATCH_HOSTED (tests): the repos this machine hosts, comma-separated.
FLEET_DISPATCH_TASK_CMD (tests): replaces `fleet-task-record.sh`.
"""
import curses
import importlib.util
import json
import locale
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path

BIN = Path(__file__).absolute().parent


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, str(BIN / file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


compose = _load("fleet_compose", "fleet-compose.py")
quick = _load("fleet_quickopen", "fleet-quickopen.py")

TEXT = {}


def tr(key, *args):
    text = TEXT.get(key, key)
    for arg in args:
        text = text.replace("\x01", str(arg), 1)
    return text.replace("\x01", "")


def load_text():
    try:
        out = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "dispatch_", "compose_"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        out = b""
    parts = out.decode("utf-8", "replace").split("\0")
    return dict(zip(parts[0::2], parts[1::2]))


def repos():
    return compose.hub_repos() or []


def repo_default(have=None, last=None):
    """The repo a ↵ goes to untouched: the one the last send went to (this
    popup's or the writing area's — one compose-state.json), else the first."""
    have = repos() if have is None else have
    last = compose.last_repo() if last is None else last
    if not have:
        return last
    return last if last in have else have[0]


def repo_pick(have=None, last=None):
    """⌘P's 「新任务」 (issue #3180): the last send's repo when the hub still names
    it, the only one when there is one, else '' — the panel asks 「派到哪个仓库」
    rather than guess the first of several."""
    have = repos() if have is None else have
    last = compose.last_repo() if last is None else last
    if last and (last in have or not have):
        return last
    return have[0] if len(have) == 1 else ""


AGENTS = ("claude", "codex")


def state_read():
    """compose-state.json as a dict: `repo` the last new session's ("" = 不绑仓库,
    a choice too — T670, EPIC T651 C2), `agent_by_repo` {repo or "": agent}."""
    try:
        got = json.loads(compose.state_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return got if isinstance(got, dict) else {}


def remember(repo, agent=None):
    """A new session opened on `repo` ("" = none) with `agent` (None = leave the
    repo's agent as it was): the next box's defaults (compose-state.json, the one
    file — the writing area's 「上次用的仓库」 too)."""
    st = state_read()
    st["repo"] = repo or ""
    by = st.get("agent_by_repo") if isinstance(st.get("agent_by_repo"), dict) else {}
    if agent in AGENTS:
        by[repo or ""] = agent
    st["agent_by_repo"] = by
    return compose.write_atomic(compose.state_path(), json.dumps(st, ensure_ascii=False) + "\n")


def repo_of(name, have):
    """`name` (owner/name, or a bare name) as one of `have`; "" when it is none."""
    name = (name or "").strip()
    if not name:
        return ""
    low = {r.lower(): r for r in have}
    if name.lower() in low:
        return low[name.lower()]
    if "/" in name:
        return name if not have else ""
    hits = [r for r in have if r.rpartition("/")[2].lower() == name.lower()]
    return hits[0] if len(hits) == 1 else ""


def defaults(view_repo="", have=None, state=None, fleet_agent=None, missing=None):
    """The 「新会话」 box's two values (T670, EPIC T651 C2 — 约定 2, the one reader):
    (repo, agent). Repo: the session in view's, when it has one the hub names →
    the last new session's (不绑仓库 counts) while still named → the only one →
    不绑仓库. Agent: that repo's last → the fleet's default (FLEET_AGENT) → the
    first usable one."""
    have = repos() if have is None else have
    st = state_read() if state is None else state
    repo = repo_of(view_repo, have)
    if not repo:
        last = st.get("repo")
        if isinstance(last, str) and (last == "" or last in have or not have):
            repo = last
        elif len(have) == 1:
            repo = have[0]
    return repo, agent_for(repo, st, fleet_agent, missing)


def agent_for(repo, state, fleet_agent=None, missing=None):
    """`repo`'s default agent: the one it last opened with, else the fleet's,
    else the first usable."""
    missing = missing or {}
    usable = [a for a in AGENTS if a not in missing]
    by = state.get("agent_by_repo") if isinstance(state.get("agent_by_repo"), dict) else {}
    for a in (by.get(repo or ""), fleet_agent if fleet_agent is not None else agent_default()):
        if a in usable:
            return a
    return usable[0] if usable else (fleet_agent or "claude")


def agent_default(session=""):
    """The fleet's effective agent — FLEET_AGENT as fleet_load_conf resolves it
    for the session (the current one when none is named), the one resolution
    every spawn path walks."""
    env = dict(os.environ, **({"FLEET_SESSION": session} if session else {}))
    script = ('[ -f "$1/../fleet.conf" ] && . "$1/../fleet.conf"; . "$1/fleet-lib.sh"; '
              's="${FLEET_SESSION:-}"; [ -n "$s" ] || s=$(fleet_current_session 2>/dev/null); '
              '[ -n "$s" ] && fleet_load_conf "$s"; printf "%s" "${FLEET_AGENT:-claude}"')
    try:
        out = subprocess.run(["bash", "-c", script, "_", str(BIN)], env=env, stdin=subprocess.DEVNULL,
                             capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        out = ""
    return out if out in AGENTS else "claude"


def agent_here(agent):
    """Is `agent` installed on this machine (fleet_find_tool's rule)?"""
    seam = os.environ.get("FLEET_DISPATCH_AGENTS_HERE")
    if seam is not None:
        return agent in seam.split(",")
    pin = os.environ.get("FLEET_CLAUDE_BIN") if agent == "claude" else ""
    if pin and os.access(pin, os.X_OK):
        return True
    if shutil.which(agent):
        return True
    dirs = (os.environ.get("FLEET_TOOL_DIRS") or "%s/.local/bin /opt/homebrew/bin /usr/local/bin"
            % os.path.expanduser("~")).split()
    return any(os.access(os.path.join(d, agent), os.X_OK) for d in dirs)


def agent_blocked():
    """{agent: reason} the hub's subscription allowlists leave nothing for on this
    login (issue #3826, fleet_agent_allow.py); {} when it cannot tell."""
    try:
        sys.path.insert(0, str(BIN))
        import fleet_agent_allow
        return fleet_agent_allow.blocked()
    except Exception:       # a picker never breaks on the check: unknown = usable
        return {}


def agent_missing(view):
    """{agent: why} of the agents a ↵ cannot use: in a 看台, the ones this machine
    lacks, then the ones the admin has not opened to this person (issue #3826 —
    「管理员暂未开放」, grey, never hidden); the old client cannot know the
    machine, so none."""
    if not view:
        return {}
    host = socket.gethostname().split(".")[0]
    out = {a: tr("dispatch_agent_missing_fmt", host, a) for a in AGENTS if not agent_here(a)}
    for a in agent_blocked():
        out.setdefault(a, tr("dispatch_agent_blocked_fmt", a.capitalize()))
    return out


def agent_pick(view, session=""):
    """The agent a new session with nothing chosen opens with, and why it is not the
    default ("" when it is): the fleet's default while usable, else the first usable
    one (⌘N, issue #3826 — a Codex-only person gets Codex, told so)."""
    dflt = agent_default(fleet_of(view) if view else session)
    missing = agent_missing(view)
    usable = [a for a in AGENTS if a not in missing]
    if dflt in usable or not usable:
        return dflt, ""
    return usable[0], missing.get(dflt, "")


def payload(title, repo, codex=False, agent=None):
    """The writing area's payload for one line (fleet-compose.py payload), marked
    `via: dispatch` so the list says the number it filed. {} = nothing to send.
    `agent` None = the fleet's default (no --agent on the way)."""
    data = compose.payload(title, "", repo, None, agent or ("codex" if codex else None))
    if data:
        data["via"] = "dispatch"
    return data


def authority(repo, fleet=""):
    """The person's task authority for a start of `repo` — hub · legacy · frozen —
    as the spawners' gate asks it (fleet_repo_authority_guard --gate); "" when no
    hub is on for it, or the hub did not say."""
    seen = (os.environ.get("FLEET_AUTHORITY_SEEN") or "").split()
    try:   # the 看台 asked a moment ago (T716): asked once a start
        fresh = float(os.environ.get("FLEET_AUTHORITY_FRESH_SECS") or 30)
        if len(seen) == 2 and seen[0] in ("hub", "legacy") and 0 <= time.time() - float(seen[1]) < fresh:
            return seen[0]
    except ValueError:
        pass
    seam = os.environ.get("FLEET_DISPATCH_AUTHORITY_CMD")
    if seam:
        argv = seam.split() + [repo, fleet]
    else:
        script = ('[ -f "$1/../fleet.conf" ] && . "$1/../fleet.conf"; . "$1/fleet-lib.sh"; '
                  's="$2"; [ -n "$s" ] || s=$(fleet_current_session 2>/dev/null); '
                  '[ -n "$s" ] && fleet_load_conf "$s"; fleet_repo_authority_guard "$3" --gate "$s"')
        argv = ["bash", "-c", script, "_", str(BIN), fleet, repo]
    try:
        out = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    line = (out.strip().splitlines() or [""])[-1].strip()
    if line in ("hub", "legacy", "frozen"):
        return line
    try:
        mode = json.loads(line).get("mode") or ""
    except (ValueError, AttributeError):
        return ""
    return mode if mode in ("hub", "legacy", "frozen") else ""


def hosted(fleet=""):
    """The repos this machine's fleet hosts (fleet_repos), lower-cased."""
    seam = os.environ.get("FLEET_DISPATCH_HOSTED")
    if seam is not None:
        return [r.strip().lower() for r in seam.split(",") if r.strip()]
    script = ('. "$1/fleet-lib.sh"; s="$2"; [ -n "$s" ] || s=$(fleet_current_session 2>/dev/null); '
              'fleet_repos "$s"')
    try:
        out = subprocess.run(["bash", "-c", script, "_", str(BIN), fleet], stdin=subprocess.DEVNULL,
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [r.strip().lower() for r in out.splitlines() if "/" in r]


TASK_TITLE_MAX = 80     # a record's title; longer words go whole as its body (the hub takes ≤200)


def task_send(data, view="", client=""):
    """A repo's start under hub authority (issue #4965): the record first
    (fleet-task-record.sh dispatch --repo --spawn), then its session here — a 看台
    goes to the window it opened. (ok, words)."""
    repo, fleet = data["repo"], fleet_of(view)
    title = data.get("draft") or data.get("title") or ""
    blank = bool(data.get("blank"))
    if blank:
        title = tr("dispatch_new_title")
    host = socket.gethostname().split(".")[0]
    if repo.lower() not in hosted(fleet):
        failed(data, view, "not hosted here")
        return False, tr("compose_failed_fmt", tr("dispatch_hub_elsewhere_fmt", repo, host))
    if blank:
        # the record in-process (T992, bin/fleet_blank_start.py): the script's bash
        # was ~0.6 s of a start; None ⇒ that road cannot take it, the script does
        try:
            sys.path.insert(0, str(BIN))
            import fleet_blank_start
            got = fleet_blank_start.start(repo, data.get("agent") if data.get("agent") in AGENTS else None, fleet,
                                          title, "⌘P", agent_default(fleet)) if fleet_blank_start.usable() else None
        except Exception:  # noqa: BLE001 — never a start lost to the fast road
            got = None
        if got is not None:
            rc, lines, err = got
            return task_answer(data, view, client, repo, subprocess.CompletedProcess([], rc, "\n".join(lines), err))
    seam = os.environ.get("FLEET_DISPATCH_TASK_CMD")
    argv = (seam.split() if seam else ["bash", str(BIN / "fleet-task-record.sh")]) + ["dispatch"]
    body = None
    head = title.strip().splitlines()[0].strip() if title.strip() else ""
    if head != title.strip() or len(head) > TASK_TITLE_MAX:
        # the hub's record holds a title of 1..200; the whole words ride as its body
        body = title
        title = head if len(head) <= TASK_TITLE_MAX else head[:TASK_TITLE_MAX - 1] + "…"
    argv += ["--title", title, "--repo", repo, "--spawn", "--origin", "hub", "--via", "⌘P", "--print"]
    argv += ["--blank"] if blank else []
    argv += ["--body-file", "-"] if body is not None else []
    argv += ["--agent", data["agent"]] if data.get("agent") in AGENTS else []
    argv += ["--session", fleet] if fleet else []
    try:
        out = subprocess.run(argv, input=body or "", capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.SubprocessError) as error:
        failed(data, view, str(error))
        return False, tr("compose_failed_fmt", str(error))
    return task_answer(data, view, client, repo, out)


def task_answer(data, view, client, repo, out):
    """The dispatch's answer (the script's, or the in-process road's in its shape):
    T<n> and its code, the window it opened here or the machine that took it."""
    lines = (out.stdout or "").splitlines()
    t = next((l.strip() for l in lines if l.strip()[:1] == "T" and l.strip()[1:].isdigit()), "")
    # the task's code first when the hub has one (EPIC T644 C3) — the name a person reads
    head = lines[0].strip() if lines else ""
    name = head if t and head != t and head[:1].isalpha() and head.isalnum() and head.isupper() else t
    if out.returncode != 0 or not t:
        err = [l.strip() for l in (out.stderr or "").splitlines() if l.strip()]
        why = (err[-1] if err else "") or "rc=%d" % out.returncode
        failed(data, view, why)
        return False, tr("compose_failed_fmt", (tr("dispatch_task_made_fmt", name) + " · " if t else "") + why)
    compose.compose_log("dispatch_task", id=data.get("id"), repo=repo, agent=data.get("agent"), view=view, task=t)
    win = next((l.split("\t", 1)[0].strip() for l in lines if l.startswith("@")), "")
    # `window` is dash-raw-session.sh's own stage now (T716, fleet_timing_at)
    remember(repo, data.get("agent"))
    if view and win:
        go(view, win, client)
    # the hub opened it on another machine (T716): the 看台 goes to it there,
    # by its worker_id (`REMOTE <machine> <worker_id> <window>`)
    far = next((l.split("\t") for l in lines if l.startswith("REMOTE\t")), None)
    if not win and far and len(far) >= 3 and far[2].strip():
        if view:
            go(view, far[2].strip(), client)
        said = tr("dispatch_task_remote_fmt", name, far[1].strip(), repo)
        notice(client, "info", said)
        return True, said
    return True, tr("dispatch_task_done_fmt", name, repo)


def go(view, win, client=""):
    """A 看台's send that opened a window here goes to it (fleet-view-go.sh)."""
    seam = os.environ.get("FLEET_DISPATCH_GO_CMD")
    arguments = [view, win, "--how", "dispatch"] + (["--client", client] if client else [])
    if seam:
        subprocess.run(seam.split() + arguments, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        import fleet_view
        fleet_view.main(["go"] + arguments, quick)


def send(data, view="", client=""):
    """Write it, --send it here. (ok, words): how it ended — a 看台 then goes to
    the window it opened (issue #3097, fleet-view-go.sh). A send that did not open is logged (`dispatch_failed`
    in logs/compose.ndjson) as well as said, never only said. Under hub authority a
    repo's send is a task record first (task_send, issue #4965)."""
    if data.get("repo") and authority(data["repo"], fleet_of(view)) == "hub":
        return task_send(data, view, client)
    path = compose.send_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    if not compose.write_atomic(path, json.dumps(data, ensure_ascii=False) + "\n"):
        return False, "✗ " + str(path)
    if data.get("repo"):
        remember(data["repo"], data.get("agent"))
    seam = os.environ.get("FLEET_DISPATCH_SEND_CMD")
    try:
        if seam:
            out = subprocess.run(seam.split() + [str(path)], stdin=subprocess.DEVNULL,
                                 capture_output=True, text=True)
        else:
            with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as stdout, \
                    tempfile.TemporaryFile(mode="w+", encoding="utf-8") as stderr:
                try:
                    code = compose.send(path, stdout=stdout, stderr=stderr)
                except Exception:
                    traceback.print_exc(file=stderr)
                    code = 1
                stdout.seek(0)
                stderr.seek(0)
                out = subprocess.CompletedProcess([], code, stdout.read(), stderr.read())
    except OSError as error:
        failed(data, view, str(error))
        return False, tr("compose_failed_fmt", str(error))
    if out.returncode == 0:
        win = next((l.split(" ", 1)[1].strip() for l in (out.stderr or "").splitlines() if l.startswith("window: @")), "")
        if view and win:
            go(view, win, client)
        return True, tr("compose_result_fmt", compose.place_why(out.stdout or out.stderr))
    compose.keep_failed(path)
    why = compose.place_why((out.stdout or "") + "\n" + (out.stderr or ""))
    failed(data, view, why or "rc=%d" % out.returncode)
    return False, tr("compose_failed_fmt", why or tr("compose_failed_unknown"))


def failed(data, view, why):
    """A ⌘T send that did not open, in logs/compose.ndjson (issue #3097): the popup
    runs under `>/dev/null 2>&1`, so the words on its screen are not a record."""
    compose.compose_log("dispatch_failed", id=data.get("id"), repo=data.get("repo"), agent=data.get("agent"),
                        view=view, why=why)


def ui(screen, session="", view="", client=""):
    curses.use_default_colors()
    curses.raw()
    try:
        curses.curs_set(1)
    except curses.error:
        pass
    curses.init_pair(1, curses.COLOR_YELLOW, -1)
    curses.init_pair(2, -1, curses.COLOR_BLUE)
    curses.init_pair(3, curses.COLOR_RED, -1)
    screen.keypad(True)
    have = repos()
    repo = repo_default(have)
    dflt = agent_default(fleet_of(view) if view else session)
    missing = agent_missing(view)
    usable = [a for a in AGENTS if a not in missing] or [dflt]
    agent = dflt if dflt in usable else usable[0]
    title, focus, note, bad = "", "title", "", False
    fields = ["title"] + (["repo"] if len(have) > 1 else []) + ["agent"]
    heal = quick.Heal()
    while True:
        screen.timeout(heal.timeout(False))
        height, width = screen.getmaxyx()
        heal.tick(screen)
        screen.erase()
        y = 0

        def line(text, attr=0, sel=False):
            nonlocal y
            if y >= height - 2:
                return
            try:
                base = quick.sel_attr(2) if sel else 0
                screen.addstr(y, 0, " " * (width - 1), base)
                screen.addstr(y, 0, quick.clip(text, width - 1), base | attr)
            except curses.error:
                pass
            y += 1

        label = tr("dispatch_field_title") + "  "
        line(label + title, curses.A_BOLD)
        cursor = (0, min(width - 1, quick.cells(label + title)))
        line("─" * (width - 1), curses.A_DIM)
        if "repo" in fields:
            line("%s %s  ‹ %s ›" % ("›" if focus == "repo" else " ", tr("dispatch_field_repo"), repo),
                 sel=focus == "repo")
        elif repo:
            line("  %s  %s" % (tr("dispatch_field_repo"), repo), curses.A_DIM)
        line("%s %s  ‹ %s%s ›" % ("›" if focus == "agent" else " ", tr("dispatch_field_agent"), agent,
                                  tr("dispatch_agent_default") if agent == dflt else ""), sel=focus == "agent")
        for a in AGENTS:
            if a in missing:
                line("    %s — %s" % (a, missing[a]), curses.A_DIM)
        if note:
            line("")
            line(note, (curses.color_pair(3) if bad else curses.color_pair(1)) | curses.A_BOLD)
        if height > 3:
            try:
                screen.addstr(height - 2, 0, "─" * (width - 1), curses.A_DIM)
                screen.addstr(height - 1, 1, quick.clip(tr("dispatch_keys"), width - 2), curses.A_DIM)
            except curses.error:
                pass
        try:
            curses.curs_set(1 if focus == "title" else 0)
            if focus == "title":
                screen.move(*cursor)
        except curses.error:
            pass
        screen.refresh()
        try:
            key = screen.get_wch()
        except curses.error:
            continue
        if key == curses.KEY_RESIZE:
            heal.resized(screen)
            continue
        if key in ("\x1b", "\x03", "\x07") or key == curses.KEY_EXIT:
            return 0
        note, bad = "", False
        if key in ("\n", "\r") or key == curses.KEY_ENTER:
            if not title.strip():
                note, bad = tr("compose_empty"), True
                continue
            if not repo:
                note, bad = tr("dispatch_norepo"), True
                continue
            note = tr("dispatch_sending")
            line(note, curses.color_pair(1))
            screen.refresh()
            ok, said = send(payload(title, repo, agent=None if agent == dflt else agent), view, client)
            if ok:
                notice(client, "info", said)
                return 0
            note, bad = said, True
            continue
        if key in ("\t", curses.KEY_DOWN):
            focus = fields[(fields.index(focus) + 1) % len(fields)]
        elif key in (curses.KEY_BTAB, curses.KEY_UP):
            focus = fields[(fields.index(focus) - 1) % len(fields)]
        elif key == "\x18" or (focus == "agent" and key in (curses.KEY_LEFT, curses.KEY_RIGHT, " ")):
            at = usable.index(agent) if agent in usable else 0
            agent = usable[(at + (-1 if key == curses.KEY_LEFT else 1)) % len(usable)]
        elif focus == "repo" and key in (curses.KEY_LEFT, curses.KEY_RIGHT, " ") and have:
            at = have.index(repo) if repo in have else 0
            repo = have[(at + (-1 if key == curses.KEY_LEFT else 1)) % len(have)]
        elif focus == "title" and key in (curses.KEY_BACKSPACE, "\x7f", "\x08"):
            title = title[:-1]
        elif focus == "title" and key == "\x15":
            title = ""
        elif isinstance(key, str) and key.isprintable():
            focus, title = "title", title + key


def fleet_of(view):
    """The fleet session a 看台 (`<fleet>@view-<id>`) is grouped onto."""
    fleet, sep, _ = (view or "").rpartition("@view-")
    return fleet if sep else ""


def opts(argv):
    out = {"--title": "", "--repo": "", "--session": "", "--view": "", "--client": "", "--agent": ""}
    i = 0
    while i < len(argv):
        if argv[i] in out and i + 1 < len(argv):
            out[argv[i]] = argv[i + 1]
            i += 2
            continue
        out[argv[i]] = True
        i += 1
    return out


def set_locale():
    """The environment's locale, else C.UTF-8, else C (issue #3514): a LANG that
    names a locale this machine lacks (en_US.UTF-8 on a slim Linux image) made
    setlocale raise — the 看台's key tables were never built and ⌘P / ⚡ died at
    start, silently, on every thin client of the login."""
    for name in ("", "C.UTF-8", "C.utf8", "C"):
        try:
            return locale.setlocale(locale.LC_ALL, name)
        except locale.Error:
            continue
    return ""



def notice(client, level, text):
    """One on-screen line on this client (T675, bin/fleet_notice.py): held for its
    tier and recorded for ⌘P's 最近消息, never a 0.75 s display-message."""
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import fleet_notice
        fleet_notice.notify(level, text, client=client or "", source="⌘T")
    except Exception:  # noqa: BLE001 — a notice never breaks the dispatch
        pass

def main(argv):
    global TEXT
    set_locale()
    TEXT = load_text()
    compose.TEXT = TEXT
    if argv[:1] == ["pick"]:
        print(repo_pick())
        for r in repos():
            print(r)
        return 0
    if argv[:1] == ["agent"]:
        a, why = agent_pick(opts(argv[1:])["--view"])
        print(json.dumps({"agent": a, "why": why}, ensure_ascii=False))
        return 0
    if argv[:1] == ["authority"]:
        o = opts(argv[1:])
        print(authority(o["--repo"], fleet_of(o["--view"])) if o["--repo"] else "")
        return 0
    if argv[:1] == ["grid"]:
        o = opts(argv[1:])
        view = o["--view"]
        have, st = repos(), state_read()
        dflt, missing = agent_default(fleet_of(view) if view else ""), agent_missing(view)
        repo, _ = defaults(o["--repo"], have, st, dflt, missing)
        # `last` the box's repo, `agents` each repo's agent ("" = 不绑仓库) — the
        # panel only shows them (约定 2)
        print(json.dumps({"repos": have, "last": repo, "agent": dflt,
                          "agents": {r: agent_for(r, st, dflt, missing) for r in [""] + have},
                          "missing": missing, "blocked": sorted(agent_blocked()) if view else []},
                         ensure_ascii=False))
        return 0
    if argv[:1] == ["remember"]:
        o = opts(argv[1:])
        return 0 if remember(o["--repo"], o["--agent"] if o["--agent"] in AGENTS else None) else 1
    o = opts(argv[1:] if argv[:1] in (["payload"], ["send"]) else argv)
    if argv[:1] == ["send"] and o.get("--blank"):
        # a blank session under hub authority (T652): a record, no words — go_new's road
        if not o["--repo"]:
            print(tr("dispatch_norepo"), file=sys.stderr)
            return 2
        data = {"repo": o["--repo"], "agent": o["--agent"] if o["--agent"] in AGENTS else None,
                "blank": True, "via": "dispatch"}
        ok, said = task_send(data, o["--view"], o["--client"])
        print(said)
        return 0 if ok else 1
    if argv[:1] in (["payload"], ["send"]):
        agent = o["--agent"] if o["--agent"] in AGENTS else None
        data = payload(o["--title"], o["--repo"] or repo_default(), bool(o.get("--codex")), agent)
        if data and o.get("--draft"):
            draft = compose.clean(o["--title"])
            if len(draft) > compose.MAX_BODY:
                print("fleet: draft exceeds 4000 characters", file=sys.stderr)
                return 2
            data.update(draft=draft, body="", attachments=[], issue=False)
        if not data:
            print(tr("compose_empty"), file=sys.stderr)
            return 2
        if argv[0] == "payload":
            print(json.dumps(data, ensure_ascii=False))
            return 0
        if not data["repo"]:
            print(tr("dispatch_norepo"), file=sys.stderr)
            return 2
        ok, said = send(data, o["--view"], o["--client"])
        print(said)
        if o.get("--toast") and said:
            notice(o["--client"], "info" if ok else "error", said)
        return 0 if ok else 1
    os.environ.setdefault("ESCDELAY", "25")
    try:
        return curses.wrapper(ui, o["--session"], o["--view"], o["--client"])
    except Exception as error:  # noqa: BLE001 — the popup's crash is said, never swallowed (issue #3097)
        import traceback
        compose.compose_log("dispatch_failed", view=o["--view"], why="crash: %r" % error,
                            trace=traceback.format_exc()[-2000:])
        notice(o["--client"], "error", tr("compose_failed_fmt", "%s: %s" % (type(error).__name__, error)))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
