#!/usr/bin/env python3
"""ONE default package for both agents — Claude Code and Codex — on a managed login.

Issue #1559 (EPIC #1524 C12; the sibling of #1558's claude-settings.default.json).
conf/agent-defaults/ is the only source:

  claude/mcp.default.json    user-scope MCP servers → ~/.claude.json "mcpServers"
                             (context7 · playwright · github · fetch)
  claude/CLAUDE.default.md   one marker-delimited block → ~/.claude/CLAUDE.md
  codex/config.default.toml  approval_policy / sandbox_mode / model_reasoning_effort /
                             check_for_update_on_startup
                             + the same [mcp_servers.*] → $CODEX_HOME/config.toml
  codex/AGENTS.default.md    the same block → $CODEX_HOME/AGENTS.md
  skills/ (the repo's)       counted here, installed by fleet-install-apply.sh's
                             skills / codex-skills passes into ~/.claude/skills and
                             $CODEX_HOME/skills

Merge = the #1558 semantics: FILL ONLY. An MCP server the login already has under
that name — whatever its command — is never rewritten; a top-level Codex key the
login has, whatever its value, is never changed; `model` is never shipped. The
doc block is the fleet's own: appended when absent, replaced in place when its
text moved on, everything outside the markers untouched. A login's ~/.claude.json
that Claude Code never wrote is not created (same as #1558); a $CODEX_HOME that
does not exist means Codex is not set up on that login — nothing is created there.
~/.config/claude-fleet/agent-overrides.json lists what is never written: a JSON
array of paths (or an object keyed by them) — `claude` / `codex` (that whole
agent), `claude.mcp` / `codex.mcp` (all servers), `claude.mcp.<name>` /
`codex.mcp.<name>`, `codex.<key>` (approval_policy …), `claude.doc` / `codex.doc`,
`claude.skills` / `codex.skills`, or a bare `<name>` = that server on both agents.

Credentials never enter a config: the github server's token is taken by
bin/mcp-github.sh from `gh auth token` when the server starts. No merged file
carries a token (the selftest greps for one).

The Codex side is edited as TEXT, not re-serialized: a missing top-level key is
inserted before the first [table], a missing server is appended as its own
[mcp_servers.<name>] table, and the login's lines stay byte for byte. macOS ships
python 3.9 (no tomllib), so the scan is a small line reader; when tomllib / tomli
IS importable the result is parsed before it is written and a parse failure
writes nothing (exit 2). The ~/.claude.json write takes Claude Code's own
.claude.json.lock through fleet-hooks-merge.py (never stolen).

  apply  [--root R] [--claude-config F] [--claude-md F] [--claude-skills D]
         [--codex-home D]… [--override F] [--skip PATH]… [--dry-run]
         Prints one line per change (`set …`), per thing the login owns (`own …`),
         what the override kept (`kept …`), and ends `filled  claude N · codex M`
         or `unchanged — …`. Idempotent: a second run writes nothing.
         --scripts-root R (issue #1725, a client-only computer): a default
         server's `$HOME/.claude/fleet/` (the github / fetch wrappers) is spelled
         as R — the package ships bin/mcp-*.sh there. A server the login
         already has is still never rewritten.
  check  [same options, no --dry-run]
         Read-only. First line `ok claude 0 missing · codex 0 missing · skills 0
         missing` (exit 0) or the same counts without `ok` plus one `missing …`
         line each (exit 1). A $CODEX_HOME that does not exist reads `codex n/a`.
         fleet-doctor's `agents` line.

Exit: 0 ok · 1 check found something missing · 2 unreadable/malformed input or a
held lock.
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(HERE)
BEGIN = "<!-- fleet:agent-defaults begin -->"
END = "<!-- fleet:agent-defaults end -->"
CLAUDE_DIR = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
DEFAULT_CLAUDE_CONFIG = os.path.join(
    os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~"), ".claude.json")
DEFAULT_CLAUDE_MD = os.path.join(CLAUDE_DIR, "CLAUDE.md")
DEFAULT_CLAUDE_SKILLS = os.environ.get("CLAUDE_SKILLS_DIR") or os.path.join(
    os.path.expanduser("~/.claude"), "skills")
DEFAULT_CODEX_HOME = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
DEFAULT_OVERRIDE = os.path.join(
    os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet"),
    "agent-overrides.json")

try:
    import tomllib as _toml          # 3.11+
except ImportError:                  # pragma: no cover — macOS python 3.9
    try:
        import tomli as _toml
    except ImportError:
        _toml = None


def die(msg):
    print("fleet-agent-defaults: %s" % msg, file=sys.stderr)
    sys.exit(2)


def hooks_merge():
    """The #1558 merge script, for its .claude.json lock + atomic writer — ONE
    lock implementation on this login, never a second copy."""
    path = os.path.join(HERE, "fleet-hooks-merge.py")
    spec = importlib.util.spec_from_file_location("fleet_hooks_merge", path)
    if spec is None or spec.loader is None:
        die("%s missing — the agents pass ships beside it" % path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def default_codex_homes():
    """$CODEX_HOME (or ~/.codex), FLEET_CODEX_HOME, and every account home in
    $FLEET_CONF_DIR/codex/accounts.json — the same set fleet-install-apply.sh's
    codex-skills pass mirrors into. `--codex-home` replaces the whole list."""
    out = [DEFAULT_CODEX_HOME]
    if os.environ.get("FLEET_CODEX_HOME"):
        out.append(os.environ["FLEET_CODEX_HOME"])
    acct = os.path.join(os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet"),
                        "codex", "accounts.json")
    try:
        with open(acct) as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = {}
    if isinstance(data, dict):
        out.extend(v for v in data.values() if isinstance(v, str) and v)
    return out


def tilde(path):
    home = os.path.abspath(os.path.expanduser("~"))
    return "~" + path[len(home):] if path == home or path.startswith(home + os.sep) else path


def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError) as e:
        die("cannot read %s: %s" % (path, e))


def write_text(path, text, dry_run):
    """Atomic replace through a symlink, mode kept; a new file gets the umask's."""
    if dry_run:
        return
    target = os.path.realpath(path)
    os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
    tmp = target + ".fleet-agent-defaults.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    if os.path.exists(target):
        shutil.copymode(target, tmp)
    os.replace(tmp, target)
    print("wrote   %s" % path)


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        die("cannot read %s: %s" % (path, e))


