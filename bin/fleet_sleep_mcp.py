"""Verify restartable stdio MCP infrastructure against the live native config.

Restartability is an operator contract, not inferred from a process name or a
tool's readOnlyHint. Browser/REPL state is not serialized by native resume.
Only exact configured launchers and verified package entrypoints are allowed;
their jobs, browsers and other descendants remain blockers.

An inventory is `(configured, statuses)`: the effective server config keyed by
name, and the runtime status per name where the agent reports one. Codex does
(app-server RPC); Claude does not, and its `statuses` is None: the exactly
matching live child process is the only readiness evidence it can offer.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

INCOMPLETE = 'MCP configuration/runtime inventory is incomplete'


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
        raise ValueError(INCOMPLETE)
    return config, {s['name']: s for s in status['data']}


def claude_layers(argv):
    """--mcp-config values in the CLI's own syntax: `=<v>`, or variadic up to the next option."""
    strict = False
    values = []
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == '--':
            break
        if arg == '--strict-mcp-config':
            strict = True
        elif arg.startswith('--mcp-config='):
            values.append(arg.split('=', 1)[1])
        elif arg == '--mcp-config':
            while i + 1 < len(argv) and not argv[i + 1].startswith('-'):
                i += 1
                values.append(argv[i])
        i += 1
    return strict, values


def claude_servers(document, required=True):
    servers = document.get('mcpServers', None if required else {}) if isinstance(document, dict) else None
    if not isinstance(servers, dict) or any(not isinstance(c, dict) for c in servers.values()):
        raise ValueError(INCOMPLETE)
    return servers


def read_json(text_or_path, path=True):
    try:
        return json.loads(Path(text_or_path).read_text() if path else text_or_path)
    except (OSError, ValueError):
        raise ValueError(INCOMPLETE)


def claude_inventory(argv, worktree, config_home=None):
    """Rebuild the effective stdio server set the way the Claude CLI resolves it.

    Claude has no runtime inventory RPC, and `claude mcp list` health-checks every
    approved server (it starts them), so a daemon cannot ask the agent. The set is
    the --mcp-config documents — the whole set under --strict-mcp-config, which is
    how every fleet spawn passes FLEET_MCP_CONFIG — else those over the CLI's own
    store: local scope (`projects[<worktree>].mcpServers`) over the approved
    project `.mcp.json` over user scope, as the CLI ranks them, plus the servers
    the enabled plugins ship under the CLI's own `plugin:<plugin>:<server>` names
    (issue #830). A server approved only through a settings file is not
    inventoried and so vetoes.
    """
    strict, values = claude_layers(argv)
    flagged = {}
    for value in values:
        document = read_json(value, path=Path(value).is_file())
        for name, conf in claude_servers(document).items():
            if name in flagged:
                raise ValueError('MCP service %s is configured more than once' % name)
            flagged[name] = conf
    if strict:
        return flagged, None
    store = read_json(Path(config_home or Path.home()) / '.claude.json')
    projects = store.get('projects') if isinstance(store, dict) else None
    if not isinstance(projects, dict):
        raise ValueError(INCOMPLETE)
    project = next((projects[key] for key in (str(Path(worktree).resolve()), str(worktree))
                    if isinstance(projects.get(key), dict)), {})
    config = plugin_servers(config_home, worktree)
    config.update(claude_servers(store, required=False))
    manifest = Path(worktree) / '.mcp.json'
    if manifest.is_file():
        approved = set(project.get('enabledMcpjsonServers') or []) - set(project.get('disabledMcpjsonServers') or [])
        config.update((name, conf) for name, conf in claude_servers(read_json(manifest)).items() if name in approved)
    config.update(claude_servers(project, required=False))
    for name in project.get('disabledMcpServers') or []:
        config.pop(name, None)
    config.update(flagged)
    return config, None


def plugin_root(value, root):
    if isinstance(value, str):
        return value.replace('${CLAUDE_PLUGIN_ROOT}', root)
    if isinstance(value, list):
        return [plugin_root(item, root) for item in value]
    if isinstance(value, dict):
        return {key: plugin_root(item, root) for key, item in value.items()}
    return value


