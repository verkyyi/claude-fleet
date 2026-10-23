#!/usr/bin/env python3
"""Opt-in native cycle peer. JSON-lines stdin/stdout; no production task access.

The Go owner harness supplies only its temporary Hub credential. Native proxy
credentials are minted only by explicit `activate`, retained in memory, revoked
on exit. Default/dry-run never starts tmux, mints, or sends a model request.
"""
import argparse
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from urllib.parse import urlsplit


class Refused(RuntimeError):
    pass


def digest(value):
    return hashlib.sha256(value).hexdigest()


def loopback(value):
    u = urlsplit(value)
    if u.scheme != 'http' or u.hostname != '127.0.0.1' or not u.port or u.username or u.password:
        raise Refused('temporary Hub must use explicit IPv4 loopback HTTP')
    return value.rstrip('/')


def native_turns(rows, expected_input, nonces, fact, text_blocks):
    """Count native turn boundaries, not injected user-role context or mirrors.

    File identity is resolved by fleet_history_read; text decoding is the same
    reader used by transfer snapshots. This probe requires exact delivery and
    final text, preserving duplicate evidence rather than deduplicating it away.
    """
    turns, active = [], None
    for row in rows:
        p = row.get('payload', {})
        kind = p.get('type')
        if row.get('type') == 'event_msg' and kind == 'task_started':
            active = dict(id=p.get('turn_id'), users=[], inputs=[], answers=[], completions=[])
            turns.append(active)
        elif active is not None and row.get('type') == 'response_item' and kind == 'message':
            text = text_blocks(p.get('content', []))
            if p.get('role') == 'user':
                active['inputs'].append(text)
            elif p.get('role') == 'assistant' and p.get('phase') == 'final_answer':
                active['answers'].append(text)
        elif active is not None and row.get('type') == 'event_msg':
            if p.get('turn_id') != active['id']:
                continue
            if kind == 'item_completed' and p.get('item', {}).get('type') == 'UserMessage':
                active['users'].append(text_blocks(p['item'].get('content', [])))
            elif kind == 'user_message':
                active['users'].append(p.get('message', ''))
            elif kind == 'task_complete':
                active['completions'].append(p)
                active = None
    valid = [t for t in turns if t['id'] and expected_input
             and t['users'] == [expected_input] and t['inputs'].count(expected_input) == 1]
    completed = [t for t in valid if len(t['completions']) == 1]
    answers = [a for t in completed for a in t['answers']]
    completion_count = sum(r.get('type') == 'event_msg'
                           and r.get('payload', {}).get('type') == 'task_complete' for r in rows)
    return dict(started_turns=len(turns), user_turns=len(valid),
                completed_turns=completion_count if completed else 0,
                final_answers=len(answers), answer_hashes=[digest(a.encode()) for a in answers],
                nonce_replies={n: sum(a == n + ' FACT=' + fact for a in answers) for n in nonces},
                context_fact_seen=any(a == n + ' FACT=' + fact for n in nonces for a in answers))


