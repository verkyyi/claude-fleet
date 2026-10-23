#!/usr/bin/env python3
# selftest-entry
"""Task stop survives missing windows; uncertainty never authorizes worker_stop."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch
import fleet_task_control as control
import fleet_task_execution as execution
import fleet_view as view

BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('stop_cli', BIN / 'fleet-session-cli.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
FID = '11111111-1111-4111-8111-111111111111'
OP = '22222222-2222-4222-8222-222222222222'
SNAP = dict(task_ref='T42', task_fid=OP, generation=1, binding_generation=1,
            attempt_id='task:T42:g1', operation_id=OP, execution_endpoint='offline',
            execution_owner=OP+'/'+FID, cancel_request='')
REPLY = dict(stop_requested=True, execution_exit_confirmed=False,
             operation=dict(operation_id=OP, action='worker_stop', status='succeeded'))

class StopEntryTests(unittest.TestCase):
    def setUp(self):
        self.local = patch.object(execution, 'read_session', return_value=None)
        self.local.start()
        self.addCleanup(self.local.stop)

    def test_record_only_offline_has_stop_and_posts_directly(self):
        row = dict(task='T42', execution_endpoint='offline', record_only=True, lost=True,
                   pin=True, loop=True, reap='keep', dirty=True)
        self.assertEqual(control.controlled_stop_task(row), 'T42')
        with patch.object(control, 'call', return_value=REPLY) as call:
            rc, said = control.stop_task(row)
        self.assertEqual(rc, 0)
        self.assertIn('等待原生', said)
        self.assertEqual(call.call_args.args[:2], ('stop', 'T42'))
        self.assertNotIn('owner', call.call_args.args[2])

    def test_marker_and_durable_local_evidence_override_missing_board(self):
        for marker in (True, False):
            row = dict(fid=FID)
            if marker: row['task_execution'] = json.dumps(SNAP)
            with patch.object(execution, 'read_session', return_value=None if marker else SNAP), \
                    patch.object(control, 'call', return_value=REPLY) as call:
                self.assertEqual(control.stop_task(row)[0], 0)
                self.assertEqual(call.call_args.args[0:2], ('stop', 'T42'))

    def test_identity_conflicts_and_malformed_marker_refuse(self):
        for row in (dict(task='T43',task_execution=SNAP), dict(fid=OP,task_execution=SNAP),
                    dict(task_execution='broken'), dict(execution_endpoint='offline')):
            with self.subTest(row=row), patch.object(control, 'call') as call:
                self.assertEqual(control.stop_task(row)[0], 1)
                call.assert_not_called()

    def test_unknown_authority_never_falls_back(self):
        for outcome in (ValueError('offline'), None, {}, {'task':{'id':'T43'}}):
            kwargs = {'side_effect':outcome} if isinstance(outcome,Exception) else {'return_value':outcome}
            with self.subTest(outcome=outcome), patch.object(control, 'call', **kwargs):
                self.assertEqual(control.stop_task(dict(task='T42'))[0], 1)
        with patch.object(control, 'call', side_effect=ValueError('refused')):
            self.assertEqual(control.stop_task(dict(task='T42',execution_endpoint='offline'))[0], 1)

    def test_fresh_legacy_is_the_only_task_fallback(self):
        with patch.object(control, 'call', return_value={'task':{'id':'T42'}}) as call:
            self.assertIsNone(control.stop_task(dict(task='T42')))
            call.assert_called_once_with('get','T42')
        with patch.object(control, 'call') as call:
            self.assertIsNone(control.stop_task({}))
            call.assert_not_called()

    def test_fresh_controlled_record_routes_to_task_stop(self):
        with patch.object(control,'call',side_effect=[{'task':{'id':'T42','execution_endpoint':'ep'}},REPLY]) as call:
            self.assertEqual(control.stop_task(dict(task='T42'))[0],0)
            self.assertEqual([x.args[0] for x in call.call_args_list],['get','stop'])

    def test_reply_requires_acceptance_and_native_scope_not_operation_success(self):
        for reply in ({'operation':REPLY['operation']}, dict(REPLY,execution_exit_confirmed=True),
                      dict(REPLY,execution_exit_confirmed='true'), dict(REPLY,operation={'action':'worker_stop'})):
            with patch.object(control,'call',return_value=reply):
                self.assertEqual(control.stop_task(dict(task='T42',execution_endpoint='ep'))[0],1)
        with patch.object(control,'call',return_value=dict(REPLY,execution_exit_confirmed=True,scope='native_session')):
            self.assertIn('退出已确认',control.stop_task(dict(task='T42',execution_endpoint='ep'))[1])
        with patch.object(control,'call',return_value=dict(REPLY,execution_never_started=True)):
            self.assertIn('尚未启动',control.stop_task(dict(task='T42',execution_endpoint='ep'))[1])

    def test_panel_offline_menu_and_execution_never_use_legacy(self):
        row = dict(task='T42',execution_endpoint='ep',record_only=True,lost=True,far=True,
                   name='task',kind='sess',state='idle',target='id:42')
        self.assertEqual(view.menu_of(row)[0][0]['id'],'stop')
        self.assertEqual(view.page_of(row)[0][0]['id'],'stop')
        with patch.object(view,'stop_task',return_value=(0,'durable')), patch.object(view,'hub_reread'), \
                patch.object(view.subprocess,'run',side_effect=AssertionError('no worker_stop')):
            self.assertEqual(view.act_run(None,'view','fleet',view.ACTION['stop'],row,''),(0,'durable',False))

    def test_cli_stop_offline_binding_does_not_require_window(self):
        with patch.object(control,'call',return_value=REPLY), \
                patch.object(cli,'hub_write',side_effect=AssertionError('no worker_stop')), \
                patch.object(cli.subprocess,'run',side_effect=AssertionError('no tmux')), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.stop_row(dict(name='task',key='@1',task='T42',execution_endpoint='ep')),0)

    def test_cli_local_marker_is_read_before_legacy_stop(self):
        answer = subprocess.CompletedProcess([],0,'@1|'+FID+'|T42|'+json.dumps(SNAP))
        with patch.dict(os.environ,{'FLEET_SESSION':'fixture'}), \
                patch.object(cli.subprocess,'run',return_value=answer), \
                patch.object(control,'call',return_value=REPLY), \
                patch.object(cli,'hub_write',side_effect=AssertionError('no worker_stop')), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.stop_row(dict(name='task',key='@1',fleet_id=FID)),0)

    def test_cli_local_identity_failure_refuses(self):
        answer = subprocess.CompletedProcess([],0,'@2|'+FID+'||')
        with patch.dict(os.environ,{'FLEET_SESSION':'fixture'}), patch.object(cli.subprocess,'run',return_value=answer), \
                patch.object(cli,'hub_write',side_effect=AssertionError('no worker_stop')), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cli.stop_row(dict(name='task',key='@1',fleet_id=FID)),1)

    def test_cli_pending_remains_cancellation(self):
        row=dict(name='task',task='T42',record_only=True,pending_start=True,pending_start_explicit=True)
        with patch.object(cli,'cancel_pending_start',return_value=(0,'cancelled')) as cancel, \
                patch.object(control,'stop_task',side_effect=AssertionError('not stop')), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.stop_row(row),0)
            cancel.assert_called_once_with('T42')

    def test_board_binding_enriches_cli_and_keeps_offline_row(self):
        board={'rows':[dict(id=FID,task='T42',execution_endpoint='ep',group='queue',tag='not_seen',lost=True)]}
        with patch.object(view,'board_read',return_value=board):
            rows=cli.pending_rows([])
            self.assertEqual(rows[0]['execution_endpoint'],'ep')
            self.assertEqual(rows[0]['task'],'T42')
            enriched=cli.pending_rows([dict(fleet_id=FID,key='@1')])
            self.assertEqual(len(enriched),1)
            self.assertEqual(enriched[0]['task'],'T42')

if __name__ == '__main__':
    unittest.main()
