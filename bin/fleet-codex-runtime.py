#!/usr/bin/env python3
"""Run a Codex TUI and its own local app-server with one bounded lifetime.

The guardian anchors its own session/process group and reads a pipe held ONLY
by the supervisor. EOF, including a SIGKILLed supervisor, tears down that private
group even if the server exited first. Helpers which create another session or
group are outside this guarantee. No shared daemon or TCP port is used.
"""
import json
import os
from pathlib import Path
import select
import re
import runpy
import shutil
import signal
import subprocess
import sys
import tempfile
import time

# The Codex versions whose rollout (session JSONL) shape fleet's context reader
# is verified against (docs/dev/AGENT-ADAPTER.md, «rollout»). The rollout is an upstream
# internal interface, so an upgrade can change it silently and the dashboard
# would then show a wrong context% with no error anywhere (issue #1079). Each
# entry is a version PREFIX matched on whole components: "0.162" covers 0.162.0
# and 0.162.3, never 0.1620. Add a version here only after the fixture tests
# (fleet-codex-session-selftest.sh) pass against its real rollout files.
# Only the release pin (0.162 since issue #3157, release.json's 0.162.1) is
# supported (T588): an older Codex is named as such, never read as compatible.
SUPPORTED_ROLLOUT_VERSIONS = ("0.162",)
PIN_COMMAND = "npm i -g @openai/codex@0.162.1"


def version_supported(version):
    parts = version.split(".")
    return any(parts[:len(p.split("."))] == p.split(".") for p in SUPPORTED_ROLLOUT_VERSIONS)


def version_older(version):
    """True when `version` sorts below every supported prefix (numeric components)."""
    def nums(v):
        return tuple(int(x) for x in v.split(".") if x.isdigit())
    return all(nums(version) < nums(p) for p in SUPPORTED_ROLLOUT_VERSIONS)


def version_check(codex="codex"):
    """(rc, one line): 0 supported, 1 unverified version, 2 not installed/unreadable."""
    try:
        out = subprocess.run([codex, "--version"], stdin=subprocess.DEVNULL,
                             capture_output=True, text=True, timeout=20)
    except FileNotFoundError:
        return 2, "codex not installed"
    except (OSError, subprocess.SubprocessError) as exc:
        return 2, "codex --version failed: " + str(exc)
    text = (out.stdout or out.stderr or "").strip()
    match = re.search(r"(\d+\.\d+(?:\.\d+)*)", text)
    if out.returncode != 0 or not match:
        return 2, "could not read codex --version: " + (text.splitlines() or ["(no output)"])[0][:120]
    version = match.group(1)
    verified = "/".join(SUPPORTED_ROLLOUT_VERSIONS)
    if version_supported(version):
        return 0, "codex " + version + " (rollout format verified for " + verified + ")"
    if version_older(version):
        return 1, ("codex " + version + " is older than the release pin " + verified +
                   " and no longer supported; pin it: `" + PIN_COMMAND +
                   "`, or set FLEET_CODEX_VERSION_CHECK=0 to silence")
    return 1, ("codex " + version + ": fleet only verified the " + verified +
               " session-file (rollout) format, so context% may be wrong; pin it: `" +
               PIN_COMMAND + "`, or set FLEET_CODEX_VERSION_CHECK=0 to silence")


def target_binary(root=None):
    """The launcher's managed release tool, otherwise its inherited PATH tool."""
    root = Path(root) if root is not None else Path(__file__).resolve().parent.parent
    managed = root / 'tools/bin/codex'
    if not os.access(managed, os.X_OK) and any(
            not Path(p).is_absolute() for p in os.environ.get('PATH', '').split(os.pathsep)):
        raise ValueError('target Codex binary PATH is relative; source retained')
    binary = str(managed) if os.access(managed, os.X_OK) else shutil.which('codex')
    if not binary:
        raise ValueError('target Codex binary is unavailable; source retained')
    return str(Path(binary).resolve())


