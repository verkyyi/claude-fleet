#!/usr/bin/env python3
"""Deterministic process fixtures; no account, network or live fleet writes."""
import copy
import os
from pathlib import Path
import runpy
import shlex
import shutil
import signal
import time
import uuid
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import json

sys.dont_write_bytecode = True
BIN = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(BIN))
LIB = runpy.run_path(str(BIN / 'fleet_worker_life.py'))


class CodexBusy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='codex-busy-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.server = self.root / 'mcp.py'
        self.server.touch()
        self.remote = 'unix://' + str(self.root / 'native.sock')
        self.source = dict(agent='codex', pid=101, session_id='native-sid',
                           worktree=str(self.root), transcript=str(self.root / 'rollout.jsonl'),
                           home=str(self.root), codex_identity=dict(owner='101', session_id='native-sid',
                           home=str(self.root), remote=self.remote))
        self.rows = {101: (1, 'bash'), 102: (101, 'codex'), 103: (102, 'python')}
        self.argv = {101: ['bash', str(BIN / 'fleet-codex.sh')],
                     102: ['codex', 'app-server', '--listen', self.remote],
                     103: [sys.executable, str(self.server)]}
        self.exes = {101: Path('/bin/bash'), 102: Path('/release/codex'),
                     103: Path(sys.executable).resolve()}
        self.config = {'service': dict(command=sys.executable, args=[str(self.server)])}
        test = self

        class Client:
            def __init__(self, remote, **kw): test.assertEqual(remote, test.remote)
            def close(self): pass
            def call(self, method, params):
                if method == 'config/read': return {'config': {'mcp_servers': test.config}}
                if method == 'mcpServerStatus/list':
                    return {'data': [{'name': 'service', 'runtimeStatus': 'ready'}]}
                raise AssertionError(method)

        for p in (patch.dict(LIB['TRANSFER'], process_rows=lambda: self.rows),
                  patch.dict(LIB['ARGV'], process_argv=lambda pid: self.argv[pid],
                             process_executable=lambda pid: self.exes[pid]),
                  patch.dict(LIB['quiet_processes'].__globals__, RPC=Client)):
            p.start(); self.addCleanup(p.stop)

    def busy(self):
        result = []
        LIB['quiet_processes'](self.source, background=result, strict=False)
        return result

    def test_idle_persistent_mcp_is_not_work(self):
        self.assertEqual(self.busy(), [])

    def managed_github(self):
        self.config['service'] = dict(command='bash', args=[
            '-lc', 'exec "$HOME/.claude/fleet/bin/mcp-github.sh"'])
        package = self.root / 'node_modules/@modelcontextprotocol/server-github'
        package.mkdir(parents=True)
        entry = package / 'index.js'
        entry.touch()
        (package / 'package.json').write_text(json.dumps(dict(
            name='@modelcontextprotocol/server-github', bin={'server-github': 'index.js'})))
        self.rows[103] = (102, 'server-github')
        self.argv[103] = ['npm exec @modelcontextprotocol/server-github']
        self.exes[103] = Path('/release/node')
        self.rows[104] = (103, 'node')
        self.argv[104] = ['/release/node', str(entry)]
        self.exes[104] = Path('/release/node')

    def test_managed_github_wrapper_resident_is_not_work(self):
        self.managed_github()
        self.assertEqual(self.busy(), [])
        self.rows[105] = (104, 'bash')
        self.argv[105] = ['/bin/bash', '-c', 'real tool job']
        self.exes[105] = Path('/bin/bash')
        self.assertEqual(self.busy(), [105])

    def test_managed_wrapper_does_not_guess_changed_config_or_package(self):
        self.managed_github()
        self.config['service']['args'][1] += ' --other'
        self.assertEqual(self.busy(), [103, 104])
        self.config['service']['args'][1] = 'exec "$HOME/.claude/fleet/bin/mcp-github.sh"'
        self.argv[104].append('--other')
        self.assertEqual(self.busy(), [103, 104])

    def test_managed_wrapper_keeps_strict_unknown_and_ambiguous_gates(self):
        self.managed_github()
        mcp = LIB['MCP']
        readers = (lambda pid: self.argv[pid], lambda pid: self.exes[pid])
        status = {'service': {'runtimeStatus': 'ready'}}
        args = (self.source, (self.config, status), self.rows, 102, *readers)
        # A busy-service identity must not grant a restartability proof.
        self.assertEqual(mcp['classify'](*args, strict=True), set())
        status['service']['runtimeStatus'] = 'starting'
        self.assertEqual(mcp['classify'](*args, strict=False), set())
        status['service']['runtimeStatus'] = 'ready'
        self.config['duplicate'] = dict(self.config['service'])
        self.assertEqual(self.busy(), [103, 104])

    def test_managed_fetch_wrapper_resident_is_not_work(self):
        self.config['service'] = dict(command='bash', args=[
            '-lc', 'exec "$HOME/.claude/fleet/bin/mcp-fetch.sh"'])
        runner = self.root / 'uvx'
        runner.touch()
        uv = self.root / 'uv'
        uv.touch()
        self.rows[103] = (102, 'uv')
        self.argv[103] = [str(uv), 'tool', 'uvx', 'mcp-server-fetch']
        self.exes[103] = uv.resolve()
        env = (self.root / 'env').resolve()
        (env / 'bin').mkdir(parents=True)
        (env / 'pyvenv.cfg').touch()
        py = env / 'bin/python'
        py.touch()
        entry = env / 'bin/mcp-server-fetch'
        entry.touch()
        self.rows[104] = (103, 'python')
        self.argv[104] = [str(py), str(entry)]
        self.exes[104] = py.resolve()
        with patch('shutil.which', return_value=str(runner)):
            self.assertEqual(self.busy(), [])
            self.rows[105] = (104, 'python')
            self.argv[105] = [str(py), '-c', 'real job']
            self.exes[105] = py.resolve()
            self.assertEqual(self.busy(), [105])

    def test_app_server_can_be_the_bound_root(self):
        self.source['pid'] = 102
        self.source['codex_identity']['owner'] = '102'
        self.assertEqual(self.busy(), [])

    def test_mcp_job_is_still_work(self):
        self.rows[104] = (103, 'python')
        self.argv[104] = [sys.executable, '-c', 'background job']
        self.exes[104] = Path(sys.executable).resolve()
        self.assertEqual(self.busy(), [104])

    def test_same_named_unconfigured_service_is_work(self):
        self.argv[103].append('--different')
        self.assertEqual(self.busy(), [103])

    def test_macos_python_framework_launcher(self):
        # python3 re-execs Python.app on macOS; the service argv is unchanged.
        self.config['service']['command'] = 'python3'
        self.exes[103] = Path('/framework/Resources/Python.app/Contents/MacOS/Python')
        self.argv[103][0] = str(self.exes[103])
        self.assertEqual(self.busy(), [])
        self.argv[103].append('--job')
        self.assertEqual(self.busy(), [103])

    def test_bundled_helper_and_its_jobs(self):
        # Linux comm truncates the bundled executable's name to 15 bytes.
        self.rows[104] = (102, 'codex-code-mode')
        self.argv[104] = ['/release/codex-code-mode-host']
        self.exes[104] = Path('/release/codex-code-mode-host')
        self.assertEqual(self.busy(), [])
        self.rows[105] = (104, 'bash')
        self.argv[105] = ['/bin/bash', '-c', 'background job']
        self.exes[105] = Path('/bin/bash')
        self.assertEqual(self.busy(), [105])
        self.exes[104] = Path('/other/codex-code-mode-host')
        self.assertIn(104, self.busy())

    def test_bg_unknown_retains_codex(self):
        # Exercise the actual shell consumer: rc 2 is NOT an idle verdict.
        script = '''. "$1/fleet-lib.sh"
_fleet_tmux() { printf 'codex\\n'; }
python3() { return 2; }
fleet_window_bg_busy fleet @1 1 1
'''
        r = subprocess.run(['bash', '-c', script, '_', str(BIN)], capture_output=True,
                           env=dict(os.environ, FLEET_SKIP_GLOBAL_CONF='1',
                                    FLEET_CONF_DIR=str(self.root), TMUX='isolated,1,0'))
        self.assertEqual(r.returncode, 0, r.stderr.decode())

    def test_park_relay_is_infrastructure_but_its_jobs_are_work(self):
        self.argv[101] = ['/bin/bash', str(BIN / 'fleet-codex.sh')]
        self.rows[110] = (101, 'python')
        self.argv[110] = [sys.executable, str(BIN / 'fleet-codex-runtime.py'), '--']
        relay = [sys.executable, str(BIN / 'fleet-status-7501.py'), 'relay', '--',
                 '/release/codex', '--remote', self.remote]
        self.rows[111] = (110, 'python'); self.argv[111] = relay
        self.rows[112] = (111, 'python'); self.argv[112] = relay  # relay's pty guardian
        self.rows[113] = (112, 'codex'); self.argv[113] = relay[4:]
        self.assertEqual(self.busy(), [])
        self.rows[114] = (112, 'python'); self.argv[114] = [sys.executable, '-c', 'job']
        self.assertEqual(self.busy(), [114])
        self.argv[111] = relay[:1] + ['/other/fleet-status-7501.py'] + relay[2:]
        self.assertIn(111, self.busy())
        self.argv[111] = relay[:-1] + ['unix:///another.sock']
        self.assertIn(111, self.busy())

    def test_managed_home_worker_can_reach_native_busy_probe(self):
        worker = LIB['Worker']
        # A normal no-repo worker deliberately has no @issue or @raw. inspect()
        # still validates its lifelong identity and physical HOME afterwards.
        for norepo in ('1', ''):
            with patch.object(worker, 'tm', side_effect=['@2|test', '%2', '0|||scratch-2', norepo]), \
                    patch.dict(worker.__init__.__globals__, root=lambda session: self.root):
                if norepo:
                    self.assertEqual(worker('test', '@2').pane, '%2')
                else:
                    with self.assertRaisesRegex(ValueError, 'not an issue'):
                        worker('test', '@2')


