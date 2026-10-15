#!/usr/bin/env python3
"""State/identity/delivery failures and the complete private-server lifecycle."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

loader = importlib.util.spec_from_file_location('fleet_loop', Path(__file__).with_name('fleet-loop.py'))
loop = importlib.util.module_from_spec(loader)
loader.loader.exec_module(loop)
SID = '12345678-1234-1234-1234-123456789abc'


class CronTests(unittest.TestCase):
    def test_recurring_and_once_without_extra_stop_condition(self):
        start = 1792004400  # 2026-10-14 19:00 UTC
        jobs = [dict(id='patrol', prompt='keep checking', cron='7,22,37,52 * * * *',
                     timezone='America/Los_Angeles', expires_at=start+7*86400, stop_when='', recurring=True),
                dict(id='acceptance', prompt='read acceptance metrics', cron='13 9 21 10 *',
                     timezone='America/Los_Angeles', expires_at=start+7*86400, stop_when='', recurring=False)]
        s = loop.spec(dict(jobs=jobs), now=start)
        once = s['jobs'][1]['next_run_at']
        self.assertEqual(once, 1792599180)  # Oct 21 09:13 PDT
        loop.advance(s, once)
        self.assertIsNone(s['jobs'][1]['next_run_at'])
        self.assertGreater(s['jobs'][0]['next_run_at'], once)
        # A handoff or recovery must preserve a consumed one-shot, not rearm it.
        restored = loop.spec(s, now=once+1)
        self.assertIsNone(restored['jobs'][1]['next_run_at'])
        # Native 2.1.295 delivers one final round at or after the 7-day expiry,
        # then deletes the job (fleet_cron.final_fire).
        loop.advance(restored, start+7*86400)
        self.assertEqual(restored['next_run_at'], start+7*86400+420)
        loop.advance(restored, start+7*86400+420)
        self.assertIsNone(restored['next_run_at'])

    def test_two_schedules_keep_phase_and_expiry(self):
        start = 1792022400  # UTC midnight, minute 0
        jobs = [dict(id='a', prompt='first patrol', cron='*/15 * * * *', timezone='UTC',
                     expires_at=start+3600, stop_when='batch completes'),
                dict(id='b', prompt='second patrol', cron='7,22,37,52 * * * *', timezone='UTC',
                     expires_at=start+3600, stop_when='operator cancels')]
        s = loop.spec(dict(jobs=jobs), now=start)
        self.assertEqual([j['next_run_at'] for j in s['jobs']], [start+900,start+420])
        self.assertEqual(s['next_run_at'],start+420)
        loop.advance(s, start+420)
        self.assertEqual([j['next_run_at'] for j in s['jobs']], [start+900,start+1320])
        self.assertEqual([j['prompt'] for j in s['jobs']], ['first patrol','second patrol'])
        loop.advance(s, start+3601)
        # 'a' (*/15) had its final round at the expiry itself; 'b' still has one.
        self.assertEqual([j['next_run_at'] for j in s['jobs']], [None, start+3600+420])
        loop.advance(s, start+3600+420)
        self.assertIsNone(s['next_run_at'])

    def test_ambiguous_specs_refuse(self):
        for value in [dict(jobs=[]), dict(jobs=[dict(id='x',prompt='p',cron='* * * * *')])]:
            with self.assertRaises(ValueError): loop.spec(value)


class NativeCronTests(unittest.TestCase):
    def setUp(self):
        home = tempfile.TemporaryDirectory()
        self.addCleanup(home.cleanup)
        env = patch.dict(os.environ, HOME=str(Path(home.name).resolve()))
        env.start()
        self.addCleanup(env.stop)

    def test_native_store_requires_an_execution_owner(self):
        import fleet_transfer_cron as native
        home = Path.home()
        store = home/'.claude/scheduled_tasks.json'
        store.parent.mkdir()
        native.check_durable_store()  # absent table
        for value in ([], dict(tasks=[]), dict(jobs=[]),
                      [dict(createdInProject=str(home/'other-project'))]):
            store.write_text(json.dumps(value))
            native.check_durable_store()
        for value in ([dict(id='a',createdInProject=str(home))],
                      dict(tasks=[dict(id='a',createdInProject=str(home))]),
                      [dict(id='unknown-project')], dict(unrecognized=[]), None):
            before=json.dumps(value); store.write_text(before)
            with self.assertRaisesRegex(ValueError, 'execution owner'):
                native.check_durable_store()
            self.assertEqual(store.read_text(),before)
        store.write_text('{')
        with self.assertRaises(ValueError): native.check_durable_store()

    def test_exact_live_snapshot_and_refusals(self):
        import fleet_transfer_cron as native
        now=1792022400
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'source.jsonl'
            jobs=[dict(id='a',prompt='one',cron='*/15 * * * *',timezone='UTC',expires_at=now+3600,stop_when='done',recurring=True,durable=False),
                  dict(id='b',prompt='two',cron='7,22,37,52 * * * *',timezone='UTC',expires_at=None,stop_when='',recurring=False,durable=False)]
            def result(name, inp, response, stamp=now):
                ts=__import__('datetime').datetime.fromtimestamp(stamp,__import__('datetime').timezone.utc).isoformat()
                return [dict(timestamp=ts,message=dict(content=[dict(type='tool_use',name=name,id=name,input=inp)])),
                        dict(timestamp=ts,toolUseResult=response,message=dict(content=[dict(type='tool_result',tool_use_id=name)]))]
            records=result('CronList',{},jobs)
            def write(rs): path.write_text(''.join(json.dumps(r)+'\n' for r in rs))
            write(records)
            raw=dict(jobs=jobs,native_source=dict(pid=42,session_id=SID,fleet_id='fid',confirmed=True))
            mark='kind=cron id=a@%d,b@%d' % (now+4000,now+4000)
            with patch.object(native,'process_start',return_value=now-60):
                write(result('CronList',{},'older display format',now-30)+records)
                self.assertEqual(len(native.validate(raw,path,42,SID,'fid',mark,now)['jobs']),2)
                wrong=json.loads(json.dumps(raw)); wrong['jobs'][1]['recurring']=True
                with self.assertRaises(ValueError): native.validate(wrong,path,42,SID,'fid',mark,now)
                wrong=json.loads(json.dumps(raw)); wrong['jobs'].pop()
                with self.assertRaises(ValueError): native.validate(wrong,path,42,SID,'fid',mark,now)
                # Native text previews prove current membership, never the full
                # prompt or unknown persistence. Preserve the null one-shot expiry.
                text='a — */15 * * * * (recurring) [session-only]: o…\nb — 7,22,37,52 * * * * (one-shot): t…'
                write(result('CronList',{},text))
                proven=json.loads(json.dumps(raw))
                proven['native_source']['job_evidence']={j['id']:{k:dict(value=j[k],source='verified source task record')
                    for k in ('prompt','timezone','expires_at','stop_when','durable')} for j in jobs}
                out=native.validate(proven,path,42,SID,'fid',mark,now)
                self.assertIsNone(out['jobs'][1]['expires_at'])
                proven['native_source']['job_evidence']['b'].pop('durable')
                with self.assertRaises(ValueError): native.validate(proven,path,42,SID,'fid',mark,now)
                proven['native_source']['job_evidence']['b']['durable']=dict(value=True,source='persistent task')
                with self.assertRaises(ValueError): native.validate(proven,path,42,SID,'fid',mark,now)
                write(records)
                # A persisted task is not a proven execution owner. Even an
                # exact record must refuse without changing it or the source.
                home=(Path(d)/'home').resolve(); (home/'.claude').mkdir(parents=True)
                store=home/'.claude/scheduled_tasks.json'
                durable=dict(id='b',cron=jobs[1]['cron'],prompt=jobs[1]['prompt'],createdInProject=str(home))
                store.write_text(json.dumps([durable]))
                kept=json.loads(json.dumps(raw)); kept['jobs'][1]['durable']=True
                kept['native_source']['durable_store']=str(store)
                write(result('CronList',{},kept['jobs']))
                with patch.dict(os.environ,HOME=str(home)):
                    with self.assertRaisesRegex(ValueError,'execution owner'):
                        native.validate(kept,path,42,SID,'fid','kind=cron id=a@%d' % (now+4000),now)
                    self.assertEqual(json.loads(store.read_text()),[durable])
                    store.write_text('[]')
                    # A current CronList reporting durable also refuses even if
                    # its table disappeared; no missing-file bypass.
                    with self.assertRaisesRegex(ValueError,'execution owner'):
                        native.validate(kept,path,42,SID,'fid',mark,now)
                write(records)
                with self.assertRaises(ValueError): native.validate(raw,path,43,SID,'fid',mark,now)
                with self.assertRaises(ValueError): native.validate(raw,path,42,SID,'other',mark,now)
                with self.assertRaises(ValueError): native.validate(raw,path,42,SID,'fid','',now)
                write(records+result('CronDelete',{'id':'b'},{}))
                with self.assertRaises(ValueError): native.validate(raw,path,42,SID,'fid',mark,now)
                write(result('CronList',{},jobs,now-120))
                with self.assertRaises(ValueError): native.validate(raw,path,42,SID,'fid',mark,now)
                write(result('CronList',{},jobs,now-400))
                with self.assertRaises(ValueError): native.validate(raw,path,42,SID,'fid',mark,now)


class LoopTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fleet-loop-test-')
        self.root = Path(self.temp.name)
        self.path = self.root / 'state.json'
        self.r = {'id': 'loop-test', 'status': 'active', 'thread_id': SID,
                  'socket': str(self.root / 'api.sock'), 'worktree': str(self.root),
                  'pane_pid': 42, 'manifest': str(self.root / 'manifest.json'),
                  'fleet': {'session': 'isolated', 'window_id': '@2', 'pane_id': '%2'},
                  'deliveries': 0,
                  'schedule': {'prompt': '继续原任务', 'interval_seconds': 3600, 'next_run_at': 0}}
        loop.save(self.path, self.r)
        self.messages = []
        self.runtime_state = 'idle'
        self.fail_send = False
        self.state = 'done'
        self.clients = ''
        self.transfer = ''
        self.handoff = ''
        self.real_current = loop.current
        owner = self

        class FakeRpc:
            def __init__(self, _): pass
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def call(self, method, params):
                if method == 'thread/read':
                    return {'thread': {'id': SID, 'cwd': str(owner.root),
                                       'status': {'type': owner.runtime_state}}}
                if method == 'turn/start':
                    owner.messages.append(params)
                    if owner.fail_send:
                        raise TimeoutError('unknown whether accepted')
                    return {'turn': {'id': 'accepted-turn-1'}}
                raise AssertionError(method)

        self.patches = [patch.object(loop, 'Rpc', FakeRpc),
                        patch.object(loop, 'current'),
                        patch.object(loop, 'pane', side_effect=lambda _, fmt: self.state if fmt == '#{@claude_state}' else self.transfer if fmt == '#{@agent_transfer_request}' else self.handoff),
                        patch.object(loop, 'tm', side_effect=lambda *_: self.clients)]
        for p in self.patches: p.start()
        self.addCleanup(lambda: [p.stop() for p in reversed(self.patches)])
        self.addCleanup(self.temp.cleanup)

    def read(self): return json.loads(self.path.read_text())

    def test_two_cron_jobs_deliver_independently_once_and_preserve_expiry(self):
        now = 1792022400
        jobs = [dict(id='a',prompt='patrol one',cron='*/15 * * * *',timezone='UTC',expires_at=now+3600,stop_when='done'),
                dict(id='b',prompt='patrol two',cron='7,22,37,52 * * * *',timezone='UTC',expires_at=None,stop_when='',recurring=False,durable=False)]
        self.r['schedule'] = loop.spec(dict(jobs=jobs), now=now)
        loop.save(self.path, self.r)
        loop.dispatch(self.path, now=now+420)
        self.assertEqual(len(self.messages),1)
        self.assertIn('patrol two',self.messages[0]['input'][0]['text'])
        self.assertNotIn('patrol one',self.messages[0]['input'][0]['text'])
        loop.dispatch(self.path, now=now+421)
        self.assertEqual(len(self.messages),1)
        loop.dispatch(self.path, now=now+900)
        self.assertEqual(len(self.messages),2)
        self.assertIn('patrol one',self.messages[1]['input'][0]['text'])
        self.assertEqual([j['next_run_at'] for j in self.read()['schedule']['jobs']], [now+1800,None])
        loop.dispatch(self.path, now=now+1320)
        self.assertEqual(len(self.messages),2)  # one-shot never runs a second time
        loop.dispatch(self.path, now=now+3601)
        # 'a' expired at +3600 and native fires its overdue final round once.
        self.assertEqual(len(self.messages),3)
        self.assertIn('patrol one',self.messages[2]['input'][0]['text'])
        loop.dispatch(self.path, now=now+3700)
        self.assertEqual(len(self.messages),3)
        self.assertEqual(self.read()['status'],'complete')

    def test_ambiguous_multi_cron_delivery_is_never_resent(self):
        now=1792022400
        self.r['schedule']=loop.spec(dict(jobs=[dict(id='a',prompt='patrol',cron='* * * * *',timezone='UTC',expires_at=now+3600,stop_when='done')]),now=now)
        loop.save(self.path,self.r)
        self.fail_send=True
        loop.dispatch(self.path,now=now+60)
        loop.dispatch(self.path,now=now+120)
        self.assertEqual(len(self.messages),1)
        self.assertEqual(self.read()['status'],'paused')

    def test_exact_thread_delivery_and_no_catchup_burst(self):
        loop.dispatch(self.path, now=10000)
        self.assertEqual(len(self.messages), 1)
        self.assertEqual(self.messages[0]['threadId'], SID)
        self.assertIn('继续原任务', self.messages[0]['input'][0]['text'])
        self.assertEqual(self.read()['last_turn_id'], 'accepted-turn-1')
        self.assertEqual(self.read()['schedule']['next_run_at'], 13600)
        loop.dispatch(self.path, now=10001)
        self.assertEqual(len(self.messages), 1)

    def test_busy_and_native_active_defer(self):
        self.state = 'working'
        loop.dispatch(self.path, now=10000)
        self.state = 'done'; self.runtime_state = 'active'
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.messages, [])
        self.assertEqual(self.read()['status'], 'active')

    def test_context_cycle_and_transfer_defer_wakeup(self):
        self.transfer = '/private/request'
        loop.dispatch(self.path, now=10000)
        self.transfer = ''; self.handoff = '1'
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.messages, [])
        self.assertEqual(self.read()['status'], 'active')

    def test_recent_operator_input_defers(self):
        self.clients = '9990|@2'
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.messages, [])

    def test_replaced_pane_pauses(self):
        loop.current.side_effect = ValueError('replaced pane')
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.read()['status'], 'paused')
        self.assertEqual(self.messages, [])

    def test_new_tui_thread_invalidates_old_loaded_thread(self):
        expected = '|'.join(['isolated', '@2', '42', 'codex', self.r['manifest'], str(self.root)])
        with patch.object(loop, 'pane', side_effect=[expected, '0', json.dumps({'session_id': 'new-thread'})]):
            with self.assertRaisesRegex(ValueError, 'TUI switched'):
                self.real_current(self.r)

    def test_unloaded_thread_never_resumed(self):
        self.runtime_state = 'notLoaded'
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.read()['status'], 'paused')
        self.assertEqual(self.messages, [])

    def test_ambiguous_delivery_is_not_retried(self):
        self.fail_send = True
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.read()['status'], 'paused')
        loop.dispatch(self.path, now=20000)
        self.assertEqual(len(self.messages), 1)

    def test_crash_after_persisting_delivering_is_not_retried(self):
        r = self.read(); r['status'] = 'delivering'; loop.save(self.path, r)
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.messages, [])

    def test_competing_controller_is_excluded(self):
        with loop.locked(self.path):
            loop.dispatch(self.path, now=10000)
        self.assertEqual(self.messages, [])

    def test_only_owner_can_change_or_stop_loop(self):
        with patch.dict(os.environ, FLEET_LOOP_RECORD=str(self.path), CODEX_THREAD_ID=SID):
            loop.command(argparse.Namespace(command='defer', seconds=600, prompt_file=None))
            self.assertEqual(self.read()['schedule']['interval_seconds'], 600)
            loop.command(argparse.Namespace(command='stop'))
            self.assertEqual(self.read()['status'], 'stopped')
            with self.assertRaises(ValueError): loop.command(argparse.Namespace(command='bind'))
        with patch.dict(os.environ, FLEET_LOOP_RECORD=str(self.path), CODEX_THREAD_ID='f'*36):
            with self.assertRaises(ValueError): loop.command(argparse.Namespace(command='stop'))

    def test_claude_delivery_requires_exact_transcript_ack_and_never_replays(self):
        history=self.root/'source.jsonl';history.write_text('')
        r=self.read();r.update(agent='claude');loop.save(self.path,r)
        with patch.object(loop,'claude_transcript',return_value=history), patch.object(loop.runpy,'run_path',return_value={'snapshot':lambda *_,**kw:{'state':'empty'}}), patch.object(loop.subprocess,'run') as send:
            loop.dispatch(self.path,now=10000)
            self.assertEqual(self.read()['status'],'delivering')
            self.assertEqual(self.read()['deliveries'],0)
            nonce=self.read()['delivery_id']
            history.write_text(json.dumps({'type':'user','uuid':'inbox-accepted','message':{'content':nonce}})+'\n')
            loop.dispatch(self.path,now=10001)
            self.assertEqual(self.read()['deliveries'],1)
            self.assertEqual(self.read()['last_turn_id'],'inbox-accepted')
            loop.dispatch(self.path,now=10002)
            self.assertEqual(send.call_count,1)

    def test_claude_unacknowledged_frame_pauses_without_resending(self):
        history=self.root/'source.jsonl';history.write_text('')
        r=self.read();r.update(agent='claude');loop.save(self.path,r)
        with patch.object(loop,'claude_transcript',return_value=history), patch.object(loop.runpy,'run_path',return_value={'snapshot':lambda *_,**kw:{'state':'empty'}}), patch.object(loop.subprocess,'run') as send:
            loop.dispatch(self.path,now=10000);loop.dispatch(self.path,now=10031);loop.dispatch(self.path,now=20000)
            self.assertEqual(self.read()['status'],'paused');self.assertEqual(send.call_count,1)

    def test_loop_generation_can_be_claimed_only_once(self):
        r=self.read();loop.claim_owner(self.path,r,{});loop.save(self.path,r)
        target=self.root/'next.json';target2=self.root/'other.json'
        raw=dict(previous_record=str(self.path),generation=1)
        next_record=dict(r)
        loop.claim_owner(target,next_record,raw)
        self.assertEqual(self.read()['active_record'],str(target))
        with self.assertRaises(ValueError):loop.claim_owner(target2,dict(r),raw)

    def test_crash_recovery_uses_exact_uuid_and_does_not_revive_stops(self):
        record=self.root/'handoffs/packet/loop/state.json';record.parent.mkdir(parents=True)
        r=self.read();r.update(agent='codex',controller_pid=99999999,home=str(self.root/'home'))
        loop.save(record,r)
        adapter={'tmux':lambda *_:'@9|%9|99|'+str(self.root)+'|codex|'+r['manifest']+'|',
                 'identity':lambda *_:dict(session_id=SID,remote='unix:///tmp/restored.sock',home=r['home'])}
        with patch.dict(os.environ,FLEET_CONF_DIR=str(self.root)), patch.object(loop.runpy,'run_path',return_value=adapter), patch.object(loop,'dispatch') as dispatch:
            loop.recover('isolated')
            saved=json.loads(record.read_text());self.assertEqual(saved['fleet']['pane_id'],'%9')
            self.assertEqual(saved['driver'],'quotawatch');self.assertEqual(dispatch.call_count,1)
            saved['status']='waiting-quota';saved['quota_request']='/exact/request';loop.save(record,saved)
            loop.recover('isolated')
            self.assertEqual(json.loads(record.read_text())['status'],'waiting-quota')
            self.assertEqual(dispatch.call_count,2)
            saved['status']='stopped';loop.save(record,saved);loop.recover('isolated')
            self.assertEqual(dispatch.call_count,2)
            saved['status']='active';saved['thread_id']='other-session';loop.save(record,saved);loop.recover('isolated')
            self.assertEqual(dispatch.call_count,2)

    def test_bad_spec_and_wrong_thread_are_rejected(self):
        for value in [{}, {'prompt': 'x', 'interval_seconds': 0},
                      {'prompt': 'x', 'interval_seconds': True},
                      {'prompt': '', 'interval_seconds': 60},
                      {'prompt': 'x', 'interval_seconds': 60, 'next_run_at': float('inf')}]:
            with self.assertRaises(ValueError): loop.spec(value)
        r = self.read(); r['thread_id'] = 'different'; loop.save(self.path, r)
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.read()['status'], 'paused')
        self.assertEqual(self.messages, [])

    def test_import_successful_wakeup_and_respect_stop(self):
        transcript = self.root / 'source.jsonl'; out = self.root / 'loop.json'
        rows = [{'timestamp': '2026-01-01T00:00:00Z', 'message': {'content': [{'type': 'tool_use', 'id': 'wake', 'name': 'ScheduleWakeup',
                                         'input': {'prompt': '检查 CI', 'delaySeconds': 3600}}]}},
                {'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'wake', 'content': 'ok'}]}}]
        transcript.write_text(''.join(json.dumps(x) + '\n' for x in rows))
        a = argparse.Namespace(transcript=str(transcript), output=str(out))
        loop.from_claude(a)
        self.assertEqual(json.loads(out.read_text())['prompt'], '检查 CI')
        self.assertEqual(json.loads(out.read_text())['next_run_at'], 1767229200)
        rows[0]['message']['content'][0]['input'] = {'stop': True}
        transcript.write_text(''.join(json.dumps(x) + '\n' for x in rows))
        with self.assertRaises(ValueError): loop.from_claude(a)


    def sleep_fixture(self, status='active'):
        self.path = self.root / 'loop/state.json'
        self.path.parent.mkdir(exist_ok=True)
        r = dict(self.r, agent='codex', status=status, controller_pid=42,
                 schedule=dict(self.r['schedule'], next_run_at=time.time()+3600))
        loop.save(self.path, r)
        source = dict(previous=r['manifest'], session_id=SID, agent='codex', pid=100,
                      session='isolated', window='@2', pane='%2', home=str(self.root),
                      worktree=str(self.root), codex_identity={'remote':'unix:///new.sock'})
        return source, self.root / 'sleep.json'

    def test_sleep_rebinds_schedule_without_turn_then_dispatches_once(self):
        source, retained = self.sleep_fixture()
        snapshot = loop.sleep_snapshot(source)
        due = snapshot['record']['schedule']['next_run_at']
        loop.sleep_suspend(snapshot, retained)
        loop.dispatch(self.path, now=due+100)
        self.assertEqual(self.messages, [])
        loop.sleep_resume(snapshot, retained, source, 55)
        loop.sleep_resume(snapshot, retained, source, 55)  # crash after rebind
        r = self.read()
        self.assertEqual(r['driver'], 'quotawatch')
        self.assertEqual(r['controller_pid'], 0)
        self.assertEqual(r['pane_pid'], 55)
        self.assertEqual(r['socket'], '/new.sock')
        self.assertEqual(r['schedule'], snapshot['record']['schedule'])
        self.assertEqual(self.messages, [])
        with patch.object(loop.runpy,'run_path',return_value={'snapshot':lambda *a,**kw:{'state':'empty'}}):
            loop.dispatch(self.path, now=due+100)
            loop.dispatch(self.path, now=due+101)
        self.assertEqual(len(self.messages), 1)

    def test_sleep_failure_rolls_back_without_losing_quota_wait(self):
        source, retained = self.sleep_fixture('waiting-quota')
        snapshot = loop.sleep_snapshot(source)
        loop.sleep_resume(snapshot, retained, source, 42, rollback=True)  # crash before suspend
        loop.sleep_suspend(snapshot, retained)
        loop.sleep_resume(snapshot, retained, source, 42, rollback=True)
        self.assertEqual(self.read(), snapshot['record'])
        loop.sleep_suspend(snapshot, retained)
        loop.sleep_resume(snapshot, retained, source, 55)
        self.assertEqual(self.read()['status'], 'waiting-quota')
        self.assertEqual(self.messages, [])

    def test_sleep_never_revives_explicit_stop_or_changed_schedule(self):
        source, retained = self.sleep_fixture()
        for kind in ('stop','schedule','thread','token'):
            loop.save(self.path, dict(self.r,agent='codex',schedule=dict(self.r['schedule'],next_run_at=time.time()+3600)))
            snapshot = loop.sleep_snapshot(source)
            loop.sleep_suspend(snapshot, retained)
            r=self.read()
            if kind=='stop':r.update(status='stopped',detail='Stopped by owner thread')
            elif kind=='schedule':r['schedule']['next_run_at']+=1
            elif kind=='thread':r['thread_id']='replacement'
            else:r['sleep_record']='another-sleep'
            loop.save(self.path,r)
            with self.assertRaises(ValueError):loop.sleep_resume(snapshot,retained,source,55)
        self.assertEqual(self.messages,[])

    def test_old_bridge_exit_is_recoverable_only_with_sleep_token(self):
        source, retained = self.sleep_fixture()
        snapshot=loop.sleep_snapshot(source);loop.sleep_suspend(snapshot,retained)
        r=self.read();r.update(status='stopped',detail='Codex TUI/controller ended; no automatic restart')
        loop.save(self.path,r);loop.sleep_resume(snapshot,retained,source,55)
        self.assertEqual(self.read()['status'],'active')

    def test_sleep_rejects_due_ambiguous_and_wrong_owner(self):
        source, retained=self.sleep_fixture()
        for status in ('delivering','paused','unbound'):
            r=self.read();r['status']=status;loop.save(self.path,r)
            with self.assertRaisesRegex(ValueError,'unresolved'):loop.sleep_snapshot(source)
        r['status']='active';r['schedule']['next_run_at']=0;loop.save(self.path,r)
        with self.assertRaisesRegex(ValueError,'due'):loop.sleep_snapshot(source)
        r['schedule']['next_run_at']=time.time()+3600;loop.save(self.path,r)
        with self.assertRaisesRegex(ValueError,'another native'):loop.sleep_snapshot(dict(source,session_id='wrong'))

    def test_lifecycle_guard_prevents_dispatch_during_rebind(self):
        with patch.object(loop,'pane',side_effect=lambda _,f:'waking' if f=='#{@worker_lifecycle}' else 'done' if f=='#{@claude_state}' else ''):
            loop.dispatch(self.path,now=10000)
        self.assertEqual(self.messages,[])


class BridgeTest(unittest.TestCase):
    def test_private_server_tui_bind_delivery_and_exit(self):
        with tempfile.TemporaryDirectory(prefix='fleet-loop-bridge-') as tmp:
            root = Path(tmp).resolve(); fake = root / 'bin'; fake.mkdir()
            manifest = root / 'manifest.json'; schedule = root / 'loop-spec.json'
            source = subprocess.Popen(['sh', '-c', 'exit 0']); source.wait()
            data = {'source': {'pid': source.pid}, 'fleet': {'session': 'isolated', 'window_id': '@2', 'pane_id': '%2'},
                    'workspace': {'path': str(root)}, 'loop_spec_path': str(schedule)}
            manifest.write_text(json.dumps(data))
            schedule.write_text(json.dumps({'prompt': '检查 CI', 'interval_seconds': 3600, 'next_run_at': 0}))
            codex = fake / 'codex'
            __import__('shutil').copyfile(Path(__file__).with_name('fleet-loop-fake-codex.py'), codex)
            tmux = fake / 'tmux'
            tmux.write_text('''#!/usr/bin/env python3
import json,os,sys
a=sys.argv[1:];r=os.environ['LOOP_TEST_ROOT']
if a[2:3]==['display-message']:
 f=a[-1]
 if f=='#{pane_pid}':print('42')
 elif f=='#{pane_dead}':print('0')
 elif f=='#{@claude_state}':print('done')
 elif f in ('#{@agent_transfer_request}','#{@handoff_armed}','#{@quota_failover}','#{@agent_transfer_until}','#{@worker_lifecycle}'):print('')
 elif f=='#{cursor_x} #{cursor_y} #{pane_width}':print('2 0 80')
 elif f=='#{@codex_identity}':print(json.dumps({'session_id':'12345678-1234-1234-1234-123456789abc'}))
 else:print('isolated|@2|42|codex|'+r+'/manifest.json|'+r)
elif 'capture-pane' in a:print('› ')
''')
            for f in (codex, tmux): f.chmod(0o755)
            script = str(Path(__file__).with_name('fleet-loop.py'))
            env = dict(os.environ, PATH=str(fake)+':'+os.environ['PATH'],
                       FLEET_HANDOFF_MANIFEST=str(manifest), FLEET_LOOP_SPEC=str(schedule),
                       LOOP_TEST_ROOT=str(root), LOOP_TEST_SCRIPT=script)
            cp = subprocess.run(['python3', script, 'bridge', '--', '-c', 'hooks.Stop=[]', 'pickup'],
                                env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(cp.returncode, 0, cp.stdout+cp.stderr)
            r = json.loads((root/'loop/state.json').read_text())
            self.assertEqual(r['status'], 'stopped')
            self.assertEqual(r['deliveries'], 1)
            self.assertEqual(r['last_turn_id'], 'native-turn')
            self.assertEqual(json.loads((root/'delivered.json').read_text())['threadId'], SID)
            self.assertIn('hooks.Stop=[]', json.loads((root/'server-argv.json').read_text()))
            with self.assertRaises(ProcessLookupError): os.kill(int((root/'server-pid').read_text()), 0)
            self.assertFalse(Path(r['socket']).exists())


if __name__ == '__main__':
    unittest.main()
