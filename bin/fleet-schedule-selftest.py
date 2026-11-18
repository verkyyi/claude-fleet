#!/usr/bin/env python3
# selftest-entry
"""Self-service schedules: registry fencing and recurrence policy (T1121)."""
import importlib.util
import pathlib
import tempfile
import types
import unittest

HERE = pathlib.Path(__file__).resolve().parent

def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), HERE / (name + '.py'))
    out = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(out)
    return out

class ScheduleTests(unittest.TestCase):
    def setUp(self):
        self.sup = module('fleet-node-supervisor')
        self.schedule = module('fleet_schedule')
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.paths = types.SimpleNamespace(logins=self.tmp.name, state_file=self.tmp.name+'/state.json')
        self.doc = {'id':'schedule-abc', 'revision':1, 'name':'Daily brief', 'prompt':'Summarize my notes',
                    'at':'07:00', 'timezone':'Asia/Shanghai', 'enabled':True, 'deleted':False,
                    'delivery':{'wechat':False,'livepage':False}}
    def test_create_receipt_survives_native_preview(self):
        import json
        mcp = module('fleet-mcp')
        data = {'action': 'create', 'schedule': {'spec': dict(self.doc, prompt='x' * 16000)}}
        response = mcp.tool_result('schedule', data)
        preview = response['content'][0]['text'][:160]
        self.assertEqual(json.loads(preview.split('\n')[0]), {'action':'create', 'schedule_id':self.doc['id']})
        self.assertEqual(response['structuredContent'], data)
        for action in ('update', 'pause', 'list'):
            other = mcp.tool_result('schedule', dict(data, action=action))
            self.assertNotIn('schedule_id', json.loads(other['content'][0]['text']))

    def test_registration_replay_conflict_and_other_login(self):
        self.schedule.apply(self.sup,self.paths,'alice',self.doc)
        self.schedule.apply(self.sup,self.paths,'alice',self.doc)
        bad=dict(self.doc,prompt='changed without revision')
        with self.assertRaises(ValueError): self.schedule.apply(self.sup,self.paths,'alice',bad)
        rows=self.sup.read_json(self.tmp.name+'/alice/services/schedule-abc.json',{})
        self.assertEqual(rows['login'],'alice')
        self.assertFalse(pathlib.Path(self.tmp.name+'/bob/services/schedule-abc.json').exists())
        with self.assertRaises(ValueError): self.schedule.apply(self.sup,self.paths,'../bob',self.doc)
    def test_frequency_calendar_and_timezone(self):
        self.assertEqual(self.schedule.validate(self.sup,self.doc),1)
        for change in ({'at':'','cron':'* * * * *'}, {'timezone':'bad/zone'}, {'at':'24:00'},
                       {'at':'','cron':'0,30 * * * *'}, {'prompt':''}, {'exec':['/bin/sh']}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.schedule.validate(self.sup,dict(self.doc,**change))
        self.assertEqual(self.schedule.validate(self.sup,dict(self.doc,at='',cron='0 */2 * * 1-5')),12)
    def test_agent_registry_and_runner_environment(self):
        self.paths.log=self.tmp.name
        for index,agent in enumerate(('claude','codex','')):
            doc=dict(self.doc,revision=index+1,agent=agent)
            svc=self.schedule.apply(self.sup,self.paths,'alice',doc)
            self.assertEqual(svc.get('agent',''),agent)
            entry=self.sup.task_entry(self.paths,svc,(1000,1000,self.tmp.name),'2026-10-27',1)
            self.assertEqual(entry['env'].get('FLEET_TASK_AGENT',''),agent)
        with self.assertRaises(ValueError):
            self.schedule.apply(self.sup,self.paths,'alice',dict(self.doc,revision=4,agent='other'))
    def test_delete_preserves_entry_and_prevents_revival(self):
        self.schedule.apply(self.sup,self.paths,'alice',self.doc)
        dead=dict(self.doc,revision=2,deleted=True,enabled=False)
        self.schedule.apply(self.sup,self.paths,'alice',dead)
        svc=self.sup.read_json(self.tmp.name+'/alice/services/schedule-abc.json',{})
        self.assertEqual(svc['state'],'stopped')
        self.assertTrue(svc['managed_schedule']['deleted'])
        with self.assertRaises(ValueError): self.schedule.apply(self.sup,self.paths,'alice',self.doc)
    def test_dst_gap_is_skipped_and_overlap_once(self):
        import datetime
        sched={'at':'02:30','tz':'America/New_York'}
        before=datetime.datetime(2026,3,8,tzinfo=datetime.timezone.utc).timestamp()
        ts,_=self.sup.task_slot(dict(sched,managed=True),before,1)
        self.assertEqual(datetime.datetime.fromtimestamp(ts,self.sup.task_tz(sched)).day,9)

    def test_adoption_reuses_one_entry_and_preserves_history(self):
        import json
        directory=pathlib.Path(self.tmp.name)/'alice/services'
        directory.mkdir(parents=True)
        old={'name':'daily','login':'alice','kind':'task','state':'stopped','prompt':self.doc['prompt'],
             'schedule':{'at':'07:00','tz':'Asia/Shanghai'},'done_when':{'file':'~/daily.done'},'agent':'claude'}
        (directory/'daily.json').write_text(json.dumps(old))
        doc=dict(self.doc,entry='daily')
        with self.assertRaises(ValueError):self.schedule.apply(self.sup,self.paths,'alice',doc)
        doc['agent']='claude'
        svc=self.schedule.apply(self.sup,self.paths,'alice',doc)
        self.assertEqual(svc['name'],'daily')
        self.assertEqual(svc['done_when'],old['done_when'])
        self.assertEqual(svc['agent'],'claude')
        self.assertEqual(len(list(directory.glob('*.json'))),1)
        with self.assertRaises(ValueError):self.schedule.apply(self.sup,self.paths,'alice',dict(doc,id='schedule-other'))
    def test_managed_window_matches_runner_id(self):
        import hashlib
        svc=self.schedule.apply(self.sup,self.paths,'alice',self.doc)
        self.paths.log=self.tmp.name
        entry=self.sup.task_entry(self.paths,svc,(1000,1000,self.tmp.name),'2026-10-27',2,'manual-test',1)
        want='schedule-'+hashlib.sha256(b'schedule-abc:manual-test:2').hexdigest()[:24]
        self.assertEqual(entry['window'],want)
    def test_paused_deferred_attempt_uses_frozen_spec(self):
        from unittest.mock import patch
        svc=self.schedule.apply(self.sup,self.paths,'alice',dict(self.doc,agent='claude'))
        ts={'state':'waiting','managed_snapshot':svc,'next_try':0,'slot':'2026-10-27','attempt':1}
        paused=dict(svc,state='stopped',agent='codex',managed_schedule=dict(self.doc,revision=2,enabled=False,agent='codex'))
        daemon=self.sup.Supervisor.__new__(self.sup.Supervisor)
        daemon.p=self.paths;daemon.state={'agent_tasks':{'alice/schedule-abc':ts}};daemon.agent_running={}
        seen=[]
        daemon.start_agent=lambda key,state,snapshot,ident,t:seen.append(snapshot)
        with patch.object(self.sup,'service_files',return_value=[('alice','schedule-abc','',paused,None)]),patch.object(self.sup,'account_ident',return_value=(1000,1000,self.tmp.name)):
            daemon.tend_agent_tasks()
        self.assertEqual(seen,[svc])

class SeatedSlotTests(unittest.TestCase):
    """Task S9F7: on a seated machine every attempt is a job NAME the root core
    rebuilds — the managed slot and a run-now's id must survive that road."""
    def setUp(self):
        self.sup = module('fleet-node-supervisor')
        self.schedule = module('fleet_schedule')
        self.core = module('fleet-node-core')
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.paths = types.SimpleNamespace(logins=self.tmp.name, state_file=self.tmp.name+'/state.json', log=self.tmp.name)
        self.doc = {'id':'schedule-108c04449657f9e32bd0a27007b29239', 'revision':1, 'name':'Daily brief',
                    'prompt':'Summarize', 'at':'07:00', 'timezone':'Asia/Shanghai', 'enabled':True,
                    'deleted':False, 'delivery':{'wechat':False,'livepage':False}}
        self.ident = (1000, 1000, self.tmp.name)

    def through_core(self, svc, ent):
        from unittest.mock import patch
        job = self.sup.task_job(ent)
        self.assertIsNotNone(job, ent['task'])
        with patch.object(self.core.sup, 'service_files', return_value=[('alice', svc['name'], '', svc, None)]), \
             patch.object(self.core.sup, 'Paths', return_value=self.paths):
            return job, self.core.resolve_job(self.paths, 'alice', job, self.ident)

    def test_scheduled_slot_survives_the_core(self):
        svc = self.schedule.apply(self.sup, self.paths, 'alice', self.doc)
        for slot_t in (1793350800, 1793437200):
            ent = self.sup.task_entry(self.paths, svc, self.ident, '2026-11-18', 1, None, slot_t)
            job, back = self.through_core(svc, ent)
            self.assertTrue(job.endswith('+%d' % slot_t), job)
            self.assertEqual(back['env']['FLEET_MANAGED_SLOT'], str(slot_t))
            self.assertEqual(back['window'], ent['window'])

    def test_run_now_id_survives_the_core_even_paused(self):
        svc = self.schedule.apply(self.sup, self.paths, 'alice', self.doc)
        run = 'manual-0123456789abcdef0123456789abcdef'
        for s in (svc, dict(svc, state='stopped')):
            ent = self.sup.task_entry(self.paths, s, self.ident, '2026-11-18', 1, run, 1793350800)
            job, back = self.through_core(s, ent)
            self.assertIn('~' + run, job)
            self.assertNotIn('+', job)
            self.assertEqual(back['env']['FLEET_MANAGED_SLOT'], run)

    def test_core_refuses_a_managed_job_without_a_slot(self):
        from unittest.mock import patch
        svc = self.schedule.apply(self.sup, self.paths, 'alice', self.doc)
        with patch.object(self.core.sup, 'service_files', return_value=[('alice', svc['name'], '', svc, None)]), \
             patch.object(self.core.sup, 'Paths', return_value=self.paths):
            with self.assertRaises(self.core.Refused):
                self.core.resolve_job(self.paths, 'alice', 'task:%s@2026-11-18#1' % svc['name'], self.ident)
            plain = dict(svc, managed_schedule=None)
            with patch.object(self.core.sup, 'service_files', return_value=[('alice', svc['name'], '', plain, None)]):
                with self.assertRaises(self.core.Refused):
                    self.core.resolve_job(self.paths, 'alice', 'task:%s@2026-11-18#1~manual-x' % svc['name'], self.ident)
                ent = self.core.resolve_job(self.paths, 'alice', 'task:%s@2026-11-18#1~1752' % svc['name'], self.ident)
                self.assertNotIn('FLEET_MANAGED_SLOT', ent['env'])

    def test_unmanaged_job_name_is_unchanged(self):
        svc = dict(self.schedule.apply(self.sup, self.paths, 'alice', self.doc), managed_schedule=None)
        ent = self.sup.task_entry(self.paths, svc, self.ident, '2026-11-18', 2, '1752', 1793350800)
        self.assertEqual(self.sup.task_job(ent), 'task:%s@2026-11-18#2~1752' % svc['name'])

    def daemon(self, ts):
        d = self.sup.Supervisor.__new__(self.sup.Supervisor)
        d.p = self.paths; d.state = {'agent_tasks': {'alice/' + self.doc['id']: ts}}; d.agent_running = {}
        d.logged = []; d.log = d.logged.append; d.notifies = []; d.notify_agent = lambda *a: None
        return d

    def test_unreadable_run_now_is_said_not_run_under_hhmm(self):
        import os
        from unittest.mock import patch
        svc = self.schedule.apply(self.sup, self.paths, 'alice', self.doc)
        os.makedirs(self.tmp.name + '/alice/run', exist_ok=True)
        open(self.tmp.name + '/alice/run/' + self.doc['id'], 'w').close()   # unreadable ⇒ read as {}
        ts = {}
        d = self.daemon(ts); seen = []
        d.start_agent = lambda *a: seen.append(a)
        with patch.object(self.sup, 'service_files', return_value=[('alice', svc['name'], '', svc, None)]), \
             patch.object(self.sup, 'account_ident', return_value=self.ident), \
             patch.object(self.sup, 'task_slot', return_value=(None, None)):
            d.tend_agent_tasks()
        self.assertEqual(seen, [])
        self.assertIn('no run id', ts.get('last_error', ''))

    def test_refused_admission_is_a_failure_with_an_alert(self):
        import os
        svc = self.schedule.apply(self.sup, self.paths, 'alice', self.doc)
        ts = {'slot': '2026-11-18', 'slot_t': 1793350800, 'attempt': 1, 'last_run': 1}
        d = self.daemon(ts)
        d.end_agent('alice/' + self.doc['id'], ts, svc, 74, 2)
        self.assertEqual(ts['state'], 'failed')
        self.assertIn('exit 74', ts['last_error'])
        self.assertIn('1793350800', ts['last_error'])
        self.assertTrue(os.path.exists(self.sup.task_alert_path(self.paths, 'alice', self.doc['id'])))
        runs = self.sup.read_json(self.sup.task_runs_path(self.paths, 'alice', self.doc['id']), {})['runs']
        self.assertEqual(runs[-1]['rc'], 74)

    def test_run_request_is_written_for_the_seat(self):
        import os, stat
        p = self.tmp.name + '/req.json'
        self.sup.write_json(p, {'run_id': 'manual-x'}, 0o640, os.getgid())
        st = os.stat(p)
        self.assertEqual((stat.S_IMODE(st.st_mode), st.st_gid), (0o640, os.getgid()))


class FinalTests(unittest.TestCase):
    def setUp(self): self.run = module('fleet_schedule_run')
    def test_claude_final_requires_native_end_and_exact_session(self):
        import json
        rows=[{'sessionId':'one','type':'assistant','message':{'stop_reason':'tool_use','content':[{'type':'text','text':'working'}]}}]
        read=lambda: self.run.final_from_lines(map(json.dumps,rows),'claude','one')
        self.assertEqual(read(),'')
        rows.append({'sessionId':'one','type':'assistant','message':{'stop_reason':'end_turn','content':[{'type':'text','text':'answer'}]}})
        self.assertEqual(read(),'answer')
        self.assertEqual(self.run.final_from_lines(map(json.dumps,rows),'claude','other'),'')
        rows.append({'sessionId':'one','type':'user','message':{'content':[]}})
        self.assertEqual(read(),'')
    def test_codex_commentary_never_counts_as_final(self):
        import json
        rows=[{'type':'session_meta','payload':{'id':'one'}}, {'type':'event_msg','payload':{'type':'task_started'}},
              {'type':'response_item','payload':{'type':'message','role':'assistant','phase':'commentary','content':[{'type':'output_text','text':'working'}]}}]
        read=lambda:self.run.final_from_lines(map(json.dumps,rows),'codex','one')
        self.assertEqual(read(),'')
        rows.append({'type':'event_msg','payload':{'type':'task_complete','last_agent_message':'answer'}})
        self.assertEqual(read(),'answer')
        rows.append({'type':'event_msg','payload':{'type':'task_started'}})
        self.assertEqual(read(),'')

class RunnerTests(unittest.TestCase):
    def test_finish_outage_replays_upload_without_spawning(self):
        for agent in ('', 'claude', 'codex'):
            with self.subTest(agent=agent):self.check_replay(agent)

    def test_mark_over_writes_the_ids_result(self):
        from unittest.mock import patch
        run=module('fleet_schedule_run')
        with patch.object(run.subprocess,'run') as sp:
            run.mark_over('','x');sp.assert_not_called()
            run.mark_over('fid-1','done')
            argv=sp.call_args.args[0]
            self.assertTrue(argv[0].endswith('fleet-id.sh'))
            self.assertEqual(argv[1:],['result','fid-1','--state','succeeded','--summary','done'])

    def test_run_title_is_readable(self):
        run=module('fleet_schedule_run')
        t=1793350000  # 2026-10-30 Asia/Shanghai
        self.assertEqual(run.run_title({'name':'LivePage 模板工厂','timezone':'Asia/Shanghai'},t,1),'LivePage 模板工厂 10-30')
        self.assertEqual(run.run_title({'name':'Daily #brief','timezone':'Asia/Shanghai'},t,3),'Daily brief 10-30 #3')
        long=run.run_title({'name':'一个非常非常长的定时任务名字用来测试截断','timezone':'Asia/Shanghai'},t,2)
        self.assertEqual(long,'一个非常非常长… 10-30 #2')
        self.assertLessEqual(sum(map(run.cols,long)),24)
        self.assertRegex(run.run_title({'name':'','timezone':'No/Zone'},t,1),r'^schedule \d\d-\d\d$')

    def test_attempt_window_finds_its_key(self):
        from unittest.mock import patch
        run=module('fleet_schedule_run')
        rows='@1\tLivePage 模板工厂 10-30\tschedule-k1\n@2\tschedule-k2\t\n@3\tother\t'
        with patch.object(run,'tmux',return_value=rows):
            self.assertEqual(run.attempt_window('test','schedule-k1',{}),'@1')  # renamed: by @schedule_key
            self.assertEqual(run.attempt_window('test','schedule-k2',{}),'@2')  # an older run: by its name
            self.assertEqual(run.attempt_window('test','schedule-k3',{}),'')

    def check_replay(self,agent):
        import json,os,time,subprocess,hashlib
        from unittest.mock import patch,Mock
        run=module('fleet_schedule_run')
        with tempfile.TemporaryDirectory() as d:
            home=pathlib.Path(d)
            script=home/'.claude/fleet/bin/dash-raw-session.sh'
            script.parent.mkdir(parents=True);script.touch();script.chmod(0o700)
            env={'FLEET_CONF_DIR':d,'FLEET_TASK_FLEET':'test','FLEET_MANAGED_SCHEDULE':json.dumps({'id':'schedule-a','revision':1,'agent':agent}),
                 'FLEET_MANAGED_SLOT':'manual-one','FLEET_TASK_ATTEMPT':'1','FLEET_TASK_PROMPT':'summary'}
            calls=[];fail=[True]
            def http(path,body):
                calls.append(path)
                if path=='finish' and fail[0]:raise run.Unreachable('offline')
                return {'run':{'id':'one','state':'running','started':time.time()}}
            spawn=Mock(return_value=subprocess.CompletedProcess([],0,'@1\tname\t\tfid\n',''))
            with patch.dict(os.environ,env),patch.object(run.Path,'home',return_value=home),patch.object(run,'http',side_effect=http),patch.object(run,'attempt_window',return_value=''),patch.object(run.subprocess,'run',spawn),patch.object(run,'native',return_value={'fid':'fid','sid':'sid','state':'idle','path':'p'}),patch.object(run,'conclusion',return_value='the final answer'),patch.object(run,'busy',return_value=False),patch.object(run,'mark_over') as over,patch.object(run,'tmux',return_value='') as stamp:
                with self.assertRaises(run.Unreachable):run.run()
                self.assertEqual(spawn.call_count,1)
                over.assert_called_once_with('fid','the final answer')  # its window can close (done:15m)
                stamp.assert_any_call('test','set-option','-w','-t','@1','@schedule_id','schedule-a')
                stamp.assert_any_call('test','set-option','-w','-t','@1','@schedule_run_id','one')
                key=hashlib.sha256(b'schedule-a:manual-one:1').hexdigest()[:24]
                stamp.assert_any_call('test','set-option','-w','-t','@1','@schedule_key','schedule-'+key)
                argv=spawn.call_args.args[0]
                self.assertEqual(argv[argv.index('--node')+1],'local')  # never placed on another machine
                self.assertRegex(argv[argv.index('--name')+1],r'^schedule \d\d-\d\d$')
                import uuid
                self.assertEqual(argv[argv.index('--fid')+1],str(uuid.uuid5(uuid.NAMESPACE_URL,'schedule-a:manual-one:1')))
                if agent:self.assertEqual(argv[argv.index('--agent')+1],agent)
                else:self.assertNotIn('--agent',argv)
                fail[0]=False
                self.assertEqual(run.run(),0)
                self.assertEqual(spawn.call_count,1)
                self.assertEqual(calls,['admit','finish','finish'])
                over.assert_called_once()  # a replayed upload does not write the result twice

if __name__ == '__main__': unittest.main()
