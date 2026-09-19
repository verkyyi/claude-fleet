"""Verify restartable stdio MCP infrastructure against the live native config.

Restartability is an operator contract, not inferred from a process name or a
tool's readOnlyHint. Browser/REPL state is not serialized by native resume.
Only exact configured launchers and verified package entrypoints are allowed;
their jobs, browsers and other descendants remain blockers.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil


def fingerprint(config):
    # Keep secrets out of retained records. Digest the entire effective server
    # config so changed launch arguments/credentials cannot pass wake validation.
    return hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()


def inventory(client):
    config = client.call('config/read', {'includeLayers': False})['config'].get('mcp_servers', {})
    status = client.call('mcpServerStatus/list', {})
    if (not isinstance(config, dict) or any(not isinstance(c, dict) for c in config.values())
            or status.get('nextCursor') or not isinstance(status.get('data'), list)
            or any(not isinstance(s, dict) or not isinstance(s.get('name'), str) for s in status['data'])):
        raise ValueError('MCP configuration/runtime inventory is incomplete')
    return config, {s['name']: s for s in status['data']}


def runtime_ready(status):
    value = status.get('runtimeStatus')
    # Native versions have shipped both a string and a tagged status object.
    ready = value == 'ready' or isinstance(value, dict) and value.get('type') == 'ready'
    # Older servers expose the initialize response and tools/list result only.
    if value is None:
        ready = bool(isinstance(status.get('serverInfo'), dict) and status['serverInfo'].get('name')
                     and isinstance(status.get('tools'), dict) and status['tools'])
    return ready and not status.get('toolsError')


def configured_process(pid, config, argv_reader, exe_reader):
    command = config.get('command')
    args = config.get('args') or []
    if not isinstance(command, str) or not isinstance(args, list) or not command:
        return False
    argv = argv_reader(pid)
    executable = exe_reader(pid)
    # A bare program name resolves on the VERIFIER's PATH, which need not be the
    # launcher's: the sleep daemon found node 26 first while Codex had started
    # mcp-image under node@22, and the exact-path comparison below called the
    # configured server an unverified job. The same program name running the
    # exact configured argv is that server; a different build of it is not a job.
    if not os.path.isabs(command) and executable.name == Path(command).name and argv[1:] == args:
        return True
    resolved = Path(command) if os.path.isabs(command) else Path(shutil.which(command) or '/nonexistent')
    if not resolved.is_file():
        return False
    resolved = resolved.resolve()
    if executable == resolved and argv[1:] == args:
        return True
    if (Path(command).name == 'uvx' and executable == resolved.with_name('uv').resolve()
            and argv[1:] == ['tool', 'uvx', *args]):
        return True
    # npx and executable Python/Node entrypoints run under an interpreter.
    if (executable.name.startswith(('node', 'python')) and len(argv) > 1
            and Path(argv[1]).is_file() and Path(argv[1]).resolve() == resolved
            and argv[2:] == args):
        return True
    return False


def npm_title_process(pid, config, rows, argv_reader, exe_reader):
    """npm overwrites argv; verify its sole package child instead of parsing ps."""
    if Path(config.get('command') or '').name != 'npx':
        return False
    args = config.get('args') or []
    if not isinstance(args, list):
        return False
    values = args[1:] if args[:1] == ['-y'] else args
    argv = argv_reader(pid)
    executable = exe_reader(pid)
    children = [child for child, (parent, _) in rows.items() if parent == pid]
    return (bool(values) and executable.name == 'node' and len(children) == 1
            and argv[0] == 'npm exec ' + ' '.join(values) and not any(argv[1:])
            and exe_reader(children[0]) == executable
            and package_child(children[0], config, argv_reader, exe_reader))


def package_child(pid, config, argv_reader, exe_reader):
    """Recognize a wrapper's one leaf entrypoint, never its arbitrary children."""
    command = Path(config.get('command') or '').name
    args = config.get('args') or []
    argv = argv_reader(pid)
    if len(argv) < 2 or not Path(argv[1]).is_file():
        return False
    script = Path(argv[1]).resolve()
    executable = exe_reader(pid)
    if command == 'npx' and executable.name == 'node':
        values = args[1:] if args[:1] == ['-y'] else args
        if not values or values[0].startswith('-'):
            return False
        package = values[0].rsplit('@', 1)[0] if '@' in values[0][1:] else values[0]
        for parent in script.parents:
            manifest = parent / 'package.json'
            if not manifest.is_file():
                continue
            data = json.loads(manifest.read_text())
            if data.get('name') != package:
                continue
            bins = data.get('bin', {})
            entries = [bins] if isinstance(bins, str) else list(bins.values())
            return (any((parent / entry).resolve() == script for entry in entries)
                    and argv[2:] == values[1:])
    if command == 'uvx' and executable.name.startswith('python'):
        values = args[2:] if args[:1] == ['--from'] else args
        # uv tools use an isolated environment. The script must reside beside
        # that environment's Python, with its exact configured entrypoint/args.
        if values and not values[0].startswith('-'):
            interpreter = Path(argv[0]).absolute()
            return (script.name == values[0] and script.parent == interpreter.parent
                    and (script.parent.parent / 'pyvenv.cfg').is_file()
                    and interpreter.resolve() == executable and argv[2:] == values[1:])
    return False


def classify(source, client, rows, server_pid, argv_reader, exe_reader):
    configured, statuses = inventory(client)
    approved = {name.strip() for name in os.environ.get('FLEET_SLEEP_MCP_RESTARTABLE', '').split(',') if name.strip()}
    allowed = set()
    proof = {}
    for pid, (parent, _) in rows.items():
        if parent != server_pid:
            continue
        matches = [(name, conf) for name, conf in configured.items()
                   if conf.get('enabled', True) and
                   (configured_process(pid, conf, argv_reader, exe_reader)
                    or npm_title_process(pid, conf, rows, argv_reader, exe_reader))]
        if len(matches) != 1:
            continue
        name, conf = matches[0]
        if name not in approved:
            raise ValueError('MCP service %s has no restartability contract (FLEET_SLEEP_MCP_RESTARTABLE)' % name)
        if not runtime_ready(statuses.get(name, {})):
            raise ValueError('MCP service %s is not ready or has unknown runtime status' % name)
        allowed.add(pid)
        for child, (pp, _) in rows.items():
            if pp != pid:
                continue
            if not package_child(child, conf, argv_reader, exe_reader):
                raise ValueError('MCP service %s owns an unverified child process' % name)
            if any(parent == child for parent, _ in rows.values()):
                raise ValueError('MCP service %s owns a live job/browser beneath its entrypoint' % name)
            allowed.add(child)
        proof[name] = fingerprint(conf)
    source['sleep_mcp'] = proof
    return allowed


def verify_resume(source, client):
    expected = source.get('sleep_mcp')
    if not expected:
        return True
    config, status = inventory(client)
    for name, digest in expected.items():
        if name not in config or fingerprint(config[name]) != digest:
            raise ValueError('MCP service %s configuration changed during sleep' % name)
        if not runtime_ready(status.get(name, {})):
            return False
    return True
