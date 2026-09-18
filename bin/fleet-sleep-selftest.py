#!/usr/bin/env python3
"""Real isolated tmux panes with deterministic native agent/identity fixtures."""
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

BIN=Path(sys.argv.pop(1)).absolute()
LIB=runpy.run_path(str(BIN/'fleet-sleep.py'))


class SleepTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory(prefix='fleet-sleep-test-')
        cls.root=Path(cls.tmp.name)
        cls.socket='sleep-test-'+str(os.getpid())
        cls.bin=cls.root/'bin'; cls.bin.mkdir()
        for name in ('fleet-sleep.py','.fleet-transfer.py','fleet-input.py','fleet-codex-session.py','fleet-codex-rpc.py','fleet_sleep_argv.py'):
            shutil.copyfile(BIN/name,cls.bin/name)
        cls.wt=cls.root/'scratch-1'; cls.wt.mkdir()
        cls.sid='11111111-1111-4111-8111-111111111111'
        cls.transcript=cls.root/'history.jsonl'; cls.transcript.write_text('{}\n')
        cls.env=dict(os.environ,FLEET_CONF_DIR=str(cls.root/'config'),FLEET_SLEEP_AFTER='1',FLEET_SLEEP='on')
        cls.agent=cls.root/'agent.py'
        cls.agent.write_text('''import os,sys,tty,json
tty.setraw(0)
print('\\033[2J\\033[H❯ ',end='',flush=True)
text=''
while True:
    c=os.read(0,1).decode()
    if c in ('\\r','\\n'):
        if text=='/exit': break
        text=''; print('\\033[2J\\033[H❯ ',end='',flush=True)
    else: text+=c
''')
        launcher=cls.bin/'fleet-claude.sh'
        launcher.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > '+str(cls.root/'launch.args')+'\nexec python3 '+str(cls.agent)+'\n')
        launcher.chmod(0o755)
        inspect=cls.bin/'fake-source.py'
        inspect.write_text('''#!/usr/bin/env python3
import json,subprocess,sys
a=sys.argv; session=a[a.index('--session')+1]; pane=a[a.index('--window')+1]
def opt(f):return subprocess.check_output(['tmux','-L',session,'display-message','-p','-t',pane,'#{'+f+'}'],text=True).strip()
if opt('pane_dead')=='1':sys.exit(1)
pid=int(opt('pane_pid'))
cmd=subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True)
if 'agent.py' not in cmd:sys.exit(1)
print(json.dumps(dict(agent='claude',session_id=SID,pid=pid,transcript=TRANSCRIPT,home='',registry='',session=session,window=opt('window_id'),pane=pane,worktree=WT,state='done',previous='',label='',subscription={},codex_identity={})))
'''.replace('SID',repr(cls.sid)).replace('TRANSCRIPT',repr(str(cls.transcript))).replace('WT',repr(str(cls.wt))))
        inspect.chmod(0o755)
        (cls.bin/'fleet-transfer.sh').write_text('exec python3 '+str(inspect)+' "$@"\n')
        # Minimal transition lock helper in the sandbox, never the user's leases.
        (cls.bin/'fleet-lib.sh').write_text('fleet_rotate_lease_file() { printf "%s" '+str(cls.root/'lease')+'; }\n'
            +'fleet_peer_send() { printf "%s\\n" "$2" >> '+str(cls.root/'messages')+'; }\n')
        cls.tm('new-session','-d','-s',cls.socket,'-x','100','-y','30','sleep 300')
        cls.tm('set-option','-g','remain-on-exit','on')

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['tmux','-L',cls.socket,'kill-server'],stderr=subprocess.DEVNULL)
        cls.tmp.cleanup()

    @classmethod
    def tm(cls,*args):
        return subprocess.check_output(['tmux','-L',cls.socket,*args],text=True,stderr=subprocess.PIPE).strip()

    def cli(self,*args,ok=True):
        p=subprocess.run(['python3',str(self.bin/'fleet-sleep.py'),args[0],'--session',self.socket,*args[1:]],env=self.env,text=True,capture_output=True,timeout=55)
        if ok:self.assertEqual(p.returncode,0,p.stderr)
        else:self.assertNotEqual(p.returncode,0,p.stdout)
        return p

    def setUp(self):
        self.pane=self.tm('new-window','-d','-P','-F','#{pane_id}','-t',self.socket,'-c',str(self.wt),'exec python3 '+str(self.agent))
        self.tm('set-option','-w','-t',self.pane,'@raw','1')
        for key,value in (('@claude_state','done'),('@cc_agent','claude'),('@worktree',str(self.wt))):
            self.stamp(key,value)
        self.pid=int(self.opt('pane_pid'))
        self.evidence=dict(session_id=self.sid,pane=self.pane,pid=self.pid,at=time.time()-60,background_tasks=[],session_crons=[],stop_hook_active=False,permission_mode='default',config_home=str(self.root/'claude'))
        self.stamp('@sleep_evidence',json.dumps(self.evidence))
        until=time.monotonic()+5
        while time.monotonic()<until:
            if LIB['INPUT']['snapshot'](self.socket,self.pane).get('state')=='empty':break
            time.sleep(.05)
        else:self.fail('fake CLI prompt did not become ready')

    def tearDown(self):self.tm('kill-window','-t',self.pane)
    def opt(self,key):return self.tm('display-message','-p','-t',self.pane,'#{'+key+'}')
    def stamp(self,key,value):self.tm('set-option','-w','-t',self.pane,key,str(value))

    def test_sleep_wake_exact_session_same_window(self):
        window=self.opt('window_id')
        dirty=self.wt/'uncommitted.txt';dirty.write_text('keep these bytes')
        self.cli('sleep',self.pane)
        self.assertEqual(self.opt('@worker_lifecycle'),'sleeping')
        self.assertFalse(LIB['alive'](self.pid))
        self.assertEqual(self.opt('window_id'),window)
        record=Path(self.opt('@sleep_record'))
        self.assertEqual(record.stat().st_mode&0o777,0o600)
        self.cli('wake',self.pane)
        self.assertEqual(self.opt('@worker_lifecycle'),'')
        self.assertEqual(self.opt('window_id'),window)
        args=(self.root/'launch.args').read_text().splitlines()
        self.assertEqual(args,['--agent','claude','--resume',self.sid,'--permission-mode','default'])
        self.assertEqual(json.loads(record.read_text())['resume_count'],1)
        self.assertEqual(dirty.read_text(),'keep these bytes')
        self.cli('wake',self.pane)
        self.assertEqual(json.loads(record.read_text())['resume_count'],1)

    def test_native_proof_required(self):
        for proof in ({},dict(self.evidence,pid=self.pid+1),dict(self.evidence,session_id='other'),dict(self.evidence,background_tasks=None),dict(self.evidence,background_tasks=[{'type':'shell'}]),dict(self.evidence,session_crons=[{}]),dict(self.evidence,stop_hook_active=True)):
            self.stamp('@sleep_evidence',json.dumps(proof))
            self.cli('sleep',self.pane,ok=False)
            self.assertTrue(LIB['alive'](self.pid))

    def test_pending_and_keep_awake_veto(self):
        for option,value in (('@claude_state','needs'),('@claude_state','working'),('@handoff_armed','1'),('@agent_transfer_request','x'),('@quota_failover','waiting'),('@sleep_keep_awake','1')):
            before=self.opt(option);self.stamp(option,value)
            self.cli('sleep',self.pane,ok=False)
            self.stamp(option,before)
        self.assertTrue(LIB['alive'](self.pid))

    def test_dry_run_does_not_exit_or_create_record(self):
        self.cli('sleep',self.pane,'--dry-run')
        self.assertTrue(LIB['alive'](self.pid))
        self.assertEqual(self.opt('@sleep_record'),'')

    def test_draft_veto_even_with_old_stop(self):
        self.tm('send-keys','-t',self.pane,'-l','unsent')
        # Fake CLI has no echo: draw the draft exactly as an agent would.
        self.tm('send-keys','-t',self.pane,'Enter')
        self.stamp('@sleep_evidence','')
        self.cli('sleep',self.pane,ok=False)
        analyzer=LIB['INPUT']['analyze']
        self.assertNotEqual(analyzer('❯ unsent',2,0,100)['state'],'empty')
        self.assertNotEqual(analyzer('❯ unsent',8,0,100)['state'],'empty')

    def test_concurrent_wakes_only_launch_once(self):
        self.cli('sleep',self.pane)
        argv=['python3',str(self.bin/'fleet-sleep.py'),'wake','--session',self.socket,self.pane]
        p=subprocess.Popen(argv,env=self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        second=subprocess.run(argv,env=self.env,capture_output=True,text=True,timeout=50)
        out,err=p.communicate(timeout=50)
        self.assertIn(0,(p.returncode,second.returncode),(err,second.stderr))
        self.assertEqual(json.loads(Path(self.opt('@sleep_record')).read_text())['resume_count'],1)

    def test_missing_history_retains_failed_worker(self):
        self.cli('sleep',self.pane)
        self.transcript.rename(self.root/'hidden-history')
        try:
            self.cli('wake',self.pane,ok=False)
            self.assertEqual(self.opt('@worker_lifecycle'),'sleeping')
            self.assertFalse(LIB['alive'](self.pid))
        finally:(self.root/'hidden-history').rename(self.transcript)

    def test_viewing_client_prevents_sleep(self):
        import pty
        master,slave=pty.openpty()
        client=subprocess.Popen(['tmux','-L',self.socket,'attach-session','-t',self.socket],
                                stdin=slave,stdout=slave,stderr=slave,env=dict(self.env,TERM='xterm-256color'))
        os.close(slave)
        try:
            self.tm('select-window','-t',self.pane)
            until=time.monotonic()+3
            while time.monotonic()<until:
                if self.opt('window_id') in self.tm('list-clients','-F','#{window_id}'):break
                time.sleep(.05)
            else:self.fail('isolated client did not attach')
            result=self.cli('sleep',self.pane,ok=False)
            self.assertIn('viewing',result.stderr)
            self.assertTrue(LIB['alive'](self.pid))
        finally:
            self.tm('detach-client','-s',self.socket)
            try: client.wait(timeout=3)
            except subprocess.TimeoutExpired: client.kill();client.wait(timeout=3)
            os.close(master)

    def test_activity_invalidates_stop_proof(self):
        socket_path=self.opt('socket_path')
        env=dict(self.env,TMUX=socket_path+',0,0',TMUX_PANE=self.pane)
        subprocess.run(['sh',str(BIN/'set-claude-state.sh'),'working'],env=env,
                       input='{"hook_event_name":"UserPromptSubmit"}',text=True,check=True,capture_output=True)
        self.assertEqual(self.opt('@sleep_evidence'),'')
        self.assertEqual(self.opt('@claude_state'),'working')

    def test_interrupted_exit_is_reconciled(self):
        self.cli('sleep',self.pane)
        path=Path(self.opt('@sleep_record'));data=json.loads(path.read_text())
        data['state']='preparing';path.write_text(json.dumps(data))
        self.stamp('@worker_lifecycle','preparing')
        self.cli('scan')
        self.assertEqual(self.opt('@worker_lifecycle'),'sleeping')
        self.assertFalse(LIB['alive'](self.pid))

    def test_restore_rebinds_saved_record_without_starting_agent(self):
        self.cli('sleep',self.pane)
        record=self.opt('@sleep_record')
        new=self.tm('new-window','-d','-P','-F','#{pane_id}','-t',self.socket,'-c',str(self.wt),'exec /bin/sh')
        try:
            self.tm('set-option','-w','-t',new,'@raw','1')
            self.cli('restore',new,'--record',record)
            data=json.loads(Path(record).read_text())
            self.assertEqual(data['pane'],new)
            self.assertEqual(data['source']['session_id'],self.sid)
            self.assertEqual(data['source']['pid'],0)
            self.assertEqual(data['state'],'sleeping')
            self.cli('wake',new)
            self.assertEqual(self.tm('display-message','-p','-t',new,'#{@worker_lifecycle}'),'')
        finally:self.tm('kill-window','-t',new)

    def test_native_codex_subagent_veto(self):
        worker=LIB['Worker'](self.socket,self.pane)
        source=dict(agent='codex',session_id=self.sid,pid=self.pid,home=str(self.root),worktree=str(self.wt),transcript=str(self.transcript),codex_identity={'remote':'unix://fixture'})
        class Client:
            def __init__(self,*a,**kw):pass
            def close(self):pass
            def call(self,method,args):
                if method=='thread/goal/get':return {'goal':None}
                if method=='thread/loaded/list':return {'data':[SleepTest.sid,'child']}
                sid=args['threadId']
                return {'thread':{'id':sid,'status':{'type':'idle' if sid==SleepTest.sid else 'active'},'turns':[{'status':'completed'}]}}
        with patch.object(worker,'inspect',return_value=source),patch.dict(worker.eligible.__globals__,RPC=Client,source_options=lambda source: []):
            with self.assertRaisesRegex(ValueError,'subagent'):
                worker.eligible(manual=True)

    def test_message_wakes_and_delivers_to_saved_conversation(self):
        self.cli('sleep',self.pane)
        p=subprocess.run(['python3',str(self.bin/'fleet-sleep.py'),'deliver','--session',self.socket,self.pane],
                         input='follow-up with quotes " and $HOME',env=self.env,text=True,capture_output=True,timeout=50)
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(self.opt('@worker_lifecycle'),'')
        self.assertIn('follow-up with quotes " and $HOME',(self.root/'messages').read_text())
        self.assertFalse(list((Path(self.env['FLEET_CONF_DIR'])/'fleets'/self.socket/'sleep').glob('inbox-*/*.json')))

    def test_restart_options_preserve_policy_without_replaying_prompt(self):
        parse=LIB['ARGV']['restart_options']
        self.assertEqual(parse(['claude','--settings','/a path/settings.json','--setting-sources','','--resume','old','--permission-mode','plan','do work'], 'claude'),
                         ['--settings','/a path/settings.json','--setting-sources','','--permission-mode','plan'])
        self.assertEqual(parse(['codex','--remote','unix:///old','--dangerously-bypass-approvals-and-sandbox','--dangerously-bypass-hook-trust','-c','x="a b"','resume','uuid','prompt'],'codex'),['--dangerously-bypass-approvals-and-sandbox','--dangerously-bypass-hook-trust','-c','x="a b"'])
        with self.assertRaises(ValueError):parse(['claude','--unknown-option','x'],'claude')

    def test_current_model_survives_an_earlier_launch_override(self):
        self.cli('sleep',self.pane)
        path=Path(self.opt('@sleep_record'));data=json.loads(path.read_text())
        data['model']='current-model';data['options']=['--model','original-model']
        path.write_text(json.dumps(data));self.cli('wake',self.pane)
        args=(self.root/'launch.args').read_text().splitlines()
        self.assertNotIn('original-model',args)
        self.assertEqual(args[args.index('--model')+1],'current-model')

    def test_npm_wrappers_require_the_workers_exact_endpoint(self):
        quiet=LIB['quiet_processes']
        script=self.root/'node_modules/@openai/codex/bin/codex.js';script.parent.mkdir(parents=True,exist_ok=True);script.touch()
        source={'pid':self.pid,'agent':'codex','codex_identity':{'remote':'unix:///owned'}}
        rows={self.pid+1:(self.pid,'node'),self.pid+2:(self.pid+1,'codex')}
        args={self.pid+1:['node',str(script),'--remote','unix:///owned'],self.pid+2:['codex','--remote','unix:///owned']}
        with patch.dict(LIB['TRANSFER'],process_rows=lambda: rows),patch.dict(LIB['ARGV'],process_argv=lambda pid:args[pid]):
            quiet(source)
            args[self.pid+2][-1]='unix:///unrelated'
            with self.assertRaisesRegex(ValueError,'different endpoint'):quiet(source)
            args[self.pid+2][-1]='unix:///owned';rows[self.pid+3]=(self.pid+2,'bash');args[self.pid+3]=['bash','background-job']
            with self.assertRaisesRegex(ValueError,'background/tool'):quiet(source)

    def test_retained_exit_survives_native_registry_removal(self):
        worker=LIB['Worker'](self.socket,self.pane)
        data={'state':'preparing','updated':time.time(),'source':{'pid':self.pid},
              'source_start':LIB['process_start'](self.pid)}
        self.stamp('@worker_lifecycle','preparing')
        with patch.object(worker,'inspect',side_effect=ValueError('registry already removed')):
            self.assertTrue(worker.holds_exit(data))
            data['updated']-=91;self.assertFalse(worker.holds_exit(data))
            data['updated']=time.time();data['source_start']='reused PID'
            self.assertFalse(worker.holds_exit(data))

    def test_remote_resume_binding_requires_exact_loaded_history(self):
        worker=LIB['Worker'](self.socket,self.pane)
        source={'session_id':self.sid,'home':str(self.root),'worktree':str(self.wt),'transcript':str(self.transcript),
                'codex_identity':{'session_id':self.sid,'home':str(self.root)}}
        self.stamp('@cc_launcher_pid',self.pid);self.stamp('@codex_home',self.root)
        thread={'id':self.sid,'cwd':str(self.wt),'path':str(self.root/'wrong-history')}
        class Client:
            def __init__(self,*a,**kw):pass
            def close(self):pass
            def call(self,method,args):
                return {'data':[SleepTest.sid]} if method=='thread/loaded/list' else {'thread':thread}
        method=worker.bind_resumed_codex
        with patch.dict(method.__globals__,RPC=Client), \
             patch.dict(LIB['TRANSFER'],process_rows=lambda: {self.pid+1:(self.pid,'codex')}), \
             patch.dict(LIB['ARGV'],process_argv=lambda pid:['codex','--remote','unix:///test','resume',self.sid]):
            with self.assertRaisesRegex(ValueError,'history'):method(source)
            self.assertEqual(self.opt('@codex_identity'),'')
            thread['path']=str(self.transcript);method(source)
        bound=json.loads(self.opt('@codex_identity'))
        self.assertEqual(bound['session_id'],self.sid)
        self.assertEqual(bound['owner'],str(self.pid))
        self.assertEqual(bound['remote'],'unix:///test')

    def test_navigation_hook_wakes_retained_window(self):
        import shlex
        self.cli('sleep',self.pane)
        line=next(line for line in (BIN.parent/'conf/tmux-attention.conf').read_text().splitlines()
                  if line.startswith('set-hook -g session-window-changed[72]'))
        original="bash ~/.claude/fleet/bin/fleet-sleep.sh wake '#{session_name}' '#{window_id}'"
        command=shlex.join(['env','FLEET_CONF_DIR='+self.env['FLEET_CONF_DIR'],'python3',str(self.bin/'fleet-sleep.py'),'wake','--session'])+" '#{session_name}' '#{window_id}'"
        hookfile=self.root/'focus.conf';hookfile.write_text(line.replace(original,command)+'\n')
        try:
            self.tm('source-file',str(hookfile))
            self.tm('select-window','-t',self.pane)
            deadline=time.monotonic()+8
            while time.monotonic()<deadline and self.opt('@worker_lifecycle'):time.sleep(.1)
            self.assertEqual(self.opt('@worker_lifecycle'),'')
            self.assertEqual(json.loads(Path(self.opt('@sleep_record')).read_text())['resume_count'],1)
        finally:self.tm('set-hook','-gu','session-window-changed[72]')

    def test_hook_trust_preserves_only_authorized_hashes(self):
        check=LIB['hook_trust']
        hooks={'data':[{'errors':[],'hooks':[{'key':'one','currentHash':'hash1','enabled':True,'trustStatus':'untrusted'},
                                          {'key':'disabled','currentHash':'hash2','enabled':False,'trustStatus':'trusted'}]}]}
        with self.assertRaisesRegex(ValueError,'review'):check(hooks,[])
        self.assertEqual(check(hooks,['--dangerously-bypass-hook-trust']),{'one':{'trusted_hash':'hash1'},'disabled':{'enabled':False}})
        hooks['data'][0]['hooks'][0]['trustStatus']='trusted'
        self.assertEqual(check(hooks,[]),{'one':{'trusted_hash':'hash1'},'disabled':{'enabled':False}})

    def test_repeated_resume_options_do_not_grow(self):
        parse=LIB['ARGV']['restart_options']
        options=['--dangerously-bypass-hook-trust','-m','gpt-fixture','-c','x=2']
        for _ in range(4):
            options=parse(['codex','--dangerously-bypass-hook-trust','-m','old','-c','x=1','resume','uuid',*options],'codex')
        self.assertEqual(options,['--dangerously-bypass-hook-trust','-m','gpt-fixture','-c','x=2'])

    def test_snapshot_preserves_missing_record_as_retained(self):
        missing=str(self.root/'missing-sleep.json')
        row='|'.join(['scratch-1',str(self.wt),'','done','','','1','','claude','','',missing,''])
        p=subprocess.run(['python3',str(BIN/'.fleet-restore-resolve.py'),str(self.root/'main')],
                         input=row+'\n',capture_output=True,text=True,check=True)
        fields=p.stdout.strip().split('\t')
        self.assertEqual(fields[13],'1')
        self.assertEqual(fields[14],missing)

    def test_no_empty_classification_for_multiline_or_attachment(self):
        analyze=LIB['INPUT']['analyze']
        for screen in ('❯ \n  second line','❯ \n[Image #1]','❯ unsent','not an input prompt'):
            self.assertNotEqual(analyze(screen,2,0,100)['state'],'empty')


if __name__=='__main__':unittest.main(verbosity=2)
