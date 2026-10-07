#!/usr/bin/env python3
"""fleet-oldcfg-replay.py — 发版前拿上一版的老会话跑一遍 (issue #2075, EPIC #2074 C2).

usage: fleet-oldcfg-replay.py [--dir <checkout>] [--old <ref>] [--new <ref> | --new-dir <dir>]
                              [--timeout <s>] [--json] [-q] [--keep]

An old session — launched before the last `fleet-stable.sh move`, never reopened (a
looping scheduler is never reopened on purpose) — keeps what it read at ITS start:

  the hook table        hooks/settings-hooks.json  (Claude Code read it into settings)
  the mod's tool list   mod/fleet/hooks/tools.ts   (registered once; a hot reload swaps
                                                    the code, never the list — #2057)
  the MCP servers       conf/mcp-worker.json       (the server's tool list, as Codex
                                                    keeps it; Claude re-lists)

Everything those name runs from the NEW install: `~/.claude/fleet` is the version
link. #2068's four rules say such a session keeps working — at worst it lacks a new
feature. On 2026-10-06 a release dropped three mod tools with no handler behind them
and four old sessions on m5 failed every spawn with «no tool.call hook answered».
This script is the gate that makes that a red BEFORE stable moves:

  old   the session's start — the three files as `--old` has them (default: the
        `stable` tag, what every install follows);
  new   the release — the tree of `--new` (default HEAD), or `--new-dir` (a working
        tree), standing in as `~/.claude/fleet`.

In a sandbox HOME (its ~/.claude/fleet → the new tree; an empty FLEET_CONF_DIR shaped
like a login's; no TMUX; tmux / gh / ssh / curl / open shimmed to fail — nothing real
is touched, nothing leaves the machine):

  hook  every command of the OLD table runs once per event (SessionStart,
        UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop, PreCompact,
        SessionEnd, one per matcher) with a minimal event JSON on stdin, the way
        Claude Code runs it: the script it names must exist in the new tree, exit 0,
        and answer within --timeout (an exit 2 is a BLOCK, any other non-zero a hook
        error shown every turn, a hang stalls the turn);
  tool  every tool the OLD mod registered must still have a tool.call handler in the
        NEW mod (tools.ts's TOOL_RE), and that handler's forward, `fleet-mcp.py --call
        <tool>`, must answer: exit 0, or 1 with its reason (refused — an answer), or 2
        (the mod turns it into the «reopen the session» message — an answer); a
        crash, a traceback or a hang is not;
  mcp   every script an OLD MCP server's command names must exist in the new tree,
        and every tool the OLD server lists (tools/list, spoken to it over stdio) must
        still be listed by the NEW server (#2068 rule 4: keep a handler, or an
        actionable refusal under the old name).

Prints one line per item — `<kind> <verdict> <name> — <detail>` — and a last line
`oldcfg-replay: GREEN …` or `oldcfg-replay: RED — N finding(s) …`; `-q` prints the
findings and the last line only; `--json` prints one object instead (C3, #2076, reads
it: {old, new, items[{kind, verdict, name, detail, …}], findings, verdict}).
Exit 0 green · 1 red · 2 cannot run (usage, no git, an unknown ref).

The degenerate case: --old and --new the same commit ⇒ nothing changed, GREEN at
once, nothing run. A tree with none of the three files has nothing to replay and is
GREEN with a note per file (a repo that is not claude-fleet).

Where it runs: `fleet-stable.sh move` (old = the current stable, new = the target;
a red REFUSES the move, `--force` moves anyway and logs one line) and
`bin/fleet-oldcfg-replay-selftest.sh` (a rig, plus this repo's own table replayed
against itself — so a hook that cannot run in the sandbox is red in CI, not at the
operator's release).
"""
import argparse
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

TREE_PATHS = ("bin", "hooks", "conf", "mod", "commands", "skills")
HOOK_TABLE = "hooks/settings-hooks.json"
MOD_TOOLS = "mod/fleet/hooks/tools.ts"
MCP_CONF = "conf/mcp-worker.json"
EVENT_ORDER = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
               "Notification", "Stop", "SubagentStop", "PreCompact", "SessionEnd")
# Commands an agent or a hook may reach for that must never touch the real machine.
SHIMMED = ("tmux", "gh", "ssh", "scp", "curl", "wget", "open", "osascript", "claude",
           "codex", "launchctl", "systemctl", "terminal-notifier")
