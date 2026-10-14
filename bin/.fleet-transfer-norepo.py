#!/usr/bin/env python3
"""Exact managed HOME identity and read-only readiness for no-repo transfers."""
import json
import os
from pathlib import Path
import re
import runpy
import time
import subprocess
import sys

FIELDS = ('fleet_id', 'fleet_role', 'fleet_role_def', 'agent_spawn', 'agent_def', 'agent_def_sha',
          'origin', 'origin_fid', 'origin_gen', 'task', 'task_line', 'repo',
          'norepo', 'issue', 'raw', 'worktree', 'reap_policy')


def identity(session, pane):
    result = {}
    for key in FIELDS:
        result[key] = subprocess.check_output(
            ['tmux', '-L', session, 'show-options', '-wqv', '-t', pane, '@' + key],
            text=True, stderr=subprocess.PIPE, timeout=5).rstrip('\n')
    return result


def validate(values, cwd):
    home = Path.home().resolve()
    if (values['norepo'] != '1' or values['fleet_role'] != 'worker'
            or not re.fullmatch(r'[0-9a-fA-F-]{36}', values['fleet_id'])
            or any(values[k] for k in ('repo', 'issue', 'worktree', 'raw'))):
        raise ValueError('no-repo transfer requires a managed HOME worker with lifelong identity and no repository binding')
    if Path(cwd).resolve() != home or (home / '.git').exists():
        raise ValueError('no-repo transfer only supports the physical login HOME, never an arbitrary directory or checkout')
    return values


def trust(home):
    # Read the exact target configuration, including a credential-proxy symlink.
    # No pre-trust writes here; #3029 owns the common launcher's grant policy.
    config = Path(home).expanduser() / 'config.toml'
    text = config.read_text()
    header = '[projects.' + json.dumps(str(Path.home().resolve()), ensure_ascii=False) + ']'
    sections = re.split(r'(?m)^\s*(\[[^\n]+\])\s*(?:#.*)?$', text)
    matches = [sections[i+1] for i in range(1, len(sections)-1, 2) if sections[i] == header]
    if len(matches) != 1 or not re.search(r'(?m)^\s*trust_level\s*=\s*"trusted"\s*(?:#.*)?$', matches[0]):
        raise ValueError('target HOME trust is not explicitly trusted; resolve #3029 or the existing trust choice before switching')


def readiness(session, pane, transcript, pid, sid, loop, agent):
    values = identity(session, pane)
    def opt(key):
        return subprocess.check_output(['tmux','-L',session,'show-options','-wqv','-t',pane,'@'+key],
                                       text=True, timeout=5).strip()
    mark = opt('loop')
    reader = runpy.run_path(str(Path(__file__).with_name('fleet_loop_mark.py')))
    active = reader['prune'](reader['parse'](mark), int(time.time()))
    if agent == 'claude':
        from fleet_transfer_cron import validate as validate_cron, has_native_activity, live_list
        native = has_native_activity(transcript, pid)
        if native and not active['ids'] and not active['next']:
            if live_list(transcript, pid, time.time()):
                raise ValueError('live CronList disagrees with the absent/expired scheduler mark')
        needs_plan = active['ids'] or active['next'] or (mark and 'kind=' not in mark)
        if needs_plan or (loop and 'jobs' in json.loads(Path(loop).read_text())):
            if not loop:
                raise ValueError('native scheduling is active or unknown: export current CronList and a verified multi-cron plan before switching')
            raw = json.loads(Path(loop).read_text())
            validate_cron(raw, transcript, pid, sid, values['fleet_id'], mark)
    view = runpy.run_path(str(Path(__file__).with_name('fleet-input.py')))['snapshot'](session,pane,agent=agent)
    if view['state'] not in ('empty','draft'):
        raise ValueError('source input is not safely exportable: ' + view.get('reason','unknown composer'))
    if agent == 'claude' and loop:
        view['native_plan'] = json.loads(Path(loop).read_text())
    return view


def main():
    action, *args = sys.argv[1:]
    if action == 'identity':
        session, pane, cwd = args
        print(json.dumps(validate(identity(session, pane), cwd), ensure_ascii=False, sort_keys=True))
    elif action == 'readiness':
        print(json.dumps(readiness(*args), ensure_ascii=False, sort_keys=True))
    elif action == 'trust':
        trust(args[0])
    else:
        raise ValueError('unknown no-repo transfer operation')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('fleet-transfer: ' + str(error), file=sys.stderr)
        sys.exit(1)
