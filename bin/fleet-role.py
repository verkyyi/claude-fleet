#!/usr/bin/env python3
"""The role definitions agents/orchestrator.md · steward.md, and the rule table.

What is left of the role engine (issue #2782) after EPIC #3111: a session started
AS something is a standard agent file (bin/fleet-agent-def.py, `--as <name>` →
`claude --agent <name>`), and a person takes the orchestrator / steward role in a
session with /fleet-orchestrate · /fleet-steward (take_role). The two launchers
that rendered a role onto a resident window — and their FLEET_ORCH_* /
FLEET_STEWARD_MODEL|EFFORT|CODEX_MODEL knobs — went with the seat (issue #3118).

  get <role> <field>      one frontmatter field (a list joins with `,`)
  body <role>             the definition's body
  prompt <role>           the body + the role's rows of the rule table
  sha <role>              the definition's content address
  rules [--role R] [--json] [--version V] [--mark N]
                          the merged rule table (bin/fleet_rules.py, issue #2786)
  list                    the roles

A definition that cannot be read is an error (exit 2). Writes nothing.
"""
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fleet_rules  # noqa: E402  the rule table's one reader (issue #2786)
BIN = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BIN)
ROLES = ('orchestrator', 'steward')


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


def prompt(d):
    """The body as the system prompt carries it: the definition's body, then the
    rule table's rows for this role (issue #2786). A table that cannot be read
    adds nothing — the role still opens, on its body alone."""
    try:
        return d['body'] + fleet_rules.section(fleet_rules.load(), d['role'])
    except fleet_rules.RulesError as e:
        print('fleet-role: %s — the rule table is left out' % e, file=sys.stderr)
        return d['body']


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