def plugin_servers(config_home, worktree):
    """Servers the enabled plugins ship, named as the CLI names them: plugin:<plugin>:<server>.

    A plugin that cannot be resolved (no registry, an ambiguous install, an
    unreadable manifest) contributes nothing: its server, if running, then vetoes
    as an unverified process, which is the pre-#830 behaviour for every plugin.
    """
    home = Path(config_home) if config_home else Path.home() / '.claude'
    enabled = {}
    for settings in (home / 'settings.json', Path(worktree) / '.claude' / 'settings.json',
                     Path(worktree) / '.claude' / 'settings.local.json'):
        if not settings.is_file():
            continue
        try:
            flags = read_json(settings).get('enabledPlugins')
        except (ValueError, AttributeError):
            continue
        if isinstance(flags, dict):
            enabled.update(flags)
    registry = home / 'plugins' / 'installed_plugins.json'
    try:
        installed = read_json(registry).get('plugins') if registry.is_file() else None
    except (ValueError, AttributeError):
        installed = None
    config = {}
    if not isinstance(installed, dict):
        return config
    for key, on in enabled.items():
        entries = installed.get(key) if on is True else None
        if not isinstance(entries, list) or len(entries) != 1 or not isinstance(entries[0], dict):
            continue
        root = entries[0].get('installPath')
        if not isinstance(root, str) or not Path(root).is_dir():
            continue
        plugin = key.split('@', 1)[0]
        for manifest in (Path(root) / '.mcp.json', Path(root) / '.claude-plugin' / 'plugin.json'):
            if not manifest.is_file():
                continue
            try:
                document = read_json(manifest)
            except ValueError:
                continue
            if not isinstance(document, dict):
                continue
            # A plugin's .mcp.json is a bare server map or the mcpServers-wrapped
            # form; plugin.json carries an inline mcpServers map or a file path.
            servers = document.get('mcpServers') if manifest.name == 'plugin.json' else document.get('mcpServers', document)
            if isinstance(servers, str):
                try:
                    servers = read_json(Path(root) / servers)
                    servers = servers.get('mcpServers', servers) if isinstance(servers, dict) else None
                except ValueError:
                    servers = None
            if not isinstance(servers, dict):
                continue
            for name, conf in servers.items():
                if isinstance(conf, dict):
                    config['plugin:%s:%s' % (plugin, name)] = plugin_root(conf, root)
    return config


def runtime_ready(status):
    value = status.get('runtimeStatus')
    # Native versions have shipped both a string and a tagged status object.
    ready = value == 'ready' or isinstance(value, dict) and value.get('type') == 'ready'
    # Older servers expose the initialize response and tools/list result only.
    if value is None:
        ready = bool(isinstance(status.get('serverInfo'), dict) and status['serverInfo'].get('name')
                     and isinstance(status.get('tools'), dict) and status['tools'])
    return ready and not status.get('toolsError')


# `bash -c 'exec WORD...'` (issue #4537): the fleet's own MCP launcher
# (conf/mcp-worker.json) is a shell that execs Python, so the live kernel is
# Python and its argv is the EXPANDED words. Only this one shape is read: words
# of literal text, '…' and "…" whose only expansions are $NAME / ${NAME} /
# ${NAME:-word} inside double quotes. Anything else — another statement, a
# command substitution, an unquoted expansion, a glob, a tilde, an escape, an
# option to exec — is not proven and stays an unverified process.
_SAFE = r'A-Za-z0-9_./,:=@%+-'
_NAME = r'[A-Za-z_][A-Za-z0-9_]*'
# Variables bash sets or rewrites itself, so the started process's environment
# does not say what the shell expanded them to.
_SHELL_OWNED = {'PWD', 'OLDPWD', 'SHLVL', '_', 'IFS', 'PPID', 'UID', 'EUID', 'RANDOM', 'SECONDS',
                'LINENO', 'HOSTNAME', 'HOSTTYPE', 'OSTYPE', 'MACHTYPE', 'OPTIND', 'OPTARG', 'PATH'}
