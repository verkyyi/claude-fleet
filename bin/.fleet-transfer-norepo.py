#!/usr/bin/env python3
"""Exact managed HOME identity and read-only readiness for no-repo transfers."""
import json
import os
from pathlib import Path
import re
import runpy
import fcntl
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


def trust(home, apply=False):
    argv = ['sh',str(Path(__file__).with_name('fleet-trust.sh')),'codex-ready','--home']
    if apply: argv.append('--apply')
    subprocess.run(argv, env=dict(os.environ,CODEX_HOME=home), check=True)


class SchedulePreparation(ValueError):
    pass


def preparation_check(session, pane, pid, sid, target):
    """A source's arm and the deferred cutover both honor the panel deadline."""
    values = identity(session, pane)
    path = Path(os.environ['FLEET_CONF_DIR'])/'transfer-preparation'/(values['fleet_id']+'.json')
    if not path.exists():
        return
    request = json.loads(path.read_text())
    if request.get('state') == 'completed':
        return
    if (request.get('pid') != int(pid) or request.get('session_id') != sid
            or request.get('fleet_id') != values['fleet_id'] or request.get('to') != target
            or request.get('state') not in ('sending', 'requested', 'uncertain')
            or not time.time() < request.get('expires_at', 0)):
        raise ValueError('panel preparation expired or changed identity/target; source stays running, select the switch again')


def preparation_complete(session, pane):
    values = identity(session, pane)
    path = Path(os.environ['FLEET_CONF_DIR'])/'transfer-preparation'/(values['fleet_id']+'.json')
    if path.exists():
        request = json.loads(path.read_text())
        request['state'] = 'completed'
        path.write_text(json.dumps(request))


def request_preparation(session, pane, transcript, pid, sid, target):
    values = identity(session, pane)
    validate(values, str(Path.home()))
    view = runpy.run_path(str(Path(__file__).with_name('fleet-input.py')))['snapshot'](session,pane,agent='claude')
    if view['state'] != 'empty':
        raise ValueError('finish the source input before requesting schedule preparation')
    root=Path(os.environ['FLEET_CONF_DIR'])/'transfer-preparation'
    root.mkdir(mode=0o700,parents=True,exist_ok=True)
    path=root/(values['fleet_id']+'.json')
    fd=os.open(str(path.with_suffix('.lock')),os.O_RDWR|os.O_CREAT,0o600)
    with os.fdopen(fd,'w') as guard:
        fcntl.flock(guard,fcntl.LOCK_EX)
        if path.exists():
            old=json.loads(path.read_text())
            if (old.get('pid')==int(pid) and old.get('session_id')==sid
                    and old.get('state') in ('sending','requested','uncertain')
                    and (old.get('state') != 'requested' or time.time() < old.get('expires_at',0))):
                print('schedule preparation already requested; source remains running')
                return
        request=dict(pid=int(pid),session_id=sid,fleet_id=values['fleet_id'],to=target,
                     transcript=transcript,created_at=time.time(),expires_at=time.time()+300,state='sending')
        path.write_text(json.dumps(request,ensure_ascii=False)); path.chmod(0o600)
        prompt=("[Fleet panel transfer request] The operator selected a switch to "+target+
                ". Source scheduling must be verified before any exit. Read the request at "+str(path)+
                "; if expired, cancelled by later user instructions, or its pid/session/fleet identity does not match, do not switch. "
                "Call native CronList now. Keep every native task running. Verify each current job's id, full untruncated prompt, cron, recurrence, durable/session-only ownership, IANA timezone, expiry and stop condition using its current tool result and this session's evidence; never guess missing values. If any task is durable, stop preparation and explain that no successor execution owner has been proven. Keep the source and all tasks running; do not arm, delete a native record or create a second timer. "
                "For session-only tasks, write a private JSON plan with jobs [{id,prompt,cron,recurring,timezone,expires_at,stop_when}] (recurring is boolean; expires_at may be null only for a one-shot with no separate expiry; stop_when is an empty string only when explicitly no additional condition) and native_source {confirmed:true,job_evidence:{job_id:{field:{value,source}}}}. Include evidence for prompt, cron, durable (boolean), timezone, expires_at and stop_when wherever absent or truncated in CronList. Include all current jobs. "
                "Export it using python3 "+str(Path(__file__).with_name('fleet-loop.py'))+
                " export-cron --session "+session+" --jobs-file <private-plan>. "
                "Write private handoff notes covering role, task record, parent/children, latest user requests, pending decisions, current work and next action. "
                "As the final tool call, use the Fleet transfer tool action arm, to "+target+", handoff <absolute-notes-path>, then end the turn. "
                "The common controller finds the verified plan and waits for Stop. Do not stop/recreate Cron tasks yourself. "
                "If any scheduling fact is unknown, explain what is missing and keep the source active; never manufacture an attestation. "
                "Continue in the existing conversation language. This requests preparation and the selected switch, not any additional task work.")
        try:
            subprocess.run(['bash',str(Path(__file__).with_name('fleet-peer-send.sh')),'-L',session,pane,'-'],
                           input=prompt,text=True,check=True,timeout=30,stdout=subprocess.DEVNULL)
        except (OSError,subprocess.SubprocessError):
            request['state']='uncertain'; path.write_text(json.dumps(request))
            raise ValueError('schedule preparation delivery is unconfirmed; source remains active, not resending') from None
        request['state']='requested'; path.write_text(json.dumps(request))
    print('schedule preparation requested; source remains running until verified handoff is armed')