# --- the override file -----------------------------------------------------------

def override_paths(path, skip):
    src = load_json(path)
    if src is None:
        paths = set()
    elif isinstance(src, list) and all(isinstance(k, str) for k in src):
        paths = set(src)
    elif isinstance(src, dict):
        paths = set(src)
    else:
        die("%s must be a JSON array of paths, or an object keyed by them" % path)
    return paths | set(skip)


def shielded(path, blocked):
    """`a.b.c` is kept when it or any ancestor is listed; a bare server name
    shields that server on both agents."""
    parts = path.split(".")
    if any(".".join(parts[:i]) in blocked for i in range(1, len(parts) + 1)):
        return True
    return len(parts) == 3 and parts[1] == "mcp" and parts[2] in blocked


# --- a small TOML reader (macOS python 3.9 has no tomllib) ---------------------------

_HDR = re.compile(r"^\s*(\[\[?)\s*(.+?)\s*\]\]?\s*(#.*)?$")
_KEY = re.compile(r"^\s*((?:[A-Za-z0-9_-]+|\"(?:[^\"\\]|\\.)*\"|'[^']*')"
                  r"(?:\s*\.\s*(?:[A-Za-z0-9_-]+|\"(?:[^\"\\]|\\.)*\"|'[^']*'))*)\s*=\s*(.*)$")


def split_key(text):
    """`a."b.c".d` → ('a', 'b.c', 'd')."""
    parts, cur, i, q, quoted = [], "", 0, None, False
    while i < len(text):
        c = text[i]
        if q:
            if c == "\\" and q == '"' and i + 1 < len(text):
                cur += text[i:i + 2]
                i += 2
                continue
            if c == q:
                cur = json.loads('"%s"' % cur) if q == '"' else cur
                q = None
                i += 1
                continue
            cur += c
        elif c in "\"'":
            q, quoted = c, True
        elif c == ".":
            parts.append(cur)
            cur, quoted = "", False
        elif not c.isspace():
            cur += c
        i += 1
    parts.append(cur)
    return tuple(parts)


