#!/usr/bin/env python3
"""fleet-agent-bundle.py — the fleet's Agent configuration as ONE package.

Issue #1725 (EPIC #1718 C7). conf/agent-bundle.manifest lists it: Claude's
hooks, skills, commands, MCP servers and the fleet mod; Codex's skills, MCP
servers and default keys. A full install (~/.claude/fleet) and a client-only
computer (~/.local/share/claude-fleet) carry the same files and apply them the
same way — fleet-install-apply.sh, fill only, the login's override files first.

  files   [--root R] [--category]
          The manifest expanded to files, one per line (with its category).
  version [--root R]
          A 12-hex digest of the package's paths + bytes: the same for a
          checkout and a client holding the same files.
  check   [--root R]
          Read-only, this login against the package, by the four categories the
          EPIC's metric counts — hooks · skills · mcp · mod. First line
          `ok 4/4 · …` (exit 0) or `N/4 · missing …` and one `missing <cat> …`
          line each (exit 1). A Codex home that does not exist is not counted.
  doctor  [--root R]
          The check as fleet-doctor's `agents` row — what `fleet doctor` prints on
          a computer that has only the client (no bin/fleet-doctor.sh beside it).
  apply   [--root R] [--dry-run]
          fleet-install-apply.sh --bundle --root R: what the installer runs.

The root defaults to the install this script sits in. Overrides: an item named
in ~/.config/claude-fleet/agent-overrides.json (`claude`, `codex`,
`claude.skills`, `claude.commands`, `codex.skills`, …) or
~/.claude/settings.fleet-override.json is the login's own — never written, never
counted as missing.

Exit: 0 ok · 1 check found something missing · 2 a malformed manifest / input.
"""
import hashlib
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(HERE)
MANIFEST = os.path.join("conf", "agent-bundle.manifest")
CATEGORIES = ("hooks", "skills", "mcp", "mod")
KNOWN = set(CATEGORIES) | {"settings", "commands", "tool"}
SKILL_MARK = "<!-- fleet skill -->"
COMMAND_MARK = re.compile(r"^<!-- fleet skill · owner: [a-z][a-z-]* -->$")
FENCE = re.compile(r"^[ \t]*(```|~~~)")


def die(msg):
    print("fleet-agent-bundle: %s" % msg, file=sys.stderr)
    sys.exit(2)


def skipped(name):
    return name.startswith(".") or name.startswith("_") or name in ("__pycache__", "node_modules")


def expand(root):
    """[(path, category)] in manifest order, each file once."""
    mf = os.path.join(root, MANIFEST)
    try:
        lines = open(mf, encoding="utf-8").read().split("\n")
    except OSError as e:
        die("no package manifest at %s (%s)" % (mf, e))
    out, seen = [], set()

    def add(p, cat):
        if p not in seen:
            seen.add(p)
            out.append((p, cat))
    add(MANIFEST, "tool")
    for n, line in enumerate(lines, 1):
        s = line.split("#", 1)[0].strip()
        if not s:
            continue
        f = s.split()
        if len(f) != 2 or f[1] not in KNOWN:
            die("%s:%d: want `<path> <category>` with a category of %s" % (mf, n, ", ".join(sorted(KNOWN))))
        p, cat = f
        if p.startswith("/") or ".." in p.split("/"):
            die("%s:%d: %s must be a repo-relative path" % (mf, n, p))
        full = os.path.join(root, p)
        if p.endswith("/"):
            if not os.path.isdir(full):
                die("%s:%d: %s is not a directory under %s" % (mf, n, p, root))
            for d, dirs, files in os.walk(full):
                dirs[:] = sorted(x for x in dirs if not skipped(x))
                for x in sorted(files):
                    if not skipped(x):
                        add(os.path.relpath(os.path.join(d, x), root).replace(os.sep, "/"), cat)
        else:
            if not os.path.isfile(full):
                die("%s:%d: %s is not a file under %s" % (mf, n, p, root))
            add(p, cat)
    return out


def version(root, files=None):
    h = hashlib.sha256()
    for p, _ in sorted(files or expand(root)):
        h.update(p.encode() + b"\0")
        with open(os.path.join(root, p), "rb") as f:
            h.update(f.read())
        h.update(b"\0")
    return h.hexdigest()[:12]


def is_command(path):
    fence = False
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.rstrip("\r\n")
            if FENCE.match(line):
                fence = not fence
                continue
            if not fence and COMMAND_MARK.match(line):
                return True
    except OSError:
        pass
    return False


def marked_skill(d):
    try:
        return SKILL_MARK in open(os.path.join(d, "SKILL.md"), encoding="utf-8", errors="replace").read()
    except OSError:
        return False