def schedule_readiness(session, pane, transcript, pid, sid, loop, agent):
    if agent == 'claude':
        from fleet_transfer_cron import check_durable_store
        # This is a hard refusal, not a request for more metadata. Reading a
        # fresh CronList cannot create the missing successor execution owner.
        check_durable_store()
    values = identity(session, pane)
    verified = None
    def opt(key):
        return subprocess.check_output(['tmux','-L',session,'show-options','-wqv','-t',pane,'@'+key],
                                       text=True, timeout=5).strip()
    mark = opt('loop')
    reader = runpy.run_path(str(Path(__file__).with_name('fleet_loop_mark.py')))
    active = reader['prune'](reader['parse'](mark), int(time.time()))
    try:
        if agent == 'claude':
            from fleet_transfer_cron import validate as validate_cron, has_native_activity, live_list
            native = has_native_activity(transcript, pid)
            if native and not active['ids'] and not active['next'] and not loop:
                if live_list(transcript, pid, time.time()):
                    raise ValueError('live CronList disagrees with the absent/expired scheduler mark')
            needs_plan = active['ids'] or active['next'] or (mark and 'kind=' not in mark)
            if needs_plan or (loop and 'jobs' in json.loads(Path(loop).read_text())):
                if not loop:
                    raise ValueError('native scheduling is active or unknown: export current CronList and a verified multi-cron plan before switching')
                raw = json.loads(Path(loop).read_text())
                verified = validate_cron(raw, transcript, pid, sid, values['fleet_id'], mark)
    except ValueError as error:
        raise SchedulePreparation(str(error)) from error
    return verified


def readiness(session, pane, transcript, pid, sid, loop, agent):
    verified = schedule_readiness(session, pane, transcript, pid, sid, loop, agent)
    view = runpy.run_path(str(Path(__file__).with_name('fleet-input.py')))['snapshot'](session,pane,agent=agent)
    if view['state'] not in ('empty','draft'):
        raise ValueError('source input is not safely exportable: ' + view.get('reason','unknown composer'))
    if agent == 'claude' and loop:
        view['native_plan'] = verified
    return view


def main():
    action, *args = sys.argv[1:]
    if action == 'identity':
        session, pane, cwd = args
        print(json.dumps(validate(identity(session, pane), cwd), ensure_ascii=False, sort_keys=True))
    elif action == 'request':
        request_preparation(*args)
    elif action == 'check-request':
        preparation_check(*args)
    elif action == 'complete-request':
        preparation_complete(*args)
    elif action == 'readiness':
        print(json.dumps(readiness(*args), ensure_ascii=False, sort_keys=True))
    elif action == 'schedule-readiness':
        schedule_readiness(*args)
    elif action == 'trust':
        trust(args[0], '--apply' in args[1:])
    else:
        raise ValueError('unknown no-repo transfer operation')


if __name__ == '__main__':
    try:
        main()
    except SchedulePreparation as error:
        print('fleet-transfer: '+str(error),file=sys.stderr)
        sys.exit(4)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('fleet-transfer: ' + str(error), file=sys.stderr)
        sys.exit(1)
