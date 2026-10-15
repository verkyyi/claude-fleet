"""Read exact native CronList evidence; never infer live tasks from CronCreate."""
import datetime
import json
import os
import re
from pathlib import Path
import subprocess
import time
import fleet_iso

from fleet_loop_mark import claude_tool_results, parse, prune
from fleet_cron import plan, next_fire, refresh


def refuse_durable():
    raise ValueError('native durable task has no proven successor execution owner; '
                     'switch refused, source and native tasks stay running')


def check_durable_store():
    """Persistence is not execution. Check even without a process-local marker:
    another session may have created this project's task. Never mutate the table
    or infer that an overdue task has already fired."""
    home = Path.home().resolve()
    try:
        data = json.loads((home/'.claude/scheduled_tasks.json').read_text())
    except FileNotFoundError:
        return
    entries = data.get('tasks', data.get('jobs')) if isinstance(data, dict) else data
    if not isinstance(entries, list):
        raise ValueError('unknown native durable task table; execution owner cannot be verified')
    for record in entries:
        project = record.get('createdInProject') if isinstance(record, dict) else None
        if not isinstance(project, str) or not Path(project).is_absolute():
            raise ValueError('unknown native durable task project; execution owner cannot be verified')
        if Path(project).resolve() == home:
            refuse_durable()


def process_start(pid):
    text = subprocess.check_output(['ps','-p',str(pid),'-o','lstart='], text=True,
                                   env=dict(os.environ, LC_ALL='C'), timeout=5).strip()
    return datetime.datetime.strptime(text, '%a %b %d %H:%M:%S %Y').timestamp()


def rows(response):
    if isinstance(response, str):
        try:
            response = json.loads(response)
        except ValueError:
            # Native CronList is a text preview on some versions. It confirms
            # membership/recurrence, not the full truncated prompt or durability.
            parsed = []
            for line in response.strip().splitlines():
                match = re.fullmatch(r'([\w-]+) — (.+?) \((recurring|one-shot)\)( \[session-only\])?: (.+)', line)
                if not match:
                    raise ValueError('unrecognized CronList text; need exact task evidence')
                ident, cadence, kind, session_only, preview = match.groups()
                row = dict(id=ident, recurring=kind=='recurring', prompt_preview=preview)
                if len(cadence.split()) == 5: row['cron'] = cadence
                if session_only: row['durable'] = False
                parsed.append(row)
            if not parsed:
                raise ValueError('empty CronList text is not proof of no tasks')
            return parsed
    if isinstance(response, dict):
        response = response.get('jobs', response.get('tasks'))
    if not isinstance(response, list) or any(not isinstance(j, dict) for j in response):
        raise ValueError('ambiguous CronList task list')
    return response


def live_list(transcript, pid, now):
    start = process_start(pid)
    latest = None
    changed = False
    for name, inp, response, use_ts, result_ts in claude_tool_results(
            Path(transcript).read_text().splitlines(), ('CronList','CronCreate','CronDelete','ScheduleWakeup'), strict=True):
        at = fleet_iso.parse(result_ts).timestamp() if result_ts else 0
        if at < start:
            continue  # A previous native process's timers are not this process's.
        if name == 'CronList':
            latest = (response, at)
            changed = False
        else:
            changed = True
    if latest is None or changed or not 0 <= now-latest[1] <= 300:
        raise ValueError('fresh CronList from this exact live source is required (no later scheduler mutation)')
    return rows(latest[0])


def has_native_activity(transcript, pid):
    start = process_start(pid)
    for _, _, _, use_ts, result_ts in claude_tool_results(
            Path(transcript).read_text().splitlines(), ('CronList','CronCreate','CronDelete','ScheduleWakeup'), strict=True):
        at = fleet_iso.parse(result_ts).timestamp() if result_ts else None
        if at is None or at >= start:
            return True
    return False