class NativeBusy(CodexBusy):
    def setUp(self):
        super().setUp()
        import fleet_native_proc
        self.process = dict(pid=101, ppid=1, birth='birth-1', executable='/bin/bash')
        self.thread = dict(id='native-sid', cwd=str(self.root), path=self.source['transcript'],
                           status={'type': 'idle'}, turns=[dict(id='turn-1', status='completed', items=[])])
        self.goal = None
        self.loaded = ['native-sid']
        self.worker = Mock(session='isolated', pane='%1')
        self.worker.inspect.side_effect = lambda: copy.deepcopy(self.source)
        self.worker.opt.return_value = ''
        self.reads = 0
        self.change = lambda: None
        owner = self
        old_client = LIB['quiet_processes'].__globals__['RPC']

        class Client(old_client):
            def call(self, method, params):
                if method == 'thread/read':
                    owner.reads += 1
                    if owner.reads == 2: owner.change()
                    return {'thread': copy.deepcopy(owner.thread)}
                if method == 'thread/goal/get': return {'goal': owner.goal}
                if method == 'thread/loaded/list': return {'data': owner.loaded}
                return super().call(method, params)

        for p in (patch.object(fleet_native_proc, 'process', side_effect=lambda pid: dict(self.process)),
                  patch.dict(LIB['child_busy'].__globals__, Worker=lambda *a: self.worker, RPC=Client)):
            p.start(); self.addCleanup(p.stop)

    def native_busy(self):
        return LIB['child_busy']('isolated', '@1', reap=True)

    def test_native_idle_is_rechecked(self):
        self.assertEqual(self.native_busy(), [])
        self.assertEqual(self.reads, 2)

    def test_settled_interrupted_turn_can_be_idle_without_success(self):
        for status in ('interrupted', 'failed'):
            with self.subTest(status=status):
                self.reads = 0
                self.thread['turns'][-1]['status'] = status
                self.assertEqual(self.native_busy(), [])
                self.assertEqual(self.reads, 2)
                self.assertEqual(self.thread['turns'][-1]['status'], status)

    def test_interrupted_turn_keeps_work_and_unknown_proofs(self):
        self.thread['turns'][-1]['status'] = 'interrupted'
        self.goal = {'status': 'active'}
        with self.assertRaisesRegex(ValueError, 'goal'): self.native_busy()
        self.goal = None
        self.thread['turns'][-1]['items'] = [dict(type='mcpToolCall', status='inProgress')]
        with self.assertRaisesRegex(ValueError, 'tool'): self.native_busy()
        self.thread['turns'][-1]['items'] = []
        for status in ('inProgress', 'unknown', None):
            self.thread['turns'][-1]['status'] = status
            with self.assertRaisesRegex(ValueError, 'settled'): self.native_busy()

    def test_stop_checks_jobs_before_native_turn_completes(self):
        self.thread['status']['type'] = 'active'
        self.assertEqual(LIB['child_busy']('isolated', '@1'), [])
        self.assertEqual(self.reads, 0)
        self.rows[104] = (103, 'python')
        self.argv[104] = [sys.executable, '-c', 'background job']
        self.exes[104] = Path(sys.executable).resolve()
        self.assertEqual(LIB['child_busy']('isolated', '@1'), [104])

    def test_active_turn_and_in_process_mcp_call_retain(self):
        for state in ('active', 'unknown', 'systemError'):
            self.thread['status']['type'] = state
            with self.assertRaisesRegex(ValueError, 'natively idle'): self.native_busy()
        self.thread['status']['type'] = 'idle'
        self.thread['turns'][-1]['items'] = [dict(type='mcpToolCall', status='inProgress')]
        with self.assertRaisesRegex(ValueError, 'tool'): self.native_busy()

    def test_unfinished_goal_or_subagent_retains(self):
        self.goal = {'status': 'active'}
        with self.assertRaisesRegex(ValueError, 'goal'): self.native_busy()
        self.goal = None
        self.loaded.append('child-sid')
        self.thread['status']['type'] = 'active'
        with self.assertRaises(ValueError): self.native_busy()

    def test_missing_stale_or_replaced_identity_retains(self):
        for key in ('owner', 'remote', 'session_id', 'home'):
            old = self.source['codex_identity'].pop(key)
            with self.assertRaisesRegex(ValueError, 'binding'): self.native_busy()
            self.source['codex_identity'][key] = old
        self.worker.inspect.side_effect = [copy.deepcopy(self.source), dict(self.source, pid=999)]
        with self.assertRaisesRegex(ValueError, 'binding'): self.native_busy()

    def test_pid_reuse_and_turn_change_retain(self):
        # Change during the process walk; even the same PID cannot waive birth.
        original = LIB['quiet_processes']
        def walk(*a, **kw):
            original(*a, **kw)
            self.process['birth'] = 'birth-2'
        with patch.dict(LIB['child_busy'].__globals__, quiet_processes=walk):
            with self.assertRaisesRegex(ValueError, 'binding changed'): self.native_busy()
        self.reads = 0
        self.change = lambda: self.thread['turns'][-1].update(id='turn-2')
        with self.assertRaisesRegex(ValueError, 'turn changed'): self.native_busy()

    def test_rpc_disconnect_is_unknown(self):
        class Broken:
            def __init__(self, *a, **kw): raise OSError('disconnected')
        with patch.dict(LIB['child_busy'].__globals__, RPC=Broken):
            with self.assertRaises(OSError): self.native_busy()

    def test_unloaded_history_is_not_current_native_idle(self):
        self.loaded = []
        with self.assertRaisesRegex(ValueError, 'no longer loaded'): self.native_busy()

    def test_native_history_must_match_the_worker(self):
        self.thread['path'] = str(self.root / 'another.jsonl')
        with self.assertRaisesRegex(ValueError, 'history'): self.native_busy()


