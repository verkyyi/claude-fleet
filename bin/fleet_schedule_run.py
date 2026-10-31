#!/usr/bin/env python3
"""One admitted attempt, opened by the existing task daemon as its own login.

Results are durably spooled before upload. Restarting the daemon adopts the
same native session; it never mistakes spawning a process for a final answer.
"""
import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import unicodedata
import uuid

BIN=Path(__file__).resolve().parent
sys.path.insert(0,str(BIN))
from fleet_node_http import call, Unreachable

class AdmissionCancelled(Exception):
    pass


def http(path,body):
    status,raw=call('POST','/v1/node/schedules/'+path,body)
    if path=='admit' and status in (400,403,404,409): raise AdmissionCancelled('schedule changed before admission')
    if status!=200: raise Unreachable('schedule request refused (%s): %s'%(status,raw[:300]))
    return json.loads(raw)

def atomic(path,value):
    tmp=path.with_name(path.name+'.tmp')
    fd=os.open(tmp,os.O_CREAT|os.O_TRUNC|os.O_WRONLY,0o600)
    with os.fdopen(fd,'w') as f: json.dump(value,f);f.flush();os.fsync(f.fileno())
    os.replace(tmp,path)

def final_from_lines(lines,agent,sid):
    final='';complete=False;matched=False
    for line in lines:
        try: row=json.loads(line)
        except ValueError: continue
        if agent=='codex':
            payload=row.get('payload') or {}
            if row.get('type')=='session_meta':
                if payload.get('id',payload.get('session_id'))!=sid:return ''
                matched=True
            if row.get('type')=='event_msg' and payload.get('type') in ('task_started','turn_started'):
                final='';complete=False
            if row.get('type')=='response_item' and payload.get('type')=='message' and payload.get('role')=='assistant' and payload.get('phase')=='final_answer':
                final='\n'.join(b.get('text','') for b in payload.get('content',[]) if b.get('type') in ('output_text','text'))
            if row.get('type')=='event_msg' and payload.get('type') in ('task_complete','turn_complete'):
                # A native completion event's last_agent_message is the final,
                # not a commentary/tool chunk from an unfinished turn.
                final=payload.get('last_agent_message') or final;complete=True
            if row.get('type')=='event_msg' and payload.get('type') in ('turn_aborted','error'):complete=False
        else:
            if row.get('sessionId') and row['sessionId']!=sid:continue
            if row.get('sessionId')==sid:matched=True
            if row.get('isSidechain') or row.get('isMeta') or row.get('isCompactSummary'):continue
            if row.get('type')=='user':final='';complete=False
            msg=row.get('message') or {}
            if row.get('type')=='assistant':
                if msg.get('stop_reason')=='end_turn':
                    final='\n'.join(b.get('text','') for b in msg.get('content',[]) if b.get('type')=='text')
                    complete=True
                elif msg.get('stop_reason')=='tool_use':complete=False
    return final.strip() if matched and complete else ''

def tmux(session,*args):
    p=subprocess.run(['tmux','-L',session,*args],text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10)
    return p.stdout.rstrip('\r\n') if p.returncode==0 else ''

def native(session,wid):
    raw=tmux(session,'display-message','-p','-t',wid,'#{@fleet_id}\t#{@cc_agent}\t#{@cc_session_id}\t#{@codex_identity}\t#{pane_current_path}\t#{@claude_state}\t#{@worktree}')
    parts=raw.split('\t')
    if len(parts)!=7:return {}
    fid,agent,sid,codex,cwd,state,worktree=parts
    path=''
    if agent=='codex':
        try:
            spec=importlib.util.spec_from_file_location('schedule_codex',BIN/'fleet-codex-session.py')
            mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
            data=mod.identity(wid,session);sid=data.get('session_id','')
            path,_=mod.rollout(data)
        except (ValueError,OSError,subprocess.SubprocessError):return {'fid':fid,'agent':agent,'sid':'','path':'','state':state}
    else:
        try:uuid.UUID(sid)
        except ValueError:return {'fid':fid,'agent':agent,'sid':'','path':'','state':state}
        # Use the established path encoder rather than a second project resolver.
        got=subprocess.run(['bash','-c','. "$1/fleet-lib.sh"; fleet_transcript_dir "$2"','_',str(BIN),worktree or cwd],text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10)
        path=str(Path(got.stdout.strip())/(sid+'.jsonl')) if got.returncode==0 else ''
    return {'fid':fid,'agent':agent,'sid':sid,'path':path,'state':state}