def require_capability(client):
    # This is the same initialize parser and floor as the writable session gate.
    from fleet_session_gate import CODEX_MIN, codex_version
    version = codex_version(client)
    if version is None or version[:2] < CODEX_MIN:
        raise ValueError('target Codex initialize capability is not verified; source retained')


def target_preflight(root=None, timeout=8):
    """Initialize only: no account HOME, MCP, thread, queue or model request.

    Reuse the private runtime guardian, so even a killed transfer closes its
    owner pipe and tears down this isolated server. This proves the runtime,
    separately from target-auth's subscription proof.
    """
    if not 0 < timeout <= 8:
        raise ValueError('target initialize budget must be in (0, 8] seconds')
    binary = target_binary(root)
    before = Path(binary).stat()
    fingerprint = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    rpc_class = runpy.run_path(str(Path(__file__).with_name('fleet-codex-rpc.py')))['Client']
    directory = tempfile.mkdtemp(prefix='fleet-probe-', dir='/tmp')
    remote = 'unix://' + directory + '/probe.sock'
    env = dict(os.environ, HOME=directory, CODEX_HOME=directory,
               XDG_CONFIG_HOME=directory, FLEET_CODEX_REMOTE=remote)
    # No ambient credentials or remote endpoint can attach the probe to a user.
    for key in list(env):
        if re.search(r'AUTH|TOKEN|SECRET|PASSWORD|_KEY', key) or key in (
                'CODEX_THREAD_ID', 'CODEX_SESSION_ID', 'FLEET_CODEX_HOME',
                'FLEET_CODEX_PROFILE', 'FLEET_WORKER_CRED', 'FLEET_WORKER_ASSERT'):
            env.pop(key)
    read_fd, write_fd = os.pipe()
    guardian = rpc = None
    deadline = time.monotonic() + timeout
    try:
        guardian = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--guard', str(read_fd),
                                     directory, binary, 'app-server', '--listen', remote],
                                    env=env, cwd=directory, pass_fds=(read_fd,),
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
        os.close(read_fd); read_fd = -1
        while not Path(remote[7:]).exists():
            if guardian.poll() is not None or time.monotonic() >= deadline:
                raise ValueError('target Codex initialize unavailable; source retained')
            time.sleep(.02)
        remaining = deadline-time.monotonic()
        if remaining <= 0:
            raise ValueError('target Codex initialize timed out; source retained')
        rpc = rpc_class(remote, timeout=remaining)
        require_capability(rpc)
        after = Path(binary).stat()
        if (target_binary(root) != binary or
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != fingerprint):
            raise ValueError('target Codex binary changed during initialize; source retained')
        return dict(binary=binary, fingerprint=fingerprint, initialize=rpc.initialized)
    except (OSError, RuntimeError, TimeoutError) as error:
        raise ValueError('target Codex initialize failed; source retained') from error
    finally:
        if rpc is not None:
            rpc.close()
        os.close(write_fd)
        if read_fd >= 0:
            os.close(read_fd)
        if guardian is not None:
            guardian.wait(timeout=8)
        shutil.rmtree(directory, ignore_errors=True)


def private_group_busy():
    """Only a grace-period hint: the final signal always reaches our own group.

    The ps child temporarily joins this group too. Exclude it and ourselves;
    zombies cannot fork or do work. A failed observation never shortens grace.
    No PID from this snapshot is ever used as a signal target.
    """
    try:
        query = subprocess.Popen(['ps', '-axo', 'pid=,pgid=,stat='], stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, text=True)
        try:
            try:
                output, _ = query.communicate(timeout=.5)
            except subprocess.TimeoutExpired:
                query.kill()
                try:
                    query.communicate(timeout=.5)
                except subprocess.TimeoutExpired:
                    pass  # final own-group KILL also covers this bounded query
                return True
            if query.returncode:
                return True
            for line in output.splitlines():
                pid, group, state = line.split()
                if int(group) == os.getpid() and int(pid) not in (os.getpid(), query.pid) and not state.startswith('Z'):
                    return True
        finally:
            query.stdout.close()
        return False
    except (OSError, ValueError):
        return True


