#!/usr/bin/env python3
"""Does a fresh fleet Codex launch need the CLI full-access flag? (issue #4724)

fleet-codex.sh used to start every fresh Codex with
--dangerously-bypass-approvals-and-sandbox. Codex counts that flag (and any `-c
approval_policy=` / `sandbox_mode=` …) as a SESSION permission override, and a TUI
connected to a remote app-server — the fleet's private runtime — refuses every
in-TUI /resume while one is set: «Permission overrides are not supported when
resuming a remote task.» So a person who reached a fleet Codex pane could never
pick an older thread back up from /resume.

The fleet already ships the same posture into the login's config.toml
(conf/agent-defaults/codex/config.default.toml: approval_policy = "never",
sandbox_mode = "danger-full-access", fill only). Held there it is a user layer, not
a session flag: the posture is identical and /resume works. This answers whether
the user layer alone yields it, so the launcher can drop the CLI flag:

    fleet-codex-posture.py check --home <CODEX_HOME> --cwd <dir> [-- <codex argv>]

exit 0 + `config` — config.toml says never + danger-full-access, nothing above it
  (a profile, a permissions table, a project .codex/config.toml, an argv override)
  can change that: launch WITHOUT the flag.
exit 1 + `flag <why>` — anything else, unreadable included: keep the flag (the old
  launch, byte for byte).
"""
import os
from pathlib import Path
import runpy
import sys

TOML = runpy.run_path(str(Path(__file__).with_name('fleet-agent-defaults.py')))

WANT = {'approval_policy': 'never', 'sandbox_mode': 'danger-full-access'}
# Top-level keys / tables that can move the effective posture off the two above.
MOVERS = ('profile', 'default_permissions', 'permissions', 'approvals_reviewer')
# Argv that is itself a permission choice (a session flag either way).
ARG_FLAGS = ('-a', '--ask-for-approval', '-s', '--sandbox', '--full-auto',
             '--dangerously-bypass-approvals-and-sandbox', '--yolo', '-p', '--profile')
ARG_KEYS = tuple(WANT) + MOVERS + ('sandbox_workspace_write',)


def scan(text):
    """{top-level key: raw value or ''} plus the set of top-level table names."""
    parser = TOML['_toml']
    if parser:
        data = parser.loads(text)
        tops = {k: v for k, v in data.items() if not isinstance(v, dict)}
        return tops, {k for k, v in data.items() if isinstance(v, dict)}
    s = TOML['TomlScan'](text)
    tops = {}
    for path, raw in s.values.items():
        if len(path) == 1:
            value, rest = TOML['parse_value'](raw)
            if rest.strip() and not rest.lstrip().startswith('#'):
                raise ValueError('unreadable value for ' + path[0])
            tops[path[0]] = value
    tables = {t[0] for t in s.tables if t} | {p[0] for p in s.values if len(p) > 1}
    return tops, tables


def argv_reason(argv):
    for i, a in enumerate(argv):
        if a == '--':
            break
        if a in ARG_FLAGS or any(a.startswith(f + '=') for f in ARG_FLAGS if f.startswith('--')):
            return 'argv ' + a
        val = None
        if a in ('-c', '--config') and i + 1 < len(argv):
            val = argv[i + 1]
        elif a.startswith('--config='):
            val = a.split('=', 1)[1]
        elif a.startswith('-c') and a != '-c':
            val = a[2:]
        if val is not None:
            key = val.split('=', 1)[0].strip().strip('"')
            if key.split('.', 1)[0] in ARG_KEYS:
                return 'argv -c ' + key
    return ''


def project_reason(cwd):
    """A project's .codex/config.toml (cwd and its parents) layers above the user's."""
    d = Path(cwd).resolve()
    for p in [d, *d.parents]:
        f = p / '.codex' / 'config.toml'
        if f.is_file():
            try:
                tops, tables = scan(f.read_text())
            except Exception:
                return 'project config unreadable: %s' % f
            if set(tops) & (set(WANT) | set(MOVERS)) or set(tables) & set(MOVERS):
                return 'project config sets permissions: %s' % f
    return ''


def check(home, cwd, argv):
    why = argv_reason(argv)
    if why:
        return why
    try:
        tops, tables = scan((Path(home) / 'config.toml').read_text())
    except FileNotFoundError:
        return 'no config.toml'
    except Exception as exc:
        return 'config.toml unreadable (%s)' % type(exc).__name__
    for key, want in WANT.items():
        if tops.get(key) != want:
            return 'config.toml %s is %r' % (key, tops.get(key))
    moved = sorted((set(tops) | set(tables)) & set(MOVERS))
    if moved:
        return 'config.toml sets ' + ','.join(moved)
    return project_reason(cwd)


def main(args):
    if not args or args[0] != 'check':
        print('usage: fleet-codex-posture.py check --home H --cwd D [-- argv]', file=sys.stderr)
        return 2
    home = cwd = None
    rest = args[1:]
    argv = []
    if '--' in rest:
        argv = rest[rest.index('--') + 1:]
        rest = rest[:rest.index('--')]
    while rest:
        if rest[0] == '--home' and len(rest) > 1:
            home, rest = rest[1], rest[2:]
        elif rest[0] == '--cwd' and len(rest) > 1:
            cwd, rest = rest[1], rest[2:]
        else:
            print('fleet-codex-posture: unknown ' + rest[0], file=sys.stderr)
            return 2
    home = home or os.environ.get('CODEX_HOME') or os.path.expanduser('~/.codex')
    why = check(home, cwd or os.getcwd(), argv)
    print('flag ' + why if why else 'config')
    return 1 if why else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
