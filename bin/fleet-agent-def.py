#!/usr/bin/env python3
"""A session started AS an agent: Claude Code's own agent file, nothing else.

Issue #3122 (EPIC #3111 C11). A custom kind of session is ONE standard agent
file — `name` · `description` · `tools` · `disallowedTools` · `model` · the body
— found the way Claude Code finds it: the project's `.claude/agents` (the nearest
directory up to the repo's root wins) > the login's `~/.claude/agents` > an
installed plugin's `agents/`. A spawn names it (`--as <name>`: dash-issue-session.sh,
dash-raw-session.sh, the `spawn` tool's `agent`); the launcher starts
`claude --agent <name>` and Claude Code reads the model, the tools and the body
itself. The fleet adds ONE frontmatter key, `fleet:` (Claude Code ignores keys it
does not know), with the sub-keys

  reap          when the fleet may close it (@reap_policy's grammar)
  repo          the repo it opens in when the spawn names none
  agent         claude | codex
  codex_model   the Codex model (-m); Claude's `model` is no Codex name
  codex_effort  Codex's model_reasoning_effort

A Codex session reads the same file: the body becomes its instructions
(`-c model_instructions_file=<a content-addressed copy of the body>`), the model
is `fleet.codex_model`; the tool list does not carry over (Codex has none).

  find <name> [--dir D]           the file's path (exit 1: none — stderr says where it looked)
  launch <name> [--dir D] [--agent claude|codex] [--no-agent-flag]
                                  what the launcher starts it with, `key<TAB>value`
                                  lines: file · sha · name · model · spawn (0|1) ·
                                  reap · repo · agent · codex_model · codex_effort ·
                                  body (Codex / --no-agent-flag: the body's copy) and
                                  `arg` lines, one argv word each
  ship [--dir D] [--check]        install the agent files the fleet core ships
                                  (conf/agent-defaults/claude/agents/*.md) into the
                                  login's ~/.claude/agents — see «ship» below
  spawn-tools <name> [--dir D]    exit 0 when its tools grant `spawn` (issue #2960)

`--dir` is the session's working directory (default: the cwd) — where the
project layer is looked for. `--no-agent-flag` is the fallback for a Claude Code
without `--agent` (the launcher asks `claude --help` once per binary): the
model, the tools and the body ride `--model` / `--tools` /
`--disallowedTools` / `--append-system-prompt-file` instead.

A spawn may run only when its file grants the `spawn` tool (EPIC #3111 共同约定 5,
issue #2960): no `tools` list (every tool) or a list naming it — `spawn`,
`mcp__<server>__spawn`, `mcp__<server>` or `mcp__<server>__*` — and no
`disallowedTools` entry taking it away. The shipped `fleet-worker` takes it away.

«ship»: the core ships `fleet-worker` (the issue-bound execution session — the
spawn's default) and, until its own plugin carries it, `fleet-debugger`. Each is
written into ~/.claude/agents once, kept up with the release while it is still
byte for byte what the fleet wrote, and never touched again once the person
edits it (their override) or deletes it (then a spawn is a plain session given
the ticket). What the fleet wrote is recorded in
$FLEET_CONF_DIR/agents-shipped.json (name → sha). A file the core no longer
ships (`epic-driver` moved into the fleet-epic plugin — issue #3116) is retired:
removed while it is still the fleet's bytes, so the plugin's copy answers (and
no plugin, no such agent); an edited one stays, the person's own.
"""
import hashlib
import json
import os
import re
import subprocess
import sys

BIN = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BIN)
FLEET_KEYS = ('reap', 'repo', 'agent', 'codex_model', 'codex_effort')
NAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$')


class AgentError(Exception):
    pass


def conf_dir():
    return os.environ.get('FLEET_CONF_DIR') or os.path.join(
        os.path.expanduser('~'), '.config', 'claude-fleet')