# Present at the shell's start, these could run code or change what `exec` is:
# BASH_ENV / ENV run a file first, SHELLOPTS / BASHOPTS / POSIXLY_CORRECT turn
# options on, EXECIGNORE hides programs from the lookup, BASH_FUNC_* (or any
# value `() {…`) define functions, SSH_CLIENT makes bash read ~/.bashrc.
_SHELL_HOOKS = ('ENV', 'SHELLOPTS', 'BASHOPTS', 'POSIXLY_CORRECT', 'EXECIGNORE', 'SSH_CLIENT', 'SSH2_CLIENT')


def _hooked(names):
    return any(n in _SHELL_HOOKS or n.startswith('BASH_') for n in names)


def _shell_expansion(text, i, names):
    """Parse one expansion at text[i] == '$'; return (end, node) or None."""
    m = re.match(r'\$(' + _NAME + r')', text[i:])
    if m:
        names.add(m.group(1))
        return i + m.end(), ('var', m.group(1), None)
    m = re.match(r'\$\{(' + _NAME + r')(:-)?', text[i:])
    if not m:
        return None
    name = m.group(1)
    names.add(name)
    j = i + m.end()
    if not m.group(2):
        return (j + 1, ('var', name, None)) if text[j:j + 1] == '}' else None
    default = []
    while j < len(text) and text[j] != '}':
        if text[j] == '$':
            got = _shell_expansion(text, j, names)
            if not got or got[1][2] is not None:  # one level of default only
                return None
            j, node = got
            default.append(node)
            continue
        lit = re.match('[' + _SAFE + ']+', text[j:])
        if not lit:
            return None
        default.append(('lit', lit.group(0)))
        j += lit.end()
    if j >= len(text):
        return None
    return j + 1, ('var', name, default)


def shell_exec_words(script):
    """`exec WORD...` as a list of words (each a list of nodes) + the names read, or None."""
    names = set()
    words = []
    i = 0
    text = script.strip(' \t\n')
    while i < len(text):
        while i < len(text) and text[i] in ' \t':
            i += 1
        if i >= len(text):
            break
        word = []
        while i < len(text) and text[i] not in ' \t':
            c = text[i]
            if c == "'":
                end = text.find("'", i + 1)
                if end < 0:
                    return None
                word.append(('lit', text[i + 1:end]))
                i = end + 1
            elif c == '"':
                i += 1
                while i < len(text) and text[i] != '"':
                    if text[i] == '$':
                        got = _shell_expansion(text, i, names)
                        if not got:
                            return None
                        i, node = got
                        word.append(node)
                        continue
                    m = re.match('[ ' + _SAFE + ']+', text[i:])
                    if not m:
                        return None
                    word.append(('lit', m.group(0)))
                    i += m.end()
                if i >= len(text):
                    return None
                i += 1
            else:
                m = re.match('[' + _SAFE + ']+', text[i:])
                if not m:
                    return None  # an unquoted expansion, glob, ~, \\, ;, | ...
                word.append(('lit', m.group(0)))
                i += m.end()
        words.append(word)
    if len(words) < 2 or words[0] != [('lit', 'exec')] or any(n[0] != 'lit' for n in words[1]):
        return None
    if ''.join(n[1] for n in words[1]).startswith('-'):
        return None  # exec -a/-c/-l rewrite argv[0] or the environment
    return words[1:], names


def _expand(nodes, env):
    out = []
    for node in nodes:
        if node[0] == 'lit':
            out.append(node[1])
            continue
        _, name, default = node
        value = env.get(name)
        if default is not None and not value:
            value = _expand(default, env)
        if value is None:
            raise ValueError('unset')  # bash would expand "", but say nothing we cannot see
        out.append(value)
    return ''.join(out)


# Codex releases whose stdio MCP environment was MEASURED to be the allowlist +
# env_vars + env (issue #4537: real app-server, every hook in its environment,
# none reached the child; one named in env_vars did). Another release gets no
# shell-exec identity until it is measured and added here.
SHELL_EXEC_CODEX = ('0.160.1',)


def codex_version(client):
    """The version the live app-server gave in its initialize answer, or None."""
    agent = (getattr(client, 'initialized', None) or {}).get('userAgent')
    m = re.match(r'[^/\s]+/(\d+\.\d+\.\d+)(?:[\s;(]|$)', agent) if isinstance(agent, str) else None
    return m.group(1) if m else None


