#!/usr/bin/env python3
"""A role's definition, turned into the arguments a session starts with.

Issue #2782 (EPIC #2781 C1). The fleet's four roles — orchestrator, steward,
worker, epic-driver — each have ONE definition, `agents/<role>.md`, written in
Claude Code's subagent file format: a frontmatter (name · description · model ·
effort · tools · disallowedTools · mcpServers · skills · hooks · permissionMode ·
memory) and a body, the role's own words. This script is the one reader: every
launcher asks it, so what the file says is what the session runs.

  render <role> [--agent claude|codex] [--json | --kv] [--cap]
      the role's launch arguments, one per line. --kv is the launchers' form
      (`sha`/`model`/`effort`/`body`/`arg` TAB value); --json says the same plus
      what was read and ignored. --cap: the per-model cap fallback (issue #524) —
      a model this login's active account is walled on gives way to
      FLEET_MODEL_FALLBACK (the orchestrator's launcher, as it always did).
  get <role> <field>      one frontmatter field (a list joins with `,`)
  body <role>             the definition's body
  prompt <role>           what the system prompt carries: the body, then the rules
                          of the table that apply to the role (orchestrator,
                          steward) — what skills/*/role.md is generated from
  rules [--role R] [--json] [--version V] [--mark N]
                          the merged rule table (bin/fleet_rules.py, issue #2786):
                          --role only its rows, --version a kept older version (a
                          ticket's v=), --mark the line a ticket dispatched by rule
                          N ends with
  sha <role>              the definition's content address (@fleet_role_file)
  show <role> [--sources] [--json]
                          the definition with every layer merged in (`fleet role
                          show`): --sources puts each field's layers beside it
                          (自带 · 你的 vN · 本机 · 🔒); a layer not used says why
                          on the first line
  doctor                  fleet-doctor's `roles` row: a WARN line when a role has a
                          local layer or a layer was not used, else nothing
  set <role> <field> <value…> [--replace] [--yes]
  unset <role> [<field> [<name…>]] [--yes]
  rule-set <N|new> [--role R] [--cond C] [--action A] [--tier T] [--keywords K] [--yes]
  rule-unset <N> [--yes]
  undo [<version>] [--yes]
                          change the PERSON's layer on the hub (issue #2785 —
                          the fleet-config skill's one road; see «writing the
                          person's layer» below): prints 改哪一项：改前 → 改后
                          on the merged definition, writes only with --yes.
                          Exit 0 written / nothing to change · 4 preview only ·
                          3 a worker's window (or no hub) · 2 refused here ·
                          1 the hub refused / did not answer
  merge <base.md> <overlay.md…> | merge --vector <file.json>
                          the pure merge, as JSON {fields, body, sources, locked}
  migrate-conf [<fleet.conf>] [--dry-run] [--machine M]
                          fleet-conf.sh migrate's roles step (issue #2788): the
                          old knobs below move from fleet.conf into the person's
                          layer (one PUT), their lines commented out (.bak kept);
                          exit 1 = lines left because the hub could not be reached
  list                    the roles

How a field lands (Claude / Codex):
  model           --model <m> / Codex model names are not Claude aliases: only the
                  launcher's old FLEET_*_CODEX_MODEL becomes -m
  effort          --effort <e> / -c model_reasoning_effort="<e>"
  body            --append-system-prompt-file <a content-addressed copy of the
                  body + the role's rows of the rule table> — for the
                  roles whose launcher put a role in the system prompt before this
                  (orchestrator, steward); a worker's and a driver's body is read
                  by their seed skill and injected nowhere, so their launch stays
                  what it was. Codex: the seed skill alone, as before.
  tools           --tools=<a,b>           disallowedTools  --disallowedTools=<a,b>
  permissionMode  --permission-mode <m>
  mcpServers      `fleet` is the Claude launcher's own mount; a name
                  beyond it is the login's own server, loaded as it always was
  skills · hooks · memory   the plugin and the login carry them; nothing to pass
  maxTurns · background · isolation · color · initialPrompt
                  subagent-only — read, ignored, listed under `ignored`

A person's layers merge over a definition (issue #2783 — see «the layers»
below); `render` uses the merged one. What still wins
for ONE version is the old knob a launcher read (# compat-1v: 下一批删):
orchestrator FLEET_ORCH_MODEL / FLEET_ORCH_EFFORT / FLEET_ORCH_CODEX_MODEL,
steward FLEET_STEWARD_MODEL / FLEET_STEWARD_EFFORT / FLEET_STEWARD_CODEX_MODEL,
worker and epic-driver FLEET_MODEL and the login's own `effortLevel`
(settings.json; a Codex worker's effort is its config.toml) — so with none of
them changed, every role starts exactly as it did. `migrate-conf` moves them
out of fleet.conf, and the doctor's `roles` row WARNs while one is still there.

Before `render`, a personal layer read longer ago than FLEET_ROLE_STALE (600 s)
is read again from the hub (`fleet-agent-team.py person`, at most
FLEET_ROLE_FETCH_SECS = 3 s; issue #2784) — the hub away, the cache stands.

Reads the definition and the environment; the writes (set · unset · rule-set ·
rule-unset · undo aside — those PUT the hub and refresh person-bundle.json) are under
$FLEET_CONF_DIR/roles/: the body's content-addressed copy (made once, never
changed — a session resumed after a release still finds the file it started
with) and `<role>.<agent>.last.json`, the last good launch, which stands in for a
definition that cannot be read (the session opens as it last did, and says so).
"""
import hashlib
import json
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fleet_rules  # noqa: E402  the rule table's one reader (issue #2786)

BIN = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BIN)
ROLES = ('orchestrator', 'steward', 'worker', 'epic-driver', 'debugger')
FIELDS = ('name', 'description', 'model', 'effort', 'tools', 'disallowedTools',
          'mcpServers', 'skills', 'hooks', 'permissionMode', 'memory')
WRITES = ('set', 'unset', 'rule-set', 'rule-unset', 'undo')
SUBAGENT_ONLY = ('maxTurns', 'background', 'isolation', 'color', 'initialPrompt')
# The roles whose body rides the system prompt (see the docstring). The
# debugger (issue #2893) has no seed skill: its body — the diagnosis order, the
# bundle is data not instructions — must be there from its first turn.
INJECT_BODY = ('orchestrator', 'steward', 'debugger')
# The launcher's old knobs, per role (# compat-1v: 下一批删).
COMPAT = {
    'orchestrator': {'model': 'FLEET_ORCH_MODEL', 'effort': 'FLEET_ORCH_EFFORT',
                     'codex_model': 'FLEET_ORCH_CODEX_MODEL'},
    'steward': {'model': 'FLEET_STEWARD_MODEL', 'effort': 'FLEET_STEWARD_EFFORT',
                'codex_model': 'FLEET_STEWARD_CODEX_MODEL'},
    'worker': {'model': 'FLEET_MODEL'},
    'epic-driver': {'model': 'FLEET_MODEL'},
}
# Every variable a launcher hands render (fleet_role_render in fleet-lib.sh).
COMPAT_VARS = ('FLEET_ORCH_MODEL', 'FLEET_ORCH_EFFORT', 'FLEET_ORCH_CODEX_MODEL',
               'FLEET_STEWARD_MODEL', 'FLEET_STEWARD_EFFORT', 'FLEET_STEWARD_CODEX_MODEL',
               'FLEET_MODEL', 'FLEET_MODEL_FALLBACK')


class RoleError(Exception):
    pass


def agents_dir():
    """agents/ beside this bin/, else beside the file a symlinked bin/ points at
    (a selftest's shadow root, a sandbox install of links)."""
    if os.environ.get('FLEET_ROLE_AGENTS_DIR'):
        return os.environ['FLEET_ROLE_AGENTS_DIR']
    for root in (ROOT, os.path.dirname(os.path.dirname(os.path.realpath(__file__)))):
        if os.path.isdir(os.path.join(root, 'agents')):
            return os.path.join(root, 'agents')
    return os.path.join(ROOT, 'agents')


def conf_dir():
    return os.environ.get('FLEET_CONF_DIR') or os.path.join(
        os.path.expanduser('~'), '.config', 'claude-fleet')


