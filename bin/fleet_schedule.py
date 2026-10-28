#!/usr/bin/env python3
"""Self-service metadata on the existing node service registry; no scheduler.

Invoked only by the supervisor's schedule command with a fixed tenant login.
The hub owns authorizations; its revisioned intent is installed atomically here.
"""
import fcntl
import json
import os
import re

ID = re.compile(r'^schedule-[a-z0-9-]{1,38}$')
FIELDS = {'id','revision','name','prompt','at','cron','timezone','enabled','deleted','delivery','repo','entry','agent','once_at','execution'}

def policy(doc):
    p=doc.get('execution') or {}
    if not isinstance(p,dict) or set(p)-{'timeout_seconds','retries','retry_delay_seconds'}:
        raise ValueError('invalid execution policy')
    timeout=p.get('timeout_seconds') or 3600
    retries=p.get('retries',0 if doc.get('once_at') else 2)
    delay=p.get('retry_delay_seconds') or 300
    for value,lo,hi in ((timeout,60,3600),(retries,0,2),(delay,300,86400)):
        if type(value) is not int or not lo<=value<=hi:raise ValueError('invalid execution policy range')
    return timeout,retries,delay

def validate(sup, doc):
    if not isinstance(doc, dict) or set(doc) - FIELDS:
        raise ValueError('unsupported schedule fields')
    if not ID.fullmatch(str(doc.get('id', ''))):
        raise ValueError('invalid schedule id')
    if type(doc.get('revision')) is not int or doc['revision'] < 1:
        raise ValueError('revision must be positive')
    for field, limit in (('name',120),('prompt',16000)):
        v=doc.get(field)
        if not isinstance(v,str) or not v.strip() or len(v)>limit or '\0' in v:
            raise ValueError('invalid '+field)
    if type(doc.get('enabled')) is not bool or type(doc.get('deleted')) is not bool:
        raise ValueError('enabled and deleted must be booleans')
    policy(doc)
    if doc.get('agent','') not in ('','claude','codex'):
        raise ValueError('agent must be claude or codex (empty uses fleet default)')
    delivery=doc.get('delivery') or {}
    if not isinstance(delivery,dict) or set(delivery)-{'wechat','livepage'} or any(type(v) is not bool for v in delivery.values()):
        raise ValueError('invalid delivery')
    if doc.get('entry') and not sup.SVC_NAME_RE.fullmatch(doc['entry']):raise ValueError('invalid existing task name')
    repo=doc.get('repo','')
    if repo and (not isinstance(repo,str) or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repo)):
        raise ValueError('invalid repo')
    sched={'tz':doc.get('timezone') or 'Asia/Shanghai'}
    if doc.get('at'): sched['at']=doc['at']
    if doc.get('cron'): sched['cron']=doc['cron']
    if sup.task_tz(sched) is False: raise ValueError('unknown timezone')
    if doc.get('once_at') is not None:
        stamp=doc['once_at']
        if type(stamp) is not int or not 1<=stamp<=253402300799 or doc.get('at') or doc.get('cron') or doc.get('entry'):
            raise ValueError('once_at cannot combine with at, cron or adopt')
        return 0
    mins,hours,*_=sup.task_cron(sched)
    times=sorted(h*60+m for h in hours for m in mins)
    if not times or any(b-a < 60 for a,b in zip(times,times[1:]+[times[0]+1440])):
        raise ValueError('a schedule may run at most once an hour')
    return len(times)