def stop_private_group(process, directory):
    """Guardian-only: never signal a cached PID/PGID after its owner was reaped.

    We remain the live session/group leader through the FINAL killpg syscall.
    That also kills this guardian, so its internal exit code may be -SIGKILL.
    The supervising runtime waits for it but preserves the TUI's exit code.
    """
    pid = os.getpid()
    if os.getpgrp() != pid or os.getsid(0) != pid:
        raise RuntimeError('guardian does not own a private session/group')
    try:
        # Our handler keeps the anchor alive while the server/helpers get TERM.
        os.killpg(pid, signal.SIGTERM)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if process is not None:
                process.poll()  # reap the direct child, including early exit
            if not private_group_busy():
                break
            time.sleep(.05)
    finally:
        # The group identity is still pinned by this executing guardian, even
        # when the server died/reaped before stop began. Never reuse server.pid.
        try:
            if process is not None:
                # Popen still owns/reaps this direct child. Do not leave its
                # zombie to a container init which may not reap adopted children.
                process.kill()
                try:
                    process.wait(timeout=.5)
                except subprocess.TimeoutExpired:
                    pass  # the final group signal remains bounded
            shutil.rmtree(directory, ignore_errors=True)
        finally:
            os.killpg(pid, signal.SIGKILL)


def guard(fd, directory, argv):
    # Normal runtime already uses start_new_session; target_preflight and older
    # callers may inherit their parent's group. Own one BEFORE starting anything.
    if os.getsid(0) != os.getpid():
        os.setsid()
    if os.getpgrp() != os.getpid():
        raise RuntimeError('guardian could not establish a private group')
    process = None
    ended = []
    for sig in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, lambda signum, frame: ended.append(signum))
    try:
        with open(Path(directory) / 'server.log', 'ab', buffering=0) as log:
            if os.environ.get("FLEET_TASK_EXECUTION"):
                from fleet_task_execution import native_command
                argv = native_command(argv, "server")
            process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log,
                                       stderr=log)
        while process.poll() is None and not ended:
            ready, _, _ = select.select([fd], [], [], 0.2)
            if ready and not os.read(fd, 1):
                break
        return 0
    finally:
        os.close(fd)
        stop_private_group(process, directory)


def toml_value(value):
    if isinstance(value, dict):
        return '{' + ','.join(json.dumps(k) + '=' + toml_value(v) for k, v in value.items()) + '}'
    if isinstance(value, list):
        return '[' + ','.join(toml_value(v) for v in value) + ']'
    if isinstance(value, (str, bool, int, float)):
        return json.dumps(value, ensure_ascii=False)
    raise ValueError('unsupported profile value: ' + type(value).__name__)


def server_flags(argv):
    """Forward config to the server: remote TUI forwards only selected keys.

CLI profiles are user-home layers; app-server has no profile flag. Materialise
that layer as overrides, then apply -c flags above it in their original order.
"""
    flags, profile = [], ''
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == '--':
            break
        if arg in ('-c', '--config', '--enable', '--disable', '-p', '--profile'):
            if i + 1 >= len(argv):
                raise ValueError('missing value for ' + arg)
            value = argv[i + 1]
            if arg in ('-p', '--profile'):
                profile = value
            else:
                flags.extend([arg, value])
            i += 2
            continue
        if arg.startswith(('--config=', '--enable=', '--disable=')):
            flags.append(arg)
        elif arg.startswith('--profile='):
            profile = arg.split('=', 1)[1]
        elif arg.startswith('-p') and arg != '-p':
            profile = arg[2:]
        elif arg.startswith('-c') and arg != '-c':
            flags.extend(['-c', arg[2:]])
        elif arg == '--strict-config':
            flags.append(arg)
        i += 1
    if not profile:
        return flags
    if '/' in profile or profile in ('.', '..'):
        raise ValueError('invalid Codex profile name')
    try:
        import tomllib
    except ImportError:
        raise ValueError('Codex profiles with fleet private servers require Python 3.11+') from None
    home = Path(os.environ.get('CODEX_HOME', '~/.codex')).expanduser()
    with (home / (profile + '.config.toml')).open('rb') as stream:
        config = tomllib.load(stream)
    layers = []
    for key, value in config.items():
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]*', key):
            raise ValueError('unsupported top-level Codex profile key')
        layers.extend(['-c', key + '=' + toml_value(value)])
    return layers + flags