def shell_exec_reader(client, reader):
    """<reader> for a measured Codex release, else None (the shape stays unverified)."""
    return reader if codex_version(client) in SHELL_EXEC_CODEX else None


def shell_exec_argv(pid, parent, config, env_reader):
    """(argv, PATH, start token) the configured `bash -c 'exec …'` would exec as <pid>, or None.

    What this proves is that the kernel process is the exec target of the
    EFFECTIVE config's shell — not a record of that launch: once bash is gone
    nothing records what it expanded. It holds under these conditions, each
    checked here or by the caller:

    - the agent is a measured Codex release (its classify calls pass an
      env_reader only through shell_exec_reader / SHELL_EXEC_CODEX): a
      0.160.1 stdio MCP child gets Codex's allowlist (HOME, LANG, PATH,
      TMPDIR, …) + the config's `env_vars` + its `env`, never the rest of
      Codex's environment — so a shell hook (_SHELL_HOOKS, BASH_*) reaches
      bash only through `env` / `env_vars`, and neither may name one; nor may
      the process's own environment, nor may its stdin be a socket (bash then
      reads ~/.bashrc instead, whatever the environment says). Another Codex
      release is not trusted until it is measured and listed. Claude hands its
      MCP children its whole, mutable environment: no proof is offered there.
    - the agent's own start environment names no hook either (a backstop for
      the allowlist above, not a proof of what it handed down at runtime;
      SSH_CLIENT there is normal and is not handed down);
    - every variable the script expands is, in the process's environment,
      exactly the config's `env` value, else the agent's, else absent — a
      launcher between bash and the kernel (macOS's python3 shim rewrites PATH)
      may change other variables, not these;
    - the process started after the agent and was not replaced meanwhile.
    """
    command = config.get('command')
    args = config.get('args')
    extra = config.get('env') or {}
    forwarded = config.get('env_vars') or []
    if (env_reader is None or parent is None or not isinstance(command, str)
            or Path(command).name != 'bash' or not isinstance(args, list) or len(args) != 2
            or args[0] != '-c' or not isinstance(args[1], str) or not isinstance(extra, dict)
            or any(not isinstance(k, str) or not isinstance(v, str) for k, v in extra.items())
            or not isinstance(forwarded, list) or any(not isinstance(n, str) for n in forwarded)):
        return None
    parsed = shell_exec_words(args[1])
    if not parsed:
        return None
    words, names = parsed
    if names & _SHELL_OWNED or any(n.startswith('BASH') for n in names):
        return None
    wanted = names | {'PATH'}
    try:
        mine = env_reader(pid, wanted)
        theirs = env_reader(parent, wanted)
    except (OSError, ValueError, UnicodeDecodeError):
        return None
    env, origin, birth = mine['values'], theirs['values'], mine['birth']
    # A socket on stdin (and SHLVL < 2) makes bash read /etc/bashrc + ~/.bashrc
    # as if started by sshd — no variable shows that, fd 0 survives the exec.
    if (mine['stdin_socket'] or _hooked(mine['names']) or mine['functions']
            or _hooked(extra) or _hooked(forwarded)
            or _hooked(n for n in theirs['names'] if not n.startswith('SSH')) or theirs['functions']
            or theirs['birth'] > birth):
        return None
    for name in names:
        if name in extra:
            if env.get(name) != extra[name]:
                return None
        elif name in env and env[name] != origin.get(name):
            return None
    try:
        # PATH is only where bash looked the program up: what it was handed, not
        # the process's own (macOS's python3 shim rewrites that before re-exec).
        return [_expand(word, env) for word in words], extra.get('PATH', origin.get('PATH')), birth
    except ValueError:
        return None


