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

Nothing overrides a definition yet (C2 adds the person's layer). What still wins
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
    d = load(role)
    fr, compat = d['front'], COMPAT.get(role, {})
    out = {'role': role, 'agent': agent, 'sha': d['sha'], 'file': d['path'], 'args': [],
           'model': '', 'effort': '', 'body': '', 'sources': {},
           'ignored': sorted(k for k in fr if k in SUBAGENT_ONLY),
           'unknown': sorted(k for k in fr if k not in FIELDS and k not in SUBAGENT_ONLY)}
    args, src = out['args'], out['sources']

    # model
    if agent == 'claude':
        model, src['model'] = str(fr.get('model', '') or ''), 'agents'
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
    effort, src['effort'] = str(fr.get('effort', '') or ''), 'agents'
    if 'effort' in compat and _env(compat['effort'])[1]:
        effort, src['effort'] = _env(compat['effort'])[1], 'local:' + compat['effort']
    elif 'effort' not in compat:
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
        if not rest:
            raise RoleError('%s: which role?' % cmd)
        role = rest[0]
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
