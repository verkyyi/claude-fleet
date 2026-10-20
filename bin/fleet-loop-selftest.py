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
import uuid
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
                        patch.object(loop, 'tm', side_effect=lambda *_: self.clients),
                        patch.object(loop, 'wait_reasons', return_value=[])]
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




class IdleDispatchTests(unittest.TestCase):
    """#4431: a due wakeup follows fresh native idle, never the panel's done/looping word.

    Two tiers. A pane with a C3 launch goes through fleet_runtime: a fresh v1 read,
    then accept_if_idle — Codex and Claude alike (#4658), capability_unavailable
    only for a provider the adapter has none for; only `accepted` counts. A pane
    without one keeps its original road (legacy_unfenced).
    """
    def setUp(self):
        LoopTests.setUp(self)
        owner = self
        self.opts = {'#{@claude_state}': 'looping'}
        self.waits, self.accepts = [], []
        self.snap = dict(state='idle', reason='', provider='codex', sid=SID)
        self.accept = 'accepted'

        class Runtime:
            @staticmethod
            def read(pane, context=None, expected=None, socket=''):
                s = owner.snap
                return dict(version=1, observed_at=time.time(), expires_at=time.time() + 5,
                            identity=dict(provider=s['provider'], native_session=s['sid'],
                                          generation=3, turn_id='user-turn-1'),
                            runtime=dict(state=s['state'], reason=s['reason']))

            @staticmethod
            def idle_accept_capability(provider):
                ok = provider in ('codex', 'claude')
                return dict(state='available' if ok else 'unavailable',
                            reason='' if ok else 'native_precondition_unavailable')

            @staticmethod
            def accept_if_idle(pane, expected, delivery_id, text, socket=''):
                owner.accepts.append((delivery_id, text))
                st = owner.accept
                return dict(state=st, delivery_id=delivery_id, submitted=st != 'rejected',
                            reason={'accepted': 'native_started', 'unknown': 'receipt_scan_incomplete',
                                    'rejected': 'native_not_idle'}[st],
                            receipt=dict(turn_id='loop-turn-%d' % len(owner.accepts),
                                         intervening_turn=False) if st == 'accepted' else None)

        for p in (patch.object(loop, 'pane', side_effect=lambda _, f: owner.opts.get(f, '')),
                  patch.object(loop, 'wait_reasons', side_effect=lambda r: list(owner.waits)),
                  patch.object(loop, '_runtime', return_value=Runtime)):
            p.start()
            self.addCleanup(p.stop)

    def read(self): return json.loads(self.path.read_text())

    def c3(self, agent='codex'):
        self.opts['#{@launch}'] = json.dumps(dict(provider=agent))
        r = self.read(); r['agent'] = agent; loop.save(self.path, r)
        p = patch.object(loop.runpy, 'run_path', return_value={'snapshot': lambda *_, **kw: {'state': 'empty'}})
        p.start()
        self.addCleanup(p.stop)

    def test_stop_looping_own_loop_legacy_codex_delivers_once(self):
        loop.dispatch(self.path, now=10000)
        self.assertEqual(len(self.messages), 1)
        r = self.read()
        self.assertEqual((r['deliveries'], r['accepted_turn'], r['deferred_reason'], r['due_since']),
                         (1, 'accepted-turn-1', None, None))
        self.assertEqual(r['last_attempt']['fence'], 'legacy_unfenced')
        loop.dispatch(self.path, now=10001)
        self.assertEqual(len(self.messages), 1)

    def test_real_waits_defer_with_reason_then_deliver_once(self):
        for waits, why in ((['bg'], 'wait:bg'), (['tool', 'children'], 'wait:tool,children'), (['unknown'], 'wait:unknown')):
            self.waits = waits
            loop.dispatch(self.path, now=10000)
            self.assertEqual((self.messages, self.read()['deferred_reason']), ([], why))
        self.assertEqual(self.read()['due_since'], 10000)
        self.waits = []
        loop.dispatch(self.path, now=10005)
        loop.dispatch(self.path, now=10006)
        self.assertEqual(len(self.messages), 1)
        self.assertIsNone(self.read()['due_since'])

    def test_attention_turn_transfer_and_input_gates_keep_their_reasons(self):
        cases = (({'#{@claude_state}': 'needs'}, 'attention'),
                 ({'#{@claude_state}': 'working'}, 'active_turn'),
                 ({'#{@claude_state}': 'exited'}, 'state:exited'),
                 ({'#{@agent_transfer_request}': '/private/req'}, 'transfer'),
                 ({'#{@handoff_armed}': '1'}, 'handoff'))
        for extra, why in cases:
            self.opts = dict({'#{@claude_state}': 'done'}, **extra)
            loop.dispatch(self.path, now=10000)
            self.assertEqual((self.messages, self.read()['deferred_reason']), ([], why), extra)
        self.opts = {'#{@claude_state}': 'done'}
        self.clients = '9990|@2'
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.read()['deferred_reason'], 'recent_input')
        self.clients = ''
        r = self.read(); r['agent'] = 'codex'; loop.save(self.path, r)
        with patch.object(loop.runpy, 'run_path', return_value={'snapshot': lambda *_, **kw: {'state': 'draft'}}):
            loop.dispatch(self.path, now=10000)
        self.assertEqual((self.messages, self.read()['deferred_reason']), ([], 'input_draft'))

    def test_c3_codex_accepted_exactly_once_never_turn_start(self):
        self.c3()
        loop.dispatch(self.path, now=10000)
        loop.dispatch(self.path, now=10001)
        r = self.read()
        self.assertEqual((len(self.accepts), self.messages), (1, []))
        self.assertEqual((r['deliveries'], r['accepted_turn'], r['last_turn_id'], r['status']),
                         (1, 'loop-turn-1', 'loop-turn-1', 'active'))
        a = r['last_attempt']
        self.assertEqual((a['fence'], a['state'], a['delivery_id'], a['native_session'], a['task_generation']),
                         ('native_idle', 'accepted', self.accepts[0][0], SID, 3))
        self.assertNotIn('pending_delivery', r)

    def test_c3_unknown_keeps_pending_and_settles_the_same_delivery(self):
        self.c3()
        self.accept = 'unknown'
        loop.dispatch(self.path, now=10000)
        r = self.read()
        self.assertEqual((r['status'], r['deliveries'], r['deferred_reason']),
                         ('delivering', 0, 'unknown:receipt_scan_incomplete'))
        self.accept = 'accepted'
        loop.dispatch(self.path, now=10001)
        loop.dispatch(self.path, now=10002)
        self.assertEqual(len(self.accepts), 2)
        self.assertEqual(self.accepts[0], self.accepts[1])  # same id + text: a settle, never a new send
        self.assertEqual((self.read()['deliveries'], self.read()['status']), (1, 'active'))

    def test_c3_rejected_stays_due_and_retries_as_a_new_delivery(self):
        self.c3()
        self.accept = 'rejected'
        loop.dispatch(self.path, now=10000)
        r = self.read()
        self.assertEqual((r['status'], r['deliveries'], r['deferred_reason'], r['schedule']['next_run_at']),
                         ('active', 0, 'rejected:native_not_idle', 0))
        self.accept = 'accepted'
        loop.dispatch(self.path, now=10010)
        self.assertNotEqual(self.accepts[0][0], self.accepts[1][0])
        self.assertEqual(self.read()['deliveries'], 1)

    def claude(self):
        self.c3('claude')
        self.snap['provider'] = 'claude'
        inbox = patch.object(loop, 'deliver_claude', side_effect=AssertionError('legacy inbox on a C3 pane'))
        inbox.start()
        self.addCleanup(inbox.stop)

    def test_c3_claude_accepted_through_the_runtime_never_the_inbox(self):
        self.claude()
        loop.dispatch(self.path, now=10000)
        loop.dispatch(self.path, now=10001)
        r = self.read()
        self.assertEqual((len(self.accepts), self.messages), (1, []))
        self.assertEqual((r['deliveries'], r['accepted_turn'], r['status'], r['deferred_reason']),
                         (1, 'loop-turn-1', 'active', None))
        a = r['last_attempt']
        self.assertEqual((a['fence'], a['state'], a['delivery_id'], a['native_session']),
                         ('native_idle', 'accepted', self.accepts[0][0], SID))
        self.assertNotIn('pending_delivery', r)
        self.assertNotIn('delivery_offset', r)  # the legacy transcript road never ran

    def test_c3_claude_unknown_settles_the_same_delivery_rejected_stays_due(self):
        self.claude()
        self.accept = 'unknown'
        loop.dispatch(self.path, now=10000)
        self.assertEqual((self.read()['status'], self.read()['deliveries']), ('delivering', 0))
        self.accept = 'accepted'
        loop.dispatch(self.path, now=10001)
        self.assertEqual(self.accepts[0], self.accepts[1])  # a settle, never a new send
        self.assertEqual(self.read()['deliveries'], 1)
        r = self.read(); r['schedule']['next_run_at'] = 0; loop.save(self.path, r)
        self.accept = 'rejected'
        loop.dispatch(self.path, now=10010)
        r = self.read()
        self.assertEqual((r['status'], r['deliveries'], r['deferred_reason'], r['schedule']['next_run_at']),
                         ('active', 1, 'rejected:native_not_idle', 0))

    def test_defer_while_a_fenced_claude_delivery_is_pending_never_reads_the_legacy_ack(self):
        r = self.read()
        r.update(agent='claude', status='delivering',
                 pending_delivery=dict(delivery_id=str(uuid.uuid4()), text='x', due_ids=[],
                                       generation=0, native_session=SID))
        loop.save(self.path, r)
        with patch.dict(os.environ, FLEET_LOOP_RECORD=str(self.path)), \
                patch.object(loop, 'current', lambda r: None), \
                patch.object(loop, 'claude_identity', return_value={'session_id': SID}), \
                patch.object(loop, 'acknowledge_claude', side_effect=AssertionError('legacy ack')):
            with self.assertRaisesRegex(ValueError, 'not active'):
                loop.command(argparse.Namespace(command='defer', seconds=600, prompt_file=None))
        self.assertEqual(self.read()['status'], 'delivering')

    def test_c3_provider_without_an_accept_is_never_sent(self):
        self.c3()
        self.snap['provider'] = 'gemini'
        loop.dispatch(self.path, now=10000)
        self.assertEqual((self.accepts, self.messages), ([], []))
        self.assertEqual(self.read()['deferred_reason'], 'capability_unavailable:native_precondition_unavailable')
        self.assertEqual(self.read()['status'], 'active')

    def test_stale_busy_or_foreign_snapshot_never_delivers(self):
        self.c3()
        for snap, why in ((dict(state='unknown', reason='expired'), 'runtime:unknown:expired'),
                          (dict(state='active'), 'runtime:active'),
                          (dict(state='approval'), 'runtime:approval'),
                          (dict(sid='f' * 36), 'runtime:identity_changed')):
            self.snap = dict(self.snap, **snap)
            loop.dispatch(self.path, now=10000)
            self.assertEqual((self.accepts, self.read()['deferred_reason']), ([], why), snap)
            self.snap = dict(state='idle', reason='', provider='codex', sid=SID)

    def test_pending_delivery_of_another_generation_or_session_is_never_resent(self):
        self.c3()
        for stale in (dict(generation=7), dict(native_session='f' * 36)):
            r = self.read()
            r.update(status='delivering', generation=1,
                     pending_delivery=dict(dict(delivery_id=str(uuid.uuid4()), text='x', due_ids=[],
                                                generation=1, native_session=SID), **stale))
            loop.save(self.path, r)
            loop.dispatch(self.path, now=10000)
            self.assertEqual((self.accepts, self.read()['status']), ([], 'paused'))


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
 elif f in ('#{@agent_transfer_request}','#{@handoff_armed}','#{@quota_failover}','#{@agent_transfer_until}','#{@launch}'):print('')
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
