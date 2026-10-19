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


OP = "0b9d7f3e-6a0e-4c8f-9a51-6f0c2b1d4e77"
SOURCE = ["preflight", "stop", "stopped", "reserve", "launch", "started"]
ALL = SOURCE + ["deliver", "bound", "consumed"]


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
    def started(self, plan, reservation):
        self.step("started")
        return {"native_identity": {"pid": 43, "native_session": "original"}, "anchor_turn_id": "t8"}
    def deliver(self, plan, record, commit=lambda: None):
        if self.fail == "deliver-rejected":
            self.calls.append("deliver")
            raise continuation.Rejected("precheck_active")
        record["delivery_attempt"] = {"operation": plan["message"]["operation"]}
        commit()
        return self.step("deliver")
    def bound(self, plan, record, seconds=30): return self.step("bound")
    def consumed(self, plan, record): return self.step("consumed")


class Journal(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "operation.json"
        self.plan = {"version": 1, "proof": {"native_session": "original"},
                     "message": {"operation": OP, "text": "继续"}}

    def test_product_entry_refuses_known_missing_capabilities_before_any_action(self):
        for args in (['--apply', str(self.path)], ['--preflight', '--pane', '%0', '--pid', '42', '--sid', 'original']):
            with patch.object(continuation.sys, 'argv', ['continue', *args]), \
                    patch.dict(os.environ, HOME=self.tmp.name, FLEET_CONF_DIR=self.tmp.name), \
                    patch.object(continuation, 'automatic_capability', return_value=dict(
                        state='unavailable', reason='x', missing_capabilities=['continuous-execution-gate'],
                        stop_submitted=False, new_admission_requested=False, message_consumption_verified=False)), \
                    patch.object(continuation, 'inspect') as inspect, \
                    patch.object(continuation, 'read') as read, \
                    patch.object(continuation, 'execute') as execute, \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(continuation.main(), 1)
            result = json.loads(output.getvalue())
            self.assertEqual(result['state'], 'unavailable')
            self.assertFalse(result['stop_submitted'])
            self.assertFalse(result['new_admission_requested'])
            inspect.assert_not_called(); read.assert_not_called(); execute.assert_not_called()
            self.assertFalse(self.path.exists())

    def test_success_and_lost_ack_never_repeat_effects(self):
        backend = Backend()
        first = continuation.execute(self.path, self.plan, backend)
        self.assertEqual(first["state"], "consumed")
        self.assertTrue(first["message_consumption_verified"])
        self.assertTrue(first["new_kernel_lifetime_verified"])
        calls = backend.calls[:]
        self.assertEqual(continuation.execute(self.path, self.plan, backend), first)
        self.assertEqual(continuation.deliver(self.path, first, backend), first)
        self.assertEqual(backend.calls, calls)
        self.assertEqual(calls, ALL)

    def test_failure_never_advances_or_retries_a_side_effect(self):
        expected = {'preflight': 'source-retained', 'stop': 'stop-unconfirmed',
                    'stopped': 'stop-unconfirmed', 'reserve': 'admission-unconfirmed',
                    'launch': 'launch-unconfirmed', 'started': 'target-unconfirmed'}
        for failing in SOURCE:
            with self.subTest(failing=failing):
                path = self.path.with_name(failing + ".json")
                backend = Backend(failing)
                result = continuation.execute(path, self.plan, backend)
                self.assertEqual(result["state"], expected[failing])
                self.assertFalse(result["new_kernel_lifetime_verified"])
                self.assertFalse(result["message_consumption_verified"])
                self.assertEqual(result["stage"], failing)
                self.assertEqual(backend.calls[-1], failing)
                calls = backend.calls[:]
                self.assertEqual(continuation.execute(path, self.plan, backend), result)
                self.assertEqual(continuation.deliver(path, result, backend), result)
                self.assertEqual(backend.calls, calls)
                self.assertNotIn("deliver", calls)
                if failing in ("preflight", "stop", "stopped"):
                    self.assertNotIn("launch", calls)
                    self.assertNotIn("reserve", calls)

    def test_message_is_the_resumed_lifetimes_first_turn_and_binds_it(self):
        # Codex 0.162.1 runs a resumed thread's SessionStart only when its first
        # turn starts: binding waits for the delivery, never the other way round.
        backend = Backend()
        continuation.execute(self.path, self.plan, backend)
        self.assertLess(backend.calls.index("started"), backend.calls.index("deliver"))
        self.assertLess(backend.calls.index("deliver"), backend.calls.index("bound"))
        record = continuation.execute(self.path.with_name("b.json"), self.plan, Backend("bound"))
        self.assertEqual(record["state"], "binding-unconfirmed")
        self.assertFalse(record["new_kernel_lifetime_verified"])
        again = Backend()
        record = continuation.deliver(self.path.with_name("b.json"), record, again)
        self.assertEqual(again.calls, ["bound", "consumed"])   # never delivered twice
        self.assertTrue(record["new_kernel_lifetime_verified"])

    def test_lost_delivery_ack_settles_by_the_same_operation_never_a_new_one(self):
        record = continuation.execute(self.path, self.plan, Backend("deliver"))
        self.assertEqual(record["state"], "delivery-unconfirmed")
        # The attempt was journaled before the native write it describes.
        self.assertEqual(continuation.read(self.path)["delivery_attempt"], {"operation": OP})
        self.assertFalse(record["message_consumption_verified"])
        seen = []
        class Settle(Backend):
            def deliver(self, plan, record, commit=lambda: None):
                seen.append((plan["message"]["operation"], record.get("delivery_attempt")))
                return self.step("deliver")
        backend = Settle()
        again = continuation.deliver(self.path, continuation.read(self.path), backend)
        self.assertEqual(again["state"], "consumed")
        self.assertEqual(seen, [(OP, {"operation": OP})])
        self.assertEqual(backend.calls, ["deliver", "bound", "consumed"])

    def test_rejected_delivery_is_still_owed_and_consumption_only_reverified(self):
        record = continuation.execute(self.path, self.plan, Backend("deliver-rejected"))
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

    def test_missing_or_malformed_original_message_refuses_before_any_effect(self):
        for bad in (None, {"operation": "not-a-uuid", "text": "x"}, {"operation": OP, "text": ""},
                    {"operation": OP, "text": "x", "extra": 1}):
            with self.subTest(bad=bad):
                backend = Backend()
                plan = dict(self.plan, message=bad)
                if bad is None:
                    del plan["message"]
                with self.assertRaises(ValueError):
                    continuation.execute(self.path, plan, backend)
                self.assertEqual(backend.calls, [])
                self.assertFalse(self.path.exists())

    def test_crashed_launch_intent_cannot_start_second_writer(self):
        record = {"version": 2, "plan": self.plan, "state": "launch-requested"}
        continuation.save(self.path, record)
        backend = Backend()
        self.assertEqual(continuation.execute(self.path, self.plan, backend), record)
        self.assertEqual(continuation.deliver(self.path, record, backend), record)
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
            def bound(self, plan, rec, seconds=30):
                if not (plan == record['plan'] and rec == record and seconds == 0):
                    raise AssertionError('wrong reconciliation scope')
                return {'native_identity': {'pid': 43}}
        result = continuation.reconcile(record, Reader())
        self.assertEqual(result['state'], 'bound')
        self.assertFalse(result['message_consumption_verified'])
        self.assertEqual(self.path.read_bytes(), before)
        unstarted = continuation.execute(self.path.with_name('u.json'), self.plan, Backend('launch'))
        self.assertEqual(continuation.reconcile(unstarted, Reader())['state'], 'launch-unconfirmed')

    def test_unproven_target_never_gets_the_message_or_relaunches(self):
        backend = Backend('started')
        result = continuation.execute(self.path, self.plan, backend)
        self.assertEqual(result['state'], 'target-unconfirmed')
        for key in ('stopped', 'reserve', 'launch'):
            self.assertIn(key, result)
        self.assertNotIn('started', result)
        self.assertNotIn('deliver', backend.calls)
        self.assertFalse(result['new_kernel_lifetime_verified'])
        count = len(backend.calls)
        continuation.execute(self.path, self.plan, backend)
        continuation.deliver(self.path, result, backend)
        self.assertEqual(len(backend.calls), count)


class Entry(unittest.TestCase):
    def test_preflight_carries_the_original_message_into_the_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            text = Path(tmp) / 'message.txt'
            text.write_text('继续做完这一步', encoding='utf-8')
            plan = {'proof': {'native_session': 'original'}}
            argv = ['continue', '--preflight', '--pane', '%3', '--pid', '42', '--sid', 'original',
                    '--message-file', str(text), '--operation', OP]
            with patch.object(continuation.sys, 'argv', argv), \
                    patch.object(continuation, 'inspect', return_value=dict(plan)) as inspect, \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(continuation.main(), 0)
            inspect.assert_called_once_with('%3', '', 42, 'original')
            self.assertEqual(json.loads(output.getvalue())['message'], {'operation': OP, 'text': '继续做完这一步'})
            with patch.object(continuation.sys, 'argv', argv[:-4]), patch.object(continuation, 'inspect') as inspect:
                with self.assertRaises(ValueError):
                    continuation.main()
                inspect.assert_not_called()


class Adopt(unittest.TestCase):
    """protected_execute re-enters a kept lock only for its own message stages."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "operation.json"
        self.plan = {"binding": {"@worktree": self.tmp.name}, "proof": {"native_session": "original"},
                     "message": {"operation": OP, "text": "继续"}}

    def test_only_a_resumable_message_stage_adopts_and_never_redoes_the_source(self):
        adopted, plain = [], []
        @contextlib.contextmanager
        def adopt(worktree, request):
            adopted.append(request)
            yield Path(self.tmp.name)
        @contextlib.contextmanager
        def lock(worktree):
            plain.append(worktree)
            yield Path(self.tmp.name)
        with patch.dict(continuation.TRANSFER, adopt_transition=adopt, transition_lock=lock):
            record = continuation.protected_execute(self.path, self.plan, Backend("deliver"))
            self.assertEqual(record["state"], "delivery-unconfirmed")
            backend = Backend()
            record = continuation.protected_execute(self.path, self.plan, backend)
        self.assertEqual(record["state"], "consumed")
        self.assertEqual(backend.calls, ["deliver", "bound", "consumed"])
        self.assertEqual(adopted, [dict(kind='native-continuation', journal=str(self.path), source=self.plan['proof'])])
        self.assertEqual(len(plain), 1)


class AdoptLock(unittest.TestCase):
    """The real .fleet-transfer.py lock: only the operation that kept it re-enters."""
    def test_adoption_needs_the_exact_request_and_no_live_other_owner(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, FLEET_CONF_DIR=tmp):
            transfer, work = continuation.TRANSFER, Path(tmp) / 'work'
            work.mkdir()
            request = dict(kind='native-continuation', journal='/j', source={'pid': 1})
            with transfer['transition_lock'](str(work)) as lock:
                (lock / 'request').write_text(json.dumps(request))
            self.assertTrue((lock / 'request').exists())      # kept: unknown completion
            with self.assertRaisesRegex(ValueError, 'another transition'):
                with transfer['transition_lock'](str(work)): pass
            for wrong in (dict(request, journal='/other'), dict(request, kind='transfer')):
                with self.assertRaisesRegex(ValueError, 'another transition'):
                    with transfer['adopt_transition'](str(work), wrong): pass
            child = subprocess.Popen(['sleep', '30'])
            self.addCleanup(child.kill)
            (lock / 'pid').write_text(str(child.pid))
            with self.assertRaisesRegex(ValueError, 'live owner'):
                with transfer['adopt_transition'](str(work), request): pass
            child.kill(); child.wait()
            with transfer['adopt_transition'](str(work), request) as adopted:
                self.assertEqual(adopted, lock)
                self.assertEqual((lock / 'pid').read_text(), str(os.getpid()))
                (lock / 'request').unlink()                     # the operation finished
            self.assertFalse(lock.exists())
            with transfer['transition_lock'](str(work)): pass  # free again


class OriginalMessage(unittest.TestCase):
    """Native.deliver/consumed against a stubbed native: identity fence, journal-first, re-read."""

    def setUp(self):
        self.plan = {"binding": {"pane": "%7", "socket": "/tmp/s", "@worktree": "/w"},
                     "proof": {"native_session": "sid", "pid": 41}, "routing": {"r": 1},
                     "workspace": {"files_sha256": "x"}, "message": {"operation": OP, "text": "继续"}}
        self.native = {"pid": 43, "birth": "b", "executable": "e"}
        self.record = {"started": {"native_identity": dict(self.native, native_session="sid", worker_id="w"),
                                   "remote": "unix:///r", "anchor_turn_id": "t8"}}
        self.calls, self.thread_status, self.added = [], "idle", []
        test = self
        class RPC:
            initialized = {"userAgent": "claude_fleet/0.162.1 (Mac OS)"}
            def __init__(self, *a, **k): test.rpc_kwargs = k
            def close(self): pass
            def call(self, method, params):
                test.calls.append(method)
                if method == "thread/read": return {"thread": {"status": {"type": test.thread_status}}}
                if method == "thread/queue/add":
                    test.added.append(params)
                    return {"queuedSubmission": {"id": "q1", "clientUserMessageId": params["clientUserMessageId"]}}
                raise AssertionError(method)
        rt = continuation.observe.runtime
        for context in (patch.object(rt, "RPC", RPC),
                        patch.object(continuation.authority, "prove_stopped", return_value={}),
                        patch.object(continuation.observe, "kernel", side_effect=lambda pid: dict(test.native)),
                        patch.object(continuation, "routing", return_value={"r": 1}),
                        patch.object(continuation, "workspace", return_value={"files_sha256": "x"})):
            context.start()
            self.addCleanup(context.stop)

    def settle(self, answer):
        return patch.object(continuation.observe.runtime, "codex_settle", return_value=answer)

    def test_another_lifetime_never_gets_the_message(self):
        self.native = {"pid": 43, "birth": "older", "executable": "e"}
        with self.settle(("accepted", "native_started", "t9", "t8")), self.assertRaises(ValueError):
            continuation.Native().deliver(self.plan, self.record)
        self.assertEqual(self.added, [])

    def test_attempt_is_journaled_before_the_add_and_answers_map(self):
        committed = []
        commit = lambda: committed.append((dict(self.record.get("delivery_attempt", {})), len(self.added)))
        with self.settle(("accepted", "native_started", "t9", "t8")) as settle:
            out = continuation.Native().deliver(self.plan, self.record, commit=commit)
        self.assertEqual(committed[0][1], 0)              # written before the native add
        self.assertEqual(committed[0][0]["operation"], OP)
        self.assertEqual(self.added[0]["clientUserMessageId"], OP)
        self.assertEqual(settle.call_args.args[1:5], ("sid", "q1", OP, "t8"))
        self.assertEqual((out["turn_id"], out["anchor_turn_id"]), ("t9", "t8"))
        self.assertEqual(self.rpc_kwargs["peer_pid"], 43)
        for answer, error in ((("rejected", "native_not_idle", None, None), continuation.Rejected),
                              (("unknown", "receipt_unconfirmed", None, None), ValueError)):
            self.record.pop("delivery_attempt", None)
            with self.subTest(answer=answer), self.settle(answer), self.assertRaises(ValueError) as caught:
                continuation.Native().deliver(self.plan, self.record)
            self.assertIs(type(caught.exception) is continuation.Rejected, error is continuation.Rejected)

    def test_busy_target_is_rejected_before_any_write(self):
        self.thread_status = "active"
        with self.assertRaises(continuation.Rejected):
            continuation.Native().deliver(self.plan, self.record)
        self.assertNotIn("delivery_attempt", self.record)
        self.assertEqual(self.added, [])

    def test_earlier_attempt_settles_by_receipt_never_resends(self):
        rt = continuation.observe.runtime
        self.record["delivery_attempt"] = {"operation": OP}
        cases = ((("q1", None), ("accepted", "native_idle_dispatch", "t9", "t8"), "settle"),
                 ((None, (True, "t9", "t8")), None, "receipt"),
                 ((None, (None, None, None)), None, "unknown"))
        for (queued, receipt), settled, kind in cases:
            with self.subTest(kind=kind), patch.object(rt, "codex_queued", return_value=queued), \
                    patch.object(rt, "codex_receipt", return_value=receipt), self.settle(settled):
                if kind == "unknown":
                    with self.assertRaises(ValueError):
                        continuation.Native().deliver(self.plan, self.record)
                else:
                    self.assertEqual(continuation.Native().deliver(self.plan, self.record)["turn_id"], "t9")
            self.assertEqual(self.added, [])
        # Provably absent and idle: the one owed delivery may be made, once.
        with patch.object(rt, "codex_queued", return_value=None), \
                patch.object(rt, "codex_receipt", return_value=(False, None, None)), \
                self.settle(("accepted", "native_started", "t9", "t8")):
            continuation.Native().deliver(self.plan, self.record)
        self.assertEqual(len(self.added), 1)

    def test_consumption_is_an_independent_reread_of_the_same_turn(self):
        rt = continuation.observe.runtime
        record = dict(self.record, deliver={"turn_id": "t9", "anchor_turn_id": "t8"})
        for found, ok in (((True, "t9", "t8"), True), ((True, "t10", "t9"), False),
                          ((None, None, None), False), ((False, None, None), False)):
            with self.subTest(found=found), patch.object(rt, "codex_receipt", return_value=found) as receipt:
                if ok:
                    out = continuation.Native().consumed(self.plan, record)
                    self.assertEqual(out["turn_id"], "t9")
                    self.assertEqual(self.rpc_kwargs["peer_pid"], 43)
                    self.assertEqual(receipt.call_args.args[1:], ("sid", OP, "t8"))
                else:
                    with self.assertRaises(ValueError):
                        continuation.Native().consumed(self.plan, record)


class Readiness(unittest.TestCase):
    """Unknown native metadata cannot authorize the first stop side effect."""
    def setUp(self):
        self.thread = dict(id='source', status=dict(type='idle', activeFlags=[]),
                           turns=[dict(id='turn', status='completed', itemsView='full', items=[])])
        self.goal = {'goal': None}
        self.pending = False
        self.closed = False
        self.calls = []
        self.queue = []
        self.mount = {'command': 'bash', 'args': ['-c', 'exec python3 x/fleet-mcp.py'], 'env_vars': ['TMUX']}
        self.configured = {}
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
                if method == 'thread/queue/list': return {'data': test.queue, 'nextCursor': None}
                if method == 'config/read': return {'config': {'mcp_servers': test.configured}}
                if method == 'mcpServerStatus/list': return {'data': [], 'nextCursor': None}
                raise AssertionError('unexpected native mutation: ' + method)

        for context in (patch.object(continuation.observe.runtime, 'RPC', RPC),
                        patch.object(continuation.observe, 'kernel', return_value={'pid': 42}),
                        patch.object(continuation.launch, 'option', return_value='isolated'),
                        patch.object(continuation, 'fleet_mounts', side_effect=lambda: {'fleet': dict(self.mount)}),
                        patch.dict(continuation.SLEEP, quiet_processes=lambda source, remounted=None: None)):
            context.start()
            self.addCleanup(context.stop)
        self.plan = dict(binding={'@worktree': '/fixture', 'pane': '%1', 'socket': '/fixture/tmux', 'window': '@1'}, proof=dict(pid=42, native_session='source'),
                         identity={'remote': 'unix:///fixture'}, processes={'native': {'pid': 42}})

    def test_completed_idle_is_observation_only(self):
        self.assertEqual(continuation.native_ready(self.plan),
                         {'mode': 'idle', 'turn_id': 'turn', 'mcp_config': {}, 'mcp_basis': {}, 'mcp_remounted': []})
        self.assertTrue(self.closed)

    def test_queued_input_refuses_before_any_stop(self):
        # It would start on the original lifetime, through hooks that no longer run.
        self.queue = [{'id': 'q1'}]
        with self.assertRaises(ValueError):
            continuation.native_ready(self.plan)
        self.assertTrue(self.closed)

    def test_only_the_current_launchers_exact_mount_is_remounted(self):
        seen = []
        def quiet(source, remounted=None):
            seen.append(remounted)
        exact = dict(self.mount, enabled=True, environment_id='local', tool_timeout_sec=600.0)
        for configured, expected in (({'fleet': exact}, ['fleet']),
                                     ({'fleet': dict(exact, args=['-c', 'exec python3 other.py'])}, []),
                                     ({'fleet': dict(exact, env={'BASH_ENV': '/x'})}, []),
                                     ({'fleet': dict(exact, enabled=False)}, []),
                                     ({'context7': dict(exact)}, [])):
            with self.subTest(configured=configured):
                self.configured = configured
                with patch.dict(continuation.SLEEP, quiet_processes=quiet):
                    result = continuation.native_ready(self.plan)
                self.assertEqual(seen[-1], expected)
                self.assertEqual(result['mcp_remounted'], expected)

    def test_mcp_uses_source_repo_contract_and_keeps_basis(self):
        def quiet(source, remounted=None):
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
        with patch.object(continuation, 'inspect') as inspect, \
                patch.object(continuation, 'automatic_capability', return_value=dict(state='unavailable')):
            with self.assertRaisesRegex(ValueError, 'automatic continuation unavailable'):
                continuation.Native().stop({})
            inspect.assert_not_called()

    def test_available_only_with_its_evidence_and_no_override(self):
        cap = continuation.automatic_capability()
        self.assertEqual((cap['state'], cap['missing_capabilities']), ('available', []))
        self.assertTrue((continuation.BIN.parent / cap['evidence']).is_file())
        with patch.dict(os.environ, FLEET_NATIVE_CONTINUE='0'):
            self.assertEqual(continuation.automatic_capability(), cap)


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
