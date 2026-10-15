"""Bounded timezone-aware cron plans for a single Fleet conversation writer."""
import datetime
import math
import time
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
from fleet_loop_mark import _cron_field


def fields(cron):
    parts = cron.split()
    if len(parts) != 5:
        raise ValueError('cron needs five fields')
    values = [_cron_field(v, lo, hi) for v, (lo, hi) in
              zip(parts, ((0,59),(0,23),(1,31),(1,12),(0,7)))]
    if any(not v for v in values):
        raise ValueError('unsupported cron expression')
    if 7 in values[4]:
        values[4].add(0)
    return parts, values


def _match(parts, values, zone, tick):
    minute, hour, dom, month, dow = values
    dt = datetime.datetime.fromtimestamp(tick, zone)
    d, w = dt.day in dom, (dt.weekday()+1) % 7 in dow
    day = (d or w) if not (parts[2].startswith('*') or parts[4].startswith('*')) else (d and w)
    return dt.minute in minute and dt.hour in hour and dt.month in month and day


def final_fire(job):
    """A recurring job's last round: native 2.1.295 delivers the first fire at or
    after its expiry (createdAt + 7 days) and only then deletes the job."""
    if job['expires_at'] is None or not job.get('recurring', True):
        return None
    parts, values = fields(job['cron'])
    zone = ZoneInfo(job['timezone'])
    tick = math.ceil(job['expires_at'] / 60) * 60
    end = tick + 8 * 86400
    while tick < end:
        if _match(parts, values, zone, tick):
            return tick
        tick += 60
    return None


def next_fire(job, after):
    parts, values = fields(job['cron'])
    zone = ZoneInfo(job['timezone'])
    # Recurring native jobs expire after one final round; one-shots may have only a firing date.
    horizon = after + (8 if job.get('recurring', True) else 366) * 86400
    last = final_fire(job)
    if job['expires_at'] is not None and not job.get('recurring', True):
        horizon = min(job['expires_at'], horizon)
    elif last is not None:
        horizon = min(last + 60, horizon)
    tick = (int(after) // 60 + 1) * 60
    while tick < horizon:
        if _match(parts, values, zone, tick):
            return tick
        tick += 60
    return None


def plan(value, now=None):
    now = time.time() if now is None else now
    jobs = value.get('jobs')
    if not isinstance(jobs, list) or not 1 <= len(jobs) <= 50:
        raise ValueError('cron plan needs 1..50 independent jobs')
    result, ids = [], set()
    for raw in jobs:
        if not isinstance(raw, dict):
            raise ValueError('cron job must be an object')
        job = {k: raw.get(k) for k in ('id','prompt','cron','timezone','expires_at','stop_when')}
        for k in ('id','prompt','cron','timezone'):
            if not isinstance(job[k], str) or not job[k].strip():
                raise ValueError('cron job requires explicit ' + k)
        # Empty means explicitly no additional stop condition; missing is unknown.
        if not isinstance(job['stop_when'], str):
            raise ValueError('cron job requires explicit stop_when (empty for none)')
        job['recurring'] = raw.get('recurring', True)
        if type(job['recurring']) is not bool:
            raise ValueError('cron recurring must be a boolean')
        if job['id'] in ids or len(job['prompt'].encode()) > 65536:
            raise ValueError('duplicate cron identity or oversized prompt')
        ids.add(job['id'])
        fields(job['cron'])
        try:
            ZoneInfo(job['timezone'])
        except (ZoneInfoNotFoundError, ValueError) as error:
            raise ValueError('unknown cron timezone') from error
        expiry = job['expires_at']
        if 'expires_at' not in raw or (expiry is None and job['recurring']):
            raise ValueError('cron expiry must be explicit (null only for one-shot)')
        if expiry is not None and (type(expiry) not in (int,float) or not math.isfinite(expiry)
                                  or expiry > now+(8 if job['recurring'] else 366)*86400):
            raise ValueError('cron expiry exceeds the bounded native lifetime')
        due = raw.get('next_run_at', next_fire(job, now))
        last = final_fire(job) if job['recurring'] else expiry
        if due is not None and (type(due) not in (int,float) or not math.isfinite(due)
                                or (last is not None and (due > last if job['recurring'] else due >= last))):
            raise ValueError('invalid cron next_run_at')
        if due is not None and next_fire(job, due-60) != due:
            raise ValueError('cron next_run_at must preserve its wall-clock phase')
        job['next_run_at'] = due
        result.append(job)
    plan = {'jobs':result}
    refresh(plan)
    return plan


def refresh(schedule):
    due = [j['next_run_at'] for j in schedule['jobs'] if j['next_run_at'] is not None]
    schedule['next_run_at'] = min(due) if due else None


def pending(schedule, now):
    # A recurring job's final round may land after its expiry (final_fire).
    return [j for j in schedule['jobs'] if j['next_run_at'] is not None and j['next_run_at'] <= now]


def advance(schedule, now):
    for job in schedule['jobs']:
        if job['next_run_at'] is not None and job['next_run_at'] <= now:
            job['next_run_at'] = next_fire(job, now) if job.get('recurring', True) else None
    refresh(schedule)
