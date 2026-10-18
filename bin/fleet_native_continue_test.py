#!/usr/bin/env python3
"""Failure-injection tests for the one-shot native continuation journal."""
import copy
import contextlib
import io
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
import unittest
import unittest.mock
from unittest.mock import patch

import fleet_native_continue as continuation


class Backend:
    def __init__(self, fail=""):
        self.fail, self.calls = fail, []

    def step(self, name):
        self.calls.append(name)
        if self.fail == name:
            raise ValueError("injected " + name)
        return {"verified": name}

    def preflight(self, plan): return self.step("preflight")
    def stop(self, plan): return self.step("stop")
    def stopped(self, plan): return self.step("stopped")
    def reserve(self, plan, reservation): return self.step("reserve")
    def launch(self, plan, reservation): return self.step("launch")
    def bound(self, plan, reservation): return self.step("bound")
    def deliver(self, plan, record):
        if self.fail == "deliver-rejected":
            self.calls.append("deliver")
            raise continuation.Rejected("precheck_active")
        return self.step("deliver")
    def consumed(self, plan, record): return self.step("consumed")


class Journal(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "operation.json"
        self.plan = {"version": 1, "proof": {"native_session": "original"}}

    def test_product_entry_refuses_known_missing_capabilities_before_any_action(self):
        for args in (['--apply', str(self.path)], ['--preflight', '--pane', '%0', '--pid', '42', '--sid', 'original']):
            with patch.object(continuation.sys, 'argv', ['continue', *args]), \
                    patch.dict(os.environ, HOME=self.tmp.name, FLEET_CONF_DIR=self.tmp.name), \
                    patch.object(continuation, 'inspect') as inspect, \
                    patch.object(continuation, 'read') as read, \
                    patch.object(continuation, 'execute') as execute, \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(continuation.main(), 1)
            result = json.loads(output.getvalue())
            self.assertEqual(result['state'], 'unavailable')
            self.assertFalse(result['stop_submitted'])
            self.assertFalse(result['new_admission_requested'])
            self.assertIn('continuous-execution-gate', result['missing_capabilities'])
            self.assertIn('missing-config-mcp-stop', result['missing_capabilities'])
            # Wired after binding, but real Codex evidence is still owed (#4775).
            self.assertIn('original-message-operation', result['pending_native_evidence'])
            inspect.assert_not_called(); read.assert_not_called(); execute.assert_not_called()
            self.assertFalse(self.path.exists())

    def test_success_and_lost_ack_never_repeat_effects(self):
        backend = Backend()
        first = continuation.execute(self.path, self.plan, backend)
        self.assertEqual(first["state"], "bound")
        self.assertFalse(first["message_consumption_verified"])
        self.assertTrue(first["new_kernel_lifetime_verified"])
        calls = backend.calls[:]
        self.assertEqual(continuation.execute(self.path, self.plan, backend), first)
        self.assertEqual(backend.calls, calls)
        self.assertEqual(calls, ["preflight", "stop", "stopped", "reserve", "launch", "bound"])

    def test_failure_never_advances_or_retries_a_side_effect(self):
        for failing in ("preflight", "stop", "stopped", "reserve", "launch", "bound"):
            with self.subTest(failing=failing):
                path = self.path.with_name(failing + ".json")
                backend = Backend(failing)
                result = continuation.execute(path, self.plan, backend)
                expected = {'preflight': 'source-retained', 'stop': 'stop-unconfirmed',
                            'stopped': 'stop-unconfirmed', 'reserve': 'admission-unconfirmed',
                            'launch': 'launch-unconfirmed', 'bound': 'target-unconfirmed'}
                self.assertEqual(result["state"], expected[failing])
                self.assertFalse(result["new_kernel_lifetime_verified"])
                self.assertFalse(result["message_consumption_verified"])
                self.assertEqual(result["stage"], failing)
                self.assertEqual(backend.calls[-1], failing)
                calls = backend.calls[:]
                self.assertEqual(continuation.execute(path, self.plan, backend), result)
                self.assertEqual(backend.calls, calls)
                if failing in ("preflight", "stop", "stopped"):
                    self.assertNotIn("launch", calls)
                    self.assertNotIn("reserve", calls)

    def message_plan(self):
        return dict(self.plan, message={"operation": "0b9d7f3e-6a0e-4c8f-9a51-6f0c2b1d4e77", "text": "继续"})

    def test_original_message_goes_after_binding_and_is_verified_once(self):
        plan, backend = self.message_plan(), Backend()
        first = continuation.execute(self.path, plan, backend)
        self.assertEqual(first["state"], "consumed")
        self.assertTrue(first["message_consumption_verified"])
        self.assertEqual(backend.calls, ["preflight", "stop", "stopped", "reserve", "launch", "bound",
                                         "deliver", "consumed"])
        calls = backend.calls[:]
        self.assertEqual(continuation.execute(self.path, plan, backend), first)
        self.assertEqual(continuation.deliver(self.path, first, backend), first)
        self.assertEqual(backend.calls, calls)

    def test_message_never_reaches_an_unbound_or_unconfirmed_target(self):
        for failing in ("stop", "stopped", "reserve", "launch", "bound"):
            with self.subTest(failing=failing):
                backend = Backend(failing)
                record = continuation.execute(self.path.with_name(failing + ".json"), self.message_plan(), backend)
                self.assertNotIn("deliver", backend.calls)
                self.assertFalse(record["message_consumption_verified"])
                self.assertEqual(continuation.deliver(self.path.with_name(failing + ".json"), record, backend), record)
                self.assertNotIn("deliver", backend.calls)

    def test_lost_delivery_ack_settles_by_the_same_operation_never_a_new_one(self):
        plan = self.message_plan()
        record = continuation.execute(self.path, plan, Backend("deliver"))
        self.assertEqual(record["state"], "delivery-unconfirmed")
        self.assertFalse(record["message_consumption_verified"])
        seen = []
        class Settle(Backend):
            def deliver(self, plan, record):
                seen.append(plan["message"]["operation"])
                return self.step("deliver")
        backend = Settle()
        again = continuation.deliver(self.path, continuation.read(self.path), backend)
        self.assertEqual(again["state"], "consumed")
        self.assertEqual(seen, [plan["message"]["operation"]])
        self.assertEqual(backend.calls, ["deliver", "consumed"])

    def test_rejected_delivery_is_still_owed_and_consumption_only_reverified(self):
        plan = self.message_plan()
        record = continuation.execute(self.path, plan, Backend("deliver-rejected"))
        self.assertEqual(record["state"], "delivery-rejected")
        self.assertFalse(record["message_consumption_verified"])
        record = continuation.deliver(self.path, record, Backend("consumed"))
        self.assertEqual(record["state"], "consumption-unconfirmed")
        backend = Backend()
        record = continuation.deliver(self.path, record, backend)
        self.assertEqual(backend.calls, ["consumed"])
        self.assertTrue(record["message_consumption_verified"])
        result = continuation.reconcile(record, None)
        self.assertEqual(result["state"], "consumed")
        self.assertTrue(result["message_consumption_verified"])

    def test_malformed_original_message_refuses_before_any_effect(self):
        for bad in ({"operation": "not-a-uuid", "text": "x"}, {"operation": "0b9d7f3e-6a0e-4c8f-9a51-6f0c2b1d4e77", "text": ""},
                    {"operation": "0b9d7f3e-6a0e-4c8f-9a51-6f0c2b1d4e77", "text": "x", "extra": 1}):
            with self.subTest(bad=bad):
                backend = Backend()
                with self.assertRaises(ValueError):
                    continuation.execute(self.path, dict(self.plan, message=bad), backend)
                self.assertEqual(backend.calls, [])
                self.assertFalse(self.path.exists())

    def test_crashed_launch_intent_cannot_start_second_writer(self):
        record = {"version": 1, "plan": self.plan, "state": "launch-requested"}
        continuation.save(self.path, record)
        backend = Backend()
        self.assertEqual(continuation.execute(self.path, self.plan, backend), record)
        self.assertEqual(backend.calls, [])

    def test_same_operation_cannot_change_source(self):
        continuation.execute(self.path, self.plan, Backend())
        changed = copy.deepcopy(self.plan)
        changed["proof"]["native_session"] = "replacement"
        with self.assertRaises(ValueError):
            continuation.execute(self.path, changed, Backend())

    def test_reconcile_only_reads_and_does_not_rewrite_or_repeat_effects(self):
        record = continuation.execute(self.path, self.plan, Backend('bound'))
        before = self.path.read_bytes()
        class Reader:
            def bound(self, plan, reservation, seconds=30):
                self_checked = (plan == record['plan'] and reservation == record['reservation'] and seconds == 0)
                if not self_checked:
                    raise AssertionError('wrong reconciliation scope')
                return {'native_identity': {'pid': 42}}
        result = continuation.reconcile(record, Reader())
        self.assertEqual(result['state'], 'bound')
        self.assertFalse(result['message_consumption_verified'])
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(continuation.execute(self.path, self.plan, Backend()), record)

    def test_trust_attention_never_claims_native_binding_or_relaunches(self):
        backend = Backend('bound')
        result = continuation.execute(self.path, self.plan, backend)
        self.assertEqual(result['state'], 'target-unconfirmed')
        self.assertIn('stopped', result)
        self.assertIn('reserve', result)
        self.assertIn('launch', result)
        self.assertNotIn('bound', result)
        self.assertFalse(result['new_kernel_lifetime_verified'])
        count = len(backend.calls)
        continuation.execute(self.path, self.plan, backend)
        self.assertEqual(len(backend.calls), count)


class OriginalMessage(unittest.TestCase):
    """Native.deliver/consumed against a stubbed runtime: identity fence, answers, re-read."""
    OP = "0b9d7f3e-6a0e-4c8f-9a51-6f0c2b1d4e77"

    def setUp(self):
        self.plan = {"binding": {"pane": "%7", "socket": "/tmp/s", "@worktree": "/w"},
                     "proof": {"native_session": "sid", "pid": 41}, "routing": {"r": 1},
                     "workspace": {"files_sha256": "x"}, "message": {"operation": self.OP, "text": "继续"}}
        self.record = {"bound": {"native_identity": {"pid": 42, "birth": "b", "executable": "e"}}}
        self.ident = {"native_session": "sid", "pid": 42, "birth": "b", "executable": "e", "native_remote": "r"}
        rt = continuation.observe.runtime
        for target, value in ((continuation, "routing"), (continuation, "workspace")):
            patcher = patch.object(target, value, return_value=self.plan[value])
            patcher.start(); self.addCleanup(patcher.stop)
        self.read = patch.object(rt, "read", side_effect=lambda *a, **k: {"version": 1, "identity": dict(self.ident)})
        self.read.start(); self.addCleanup(self.read.stop)

    def accept(self, answer):
        return patch.object(continuation.observe.runtime, "accept_if_idle", return_value=answer)

    def test_original_lifetime_or_another_sid_never_gets_the_message(self):
        for change in ({"pid": 41}, {"native_session": "other"}, {"birth": "older"}):
            with self.subTest(change=change):
                self.ident.update(change)
                with self.accept({}) as accept, self.assertRaises(ValueError):
                    continuation.Native().deliver(self.plan, self.record)
                accept.assert_not_called()
                self.ident.update(native_session="sid", pid=42, birth="b")

    def test_rejected_is_owed_unknown_is_never_consumed(self):
        with self.accept({"state": "rejected", "reason": "precheck_active"}), self.assertRaises(continuation.Rejected):
            continuation.Native().deliver(self.plan, self.record)
        for answer in ({"state": "unknown", "reason": "receipt_unconfirmed"},
                       {"state": "accepted", "delivery_id": self.OP, "receipt": {"delivery_id": "other", "native_session": "sid", "turn_id": "t"}},
                       {"state": "accepted", "delivery_id": self.OP, "receipt": {"delivery_id": self.OP, "native_session": "sid"}}):
            with self.subTest(answer=answer), self.accept(answer), self.assertRaises(ValueError) as caught:
                continuation.Native().deliver(self.plan, self.record)
            self.assertNotIsInstance(caught.exception, continuation.Rejected)
        receipt = {"delivery_id": self.OP, "native_session": "sid", "turn_id": "t9", "anchor_turn_id": "t8"}
        with self.accept({"state": "accepted", "delivery_id": self.OP, "receipt": receipt}) as accept:
            out = continuation.Native().deliver(self.plan, self.record)
        self.assertEqual(accept.call_args.args[2:4], (self.OP, "继续"))
        self.assertEqual(out["receipt"]["turn_id"], "t9")

    def test_consumption_is_an_independent_reread_of_the_same_turn(self):
        rt = continuation.observe.runtime
        record = dict(self.record, deliver={"receipt": {"turn_id": "t9", "anchor_turn_id": "t8"}})
        client = unittest.mock.MagicMock()
        for found, ok in (((True, "t9", "t8"), True), ((True, "t10", "t9"), False),
                          ((None, None, None), False), ((False, None, None), False)):
            with self.subTest(found=found), \
                    patch.dict(rt.CODEX, identity=lambda *a: {"session_id": "sid", "remote": "r"}), \
                    patch.object(rt, "RPC", return_value=client) as rpc, \
                    patch.object(rt, "codex_receipt", return_value=found) as receipt:
                if ok:
                    out = continuation.Native().consumed(self.plan, record)
                    self.assertEqual(out["turn_id"], "t9")
                    self.assertEqual(rpc.call_args.kwargs["peer_pid"], 42)
                    self.assertEqual(receipt.call_args.args[1:], ("sid", self.OP, "t8"))
                else:
                    with self.assertRaises(ValueError):
                        continuation.Native().consumed(self.plan, record)
                client.close.assert_called()


class Readiness(unittest.TestCase):
    """Unknown native metadata cannot authorize the first stop side effect."""
    def setUp(self):
        self.thread = dict(id='source', status=dict(type='idle', activeFlags=[]),
                           turns=[dict(id='turn', status='completed', itemsView='full', items=[])])
        self.goal = {'goal': None}
        self.pending = False
        self.closed = False
        self.calls = []
        test = self

        class RPC:
            def __init__(self, *args, **kwargs): self.events = []
            def close(self): test.closed = True
            def call(self, method, params):
                test.calls.append(method)
                if method == 'thread/resume': return {'thread': {'id': 'source'}}
                if method == 'thread/read':
                    if test.pending:
                        self.events.append({'id': 9, 'method': 'item/commandExecution/requestApproval'})
                    return {'thread': test.thread}
                if method == 'thread/goal/get': return test.goal
                if method == 'thread/loaded/list': return {'data': ['source']}
                raise AssertionError('unexpected native mutation: ' + method)

        for context in (patch.object(continuation.observe.runtime, 'RPC', RPC),
                        patch.object(continuation.observe, 'kernel', return_value={'pid': 42}),
                        patch.object(continuation.launch, 'option', return_value='isolated'),
                        patch.dict(continuation.SLEEP, quiet_processes=lambda source: None)):
            context.start()
            self.addCleanup(context.stop)
        self.plan = dict(binding={'@worktree': '/fixture', 'pane': '%1', 'socket': '/fixture/tmux', 'window': '@1'}, proof=dict(pid=42, native_session='source'),
                         identity={'remote': 'unix:///fixture'}, processes={'native': {'pid': 42}})

    def test_completed_idle_is_observation_only(self):
        self.assertEqual(continuation.native_ready(self.plan),
                         {'mode': 'idle', 'turn_id': 'turn', 'mcp_config': {}, 'mcp_basis': {}})
        self.assertTrue(self.closed)

    def test_mcp_uses_source_repo_contract_and_keeps_basis(self):
        def quiet(source):
            self.assertEqual((source['session'], source['worktree']), ('isolated', '/fixture'))
            self.assertNotIn('window', source)
            source['sleep_mcp'] = {'fleet': 'effective-config-digest'}
            source['sleep_mcp_basis'] = {'fleet': 'shell-exec'}
        with patch.dict(continuation.SLEEP, quiet_processes=quiet):
            result = continuation.native_ready(self.plan)
        self.assertEqual(result['mcp_basis'], {'fleet': 'shell-exec'})
        self.assertEqual(result['mcp_config'], {'fleet': 'effective-config-digest'})

    def test_pending_request_arriving_after_rejoin_refuses(self):
        self.pending = True
        with self.assertRaises(ValueError):
            continuation.native_ready(self.plan)
        self.assertTrue(self.closed)

    def test_unknown_goal_response_refuses(self):
        self.goal = {}
        with self.assertRaises(ValueError):
            continuation.native_ready(self.plan)

    def test_missing_items_are_unknown(self):
        del self.thread['turns'][0]['items']
        with self.assertRaises(ValueError):
            continuation.native_ready(self.plan)

    def test_active_unknown_attention_and_unfinished_tool_refuse(self):
        for change in ('active', 'unknown', 'attention', 'tool'):
            with self.subTest(change=change):
                original = copy.deepcopy(self.thread)
                if change in ('active', 'unknown'):
                    self.thread['status']['type'] = change
                elif change == 'attention':
                    self.thread['status']['activeFlags'] = ['waitingOnApproval']
                else:
                    self.thread['turns'][0]['items'] = [dict(type='commandExecution', status='inProgress')]
                with self.assertRaises(ValueError):
                    continuation.native_ready(self.plan)
                self.thread = original


class Workspace(unittest.TestCase):
    def test_staged_bytes_cannot_change_under_same_status_and_working_bytes(self):
        with tempfile.TemporaryDirectory(prefix='continue-index-') as temporary:
            root = Path(temporary).resolve()
            base, work = root / 'base', root / 'work'
            env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
            def git(*args):
                return subprocess.check_output(['git', '-c', 'user.name=Fixture', '-c',
                    'user.email=fixture@example.invalid', *map(str, args)], env=env,
                    stderr=subprocess.PIPE)
            git('init', '-q', base)
            (base / 'business.txt').write_text('committed\n')
            git('-C', base, 'add', 'business.txt')
            git('-C', base, 'commit', '-qm', 'fixture')
            git('-C', base, 'worktree', 'add', '-qb', 'fixture', work)
            def snapshot(staged):
                (work / 'business.txt').write_text(staged)
                git('-C', work, 'add', 'business.txt')
                (work / 'business.txt').write_text('same uncommitted business edits\n')
                return continuation.workspace(str(work))
            first, second = snapshot('staged one\n'), snapshot('staged two\n')
            self.assertEqual(first['files_sha256'], second['files_sha256'])
            self.assertEqual(first['status_sha256'], second['status_sha256'])
            self.assertNotEqual(first, second)


class Capability(unittest.TestCase):
    def test_unready_diagnostic_is_still_unavailable_and_native_backend_cannot_bypass_product_gate(self):
        # The automatic entry now refuses even before this read-only diagnostic.
        result = continuation.unavailable(ValueError('MCP service fleet is not ready or has unknown runtime status'))
        self.assertEqual(result, dict(state='unavailable', reason='mcp-not-ready',
            stop_submitted=False, new_admission_requested=False, message_consumption_verified=False))
        with patch.object(continuation, 'inspect') as inspect:
            with self.assertRaisesRegex(ValueError, 'automatic continuation unavailable'):
                continuation.Native().stop({})
            inspect.assert_not_called()


class AuthorityAck(unittest.TestCase):
    def test_returned_authority_failure_stops_this_session_start_turn(self):
        code = continuation.observe.runtime.CODEX
        payload = dict(hook_event_name='SessionStart', session_id='11111111-1111-4111-8111-111111111111')
        output = io.StringIO()
        with patch.dict(os.environ, FLEET_AUTHORITY_CONTEXT='{}'), \
                patch('sys.stdin', io.StringIO(json.dumps(payload))), \
                patch.object(continuation.authority, 'observe_native', side_effect=ValueError('private error')), \
                contextlib.redirect_stdout(output):
            code['hook']()
        self.assertFalse(json.loads(output.getvalue())['continue'])
        self.assertNotIn('private error', output.getvalue())

    def test_ack_requires_all_independently_expected_scope_fields(self):
        a = continuation.authority
        expected = dict(repo='fixture/repo', reservation='new-reservation', worker_id='fleet/fid',
                        owner='owner', endpoint_id='node')
        proof = dict(worker_id='fleet/fid', native_session='sid', pid=42, birth='birth', executable='/bin/codex')
        good = dict(expected, phase='observed', native_identity=proof)
        for field in (*a.START_KEYS, 'phase', 'native_identity'):
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    a.check_start_ack(expected, dict(good, **{field:'wrong'}), 'observed', proof)
        for field in ('owner', 'endpoint_id'):
            incomplete = dict(expected); del incomplete[field]
            with self.assertRaises(ValueError):
                a.check_start_ack(incomplete, good, 'observed', proof)


@unittest.skipUnless(shutil.which('tmux'), 'tmux required')
class SocketIdentity(unittest.TestCase):
    def test_successor_identity_reads_the_explicit_absolute_socket(self):
        with tempfile.TemporaryDirectory(prefix='continue-socket-', dir='/tmp') as tmp:
            socket = str(Path(tmp).resolve() / 'tmux')
            def tm(*args):
                return subprocess.check_output(['tmux', '-S', socket, *args], text=True).strip()
            try:
                pane = tm('-f', '/dev/null', 'new-session', '-d', '-P', '-F', '#{pane_id}', 'sleep 60')
                data = dict(owner='123', session_id='11111111-1111-4111-8111-111111111111', home='/fixture')
                for key, value in {'@cc_agent':'codex', '@cc_launcher_pid':'123',
                                   '@codex_identity':json.dumps(data)}.items():
                    tm('set-option', '-w', '-t', pane, key, value)
                self.assertEqual(continuation.observe.runtime.CODEX['identity'](pane, socket), data)
            finally:
                subprocess.run(['tmux', '-S', socket, 'kill-server'], capture_output=True)


if __name__ == "__main__":
    unittest.main()
