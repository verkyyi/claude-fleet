#!/usr/bin/env python3
"""Change an idle Codex thread's model through native settings, without typing.

A person's switch only: the quota-triggered automatic fallback left with the local
Codex account registry (T560, EPIC T542 C5). It never restarts a worker to change
its model. `limits` prints the thread's native quota buckets, normalized.
"""
import argparse
import json
from pathlib import Path
import runpy
import shlex
import subprocess
import sys

BIN = Path(__file__).absolute().parent
cx = runpy.run_path(str(BIN / 'fleet-codex-session.py'))
Client = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client']


def numeric(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def normalize(response):
    """Only usage metadata out of account/rateLimits/read — never a credential."""
    if not isinstance(response, dict) or not isinstance(response.get('rateLimits'), dict):
        raise ValueError('unrecognized native quota response')
    def bucket(value):
        if not isinstance(value, dict): return {}
        result = {k: value[k] for k in ('limitId', 'normalModelSlug', 'planType', 'spendControlReached', 'rateLimitReachedType') if isinstance(value.get(k), (str, bool))}
        for key in ('primary', 'secondary'):
            row = value.get(key)
            if not isinstance(row, dict) or not numeric(row.get('usedPercent')): continue
            result[key] = {k: row[k] for k in ('usedPercent', 'windowDurationMins', 'resetsAt') if numeric(row.get(k))}
        credits = value.get('credits')
        if isinstance(credits, dict):
            result['credits'] = {k: credits[k] for k in ('hasCredits', 'unlimited') if isinstance(credits.get(k), bool)}
        return result
    data = {'rateLimits': bucket(response['rateLimits']), 'rateLimitsByLimitId': {}}
    buckets = response.get('rateLimitsByLimitId') or {}
    if not isinstance(buckets, dict): raise ValueError('unrecognized native quota buckets')
    for key, value in buckets.items():
        data['rateLimitsByLimitId'][key] = bucket(value)
    if isinstance(response.get('ordinaryUsageAllowed'), bool):
        data['ordinaryUsageAllowed'] = response['ordinaryUsageAllowed']
    return data


def current(data, pane, socket):
    now = cx['identity'](pane, socket)
    if any(now.get(k) != data.get(k) for k in ('owner','session_id','home','remote')):
        raise ValueError('worker identity changed; no model switch')


def native_idle(client, data):
    thread = client.call('thread/read', {'threadId':data['session_id'],'includeTurns':False})['thread']
    if thread.get('id') != data['session_id'] or thread.get('status', {}).get('type') != 'idle':
        raise ValueError('Codex thread is not idle')


def switch(data, pane, socket, model, dry=False):
    if data.get('cwd') and not dry:
        helper=runpy.run_path(str(BIN/'.fleet-transfer.py'))
        with helper['transition_lock'](data['cwd']):
            return switch_locked(data,pane,socket,model,dry)
    return switch_locked(data,pane,socket,model,dry)


def switch_locked(data, pane, socket, model, dry=False):
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
        flags = cx['tmux'](['display-message','-p','-t',pane,
            '#{@claude_state}|#{@claude_needs}|#{@agent_transfer_request}|#{@agent_transfer_until}|#{@handoff_armed}'], socket).split('|')
        if len(flags) != 5 or any(flags[i] for i in (2,3)) or flags[4] == '1':
            raise ValueError('a handoff/transfer is pending')
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
        except (OSError,ValueError,KeyError,TypeError,EOFError,subprocess.SubprocessError) as error:
            raise ValueError(str(error)) from error
        return True
    finally:
        client.close()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=('switch','limits'))
    p.add_argument('--session', required=True)
    p.add_argument('--window', default='')
    p.add_argument('--to', default='')
    p.add_argument('--dry-run', action='store_true')
    a=p.parse_args()
    if not a.window: raise ValueError('--window is required')
    data=cx['identity'](a.window,a.session)
    if not data: raise ValueError('no current Codex identity')
    if a.command=='limits':
        client=Client(data.get('remote',''),timeout=3)
        try: print(json.dumps(normalize(client.call('account/rateLimits/read',{'excludeResetCreditDetails':True})),indent=2))
        finally:client.close()
        return 0
    switch(data,a.window,a.session,a.to,dry=a.dry_run)
    return 0


if __name__=='__main__':
    try:sys.exit(main())
    except (OSError,ValueError,KeyError,TypeError,EOFError,subprocess.SubprocessError) as error:
        print('fleet-codex-model: '+str(error),file=sys.stderr);sys.exit(1)
