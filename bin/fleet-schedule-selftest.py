#!/usr/bin/env python3
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

    def check_replay(self,agent):
        import json,os,time,subprocess
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
            with patch.dict(os.environ,env),patch.object(run.Path,'home',return_value=home),patch.object(run,'http',side_effect=http),patch.object(run,'attempt_window',return_value=''),patch.object(run.subprocess,'run',spawn),patch.object(run,'native',return_value={'fid':'fid','sid':'sid','state':'idle','path':'p'}),patch.object(run,'conclusion',return_value='the final answer'),patch.object(run,'busy',return_value=False):
                with self.assertRaises(run.Unreachable):run.run()
                self.assertEqual(spawn.call_count,1)
                argv=spawn.call_args.args[0]
                if agent:self.assertEqual(argv[argv.index('--agent')+1],agent)
                else:self.assertNotIn('--agent',argv)
                fail[0]=False
                self.assertEqual(run.run(),0)
                self.assertEqual(spawn.call_count,1)
                self.assertEqual(calls,['admit','finish','finish'])

if __name__ == '__main__': unittest.main()
