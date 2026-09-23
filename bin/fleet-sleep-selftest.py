#!/usr/bin/env python3
"""Real isolated tmux panes with deterministic native agent/identity fixtures."""
import json
from contextlib import contextmanager
import os
from pathlib import Path
import runpy
import shutil
import signal
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
        for name in ('fleet-sleep.py','.fleet-transfer.py','fleet-input.py','fleet-codex-session.py','fleet-codex-rpc.py','fleet_sleep_argv.py','fleet-loop.py','fleet_sleep_mcp.py','fleet_sleep_park.py'):
            shutil.copyfile(BIN/name,cls.bin/name)
        cls.wt=cls.root/'scratch-1'; cls.wt.mkdir()
        cls.sid='11111111-1111-4111-8111-111111111111'
        cls.transcript=cls.root/'history.jsonl'; cls.transcript.write_text('{}\n')
        cls.env=dict(os.environ,FLEET_CONF_DIR=str(cls.root/'config'),FLEET_SLEEP_AFTER='1',FLEET_SLEEP='on')
        cls.agent=cls.root/'agent.py'
        cls.agent.write_text('''import os,sys,tty,json,subprocess,atexit
servers=[]
for arg in sys.argv[1:]:
    if arg.startswith('--mcp-config='):
        for conf in json.load(open(arg.split('=',1)[1]))['mcpServers'].values():
            servers.append(subprocess.Popen([conf['command'],*conf['args']],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL))
atexit.register(lambda:[p.kill() for p in servers])
tty.setraw(0)
trace=open(os.path.join(os.path.dirname(__file__),'input-'+str(os.getpid())+'.log'),'ab',buffering=0)
print('\\033[2J\\033[H❯ ',end='',flush=True)
text=''
while True:
    raw=os.read(0,1);trace.write(raw);c=raw.decode()
    if c in ('\\r','\\n'):
        if text=='/exit': break
        text=''; print('\\033[2J\\033[H❯ ',end='',flush=True)
    else: text+=c
''')
        launcher=cls.bin/'fleet-claude.sh'
        launcher.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > '+str(cls.root/'launch.args')+'\nexec python3 '+str(cls.agent)+' "$@"\n')
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
print(json.dumps(dict(agent='claude',session_id=SID,pid=pid,transcript=TRANSCRIPT,home='',registry='',session=session,window=opt('window_id'),pane=pane,worktree=WT,state='done',previous=opt('@handoff_manifest'),label='',subscription={},codex_identity={})))
'''.replace('SID',repr(cls.sid)).replace('TRANSCRIPT',repr(str(cls.transcript))).replace('WT',repr(str(cls.wt))))
        inspect.chmod(0o755)
        (cls.bin/'fleet-transfer.sh').write_text('exec python3 '+str(inspect)+' "$@"\n')
        # Minimal transition lock helper in the sandbox, never the user's leases.
        (cls.bin/'fleet-lib.sh').write_text('fleet_rotate_lease_file() { printf "%s" '+str(cls.root/'lease')+'; }\n'
            +'fleet_peer_send() { printf "%s\\n" "$2" >> '+str(cls.root/'messages')+'; }\n'
            # The session-limit read (issue #1058): full iff the test wrote <root>/full.
            +'fleet_load_conf() { :; }\n'
            +'fleet_cap_full() { [ -s '+str(cls.root/'full')+' ] && cat '+str(cls.root/'full')+'; }\n')
        cls.tm('-f','/dev/null','new-session','-d','-s',cls.socket,'-x','100','-y','30','sleep 300')
        cls.tm('set-option','-g','remain-on-exit','on')

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['tmux','-L',cls.socket,'kill-server'],stderr=subprocess.DEVNULL)
        cls.tmp.cleanup()

    @classmethod
    def tm(cls,*args):
        return subprocess.check_output(['tmux','-L',cls.socket,*args],text=True,stderr=subprocess.PIPE).strip()

    def cli(self,*args,ok=True,**env):
        p=subprocess.run(['python3',str(self.bin/'fleet-sleep.py'),args[0],'--session',self.socket,*args[1:]],env=dict(self.env,**env),text=True,capture_output=True,timeout=55)
        if ok:
            trace=self.root/('input-'+str(self.pid)+'.log')
            self.assertEqual(p.returncode,0,p.stderr+' fake input='+repr(trace.read_bytes() if trace.exists() else b''))
        else:self.assertNotEqual(p.returncode,0,p.stdout)
        return p

    def setUp(self):self.open_worker()

    def open_worker(self,*agent_args):
        self.pane=self.tm('new-window','-d','-P','-F','#{pane_id}','-t',self.socket,'-c',str(self.wt),'exec python3 '+str(self.agent)+''.join(' '+a for a in agent_args))
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
    def assertExited(self,pid):
        # tmux before 3.5 can lose SIGCHLD and leave the exited agent unreaped.
        self.assertIn(LIB['process_state'](pid)[0][:1],('','Z'))
    def opt(self,key):return self.tm('display-message','-p','-t',self.pane,'#{'+key+'}')
    def stamp(self,key,value):self.tm('set-option','-w','-t',self.pane,key,str(value))

    def test_sleep_wake_exact_session_same_window(self):
        window=self.opt('window_id')
        dirty=self.wt/'uncommitted.txt';dirty.write_text('keep these bytes')
        self.cli('sleep',self.pane)
        self.assertEqual(self.opt('@worker_lifecycle'),'sleeping')
        self.assertExited(self.pid)
        self.assertEqual(self.opt('window_id'),window)
        record=Path(self.opt('@sleep_record'))
        self.assertEqual(record.stat().st_mode&0o777,0o600)
        self.stamp('@quota_failover','waiting: retired process')
        self.cli('wake',self.pane)
        self.assertEqual(self.opt('@worker_lifecycle'),'')
        self.assertEqual(self.opt('@quota_failover'),'')
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
        # A bare @quota_failover marker is no longer an unconditional veto: the
        # journal decides sleep-eligibility now (#755/#809), covered by
        # test_only_verified_proactive_quota_wait_can_sleep and
        # test_stale_failover_marker_from_a_completed_episode_allows_sleep.
        for option,value in (('@claude_state','needs'),('@claude_state','working'),('@handoff_armed','1'),('@agent_transfer_request','x'),('@sleep_keep_awake','1')):
            before=self.opt(option);self.stamp(option,value)
            self.cli('sleep',self.pane,ok=False)
            self.stamp(option,before)
        self.assertTrue(LIB['alive'](self.pid))

    def test_why_lists_every_unmet_condition_not_just_the_first(self):
        # #837: a diagnostic must show ALL the cheap blockers at once, where
        # eligible() (and every scan skip) reports only the first.
        self.stamp('@claude_state','working')      # not done
        self.stamp('@sleep_keep_awake','1')        # keep awake
        reasons=json.loads(self.cli('why',self.pane).stdout)['reasons']
        self.assertIn('worker is not done',reasons)
        self.assertIn('keep awake enabled',reasons)
        # A window past the cheap gates falls through to the first deep reason only.
        self.stamp('@claude_state','done');self.stamp('@sleep_keep_awake','')
        self.stamp('@sleep_evidence',json.dumps(dict(self.evidence,session_id='other')))
        deep=json.loads(self.cli('why',self.pane).stdout)['reasons']
        self.assertEqual(deep,['no native Stop evidence for this process/session'])
        # A window that can sleep has no unmet condition.
        self.stamp('@sleep_evidence',json.dumps(self.evidence))
        self.assertEqual(json.loads(self.cli('why',self.pane).stdout)['reasons'],[])

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
            self.assertExited(self.pid)
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
        self.assertExited(self.pid)

    def test_scan_skips_panels_silently_and_stamps_each_record(self):
        # A panel/hub window produces no per-tick skip record (#755/#809
        # follow-up: it was ~a fifth of the log's noise); a real worker's record
        # carries a timestamp the log previously lacked.
        panel=self.tm('new-window','-d','-P','-F','#{pane_id}','-t',self.socket,'-c',str(self.wt),'exec /bin/sh')
        panel_win=self.tm('display-message','-p','-t',panel,'#{window_id}')
        self.tm('rename-window','-t',panel,'dash')
        try:
            out=self.cli('scan').stdout.strip().splitlines()
            records=[json.loads(l) for l in out if l.startswith('{')]
            self.assertFalse([r for r in records if r.get('window')==panel_win])
            mine=[r for r in records if r.get('window')==self.opt('window_id')]
            self.assertTrue(mine and all('at' in r for r in records))
        finally:
            self.tm('kill-window','-t',panel)

    def capture(self,until,timeout=5):
        deadline=time.monotonic()+timeout
        while True:
            screen=self.tm('capture-pane','-p','-t',self.pane)
            if until(screen) or time.monotonic()>deadline:return screen
            time.sleep(.05)

    def test_park_card_explains_itself_and_redraws_at_the_new_width(self):
        # Issue #1049: the sleeping page is drawn for the CURRENT pane, not the
        # screen captured at sleep time, and a resize (SIGWINCH) redraws it.
        reply='Shipped the fix and reported back.\n'+'这是一段很长的中文回复，用来检查宽字符按显示宽度换行。'*6
        entry={'type':'assistant','message':{'content':[{'type':'tool_use','name':'x'},{'type':'text','text':reply}]}}
        saved=self.transcript.read_text()
        self.transcript.write_text(saved+json.dumps(entry,ensure_ascii=False)+'\n')
        self.addCleanup(self.transcript.write_text,saved)
        self.stamp('@issue','1049');self.tm('rename-window','-t',self.pane,'sleeping-page')
        self.tm('resize-window','-t',self.pane,'-x','80','-y','24')
        self.cli('sleep',self.pane)
        for cols,rows in ((80,24),(200,50)):
            self.tm('resize-window','-t',self.pane,'-x',str(cols),'-y',str(rows))
            screen=self.capture(lambda s:'─'*(cols-1) in s and 'reported back' in s)
            lines=screen.split('\n')
            self.assertIn('Sleeping · #1049 sleeping-page',lines[0],screen)
            self.assertIn('Last reply',screen)
            self.assertIn('Shipped the fix and reported back.',screen)
            self.assertIn('wakes on its own: incoming message',screen)
            self.assertIn('asleep ',screen);self.assertIn('claude',screen)
            self.assertLessEqual(len(lines),rows)
            self.assertLessEqual(max(LIB['PARK']['width'](l) for l in lines),cols,screen)
        self.cli('wake',self.pane)

    def test_park_card_fallback_and_states(self):
        P=LIB['PARK']
        data=dict(state='sleeping',created=time.time()-3700,evidence={'at':time.time()-5000},model='opus',
                  source={'agent':'codex','label':'me@x','sleep_loop':{'record':{'status':'active','schedule':{'next_run_at':time.time()+600}}}},
                  screen='old work line\n'+'x'*300+'\n──────\n❯ \n──────\n  ◆ Opus status line')
        out=P['render_park'](data,{'issue':'7','title':'t'},80,24)
        plain=P['ANSI'].sub('',out).split('\n')
        self.assertEqual(len(plain),24)
        self.assertLessEqual(max(P['width'](l) for l in plain),80)
        self.assertIn('\x1b[2mold work line',out)          # the old screen, dimmed…
        self.assertIn('saved screen (old, not live)',out)  # …and marked as old
        self.assertNotIn('❯',out);self.assertNotIn('status line',out)
        self.assertIn('asleep 1h 01m',out);self.assertIn('loop due ',out)
        failed=P['render_park'](dict(data,state='failed',error='resume is not ready'),{},80,24)
        self.assertIn('Wake failed',failed);self.assertIn('error: resume is not ready',failed)
        self.assertIn('Waking…',P['render_park'](dict(data,state='waking'),{},80,24))
        self.assertIn('button',P['render_park'](data,{},80,24,footer_lines=['[ button ]']))
        self.assertIsNone(P['last_reply'](self.root/'no-such.jsonl'))
        repo=self.root/'git-state';repo.mkdir()
        git=lambda *a:subprocess.run(['git','-C',str(repo),'-c','user.name=t','-c','user.email=t@t',*a],check=True,capture_output=True)
        git('init','-q','-b','issue-7');(repo/'a').write_text('1');git('add','a');git('commit','-qm','a');(repo/'b').write_text('2')
        self.assertEqual(P['git_state'](repo),{'branch':'issue-7','dirty':1,'unpushed':1})
        self.assertIn('work: 1 uncommitted, 1 unpushed on issue-7',P['render_park'](data,{'git':P['git_state'](repo)},80,24))
        tiny=P['ANSI'].sub('',P['render_park'](data,{'reply':'r'*500},20,5)).split('\n')
        self.assertLessEqual(len(tiny),5);self.assertLessEqual(max(P['width'](l) for l in tiny),20)

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
        source=dict(agent='codex',session_id=self.sid,pid=self.pid,home=str(self.root),worktree=str(self.wt),transcript=str(self.transcript),codex_identity={'remote':'unix:///fixture'})
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

    @contextmanager
    def codex_probe(self):
        source=dict(agent='codex',session_id=self.sid,pid=self.pid,home=str(self.root),
                    session=self.socket,window=self.opt('window_id'),pane=self.pane,
                    worktree=str(self.wt),transcript=str(self.transcript),codex_identity={'remote':'unix:///fixture'})
        thread=dict(id=self.sid,cwd=str(self.wt),path=str(self.transcript),status={'type':'idle'},
                    turns=[dict(id='finished-turn',status='completed',completedAt=time.time()-60,items=[])])
        class Client:
            def __init__(self,*a,**kw):pass
            def close(self):pass
            def call(self,method,args):
                if method=='thread/goal/get':return {'goal':None}
                if method=='thread/loaded/list':return {'data':[SleepTest.sid]}
                if method=='hooks/list':return {'data':[{'errors':[],'hooks':[]}]}
                return {'thread':thread}
        with patch.dict(os.environ,self.env):
            worker=LIB['Worker'](self.socket,self.pane)
            with patch.object(worker,'inspect',return_value=source), \
                 patch.dict(worker.eligible.__globals__,RPC=Client,source_options=lambda source: [],quiet_processes=lambda source,*args: None):
                yield worker,source,thread

    def test_native_completion_bootstraps_old_codex_without_stop(self):
        self.stamp('@sleep_evidence','')
        with self.codex_probe() as (worker,source,thread):
            _,proof=worker.eligible()
            self.assertEqual(proof['proof'],'native-completed-turn')
            self.assertEqual(proof['turn_id'],'finished-turn')
            self.assertEqual(proof['at'],thread['turns'][-1]['completedAt'])
            self.assertEqual(self.opt('@sleep_evidence'),'')  # observation never invents a Stop

    def test_codex_wake_and_recovery_recognize_animation_and_retire_old_quota_marker(self):
        self.cli('sleep',self.pane)
        with self.codex_probe() as (worker,source,thread):
            path,data=worker.record()
            data['source']=dict(source)
            source['pid']=self.pid+1000000  # simulated exact native rebind
            real_tm=worker.tm
            def tm(*args):
                return '' if args[0]=='respawn-pane' else real_tm(*args)
            def snapshot(session,pane,agent=None):
                self.assertEqual(agent,'codex')
                screen='› \x1b[2mAsk Codex to do anything\x1b[0m \x1b[38;2;60;83;90m\x1b[48;2;42;67;76m⠁\n'
                empty=LIB['INPUT']['codex_empty_with_particles'](screen,2,0,100)
                return {'state':'empty' if empty else 'unknown'}
            with patch.object(worker,'tm',side_effect=tm),patch.object(worker,'replaceable'), \
                 patch.object(worker,'bind_resumed_codex'),patch.dict(LIB['INPUT'],snapshot=snapshot):
                self.stamp('@quota_failover','waiting: retired process')
                worker.wake_locked(path,data)
                self.assertEqual(self.opt('@worker_lifecycle'),'')
                self.assertEqual(self.opt('@quota_failover'),'')
                for original in (False,True):
                    data['state']='failed'
                    if original:data['source']['pid']=source['pid']
                    LIB['save'](path,data);self.stamp('@worker_lifecycle','failed')
                    self.stamp('@quota_failover','waiting: retained marker')
                    worker.recover()
                    self.assertEqual(self.opt('@worker_lifecycle'),'')
                    self.assertEqual(self.opt('@quota_failover'),'waiting: retained marker' if original else '')

    def test_native_idle_requires_terminal_tools_exact_history_and_time(self):
        self.stamp('@sleep_evidence','')
        with self.codex_probe() as (worker,source,thread):
            last=thread['turns'][-1]
            for status in ('inProgress','pending','unknown'):
                last['items']=[{'type':'commandExecution','status':status}]
                with self.assertRaisesRegex(ValueError,'tool'):worker.eligible()
            last['items']=[]
            for at in (None,0,True,float('nan'),time.time()+60):
                last['completedAt']=at
                with self.assertRaisesRegex(ValueError,'completion time'):worker.eligible()
            last['completedAt']=time.time()-60
            thread['path']=str(self.root/'wrong-history')
            with self.assertRaisesRegex(ValueError,'history'):worker.eligible()
            thread['path']=str(self.transcript);thread['status']={'type':'active'}
            with self.assertRaisesRegex(ValueError,'natively idle'):worker.eligible()

    def test_resumed_codex_observes_fresh_grace_without_an_extra_turn(self):
        self.stamp('@sleep_evidence','')
        with self.codex_probe() as (worker,source,thread):
            self.stamp('@sleep_woke_at',time.time())
            with self.assertRaisesRegex(ValueError,'grace'):worker.eligible()
            self.stamp('@sleep_woke_at',time.time()-60)
            worker.eligible()
            thread['turns'][-1]['completedAt']=time.time()
            with self.assertRaisesRegex(ValueError,'grace'):worker.eligible()

    def test_only_verified_proactive_quota_wait_can_sleep(self):
        import hashlib
        self.stamp('@quota_failover','waiting: old process warning')
        with self.codex_probe() as (worker,source,thread):
            worker.eligible()  # orphaned text marker, no unresolved journal
            self.assertEqual(source['stale_quota_marker'],'waiting: old process warning')
            unrelated=worker.quota_directory/'old-source'/'request.json'
            LIB['save'](unrelated,{'source':dict(source,pid=1),'state':'ambiguous'})
            with self.assertRaisesRegex(ValueError,'unresolved'):worker.eligible()
            unrelated.unlink()
            key=hashlib.sha256(json.dumps([source[k] for k in ('session','window','session_id','pid','agent')]).encode()).hexdigest()[:32]
            path=worker.quota_directory/key/'request.json'
            request={'source':source,'state':'waiting','hard':False}
            LIB['save'](path,request);worker.eligible()
            for state in ('preparing','ambiguous','recovery-sending','bound','unknown'):
                request['state']=state;LIB['save'](path,request)
                with self.assertRaisesRegex(ValueError,'quota failover'):worker.eligible()
            request.update(state='waiting-quota',hard=True);LIB['save'](path,request)
            with self.assertRaisesRegex(ValueError,'quota failover'):worker.eligible()
            request.update(hard=False);request['source']=dict(source,pid=self.pid+1);LIB['save'](path,request)
            with self.assertRaisesRegex(ValueError,'another source'):worker.eligible()

    def test_stale_failover_marker_from_a_completed_episode_allows_sleep(self):
        # A marker that outlived its episode no longer vetoes hibernation
        # (#755/#809): a non-waiting prefix is not an automatic refusal, a
        # completed migration for this window is terminal, and a soft proactive
        # wait means sleep rather than migrate. Only a live cutover or a hard
        # failure for this window still blocks.
        with self.codex_probe() as (worker,source,thread):
            self.stamp('@quota_failover','preparing: selected claude/acct')
            worker.eligible()
            self.assertEqual(source['stale_quota_marker'],'preparing: selected claude/acct')
            other=worker.quota_directory/'episode'/'request.json'
            for state in ('bound','cancelled','recovered'):
                LIB['save'](other,{'source':dict(source,pid=self.pid+9),'state':state})
                worker.eligible()
            LIB['save'](other,{'source':dict(source,pid=self.pid+9),'state':'waiting','hard':False})
            worker.eligible()
            for req in ({'state':'preparing'},{'state':'ambiguous'},{'state':'waiting','hard':True}):
                LIB['save'](other,dict(source={'session':source['session'],'window':source['window'],
                                                'session_id':'unrelated','pid':self.pid+9},**req))
                with self.assertRaisesRegex(ValueError,'unresolved'):worker.eligible()

    def test_quota_controller_lock_excludes_sleep(self):
        with patch.dict(os.environ,self.env):
            worker=LIB['Worker'](self.socket,self.pane)
            with LIB['lock'](worker.quota_directory/(self.socket+'.lock')):
                result=self.cli('sleep',self.pane,ok=False)
                self.assertIn('owns this worker',result.stderr)
        self.assertTrue(LIB['alive'](self.pid))

    def test_loop_scheduler_wakes_only_when_due_or_quota_is_fresh(self):
        with patch.dict(os.environ,self.env):
            worker=LIB['Worker'](self.socket,self.pane)
            snapshot={'record':{'status':'active','schedule':{'next_run_at':time.time()+3600}}}
            data={'source':{'agent':'codex','sleep_loop':snapshot,'sleep_account_key':'owned'}}
            with patch.dict(LIB['LOOP'],sleep_retained=lambda *a:None):
                self.assertFalse(worker.scheduled_wake('record',data))
                snapshot['record']['schedule']['next_run_at']=time.time()-1
                self.assertTrue(worker.scheduled_wake('record',data))
                snapshot['record']['status']='waiting-quota'
                row={'key':'owned','fresh':False}
                policy={'inventory':lambda:{'accounts':[row]},'eligible':lambda r:r['fresh'],
                        'choose':lambda *a,**kw:{'target':None}}
                with patch.object(LIB['runpy'],'run_path',return_value=policy):
                    self.assertFalse(worker.scheduled_wake('record',data))
                    row['fresh']=True
                    self.assertTrue(worker.scheduled_wake('record',data))
                    row['key']='unrelated'
                    self.assertFalse(worker.scheduled_wake('record',data))
                    with patch.dict(os.environ,FLEET_FAILOVER='1'):
                        policy['choose']=lambda *a,**kw:{'target':row}
                        self.assertTrue(worker.scheduled_wake('record',data))

    def test_legacy_endpoint_is_diagnostic_not_permission_to_guess(self):
        with self.codex_probe() as (worker,source,thread):
            source['codex_identity']['remote']=''
            with self.assertRaisesRegex(ValueError,'legacy Codex.*rebind'):worker.eligible()
        self.assertEqual(LIB['CODEX']['saved_identity']('', ''),{})

    def test_real_pane_loop_sleeps_and_timer_resumes_exact_history(self):
        module=runpy.run_path(str(self.bin/'fleet-sleep.py'))
        manifest=self.root/('loop-packet-'+self.pane[1:])/'manifest.json'
        path=manifest.parent/'loop/state.json';path.parent.mkdir(parents=True)
        due=time.time()+3600
        record=dict(id='retained-loop',status='active',agent='claude',thread_id=self.sid,
                    manifest=str(manifest),worktree=str(self.wt),controller_pid=self.pid,
                    pane_pid=self.pid,fleet={'session':self.socket,'window_id':self.opt('window_id'),'pane_id':self.pane},
                    schedule={'prompt':'continue authorized monitoring','interval_seconds':3600,'next_run_at':due},deliveries=7)
        path.write_text(json.dumps(record));self.stamp('@handoff_manifest',manifest)
        globals_=module['LOOP']['sleep_snapshot'].__globals__
        with patch.dict(os.environ,self.env),patch.dict(globals_,current=lambda r:None):
            worker=module['Worker'](self.socket,self.pane)
            try:result=worker.sleep(manual=True)
            except Exception as exc:
                trace=self.root/('input-'+str(self.pid)+'.log')
                status=subprocess.run(['ps','-p',str(self.pid),'-o','pid=,ppid=,stat=,comm='],text=True,capture_output=True).stdout
                self.fail('%s; fake input=%r; process=%r; pane=%r' %
                          (exc,trace.read_bytes() if trace.exists() else None,status,
                           self.tm('display-message','-p','-t',self.pane,'#{pane_pid}|#{pane_dead}|#{pane_input_off}')))
            self.assertEqual(result['state'],'sleeping')
            self.assertExited(self.pid)
            self.assertEqual(json.loads(path.read_text())['status'],'hibernating')
            worker.recover()
            self.assertEqual(self.opt('@worker_lifecycle'),'sleeping')
            with patch.object(module['time'],'time',return_value=due+1):worker.recover()
            self.assertEqual(self.opt('@worker_lifecycle'),'')
            self.assertEqual(self.opt('@claude_state'),'done')
            resumed=json.loads(path.read_text())
            self.assertEqual(resumed['schedule'],record['schedule'])
            self.assertEqual(resumed['deliveries'],7)
            self.assertEqual(resumed['thread_id'],self.sid)
            self.assertEqual(resumed['driver'],'quotawatch')
            self.assertNotEqual(resumed['native_pid'],self.pid)
            trace=self.root/('input-'+str(resumed['native_pid'])+'.log')
            self.assertEqual(trace.read_bytes(),b'')  # wake itself sends no prompt

    def fleet_full(self,full=True):
        f=self.root/'full'
        if full: f.write_text('3 3\n')
        elif f.exists(): f.unlink()

    def inbox(self):
        return list((Path(self.env['FLEET_CONF_DIR'])/'fleets'/self.socket/'sleep').glob('inbox-*/*.json'))

    def test_due_loop_waits_for_a_slot_then_runs_once(self):
        # Issue #1058: a sleeper holds no slot, so an automatic wake at a full
        # fleet must not push the awake count over — it defers, says so on the
        # window, and the next tick after a slot frees runs it (late, not twice).
        module=runpy.run_path(str(self.bin/'fleet-sleep.py'))
        manifest=self.root/('loop-packet-'+self.pane[1:])/'manifest.json'
        path=manifest.parent/'loop/state.json';path.parent.mkdir(parents=True)
        due=time.time()+3600
        record=dict(id='slot-loop',status='active',agent='claude',thread_id=self.sid,
                    manifest=str(manifest),worktree=str(self.wt),controller_pid=self.pid,
                    pane_pid=self.pid,fleet={'session':self.socket,'window_id':self.opt('window_id'),'pane_id':self.pane},
                    schedule={'prompt':'continue','interval_seconds':3600,'next_run_at':due},deliveries=2)
        path.write_text(json.dumps(record));self.stamp('@handoff_manifest',manifest)
        globals_=module['LOOP']['sleep_snapshot'].__globals__
        self.addCleanup(self.fleet_full,False)
        with patch.dict(os.environ,self.env),patch.dict(globals_,current=lambda r:None):
            worker=module['Worker'](self.socket,self.pane)
            self.assertEqual(worker.sleep(manual=True)['state'],'sleeping')
            self.fleet_full()
            with patch.object(module['time'],'time',return_value=due+1):
                worker.recover();worker.recover()
            self.assertEqual(self.opt('@worker_lifecycle'),'sleeping')
            self.assertEqual(self.opt('@sleep_wake_deferred'),'cap')
            self.assertEqual(self.resume_count(),0)
            self.fleet_full(False)
            with patch.object(module['time'],'time',return_value=due+1):worker.recover()
            self.assertEqual(self.opt('@worker_lifecycle'),'')
            self.assertEqual(self.opt('@sleep_wake_deferred'),'')
            self.assertEqual(self.resume_count(),1)
            self.assertEqual(json.loads(path.read_text())['deliveries'],2)

    def test_message_waits_for_a_slot_and_delivers_once_one_frees(self):
        self.cli('sleep',self.pane)
        self.fleet_full();self.addCleanup(self.fleet_full,False)
        p=subprocess.run(['python3',str(self.bin/'fleet-sleep.py'),'deliver','--session',self.socket,self.pane],
                         input='held for a slot',env=self.env,text=True,capture_output=True,timeout=50)
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertIn('queued — fleet at its session limit',p.stderr)
        self.assertEqual(self.opt('@worker_lifecycle'),'sleeping')
        self.assertEqual(self.opt('@sleep_wake_deferred'),'cap')
        self.assertEqual(len(self.inbox()),1)
        self.cli('scan')   # still full: the drain retries and defers again
        self.assertEqual((self.opt('@worker_lifecycle'),self.resume_count(),len(self.inbox())),('sleeping',0,1))
        self.assertFalse((self.root/'messages').exists() and 'held for a slot' in (self.root/'messages').read_text())
        # A bare CLI wake at the limit refuses (nothing would retry it) …
        self.assertIn('fleet full 3/3',self.cli('wake',self.pane,ok=False).stderr)
        self.assertEqual(self.opt('@worker_lifecycle'),'sleeping')
        self.fleet_full(False)
        self.cli('scan')
        self.assertEqual(self.opt('@worker_lifecycle'),'')
        self.assertEqual(self.opt('@sleep_wake_deferred'),'')
        self.assertEqual(self.resume_count(),1)
        self.assertIn('held for a slot',(self.root/'messages').read_text())
        self.assertEqual(self.inbox(),[])

    def test_operator_wake_goes_over_the_limit(self):
        self.cli('sleep',self.pane)
        self.fleet_full();self.addCleanup(self.fleet_full,False)
        self.cli('wake',self.pane,'--over-cap')
        self.assertEqual(self.opt('@worker_lifecycle'),'')
        self.assertEqual(self.resume_count(),1)

    def test_page_warns_when_full_and_still_wakes(self):
        # The armed line names the overage; the second press wakes anyway.
        self.cli('sleep',self.pane)
        self.fleet_full();self.addCleanup(self.fleet_full,False)
        self.capture(lambda s:'⏎ Wake' in s)
        self.assertNotIn('fleet full',self.tm('capture-pane','-p','-t',self.pane))
        self.tm('send-keys','-t',self.pane,'Enter')
        screen=self.capture(lambda s:'fleet full' in s)
        self.assertIn('fleet full 3/3 — waking makes 4',screen)
        self.assertIn('again to wake',screen)
        out=os.environ.get('FLEET_SLOTS_EVIDENCE')
        if out: Path(out).write_text(screen)
        time.sleep(.4)
        self.tm('send-keys','-t',self.pane,'Enter')
        self.await_awake()
        self.assertEqual(self.resume_count(),1)

    def test_claude_mcp_child_sleeps_only_under_the_contract_and_restarts_on_resume(self):
        # A Claude worker's MCP servers are its direct children with no RPC to
        # enumerate them (issue #784). Copying /bin/sleep trips code signing on
        # macOS; a symlink gives the fixture its own launcher path.
        server=self.root/'fake-mcp'
        if not server.exists():server.symlink_to('/bin/sleep')
        config=self.root/'mcp.json'
        config.write_text(json.dumps({'mcpServers':{'fake':{'type':'stdio','command':str(server),'args':['300']}}}))
        self.tm('kill-window','-t',self.pane)
        self.open_worker('--strict-mcp-config','--mcp-config='+str(config))
        def child():
            rows=LIB['TRANSFER']['process_rows']()
            return [pid for pid,(pp,_) in rows.items() if pp==self.pid]
        until=time.monotonic()+5
        while time.monotonic()<until and not child():time.sleep(.05)
        first=child();self.assertEqual(len(first),1)
        p=self.cli('sleep',self.pane,'--dry-run',ok=False)
        self.assertIn('restartability contract',p.stderr)
        self.cli('sleep',self.pane,'--dry-run',FLEET_SLEEP_MCP_RESTARTABLE='fake')
        config.write_text(json.dumps({'mcpServers':{'fake':{'type':'stdio','command':str(server),'args':['301']}}}))
        p=self.cli('sleep',self.pane,'--dry-run',ok=False,FLEET_SLEEP_MCP_RESTARTABLE='fake')
        self.assertIn('Claude owns unverified background/tool process',p.stderr)
        config.write_text(json.dumps({'mcpServers':{'fake':{'type':'stdio','command':str(server),'args':['300']}}}))
        self.cli('sleep',self.pane,FLEET_SLEEP_MCP_RESTARTABLE='fake')
        self.assertExited(self.pid)
        self.assertIn(LIB['process_state'](first[0])[0][:1],('','Z'))
        record=Path(self.opt('@sleep_record'));data=json.loads(record.read_text())
        self.assertEqual(sorted(data['source']['sleep_mcp']),['fake'])
        self.assertIn('--mcp-config='+str(config),data['options']);self.assertIn('--strict-mcp-config',data['options'])
        self.cli('wake',self.pane)
        self.assertEqual(self.opt('@worker_lifecycle'),'')
        self.assertEqual(json.loads(record.read_text())['state'],'awake')
        self.pid=int(self.opt('pane_pid'))
        self.assertEqual(len(child()),1)
        self.assertIn('--mcp-config='+str(config),(self.root/'launch.args').read_text().splitlines())

    def test_bundled_code_host_is_idle_infrastructure_but_its_jobs_are_not(self):
        quiet=LIB['quiet_processes'];base=self.pid
        source={'pid':base,'agent':'codex','codex_identity':{'remote':'unix:///owned'}}
        rows={base+1:(base,'codex'),base+2:(base+1,'codex-code-mode-host')}
        args={base+1:['codex','app-server','--listen','unix:///owned'],base+2:['/release/codex-code-mode-host']}
        exes={base+1:Path('/release/codex'),base+2:Path('/release/codex-code-mode-host')}
        with patch.dict(LIB['TRANSFER'],process_rows=lambda:rows), \
             patch.dict(LIB['ARGV'],process_argv=lambda pid:args[pid],process_executable=lambda pid:exes[pid]):
            quiet(source)
            exes[base+2]=Path('/other/codex-code-mode-host')
            with self.assertRaisesRegex(ValueError,'background/tool'):quiet(source)
            exes[base+2]=Path('/release/codex-code-mode-host')
            rows[base+3]=(base+2,'bash');args[base+3]=['bash','active-job']
            exes[base+3]=Path('/bin/bash')
            with self.assertRaisesRegex(ValueError,'background/tool'):quiet(source)

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

    def source_navigation_hook(self,mode='confirm'):
        # The shipped [72] hooks, their wake command pointed at the sandbox and
        # the FLEET_SLEEP_WAKE knob fleet-sleep.sh would export (issue #1050).
        # The dwell they carry (issue #822) applies only under `dwell`.
        import shlex
        lines=[line for line in (BIN.parent/'conf/tmux-attention.conf').read_text().splitlines()
               if line.startswith(('set-hook -g session-window-changed[72]','set-hook -g client-attached[72]'))]
        self.assertEqual(len(lines),2)
        original="bash ~/.claude/fleet/bin/fleet-sleep.sh wake"
        command=shlex.join(['env','FLEET_CONF_DIR='+self.env['FLEET_CONF_DIR'],'FLEET_SLEEP_WAKE='+mode,
                            'python3',str(self.bin/'fleet-sleep.py'),'wake','--session'])
        for line in lines:self.assertIn(original+" '#{session_name}' '#{window_id}' --dwell 2 --nav",line)
        hookfile=self.root/'focus.conf';hookfile.write_text(''.join(l.replace(original,command)+'\n' for l in lines))
        self.tm('source-file',str(hookfile))
        self.addCleanup(self.tm,'set-hook','-gu','client-attached[72]')
        self.addCleanup(self.tm,'set-hook','-gu','session-window-changed[72]')

    def resume_count(self):
        return json.loads(Path(self.opt('@sleep_record')).read_text())['resume_count']

    def await_awake(self,timeout=45):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline and self.opt('@worker_lifecycle'):time.sleep(.1)
        self.assertEqual(self.opt('@worker_lifecycle'),'',self.tm('capture-pane','-p','-t',self.pane))

    @contextmanager
    def viewing_client(self):
        import pty
        master,slave=pty.openpty()
        client=subprocess.Popen(['tmux','-L',self.socket,'attach-session','-t',self.socket],
                                stdin=slave,stdout=slave,stderr=slave,env=dict(self.env,TERM='xterm-256color'))
        os.close(slave)
        try:
            until=time.monotonic()+3
            while time.monotonic()<until and self.opt('window_id') not in self.tm('list-clients','-F','#{window_id}'):
                time.sleep(.05)
            self.assertIn(self.opt('window_id'),self.tm('list-clients','-F','#{window_id}'))
            yield
        finally:
            self.tm('detach-client','-s',self.socket)
            try: client.wait(timeout=3)
            except subprocess.TimeoutExpired: client.kill();client.wait(timeout=3)
            os.close(master)

    def test_navigation_and_viewing_never_wake_under_confirm(self):
        # Issue #1050: arriving on a sleeper, attaching a client to it, and
        # the scan finding it on screen all leave it asleep by default.
        self.cli('sleep',self.pane)
        self.source_navigation_hook()
        self.tm('select-window','-t',self.pane)
        with self.viewing_client():
            time.sleep(3)
            self.cli('scan')
            self.assertEqual(self.opt('@worker_lifecycle'),'sleeping')
        self.assertEqual(self.resume_count(),0)
        # Explicit CLI wake (no --nav) is untouched by the knob.
        self.cli('wake',self.pane)
        self.assertEqual(self.opt('@worker_lifecycle'),'')

    def test_scan_wakes_viewed_sleeper_only_under_dwell(self):
        self.cli('sleep',self.pane)
        self.tm('select-window','-t',self.pane)
        with self.viewing_client():
            self.cli('scan',FLEET_SLEEP_WAKE='dwell')
            self.assertEqual(self.opt('@worker_lifecycle'),'')

    def test_navigation_hook_wakes_retained_window_under_dwell(self):
        self.cli('sleep',self.pane)
        self.source_navigation_hook('dwell')
        self.tm('select-window','-t',self.pane)
        self.await_awake(15)
        self.assertEqual(self.resume_count(),1)

    def test_navigation_hook_dwell_skips_passed_window(self):
        # Selecting the sleeper and leaving again within the dwell — the
        # sidebar's ↑↓ follow, prefix n past it — must not resume it; a direct
        # wake with a dwell honours the same rule, and settling on it wakes.
        first=self.tm('list-windows','-t',self.socket,'-F','#{window_id}').splitlines()[0]
        self.cli('sleep',self.pane)
        self.source_navigation_hook('dwell')
        self.tm('select-window','-t',self.pane)
        self.tm('select-window','-t',first)
        time.sleep(3.5)
        self.assertEqual(self.opt('@worker_lifecycle'),'sleeping')
        self.assertEqual(self.resume_count(),0)
        self.assertExited(self.pid)
        self.cli('wake',self.pane,'--dwell','0.2')
        self.assertEqual(self.opt('@worker_lifecycle'),'sleeping')
        self.assertEqual(self.resume_count(),0)
        self.tm('select-window','-t',self.pane)
        self.cli('wake',self.pane,'--dwell','0.2')
        self.assertEqual(self.opt('@worker_lifecycle'),'')
        self.assertEqual(self.resume_count(),1)

    def test_page_wakes_on_a_double_press_and_swallows_typing(self):
        # Issue #1050: one ⏎ arms (still asleep), the arm lapses silently, a
        # bounce <0.3s is not a second press, a second ⏎ inside the window
        # wakes — and no byte typed at the page reaches the resumed agent.
        self.cli('sleep',self.pane,FLEET_SLEEP_WAKE_ARM='2')
        self.capture(lambda s:'⏎ Wake' in s)
        self.tm('send-keys','-t',self.pane,'-l','abc')
        self.tm('send-keys','-t',self.pane,'Enter')
        screen=self.capture(lambda s:'again to wake' in s)
        self.assertIn('again to wake · 2…',screen)
        self.assertEqual(self.opt('@worker_lifecycle'),'sleeping')
        self.assertIn('again to wake · 1…',self.capture(lambda s:'again to wake · 1' in s))
        screen=self.capture(lambda s:'⏎ Wake' in s,timeout=4)
        self.assertNotIn('again to wake',screen)
        self.tm('send-keys','-t',self.pane,'Enter',';','send-keys','-t',self.pane,'Enter')
        time.sleep(.5)
        self.assertEqual(self.opt('@worker_lifecycle'),'sleeping')
        self.tm('send-keys','-t',self.pane,'-l','xyz')
        self.assertEqual(self.resume_count(),0)
        self.tm('send-keys','-t',self.pane,'Enter')
        self.await_awake()
        self.assertEqual(self.resume_count(),1)
        trace=self.root/('input-'+self.opt('pane_pid')+'.log')
        typed=trace.read_bytes() if trace.exists() else b''
        for word in (b'abc',b'xyz',b'\r'):self.assertNotIn(word,typed)
        self.assertEqual(LIB['INPUT']['snapshot'](self.socket,self.pane).get('state'),'empty')

    def test_page_wakes_on_two_taps_on_the_button_only(self):
        self.cli('sleep',self.pane)
        self.capture(lambda s:'⏎ Wake' in s)
        rows=int(self.opt('pane_height'))
        self.assertEqual((self.opt('mouse_standard_flag'),self.opt('mouse_sgr_flag')),('1','1'))
        def click(row):
            seq='\x1b[<0;3;%dM\x1b[<0;3;%dm'%(row,row)
            self.tm('send-keys','-t',self.pane,'-H',*('%02x'%ord(c) for c in seq))
        click(1);time.sleep(.4);click(2)
        time.sleep(.3)
        self.assertNotIn('again to wake',self.tm('capture-pane','-p','-t',self.pane))
        click(rows)
        self.capture(lambda s:'again to wake' in s)
        time.sleep(.4);click(rows)
        self.await_awake()
        self.assertEqual(self.resume_count(),1)
        # The resumed agent must not inherit the page's mouse reporting.
        self.assertEqual((self.opt('mouse_standard_flag'),self.opt('mouse_sgr_flag')),('0','0'))

    def test_wake_button_state_machine(self):
        P=LIB['PARK'];b=P['WakeButton'](3)
        self.assertIsNone(b.timeout(0))
        self.assertFalse(b.press(10));self.assertEqual(b.state,'armed')
        self.assertFalse(b.press(10.1));self.assertEqual(b.state,'armed')
        self.assertAlmostEqual(b.timeout(10.5),0.51,places=2)
        self.assertFalse(b.press(13.5));self.assertEqual(b.state,'armed')
        self.assertTrue(b.press(14));self.assertEqual(b.state,'waking')
        self.assertFalse(b.press(14.5))
        self.assertEqual(P['presses'](b'q\r\n\x1b[A\x1b[<0;1;9M\x1b[<0;1;9m\x1b[<0;1;3M\x1b[<2;1;9M',{9}),2)

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

    def test_codex_particles_require_empty_placeholder_and_preserve_drafts(self):
        check=LIB['INPUT']['codex_empty_with_particles']
        particle='\x1b[38;2;60;83;90m\x1b[48;2;42;67;76m⠁\x1b[39m'
        screen='›'+particle+'\x1b[2mAsk Codex to do anything\x1b[0m '+particle+'\n  '+particle+'\nfooter'
        self.assertNotEqual(LIB['INPUT']['analyze'](screen,2,0,100)['state'],'empty')
        self.assertTrue(check(screen,2,0,100))
        for draft in ('real draft','⠁','Ask Codex to do anything'):
            self.assertFalse(check('› '+draft+' '+particle+'\n',2,0,100))
        for extra in ('second line','[Image #1]','[Pasted text #1]','⠁'):
            self.assertFalse(check(screen.replace('\n  '+particle,'\n\x1b[0m'+extra),2,0,100))
        self.assertFalse(check(screen,3,0,100))
        self.assertFalse(check(screen.replace('\x1b[48;2;42;67;76m',''),2,0,100))


class McpRestartTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='fleet-mcp-sleep-')
        self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name).resolve()
        self.node=self.root/'node';self.node.touch()
        self.script=self.root/'server.js';self.script.touch()
        self.config={'safe':{'command':str(self.node),'args':[str(self.script)]}}
        self.status={'data':[{'name':'safe','runtimeStatus':'ready','toolsError':None}]}
        self.rows={2:(1,'node')};self.argv={2:[str(self.node),str(self.script)]}
        self.exes={2:self.node};self.source={}
        owner=self
        class Client:
            def call(self,method,args):
                if method=='config/read':return {'config':{'mcp_servers':owner.config}}
                if method=='mcpServerStatus/list':return owner.status
                raise AssertionError(method)
        self.client=Client()

    def classify(self):
        return LIB['MCP']['classify'](self.source,LIB['MCP']['inventory'](self.client),self.rows,1,
                                      lambda pid:self.argv[pid],lambda pid:self.exes[pid])

    def claude_inventory(self,argv,config_home=None):
        return LIB['MCP']['claude_inventory'](argv,self.root/'worktree',config_home or self.root/'home')

    def test_claude_strict_inventory_is_exactly_the_mcp_config_documents(self):
        inventory=LIB['MCP']['claude_inventory']
        one=self.root/'one.json';one.write_text(json.dumps({'mcpServers':{'safe':self.config['safe']}}))
        two=self.root/'two.json';two.write_text(json.dumps({'mcpServers':{'remote':{'type':'http','url':'https://example.invalid'}}}))
        for argv in (['claude','--strict-mcp-config','--mcp-config='+str(one)],
                     ['claude','--mcp-config',str(one),'--strict-mcp-config'],
                     ['claude','--strict-mcp-config','--mcp-config='+json.dumps({'mcpServers':{'safe':self.config['safe']}})]):
            config,statuses=inventory(argv,self.root/'nowhere')
            self.assertEqual((set(config),statuses),({'safe'},None))
        config,_=inventory(['claude','--mcp-config',str(one),str(two),'--strict-mcp-config','prompt'],self.root/'nowhere')
        self.assertEqual(set(config),{'safe','remote'})
        with self.assertRaisesRegex(ValueError,'more than once'):
            inventory(['claude','--strict-mcp-config','--mcp-config',str(one),str(one)],self.root/'nowhere')
        for bad in ('{"mcpServers":[]}','{"mcpServers":{"x":1}}','not json',str(self.root/'missing.json')):
            with self.assertRaisesRegex(ValueError,'incomplete'):
                inventory(['claude','--strict-mcp-config','--mcp-config='+bad],self.root/'nowhere')
        with self.assertRaisesRegex(ValueError,'incomplete'):  # no store beneath a non-strict launch
            inventory(['claude','--mcp-config='+str(one)],self.root/'nowhere',self.root/'nowhere')

    def test_claude_store_scopes_rank_local_over_project_over_user(self):
        wt=self.root/'worktree';wt.mkdir();home=self.root/'home';home.mkdir()
        user={'command':'/u','args':[]};local={'command':'/l','args':[]};project={'command':'/p','args':[]}
        (wt/'.mcp.json').write_text(json.dumps({'mcpServers':{'shared':project,'approved':project,'pending':project,'refused':project}}))
        store={'mcpServers':{'shared':user,'only-user':user,'muted':user},
               'projects':{str(wt.resolve()):{'mcpServers':{'shared':local,'only-local':local},
                                              'enabledMcpjsonServers':['approved','refused'],'disabledMcpjsonServers':['refused'],
                                              'disabledMcpServers':['muted','plugin:x:y']}}}
        (home/'.claude.json').write_text(json.dumps(store))
        flag=self.root/'flag.json';flag.write_text(json.dumps({'mcpServers':{'only-user':{'command':'/f','args':[]}}}))
        config,statuses=self.claude_inventory(['claude','--mcp-config='+str(flag)])
        self.assertIsNone(statuses)
        self.assertEqual({name:conf['command'] for name,conf in config.items()},
                         {'shared':'/l','only-local':'/l','approved':'/p','only-user':'/f'})
        store['projects']={}
        (home/'.claude.json').write_text(json.dumps(store))
        config,_=self.claude_inventory(['claude'])
        self.assertEqual(set(config),{'shared','only-user','muted'})

    def test_claude_plugin_servers_carry_the_clis_names_and_gates(self):
        # A plugin's server is `plugin:<plugin>:<server>`, from the enabled plugins'
        # install roots (issue #830). Anything unresolvable contributes nothing.
        wt=self.root/'worktree';wt.mkdir();home=self.root/'home';home.mkdir()
        (home/'.claude.json').write_text(json.dumps({'projects':{str(wt.resolve()):{'disabledMcpServers':['plugin:muted:tool']}}}))
        (home/'settings.json').write_text(json.dumps({'enabledPlugins':{'shipped@market':True,'muted@market':True,'off@market':False,'ghost@market':True,'twice@market':True,'broken@market':True}}))
        (wt/'.claude').mkdir();(wt/'.claude'/'settings.json').write_text(json.dumps({'enabledPlugins':{'wrapped@market':True}}))
        def install(key,servers,wrapped=False,manifest='.mcp.json'):
            root=home/'plugins'/'cache'/key;(root/'.claude-plugin').mkdir(parents=True)
            (root/manifest).write_text(json.dumps({'mcpServers':servers} if wrapped else servers) if isinstance(servers,dict) else servers)
            return {'installPath':str(root)}
        registry={'shipped@market':[install('shipped',{'tool':{'command':'${CLAUDE_PLUGIN_ROOT}/bin/tool','args':['--root','${CLAUDE_PLUGIN_ROOT}'],'env':{'HOME':'${CLAUDE_PLUGIN_ROOT}'}}})],
                  'wrapped@market':[install('wrapped',{'tool':{'command':'/w','args':[]},'remote':{'type':'http','url':'https://example.invalid'}},wrapped=True)],
                  'muted@market':[install('muted',{'tool':{'command':'/m','args':[]}})],
                  'off@market':[install('off',{'tool':{'command':'/o','args':[]}})],
                  'twice@market':[install('twice-a',{'tool':{'command':'/t','args':[]}}),install('twice-b',{'tool':{'command':'/t','args':[]}})],
                  'broken@market':[install('broken','{not json')]}
        (home/'plugins'/'installed_plugins.json').write_text(json.dumps({'version':2,'plugins':registry}))
        inventory=LIB['MCP']['claude_inventory']
        config,_=inventory(['claude'],wt,home)
        root=registry['shipped@market'][0]['installPath']
        self.assertEqual(config,{'plugin:shipped:tool':{'command':root+'/bin/tool','args':['--root',root],'env':{'HOME':root}},
                                 'plugin:wrapped:tool':{'command':'/w','args':[]},
                                 'plugin:wrapped:remote':{'type':'http','url':'https://example.invalid'}})
        self.assertEqual(inventory(['claude','--strict-mcp-config'],wt,home)[0],{})
        (home/'plugins'/'installed_plugins.json').unlink()
        self.assertEqual(inventory(['claude'],wt,home)[0],{})

    def test_claude_process_evidence_replaces_runtime_status_until_the_server_restarts(self):
        # No runtime RPC: the exact live child is the evidence at sleep, and its
        # restart from an unchanged digest is the evidence at wake.
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='safe'):
            readers=(lambda pid:self.argv[pid],lambda pid:self.exes[pid])
            self.assertEqual(LIB['MCP']['classify'](self.source,(self.config,None),self.rows,1,*readers),{2})
            verify=LIB['MCP']['verify_resume']
            self.assertFalse(verify(self.source,(self.config,None),({},9,*readers)))
            self.assertTrue(verify(self.source,(self.config,None),({2:(9,'node')},9,*readers)))
            self.argv[3]=self.argv[2];self.exes[3]=self.node  # two copies prove nothing about which one Claude owns
            self.assertFalse(verify(self.source,(self.config,None),({2:(9,'node'),3:(9,'node')},9,*readers)))
            changed={'safe':dict(self.config['safe'],env={'TOKEN':'x'})}
            with self.assertRaisesRegex(ValueError,'configuration changed'):verify(self.source,(changed,None),({2:(9,'node')},9,*readers))

    def test_exact_config_and_explicit_contract_required(self):
        self.config['remote']={'url':'https://example.invalid/mcp','command':None,'args':None}
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='',FLEET_CONF_DIR='/cf'):
            with self.assertRaisesRegex(ValueError,'restartability contract'):self.classify()
        # The refusal names the exact line and file that lifts it (#786): a
        # failover refusal is otherwise visible only in request.json.
        self.source['session']='fleet-x'
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='other',FLEET_CONF_DIR='/cf'):
            with self.assertRaisesRegex(ValueError,'add FLEET_SLEEP_MCP_RESTARTABLE=other,safe to /cf/fleets/fleet-x/conf'):self.classify()
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='safe'):
            self.assertEqual(self.classify(),{2})
            self.assertEqual(set(self.source['sleep_mcp']),{'safe'})
            self.argv[2].append('--different')
            self.assertEqual(self.classify(),set())
            self.argv[2].pop();self.exes[2]=self.root/'impostor'
            self.assertEqual(self.classify(),set())

    def test_bare_interpreter_name_matches_the_launchers_build_not_the_verifiers_path(self):
        # The daemon's PATH resolved `node` to node 26 while Codex had started the
        # server under node@22: a bare command name must match the running
        # program's name and exact argv, whatever build the verifier would find.
        other=self.root/'path'/'node';other.parent.mkdir();other.touch();other.chmod(0o755)
        self.config['safe']={'command':'node','args':[str(self.script)]}
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='safe'):
            for path in (str(other.parent),str(self.root/'empty')):
                with patch.dict(os.environ,PATH=path):
                    self.assertEqual(self.classify(),{2})
            with patch.dict(os.environ,PATH=str(other.parent)):
                self.exes[2]=self.root/'python';self.exes[2].touch()
                self.assertEqual(self.classify(),set())
                self.exes[2]=self.node;self.argv[2]=[str(self.node),str(self.script),'--other']
                self.assertEqual(self.classify(),set())

    def test_children_and_partial_inventory_still_veto(self):
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='safe'):
            self.rows[3]=(2,'browser');self.argv[3]=['browser'];self.exes[3]=self.root/'browser'
            with self.assertRaisesRegex(ValueError,'child process'):self.classify()
            del self.rows[3]
            self.status['nextCursor']='more'
            with self.assertRaisesRegex(ValueError,'incomplete'):self.classify()
            del self.status['nextCursor']
            self.status['data'].append(None)
            with self.assertRaisesRegex(ValueError,'incomplete'):self.classify()
            self.status['data'].pop()
            self.status['data'][0]['runtimeStatus']='starting'
            with self.assertRaisesRegex(ValueError,'not ready'):self.classify()

    def test_resume_waits_for_service_and_rejects_changed_config(self):
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='safe'):
            self.classify()
        verify=lambda:LIB['MCP']['verify_resume'](self.source,LIB['MCP']['inventory'](self.client))
        self.assertTrue(verify())
        self.status['data'][0]['runtimeStatus']='starting'
        self.assertFalse(verify())
        self.config['safe']['args'].append('changed')
        with self.assertRaisesRegex(ValueError,'configuration changed'):verify()

    def test_older_runtime_requires_initialize_and_tool_inventory(self):
        ready=LIB['MCP']['runtime_ready']
        self.assertFalse(ready({'runtimeStatus':None}))
        old={'runtimeStatus':None,'serverInfo':{'name':'safe'},'tools':{'read':{}},'toolsError':None}
        self.assertTrue(ready(old))
        old['toolsError']='failed';self.assertFalse(ready(old))

    def test_npx_package_entrypoint_is_allowed_but_its_browser_is_not(self):
        wrapper=self.root/'npx';wrapper.touch()
        package=self.root/'node_modules/safe-mcp';package.mkdir(parents=True)
        script=package/'cli.js';script.touch()
        (package/'package.json').write_text(json.dumps({'name':'safe-mcp','bin':{'safe':'cli.js'}}))
        self.config['safe']={'command':str(wrapper),'args':['safe-mcp@1.0','--stdio']}
        self.argv[2]=[str(self.node),str(wrapper),'safe-mcp@1.0','--stdio']
        self.rows[3]=(2,'node');self.argv[3]=[str(self.node),str(script),'--stdio'];self.exes[3]=self.node
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='safe'):
            self.assertEqual(self.classify(),{2,3})
            self.argv[2]=['npm exec safe-mcp@1.0 --stdio','','','']
            self.assertEqual(self.classify(),{2,3})
            self.exes[3]=self.root/'different-node'
            self.assertEqual(self.classify(),set())
            self.exes[3]=self.node
            self.rows[4]=(3,'browser')
            with self.assertRaisesRegex(ValueError,'job/browser'):self.classify()
            del self.rows[4]
            self.argv[3].append('--wrong')
            self.assertEqual(self.classify(),set())  # rewritten wrapper cannot prove its child

    def test_busy_classify_drops_the_contract_but_keeps_identification(self):
        # child_busy (#864) asks "MCP service or agent work?", not "may it sleep?":
        # an uncontracted server and its job/browser are still infrastructure, an
        # unidentified process is still work.
        self.rows[4]=(2,'browser');self.rows[5]=(4,'renderer')
        readers=(lambda pid:self.argv[pid],lambda pid:self.exes[pid])
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE=''):
            with self.assertRaisesRegex(ValueError,'restartability contract'):self.classify()
            self.assertEqual(LIB['MCP']['classify'](self.source,(self.config,None),self.rows,1,*readers,strict=False),{2,4,5})
            self.argv[2]=self.argv[2]+['--different']
            self.assertEqual(LIB['MCP']['classify'](self.source,(self.config,None),self.rows,1,*readers,strict=False),set())

    def test_uvx_reexec_requires_sibling_binary_and_isolated_entrypoint(self):
        uvx=self.root/'uvx';uvx.touch()
        uv=self.root/'uv';uv.touch()
        self.config['safe']={'command':str(uvx),'args':['--from','safe-mcp','safe-mcp']}
        self.exes[2]=uv;self.argv[2]=[str(uv),'tool','uvx','--from','safe-mcp','safe-mcp']
        env=self.root/'env';(env/'bin').mkdir(parents=True)
        (env/'pyvenv.cfg').touch()
        python=env/'bin/python';python.touch()
        entry=env/'bin/safe-mcp';entry.touch()
        self.rows[3]=(2,'python');self.exes[3]=python;self.argv[3]=[str(python),str(entry)]
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='safe'):
            self.assertEqual(self.classify(),{2,3})
            (env/'pyvenv.cfg').unlink()
            with self.assertRaisesRegex(ValueError,'unverified child'):self.classify()


class ExitDetectionTest(unittest.TestCase):
    def test_unreaped_zombie_counts_as_exited(self):
        # tmux may reap an exited pane process late. BSD ps renames a zombie's
        # comm to <defunct>; Linux procps prints lstart/comm unchanged, so the
        # start fingerprint alone would keep reporting the agent as alive.
        child=subprocess.Popen(['python3','-c','import time;time.sleep(30)'])
        try:
            # macOS reports the launcher's comm until exec settles; fingerprint
            # the running process, as sleep does for a long-idle agent.
            until=time.monotonic()+5;start=LIB['process_start'](child.pid)
            while time.monotonic()<until:
                time.sleep(.1);current=LIB['process_start'](child.pid)
                if current==start:break
                start=current
            data={'source':{'pid':child.pid},'source_start':start}
            self.assertTrue(data['source_start']);self.assertTrue(LIB['source_alive'](data))
            os.kill(child.pid,signal.SIGTERM)
            until=time.monotonic()+5
            while time.monotonic()<until and not LIB['process_state'](child.pid)[0].startswith('Z'):time.sleep(.05)
            self.assertTrue(LIB['process_state'](child.pid)[0].startswith('Z'))
            self.assertFalse(LIB['source_alive'](data))
        finally:child.wait()
        self.assertEqual(LIB['process_state'](child.pid),('',''))
        self.assertFalse(LIB['source_alive'](data))


if __name__=='__main__':unittest.main(verbosity=2)
