#!/usr/bin/env python3
"""Behavioral fixtures for the shared account selector and ccquota adapters."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('accounts', Path(__file__).with_name('.fleet-account.py'))
accounts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(accounts)


def candidate(agent, name, used=10, **extra):
    return dict(agent=agent, key=agent + '/' + name, account=name, score=(100-used)*2,
                utilization=used, available=True, login='valid', **extra)


class Providers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.patch = patch.dict(os.environ, FLEET_C=str(self.root), FLEET_ACCOUNT_CEILING='85',
                                FLEET_ACCOUNT_PICK='5h', FLEET_ACCOUNT_PICK_HYST='10')
        self.patch.start()
        self.profile = dict(agent='codex', account='codex:account:fixture', home=str(self.root),
                            profile='work', login='valid')

    def tearDown(self):
        self.patch.stop()
        self.tmp.cleanup()

    def test_same_agent_before_larger_other_pool_in_both_directions(self):
        for agent, other in (('claude','codex'), ('codex','claude')):
            rows = [candidate(other,'other',0), candidate(agent,'source',99), candidate(agent,'next',80)]
            r = accounts.choose({'accounts':rows}, agent, [agent+'/source'])
            self.assertEqual(r['target']['account'], 'next')
            rows.pop()
            self.assertEqual(accounts.choose({'accounts':rows}, agent)['reason'], 'cross-agent')

    def test_no_unreadable_stale_benched_or_auth_target(self):
        rows = [candidate('codex','full',100), candidate('claude','stale')]
        rows[1]['available'] = False
        rows.append(candidate('codex','bench',limited_until=time.time()+60))
        rows.append(candidate('codex','expired')); rows[-1]['login']='reauth_required'
        r = accounts.choose({'accounts':rows}, 'claude')
        self.assertEqual(r['state'], 'waiting-quota')

    def test_a_bad_login_is_excluded_by_name_never_chosen(self):
        # issue #1670: four candidates, one reauth_required with the most room —
        # never the target, always listed as excluded with `auth:<state>`.
        rows = [candidate('claude', n, u) for n, u in (('a', 50), ('b', 0), ('c', 40), ('d', 60))]
        rows[1]['login'] = 'reauth_required'
        r = accounts.choose({'accounts': rows}, 'claude')
        self.assertEqual(r['target']['account'], 'c')
        self.assertEqual([(e['key'], e['reason']) for e in r['excluded']], [('claude/b', 'auth:reauth_required')])
        for row in rows:
            row['login'] = 'expired'
        r = accounts.choose({'accounts': rows}, 'claude')
        self.assertEqual((r['state'], r['target']), ('waiting-quota', None))
        self.assertEqual(len(r['excluded']), 4)
        self.assertIn('login needed', r['reason'])

    def test_hub_managed_profile_is_valid_and_only_the_hub_lease_counts(self):
        # issue #1666: a hub-leased home is a valid login — ccquota reports
        # where it is refreshed, and the adapter carries that through.
        row = dict(name='default', home=str(self.root), default=True, managed=True,
                   account='codex:account:hub', email='x@example.test', plan='pro',
                   login=dict(state='valid', source='hub', auto_refresh=False, has_refresh_token=False))
        with patch.object(accounts, 'ccquota', return_value=[row]):
            p = accounts.profile('default')
            self.assertEqual((p['login'], p['source']), ('valid', 'hub'))
            reading = dict(available=True, windows=[dict(id='codex:primary', minutes=300, utilization=5)])
            self.assertTrue(accounts.eligible(accounts.normalize_codex(p, reading)))
            # A lease the node agent did not renew: not usable, and the cause
            # names the hub lease, never a re-login.
            row['login'] = dict(state='access_expired', source='hub')
            with self.assertRaisesRegex(ValueError, 'hub-managed.*node agent'):
                accounts.profile('default')
            r = accounts.normalize_codex(accounts.profiles()[0], reading)
            self.assertEqual(r['reason'], 'hub-lease-lapsed')
            self.assertFalse(accounts.eligible(r))
            # claude-fleet#1920: a lease the upstream refused before its exp is
            # not usable either, and the cause says the hub must re-issue it.
            row['login'] = dict(state='access_rejected', source='hub', upstream_error='token_revoked',
                                reason='Upstream refused this hub lease (token_revoked, …)')
            with self.assertRaisesRegex(ValueError, 'hub-managed.*refused its lease.*token_revoked.*hub must issue'):
                accounts.profile('default')
            self.assertFalse(accounts.eligible(accounts.normalize_codex(accounts.profiles()[0], reading)))
            # Degenerate case: an older ccquota prints no source → local, and
            # the gate is what it always was.
            row['login'] = dict(state='valid')
            self.assertEqual(accounts.profiles()[0]['source'], 'local')
            row['login'] = dict(state='reauth_required')
            with self.assertRaisesRegex(ValueError, 'verified subscription login'):
                accounts.profile('default')
            self.assertEqual(accounts.normalize_codex(accounts.profiles()[0], reading)['reason'], 'auth-unavailable')

    def test_window_ids_are_not_durations(self):
        reading = dict(available=True, windows=[dict(id='codex:primary', minutes=10080, utilization=95)])
        r = accounts.normalize_codex(self.profile, reading)
        self.assertEqual(r['utilization'],95)
        self.assertFalse(accounts.eligible(r))

    def test_invalid_secondary_never_disappears_into_headroom(self):
        reading = dict(available=True, windows=[dict(id='a',minutes=300,utilization=5),
                                               dict(id='b',minutes=10080,utilization=None)])
        self.assertFalse(accounts.normalize_codex(self.profile,reading)['available'])

    def test_blocked_credits_and_reset_windows(self):
        self.assertFalse(accounts.normalize_codex(self.profile,dict(available=True,credits={'unlimited':True}))['available'])
        r=accounts.normalize_codex(self.profile,dict(available=True,blocked=True))
        self.assertEqual(r['utilization'],100)
        reading=dict(available=True,windows=[dict(id='old',minutes=300,utilization=100,resets_at=1)])
        self.assertFalse(accounts.normalize_codex(self.profile,reading)['available'])
        reading['windows']=[dict(id='a',minutes=300,utilization=90,resets_at=2000),
                            dict(id='b',minutes=10080,utilization=95,resets_at=3000)]
        self.assertEqual(accounts.normalize_codex(self.profile,reading,now=1000)['reset_at'],3000)

    def test_missing_duration_retains_known_percentage_without_five_hour_guess(self):
        reading=dict(available=True,windows=[dict(id='codex:primary',utilization=58),
                                            dict(id='special:primary',minutes=300,utilization=100)])
        row=accounts.normalize_codex(self.profile,reading,scope='codex')
        self.assertTrue(row['available']); self.assertEqual(row['utilization'],58)
        self.assertIsNone(row['windows'][0]['minutes'])
        self.assertEqual(row['score'],84)
        self.assertEqual(accounts.normalize_codex(self.profile,reading,scope='special')['utilization'],100)

    def test_profiles_share_account_exclusion_and_bench(self):
        a=candidate('codex','seat',home='/one',profile='one')
        b=dict(a,home='/two',profile='two')
        self.assertIsNone(accounts.choose({'accounts':[a,b]},'codex',['codex/seat'])['target'])
        accounts.bench('codex/seat',int(time.time())+60,'quota')
        benches=accounts.read(accounts.state_dir()/'account.codex-limited.json')
        self.assertIn('codex/seat',benches)

    def test_phase_and_hysteresis_keep_existing_preference(self):
        a=candidate('claude','a',20,hold_until=time.time()+100)
        b=candidate('claude','b',25)
        self.assertEqual(accounts.choose({'accounts':[a,b]},'claude')['target']['account'],'b')
        b['hold_until']=time.time()+100
        self.assertEqual(accounts.choose({'accounts':[a,b]},'claude',current='claude/b')['target']['account'],'b')

    def test_pace_ranks_the_week_and_holds_far_ahead(self):
        # issue #1231: the shortest window is the expiring one, the longest the week;
        # pace = week% − 85 × elapsed; a lead of 10 points outweighs a whole 5h window.
        # setUp pins the class to the #598 `5h` score; this test is the `pace` default.
        self.patch.stop(); self.patch = patch.dict(os.environ, FLEET_C=str(self.root), FLEET_ACCOUNT_CEILING='85',
                                                   FLEET_ACCOUNT_PICK='pace', FLEET_ACCOUNT_PICK_HYST='10')
        self.patch.start()
        now = 1_000_000
        ahead = dict(available=True, windows=[dict(id='codex:primary', minutes=300, utilization=0, resets_at=now + 3600),
                                              dict(id='codex:week', minutes=10080, utilization=65, resets_at=now + 6 * 86400)])
        behind = dict(available=True, windows=[dict(id='codex:primary', minutes=300, utilization=60, resets_at=now + 3600),
                                               dict(id='codex:week', minutes=10080, utilization=10, resets_at=now + 86400)])
        a = accounts.normalize_codex(dict(self.profile, account='a'), ahead, now=now)
        b = accounts.normalize_codex(dict(self.profile, account='b'), behind, now=now)
        self.assertEqual((a['pace'], a['pace_held']), (53, True))
        self.assertEqual((b['pace'], b['pace_held']), (-63, False))
        self.assertEqual(a['score'], 200 + (100 - 53) * 20)
        self.assertEqual(b['score'], 80 + (100 + 63) * 20)
        # the held account loses even with a fresh 5h window; alone, it is still picked (fail-open)
        self.assertEqual(accounts.choose({'accounts': [a, b]}, 'codex')['target']['account'], 'b')
        self.assertEqual(accounts.choose({'accounts': [a]}, 'codex')['target']['account'], 'a')
        # rollback: FLEET_ACCOUNT_PICK=5h is the #598 score, no pace, no hold
        with patch.dict(os.environ, FLEET_ACCOUNT_PICK='5h'):
            a5 = accounts.normalize_codex(dict(self.profile, account='a'), ahead, now=now)
        self.assertEqual((a5['score'], a5['pace'], a5['pace_held']), (200 + 35, 0, False))

    def test_a_paused_pool_account_is_never_chosen(self):
        # issue #2083: the hub's pool.paused.<account> (FLEET_ACCOUNT_PAUSED, or
        # global/account.paused as the quota tick fetched it) takes a `hub:` label
        # out of choose(); a local label of the same name is never paused; with
        # nothing paused the inventory is what it was.
        acct = self.root/'accounts'; acct.mkdir()
        (acct/'local').write_text('tok-secret\n')
        for name in ('h1', 'h2'):
            (acct/name).write_text('hub:%s\n' % name); (acct/(name+'.hub')).mkdir()
            (acct/(name+'.hub')/'.credentials.json').write_text(json.dumps(
                {'claudeAiOauth': {'accessToken': 'x', 'expiresAt': (time.time()+3600)*1000}}))
        line = lambda l, used: '%s\tuuid\t%d\t%d\t0\t0\t0\t1\t1\t1\t1\t0\t0' % (l, used, (100-used)*2)
        out = '\n'.join([line('h1', 0), line('h2', 50), line('local', 60)])

        def inv(**over):
            env = dict({'FLEET_ACCOUNT_PAUSED': ''}, **over)
            with patch.dict(os.environ, dict(env, FLEET_ACCOUNTS_DIR=str(acct))), \
                 patch.object(accounts, 'run', return_value=out), \
                 patch.object(accounts, 'profiles', return_value=[]), \
                 patch.object(accounts, 'codex_reading', return_value={'accounts': [], 'reason': ''}):
                return accounts.inventory()
        data = inv()
        self.assertEqual({r['label']: r['login'] for r in data['accounts']}, {'h1': 'valid', 'h2': 'valid', 'local': 'valid'})
        self.assertEqual(accounts.choose(data, 'claude')['target']['label'], 'h1')
        data = inv(FLEET_ACCOUNT_PAUSED='h1 local')
        self.assertEqual({r['label']: r['login'] for r in data['accounts']}, {'h1': 'paused', 'h2': 'valid', 'local': 'valid'})
        r = accounts.choose(data, 'claude')
        self.assertEqual(r['target']['label'], 'h2')
        self.assertEqual([(e['label'], e['reason']) for e in r['excluded']], [('h1', 'paused')])
        state = accounts.state_dir(); state.mkdir(parents=True)
        (state/'account.paused').write_text('h1\nh2\n')
        r = accounts.choose(inv(), 'claude')
        self.assertEqual(r['target']['label'], 'local')
        (state/'account.paused').write_text('h1\nh2\nlocal\n')
        r = accounts.choose(inv(), 'claude')
        self.assertEqual(r['target']['label'], 'local')   # a local label is never paused
        # every pool label paused and nothing else: waiting, never «login needed»
        rows = [x for x in inv()['accounts'] if x['label'] != 'local']
        r = accounts.choose({'accounts': rows}, 'claude')
        self.assertEqual((r['state'], r['target']), ('waiting-quota', None))
        self.assertNotIn('login needed', r['reason'])

    def test_claude_inventory_reads_pace_fields(self):
        # fleet-account.sh _claude-inventory grew fields 12–13 (pace, held); a pre-#1231
        # 11-field row still parses, with no hold.
        line13 = 'x\tuuid\t40\t3000\t0\t0\t0\t1\t1\t1\t1\t-12\t0'
        line11 = 'y\tuuid\t40\t3000\t0\t0\t0\t1\t1\t1\t1'
        held13 = 'z\tuuid\t70\t900\t0\t0\t0\t1\t1\t1\t1\t40\t1'
        with patch.object(accounts, 'run', return_value='\n'.join([line13, line11, held13])), \
             patch.object(accounts, 'profiles', return_value=[]), \
             patch.object(accounts, 'codex_reading', return_value={'accounts': [], 'reason': ''}):
            rows = {r['label']: r for r in accounts.inventory()['accounts']}
        self.assertEqual((rows['x']['pace'], rows['x']['pace_held']), (-12, False))
        self.assertEqual((rows['y']['pace'], rows['y']['pace_held']), (0, False))
        self.assertEqual((rows['z']['pace'], rows['z']['pace_held']), (40, True))
        # the hold is fail-open in choose(): z loses to x, wins alone
        self.assertEqual(accounts.choose({'accounts': [rows['z'], rows['x']]}, 'claude')['target']['label'], 'x')
        self.assertEqual(accounts.choose({'accounts': [rows['z']]}, 'claude')['target']['label'], 'z')

    def test_local_profile_intersection_and_uuid(self):
        raw=dict(source='codex',accounts=[dict(account_uuid=self.profile['account'],available=True,
            windows=[dict(id='codex:primary',minutes=300,utilization=10)]),
            dict(account_uuid='remote-only',available=True,windows=[dict(id='p',minutes=300,utilization=0)])])
        with patch.object(accounts,'profiles',return_value=[self.profile]), patch.object(accounts,'ccquota',return_value=raw), patch.object(accounts,'run',return_value=''):
            result=accounts.inventory(True)
        self.assertEqual(len(result['accounts']),1)
        self.assertEqual(result['accounts'][0]['account'],self.profile['account'])

    def test_failed_refresh_invalidates_old_success(self):
        path=accounts.state_dir()/'account.codex-quota.json'
        accounts.save(path,dict(fetched_at=time.time(),accounts=[{'account_uuid':'old'}]))
        with patch.object(accounts,'ccquota',side_effect=ValueError('unsupported')):
            self.assertEqual(accounts.codex_reading(True)['accounts'],[])
        self.assertEqual(accounts.read(path)['accounts'],[])

    def test_claude_login_states_and_target_auth(self):
        # issue #1667: the Claude-side judge — a plain token file, a hub-managed
        # token (fresh / expired), the mark-reauth marker, nothing at all.
        acct = self.root/'accounts'; acct.mkdir()
        (acct/'plain').write_text('tok-secret\n'); (acct/'empty').write_text('\n')
        for name, offset in (('hubbed', 3600), ('stale', -5)):
            (acct/name).write_text('hub:%s\n' % name); (acct/(name+'.hub')).mkdir()
            (acct/(name+'.hub')/'.credentials.json').write_text(json.dumps(
                {'claudeAiOauth': {'accessToken': 'x', 'expiresAt': (time.time()+offset)*1000}}))
        (acct/'marked').write_text('tok-secret\n')
        state = accounts.state_dir(); state.mkdir(parents=True)
        (state/'account.claude-reauth').write_text('marked\t%d\tauth error\n' % time.time())
        # FLEET_ACCOUNT_LABEL is a worker pane's own pin — cleared, or «no label»
        # below would read the developer's account instead of the sandbox
        with patch.dict(os.environ, FLEET_ACCOUNTS_DIR=str(acct), FLEET_ACCOUNT_LABEL=''):
            self.assertEqual([accounts.claude_login(l) for l in ('plain','empty','hubbed','stale','marked','missing','../x')],
                             ['valid','no_credentials','valid','expired','reauth_required','no_credentials','no_credentials'])
            self.assertEqual(accounts.target_auth('claude', label='plain')['verdict'], 'ok')
            r = accounts.target_auth('claude', label='marked')
            self.assertEqual((r['verdict'], r['login'], r['key']), ('refuse', 'reauth_required', 'claude/marked'))
            self.assertIn('needs a new login (reauth_required)', r['reason'])
            self.assertEqual(accounts.target_auth('claude', label='stale')['login'], 'expired')
            with patch.object(accounts, 'run', return_value=''):   # multi-account off
                self.assertEqual(accounts.target_auth('claude')['verdict'], 'unknown')
            with self.assertRaisesRegex(ValueError, 'target-auth: Claude account stale'):
                accounts.claude_profile('stale')
            # the inventory carries the same answer, so choose() never picks it
            line = lambda l: '%s\tuuid\t40\t3000\t0\t0\t0\t1\t1\t1\t1\t0\t0' % l
            with patch.object(accounts, 'run', return_value='\n'.join(line(l) for l in ('plain','marked','stale'))), \
                 patch.object(accounts, 'profiles', return_value=[]), \
                 patch.object(accounts, 'codex_reading', return_value={'accounts': [], 'reason': ''}):
                rows = {r['label']: r['login'] for r in accounts.inventory()['accounts']}
            self.assertEqual(rows, {'plain': 'valid', 'marked': 'reauth_required', 'stale': 'expired'})
            # …and C2's bar stamp (#1469) names the marked label beside ccquota's rows
            accounts.stamp_reauth([dict(self.profile, login='reauth_required', profile='work', email='w@example.invalid')])
            stamped = [l.split('\t') for l in (state/'account.reauth').read_text().splitlines()[1:]]
            self.assertEqual([(r[1], r[2], r[4], r[5]) for r in stamped],
                             [('codex', 'work', 'reauth_required', 'codex login --device-auth'),
                              ('claude', 'marked', 'reauth_required', 'claude setup-token')])

    def test_target_auth_codex_refuses_reauth_passes_valid_unknown_without_registry(self):
        home = self.root/'codex-home'; home.mkdir(); home = home.resolve()
        bad = dict(self.profile, home=str(home), login='reauth_required')
        good = dict(bad, login='refresh_due')
        with patch.object(accounts, 'profiles', return_value=[bad]):
            r = accounts.target_auth('codex', home=str(home))
            self.assertEqual((r['verdict'], r['login'], r['profile']), ('refuse', 'reauth_required', 'work'))
            self.assertEqual(r['reason'], 'Codex profile needs a verified subscription login: work (reauth_required)')
            # an unregistered home: the planner's launcher would refuse it, a plain
            # install runs Codex on it as before
            with patch.dict(os.environ, FLEET_FAILOVER='1'):
                self.assertEqual(accounts.target_auth('codex', home=str(self.root/'nowhere'))['verdict'], 'refuse')
            with patch.dict(os.environ, FLEET_FAILOVER='0'):
                self.assertEqual(accounts.target_auth('codex', home=str(self.root/'nowhere'))['verdict'], 'unknown')
        with patch.object(accounts, 'profiles', return_value=[good]):
            self.assertEqual(accounts.target_auth('codex', profile_name='work')['verdict'], 'ok')
            with patch.dict(os.environ, FLEET_CODEX_ACCOUNTS='work', FLEET_CODEX_HOME=''):
                self.assertEqual(accounts.target_auth('codex')['verdict'], 'ok')
        with patch.object(accounts, 'profiles', return_value=[bad]), \
             patch.dict(os.environ, FLEET_CODEX_ACCOUNTS='work', FLEET_CODEX_HOME=''):
            self.assertEqual(accounts.target_auth('codex')['verdict'], 'refuse')
        with patch.object(accounts, 'profiles', side_effect=OSError('no ccquota')):
            self.assertEqual(accounts.target_auth('codex', home=str(home))['verdict'], 'unknown')

    def test_check_target_names_a_bad_login_as_target_auth(self):
        target = candidate('claude', 'x', label='x')
        with patch.object(accounts, 'inventory', return_value={'accounts': [dict(target, login='reauth_required')]}):
            with self.assertRaisesRegex(ValueError, r'target-auth: pinned destination claude/x needs a new login \(reauth_required\)'):
                accounts.check_target(target)
        with patch.object(accounts, 'inventory', return_value={'accounts': [target]}):
            self.assertEqual(accounts.check_target(target)['key'], 'claude/x')

    def test_pinned_target_rejects_relogin(self):
        target=candidate('codex','old',profile='p',home='/home')
        data={'accounts':[candidate('codex','new',profile='p',home='/home')]}
        with patch.object(accounts,'inventory',return_value=data):
            with self.assertRaisesRegex(ValueError,'no longer eligible'):
                accounts.check_target(target)

    def test_existing_source_verifies_native_provider_without_rereading_startup_config(self):
        source=dict(session_id='exact-thread',worktree=str(self.root))
        native=dict(id='exact-thread',cwd=str(self.root),modelProvider='openai')
        auth=dict(account={'type':'chatgpt','email':'fixture@example.com'},requiresOpenaiAuth=True)
        calls=[]
        class Client:
            def __init__(self,*_,**__):pass
            def close(self):pass
            def call(self,method,params):
                calls.append(method)
                if method=='account/read':return auth
                if method=='thread/read':return {'thread':native}
                raise ValueError('startup feature override file no longer exists')
        expected=dict(self.profile,email='fixture@example.com')
        with patch.object(accounts,'read_subscription',return_value=expected), patch.object(accounts,'profile',return_value=expected), patch.object(accounts.runpy,'run_path',return_value={'Client':Client}):
            accounts.verify_codex_runtime('unix:///exact.sock',source=source)
            self.assertEqual(calls,['account/read','thread/read'])
            for key,value in (('id','replacement'),('cwd','/wrong'),('modelProvider','custom')):
                with patch.dict(native,{key:value}):
                    with self.assertRaises(ValueError):accounts.verify_codex_runtime('unix:///exact.sock',source=source)
            with patch.dict(auth['account'],email='other@example.com'):
                with self.assertRaises(ValueError):accounts.verify_codex_runtime('unix:///exact.sock',source=source)
            # A new destination still requires pre-TUI config verification.
            with self.assertRaisesRegex(ValueError,'startup feature'):
                accounts.verify_codex_runtime('unix:///exact.sock')



class CodexLoginReason(unittest.TestCase):
    """claude-fleet#1404 (EPIC #1665 C7): ccquota's own reason for a failed Codex
    login travels verbatim — the profile check, the row and the chooser's refusal
    all say WHY, not just that auth is unavailable."""
    REASON = 'Codex refresh credential rejected; sign in again for this profile'

    def rows(self, home):
        return [dict(name='work', home=home, default=True, account='acct-work', email='w@example.com',
                     plan='plus', login=dict(state='reauth_required', reason=self.REASON))]

    def test_ccquota_reason_reaches_profile_check_row_and_chooser(self):
        with tempfile.TemporaryDirectory() as home, patch.object(accounts, 'ccquota', return_value=self.rows(home)):
            p = accounts.profiles()[0]
            self.assertEqual(p['login'], 'reauth_required')
            self.assertEqual(p['login_reason'], self.REASON)
            with self.assertRaises(ValueError) as cm:
                accounts.profile('work')
            self.assertIn('reauth_required', str(cm.exception))
            self.assertIn(self.REASON, str(cm.exception))
            row = accounts.normalize_codex(p, dict(available=True))
            self.assertEqual(row['reason'], 'auth-unavailable')
            self.assertEqual(row['login_reason'], self.REASON)
            r = accounts.choose({'accounts': [row]}, 'codex')
            self.assertEqual(r['state'], 'waiting-quota')
            self.assertIn('codex/acct-work', r['reason'])
            self.assertIn(self.REASON, r['reason'])

    def test_valid_login_carries_no_reason_and_capped_text_is_unchanged(self):
        with tempfile.TemporaryDirectory() as home:
            rows = self.rows(home)
            rows[0]['login'] = dict(state='valid')
            with patch.object(accounts, 'ccquota', return_value=rows):
                self.assertEqual(accounts.profiles()[0]['login_reason'], '')
        r = accounts.choose({'accounts': [candidate('codex', 'full', 100)]}, 'codex')
        self.assertEqual(r['reason'], 'accounts · all capped')

if __name__ == '__main__':
    unittest.main()