def _str_end(s, i):
    """Index of the closing quote of the basic string opening at s[i]."""
    j = i + 1
    while j < len(s):
        if s[j] == "\\":
            j += 2
            continue
        if s[j] == '"':
            return j
        j += 1
    raise ValueError("unterminated string")


def parse_value(s):
    """(value, rest) for the subset our defaults use: strings, booleans, numbers,
    one-line arrays and inline tables of those."""
    s = s.lstrip()
    if not s:
        raise ValueError("missing value")
    if s[0] == '"':
        end = _str_end(s, 0)
        return json.loads(s[:end + 1]), s[end + 1:]
    if s[0] == "'":
        end = s.index("'", 1)
        return s[1:end], s[end + 1:]
    if s[0] == "[":
        items, rest = [], s[1:].lstrip()
        while not rest.startswith("]"):
            v, rest = parse_value(rest)
            items.append(v)
            rest = rest.lstrip()
            if rest.startswith(","):
                rest = rest[1:].lstrip()
        return items, rest[1:]
    if s[0] == "{":
        out, rest = {}, s[1:].lstrip()
        while not rest.startswith("}"):
            m = _KEY.match(rest)
            if not m:
                raise ValueError("bad inline table near %r" % rest[:20])
            key = split_key(m.group(1))
            if len(key) != 1:
                raise ValueError("dotted key inside an inline table")
            v, rest = parse_value(m.group(2))
            out[key[0]] = v
            rest = rest.lstrip()
            if rest.startswith(","):
                rest = rest[1:].lstrip()
        return out, rest[1:]
    m = re.match(r"(true|false)\b", s)
    if m:
        return m.group(1) == "true", s[m.end():]
    m = re.match(r"[-+]?\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?", s)
    if m:
        lit = m.group(0).replace("_", "")
        return (float(lit) if any(c in lit for c in ".eE") else int(lit)), s[m.end():]
    raise ValueError("unsupported value near %r" % s[:20])


def toml_str(s):
    return json.dumps(s, ensure_ascii=False)     # a TOML basic string accepts JSON's escapes


def toml_key(k):
    return k if re.fullmatch(r"[A-Za-z0-9_-]+", k) else toml_str(k)


