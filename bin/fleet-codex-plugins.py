#!/usr/bin/env python3
"""fleet-codex-plugins.py — a Codex session reads the same plugins, through Codex's
OWN plugin manager (issue #3123 made the bridge; T589 / EPIC T580 C3 retired it).

Plugins are still installed in one place only: Claude Code's /plugin (CLAUDE.md
«This repo is a plugin marketplace»). What the Claude side has installed AND
enabled of this repo's marketplace (fleet-epic · fleet-browser · …) — asked of
`claude plugin list --json` through fleet-plugins.py, the one reader; nothing is
recorded a second time — is FOLLOWED in every Codex home by Codex's native
installer, at install time (fleet-install-apply.sh), never at a session launch:

  marketplace  `codex plugin marketplace add <the same source Claude added>`; one
               added from another source is removed and re-added.
  install      `codex plugin add <plugin>@<marketplace>` for a plugin Claude has and
               the home lacks, or holds at another version (the plugin.json
               version — a plugin bumps it whenever its files change). Codex copies
               it into $CODEX_HOME/plugins/cache/ and serves its skills
               (`<plugin>:<skill>`), commands (`<plugin>:source-command-<c>`), hooks
               and .mcp.json itself.
  remove       `codex plugin remove` for one of OUR marketplace's plugins Claude no
               longer has installed and enabled. Any other marketplace's plugin is
               the login's and never touched.
  retire       the old bridge's products are cleared from the home first: a
               `fleet-plugin-*` skill link into Claude's plugin cache or this tree's
               plugins/, a marked single-file adapter skill, the paired marker block
               in config.toml. A personal entry there (no link of ours, no mark) is
               left alone and said.

`codex.plugins` (or `codex`) in agent-overrides.json ⇒ this login manages Codex's
plugins itself: nothing is done. No codex binary ⇒ the home is only retired.
Not carried (the doctor's `plugins` row lists them): mod interface modules,
PreCompact (Codex has no such event), an agent file's `tools` limits. A plugin
hook is untrusted to Codex until reviewed; the fleet's launcher runs Codex with
--dangerously-bypass-hook-trust (as it did for the bridge's injected hooks).

  sync   [--codex-home D]… [--root R] [--claude C] [--codex X] [--cache F] [--override F] [--dry-run]
         One line per change (`retire` · `market` · `add` · `remove`), ending
         `ok — N change(s)` or `unchanged`. A home that does not exist is skipped.
         --print-dirs (compat-1v: 下一批删 — the old launcher's form) prints nothing on stdout.
  dirs   compat-1v: 下一批删 — prints nothing (plugin hooks are Codex's own now).
  retire [--codex-home D]… [--root R] [--claude C] [--apply]
         only the bridge cleanup, preview unless --apply.
  mention <name> [--codex-home D]
         the name Codex lists a plugin SKILL under (`fleet-epic:epic-page`). Exit 1 none.
  command <name> [--codex-home D]
         the path of a natively installed plugin COMMAND's .md (bin/fleet-codex.sh
         expands a `/name` seed from it). Exit 1 none.
  doctor [--codex-home D]… [--root R] [--claude C] [--cache F]
         one clause for fleet-doctor's `plugins` row. Exit 0 printed · 3 nothing to
         say (no Codex home, or none of our plugins installed).

Exit 0 ok · 1 a home could not be written · 2 usage / unreadable input.
"""
import argparse
import contextlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PREFIX = "fleet-plugin-"
MARK = "<!-- fleet codex plugin skill -->"
BEGIN = "# >>> fleet plugins — bin/fleet-codex-plugins.py sync writes this block; edit outside it >>>"
END = "# <<< fleet plugins <<<"
CONF_DIR = os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet")
TIMEOUT = 120


def _load(name, fname):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, fname))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


PL = _load("fleet_plugins", "fleet-plugins.py")
AD = _load("fleet_agent_defaults", "fleet-agent-defaults.py")

GAPS = [
    "mod 界面模块（插件的 .tsx 模块，Codex 没有）",
    "PreCompact（Codex 没有这个事件）",
    "agent 文件的 tools 限制",
]


def any_installed(mname):
    """Claude Code's own installed_plugins.json names a plugin of ours? Only then is
    `claude plugin list` asked — a Codex launch on a login with none starts no node
    (and a missing file means none: /plugin writes it on the first install)."""
    cdir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    try:
        with open(os.path.join(cdir, "plugins", "installed_plugins.json"), encoding="utf-8") as f:
            return ("@%s\"" % mname) in f.read()
    except OSError:
        return False