SCRUB_ENV = re.compile(r"^(FLEET_|CCQUOTA_|TMUX|CLAUDE|CODEX|GH_|GITHUB_)")
FLEET_PATH = re.compile(r"(?:~|\$HOME)/\.claude/fleet/((?:[\w.-]+/)+[\w.-]+)")
SCRIPT_NAME = re.compile(r"\b([\w.-]+\.(?:py|sh))\b")
MCP_LIST_TIMEOUT_S = 20


class CannotRun(Exception):
    pass


# ---------------------------------------------------------------- the inputs ----

def first_alternative(matcher):
    """`Edit|Write|MultiEdit` → `Edit`; a regex's anchors and groups stripped."""
    if not matcher:
        return None
    first = matcher.split("|")[0]
    return re.sub(r"[\^$()\\.*+?\[\]{}]", "", first).strip() or None


def tool_input(tool, cwd):
    """A benign tool call of each kind a guard looks at."""
    if tool == "Bash":
        return {"command": "true", "description": "oldcfg replay"}
    if tool in ("Edit", "MultiEdit"):
        return {"file_path": os.path.join(cwd, "replay.txt"), "old_string": "a", "new_string": "b"}
    if tool in ("Write", "NotebookEdit"):
        return {"file_path": os.path.join(cwd, "replay.txt"), "content": "replay"}
    if tool == "Artifact":
        return {"action": "list"}
    if tool == "Agent":
        return {"subagent_type": "Explore", "prompt": "where is x", "description": "find x"}
    if tool == "ScheduleWakeup":
        return {"delaySeconds": 60, "prompt": "/loop", "reason": "replay"}
    if tool == "CronCreate":
        return {"cron": "*/5 * * * *", "prompt": "/loop"}
    if tool == "CronDelete":
        return {"id": "replay"}
    return {}


def event_json(event, matcher, work):
    base = {"session_id": "oldcfg-replay", "transcript_path": os.path.join(work, "transcript.jsonl"),
            "cwd": os.path.join(work, "cwd"), "hook_event_name": event, "permission_mode": "default"}
    alt = first_alternative(matcher)
    if event == "SessionStart":
        base["source"] = alt or "startup"
    elif event == "UserPromptSubmit":
        base["prompt"] = "hi"
    elif event in ("PreToolUse", "PostToolUse"):
        tool = alt or "Bash"
        base.update(tool_name=tool, tool_input=tool_input(tool, base["cwd"]), tool_use_id="toolu_oldcfg")
        if event == "PostToolUse":
            base["tool_response"] = {}
    elif event == "Notification":
        base.update(message="replay", notification_type=alt or "idle_prompt")
    elif event in ("Stop", "SubagentStop"):
        base["stop_hook_active"] = False
    elif event == "PreCompact":
        base.update(trigger=alt or "manual", custom_instructions="")
    elif event == "SessionEnd":
        base["reason"] = alt or "other"
    return json.dumps(base)


# ---------------------------------------------------------------- the trees -----

def git(checkout, *args, **kw):
    return subprocess.run(["git", "-C", checkout] + list(args), text=True, capture_output=True, **kw)


def resolve(checkout, ref):
    r = git(checkout, "rev-parse", "--verify", "-q", ref + "^{commit}")
    if r.returncode != 0:
        hint = (" — fetch it first: git fetch origin +refs/tags/stable:refs/tags/stable" if ref == "stable" else "")
        raise CannotRun("%s is not a commit in %s%s" % (ref, checkout, hint))
    return r.stdout.strip()


def subject(checkout, sha):
    return git(checkout, "log", "-1", "--format=%s", sha).stdout.strip()


def export_tree(checkout, sha, dest):
    """The commit's bin/ hooks/ conf/ mod/ … as plain files (git archive: no side effect
    on the checkout, no .git — the way a client install lays them out)."""
    present = git(checkout, "ls-tree", "--name-only", sha).stdout.split()
    paths = [p for p in TREE_PATHS if p in present]
    os.makedirs(dest, exist_ok=True)
    if not paths:
        return
    arc = subprocess.Popen(["git", "-C", checkout, "archive", sha, "--"] + paths, stdout=subprocess.PIPE)
    tar = subprocess.run(["tar", "-x", "-C", dest], stdin=arc.stdout, capture_output=True, text=True)
    arc.stdout.close()
    if arc.wait() != 0 or tar.returncode != 0:
        raise CannotRun("could not export %s from %s: %s" % (sha[:8], checkout, tar.stderr.strip()))