def claude_dir():
    return os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(os.path.expanduser('~'), '.claude')


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
    """(frontmatter dict, body) of an agent file: `key: value`, `key: [a, b]`, a
    block list (`key:` then `  - item`), one level of block mapping (`fleet:`
    then `  reap: done`) and an inline JSON object — the subset Claude Code's own
    examples use (macOS python3 has no yaml)."""
    if not text.startswith('---\n'):
        raise AgentError('no frontmatter (the file must start with ---)')
    end = text.find('\n---', 3)
    if end < 0:
        raise AgentError('frontmatter has no closing ---')
    head, body = text[4:end + 1], text[end + 4:]
    body = body[1:] if body.startswith('\n') else body
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
            elif ':' in item:
                if not isinstance(front.get(key), dict):
                    front[key] = {}
                k, v = item.split(':', 1)
                front[key][k.strip()] = _scalar(v)
            continue
        if ':' not in ln:
            raise AgentError('cannot read frontmatter line: %s' % ln)
        key, val = ln.split(':', 1)
        key = key.strip()
        front[key] = _scalar(val) if val.strip() else ''
    return front, body


def _listval(v):
    if isinstance(v, list):
        return [str(x).strip() for x in v if str(x).strip()]
    return [x.strip() for x in str(v or '').split(',') if x.strip()]


def _project_dirs(start):
    """`.claude/agents` from the working directory up to the repo's root (the
    nearest wins), as Claude Code walks it; outside a repo just the directory."""
    out, d = [], os.path.abspath(start or os.getcwd())
    while True:
        out.append(os.path.join(d, '.claude', 'agents'))
        if os.path.exists(os.path.join(d, '.git')):
            break
        up = os.path.dirname(d)
        if up == d:
            return out[:1]
        d = up
    return out


def _plugin_dirs():
    """Each installed plugin's agents/ — `claude plugin list --json` (the one
    place Claude Code says what is installed; FLEET_AGENT_PLUGINS_CMD is the
    selftest's seam). A plugin agent answers to `<name>` and `<plugin>:<name>`."""
    cmd = os.environ.get('FLEET_AGENT_PLUGINS_CMD') or 'claude plugin list --json'
    # asked once per change of what is installed (the plugins dir and settings.json
    # move when /plugin installs, enables or removes one): a spawn costs no node start
    stamp = [cmd]
    for pth in (os.path.join(claude_dir(), 'plugins'),
                os.path.join(claude_dir(), 'plugins', 'installed_plugins.json'),
                os.path.join(claude_dir(), 'settings.json')):
        try:
            stamp.append(os.stat(pth).st_mtime_ns)
        except OSError:
            stamp.append(0)
    cache = os.path.join(conf_dir(), 'agents', 'plugins.json')
    rows = None
    try:
        with open(cache) as f:
            c = json.load(f)
        if c.get('stamp') == stamp:
            rows = c.get('rows')
    except (OSError, ValueError, AttributeError):
        pass
    if rows is None:
        try:
            out = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15).stdout
            rows = json.loads(out or '[]')
        except (OSError, subprocess.SubprocessError, ValueError):
            return []
        try:
            os.makedirs(os.path.dirname(cache), exist_ok=True)
            tmp = '%s.%d.tmp' % (cache, os.getpid())
            with open(tmp, 'w') as f:
                json.dump({'stamp': stamp, 'rows': rows}, f)
            os.replace(tmp, cache)
        except OSError:
            pass
    dirs = []
    for r in rows if isinstance(rows, list) else []:
        if not isinstance(r, dict) or r.get('enabled') is False:
            continue
        path = r.get('installPath') or r.get('path')
        if isinstance(path, str) and path:
            pid = str(r.get('id') or r.get('name') or '').split('@', 1)[0]
            dirs.append((pid, os.path.join(path, 'agents')))
    return dirs


def _match(d, name, plugin=''):
    """The file in <d> answering to <name>: Claude Code matches the frontmatter
    `name`; the file name is the first guess, then every *.md is read."""
    want = name.split(':', 1)[1] if plugin and name.startswith(plugin + ':') else name
    if not os.path.isdir(d):
        return None
    first = os.path.join(d, want + '.md')
    cands = ([first] if os.path.isfile(first) else []) + sorted(
        os.path.join(d, f) for f in os.listdir(d) if f.endswith('.md') and f != want + '.md')
    for p in cands:
        try:
            with open(p, encoding='utf-8') as f:
                front, _ = parse(f.read())
        except (OSError, UnicodeDecodeError, AgentError):
            if p == first:
                return p   # unreadable but named so: load() says why
            continue
        if str(front.get('name') or os.path.basename(p)[:-3]) == want:
            return p
    return None