def overrides():
    """Paths the login keeps for itself (agent-overrides.json; a JSON array or an
    object keyed by them). Unreadable → none."""
    conf = os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet")
    try:
        d = json.load(open(os.path.join(conf, "agent-overrides.json")))
    except (OSError, ValueError):
        return set()
    if isinstance(d, (list, dict)):
        return {k for k in d if isinstance(k, str)}
    return set()


def shielded(path, blocked):
    parts = path.split(".")
    return any(".".join(parts[:i]) in blocked for i in range(1, len(parts) + 1))


def codex_homes():
    homes = [os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")]
    if os.environ.get("FLEET_CODEX_HOME"):
        homes.append(os.environ["FLEET_CODEX_HOME"])
    conf = os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet")
    try:
        d = json.load(open(os.path.join(conf, "codex", "accounts.json")))
        if isinstance(d, dict):
            homes += [v for v in d.values() if isinstance(v, str)]
    except (OSError, ValueError):
        pass
    out = []
    for h in homes:
        h = os.path.abspath(os.path.expanduser(h))
        if h not in out:
            out.append(h)
    return out


def run(argv):
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    return p.returncode, p.stdout


def node_root():
    return os.path.abspath(os.path.expanduser(
        os.environ.get("FLEET_INSTALL_NODE_ROOT") or "~/.claude/fleet"))


def check(root):
    """(have, missing_lines, notes) per category."""
    files = expand(root)
    cdir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    gconf = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~"), ".claude.json")
    blocked = overrides()
    missing = {c: [] for c in CATEGORIES}
    notes = {}
    client = os.path.abspath(root) != node_root()
    plugin = any(os.path.isfile(os.path.join(cdir, "plugins", "cache", m, "fleet", v, "commands", "fleet-claim.md"))
                 for m in _ls(os.path.join(cdir, "plugins", "cache"))
                 for v in _ls(os.path.join(cdir, "plugins", "cache", m, "fleet")))

    # hooks — by identity (fleet-hooks-merge.py check), the wiring a client gets included
    argv = [sys.executable, os.path.join(root, "bin", "fleet-hooks-merge.py"), "check",
            "--source", os.path.join(root, "hooks", "settings-hooks.json"),
            "--settings", os.path.join(cdir, "settings.json")]
    if plugin:
        argv.append("--plugin")
    rc, out = run(argv)
    if rc == 0:
        notes["hooks"] = out.split()[1] if out.startswith("ok ") else "ok"
    else:
        for line in out.strip().split("\n"):
            if line.strip():
                missing["hooks"].append("missing  hooks   " + " ".join(line.split()))

    # skills — Claude's skills + commands, every Codex home's copies of both
    skills = [p.split("/")[1] for p, c in files if c == "skills" and p.count("/") == 2 and p.endswith("/SKILL.md")]
    skills = [n for n in skills if marked_skill(os.path.join(root, "skills", n))]
    commands = [p.split("/", 1)[1] for p, c in files
                if c == "commands" and p.startswith("commands/") and p.count("/") == 1
                and is_command(os.path.join(root, p))]
    n_sk = 0
    if not plugin and not shielded("claude.skills", blocked):
        for n in skills:
            n_sk += 1
            if not os.path.isfile(os.path.join(cdir, "skills", n, "SKILL.md")):
                missing["skills"].append("missing  skills  claude skill %s" % n)
    if not plugin and not shielded("claude.commands", blocked):
        for b in commands:
            n_sk += 1
            if not os.path.isfile(os.path.join(cdir, "commands", b)):
                missing["skills"].append("missing  skills  claude command /%s" % b[:-3])
    if not shielded("codex.skills", blocked):
        for h in codex_homes():
            if not os.path.isdir(h):
                continue
            tag = "codex" if h == os.path.abspath(os.path.expanduser(
                os.environ.get("CODEX_HOME") or "~/.codex")) else "codex[%s]" % h
            for n in skills + [b[:-3] for b in commands]:
                n_sk += 1
                if not os.path.isfile(os.path.join(h, "skills", n, "SKILL.md")):
                    missing["skills"].append("missing  skills  %s skill %s" % (tag, n))
    notes["skills"] = str(n_sk)

    # mcp — the servers, the doc block and Codex's keys (fleet-agent-defaults.py check)
    argv = [sys.executable, os.path.join(root, "bin", "fleet-agent-defaults.py"), "check",
            "--root", root, "--claude-config", gconf, "--claude-md", os.path.join(cdir, "CLAUDE.md"),
            "--claude-skills", ""]
    if client:
        argv += ["--scripts-root", root]
    rc, out = run(argv)
    lines = [l for l in out.strip().split("\n") if l.strip()]
    if rc == 0:
        notes["mcp"] = "ok"
    elif rc == 1:
        for line in lines[1:]:
            if " skill " not in line:
                missing["mcp"].append("missing  mcp     " + " ".join(line.split()[1:]))
        if not missing["mcp"]:
            notes["mcp"] = "ok"
    else:
        missing["mcp"].append("missing  mcp     fleet-agent-defaults.py check: %s" % (lines[-1] if lines else rc))

    # mod — the plugin folder every fleet-launched Claude loads (#1335)
    pj = os.path.join(root, "mod", "fleet", ".claude-plugin", "plugin.json")
    try:
        notes["mod"] = json.load(open(pj)).get("version") or "?"
    except (OSError, ValueError):
        missing["mod"].append("missing  mod     %s" % pj)
    return files, missing, notes


def _ls(d):
    try:
        return sorted(os.listdir(d))
    except OSError:
        return []


def team_status(root):
    """The team layer applied here (issue #1726) — '' when there never was one."""
    t = os.path.join(root, "bin", "fleet-agent-team.py")
    if not os.path.isfile(t):
        return ""
    try:
        return subprocess.run([sys.executable, t, "status", "--short"], capture_output=True,
                              text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def summary(root):
    files, missing, notes = check(root)
    have = [c for c in CATEGORIES if not missing[c]]
    ver = version(root, files)
    parts = []
    for c in CATEGORIES:
        if missing[c]:
            parts.append("%s ✗%d" % (c, len(missing[c])))
        else:
            parts.append("%s %s" % (c, notes.get(c, "ok")))
    head = "%d/4 · %s · package %s" % (len(have), " · ".join(parts), ver)
    team = team_status(root)
    if team:
        head += " · " + team
    lines = [l for c in CATEGORIES for l in missing[c]]
    return len(have) == 4, head, lines


def iterm_clipboard():
    """The `clipboard` row (issue #1766): text selected in another machine's
    session reaches this computer as OSC 52, which iTerm2 drops unless
    「Applications in terminal may access clipboard」 is on. Advice only —
    never counted in the exit code, never changed for the person. None = no
    iTerm2 here (not macOS, or never run), so no row."""
    val = os.environ.get("FLEET_ITERM_CLIPBOARD")  # selftest seam
    if val is None:
        plist = os.path.expanduser("~/Library/Preferences/com.googlecode.iterm2.plist")
        if sys.platform != "darwin" or not os.path.exists(plist):
            return None
        try:
            r = subprocess.run(["defaults", "read", "com.googlecode.iterm2", "AllowClipboardAccess"],
                               capture_output=True, text=True, timeout=5)
        except Exception:
            return None
        val = r.stdout.strip() if r.returncode == 0 else ""  # unset = iTerm2's default, off
    if val == "none":
        return None
    if val in ("1", "true", "YES"):
        return "  PASS  %-8s iTerm2 lets programs set the clipboard — a selection in a session pastes here" % "clipboard"
    return ("  WARN  %-8s iTerm2 drops the clipboard a program sends: text selected in a session will not paste here "
            "(iTerm2 → Settings → General → Selection → 「Applications in terminal may access clipboard」)" % "clipboard")


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0
    action, rest = argv[0], argv[1:]
    root, cat, dry = DEFAULT_ROOT, False, False
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--root" and i + 1 < len(rest):
            root = os.path.abspath(os.path.expanduser(rest[i + 1]))
            i += 2
            continue
        if a == "--category":
            cat = True
        elif a == "--dry-run":
            dry = True
        else:
            die("unknown argument %s (--help)" % a)
        i += 1
    if action == "files":
        for p, c in expand(root):
            print("%s %s" % (p, c) if cat else p)
        return 0
    if action == "version":
        print(version(root))
        return 0
    if action == "check":
        ok, head, lines = summary(root)
        print(("ok " if ok else "") + head)
        for l in lines:
            print(l)
        return 0 if ok else 1
    if action == "doctor":
        ok, head, lines = summary(root)
        word = "PASS" if ok else "WARN"
        fix = "" if ok else (" (fix: %s apply — fill only; keep one for this login in "
                             "~/.config/claude-fleet/agent-overrides.json)" % os.path.join(root, "bin", "fleet-agent-bundle.py"))
        print("  %s  %-8s %s%s" % (word, "agents", head, fix))
        for l in lines:
            print("            " + l)
        clip = iterm_clipboard()
        if clip is not None:
            print(clip)
        return 0 if ok else 1
    if action == "apply":
        cmd = ["bash", os.path.join(root, "bin", "fleet-install-apply.sh"), "--bundle", "--root", root]
        if dry:
            cmd.append("--dry-run")
        os.execvp("bash", cmd)
    die("unknown action %s (files · version · check · doctor · apply)" % action)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
