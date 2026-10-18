#!/usr/bin/env python3
"""fleet_transfer_durable.py — single-owner durable handover, with real processes.

Every leg runs in a private HOME / FLEET_CONF_DIR. The source, a third-party
lock holder, a foreign creator and the "native" side (the CronDelete /
CronCreate effects and their transcript receipts) are real separate processes;
an observer thread samples owner() the whole time: the task is never owned by
both sides and never by nobody, except the visible `attention` state the module
documents (a receipt the evidence cannot settle).
"""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
os.environ['TZ'] = 'America/Los_Angeles'
time.tzset()
import fleet_transfer_durable as D  # noqa: E402

FID = '11111111-1111-4111-8111-111111114280'
SLEEPER = 'import signal,time; signal.alarm(120); time.sleep(120)'
NATIVE = r'''
import json, os, sys
store, op, payload = sys.argv[1:]
table = json.load(open(store)) if os.path.exists(store) else {"tasks": []}
if op == "delete":
    table["tasks"] = [t for t in table["tasks"] if t["id"] != payload]
else:
    table["tasks"].append(json.loads(payload))
tmp = store + ".native"
open(tmp, "w").write(json.dumps(table))
os.rename(tmp, store)
'''


def wait_for(cond, secs=10):
    end = time.time() + secs
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.05)
    return cond()


class Observer(threading.Thread):
    """owner() with a stable journal state around each table read."""
    def __init__(self, path):
        super().__init__(daemon=True)
        self.path, self.seen, self.bad, self.stop = path, [], [], False

    def run(self):
        while not self.stop:
            try:
                a = D.read(self.path)
                ids = {j['id'] for j in a['jobs']} | set(a.get('restored_ids', []))
                present = bool(ids & set(D.table(a['store'])))
                b = D.read(self.path)
            except (OSError, ValueError, TypeError):
                time.sleep(0.01)
                continue
            if a['state'] == b['state']:
                who = D.owner(a, present)
                self.seen.append(who)
                if who in ('both', 'none'):
                    self.bad.append((a['state'], present, who))
            time.sleep(0.005)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name, 'home').resolve()
        (self.home / '.claude').mkdir(parents=True)
        os.environ['FLEET_CONF_DIR'] = str(Path(self.tmp.name, 'conf'))
        os.environ['HOME'] = str(self.home)
        self.procs = []
        self.source = self.spawn()
        self.start = D.proc_start(self.source.pid)
        due = datetime.datetime.now() + datetime.timedelta(days=1)
        minute = 13 if due.minute in (0, 30) else due.minute
        self.cron = '%d %d %d %d *' % (minute, due.hour, due.day, due.month)
        # Created before a /clear: the lock and the record carry the OLD session
        # id; the live process (same pid + start) now runs another one.
        self.record = dict(id='2b6a2f9f', cron=self.cron, prompt='EPIC acceptance: reread the metrics',
                           createdAt=int(time.time() * 1000), createdBySessionId='before-clear',
                           createdByPid=self.source.pid, createdByProcStart=self.start,
                           createdInProject=str(self.home))
        self.store, self.lock = D.native_paths(self.home)
        self.store.write_text(json.dumps(dict(tasks=[self.record])))
        self.original = self.store.read_bytes()
        self.lock.write_text(json.dumps(dict(sessionId='before-clear', pid=self.source.pid,
                                             procStart=self.start, acquiredAt=1)))
        self.transcript = Path(self.tmp.name, 'source.jsonl')
        self.transcript.write_text(json.dumps(dict(type='user', version='2.1.295')) + '\n')
        self.job = D.job_for(self.record)
        self.observer = None
        self.n = 0

    def tearDown(self):
        if self.observer:
            self.observer.stop = True
            self.observer.join(2)
        for p in self.procs:
            if p.poll() is None:
                p.kill()
            p.wait()
        self.tmp.cleanup()

    def spawn(self):
        p = subprocess.Popen([sys.executable, '-c', SLEEPER])
        self.procs.append(p)
        wait_for(lambda: D.proc_start(p.pid))
        return p

    def stage(self):
        path = D.stage(FID, self.home, self.source.pid, 'after-clear', '2.1.295', [self.job], self.transcript)
        self.observer = Observer(path)
        self.observer.start()
        return path

    def tool(self, name, inp, result):
        """A main-thread tool call + its result, as the source transcript holds them."""
        self.n += 1
        ts = datetime.datetime.now(datetime.timezone.utc).isoformat()
        use = dict(timestamp=ts, message=dict(content=[dict(type='tool_use', id='t%d' % self.n, name=name, input=inp)]))
        res = dict(timestamp=ts, toolUseResult=result,
                   message=dict(content=[dict(type='tool_result', tool_use_id='t%d' % self.n)]))
        with self.transcript.open('a') as out:
            out.write(json.dumps(use) + '\n' + json.dumps(res) + '\n')

    def native(self, op, payload):
        subprocess.run([sys.executable, '-c', NATIVE, str(self.store), op, payload], check=True, timeout=10)

    def cron_delete(self):
        self.native('delete', self.record['id'])
        self.tool('CronDelete', dict(id=self.record['id']), 'Cancelled ' + self.record['id'])

    def cron_list(self, jobs=()):
        self.tool('CronList', {}, dict(jobs=list(jobs)))

    def kill_source(self):
        self.source.kill()
        self.source.wait()

    def state(self):
        return D.read(D.journal_path(FID))['state']

    def assert_single_owner(self):
        time.sleep(0.1)
        self.assertGreater(len(self.observer.seen), 0)
        self.assertEqual(self.observer.bad, [])


