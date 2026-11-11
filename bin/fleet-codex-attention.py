#!/usr/bin/env python3
"""Native Codex attention signals and exact pending-request replies.

thread/read is read-only. A metadata-only resume rejoins an already-loaded
thread to replay its outstanding server requests; no new thread/turn is started.
Responses require the same launcher, thread and request fingerprint shown to the
operator, and are confirmed by serverRequest/resolved. No TUI keystrokes.
"""
import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import subprocess
import sys
import time

BIN = Path(__file__).absolute().parent
session = runpy.run_path(str(BIN / 'fleet-codex-session.py'))
Client = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client']
needs_detail = runpy.run_path(str(BIN / 'fleet_needs_detail.py'))['detail']
QUESTION = 'item/tool/requestUserInput'
PERMISSIONS = {'item/commandExecution/requestApproval', 'item/fileChange/requestApproval', 'item/permissions/requestApproval', 'mcpServer/elicitation/request'}
TELEMETRY_OPT_OUT = ('item/agentMessage/delta', 'item/reasoning/textDelta', 'item/reasoning/summaryTextDelta',
                     'item/commandExecution/outputDelta', 'item/fileChange/outputDelta', 'item/plan/delta',
                     'item/started', 'item/completed', 'turn/diff/updated', 'turn/plan/updated',
                     'hook/started', 'hook/completed', 'rawResponseItem/completed')


def kind(thread):
    status = thread.get('status', {})
    if status.get('type') != 'active': return ''
    flags = status.get('activeFlags', [])
    if 'waitingOnApproval' in flags: return 'perm'
    if 'waitingOnUserInput' in flags: return 'ask'
    return ''


def thread_read(client, data, include_turns=False):
    thread = client.call('thread/read', {'threadId': data['session_id'], 'includeTurns': include_turns})['thread']
    if thread.get('id') != data['session_id']: raise ValueError('native thread identity changed')
    return thread


def fingerprint(data, request):
    return hashlib.sha256(json.dumps([data['owner'], data['session_id'], request], sort_keys=True).encode()).hexdigest()


def current(data, pane, socket):
    now = session['identity'](pane, socket)
    keys = ('owner', 'session_id', 'home', 'remote')
    if any(now.get(k) != data.get(k) for k in keys): raise ValueError('launcher or thread changed; refresh the request')


class Pending:
    def __init__(self, data, category='ask', token=''):
        self.data = data
        self.client = Client(data.get('remote', ''), timeout=3)
        try:
            thread = thread_read(self.client, data)
            if thread.get('status', {}).get('type') not in ('active', 'idle'):
                raise ValueError('thread is not loaded; refusing to resume an old session')
            params = {'threadId': data['session_id'], 'excludeTurns': True}
            if data.get('transcript'): params['path'] = data['transcript']
            resumed = self.client.call('thread/resume', params)
            if resumed['thread']['id'] != data['session_id']: raise ValueError('resumed thread changed')
            self.request = None
            self.client.deadline = time.monotonic() + 3
            while self.request is None:
                event = self.client.events.pop(0) if self.client.events else self.client.receive()
                if 'id' not in event or event.get('params', {}).get('threadId') != data['session_id']: continue
                method = event.get('method')
                if method not in PERMISSIONS | {QUESTION}: continue
                if (category == 'ask' and method != QUESTION) or (category == 'perm' and method not in PERMISSIONS): continue
                if token and fingerprint(data, event) != token: continue
                self.request = event
            self.token = fingerprint(data, self.request)
        except Exception:
            self.client.close()
            raise

    def close(self): self.client.close()

    def show(self):
        params = self.request['params']
        return dict(agent='codex', request_token=self.token, method=self.request['method'],
                    tool_use_id=str(self.request['id']), questions=params.get('questions', []), request=params)

    def respond(self, result, pane, socket):
        current(self.data, pane, socket)
        # Round trip flushes any request-resolved notifications before submission.
        thread_read(self.client, self.data)
        for event in self.client.events:
            if self.resolved(event): raise ValueError('request was already resolved; nothing sent')
        self.client.send({'id': self.request['id'], 'result': result})
        self.client.deadline = time.monotonic() + 5
        while True:
            event = self.client.events.pop(0) if self.client.events else self.client.receive()
            if self.resolved(event):
                print('Codex confirmed request resolution.')
                return

    def resolved(self, event):
        p = event.get('params', {})
        return (event.get('method') == 'serverRequest/resolved' and p.get('threadId') == self.data['session_id']
                and p.get('requestId') == self.request['id'])