def plugins(a):
    """[(name, dir)] of this marketplace's plugins installed AND enabled on the
    Claude side, or None when that cannot be told (no marketplace, no claude)."""
    m = PL.market(a.root)
    if m is None:
        return None
    ours, mname = PL.ours(m), m.get("name") or "claude-fleet"
    if not any_installed(mname):
        return []                               # nothing of ours: no node start at all
    have, _why = PL.installed(a.claude, mname, a.cache)
    if have is None:
        return None
    out = []
    for name in sorted(have):
        e = have[name]
        if name not in ours or e.get("enabled", True) is False:
            continue
        d = e.get("installPath") or e.get("readFromFolder") or ""
        if isinstance(d, str) and os.path.isdir(d):
            out.append((name, d))
    return out


def split_block(text):
    """(text without our block, the block's lines or None, malformed?)."""
    lines = text.split("\n")
    if BEGIN not in lines and END not in lines:
        return text, None, False
    if BEGIN not in lines or END not in lines or lines.index(END) < lines.index(BEGIN):
        return text, None, True
    b, e = lines.index(BEGIN), lines.index(END)
    block = lines[b:e + 1]
    del lines[b:e + 1]
    if b > 0 and lines[b - 1] == "":
        del lines[b - 1]                       # the one blank line sync put before it
    return "\n".join(lines), block, False


def write(path, text):
    target = os.path.realpath(path)
    descriptor, temporary = tempfile.mkstemp(prefix=".fleet-codex-plugins.", dir=os.path.dirname(target))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as output:
            output.write(text)
        if os.path.exists(target):
            shutil.copymode(target, temporary)
        os.replace(temporary, target)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def market_name(root):
    m = PL.market(root)
    return None if m is None else (m.get("name") or "claude-fleet")


def versions(root):
    """{plugin: version} of this tree's marketplace plugins (their plugin.json)."""
    m = PL.market(root)
    out = {}
    for name, rel in PL.ours(m).items():
        try:
            with open(os.path.join(root, rel, ".claude-plugin", "plugin.json"), encoding="utf-8") as f:
                out[name] = str(json.load(f).get("version") or "")
        except (OSError, ValueError, AttributeError):
            out[name] = ""
    return out


def homes(a):
    out = []
    for h in (a.codex_home or AD.default_codex_homes()):
        h = os.path.abspath(os.path.expanduser(h))
        if h not in out:
            out.append(h)
    return out


def find_cli(a):
    for c in (a.codex, "codex", os.path.expanduser("~/.local/bin/codex")):
        if c and (os.path.sep in c and os.access(c, os.X_OK) or shutil.which(c)):
            return c if os.path.sep in c else shutil.which(c)
    return None