class Road(Base):
    def test_success_live_source_receipts_then_one_fleet_owner(self):
        self.stage()
        self.assertEqual(D.gate(FID), 'wait')                 # staged copy is inert
        D.begin(FID)
        self.cron_delete()
        self.cron_list()
        D.confirm(FID, self.transcript)
        self.assertEqual(self.state(), 'withdrawn')
        self.assertEqual(D.gate(FID), 'wait')                 # still inert: source alive
        D.claim(FID, os.getpid())
        with self.assertRaises(D.Refused):
            D.handed(FID)                                     # the source has not exited
        with self.assertRaises(D.Refused):
            D.activate(FID, dict(agent='codex'))
        self.kill_source()
        D.handed(FID)
        D.activate(FID, dict(agent='codex', session='target'))
        D.activate(FID, dict(agent='codex', session='target'))   # idempotent
        self.assertEqual(D.gate(FID), 'deliver')
        D.complete(FID, 'turn-1')
        self.assertEqual(D.gate(FID), 'drop')                 # never a second time
        self.assertEqual(D.owner(D.read(D.journal_path(FID))), 'done')
        self.assertNotIn(self.record['id'], D.table(self.store))
        self.assert_single_owner()

    def test_clear_changed_sid_is_still_the_live_source(self):
        kind, _ = D.holder(self.lock, dict(pid=self.source.pid, start=self.start))
        self.assertEqual(kind, 'source')

    def test_confirm_needs_every_receipt(self):
        self.stage()
        D.begin(FID)
        with self.assertRaises(ValueError):
            D.confirm(FID, self.transcript)                   # nothing deleted yet
        self.native('delete', self.record['id'])              # deleted without a receipt
        self.cron_list()
        with self.assertRaises(ValueError):
            D.confirm(FID, self.transcript)
        self.tool('CronDelete', dict(id=self.record['id']), 'Cancelled')
        with self.assertRaises(ValueError):
            D.confirm(FID, self.transcript)                   # no CronList after the delete
        self.cron_list([dict(id=self.record['id'], cron=self.cron)])
        with self.assertRaises(ValueError):
            D.confirm(FID, self.transcript)                   # the list still has it
        self.cron_list()
        self.tool('CronCreate', dict(cron='5 * * * *', prompt='x'), dict(id='new'))
        with self.assertRaises(ValueError):
            D.confirm(FID, self.transcript)                   # a later change voids the list
        self.cron_list()
        D.confirm(FID, self.transcript)
        self.assertEqual(self.state(), 'withdrawn')
        self.assert_single_owner()

    def test_unsupported_shapes_refuse_read_only(self):
        with self.assertRaises(D.Refused):
            D.inspect(self.home, self.source.pid, '2.1.296')
        for bad in (dict(self.record, cron='30 9 21 10 *'), dict(self.record, recurring=True),
                    dict(self.record, createdInProject='/elsewhere')):
            self.store.write_text(json.dumps(dict(tasks=[bad])))
            with self.assertRaises(D.Refused):
                D.inspect(self.home, self.source.pid, '2.1.295')
        creator = self.spawn()
        foreign = dict(self.record, createdByPid=creator.pid, createdByProcStart=D.proc_start(creator.pid))
        self.store.write_text(json.dumps(dict(tasks=[foreign])))
        # Another live session's record is its own: never staged here (#4758).
        self.assertEqual(D.inspect(self.home, self.source.pid, '2.1.295')['records'], [])
        self.assertFalse(D.journal_path(FID).exists())

    def test_third_party_holder_refuses_and_names_it(self):
        other = self.spawn()
        self.lock.write_text(json.dumps(dict(sessionId='someone-else', pid=other.pid,
                                             procStart=D.proc_start(other.pid), acquiredAt=1)))
        with self.assertRaises(D.Refused) as caught:
            D.inspect(self.home, self.source.pid, '2.1.295')
        self.assertIn('pid %d' % other.pid, str(caught.exception))
        self.assertEqual(self.store.read_bytes(), self.original)

    def test_dead_or_reused_holder_is_not_the_live_source(self):
        impostor = self.spawn()
        for pid, start in ((99999999, self.start), (impostor.pid, 'Thu Jan  1 00:00:00 1970')):
            self.lock.write_text(json.dumps(dict(sessionId='before-clear', pid=pid, procStart=start, acquiredAt=1)))
            self.assertEqual(D.holder(self.lock, dict(pid=self.source.pid, start=self.start))[0], 'dead')

    def test_reappearing_record_goes_back_to_native(self):
        self.stage()
        D.begin(FID)
        self.cron_delete()
        self.cron_list()
        D.confirm(FID, self.transcript)
        self.kill_source()
        D.activate(FID, dict(agent='codex'))
        self.native('create', json.dumps(self.record))         # a stale native writer
        self.assertEqual(D.gate(FID), 'drop')
        self.assertEqual(self.state(), 'returned')
        self.assertEqual(D.owner(D.read(D.journal_path(FID))), 'native')