def request_detail(data, subtype):
    """What the pending request asks, in its own words (issue #1951): the
    request_user_input question, an approval's command — the one rule
    (fleet_needs_detail.py) Claude's needs use too. '' when it cannot be read: a
    missing detail never costs the state."""
    try:
        pending = Pending(data, subtype)
    except Exception:
        return ''
    try:
        req = pending.request or {}
        params = req.get('params') or {}
        tool = '' if req.get('method') == QUESTION else {
            'item/commandExecution/requestApproval': 'Bash', 'item/fileChange/requestApproval': 'Edit',
            'mcpServer/elicitation/request': 'MCP'}.get(req.get('method'), 'Permission')
        return needs_detail(tool, params)
    except Exception:
        return ''
    finally:
        pending.close()


def answers(request, picks):
    qs = request['params'].get('questions', [])
    if len(qs) != len(picks): raise ValueError('provide one answer per question')
    result = {}
    for q, pick in zip(qs, picks):
        if not isinstance(q.get('id'), str) or q['id'] in result: raise ValueError('invalid question identities')
        if pick.startswith('text:'):
            if q.get('options') and not q.get('isOther'): raise ValueError('this question does not allow a free-text answer')
            value = pick[5:]
        else:
            try: idx = int(pick)
            except ValueError: raise ValueError('use an option number or text:ANSWER') from None
            options = q.get('options') or []
            if not 1 <= idx <= len(options): raise ValueError('option number out of range')
            value = options[idx-1]['label']
        if not value: raise ValueError('empty answer')
        result[q['id']] = {'answers': [value]}
    return {'answers': result}


def display(text):
    return re.sub(r'[\x00-\x08\x0b-\x1f\x7f]', '', str(text))


def popup(data, pane, socket):
    pending = Pending(data, 'any')
    try:
        if pending.request['method'] != QUESTION:
            print('Codex needs permission or an MCP response. Review in the worker pane.\n')
            print(display(json.dumps(pending.request['params'], ensure_ascii=False, indent=2)))
            input('\nPress Enter to close. ')
            return
        picks = []
        for q in pending.request['params']['questions']:
            options = q.get('options') or []
            if options:
                rows = ['%s\t%s — %s' % (i, display(o['label']), display(o.get('description', ''))) for i, o in enumerate(options, 1)]
                if q.get('isOther'): rows.append('text\tEnter another answer')
                proc = subprocess.run(['fzf', '--delimiter=\t', '--with-nth=2..', '--no-multi', '--no-sort', '--height=100%',
                                       '--header', display(q['question']) + '\nEsc closes without answering.', '--prompt', 'Codex answer ▸ '],
                                      input='\n'.join(rows), capture_output=True, text=True)
                if proc.returncode: return
                pick = proc.stdout.strip().split('\t', 1)[0]
            else: pick = 'text'
            if pick == 'text':
                reader = getpass.getpass if q.get('isSecret') else input
                pick = 'text:' + reader(display(q['question']) + '\n> ')
            picks.append(pick)
        pending.respond(answers(pending.request, picks), pane, socket)
    finally:
        pending.close()


def _env_secs(name, default):
    try:
        return max(1.0, float(os.environ.get(name, '') or default))
    except ValueError:
        return float(default)


def idle_after():
    """Seconds a session sits done (no question) before the monitor slows."""
    return _env_secs('FLEET_CODEX_ATTENTION_IDLE_AFTER', 300)


