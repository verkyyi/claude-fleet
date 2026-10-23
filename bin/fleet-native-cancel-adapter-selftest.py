#!/usr/bin/env python3
# bin-inventory: 人工入口 — opt-in 原生取消适配器验证，docs/dev/AGENT-ADAPTER.md
"""Opt-in real native.cancel inbox test; isolated HOME/project/socket, no model.

Uses the production mod and verifier. Default mode seeds a stopped fixture fence;
--stop-order uses the real supervisor, --stop-race adds concurrent executors.
Neither mode proves termination of independent teammates or the whole Task.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

from fleet_native_proc import process
from fleet_task_execution import ExecutionFence


MODULE = r'''export function register(on) {
  on('session.start', async ($, event, next) => {
    const root = await $.env.get('T970_CANCEL_ROOT');
    const role = await $.env.get('T970_CANCEL_ROLE');
    const session = await $.session.id();
    if (role === 'primary' && await $.env.get('T970_STOP_ORDER') === '1') {
      const pane = await $.env.get('TMUX_PANE');
      for (const [key,value] of [['@fleet_id','66666666-6666-4666-8666-666666666666'],
          ['@task','T970'],['@cc_agent','claude'],['@cc_session_id',session]]) {
        await $.process.run(['tmux','set-option','-w','-t',pane,key,value], {timeoutMs:500});
      }
    }
    async function save(phase, extra = {}) {
      await $.fs.write(`${root}/${role}.json`, JSON.stringify({phase, session, ...extra}));
    }
    $.clock.after(500, async () => {
      try {
        const result = await $.tool.call({tool:'CronCreate', cron:'7 1 1 1 *',
          prompt:`T970 ADAPTER ${role} NEVER EXECUTE`, recurring:false, durable:true});
        if (result.isError || result.deny) throw Error('fixture create failed');
        await save('holding', {plan_id:result.result.id});
        const limit = await $.clock.now() + 30000;
        while (!(await $.fs.exists(`${root}/cleanup-${role}`))) {
          if (await $.clock.now() > limit) throw Error('fixture cleanup timed out');
          await $.clock.sleep(50);
        }
        if (role === 'other') await $.tool.call({tool:'CronDelete', id:result.result.id});
        await save('cleaned');
      } catch (error) { await save('failed', {error:String(error)}); }
    });
    return next(event);
  });
}'''


def raw_record(path, identifier):
    """Return the original JSON object's bytes, not a reserialized equivalent."""
    text = path.read_text()
    offset = text.index('[', text.index('"tasks"')) + 1
    decoder = json.JSONDecoder()
    while True:
        while text[offset] in ' \n\r\t,':
            offset += 1
        if text[offset] == ']':
            raise AssertionError('expected native plan disappeared')
        row, length = decoder.raw_decode(text[offset:])
        if row.get('id') == identifier:
            return text[offset:offset + length].encode(), row
        offset += length