class Orphan(Base):
    """A durable task another, gone session left in HOME (#4758): it neither
    holds this session's switch nor moves with it; it is named and left alone."""
    def setUp(self):
        super().setUp()
        dead = self.spawn()
        self.dead_start = D.proc_start(dead.pid)
        dead.kill()
        dead.wait()
        self.orphan = dict(self.record, id='0rphan01', createdBySessionId='long-gone',
                           createdByPid=dead.pid, createdByProcStart=self.dead_start)

    def check(self, tasks, pid=None):
        import fleet_transfer_cron as C
        import contextlib
        import io
        self.store.write_text(json.dumps(dict(tasks=tasks)))
        before, err = self.store.read_bytes(), io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                C.check_durable_store(FID, self.source.pid if pid is None else pid)
        finally:
            self.assertEqual(self.store.read_bytes(), before)     # never touched
        return err.getvalue()

    def test_orphan_does_not_hold_the_switch(self):
        note = self.check([self.orphan])
        self.assertIn('0rphan01', note)
        self.assertIn('gone', note)
        self.assertIn('long-gone', note)

    def test_live_foreign_task_does_not_hold_the_switch(self):
        other = self.spawn()
        foreign = dict(self.record, id='f0reign1', createdByPid=other.pid,
                       createdByProcStart=D.proc_start(other.pid))
        self.assertIn('live pid %d' % other.pid, self.check([foreign]))

    def test_own_or_unproven_task_still_refuses_and_says_which(self):
        unknown = {k: v for k, v in self.record.items() if not k.startswith('createdByP')}
        for tasks, pid in (([self.orphan, self.record], None), ([unknown], None), ([self.orphan], 0)):
            with self.assertRaises(ValueError) as caught:
                self.check(tasks, pid)
            msg = str(caught.exception)
            self.assertIn('execution owner', msg)
            self.assertIn('fires ', msg)
            self.assertIn('CronDelete', msg)
            self.assertIn((unknown if tasks == [unknown] else tasks[-1])['id'], msg)
        self.assertNotIn('0rphan01', msg.split(':', 1)[0])

    def test_orphan_never_stages_with_the_source(self):
        self.store.write_text(json.dumps(dict(tasks=[self.orphan])))
        self.assertEqual(D.inspect(self.home, self.source.pid, '9.9.9')['records'], [])
        self.store.write_text(json.dumps(dict(tasks=[self.orphan, self.record])))
        self.assertEqual(D.inspect(self.home, self.source.pid, '2.1.295')['records'], [self.record])