def idle_secs():
    """The monitor's interval for such a long-idle session (2 s otherwise)."""
    return _env_secs('FLEET_CODEX_ATTENTION_IDLE_SECS', 6)


# A failed turn (T1392). Codex has no StopFailure hook: a turn the provider
# failed (`■ unexpected status 409 …`, a 5xx, a cut stream) leaves the TUI at its
# prompt while the row kept reading «working» — once for two days. The monitor
# reads the settled failed turn's TurnError, shows it as needs/error with its
# words, and for a TRANSIENT kind books one «carry on» over the session's own
# inbox after a backoff (the Claude half is fleet-stream-resume.sh, #4714).
RETRY_INFO = {'internalServerError', 'serverOverloaded', 'httpConnectionFailed',
              'responseStreamConnectionFailed', 'responseStreamDisconnected',
              'responseTooManyFailedAttempts'}
FINAL_INFO = {'contextWindowExceeded', 'usageLimitExceeded', 'unauthorized', 'badRequest',
              'sandboxError', 'threadRollbackFailed'}
TRANSIENT_WORDS = re.compile(r'stream disconnected|connection (?:reset|closed|lost|refused)|'
                             r'timed out|timeout|overloaded|server error|bad gateway|service unavailable', re.I)
SECRET = re.compile(r'(?i)(bearer\s+|sk-[a-z0-9_-]*|(?:token|key|secret|password)["\'=: ]+)[A-Za-z0-9._~+/=-]{8,}')
RESUME_TEXT = ('Your last turn failed with an upstream error ({why}) before it finished. '
               'Continue the task from where it stopped — re-check anything that may not have completed.')


def error_summary(message):
    """The error's first line, one row's worth: no control bytes, no credential."""
    line = next((l.strip() for l in str(message or '').splitlines() if l.strip()), '')
    line = SECRET.sub(lambda m: m.group(1) + '…', re.sub(r'[\x00-\x1f\x7f]', ' ', line))
    return line[:157] + '…' if len(line) > 160 else line


def turn_error(turn):
    """(summary, retryable) of a failed Turn's TurnError {message, codexErrorInfo}.
    Retryable: a cut stream / connection, a 5xx, a 408/409 (the credential proxy's
    continuation refusal). Never a quota (429, usageLimitExceeded), auth, budget
    (403) or a request the provider refused as such."""
    err = turn.get('error') if isinstance(turn.get('error'), dict) else {}
    message = str(err.get('message') or '')
    info, status = err.get('codexErrorInfo'), None
    if isinstance(info, dict) and len(info) == 1:
        info, body = next(iter(info.items()))
        if isinstance(body, dict) and isinstance(body.get('httpStatusCode'), int):
            status = body['httpStatusCode']
    found = re.search(r'\bstatus (\d{3})\b', message)
    if status is None and found:
        status = int(found.group(1))
    if info in FINAL_INFO:
        retry = False
    elif status is not None:
        retry = status in (408, 409) or 500 <= status <= 599
    elif info in RETRY_INFO:
        retry = True
    else:
        retry = bool(TRANSIENT_WORDS.search(message))
    return error_summary(message) or (str(info) if isinstance(info, str) else '') or 'turn failed', retry


def _env_int(name, default):
    try:
        return max(0, int(os.environ.get(name, '') or default))
    except ValueError:
        return default


def retry_log(pane, text):
    d = Path(os.environ.get('FLEET_CONF_DIR') or os.path.expanduser('~/.config/claude-fleet')) / 'logs'
    try:
        d.mkdir(parents=True, exist_ok=True)
        with open(d / 'codex-turn-retry.log', 'a') as fh:
            fh.write('%s %s %s\n' % (time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), pane, text))
    except OSError:
        pass