# The hook sources the launcher's own table brings (issue #4728): fleet-codex.sh's
# `-c hooks.…` flags and the plugins it loads. A person's own config / project
# hooks keep their review — the fleet never vouches for those.
FLEET_HOOK_SOURCES = ('sessionFlags', 'plugin')


def trust_launch_hooks(remote, cwd, rpc_client=None):
    """Persist trust for the hooks a `--dangerously-bypass-hook-trust` launch
    would run untrusted anyway (issue #4728). Over `--remote` the flag stays in the
    TUI: Codex's protocol has no bypass to hand the server, and a remote RESUME
    stops on «Hooks need review · N hooks are new or changed» with nobody to press
    Enter — the window then holds no thread id for the snapshot to keep. So the
    launcher's own hooks are trusted here, at their current hash, before the TUI
    connects: the same set the flag covers, no wider. Returns how many it wrote."""
    if rpc_client is None:
        rpc_client = runpy.run_path(str(Path(__file__).with_name('fleet-codex-rpc.py')))['Client']
    client = rpc_client(remote, timeout=5)
    try:
        entries = (client.call('hooks/list', {'cwds': [cwd]}) or {}).get('data') or []
        value = {}
        for entry in entries:
            for hook in entry.get('hooks') or []:
                if (hook.get('source') in FLEET_HOOK_SOURCES and not hook.get('isManaged')
                        and hook.get('trustStatus') in ('untrusted', 'modified')
                        and isinstance(hook.get('key'), str) and isinstance(hook.get('currentHash'), str)):
                    value[hook['key']] = {'trusted_hash': hook['currentHash']}
        if value:
            client.call('config/value/write', {'keyPath': 'hooks.state', 'mergeStrategy': 'upsert', 'value': value})
        return len(value)
    finally:
        client.close()


def input_ready(pane):
    """True once the Codex thread in <pane> is up and its `input` stage written
    (fleet_timing.input_once). A parked wake also waits for this native binding,
    including when there is no new-session clock."""
    try:
        out = subprocess.run(['tmux', 'display-message', '-p', '-t', pane, '#{@timing_t0}\t#{@codex_session_id}\t#{@park_start}'],
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             text=True, timeout=5).stdout.rstrip('\n')
    except (OSError, subprocess.SubprocessError):
        return False
    fields = out.split('\t')
    t0, sid, waking = (fields + ['', '', ''])[:3]
    if not t0 and not waking:
        return True
    if not sid:
        return False
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import fleet_timing
        if t0:
            fleet_timing.input_once(pane)
        if waking:
            import fleet_session_gate
            fleet_session_gate.wake_ready(pane)
    except Exception:  # noqa: BLE001 — a clock never costs the session
        pass
    return True


