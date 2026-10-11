#!/usr/bin/env python3
"""The orchestrator's and the steward's launch arguments, and the rule table.

What is left of the role engine (issue #2782) after EPIC #3111 C11 (issue
#3122): a session started AS something is a standard agent file now
(bin/fleet-agent-def.py, `--as <name>` → `claude --agent <name>`), and the
person's layer, the merge, the locks and `fleet role set|unset|undo` are gone —
a personal override is your own agent file or skill copy, found the way Claude
Code finds it. Only the two launchers EPIC #3111 C7 deletes still read here
(bin/fleet-orchestrator.sh, bin/fleet-steward.sh — their body rides the system
prompt), and the rule table's reader stays until C3 / C4 move it into their skills.

  render orchestrator|steward [--agent claude|codex] [--kv | --json] [--cap]
      the role's launch arguments: --kv is the launchers' form
      (`sha`/`model`/`effort`/`body`/`arg` TAB value). --cap: the per-model cap
      fallback (issue #524) — a model this login's active account is walled on
      gives way to FLEET_MODEL_FALLBACK.
  get <role> <field>      one frontmatter field (a list joins with `,`)
  body <role>             the definition's body
  prompt <role>           the body + the role's rows of the rule table
  sha <role>              the definition's content address
  rules [--role R] [--json] [--version V] [--mark N]
                          the merged rule table (bin/fleet_rules.py, issue #2786)
  list                    the roles

The launcher's old knobs still win (# compat-1v: 下一批删): FLEET_ORCH_MODEL /
FLEET_ORCH_EFFORT / FLEET_ORCH_CODEX_MODEL, FLEET_STEWARD_MODEL /
FLEET_STEWARD_EFFORT / FLEET_STEWARD_CODEX_MODEL, then the model / effort the
person set on the hub (person-bundle.json `roles.<role>`). A definition that cannot be
read is an error (exit 2): the launcher opens the session without a role.
Writes only the body's content-addressed copy, $FLEET_CONF_DIR/roles/<role>-<sha>.md
(made once, never changed — a session resumed after a release still finds it).
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
ROLES = ('orchestrator', 'steward')
COMPAT = {
    'orchestrator': {'model': 'FLEET_ORCH_MODEL', 'effort': 'FLEET_ORCH_EFFORT',
                     'codex_model': 'FLEET_ORCH_CODEX_MODEL'},
    'steward': {'model': 'FLEET_STEWARD_MODEL', 'effort': 'FLEET_STEWARD_EFFORT',
                'codex_model': 'FLEET_STEWARD_CODEX_MODEL'},
}


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


def _person_scalar(role, field):
    """The person's model / effort for <role> as they set it on the hub before
    the layer was retired (person-bundle.json's `roles.<role>`), or '' — read
    until C7 deletes these launchers, so a reopened orchestrator keeps the model
    the person chose (# compat-1v: 下一批删). Nothing else of the layer is read."""
    try:
        with open(os.path.join(conf_dir(), 'person-bundle.json')) as f:
            pc = json.load(f)
        b = pc.get('bundle') if isinstance(pc.get('bundle'), dict) else pc
        ov = (b.get('roles') or {}).get(role)
        if isinstance(ov, str):
            ov = {'front': parse(ov if ov.startswith('---\n') else '---\n---\n' + ov)[0]}
        front = ov.get('front') if isinstance(ov.get('front'), dict) else ov
        v = front.get(field)
        return v if isinstance(v, str) else ''
    except (OSError, ValueError, AttributeError, RoleError):
        return ''


def render(role, agent='claude', cap=False):
    d = load(role)
    fr, compat = d['front'], COMPAT[role]
    out = {'role': role, 'agent': agent, 'sha': d['sha'], 'file': d['path'], 'args': [],
           'model': '', 'effort': '', 'body': ''}
    args = out['args']
    if agent == 'claude':
        model = _person_scalar(role, 'model') or str(fr.get('model', '') or '')
        if _env(compat['model'])[0]:
            model = _env(compat['model'])[1]
        if model == 'inherit':
            model = ''
        if cap:
            model = _capped(model)
    else:
        model = _env(compat['codex_model'])[1]
    out['model'] = model
    if model:
        args += (['--model', model] if agent == 'claude' else ['-m', model])
    effort = (_env(compat['effort'])[1] or _person_scalar(role, 'effort')
              or str(fr.get('effort', '') or ''))
    out['effort'] = effort
    if effort:
        args += (['--effort', effort] if agent == 'claude'
                 else ['-c', 'model_reasoning_effort="%s"' % effort])
    if agent == 'claude':
        if d['body'].strip():
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