class Failures(Base):
    def test_abort_before_the_delete_changes_nothing(self):
        self.stage()
        D.begin(FID)
        self.assertEqual(D.abort(FID, 'target login refused'), 'rolled_back')
        self.assertEqual(self.store.read_bytes(), self.original)
        self.assertEqual(D.gate(FID), 'drop')
        self.assert_single_owner()

    def test_live_source_after_the_delete_recreates_natively(self):
        self.stage()
        D.begin(FID)
        self.cron_delete()
        self.cron_list()
        D.confirm(FID, self.transcript)
        self.assertEqual(D.abort(FID, 'identity changed before exit'), 'restoring')
        ask = D.restore_request(D.load(FID))
        self.assertIn('CronCreate', ask)
        self.assertIn(json.dumps(self.record['prompt']), ask)
        with self.assertRaises(ValueError):
            D.confirm_restored(FID, self.transcript)          # no receipt yet
        made = dict(self.record, id='a1b2c3d4', createdAt=int(time.time() * 1000))
        self.native('create', json.dumps(made))
        self.tool('CronCreate', dict(cron=self.cron, prompt=self.record['prompt'], recurring=False, durable=True),
                  dict(id='a1b2c3d4', durable=True))
        D.confirm_restored(FID, self.transcript)
        self.assertEqual(self.state(), 'rolled_back')
        self.assertEqual(D.owner(D.read(D.journal_path(FID))), 'native')
        self.assertEqual(D.gate(FID), 'drop')
        self.assert_single_owner()

    def test_gone_source_after_the_delete_stays_fleets_for_the_rollback(self):
        self.stage()
        D.begin(FID)
        self.cron_delete()
        self.cron_list()
        D.confirm(FID, self.transcript)
        D.claim(FID, os.getpid())
        self.kill_source()
        self.assertEqual(D.abort(FID, 'target did not bind'), 'withdrawn')
        self.assertIn('resume-source.sh', D.load(FID)['attention'])
        D.activate(FID, dict(agent='claude', rollback=True))  # the resumed source's loop
        self.assertEqual(D.gate(FID), 'deliver')
        self.assert_single_owner()


