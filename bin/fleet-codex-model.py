#!/usr/bin/env python3
"""Change an idle Codex thread's model through native settings, without typing.

Automatic fallback requires an explicit model -> native quota limit-ID map,
fresh low current-model quota, and fresh available destination quota. It never
infers a model from a display name or restarts a worker to change its model.
"""
import argparse
import json
import os
from pathlib import Path
import runpy
import shlex
import subprocess
import sys
import time

BIN = Path(__file__).absolute().parent
cx = runpy.run_path(str(BIN / 'fleet-codex-session.py'))
account = runpy.run_path(str(BIN / 'fleet-codex-account.py'))
Client = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client']


class SwitchAttemptedError(ValueError):
    """The native mutation may have applied; stop this collector tick."""


def eligible(home, old, new):
    mapping = account['model_limits']()
    if not old or not new or old == new or old not in mapping or new not in mapping: return False
    if mapping[old] == mapping[new]: return False
    # An account-wide wall belongs to home migration, not a guessed model bypass.
    if account['status'](home)['state'] != 'available': return False
    return (account['status'](home, limit_id=mapping[old])['state'] == 'low'
            and account['status'](home, limit_id=mapping[new])['state'] == 'available')


def current(data, pane, socket):
    now = cx['identity'](pane, socket)
    if any(now.get(k) != data.get(k) for k in ('owner','session_id','home','remote')):
        raise ValueError('worker identity changed; no model switch')


def native_idle(client, data):
    thread = client.call('thread/read', {'threadId':data['session_id'],'includeTurns':False})['thread']
    if thread.get('id') != data['session_id'] or thread.get('status', {}).get('type') != 'idle':
        raise ValueError('Codex thread is not idle')


def capped_turn(client, data):
    turns = client.call('thread/turns/list', {'threadId':data['session_id'], 'limit':1,
                       'sortDirection':'desc', 'itemsView':'summary'}).get('data', [])
    if not turns: return ''
    turn = turns[0]
    if turn.get('status') == 'failed' and (turn.get('error') or {}).get('codexErrorInfo') in ('usageLimitExceeded','rateLimitExceeded'):
        return turn.get('id', '')
    return ''


def switch(data, pane, socket, model, automatic=False, dry=False):
    if not model or any(ord(c) < 32 for c in model): raise ValueError('a native model name is required')
    current(data, pane, socket)
    client = Client(data.get('remote', ''), timeout=3)
    try:
        native_idle(client, data)
        params = {'threadId':data['session_id'],'excludeTurns':True}
        if data.get('transcript'): params['path'] = data['transcript']
        snapshot = client.call('thread/resume', params)
        if snapshot['thread']['id'] != data['session_id']: raise ValueError('thread changed')
        old = snapshot['model']
        if old == model: return False
        if automatic and not eligible(data['home'], old, model): return False
        flags = cx['tmux'](['display-message','-p','-t',pane,
            '#{@claude_state}|#{@claude_needs}|#{@agent_transfer_request}|#{@agent_transfer_until}|#{@handoff_armed}'], socket).split('|')
        if len(flags) != 5 or any(flags[i] for i in (2,3)) or flags[4] == '1':
            raise ValueError('a handoff/transfer is pending')
        if automatic and (flags[0] not in ('done','working') or flags[1]): return False
        failed_turn = capped_turn(client, data) if automatic else ''
        current(data, pane, socket)
        native_idle(client, data)
        if dry:
            print('Dry-run: %s -> %s; thread %s unchanged.' % (old, model, data['session_id']))
            return True
        try:
            client.call('thread/settings/update', {'threadId':data['session_id'],'model':model})
            confirmed = client.call('thread/resume', params)
            if confirmed['thread']['id'] != data['session_id'] or confirmed.get('model') != model:
                raise ValueError('native model change was not confirmed; inspect the worker')
            current(data, pane, socket)
            # Native settings notifications also update attached Codex TUIs.
            test = '#{&&:#{==:#{@cc_launcher_pid},' + data['owner'] + '},#{==:#{@codex_session_id},' + data['session_id'] + '}}'
            cmd = ['set-option','-w','-t',pane,'@cc_model',model]
            cx['tmux'](['if-shell','-F','-t',pane,test,shlex.join(cmd)], socket)
            print('Codex model: %s -> %s (same thread %s).' % (old, model, data['session_id']))
            if failed_turn:
                # A completed idle task receives no nudge. Resume only the exact
                # latest turn that natively failed on quota, after rechecking it.
                current(data, pane, socket)
                native_idle(client, data)
                if capped_turn(client, data) == failed_turn:
                    rule = subprocess.check_output(['bash', str(BIN/'fleet-lang.sh'), 'resume'], text=True, timeout=3).strip()
                    message = '[fleet model recovery] The last turn hit a native quota limit. Fleet switched this thread to ' + model + '. Continue the previously authorized task from that interruption; do not redo completed work. ' + rule
                    queued = subprocess.run(['codex','queue','--remote',data['remote'],'--thread',data['session_id'],'--message',message],
                                            env=dict(os.environ,CODEX_HOME=data['home']),capture_output=True,text=True,timeout=10)
                    if queued.returncode: raise ValueError('model changed, but recovery message was not accepted')
                    print('Queued continuation for the quota-failed turn.')
        except (OSError,ValueError,KeyError,TypeError,EOFError,subprocess.SubprocessError) as error:
            raise SwitchAttemptedError(str(error)) from error
        return True
    finally:
        client.close()


def watch(socket):
    fallback = os.environ.get('FLEET_CODEX_MODEL_FALLBACK', '')
    if not fallback or not account['model_limits'](): return False
    deadline = time.monotonic() + 8
    rows = cx['tmux'](['list-windows','-t',socket,'-F',
        '#{pane_id}|#{@cc_agent}|#{@cc_launcher_pid}|#{@claude_state}|#{@codex_identity}'], socket)
    for row in rows.splitlines():
        if time.monotonic() > deadline: break
        try:
            pane, agent, owner, state, raw = row.split('|', 4)
            if agent != 'codex' or state not in ('done','working'): continue
            data = cx['saved_identity'](raw,owner)
            if not data or not eligible(data['home'],data.get('model',''),fallback): continue
            if switch(data,pane,socket,fallback,automatic=True): return True
        except SwitchAttemptedError as error:
            print('fleet-codex-model: '+str(error), file=sys.stderr)
            return True  # Do not switch another worker or migrate a home this tick.
        except (OSError,ValueError,KeyError,TypeError,EOFError,subprocess.SubprocessError):
            continue
    return False


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=('switch','limits','watch'))
    p.add_argument('--session', required=True)
    p.add_argument('--window', default='')
    p.add_argument('--to', default='')
    p.add_argument('--dry-run', action='store_true')
    a=p.parse_args()
    if a.command=='watch': watch(a.session);return 0
    if not a.window: raise ValueError('--window is required')
    data=cx['identity'](a.window,a.session)
    if not data: raise ValueError('no current Codex identity')
    if a.command=='limits':
        client=Client(data.get('remote',''),timeout=3)
        try: print(json.dumps(account['normalize'](client.call('account/rateLimits/read',{'excludeResetCreditDetails':True})),indent=2))
        finally:client.close()
        return 0
    switch(data,a.window,a.session,a.to,dry=a.dry_run)
    return 0


if __name__=='__main__':
    try:sys.exit(main())
    except (OSError,ValueError,KeyError,TypeError,EOFError,subprocess.SubprocessError) as error:
        print('fleet-codex-model: '+str(error),file=sys.stderr);sys.exit(1)