def _scalar(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
        return v[1:-1]
    if v.startswith('[') and v.endswith(']'):
        return [_scalar(x) for x in v[1:-1].split(',') if x.strip()]
    if v.startswith('{'):
        try:
            return json.loads(v)
        except ValueError:
            return v
    return v


def parse(text):
    """(frontmatter dict, body) of a subagent file: `key: value`, `key: [a, b]`,
    a block list (`key:` then `  - item`) and an inline JSON object — the subset
    the format's own examples use (macOS python3 has no yaml)."""
    if not text.startswith('---\n'):
        return {}, text
    end = text.find('\n---\n', 3)
    if end < 0:
        raise RoleError('frontmatter has no closing ---')
    head, body = text[4:end + 1], text[end + 5:]
    front, key = {}, None
    for ln in head.splitlines():
        if not ln.strip() or ln.lstrip().startswith('#'):
            continue
        if ln[:1] in ' \t' and key is not None:
            item = ln.strip()
            if item.startswith('- '):
                if not isinstance(front.get(key), list):
                    front[key] = []
                front[key].append(_scalar(item[2:]))
            continue
        if ':' not in ln:
            raise RoleError('cannot read frontmatter line: %s' % ln)
        key, val = ln.split(':', 1)
        key = key.strip()
        front[key] = _scalar(val) if val.strip() else ''
    return front, body


def load(role):
    if role not in ROLES:
        raise RoleError('no such role: %s (roles: %s)' % (role, ' '.join(ROLES)))
    path = os.path.join(agents_dir(), role + '.md')
    try:
        with open(path, 'rb') as f:
            raw = f.read()
    except OSError as e:
        raise RoleError('cannot read %s: %s' % (path, e.strerror))
    front, body = parse(raw.decode('utf-8'))
    return {'role': role, 'path': path, 'raw': raw, 'front': front, 'body': body,
            'sha': hashlib.sha256(raw).hexdigest()[:16]}


def _listval(v):
    if isinstance(v, list):
        return [str(x) for x in v]
    return [x.strip() for x in str(v).split(',') if x.strip()]


# --- the layers (issue #2783, EPIC #2781 C2) ----------------------------------
# A role's definition is the base; a person changes it with an OVERLAY in the
# same format, writing only what changes. Low → high: the built-in agents/<role>.md
# < the person's layer (the person bundle's `roles.<role>`, $FLEET_CONF_DIR/
# person-bundle.json — fetched by C3) < this computer's
# $FLEET_CONF_DIR/roles/<role>.md (development and emergencies; the doctor says
# when one is there). merge() is pure; tests/role-merge/*.json are its vectors,
# and the hub's Go copy (C6) is held to the same set.
#
#   scalar  model effort permissionMode memory description  — replaced
#   list    tools disallowedTools skills  — `+X` / `X` adds, `-X` removes;
#           a first item `!replace` replaces the whole list. A role with no
#           `tools` has every tool: `+X` there changes nothing and `-X` becomes
#           a disallowedTools entry (never a one-tool allowlist)
#   dict    mcpServers hooks  — merged by key, a `null` value deletes the key;
#           mcpServers may be a list (a name = the login's own server, `-name`
#           removes, `{name: config}` inline)
#   body    appended under 「## （你加的）」 (本机: 「## （本机加的）」);
#           `body: replace` in the frontmatter replaces it
#
# A layer with any key or value it may not carry is not used at all: the last
# good copy of that layer stands (`$FLEET_CONF_DIR/roles/<role>.<layer>.good.json`,
# for the person's layer else person-bundle.good.json's), and `show` says why on
# its first line. Locks (conf/agent-locked.list, `role.<role>.<field>`, `*` for
# every role) are written back after the merge: a locked field never ends looser
# than the built-in — a list keeps every built-in item, a permissionMode is never
# below the built-in's, any other field is the built-in's. The guard hooks never
# read a role file, so no layer can loosen them anyway (EPIC #2781 共同约定 9).
SCALARS = ('description', 'model', 'effort', 'permissionMode', 'memory')
LISTS = ('tools', 'disallowedTools', 'skills')
DICTS = ('mcpServers', 'hooks')
OVERRIDABLE = SCALARS + LISTS + DICTS          # the ten a person can change
EFFORTS = ('low', 'medium', 'high', 'xhigh', 'max')
MODES = ('default', 'acceptEdits', 'auto', 'dontAsk', 'plan', 'bypassPermissions')
MODE_RANK = {'bypassPermissions': 0, 'acceptEdits': 1, 'auto': 1, 'default': 2, 'dontAsk': 3, 'plan': 3}
MEMORY = ('user', 'project', 'local')
BODY_HEAD = {'person': '## （你加的）', 'local': '## （本机加的）'}
REPLACE = '!replace'
HOOK_EVENTS = ('PreToolUse', 'PostToolUse', 'UserPromptSubmit', 'Stop', 'SubagentStop',
               'SessionStart', 'SessionEnd', 'Notification', 'PreCompact')
_NAME_RE = r'[A-Za-z0-9_.:-]{1,64}'


def _secret(v):
    """The person bundle's own credential rule (bin/fleet-agent-team.py, kept in
    step with the hub's): a path when `v` carries something credential-shaped."""
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location('fleet_agent_team', os.path.join(BIN, 'fleet-agent-team.py'))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except (OSError, ImportError, SyntaxError, AttributeError, SystemExit):
        return ''
    return mod.secret_in('', v)


def overlay_of(obj):
    """(front, body) of one overlay: the agents/*.md text, or the same as an
    object — {"front": {<field>: …}, "body": "…"} (where `body: replace` goes
    in front, as in the text), or flat {<field>: …, "body": "<text>"}."""
    if isinstance(obj, str):
        text = obj if obj.startswith('---\n') else '---\n---\n' + obj
        return parse(text)
    if isinstance(obj, dict) and isinstance(obj.get('front'), dict):
        return dict(obj['front']), obj.get('body') or ''
    if isinstance(obj, dict):
        front = {k: v for k, v in obj.items() if k != 'body'}
        return front, obj.get('body') or ''
    raise RoleError('an overlay is the definition text or an object, not %s' % type(obj).__name__)


def check_overlay(role, front, body):
    """'' when the layer may be used, else the one-line reason."""
    import re
    for k, v in front.items():
        if k == 'name':
            if v != role:
                return 'name: %s is not this role (%s)' % (v, role)
            continue
        if k == 'body':
            if v not in ('replace', 'append'):
                return 'body: %s — only replace (or append, the default)' % v
            continue
        if k not in OVERRIDABLE:
            return '%s is not something a layer can change (%s)' % (k, ' '.join(OVERRIDABLE))
        if k in SCALARS:
            if v is not None and not isinstance(v, str):
                return '%s must be one value' % k
            if v and k == 'effort' and v not in EFFORTS:
                return 'effort: %s is none of %s' % (v, ' '.join(EFFORTS))
            if v and k == 'permissionMode' and v not in MODES:
                return 'permissionMode: %s is none of %s' % (v, ' '.join(MODES))
            if v and k == 'memory' and v not in MEMORY:
                return 'memory: %s is none of %s' % (v, ' '.join(MEMORY))
            if v and k == 'model' and not re.fullmatch(r'[A-Za-z0-9._\[\]-]{1,64}', v):
                return 'model: %s is no model name' % v
        elif k in LISTS:
            items = v if isinstance(v, list) else _listval(v or '')
            for i, x in enumerate(items):
                if not isinstance(x, str) or not x.strip() or (x == REPLACE and i):
                    return '%s[%d] must be a name (+X adds, -X removes, %s first)' % (k, i, REPLACE)
        elif k == 'mcpServers':
            if isinstance(v, list):
                for x in v:
                    if isinstance(x, dict):
                        if len(x) != 1 or not re.fullmatch(_NAME_RE, next(iter(x))) \
                                or not isinstance(next(iter(x.values())), dict):
                            return 'mcpServers: an inline server is {name: {command|url…}}'
                    elif not isinstance(x, str) or not re.fullmatch('[+-]?' + _NAME_RE, x):
                        return 'mcpServers: %r is no server name' % (x,)
            elif isinstance(v, dict):
                for n, s in v.items():
                    if not re.fullmatch(_NAME_RE, n) or not (s is None or isinstance(s, (dict, str))):
                        return 'mcpServers.%s: a config object, the name again, or null to remove' % n
            else:
                return 'mcpServers must be a list or an object'
        elif k == 'hooks':
            if not isinstance(v, dict):
                return 'hooks must be an object of hook events'
            for ev, h in v.items():
                if ev not in HOOK_EVENTS or not (h is None or isinstance(h, list)):
                    return 'hooks.%s is not a hook event with a list (or null)' % ev
    if not isinstance(body, str):
        return 'the body must be text'
    s = _secret({'front': front, 'body': body})
    if s:
        return 'carries something credential-shaped (%s) — a key goes in a wrapper script and an env name' % s
    return ''


def items_of(v):
    return v if isinstance(v, list) else _listval(v or '')


def _mcp_dict(v):
    """mcpServers as an ordered (name → config | True for 'the login's own')."""
    out = {}
    for x in (v if isinstance(v, list) else ([] if v in (None, '') else [v])):
        if isinstance(x, dict):
            out.update(x)
        else:
            out[str(x)] = True
    if isinstance(v, dict):
        out = dict(v)
    return out


def _mcp_list(d):
    return [n if c is True or isinstance(c, str) else {n: c} for n, c in d.items()]


def merge(base_front, base_body, layers, locks=()):
    """The pure merge. `layers` = [(label, kind, front, body)] low → high, kind
    'person' | 'local'; `locks` = the fields held at the built-in. Returns
    {fields, body, sources, locked}; sources[field] lists who shaped it, low →
    high ('agents', a layer's label, 'lock')."""
    fields = {k: v for k, v in base_front.items()}
    sources = {k: ['agents'] for k in base_front}
    body, bsrc = base_body, ['agents']
    for label, kind, front, obody in layers:
        for k, v in front.items():
            if k in ('name', 'body'):
                continue
            if k in SCALARS:
                fields[k], sources[k] = (v if v is not None else ''), [label]
            elif k == 'tools' and not fields.get(k) and items_of(v)[:1] != [REPLACE]:
                # no `tools` = every tool: adding to it changes nothing, and a
                # removal is a disallowedTools entry (never a one-tool allowlist)
                gone = [x[1:] for x in items_of(v) if x.startswith('-')]
                if gone:
                    cur = _listval(fields.get('disallowedTools') or [])
                    fields['disallowedTools'] = cur + [x for x in gone if x not in cur]
                    srcs = sources.get('disallowedTools', [])
                    sources['disallowedTools'] = srcs + ([label] if label not in srcs else [])
            elif k in LISTS:
                items = items_of(v)
                cur = [] if items[:1] == [REPLACE] else _listval(fields.get(k) or [])
                srcs = [label] if items[:1] == [REPLACE] else sources.get(k, [])
                for x in (items[1:] if items[:1] == [REPLACE] else items):
                    if x.startswith('-'):
                        cur = [y for y in cur if y != x[1:]]
                    else:
                        x = x[1:] if x.startswith('+') else x
                        if x not in cur:
                            cur.append(x)
                fields[k] = cur
                sources[k] = srcs + ([label] if label not in srcs else [])
            elif k == 'mcpServers':
                cur = _mcp_dict(fields.get(k))
                if isinstance(v, list):
                    for x in v:
                        if isinstance(x, dict):
                            cur.update(x)
                        elif x.startswith('-'):
                            cur.pop(x[1:], None)
                        else:
                            cur[x.lstrip('+')] = True
                else:
                    for n, c in v.items():
                        if c is None:
                            cur.pop(n, None)
                        else:
                            cur[n] = True if isinstance(c, str) else c
                fields[k] = _mcp_list(cur)
                sources[k] = sources.get(k, []) + [label]
            elif k == 'hooks':
                cur = dict(fields.get(k) or {}) if isinstance(fields.get(k), dict) else {}
                for ev, h in v.items():
                    if h is None:
                        cur.pop(ev, None)
                    else:
                        cur[ev] = h
                fields[k] = cur
                sources[k] = sources.get(k, []) + [label]
        if front.get('body') == 'replace':
            body, bsrc = obody, [label]
        elif obody.strip():
            body = '%s\n\n%s\n\n%s\n' % (body.rstrip('\n'), BODY_HEAD.get(kind, BODY_HEAD['person']),
                                         obody.strip('\n'))
            bsrc = bsrc + [label]
    locked = []
    for k in locks:
        if k not in base_front and k not in fields:
            continue
        locked.append(k)
        b, cur = base_front.get(k), fields.get(k)
        if k in LISTS:
            want = _listval(b or [])
            have = _listval(cur or [])
            miss = [x for x in want if x not in have]
            if miss:
                fields[k] = have + miss
                sources[k] = sources.get(k, []) + ['lock']
        elif k == 'permissionMode':
            if MODE_RANK.get(cur or '', 0) < MODE_RANK.get(b or '', 0):
                fields[k], sources[k] = b, sources.get(k, []) + ['lock']
        elif cur != b:
            if b is None:
                fields.pop(k, None)
            else:
                fields[k] = b
            sources[k] = sources.get(k, []) + ['lock']
    for k in [k for k, v in fields.items() if v in ('', None) and k not in base_front]:
        fields.pop(k)
        sources.pop(k, None)
    sources['body'] = bsrc
    return {'fields': fields, 'body': body, 'sources': sources, 'locked': sorted(locked)}


def role_locks(role, root=None):
    """The fields conf/agent-locked.list holds for `role` (`role.<role>.<field>`,
    `role.*.<field>`)."""
    out = []
    try:
        with open(os.path.join(root or ROOT, 'conf', 'agent-locked.list')) as f:
            for ln in f:
                p = ln.split('#', 1)[0].strip().split('.')
                if len(p) == 3 and p[0] == 'role' and p[1] in (role, '*') and p[2] not in out:
                    out.append(p[2])
    except OSError:
        pass
    return out


def _read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _person_overlay(pc, role):
    """(version, overlay | None) out of a person-bundle cache object."""
    if not isinstance(pc, dict):
        return None, None
    b = pc.get('bundle') if isinstance(pc.get('bundle'), dict) else {}
    roles = b.get('roles') if isinstance(b.get('roles'), dict) else pc.get('roles')
    if not isinstance(roles, dict) or role not in roles:
        return pc.get('version'), None
    return pc.get('version'), roles[role]


def _good_path(role, kind):
    return os.path.join(conf_dir(), 'roles', '%s.%s.good.json' % (role, kind))


def layers_for(role):
    """([(label, kind, front, body)], notes) — every layer this computer holds
    for `role`, each checked; a bad one gives way to its last good copy."""
    layers, notes = [], []
    cands = []
    pc = _read_json(os.path.join(conf_dir(), 'person-bundle.json'))
    ver, ov = _person_overlay(pc, role)
    if ov is not None:
        cands.append(('person', 'person:v%s' % (ver or 0), ov, '你的 v%s' % (ver or 0)))
    lp = os.path.join(conf_dir(), 'roles', role + '.md')
    if os.path.isfile(lp):
        try:
            with open(lp, encoding='utf-8') as f:
                cands.append(('local', 'local', f.read(), '本机 %s' % lp))
        except (OSError, UnicodeDecodeError) as e:
            cands.append(('local', 'local', None, '本机 %s（%s）' % (lp, e)))
    for kind, label, raw, say in cands:
        why = ''
        try:
            if raw is None:
                raise RoleError('unreadable')
            front, body = overlay_of(raw)
            why = check_overlay(role, front, body)
        except RoleError as e:
            why = str(e)
        if not why:
            layers.append((label, kind, front, body))
            _write_good(role, kind, {'label': label, 'front': front, 'body': body})
            continue
        good = _read_json(_good_path(role, kind))
        if kind == 'person' and not isinstance(good, dict):
            gver, gov = _person_overlay(_read_json(os.path.join(conf_dir(), 'person-bundle.good.json')), role)
            if gov is not None:
                try:
                    gf, gb = overlay_of(gov)
                    if not check_overlay(role, gf, gb):
                        good = {'label': 'person:v%s' % (gver or 0), 'front': gf, 'body': gb}
                except RoleError:
                    pass
        if isinstance(good, dict) and isinstance(good.get('front'), dict):
            layers.append((good.get('label') or label, kind, good['front'], good.get('body') or ''))
            notes.append('%s 不用：%s——用上一份好的（%s）' % (say, why, good.get('label') or label))
        else:
            notes.append('%s 不用：%s——没有上一份好的，这一层不算' % (say, why))
    return layers, notes


def _write_good(role, kind, data):
    try:
        dst, txt = _good_path(role, kind), json.dumps(data, ensure_ascii=False, sort_keys=True)
        if os.path.isfile(dst):
            with open(dst) as f:
                if f.read() == txt:
                    return
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        tmp = '%s.%d.tmp' % (dst, os.getpid())
        with open(tmp, 'w') as f:
            f.write(txt)
        os.replace(tmp, dst)
    except OSError:
        pass


def effective(role):
    """load() with every layer merged in: the same keys, plus `sources`,
    `locked`, `notes`, `layers`. No layer ⇒ front / body / sha are load()'s."""
    d = load(role)
    layers, notes = layers_for(role)
    m = merge(d['front'], d['body'], layers, role_locks(role))
    d = dict(d, front=m['fields'], body=m['body'], sources=m['sources'], locked=m['locked'],
             notes=notes, layers=[l[0] for l in layers])
    if layers:
        d['sha'] = hashlib.sha256(d['raw'] + json.dumps(
            [list(l) for l in layers], ensure_ascii=False, sort_keys=True).encode('utf-8')).hexdigest()[:16]
    return d


def _env(name):
    """(set?, value) — an empty value is a choice (no --model), unset is not."""
    return (name in os.environ, os.environ.get(name, ''))


def _login_effort():
    """The login's own effortLevel (settings.json), or ''."""
    cfg = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(os.path.expanduser('~'), '.claude')
    try:
        with open(os.path.join(cfg, 'settings.json')) as f:
            v = json.load(f).get('effortLevel')
        return v if isinstance(v, str) else ''
    except (OSError, ValueError, AttributeError):
        return ''


def _capped(model):
    """The per-model cap (issue #524): FLEET_MODEL_FALLBACK while the login's
    active account is walled on `model`. Unchanged when nothing says so."""
    fset, fb = _env('FLEET_MODEL_FALLBACK')
    if not fset:
        fb = 'opus'
    if not model or not fb:
        return model
    acct = os.path.join(BIN, 'fleet-account.sh')
    try:
        label = subprocess.run([acct, 'active'], capture_output=True, text=True,
                               timeout=20).stdout.strip()
        if not label:
            return model
        till = subprocess.run([acct, 'model-limited-until', label, model], capture_output=True,
                              text=True, timeout=20).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return model
    return fb if till.isdigit() and int(till) > time.time() else model


def prompt(d):
    """The body as the system prompt carries it: the definition's body, then the
    rule table's rows for this role (issue #2786). A table that cannot be read
    adds nothing — the role still opens, on its body alone."""
    try:
        return d['body'] + fleet_rules.section(fleet_rules.load(), d['role'])
    except fleet_rules.RulesError as e:
        print('fleet-role: %s — the rule table is left out' % e, file=sys.stderr)
        return d['body']


def body_file(d):
    """The prompt's content-addressed copy: written once, atomically."""
    body = prompt(d)
    sha = hashlib.sha256(body.encode('utf-8')).hexdigest()[:16]
    dst = os.path.join(conf_dir(), 'roles', '%s-%s.md' % (d['role'], sha))
    if not os.path.isfile(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        tmp = '%s.%d.tmp' % (dst, os.getpid())
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(body)
        os.replace(tmp, dst)
    return dst


def _last_path(role, agent):
    return os.path.join(conf_dir(), 'roles', '%s.%s.last.json' % (role, agent))


def _person_age():
    """Seconds since this login last read its personal layer from the hub
    (person-sync.json's `checked`, else the cache's `fetched`), or None when it
    holds no personal layer — or one with no clock (made by hand)."""
    cd = conf_dir()
    pc = _read_json(os.path.join(cd, 'person-bundle.json'))
    if not isinstance(pc, dict):
        pc = _read_json(os.path.join(cd, 'person-bundle.good.json'))
    if not isinstance(pc, dict):
        return None
    rec = _read_json(os.path.join(cd, 'person-sync.json'))
    ts = rec.get('checked') if isinstance(rec, dict) else None
    if not isinstance(ts, (int, float)):
        ts = pc.get('fetched')
    if not isinstance(ts, (int, float)) or isinstance(ts, bool):
        return None
    return max(0, time.time() - ts)


def refresh_person():
    """Before a launch (issue #2784, EPIC #2781 C3): a personal layer read longer
    ago than FLEET_ROLE_STALE (600 s) is read again — `fleet-agent-team.py person`,
    bounded at FLEET_ROLE_FETCH_SECS (3 s). The hub down, slow or refusing: the
    cache stands and the launch goes on with it (the doctor's `roles` row says how
    old it is). No personal layer here, or FLEET_ROLE_STALE=0 → nothing at all,
    byte for byte. A refresh that did not finish is not tried again for a minute,
    so a hub that is away costs one wait, not one per launch."""
    try:
        stale = int(os.environ.get('FLEET_ROLE_STALE') or 600)
        wait = float(os.environ.get('FLEET_ROLE_FETCH_SECS') or 3)
    except ValueError:
        stale, wait = 600, 3.0
    if stale <= 0:
        return
    age = _person_age()
    if age is None or age < stale:
        return
    mark = os.path.join(conf_dir(), 'roles', 'person-refresh.at')
    try:
        if time.time() - os.path.getmtime(mark) < 60:
            return
    except OSError:
        pass
    try:
        os.makedirs(os.path.dirname(mark), exist_ok=True)
        with open(mark, 'w') as f:
            f.write('%d\n' % time.time())
    except OSError:
        pass
    script = os.path.join(BIN, 'fleet-agent-team.py')
    if not os.path.isfile(script):
        return
    try:
        # its own process group: a read cut short takes everything it started with it
        p = subprocess.Popen([sys.executable or 'python3', script, 'person', '--timeout', str(max(0.5, wait - 0.5))],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return
    try:
        p.wait(timeout=wait)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.wait()
        print('fleet-role: the personal layer was not read again in %gs — using the copy from %d minutes ago'
              % (wait, age // 60), file=sys.stderr)


def render(role, agent='claude', cap=False):
    """The role's launch, and the last good one when its definition is broken:
    a definition that cannot be read or parsed is not used at all — the launch
    this computer last rendered for it stands (`stale`), so a bad edit never
    opens a session with no model and no role (docs/BREAK-IT.md role-def-broken).
    No last good one ⇒ the error."""
    refresh_person()
    try:
        out = _render(role, agent, cap)
    except RoleError as e:
        if role not in ROLES:
            raise
        try:
            with open(_last_path(role, agent)) as f:
                out = json.load(f)
        except (OSError, ValueError):
            raise e
        out['stale'] = str(e)
        print('fleet-role: %s — using the last good %s launch (%s)' % (e, role, out.get('sha', '?')),
              file=sys.stderr)
        return out
    try:
        dst, data = _last_path(role, agent), json.dumps(out, ensure_ascii=False, sort_keys=True)
        cur = None
        if os.path.isfile(dst):
            with open(dst) as f:
                cur = f.read()
        if cur != data:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            tmp = '%s.%d.tmp' % (dst, os.getpid())
            with open(tmp, 'w') as f:
                f.write(data)
            os.replace(tmp, dst)
    except OSError:
        pass
    return out


def _render(role, agent, cap):
    d = effective(role)
    fr, compat = d['front'], COMPAT.get(role, {})
    out = {'role': role, 'agent': agent, 'sha': d['sha'], 'file': d['path'], 'args': [],
           'model': '', 'effort': '', 'body': '', 'sources': {},
           'ignored': sorted(k for k in fr if k in SUBAGENT_ONLY),
           'unknown': sorted(k for k in fr if k not in FIELDS and k not in SUBAGENT_ONLY)}
    if d['layers'] or d['notes']:
        out['layers'], out['notes'] = d['layers'], d['notes']
    args, src = out['args'], out['sources']
    # who set a field last: 'agents', a layer's label (person:vN · local) or 'lock'
    top = {k: (v[-1] if v else 'agents') for k, v in d['sources'].items()}

    # model
    if agent == 'claude':
        model, src['model'] = str(fr.get('model', '') or ''), top.get('model', 'agents')
        if 'model' in compat and _env(compat['model'])[0]:
            model, src['model'] = _env(compat['model'])[1], 'local:' + compat['model']
        if model == 'inherit':
            model = ''
        if cap:
            m2 = _capped(model)
            if m2 != model:
                model, src['model'] = m2, 'cap:FLEET_MODEL_FALLBACK'
    else:
        model, src['model'] = '', 'config.toml'
        if 'codex_model' in compat and _env(compat['codex_model'])[1]:
            model, src['model'] = _env(compat['codex_model'])[1], 'local:' + compat['codex_model']
    out['model'] = model
    if model:
        args += (['--model', model] if agent == 'claude' else ['-m', model])

    # effort
    effort, src['effort'] = str(fr.get('effort', '') or ''), top.get('effort', 'agents')
    if 'effort' in compat and _env(compat['effort'])[1]:
        effort, src['effort'] = _env(compat['effort'])[1], 'local:' + compat['effort']
    elif 'effort' not in compat and src['effort'] in ('agents', 'lock') and role != 'debugger':
        # (the debugger — issue #2893 — is no login's own session: its definition's
        # effort stands, whatever the dedicated login's settings say)
        # (a layer that names an effort is the person's choice, and it wins)
        # a worker's effort was always the login's own (settings.json / config.toml)
        if agent == 'codex':
            effort, src['effort'] = '', 'config.toml'
        elif _login_effort():
            effort, src['effort'] = '', 'local:settings.json effortLevel=' + _login_effort()
    out['effort'] = effort
    if effort:
        args += (['--effort', effort] if agent == 'claude'
                 else ['-c', 'model_reasoning_effort="%s"' % effort])

    if agent == 'claude':
        if role in INJECT_BODY and d['body'].strip():
            out['body'] = body_file(d)
            args += ['--append-system-prompt-file', out['body']]
        if fr.get('tools'):
            args.append('--tools=' + ','.join(_listval(fr['tools'])))
        if fr.get('disallowedTools'):
            args.append('--disallowedTools=' + ','.join(_listval(fr['disallowedTools'])))
        if fr.get('permissionMode'):
            args += ['--permission-mode', str(fr['permissionMode'])]
    return out


def rules_cmd(rest):
    role = version = mark = None
    fmt, i = 'md', 0
    while i < len(rest):
        a = rest[i]
        if a in ('--role', '--version', '--mark') and i + 1 < len(rest):
            if a == '--role':
                role = rest[i + 1]
            elif a == '--version':
                version = rest[i + 1]
            else:
                mark = rest[i + 1]
            i += 1
        elif a == '--json':
            fmt = 'json'
        else:
            raise RoleError('rules: unknown option %s' % a)
        i += 1
    if role is not None and role not in ROLES:
        raise RoleError('no such role: %s' % role)
    try:
        if version:
            table = fleet_rules.find(version)
            if table is None:
                raise RoleError('rules: no kept version %s' % version)
        else:
            table = fleet_rules.load()
            fleet_rules.save(table)
        if mark is not None:
            if not mark.isdigit():
                raise RoleError('rules --mark: a rule number, not %s' % mark)
            print(fleet_rules.mark(mark, table))
            return 0
    except fleet_rules.RulesError as e:
        raise RoleError(str(e))
    for p in table['problems']:
        print('fleet-role: %s' % p, file=sys.stderr)
    if fmt == 'json':
        out = dict(table, rows=[r for r in table['rows'] if role in (None, r['role'])])
        print(json.dumps(out, ensure_ascii=False, indent=1))
    else:
        sys.stdout.write('# 规则表 v=%s\n\n' % table['version'] + fleet_rules.markdown(table, role))
    return 0


def say_source(label):
    """A source label as a person reads it."""
    if label == 'agents':
        return '自带'
    if label == 'lock':
        return '🔒'
    if label.startswith('person:'):
        return '你的 ' + label.split(':', 1)[1]
    if label == 'local':
        return '本机'
    return label


def _yaml_lines(k, v):
    if isinstance(v, list):
        return ['%s:' % k] + ['  - %s' % (json.dumps(x, ensure_ascii=False) if isinstance(x, (dict, list)) else x)
                              for x in v]
    if isinstance(v, dict):
        return ['%s: %s' % (k, json.dumps(v, ensure_ascii=False, sort_keys=True))]
    return ['%s: %s' % (k, v)]


def show(role, sources=False):
    """The merged definition as text — the agents/*.md format — with, under
    --sources, each field's layers beside it."""
    d = effective(role)
    out = ['# ⚠ %s' % n for n in d['notes']]
    lines = []
    for k in [k for k in FIELDS if k in d['front']] + [k for k in d['front'] if k not in FIELDS]:
        yl = _yaml_lines(k, d['front'][k])
        if sources:
            src = ' + '.join(say_source(x) for x in d['sources'].get(k, ['agents']))
            if k in d['locked'] and '🔒' not in src:
                src += ' 🔒'
            yl[0] = '%-34s # %s' % (yl[0], src)
        lines += yl
    out += ['---'] + lines + ['---']
    text = '\n'.join(out) + '\n' + d['body']
    if sources:
        text += '\n# 正文：%s\n' % ' + '.join(say_source(x) for x in d['sources'].get('body', ['agents']))
    return d, text


# --- writing the person's layer (issue #2785, EPIC #2781 C4) ------------------
# `fleet role set|unset|rule-set|rule-unset|undo` — what the fleet-config skill
# runs when a person says «让管家别自动答金额相关的问题». Each one reads the
# person's layer FROM THE HUB (bin/fleet-config.py's client: the node token, else
# the connection certificate; its FLEET_PERSON_HUB_CMD seam), makes the smallest
# change to `roles.<role>` / `rules`, prints what it changes on the MERGED
# definition one line an item (改哪一项：改前 → 改后), and — only with --yes —
# PUTs it back with base = the version read (a 409 re-reads and redoes it once,
# a second conflict goes to the person), then writes the hub's answer into this
# computer's cache at once (the launch reads it; no wait for the next sync).
# A worker's window (@fleet_role worker — a batch driver's too) only reads:
# every write exits 3 there. A credential-shaped value is refused before
# anything is sent: a key goes in a wrapper script that reads it at start
# (bin/mcp-github.sh), the configuration names the server, its command and the
# environment variable's name.
SAY_ROLE = {'orchestrator': '编排会话', 'steward': '管家', 'worker': '执行会话', 'epic-driver': '批次驱动',
            'debugger': '诊断员'}
SAY_FIELD = {'model': '模型', 'effort': '思考档位', 'permissionMode': '权限模式', 'memory': '记忆',
             'description': '描述', 'tools': '工具', 'disallowedTools': '禁用工具', 'skills': '技能',
             'mcpServers': '外接工具', 'hooks': '钩子', 'body': '说明'}
SAY_TIER = {'auto': '自己定', 'default': '到点按默认走', 'ask': '必须问你', 'off': '不用'}
RULE_CELLS = ('role', 'cond', 'action', 'tier', 'keywords')
SAY_CELL = {'role': '角色', 'cond': '条件', 'action': '动作', 'tier': '档位', 'keywords': '关键词'}


class Refused(Exception):
    """A write that is not this session's to make, or not sent (exit `code`)."""
    def __init__(self, msg, code=2):
        Exception.__init__(self, msg)
        self.code = code


def window_role():
    """THIS pane's @fleet_role ('' outside a fleet window). Never the empty
    target: inside tmux with no TMUX_PANE (a popup) the answer is ''."""
    pane = os.environ.get('TMUX_PANE') or ''
    if not os.environ.get('TMUX') or not pane:
        return ''
    try:
        return subprocess.run(['tmux', 'display-message', '-p', '-t', pane, '#{@fleet_role}'],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                              timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ''


def _guard():
    if window_role() == 'worker':
        raise Refused('执行会话里只能看不能改（fleet role show / rules 照常）——'
                      '到编排会话、草稿会话或你自己的终端里说', 3)


def _config():
    """bin/fleet-config.py as a module: its hub client is the one this uses."""
    import importlib.util
    import types
    spec = importlib.util.spec_from_file_location('fleet_config', os.path.join(BIN, 'fleet-config.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    a = types.SimpleNamespace(action='role', person='', hub='', timeout=float(
        os.environ.get('FLEET_TEAM_TIMEOUT') or 8))
    return mod, a


def _get(cfg, a, query=''):
    code, cur = cfg.person_call(a, 'GET', None, query)
    if code != 200:
        cfg.hub_err(code, cur)
    return cur


def _say_val(v):
    if v in (None, '', [], {}):
        return '（无）'
    if isinstance(v, list):
        return '、'.join(x if isinstance(x, str) else '%s（内联）' % next(iter(x)) if isinstance(x, dict) and len(x) == 1
                        else json.dumps(x, ensure_ascii=False) for x in v)
    if isinstance(v, dict):
        return json.dumps(v, ensure_ascii=False, sort_keys=True)
    v = ' '.join(str(v).split())
    return '「%s」' % (v if len(v) <= 80 else v[:77] + '…') if ' ' in v or len(v) > 24 else v


def _overlay(bundle, role):
    """(front, body) of the person's overlay for `role` in a bundle; ({}, '') none."""
    ov = (bundle.get('roles') or {}).get(role) if isinstance(bundle.get('roles'), dict) else None
    if ov in (None, '', {}):
        return {}, ''
    return overlay_of(ov)


def _merged(role, front, body):
    """merge() of the built-in with this overlay (and this computer's own layer)."""
    d = load(role)
    layers = []
    if front or body.strip():
        layers.append(('person:new', 'person', front, body))
    layers += [l for l in layers_for(role)[0] if l[1] == 'local']
    return merge(d['front'], d['body'], layers, role_locks(role))


def role_diff(role, before, after):
    """[line] — every item of the merged definition that moves between two
    overlays, as 「<角色> · <项>：改前 → 改后」."""
    try:
        m0 = _merged(role, *before)
    except RoleError:
        m0 = _merged(role, {}, '')
    m1 = _merged(role, *after)
    out = []
    keys = [k for k in FIELDS if k in m0['fields'] or k in m1['fields']]
    keys += [k for k in list(m0['fields']) + list(m1['fields']) if k not in keys and k not in FIELDS]
    for k in keys:
        v0, v1 = m0['fields'].get(k), m1['fields'].get(k)
        if v0 != v1:
            out.append('%s · %s：%s → %s' % (SAY_ROLE[role], SAY_FIELD.get(k, k), _say_val(v0), _say_val(v1)))
    if m0['body'] != m1['body']:
        b0, b1 = before[1].strip(), after[1].strip()
        if after[0].get('body') == 'replace' or before[0].get('body') == 'replace':
            out.append('%s · 说明：%s → %s' % (SAY_ROLE[role], '整段换掉' if before[0].get('body') == 'replace'
                                                else '自带', '整段换成 ' + _say_val(b1) if after[0].get('body') == 'replace'
                                                else '自带' + ('＋' + _say_val(b1) if b1 else '')))
        else:
            out.append('%s · 说明（你加的）：%s → %s' % (SAY_ROLE[role], _say_val(b0), _say_val(b1)))
    return out


def _person_rows(bundle):
    """The person layer's rule rows (dicts, any numbers) out of a bundle."""
    r = bundle.get('rules')
    if r in (None, '', []):
        return []
    rows = fleet_rules.parse(r) if isinstance(r, str) else [fleet_rules._row(x) for x in r]
    return [{k: x[k] for k in ('n',) + RULE_CELLS} for x in rows]


def _rules_with(rows):
    """The merged table with `rows` as the person's layer (None = none)."""
    return fleet_rules.load(person=lambda: ([fleet_rules._row(r) for r in rows], '你的') if rows else None)


def rules_diff(before_rows, after_rows):
    t0, t1 = _rules_with(before_rows), _rules_with(after_rows)
    bad = [p for p in t1['problems'] if p.startswith('person')]
    if bad:
        raise Refused('规则改不成：%s' % bad[0])
    r0, r1 = {r['n']: r for r in t0['rows']}, {r['n']: r for r in t1['rows']}
    out = []
    for n in sorted(set(r0) | set(r1)):
        a, b = r0.get(n), r1.get(n)
        if a == b or (a and b and all(a[c] == b[c] for c in RULE_CELLS)):
            continue
        row = b or a
        who = SAY_ROLE.get(row['role'], row['role'])
        if not a:
            out.append('%s · 规则 %d（新）：%s → %s · %s' % (who, n, row['cond'], row['action'], SAY_TIER[row['tier']]))
        elif not b:
            out.append('%s · 规则 %d：%s → 删掉' % (who, n, a['cond']))
        else:
            for c in RULE_CELLS:
                if a[c] != b[c]:
                    if c == 'tier':
                        out.append('%s · 规则 %d：%s → %s' % (who, n, a['cond'], SAY_TIER[b['tier']])
                                   if a['cond'] == b['cond'] else
                                   '%s · 规则 %d · 档位：%s → %s' % (who, n, SAY_TIER[a['tier']], SAY_TIER[b['tier']]))
                    else:
                        out.append('%s · 规则 %d · %s：%s → %s' % (who, n, SAY_CELL[c], _say_val(a[c]), _say_val(b[c])))
    return out


def _secret_refusal(why):
    return ('拒收，什么都没写：%s。密钥从不进配置——写一个包装脚本在启动时读它（同 bin/mcp-github.sh 从 '
            '`gh auth token` 读），配置里只写外接工具的名字、启动命令和要读的环境变量名（如 "${WECOM_TOKEN}"）'
            % why)


def _check_bundle(cfg, bundle):
    why = cfg.validate(bundle)
    if why:
        if 'credential' in why:
            raise Refused(_secret_refusal(why))
        raise Refused('拒收，什么都没写：%s' % why)


def _write_cache(cfg, resp):
    """The hub's answer is the person's layer now: this computer's cache takes it
    at once (what a launch and the rule table read) — fleet-agent-team.py's own
    files, the shape its fetch writes."""
    T = cfg.T
    body = {'version': resp.get('version'), 'prev': resp.get('prev'), 'created': resp.get('created'),
            'actor': resp.get('actor'), 'bundle': resp.get('bundle') or {}, 'fetched': int(time.time()),
            'etag': None}
    try:
        T.write_json_atomic(T.PERSON_CACHE, body)
        T.write_json_atomic(T.PERSON_GOOD, body)
        T.record_person(0, 'written here (#2785)', None)
    except OSError as e:
        print('fleet-role: 本机缓存没写上（%s）——下次同步带上' % e, file=sys.stderr)


def _effect(roles):
    roles = [r for r in ROLES if r in roles]
    names = '、'.join(SAY_ROLE[r] for r in roles)
    if roles == ['worker'] or roles == ['epic-driver']:
        return '下次开的%s生效（已经开着的不变）。' % names
    return '下次开%s生效；要现在生效说「重开%s」。' % (names, names)


def write(change, note, yes):
    """GET → change(bundle) → [(role…), lines] → PUT base (409: once more).
    change returns (touched roles, the lines) or raises Refused."""
    _guard()
    cfg, a = _config()
    for attempt in (1, 2):
        cur = _get(cfg, a)
        bundle = json.loads(json.dumps(cur.get('bundle') or {}))
        base = int(cur.get('version') or 0)
        roles, lines = change(bundle)
        if not lines:
            print('合起来没有变化——什么都没写（入口 v%d）' % base)
            return 0
        _check_bundle(cfg, bundle)
        if not yes:
            for ln in lines:
                print('改 %s' % ln)
            print('还没写——人说好了，同一条命令加 --yes')
            return 4
        code, resp = cfg.person_call(a, 'PUT', {'bundle': bundle, 'base': base, 'note': note})
        if code == 409 and attempt == 1:
            continue
        if code == 409:
            raise Refused('入口上的个人配置刚被别处改过两次——重读一遍（fleet role show），再说一次', 1)
        if code != 200:
            cfg.hub_err(code, resp)
        _write_cache(cfg, resp)
        for ln in lines:
            print('已改 %s（入口 v%s）' % (ln, resp.get('version')))
        print(_effect(roles))
        return 0
    return 1


def _put_overlay(bundle, role, front, body):
    roles = bundle.setdefault('roles', {})
    if front or body.strip():
        roles[role] = {'front': front, 'body': body}
    else:
        roles.pop(role, None)
    if not roles:
        bundle.pop('roles', None)


def _mcp_overlay(v):
    """An overlay's mcpServers as {name: config | name (the login's own) | None (remove)}."""
    if isinstance(v, dict):
        return dict(v)
    out = {}
    for x in (v if isinstance(v, list) else []):
        if isinstance(x, dict):
            out.update(x)
        elif str(x).startswith('-'):
            out[x[1:]] = None
        else:
            out[str(x).lstrip('+')] = str(x).lstrip('+')
    return out


def set_change(role, field, values, replace=False):
    if role not in ROLES:
        raise Refused('没有这个角色：%s（%s）' % (role, ' '.join(ROLES)))

    def change(bundle):
        f0, b0 = _overlay(bundle, role)
        front, body = dict(f0), b0
        if field == 'body':
            text = ' '.join(values).strip()
            if not text:
                raise Refused('说明要一段话')
            if replace:
                front['body'], body = 'replace', text + '\n'
            else:
                body = ('%s\n\n%s\n' % (body.rstrip('\n'), text)) if body.strip() else text + '\n'
        elif field in SCALARS:
            if len(values) != 1:
                raise Refused('%s 只有一个值' % field)
            front[field] = values[0]
        elif field in LISTS:
            items = items_of(front.get(field))
            for v in values:
                op, name = (v[0], v[1:]) if v[:1] in '+-' else ('+', v)
                if items[:1] == [REPLACE]:
                    items = [x for x in items if x != name]
                    if op == '+':
                        items.append(name)
                else:
                    items = [x for x in items if x.lstrip('+-') != name] + [op + name]
            front[field] = items
        elif field in DICTS:
            cur = _mcp_overlay(front.get(field)) if field == 'mcpServers' else dict(front.get(field) or {})
            i = 0
            while i < len(values):
                v = values[i]
                if v.startswith('{'):
                    try:
                        obj = json.loads(v)
                    except ValueError:
                        raise Refused('%s 的值读不懂（要 JSON）：%s' % (field, v))
                    cur.update(obj)
                elif v[:1] == '-':
                    cur[v[1:]] = None
                elif i + 1 < len(values) and values[i + 1].startswith('{'):
                    try:
                        cur[v.lstrip('+')] = json.loads(values[i + 1])
                    except ValueError:
                        raise Refused('%s.%s 的配置读不懂（要 JSON）' % (field, v))
                    i += 1
                elif field == 'mcpServers':
                    cur[v.lstrip('+')] = v.lstrip('+')
                else:
                    raise Refused('%s 要 JSON：{"<事件>": [...]}' % field)
                i += 1
            front[field] = cur
        else:
            raise Refused('%s 不是能改的项（%s · body）' % (field, ' '.join(OVERRIDABLE)))
        why = check_overlay(role, front, body)
        if why:
            raise Refused(_secret_refusal(why) if 'credential' in why else '这样改不成：%s' % why)
        _put_overlay(bundle, role, front, body)
        return [role], role_diff(role, (f0, b0), (front, body))
    return change


def unset_change(role, field=None, items=()):
    if role not in ROLES:
        raise Refused('没有这个角色：%s（%s）' % (role, ' '.join(ROLES)))

    def change(bundle):
        f0, b0 = _overlay(bundle, role)
        front, body = dict(f0), b0
        if field is None:
            front, body = {}, ''
        elif field == 'body':
            front.pop('body', None)
            body = ''
        elif field not in front:
            return [role], []
        elif items and field in LISTS:
            front[field] = [x for x in items_of(front[field]) if x.lstrip('+-') not in items or x == REPLACE]
            if front[field] in ([], [REPLACE]):
                front.pop(field)
        elif items and field in DICTS:
            cur = _mcp_overlay(front[field]) if field == 'mcpServers' else dict(front[field])
            for n in items:
                cur.pop(n, None)
            front[field] = cur
            if not cur:
                front.pop(field)
        else:
            front.pop(field)
        _put_overlay(bundle, role, front, body)
        return [role], role_diff(role, (f0, b0), (front, body))
    return change


def _used_numbers(person_rows):
    """Every rule number any layer here holds or held (a number is never reused)."""
    nums = {r['n'] for r in person_rows}
    try:
        with open(fleet_rules.default_path(), encoding='utf-8') as f:
            nums |= {r['n'] for r in fleet_rules.parse(f.read())}
    except (OSError, fleet_rules.RulesError):
        pass
    try:
        with open(os.path.join(conf_dir(), 'roles', 'rules.md'), encoding='utf-8') as f:
            nums |= {r['n'] for r in fleet_rules.parse(f.read())}
    except (OSError, fleet_rules.RulesError):
        pass
    return nums


def rule_change(n, cells):
    """rule-set: row `n` ('new' = the next free number from 100) in the person's
    layer, every cell not given kept from the merged row."""
    if 'tier' in cells and cells['tier'] not in fleet_rules.TIERS:
        raise Refused('档位是 %s 之一，不是 %s' % (' '.join(fleet_rules.TIERS), cells['tier']))
    if 'role' in cells and cells['role'] not in ROLES:
        raise Refused('没有这个角色：%s' % cells['role'])

    def change(bundle):
        mine = _person_rows(bundle)
        cur = _rules_with(mine)
        if n == 'new':
            num = max([fleet_rules.NEW_FROM - 1] + list(_used_numbers(mine))) + 1
            row = {'n': num, 'role': '', 'cond': '', 'action': '', 'tier': '', 'keywords': []}
            miss = [SAY_CELL[c] for c in ('role', 'cond', 'action', 'tier') if not cells.get(c)]
            if miss:
                raise Refused('新规则要写全：%s' % '、'.join(miss))
        else:
            if not str(n).isdigit():
                raise Refused('规则编号是数字，或 new')
            num = int(n)
            have = next((r for r in cur['rows'] if r['n'] == num), None) \
                or next((r for r in mine if r['n'] == num), None)
            if have is None:
                raise Refused('规则表里没有 %d——新规则用 rule-set new（从 %d 起编，编号不复用）'
                              % (num, fleet_rules.NEW_FROM))
            row = {k: have[k] for k in ('n',) + RULE_CELLS}
        for c, v in cells.items():
            row[c] = fleet_rules._words(v) if c == 'keywords' else v
        rows = [r for r in mine if r['n'] != num] + [row]
        rows.sort(key=lambda r: r['n'])
        lines = rules_diff(mine, rows)
        bundle['rules'] = [dict(r, keywords=', '.join(r['keywords'])) for r in rows]
        return [row['role']] + ([have['role']] if n != 'new' and have['role'] != row['role'] else []), lines
    return change


def rule_unset_change(n):
    def change(bundle):
        mine = _person_rows(bundle)
        if not str(n).isdigit() or int(n) not in {r['n'] for r in mine}:
            return [], []
        gone = next(r for r in mine if r['n'] == int(n))
        rows = [r for r in mine if r['n'] != int(n)]
        lines = rules_diff(mine, rows)
        if rows:
            bundle['rules'] = [dict(r, keywords=', '.join(r['keywords'])) for r in rows]
        else:
            bundle.pop('rules', None)
        return [gone['role']], lines
    return change


def undo(yes, to=None):
    """Back to the version before this one (or `to`): the hub's restore — that
    version's body as a NEW version, so an undo is itself undoable."""
    _guard()
    cfg, a = _config()
    for attempt in (1, 2):
        cur = _get(cfg, a)
        v = int(cur.get('version') or 0)
        back = int(to) if to else int(cur.get('prev') or (v - 1 if v > 1 else 0))
        if back < 1 or back == v:
            raise Refused('没有上一版可回（入口 v%d）' % v)
        old = _get(cfg, a, 'version=%d' % back)
        b0, b1 = cur.get('bundle') or {}, old.get('bundle') or {}
        lines, roles = [], []
        for r in ROLES:
            got = role_diff(r, _overlay(b0, r), _overlay(b1, r))
            if got:
                lines += got
                roles.append(r)
        try:
            got = rules_diff(_person_rows(b0), _person_rows(b1))
        except Refused:
            got = ['规则表回到 v%d 的样子' % back]
        lines += got
        roles += [ln.split(' · ')[0] for ln in got]
        roles = [r for r in ROLES if r in roles or SAY_ROLE[r] in roles]
        others = sorted(k for k in set(b0) | set(b1) if k not in ('roles', 'rules') and b0.get(k) != b1.get(k))
        if others:
            lines.append('个人配置的其它部分（%s）也回到 v%d' % ('、'.join(others), back))
        if not yes:
            for ln in lines or ['角色和规则合起来没有变化']:
                print('撤回 %s' % ln)
            print('还没写——回到 v%d；人说好了，同一条命令加 --yes' % back)
            return 4
        code, resp = cfg.person_call(a, 'PUT', {'restore': back, 'base': v, 'note': 'undo → v%d' % back})
        if code == 409 and attempt == 1:
            continue
        if code == 409:
            raise Refused('入口上的个人配置刚被别处改过两次——重读一遍，再说一次', 1)
        if code != 200:
            cfg.hub_err(code, resp)
        _write_cache(cfg, resp)
        for ln in lines or ['角色和规则合起来没有变化']:
            print('已撤回 %s（入口 v%s = v%d 的内容）' % (ln, resp.get('version'), back))
        if roles:
            print(_effect(roles))
        return 0
    return 1


def write_cmd(cmd, rest):
    """Parse a write command's words; returns its exit."""
    yes, replace, note, cells, pos, i = False, False, '', {}, [], 0
    while i < len(rest):
        x = rest[i]
        if x == '--yes':
            yes = True
        elif x == '--replace':
            replace = True
        elif x in ('--note',) + tuple('--' + c for c in RULE_CELLS) and i + 1 < len(rest):
            if x == '--note':
                note = rest[i + 1]
            else:
                cells[x[2:]] = rest[i + 1]
            i += 1
        else:
            pos.append(x)
        i += 1
    if cmd == 'undo':
        return undo(yes, pos[0] if pos else None)
    if cmd == 'set':
        if len(pos) < 3:
            raise Refused('用法：set <role> <项> <值…> [--replace] [--yes]')
        return write(set_change(pos[0], pos[1], pos[2:], replace), note or 'set %s.%s' % (pos[0], pos[1]), yes)
    if cmd == 'unset':
        if not pos:
            raise Refused('用法：unset <role> [<项> [<名字…>]] [--yes]')
        return write(unset_change(pos[0], pos[1] if len(pos) > 1 else None, pos[2:]),
                     note or 'unset %s' % '.'.join(pos[:2]), yes)
    if cmd == 'rule-set':
        if len(pos) != 1 or not cells:
            raise Refused('用法：rule-set <N|new> [--role R] [--cond C] [--action A] [--tier T] [--keywords K] [--yes]')
        return write(rule_change(pos[0], cells), note or 'rule %s' % pos[0], yes)
    if cmd == 'rule-unset':
        if len(pos) != 1:
            raise Refused('用法：rule-unset <N> [--yes]')
        return write(rule_unset_change(pos[0]), note or 'rule-unset %s' % pos[0], yes)
    raise Refused('unknown command %s' % cmd)


# ---- moving the old knobs out of fleet.conf (issue #2788, EPIC #2781 C7) ----------
# A machine's fleet.conf still carries the launchers' old role knobs, and while it
# does they win over the person's layer (COMPAT above) — two places, nobody sure
# which one speaks. `migrate-conf` (fleet-conf.sh migrate's roles step) moves each
# into the person's layer and comments the line out, so the merged definition is
# the only answer. Per (role, field):
#   the person's layer already names it     → the line is commented out; the
#                                             person's value stands (one person, many
#                                             machines: the first to say it wins,
#                                             never a later machine's leftover)
#   the value is the built-in's             → commented out, nothing written
#   else                                    → written into the person's layer, ONE
#                                             PUT for the whole file, note
#                                             「从 <机器> 的 fleet.conf 迁入」
# Lines that need the hub stay as they are while it cannot be reached (they still
# win, as before); a second run finds no active line and writes nothing. Codex
# model names (FLEET_*_CODEX_MODEL) and the subagent tier (FLEET_SUBAGENT_MODEL)
# have no field in a layer — they stay this machine's and are only listed.
MIGRATE = (('FLEET_ORCH_MODEL', (('orchestrator', 'model'),)),
           ('FLEET_ORCH_EFFORT', (('orchestrator', 'effort'),)),
           ('FLEET_STEWARD_MODEL', (('steward', 'model'),)),
           ('FLEET_STEWARD_EFFORT', (('steward', 'effort'),)),
           ('FLEET_MODEL', (('worker', 'model'), ('epic-driver', 'model'))))
MIGRATE_STAY = ('FLEET_ORCH_CODEX_MODEL', 'FLEET_STEWARD_CODEX_MODEL', 'FLEET_SUBAGENT_MODEL')
MIGRATE_MARK = '# → 你的那一层（fleet-conf.sh migrate, #2788）'


def _conf_lines(path, keys):
    """[(line index, key, value | None)] — every active assignment of `keys` in a
    shell conf; value None = not a plain literal (left as it is)."""
    import re
    import shlex
    rx = re.compile(r'^\s*(?:export\s+)?(%s)=(.*)$' % '|'.join(keys))
    try:
        with open(path, encoding='utf-8') as f:
            lines = f.read().split('\n')
    except OSError:
        return [], []
    out = []
    for i, ln in enumerate(lines):
        m = rx.match(ln)
        if not m:
            continue
        try:
            tok = shlex.split(m.group(2), comments=True)
        except ValueError:
            tok = None
        val = None
        if tok is not None and len(tok) <= 1 and '$' not in m.group(2) and '`' not in m.group(2):
            val = tok[0] if tok else ''
        out.append((i, m.group(1), val))
    return lines, out


def local_role_vars(path=None):
    """The MIGRATE keys fleet.conf still sets (the doctor's WARN)."""
    path = path or os.path.join(conf_dir(), 'fleet.conf')
    return sorted({k for _, k, _ in _conf_lines(path, [k for k, _ in MIGRATE])[1]})


def _machine():
    import socket
    return os.environ.get('FLEET_MACHINE_NAME') or socket.gethostname().split('.')[0] or '这台机器'


def migrate_conf(path, dry=False, machine=None):
    """Exit 0 done or nothing to do · 1 lines left for the hub (said why)."""
    keys = [k for k, _ in MIGRATE]
    lines, found = _conf_lines(path, keys)
    stay = sorted({k for _, k, _ in _conf_lines(path, list(MIGRATE_STAY))[1]})
    if not found:
        return 0
    targets = dict(MIGRATE)
    last = {}                       # the shell's answer: the last assignment wins
    for i, k, v in found:
        last[k] = v
    builtin = {r: load(r)['front'] for r in ROLES}
    want, why, odd = {}, {}, []     # (role, field) → value; key → how it went
    for k, v in last.items():
        if v is None:
            odd.append(k)
            continue
        for role, field in targets[k]:
            val = v
            if field == 'model' and val == '':
                val = 'inherit'     # empty = the login's own default, as render reads it
            if field == 'effort' and val == '':
                continue            # an empty effort never won (render ignores it)
            if str(builtin[role].get(field, '') or '') == val:
                continue
            want[(role, field)] = val
    version, pending = None, False
    if want:
        cfg = a = None
        try:
            cfg, a = _config()
            moved = {}
            for attempt in (1, 2):
                cur = _get(cfg, a)
                bundle = json.loads(json.dumps(cur.get('bundle') or {}))
                base = int(cur.get('version') or 0)
                lines_said, todo = [], 0
                for (role, field), val in sorted(want.items()):
                    if field in _overlay(bundle, role)[0]:
                        moved[(role, field)] = 'person'
                        continue
                    _, said = set_change(role, field, [val])(bundle)
                    lines_said += said
                    moved[(role, field)] = 'written'
                    todo += 1
                if not todo:
                    version = base
                    break
                _check_bundle(cfg, bundle)
                if dry:
                    for ln in lines_said:
                        print('fleet-conf: would move into your layer: %s' % ln)
                    version = base
                    break
                code, resp = cfg.person_call(a, 'PUT', {'bundle': bundle, 'base': base,
                                                       'note': '从 %s 的 fleet.conf 迁入' % (machine or _machine())})
                if code == 409 and attempt == 1:
                    continue
                if code != 200:
                    cfg.hub_err(code, resp)
                _write_cache(cfg, resp)
                version = resp.get('version')
                for ln in lines_said:
                    print('fleet-conf: moved into your layer (入口 v%s): %s' % (version, ln))
                break
            for (role, field), how in moved.items():
                if how == 'person' and not dry:
                    print('fleet-conf: %s.%s — 入口上已有你的设定，本机这一行不搬，只注释掉' % (role, field))
        except (Refused, SystemExit) as e:
            pending = True
            msg = str(e) if isinstance(e, Refused) else 'the hub could not be read or written'
            print('fleet-conf: role knobs left in %s (%s): %s — they still win here; the next migrate moves them'
                  % (path, ' '.join(sorted({k for k in last if any(t in want for t in targets[k])})), msg),
                  file=sys.stderr)
    # comment out every line whose value is now carried (or never differed)
    drop = []
    for i, k, v in found:
        if k in odd:
            continue
        if pending and any(t in want for t in targets[k]):
            continue
        drop.append(i)
    if odd:
        print('fleet-conf: %s not a plain value in %s — left as it is (move it by hand: fleet role set …)'
              % (' '.join(sorted(odd)), path), file=sys.stderr)
    if stay:
        print('fleet-conf: %s stay in %s — a layer has no Codex model / subagent tier field'
              % (' '.join(stay), path), file=sys.stderr)
    if not drop:
        return 1 if pending else 0
    if dry:
        print('fleet-conf: would comment out in %s: %s' % (path, ' '.join(lines[i].strip() for i in drop)))
        return 1 if pending else 0
    import shutil
    st = os.stat(path)
    bak = '%s.bak-%s' % (path, time.strftime('%Y%m%d-%H%M%S'))
    if not os.path.exists(bak):
        shutil.copy2(path, bak)
    tag = MIGRATE_MARK + (' v%s' % version if version else '')
    same = '# 与自带定义相同，不必搬（fleet-conf.sh migrate, #2788）'
    for i in drop:
        k = next(k for j, k, _ in found if j == i)
        lines[i] = '# %s  %s' % (lines[i], tag if any(t in want for t in targets[k]) else same)
    tmp = '%s.tmp.%d' % (path, os.getpid())
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    os.chmod(tmp, st.st_mode & 0o7777)
    os.replace(tmp, path)
    print('fleet-conf: role knobs commented out in %s (%s; was kept as %s)'
          % (path, ' '.join(sorted({k for i, k, _ in found if i in drop})), os.path.basename(bak)))
    return 1 if pending else 0


def _vector(path):
    """One test vector (tests/role-merge/*.json): {base: {front, body}, layers:
    [{label, kind, front, body} | {label, kind, text}], locks} → merge's answer."""
    with open(path, encoding='utf-8') as f:
        v = json.load(f)
    layers = []
    for l in v.get('layers', []):
        front, body = overlay_of(l['text'] if 'text' in l else {'front': l.get('front', {}), 'body': l.get('body', '')})
        why = check_overlay(v.get('role', 'worker'), front, body)
        if why:
            layers.append(None)
            continue
        layers.append((l['label'], l.get('kind', 'person'), front, body))
    base = v['base']
    bf, bb = (parse(base['text']) if 'text' in base else (base.get('front', {}), base.get('body', '')))
    m = merge(bf, bb, [l for l in layers if l], v.get('locks', []))
    m['refused'] = [i for i, l in enumerate(layers) if l is None]
    return m


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__.strip())
        return 0 if argv else 2
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == 'list':
            print('\n'.join(ROLES))
            return 0
        if cmd == 'rules':
            return rules_cmd(rest)
        if cmd == 'migrate-conf':
            dry, mach, pth, i = False, None, None, 0
            while i < len(rest):
                if rest[i] == '--dry-run':
                    dry = True
                elif rest[i] == '--machine' and i + 1 < len(rest):
                    mach = rest[i + 1]
                    i += 1
                else:
                    pth = rest[i]
                i += 1
            return migrate_conf(pth or os.path.join(conf_dir(), 'fleet.conf'), dry, mach)
        if cmd in WRITES:
            try:
                return write_cmd(cmd, rest)
            except Refused as e:
                print('fleet-role: %s' % e, file=sys.stderr)
                return e.code
        if not rest and cmd == 'doctor':
            rest = ['-']
        if not rest:
            raise RoleError('%s: which role?' % cmd)
        if cmd == 'merge':
            if rest[0] == '--vector':
                print(json.dumps(_vector(rest[1]), ensure_ascii=False, indent=1, sort_keys=True))
                return 0
            with open(rest[0], encoding='utf-8') as f:
                bf, bb = parse(f.read())
            layers = []
            for p in rest[1:]:
                with open(p, encoding='utf-8') as f:
                    front, body = overlay_of(f.read())
                why = check_overlay(str(bf.get('name') or ''), front, body)
                if why:
                    raise RoleError('%s: %s' % (p, why))
                layers.append((os.path.basename(p), 'person', front, body))
            print(json.dumps(merge(bf, bb, layers), ensure_ascii=False, indent=1, sort_keys=True))
            return 0
        role = rest[0]
        if cmd == 'doctor':
            # fleet-doctor's `roles` row: nothing when no role has a local layer
            # and every layer was used (the degenerate case prints no row)
            local, notes = [], []
            for r in ROLES:
                try:
                    d = effective(r)
                except RoleError as e:
                    notes.append('%s: %s' % (r, e))
                    continue
                if 'local' in d['layers'] or os.path.isfile(os.path.join(conf_dir(), 'roles', r + '.md')):
                    local.append(r)
                notes += ['%s: %s' % (r, n) for n in d['notes']]
            left = local_role_vars()
            if local or notes or left:
                say = []
                if left:
                    say.append('本机还有角色变量：%s（fleet.conf 里的这一版还算数；`fleet-conf.sh migrate` 把它们搬进你的那一层）'
                               % ' '.join(left))
                if local:
                    say.append('有本机层：%s（%s/roles/<role>.md，只管这台；用完删掉）' % (' '.join(local), conf_dir()))
                say += notes
                print('WARN\t%s (fleet role show <role> --sources)' % ' · '.join(say))
            return 0
        if cmd == 'show':
            d, text = show(role, '--sources' in rest)
            if '--json' in rest:
                print(json.dumps({k: d[k] for k in ('role', 'sha', 'front', 'body', 'sources', 'locked',
                                                    'notes', 'layers')},
                                 ensure_ascii=False, indent=1, sort_keys=True))
            else:
                sys.stdout.write(text)
            return 0
        if cmd == 'render':
            agent, fmt, cap, i = 'claude', 'lines', False, 1
            while i < len(rest):
                a = rest[i]
                if a == '--agent' and i + 1 < len(rest):
                    agent = rest[i + 1]
                    i += 1
                elif a.startswith('--agent='):
                    agent = a.split('=', 1)[1]
                elif a in ('--json', '--kv'):
                    fmt = a[2:]
                elif a == '--cap':
                    cap = True
                else:
                    raise RoleError('render: unknown option %s' % a)
                i += 1
            if agent not in ('claude', 'codex'):
                raise RoleError('render: --agent claude|codex, not %s' % agent)
            r = render(role, agent, cap)
            if fmt == 'json':
                print(json.dumps(r, ensure_ascii=False, indent=1))
            elif fmt == 'kv':
                print('sha\t%s' % r['sha'])
                print('model\t%s' % r['model'])
                print('effort\t%s' % r['effort'])
                if r['body']:
                    print('body\t%s' % r['body'])
                for a in r['args']:
                    print('arg\t%s' % a)
            else:
                for a in r['args']:
                    print(a)
            return 0
        d = load(role)
        if cmd == 'get':
            # the merged definition (#2788): a launch with no --role (a scratch
            # session's model) follows the person's layer too
            if len(rest) < 2:
                raise RoleError('get: which field?')
            v = effective(role)['front'].get(rest[1], '')
            print(','.join(_listval(v)) if isinstance(v, list) else v)
        elif cmd == 'body':
            sys.stdout.write(d['body'])
        elif cmd == 'prompt':
            sys.stdout.write(prompt(d))
        elif cmd == 'sha':
            print(d['sha'])
        else:
            raise RoleError('unknown command %s' % cmd)
        return 0
    except RoleError as e:
        print('fleet-role: %s' % e, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