def read_text(tree, rel):
    p = os.path.join(tree, rel)
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read()


# ---------------------------------------------------------------- the sandbox ---

class Sandbox:
    def __init__(self, work, new_tree, old_tree):
        self.work = work
        self.home = os.path.join(work, "home")
        self.home_old = os.path.join(work, "home-old")
        self.cwd = os.path.join(work, "cwd")
        self.conf = os.path.join(work, "conf")
        shim = os.path.join(work, "shim")
        for d in (self.cwd, shim, os.path.join(self.conf, "global"), os.path.join(self.conf, "fleets"),
                  os.path.join(self.home, ".claude"), os.path.join(self.home_old, ".claude")):
            os.makedirs(d, exist_ok=True)
        os.symlink(new_tree, os.path.join(self.home, ".claude", "fleet"))
        if old_tree is not None:
            os.symlink(old_tree, os.path.join(self.home_old, ".claude", "fleet"))
        open(os.path.join(work, "transcript.jsonl"), "w").close()
        for name in SHIMMED:
            p = os.path.join(shim, name)
            with open(p, "w") as fh:
                fh.write("#!/bin/sh\nprintf '%%s: not available in the oldcfg replay sandbox\\n' '%s' >&2\nexit 1\n" % name)
            os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        self.env = {k: v for k, v in os.environ.items() if not SCRUB_ENV.match(k)}
        self.env.update(HOME=self.home, FLEET_CONF_DIR=self.conf,
                        PATH=shim + os.pathsep + self.env.get("PATH", "/usr/bin:/bin"),
                        FLEET_MCP_RELOAD="0")

    def env_for(self, old=False):
        env = dict(self.env)
        if old:
            env["HOME"] = self.home_old
        return env

    def run(self, argv, stdin_text, timeout, shell=False, old=False):
        """Run one command the way a hook runs: stdin = the event, stdout/stderr to files
        (a child the hook leaves behind cannot hold a pipe open), its own process group
        (a timeout takes the group with it). Returns (rc | None on timeout, stderr head, secs)."""
        out = os.path.join(self.work, "out")
        err = os.path.join(self.work, "err")
        t0 = time.time()
        with open(out, "w") as fo, open(err, "w") as fe:
            p = subprocess.Popen(argv if not shell else ["sh", "-c", argv], stdin=subprocess.PIPE, stdout=fo,
                                 stderr=fe, cwd=self.cwd, env=self.env_for(old), start_new_session=True)
            try:
                p.communicate(input=stdin_text.encode("utf-8"), timeout=timeout)
                rc = p.returncode
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    pass
                p.wait()
                rc = None
        with open(err, encoding="utf-8", errors="replace") as fh:
            e = fh.read()
        with open(out, encoding="utf-8", errors="replace") as fh:
            o = fh.read()
        return rc, o, e, time.time() - t0


# ---------------------------------------------------------------- the replay ----

