#!/usr/bin/env python3
"""fleet-codex-plugins.py — a Codex session reads the same plugins (issue #3123,
EPIC #3111 C12).

Codex has no /plugin. What the Claude side has installed AND enabled of this
repo's marketplace (fleet-orchestrate · fleet-steward · fleet-epic) — asked of
`claude plugin list --json` through fleet-plugins.py, the one reader; nothing is
recorded a second time — is carried into each Codex home as far as Codex can take
it, and what it cannot take is said:

  skills      <plugin>/skills/<s>/ is LINKED as $CODEX_HOME/skills/fleet-plugin-<s>
              (Codex follows the link and names the skill by its SKILL.md `name`,
              so `$fleet-orchestrate` works); a plugin command <plugin>/commands/<c>.md
              becomes a generated adapter skill fleet-plugin-<c>/SKILL.md (marked).
              Only `fleet-plugin-*` entries are ever removed — and a personal one
              there (no link, no mark) is left alone.
  MCP         every server of the plugin's .mcp.json → ONE marker block of
              [mcp_servers.<name>] tables at the end of $CODEX_HOME/config.toml,
              with the env Codex would otherwise withhold (fleet-mcp.py's
              CODEX_ENV) and its await-sized timeout. Fill only: a server the login
              defines outside the block is the login's and never written. The rest
              of the file stays byte for byte; no plugin left ⇒ the block goes and
              the file is what it was.
  hooks       not written here: bin/fleet-codex.sh hands `dirs` to
              fleet-hooks-emit.sh --plugin-dir, which merges each plugin's
              hooks/hooks.json into the `-c hooks.*` it emits, by
              hooks/codex-map.json (an event Codex lacks — PreCompact — is dropped
              with one stderr line).
  agent files read as they are by fleet-agent-def.py (C11): body → instructions,
              `fleet.codex_model` → model.

Not carried (the doctor's `plugins` row lists them): mod interface modules (the
decision-sheet panel, /qd — Codex gets the `[decision]` text), PreCompact (no such
event: no pre-compaction snapshot; the restore on resume still runs), an agent
file's `tools` limits, and /plugin itself.

  sync   [--codex-home D]… [--root R] [--claude C] [--cache F] [--override F] [--dry-run]
         One line per change (`link` · `skill` · `unlink` · `mcp` · `own` · `drop`),
         ending `ok — N change(s)` or `unchanged`. A home that does not exist is
         skipped (Codex not set up there). `codex.plugins` in agent-overrides.json
         ⇒ nothing. bin/fleet-codex.sh runs it for its CODEX_HOME before every
         launch; fleet-install-apply.sh's agents pass for every home.
  dirs   [--root R] [--claude C] [--cache F]
         the enabled plugins' directories, one a line (for --plugin-dir).
  mention <name> [--codex-home D]
         the name Codex lists $CODEX_HOME/skills/fleet-plugin-<name> under
         (`fleet-orchestrate:fleet-orchestrate` for a linked plugin skill — Codex
         namespaces it by the plugin.json beside it — else <name>). Exit 1 none.
         bin/fleet-codex.sh turns a `/name` seed into `$<that>`.
  doctor [--codex-home D]… [--root R] [--claude C] [--cache F]
         one clause for fleet-doctor's `plugins` row. Exit 0 printed · 3 nothing to
         say (no Codex home, or none of our plugins installed).

Exit 0 ok · 1 a home could not be written · 2 usage / unreadable input.
"""
import argparse
import importlib.util
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PREFIX = "fleet-plugin-"
MARK = "<!-- fleet codex plugin skill -->"
BEGIN = "# >>> fleet plugins — bin/fleet-codex-plugins.py sync writes this block; edit outside it >>>"
END = "# <<< fleet plugins <<<"
CONF_DIR = os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet")


def _load(name, fname):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, fname))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


PL = _load("fleet_plugins", "fleet-plugins.py")
AD = _load("fleet_agent_defaults", "fleet-agent-defaults.py")
try:
    _MCP = _load("fleet_mcp", "fleet-mcp.py")
    CODEX_ENV, CODEX_TIMEOUT = list(_MCP.CODEX_ENV), int(_MCP.CODEX_TOOL_TIMEOUT_S)
