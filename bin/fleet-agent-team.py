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

The personal layer (issue #1857, EPIC #1855 C2) sits between: local > personal
> team > default. It is the person's own bundle (GET /v1/fleet/person-bundle,
cached in $FLEET_CONF_DIR/person-bundle.json, the seam FLEET_PERSON_BUNDLE_CMD),
the same allow-list plus `hook_scripts`, the same credential rules. A row
records WHICH layer wrote it, so a layer that drops an item takes back only what
it wrote and nobody touched — a personal item the team also hands goes back to
the team's value. `"personal": "off"` in agent-overrides.json leaves it. No
person behind the login (404), or one who never wrote (version 0): no cache, and
every output below is byte for byte what it is with no personal layer at all.

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
          the response JSON instead. Prints `team: v<N> (new|unchanged)`, then
          the personal layer's read the same way (`personal: v<N> (…)` — only
          when there is one; its failure never changes the exit code).
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
  status  [--short]  the applied version(s) and the source counts (doctor):
          `team v<N>`. With a personal layer (EPIC #1855 C6) --short prints the
          ONE person-facing line instead — `团队 v<N> · 个人 v<M> · 本机独有 <K> 项
          （fleet config promote 可带走）`, K = the 本机 rows `fleet config show`
          lists; the doctor rows and the launch line only reprint it.

A session's configuration, fixed at launch (issue #1782 — see "the session's
configuration" below):
  session  claude|codex [--lock warn|enforce] [--mod-off] [--no-mcp] [--no-settings]
           Compose fleet default < team < local NOW and print, TAB-separated, what
           the launcher hands: `fp <12 hex>`, `src <each layer's version>` (a
           `personal:v<N>|off` segment only when there is a personal layer),
           `mod on|off|na`, `say <the status --short line>` (only with a
           personal layer: the launcher prints it), `mcp <file>` / `settings <file>` (Claude: only what the
           login's files lack, in content-addressed files under global/agent-cfg/),
           `c <key=toml>` (Codex -c values), `lock <path> used|ignored (…)`.
  expected [--write]   the fingerprint a fresh session would get, per agent
           (`<agent> <fp> <src>`); --write caches it in global/agent-cfg.expected.
  check    the doctor's `agentcfg` row: exit 1 when a locked item is overridden here.

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
PERSON_CACHE = os.path.join(CONF_DIR, "person-bundle.json")
EFFECTIVE = os.path.join(CONF_DIR, "agent-effective.json")
TEAM_PATH = "/v1/fleet/team-bundle"
PERSON_PATH = "/v1/fleet/person-bundle"
SIG_NS = "fleet-team@claude-fleet"
PERSON_SIG_NS = "fleet-person@claude-fleet"
# The layers a fleet write can come from, high → low (EPIC #1855: local >
# personal > team > default). A row whose source is one of these is the
# fleet's to follow while it still holds what that layer wrote.
LAYERS = ("personal", "team")
WHOSE = {"team": "team's", "personal": "personal layer's"}
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


def validate(b, layer="team"):
    """'' when the bundle may be applied, else the one-line reason. The personal
    layer (#1857) has the team's allow-list plus `hook_scripts` (C4's)."""
    if not isinstance(b, dict):
        return "bundle is not an object"
    allowed = ALLOWED + (("hook_scripts",) if layer == "personal" else ())
    for k in b:
        if k not in allowed:
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
        return "%s looks like a credential — the %s layer never carries one" % (p, layer)
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


def cert_proof(ns=SIG_NS, word="fleet-team"):
    key = os.environ.get("FLEET_CERT") or os.path.join(os.path.expanduser("~"), ".ssh", "fleet-cert")
    cert = key + "-cert.pub"
    if not (os.path.exists(key) and os.path.exists(cert)):
        return None
    ts = int(time.time())
    try:
        sig = subprocess.run(["ssh-keygen", "-Y", "sign", "-f", key, "-n", ns],
                             input=("%s %d" % (word, ts)).encode(), capture_output=True, check=True).stdout.decode()
        with open(cert) as f:
            line = f.readline().strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return {"cert": line, "sig": sig, "ts": ts}


def http(url, method, headers, body, timeout, got=None):
    """(status, body); `got` (a dict) receives the response's headers."""
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if got is not None:
                got.update({k.lower(): v for k, v in r.headers.items()})
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


def fetch_person(a):
    """The personal layer (issue #1857, EPIC #1855 C2): this login's person's own
    bundle, GET /v1/fleet/person-bundle with the same credentials as the team's.
    (rc, version, note). No person behind this login (404), or one who never
    wrote (version 0) → note "none" and NO cache — the degenerate case; a cache
    that was there is removed so the next apply takes back what it wrote."""
    cached = read_json_quiet(PERSON_CACHE)
    cached = cached if isinstance(cached, dict) else None
    have = cached.get("version") if cached else None
    got = {}
    if os.environ.get("FLEET_PERSON_BUNDLE_CMD"):
        p = subprocess.run(["bash", "-c", os.environ["FLEET_PERSON_BUNDLE_CMD"]], capture_output=True)
        if p.returncode != 0:
            return 1, have, "FLEET_PERSON_BUNDLE_CMD exit %d" % p.returncode
        code, raw = (200 if p.stdout.strip() else 404), p.stdout
    else:
        url = hub_url(a.hub)
        if not url:
            return 3, have, "no hub configured — no personal layer on this computer"
        hdr = {"Accept": "application/json"}
        if cached and cached.get("etag"):
            hdr["If-None-Match"] = cached["etag"]
        tok = env_file_val(os.path.join(CONF_DIR, "node.env"), "CCQUOTA_TOKEN")
        code, raw = 0, b""
        if tok:
            code, raw = http(url + PERSON_PATH, "GET", dict(hdr, Authorization="Bearer " + tok), None, a.timeout, got)
        if code in (0, 401, 403) or not tok:
            proof = cert_proof(PERSON_SIG_NS, "fleet-person")
            if proof:
                code, raw = http(url + PERSON_PATH, "POST", dict(hdr, **{"Content-Type": "application/json"}),
                                 json.dumps(proof).encode(), a.timeout, got)
            elif not tok:
                return 1, have, "no node token and no connection certificate (fleet login) to read the personal layer with"
        if code == 304:
            return 0, have, "unchanged"
        if code not in (200, 404):
            msg = raw.decode(errors="replace").strip()
            try:
                msg = json.loads(msg).get("error", msg)
            except (ValueError, AttributeError):
                pass
            return 1, have, "the hub answered %s: %s" % (code or "nothing", msg[:200])
    resp = {}
    if code == 200:
        try:
            resp = json.loads(raw.decode())
            version, bundle = int(resp.get("version") or 0), resp.get("bundle") or {}
        except (ValueError, AttributeError, TypeError):
            return 2, have, "the hub's answer is not a personal bundle"
    else:
        version, bundle = 0, {}
    if version == 0 and not bundle:
        if cached is None:
            return 0, None, "none"
        try:
            os.remove(PERSON_CACHE)
        except OSError:
            pass
        return 0, None, "none (v%s taken back)" % have
    why = validate(bundle, "personal")
    if why:
        return 2, have, "refused v%d: %s (kept v%s)" % (version, why, have)
    if version == have and cached.get("bundle") == bundle:
        return 0, have, "unchanged"
    write_json_atomic(PERSON_CACHE, {"version": version, "prev": resp.get("prev"), "created": resp.get("created"),
                               "actor": resp.get("actor"), "bundle": bundle, "fetched": int(time.time()),
                               "etag": got.get("etag")})
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

def compose(c, path, cur, layers, default, prev, blocked, ad, write, drop):
    """One item. `layers` = [(source, value)] high → low (personal, team; a value
    None = that layer does not hand it out). Returns the row for
    agent-effective.json, or None (nothing here). A row records which layer
    wrote it (+ the hash of what it wrote), so a layer that stops handing an item
    out takes back only what IT wrote and nobody touched since (#1857)."""
    want, wsrc = None, None
    for lsrc, v in layers:
        if v is not None:
            want, wsrc = v, lsrc
            break
    hcur = digest(cur) if cur is not None else None
    owner = prev.get("source") if prev and prev.get("source") in LAYERS and prev.get("hash") == hcur \
        and cur is not None else None
    if ad.shielded(path, blocked):
        if cur is None:
            return None
        return {"source": "local", "why": "override"}
    target = want if want is not None else (default if owner else None)
    if cur is None:
        if want is None:
            return None
        write(want)
        c.say("set            %s (%s)" % (path, wsrc))
        c.changed += 1
        return {"source": wsrc, "hash": digest(want)}
    if owner:
        if target is None:
            drop()
            c.say("drop           %s (the %s no longer hands it out)"
                  % (path, "team" if owner == "team" else "personal layer"))
            c.changed += 1
            return None
        if digest(target) != hcur:
            write(target)
            c.say("set            %s (%s)" % (path, wsrc if want is not None else "back to the fleet default"))
            c.changed += 1
        if want is None:
            return {"source": "default"}
        return {"source": wsrc, "hash": digest(want)}
    if default is not None and hcur == digest(default):
        if want is not None and digest(want) != hcur:
            write(want)
            c.say("set            %s (%s over the fleet default)" % (path, wsrc))
            c.changed += 1
            return {"source": wsrc, "hash": digest(want)}
        if want is not None:
            return {"source": wsrc, "hash": digest(want)}
        return {"source": "default"}
    if want is not None and digest(want) != hcur:
        c.say("own            %s — this login's value wins over the %s" % (path, WHOSE[wsrc]))
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


def layer_off(override_path, layer):
    """agent-overrides.json leaves a whole layer: `"team": "off"` / `"personal": "off"`
    (or the layer's name in the array form)."""
    d = read_json_quiet(override_path)
    if isinstance(d, list):
        return layer in d or layer + ":off" in d or layer + ": off" in d
    if isinstance(d, dict) and layer in d:
        v = d[layer]
        return v is False or str(v).strip().lower() in ("off", "false", "0", "no")
    return False


def team_off(override_path):
    return layer_off(override_path, "team")


def personal_off(override_path):
    return layer_off(override_path, "personal")


def personal_layer(override_path):
    """(cache dict | None, state 'on'|'off'|None, bundle). None state = no personal
    layer on this login — the degenerate case, where nothing anywhere mentions one."""
    pc = read_json_quiet(PERSON_CACHE)
    if not isinstance(pc, dict):
        return None, None, {}
    if personal_off(override_path):
        return pc, "off", {}
    b = pc.get("bundle") or {}
    return pc, "on", (b if isinstance(b, dict) and not validate(b, "personal") else {})


def apply(a):
    cache = read_json_quiet(CACHE)
    record = read_json_quiet(EFFECTIVE)
    pcache, pstate, pbundle = personal_layer(a.override)
    if cache is None and record is None and pcache is None:
        print("team: none — no team layer on this computer (nothing fetched, nothing written)")
        return 0
    cache = cache if isinstance(cache, dict) else {}
    bundle = cache.get("bundle") or {}
    why = validate(bundle)
    if why:
        die("the cached team bundle is refused: %s — nothing applied" % why)
    if pcache is not None:
        why = validate(pcache.get("bundle") or {}, "personal")
        if why:
            die("the cached personal bundle is refused: %s — nothing applied" % why)
    off = team_off(a.override)
    if off:
        bundle = {}
    version = cache.get("version") or 0
    ad = load_mod("fleet_agent_defaults", "fleet-agent-defaults.py")
    hm = load_mod("fleet_hooks_merge", "fleet-hooks-merge.py")
    dfl = defaults_for(ad, a)
    blocked = ad.override_paths(a.override, [])
    blocked.discard("team")
    blocked.discard("personal")

    def L(kind, name, conv=None):
        """The layers' values for one item, high → low."""
        out = []
        for lsrc, b in (("personal", pbundle), ("team", bundle)):
            v = (b.get(kind) or {}).get(name)
            out.append((lsrc, conv(v) if conv and v is not None else v))
        return out

    def names(kind):
        return set(bundle.get(kind) or {}) | set(pbundle.get(kind) or {})
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
            if cj.data is None and (bundle.get("mcp") or pbundle.get("mcp")):
                c.say("absent  %s — Claude Code has not run on this login yet; the %s servers wait for the next sync"
                      % (a.claude_config, "team's" if bundle.get("mcp") else "personal layer's"))
            return
        servers = cj.data.get("mcpServers") if isinstance(cj.data.get("mcpServers"), dict) else None
        ns = names("mcp") | set(dfl["mcp"]) | set(servers or {}) \
            | {k.split(".", 2)[2] for k in prev_items if k.startswith("claude.mcp.")}
        for n in sorted(ns):
            path = "claude.mcp." + n
            cur = (servers or {}).get(n)

            def w(v, n=n):
                cj.data.setdefault("mcpServers", {})[n] = json.loads(json.dumps(v))

            def dr(n=n):
                cj.data.get("mcpServers", {}).pop(n, None)
            row = compose(c, path, cur, L("mcp", n), dfl["mcp"].get(n), prev_items.get(path),
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
    if sj.data is None and (bundle.get("claude_settings") or bundle.get("hooks")
                            or pbundle.get("claude_settings") or pbundle.get("hooks")):
        sj.data = {}
    if isinstance(sj.data, dict):
        keys = names("claude_settings") \
            | {k.split(".", 2)[2] for k in prev_items if k.startswith("claude.settings.")}
        for k in sorted(keys):
            path = "claude.settings." + k

            def w(v, k=k):
                sj.data[k] = json.loads(json.dumps(v))

            def dr(k=k):
                sj.data.pop(k, None)
            row = compose(c, path, sj.data.get(k), L("claude_settings", k),
                          dfl["settings"].get(k), prev_items.get(path), blocked, ad, w, dr)
            if row:
                items[path] = row
        want_hooks = {}         # path → {layer: (event, hook)}
        for lsrc, b in (("personal", pbundle), ("team", bundle)):
            for ev, lst in (b.get("hooks") or {}).items():
                for h in lst:
                    want_hooks.setdefault("claude.hooks.%s.%s" % (ev, hook_key(h["command"])), {})[lsrc] = (ev, h)
        for path in sorted(set(want_hooks) | {k for k in prev_items if k.startswith("claude.hooks.")}):
            per = want_hooks.get(path, {})
            ev, h = per.get("personal") or per.get("team") or (None, None)
            if h is None:
                prow = prev_items[path]
                ev, cmd = prow.get("event"), prow.get("command")
            else:
                cmd = h["command"]
            if not ev or not cmd:
                continue
            f = hook_find(sj.data, ev, cmd)
            want = []
            for lsrc in ("personal", "team"):
                hh = per.get(lsrc, (None, None))[1]
                want.append((lsrc, None if hh is None else
                             {k: hh[k] for k in ("matcher", "command", "timeout") if k in hh and hh[k] not in ("", None)}))

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
        ns = names("skills") | {k[len(tag) + 1:] for k in prev_items if k.startswith(tag + ".")}
        for n in sorted(ns):
            path = "%s.%s" % (tag, n)
            want = L("skills", n, skill_body)

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
        keys = names("codex_config") | set(dfl["codex"]) \
            | {k[len(tag) + 1:] for k in prev_items if k.startswith(tag + ".") and "." not in k[len(tag) + 1:]}
        for k in sorted(keys):
            path = "%s.%s" % (tag, k)
            row = compose(c, "codex." + k, cc.get_top(k), L("codex_config", k), dfl["codex"].get(k),
                          prev_items.get(path), blocked, ad, lambda v, k=k, cc=cc: cc.set_top(k, v),
                          lambda k=k, cc=cc: cc.del_top(k))
            if row:
                items[path] = row
        if sc.mcp_inline():
            if bundle.get("mcp") or pbundle.get("mcp"):
                c.say("own            %s mcp — mcp_servers is an inline table, not extended" % tag)
        else:
            known = {p[1] for p in sc.tables if len(p) >= 2 and p[0] == "mcp_servers"} \
                | {p[1] for p in sc.keys if len(p) >= 2 and p[0] == "mcp_servers"}
            ns = names("mcp") | set(dfl["codex_mcp"]) | known \
                | {k[len(tag) + 5:] for k in prev_items if k.startswith(tag + ".mcp.")}
            for n in sorted(ns):
                path = "%s.mcp.%s" % (tag, n)
                row = compose(c, "codex.mcp." + n, cc.get_server(n), L("mcp", n),
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
        rec = {"team": {"version": version, "state": "off" if off else ("on" if cache else "none"),
                        "created": cache.get("created"), "actor": cache.get("actor"), "applied": int(time.time())},
               "counts": counts, "items": items}
        if pcache is not None:     # only when there is a personal layer (#1857): else byte for byte as before
            rec["personal"] = {"version": pcache.get("version") or 0, "state": pstate, "created": pcache.get("created"),
                               "actor": pcache.get("actor"), "applied": rec["team"]["applied"]}
            rec["personal_version"] = pcache.get("version") or 0
        write_json_atomic(EFFECTIVE, rec)
        try:                     # the layer moved: what a fresh session gets moved with it (#1782)
            expected(argparse.Namespace(**dict(vars(a), write=True, quiet=True)))
        except SystemExit:
            pass
    word = "would change" if a.dry_run else "changed"
    state = "off (agent-overrides.json team: off)" if off else "v%d" % version
    if pcache is not None:
        state += " · personal %s" % ("off" if pstate == "off" else "v%s" % (pcache.get("version") or 0))
    print("team: %s — %s %d item(s)%s" % (state, word, c.changed, "" if a.dry_run else "; %s" % EFFECTIVE))
    return 0


def layer_word(state, version):
    return {"off": "已关", "none": "无"}.get(state) or "v%s" % version


def local_only(a):
    """How many rows `fleet config show` lists as 本机 — counted BY that command's
    own composition (fleet-config.py compose_rows), so the two never disagree.
    None when it cannot be counted (no fleet-config.py beside this script)."""
    try:
        fc = load_mod("fleet_config", "fleet-config.py")
        args = fc.team_args(["--root", a.root, "--claude-config", a.claude_config,
                             "--claude-settings", a.claude_settings, "--claude-skills", a.claude_skills,
                             "--override", a.override] + [x for h in a.codex_home for x in ("--codex-home", h)])
        rows, _ = fc.compose_rows(args)
    except (Exception, SystemExit):
        return None
    return sum(1 for r in rows.values() if r.get("source") == "local")


def human_line(a):
    """The ONE line that tells a person where their configuration comes from (EPIC
    #1855 C6): `团队 vN · 个人 vM · 本机独有 K 项（fleet config promote 可带走）`.
    The doctor rows (node + client) and the launch line reprint it, never spell
    their own. None with no personal layer — every caller then prints byte for
    byte what it did before."""
    rec = read_json_quiet(EFFECTIVE)
    p = rec.get("personal") if isinstance(rec, dict) else None
    if not isinstance(p, dict):
        return None
    t = rec.get("team") or {}
    team = layer_word(t.get("state"), t.get("version"))
    cache = read_json_quiet(CACHE)
    if isinstance(cache, dict) and cache.get("version") != t.get("version") and t.get("state") != "off":
        team += "（已取到 v%s，未应用）" % cache.get("version")
    line = "团队 %s · 个人 %s" % (team, layer_word(p.get("state"), p.get("version")))
    n = local_only(a)
    if n:
        line += " · 本机独有 %d 项（fleet config promote 可带走）" % n
    elif n == 0:
        line += " · 本机独有 0 项"
    return line


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
    p = rec.get("personal")
    if isinstance(p, dict):         # the personal layer (#1857) — absent, the line is as before
        ph = "personal off" if p.get("state") == "off" else "personal v%s" % p.get("version")
        head = ph if t.get("state") == "none" else "%s · %s" % (head, ph)
    if a.short:
        print(human_line(a) or head)
    else:
        kinds = ("default", "team", "personal", "local") if isinstance(p, dict) else ("default", "team", "local")
        print("%s · %s" % (head, " · ".join("%s %d" % (k, counts.get(k, 0)) for k in kinds)))
    return 0


# --- the session's configuration, fixed at launch (issue #1782, EPIC #1776 C6) -----
#
# The sync above FILLS files; what a session actually got was whatever those files
# happened to hold when it started. `session` composes the same three layers —
# fleet default < team < local — at the moment of the launch, hands the launcher
# exactly what the files lack (a --settings / --mcp-config file for Claude, `-c`
# values for Codex), and prints a FINGERPRINT of the composed result: the first
# 12 hex of sha256 over the canonical JSON of every item's effective value. The
# launcher stamps it on the window as @agent_cfg (+ @agent_cfg_src, each layer's
# version); `expected` is the same computation with no session, cached for the
# readers that compare (C7, #1783).
#
# Scope (the EPIC's 口径): only what the fleet hands an agent — the mod, the fleet
# hook table (+ the team's hooks), the fleet's MCP servers (default ∪ team), the
# settings / config keys the fleet manages. Never the agent's own version, never a
# per-session thing (cwd, account, model), never a fleet's MCP allowlist — so two
# sessions on one login fingerprint alike, and a stale one differs.
#
# Locks (conf/agent-locked.list): the items fleet itself runs on. A login's own
# value for one — a different definition, or a shield in agent-overrides.json —
# is used and LISTED under FLEET_AGENT_LOCK=warn (the default, the operator's
# week of 先标出不强制), and ignored under enforce (the fleet's value is handed).
# ⚠️ enforce on an MCP server hands the fleet's definition through --mcp-config;
# Claude Code resolves a duplicate NAME by scope and does not document where
# --mcp-config ranks against the user scope, so `check` names such a server — the
# durable fix is to drop the login's own copy.

LOCK_MODES = ("warn", "enforce")


def locked_set(root):
    out = set()
    try:
        with open(os.path.join(root, "conf", "agent-locked.list")) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if line:
                    out.add(line)
    except OSError:
        pass
    return out


def is_locked(path, locked):
    parts = path.split(".")
    return any(".".join(parts[:i]) in locked for i in range(1, len(parts) + 1))


def conf_val(key):
    """A global knob for a caller that sourced no conf (install-apply, a client):
    the environment, else the login's files in the order the launcher sources them
    (install fleet.conf < fleet.settings < $FLEET_CONF_DIR/fleet.conf, #979/#1623)."""
    if os.environ.get(key) is not None:
        return os.environ[key]
    val = None
    pat = re.compile(r"^\s*(?:export\s+)?%s=(.*)$" % re.escape(key))
    for f in (os.path.join(DEFAULT_ROOT, "fleet.conf"), os.path.join(CONF_DIR, "fleet.settings"),
              os.path.join(CONF_DIR, "fleet.conf")):
        try:
            with open(f) as fh:
                for line in fh:
                    m = pat.match(line)
                    if m:
                        val = m.group(1).split("#", 1)[0].strip().strip("'\"")
        except OSError:
            pass
    return val


def lock_mode(arg):
    v = (arg or conf_val("FLEET_AGENT_LOCK") or "warn").strip().lower()
    return v if v in LOCK_MODES else "warn"


def leaves_of(v, prefix):
    """{'permissions': {'defaultMode': x}} → {'permissions.defaultMode': x}."""
    if isinstance(v, dict) and v:
        out = {}
        for k, x in v.items():
            out.update(leaves_of(x, prefix + "." + k))
        return out
    return {prefix: v}


def leaf_get(d, dotted):
    for p in dotted.split("."):
        if not isinstance(d, dict) or p not in d:
            return None
        d = d[p]
    return d


def leaf_set(d, dotted, v):
    ps = dotted.split(".")
    for p in ps[:-1]:
        d = d.setdefault(p, {})
    d[ps[-1]] = v


def mod_version(root):
    d = read_json_quiet(os.path.join(root, "mod", "fleet", ".claude-plugin", "plugin.json"))
    return str(d.get("version") or "?") if isinstance(d, dict) else None


def fleet_plugin_wires_hooks():
    """The fleet plugin (#1335's sibling, .claude-plugin/) wires the hook table
    itself — KEEP IN SYNC with fleet_plugin_installed / fleet-doctor's glob."""
    import glob
    cdir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    return bool(glob.glob(os.path.join(cdir, "plugins", "cache", "*", "fleet", "*", "commands", "fleet-claim.md")))


class Session:
    """One composition: rows {path: {value, source, locked}} + what to hand."""

    def __init__(self, a, agent):
        self.a, self.agent = a, agent
        self.mode = lock_mode(a.lock)
        self.locked = locked_set(a.root)
        self.ad = load_mod("fleet_agent_defaults", "fleet-agent-defaults.py")
        self.hm = load_mod("fleet_hooks_merge", "fleet-hooks-merge.py")
        self.dfl = defaults_for(self.ad, a)
        self.blocked = self.ad.override_paths(a.override, [])
        self.blocked.discard("team")
        self.blocked.discard("personal")
        pc, pstate, self.pbundle = personal_layer(a.override)
        self.personal = None if pc is None else ("off" if pstate == "off" else "v%s" % (pc.get("version") or 0))
        cache = read_json_quiet(CACHE)
        bundle = (cache or {}).get("bundle") if isinstance(cache, dict) else None
        if team_off(a.override):
            self.team, self.bundle = "off", {}
        elif isinstance(bundle, dict) and not validate(bundle):
            self.team, self.bundle = "v%s" % (cache.get("version") or 0), bundle
        else:
            self.team, self.bundle = "none", {}
        self.rows, self.overrides, self.notes = {}, [], []
        self.hand = {}          # path → value the launcher must pass

    def item(self, path, local, personal, team, default, present=None):
        """Compose one item; returns nothing. `present` = the login has it at all
        (for a value that can legitimately be None)."""
        if personal is not None:
            fv, fsrc = personal, "personal"
        elif team is not None:
            fv, fsrc = team, "team"
        elif default is not None:
            fv, fsrc = default, "default"
        else:
            return
        has = (local is not None) if present is None else present
        lk = is_locked(path, self.locked)
        shield = self.ad.shielded(path, self.blocked)
        own = shield or (has and local != fv)
        if not own:
            self.rows[path] = {"value": fv, "source": fsrc, "locked": lk}
            if not has:
                self.hand[path] = fv
            return
        if lk and self.mode == "enforce":
            self.rows[path] = {"value": fv, "source": fsrc, "locked": True}
            self.hand[path] = fv
            self.overrides.append((path, "ignored", "shielded" if shield and not has else "own value"))
            return
        if lk:
            self.overrides.append((path, "used", "shielded" if shield and not has else "own value"))
        if has:
            self.rows[path] = {"value": local, "source": "local", "locked": lk}

    def hook_table(self):
        """The fleet table, canonical: [[event, matcher, command, timeout]] sorted."""
        src = os.path.join(self.a.root, "hooks", "settings-hooks.json")
        d = read_json_quiet(src)
        out = []
        for ev, groups in ((d or {}).get("hooks") or {}).items():
            for g in groups or []:
                for h in g.get("hooks") or []:
                    out.append([ev, g.get("matcher", "") or "", h.get("command", ""), h.get("timeout")])
        return sorted(out, key=lambda r: json.dumps(r))

    def compose(self):
        a, b = self.a, self.bundle
        mv = mod_version(a.root)
        if self.agent == "codex":
            self.rows["mod"] = {"value": "na", "source": "default", "locked": False}
        elif mv is not None:
            self.item("mod", "off" if a.mod_off else None, None, None, mv)
        table = self.hook_table()
        if self.agent == "claude":
            self.claude(table)
        else:
            self.codex(table)
        return self

    def claude(self, table):
        a, b = self.a, self.bundle
        settings = read_json_quiet(a.claude_settings)
        settings = settings if isinstance(settings, dict) else {}
        # the fleet hook table, as one item: what the login wires (settings.json
        # by identity, or the plugin wholesale) against what the table says
        if table:
            if fleet_plugin_wires_hooks():
                have = table
            else:
                idents = set()
                for ev, groups in (settings.get("hooks") or {}).items():
                    for g in groups if isinstance(groups, list) else []:
                        for h in (g or {}).get("hooks") or []:
                            i = self.hm.identity(ev, g, h) if isinstance(h, dict) else None
                            if i:
                                idents.add(i)
                have = [r for r in table if (r[0], r[1], self.hm.script_of(r[2])) in idents]
            self.item("claude.hooks", have if have else None, None, None, table)
            if "claude.hooks" in self.hand:     # hand only the identities missing here
                got = {json.dumps(r) for r in have}
                self.hand["claude.hooks"] = [r for r in table if json.dumps(r) not in got]
        pb = self.pbundle
        hooks = {}              # path → [event, {layer: want}]
        for lsrc, bb in (("personal", pb), ("team", b)):
            for ev, lst in sorted((bb.get("hooks") or {}).items()):
                for h in lst:
                    want = {k: h[k] for k in ("matcher", "command", "timeout") if k in h and h[k] not in ("", None)}
                    hooks.setdefault("claude.hooks.%s.%s" % (ev, hook_key(h["command"])), [ev, {}])[1][lsrc] = want
        for path in sorted(hooks):
            ev, per = hooks[path]
            f = hook_find(settings, ev, (per.get("personal") or per.get("team"))["command"])
            self.item(path, f[2] if f else None, per.get("personal"), per.get("team"), None)
        cj = read_json_quiet(a.claude_config)
        servers = (cj or {}).get("mcpServers") if isinstance(cj, dict) else None
        servers = servers if isinstance(servers, dict) else {}
        for n in sorted(set(self.dfl["mcp"]) | set(b.get("mcp") or {}) | set(pb.get("mcp") or {})):
            self.item("claude.mcp." + n, servers.get(n), (pb.get("mcp") or {}).get(n), (b.get("mcp") or {}).get(n),
                      self.dfl["mcp"].get(n))
        team_keys = b.get("claude_settings") or {}
        pers_keys = pb.get("claude_settings") or {}
        dleaves = {}
        for k, v in self.dfl["settings"].items():
            if k not in team_keys and k not in pers_keys:
                dleaves.update(leaves_of(v, k))
        for k in sorted(set(dleaves) | set(team_keys) | set(pers_keys)):
            self.item("claude.settings." + k, leaf_get(settings, k), pers_keys.get(k), team_keys.get(k), dleaves.get(k))

    def codex(self, table):
        a, b = self.a, self.bundle
        self.rows["codex.hooks"] = {"value": table, "source": "default", "locked": is_locked("codex.hooks", self.locked)}
        home = os.path.abspath(os.path.expanduser(a.codex_home[0] if a.codex_home
                                                  else os.environ.get("CODEX_HOME") or "~/.codex"))
        cc = CodexConf(self.ad, home)
        pb = self.pbundle
        for k in sorted(set(self.dfl["codex"]) | set(b.get("codex_config") or {}) | set(pb.get("codex_config") or {})):
            self.item("codex." + k, cc.get_top(k), (pb.get("codex_config") or {}).get(k),
                      (b.get("codex_config") or {}).get(k), self.dfl["codex"].get(k))
        if cc.scan().mcp_inline():
            self.notes.append("codex mcp_servers is an inline table — servers not handed")
            return
        for n in sorted(set(self.dfl["codex_mcp"]) | set(b.get("mcp") or {}) | set(pb.get("mcp") or {})):
            self.item("codex.mcp." + n, cc.get_server(n), (pb.get("mcp") or {}).get(n), (b.get("mcp") or {}).get(n),
                      self.dfl["codex_mcp"].get(n))

    def fingerprint(self):
        vals = {p: r["value"] for p, r in self.rows.items()}
        return hashlib.sha256(json.dumps({"agent": self.agent, "items": vals}, sort_keys=True,
                                         ensure_ascii=False).encode()).hexdigest()[:12]

    def src(self):
        dv = {p: r["value"] for p, r in self.rows.items() if r["source"] == "default"}
        lv = {p: r["value"] for p, r in self.rows.items() if r["source"] == "local"}
        local = "local:%d" % len(lv) + ("@" + digest(lv)[:8] if lv else "")
        pers = " personal:%s" % self.personal if self.personal else ""   # absent with no personal layer (#1857)
        return "default:%s team:%s%s %s lock:%s" % (digest(dv)[:8], self.team, pers, local, self.mode)


def project_has(cwd, dotted):
    """A project's own settings (cwd's .claude/settings{,.local}.json) are local too:
    --settings outranks them, so a fill never covers a key a project sets."""
    for f in ("settings.json", "settings.local.json"):
        d = read_json_quiet(os.path.join(cwd, ".claude", f))
        if isinstance(d, dict) and leaf_get(d, dotted) is not None:
            return True
    return False


def gen_file(kind, agent, data):
    """Content-addressed, so concurrent launches share one file and never race."""
    body = json.dumps(data, sort_keys=True, ensure_ascii=False, indent=1) + "\n"
    d = os.path.join(CONF_DIR, "global", "agent-cfg")
    path = os.path.join(d, "%s-%s-%s.json" % (agent, kind, hashlib.sha256(body.encode()).hexdigest()[:12]))
    if not os.path.exists(path):
        os.makedirs(d, exist_ok=True)
        tmp = path + ".tmp.%d" % os.getpid()
        with open(tmp, "w") as f:
            f.write(body)
        os.replace(tmp, path)
    return path


def session(a):
    agent = a.arg or "claude"
    if agent not in ("claude", "codex"):
        die("session takes claude|codex")
    s = Session(a, agent).compose()
    print("fp\t%s" % s.fingerprint())
    print("src\t%s" % s.src())
    if s.personal:                  # the person-facing line (EPIC #1855 C6) — absent, as before
        say = human_line(a)
        if say:
            print("say\t%s" % say)
    if agent == "claude":
        mr = s.rows.get("mod")
        print("mod\t%s" % ("on" if mr and mr["value"] != "off" else "off"))
        mcp = {p.split(".", 2)[2]: v for p, v in s.hand.items() if p.startswith("claude.mcp.")}
        if mcp and not a.no_mcp:
            print("mcp\t%s" % gen_file("mcp", agent, {"mcpServers": mcp}))
        st = {}
        for p, v in s.hand.items():
            if p.startswith("claude.settings."):
                k = p[len("claude.settings."):]
                if not project_has(os.getcwd(), k) or s.rows.get(p, {}).get("locked"):
                    leaf_set(st, k, v)
            elif p == "claude.hooks":
                for ev, m, cmd, to in v:
                    h = {"type": "command", "command": cmd}
                    if to is not None:
                        h["timeout"] = to
                    g = {"matcher": m, "hooks": [h]} if m else {"hooks": [h]}
                    st.setdefault("hooks", {}).setdefault(ev, []).append(g)
            elif p.startswith("claude.hooks."):
                hook_set(st, p.split(".")[2], v)
        if st and not a.no_settings:
            print("settings\t%s" % gen_file("settings", agent, st))
    else:
        print("mod\tna")
        for p, v in sorted(s.hand.items()):
            if p.startswith("codex.mcp."):
                if not a.no_mcp:
                    print("c\tmcp_servers.%s=%s" % (s.ad.toml_key(p[len("codex.mcp."):]), s.ad.toml_val(v)))
            elif p.startswith("codex.") and p != "codex.hooks":
                print("c\t%s=%s" % (s.ad.toml_key(p[len("codex."):]), s.ad.toml_val(v)))
    for path, what, why in s.overrides:
        print("lock\t%s %s (%s, FLEET_AGENT_LOCK=%s)" % (path, what, why, s.mode))
    return 0


def expected_lines(a):
    out = []
    for agent in ("claude", "codex"):
        s = Session(a, agent).compose()
        out.append("%s %s %s" % (agent, s.fingerprint(), s.src()))
    return out


def expected(a):
    lines = expected_lines(a)
    if a.write:
        path = os.path.join(CONF_DIR, "global", "agent-cfg.expected")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp.%d" % os.getpid()
        with open(tmp, "w") as f:
            f.write("\n".join(lines) + "\n")
        os.replace(tmp, path)
    if not getattr(a, "quiet", False):
        print("\n".join(lines))
    return 0


def check(a):
    """fleet-doctor's `agentcfg` row: exit 0 nothing locked is overridden here, 1 otherwise."""
    rows, mode = [], lock_mode(a.lock)
    for agent in ("claude", "codex"):
        s = Session(a, agent).compose()
        rows += ["%s (%s, %s)" % (p, why, what) for p, what, why in s.overrides]
        if agent == "claude":
            fp = s.fingerprint()
    n = len(locked_set(a.root))
    if not rows:
        print("ok lock=%s · %d locked item(s), none overridden here · expected claude %s" % (mode, n, fp))
        return 0
    print("%d locked item(s) overridden on this login (lock=%s): %s" % (len(rows), mode, "; ".join(rows)))
    return 1


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


def build_parser():
    """The one argument set (fleet-config.py parses `session claude` with it, #1860)."""
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=("fetch", "apply", "sync", "status", "put", "restore", "history",
                                       "session", "expected", "check"))
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
    ap.add_argument("--lock", default="", help="session/expected/check: warn|enforce (default $FLEET_AGENT_LOCK, else warn)")
    ap.add_argument("--mod-off", action="store_true", default=conf_val("FLEET_MOD") == "0", help="session/expected/check: this login runs FLEET_MOD=0")
    ap.add_argument("--no-mcp", action="store_true", help="session: an MCP allowlist governs — hand no servers")
    ap.add_argument("--no-settings", action="store_true", help="session: the caller passed its own --settings")
    ap.add_argument("--write", action="store_true", help="expected: also cache it in global/agent-cfg.expected")
    return ap


def main():
    a = build_parser().parse_args()
    if a.action == "session":
        return session(a)
    if a.action == "expected":
        return expected(a)
    if a.action == "check":
        return check(a)
    if a.action in ("put", "restore", "history"):
        return operator(a)
    if a.action == "status":
        return status(a)
    if a.action == "apply":
        return apply(a)
    rc, v, note = fetch(a)
    print("team: v%s (%s)" % (v if v is not None else "-", note) if rc == 0 else "team: %s" % note)
    # the personal layer (#1857): its own line only when there is one — no person,
    # or one who never wrote, prints nothing (the degenerate case). A hub that did
    # not answer the team's read is not asked again; the cached layer stands.
    if rc == 1 and not os.environ.get("FLEET_PERSON_BUNDLE_CMD"):
        prc, pnote = 1, ""
    else:
        prc, pv, pnote = fetch_person(a)
        if prc == 0 and pnote != "none":
            print("personal: v%s (%s)" % (pv, pnote) if pv is not None else "personal: %s" % pnote)
        elif prc not in (0, 3):
            print("personal: %s" % pnote)
    if a.action == "fetch":
        return rc
    if rc == 3 and prc == 3 and not os.path.exists(EFFECTIVE):
        return 3
    rec = read_json_quiet(EFFECTIVE) or {}
    applied = (rec.get("team") or {}).get("version")
    state = (rec.get("team") or {}).get("state")
    pc, pstate, _ = personal_layer(a.override)
    prec = rec.get("personal") or {}
    pmoved = (prec.get("version"), prec.get("state")) != ((pc.get("version") or 0) if pc else None, pstate)
    if a.force or not rec or applied != v or state != ("off" if team_off(a.override) else "on") or pmoved:
        arc = apply(a)
        return arc if rc in (0, 3) else rc
    return rc


if __name__ == "__main__":
    sys.exit(main())
