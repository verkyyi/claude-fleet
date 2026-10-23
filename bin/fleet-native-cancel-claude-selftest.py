#!/usr/bin/env python3
# bin-inventory: 人工入口 — opt-in 原生取消探针，docs/dev/AGENT-ADAPTER.md
"""Real Claude mod cancellation, isolated HOME/project/socket, no model execution.

This is a capability probe, not a production cancel endpoint or a whole-Task
stop proof. The second session's durable plan is deliberately not ours to cancel.
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


MODULE = r'''export function register(on) {
  on('session.start', async ($, event, next) => {
    const root = await $.env.get('T970_CANCEL_ROOT');
    const role = await $.env.get('T970_CANCEL_ROLE');
    const session = await $.session.id();
    const receipts = [];
    const ids = [];
    async function save(phase, extra = {}) {
      await $.fs.write(`${root}/${role}.json`, JSON.stringify({phase, session, receipts, ...extra}));
    }
    async function call(input) {
      const result = await $.tool.call(input);
      receipts.push({input, result});
      if (result.isError || result.deny) throw Error(JSON.stringify(result));
      return result.result;
    }
    async function waitFor(name) {
      const deadline = (await $.clock.now()) + 15000;
      while (!(await $.fs.exists(`${root}/${name}`))) {
        if ((await $.clock.now()) >= deadline) throw Error(`fixture timed out: ${name}`);
        await $.clock.sleep(50);
      }
    }
    $.clock.after(500, async () => {
      try {
        if (role === 'other') {
          const job = await call({tool:'CronCreate', cron:'7 1 1 1 *',
            prompt:'T970 OWNED OTHER SESSION NEVER EXECUTE', recurring:false, durable:true});
          ids.push(job.id);
          await save('holding', {plan_id:job.id});
          await waitFor('cleanup-other');
          await call({tool:'CronDelete', id:job.id});
          ids.pop();
          await save('cleaned');
          return;
        }
        await call({tool:'CronList'});
        for (const durable of [false, true]) {
          const job = await call({tool:'CronCreate', cron:'7 1 1 1 *',
            prompt:`T970 OWNED PRIMARY ${durable} NEVER EXECUTE`, recurring:false, durable});
          ids.push(job.id);
        }
        await call({tool:'CronList'});
        for (const id of [...ids]) {
          await call({tool:'CronDelete', id});
          ids.splice(ids.indexOf(id), 1);
        }
        await call({tool:'CronList'});
        const command = await $.fs.read(`${root}/sample-command`);
        const task = await call({tool:'Bash', command,
          description:'T970 owned bounded cancellation sample', run_in_background:true});
        if (!task.backgroundTaskId) throw Error('native Bash returned no background task ID');
        await waitFor('sample-process.json');
        await save('sample-running', {task_id:task.backgroundTaskId});
        await waitFor('release-stop');
        await call({tool:'TaskStop', task_id:task.backgroundTaskId});
        await save('done', {task_id:task.backgroundTaskId});
      } catch (error) {
        await save('failed', {error:String(error)});
      } finally {
        // Only IDs created by this exact fixture session; never CronList-all.
        for (const id of ids) {
          try { await call({tool:'CronDelete', id}); } catch (_) { /* parent removes isolated project */ }
        }
      }
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
    args = parser.parse_args()
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
            sample = root / 'sample.py'
            sample.write_text('import json,os,sys,time\nfrom pathlib import Path\n'
                + 'sys.path.insert(0,' + repr(str(Path(__file__).resolve().parent)) + ')\n'
                + 'from fleet_native_proc import process\n'
                + 'Path(__file__).with_name("sample-process.json").write_text(json.dumps(process(os.getpid())))\n'
                + 'time.sleep(45)\n')
            (root / 'sample-command').write_text(shlex.join([sys.executable, str(sample)]))
            environment = {
                'HOME': str(home), 'CLAUDE_CONFIG_DIR': str(home / '.claude'),
                'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'TERM': 'xterm-256color',
                'TMPDIR': str(root), 'CLAUDE_CODE_TMPDIR': str(root / 'native-tmp'),
                'ANTHROPIC_API_KEY': 'fixture-not-a-credential',
                'ANTHROPIC_BASE_URL': f'http://127.0.0.1:{endpoint.server_port}',
                'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1', 'DISABLE_AUTOUPDATER': '1',
                'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                'T970_CANCEL_ROOT': str(root),
            }
            version = subprocess.check_output([binary, '--version'], env=environment,
                                               text=True, timeout=10).strip()
            check(version == '2.1.295 (Claude Code)', 'probe is pinned to verified Claude 2.1.295')
            socket = root / 'tmux.sock'

            def tm(*argv):
                return subprocess.run(['tmux', '-S', str(socket), *argv], env=environment,
                                      capture_output=True, text=True, timeout=5)

            def start(role):
                command = shlex.join(['env', 'T970_CANCEL_ROLE=' + role, binary,
                    '--setting-sources', '', '--strict-mcp-config', '--plugin-dir', str(plugin),
                    '--debug-file', str(root / (role + '.debug'))])
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

            proof = None
            try:
                start('other')
                other = wait_phase('other', 'holding')
                table = project / '.claude/scheduled_tasks.json'
                original_bytes, original_record = raw_record(table, other['plan_id'])
                check(original_record['createdBySessionId'] == other['session'],
                      'untargeted durable plan belongs to the other actual native session')
                start('primary')
                running = wait_phase('primary', 'sample-running')
                check(running['session'] != other['session'], 'two distinct native session identities')
                proof = json.loads((root / 'sample-process.json').read_text())
                check(same_process(proof), 'background sample really runs before TaskStop')
                check(raw_record(table, other['plan_id'])[0] == original_bytes,
                      'same-project other-session durable plan preserved byte for byte')
                (root / 'release-stop').write_text('stop only the witnessed sample\n')
                result = wait_phase('primary', 'done')
                deadline = time.monotonic() + 3
                while same_process(proof) and time.monotonic() < deadline:
                    time.sleep(.05)
                check(not same_process(proof), 'TaskStop ends the witnessed process before root teardown')
                receipts = result['receipts']
                lists = [r['result']['result']['jobs'] for r in receipts if r['input']['tool'] == 'CronList']
                creates = [r['result']['result']['id'] for r in receipts if r['input']['tool'] == 'CronCreate']
                deletes = [r['input']['id'] for r in receipts if r['input']['tool'] == 'CronDelete']
                check(len(creates) == 2 and deletes == creates, 'only this session-created plan IDs were deleted')
                check({job['id'] for job in lists[1]} == {other['plan_id'], *creates},
                      'native list sees both own plans plus the other session plan')
                check([job['id'] for job in lists[-1]] == [other['plan_id']],
                      'CronDelete removes session-only and durable plans, leaving the other plan')
                check(raw_record(table, other['plan_id'])[0] == original_bytes,
                      'other-session durable bytes remain unchanged after all primary cancellations')
                stop = next(r for r in receipts if r['input']['tool'] == 'TaskStop')
                check(stop['result']['result']['task_id'] == running['task_id']
                      and stop['result']['result']['task_type'] == 'local_bash',
                      'native TaskStop receipt names the exact background task')
                (root / 'cleanup-other').write_text('creator cleans its own fixture plan\n')
                wait_phase('other', 'cleaned')
                check(json.loads(table.read_text())['tasks'] == [], 'fixture creators cleaned every durable plan')
                check(requests == [], 'all native calls execute without any model HTTP request')
                print(json.dumps(dict(version=version, checks=checks, receipts=receipts,
                    model_requests=len(requests), scope='native tools only; no teammate or whole-task stop proof'),
                    ensure_ascii=False, indent=2))
            finally:
                # The socket was created under this fresh, marked directory.
                roots = []
                for pid in tm('list-panes', '-a', '-F', '#{pane_pid}').stdout.splitlines():
                    try:
                        roots.append(process(int(pid)))
                    except (ValueError, OSError, subprocess.SubprocessError):
                        pass
                tm('kill-server')
                if proof is None and (root / 'sample-process.json').exists():
                    proof = json.loads((root / 'sample-process.json').read_text())
                if proof and same_process(proof):
                    os.kill(proof['pid'], signal.SIGKILL)
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