def fixture(mode, record):
    """Real bounded process tree; only the native protocol is deterministic."""
    path = Path(record)
    if mode in ('agent', 'native', 'service'):
        child = None
        def stop(*_):
            if child is not None:
                child.terminate()
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()
            raise SystemExit(0)
        signal.signal(signal.SIGHUP, stop)
        signal.signal(signal.SIGTERM, stop)
        if mode != 'service':
            next_mode = 'native' if mode == 'agent' else 'service'
            child = subprocess.Popen([sys.executable, __file__, str(BIN), '--fixture', next_mode, record])
        (path.parent / (mode + '.pid')).write_text(str(os.getpid()))
        try: time.sleep(120)
        finally: stop()
        return
    # Entry used ONLY by the isolated test's fleet_worker_life.py. Process identity,
    # helper argv, shell/reap/children gates and disposal remain production code.
    rec = json.loads(path.read_text())
    native = int((path.parent / 'native.pid').read_text())
    root = int((path.parent / 'agent.pid').read_text())
    original_rows = LIB['TRANSFER']['process_rows']
    original_argv = LIB['ARGV']['process_argv']
    def rows():
        result = original_rows()
        result[native] = (root, 'codex')
        return result
    def argv(pid):
        return ['codex', 'app-server', '--listen', rec['remote']] if pid == native else original_argv(pid)
    def inspect(worker):
        identity = LIB['CODEX']['identity'](worker.pane, worker.session)
        if not identity: raise ValueError('missing fixture native identity')
        return dict(agent='codex', pid=root, session_id=rec['sid'], home=str(path.parent),
                    worktree=str(path.parent), transcript=str(path.parent / 'rollout.jsonl'),
                    codex_identity=identity)
    class Client:
        def __init__(self, remote, **kw):
            if remote != rec['remote']: raise ValueError('foreign endpoint')
        def close(self): pass
        def call(self, method, params):
            state = json.loads(path.read_text())
            if method == 'thread/read':
                return {'thread': dict(id=rec['sid'], cwd=str(path.parent), path=str(path.parent / 'rollout.jsonl'),
                        status={'type': state['state']}, turns=[dict(id='turn-1', status='completed', items=[])])}
            if method == 'thread/goal/get': return {'goal': None}
            if method == 'thread/loaded/list': return {'data': [rec['sid']]}
            if method == 'config/read':
                return {'config': {'mcp_servers': {'fixture': dict(command='python3',
                    args=[__file__, str(BIN), '--fixture', 'service', record])}}}
            if method == 'mcpServerStatus/list': return {'data': [{'name': 'fixture', 'runtimeStatus': 'ready'}]}
            raise ValueError('unexpected RPC: ' + method)
    LIB['TRANSFER']['process_rows'] = rows
    LIB['ARGV']['process_argv'] = argv
    LIB['Worker'].inspect = inspect
    LIB['child_busy'].__globals__['RPC'] = Client
    sys.argv = ['fleet_worker_life.py', *sys.argv[4:]]
    return LIB['main']()


