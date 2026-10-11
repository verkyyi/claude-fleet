#!/usr/bin/env python3
"""fleet-plugins.py — this repo IS a Claude Code plugin marketplace (issue #3112,
EPIC #3111 C1).

Orchestration, the steward and EPIC batches are three standard plugins under
plugins/ (fleet-orchestrate · fleet-steward · fleet-epic), listed beside the core
`fleet` plugin in .claude-plugin/marketplace.json. Installing, uninstalling,
enabling and disabling them is Claude Code's own `/plugin` (or `claude plugin
install|uninstall|enable|disable`) — the fleet keeps NO record of what is
installed: to know, it asks `claude plugin list --json`, and this file is the ONE
place that asks.

  ensure  --root R [--source S] [--claude C] [--claude-dir D] [--gone F] [--dry-run]
          fleet-install-apply.sh's `plugins` pass on a hosting login:
          · add the marketplace from S (default: market_source(R)) when it is
            not added yet, or re-point it when it was added from elsewhere.
            market_source: R as spelled (~/.claude/fleet, never its resolved
            fleet.versions/<sha>, so it follows every version switch) — unless
            R is a managed login's LINK TREE (every file a symlink into the
            runtime, issue #2774): Claude Code's install copies no symlink
            that leaves the marketplace (measured: an empty cache, version
            `unknown`, the dependency not pulled), so the source is then the
            runtime's real tree — <runtime>/current when it is that version
            (it moves with every switch), else the version dir;
          · carry-over: F lists the paths that left the install this apply (its
            GONE list). A part that moved into a plugin — skills/<x>/… now at
            plugins/<p>/skills/<x>/, commands/<x>.md now at
            plugins/<p>/commands/<x>.md, an agent file the core shipped
            (conf/agent-defaults/claude/agents/<x>.md, in D/agents) now at
            plugins/<p>/agents/<x>.md — that this login still HAS installed in
            D (a fleet copy) means the person used it: install <p> so nothing
            they did yesterday breaks. A fresh login never had one, so it gets
            none: a new install has no plugin;
          · update an installed plugin of ours whose version is behind the
            runtime's (`version` != `folderVersion` — Claude Code's own reading).
          Never installs anything else. Exit 0 ok · 1 a step failed · 2 usage.
  doctor  --root R [--claude C]
          one line for fleet-doctor's `plugins` row: each of our plugins installed
          (and its version) or not, 落后 when behind the runtime. Exit 0 ok ·
          1 WARN (marketplace not added, a plugin behind) · 3 nothing to say (no
          claude, no marketplace.json).
  names   --root R
          our plugin names, one a line (marketplace entries under ./plugins/).
"""
import argparse
import json
import os
import subprocess
import sys

TIMEOUT = 60