def configured_process(pid, config, argv_reader, exe_reader, env_reader=None, parent=None):
    command = config.get('command')
    args = config.get('args') or []
    if not isinstance(command, str) or not isinstance(args, list) or not command:
        return False
    launched = shell_exec_argv(pid, parent, config, env_reader)
    if launched is not None:
        # After exec the shell is gone: compare the kernel's process with what it
        # would exec. Same rule as a bare configured program below — exact argv,
        # the program found on the PATH bash was handed, its name, or macOS's
        # framework Python — so this says which configured server the process
        # is, never that its script still exists or that it may be restarted.
        launched, search, birth = launched
        argv = argv_reader(pid)
        executable = exe_reader(pid)
        try:
            same = env_reader(pid, set())['birth'] == birth  # the number was not reused meanwhile
        except (OSError, ValueError):
            same = False
        program = launched[0]
        found = shutil.which(program, path=search) if search else None
        framework_python = (re.fullmatch(r'python(?:\d+(?:\.\d+)*)?', program) is not None
                            and executable.parts[-4:] == ('Python.app', 'Contents', 'MacOS', 'Python'))
        if (same and '/' not in program and argv[1:] == launched[1:]
                and (executable.name == program or framework_python
                     or (found and executable == Path(found).resolve()))):
            return True
    argv = argv_reader(pid)
    executable = exe_reader(pid)
    # A bare program name resolves on the VERIFIER's PATH, which need not be the
    # launcher's: the sleep daemon found node 26 first while Codex had started
    # mcp-image under node@22, and the exact-path comparison below called the
    # configured server an unverified job. The same program name running the
    # exact configured argv is that server; a different build of it is not a job.
    # macOS's python3 launcher re-execs the framework's Python.app binary.
    # Keep the exact configured service argv and native parent/inventory checks;
    # this is not an exemption for arbitrary Python jobs or an absolute command
    # that points at a different executable.
    framework_python = (re.fullmatch(r'python(?:\d+(?:\.\d+)*)?', command) is not None
                        and executable.parts[-4:] == ('Python.app', 'Contents', 'MacOS', 'Python'))
    if (not os.path.isabs(command) and (executable.name == Path(command).name or framework_python)
            and argv[1:] == args):
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


def matched_services(pid, configured, rows, argv_reader, exe_reader, env_reader=None):
    return [(name, conf) for name, conf in configured.items()
            if conf.get('enabled', True) and
            (configured_process(pid, conf, argv_reader, exe_reader, env_reader, rows.get(pid, (None,))[0])
             or npm_title_process(pid, conf, rows, argv_reader, exe_reader))]


def restartable(source):
    """The approved restartable-MCP names for THIS worker, and the conf holding them.

    Per repo (issue #978): in a fleet with repo overlays the list is the worker's
    repo's FLEET_SLEEP_MCP_RESTARTABLE, falling back to the fleet value — resolved
    by `fleet-repo.sh get` from the window (else the worktree), never guessed here.
    A fleet with no overlay reads the inherited fleet value, exactly as before.
    """
    fleet = os.environ.get('FLEET_SLEEP_MCP_RESTARTABLE', '')
    session = source.get('session') or ''
    conf_dir = Path(os.environ.get('FLEET_CONF_DIR') or Path.home() / '.config' / 'claude-fleet')
    conf = conf_dir / 'fleets' / (session or '<fleet>') / 'conf'
    value = fleet
    if session and any((conf_dir / 'fleets' / session / 'repos').glob('*.conf')):
        where = (['--window', source['window']] if source.get('window')
                 else ['--worktree', source['worktree']] if source.get('worktree') else [])
        try:
            out = subprocess.run(['bash', str(Path(__file__).absolute().parent / 'fleet-repo.sh'), 'get',
                                  'FLEET_SLEEP_MCP_RESTARTABLE', '--session', session, *where, '--tsv'],
                                 capture_output=True, text=True, timeout=20)
            fields = out.stdout.rstrip('\n').split('\t')
            if out.returncode == 0 and len(fields) == 3:
                _, conf, value = fields
                conf = Path(conf)
        except (OSError, subprocess.SubprocessError):
            pass
    return {name.strip() for name in value.split(',') if name.strip()}, conf


def contracted(name, approved):
    """Is <name> on the restartability contract? A plugin's stdio server
    (`plugin:<plugin>:<server>`) is by default (issue #1583): Claude Code starts
    it afresh with every process, exactly as a resumed session needs — and a
    browser or job beneath it is still refused below. `!plugin:*` in the list
    takes that default back; `!<name>` refuses one plugin server."""
    if '!' + name in approved:
        return False
    return name in approved or (name.startswith('plugin:') and '!plugin:*' not in approved)


