#!/bin/bash
# Exact Codex identity/telemetry and queue routing; private tmux, fixture rollouts,
# fake codex only. No model requests, operator files or live fleet sockets.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 - "$BIN" <<'PY'
import importlib.util, json, os, pathlib, shutil, subprocess, sys, tempfile, time, unittest
from unittest import mock

BIN = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('codex_session', BIN / 'fleet-codex-session.py')
cx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cx)
sys.path.insert(0, str(BIN))
import fleet_codex_fake_appserver as fake_server   # T540: a real RPC peer, no Codex
SID = '11111111-1111-4111-8111-111111111111'
OTHER = '22222222-2222-4222-8222-222222222222'

class SessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fleet-codex-session-')
        self.root = pathlib.Path(self.tmp.name)
        self.home = self.root / 'a home'
        self.path = self.home / 'sessions/2026/09/17' / ('rollout-' + SID + '.jsonl')
        self.path.parent.mkdir(parents=True)
        self.data = dict(session_id=SID, home=str(self.home), owner='1234', model='fixture-model')
        self.records = [dict(type='session_meta', payload=dict(id=SID, cwd=str(self.root))),
                        dict(type='turn_context', payload=dict(model='gpt-fixture')),
                        dict(type='event_msg', payload=dict(type='token_count', info=dict(
                            model_context_window=300000,
                            last_token_usage=dict(input_tokens=100000, cached_input_tokens=90000, output_tokens=20000, total_tokens=120000),
                            total_token_usage=dict(output_tokens=40000))))]
        self.write()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self):
        self.path.write_text(''.join(json.dumps(r) + '\n' for r in self.records))

    def test_exact_id_and_cache_tokens(self):
        wrong = self.path.with_name('rollout-' + OTHER + '.jsonl')
        wrong.write_text(json.dumps(dict(type='session_meta', payload=dict(id=OTHER))) + '\n')
        got = cx.telemetry(self.data)
        self.assertEqual((got['pct'], got['live_tokens'], got['limit']), (40, 120000, 300000))
        self.assertEqual(got['model'], 'gpt-fixture')
        self.assertEqual(got['output_tokens'], 40000)
        self.assertEqual(got['transcript'], str(self.path))

    def test_native_usage_drives_existing_bus_and_suppresses_rollout_polling(self):
        data = dict(self.data, remote='unix:///fixture')
        meter = cx.Meter(dict(TMUX_PANE='%fixture', FLEET_CODEX_LAUNCHER_PID='1234'))
        usage = dict(last=dict(totalTokens=120000, inputTokens=100000, cachedInputTokens=90000, outputTokens=20000),
                     total=dict(totalTokens=9999999), modelContextWindow=300000)
        settings = dict(model='native-model', effort='high')
        with mock.patch.object(cx, 'identity', return_value=data), mock.patch.object(cx, 'feed') as feed, \
                mock.patch.object(cx.time, 'monotonic', return_value=100), mock.patch.object(cx, 'rollout') as rollout:
            self.assertTrue(meter.observe(data, usage, settings))
            stats = feed.call_args.args[2]
            self.assertEqual((stats['pct'], stats['live_tokens'], stats['limit'], stats['model']),
                             (40, 120000, 300000, 'native-model'))
            self.assertEqual(feed.call_args.kwargs['expected'], data)
            self.assertEqual(feed.call_args.args[3], '')
            self.assertFalse(meter.tick(101))
            rollout.assert_not_called()
            self.assertTrue(meter.observe(data, usage, settings))
            self.assertEqual(feed.call_count, 1)
            self.assertTrue(meter.observe(data, None, dict(model='changed-model', effort=None)))
            self.assertEqual(feed.call_args.args[2]['effort'], '')
            self.assertEqual(feed.call_count, 2)
            meter.reset_native()
            self.assertEqual(meter.native_until, 0)
            self.assertIsNone(meter.native_stats)

    def test_native_unknown_usage_never_becomes_zero_or_extends_a_lease(self):
        data = dict(self.data, remote='unix:///fixture')
        meter = cx.Meter(dict(TMUX_PANE='%fixture', FLEET_CODEX_LAUNCHER_PID='1234'))
        settings = dict(model='native', effort='low')
        with mock.patch.object(cx, 'identity', return_value=data), mock.patch.object(cx, 'feed') as feed:
            for usage in (dict(last={}, modelContextWindow=300000), dict(last=dict(totalTokens=True), modelContextWindow=300000),
                          dict(last=dict(totalTokens=123), modelContextWindow=0), dict(last=dict(totalTokens=-1), modelContextWindow=300000)):
                self.assertFalse(meter.observe(data, usage, settings))
                meter.keep_native(data)
                self.assertEqual(meter.native_until, 0)
            feed.assert_not_called()
            self.assertTrue(meter.observe(data, dict(last=dict(inputTokens=100, outputTokens=20), modelContextWindow=300), settings))
            self.assertEqual(feed.call_args.args[2]['pct'], 40)

    def test_native_binding_rejects_changed_account_root_owner_or_endpoint(self):
        data = dict(self.data, remote='unix:///fixture')
        meter = cx.Meter(dict(TMUX_PANE='%fixture', FLEET_CODEX_LAUNCHER_PID='1234'))
        usage = dict(last=dict(totalTokens=10), modelContextWindow=100)
        with mock.patch.object(cx, 'feed') as feed:
            for key, value in (('owner', '999'), ('session_id', OTHER), ('home', '/different'), ('remote', 'unix:///different')):
                with mock.patch.object(cx, 'identity', return_value=dict(data, **{key: value})):
                    self.assertFalse(meter.observe(data, usage, dict(model='fixture', effort=None)))
                    self.assertEqual(meter.native_until, 0)
            feed.assert_not_called()

    def test_expired_native_lease_restores_existing_rollout_reader(self):
        data = dict(self.data, remote='unix:///fixture')
        meter = cx.Meter(dict(TMUX_PANE='%fixture', FLEET_CODEX_LAUNCHER_PID='1234'))
        with mock.patch.object(cx, 'identity', return_value=data), mock.patch.object(cx, 'feed') as feed, \
                mock.patch.object(cx.time, 'monotonic', return_value=100):
            meter.observe(data, dict(last=dict(totalTokens=1), modelContextWindow=100), dict(model='native', effort='low'))
            self.assertTrue(meter.tick(106))
            self.assertEqual(feed.call_args.args[2]['source'], 'codex-rollout')
            self.assertEqual(feed.call_args.args[2]['model'], 'gpt-fixture')
            self.assertIsNone(meter.native_stats)
            meter.observe(data, dict(last=dict(totalTokens=1), modelContextWindow=100), dict(model='native', effort='low'))
            self.assertEqual(feed.call_args.args[2]['source'], 'codex-native')
            self.assertEqual(feed.call_count, 3)

    @unittest.skipUnless(shutil.which('tmux'), 'tmux unavailable')
    def test_native_measurement_bus_rechecks_root_in_the_write_queue(self):
        label = 'native-meter-test-' + str(os.getpid())
        prefix = ['tmux', '-L', label]
        def call(*arguments):
            return subprocess.check_output(prefix + list(arguments), text=True).strip()
        try:
            call('new-session', '-d', '-s', 'fixture', 'sleep 60')
            pane = call('display-message', '-p', '#{pane_id}')
            data = dict(self.data, remote='unix:///fixture')
            for key, value in (('@cc_agent', 'codex'), ('@cc_launcher_pid', '1234'),
                               ('@codex_session_id', SID), ('@codex_identity', json.dumps(data))):
                call('set-option', '-w', '-t', pane, key, value)
            environment = dict(TMUX=call('display-message', '-p', '#{socket_path}') + ',1,0', TMUX_PANE=pane)
            stats = dict(session_id=SID, model="native ' quoted 模型", effort='high', pct=40, live_tokens=120, limit=300)
            with mock.patch.dict(os.environ, environment):
                cx.feed(pane, '1234', stats, '', expected=data)
                self.assertEqual(call('display-message', '-p', '#{@model}'), stats['model'])
                self.assertEqual(call('display-message', '-p', '#{@ctx_pct}'), '40')
                call('set-option', '-w', '-t', pane, '@codex_session_id', OTHER)
                cx.feed(pane, '1234', dict(stats, pct=90, live_tokens=270), '', expected=data)
                self.assertEqual(call('display-message', '-p', '#{@ctx_pct}'), '40')
        finally:
            subprocess.run(prefix + ['kill-server'], capture_output=True)

    def test_percent_only_avoids_policy_and_armed_reads(self):
        import contextlib, io, types
        from unittest.mock import patch
        args = types.SimpleNamespace(pane='%1', socket='', session='', pct=True, json=False, quiet=False)
        for expected in (40, 95, -1):
            output = io.StringIO()
            with patch.object(cx, 'identity', return_value=self.data), \
                 patch.object(cx, 'telemetry', return_value={'pct': expected}), \
                 patch.object(cx, 'tmux', side_effect=AssertionError('unexpected policy read')), \
                 patch.object(cx.subprocess, 'run', side_effect=AssertionError('unexpected subprocess')), \
                 contextlib.redirect_stdout(output):
                self.assertEqual(cx.context(args), 0 if expected >= 0 else 1)
            self.assertEqual(output.getvalue(), str(expected) + '\n')

    def test_percent_cli_keeps_exact_native_telemetry(self):
        result = subprocess.run([sys.executable, str(BIN / 'fleet-codex-session.py'), 'context',
                                 '--session', SID, '--home', str(self.home), '--pane', '', '--pct'],
                                capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout), (0, '40\n'))

    def test_context_defaults_to_native_compaction_preserving_explicit_policy(self):
        import contextlib, io, types
        from unittest.mock import patch
        args = types.SimpleNamespace(pane='%1', socket='', session='', pct=False, json=True, quiet=False)
        for configured, expected in (('', 0), ('0', 0), ('80', 80), ('60', 60), ('invalid', 0)):
            with self.subTest(configured=configured):
                output = io.StringIO()
                with patch.dict(os.environ, {'TMUX': '/fixture,1,0'}), \
                     patch.object(cx, 'identity', return_value=self.data), \
                     patch.object(cx, 'tmux', return_value=''), \
                     patch.object(cx.subprocess, 'run', return_value=types.SimpleNamespace(returncode=0, stdout=configured)), \
                     contextlib.redirect_stdout(output):
                    cx.context(args)
                result = json.loads(output.getvalue())
                self.assertEqual(result['auto_handoff_pct'], expected)
                self.assertEqual(result['handoff_pct'], expected or 80)

    def test_context_text_distinguishes_manual_transfer_from_automatic_policy(self):
        result = subprocess.run([sys.executable, str(BIN / 'fleet-codex-session.py'), 'context',
                                 '--session', SID, '--home', str(self.home), '--pane', ''],
                                capture_output=True, text=True)
        self.assertIn('auto-handoff OFF', result.stdout)
        self.assertIn('native Agent manages compaction', result.stdout)
        self.assertIn('manual    fleet-transfer.sh', result.stdout)

    def test_context_token_opt_in_matches_stop_policy(self):
        import contextlib, io, types
        from unittest.mock import patch
        args = types.SimpleNamespace(pane='%1', socket='', session='', pct=False, json=True, quiet=False)
        for configured, limit, expected in (('\n150001', '300000', 51), ('80\n150000', '300000', 50),
                                             ('\n900000', '300000', 100), ('\n150000', '', 0),
                                             ('60\n150000', 'bad', 60), ('bad\n150000', '300000', 50)):
            with self.subTest(configured=configured, limit=limit):
                output = io.StringIO()
                with patch.dict(os.environ, {'TMUX': '/fixture,1,0'}), \
                     patch.object(cx, 'identity', return_value=self.data), \
                     patch.object(cx, 'tmux', side_effect=lambda argv, socket: limit if argv[-1] == '#{@ctx_limit}' else ''), \
                     patch.object(cx.subprocess, 'run', return_value=types.SimpleNamespace(returncode=0, stdout=configured)), \
                     contextlib.redirect_stdout(output):
                    cx.context(args)
                self.assertEqual(json.loads(output.getvalue())['auto_handoff_pct'], expected)

    def test_effort_turn_context_then_config(self):
        # issue #2431: the turn's effort, else collaboration_mode, else config.toml
        self.assertEqual(cx.telemetry(self.data)['effort'], '')
        (self.home / 'config.toml').write_text('model = "x"\nmodel_reasoning_effort = "medium"  # c\n[profiles.p]\nmodel_reasoning_effort = "low"\n')
        stats = cx.telemetry(self.data)
        self.assertEqual(cx.bus_fields(stats, str(self.home)),
                         ['pct=40.00', 'limit=300000', 'model=gpt-fixture', 'effort=medium'])
        self.records.insert(2, dict(type='turn_context', payload=dict(model='gpt-fixture', collaboration_mode=dict(
            mode='default', settings=dict(model='gpt-fixture', reasoning_effort='xhigh')))))
        self.write()
        self.assertEqual(cx.telemetry(self.data)['effort'], 'xhigh')
        self.records.insert(3, dict(type='turn_context', payload=dict(model='gpt-fixture', effort='high')))
        self.write()
        self.assertEqual(cx.bus_fields(cx.telemetry(self.data), str(self.home))[-1], 'effort=high')
        # a [table]'s key is not the top level's; no file → no effort
        (self.home / 'config.toml').write_text('[profiles.p]\nmodel_reasoning_effort = "low"\n')
        self.assertEqual(cx.config_effort(str(self.home)), '')
        self.assertEqual(cx.config_effort(str(self.root / 'nowhere')), '')
        # an unknown % feeds the model only, never a context stamp
        self.data['home'] = str(self.root / 'another-account')
        self.assertEqual(cx.bus_fields(cx.telemetry(self.data), ''), ['model=fixture-model'])

    def test_real_0162_rollout_shape(self):
        # issue #3157: codex-cli 0.162.1's records, copied from a real rollout
        # (base_instructions / git / rate limits trimmed) — the release pin's shape.
        self.records = [
            dict(type='session_meta', payload=dict(session_id=SID, id=SID, cwd=str(self.root), originator='codex_exec',
                 cli_version='0.162.1', model_provider='fleet', context_window=258400, history_mode='full')),
            dict(type='event_msg', payload=dict(type='task_started')),
            dict(type='turn_context', payload=dict(model='gpt-6.1-sol', effort='high', cwd=str(self.root), summary='none',
                 collaboration_mode=dict(mode='default', settings=dict(model='gpt-6.1-sol', reasoning_effort='high',
                                                                      developer_instructions=None)))),
            dict(type='token_usage_record', payload=dict()),
            dict(type='event_msg', payload=dict(type='token_count', info=dict(
                total_token_usage=dict(input_tokens=12646, cached_input_tokens=0, cache_write_input_tokens=0,
                                       output_tokens=5, reasoning_output_tokens=0, total_tokens=12651),
                last_token_usage=dict(input_tokens=12646, cached_input_tokens=0, cache_write_input_tokens=0,
                                      output_tokens=5, reasoning_output_tokens=0, total_tokens=12651),
                model_context_window=258400))),
            dict(type='event_msg', payload=dict(type='task_complete'))]
        self.write()
        got = cx.telemetry(self.data)
        self.assertEqual((got['pct'], got['live_tokens'], got['limit']), (4, 12651, 258400))
        self.assertEqual((got['model'], got['effort'], got['output_tokens']), ('gpt-6.1-sol', 'high', 5))

    def test_wrong_hint_does_not_override_identity(self):
        wrong = self.root / 'wrong.jsonl'
        wrong.write_text(json.dumps(dict(type='session_meta', payload=dict(id=OTHER))) + '\n')
        self.data['transcript'] = str(wrong)
        self.assertEqual(cx.telemetry(self.data)['transcript'], str(self.path))
        self.data['session_id'] = OTHER
        self.data['transcript'] = str(self.path)
        self.assertEqual(cx.telemetry(self.data)['pct'], -1)

    def test_missing_and_malformed_are_unknown(self):
        self.data['home'] = str(self.root / 'another-account')
        self.assertEqual(cx.telemetry(self.data)['pct'], -1)
        self.data['session_id'] = '../*'
        self.assertEqual(cx.telemetry(self.data)['pct'], -1)
        self.assertEqual(cx.telemetry({})['pct'], -1)
        self.records[-1]['payload']['info']['model_context_window'] = None
        self.write()
        self.assertEqual(cx.telemetry(dict(session_id=SID, home=str(self.home)))['pct'], -1)

    def test_compaction_and_torn_append(self):
        newer = json.loads(json.dumps(self.records[-1]))
        newer['payload']['info']['last_token_usage']['total_tokens'] = 15000
        self.records.append(newer)
        self.write()
        with self.path.open('a') as f: f.write('{"type":')
        self.assertEqual(cx.telemetry(self.data)['pct'], 5)

    def test_context_cli_provider_never_reads_claude(self):
        env = dict(os.environ, CODEX_HOME=str(self.home))
        env.pop('TMUX', None); env.pop('TMUX_PANE', None)
        p = subprocess.run(['bash', str(BIN / 'fleet-context.sh'), '--agent', 'codex', '--session', SID, '--json'], env=env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)['pct'], 40)
        p = subprocess.run(['bash', str(BIN / 'fleet-context.sh'), '--agent', 'codex', '--session', OTHER, '--json'], env=env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 1, p.stderr)
        self.assertEqual(json.loads(p.stdout)['verdict'], 'UNKNOWN')

    def test_agent_switch_clears_every_bus_stamp(self):
        # issue #3461: a Claude → Codex transfer (fleet-transfer.sh) and a Codex
        # launch (fleet-codex.sh) unset the WHOLE measurement bus — @ctx_left /
        # @ctx_ts / @ctx_src too, or the top line reads the old agent's numbers.
        bus = ['@ctx_pct', '@ctx_limit', '@ctx_band', '@ctx_left', '@ctx_ts', '@ctx_src', '@model', '@effort']
        for script, marker in (('fleet-transfer.sh', 'for key in @cc_account'), ('fleet-codex.sh', 'for _opt in @codex_identity')):
            line = next(l.strip() for l in (BIN / script).read_text().splitlines() if l.strip().startswith(marker))
            for name in bus:
                self.assertIn(' ' + name + ' ', line, script + ' must unset ' + name)

    @unittest.skipUnless(shutil.which('tmux'), 'tmux unavailable')
    def test_meter_feeds_the_bus_mid_turn(self):
        # issue #3461: the hook feeds the bus only at SessionStart (no token count
        # yet) and Stop; the launcher's Meter re-reads a CHANGED rollout every few
        # seconds, so a long turn's context moves like a Claude window's.
        label = 'codex-meter-test-' + str(os.getpid())
        tm = ['tmux', '-L', label]
        def call(*args):
            return subprocess.check_output(tm + list(args), text=True).strip()
        saved = {k: os.environ.get(k) for k in ('TMUX', 'TMUX_PANE')}
        try:
            call('new-session', '-d', '-s', 'fixture', '-n', 'w', 'sleep 60')
            pane = call('display-message', '-p', '#{pane_id}')
            os.environ['TMUX'] = call('display-message', '-p', '#{socket_path}') + ',1,0'
            os.environ.pop('TMUX_PANE', None)
            ident = dict(self.data, transcript=str(self.path))
            for name, value in (('@cc_agent', 'codex'), ('@cc_launcher_pid', '1234'),
                                ('@codex_identity', json.dumps(ident)), ('@model', 'Opus 5.5'), ('@ctx_left', '90')):
                call('set-option', '-w', '-t', pane, name, value)
            opt = lambda n: call('display-message', '-p', '-t', pane, '#{' + n + '}')
            meter = cx.Meter(dict(TMUX_PANE=pane, FLEET_CODEX_LAUNCHER_PID='1234', FLEET_CODEX_METER_SECS='5'))
            self.assertTrue(meter.tick(100))
            self.assertEqual([opt(n) for n in ('@ctx_pct', '@ctx_left', '@ctx_band', '@ctx_src', '@model')],
                             ['40', '60', 'ok', 'codex', 'gpt-fixture'])
            self.assertRegex(opt('@ctx_ts'), r'^[0-9]{10}$')
            self.assertFalse(meter.tick(101), 'paced: no read inside the period')
            self.assertFalse(meter.tick(106), 'an unchanged rollout is not re-read')
            newer = json.loads(json.dumps(self.records[-1]))
            newer['payload']['info']['last_token_usage']['total_tokens'] = 150000
            self.records.append(newer); self.write()
            self.assertTrue(meter.tick(112))
            self.assertEqual((opt('@ctx_pct'), opt('@ctx_left')), ('50', '50'))
            # a replacement launch owns the window: never stamped by the old meter
            call('set-option', '-w', '-t', pane, '@cc_launcher_pid', '5678')
            newer = json.loads(json.dumps(newer)); newer['payload']['info']['last_token_usage']['total_tokens'] = 240000
            self.records.append(newer); self.write()
            self.assertFalse(meter.tick(118))
            self.assertEqual(opt('@ctx_pct'), '50')
            self.assertFalse(cx.Meter({}).tick(0), 'no pane, no owner: nothing')
        finally:
            for k, v in saved.items():
                if v is None: os.environ.pop(k, None)
                else: os.environ[k] = v
            subprocess.run(tm + ['kill-server'], capture_output=True)

    @unittest.skipUnless(shutil.which('tmux'), 'tmux unavailable')
    def test_hooks_cache_queue_and_parent_end_to_end(self):
        label = 'codex-session-test-' + str(os.getpid())
        tm = ['tmux', '-L', label]
        def call(*args):
            return subprocess.check_output(tm + list(args), text=True).strip()
        # the window's private server: delivery asks it which thread is current (T540)
        sockdir = tempfile.mkdtemp(prefix='cxs-', dir='/tmp')
        server = fake_server.FakeAppServer(sockdir + '/worker.sock')
        server.add(fake_server.tui_thread(SID))
        try:
            call('new-session', '-d', '-s', 'fixture', '-n', 'parent', 'sleep 60')
            pane = call('display-message', '-p', '#{pane_id}')
            win = call('display-message', '-p', '#{window_id}')
            socket = call('display-message', '-p', '#{socket_path}')
            env = dict(os.environ, TMUX=socket + ',1,0', TMUX_PANE=pane, CODEX_HOME=str(self.home),
                       FLEET_CODEX_LAUNCHER_PID='1234', FLEET_CODEX_REMOTE=server.remote)
            for name, value in (('@cc_agent', 'codex'), ('@cc_launcher_pid', '1234'), ('@issue', '42')):
                call('set-option', '-w', '-t', pane, name, value)
            def hook(sid=SID, owner='1234', event='SessionStart'):
                p = subprocess.run([sys.executable, str(BIN / 'fleet-codex-session.py'), 'hook'],
                    env=dict(env, FLEET_CODEX_LAUNCHER_PID=owner), input=json.dumps(dict(session_id=sid,
                    hook_event_name=event, transcript_path=str(self.path), cwd=str(self.root))), text=True, capture_output=True)
                self.assertEqual(p.returncode, 0, p.stderr)
            hook()
            data = json.loads(call('show-options', '-wv', '-t', pane, '@codex_identity'))
            self.assertEqual(data['session_id'], SID)
            self.assertEqual(data['home'], str(self.home.resolve()))
            self.assertEqual(call('show-options', '-wv', '-t', pane, '@ctx_pct'), '40')
            # issue #2431: over the bus — the same stamps a Claude window gets
            opt = lambda n: call('display-message', '-p', '-t', pane, '#{' + n + '}')
            self.assertEqual([opt(n) for n in ('@ctx_limit', '@ctx_band', '@ctx_left', '@ctx_src', '@model')],
                             ['300000', 'ok', '60', 'codex', 'gpt-fixture'])
            self.assertRegex(opt('@ctx_ts'), r'^[0-9]{10}$')
            self.assertEqual(opt('@cc_model'), '', 'the hook no longer writes @cc_model')
            hook(OTHER, owner='999')
            hook(OTHER, event='Stop')
            self.assertEqual(json.loads(call('show-options', '-wv', '-t', pane, '@codex_identity'))['session_id'], SID)
            cache = self.root / '.claude-dash/global'; cache.mkdir(parents=True)
            row = '|'.join(['fixture', win, 'codex', '1234', json.dumps(data)]) + '\n'
            p = subprocess.run([sys.executable, str(BIN / 'fleet-codex-session.py'), 'collect', '--cache', str(cache)], input=row, text=True)
            self.assertEqual(p.returncode, 0)
            self.assertEqual(next(cache.glob('ctx_*')).read_text().strip(), 'gpt-fixture\t120000\t300000')
            # The real row producer must use Codex's 300k denominator, and stop
            # reading this cache the instant the pane switches root sessions.
            rows_env = dict(env, TMPDIR=str(self.root), FLEET_SESSION='fixture')
            def rows():
                return subprocess.check_output(['bash', str(BIN / 'tmux-dashboard-rows.sh')], env=rows_env, text=True)
            self.assertIn('40%', rows())
            call('set-option', '-w', '-t', pane, '@codex_session_id', OTHER)
            self.assertNotIn('40%', rows())
            call('set-option', '-w', '-t', pane, '@codex_session_id', SID)
            fakebin = self.root / 'bin'; fakebin.mkdir()
            fake = fakebin / 'codex'
            fake.write_text('#!' + sys.executable + '\nimport sys,os,json\njson.dump([sys.argv[1:],os.environ["CODEX_HOME"]],open(os.environ["QUEUE_LOG"],"w"))\nsys.exit(int(os.environ.get("QUEUE_FAIL","0")))\n')
            fake.chmod(0o755)
            env.update(PATH=str(fakebin) + ':' + os.environ['PATH'], QUEUE_LOG=str(self.root / 'queue.json'))
            def send():
                return subprocess.run(['bash', str(BIN / 'fleet-peer-send.sh'), '-L', label, pane, 'hello\npeer'], env=env, capture_output=True, text=True)
            p = send(); self.assertEqual(p.returncode, 0, p.stderr)
            argv, home = json.loads((self.root / 'queue.json').read_text())
            self.assertEqual(argv, ['queue', '--remote', server.remote, '--thread', SID, '--message', 'hello\npeer'])
            self.assertEqual(home, str(self.home.resolve()))
            child = call('new-window', '-d', '-P', '-F', '#{window_id}', '-n', 'child', 'sleep 60')
            call('set-option', '-w', '-t', child, '@origin', 'issue-42')
            p = subprocess.run(['bash', str(BIN / 'fleet-report-parent.sh'), '-L', label, '--win', child, '--state', 'merged', '--key', 'issue-43', '--summary', 'done'], env=env, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(call('show-options', '-wv', '-t', child, '@reported'), '1')
            self.assertIn('[child-report]', json.loads((self.root / 'queue.json').read_text())[0][-1])
            env['QUEUE_FAIL'] = '1'
            self.assertNotEqual(send().returncode, 0)
            env.pop('QUEUE_FAIL')
            data['remote'] = ''
            call('set-option', '-w', '-t', pane, '@codex_identity', json.dumps(data))
            self.assertNotEqual(send().returncode, 0, 'embedded server must not report a false delivery')
            call('set-option', '-w', '-t', pane, '@cc_launcher_pid', '5678')
            self.assertNotEqual(send().returncode, 0, 'stale identity must not deliver')
        finally:
            subprocess.run(tm + ['kill-server'], capture_output=True)
            server.close()
            shutil.rmtree(sockdir, ignore_errors=True)

    @unittest.skipUnless(shutil.which('tmux'), 'tmux unavailable')
    def test_clear_holds_then_follows_into_the_new_thread(self):
        # T540: Codex 0.162 runs SessionStart only at a thread's first turn and keeps
        # the old thread LOADED after /clear, so a queue into it is accepted and never
        # shown. Before the follow: held (queued for the window's identity, exit 3,
        # no `codex queue`, no DELIVERED). thread/started: the window names the new
        # thread at once, the ledger gets its segment, and the held item drains INTO it.
        label = 'cxclear' + str(os.getpid())
        tm = ['tmux', '-L', label]
        def call(*args):
            return subprocess.check_output(tm + list(args), text=True).strip()
        sockdir = tempfile.mkdtemp(prefix='cxc-', dir='/tmp')
        server = fake_server.FakeAppServer(sockdir + '/worker.sock')
        now = int(time.time() * 1000)
        old_t, new_t = fake_server.uuid7(now - 60000), fake_server.uuid7(now)
        server.add(fake_server.tui_thread(old_t))
        conf = self.root / 'conf'; ids = self.root / 'ids'
        saved = {k: os.environ.get(k) for k in ('TMUX', 'TMUX_PANE', 'FLEET_CODEX_LAUNCHER_PID', 'FLEET_ID_DIR', 'FLEET_ID_PUSH', 'FLEET_CONF_DIR')}
        try:
            call('new-session', '-d', '-s', label, '-n', 'parent', 'sleep 60')
            pane = call('display-message', '-p', '#{pane_id}')
            socket = call('display-message', '-p', '#{socket_path}')
            ident = dict(session_id=old_t, owner='1234', home=str(self.home), remote=server.remote)
            for name, value in (('@cc_agent', 'codex'), ('@cc_launcher_pid', '1234'), ('@issue', '42'),
                                ('@codex_identity', json.dumps(ident)), ('@codex_session_id', old_t)):
                call('set-option', '-w', '-t', pane, name, value)
            fakebin = self.root / 'bin'; fakebin.mkdir()
            (fakebin / 'codex').write_text('#!' + sys.executable + '\nimport sys,os,json\nopen(os.environ["QUEUE_LOG"],"a").write(json.dumps(sys.argv[1:])+"\\n")\n')
            (fakebin / 'codex').chmod(0o755)
            qlog = self.root / 'queue.ndjson'
            env = dict(os.environ, TMUX=socket + ',1,0', TMUX_PANE=pane, PATH=str(fakebin) + ':' + os.environ['PATH'],
                       QUEUE_LOG=str(qlog), FLEET_CONF_DIR=str(conf), FLEET_ID_DIR=str(ids), FLEET_ID_PUSH='0')
            env.pop('FLEET_CODEX_LAUNCHER_PID', None)
            def peer(text):
                return subprocess.run(['bash', str(BIN / 'fleet-peer-send.sh'), '-L', label, pane, text],
                                      env=env, capture_output=True, text=True)
            queued = lambda: [json.loads(l) for l in qlog.read_text().splitlines()] if qlog.exists() else []
            book = conf / 'fleets' / label / 'delivery.ndjson'
            rows = lambda: [json.loads(l) for l in book.read_text().splitlines()] if book.exists() else []
            p = peer('before clear'); self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(queued()[-1][4], old_t)
            os.environ.update(TMUX=socket + ',1,0', TMUX_PANE=pane, FLEET_CODEX_LAUNCHER_PID='1234',
                              FLEET_ID_DIR=str(ids), FLEET_ID_PUSH='0', FLEET_CONF_DIR=str(conf))
            follower = cx.Follow(dict(TMUX_PANE=pane, FLEET_CODEX_LAUNCHER_PID='1234', FLEET_CODEX_REMOTE=server.remote))
            self.assertEqual(follower.tick(), '')   # connected, nothing started yet
            # /clear: the TUI's new thread is loaded beside the old one, not yet followed
            server.add(fake_server.tui_thread(new_t))
            p = peer('child report while cleared')
            self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
            self.assertIn('queued', p.stdout)
            self.assertIn(new_t, p.stdout, 'the hold names the thread the window moved to')
            self.assertEqual(len(queued()), 1, 'nothing was queued into the old thread')
            self.assertFalse([r for r in rows() if r.get('state') == 'DELIVERED'], 'held is never DELIVERED')
            self.assertEqual([r.get('state') for r in rows()], ['QUEUED'])
            child = call('new-window', '-d', '-P', '-F', '#{window_id}', '-n', 'child', 'sleep 60')
            call('set-option', '-w', '-t', child, '@origin', 'issue-42')
            p = subprocess.run(['bash', str(BIN / 'fleet-report-parent.sh'), '-L', label, '--win', child,
                                '--state', 'merged', '--key', 'issue-43', '--summary', 'done'], env=env, capture_output=True, text=True)
            self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
            self.assertIn('new Codex thread', p.stdout)
            self.assertEqual(len(queued()), 1, "the child's report did not go into the old thread")
            # the server's broadcast: the window follows at once, not at the first turn
            server.broadcast({'method': 'thread/started', 'params': {'thread': server.threads[new_t]}})
            moved = ''
            for _ in range(30):
                moved = follower.tick()
                if moved: break
                time.sleep(0.1)
            self.assertEqual(moved, new_t)
            self.assertEqual(call('show-options', '-wv', '-t', pane, '@codex_session_id'), new_t)
            self.assertEqual(json.loads(call('show-options', '-wv', '-t', pane, '@codex_identity'))['session_id'], new_t)
            fid = call('show-options', '-wv', '-t', pane, '@fleet_id')
            segs = [json.loads(l) for l in (ids / (fid + '.ndjson')).read_text().splitlines()]
            self.assertEqual([(e['native'], e['trigger']) for e in segs if e.get('ev') == 'native'][-1], (new_t, 'clear'))
            # the held items replay INTO the new thread, and only then read DELIVERED
            p = subprocess.run(['bash', str(BIN / 'fleet-peer-queue.sh'), 'drain', '-L', label], env=env, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual([q[4] for q in queued()[1:]], [new_t, new_t])
            self.assertTrue(any('child report while cleared' in q[-1] for q in queued()[1:]))
            self.assertEqual(sorted(r['state'] for r in rows() if r.get('state') != 'QUEUED'), ['DELIVERED', 'DELIVERED'])
            p = peer('after follow'); self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(queued()[-1][4], new_t)
            # an older thread starting again is not a /clear: never followed backwards
            self.assertEqual(cx.follow(pane, '1234', server.threads[old_t]), '')
            # a subagent's thread is not the TUI's
            self.assertEqual(cx.follow(pane, '1234', fake_server.tui_thread(fake_server.uuid7(now + 1000), parentThreadId=new_t)), '')
            # under an authority receipt the follower stays off; delivery holds instead
            self.assertTrue(cx.Follow(dict(TMUX_PANE=pane, FLEET_CODEX_LAUNCHER_PID='1234', FLEET_CODEX_REMOTE=server.remote,
                                           FLEET_AUTHORITY_CONTEXT='{}')).off)
            follower.close()
        finally:
            for k, v in saved.items():
                if v is None: os.environ.pop(k, None)
                else: os.environ[k] = v
            subprocess.run(tm + ['kill-server'], capture_output=True)
            server.close()
            shutil.rmtree(sockdir, ignore_errors=True)

unittest.main(argv=['codex-session'], verbosity=2)
PY