except Exception:  # noqa: BLE001 — a launch never fails over the constants
    CODEX_ENV = ["TMUX", "TMUX_PANE", "FLEET_CONF_DIR", "FLEET_SESSION", "FLEET_WORKER_CRED",
                 "FLEET_MCP_BIN", "FLEET_MCP_ORCH"]
    CODEX_TIMEOUT = 600

GAPS = [
    "mod 界面模块（决定单面板、/qd；Codex 收文字版 [decision]）",
    "PreCompact（Codex 没有这个事件：压缩前存档不做，恢复时补回照做）",
    "agent 文件的 tools 限制",
    "/plugin 本身（Codex 跟着 Claude 这边装了什么同步）",
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


def wanted_skills(plugs):
    """{entry name: ('link', target) | ('skill', SKILL.md text)}."""
    want = {}
    pre = ""
    try:
        with open(os.path.join(HERE, "..", "conf", "codex-preamble.md")) as f:
            pre = f.read()
    except OSError:
        pass
    for _name, d in plugs:
        sdir = os.path.join(d, "skills")
        for s in sorted(os.listdir(sdir)) if os.path.isdir(sdir) else []:
            if os.path.isfile(os.path.join(sdir, s, "SKILL.md")):
                want[PREFIX + s] = ("link", os.path.join(sdir, s))
        cdir = os.path.join(d, "commands")
        for c in sorted(os.listdir(cdir)) if os.path.isdir(cdir) else []:
            if not c.endswith(".md"):
                continue
            n = c[:-3]
            try:
                with open(os.path.join(cdir, c)) as f:
                    body = f.read()
            except OSError:
                continue
            want.setdefault(PREFIX + n, ("skill", adapter(n, body, pre)))
    return want


def adapter(name, body, pre):
    """The Codex skill for a plugin command — fleet-install-apply.sh's
    codex_command_skill, for a command that lives in a plugin."""
    title = ""
    for line in body.splitlines()[:1]:
        if line.startswith("# "):
            title = " ".join(line[2:].split()).replace(":", " -")
    title = title or "/" + name
    desc = ("Run the claude-fleet /%s command as a native Codex skill. Use when the user invokes "
            "/%s, $%s, or asks for this fleet command. Source: a fleet plugin's commands/%s.md (%s)."
            % (name, name, name, name, title))
    arg = "the text after this skill name"
    out = "---\nname: %s\ndescription: >-\n  %s\n---\n\n# claude-fleet Codex adapter for /%s\n\n%s\n\n" % (
        name, desc, name, MARK)
    if pre:
        out += pre.replace("$ARGUMENTS", arg) + "\n---\n\n"
    return out + body.replace("$ARGUMENTS", arg)


def wanted_servers(plugs):
    srv = {}
    for name, d in plugs:
        mj = os.path.join(d, ".mcp.json")
        if not os.path.isfile(mj):
            continue
        try:
            with open(mj) as f:
                got = (json.load(f) or {}).get("mcpServers") or {}
        except (OSError, ValueError, AttributeError):
            print("own     %s .mcp.json unreadable — skipped" % name)
            continue
        for n, v in sorted(got.items()):
            if isinstance(v, dict) and v.get("command"):
                srv.setdefault(n, v)
    return srv


def server_lines(name, v):
    lines = ["[mcp_servers.%s]" % AD.toml_key(name), "command = %s" % AD.toml_val(v["command"])]
    if v.get("args"):
        lines.append("args = %s" % AD.toml_val([str(x) for x in v["args"]]))
    if isinstance(v.get("env"), dict) and v["env"]:
        lines.append("env = %s" % AD.toml_val({k: str(x) for k, x in v["env"].items()}))
    lines.append("env_vars = %s" % AD.toml_val(CODEX_ENV))
    lines.append("tool_timeout_sec = %d" % CODEX_TIMEOUT)
    return lines


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


def with_block(text, block):
    if not block:
        return text
    if not text:
        return "\n".join(block) + "\n"
    if not text.endswith("\n"):
        text += "\n"
    return text + "\n" + "\n".join(block) + "\n"


def write(path, text):
    target = os.path.realpath(path)
    tmp = target + ".fleet-codex-plugins.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    if os.path.exists(target):
        shutil.copymode(target, tmp)
    os.replace(tmp, target)


def entry(p):
    """What a fleet-plugin-* entry IS: ('link', target) · ('skill', text) of a marked
    adapter · None (a personal one — never touched)."""
    if os.path.islink(p):
        return ("link", os.readlink(p))
    try:
        with open(os.path.join(p, "SKILL.md"), encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    return ("skill", text) if MARK in text else None


def sync_home(home, want, srv, dry):
    """Returns (changes, failed)."""
    n, bad = 0, False
    want = dict(want)
    sk = os.path.join(home, "skills")
    present = sorted(e for e in os.listdir(sk) if e.startswith(PREFIX)) if os.path.isdir(sk) else []
    for e in present:
        p = os.path.join(sk, e)
        have = entry(p)
        if have is None:
            print("own     %s — not a link or a marked adapter; left alone" % p)
            want.pop(e, None)
            continue
        if want.get(e) == have:
            del want[e]                         # already right
            continue
        if e not in want:
            print("unlink  %s" % p)
            n += 1
        if dry:
            continue
        try:
            if have[0] == "link":
                os.unlink(p)
            else:
                shutil.rmtree(p)
        except OSError as exc:
            print("FAIL    remove %s: %s" % (p, exc))
            bad = True
    for e, (kind, val) in sorted(want.items()):
        p = os.path.join(sk, e)
        if kind == "link":
            print("link    %s → %s" % (p, val))
        else:
            print("skill   %s (adapter for a plugin command)" % p)
        n += 1
        if dry:
            continue
        try:
            os.makedirs(sk, exist_ok=True)
            if kind == "link":
                os.symlink(val, p)
            else:
                os.makedirs(p, exist_ok=True)
                write(os.path.join(p, "SKILL.md"), val)
        except OSError as exc:
            print("FAIL    %s: %s" % (p, exc))
            bad = True
    # config.toml
    conf = os.path.join(home, "config.toml")
    try:
        with open(conf, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        text = ""
    except OSError as exc:
        print("FAIL    read %s: %s" % (conf, exc))
        return n, True
    outside, old, malformed = split_block(text)
    if malformed:
        print("own     %s — a fleet plugins marker without its pair; left alone" % conf)
        return n, bad
    scan = AD.TomlScan(outside)
    block = []
    for name, v in sorted(srv.items()):
        if scan.has_server(name):
            print("own     %s mcp %s — this login's" % (conf, name))
            continue
        if scan.mcp_inline():
            print("own     %s mcp %s — mcp_servers is an inline table, not extended" % (conf, name))
            continue
        block += server_lines(name, v)
        block.append("")
    if block:
        block = [BEGIN] + block[:-1] + [END]
    new = with_block(outside, block)
    if new != text:
        names = sorted(n_ for n_ in srv if ("[mcp_servers.%s]" % AD.toml_key(n_)) in block)
        print("mcp     %s %s" % (conf, ("block: " + ", ".join(names)) if block else "block removed"))
        n += 1
        if AD._toml is not None:
            try:
                AD._toml.loads(new)
            except Exception as exc:  # noqa: BLE001
                print("FAIL    %s: the merged file would not parse (%s) — nothing written" % (conf, exc))
                return n, True
        if not dry and (os.path.exists(conf) or new):
            try:
                write(conf, new)
            except OSError as exc:
                print("FAIL    write %s: %s" % (conf, exc))
                bad = True
    return n, bad


def homes(a):
    out = []
    for h in (a.codex_home or AD.default_codex_homes()):
        h = os.path.abspath(os.path.expanduser(h))
        if h not in out:
            out.append(h)
    return out


def hook_drops(plugs):
    """[(plugin, event, reason)] — the hooks.json events Codex has not."""
    try:
        with open(os.path.join(HERE, "..", "hooks", "codex-map.json")) as f:
            events = json.load(f).get("events", {})
    except (OSError, ValueError):
        events = {}
    out = []
    for name, d in plugs:
        try:
            with open(os.path.join(d, "hooks", "hooks.json")) as f:
                tbl = json.load(f).get("hooks") or {}
        except (OSError, ValueError, AttributeError):
            continue
        for ev in tbl:
            if events.get(ev) is not True:
                out.append((name, ev, events.get(ev) or "not a Codex event"))
    return out


def cmd_sync(a):
    if AD.shielded("codex.plugins", AD.override_paths(a.override, [])):
        print("unchanged — codex.plugins is this login's own (agent-overrides.json)")
        return 0
    plugs = plugins(a)
    if plugs is None:
        print("unchanged — cannot tell what the Claude side has installed (no claude / no marketplace)")
        return 0
    srv = wanted_servers(plugs)
    total, bad = 0, False
    for home in homes(a):
        if not os.path.isdir(home):
            continue
        n, b = sync_home(home, wanted_skills(plugs), srv, a.dry_run)
        total += n
        bad = bad or b
    for name, ev, why in hook_drops(plugs):
        print("drop    %s hooks %s — %s" % (name, ev, why))
    if total:
        print("ok — %d change(s)%s · plugins: %s" % (total, " (dry run)" if a.dry_run else "",
                                                   ", ".join(n for n, _ in plugs) or "none"))
    else:
        print("unchanged · plugins: %s" % (", ".join(n for n, _ in plugs) or "none"))
    return 1 if bad else 0


def cmd_dirs(a):
    for _n, d in plugins(a) or []:
        print(d)
    return 0


def cmd_mention(a):
    """How Codex lists fleet-plugin-<name>: a linked plugin skill is namespaced by
    its plugin (Codex reads the manifest beside it, as Claude Code does) —
    `fleet-orchestrate:fleet-orchestrate`; an adapter skill is its own name."""
    for home in homes(a)[:1]:
        p = os.path.join(home, "skills", PREFIX + a.name)
        have = entry(p)
        if have is None:
            return 1
        if have[0] == "skill":
            print(a.name)
            return 0
        try:
            with open(os.path.join(os.path.realpath(p), "..", "..", ".claude-plugin", "plugin.json")) as f:
                plug = json.load(f).get("name") or ""
        except (OSError, ValueError, AttributeError):
            plug = ""
        print("%s:%s" % (plug, a.name) if plug else a.name)
        return 0
    return 1


def cmd_doctor(a):
    if not any(os.path.isdir(h) for h in homes(a)):
        return 3
    plugs = plugins(a)
    if not plugs:
        return 3
    skills = len(wanted_skills(plugs))
    srv = sorted(wanted_servers(plugs))
    gaps = list(GAPS)
    for name, ev, _why in hook_drops(plugs):
        if ev != "PreCompact":
            gaps.append("%s 的 %s 钩子" % (name, ev))
    print("Codex 带过去 技能 %d%s；带不过去：%s" % (
        skills, (" · 工具服务 " + ", ".join(srv)) if srv else "", " · ".join(gaps)))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="fleet-codex-plugins.py", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd")
    for c in ("sync", "dirs", "doctor", "mention"):
        p = sub.add_parser(c)
        p.add_argument("--root", default=os.path.dirname(HERE))
        p.add_argument("--claude", default=os.environ.get("FLEET_INSTALL_CLAUDE", "claude"))
        p.add_argument("--cache", default=os.path.join(CONF_DIR, "codex", "plugins.json"),
                       help="'' = ask claude every time")
        p.add_argument("--codex-home", action="append", default=[])
        if c == "mention":
            p.add_argument("name")
        if c == "sync":
            p.add_argument("--override", default=os.path.join(CONF_DIR, "agent-overrides.json"))
            p.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "sync":
        return cmd_sync(a)
    if a.cmd == "dirs":
        return cmd_dirs(a)
    if a.cmd == "doctor":
        return cmd_doctor(a)
    if a.cmd == "mention":
        return cmd_mention(a)
    ap.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