def run(argv, prepare=None, tick=None):
    options = argv[:argv.index('--')] if '--' in argv else argv
    if '--no-daemon' in options:
        # compat-1v: 下一批删 — only a session launched before T560 still carries FLEET_CODEX_SUBSCRIPTION
        if os.environ.get('FLEET_CODEX_SUBSCRIPTION'):
            raise ValueError('a pinned subscription requires the verified private runtime')
        command = ['codex', *argv]
        if os.environ.get('FLEET_TASK_EXECUTION'):
            from fleet_task_execution import native_command
            # This is still the Codex CLI root. Do not label it Claude's agent
            # or invent a private server just to produce a complete exit proof.
            command = native_command(command, 'client')
        return subprocess.call(command)
    if '--worktree' in options:
        raise ValueError('native --worktree requires a local Codex session; '
                         'Fleet private runtime uses --remote and cannot create it. '
                         'Keep the existing Fleet worktree launch until native runtime migration is verified')
    flags = server_flags(argv)
    # macOS AF_UNIX paths are limited to 104 bytes. TMPDIR may itself exceed
    # that; /tmp + a random 0700 directory is short and private on both OSes.
    directory = tempfile.mkdtemp(prefix='fleet-codex-', dir='/tmp')
    remote = 'unix://' + directory + '/worker.sock'
    env = dict(os.environ, FLEET_CODEX_REMOTE=remote)
    env.pop('CODEX_THREAD_ID', None)
    env.pop('CODEX_SESSION_ID', None)
    read_fd, write_fd = os.pipe()
    guardian = client = monitor = follower = None
    ended = []
    old_handlers = {}
    try:
        if prepare:
            prepare(remote, env)
        for sig in (signal.SIGHUP, signal.SIGTERM):
            old_handlers[sig] = signal.signal(sig, lambda signum, frame: ended.append(signum))
        # Ctrl-C belongs to the TUI (interrupt a turn), not this supervisor.
        old_handlers[signal.SIGINT] = signal.signal(signal.SIGINT, signal.SIG_IGN)
        guardian = subprocess.Popen([sys.executable, __file__, '--guard', str(read_fd), directory,
                                     'codex', *flags, 'app-server', '--listen', remote],
                                    env=env, pass_fds=(read_fd,), stdin=subprocess.DEVNULL,
                                    start_new_session=True)
        os.close(read_fd)
        read_fd = -1
        deadline = time.monotonic() + 15
        sock = Path(directory) / 'worker.sock'
        while not sock.exists() and guardian.poll() is None and not ended:
            if time.monotonic() >= deadline:
                raise RuntimeError('private Codex server did not become ready within 15s')
            time.sleep(0.05)
        if ended:
            return 128 + ended[0]
        if guardian.poll() is not None:
            raise RuntimeError('private Codex server exited before creating its socket')
        if os.environ.get("FLEET_CODEX_SUBSCRIPTION"):
            runpy.run_path(str(Path(__file__).with_name(".fleet-account.py")))["verify_codex_runtime"](remote)
        attention = Path(__file__).with_name("fleet-codex-attention.py")
        if attention.is_file():
            monitor = runpy.run_path(str(attention))["Monitor"](remote, env)
        # issue #3461: the live context / model reading for the top line
        meter = follower = None
        meter_mod = Path(__file__).with_name("fleet-codex-session.py")
        if meter_mod.is_file():
            try:
                session_mod = runpy.run_path(str(meter_mod))
                meter = session_mod["Meter"](env)
                # T540: a /clear re-points the window's delivery at once, not at
                # the new thread's first turn.
                follower = session_mod["Follow"](env) if "Follow" in session_mod else None
            except Exception:
                meter = follower = None
        if monitor is not None and meter is not None and env.get('FLEET_CODEX_NATIVE_USAGE') == '1':
            monitor.meter = meter
        # issue #2430: the seed is SUBMITTED — a first sentence left sitting in
        # the composer gets its Enter (bin/fleet-codex-seed.py; reads only).
        seeder = None
        seed_mod = Path(__file__).with_name("fleet-codex-seed.py")
        if seed_mod.is_file():
            try:
                seeder = runpy.run_path(str(seed_mod))["for_launch"](argv)
            except Exception:
                seeder = None
        if '--dangerously-bypass-hook-trust' in options and os.environ.get('FLEET_CODEX_PRETRUST_HOOKS', '1') != '0':
            try:
                trusted = trust_launch_hooks(remote, os.getcwd())
                if trusted:
                    print('fleet-codex-runtime: trusted %d fleet hook(s) for this launch (issue #4728)' % trusted,
                          file=sys.stderr)
            except Exception as exc:
                print('fleet-codex-runtime: could not pre-trust the fleet hooks: ' + str(exc), file=sys.stderr)
        command = ['codex', '--remote', remote, *argv]
        if env.get("FLEET_TASK_EXECUTION"):
            from fleet_task_execution import native_command
            command = native_command(command, "client", env)
        # The same pty owner as Claude: keyboard generation protects drafts and
        # park_exit is submitted only after the gate's native idle proof.
        relay = Path(__file__).with_name('fleet-status-7501.py')
        if (env.get('TMUX') and env.get('TMUX_PANE') and env.get('FLEET_STATUS_7501', '1') != '0'
                and sys.stdin.isatty() and sys.stdout.isatty() and relay.is_file()):
            command = [sys.executable, str(relay), 'relay', '--', *command]
        client = subprocess.Popen(command, env=env)
        next_tick = time.monotonic()
        binding_until = next_tick + 5
        # T716: the new session's clock to 能打字 — the TUI's thread is up (its
        # SessionStart stamped @codex_session_id) ⇒ `input` under @timing_t0, once
        clock_pane = env.get('TMUX_PANE', '') if env.get('TMUX') else ''
        clock_until = time.monotonic() + 120 if clock_pane else 0
        while client.poll() is None and guardian.poll() is None and not ended:
            if clock_until and time.monotonic() < clock_until:
                if input_ready(clock_pane):
                    clock_until = 0
            elif clock_until:
                clock_until = 0
            if time.monotonic() >= next_tick:
                if monitor: monitor.tick()
                if meter is not None: meter.tick()
                if follower is not None: follower.tick()
                if seeder is not None and not seeder.tick():
                    seeder = None
                if tick: tick()
                # A resumed TUI commonly binds just after the first observation.
                # Do not add a whole second to wake confirmation. Only the first
                # five seconds can poll faster; steady idle keeps its 1s cadence.
                binding = follower is not None and not getattr(follower, 'started', True)
                next_tick = time.monotonic() + (.1 if binding and time.monotonic() < binding_until else 1)
            time.sleep(0.1)
        if ended:
            return 128 + ended[0]
        if client.poll() is None:
            raise RuntimeError('private Codex server exited while the TUI was running')
        return client.returncode if client.returncode >= 0 else 128 - client.returncode
    finally:
        if monitor is not None:
            monitor.close()
        if follower is not None:
            follower.close()
        # The TUI shares our process group; signal only its exact child PID.
        if client is not None and client.poll() is None:
            client.terminate()
            try:
                client.wait(timeout=3)
            except subprocess.TimeoutExpired:
                client.kill(); client.wait()
        os.close(write_fd)  # guardian owns server shutdown, even on parent death
        if read_fd >= 0:
            os.close(read_fd)
        if guardian is not None:
            guardian.wait(timeout=8)
        else:
            shutil.rmtree(directory, ignore_errors=True)
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


if __name__ == '__main__':
    try:
        if sys.argv[1:2] == ['target-preflight']:
            print(json.dumps(target_preflight()))
            sys.exit(0)
        if sys.argv[1:2] == ['version-check']:
            rc, line = version_check()
            print(line)
            sys.exit(rc)
        if sys.argv[1:2] == ['--guard']:
            sys.exit(guard(int(sys.argv[2]), sys.argv[3], sys.argv[4:]))
        args = sys.argv[1:]
        if args[:1] == ['--']:
            args = args[1:]
        sys.exit(run(args))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print('fleet-codex-runtime: ' + str(exc), file=sys.stderr)
        sys.exit(1)
