#!/usr/bin/env python3
"""ONE default package for both agents — Claude Code and Codex — on a managed login.

Issue #1559 (EPIC #1524 C12; the sibling of #1558's claude-settings.default.json).
conf/agent-defaults/ is the only source:

  claude/mcp.default.json    user-scope MCP servers → ~/.claude.json "mcpServers"
                             (context7 · playwright · github · fetch)
  claude/CLAUDE.default.md   legacy block reference (not installed)
  codex/config.default.toml  approval_policy / sandbox_mode / model_reasoning_effort /
                             check_for_update_on_startup
                             + the same [mcp_servers.*] → $CODEX_HOME/config.toml
  codex/AGENTS.default.md    legacy block reference (not installed)
  skills/ (the repo's)       counted here, installed by fleet-install-apply.sh's
                             skills / codex-skills passes into ~/.claude/skills and
                             $CODEX_HOME/skills

Merge = the #1558 semantics: FILL ONLY. An MCP server the login already has under
that name — whatever its command — is never rewritten; a top-level Codex key the
login has, whatever its value, is never changed; `model` is never shipped. The
legacy doc blocks are left byte for byte as they are; apply/check neither install
nor require them (#3125). Only an explicit strip removes a marked block. A login's ~/.claude.json
that Claude Code never wrote is not created (same as #1558); a $CODEX_HOME that
does not exist means Codex is not set up on that login — nothing is created there.
~/.config/claude-fleet/agent-overrides.json lists what is never written: a JSON
array of paths (or an object keyed by them) — `claude` / `codex` (that whole
agent), `claude.mcp` / `codex.mcp` (all servers), `claude.mcp.<name>` /
`codex.mcp.<name>`, `codex.<key>` (approval_policy …), `claude.doc` / `codex.doc`,
`claude.skills` / `codex.skills`, or a bare `<name>` = that server on both agents.

Credentials never enter a config: the github server's token is taken by
bin/mcp-github.sh from the gh CLI (`auth token`) when the server starts. No merged file
carries a token (the selftest greps for one).

By default the Codex side is edited as TEXT, not re-serialized: a missing top-level key is
inserted before the first [table], a missing server is appended as its own
[mcp_servers.<name>] table, and the login's lines stay byte for byte. macOS ships
python 3.9 (no tomllib), so the scan is a small line reader; when tomllib / tomli
IS importable the result is parsed before it is written and a parse failure
writes nothing (exit 2). The ~/.claude.json write takes Claude Code's own
.claude.json.lock through fleet-hooks-merge.py (never stolen).

Explicit --codex-native-remote / --codex-native-peer-pid delegates Codex writes
to its native config/batchWrite API. Requires exactly one --codex-home and
--skip claude, a kernel-verified idle backend for that home, and a maintenance
window with no concurrent launches. Existing keys/servers are retained; native
version conflicts refuse without legacy fallback. No loaded-thread hot reload,
automatic backend startup or default installer behavior change.

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

  strip  [--claude-md F] [--codex-home D]… [--override F] [--skip PATH]…
         [--dry-run] removes only the legacy marker block; leaves personal text,
         configs and skills alone. Malformed/duplicate markers refuse before any
         write. Missing files stay absent. No installed defaults are needed.

Exit: 0 ok · 1 check found something missing · 2 unreadable/malformed input or a
held lock.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import runpy
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

def strip_docs(a, homes, blocked):
    """Explicit cleanup only; preflight every file before writing any of them."""
    paths = []
    if not shielded("claude.doc", blocked):
        paths.append(a.claude_md)
    if not shielded("codex.doc", blocked):
        paths.extend(os.path.join(h, "AGENTS.md") for h in homes)
    changes = {}
    for path in paths:
        target = os.path.realpath(path)
        try:
            # Preserve personal text including CRLF outside the marked block.
            with open(target, encoding="utf-8", newline="") as f:
                cur = f.read()
        except FileNotFoundError:
            continue
        except (OSError, UnicodeDecodeError) as e:
            die("cannot read %s: %s" % (path, e))
        if BEGIN not in cur and END not in cur:
            continue
        if cur.count(BEGIN) != 1 or cur.count(END) != 1 or cur.index(END) < cur.index(BEGIN):
            die("%s: malformed or duplicate fleet markers — left alone" % path)
        b, e = cur.index(BEGIN), cur.index(END) + len(END)
        # The marker's line ending belongs to the block, not the following text.
        if cur[e:e + 2] == "\r\n":
            e += 2
        elif cur[e:e + 1] == "\n":
            e += 1
        changes[target] = (path, cur[:b] + cur[e:])
    for path, text in changes.values():
        write_text(path, text, a.dry_run)
    print("stripped %d fleet block(s)%s" % (len(changes),
          " (dry run — nothing written)" if a.dry_run else ""))
    return 0


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


def claude_side(a, rep, want_mcp, blocked, check):
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

    # skills (count only — the install's skills pass copies them)
    if a.claude_skills and not shielded("claude.skills", blocked):
        for n in missing_skills(repo_skills(a.root), a.claude_skills):
            rep.missing["skills"].append("missing    claude skill %s" % n)
    elif a.claude_skills:
        rep.kept.append("claude.skills")


def native_codex_defaults(client, home, want_top, want_srv, blocked, check_only=False):
    home = Path(home).resolve()
    target = home / 'config.toml'
    if not home.is_dir() or home.stat().st_uid != os.getuid():
        raise ValueError('native configuration requires an existing owned Codex home')
    if target.is_symlink() or (target.exists() and (not target.is_file() or target.stat().st_uid != os.getuid())):
        raise ValueError('native configuration requires an unshared owned configuration file')
    if client.call('thread/loaded/list', {})['data']:
        raise ValueError('native configuration requires an idle maintenance backend')
    layers = client.call('config/read', {'includeLayers': True})['layers']
    users = [layer for layer in layers or [] if layer.get('name', {}).get('type') == 'user'
             and not layer['name'].get('profile')]
    if len(users) != 1 or Path(users[0]['name']['file']) != target:
        raise ValueError('native backend does not own the requested base Codex home')
    layer = users[0]
    existing, version = layer['config'], layer['version']
    if layer.get('disabledReason') or not isinstance(existing, dict) or not isinstance(version, str) or not version:
        raise ValueError('native user configuration layer is not writable')
    servers = existing.get('mcp_servers', {})
    if not isinstance(servers, dict):
        raise ValueError('native MCP configuration is not a table')
    edits = [{'keyPath': toml_key(key), 'value': value, 'mergeStrategy': 'upsert'}
             for key, value in want_top.items() if key not in existing and not shielded('codex.' + key, blocked)]
    edits.extend({'keyPath': 'mcp_servers.' + toml_key(name), 'value': value, 'mergeStrategy': 'upsert'}
                 for name, value in want_srv.items() if name not in servers and not shielded('codex.mcp.' + name, blocked))
    if edits and not check_only:
        if client.call('thread/loaded/list', {})['data']:
            raise ValueError('native backend became active before configuration publication')
        published = client.call('config/batchWrite', {'edits': edits, 'expectedVersion': version,
                                                    'filePath': str(target), 'reloadUserConfig': False})
        if (not isinstance(published, dict) or published.get('status') not in ('ok', 'okOverridden')
                or published.get('filePath') != str(target)
                or not isinstance(published.get('version'), str) or not published['version']):
            raise ValueError('native publication result is unverified; inspect before retrying')
    return edits


def codex_side(a, rep, home, tag, want_top, want_srv, blocked, check):
    if not os.path.isdir(home):
        rep.codex_na.append(home)
        if not check:
            rep.say("absent  %s — Codex is not set up on this login; nothing created" % tilde(home))
        return
    if a.codex_native_remote:
        client = None
        try:
            client_type = runpy.run_path(os.path.join(HERE, 'fleet-codex-rpc.py'))['Client']
            client = client_type(a.codex_native_remote, peer_pid=a.codex_native_peer_pid)
            edits = native_codex_defaults(client, home, want_top, want_srv, blocked, check or a.dry_run)
        except (OSError, ValueError, KeyError, TypeError, EOFError):
            die('native Codex configuration not confirmed; verify the idle backend and home, inspect native config before retrying; no legacy fallback')
        finally:
            if client is not None:
                client.close()
        for edit in edits:
            if check:
                rep.missing['codex'].append('missing    %s %s' % (tag, edit['keyPath']))
            else:
                rep.say('set            %s %s (native)' % (tag, edit['keyPath']))
        if not check:
            rep.sets['codex'] += len(edits)
        codex_skill_report(a, rep, home, tag, blocked)
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
    codex_skill_report(a, rep, home, tag, blocked)


def codex_skill_report(a, rep, home, tag, blocked):
    if shielded("codex.skills", blocked):
        rep.kept.append("%s.skills" % tag)
    else:
        for name in missing_skills(repo_skills(a.root), os.path.join(home, "skills")):
            rep.missing["skills"].append("missing    %s skill %s" % (tag, name))


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
    ap.add_argument("action", choices=("apply", "check", "strip"))
    ap.add_argument("--root", default=DEFAULT_ROOT, help="install root holding conf/agent-defaults/ and skills/")
    ap.add_argument("--claude-config", default=DEFAULT_CLAUDE_CONFIG)
    ap.add_argument("--claude-md", default=DEFAULT_CLAUDE_MD)
    ap.add_argument("--claude-skills", default=DEFAULT_CLAUDE_SKILLS, help="'' = do not count Claude skills")
    ap.add_argument("--codex-home", action="append", default=[])
    ap.add_argument("--codex-native-remote", help="explicit idle local native backend; no automatic launch or fallback")
    ap.add_argument("--codex-native-peer-pid", type=int, help="expected native backend PID, verified by the kernel")
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

    blocked = override_paths(a.override, a.skip)
    if a.codex_native_remote or a.codex_native_peer_pid is not None:
        if (not a.codex_native_remote or not a.codex_native_remote.startswith('unix:///')
                or not a.codex_native_peer_pid or a.codex_native_peer_pid < 1
                or len(a.codex_home) != 1 or len(homes) != 1
                or not os.path.isdir(homes[0])
                or not shielded('claude', blocked) or a.action == 'strip'):
            ap.error('native mode requires one explicit Codex home, local Unix endpoint, positive peer PID and --skip claude; apply/check only')
    if a.action == "strip":
        return strip_docs(a, homes, blocked)

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

    rep = Report()
    if shielded("claude", blocked):
        rep.kept.append("claude")
    else:
        claude_side(a, rep, mcp["mcpServers"], blocked, check)
    if shielded("codex", blocked):
        rep.kept.append("codex")
    else:
        for h in homes:
            tag = "codex" if len(homes) == 1 and h == os.path.abspath(DEFAULT_CODEX_HOME) else "codex[%s]" % tilde(h)
            codex_side(a, rep, h, tag, want_top, want_srv, blocked, check)

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
