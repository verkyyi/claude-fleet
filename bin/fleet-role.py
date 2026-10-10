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
  merge <base.md> <overlay.md…> | merge --vector <file.json>
                          the pure merge, as JSON {fields, body, sources, locked}
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
them changed, every role starts exactly as it did.

Reads the definition and the environment; the only writes are under
$FLEET_CONF_DIR/roles/: the body's content-addressed copy (made once, never
changed — a session resumed after a release still finds the file it started
with) and `<role>.<agent>.last.json`, the last good launch, which stands in for a
definition that cannot be read (the session opens as it last did, and says so).
"""
import hashlib
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fleet_rules  # noqa: E402  the rule table's one reader (issue #2786)

BIN = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BIN)
ROLES = ('orchestrator', 'steward', 'worker', 'epic-driver')
FIELDS = ('name', 'description', 'model', 'effort', 'tools', 'disallowedTools',
          'mcpServers', 'skills', 'hooks', 'permissionMode', 'memory')
SUBAGENT_ONLY = ('maxTurns', 'background', 'isolation', 'color', 'initialPrompt')
# The roles whose body rides the system prompt (see the docstring).
INJECT_BODY = ('orchestrator', 'steward')
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


def render(role, agent='claude', cap=False):
    """The role's launch, and the last good one when its definition is broken:
    a definition that cannot be read or parsed is not used at all — the launch
    this computer last rendered for it stands (`stale`), so a bad edit never
    opens a session with no model and no role (docs/BREAK-IT.md role-def-broken).
    No last good one ⇒ the error."""
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
    elif 'effort' not in compat and src['effort'] in ('agents', 'lock'):
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
            if local or notes:
                say = []
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
            if len(rest) < 2:
                raise RoleError('get: which field?')
            v = d['front'].get(rest[1], '')
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