def find(name, start=None):
    if not NAME_RE.match(name or ''):
        raise AgentError('not an agent name: %r' % name)
    looked = []
    for d in _project_dirs(start) + [os.path.join(claude_dir(), 'agents')]:
        looked.append(d)
        p = _match(d, name)
        if p:
            return p
    for pid, d in _plugin_dirs():
        looked.append(d)
        p = _match(d, name, pid)
        if p:
            return p
    raise AgentError('no agent file %r (looked in %s)' % (name, ' · '.join(looked)))


def load(path):
    try:
        with open(path, 'rb') as f:
            raw = f.read()
    except OSError as e:
        raise AgentError('cannot read %s: %s' % (path, e.strerror))
    try:
        front, body = parse(raw.decode('utf-8'))
    except (UnicodeDecodeError, AgentError) as e:
        raise AgentError('cannot read %s: %s' % (path, e))
    fl = front.get('fleet')
    if fl not in (None, '') and not isinstance(fl, dict):
        raise AgentError('cannot read %s: `fleet:` must be a mapping (%s)' % (path, ', '.join(FLEET_KEYS)))
    return {'path': path, 'front': front, 'body': body, 'fleet': fl or {},
            'sha': hashlib.sha256(raw).hexdigest()[:16]}


def _is_spawn(t):
    t = t.strip()
    if t == 'spawn':
        return True
    if not t.startswith('mcp__'):
        return False
    parts = t.split('__')
    return len(parts) == 2 or (len(parts) == 3 and parts[2] in ('spawn', '*'))


def grants_spawn(front):
    tools = front.get('tools')
    allowed = not tools or any(_is_spawn(t) for t in _listval(tools))
    denied = any(t.strip() in ('spawn', 'mcp__*') or (t.startswith('mcp__') and _is_spawn(t))
                 for t in _listval(front.get('disallowedTools')))
    return allowed and not denied


