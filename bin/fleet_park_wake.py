#!/usr/bin/env python3
"""C3: persistent timer contracts for the existing session gate.

export is called under the parker's fid lock before exit; activate follows the
wrapper's held acknowledgement. tick runs on the existing spinner, not a new
daemon. A delivery ID is written before calling the gate, so overlapping ticks
and a killed dispatcher settle the same delivery, never post a second one.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time
from types import SimpleNamespace
import uuid

import fleet_cron
import fleet_loop_mark as mark
import fleet_session_gate as gate
import fleet_transfer_durable as durable
from fleet_agent_adapter import ADAPTERS


def loop_module():
    spec = importlib.util.spec_from_file_location('park_loop', Path(__file__).with_name('fleet-loop.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ledger_due(record):
    """The existing ledger remains the schedule's only writer, including defer
    and stop from the resumed agent. The contract is only its delivery owner."""
    if not record.get('ledger'):
        return record.get('next', 0)
    r = durable.read(record['ledger'])
    if not r or r.get('park_fid') != record['fid'] or r.get('status') not in ('active', 'waiting-quota'):
        return 0
    return r['schedule'].get('next_run_at') or 0


def path_for(fid):
    if not gate.FID_RE.fullmatch(fid):
        raise ValueError('invalid session identity')
    root = gate.conf_dir() / 'wake'
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    return root / (fid + '.json')


@contextmanager
def locked(fid):
    path = path_for(fid)
    with path.with_suffix('.lock').open('a') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield path


def save(path, record):
    record['next'] = ledger_due(record) if record.get('ledger') else min(
        (j['next'] for j in record['jobs'] if j['next'] is not None), default=0)
    durable.atomic(path, record)


def cron_job(ident, inp, created, kind='cron'):
    recurring = inp.get('recurring', True)
    until = created + 7 * 86400 if recurring else None
    job = dict(id=ident, kind=kind, expr=inp['cron'], prompt=inp['prompt'], until=until,
               recurring=recurring, timezone=durable.local_zone(), created=created)
    # Validate with the same bounded parser the transferred loop uses.
    fleet_cron.fields(job['expr'])
    job['next'] = following(job, created)
    return job


def following(job, after):
    return fleet_cron.next_fire(dict(cron=job['expr'], timezone=job['timezone'],
                                    expires_at=job['until'], recurring=job['recurring']), after)


def native_jobs(w, at):
    """The mark says which timers are still pending; the transcript supplies
    exact prompts. Read the whole conversation: a long-lived cron can be older
    than the Stop hook's bounded tail. Never export a subagent or failed call.
    """
    value = mark.parse(w['loop'])
    if w['loop'] and not (value['next'] or value['ids'] or value.get('park')):
        raise ValueError('unrecognized native timer mark')
    value = mark.prune(value, at)
    transcript = gate.claude_transcript(w['sid'])
    if transcript is None:
        if value['next'] or value['ids']:
            raise ValueError('pending timer has no exact transcript')
        return [], None
    if not value['next'] and not value['ids']:
        return [], transcript
    wake, jobs = None, {}
    with transcript.open() as lines:
        for name, inp, resp, used, result in mark.claude_tool_results(
                lines, ('ScheduleWakeup', 'CronCreate', 'CronDelete')):
            created = mark._epoch(result) or mark._epoch(used)
            if created is None:
                continue
            if name == 'ScheduleWakeup':
                wake = None if inp.get('stop') else (inp, created)
            elif name == 'CronCreate':
                ident = mark.cron_id(resp)
                if ident:
                    jobs[ident] = (inp, created)
            else:
                jobs.pop(str(inp.get('id', '')), None)
    out = []
    if value['next'] > at:
        if not wake or not isinstance(wake[0].get('prompt'), str) or not wake[0]['prompt'].strip():
            raise ValueError('pending wakeup has no exact prompt')
        inp, created = wake
        ident = 'wakeup:' + hashlib.sha256((str(created) + inp['prompt']).encode()).hexdigest()[:24]
        out.append(dict(id=ident, kind='wakeup', expr='', prompt=inp['prompt'],
                        until=mark.wake_until(value), next=value['next'], recurring=False, created=created))
    for ident, _ in value['ids']:
        if ident not in jobs:
            raise ValueError('pending cron has no exact prompt: ' + ident)
        inp, created = jobs[ident]
        if inp.get('durable'):
            continue  # The native table's single-owner road below owns these.
        if not isinstance(inp.get('prompt'), str) or not inp['prompt'].strip():
            raise ValueError('pending cron has no exact prompt: ' + ident)
        job = cron_job(ident, inp, created)
        job['next'] = value['at'].get(ident) if inp.get('recurring') is False else following(job, at)
        out.append(job)
    return out, transcript


def export(fid):
    w = gate.window(fid)
    if not w or not w['sid']:
        raise ValueError('no exact conversation to export')
    manifest = (gate.tmux(w['sock'], 'display-message', '-p', '-t', w['win'], '#{@handoff_manifest}') or '').strip()
    ledger = Path(manifest).parent / 'loop/state.json' if manifest else None
    if ledger and ledger.exists():
        loop = loop_module()
        with locked(fid) as path, loop.locked(ledger) as source:
            if source.get('status') == 'delivering':
                raise ValueError('loop delivery is unsettled')
            if source.get('status') in ('active', 'waiting-quota'):
                if (source.get('thread_id') != w['sid'] or source.get('agent', 'codex') != w['agent']
                        or source.get('manifest') != manifest):
                    raise ValueError('loop ledger belongs to another conversation')
                prior = durable.read(path)
                if prior and prior['sid'] != w['sid']:
                    raise ValueError('timer contract belongs to another conversation')
                r = prior or dict(v=1, fid=fid, sid=w['sid'], agent=w['agent'], jobs=[])
                r['previous'] = dict(prior) if prior else None
                r.update(ledger=str(ledger), phase='prepared', parked=True, next=source['schedule']['next_run_at'])
                durable.atomic(path, r)  # inert contract first, then stop the old dispatcher
                source['park_fid'] = fid
                loop.save(ledger, source)
                return dict(ok=True, ledger=str(ledger))
    if ADAPTERS[w['agent']]['native_cron'] != '1':
        return dict(ok=True, jobs=0)
    at = time.time()
    incoming, transcript = native_jobs(w, at)
    home = Path(os.environ.get('FLEET_WAKE_NATIVE_HOME') or Path.home())
    entries = durable.tasks(durable.read(home / '.claude/scheduled_tasks.json'))
    own = [r for r in entries if r.get('createdBySessionId') == w['sid']]
    # Unknown creator evidence cannot be silently treated as another session.
    if any(not r.get('createdBySessionId') for r in entries):
        raise ValueError('native durable task has no session owner')
    with locked(fid) as path:
        old = durable.read(path)
        if old and old['sid'] != w['sid']:
            raise ValueError('timer contract belongs to another conversation')
        record = old or dict(v=1, fid=fid, sid=w['sid'], agent=w['agent'], jobs=[])
        previous = dict(record) if old else None
        known = {j['id']: j for j in record['jobs']}
        if any(j['next'] is not None and j['next'] <= at and j['id'] not in known for j in incoming):
            raise ValueError('native one-shot is already due; keep its current owner')
        native = [j for j in incoming if j['id'] not in known]
        for job in incoming:
            # Consumed one-shots are tombstones; a second park must not rearm them.
            known.setdefault(job['id'], job)
        if own:
            source = gate.relay_request(w, dict(op='status'))
            pid = source.get('agent_pid')
            version = durable.transcript_version(transcript) if transcript else ''
            durable.stage_takeover(fid, home, pid, w['sid'], version, os.getpid())
            journal = durable.load(fid)
            if set(journal['records']) != {r['id'] for r in own}:
                raise ValueError('durable process/session ownership differs')
            durable.take_gate(journal)
            for durable_job in journal['jobs']:
                job = cron_job(durable_job['id'], dict(cron=durable_job['cron'], prompt=durable_job['prompt'], recurring=False), at, 'durable')
                job['next'] = durable_job['next_run_at']
                known.setdefault(job['id'], job)
            record['durable'] = True
        record.update(jobs=list(known.values()), phase='prepared', parked=True)
        record['native'] = native
        record['previous'] = previous
        if record['jobs']:
            save(path, record)
        return dict(ok=True, jobs=len(record['jobs']))


def activate(fid):
    with locked(fid) as path:
        r = durable.read(path)
        if not r:
            return
        if r.get('durable') and any(j['kind'] == 'durable' and j['next'] is not None for j in r['jobs']):
            durable.handed(fid)
            durable.activate(fid, dict(kind='park', path=str(path), session_id=r['sid']))
        r['phase'] = 'active'
        r.pop('previous', None)
        save(path, r)
    w = gate.window(fid)
    if w:
        # Native timers died with the process. Their old expiry marks must not
        # outlive a cancelled/consumed contract or revive them on the next park.
        gate.tmux(w['sock'], 'set-option', '-w', '-t', w['win'], '@loop', 'park=' + fid)


def abort(fid):
    """A refused exit leaves native timers native and existing Fleet timers live."""
    with locked(fid) as path:
        r = durable.read(path)
        if not r or r.get('phase') != 'prepared':
            return
        if r.get('previous'):
            save(path, r['previous'])
        else:
            path.unlink()
        if r.get('ledger') and not r.get('previous'):
            loop = loop_module()
            with loop.locked(Path(r['ledger'])) as source:
                source.pop('park_fid', None)
                loop.save(Path(r['ledger']), source)
        if r.get('durable'):
            durable.abort(fid, 'park exit refused')


def resumed(fid):
    with locked(fid) as path:
        r = durable.read(path)
        if r:
            r['parked'] = False
            save(path, r)


def cancel(fid, payload):
    """Existing PostToolUse entry: a native stop/delete cancels its Fleet copy.
    No native task is recreated on resume. Other jobs keep their phase.
    """
    with locked(fid) as path:
        r = durable.read(path)
        if not r:
            return
        name, inp = payload.get('tool_name'), payload.get('tool_input') or {}
        for job in r['jobs']:
            if ((name == 'CronDelete' and job['id'] == inp.get('id'))
                    or (name == 'ScheduleWakeup' and job['kind'] == 'wakeup')):
                job['next'] = None
        save(path, r)


def exit_confirmation(fid, screen):
    """Only the native exit dialog for exactly the timers staged by this park.
    Its selected action, footer and every listed task must match. The relay
    rechecks the screen fingerprint and keyboard generation before one Enter.
    """
    r = durable.read(path_for(fid))
    jobs = r.get('native', []) if r and r.get('phase') == 'prepared' else []
    n = len(jobs)
    lines = [line.strip() for line in screen.splitlines() if line.strip()]
    if not n or len(lines) < n + 6:
        return False
    if lines[-n-6:-n-4] != ['Background work is running', 'The following will stop when you exit:']:
        return False
    if lines[-4:] != ['❯ 1. Exit and stop tasks', '2. Move to background and exit',
                      '3. Stay', 'Enter to confirm · Esc to cancel']:
        return False
    tasks = lines[-n-4:-4]
    return (all(re.match(r'(?:scheduled|cron) task · ', line) for line in tasks)
            and all(sum((j['expr'] and j['expr'] in line) or j['prompt'] in line for line in tasks) == 1
                    for j in jobs))


def restore(fid, sid, owned=False):
    r = durable.read(path_for(fid))
    return bool(r and r['sid'] == sid and (owned or r.get('parked')) and ledger_due(r))


def tick(fid, at=None):
    at = time.time() if at is None else at
    w = gate.window(fid)
    if not w:
        return  # restore owns the missing window, identity and worktree.
    prepared = durable.read(path_for(fid))
    if prepared and prepared.get('phase') == 'prepared':
        with gate.lock(fid):  # a live parker finishes first; never undo its export
            w = gate.window(fid)
            if not w:
                return
            if not w['parked']:
                abort(fid)  # parker died before requesting exit; old owner continues
            elif not w.get('relay'):
                held = gate.tmux(w['sock'], 'display-message', '-p', '-t', w['win'], '#{@park_held}')
                if held and held.strip():
                    activate(fid)  # died after exit, before held acknowledgement
    with locked(fid) as path:
        r = durable.read(path)
        if not r or r['sid'] != w['sid'] or r['agent'] != w['agent']:
            return
        if r.get('phase') != 'active':
            return  # An exit refused by the native engine never enables timers.
        pending = r.get('pending')
        ledger = Path(r['ledger']) if r.get('ledger') else None
        if ledger:
            loop = loop_module()
            with loop.locked(ledger) as source:
                next_at = ledger_due(r)
                if not pending and (not next_at or next_at > at or not loop.durable_ready(source, at)):
                    return
                if not pending:
                    due_ids = [j['id'] for j in fleet_cron.pending(source['schedule'], at)] if 'jobs' in source['schedule'] else []
                    pending = dict(delivery=str(uuid.uuid5(uuid.UUID(fid), 'ledger:' + str(next_at))),
                                   next=next_at, prompt=loop.wakeup_prompt(source['schedule'], at), rounds=[],
                                   ledger_due=next_at, due_ids=due_ids)
                    r['pending'] = pending
                    durable.atomic(path, r)
        due = [j for j in r['jobs'] if j['next'] is not None and j['next'] <= at]
        if not pending and not due:
            return
        if not pending:
            if any(j['kind'] == 'durable' for j in due) and durable.gate(fid) != 'deliver':
                return
            rounds = [(j['id'], j['next']) for j in due]
            delivery = str(uuid.uuid5(uuid.UUID(fid), json.dumps(rounds)))
            pending = dict(delivery=delivery, rounds=rounds, next=min(j['next'] for j in due),
                           prompt='\n\n'.join(j['prompt'] for j in due))
            r['pending'] = pending
            save(path, r)  # write-ahead, before gate.say may launch the first turn
    # Never hold the contract lock while taking the session gate's fid lock.
    # The same ID enters the same existing gate record on every retry.
    gate.say(SimpleNamespace(fid=fid, text_file=None, text=pending['prompt'], image=[],
                             delivery=pending['delivery'], why='定时', next_at=pending['next']))
    delivery = gate.find(gate.records(fid), pending['delivery'])
    if not delivery or delivery.get('state') != 'sent':
        gate.settle(fid, pending['delivery'])
        delivery = gate.find(gate.records(fid), pending['delivery'])
    if not delivery or delivery.get('state') != 'sent':
        if delivery and delivery.get('state') == 'returned':
            with locked(fid) as path:
                r = durable.read(path)
                if r and r.get('pending', {}).get('delivery') == pending['delivery'] and not r.get('attention'):
                    r['attention'] = delivery.get('why') or 'delivery_returned'
                    save(path, r)
                    if not Path(str(gate.wake_path(fid, pending['delivery'])) + '.meta.failed').exists():
                        gate.park_log(fid, 'fail', '定时', result=r['attention'], next_at=pending['next'])
        return
    with locked(fid) as path:
        r = durable.read(path)
        if not r or r.get('pending', {}).get('delivery') != pending['delivery']:
            return
        if r.get('ledger'):
            loop = loop_module()
            with loop.locked(Path(r['ledger'])) as source:
                # defer/stop may have run in the accepted turn already. Never
                # overwrite the owner's newer cadence with our acknowledgement.
                if (source['schedule'].get('next_run_at') == pending['ledger_due']
                        and source.get('status') in ('active', 'waiting-quota')):
                    loop.delivered(source, at, pending['due_ids'], pending['delivery'], 'Park gate accepted the original prompt')
                    loop.save(Path(r['ledger']), source)
            r.pop('pending', None)
            r['parked'] = False
            r['next'] = ledger_due(r)
            durable.atomic(path, r)
            return
        rounds = dict(pending['rounds'])
        for job in r['jobs']:
            if job['id'] in rounds and job['next'] == rounds[job['id']]:
                job['next'] = following(job, max(at, rounds[job['id']])) if job['recurring'] else None
        r.pop('pending', None)
        r['parked'] = False
        save(path, r)
        if r.get('durable') and not any(j['kind'] == 'durable' and j['next'] is not None for j in r['jobs']):
            durable.complete(fid, pending['delivery'])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=('export', 'activate', 'tick', 'restore', 'stop'))
    p.add_argument('--fid')
    p.add_argument('--sid')
    p.add_argument('--now', type=float)
    p.add_argument('--owned', action='store_true')
    p.add_argument('--job')
    a = p.parse_args()
    try:
        if a.command == 'export':
            print(json.dumps(export(a.fid)))
        elif a.command == 'activate':
            activate(a.fid)
        elif a.command == 'restore':
            return 0 if restore(a.fid, a.sid, a.owned) else 1
        elif a.command == 'stop':
            with locked(a.fid) as path:
                r = durable.read(path)
                if r:
                    if r.get('ledger'):
                        raise ValueError('use fleet-loop.py stop in the owning session for this ledger')
                    for job in r['jobs']:
                        if a.job is None or job['id'] == a.job:
                            job['next'] = None
                    save(path, r)
        else:
            paths = [path_for(a.fid)] if a.fid else sorted((gate.conf_dir() / 'wake').glob('*.json'))
            failed = False
            for path in paths:
                try:
                    tick(path.stem, a.now)
                except (OSError, ValueError, KeyError, TypeError) as error:
                    print('park wake ' + path.stem + ': ' + str(error), file=sys.stderr)
                    failed = True
            return int(failed)
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('park wake: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