def conclusion(rec):
    try:
        path=Path(rec.get('path',''))
        if not path.is_file() or path.stat().st_size>64*1024*1024:return ''
        with path.open(errors='replace') as f:return final_from_lines(f,rec.get('agent','claude'),rec.get('sid',''))
    except OSError:return ''

def cols(ch):
    return 2 if unicodedata.east_asian_width(ch) in ('W','F') else 1

def run_title(doc,started,attempt):
    """A person reads this, not a key: the schedule's name, its day and the
    attempt past the first — the hub's session_title (fleet_schedules.go) —
    in the 24 columns a window name keeps (dash-raw-session.sh): the name is
    clipped, never the day."""
    try:
        from zoneinfo import ZoneInfo
        day=datetime.datetime.fromtimestamp(started,ZoneInfo(doc.get('timezone') or 'Asia/Shanghai')).strftime('%m-%d')
    except (ImportError,ValueError,KeyError,OSError):
        day=time.strftime('%m-%d',time.localtime(started))
    tail=' '+day+(' #%d'%attempt if attempt>1 else '')
    name=' '.join(str(doc.get('name') or '').replace('#',' ').split()) or 'schedule'
    room=24-len(tail)
    if sum(map(cols,name))>room:
        out='';w=0
        for ch in name:
            if w+cols(ch)>room-1:break
            out+=ch;w+=cols(ch)
        name=out.rstrip()+'…'
    return name+tail

def attempt_window(session,name,rec):
    if rec.get('fid'):
        p=subprocess.run(['bash','-c','. "$1/fleet-lib.sh"; fleet_win_for_fid "$2" "$3"','_',str(BIN),rec['fid'],session],capture_output=True,text=True,timeout=15)
        if p.returncode==0 and p.stdout.strip():return p.stdout.strip()
        if p.returncode==2:raise ValueError('ambiguous attempt identity')
    # The attempt's key: @schedule_key, or the window name an older run gave it.
    windows=tmux(session,'list-windows','-a','-F','#{window_id}\t#{window_name}\t#{@schedule_key}').splitlines()
    matches={x.split('\t')[0] for x in windows if name in x.split('\t')[1:]}
    if len(matches)>1:raise ValueError('ambiguous attempt session')
    return next(iter(matches),'')