class Crashes(Base):
    """The source / controller SIGKILLed at each step; the tick's sweep recovers."""
    def test_source_killed_before_its_delete(self):
        self.stage()
        D.begin(FID)
        self.kill_source()
        self.assertEqual(D.recover_all(), [(FID, 'rolled_back')])
        self.assertEqual(self.store.read_bytes(), self.original)
        self.assert_single_owner()

    def test_source_killed_between_delete_and_list(self):
        self.stage()
        D.begin(FID)
        self.cron_delete()
        self.kill_source()
        self.assertEqual(D.recover_all(), [(FID, 'withdrawn')])
        self.assertIn('resume-source.sh', D.load(FID)['attention'])
        D.activate(FID, dict(agent='claude', rollback=True))
        self.assertEqual(D.gate(FID), 'deliver')
        self.assert_single_owner()

    def test_unclaimed_journal_past_its_deadline_goes_back(self):
        self.stage()
        r = D.load(FID)
        r['deadline'] = 0
        D.atomic(D.journal_path(FID), r)
        self.assertEqual(D.recover_all(), [(FID, 'rolled_back')])

    def test_controller_killed_after_claim(self):
        self.stage()
        D.begin(FID)
        self.cron_delete()
        self.cron_list()
        D.confirm(FID, self.transcript)
        ctl = self.spawn()
        D.claim(FID, ctl.pid)
        self.kill_source()
        ctl.kill()
        ctl.wait()
        self.assertEqual(D.recover_all(), [(FID, 'withdrawn')])
        self.assertIn('resume-source.sh', D.load(FID)['attention'])
        self.assertEqual(D.owner(D.load(FID)), 'fleet')
        self.assert_single_owner()


