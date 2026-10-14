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


def next_fire(job, after):
    parts, (minute, hour, dom, month, dow) = fields(job['cron'])
    zone = ZoneInfo(job['timezone'])
    # Native jobs expire within seven days. Bound scans even for impossible dates.
    end = min(job['expires_at'], after + 8 * 86400)
    tick = (int(after) // 60 + 1) * 60
    while tick < end:
        dt = datetime.datetime.fromtimestamp(tick, zone)
        d, w = dt.day in dom, (dt.weekday()+1) % 7 in dow
        day = (d or w) if not (parts[2].startswith('*') or parts[4].startswith('*')) else (d and w)
        if dt.minute in minute and dt.hour in hour and dt.month in month and day:
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
        for k in ('id','prompt','cron','timezone','stop_when'):
            if not isinstance(job[k], str) or not job[k].strip():
                raise ValueError('cron job requires explicit ' + k)
        if job['id'] in ids or len(job['prompt'].encode()) > 65536:
            raise ValueError('duplicate cron identity or oversized prompt')
        ids.add(job['id'])
        fields(job['cron'])
        try:
            ZoneInfo(job['timezone'])
        except (ZoneInfoNotFoundError, ValueError) as error:
            raise ValueError('unknown cron timezone') from error
        expiry = job['expires_at']
        if type(expiry) not in (int,float) or not math.isfinite(expiry) or expiry > now+8*86400:
            raise ValueError('cron expiry must be explicit and within eight days')
        due = raw.get('next_run_at', next_fire(job, now))
        if due is not None and (type(due) not in (int,float) or not math.isfinite(due) or due >= expiry):
            raise ValueError('invalid cron next_run_at')
        if due is not None and next_fire(job, due-60) != due:
            raise ValueError('cron next_run_at must preserve its wall-clock phase')
        job['next_run_at'] = due if expiry > now else None
        result.append(job)
    plan = {'jobs':result}
    refresh(plan)
    return plan


def refresh(schedule):
    due = [j['next_run_at'] for j in schedule['jobs'] if j['next_run_at'] is not None]
    schedule['next_run_at'] = min(due) if due else None


def pending(schedule, now):
    return [j for j in schedule['jobs'] if j['next_run_at'] is not None
            and j['next_run_at'] <= now < j['expires_at']]


def advance(schedule, now):
    for job in schedule['jobs']:
        if job['next_run_at'] is not None and job['next_run_at'] <= now:
            job['next_run_at'] = next_fire(job, now)
    refresh(schedule)