def toml_val(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return toml_str(v)
    if isinstance(v, list):
        return "[" + ", ".join(toml_val(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{ " + ", ".join("%s = %s" % (toml_key(k), toml_val(x)) for k, x in v.items()) + " }"
    raise ValueError("cannot serialize %r" % (v,))


class TomlScan:
    """Where things ARE in a config.toml — enough for a fill-only merge: the
    top-level keys, every [table], every key path, the first header's line."""

    def __init__(self, text):
        self.lines = text.split("\n")
        if self.lines and self.lines[-1] == "":
            self.lines.pop()
        self.tables, self.keys, self.values = set(), {}, {}
        self.first_header = None
        table = ()
        for idx, line in enumerate(self.lines):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            h = _HDR.match(line)
            if h:
                table = split_key(h.group(2))
                self.tables.add(table)
                if self.first_header is None:
                    self.first_header = idx
                continue
            k = _KEY.match(line)
            if k:
                path = table + split_key(k.group(1))
                self.keys.setdefault(path, idx)
                self.values.setdefault(path, k.group(2).strip())

    def has_top(self, key):
        return (key,) in self.keys

    def top_value(self, key):
        return self.values.get((key,), "")

    def has_server(self, name):
        p = ("mcp_servers", name)
        return p in self.tables or p in self.keys or any(k[:2] == p for k in self.keys)

    def mcp_inline(self):
        """`mcp_servers = { … }` at the top: an inline table cannot be extended by
        a later [mcp_servers.<name>] header."""
        return ("mcp_servers",) in self.keys


def parse_defaults_toml(path):
    """conf/agent-defaults/codex/config.default.toml → (top: {key: value},
    servers: {name: {key: value}}) in file order. Our own file: a shape outside
    the subset is a malformed default, exit 2."""
    text = read_text(path)
    if text is None:
        die("%s missing" % path)
    top, servers, table = {}, {}, None
    for n, line in enumerate(text.split("\n"), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        h = _HDR.match(line)
        if h:
            parts = split_key(h.group(2))
            if h.group(1) == "[[" or len(parts) != 2 or parts[0] != "mcp_servers":
                die("%s:%d: only [mcp_servers.<name>] tables are allowed in the defaults" % (path, n))
            table = parts[1]
            servers.setdefault(table, {})
            continue
        k = _KEY.match(line)
        if not k:
            die("%s:%d: not a `key = value` line" % (path, n))
        key = split_key(k.group(1))
        if len(key) != 1:
            die("%s:%d: dotted keys are not allowed in the defaults" % (path, n))
        try:
            val, rest = parse_value(k.group(2))
        except (ValueError, IndexError) as e:
            die("%s:%d: %s" % (path, n, e))
        if rest.strip() and not rest.strip().startswith("#"):
            die("%s:%d: trailing text after the value" % (path, n))
        if table is None:
            if key[0] == "model":
                die("%s: `model` is never shipped — it stays the login's" % path)
            top[key[0]] = val
        else:
            servers[table][key[0]] = val
    if _toml is not None:
        try:
            parsed = _toml.loads(text)
        except Exception as e:  # noqa: BLE001 — tomllib's error type varies by version
            die("%s: %s" % (path, e))
        if parsed != dict(top, **({"mcp_servers": servers} if servers else {})):
            die("%s: the fleet's reader and tomllib disagree — keep the file to its subset" % path)
    return top, servers


# --- the doc block ------------------------------------------------------------------

def block_of(path):
    text = read_text(path)
    if text is None:
        die("%s missing" % path)
    if BEGIN not in text or END not in text or text.index(BEGIN) > text.index(END):
        die("%s must hold one %s … %s block" % (path, BEGIN, END))
    return text.strip("\n") + "\n"


def doc_merge(path, block):
    """(new_text or None, status): appended · replaced · unchanged · malformed."""
    cur = read_text(path)
    if cur is None:
        return block, "appended"
    b, e = cur.find(BEGIN), cur.find(END)
    if b < 0 and e < 0:
        sep = "" if cur == "" or cur.endswith("\n\n") else ("\n" if cur.endswith("\n") else "\n\n")
        return cur + sep + block, "appended"
    if b < 0 or e < 0 or e < b:
        return None, "malformed"
    e_end = e + len(END)
    old = cur[b:e_end]
    new_block = block.strip("\n")
    if old == new_block:
        return None, "unchanged"
    return cur[:b] + new_block + cur[e_end:], "replaced"


# --- skills -------------------------------------------------------------------------

def repo_skills(root):
    d = os.path.join(root, "skills")
    try:
        return sorted(n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n, "SKILL.md")))
    except OSError:
        return []


def missing_skills(names, skills_dir):
    return [n for n in names if not os.path.isfile(os.path.join(skills_dir, n, "SKILL.md"))]


# --- the two sides -------------------------------------------------------------------

class Report:
    def __init__(self):
        self.lines, self.sets, self.kept = [], {"claude": 0, "codex": 0}, []
        self.missing = {"claude": [], "codex": [], "skills": []}
        self.codex_na = []

    def say(self, line):
        self.lines.append(line)
        print(line)


def claude_side(a, rep, want_mcp, block, blocked, check):
    label = os.path.basename(a.claude_config)
    names = [n for n in want_mcp]
    kept_names = [n for n in names if shielded("claude.mcp." + n, blocked)]
    rep.kept.extend("claude.mcp." + n for n in kept_names)
    names = [n for n in names if n not in kept_names]

    def fill(cfg):
        """Fill-only on the mcpServers object. Returns (new_cfg or None, set_names)."""
        servers = cfg.get("mcpServers")
        if servers is None:
            servers = {}
        if not isinstance(servers, dict):
            rep.say("own            claude %s mcpServers is not an object — left alone" % label)
            return None, []
        add = []
        for n in names:
            if n in servers:
                have = servers[n] if isinstance(servers[n], dict) else {}
                rep.say("own            claude mcp %s — this login's (%s)"
                        % (n, " ".join([str(have.get("command", have.get("url", "?")))]
                                       + [str(x) for x in (have.get("args") or [])])))
            else:
                add.append(n)
        if not add:
            return None, []
        new = json.loads(json.dumps(cfg))
        new.setdefault("mcpServers", {})
        for n in add:
            new["mcpServers"][n] = json.loads(json.dumps(want_mcp[n]))
            rep.say("set            claude mcp %s" % n)
        return new, add

    if check:
        cfg = load_json(a.claude_config)
        if cfg is not None and not isinstance(cfg, dict):
            die("%s is not a JSON object" % a.claude_config)
        if cfg is None:
            for n in names:
                rep.missing["claude"].append("missing    claude mcp %s — Claude Code has not run on this login yet" % n)
        else:
            servers = cfg.get("mcpServers")
            servers = servers if isinstance(servers, dict) else {}
            for n in names:
                if n not in servers:
                    rep.missing["claude"].append("missing    claude mcp %s" % n)
    else:
        hm = hooks_merge()

        def apply_cfg():
            cfg = load_json(a.claude_config)
            if cfg is None:
                rep.say("absent  %s — Claude Code has not run on this login yet; its %d server(s) wait for the next sync"
                        % (a.claude_config, len(names)))
                return
            if not isinstance(cfg, dict):
                die("%s is not a JSON object" % a.claude_config)
            new, add = fill(cfg)
            if new is not None:
                rep.sets["claude"] += len(add)
                if not a.dry_run:
                    hm.write_settings(a.claude_config, new, backup=False)

        if names:
            if a.dry_run or not os.path.exists(a.claude_config):
                apply_cfg()
            else:
                hm.with_config_lock(a.claude_config, apply_cfg)

    # the CLAUDE.md block
    if shielded("claude.doc", blocked):
        rep.kept.append("claude.doc")
    else:
        new, status = doc_merge(a.claude_md, block)
        if check:
            if status in ("appended", "replaced"):
                rep.missing["claude"].append("missing    claude doc %s fleet block (%s)"
                                             % (os.path.basename(a.claude_md),
                                                "absent" if status == "appended" else "stale"))
            elif status == "malformed":
                rep.missing["claude"].append("missing    claude doc %s fleet block is malformed (one marker without the other)"
                                             % os.path.basename(a.claude_md))
        elif status == "malformed":
            rep.say("own            claude doc %s — a fleet marker without its pair; left alone" % os.path.basename(a.claude_md))
        elif status != "unchanged":
            rep.say("set            claude doc %s fleet block (%s)" % (os.path.basename(a.claude_md), status))
            rep.sets["claude"] += 1
            write_text(a.claude_md, new, a.dry_run)

    # skills (count only — the install's skills pass copies them)
    if a.claude_skills and not shielded("claude.skills", blocked):
        for n in missing_skills(repo_skills(a.root), a.claude_skills):
            rep.missing["skills"].append("missing    claude skill %s" % n)
    elif a.claude_skills:
        rep.kept.append("claude.skills")


def codex_side(a, rep, home, tag, want_top, want_srv, block, blocked, check):
    if not os.path.isdir(home):
        rep.codex_na.append(home)
        if not check:
            rep.say("absent  %s — Codex is not set up on this login; nothing created" % tilde(home))
        return
    conf = os.path.join(home, "config.toml")
    text = read_text(conf)
    scan = TomlScan(text or "")
    top_add, srv_add = [], []
    for k, v in want_top.items():
        if shielded("codex." + k, blocked):
            rep.kept.append("%s.%s" % (tag, k))
        elif scan.has_top(k):
            if not check:
                rep.say("own            %s %s = %s (default %s)" % (tag, k, scan.top_value(k), toml_val(v)))
        else:
            top_add.append(k)
            if check:
                rep.missing["codex"].append("missing    %s %s (default %s)" % (tag, k, toml_val(v)))
    for n, tbl in want_srv.items():
        if shielded("codex.mcp." + n, blocked):
            rep.kept.append("%s.mcp.%s" % (tag, n))
        elif scan.has_server(n):
            if not check:
                rep.say("own            %s mcp %s — this login's" % (tag, n))
        elif scan.mcp_inline():
            if check:
                rep.missing["codex"].append("missing    %s mcp %s — mcp_servers is an inline table; add it by hand" % (tag, n))
            else:
                rep.say("own            %s mcp %s — mcp_servers is an inline table, not extended" % (tag, n))
        else:
            srv_add.append(n)
            if check:
                rep.missing["codex"].append("missing    %s mcp %s" % (tag, n))
    if not check and (top_add or srv_add):
        lines = list(scan.lines)
        if top_add:
            ins = ["%s = %s" % (toml_key(k), toml_val(want_top[k])) for k in top_add]
            if scan.first_header is None:
                if lines and lines[-1].strip():
                    lines.append("")
                lines.extend(ins)
            else:
                at = scan.first_header
                while at > 0 and (not lines[at - 1].strip() or lines[at - 1].lstrip().startswith("#")):
                    at -= 1
                if at > 0 and lines[at - 1].strip():
                    ins = [""] + ins
                lines[at:at] = ins + [""]
            for k in top_add:
                rep.say("set            %s %s = %s" % (tag, k, toml_val(want_top[k])))
        for n in srv_add:
            if lines and lines[-1].strip():
                lines.append("")
            lines.append("[mcp_servers.%s]" % toml_key(n))
            for k, v in want_srv[n].items():
                lines.append("%s = %s" % (toml_key(k), toml_val(v)))
            rep.say("set            %s mcp %s" % (tag, n))
        new_text = "\n".join(lines) + "\n"
        if _toml is not None:
            try:
                _toml.loads(new_text)
            except Exception as e:  # noqa: BLE001
                die("%s: the merged file would not parse (%s) — nothing written" % (conf, e))
        rep.sets["codex"] += len(top_add) + len(srv_add)
        write_text(conf, new_text, a.dry_run)
    # the AGENTS.md block
    agents = os.path.join(home, "AGENTS.md")
    if shielded("codex.doc", blocked):
        rep.kept.append("%s.doc" % tag)
    else:
        new, status = doc_merge(agents, block)
        if check:
            if status in ("appended", "replaced"):
                rep.missing["codex"].append("missing    %s doc AGENTS.md fleet block (%s)"
                                            % (tag, "absent" if status == "appended" else "stale"))
            elif status == "malformed":
                rep.missing["codex"].append("missing    %s doc AGENTS.md fleet block is malformed (one marker without the other)" % tag)
        elif status == "malformed":
            rep.say("own            %s doc AGENTS.md — a fleet marker without its pair; left alone" % tag)
        elif status != "unchanged":
            rep.say("set            %s doc AGENTS.md fleet block (%s)" % (tag, status))
            rep.sets["codex"] += 1
            write_text(agents, new, a.dry_run)
    # skills (count only — the install's codex-skills pass copies them)
    if shielded("codex.skills", blocked):
        rep.kept.append("%s.skills" % tag)
    else:
        for n in missing_skills(repo_skills(a.root), os.path.join(home, "skills")):
            rep.missing["skills"].append("missing    %s skill %s" % (tag, n))


FLEET_HOME_PREFIX = "$HOME/.claude/fleet/"
def scripts_spelling(root):
    """A client-only root (issue #1725) as a server's args spell it: $HOME/… under
    the home, else absolute — the wrappers bin/mcp-*.sh ship in the package."""
    root = os.path.abspath(os.path.expanduser(root))
    if any(c in root for c in "\"$`\\"):
        die("--scripts-root %s: a quote / $ / backslash in the path" % root)
    home = os.path.abspath(os.path.expanduser("~"))
    if root == home or root.startswith(home + os.sep):
        root = "$HOME" + root[len(home):]
    return root + "/"
def reroot(v, spelled):
    """Every "$HOME/.claude/fleet/" in a default server's strings → `spelled`."""
    if isinstance(v, str):
        return v.replace(FLEET_HOME_PREFIX, spelled)
    if isinstance(v, list):
        return [reroot(x, spelled) for x in v]
    if isinstance(v, dict):
        return {k: reroot(x, spelled) for k, x in v.items()}
    return v


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=("apply", "check"))
    ap.add_argument("--root", default=DEFAULT_ROOT, help="install root holding conf/agent-defaults/ and skills/")
    ap.add_argument("--claude-config", default=DEFAULT_CLAUDE_CONFIG)
    ap.add_argument("--claude-md", default=DEFAULT_CLAUDE_MD)
    ap.add_argument("--claude-skills", default=DEFAULT_CLAUDE_SKILLS, help="'' = do not count Claude skills")
    ap.add_argument("--codex-home", action="append", default=[])
    ap.add_argument("--override", default=DEFAULT_OVERRIDE)
    ap.add_argument("--skip", action="append", default=[])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--scripts-root", default=None,
                    help="client-only root holding bin/mcp-*.sh (#1725): a default server's "
                         "$HOME/.claude/fleet/ is spelled as this root instead")
    a = ap.parse_args()
    check = a.action == "check"
    homes = []
    for h in (a.codex_home or default_codex_homes()):
        h = os.path.abspath(os.path.expanduser(h))
        if h not in homes:
            homes.append(h)

    base = os.path.join(a.root, "conf", "agent-defaults")
    if not os.path.isdir(base):
        die("%s missing — no agent defaults in this install" % base)
    mcp = load_json(os.path.join(base, "claude", "mcp.default.json"))
    if not isinstance(mcp, dict) or not isinstance(mcp.get("mcpServers"), dict) or set(mcp) != {"mcpServers"}:
        die('%s must be {"mcpServers": {…}}' % os.path.join(base, "claude", "mcp.default.json"))
    for n, v in mcp["mcpServers"].items():
        if not isinstance(v, dict) or not ("command" in v or "url" in v):
            die("%s: server %s needs a command or url" % (os.path.join(base, "claude", "mcp.default.json"), n))
        if any(k in json.dumps(v).lower() for k in ("token", "secret", "password", "api_key", "apikey")):
            die("%s: server %s carries a credential-shaped key — tokens are read at start, never shipped" % (base, n))
    want_top, want_srv = parse_defaults_toml(os.path.join(base, "codex", "config.default.toml"))
    if a.scripts_root:
        spelled = scripts_spelling(a.scripts_root)
        mcp["mcpServers"] = reroot(mcp["mcpServers"], spelled)
        want_srv = reroot(want_srv, spelled)
    claude_block = block_of(os.path.join(base, "claude", "CLAUDE.default.md"))
    codex_block = block_of(os.path.join(base, "codex", "AGENTS.default.md"))
    blocked = override_paths(a.override, a.skip)

    rep = Report()
    if shielded("claude", blocked):
        rep.kept.append("claude")
    else:
        claude_side(a, rep, mcp["mcpServers"], claude_block, blocked, check)
    if shielded("codex", blocked):
        rep.kept.append("codex")
    else:
        for h in homes:
            tag = "codex" if len(homes) == 1 and h == os.path.abspath(DEFAULT_CODEX_HOME) else "codex[%s]" % tilde(h)
            codex_side(a, rep, h, tag, want_top, want_srv, codex_block, blocked, check)

    kept_note = "" if not rep.kept else "; %d left to this login: %s" % (len(rep.kept), ", ".join(rep.kept))
    if check:
        n_c, n_x, n_s = len(rep.missing["claude"]), len(rep.missing["codex"]), len(rep.missing["skills"])
        codex_word = "codex n/a (no %s)" % ", ".join(tilde(h) for h in rep.codex_na) \
            if rep.codex_na and len(rep.codex_na) == len(homes) and "codex" not in rep.kept else "codex %d missing" % n_x
        if "codex" in rep.kept:
            codex_word = "codex kept"
        head = "claude %d missing · %s · skills %d missing" % (n_c, codex_word, n_s)
        if n_c + n_x + n_s == 0:
            print("ok %s%s" % (head, kept_note))
            return 0
        print(head + kept_note)
        for line in rep.missing["claude"] + rep.missing["codex"] + rep.missing["skills"]:
            print(line)
        return 1
    if rep.kept:
        print("kept    %d item(s) left to this login: %s" % (len(rep.kept), ", ".join(rep.kept)))
    if rep.missing["skills"]:
        print("skills  %d not installed yet (the sync's skills passes copy them): %s"
              % (len(rep.missing["skills"]),
                 ", ".join(l.split(None, 1)[1].replace(" skill ", " ") for l in rep.missing["skills"])))
    if rep.sets["claude"] + rep.sets["codex"] == 0:
        print("unchanged — every default in place, or this login's own")
    else:
        print("filled  claude %d · codex %d%s" % (rep.sets["claude"], rep.sets["codex"],
                                                 " (dry run — nothing written)" if a.dry_run else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