@unittest.skipUnless(shutil.which('tmux'), 'tmux unavailable')
class ReapIntegration(unittest.TestCase):
    def test_persistent_idle_reaps_and_releases_parent(self):
        with tempfile.TemporaryDirectory(prefix='codex-reap-') as tmp:
            root = Path(tmp)
            socket = 'codex-reap-' + str(os.getpid())
            env = dict(os.environ, HOME=str(root), FLEET_CONF_DIR=str(root / 'conf'),
                       FLEET_SKIP_GLOBAL_CONF='1', FLEET_SESSION=socket, FLEET_REAP_MIN_AGE='0',
                       CCQUOTA_FLEET='0', FLEET_FORGE='none', FLEET_MAIN='', FLEET_REPO='')
            env.pop('TMUX', None); env.pop('TMUX_PANE', None)
            def tm(*args):
                return subprocess.check_output(['tmux', '-L', socket, *args], env=env,
                                               text=True, stderr=subprocess.DEVNULL).strip()
            def stamp(w, key, value): tm('set-option', '-w', '-t', w, key, str(value))
            # One private socket and HOME; closing it cannot reach a fleet.
            tm('-f', '/dev/null', 'new-session', '-d', '-s', socket, '-n', 'scratch-1', 'sleep 120')
            parent = tm('display-message', '-p', '-t', socket, '#{window_id}')
            try:
                conf = root / 'conf' / 'fleets' / socket
                conf.mkdir(parents=True)
                (conf / 'conf').write_text('FLEET_FORGE=none\n')
                testbin = root / 'bin'; testbin.mkdir()
                for f in BIN.iterdir():
                    if f.is_file() and f.name != 'fleet_worker_life.py': (testbin / f.name).symlink_to(f)
                wrapper = ('import runpy,sys\nsys.argv=[' + repr(__file__) + ',' + repr(str(BIN))
                           + ',"--fixture","probe",' + repr(str(root / 'native.json'))
                           + ']+sys.argv[1:]\nrunpy.run_path(' + repr(__file__) + ',run_name="__main__")\n')
                (testbin / 'fleet_worker_life.py').write_text(wrapper)
                command = shlex.join([sys.executable, __file__, str(BIN), '--fixture', 'agent', str(root / 'native.json')])
                child = tm('new-window', '-d', '-P', '-F', '#{window_id}', '-t', socket, '-n', 'scratch-2', command)
                pane = tm('display-message', '-p', '-t', child, '#{pane_id}')
                deadline = time.monotonic() + 5
                while not (root / 'service.pid').exists():
                    self.assertLess(time.monotonic(), deadline, 'fixture did not start')
                    time.sleep(.03)
                owner = (root / 'agent.pid').read_text()
                rec = dict(sid=str(uuid.uuid4()), remote='unix://' + str(root / 'native.sock'), state='idle')
                (root / 'native.json').write_text(json.dumps(rec))
                identity = dict(owner=owner, session_id=rec['sid'], remote=rec['remote'], home=str(root))
                for win, name in ((parent, 'scratch-1'), (child, 'scratch-2')):
                    for key, value in {'@raw': 1, '@fleet_role': 'worker', '@claude_state': 'done',
                                       '@worktree': str(root / name), '@wid': name}.items(): stamp(win, key, value)
                for key, value in {'@cc_agent': 'codex', '@cc_launcher_pid': owner,
                                   '@codex_identity': json.dumps(identity), '@origin': 'scratch-1'}.items(): stamp(child, key, value)
                env['TMUX'] = tm('display-message', '-p', '-t', pane, '#{socket_path}') + ',1,0'
                env['TMUX_PANE'] = pane
                def reap():
                    return subprocess.run(['bash', str(testbin / 'dash-reap.sh'), child, '--yes'],
                                          capture_output=True, text=True, env=env, timeout=30)
                def why(target):
                    r = subprocess.run([sys.executable, str(testbin / 'fleet-reap-live.py'), target],
                                       capture_output=True, text=True, env=env, timeout=30)
                    return r.stdout + r.stderr
                stamp(child, '@claude_state', 'working')
                self.assertNotIn('retained:children', why(parent))  # old @origin is not native work
                stamp(child, '@claude_state', 'done')
                stamp(child, '@loop', 'kind=wakeup next=%d ttl=600' % (time.time() + 600))
                self.assertIn('retained:loop', why(child))
                stamp(child, '@loop', '')
                rec['state'] = 'active'; (root / 'native.json').write_text(json.dumps(rec))
                r = reap(); self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
                self.assertIn('retained:bg', r.stderr)
                rec['state'] = 'idle'; (root / 'native.json').write_text(json.dumps(rec))
                stamp(child, '@codex_identity', '')
                self.assertIn('retained:bg', why(child))
                stamp(child, '@codex_identity', json.dumps(identity))
                probe = subprocess.run([sys.executable, str(testbin / 'fleet_worker_life.py'), 'busy',
                                        '--session', socket, '--reap', child], capture_output=True, text=True, env=env)
                if probe.returncode != 1:
                    ids = {n: (root / (n + '.pid')).read_text() for n in ('agent', 'native', 'service')}
                    args = LIB['ARGV']['process_argv'](int(ids['service']))
                    self.fail(str(ids) + repr(args) + probe.stdout + probe.stderr)
                r = reap(); self.assertEqual((r.returncode, r.stdout.strip()), (0, 'reaped:full'), r.stderr)
                self.assertNotIn('retained:children', why(parent))
                self.assertNotIn(child, tm('list-windows', '-t', socket, '-F', '#{window_id}').splitlines())
            finally:
                subprocess.run(['tmux', '-L', socket, 'kill-server'], env=env, stderr=subprocess.DEVNULL)
                for name in ('agent', 'native', 'service'):
                    try: os.kill(int((root / (name + '.pid')).read_text()), signal.SIGTERM)
                    except (FileNotFoundError, ProcessLookupError): pass


if __name__ == '__main__':
    if sys.argv[1:2] == ['--fixture']:
        sys.exit(fixture(sys.argv[2], sys.argv[3]))
    unittest.main()