def resume_send(pane, text):
    """The session's own inbox (fleet-peer-send.sh %<pane> — the one delivery road,
    held and replayed when the server cannot take it), detached from the tick."""
    cmd = os.environ.get('FLEET_CODEX_TURN_RETRY_SEND_CMD')
    argv = shlex.split(cmd) + [pane, text] if cmd else ['bash', str(BIN / 'fleet-peer-send.sh'), pane, text]
    subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


class Monitor:
    def __init__(self, remote, env):
        self.remote, self.pane = remote, env.get('TMUX_PANE', '')
        self.owner = env.get('FLEET_CODEX_LAUNCHER_PID', '')
        self.next_at = 0
        self.reconcile_at = 0
        self.client = None
        self.binding = None
        self.event_stream = False
        self.native_usage = env.get('FLEET_CODEX_NATIVE_USAGE') == '1'
        self.meter = None
        self.subscribed = False
        self.pending_usage = None
        self.settings = None
        self.settings_changed = False

    def close(self):
        if self.client:
            try:
                self.client.close()
            except OSError:
                pass
        self.client = None
        self.binding = None
        self.reconcile_at = 0
        self.event_stream = False
        self.subscribed = False
        self.pending_usage = None
        self.settings = None
        self.settings_changed = False
        if self.meter is not None:
            self.meter.reset_native()

    def events(self, identifier):
        thread = None
        self.client.deadline = time.monotonic() + .05
        for _ in range(128):
            if self.client.events:
                event = self.client.events.pop(0)
            else:
                event = self.client.receive(nonblocking=True)
                if event is None:
                    return thread
            if not isinstance(event, dict):
                raise ValueError('invalid native event')
            params = event.get('params', {})
            if not isinstance(params, dict) or params.get('threadId') != identifier:
                continue
            if event.get('method') == 'thread/status/changed':
                status = params.get('status')
                if not isinstance(status, dict) or not isinstance(status.get('type'), str):
                    raise ValueError('invalid native thread status')
                if not self.event_stream:
                    self.event_stream = True
                    if self.reconcile_at:
                        self.reconcile_at = time.monotonic() + 30
                thread = {'id': identifier, 'status': status}
            elif event.get('method') == 'thread/closed':
                thread = {'id': identifier, 'status': {'type': 'notLoaded'}}
                self.subscribed = False
                self.pending_usage = None
                if self.meter is not None:
                    self.meter.reset_native()
            elif self.subscribed and event.get('method') == 'thread/tokenUsage/updated':
                self.pending_usage = params.get('tokenUsage')
                if not isinstance(self.pending_usage, dict):
                    raise ValueError('invalid native token usage')
            elif self.subscribed and event.get('method') == 'thread/settings/updated':
                self.settings = params.get('threadSettings')
                if not isinstance(self.settings, dict):
                    raise ValueError('invalid native model settings')
                self.settings_changed = True
            elif self.subscribed and event.get('method') == 'model/rerouted':
                self.settings = dict(self.settings or {}, model=params.get('toModel'))
                self.settings_changed = True
        raise ValueError('native event backlog exceeds monitor budget')

    def failed_turn(self, data):
        """The thread's last turn when it settled FAILED and the thread is not
        running another; None otherwise (or when the turns cannot be read)."""
        try:
            latest = thread_read(self.client, data, include_turns=True)
        except ValueError:
            return None
        turns = latest.get('turns') or []
        if (latest.get('status', {}).get('type') not in ('systemError', 'idle') or not turns
                or not isinstance(turns[-1], dict) or turns[-1].get('status') != 'failed'):
            return None
        return turns[-1]

    def failure(self, turn, book):
        """The values a failed turn writes: needs/error with its words, and — a
        transient kind inside the window's budget — one resume booked."""
        summary, retry = turn_error(turn)
        now = int(time.time())
        top = _env_int('FLEET_CODEX_TURN_RETRY_MAX', 2)
        span = _env_int('FLEET_CODEX_TURN_RETRY_WINDOW', 1800)
        base = max(1, _env_int('FLEET_CODEX_TURN_RETRY_SECS', 30))
        on = os.environ.get('FLEET_CODEX_TURN_RETRY', '1') != '0'
        parts = book.split()
        n = int(parts[0]) if len(parts) == 2 and parts[0].isdigit() else 0
        since = int(parts[1]) if len(parts) == 2 and parts[1].isdigit() else now
        if now - since >= span:
            n, since = 0, now
        values = {'@claude_state': 'needs', '@claude_needs': 'error', '@claude_state_ts': str(now),
                  '@turn_error': summary, '@turn_retry_at': ''}
        if retry and on and n < top:
            delay = base * 2 ** n
            values.update({'@turn_retry': '%d %d' % (n + 1, since), '@turn_retry_at': str(now + delay)})
            values['@claude_needs_detail'] = '%s · 自动重试 %d/%d，%d 秒后' % (summary, n + 1, top, delay)
            retry_log(self.pane, 'booked %d/%d in %ds: %s' % (n + 1, top, delay, summary))
        else:
            why = ('已自动重试 %d 次仍失败' % n) if retry and on else '不会自动重试'
            values['@claude_needs_detail'] = '%s · %s，等你处理' % (summary, why)
            retry_log(self.pane, 'left for a person (%s): %s' % (why, summary))
        return values

    def fire(self, data, state_ts, retry_at):
        """A booked resume is due: claim it (one tmux compare-and-set, so it is
        sent once), then hand the words to the session's inbox."""
        thread = thread_read(self.client, data)
        if thread.get('status', {}).get('type') == 'active':
            return thread   # the session moved on by itself: the active branch ends the row
        claim = ('#{&&:#{==:#{@turn_retry_at},%s},#{&&:#{==:#{@claude_needs},error},#{==:#{@claude_state_ts},%s}}}'
                 % (retry_at, state_ts))
        tm = session['tmux']
        why = tm(['display-message', '-p', '-t', self.pane, '#{@turn_error}']) or 'upstream error'
        cmds = [['set-option', '-w', '-t', self.pane, '@turn_retry_at', 'sent:' + retry_at],
                ['set-option', '-w', '-t', self.pane, '@claude_needs_detail', why + ' · 已自动续一轮，等它回话']]
        tm(['if-shell', '-F', '-t', self.pane, claim, ' ; '.join(shlex.join(c) for c in cmds)])
        if tm(['display-message', '-p', '-t', self.pane, '#{@turn_retry_at}']) != 'sent:' + retry_at:
            return
        retry_log(self.pane, 'sent: ' + why)
        resume_send(self.pane, RESUME_TEXT.format(why=why))

    def tick(self):
        if not self.pane or not self.owner or time.monotonic() < self.next_at: return
        self.next_at = time.monotonic() + 2
        try:
            data = session['identity'](self.pane)
            if data.get('owner') != self.owner or data.get('remote') != self.remote:
                self.close()
                return
            tm = session['tmux']
            observed_state = tm(['display-message', '-p', '-t', self.pane,
                                 '#{@claude_state}|#{@claude_needs}|#{@codex_attention}|#{@claude_state_ts}'
                                 '|#{@turn_retry_at}|#{@turn_retry}']).split('|', 5)
            state, why, before, state_ts, retry_at, book = (observed_state + [''] * 6)[:6]
            if (state == 'done' and not why and not before and state_ts.isdigit()
                    and time.time() - int(state_ts) >= idle_after()):
                # A long-idle session asks nothing: its next turn's start is the
                # hooks' word, not this monitor's. Two tmux forks every 2 s per
                # Codex session (36 on one machine) slowed every other window's
                # tmux; idle, the next look waits FLEET_CODEX_ATTENTION_IDLE_SECS.
                self.next_at = time.monotonic() + idle_secs()
            binding = tuple(data.get(key) for key in ('owner', 'session_id', 'home', 'remote'))
            if binding != self.binding:
                self.close()
            if self.client is None:
                options = {'opt_out_notifications': TELEMETRY_OPT_OUT} if self.native_usage and self.meter is not None else {}
                self.client = Client(self.remote, timeout=.6, **options)
                self.binding = binding
            thread = self.events(data['session_id'])
            if time.monotonic() >= self.reconcile_at:
                thread = thread_read(self.client, data)
                if (self.native_usage and self.meter is not None and not self.subscribed
                        and thread.get('status', {}).get('type') in ('active', 'idle')
                        and thread.get('source') in ('cli', 'exec', 'appServer', 'vscode')
                        and thread.get('parentThreadId') is None and thread.get('threadSource') != 'thread_title'):
                    current(data, self.pane, '')
                    resumed = self.client.call('thread/resume', {'threadId': data['session_id'], 'excludeTurns': True})
                    if resumed['thread']['id'] != data['session_id']:
                        raise ValueError('native telemetry subscription changed thread')
                    current(data, self.pane, '')
                    self.subscribed = True
                    self.settings = {'model': resumed['model'], 'effort': resumed.get('reasoningEffort')}
                    self.settings_changed = True
                observed = self.events(data['session_id'])
                if observed is not None and observed.get('status') != thread.get('status'):
                    self.reconcile_at = 0
                    return
                self.reconcile_at = time.monotonic() + (30 if self.event_stream else 2)
            if self.subscribed:
                if thread is not None and thread.get('status', {}).get('type') not in ('active', 'idle'):
                    self.meter.reset_native()
                    self.pending_usage = None
                    if thread.get('status', {}).get('type') == 'notLoaded':
                        self.subscribed = False
                else:
                    if self.pending_usage is not None or self.settings_changed:
                        self.meter.observe(data, self.pending_usage, self.settings)
                        self.pending_usage = None
                        self.settings_changed = False
                    self.meter.keep_native(data)
            if (state, why) == ('needs', 'error') and retry_at.isdigit() and time.time() >= int(retry_at):
                thread = self.fire(data, state_ts, retry_at)
            if thread is None:
                return
            subtype = kind(thread)
            stype = thread.get('status', {}).get('type')
            cmds = []
            if subtype:
                if (state, why, before) == ('needs', subtype, subtype): return
                values = {'@claude_state':'needs','@claude_needs':subtype,'@codex_attention':subtype,
                          '@claude_needs_detail':request_detail(data, subtype),
                          '@claude_state_ts':str(int(time.time()))}
            elif before and why == before and state == 'needs' and thread.get('status', {}).get('type') in ('active','idle'):
                values = {'@claude_state':'working' if thread['status']['type']=='active' else 'done',
                          '@claude_needs':'','@claude_needs_detail':'','@codex_attention':'',
                          '@claude_state_ts':str(int(time.time()))}
            elif before:
                values = {'@codex_attention':''}
            elif (state, why) == ('needs', 'error') and stype == 'active':
                # The failed session runs again (the booked resume, or a person's
                # words the hooks did not stamp): the error row ends.
                values = {'@claude_state': 'working', '@claude_needs': '', '@claude_needs_detail': '',
                          '@turn_retry_at': '', '@claude_state_ts': str(int(time.time()))}
            elif not why and state == 'working' and stype == 'systemError':
                # A turn the provider failed (T1381: every retry refused) leaves
                # the thread in systemError with no Stop hook: the row read
                # «working» over an idle prompt. Only a settled FAILED last turn
                # ends it — as a visible failure (T1392), never as success.
                failed = self.failed_turn(data)
                if failed is None:
                    return
                values = self.failure(failed, book)
            elif (not why and state == 'working' and stype == 'idle'
                    and (failed := self.failed_turn(data)) is not None):
                # The same failure with the thread back at idle (T1392).
                values = self.failure(failed, book)
            elif not why and state in ('working', 'done') and thread.get('status', {}).get('type') in ('active', 'idle'):
                # Interrupts may emit native idle without a Stop hook. Project
                # the loaded thread directly; this says nothing about Task completion.
                native_state = 'working' if thread['status']['type'] == 'active' else 'done'
                if state == native_state: return
                if native_state == 'done':
                    # A queued idle event may precede a new turn whose working
                    # hook has the same second timestamp. Read the native thread
                    # now, then drain any newer status before demoting the row.
                    latest = thread_read(self.client, data)
                    newer = self.events(data['session_id'])
                    if latest.get('status', {}).get('type') != 'idle' or (newer is not None and
                            newer.get('status', {}).get('type') != 'idle'):
                        self.reconcile_at = 0
                        return
                values = {'@claude_state': native_state, '@claude_state_ts': str(int(time.time()))}
            else: return
            if values.get('@claude_state') == 'done' and '@claude_state_ts' in values:
                values['@turn_activity_at'] = values['@claude_state_ts']
            for name, value in values.items(): cmds.append(['set-option','-w','-t',self.pane,name,value])
            test = '#{&&:#{==:#{@cc_launcher_pid},' + self.owner + '},#{==:#{@codex_session_id},' + data['session_id'] + '}}'
            test = '#{&&:#{==:#{@cc_agent},codex},' + test + '}'
            # Clearing only the native attention subtype cannot erase an explicit
            # blocked declaration that arrived during the RPC.
            if not subtype:
                for name, value in (('@claude_needs', why), ('@claude_state', state), ('@claude_state_ts', state_ts)):
                    test = '#{&&:' + test + ',#{==:#{' + name + '},' + value + '}}'
            tm(['if-shell','-F','-t',self.pane,test,' ; '.join(shlex.join(c) for c in cmds)])
            if subtype and before != subtype:
                try:
                    with open('/dev/tty','w') as tty: tty.write('\a')
                except OSError: pass
        except (OSError, ValueError, KeyError, TypeError, EOFError, subprocess.SubprocessError):
            self.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=('show','answer','cancel','deny','popup'))
    p.add_argument('picks', nargs='*')
    p.add_argument('--pane', required=True)
    p.add_argument('--socket', default='')
    p.add_argument('--category', choices=('ask','perm'), default='ask')
    p.add_argument('--request-token', default='')
    p.add_argument('--json', action='store_true')
    p.add_argument('--dry-run', action='store_true')
    a = p.parse_intermixed_args()
    data = session['identity'](a.pane,a.socket)
    if not data: raise ValueError('no current Codex thread identity')
    if a.command=='popup': popup(data,a.pane,a.socket);return 0
    if a.command!='show' and not a.request_token: raise ValueError('use --show --json and pass its --request-token when replying')
    if a.command=='deny' and os.environ.get('FLEET_ALLOW_AUTO_DENY')!='1': raise ValueError('permission denial is not armed (FLEET_ALLOW_AUTO_DENY=1)')
    pending = Pending(data, a.category, a.request_token)
    try:
        if a.command=='show':
            print(json.dumps(pending.show(),ensure_ascii=False,indent=2) if a.json else display(json.dumps(pending.show(),ensure_ascii=False,indent=2)))
            return 0
        if (a.command in ('answer','cancel')) != (pending.request['method']==QUESTION):
            raise ValueError('request category does not match this response command')
        if a.command=='answer': result=answers(pending.request,a.picks)
        elif a.command=='cancel': result={'answers':{}}
        elif pending.request['method']=='item/permissions/requestApproval': result={'permissions':{},'scope':'turn'}
        elif pending.request['method']=='mcpServer/elicitation/request': result={'action':'decline'}
        else: result={'decision':'decline'}
        if a.dry_run: print('Dry-run: validated current request; nothing sent.');return 0
        pending.respond(result,a.pane,a.socket)
        return 0
    finally:
        pending.close()


if __name__=='__main__':
    try:sys.exit(main())
    except (OSError,ValueError,KeyError,TypeError,EOFError,subprocess.SubprocessError) as error:
        print('fleet-codex-attention: '+str(error),file=sys.stderr);sys.exit(1)
    except KeyboardInterrupt:sys.exit(130)
