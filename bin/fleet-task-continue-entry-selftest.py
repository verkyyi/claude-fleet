#!/usr/bin/env python3
# selftest-entry
"""Owner continuation is explicit, retains lost replies and never uses resume."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import fleet_task_control as control
import fleet_view as view

BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('continue_cli', BIN / 'fleet-session-cli.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
STOP = '22222222-2222-4222-8222-222222222222'
OP = '33333333-3333-4333-8333-333333333333'
RECORD = {'task': dict(id='T42', execution_endpoint='ep', cancel_request=STOP, generation=2)}
ANSWER = dict(task='T42', authorized_generation=3, agent='codex', exit_operation_id=OP,
              operation=dict(operation_id=OP, action='worker_start', status='succeeded'))

class ContinueEntryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = patch.dict(os.environ, {'FLEET_CONF_DIR': self.tmp.name, 'FLEET_HUB_URL': 'https://hub.test', 'CCQUOTA_HUB_URL': 'https://hub.test'})
        env.start(); self.addCleanup(env.stop)

    def test_lost_response_retains_identical_payload_without_reread(self):
        sent = []
        def write(argv, **kwargs):
            sent.append(json.loads(argv[-1]))
            self.assertEqual(argv[-2], 'task_continue')
            if len(sent) == 1:
                raise subprocess.TimeoutExpired(argv, 50)
            return subprocess.CompletedProcess(argv, 0, json.dumps(ANSWER), '')
        with patch.object(control, 'call', return_value=RECORD) as read, patch.object(control.subprocess, 'run', side_effect=write):
            self.assertEqual(control.continue_task({'task':'T42'})[0], 1)
            self.assertEqual(control.continue_task({'task':'T42'})[0], 0)
        self.assertEqual(read.call_count, 1)
        self.assertEqual(sent[0], sent[1])
        self.assertEqual(sent[0]['expected_stop_operation_id'], STOP)
        self.assertEqual(sent[0]['expected_generation'], 2)
        self.assertFalse((Path(self.tmp.name)/'task-continue/T42.json').exists())

    def test_provider_choice_is_frozen_through_lost_reply(self):
        sent=[]
        def writer(argv,**kwargs):
            sent.append(json.loads(argv[-1]))
            if len(sent)==1: raise subprocess.TimeoutExpired(argv,50)
            return subprocess.CompletedProcess(argv,0,json.dumps(dict(ANSWER,agent='claude')),'')
        with patch.object(control,'call',return_value=RECORD) as read, patch.object(control.subprocess,'run',side_effect=writer):
            self.assertEqual(control.continue_task({'task':'T42'},agent='claude')[0],1)
            self.assertEqual(control.continue_task({'task':'T42'},agent='codex')[0],1)
            self.assertEqual(control.continue_task({'task':'T42'},agent='claude')[0],0)
        self.assertEqual(sent[0],sent[1]); self.assertEqual(sent[0]['agent'],'claude')
        self.assertEqual(read.call_count,1)

    def test_reply_agent_and_proof_must_match_intent(self):
        for reply in (dict(ANSWER,agent='claude'),dict(ANSWER,stop_operation_id=STOP),
                      dict(ANSWER,exit_operation_id='invalid')):
            with patch.object(control,'call',return_value=RECORD), patch.object(control.subprocess,'run',return_value=subprocess.CompletedProcess([],0,json.dumps(reply),'')):
                self.assertEqual(control.continue_task({'task':'T42'},agent='codex')[0],1)
        unclaimed=dict(ANSWER,stop_operation_id=STOP);del unclaimed['exit_operation_id']
        with patch.object(control,'call',return_value=RECORD),patch.object(control.subprocess,'run',return_value=subprocess.CompletedProcess([],0,json.dumps(unclaimed),'')):
            self.assertEqual(control.continue_task({'task':'T42'},agent='codex')[0],0)

    def test_explicit_provider_choices_reach_shared_helper(self):
        with patch.object(control,'continue_task',return_value=(0,'accepted')) as action, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.cmd_continue(['T42','--agent','claude']),0)
            action.assert_called_once_with({'task':'T42'},agent='claude')
        row=dict(task='T42',execution_endpoint='ep',cancel_request=STOP,record_only=True)
        with patch.object(view,'continue_task',return_value=(0,'accepted')) as action,patch.object(view,'hub_reread'):
            self.assertEqual(view.act_run(None,'v','fleet',view.ACTION['continue'],row,'codex')[0],0)
            self.assertEqual(action.call_args.kwargs['agent'],'codex')
        self.assertEqual([x[0] for x in view.ACTION['continue']['choices'](row,'fleet')],['same','claude','codex'])

    def test_invalid_reference_refuses_without_io(self):
        with patch.object(control,'call') as read, patch.object(control.subprocess,'run') as write:
            self.assertEqual(control.continue_task({'task':42})[0],1)
            read.assert_not_called(); write.assert_not_called()

    def test_changed_selection_refuses_before_write(self):
        with patch.object(control,'call',return_value=RECORD), patch.object(control.subprocess,'run') as write:
            self.assertEqual(control.continue_task({'task':'T42','cancel_request':STOP,'generation':3})[0],1)
            write.assert_not_called()

    def test_missing_stopped_authority_never_writes(self):
        for record in ({}, {'task':dict(RECORD['task'],cancel_request='')},
                       {'task':dict(RECORD['task'],id='T43')},
                       {'task':dict(RECORD['task'],generation=True)}):
            with patch.object(control,'call',return_value=record), patch.object(control.subprocess,'run') as write:
                self.assertEqual(control.continue_task({'task':'T42'})[0],1)
                write.assert_not_called()

    def test_no_credentials_returns_exact_readonly_web_route(self):
        reply = subprocess.CompletedProcess([],1,'','owner credential required')
        with patch.object(control,'call',return_value=RECORD), patch.object(control.subprocess,'run',return_value=reply) as write:
            rc, said = control.continue_task({'task':'T42'})
        self.assertEqual(rc,1)
        self.assertIn('https://hub.test/app/s/T42',said)
        self.assertIn('owner credential required',said)
        self.assertEqual(write.call_count,1)

    def test_mismatched_ack_is_retained_for_exact_retry(self):
        reply = subprocess.CompletedProcess([],0,json.dumps(dict(ANSWER,task='T43')),'')
        with patch.object(control,'call',return_value=RECORD), patch.object(control.subprocess,'run',return_value=reply):
            self.assertEqual(control.continue_task({'task':'T42'})[0],1)
        self.assertTrue((Path(self.tmp.name)/'task-continue/T42.json').exists())

    def test_task_menu_explicit_continue_and_no_legacy_resume(self):
        row=dict(task='T42',execution_endpoint='ep',cancel_request=STOP,record_only=True,lost=True,gone=True, state='exited')
        actions=[a['id'] for a,_ in view.menu_of(row)]
        self.assertIn('continue',actions)
        self.assertNotIn('resume',actions)
        with patch.object(view,'continue_task',return_value=(0,'accepted')) as action, patch.object(view,'hub_reread'), patch.object(view,'tm',side_effect=AssertionError('no resume')):
            self.assertEqual(view.act_run(None,'v','fleet',view.ACTION['continue'],row,''),(0,'accepted',False))
            self.assertEqual(action.call_count,1)
            self.assertEqual(view.act_run(None,'v','fleet',view.ACTION['resume'],row,'')[0],1)
            self.assertEqual(view.act_run(None,'v','fleet',view.ACTION['resume'],dict(row,far=True),'')[0],1)
        self.assertFalse(view.ACTION['continue']['when'](dict(row,running=True)))

    def test_cli_exact_task_does_not_resolve_or_spawn(self):
        with patch.object(control,'continue_task',return_value=(0,'accepted')) as action, patch.object(cli,'rows',side_effect=AssertionError('no row needed')), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.cmd_continue(['T42']),0)
            action.assert_called_once_with({'task':'T42'})
        self.assertIn('continue',cli.VERBS)

    def test_history_open_does_not_offer_implicit_restore_for_task(self):
        row=dict(task='T42',execution_endpoint='ep',gone=True,state='exited',fid=OP)
        self.assertFalse(view.ACTION['resume']['when'](row))
        with patch.object(view, 'say', return_value='Resume'), patch.object(view, 'ui_lang', return_value='en'), patch.object(view.subprocess,'run',side_effect=AssertionError('history must not launch')):
            self.assertEqual(view.act_run(None,'v','fleet',view.ACTION['resume'],row,'')[0],1)
            self.assertEqual(view.act_run(None,'v','fleet',view.ACTION['resume'],dict(row,far=True),'')[0],1)

    def test_shell_writer_skips_node_door_and_binds_viewer_request(self):
        fakebin = Path(self.tmp.name)/'bin'
        fakebin.mkdir()
        capture=Path(self.tmp.name)/'capture.json'
        fake=fakebin/'curl'
        fake.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:]
Path(os.environ['CAPTURE']).write_text(json.dumps({'args':a,'stdin':sys.stdin.read()}))
Path(a[a.index('-o')+1]).write_text(os.environ['REPLY'])
print('202',end='')
''')
        fake.chmod(0o755)
        config=Path(self.tmp.name)/'config';config.mkdir()
        (config/'node.env').write_text('CCQUOTA_TOKEN=fixture-node\nCCQUOTA_HUB_URL=https://node.invalid\n')
        env=dict(PATH=str(fakebin)+':'+os.environ['PATH'],HOME=self.tmp.name,FLEET_CONF_DIR=str(config),
                 CCQUOTA_HUB_URL='https://hub.test',CCQUOTA_VIEWER_TOKEN='fixture-viewer',
                 CAPTURE=str(capture),REPLY=json.dumps(ANSWER))
        payload=dict(task='T42',expected_stop_operation_id=STOP,expected_generation=2,idempotency_key='stable-key')
        got=subprocess.run(['bash',str(BIN/'fleet-hub-write.sh'),'task_continue',json.dumps(payload)],capture_output=True,text=True,env=env,timeout=10)
        self.assertEqual(got.returncode,0,got.stderr)
        sent=json.loads(capture.read_text())
        self.assertEqual(sent['args'][-1],'https://hub.test/v1/fleet/write')
        self.assertNotIn('fixture-viewer',' '.join(sent['args']))
        envelope=json.loads(sent['args'][sent['args'].index('--data-binary')+1])
        self.assertEqual(envelope['tool'],'task_continue')
        self.assertEqual(json.loads(envelope['args_json']),payload)
        capture.unlink();env.pop('CCQUOTA_VIEWER_TOKEN')
        got=subprocess.run(['bash',str(BIN/'fleet-hub-write.sh'),'task_continue',json.dumps(payload)],capture_output=True,text=True,env=env,timeout=10)
        self.assertEqual(got.returncode,1)
        self.assertIn('node/session worker credentials cannot continue',got.stderr)
        self.assertFalse(capture.exists(),'node door must not be tried')

    def test_definitive_refusal_allows_fresh_explicit_action(self):
        with patch.object(control,'call',return_value=RECORD), patch.object(control.subprocess,'run',return_value=subprocess.CompletedProcess([],1,'{"error":"stale generation"}','')):
            self.assertEqual(control.continue_task({'task':'T42'})[0],1)
        self.assertFalse((Path(self.tmp.name)/'task-continue/T42.json').exists())

    def test_older_history_is_a_read_only_command(self):
        with patch.object(view.curses,'def_prog_mode'),patch.object(view.curses,'endwin'),patch.object(view.curses,'reset_prog_mode'),patch.object(view,'wait_key'),patch.object(view,'ui_lang',return_value='en'),patch.object(view,'act_env',return_value={}),patch.object(view.subprocess,'run') as run:
            from unittest.mock import Mock
            self.assertEqual(view.history_pick(Mock(),'fleet'),1)
        self.assertEqual(Path(run.call_args.args[0][1]).name,'fleet-history.sh')
        self.assertEqual(run.call_args.args[0][2:],['list'])


if __name__ == '__main__':
    unittest.main()