def same_process(proof):
    try:
        current = process(proof['pid'])
        return current['birth'] == proof['birth'] and current['executable'] == proof['executable']
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--claude', default='claude')
    parser.add_argument('--stop-order', action='store_true', help='exercise real supervisor cancel-before-signal')
    parser.add_argument('--stop-race', action='store_true', help='race two executors against the real supervisor')
    args = parser.parse_args()
    args.stop_order = args.stop_order or args.stop_race
    executable = shutil.which(args.claude)
    if not executable or not shutil.which('tmux'):
        parser.error('native Claude and tmux are required')
    for managed in (Path('/Library/Application Support/ClaudeCode'), Path('/etc/claude-code')):
        if managed.exists():
            parser.error('fixture requires a host without machine-managed Claude configuration')
    binary = str(Path(executable).resolve())
    requests, checks = [], []

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            requests.append(self.path)  # no headers, payloads, or credentials
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"type":"error","error":{"type":"invalid_request_error","message":"no model in cancellation fixture"}}')

        def log_message(self, *unused):
            pass

    endpoint = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Endpoint)
    serving = threading.Thread(target=endpoint.serve_forever, daemon=True)
    serving.start()

    def check(condition, description):
        if not condition:
            raise AssertionError(description)
        checks.append(description)

    try:
        with tempfile.TemporaryDirectory(prefix='t970-native-cancel-', dir='/tmp') as temporary:
            root = Path(temporary).resolve()
            (root / 'OWNED-BY-T970').write_text('isolated native cancellation fixture\n')
            home, project, plugin = root / 'home', root / 'project', root / 'plugin'
            for directory in (home / '.claude', project, plugin / '.claude-plugin', plugin / 'hooks'):
                directory.mkdir(parents=True)
            (plugin / '.claude-plugin/plugin.json').write_text(json.dumps(
                dict(name='t970-native-cancel-fixture', version='0.1.0')))
            (plugin / 'hooks/hooks.json').write_text(json.dumps(dict(modules=['./register.js'])))
            (plugin / 'hooks/register.js').write_text(MODULE)
            # This trust/config belongs only to the newly created fixture HOME.
            (home / '.claude/.claude.json').write_text(json.dumps({
                'hasCompletedOnboarding': True, 'theme': 'dark',
                'customApiKeyResponses': {'approved': ['fixture-not-a-credential'[-20:]]},
                'projects': {str(project): {'hasTrustDialogAccepted': True,
                                           'hasCompletedProjectOnboarding': True}}}))
            environment = {
                'HOME': str(home), 'CLAUDE_CONFIG_DIR': str(home / '.claude'),
                'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'TERM': 'xterm-256color',
                'TMPDIR': str(root), 'CLAUDE_CODE_TMPDIR': str(root / 'native-tmp'),
                'ANTHROPIC_API_KEY': 'fixture-not-a-credential',
                'ANTHROPIC_BASE_URL': f'http://127.0.0.1:{endpoint.server_port}',
                'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1', 'DISABLE_AUTOUPDATER': '1',
                'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                'T970_CANCEL_ROOT': str(root), 'FLEET_CONF_DIR': str(root / 'conf'),
                'FLEET_MCP_SERVER': '1', 'T970_STOP_ORDER': '1' if args.stop_order else '0',
            }
            version = subprocess.check_output([binary, '--version'], env=environment,
                                               text=True, timeout=10).strip()
            check(version == '2.1.295 (Claude Code)', 'probe is pinned to verified Claude 2.1.295')
            socket = root / 'tmux.sock'

            def tm(*argv):
                return subprocess.run(['tmux', '-S', str(socket), *argv], env=environment,
                                      capture_output=True, text=True, timeout=5)

            grant = dict(task_ref='T970', task_fid='44444444-4444-4444-8444-444444444444',
                generation=1, binding_generation=1, attempt_id='task:T970:g1', operation_id='start-fixture',
                execution_endpoint='fixture', execution_owner='55555555-5555-4555-8555-555555555555/'
                + '66666666-6666-4666-8666-666666666666', cancel_request='')
            fence = ExecutionFence(root / 'conf')
            fence.bind(grant, authorized=True)
            fixture_bin = root/'bin'
            if args.stop_order:
                fixture_bin.mkdir()
                for name in ('fleet_task_execution.py','fleet_native_stop.py','fleet_native_cancel.py',
                             'fleet_native_proc.py','fleet_hub_common.py','fleet_task_exit_submit.py'):
                    shutil.copy2(Path(__file__).parent/name,fixture_bin/name)
                (root/'authority.json').write_text(json.dumps(grant))
                (fixture_bin/'fleet-task-record.sh').write_text('if [ "$1" = execution-list ]; then\nprintf \'{"control_version":1,"task_executions":[\'\ncat "$T970_CANCEL_ROOT/authority.json"\nprintf \']}\\n\'\nelse cat "$T970_CANCEL_ROOT/authority.json"; fi\n')

            def start(role):
                native_command = [binary,
                    '--setting-sources', '', '--strict-mcp-config', '--plugin-dir', str(plugin),
                    '--plugin-dir', str(Path(__file__).resolve().parent.parent / 'mod/fleet'),
                    '--debug-file', str(root / (role + '.debug'))]
                if args.stop_order and role == 'primary':
                    native_command = [sys.executable,str(fixture_bin/'fleet_task_execution.py'),
                        'run','--snapshot',json.dumps(grant),'--',sys.executable,
                        str(fixture_bin/'fleet_task_execution.py'),'native','--component','agent','--',*native_command]
                command = shlex.join(['env','T970_CANCEL_ROLE='+role,*native_command])
                if role == 'other':
                    result = tm('-f', '/dev/null', 'new-session', '-d', '-s', 'fixture',
                                '-n', role, '-x', '120', '-y', '32', '-c', str(project), command)
                else:
                    result = tm('new-window', '-d', '-t', 'fixture:', '-n', role,
                                '-c', str(project), command)
                check(result.returncode == 0, 'started isolated ' + role + ' session')

            def wait_phase(role, phase):
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    try:
                        data = json.loads((root / (role + '.json')).read_text())
                        if data['phase'] == 'failed':
                            raise AssertionError(json.dumps(data))
                        if data['phase'] == phase:
                            return data
                    except (FileNotFoundError, json.JSONDecodeError):
                        pass
                    time.sleep(.05)
                screen = tm('capture-pane', '-p', '-t', 'fixture:' + role).stdout
                raise AssertionError(role + ' did not reach ' + phase + ': ' + screen[-4000:])

            contenders = []
            try:
                start('other')
                other = wait_phase('other', 'holding')
                table = project / '.claude/scheduled_tasks.json'
                original_bytes, original_record = raw_record(table, other['plan_id'])
                check(original_record['createdBySessionId'] == other['session'],
                      'untargeted durable plan belongs to the other actual native session')
                start('primary')
                primary = wait_phase('primary', 'holding')
                own_record = raw_record(table, primary['plan_id'])[1]
                check(primary['session'] != other['session'], 'two actual native session identities')
                native = process(own_record['createdByPid'])
                launch = '33333333-3333-4333-8333-333333333333'
                if args.stop_order:
                    launch = fence.launch('T970')['launch_id']
                else:
                    with fence.admission(grant) as permit:
                        permit.reserve_launch(launch, native)
                        permit.register_child(launch, native)
                        permit.register_native(launch, 'agent', native)
                stopped = dict(grant, generation=2, cancel_request='stop-fixture')
                stop_started = time.monotonic()
                fence.apply_stop(stopped)
                pane = tm('display-message', '-p', '-t', 'fixture:primary', '#{pane_id}').stdout.strip()
                inbox = root / 'conf/global/mod-inbox' / socket.name / pane[1:]
                inbox.mkdir(parents=True, exist_ok=True)
                if args.stop_race:
                    contender_env = dict(environment, PYTHONPATH=str(Path(__file__).resolve().parent),
                                         TMUX=str(socket)+',0,0', TMUX_PANE=pane)
                    for _ in range(2):
                        contenders.append(subprocess.Popen([sys.executable,'-c',
                            'from fleet_task_execution import ExecutionFence,terminate_registered; '
                            'terminate_registered(ExecutionFence(),"T970")'],env=contender_env))
                def cancel(ids, nonce):
                    slot = inbox / 'native-cancel.json'
                    done = inbox / 'native-cancel.done'
                    done.unlink(missing_ok=True)
                    request = dict(cancel='native.cancel.v1', nonce=nonce * 32, execution=stopped,
                        launch_id=launch, session_id=primary['session'], deadline=time.time() + 2.9,
                        cron_ids=ids)
                    pending = inbox / '.cancel.tmp'
                    pending.write_text(json.dumps(request))
                    pending.replace(slot)
                    until = time.monotonic() + 5
                    while time.monotonic() < until:
                        try:
                            result = json.loads(done.read_text())
                            if result.get('nonce') == request['nonce']:
                                return result
                        except (FileNotFoundError, json.JSONDecodeError):
                            pass
                        time.sleep(.02)
                    raise AssertionError('no cancel receipt: ' + tm('capture-pane', '-p', '-t', 'fixture:primary').stdout)
                if args.stop_order:
                    until = time.monotonic()+4
                    while same_process(native) and time.monotonic()<until:
                        time.sleep(.025)
                    check(not same_process(native), 'actual supervisor/executor ended exact native root')
                    for contender in contenders:
                        check(contender.wait(timeout=2) == 0, 'concurrent executor completed the same bounded stop')
                    check(time.monotonic()-stop_started < 3.6, 'shared stop deadline bounds native root exit')
                    ids = [job['id'] for job in json.loads(table.read_text())['tasks']]
                    check(primary['plan_id'] not in ids, 'actual supervisor cancelled own durable plan before root exit')
                    check(raw_record(table,other['plan_id'])[0] == original_bytes,
                          'other native session durable plan survives supervised stop byte for byte')
                    owned = json.loads((inbox/'native-cancel.done').read_text())
                    check(owned.get('state') == 'observed_absent', 'actual production mod confirmed absence before signal')
                    foreign = {'scope':'native_durable_plans','state':'untargeted'}
                    (root/'cleanup-other').touch()
                    wait_phase('other','cleaned')
                else:
                    foreign = cancel([other['plan_id']], 'a')
                    check(foreign['state'] == 'refused', 'real verifier refuses another session plan in same project')
                    check(raw_record(table, other['plan_id'])[0] == original_bytes,
                          'foreign plan preserved after refused cancellation')
                    owned = cancel([primary['plan_id']], 'b')
                    check(owned['state'] == 'observed_absent', 'production inbox/verifier/native tools confirm own plan absent: ' + str(owned))
                    check(owned['cancelled_ids'] == [primary['plan_id']], 'receipt covers only the exact requested plan')
                    check(raw_record(table, other['plan_id'])[0] == original_bytes,
                          'same-project foreign plan preserved byte for byte after own cancellation')
                    check(same_process(native), 'native root still alive: this is plan cancellation, not a root-exit proof')
                    for role in ('other', 'primary'):
                        (root / ('cleanup-' + role)).write_text('creator cleans fixture plan\n')
                        wait_phase(role, 'cleaned')
                check(json.loads(table.read_text())['tasks'] == [], 'fixture creators cleaned every durable plan')
                check(requests == [], 'no model HTTP requests')
                print(json.dumps(dict(version=version, checks=checks, receipts=[foreign, owned],
                    model_requests=len(requests), scope='native durable plans only'), ensure_ascii=False, indent=2))
            finally:
                for contender in contenders:
                    if contender.poll() is None:
                        contender.kill()
                    contender.wait(timeout=2)
                # The socket was created under this fresh, marked directory.
                roots = []
                for pid in tm('list-panes', '-a', '-F', '#{pane_pid}').stdout.splitlines():
                    try:
                        roots.append(process(int(pid)))
                    except (ValueError, OSError, subprocess.SubprocessError):
                        pass
                tm('kill-server')
                deadline = time.monotonic() + 3
                while any(same_process(p) for p in roots) and time.monotonic() < deadline:
                    time.sleep(.05)
                for native in roots:
                    if same_process(native):
                        os.kill(native['pid'], signal.SIGKILL)
    finally:
        endpoint.shutdown()
        endpoint.server_close()
        serving.join(timeout=2)


if __name__ == '__main__':
    main()