def contract_hint(source, approved, name, conf=None):
    """The one conf line that would lift this refusal, and where it goes (#786).

    Sleep and quota failover share this classifier, and a failover refusal lives
    only in its request.json detail, so the fix must be in the message itself.
    """
    listed = sorted(approved) + [name]
    if conf is None:
        conf = Path(os.environ.get('FLEET_CONF_DIR') or Path.home() / '.config' / 'claude-fleet')
        conf = conf / 'fleets' / (source.get('session') or '<fleet>') / 'conf'
    return ('if %s survives a restart, add FLEET_SLEEP_MCP_RESTARTABLE=%s to %s'
            % (name, ','.join(listed), conf))


def classify(source, inventory, rows, server_pid, argv_reader, exe_reader, strict=True, env_reader=None):
    # strict=False answers a narrower question (issue #864): not "may this worker
    # hibernate?" but "is this configured MCP service, or something the agent is
    # still running?". An uncontracted, unready or job-owning service is still an
    # MCP service. Claude's historical non-strict walk delegates its tool work
    # to fleet_window_tool_busy. Codex must keep jobs beneath a server visible:
    # only the configured launcher and verified package entrypoint are helpers.
    # env_reader (fleet_sleep_argv.process_env) lets a `bash -c 'exec …'` launcher
    # match its exec target (shell_exec_argv, issue #4537) — Codex callers only;
    # without it that shape stays unverified. Identity is never a contract.
    configured, statuses = inventory
    approved, contract_conf = restartable(source) if strict else (set(), None)
    allowed = set()
    proof = {}
    basis = {}
    for pid, (parent, _) in rows.items():
        if parent != server_pid:
            continue
        matches = matched_services(pid, configured, rows, argv_reader, exe_reader, env_reader)
        if len(matches) != 1:
            continue
        name, conf = matches[0]
        if not strict and source.get('agent') == 'codex':
            if statuses is None or not runtime_ready(statuses.get(name, {})):
                continue  # unknown/unready is not evidence of idle infrastructure
            allowed.add(pid)
            allowed.update(child for child, (pp, _) in rows.items() if pp == pid
                           and package_child(child, conf, argv_reader, exe_reader))
            continue
        if not strict:
            pending = [pid]
            while pending:
                node = pending.pop()
                if node in allowed:
                    continue
                allowed.add(node)
                pending.extend(child for child, (pp, _) in rows.items() if pp == node)
            continue
        if not contracted(name, approved):
            raise ValueError('MCP service %s has no restartability contract (FLEET_SLEEP_MCP_RESTARTABLE); %s'
                             % (name, contract_hint(source, approved, name, contract_conf)))
        # Codex reports a runtime status per server. Claude has no such channel:
        # the exactly matching live process is the evidence, and a server still
        # initializing is as restartable as a ready one.
        if statuses is not None and not runtime_ready(statuses.get(name, {})):
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
        if shell_exec_argv(pid, server_pid, conf, env_reader) is not None:
            basis[name] = 'shell-exec'
    source['sleep_mcp'] = proof
    if basis:
        # How each service was identified, for the record: 'shell-exec' = the
        # kernel is the exec target of the effective config's shell, under
        # shell_exec_argv's conditions. Names and the basis only — never a value.
        source['sleep_mcp_basis'] = basis
    else:
        source.pop('sleep_mcp_basis', None)
    return allowed


def service_running(conf, processes):
    """Claude readiness: exactly one child of the resumed agent runs the configured launcher."""
    rows, server_pid, argv_reader, exe_reader = processes
    live = [pid for pid, (parent, _) in rows.items()
            if parent == server_pid and matched_services(pid, {'_': conf}, rows, argv_reader, exe_reader)]
    return len(live) == 1


def verify_resume(source, inventory, processes=None):
    expected = source.get('sleep_mcp')
    if not expected:
        return True
    config, statuses = inventory
    for name, digest in expected.items():
        if name not in config or fingerprint(config[name]) != digest:
            raise ValueError('MCP service %s configuration changed during sleep' % name)
        if statuses is not None:
            if not runtime_ready(statuses.get(name, {})):
                return False
        elif not service_running(config[name], processes):
            return False
    return True
