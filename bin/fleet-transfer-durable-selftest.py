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
        with self.assertRaises(D.Refused):
            D.inspect(self.home, self.source.pid, '2.1.295')
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


if __name__ == '__main__':
    result = unittest.main(exit=False, verbosity=1).result
    if result.wasSuccessful():
        print('fleet-transfer-durable selftest: PASS (%d)' % result.testsRun)
    sys.exit(0 if result.wasSuccessful() else 1)