def busy(session,wid):
    loop=tmux(session,'display-message','-p','-t',wid,'#{@loop}')
    if loop:
        manifest=tmux(session,'display-message','-p','-t',wid,'#{@handoff_manifest}')
        args=['python3',str(BIN/'fleet_loop_mark.py'),'status','--value',loop]
        if manifest:args+=['--manifest',manifest]
        if subprocess.run(args,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15).returncode==0:return True
    p=subprocess.run(['bash','-c','. "$1/fleet-lib.sh"; fleet_window_bg_busy "$2" "$3" "" 1','_',str(BIN),session,wid],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
    return p.returncode!=1  # missing evidence holds the admission

def run():
    doc=json.loads(os.environ['FLEET_MANAGED_SCHEDULE'])
    slot=os.environ['FLEET_MANAGED_SLOT'];attempt=int(os.environ['FLEET_TASK_ATTEMPT'])
    manual=slot.startswith('manual-')
    root=Path(os.environ.get('FLEET_CONF_DIR',str(Path.home()/'.config/claude-fleet')))/'schedule-runs'
    root.mkdir(mode=0o700,parents=True,exist_ok=True)
    key=hashlib.sha256((doc['id']+':'+slot+':'+str(attempt)).encode()).hexdigest()[:24]
    local=root/(key+'.json')
    with (root/(key+'.lock')).open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:return 75
        try:rec=json.loads(local.read_text())
        except (OSError,ValueError):rec={}
        if rec.get('result'):
            http('finish',rec['result'])
            return 0 if rec['result']['state']=='succeeded' else 13
        session=os.environ.get('FLEET_TASK_FLEET')
        if not session:
            fleets=list((root.parent/'fleets').glob('*/conf'))
            if len(fleets)!=1:raise ValueError('one personal fleet is required')
            session=fleets[0].parent.name
        spawn=Path.home()/'.claude/fleet/bin/dash-raw-session.sh'
        if not spawn.is_file() or not os.access(spawn,os.X_OK):raise ValueError('personal runtime is still being prepared')
        ans=http('admit',{'id':doc['id'],'revision':doc['revision'],'slot':slot,'attempt':attempt,'manual':manual})['run']
        if ans['state']!='running':return 0 if ans['state']=='succeeded' else 13
        name='schedule-'+key
        wid=attempt_window(session,name,rec)
        if not wid and not rec.get('launch_intent'):
            # Commit the launch intent first. A crash after fork must never
            # cause a second session, even if stdout was lost or renamed.
            rec.update(launch_intent=True,started=ans['started'],fid=str(uuid.uuid5(uuid.NAMESPACE_URL,doc['id']+':'+slot+':'+str(attempt))));atomic(local,rec)
            args=[str(spawn),'--origin','hub','--source','schedule','--reap-origin','probe','--reap','done:15m','--print','--fid',rec['fid'],'--name',run_title(doc,ans['started'],attempt),'--prompt',os.environ['FLEET_TASK_PROMPT']]
            if doc.get('agent'):args+=['--agent',doc['agent']]
            args+=['--repo',doc['repo']] if doc.get('repo') else ['--no-repo']
            try:
                p=subprocess.run(args+[session],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120)
                receipt=next((l.split('\t') for l in p.stdout.splitlines() if re.match(r'^@[0-9]+\t',l)), [])
                wid=receipt[0] if receipt else attempt_window(session,name,rec)
                if len(receipt)>3:rec['fid']=receipt[3]
                if p.returncode and not wid:
                    rec['result']={'run_id':ans['id'],'state':'failed','summary':'','error':'session start refused','session_id':''}
                    atomic(local,rec);http('finish',rec['result']);return 11
            except subprocess.TimeoutExpired:
                wid=attempt_window(session,name,rec)
            if wid:
                rec.update(spawned=True,wid=wid)
                rec['fid']=rec.get('fid') or tmux(session,'display-message','-p','-t',wid,'#{@fleet_id}')
            atomic(local,rec)
        if wid:
            tmux(session,'set-option','-w','-t',wid,'@schedule_id',doc['id'])
            tmux(session,'set-option','-w','-t',wid,'@schedule_key',name)
            tmux(session,'set-option','-w','-t',wid,'@schedule_run_id',ans['id'])
        started=rec.get('started',ans['started']);last=rec.get('native',{});summary='';why=''
        while time.time()-started<3600:
            if not wid:wid=attempt_window(session,name,rec)
            current=native(session,wid) if wid else {}
            if current:
                last=current;rec.update(native=last,wid=wid,fid=last.get('fid'),spawned=True);atomic(local,rec)
            summary=conclusion(last)
            if summary and (not current or current.get('state') in ('done','idle','exited')):
                done=os.environ.get('FLEET_TASK_DONE_FILE')
                if (not done or Path(done).exists()) and (not current or not busy(session,wid)):break
            if not current and time.time()-started>120:
                why='session start or completion could not be confirmed';break
            if current.get('state') in ('needs','blocked','ask'):
                why='task needs your input';break
            time.sleep(5)
        else:why='task exceeded its one-hour limit'
        if why:
            summary=''
            fid=last.get('fid') or rec.get('fid')
            if fid:
                # Stop only this attempt through Fleet's identity-aware lifecycle.
                p=subprocess.run([str(BIN/'fleet-worker-stop.sh'),session,'fid:'+fid],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=90)
                if p.returncode not in (0,5):raise ValueError('could not stop the timed-out session; admission remains held')
        result={'run_id':ans['id'],'state':'succeeded' if summary else 'failed','summary':summary[:32000],
                'error':why or ('' if summary else 'no final answer'),'session_id':rec.get('fid','')}
        rec['result']=result;atomic(local,rec)
        http('finish',result)
        print('schedule: '+result['state']+' — '+(summary.splitlines()[-1][:160] if summary else result['error']))
        return 0 if summary else 13

if __name__=='__main__':
    try:sys.exit(run())
    except AdmissionCancelled:
        sys.exit(74)
    except (Unreachable,OSError,ValueError,subprocess.SubprocessError) as e:
        print('schedule: deferred — '+str(e),file=sys.stderr);sys.exit(75)
