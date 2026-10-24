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
                                 '#{@claude_state}|#{@claude_needs}|#{@codex_attention}|#{@claude_state_ts}']).split('|', 3)
            state, why, before, state_ts = (observed_state + [''] * 4)[:4]
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
            if thread is None:
                return
            subtype = kind(thread)
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
            if '@claude_state_ts' in values:
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
