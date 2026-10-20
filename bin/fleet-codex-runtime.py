#!/usr/bin/env python3
"""Run a Codex TUI and its own local app-server with one bounded lifetime.

The guardian owns the server and reads a pipe held ONLY by the supervisor.
EOF, including a SIGKILLed supervisor, tears down the server. A shell EXIT trap
alone cannot provide that guarantee. No shared daemon or TCP port is used.
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
# is verified against (docs/dev/CODEX-RUNTIME.md#context). The rollout is an upstream
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


def stop(process):
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def guard(fd, directory, argv):
    process = None
    ended = []
    for sig in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, lambda signum, frame: ended.append(signum))
    try:
        with open(Path(directory) / 'server.log', 'ab', buffering=0) as log:
            process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log,
                                       stderr=log, start_new_session=True)
        while process.poll() is None and not ended:
            ready, _, _ = select.select([fd], [], [], 0.2)
            if ready and not os.read(fd, 1):
                break
        return 0
    finally:
        stop(process)
        os.close(fd)
        shutil.rmtree(directory, ignore_errors=True)


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


class LaunchWitness:
    """Write an accepted launch's receipt off this runtime's own server (T485).

    Codex 0.162's app-server runs SessionStart only when the first turn starts,
    while fleet_launch.py holds the task's first turn until a receipt exists:
    waiting for the hook was a deadlock (every task-bound Codex start gave up
    after 45 s, «no matching process/native-session receipt»). The server is
    private to this TUI, so its one loaded root thread IS the TUI's session and
    the socket's kernel peer IS the native process; fleet_launch.witness_codex
    applies the hook's own checks to them. A later SessionStart hook finds the
    same pid + session and leaves the receipt alone."""

    def __init__(self, remote, rpc_client=None, launch=None):
        self.remote = remote
        self.rpc_client = rpc_client or runpy.run_path(str(Path(__file__).with_name('fleet-codex-rpc.py')))['Client']
        if launch is None:
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            import fleet_launch as launch
        self.launch = launch
        self.error = ''
        # fleet_launch.py stops waiting after 45 s; past that nobody reads it.
        self.deadline = time.monotonic() + 60

    def tick(self):
        """False once the receipt is written or too late (stop ticking); True to try again."""
        if time.monotonic() > self.deadline:
            return False
        try:
            client = self.rpc_client(self.remote, timeout=3)
            try:
                peer = client.peer_pid()
                roots = []
                for thread_id in (client.call('thread/loaded/list', {}) or {}).get('data') or []:
                    thread = (client.call('thread/read', {'threadId': thread_id}) or {}).get('thread') or {}
                    if thread.get('id') == thread_id and not thread.get('parentThreadId') and not thread.get('ephemeral'):
                        roots.append(thread)
            finally:
                client.close()
            if len(roots) != 1:
                return True  # the TUI has not started its thread yet (or it is not one thread)
            self.launch.witness_codex(peer, {'hook_event_name': 'SessionStart', 'session_id': roots[0]['id'],
                                             'cwd': roots[0].get('cwd', '')}, self.remote)
            return False
        except Exception as exc:
            self.error = str(exc)
            return True


def run(argv, prepare=None, tick=None):
    options = argv[:argv.index('--')] if '--' in argv else argv
    if '--no-daemon' in options:
        if os.environ.get('FLEET_CODEX_SUBSCRIPTION'):
            raise ValueError('a pinned subscription requires the verified private runtime')
        return subprocess.call(['codex', *argv])
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
        witness = None
        if env.get('FLEET_LAUNCH_CONTEXT'):
            try:
                witness = LaunchWitness(remote)
            except Exception as exc:
                # The SessionStart hook stays the receipt's only road then.
                print('fleet-codex-runtime: launch witness unavailable: ' + str(exc), file=sys.stderr)
        client = subprocess.Popen(['codex', '--remote', remote, *argv], env=env)
        next_tick = time.monotonic()
        while client.poll() is None and guardian.poll() is None and not ended:
            if time.monotonic() >= next_tick:
                if monitor: monitor.tick()
                if meter is not None: meter.tick()
                if follower is not None: follower.tick()
                if seeder is not None and not seeder.tick():
                    seeder = None
                if witness is not None and not witness.tick():
                    witness = None
                if tick: tick()
                next_tick = time.monotonic() + 1
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