def market(root):
    try:
        with open(os.path.join(root, ".claude-plugin", "marketplace.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def ours(m):
    """{name: dir} for the marketplace entries that live under ./plugins/."""
    out = {}
    for p in (m or {}).get("plugins") or []:
        src = p.get("source")
        if isinstance(src, str) and src.startswith("./plugins/") and p.get("name"):
            out[p["name"]] = src[2:].rstrip("/")
    return out


def run(claude, *args):
    try:
        r = subprocess.run([claude, "plugin"] + list(args), capture_output=True, text=True,
                           timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)
    return r.returncode, r.stdout, r.stderr


def jlist(claude, *args):
    rc, out, err = run(claude, *args)
    if rc != 0:
        return None, (err or out).strip().splitlines()[-1:] or ["exit %d" % rc]
    try:
        return json.loads(out), None
    except ValueError:
        return None, ["unreadable --json output"]


def listed(claude, cache=""):
    """`claude plugin list --json` as a list, or (None, why). With a cache file it is
    asked once per change of what is installed — the plugins dir, its
    installed_plugins.json and settings.json move when /plugin installs, enables or
    removes one — so a session launch (fleet-codex-plugins.py) costs no node start."""
    if not cache:
        return jlist(claude, "list", "--json")
    cdir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    stamp = [claude]
    for pth in (os.path.join(cdir, "plugins"), os.path.join(cdir, "plugins", "installed_plugins.json"),
                os.path.join(cdir, "settings.json")):
        try:
            stamp.append(os.stat(pth).st_mtime_ns)
        except OSError:
            stamp.append(0)
    try:
        with open(cache) as f:
            c = json.load(f)
        if c.get("stamp") == stamp and isinstance(c.get("rows"), list):
            return c["rows"], None
    except (OSError, ValueError, AttributeError):
        pass
    lst, why = jlist(claude, "list", "--json")
    if lst is not None:
        try:
            os.makedirs(os.path.dirname(cache), exist_ok=True)
            tmp = "%s.%d.tmp" % (cache, os.getpid())
            with open(tmp, "w") as f:
                json.dump({"stamp": stamp, "rows": lst}, f)
            os.replace(tmp, cache)
        except OSError:
            pass
    return lst, why


def installed(claude, mname, cache=""):
    """{plugin name: entry} of this marketplace's installed plugins, or (None, why)."""
    lst, why = listed(claude, cache)
    if lst is None:
        return None, why
    got = {}
    for e in lst if isinstance(lst, list) else []:
        pid = str(e.get("id") or "")
        if pid.endswith("@" + mname):
            got[pid[: -len(mname) - 1]] = e
    return got, None


def market_added(claude, mname):
    """(the path it was added from — "" when added with none — or False, why)."""
    lst, why = jlist(claude, "marketplace", "list", "--json")
    if lst is None:
        return None, why
    for e in lst:
        if isinstance(e, dict) and e.get("name") == mname:
            return e.get("path") or e.get("installLocation") or "", None
    return False, None


def market_source(root):
    """Where to add the marketplace from (see ensure in the module doc)."""
    mj = os.path.join(root, ".claude-plugin", "marketplace.json")
    if not os.path.islink(mj):
        return root
    real = os.path.dirname(os.path.dirname(os.path.realpath(mj)))
    cur = os.path.join(os.path.dirname(real), "current")
    if os.path.islink(cur) and os.path.realpath(cur) == real:
        return cur
    return real


def carried(root, plugs, gone, cdir):
    """The plugins whose moved-out parts this login still has installed."""
    want = set()
    for path in gone:
        path = path.strip()
        part = None
        if path.startswith("skills/") and path.count("/") >= 2:
            x = path.split("/")[1]
            part, sub, have = x, "skills/" + x, os.path.join(cdir, "skills", x, "SKILL.md")
        elif path.startswith("commands/") and path.endswith(".md") and path.count("/") == 1:
            x = path[len("commands/"):]
            part, sub, have = x, "commands/" + x, os.path.join(cdir, "commands", x)
        elif path.startswith("conf/agent-defaults/claude/agents/") and path.endswith(".md") \
                and path.count("/") == 4:
            # an agent file the core shipped into ~/.claude/agents (issue #3116:
            # epic-driver now rides fleet-epic) — the agentfiles pass retires it
            x = path.rsplit("/", 1)[1]
            part, sub, have = x, "agents/" + x, os.path.join(cdir, "agents", x)
        if part is None or not os.path.exists(have):
            continue
        for name, d in plugs.items():
            if os.path.exists(os.path.join(root, d, sub)):
                want.add(name)
    return sorted(want)


def behind(e):
    v, fv = e.get("version"), e.get("folderVersion")
    return bool(v and fv and v != fv)


def cmd_ensure(a):
    m = market(a.root)
    if m is None:
        print("plugins: skip — no .claude-plugin/marketplace.json in this version")
        return 0
    mname, plugs = m.get("name") or "claude-fleet", ours(m)
    fails = 0
    added, why = market_added(a.claude, mname)
    if added is None:
        print("plugins: skip — `%s plugin marketplace list` failed: %s" % (a.claude, "; ".join(why)))
        return 0
    src = a.source or market_source(a.root)
    if added is False or (added and added != src):
        was = "" if added is False else " (was %s)" % added
        added = False
        if a.dry_run:
            print("plugins: would add the %s marketplace from %s%s" % (mname, src, was))
        else:
            rc, out, err = run(a.claude, "marketplace", "add", src)
            if rc == 0:
                print("plugins: added the %s marketplace from %s%s (nothing installed)" % (mname, src, was))
            else:
                print("plugins: FAIL marketplace add %s: %s" % (src, (err or out).strip().splitlines()[-1:]))
                return 1
    gone = []
    if a.gone:
        try:
            with open(a.gone) as f:
                gone = [l for l in f.read().splitlines() if l.strip()]
        except OSError:
            pass
    have, why = ({}, None) if (a.dry_run and not added) else installed(a.claude, mname)
    if have is None:
        print("plugins: FAIL `%s plugin list --json`: %s" % (a.claude, "; ".join(why)))
        return 1
    for name in carried(a.root, plugs, gone, a.claude_dir):
        if name in have:
            continue
        pid = "%s@%s" % (name, mname)
        if a.dry_run:
            print("plugins: would install %s — this login had its parts before they moved into it" % pid)
            continue
        rc, out, err = run(a.claude, "install", pid)
        if rc == 0:
            print("plugins: installed %s — this login had its parts before they moved into it" % pid)
        else:
            fails += 1
            print("plugins: FAIL install %s: %s" % (pid, (err or out).strip().splitlines()[-1:]))
    for name, e in sorted(have.items()):
        if name in plugs and behind(e):
            pid = "%s@%s" % (name, mname)
            if a.dry_run:
                print("plugins: would update %s %s → %s" % (pid, e.get("version"), e.get("folderVersion")))
                continue
            rc, out, err = run(a.claude, "update", pid)
            if rc == 0:
                print("plugins: updated %s %s → %s (takes effect in the next session)"
                      % (pid, e.get("version"), e.get("folderVersion")))
            else:
                fails += 1
                print("plugins: FAIL update %s: %s" % (pid, (err or out).strip().splitlines()[-1:]))
    if not fails:
        print("plugins: ok — %s marketplace added · installed: %s" % (
            mname, ", ".join(sorted(n for n in have if n in plugs)) or "none"))
    return 1 if fails else 0


def cmd_doctor(a):
    m = market(a.root)
    if m is None:
        return 3
    mname, plugs = m.get("name") or "claude-fleet", ours(m)
    added, why = market_added(a.claude, mname)
    if added is None:
        return 3
    if added is False:
        print("the %s marketplace is not added — /plugin cannot offer %s (the next sync adds it, or now: "
              "claude plugin marketplace add ~/.claude/fleet)" % (mname, " · ".join(sorted(plugs))))
        return 1
    have, why = installed(a.claude, mname)
    if have is None:
        print("`claude plugin list --json` failed: %s" % "; ".join(why))
        return 1
    bits, late = [], []
    for name in sorted(plugs):
        e = have.get(name)
        if e is None:
            bits.append("%s 未装" % name)
        elif behind(e):
            late.append(name)
            bits.append("%s %s 落后（运行时 %s）" % (name, e.get("version"), e.get("folderVersion")))
        else:
            bits.append("%s %s%s" % (name, e.get("version") or "?", "" if e.get("enabled", True) else " 已关"))
    line = " · ".join(bits)
    if late:
        print("%s (fix: claude plugin update <name>@%s, then reopen the session)" % (line, mname))
        return 1
    print(line)
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="fleet-plugins.py", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd")
    home = os.path.expanduser("~")
    for c in ("ensure", "doctor", "names"):
        p = sub.add_parser(c)
        p.add_argument("--root", default=os.path.join(home, ".claude", "fleet"))
        p.add_argument("--claude", default=os.environ.get("FLEET_INSTALL_CLAUDE", "claude"))
        if c == "ensure":
            p.add_argument("--source", default="")
            p.add_argument("--claude-dir", default=os.environ.get("CLAUDE_CONFIG_DIR", os.path.join(home, ".claude")))
            p.add_argument("--gone", default="")
            p.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "ensure":
        return cmd_ensure(a)
    if a.cmd == "doctor":
        return cmd_doctor(a)
    if a.cmd == "names":
        for n in sorted(ours(market(a.root))):
            print(n)
        return 0
    ap.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