def validate(raw, transcript, pid, sid, fid, mark, now=None):
    check_durable_store()
    now = time.time() if now is None else now
    proof = raw.get('native_source', {})
    if (proof.get('pid') != int(pid) or proof.get('session_id') != sid or proof.get('fleet_id') != fid
            or proof.get('confirmed') is not True):
        raise ValueError('cron plan must be confirmed by the exact source process/session/fleet identity')
    native = live_list(transcript, pid, now)
    schedule = plan(raw, now)
    by_id = {str(j.get('id')):j for j in native}
    if len(by_id) != len(native) or set(by_id) != {j['id'] for j in schedule['jobs']}:
        raise ValueError('cron plan does not match the current native task identities')
    moved = []
    for job in schedule['jobs']:
        original = by_id[job['id']]
        evidence = proof.get('job_evidence', {}).get(job['id'], {})
        if (type(original.get('recurring')) is not bool
                or original['recurring'] != job['recurring']):
            raise ValueError('cron recurrence differs from the live task')
        # A durable record alone cannot prove execution after the source exits.
        durable = original.get('durable', evidence.get('durable', {}).get('value'))
        if type(durable) is not bool or ('durable' not in original and not evidence.get('durable', {}).get('source')):
            raise ValueError('cron native durability must be proven before handover')
        # Missing native timezone/expiry requires the source's explicit evidence,
        # never an interval or the marker's grace-extended expiry as a guess.
        for key in ('prompt', 'cron', 'timezone', 'expires_at', 'stop_when'):
            if key in original:
                if original[key] != job[key]:
                    raise ValueError('cron ' + key + ' differs from native evidence')
            elif evidence.get(key, {}).get('value') != job[key] or not evidence.get(key, {}).get('source'):
                raise ValueError('source evidence is required for cron ' + key)
        preview = original.get('prompt_preview')
        if preview and not job['prompt'].startswith(preview.removesuffix('…').removesuffix('...')):
            raise ValueError('full cron prompt disagrees with the current preview')
        if durable:
            refuse_durable()
        moved.append(job)
        if job['next_run_at'] is None or (job['expires_at'] is not None and job['expires_at'] <= now):
            raise ValueError('cron task is no longer active')
        if job['next_run_at'] != next_fire(job, now):
            raise ValueError('cron plan no longer names the next native calendar round')
        if job['next_run_at'] <= now + 60:
            raise ValueError('native cron is due within the cutover margin; let that round finish before switching')
    marker = prune(parse(mark), int(now))
    marked = {j for j, _ in marker['ids']}
    if marker['next'] or not {j['id'] for j in moved} <= marked <= set(by_id):
        raise ValueError('native scheduler mark is unknown, mixed, or disagrees with CronList')
    schedule.update(jobs=moved)
    refresh(schedule)
    return schedule


def export(jobs_file, session, pane):
    """Source-only preparation; never stops a native job or switches a pane."""
    if pane != os.environ.get('TMUX_PANE') or not os.environ.get('TMUX'):
        raise ValueError('export the cron plan from the owning source session')
    controller = Path(__file__).with_name('fleet-transfer.sh')
    source = json.loads(subprocess.check_output(
        ['bash',str(controller),'--session',session,'--window',pane,'--to','codex','--inspect'],
        text=True, timeout=30))
    if source['agent'] != 'claude':
        raise ValueError('native cron export requires the Claude source')
    def opt(key):
        return subprocess.check_output(['tmux','-L',session,'show-options','-wqv','-t',pane,'@'+key],
                                       text=True, timeout=5).strip()
    fid, mark = opt('fleet_id'), opt('loop')
    raw = json.loads(Path(jobs_file).read_text())
    proof = raw.setdefault('native_source', {})
    # The caller must supply confirmed=True and explicit per-job evidence;
    # source identity is read here, never supplied by an unrelated transcript.
    proof.update(pid=source['pid'], session_id=source['session_id'], fleet_id=fid)
    validate(raw, source['transcript'], source['pid'], source['session_id'], fid, mark)
    root = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home()/'.config/claude-fleet'))) / 'transfer-plans'
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not fid or any(c not in 'abcdefABCDEF0123456789-' for c in fid):
        raise ValueError('source lacks a valid lifelong identity')
    path = root / (fid + '.json')
    temp = path.with_suffix('.tmp')
    with temp.open('w') as f:
        os.chmod(temp, 0o600)
        json.dump(raw, f, ensure_ascii=False, indent=2)
    temp.replace(path)
    print(path)