def native_cli(binary, home, *args):
    """(rc, stdout, stderr) of `codex plugin …` against one home."""
    env = dict(os.environ, CODEX_HOME=home)
    try:
        r = subprocess.run([binary, "plugin"] + list(args), capture_output=True, text=True,
                           timeout=TIMEOUT, env=env, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, "", str(exc)
    return r.returncode, r.stdout, r.stderr


def last(text):
    lines = [x for x in (text or "").strip().splitlines() if x.strip()]
    return lines[-1] if lines else ""


# --- what a home holds natively ---------------------------------------------------

def native(home, mname):
    """{plugin: (enabled, version or "")} of mname's plugins this home's config.toml
    lists, the version read off the plugin cache Codex keeps (the newest dir)."""
    try:
        with open(os.path.join(home, "config.toml"), encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return {}
    out, cur = {}, None
    head = re.compile(r'^\[plugins\.["\']?([^"\'\]]+)@%s["\']?\]\s*$' % re.escape(mname))
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("["):
            m = head.match(s)
            cur = m.group(1) if m else None
            if cur:
                out[cur] = True
            continue
        if cur and re.match(r"^enabled\s*=\s*false\b", s):
            out[cur] = False
    res = {}
    for name, enabled in out.items():
        d = os.path.join(home, "plugins", "cache", mname, name)
        vers = sorted((v for v in (os.listdir(d) if os.path.isdir(d) else [])
                       if os.path.isdir(os.path.join(d, v))),
                      key=lambda v: os.path.getmtime(os.path.join(d, v)))
        res[name] = (enabled, vers[-1] if vers else "")
    return res


def native_dir(home, mname, name):
    have = native(home, mname).get(name)
    if not have or not have[0] or not have[1]:
        return None
    return os.path.join(home, "plugins", "cache", mname, name, have[1])


def market_source_of(home, mname):
    """The source this home added mname from, read off config.toml ("" none)."""
    try:
        with open(os.path.join(home, "config.toml"), encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return ""
    sect = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("["):
            sect = s in ("[marketplaces.%s]" % mname, '[marketplaces."%s"]' % mname)
            continue
        m = re.match(r'^source\s*=\s*"(.*)"\s*$', s) if sect else None
        if m:
            return m.group(1)
    return ""


# --- the old bridge's products ----------------------------------------------------

def bridge_plan(home, root):
    """[(kind, path, before, after)] the old bridge left in this home, and
    [(path, why)] entries under its prefix that are not provably ours."""
    plan, own = [], []
    cdir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    mname = market_name(root) or "claude-fleet"
    roots = [os.path.join(cdir, "plugins", "cache", mname) + os.sep, os.path.join(root, "plugins") + os.sep]
    roots += [os.path.realpath(r.rstrip(os.sep)) + os.sep for r in roots]
    skills = os.path.join(home, "skills")
    names = sorted(os.listdir(skills)) if os.path.isdir(skills) and not os.path.islink(skills) else []
    for name in names:
        if not name.startswith(PREFIX):
            continue
        path = os.path.join(skills, name)
        if os.path.islink(path):
            target = os.readlink(path)
            if not os.path.isabs(target):
                target = os.path.normpath(os.path.join(skills, target))
            if any(target.startswith(r) for r in roots):
                plan.append(("link", path, os.readlink(path), None))
            else:
                own.append((path, "a link not into a fleet plugin"))
            continue
        skill = os.path.join(path, "SKILL.md")
        if os.path.islink(skill) or not os.path.isfile(skill):
            own.append((path, "not a marked adapter"))
            continue
        with open(skill, encoding="utf-8", newline="") as f:
            content = f.read()
        if MARK not in content:
            own.append((path, "not a marked adapter"))
        elif os.listdir(path) != ["SKILL.md"]:
            own.append((path, "a marked adapter with files of yours beside it"))
        else:
            plan.append(("skill", skill, content, None))
    config = os.path.join(home, "config.toml")
    if os.path.isfile(config) and not os.path.islink(config):
        with open(config, encoding="utf-8", newline="") as f:
            content = f.read()
        if BEGIN in content or END in content:
            lines = content.split("\n")
            outside, _block, malformed = split_block(content)
            if malformed or lines.count(BEGIN) != 1 or lines.count(END) != 1:
                own.append((config, "a fleet plugins marker without its pair"))
            else:
                plan.append(("config", config, content, outside))
    return plan, own


def retire_home(home, root, apply):
    """Returns (changes, failed)."""
    plan, own = bridge_plan(home, root)
    for path, why in own:
        print("own     %s — %s; left alone" % (path, why))
    bad = False
    for kind, path, _before, after in plan:
        print("retire  %s %s%s" % (kind, path, "" if apply else " (preview)"))
        if not apply:
            continue
        try:
            if kind == "config":
                write(path, after)
            else:
                os.unlink(path)
                if kind == "skill":
                    os.rmdir(os.path.dirname(path))
        except OSError as exc:
            print("FAIL    retire %s: %s" % (path, exc))
            bad = True
    return len(plan), bad


# --- follow ----------------------------------------------------------------------

def follow_home(home, a, binary, mname, want, dry):
    """Native install of `want` ({plugin: version}) in one home; returns (changes, failed)."""
    n, bad = 0, False
    have = native(home, mname)
    src = PL.market_source(a.root)
    if want or have:
        cur = market_source_of(home, mname)
        if cur != src:
            print("market  %s %s → %s" % (home, mname, src))
            n += 1
            if not dry:
                if cur:
                    native_cli(binary, home, "marketplace", "remove", mname)
                rc, out, err = native_cli(binary, home, "marketplace", "add", src)
                if rc != 0:
                    print("FAIL    %s marketplace add %s: %s" % (home, src, last(err or out)))
                    return n, True
    for name in sorted(want):
        got = have.get(name)
        if got and got[0] and got[1] == want[name]:
            continue
        print("add     %s %s@%s %s" % (home, name, mname, want[name] or "?"))
        n += 1
        if dry:
            continue
        rc, out, err = native_cli(binary, home, "add", "%s@%s" % (name, mname))
        if rc != 0:
            print("FAIL    %s plugin add %s@%s: %s" % (home, name, mname, last(err or out)))
            bad = True
    for name in sorted(set(have) - set(want)):
        print("remove  %s %s@%s" % (home, name, mname))
        n += 1
        if dry:
            continue
        rc, out, err = native_cli(binary, home, "remove", "%s@%s" % (name, mname))
        if rc != 0:
            print("FAIL    %s plugin remove %s@%s: %s" % (home, name, mname, last(err or out)))
            bad = True
    return n, bad


def cmd_sync(a):
    with contextlib.redirect_stdout(sys.stderr if a.print_dirs else sys.stdout):
        return sync(a)


def sync(a):
    if AD.shielded("codex.plugins", AD.override_paths(a.override, [])):
        print("unchanged — codex.plugins is this login's own (agent-overrides.json)")
        return 0
    mname = market_name(a.root)
    plugs = plugins(a)
    if plugs is None or mname is None:
        print("unchanged — cannot tell what the Claude side has installed (no claude / no marketplace)")
        return 0
    vers = versions(a.root)
    want = {name: vers.get(name, "") for name, _d in plugs}
    binary = find_cli(a)
    total, bad = 0, False
    for home in homes(a):
        if not os.path.isdir(home):
            continue
        n, b = retire_home(home, a.root, not a.dry_run)
        total, bad = total + n, bad or b
        if binary is None:
            if want:
                print("skip    %s — no codex binary here; %s not installed natively" % (home, ", ".join(sorted(want))))
            continue
        n, b = follow_home(home, a, binary, mname, want, a.dry_run)
        total, bad = total + n, bad or b
    names = ", ".join(sorted(want)) or "none"
    if total:
        print("ok — %d change(s)%s · plugins: %s (native)" % (total, " (dry run)" if a.dry_run else "", names))
    else:
        print("unchanged · plugins: %s (native)" % names)
    return 1 if bad else 0


def cmd_retire(a):
    total, bad = 0, False
    for home in dict.fromkeys(os.path.realpath(h) for h in homes(a)):
        if os.path.isdir(home):
            n, b = retire_home(home, a.root, a.apply)
            total, bad = total + n, bad or b
    print("ok — %d bridge artifact(s)%s; native plugins and user files left alone" % (
        total, " retired" if a.apply else " (preview only; use --apply after review)"))
    return 1 if bad else 0


def cmd_mention(a):
    mname = market_name(a.root) or "claude-fleet"
    for home in homes(a)[:1]:
        for name in sorted(native(home, mname)):
            d = native_dir(home, mname, name)
            if d and os.path.isfile(os.path.join(d, "skills", a.name, "SKILL.md")):
                print("%s:%s" % (name, a.name))
                return 0
    return 1


def cmd_command(a):
    mname = market_name(a.root) or "claude-fleet"
    for home in homes(a)[:1]:
        for name in sorted(native(home, mname)):
            d = native_dir(home, mname, name)
            f = d and os.path.join(d, "commands", a.name + ".md")
            if f and os.path.isfile(f):
                print(f)
                return 0
    return 1


def cmd_doctor(a):
    hs = [h for h in homes(a) if os.path.isdir(h)]
    if not hs:
        return 3
    plugs = plugins(a)
    mname = market_name(a.root)
    if not plugs or mname is None:
        return 3
    vers = versions(a.root)
    lack, left = [], 0
    for home in hs:
        have = native(home, mname)
        for name, _d in plugs:
            got = have.get(name)
            if not got or not got[0] or got[1] != vers.get(name, ""):
                lack.append(name)
        left += len(bridge_plan(home, a.root)[0])
    said = "Codex 原生装着 %s" % ", ".join(sorted(n for n, _d in plugs))
    if lack:
        said = "Codex 原生缺 / 落后 %s（下次同步装上）" % ", ".join(sorted(set(lack)))
    if left:
        said += " · 旧桥残留 %d 项（下次同步清掉）" % left
    print("%s；带不过去：%s" % (said, " · ".join(GAPS)))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="fleet-codex-plugins.py", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd")
    for c in ("sync", "dirs", "retire", "doctor", "mention", "command"):
        p = sub.add_parser(c)
        p.add_argument("--root", default=os.path.dirname(HERE))
        p.add_argument("--claude", default=os.environ.get("FLEET_INSTALL_CLAUDE", "claude"))
        p.add_argument("--codex", default=os.environ.get("FLEET_INSTALL_CODEX", ""))
        p.add_argument("--cache", default=os.path.join(CONF_DIR, "codex", "plugins.json"),
                       help="'' = ask claude every time")
        p.add_argument("--codex-home", action="append", default=[])
        if c in ("mention", "command"):
            p.add_argument("name")
        p.add_argument("--override", default=os.path.join(CONF_DIR, "agent-overrides.json"))
        if c == "sync":
            p.add_argument("--dry-run", action="store_true")
            p.add_argument("--print-dirs", action="store_true", help="compat-1v: 下一批删 — prints nothing")
        if c == "retire":
            p.add_argument("--apply", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd:
        a.root = os.path.abspath(a.root)
    if a.cmd == "dirs":
        return 0                                # compat-1v: 下一批删
    fn = {"sync": cmd_sync, "retire": cmd_retire, "doctor": cmd_doctor,
          "mention": cmd_mention, "command": cmd_command}.get(a.cmd)
    if fn is None:
        ap.print_usage(sys.stderr)
        return 2
    return fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
