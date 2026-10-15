#!/usr/bin/env python3
"""Exact managed HOME identity and read-only readiness for no-repo transfers."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import runpy
import fcntl
import time
import subprocess
import sys
import shlex
import uuid

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


def preparation_path(values):
    return Path(os.environ['FLEET_CONF_DIR'])/'transfer-preparation'/(values['fleet_id']+'.json')


@contextmanager
def preparation_lock(path):
    fd = os.open(str(path.with_suffix('.lock')), os.O_RDWR | os.O_CREAT, 0o600)
    with os.fdopen(fd, 'w') as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        yield


def preparation_save(path, request):
    temp = path.with_suffix('.tmp')
    fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as out:
        os.fchmod(out.fileno(), 0o600)
        json.dump(request, out, ensure_ascii=False)
        out.flush(); os.fsync(out.fileno())
    temp.replace(path)


def notes_request(notes):
    if not notes:
        return ''
    lines = Path(notes).read_text().splitlines()
    headers = [line for line in lines if line.startswith('Fleet-Preparation-Request:')]
    if not headers:
        return ''
    if len(headers) != 1 or not lines or headers[0] != lines[0]:
        raise ValueError('panel preparation request header must occur once, on the first line')
    match = re.fullmatch(r'Fleet-Preparation-Request: ([0-9a-f-]{36})', headers[0])
    if not match:
        raise ValueError('invalid panel preparation request id in notes')
    return match[1]


def preparation_check(session, pane, pid, sid, target, request_id='', notes='', commit=False):
    """Pin the generation, not just the current file at this session's address."""
    given = notes_request(notes)
    if request_id and given and request_id != given:
        raise ValueError('panel preparation request id differs between waiter and notes')
    request_id = request_id or given
    values = identity(session, pane)
    path = preparation_path(values)
    if not path.exists():
        if request_id:
            raise ValueError('panel preparation request no longer exists')
        return ''
    with preparation_lock(path):
        request = json.loads(path.read_text())
        if request.get('state') == 'completed' and not request_id:
            return ''  # An ordinary subsequent handoff, not an old panel request.
        if (request.get('pid') != int(pid) or request.get('session_id') != sid
                or request.get('fleet_id') != values['fleet_id'] or request.get('to') != target
                or request.get('state') not in ('sending', 'requested', 'uncertain')
                or not time.time() < request.get('expires_at', 0)):
            raise ValueError('panel preparation expired or changed identity/target/state; source stays running, select the switch again')
        if not request_id or request.get('request_id') != request_id:
            raise ValueError('panel preparation request id missing or superseded; source stays running')
        if commit:
            # Close the check-to-/exit race. Further clicks cannot replace a
            # committed transition, even if its preparation deadline passes.
            request['state'] = 'exiting'
            preparation_save(path, request)
    return request_id


def preparation_complete(session, pane, request_id=''):
    if not request_id:
        return
    path = preparation_path(identity(session, pane))
    with preparation_lock(path):
        request = json.loads(path.read_text())
        if request.get('request_id') != request_id or request.get('state') != 'exiting':
            raise ValueError('panel preparation completion belongs to a superseded or uncommitted request')
        request['state'] = 'completed'
        preparation_save(path, request)


def source_identity(session, pane):
    # The inspector proves the native owner; never trust a PID supplied in notes.
    return json.loads(subprocess.check_output(
        ['bash', str(Path(__file__).with_name('fleet-transfer.sh')), '--session', session,
         '--window', pane, '--to', 'codex', '--inspect'], text=True, timeout=30))


def preparation_reject(session, pane, request_id, abort=False):
    source = source_identity(session, pane)
    path = preparation_path(identity(session, pane))
    with preparation_lock(path):
        request = json.loads(path.read_text())
        allowed = ('sending', 'requested', 'uncertain') + (('exiting',) if abort else ())
        if (not request_id or request.get('request_id') != request_id
                or request.get('pid') != source['pid'] or request.get('session_id') != source['session_id']
                or request.get('state') not in allowed):
            raise ValueError('panel preparation rejection belongs to a superseded request or source')
        request['state'] = 'rejected'
        preparation_save(path, request)