class Replay:
    def __init__(self, sb, old_tree, new_tree, timeout):
        self.sb, self.old, self.new, self.timeout = sb, old_tree, new_tree, timeout
        self.items = []
        self.counts = {"hook": 0, "tool": 0, "mcp": 0}

    def item(self, kind, verdict, name, detail, **extra):
        row = {"kind": kind, "verdict": verdict, "name": name, "detail": detail}
        row.update(extra)
        self.items.append(row)
        return row

    @staticmethod
    def head(text):
        for line in text.splitlines():
            if line.strip():
                return line.strip()[:160]
        return ""

    # --- hooks ---------------------------------------------------------------
    def hooks(self):
        text = read_text(self.old, HOOK_TABLE)
        if text is None:
            self.item("hook", "none", HOOK_TABLE, "not in the old tree — no hook table to replay")
            return
        try:
            table = json.loads(text).get("hooks", {})
        except ValueError as exc:
            self.item("hook", "ERROR", HOOK_TABLE, "the old table is not JSON: %s" % exc)
            return
        events = [e for e in EVENT_ORDER if e in table] + [e for e in table if e not in EVENT_ORDER]
        for event in events:
            for entry in table.get(event) or []:
                matcher = entry.get("matcher") or ""
                label = "%s[%s]" % (event, matcher) if matcher else event
                stdin_text = event_json(event, matcher, self.sb.work)
                for hook in entry.get("hooks") or []:
                    if hook.get("type", "command") != "command":
                        continue
                    self.one_hook(label, hook.get("command", ""), stdin_text)

    def one_hook(self, label, command, stdin_text):
        self.counts["hook"] += 1
        missing = [rel for rel in FLEET_PATH.findall(command) if not os.path.exists(os.path.join(self.new, rel))]
        if missing:
            self.item("hook", "MISSING", label, "%s — %s not in the new tree: the old table runs it every "
                      "turn and gets «not found» (a PreToolUse one BLOCKS the call)"
                      % (command, ", ".join(missing)), command=command)
            return
        rc, _out, err, secs = self.sb.run(command, stdin_text, self.timeout, shell=True)
        if rc is None:
            self.item("hook", "TIMEOUT", label, "%s — no answer within %ss: the turn would stall"
                      % (command, self.timeout), command=command, secs=round(secs, 2))
        elif rc != 0:
            what = "BLOCKS the call" if rc == 2 else "a hook error, every turn"
            self.item("hook", "ERROR", label, "%s — exit %d (%s): %s" % (command, rc, what, self.head(err) or "no stderr"),
                      command=command, secs=round(secs, 2), exit=rc)
        else:
            self.item("hook", "ok", label, "%s  %.2fs" % (command, secs), command=command, secs=round(secs, 2))

    # --- the mod's tools ------------------------------------------------------
    @staticmethod
    def registered_tools(src):
        """The tools a tools.ts registers: `fleet_` + each FALLBACK name (0.4.1+), or a
        literal `name: 'fleet_…'` (the pre-#1812 shape). None = unreadable."""
        names = []
        m = re.search(r"FALLBACK\s*=\s*\[([^\]]*)\]", src)
        if m:
            names += ["mcp__fleet__fleet_" + n for n in re.findall(r"['\"](\w+)['\"]", m.group(1))]
        names += ["mcp__fleet__" + n for n in re.findall(r"name:\s*['\"](fleet_\w+)['\"]", src)]
        return names if (m or names) else None

    @staticmethod
    def handler_re(src):
        m = re.search(r"TOOL_RE\s*=\s*/(.+?)/[gimsuy]*\s*$", src, re.M)
        try:
            return re.compile(m.group(1)) if m else None
        except re.error:
            return None

    def tools(self):
        old_src = read_text(self.old, MOD_TOOLS)
        if old_src is None:
            self.item("tool", "none", MOD_TOOLS, "not in the old tree — the old mod registered no tool")
            return
        old_tools = self.registered_tools(old_src)
        if old_tools is None:
            self.item("tool", "ERROR", MOD_TOOLS, "cannot read which tools the OLD mod registered (no FALLBACK "
                      "list, no name: 'fleet_…') — teach fleet-oldcfg-replay.py its shape")
            return
        new_src = read_text(self.new, MOD_TOOLS)
        handler = self.handler_re(new_src) if new_src is not None else None
        if old_tools and new_src is not None and handler is None:
            self.item("tool", "ERROR", MOD_TOOLS, "cannot read the NEW mod's tool.call handler (no TOOL_RE = /…/) "
                      "— teach fleet-oldcfg-replay.py its shape")
            return
        fwd_script = os.path.join(self.new, "bin", "fleet-mcp.py")
        for tool in old_tools:
            self.counts["tool"] += 1
            m = handler.search(tool) if handler is not None else None
            if m is None:
                self.item("tool", "MISSING", tool, "no tool.call handler in the new %s (TOOL_RE) — an old session "
                          "that lists it dies with «no tool.call hook answered» (#2068 rule 1: forward it, or answer "
                          "how to reopen)" % MOD_TOOLS)
                continue
            fwd = m.group(1) if m.lastindex else tool
            if not os.path.isfile(fwd_script):
                self.item("tool", "ERROR", tool, "handler present, but its forward bin/fleet-mcp.py is not in the new tree")
                continue
            rc, out, err, secs = self.sb.run(["python3", fwd_script, "--call", fwd, "{}"], "", self.timeout)
            if rc is None:
                self.item("tool", "TIMEOUT", tool, "fleet-mcp.py --call %s gave no answer within %ss" % (fwd, self.timeout))
            elif "Traceback" in err or rc not in (0, 1, 2):
                self.item("tool", "ERROR", tool, "fleet-mcp.py --call %s crashed (exit %s): %s" % (fwd, rc, self.head(err)))
            else:
                how = {0: "answered", 1: "refused with its reason", 2: "the mod answers «reopen the session»"}[rc]
                self.item("tool", "ok", tool, "handler in %s → fleet-mcp.py --call %s: exit %d, %s  %.2fs"
                          % (MOD_TOOLS, fwd, rc, how, secs), secs=round(secs, 2), exit=rc)

    # --- the MCP servers --------------------------------------------------------
    def mcp_tools_list(self, srv, old):
        """tools/list spoken to the server as its config starts it (HOME's ~/.claude/fleet
        → the old or the new tree). Returns (names | None, why)."""
        argv = [srv.get("command", "")] + list(srv.get("args") or [])
        if not argv[0]:
            return None, "no command"
        env_extra = srv.get("env") or {}
        saved = dict(self.sb.env)
        self.sb.env.update({k: str(v) for k, v in env_extra.items()})
        try:
            req = ('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05",'
                   '"capabilities":{},"clientInfo":{"name":"oldcfg-replay","version":"0"}}}\n'
                   '{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
                   '{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n')
            rc, out, err, _secs = self.sb.run(argv, req, MCP_LIST_TIMEOUT_S, old=old)
        finally:
            self.sb.env = saved
        if rc is None:
            return None, "no tools/list answer within %ss" % MCP_LIST_TIMEOUT_S
        for line in out.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("id") == 2:
                if "error" in msg:
                    return None, "tools/list error: %s" % msg["error"].get("message")
                return sorted(t.get("name", "") for t in msg.get("result", {}).get("tools", [])), ""
        return None, "no tools/list answer (exit %s): %s" % (rc, self.head(err) or self.head(out) or "nothing printed")

    def mcp(self):
        text = read_text(self.old, MCP_CONF)
        if text is None:
            self.item("mcp", "none", MCP_CONF, "not in the old tree — no MCP server to replay")
            return
        try:
            servers = json.loads(text).get("mcpServers", {})
        except ValueError as exc:
            self.item("mcp", "ERROR", MCP_CONF, "the old file is not JSON: %s" % exc)
            return
        for name, srv in servers.items():
            self.counts["mcp"] += 1
            words = " ".join([srv.get("command", "")] + [str(a) for a in srv.get("args") or []])
            if ".claude/fleet" not in words:
                self.item("mcp", "ok", name, "not a fleet script (%s) — nothing of ours to break" % words[:80])
                continue
            missing = [s for s in sorted(set(SCRIPT_NAME.findall(words)))
                       if not any(os.path.isfile(os.path.join(self.new, d, s)) for d in ("bin", "hooks"))]
            if missing:
                self.item("mcp", "MISSING", name, "%s not in the new tree — the server an old session restarts "
                          "(or the version link execs into, #1898) is gone" % ", ".join(missing))
                continue
            old_tools, why = self.mcp_tools_list(srv, old=True)
            if old_tools is None:
                self.item("mcp", "ERROR", name, "the OLD server's tool list could not be read: %s" % why)
                continue
            new_tools, why = self.mcp_tools_list(srv, old=False)
            if new_tools is None:
                self.item("mcp", "ERROR", name, "the NEW server does not answer tools/list: %s" % why)
                continue
            gone = [t for t in old_tools if t not in new_tools]
            for t in gone:
                self.item("mcp", "MISSING", "%s.%s" % (name, t), "the new server does not list it — a Codex session "
                          "keeps the old list and calls it (#2068 rule 4: keep the name, forward it or refuse with "
                          "what to do)")
            added = [t for t in new_tools if t not in old_tools]
            if not gone:
                self.item("mcp", "ok", name, "%d tool(s) of the old server still listed by the new%s"
                          % (len(old_tools), (" (+ new: %s)" % ", ".join(added)) if added else ""))

    def run(self):
        self.hooks()
        self.tools()
        self.mcp()
        return [i for i in self.items if i["verdict"] not in ("ok", "none")]