def body_copy(d):
    """The body's content-addressed copy (written once, atomically): what a Codex
    session reads as its instructions and the fallback appends to the prompt."""
    body = d['body']
    sha = hashlib.sha256(body.encode('utf-8')).hexdigest()[:16]
    name = re.sub(r'[^A-Za-z0-9_.-]', '-', str(d['front'].get('name') or 'agent'))
    dst = os.path.join(conf_dir(), 'agents', '%s-%s.md' % (name, sha))
    if not os.path.isfile(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        tmp = '%s.%d.tmp' % (dst, os.getpid())
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(body)
        os.replace(tmp, dst)
    return dst


def launch(name, start=None, agent='claude', agent_flag=True):
    d = load(find(name, start))
    fr, fl = d['front'], d['fleet']
    model = str(fr.get('model') or '')
    out = [('file', d['path']), ('sha', d['sha']), ('name', name),
           ('model', '' if model == 'inherit' else model),
           ('spawn', '1' if grants_spawn(fr) else '0')]
    out += [(k, str(fl.get(k) or '')) for k in FLEET_KEYS]
    args = []
    if agent == 'codex':
        if fl.get('codex_model'):
            args += ['-m', str(fl['codex_model'])]
        if fl.get('codex_effort'):
            args += ['-c', 'model_reasoning_effort="%s"' % fl['codex_effort']]
        if d['body'].strip():
            p = body_copy(d)
            out.append(('body', p))
            args += ['-c', 'model_instructions_file=%s' % json.dumps(p)]
    elif agent_flag:
        args += ['--agent', name]
    else:
        if fr.get('tools'):
            args.append('--tools=' + ','.join(_listval(fr['tools'])))
        if fr.get('disallowedTools'):
            args.append('--disallowedTools=' + ','.join(_listval(fr['disallowedTools'])))
        if fr.get('permissionMode'):
            args += ['--permission-mode', str(fr['permissionMode'])]
        if d['body'].strip():
            p = body_copy(d)
            out.append(('body', p))
            args += ['--append-system-prompt-file', p]
    return out + [('arg', a) for a in args]


# --- ship ----------------------------------------------------------------------
def ship(dst_dir=None, check=False):
    src = os.path.join(ROOT, 'conf', 'agent-defaults', 'claude', 'agents')
    dst_dir = dst_dir or os.path.join(claude_dir(), 'agents')
    rec_path = os.path.join(conf_dir(), 'agents-shipped.json')
    try:
        with open(rec_path) as f:
            rec = json.load(f)
        rec = rec if isinstance(rec, dict) else {}
    except (OSError, ValueError):
        rec = {}
    lines, changed = [], False
    for fn in sorted(os.listdir(src)) if os.path.isdir(src) else []:
        if not fn.endswith('.md'):
            continue
        name = fn[:-3]
        with open(os.path.join(src, fn), 'rb') as f:
            want = f.read()
        wsha = hashlib.sha256(want).hexdigest()
        dst = os.path.join(dst_dir, fn)
        cur = None
        if os.path.isfile(dst):
            with open(dst, 'rb') as f:
                cur = f.read()
        csha = hashlib.sha256(cur).hexdigest() if cur is not None else None
        if cur is None and name in rec:
            lines.append('deleted  %s (the person removed it — left out)' % name)
            continue
        if csha == wsha:
            lines.append('ok       %s' % name)
            if rec.get(name) != wsha:
                rec[name], changed = wsha, True
            continue
        if cur is not None and rec.get(name) != csha:
            lines.append('theirs   %s (edited — the person\'s own, kept)' % name)
            continue
        lines.append('%s %s' % ('would write' if check else 'wrote   ', name))
        if not check:
            os.makedirs(dst_dir, exist_ok=True)
            tmp = '%s.%d.tmp' % (dst, os.getpid())
            with open(tmp, 'wb') as f:
                f.write(want)
            os.replace(tmp, dst)
            rec[name], changed = wsha, True
    # retired: shipped once, no longer in the core (moved into a plugin)
    have = set(fn[:-3] for fn in os.listdir(src) if fn.endswith('.md')) if os.path.isdir(src) else set()
    for name in sorted(n for n in rec if n not in have):
        dst = os.path.join(dst_dir, name + '.md')
        cur = None
        if os.path.isfile(dst):
            with open(dst, 'rb') as f:
                cur = f.read()
        if cur is not None and hashlib.sha256(cur).hexdigest() != rec[name]:
            lines.append('theirs   %s (edited — the person\'s own, kept; the core no longer ships it)' % name)
            continue
        lines.append('%s %s (the core no longer ships it)' % ('would retire' if check else 'retired ', name))
        if not check:
            if cur is not None:
                os.remove(dst)
            del rec[name]
            changed = True
    if changed and not check:
        os.makedirs(os.path.dirname(rec_path), exist_ok=True)
        tmp = '%s.%d.tmp' % (rec_path, os.getpid())
        with open(tmp, 'w') as f:
            json.dump(rec, f, sort_keys=True)
            f.write('\n')
        os.replace(tmp, rec_path)
    return lines


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    opts, pos, i = {}, [], 0
    while i < len(rest):
        a = rest[i]
        if a in ('--dir', '--agent') and i + 1 < len(rest):
            opts[a], i = rest[i + 1], i + 2
            continue
        if a in ('--check', '--no-agent-flag'):
            opts[a] = True
        elif a.startswith('--'):
            print('fleet-agent-def: unknown option %s' % a, file=sys.stderr)
            return 2
        else:
            pos.append(a)
        i += 1
    try:
        if cmd == 'find' and len(pos) == 1:
            print(find(pos[0], opts.get('--dir')))
        elif cmd == 'launch' and len(pos) == 1:
            agent = opts.get('--agent', 'claude')
            if agent not in ('claude', 'codex'):
                raise AgentError('--agent must be claude|codex')
            for k, v in launch(pos[0], opts.get('--dir'), agent, not opts.get('--no-agent-flag')):
                print('%s\t%s' % (k, v))
        elif cmd == 'spawn-tools' and len(pos) == 1:
            return 0 if grants_spawn(load(find(pos[0], opts.get('--dir')))['front']) else 1
        elif cmd == 'ship' and not pos:
            for ln in ship(opts.get('--dir'), opts.get('--check', False)):
                print(ln)
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except AgentError as e:
        print('fleet-agent-def: %s' % e, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