def request_preparation(session, pane, transcript, pid, sid, target):
    values = identity(session, pane)
    validate(values, str(Path.home()))
    view = runpy.run_path(str(Path(__file__).with_name('fleet-input.py')))['snapshot'](session,pane,agent='claude')
    if view['state'] != 'empty':
        raise ValueError('finish the source input before requesting schedule preparation')
    root=Path(os.environ['FLEET_CONF_DIR'])/'transfer-preparation'
    root.mkdir(mode=0o700,parents=True,exist_ok=True)
    path=preparation_path(values)
    with preparation_lock(path):
        if path.exists():
            old=json.loads(path.read_text())
            if old.get('state') not in ('sending', 'requested', 'uncertain', 'exiting',
                                         'rejected', 'cancelled', 'completed', 'failed'):
                raise ValueError('unknown preparation state; inspect delivery before retrying')
            if (old.get('pid')==int(pid) and old.get('session_id')==sid
                    and old.get('state') in ('sending','requested','uncertain','exiting')
                    and (old.get('state') != 'requested' or time.time() < old.get('expires_at',0))):
                if old['state'] in ('sending', 'uncertain'):
                    print('schedule preparation delivery is unconfirmed; source remains running, not resending')
                elif old['state'] == 'exiting':
                    print('schedule preparation cutover is committed; inspect its result before retrying')
                else:
                    print('schedule preparation already requested; source remains running')
                return
        request=dict(request_id=str(uuid.uuid4()),pid=int(pid),session_id=sid,fleet_id=values['fleet_id'],to=target,
                     transcript=transcript,created_at=time.time(),expires_at=time.time()+300,state='sending')
        preparation_save(path, request)
        reject = shlex.join(['python3', str(Path(__file__).absolute()), 'reject-request', session, pane, request['request_id']])
        prompt=("[Fleet panel transfer request] The operator selected a switch to "+target+
                ". Source scheduling must be verified before any exit. Read the request at "+str(path)+
                "; this message belongs ONLY to request id "+request['request_id']+". If the file now has another id, do not use the newer id or arm from this old message. "
                "If expired, cancelled by later user instructions, or its pid/session/fleet identity does not match, do not switch. "
                "Call native CronList now. Keep every native task running. Verify each current job's id, full untruncated prompt, cron, recurrence, durable/session-only ownership, IANA timezone, expiry and stop condition using its current tool result and this session's evidence; never guess missing values. "
                "Start the handoff notes with this exact first line: Fleet-Preparation-Request: "+request['request_id']+"\n"
                "If you refuse or cannot finish preparation, run "+reject+" to explicitly end ONLY this request; a later panel click may then try again. "
                "Write private handoff notes covering this current task inventory, role, task record, parent/children, latest user requests, pending decisions, current work and next action. "
                "If any task is durable, include its verified ownership and any missing evidence in those notes, then explain that successor execution ownership is not yet proven. Run the rejection command above, then stop here; do not proceed with the export/arm instructions below. Keep the source and all tasks running; do not arm, delete a native record or create a second timer, and do not ask the operator to find or export JSON. "
                "For session-only tasks, write a private JSON plan with jobs [{id,prompt,cron,recurring,timezone,expires_at,stop_when}] (recurring is boolean; expires_at may be null only for a one-shot with no separate expiry; stop_when is an empty string only when explicitly no additional condition) and native_source {confirmed:true,job_evidence:{job_id:{field:{value,source}}}}. Include evidence for prompt, cron, durable (boolean), timezone, expires_at and stop_when wherever absent or truncated in CronList. Include all current jobs. "
                "Export it using python3 "+str(Path(__file__).with_name('fleet-loop.py'))+
                " export-cron --session "+session+" --jobs-file <private-plan>. "
                "As the final tool call, use the Fleet transfer tool action arm, to "+target+", handoff <absolute-notes-path>, then end the turn. "
                "The common controller finds the verified plan and waits for Stop. Do not stop/recreate Cron tasks yourself. "
                "If any scheduling fact is unknown, explain what is missing and keep the source active; never manufacture an attestation. "
                "Continue in the existing conversation language. This requests preparation and the selected switch, not any additional task work.")
        try:
            subprocess.run(['bash',str(Path(__file__).with_name('fleet-peer-send.sh')),'-L',session,pane,'-'],
                           input=prompt,text=True,check=True,timeout=30,stdout=subprocess.DEVNULL)
        except (OSError,subprocess.SubprocessError):
            request['state']='uncertain'; preparation_save(path, request)
            raise ValueError('schedule preparation delivery is unconfirmed; source remains active, not resending') from None
        request['state']='requested'; preparation_save(path, request)
    print('schedule preparation requested; source remains running until verified handoff is armed')


def schedule_readiness(session, pane, transcript, pid, sid, loop, agent):
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
            from fleet_transfer_cron import validate as validate_cron, has_native_activity, live_list, check_durable_store
            # The panel may request read-only source preparation even when a
            # durable record blocks cutover. Neither preparation nor a fresh
            # CronList supplies the still-missing successor execution fence.
            check_durable_store()
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
        commit = bool(args and args[-1] == '--commit')
        if commit: args.pop()
        print(preparation_check(*args, commit=commit))
    elif action in ('reject-request', 'abort-request'):
        preparation_reject(*args, abort=action == 'abort-request')
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