# ---------------------------------------------------------------- main ----------

def default_checkout():
    here = os.path.dirname(os.path.realpath(__file__))
    r = subprocess.run(["git", "-C", here, "rev-parse", "--show-toplevel"], text=True, capture_output=True)
    return r.stdout.strip() if r.returncode == 0 else None


def main(argv):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--dir")
    ap.add_argument("--old", default="stable")
    ap.add_argument("--new", default="HEAD")
    ap.add_argument("--new-dir")
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("-q", "--quiet", action="store_true")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")
    try:
        a = ap.parse_args(argv)
    except SystemExit:
        return 2
    if a.help:
        print(__doc__.strip())
        return 0
    if shutil.which("git") is None or shutil.which("python3") is None:
        print("oldcfg-replay: git and python3 are needed", file=sys.stderr)
        return 2
    checkout = a.dir or default_checkout()
    if not checkout or git(checkout, "rev-parse", "--git-dir").returncode != 0:
        print("oldcfg-replay: %s is not a git checkout (--dir)" % (checkout or "(none)"), file=sys.stderr)
        return 2
    try:
        old_sha = resolve(checkout, a.old)
        new_sha = None if a.new_dir else resolve(checkout, a.new)
    except CannotRun as exc:
        print("oldcfg-replay: %s" % exc, file=sys.stderr)
        return 2
    old_label = "%s 「%s」" % (old_sha[:8], subject(checkout, old_sha))
    if a.new_dir:
        new_dir = os.path.abspath(a.new_dir)
        if not os.path.isdir(new_dir):
            print("oldcfg-replay: --new-dir %s is not a directory" % new_dir, file=sys.stderr)
            return 2
        new_label = new_dir
    else:
        new_label = "%s 「%s」" % (new_sha[:8], subject(checkout, new_sha))
        if new_sha == old_sha:
            msg = "oldcfg-replay: old == new (%s) — nothing changed, GREEN" % old_sha[:8]
            if a.json:
                print(json.dumps({"old": {"ref": a.old, "sha": old_sha}, "new": {"ref": a.new, "sha": new_sha},
                                  "items": [], "findings": 0, "verdict": "GREEN", "note": "old == new"}, ensure_ascii=False))
            else:
                print(msg)
            return 0

    work = tempfile.mkdtemp(prefix="oldcfg-replay.")
    try:
        old_tree = os.path.join(work, "old")
        export_tree(checkout, old_sha, old_tree)
        if a.new_dir:
            new_tree = new_dir
        else:
            new_tree = os.path.join(work, "new")
            export_tree(checkout, new_sha, new_tree)
        sb = Sandbox(work, new_tree, old_tree)
        rp = Replay(sb, old_tree, new_tree, a.timeout)
        findings = rp.run()
    except CannotRun as exc:
        print("oldcfg-replay: %s" % exc, file=sys.stderr)
        return 2
    finally:
        if a.keep:
            print("oldcfg-replay: kept %s" % work, file=sys.stderr)
        else:
            shutil.rmtree(work, ignore_errors=True)

    verdict = "RED" if findings else "GREEN"
    c = rp.counts
    if findings:
        summary = ("oldcfg-replay: RED — %d finding(s): an old session of %s would break on %s"
                   % (len(findings), old_sha[:8], new_sha[:8] if new_sha else new_label))
    else:
        summary = ("oldcfg-replay: GREEN — %d hook(s) · %d mod tool(s) · %d MCP server(s) replayed: an old session "
                   "of %s runs on %s" % (c["hook"], c["tool"], c["mcp"], old_sha[:8], new_sha[:8] if new_sha else new_label))
    if a.json:
        print(json.dumps({"old": {"ref": a.old, "sha": old_sha}, "new": {"ref": None if a.new_dir else a.new,
                          "sha": new_sha, "dir": new_dir if a.new_dir else None}, "items": rp.items,
                          "counts": c, "findings": len(findings), "verdict": verdict, "summary": summary},
                         ensure_ascii=False))
        return 1 if findings else 0
    print("oldcfg-replay: old=%s  new=%s" % (old_label, new_label))
    for it in rp.items:
        if a.quiet and it["verdict"] in ("ok", "none"):
            continue
        print("%-5s %-8s %-28s %s" % (it["kind"], it["verdict"], it["name"], it["detail"]))
    print(summary)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
