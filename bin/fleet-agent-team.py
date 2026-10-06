#!/usr/bin/env python3
"""The team layer of the Agent configuration — fleet default < team < local.

Issue #1726 (EPIC #1718 C8). The hub keeps ONE team configuration, versioned
(GET/PUT /v1/fleet/team-bundle; a PUT is the operator's alone, a rollback is a
PUT of an earlier version). This script is the computer's half: it fetches the
layer and composes it over what fleet-agent-defaults.py (#1559) filled, with
this login's own writes always winning.

The bundle (an allow-list — anything else, and anything credential-shaped, is
refused here exactly as the hub refuses it):

  mcp              {name: server}       ~/.claude.json mcpServers + every
                                        $CODEX_HOME/config.toml [mcp_servers.<name>]
  hooks            {Event: [{matcher?, command, timeout?}]}
                                        ~/.claude/settings.json hooks
  skills           {name: "SKILL.md"}   ~/.claude/skills/<name> + $CODEX_HOME/skills/<name>
  claude_settings  {key: value}         ~/.claude/settings.json top-level keys
  codex_config     {key: value}         $CODEX_HOME/config.toml top-level keys

Composition, per item (one MCP server, one setting key, one hook command, one
skill), against $FLEET_CONF_DIR/agent-effective.json — the record of what the
fleet wrote last time and where it came from:

  · absent here                    → the team's value is written (source team)
  · what the team wrote last time,
    unchanged here                 → follows the team: a new value replaces it,
                                     a value the team dropped is taken back (or
                                     goes back to the fleet default, if there is one)
  · the fleet default, untouched   → the team's value replaces it (team > default)
  · anything else                  → this login's own: never written (source local)

So a value written here by hand always wins, and a rollback on the hub undoes
exactly what the team layer did. agent-overrides.json (#1559) shields an item
from the team the way it shields one from the defaults (`claude.mcp.<name>`, a
bare `<name>`, `codex.<key>`, `claude.settings.<key>`, `claude.hooks`,
`claude.skills`, `claude` / `codex`), and `"team": "off"` (or a `team` entry
in the array form) leaves the whole layer: what the team wrote and nobody
touched is taken back, nothing new is added.

agent-effective.json is the composed picture: one row per item — MCP servers,
Codex keys, settings keys, hooks, skills — with its source (default / team /
local), plus the team version applied. fleet-doctor's `agents` row and `fleet
doctor` on a client print the version from it.

  fetch   [--hub URL] [--timeout S]
          GET the layer into $FLEET_CONF_DIR/team-bundle.json (If-None-Match on
          the cached version). Credentials, in order: a node's token
          ($FLEET_CONF_DIR/node.env CCQUOTA_TOKEN, read — never exported), then
          this person's connection certificate (~/.ssh/fleet-cert, a signed POST
          under fleet-team@claude-fleet). FLEET_TEAM_BUNDLE_CMD (a seam) prints
          the response JSON instead. Prints `team: v<N> (new|unchanged)`.
          Exit 0 · 2 refused (credential-shaped / not on the allow-list — the
          cache is kept) · 3 no hub configured (the degenerate case: nothing
          fetched, nothing written) · 1 the hub did not answer.
  apply   [--root R] [--scripts-root R] [--claude-config F] [--claude-settings F]
          [--claude-skills D] [--codex-home D]… [--override F] [--dry-run]
          Compose the cached layer. No cache and no record → nothing at all
          (byte for byte a login with no team layer). Prints one `set …` /
          `drop …` / `own …` line per item and ends `team: v<N> — …`.
  sync    fetch, then apply when the version moved, the record is missing, or
          --force. What install-sync's tick and the client's start run.
  status  [--short]  the applied version and the source counts (doctor).

The operator's side (a viewer token in CCQUOTA_VIEWER_TOKEN — read from the
environment, never written down; a person's session or a node is refused 403):
  put <file.json> [--base N] [--note T]   a new version (the file is the bundle);
                                          refused 422 when it carries a credential
  restore <N> [--note T]                  the rollback: version N's body, as a new version
  history                                 the versions, newest first

Exit: 0 ok · 1 hub unreachable (fetch) · 2 refused / malformed · 3 no hub.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(HERE)
CONF_DIR = os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet")
CACHE = os.path.join(CONF_DIR, "team-bundle.json")
EFFECTIVE = os.path.join(CONF_DIR, "agent-effective.json")
TEAM_PATH = "/v1/fleet/team-bundle"
SIG_NS = "fleet-team@claude-fleet"
SKILL_MARK = "<!-- fleet team skill -->"

ALLOWED = ("mcp", "hooks", "skills", "claude_settings", "codex_config")
HOOK_EVENTS = {"PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop", "SubagentStop",
               "SessionStart", "SessionEnd", "Notification", "PreCompact"}
CLAUDE_DENIED = {"model", "hooks", "apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "otelHeadersHelper"}
CODEX_DENIED = {"model", "mcp_servers", "model_providers"}
# The hub's rules (tokenledger/internal/api/fleet_team_bundle.go), kept in step.
SECRET_KEY = re.compile(r"(?i)(token|secret|passw(or)?d|api[_-]?key|credential|private[_-]?key|authorization"
                        r"|(^|[_-])auth($|[_-])|cookie|session[_-]?key)")
SECRET_REF = re.compile(r"^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$")
SECRET_VALS = [re.compile(p) for p in (
    r"sk-ant-[A-Za-z0-9_-]{8,}", r"\bsk-[A-Za-z0-9_-]{20,}", r"\bgh[pousr]_[A-Za-z0-9]{20,}",
    r"\bgithub_pat_[A-Za-z0-9_]{20,}", r"\bglpat-[A-Za-z0-9_-]{20,}", r"\bxox[abprs]-[A-Za-z0-9-]{10,}",
    r"\bAKIA[0-9A-Z]{16}\b", r"\bAIza[0-9A-Za-z_-]{30,}", r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}", r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}")]


def die(msg, code=2):
    print("fleet-agent-team: %s" % msg, file=sys.stderr)
    sys.exit(code)


def load_mod(name, fname):
    path = os.path.join(HERE, fname)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        die("%s missing — it ships beside this script" % path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def digest(v):
    return hashlib.sha256(json.dumps(v, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:16]


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        die("cannot read %s: %s" % (path, e))


def write_json_atomic(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


# --- the rules ---------------------------------------------------------------------

def secret_in(path, v):
    if isinstance(v, dict):
        for k in sorted(v):
            p = "%s.%s" % (path, k)
            x = v[k]
            if isinstance(x, str) and SECRET_KEY.search(k) and x and not SECRET_REF.match(x):
                return p
            r = secret_in(p, x)
            if r:
                return r
    elif isinstance(v, list):
        for i, x in enumerate(v):
            r = secret_in("%s[%d]" % (path, i), x)
            if r:
                return r
    elif isinstance(v, str):
        if any(rx.search(v) for rx in SECRET_VALS):
            return path
    return ""


def scalar(v):
    return isinstance(v, (str, bool, int, float)) and not isinstance(v, type(None))


def validate(b):
    """'' when the bundle may be applied, else the one-line reason."""
    if not isinstance(b, dict):
        return "bundle is not an object"
    for k in b:
        if k not in ALLOWED:
            return "bundle.%s is not something a team hands out" % k
        if not isinstance(b[k], dict):
            return "bundle.%s must be an object" % k
    for n, s in b.get("mcp", {}).items():
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", n) or not isinstance(s, dict) \
                or not (isinstance(s.get("command"), str) and s["command"] or isinstance(s.get("url"), str) and s["url"]):
            return "bundle.mcp.%s needs a name [A-Za-z0-9_-] and a command or url" % n
    for ev, lst in b.get("hooks", {}).items():
        if ev not in HOOK_EVENTS or not isinstance(lst, list):
            return "bundle.hooks.%s is not a hook event with a list" % ev
        for i, h in enumerate(lst):
            if not isinstance(h, dict) or not isinstance(h.get("command"), str) or not h["command"].strip() \
                    or set(h) - {"matcher", "command", "timeout"}:
                return "bundle.hooks.%s[%d] must be {matcher?, command, timeout?}" % (ev, i)
    for n, t in b.get("skills", {}).items():
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", n) or not isinstance(t, str) or not t.strip():
            return "bundle.skills.%s needs a name [a-z0-9-] and SKILL.md text" % n
    for k in b.get("claude_settings", {}):
        if k in CLAUDE_DENIED or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,63}", k):
            return "bundle.claude_settings.%s is never handed out" % k
    for k, v in b.get("codex_config", {}).items():
        if k in CODEX_DENIED or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,63}", k):
            return "bundle.codex_config.%s is never handed out" % k
        if not (scalar(v) or isinstance(v, list) and all(scalar(x) for x in v)):
            return "bundle.codex_config.%s must be a scalar or a list of them" % k
    p = secret_in("bundle", b)
    if p:
        return "%s looks like a credential — the team layer never carries one" % p
    return ""


# --- fetch -------------------------------------------------------------------------

def env_file_val(path, key):
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"\s*(?:export\s+)?%s=(.*)$" % re.escape(key), line)
                if m:
                    return m.group(1).split(" #")[0].strip().strip("\"'")
    except OSError:
        pass
    return ""


def hub_url(arg):
    url = arg or os.environ.get("CCQUOTA_HUB_URL") or os.environ.get("FLEET_HUB_URL") \
        or env_file_val(os.path.join(CONF_DIR, "node.env"), "CCQUOTA_HUB_URL") \
        or env_file_val(os.path.join(CONF_DIR, "fleet.conf"), "FLEET_HUB_URL")
    if not url:
        d = read_json_quiet(os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
                                         "claude-fleet", "hub.json"))
        url = str(d.get("url") or "") if isinstance(d, dict) else ""
    return url.rstrip("/")


def read_json_quiet(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def cert_proof():
    key = os.environ.get("FLEET_CERT") or os.path.join(os.path.expanduser("~"), ".ssh", "fleet-cert")
    cert = key + "-cert.pub"
    if not (os.path.exists(key) and os.path.exists(cert)):
        return None
    ts = int(time.time())
    try:
        sig = subprocess.run(["ssh-keygen", "-Y", "sign", "-f", key, "-n", SIG_NS],
                             input=("fleet-team %d" % ts).encode(), capture_output=True, check=True).stdout.decode()
        with open(cert) as f:
            line = f.readline().strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return {"cert": line, "sig": sig, "ts": ts}


def http(url, method, headers, body, timeout):
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except (urllib.error.URLError, OSError, ValueError) as e:
        return 0, str(e).encode()


def fetch(a):
    """(rc, version, note). Writes the cache on a new, valid version."""
    cached = read_json_quiet(CACHE) or {}
    have = cached.get("version") if isinstance(cached, dict) else None
    if os.environ.get("FLEET_TEAM_BUNDLE_CMD"):
        p = subprocess.run(["bash", "-c", os.environ["FLEET_TEAM_BUNDLE_CMD"]], capture_output=True)
        if p.returncode != 0:
            return 1, have, "FLEET_TEAM_BUNDLE_CMD exit %d" % p.returncode
        code, raw = 200, p.stdout
    else:
        url = hub_url(a.hub)
        if not url:
            return 3, have, "no hub configured — no team layer on this computer"
        hdr = {"Accept": "application/json"}
        if isinstance(have, int):
            hdr["If-None-Match"] = '"team-v%d"' % have
        tok = env_file_val(os.path.join(CONF_DIR, "node.env"), "CCQUOTA_TOKEN")
        code, raw = 0, b""
        if tok:
            code, raw = http(url + TEAM_PATH, "GET", dict(hdr, Authorization="Bearer " + tok), None, a.timeout)
        if code in (0, 401, 403) or not tok:
            proof = cert_proof()
            if proof:
                code, raw = http(url + TEAM_PATH, "POST", dict(hdr, **{"Content-Type": "application/json"}),
                                 json.dumps(proof).encode(), a.timeout)
            elif not tok:
                return 1, have, "no node token and no connection certificate (fleet login) to read the team layer with"
        if code == 304:
            return 0, have, "unchanged"
        if code != 200:
            msg = raw.decode(errors="replace").strip()
            try:
                msg = json.loads(msg).get("error", msg)
            except (ValueError, AttributeError):
                pass
            return 1, have, "the hub answered %s: %s" % (code or "nothing", msg[:200])
    try:
        resp = json.loads(raw.decode())
        version, bundle = int(resp.get("version") or 0), resp.get("bundle") or {}
    except (ValueError, AttributeError, TypeError):
        return 2, have, "the hub's answer is not a team bundle"
    why = validate(bundle)
    if why:
        return 2, have, "refused v%d: %s (kept v%s)" % (version, why, have)
    if version == have and cached.get("bundle") == bundle:
        return 0, have, "unchanged"
    write_json_atomic(CACHE, {"version": version, "prev": resp.get("prev"), "created": resp.get("created"),
                              "actor": resp.get("actor"), "bundle": bundle, "fetched": int(time.time())})
    return 0, version, "new"


# --- the items -----------------------------------------------------------------------

class Ctx:
    def __init__(self, a, defaults):
        self.a, self.d = a, defaults
        self.lines, self.changed = [], 0

    def say(self, line):
        self.lines.append(line)
        print(line)


class JsonFile:
    """One JSON file (settings.json / .claude.json), read once, written once."""

    def __init__(self, path, lock):
        self.path, self.lock = path, lock
        self.data = read_json(path)
        self.orig = json.dumps(self.data, sort_keys=True)

    def dirty(self):
        return json.dumps(self.data, sort_keys=True) != self.orig


class CodexConf:
    """A config.toml edited as text (the #1559 rule: the login's lines stay byte for byte)."""

    def __init__(self, ad, home):
        self.ad, self.path = ad, os.path.join(home, "config.toml")
        self.text = ad.read_text(self.path) or ""
        self.orig = self.text

    def scan(self):
        return self.ad.TomlScan(self.text)

    def lines(self):
        ls = self.text.split("\n")
        if ls and ls[-1] == "":
            ls.pop()
        return ls

    def set_lines(self, ls):
        self.text = "\n".join(ls) + "\n" if ls else ""

    def get_top(self, key):
        sc = self.scan()
        if not sc.has_top(key):
            return None
        try:
            return self.ad.parse_value(sc.top_value(key))[0]
        except (ValueError, IndexError):
            return {"unparsed": sc.top_value(key)}

    def set_top(self, key, val):
        sc, ls = self.scan(), self.lines()
        line = "%s = %s" % (self.ad.toml_key(key), self.ad.toml_val(val))
        if sc.has_top(key):
            ls[sc.keys[(key,)]] = line
        elif sc.first_header is None:
            ls.append(line)
        else:
            ls.insert(sc.first_header, line)
        self.set_lines(ls)

    def del_top(self, key):
        sc, ls = self.scan(), self.lines()
        if sc.has_top(key):
            del ls[sc.keys[(key,)]]
            self.set_lines(ls)

    def _server_span(self, name):
        """(start, end) line spans of every [mcp_servers.<name>…] table."""
        ls, spans, cur = self.lines(), [], None
        for i, line in enumerate(ls):
            h = self.ad._HDR.match(line)
            if h:
                if cur is not None:
                    spans.append((cur, i))
                    cur = None
                parts = self.ad.split_key(h.group(2))
                if parts[:2] == ("mcp_servers", name):
                    cur = i
        if cur is not None:
            spans.append((cur, len(ls)))
        return spans

    def get_server(self, name):
        sc = self.scan()
        if not sc.has_server(name):
            return None
        out = {}
        for path, raw in sc.values.items():
            if path[:2] != ("mcp_servers", name) or len(path) < 3:
                continue
            try:
                v = self.ad.parse_value(raw)[0]
            except (ValueError, IndexError):
                v = raw
            d = out
            for p in path[2:-1]:
                d = d.setdefault(p, {})
            d[path[-1]] = v
        return out

    def set_server(self, name, srv):
        self.del_server(name)
        ls = self.lines()
        while ls and not ls[-1].strip():
            ls.pop()
        if ls:
            ls.append("")
        ls.append("[mcp_servers.%s]" % self.ad.toml_key(name))
        for k, v in srv.items():
            ls.append("%s = %s" % (self.ad.toml_key(k), self.ad.toml_val(v)))
        self.set_lines(ls)

    def del_server(self, name):
        ls = self.lines()
        for s, e in reversed(self._server_span(name)):
            while e > s and e - 1 < len(ls) and not ls[e - 1].strip():
                e -= 1
            del ls[s:e]
            while s < len(ls) and s > 0 and not ls[s].strip() and not ls[s - 1].strip():
                del ls[s]
        while ls and not ls[-1].strip():
            ls.pop()
        self.set_lines(ls)

    def dirty(self):
        return self.text != self.orig


def hook_find(settings, event, command):
    """(group index, hook index, {matcher, command, timeout}) or None."""
    groups = ((settings or {}).get("hooks") or {}).get(event) or []
    for gi, g in enumerate(groups if isinstance(groups, list) else []):
        for hi, h in enumerate((g or {}).get("hooks") or []):
            if isinstance(h, dict) and h.get("command") == command:
                v = {"command": command}
                if g.get("matcher"):
                    v["matcher"] = g["matcher"]
                if "timeout" in h:
                    v["timeout"] = h["timeout"]
                return gi, hi, v
    return None


def hook_del(settings, event, command):
    f = hook_find(settings, event, command)
    if not f:
        return
    gi, hi, _ = f
    groups = settings["hooks"][event]
    del groups[gi]["hooks"][hi]
    if not groups[gi]["hooks"]:
        del groups[gi]
    if not groups:
        del settings["hooks"][event]
    if not settings["hooks"]:
        del settings["hooks"]


def hook_set(settings, event, val):
    hook_del(settings, event, val["command"])
    h = {"type": "command", "command": val["command"]}
    if "timeout" in val:
        h["timeout"] = val["timeout"]
    g = {"hooks": [h]}
    if val.get("matcher"):
        g = {"matcher": val["matcher"], "hooks": [h]}
    settings.setdefault("hooks", {}).setdefault(event, []).append(g)


def hook_key(command):
    return hashlib.sha256(command.encode()).hexdigest()[:10]


def skill_get(d, name):
    try:
        with open(os.path.join(d, name, "SKILL.md"), encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return None


def skill_body(text):
    """The team's text as installed: the marker after the front matter's end."""
    return text if SKILL_MARK in text else text.rstrip("\n") + "\n\n" + SKILL_MARK + "\n"


# --- compose -----------------------------------------------------------------------

def compose(c, path, cur, want, default, prev, blocked, ad, write, drop):
    """One item. Returns the row for agent-effective.json, or None (nothing here)."""
    hcur = digest(cur) if cur is not None else None
    team_owned = bool(prev and prev.get("source") == "team" and prev.get("hash") == hcur and cur is not None)
    if ad.shielded(path, blocked):
        if cur is None:
            return None
        return {"source": "local", "why": "override"}
    target = want if want is not None else (default if team_owned else None)
    if cur is None:
        if want is None:
            return None
        write(want)
        c.say("set            %s (team)" % path)
        c.changed += 1
        return {"source": "team", "hash": digest(want)}
    if team_owned:
        if target is None:
            drop()
            c.say("drop           %s (the team no longer hands it out)" % path)
            c.changed += 1
            return None
        if digest(target) != hcur:
            write(target)
            c.say("set            %s (%s)" % (path, "team" if want is not None else "back to the fleet default"))
            c.changed += 1
        if want is None:
            return {"source": "default"}
        return {"source": "team", "hash": digest(want)}
    if default is not None and hcur == digest(default):
        if want is not None and digest(want) != hcur:
            write(want)
            c.say("set            %s (team over the fleet default)" % path)
            c.changed += 1
            return {"source": "team", "hash": digest(want)}
        if want is not None:
            return {"source": "team", "hash": digest(want)}
        return {"source": "default"}
    if want is not None and digest(want) != hcur:
        c.say("own            %s — this login's value wins over the team's" % path)
    return {"source": "local"}


def defaults_for(ad, a):
    """The fleet defaults the team layer sits on: claude/codex MCP, Codex keys,
    Claude settings keys — the values fleet-agent-defaults.py fills."""
    base = os.path.join(a.root, "conf", "agent-defaults")
    out = {"mcp": {}, "codex_mcp": {}, "codex": {}, "settings": {}}
    m = read_json_quiet(os.path.join(base, "claude", "mcp.default.json")) or {}
    out["mcp"] = dict(m.get("mcpServers") or {})
    try:
        out["codex"], out["codex_mcp"] = ad.parse_defaults_toml(os.path.join(base, "codex", "config.default.toml"))
    except SystemExit:
        out["codex"], out["codex_mcp"] = {}, {}
    if a.scripts_root:
        sp = ad.scripts_spelling(a.scripts_root)
        out["mcp"] = ad.reroot(out["mcp"], sp)
        out["codex_mcp"] = ad.reroot(out["codex_mcp"], sp)
    s = read_json_quiet(os.path.join(a.root, "conf", "claude-settings.default.json")) or {}
    out["settings"] = dict(s.get("settings") or {})
    return out


def team_off(override_path):
    d = read_json_quiet(override_path)
    if isinstance(d, list):
        return "team" in d or "team:off" in d or "team: off" in d
    if isinstance(d, dict) and "team" in d:
        v = d["team"]
        return v is False or str(v).strip().lower() in ("off", "false", "0", "no")
    return False


def apply(a):
    cache = read_json_quiet(CACHE)
    record = read_json_quiet(EFFECTIVE)
    if cache is None and record is None:
        print("team: none — no team layer on this computer (nothing fetched, nothing written)")
        return 0
    cache = cache if isinstance(cache, dict) else {}
    bundle = cache.get("bundle") or {}
    why = validate(bundle)
    if why:
        die("the cached team bundle is refused: %s — nothing applied" % why)
    off = team_off(a.override)
    if off:
        bundle = {}
    version = cache.get("version") or 0
    ad = load_mod("fleet_agent_defaults", "fleet-agent-defaults.py")
    hm = load_mod("fleet_hooks_merge", "fleet-hooks-merge.py")
    dfl = defaults_for(ad, a)
    blocked = ad.override_paths(a.override, [])
    blocked.discard("team")
    prev_items = (record or {}).get("items") or {}
    items = {}
    c = Ctx(a, dfl)
    files = []

    # --- Claude: ~/.claude.json mcpServers — read, composed and written under
    # Claude Code's own lock (fleet-hooks-merge.py's, never stolen) ---
    def claude_json():
        cj = JsonFile(a.claude_config, True)
        claude_mcp(cj)
        if cj.dirty() and not a.dry_run:
            hm.write_settings(cj.path, cj.data, backup=False)

    def claude_mcp(cj):
        if not isinstance(cj.data, dict):
            if cj.data is None and bundle.get("mcp"):
                c.say("absent  %s — Claude Code has not run on this login yet; the team's servers wait for the next sync"
                      % a.claude_config)
            return
        servers = cj.data.get("mcpServers") if isinstance(cj.data.get("mcpServers"), dict) else None
        names = set(bundle.get("mcp", {})) | set(dfl["mcp"]) | set(servers or {}) \
            | {k.split(".", 2)[2] for k in prev_items if k.startswith("claude.mcp.")}
        for n in sorted(names):
            path = "claude.mcp." + n
            cur = (servers or {}).get(n)

            def w(v, n=n):
                cj.data.setdefault("mcpServers", {})[n] = json.loads(json.dumps(v))

            def dr(n=n):
                cj.data.get("mcpServers", {}).pop(n, None)
            row = compose(c, path, cur, bundle.get("mcp", {}).get(n), dfl["mcp"].get(n), prev_items.get(path),
                          blocked, ad, w, dr)
            if row:
                items[path] = row
            servers = cj.data.get("mcpServers") if isinstance(cj.data.get("mcpServers"), dict) else None

    if a.dry_run or not os.path.exists(a.claude_config):
        claude_json()
    else:
        hm.with_config_lock(a.claude_config, claude_json)

    # --- Claude: settings.json keys + hooks ---
    sj = JsonFile(a.claude_settings, False)
    if sj.data is None and (bundle.get("claude_settings") or bundle.get("hooks")):
        sj.data = {}
    if isinstance(sj.data, dict):
        keys = set(bundle.get("claude_settings", {})) \
            | {k.split(".", 2)[2] for k in prev_items if k.startswith("claude.settings.")}
        for k in sorted(keys):
            path = "claude.settings." + k

            def w(v, k=k):
                sj.data[k] = json.loads(json.dumps(v))

            def dr(k=k):
                sj.data.pop(k, None)
            row = compose(c, path, sj.data.get(k), bundle.get("claude_settings", {}).get(k),
                          dfl["settings"].get(k), prev_items.get(path), blocked, ad, w, dr)
            if row:
                items[path] = row
        want_hooks = {}
        for ev, lst in bundle.get("hooks", {}).items():
            for h in lst:
                want_hooks["claude.hooks.%s.%s" % (ev, hook_key(h["command"]))] = (ev, h)
        for path in sorted(set(want_hooks) | {k for k in prev_items if k.startswith("claude.hooks.")}):
            ev, h = want_hooks.get(path, (None, None))
            if h is None:
                prow = prev_items[path]
                ev, cmd = prow.get("event"), prow.get("command")
            else:
                cmd = h["command"]
            if not ev or not cmd:
                continue
            f = hook_find(sj.data, ev, cmd)
            want = None
            if h is not None:
                want = {k: h[k] for k in ("matcher", "command", "timeout") if k in h and h[k] not in ("", None)}

            def w(v, ev=ev):
                hook_set(sj.data, ev, v)

            def dr(ev=ev, cmd=cmd):
                hook_del(sj.data, ev, cmd)
            row = compose(c, path, f[2] if f else None, want, None, prev_items.get(path), blocked, ad, w, dr)
            if row:
                row.update({"event": ev, "command": cmd})
                items[path] = row
        files.append(sj)

    # --- skills: Claude + every Codex home ---
    homes = []
    for h in (a.codex_home or ad.default_codex_homes()):
        h = os.path.abspath(os.path.expanduser(h))
        if h not in homes and os.path.isdir(h):
            homes.append(h)
    skill_dirs = []
    if a.claude_skills:
        skill_dirs.append(("claude.skills", a.claude_skills))
    for h in homes:
        skill_dirs.append(("codex.skills" if len(homes) == 1 else "codex[%s].skills" % ad.tilde(h),
                           os.path.join(h, "skills")))
    skill_writes = []
    for tag, d in skill_dirs:
        names = set(bundle.get("skills", {})) | {k[len(tag) + 1:] for k in prev_items if k.startswith(tag + ".")}
        for n in sorted(names):
            path = "%s.%s" % (tag, n)
            t = bundle.get("skills", {}).get(n)
            want = skill_body(t) if t is not None else None

            def w(v, d=d, n=n):
                skill_writes.append(("w", os.path.join(d, n), v))

            def dr(d=d, n=n):
                skill_writes.append(("d", os.path.join(d, n), None))
            canon = ("claude.skills." if tag == "claude.skills" else "codex.skills.") + n
            row = compose(c, canon, skill_get(d, n), want, None, prev_items.get(path), blocked, ad, w, dr)
            if row:
                items[path] = row

    # --- Codex: config.toml keys + servers, each home ---
    confs = []
    for h in homes:
        tag = "codex" if len(homes) == 1 else "codex[%s]" % ad.tilde(h)
        cc = CodexConf(ad, h)
        sc = cc.scan()
        keys = set(bundle.get("codex_config", {})) | set(dfl["codex"]) \
            | {k[len(tag) + 1:] for k in prev_items if k.startswith(tag + ".") and "." not in k[len(tag) + 1:]}
        for k in sorted(keys):
            path = "%s.%s" % (tag, k)
            row = compose(c, "codex." + k, cc.get_top(k), bundle.get("codex_config", {}).get(k), dfl["codex"].get(k),
                          prev_items.get(path), blocked, ad, lambda v, k=k, cc=cc: cc.set_top(k, v),
                          lambda k=k, cc=cc: cc.del_top(k))
            if row:
                items[path] = row
        if sc.mcp_inline():
            if bundle.get("mcp"):
                c.say("own            %s mcp — mcp_servers is an inline table, not extended" % tag)
        else:
            known = {p[1] for p in sc.tables if len(p) >= 2 and p[0] == "mcp_servers"} \
                | {p[1] for p in sc.keys if len(p) >= 2 and p[0] == "mcp_servers"}
            names = set(bundle.get("mcp", {})) | set(dfl["codex_mcp"]) | known \
                | {k[len(tag) + 5:] for k in prev_items if k.startswith(tag + ".mcp.")}
            for n in sorted(names):
                path = "%s.mcp.%s" % (tag, n)
                row = compose(c, "codex.mcp." + n, cc.get_server(n), bundle.get("mcp", {}).get(n),
                              dfl["codex_mcp"].get(n), prev_items.get(path), blocked, ad,
                              lambda v, n=n, cc=cc: cc.set_server(n, v), lambda n=n, cc=cc: cc.del_server(n))
                if row:
                    items[path] = row
        confs.append(cc)

    # --- write ---
    if not a.dry_run:
        for f in files:
            if f.dirty():
                hm.write_settings(f.path, f.data, backup=False)
        for cc in confs:
            if cc.dirty():
                if ad._toml is not None:
                    try:
                        ad._toml.loads(cc.text)
                    except Exception as e:  # noqa: BLE001
                        die("%s: the composed file would not parse (%s) — nothing written" % (cc.path, e))
                ad.write_text(cc.path, cc.text, False)
        for op, d, v in skill_writes:
            if op == "w":
                os.makedirs(d, exist_ok=True)
                with open(os.path.join(d, "SKILL.md"), "w", encoding="utf-8") as fh:
                    fh.write(v)
            else:
                try:
                    os.remove(os.path.join(d, "SKILL.md"))
                    if not os.listdir(d):
                        os.rmdir(d)
                except OSError:
                    pass
        counts = {}
        for row in items.values():
            counts[row["source"]] = counts.get(row["source"], 0) + 1
        write_json_atomic(EFFECTIVE, {
            "team": {"version": version, "state": "off" if off else ("on" if cache else "none"),
                     "created": cache.get("created"), "actor": cache.get("actor"), "applied": int(time.time())},
            "counts": counts, "items": items})
    word = "would change" if a.dry_run else "changed"
    state = "off (agent-overrides.json team: off)" if off else "v%d" % version
    print("team: %s — %s %d item(s)%s" % (state, word, c.changed, "" if a.dry_run else "; %s" % EFFECTIVE))
    return 0


def status(a):
    rec = read_json_quiet(EFFECTIVE)
    cache = read_json_quiet(CACHE)
    if not isinstance(rec, dict):
        if isinstance(cache, dict):
            print("team v%s fetched, not applied yet" % cache.get("version"))
        elif not a.short:
            print("no team layer on this computer")
        return 0
    t = rec.get("team") or {}
    counts = rec.get("counts") or {}
    head = "team off" if t.get("state") == "off" else "team v%s" % t.get("version")
    if isinstance(cache, dict) and cache.get("version") != t.get("version") and t.get("state") != "off":
        head += " (v%s fetched, not applied)" % cache.get("version")
    if a.short:
        print(head)
    else:
        print("%s · %s" % (head, " · ".join("%s %d" % (k, counts.get(k, 0)) for k in ("default", "team", "local"))))
    return 0


def operator(a):
    url = hub_url(a.hub)
    tok = os.environ.get("CCQUOTA_VIEWER_TOKEN") or ""
    if not url or not tok:
        die("%s — the operator's call needs the hub URL and CCQUOTA_VIEWER_TOKEN in the environment"
            % ("no hub URL" if not url else "no CCQUOTA_VIEWER_TOKEN"))
    hdr = {"Authorization": "Bearer " + tok, "Accept": "application/json", "Content-Type": "application/json"}
    if a.action == "history":
        code, raw = http(url + TEAM_PATH + "?history=1", "GET", hdr, None, a.timeout)
    else:
        body = {"note": a.note} if a.note else {}
        if a.base is not None:
            body["base"] = a.base
        if a.action == "put":
            b = read_json(a.arg)
            if b is None:
                die("%s: no such file" % a.arg)
            if isinstance(b, dict) and set(b) == {"bundle"}:
                b = b["bundle"]
            why = validate(b)
            if why:
                die("refused before sending: %s" % why)
            body["bundle"] = b
        else:
            try:
                body["restore"] = int(a.arg)
            except (TypeError, ValueError):
                die("restore takes a version number")
        code, raw = http(url + TEAM_PATH, "PUT", hdr, json.dumps(body).encode(), a.timeout)
    try:
        resp = json.loads(raw.decode())
    except ValueError:
        resp = {"error": raw.decode(errors="replace")[:200]}
    if code != 200:
        die("the hub answered %s: %s" % (code or "nothing", resp.get("error", resp)), 1)
    if a.action == "history":
        print("current v%s" % resp.get("version"))
        for h in resp.get("history") or []:
            print("v%-4s prev v%-4s %s  %s%s" % (h.get("version"), h.get("prev"), h.get("created"), h.get("actor"),
                                                 "  — " + h["note"] if h.get("note") else ""))
    else:
        print("team: v%s (prev v%s) — every computer composes it on its next sync" % (resp.get("version"), resp.get("prev")))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=("fetch", "apply", "sync", "status", "put", "restore", "history"))
    ap.add_argument("arg", nargs="?", default=None, help="put: the bundle file · restore: the version")
    ap.add_argument("--base", type=int, default=None)
    ap.add_argument("--note", default="")
    ap.add_argument("--hub", default="")
    ap.add_argument("--timeout", type=float, default=float(os.environ.get("FLEET_TEAM_TIMEOUT") or 8))
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--scripts-root", default=None)
    ap.add_argument("--claude-config", default=os.path.join(
        os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~"), ".claude.json"))
    cdir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    ap.add_argument("--claude-settings", default=os.path.join(cdir, "settings.json"))
    ap.add_argument("--claude-skills", default=os.path.join(cdir, "skills"))
    ap.add_argument("--codex-home", action="append", default=[])
    ap.add_argument("--override", default=os.path.join(CONF_DIR, "agent-overrides.json"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--short", action="store_true")
    a = ap.parse_args()
    if a.action in ("put", "restore", "history"):
        return operator(a)
    if a.action == "status":
        return status(a)
    if a.action == "apply":
        return apply(a)
    rc, v, note = fetch(a)
    print("team: v%s (%s)" % (v if v is not None else "-", note) if rc == 0 else "team: %s" % note)
    if a.action == "fetch":
        return rc
    if rc == 3 and not os.path.exists(EFFECTIVE):
        return 3
    rec = read_json_quiet(EFFECTIVE) or {}
    applied = (rec.get("team") or {}).get("version")
    state = (rec.get("team") or {}).get("state")
    if a.force or not rec or applied != v or state != ("off" if team_off(a.override) else "on"):
        arc = apply(a)
        return arc if rc in (0, 3) else rc
    return rc


if __name__ == "__main__":
    sys.exit(main())