class Probe:
    def __init__(self, data):
        self.original = dict(os.environ)
        self.root = Path(data['root']).resolve()
        self.bin = Path(data['bin']).resolve()
        self.live = data.get('live') is True
        self.url = loopback(data['url'])
        self.token = data['token']  # temporary Hub token, never a production token
        self.fleet = str(uuid.UUID(data['fleet']))
        self.socket = 'native-cycle-' + uuid.uuid4().hex[:16]
        self.conf = self.root / 'conf'
        self.home = self.root / 'home'
        self.repo = self.root / 'repo'
        self.codex = self.home / '.codex'
        self.cred = ''
        self.cred_sid = ''
        self.proxy = None
        self.tmux_started = False
        self.tasks = set()
        self.deadline = time.monotonic() + 600
        self.requests = 0
        self.closed = False
        self.lock = threading.Lock()
        if not self.root.is_dir() or any(self.root.iterdir()):
            raise Refused('fixture root must be a new empty directory')
        if not (self.bin / 'fleet_control.py').is_file() or (self.bin.parent / 'fleet.conf').exists():
            raise Refused('use the review worktree bin without installed global fleet.conf')
        for p in (self.conf, self.home, self.codex, self.root / 'tmp', self.root / 'tmux'):
            p.mkdir(parents=True, exist_ok=True)
        self.root.chmod(0o700)
        (self.root / 'native-cycle-owner.json').write_text(json.dumps({'socket': self.socket, 'fleet': self.fleet}))
        self.env = {k: v for k, v in self.original.items() if k in ('PATH', 'LANG', 'LC_ALL', 'USER', 'LOGNAME')}
        self.env.update(HOME=str(self.home), FLEET_CONF_DIR=str(self.conf),
                        TMPDIR=str(self.root / 'tmp'), TMUX_TMPDIR=str(self.root / 'tmux'),
                        PYTHONDONTWRITEBYTECODE='1')
        # Current helper and detached production Control executors share only
        # fixture HOME/config. No inherited TMUX, proxy, account or worker creds.
        os.environ.clear()
        os.environ.update(self.env)
        sys.path.insert(0, str(self.bin))
        from fleet_control import Control
        self.control = Control(self.conf, bin_dir=self.bin)
        self.fleet = self.control.mint(self.socket, 'native/fixture', str(self.repo))
        (self.root / 'native-cycle-owner.json').write_text(json.dumps({'socket': self.socket, 'fleet': self.fleet}))
        self._files()
        self._git('init', '-b', 'main', str(self.repo))
        (self.repo / 'README.md').write_text('Isolated native Task acceptance repository.\n')
        self._git('-C', str(self.repo), 'add', 'README.md')
        self._git('-C', str(self.repo), '-c', 'user.name=Native acceptance',
                  '-c', 'user.email=native-acceptance@example.invalid', 'commit', '-m', 'fixture')
        self.text_blocks = runpy.run_path(str(self.bin / '.fleet-transfer.py'))['text_blocks']
        self.expected_inputs = {}
        self.manifest = dict(socket=self.socket, root=str(self.root), fleet=self.fleet,
                             machine_id=self.control.machine_id, live=False,
                             model_requests=0, claude='blocked_by_known_quota_not_executed')
        self.save()

    def _git(self, *args):
        return subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', *args], env=self.env,
                              capture_output=True, text=True, check=True, timeout=20).stdout.strip()

    def _files(self):
        # Synthetic node credential is only readable in this disposable fixture.
        p = self.conf / 'node.env'
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write('CCQUOTA_HUB_URL=' + shlex.quote(self.url) + '\nCCQUOTA_TOKEN=' + shlex.quote(self.token) + '\n')
        fleetdir = self.conf / 'fleets' / self.socket
        (fleetdir / 'repos').mkdir(parents=True)
        (fleetdir / 'identity').write_text(self.fleet + '\n')
        (fleetdir / 'conf').write_text('FLEET_MAX_SESSIONS=2\nCCQUOTA_FLEET=1\nFLEET_AGENT=codex\n')
        (fleetdir / 'repos' / '.order').write_text('native-fixture\n')
        (fleetdir / 'repos' / 'native-fixture.conf').write_text(
            'FLEET_REPO=native/fixture\nFLEET_MAIN=' + shlex.quote(str(self.repo)) + '\nFLEET_BASE_BRANCH=main\n')
        (self.conf / 'empty-mcp.json').write_text('{"mcpServers":{}}\n')
        # No existing Codex HOME or native auth file is copied or linked.
        (self.conf / 'fleet.conf').write_text(
            'export FLEET_CRED_PROXY=0 FLEET_MCP=0 FLEET_CODEX_SERVER=1\n'
            'export CCQUOTA_HUB_SOCK=off FLEET_CODEX_QUOTA_GATE=1\n'
            'export FLEET_CODEX_HOME=' + shlex.quote(str(self.codex)) + '\n'
            'export FLEET_AGENT_LOCK=warn FLEET_CODEX_MCP_CONFIG=' + shlex.quote(str(self.conf / 'empty-mcp.json')) + '\n'
            'export CCQUOTA_HUB_URL=' + shlex.quote(self.url) + '\n')

    def save(self):
        self.manifest['model_requests'] = self.requests
        (self.root / 'manifest.json').write_text(json.dumps(self.manifest, indent=2) + '\n')

    def check(self):
        if time.monotonic() > self.deadline:
            raise Refused('fixture 600 second deadline reached')

    def activate(self):
        self.check()
        if not self.live or self.original.get('FLEET_NATIVE_TASK_CYCLE') != '1':
            raise Refused('native activation requires explicit opt-in')
        if self.tmux_started or self.proxy:
            raise Refused('activation is one-shot')
        for tool in ('tmux', 'codex', 'git', 'bash', 'curl'):
            if not shutil.which(tool, path=self.env['PATH']):
                raise Refused('required executable unavailable: ' + tool)
        model = self.original.get('FLEET_NATIVE_TASK_MODEL', '')
        if not re.fullmatch(r'[A-Za-z0-9._-]+', model):
            raise Refused('set FLEET_NATIVE_TASK_MODEL explicitly before live activation')
        self.cred_sid = 'native-cycle-' + uuid.uuid4().hex
        self.credential_env = {k: v for k, v in self.original.items() if k not in
                               ('FLEET_WORKER_CRED', 'FLEET_WORKER_ASSERT', 'TMUX', 'TMUX_PANE', 'FLEET_CRED_SID')}
        # Existing mint helper owns account access. Never read auth.json here.
        helper = self.bin / 'fleet-session-cred.sh'
        result = subprocess.run(['bash', str(helper), 'mint', '--provider', 'codex', '--sid', self.cred_sid,
                                 '--codex-home', str(Path(self.original['HOME']) / '.codex')],
                                env=self.credential_env, capture_output=True, text=True, timeout=35)
        if result.returncode:
            raise Refused('native credential mint unavailable (no credential copied; rc=%d)' % result.returncode)
        parts = result.stdout.strip().split('\t')
        if len(parts) != 3 or not parts[1].isdigit() or not parts[2]:
            raise Refused('native credential mint returned invalid transport')
        _, port, self.cred = parts
        outer = self
        class Bridge(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.0'
            def log_message(self, *_):
                pass
            def do_POST(self):
                if self.path not in ('/responses', '/responses/compact'):
                    self.send_error(404); return
                with outer.lock:
                    outer.requests += 1
                    allowed = outer.requests <= 24 and time.monotonic() < outer.deadline
                size = int(self.headers.get('Content-Length', '0'))
                if not allowed or not 0 < size <= 8 * 1024 * 1024:
                    self.send_error(429); return
                body = self.rfile.read(size)
                conn = http.client.HTTPConnection('127.0.0.1', int(port), timeout=90)
                try:
                    # Both credential and request body remain in memory. Only
                    # the supported Responses path reaches the existing proxy.
                    headers = {'Authorization': 'Bearer ' + outer.cred, 'Content-Type': 'application/json'}
                    for name in ('OpenAI-Beta', 'originator', 'session_id', 'x-codex-turn-state'):
                        if self.headers.get(name): headers[name] = self.headers[name]
                    conn.request('POST', '/codex' + self.path, body, headers)
                    response = conn.getresponse()
                    self.send_response(response.status)
                    self.send_header('Content-Type', response.getheader('Content-Type', 'application/json'))
                    self.send_header('Connection', 'close')
                    self.end_headers()
                    while True:
                        chunk = response.read1(65536)
                        if not chunk: break
                        self.wfile.write(chunk); self.wfile.flush()
                except (OSError, http.client.HTTPException):
                    self.close_connection = True
                finally:
                    conn.close()
        self.proxy = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Bridge)
        self.proxy.daemon_threads = True
        threading.Thread(target=self.proxy.serve_forever, daemon=True).start()
        config = ('model = ' + json.dumps(model) + '\nmodel_provider = "cycle"\n'
                  'approval_policy = "never"\nsandbox_mode = "danger-full-access"\n'
                  '[model_providers.cycle]\nname = "isolated acceptance proxy"\nwire_api = "responses"\n'
                  'base_url = "http://127.0.0.1:%d"\nrequires_openai_auth = false\nsupports_websockets = false\n' % self.proxy.server_port)
        (self.codex / 'config.toml').write_text(config)
        self.tmux('new-session', '-d', '-s', self.socket, '-n', 'home', '-c', str(self.home))
        self.tmux_started = True
        self.tmux('set-option', '-g', 'exit-empty', 'off')
        self.tmux('set-option', '-w', '-t', self.socket + ':home', '@fleet_role', 'home')
        self.manifest['live'] = True
        self.save()
        return {'activated': True, 'socket': self.socket}

    def tmux(self, *args):
        return subprocess.run(['tmux', '-L', self.socket, *args], env=self.env, capture_output=True,
                              text=True, check=True, timeout=12).stdout.strip()

    def submit(self, req):
        self.check()
        if not self.tmux_started:
            raise Refused('native peer is not activated')
        if req['fleet_id'] != self.fleet or req['action'] not in ('worker_start', 'worker_stop'):
            raise Refused('only this fixture fleet start/stop is accepted')
        snap = req.get('task_execution', {})
        ref = snap.get('task_ref', '')
        if not re.fullmatch(r'T[1-9][0-9]*', ref) or snap.get('execution_endpoint') != 'ep_native-cycle':
            raise Refused('fixture Task/endpoint mismatch')
        if self.tasks and ref not in self.tasks:
            raise Refused('fixture is limited to one Task')
        if req['action'] == 'worker_start' and req['params'].get('agent') != 'codex':
            raise Refused('Claude quota blocked; this opt-in runner executes Codex only')
        self.tasks.add(ref)
        if req['action'] == 'worker_start' and req['operation_id'] not in self.expected_inputs:
            params = req['params']
            seed = self.control.attached_body(params)
            if params.get('continuation'):
                # Reuse the production read-only plan before native start; do
                # not infer the expected input from the transcript under test.
                from fleet_dispatch import check_current
                from fleet_task_continuation import continuation_plan
                authority = check_current(params.get('dispatch'), execution=snap,
                                          continuation=params['continuation'])
                plan = continuation_plan(snap, params['continuation'], authority, conf_dir=self.conf)
                if plan['seed'] is not None: seed = plan['seed']
            self.expected_inputs[req['operation_id']] = params.get('draft', seed)
            self.manifest['expected_input_hashes'] = {k: digest(v.encode()) for k, v in self.expected_inputs.items()}
            self.save()
        return self.control.submit(req)

    def observe(self, ref):
        self.check()
        if ref not in self.tasks:
            raise Refused('unowned sample')
        snap = self.control.execution.read(ref)
        out = {'snapshot': snap}
        if not snap or not snap['execution_owner']: return out
        fid = snap['execution_owner'].split('/')[1]
        from fleet_history_read import history
        past = history(fid)
        out['history'] = {k: past.get(k) for k in ('sid', 'readable', 'worktree', 'transcript', 'agent')}
        if past.get('readable'):
            path = Path(past['transcript']).resolve()
            if not path.is_relative_to(self.root): raise Refused('native transcript escaped fixture')
            rows = []
            for line in path.read_text().splitlines():
                try: rows.append(json.loads(line))
                except ValueError: continue
            fact = self.manifest.get('fact', '')
            out.update(native_turns(rows, self.expected_inputs.get(snap['operation_id'], ''),
                                    self.manifest.get('nonces', []), fact, self.text_blocks))
            old_path = self.manifest.get('first_transcript', '')
            calls = {r['payload'].get('call_id') for r in rows
                     if r.get('type') == 'response_item'
                     and r.get('payload', {}).get('type') in ('function_call', 'custom_tool_call')
                     and old_path and old_path in json.dumps(r['payload'].get('arguments', r['payload'].get('input', '')))}
            outputs = [r.get('payload', {}) for r in rows if r.get('type') == 'response_item'
                       and r.get('payload', {}).get('type') in ('function_call_output', 'custom_tool_call_output')
                       and r['payload'].get('call_id') in calls]
            first_nonce = self.manifest.get('nonces', [''])[0]
            confirmed = []
            for item in outputs:
                value = item.get('output', '')
                text = value if isinstance(value, str) else json.dumps(value)
                # Match the actual call_id and successful tool result containing
                # the first turn's private markers. A path in argv or the final
                # answer alone is not proof that history was read successfully.
                successful = re.search(r'"exit_code"\s*:\s*0|Process exited with code 0|Exit code: 0', text)
                if successful and first_nonce and fact and first_nonce in text and fact in text:
                    confirmed.append(digest(text.encode()))
            out['exact_history_read_confirmed'] = bool(confirmed)
            out['history_read_output_hashes'] = confirmed
        with self.control.store.connect() as db:
            components = db.execute('SELECT component FROM task_execution_native WHERE task_ref=?', (ref,)).fetchall()
            out['components'] = sorted(r[0] for r in components)
        return out

    def sentinel(self, ref, first):
        observed = self.observe(ref)
        past = observed['history']
        if not past.get('readable'): raise Refused('real native history not recorded')
        wt = Path(past['worktree']).resolve()
        if not wt.is_relative_to(self.root) or wt == self.repo:
            raise Refused('workspace is not an isolated worktree')
        gd = self._git('-C', str(wt), 'rev-parse', '--absolute-git-dir')
        if first:
            self.manifest.update(first_worktree=str(wt), first_gitdir=gd,
                                 first_transcript=past['transcript'], first_sid=past['sid'])
            (wt / 'user-uncommitted.txt').write_text('untouched user file ' + uuid.uuid4().hex + '\n')
            self.manifest['sentinel_hash'] = digest((wt / 'user-uncommitted.txt').read_bytes())
            (wt / 'acceptance-next.txt').write_text(
                'Read the exact previous native transcript named by your continuation seed. '
                'Recall the private FACT from its first user message. Do not modify any files. '
                'Your final answer must be exactly: ' + self.manifest['nonces'][1] + ' FACT=<the recalled fact>.\n')
            self.manifest['git_diff_hash'] = digest(self._git('-C', str(wt), 'status', '--porcelain=v1').encode())
            self.save()
        return {'workspace_preserved': str(wt) == self.manifest['first_worktree'] and gd == self.manifest['first_gitdir'],
                'sentinel_preserved': digest((wt / 'user-uncommitted.txt').read_bytes()) == self.manifest['sentinel_hash'],
                'git_status_preserved': digest(self._git('-C', str(wt), 'status', '--porcelain=v1').encode()) == self.manifest['git_diff_hash'],
                'old_history_preserved': first or digest(Path(self.manifest['first_transcript']).read_bytes()) == self.manifest.get('first_transcript_hash')}

    def receipt(self, op):
        with self.control.store.connect() as db:
            row = db.execute('SELECT result FROM operations WHERE id=?', (op,)).fetchone()
        r = json.loads(row[0] or '{}').get('native_exit_receipt', {}) if row else {}
        if r.get('confirmed') and self.manifest.get('first_transcript') and not self.manifest.get('first_transcript_hash'):
            self.manifest['first_transcript_hash'] = digest(Path(self.manifest['first_transcript']).read_bytes())
            self.save()
        return dict(confirmed=r.get('confirmed', False), operation_id=r.get('operation_id'),
                    payload_hash=digest(json.dumps(r.get('payload'), sort_keys=True, separators=(',', ':')).encode()) if r.get('payload') else None)

    def close(self):
        if self.closed:
            return {'closed': True, 'fixture_forced_cleanup': self.manifest.get('fixture_forced_cleanup', False)}
        self.closed = True
        forced, cleanup_errors = False, []
        # Normal owner stop precedes this. Every fallback is recorded; never
        # fabricate a receipt, release a binding, or erase retained evidence.
        try:
            for ref in self.tasks:
                try:
                    snapshot = self.control.execution.read(ref)
                    stop = snapshot.get('cancel_request', '') if snapshot else ''
                    deadline = time.monotonic() + 30
                    while stop and time.monotonic() < deadline:
                        receipt = self.receipt(stop)
                        if receipt['confirmed']: break
                        if receipt['payload_hash']:
                            from fleet_control import Control
                            Control(self.conf, bin_dir=self.bin).submit_native_exit(stop)
                        time.sleep(.2)
                    forced = forced or not stop or not self.receipt(stop)['confirmed']
                    from fleet_task_execution import terminate_registered, _definitely_exited
                    registration = self.control.execution.launch(ref)
                    terminate_registered(self.control.execution, ref)
                    if registration:
                        proofs = [n['process'] for n in registration['native']]
                        if registration.get('child'): proofs.append(registration['child'])
                        for proof in proofs:
                            if not _definitely_exited(proof):
                                cleanup_errors.append('registered native root exit unconfirmed')
                except Exception as exc:
                    cleanup_errors.append(type(exc).__name__)
            if self.tmux_started:
                try:
                    marker = json.loads((self.root / 'native-cycle-owner.json').read_text())
                    if marker != {'socket': self.socket, 'fleet': self.fleet}:
                        raise Refused('isolated socket ownership marker changed')
                    rows = self.tmux('list-windows', '-t', '=' + self.socket, '-F', '#{@fleet_role}').splitlines()
                    forced = forced or any(r not in ('home', 'panel') for r in rows)
                    self.tmux('kill-server')  # exact fixture socket, never live Fleet
                except Exception as exc:
                    cleanup_errors.append(type(exc).__name__)
        finally:
            if self.proxy:
                self.proxy.shutdown(); self.proxy.server_close()
            if self.cred_sid:
                try:
                    result = subprocess.run(['bash', str(self.bin / 'fleet-session-cred.sh'), 'revoke', '--sid', self.cred_sid],
                                            env=self.credential_env, capture_output=True, timeout=20)
                    if result.returncode: cleanup_errors.append('credential revocation refused')
                except Exception as exc:
                    cleanup_errors.append('credential revocation ' + type(exc).__name__)
            self.cred = ''
            # The disposable Hub token expires with its server. Remove its file
            # before retaining the fixture evidence/workspace.
            (self.conf / 'node.env').unlink(missing_ok=True)
            self.manifest.update(fixture_forced_cleanup=forced, cleanup_errors=cleanup_errors,
                                 closed=not cleanup_errors)
            self.save()
        return {'closed': not cleanup_errors, 'fixture_forced_cleanup': forced, 'cleanup_errors': cleanup_errors}

    def call(self, data):
        action = data['action']
        if action == 'activate': return self.activate()
        if action == 'submit': return self.submit(data['request'])
        if action == 'operation': return self.control.get_operation(data['id'])
        if action == 'observe': return self.observe(data['task'])
        if action == 'sentinel': return self.sentinel(data['task'], data.get('first', False))
        if action == 'receipt': return self.receipt(data['id'])
        if action == 'retry':
            # New Control instance models helper recreation; production retries
            # the saved packet, not stop or proof generation.
            from fleet_control import Control
            return {'sent': Control(self.conf, bin_dir=self.bin).submit_native_exit(data['id'])}
        if action == 'old':
            from fleet_task_execution import read_session
            old = read_session(data['fid'], conf_dir=self.conf)
            return {'old_stopped': old['cancel_request'] == data['stop']}
        if action == 'seed':
            self.manifest.update(nonces=data['nonces'], fact=data['fact'])
            self.save()
            return {'seeded': True}
        if action == 'close': return self.close()
        raise Refused('unknown fixture action')