class Takeover(Base):
    """Road 2: the source cannot cooperate; Fleet withdraws inside isolation."""
    def setUp(self):
        super().setUp()
        self.registry = Path(self.tmp.name, 'sessions')
        self.registry.mkdir()
        os.environ['FLEET_CC_SESSIONS_DIR'] = str(self.registry)
        # Claude processes already on this machine (a developer's own sessions)
        # are accounted for as running elsewhere; the legs add their own.
        for pid in D.claude_processes():
            self.register(pid, '/elsewhere')
        dead = dict(self.record, id='unrelated', prompt='someone else\'s reminder', createdByPid=1,
                    createdByProcStart='Thu Jan  1 00:00:00 1970')
        self.store.write_text(json.dumps(dict(tasks=[dead, self.record])))
        self.unrelated = dead
        self.ctl = self.spawn()

    def register(self, pid, cwd):
        (self.registry / ('%d.json' % pid)).write_text(json.dumps(dict(sessionId='s%d' % pid, cwd=cwd)))

    def fake_claude(self):
        link = Path(self.tmp.name, 'bin', 'claude')
        link.parent.mkdir(exist_ok=True)
        if not link.exists():
            link.symlink_to('/bin/sleep')
        p = subprocess.Popen([str(link), '60'])
        self.procs.append(p)
        wait_for(lambda: p.pid in D.claude_processes())
        return p

    def stage2(self):
        path = D.stage_takeover(FID, self.home, self.source.pid, 'after-clear', '2.1.295', self.ctl.pid)
        self.observer = Observer(path)
        self.observer.start()
        return path

    def test_isolated_takeover_keeps_every_other_record(self):
        self.stage2()
        self.assertEqual(D.gate(FID), 'wait')
        D.claim(FID, self.ctl.pid)
        self.kill_source()
        D.handed(FID)
        self.assertEqual(self.state(), 'withdrawn')
        self.assertEqual(D.tasks(D.read(self.store)), [self.unrelated])
        gate = D.read(D.gate_path())
        self.assertEqual((gate['pid'], gate['home']), (self.ctl.pid, str(self.home)))
        waiter = subprocess.Popen([sys.executable, str(BIN / 'fleet_transfer_durable.py'), 'gate-wait', str(self.home)],
                                  stdout=subprocess.DEVNULL, env=dict(os.environ))
        time.sleep(1)
        self.assertIsNone(waiter.poll())                      # a new Claude here waits
        D.activate(FID, dict(agent='codex'))
        self.assertEqual(waiter.wait(timeout=5), 0)          # and starts once it is settled
        self.assertFalse(D.gate_path().exists())
        self.assertEqual(D.gate(FID), 'deliver')
        self.assert_single_owner()

    def test_unknown_claude_refuses_naming_it(self):
        stray = self.fake_claude()
        with self.assertRaises(D.Refused) as caught:
            self.stage2()
        self.assertIn('pid %d' % stray.pid, str(caught.exception))
        self.register(stray.pid, str(self.home))
        with self.assertRaises(D.Refused) as caught:
            self.stage2()
        self.assertIn('runs in this HOME', str(caught.exception))
        self.register(stray.pid, '/somewhere/else')
        self.stage2()                                         # accounted for: allowed
        self.assertEqual(self.state(), 'staged')

    def test_claude_appearing_after_staging_refuses_before_any_write(self):
        self.stage2()
        D.claim(FID, self.ctl.pid)
        self.kill_source()
        before = self.store.read_bytes()
        self.fake_claude()
        with self.assertRaises(D.Refused):
            D.handed(FID)
        self.assertEqual(self.store.read_bytes(), before)
        self.assertEqual(D.abort(FID, 'isolation broke'), 'rolled_back')
        self.assertFalse(D.gate_path().exists())
        self.assert_single_owner()

    def test_third_party_lock_holder_refuses(self):
        other = self.spawn()
        self.lock.write_text(json.dumps(dict(sessionId='someone-else', pid=other.pid,
                                             procStart=D.proc_start(other.pid), acquiredAt=1)))
        with self.assertRaises(D.Refused) as caught:
            self.stage2()
        self.assertIn('pid %d' % other.pid, str(caught.exception))

    def crash_at(self, point):
        self.stage2()
        self.kill_source()
        env = dict(os.environ, FLEET_DURABLE_TEST_CRASH=point, PYTHONPATH=str(BIN))
        code = 'import os,sys,fleet_transfer_durable as D; D.claim(sys.argv[1], os.getpid()); D.handed(sys.argv[1])'
        ctl = subprocess.run([sys.executable, '-c', code, FID], env=env, timeout=30)
        self.assertEqual(ctl.returncode, -9)
        self.assertIn(self.unrelated, D.tasks(D.read(self.store)))   # never lost, at any step
        return D.recover_all()

    def test_crash_after_write_ahead(self):
        self.assertEqual(self.crash_at('withdrawing'), [(FID, 'rolled_back')])
        self.assertEqual(D.tasks(D.read(self.store)), [self.unrelated, self.record])
        self.assertFalse(D.gate_path().exists() and D.alive(D.read(D.gate_path())['pid'], D.read(D.gate_path())['start']))
        self.assert_single_owner()

    def test_crash_after_table_write(self):
        self.assertEqual(self.crash_at('table-written'), [(FID, 'withdrawing')])
        self.assertEqual(D.owner(D.load(FID)), 'fleet')       # Fleet's journal holds it,
        self.assertIn('resume-source.sh', D.load(FID)['attention'])   # visibly
        self.assertEqual(D.tasks(D.read(self.store)), [self.unrelated])
        self.assert_single_owner()

    def test_crash_after_withdrawn(self):
        self.assertEqual(self.crash_at('withdrawn'), [(FID, 'withdrawn')])
        D.activate(FID, dict(agent='claude', rollback=True))  # the resumed source's loop
        self.assertEqual(D.gate(FID), 'deliver')
        self.assert_single_owner()


if __name__ == '__main__':
    result = unittest.main(exit=False, verbosity=1).result
    if result.wasSuccessful():
        print('fleet-transfer-durable selftest: PASS (%d)' % result.testsRun)
    sys.exit(0 if result.wasSuccessful() else 1)