def apply(sup, paths, login, doc):
    validate(sup,doc)
    if not sup.LOGIN_RE.fullmatch(login): raise ValueError('invalid login')
    directory=sup.service_dir(paths,login)
    sup._svc_mkdir(directory)
    with open(os.path.join(directory,'.schedule.lock'),'a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        name=doc.get('entry') or doc['id']
        path=os.path.join(directory,name+'.json')
        old=sup.read_json(path,None)
        previous=(old or {}).get('managed_schedule')
        if old and not previous:
            ts=(sup.read_json(paths.state_file,{}) or {}).get('agent_tasks',{}).get(login+'/'+name,{})
            if not doc.get('entry') or old.get('kind')!='task' or old.get('state')!='stopped' or ts.get('state') in ('running','interrupted','waiting','retrying'):
                raise ValueError('pause the existing task and wait for its run to finish before adopting')
            if old.get('prompt')!=doc['prompt'] or sup.task_cron(old.get('schedule'))!=sup.task_cron({'at':doc['at']} if doc.get('at') else {'cron':doc['cron']}) or (old.get('schedule') or {}).get('tz')!=doc['timezone']:
                raise ValueError('adoption must preserve the existing prompt, recurrence and timezone')
            if old.get('agent','')!=doc.get('agent',''):
                raise ValueError('adoption must preserve the existing agent')
        if not old and doc.get('entry'):raise ValueError('existing task not found in this login')
        if previous:
            if previous['id']!=doc['id']:raise ValueError('existing task is already managed')
            if previous==doc: return old
            if doc['revision']<=previous['revision'] or previous.get('deleted'):
                raise ValueError('stale schedule revision')
        elif doc['revision']!=1:
            # A missed initial create is safely reconstructible from full desired state.
            # Deleted first remains a tombstone, so a late create cannot revive it.
            pass
        sched={'tz':doc.get('timezone') or 'Asia/Shanghai','managed':True}
        if doc.get('once_at'):sched['once_at']=doc['once_at']
        else:sched['at' if doc.get('at') else 'cron']=doc.get('at') or doc.get('cron')
        timeout,retries,delay=policy(doc)
        now=sup.task_clock()
        svc=dict(old or {},name=name,login=login,kind='task',exec=None,
                 prompt=doc['prompt'],agent=doc.get('agent',''),schedule=sched,managed_schedule=doc,
                 state='enabled' if doc['enabled'] and not doc['deleted'] else 'stopped',
                 retries=retries,retry_delay=delay,timeout=timeout,idle=600,changed=now,
                 added=(old or {}).get('added',now))
        if not old or old.get('schedule')!=sched or old.get('state')!=svc['state']:
            svc['rescheduled']=now
        why=sup.service_check(svc,login,name)
        if why: raise ValueError(why)
        sup.write_json(path,svc,0o600)
        return svc

def command(sup, paths, rest):
    if len(rest)!=2 or rest[0]!='--login' or not sup.LOGIN_RE.fullmatch(rest[1]):
        raise ValueError('schedule --login LOGIN reads one JSON command on stdin')
    login=rest[1]
    if sup.pod_self_uid(login) is None and not sup._svc_root('schedule'): return 1
    if sup._svc_ident(login) is None: return 1
    import sys
    body=sys.stdin.read(262145)
    if len(body)>262144: raise ValueError('request too large')
    request=json.loads(body)
    if set(request)-{'action','schedule','run_id'}: raise ValueError('unsupported command')
    doc=request.get('schedule')
    action=request.get('action')
    if action=='apply':
        svc=apply(sup,paths,login,doc)
        print(json.dumps({'revision':doc['revision'],'schedule':sup.task_summary(paths,svc,{})}))
    elif action=='run-now':
        validate(sup,doc)
        svc=sup.read_json(os.path.join(sup.service_dir(paths,login),(doc.get('entry') or doc['id'])+'.json'),{})
        if svc.get('managed_schedule')!=doc or doc['deleted']: raise ValueError('stale or deleted schedule')
        run=request.get('run_id','')
        if not re.fullmatch(r'[a-zA-Z0-9-]{1,100}',run): raise ValueError('invalid run id')
        directory=os.path.join(paths.logins,login,'run')
        sup._svc_mkdir(directory)
        path=os.path.join(directory,doc.get('entry') or doc['id'])
        with open(os.path.join(directory,'.schedule.lock'),'a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            pending=sup.read_json(path,{})
            if pending and pending.get('run_id')!=run: raise ValueError('another manual run is queued')
            sup.write_json(path,{'at':sup.task_clock(),'run_id':run},0o600)
        print(json.dumps({'run_id':run,'status':'queued'}))
    else: raise ValueError('unknown schedule action')
    return 0