def pane_read(data):
    """Real isolated tmux reader, never a Coding Agent launch or credential mint."""
    data['live'] = False
    p = Probe(data)
    try:
        p.tmux('new-session', '-d', '-s', p.socket, '-n', 'home', '-c', str(p.home))
        p.tmux_started = True
        p.tmux('set-option', '-g', 'exit-empty', 'off')
        p.tmux('set-option', '-w', '-t', p.socket + ':home', '@fleet_role', 'home')
        conf = p.conf / 'fleets' / p.socket / 'conf'
        enabled = conf.read_text()
        answers = []
        for hub_on in (False, True):
            conf.write_text(enabled if hub_on else enabled.replace('CCQUOTA_FLEET=1', 'CCQUOTA_FLEET=0'))
            output = p.root / ('pane-start-%d.json' % hub_on)
            status = p.root / ('pane-status-%d.txt' % hub_on)
            command = shlex.join(['bash', str(p.bin / 'fleet-task-record.sh'), 'execution-start', data['task']])
            script = command + ' > ' + shlex.quote(str(output)) + ' 2>/dev/null; printf "%s" "$?" > ' + shlex.quote(str(status))
            p.tmux('new-window', '-d', '-t', p.socket, '-n', 'reader', 'bash', '-c', script)
            deadline = time.monotonic() + 12
            while not status.exists() and time.monotonic() < deadline:
                time.sleep(.025)
            if not status.exists(): raise Refused('isolated pane read deadline')
            code = int(status.read_text())
            if not hub_on:
                if code != 3: raise Refused('disabled fixture Hub did not reproduce pane refusal')
                answers.append({'hub_enabled': False, 'read_exit': 3})
            else:
                if code != 0: raise Refused('enabled fixture Hub still refused authenticated pane read')
                authority = json.loads(output.read_text())
                if authority['start']['operation_id'] != data['operation_id']:
                    raise Refused('pane read returned a different immutable start')
                answers.append({'hub_enabled': True, 'read_exit': 0, 'same_start': True})
            # Wait for the short reader shell to exit, not just its status write.
            deadline = time.monotonic() + 2
            while 'reader' in p.tmux('list-windows', '-t', '=' + p.socket, '-F', '#{window_name}').splitlines() and time.monotonic() < deadline:
                time.sleep(.025)
        return {'pane_reads': answers, 'model_requests': p.requests, 'credentials_minted': bool(p.cred_sid)}
    finally:
        result = p.close()
        if not result['closed'] or result['fixture_forced_cleanup']:
            raise Refused('isolated pane cleanup not confirmed')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--pane-read', action='store_true')
    args = parser.parse_args()
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    if args.pane_read:
        print(json.dumps(pane_read(json.load(sys.stdin))))
        return
    if args.dry_run:
        # No credential discovery or mint and no tmux/native process in dry-run.
        with tempfile.TemporaryDirectory(prefix='native-cycle-dry-') as root:
            p = Probe(dict(root=root, bin=str(Path(__file__).resolve().parents[4] / 'bin'),
                           url='http://127.0.0.1:9', token='synthetic-dry-token', fleet=str(uuid.uuid4())))
            assert not (p.codex / 'auth.json').exists()
            assert not p.tmux_started and not p.cred_sid and p.requests == 0
            assert (p.conf / 'node.env').stat().st_mode & 0o077 == 0
            assert p.control.inventory()[0]['fleet_id'] == p.fleet
            print(json.dumps({'dry_run': True, 'model_requests': 0, 'tmux_started': False,
                              'credentials_minted': False, 'real_control_inventory': True}))
        return
    p = None
    timer = None
    try:
        data = json.loads(sys.stdin.readline())
        p = Probe(data)
        timer = threading.Timer(600, lambda: os.kill(os.getpid(), signal.SIGTERM))
        timer.daemon = True
        timer.start()
        print(json.dumps({'ok': True, 'result': p.manifest}), flush=True)
        for line in sys.stdin:
            try:
                request = json.loads(line)
                result = p.call(request)
                print(json.dumps({'ok': True, 'result': result}), flush=True)
                if request['action'] == 'close': p = None; break
            except Exception as exc:
                # Never forward raw provider/HTTP stderr or credential-bearing
                # requests. Known local refusals are static, other errors typed.
                message = str(exc) if isinstance(exc, Refused) else type(exc).__name__
                print(json.dumps({'ok': False, 'error': message}), flush=True)
    finally:
        if timer: timer.cancel()
        if p: p.close()


if __name__ == '__main__':
    main()
