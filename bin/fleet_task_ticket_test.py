#!/usr/bin/env python3
"""Isolated filing journal tests; API/CLI contract is also tested in Go."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
import threading
import unittest
from unittest.mock import patch

from fleet_task_ticket import Filing, task_call
import fleet_ticket


class TicketTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.body = self.root / "body"
        self.body.write_text("original")
        self.args = ["--repo", "org/repo", "--title", "original", "--body-file", str(self.body)]
        self.d = dict(version=1, request_id="original", requested_agent="codex", resolved_agent="codex", agent_source="explicit")
        self.task = dict(id="T7", owner="alice", authority_version=1, repo="org/repo", generation=1, attempt_id="task:T7:g1",
                         state="accepted", requested_agent="codex", resolved_agent="codex", request_payload=json.dumps(dict(dispatch=self.d)))
        self.d.update(task="T7", generation=1, attempt_id="task:T7:g1")
        self.url = "https://github.com/org/repo/issues/71"
        self.creates = 0
        self.issue = False
        self.failure = ""
        self.link_failure = ""
        self.links = 0

    def call(self, action, task, payload=None):
        if action == "get":
            return dict(task=self.task)
        if payload["kind"] == "ticket_link":
            if self.link_failure == "before":
                self.link_failure = ""
                raise ValueError("HTTP unavailable before link")
            if not self.task.get("ticket_ref"):
                self.links += 1
                self.task["ticket_ref"] = payload["ticket_ref"]
            if self.link_failure == "ack":
                self.link_failure = ""
                raise ValueError("link committed, acknowledgement lost")
        return self.task

    def ticket_run(self, argv):
        if "create-ready" in argv:
            return subprocess.CompletedProcess(argv, 4 if self.failure == "quota" else 0, "", "")
        if "find" in argv:
            return subprocess.CompletedProcess(argv, 0 if self.issue else 1,
                "gh:org/repo#71\t"+self.url if self.issue else "", "")
        self.creates += 1
        self.assertIn("fleet:task-ticket v=1", Path(argv[argv.index("--body-file")+1]).read_text())
        if self.failure != "network":
            self.issue = True
        return subprocess.CompletedProcess(argv, 1 if self.failure else 0, "" if self.failure else self.url, "connection reset" if self.failure else "")

    def file(self):
        # A new object on every retry proves the state survives process exit.
        return Filing(self.root, "http://fixture-hub", self.call, self.ticket_run).file("T7", self.d, self.args)

    def test_quota_recovers_same_request(self):
        self.failure = "quota"
        with self.assertRaises(ValueError): self.file()
        self.assertFalse(self.issue)
        self.failure = ""
        self.assertEqual(self.file(), self.url)
        self.assertEqual(self.file(), self.url)
        self.assertEqual((self.creates,self.links),(1,1))

    def test_create_ack_and_association_retry(self):
        self.link_failure = "before"
        self.failure = "ack"
        with self.assertRaises(ValueError): self.file()
        with self.assertRaises(ValueError): self.file()
        self.assertEqual(self.file(),self.url)
        self.assertEqual((self.creates,self.links),(1,1))

    def test_link_lost_ack(self):
        self.link_failure = "ack"
        with self.assertRaises(ValueError): self.file()
        self.assertEqual(self.file(),self.url)
        self.assertEqual((self.creates,self.links),(1,1))

    def test_unknown_create_never_sent_twice(self):
        self.failure = "network"
        with self.assertRaises(ValueError): self.file()
        self.failure = ""
        with self.assertRaisesRegex(ValueError,"RECONCILIATION_REQUIRED"): self.file()
        self.assertEqual(self.creates,1)

    def test_post_create_rate_limit_is_unknown(self):
        for output in (self.url, ""):
            with self.subTest(output=output), tempfile.TemporaryDirectory() as root:
                def partial(argv):
                    if "create-ready" in argv:
                        return subprocess.CompletedProcess(argv, 0, "", "")
                    return subprocess.CompletedProcess(argv, 1, output, "GraphQL: API rate limit exceeded")
                filing = Filing(root, "http://fixture-hub", self.call, partial)
                with self.assertRaises(ValueError):
                    filing.file("T7", self.d, self.args)
                with filing.store.connect() as db:
                    self.assertEqual(db.execute("SELECT status FROM operations").fetchone()[0], "sending")

    def test_overlapping_same_request_creates_once(self):
        entered, release = threading.Event(), threading.Event()
        def slow(argv):
            if "new" in argv:
                entered.set()
                self.assertTrue(release.wait(5))
            return self.ticket_run(argv)
        with ThreadPoolExecutor(2) as pool:
            def invoke():
                return Filing(self.root, "http://fixture-hub", self.call, slow).file("T7", self.d, self.args)
            first = pool.submit(invoke)
            self.assertTrue(entered.wait(5))
            second = pool.submit(invoke)
            release.set()
            self.assertEqual(first.result(), self.url)
            self.assertEqual(second.result(), self.url)
        self.assertEqual((self.creates, self.links), (1, 1))

    def test_hub_reconciliation_bound_and_link(self):
        args = ['--repo', 'org/repo', '--marker', 'marker', '--all']
        with patch.object(fleet_ticket, 'api', return_value={'tickets': [{}] * 500}):
            with self.assertRaises(fleet_ticket.Fail) as exc:
                fleet_ticket.hub_verb('find', args)
            self.assertEqual(exc.exception.rc, 4)
        with patch.object(fleet_ticket, 'api', return_value={'tickets': []}):
            with self.assertRaises(fleet_ticket.Fail) as exc:
                fleet_ticket.hub_verb('find', args)
            self.assertEqual(exc.exception.rc, 1)
        ticket = dict(number=71, body='marker', state='closed')
        with patch.object(fleet_ticket, 'api', return_value={'tickets': [ticket]}), patch.object(fleet_ticket, 'turl', return_value='http://fixture-hub/fleet/tickets/org/repo/71'):
            self.assertEqual(fleet_ticket.hub_verb('find', args), 'hub:org/repo#71\thttp://fixture-hub/fleet/tickets/org/repo/71')
        self.url = 'http://fixture-hub/fleet/tickets/org/repo/71'
        self.assertEqual(Filing(self.root, 'http://fixture-hub', self.call, self.ticket_run, backend='hub').file('T7', self.d, self.args), self.url)
        self.assertEqual(self.task['ticket_ref'], 'hub:org/repo#71')

    def test_real_ticket_preflight_and_single_send(self):
        fake = self.root / 'fake'; fake.mkdir()
        gh = fake / 'gh'
        gh.write_text('''#!/bin/sh
case "$1 $2" in
  'api rate_limit') cat "$FIXTURE_ROOT/remaining";;
  'issue create')
    echo create >> "$FIXTURE_ROOT/creates"
    cat "$FIXTURE_ROOT/output"
    echo 'GraphQL: secondary rate limit' >&2
    exit 1;;
esac
'''); gh.chmod(0o700)
        tmux = fake / 'tmux'; tmux.write_text('#!/bin/sh\nexit 1\n'); tmux.chmod(0o700)
        env = dict(HOME=str(self.root), PATH=str(fake)+':'+os.environ['PATH'], FLEET_CONF_DIR=str(self.root/'conf'),
                   FLEET_SKIP_GLOBAL_CONF='1', FLEET_STATE_DIR=str(self.root/'state'), FLEET_GH_WRITE_GAP='0',
                   FLEET_GH_WRITE_BACKOFF='0', FIXTURE_ROOT=str(self.root))
        script = str(Path(__file__).resolve().with_name('fleet-ticket.sh'))
        (self.root / 'remaining').write_text('0')
        r = subprocess.run(['bash', script, 'create-ready', '--repo', 'org/repo'], env=env, capture_output=True)
        self.assertEqual(r.returncode, 4)
        self.assertFalse((self.root / 'creates').exists())
        (self.root / 'remaining').write_text('100')
        r = subprocess.run(['bash', script, 'create-ready', '--repo', 'org/repo'], env=env, capture_output=True)
        self.assertEqual(r.returncode, 0)
        for output in (self.url, ''):
            (self.root / 'output').write_text(output)
            r = subprocess.run(['bash', script, 'new', '--filed', '--once', *self.args], env=env, text=True, capture_output=True, timeout=15)
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(r.stdout, output)
        self.assertEqual((self.root / 'creates').read_text().splitlines(), ['create', 'create'])

    def test_changed_input_or_generation_refused(self):
        self.assertEqual(self.file(),self.url)
        self.body.write_text("changed")
        with self.assertRaises(ValueError): self.file()
        self.task["generation"] = 2
        with self.assertRaises(ValueError): self.file()
        self.assertEqual(self.creates,1)

    def test_unknown_authority_is_never_legacy(self):
        with patch.dict(os.environ, {}, clear=True), patch('fleet_task_ticket.run', return_value=subprocess.CompletedProcess([],3,'','')):
            with self.assertRaisesRegex(ValueError, 'authority unavailable'):
                task_call('get','T7')

    def test_bounded_reconciliation_refuses_incomplete(self):
        fake=self.root/'fake';fake.mkdir()
        gh=fake/'gh';gh.write_text('#!/bin/sh\necho x >> "$QUERY_LOG"\nprintf "__fleet_count__\\t100\\n"\n');gh.chmod(0o700)
        tmux=fake/'tmux';tmux.write_text('#!/bin/sh\nexit 1\n');tmux.chmod(0o700)
        env=dict(HOME=str(self.root),PATH=str(fake)+':'+os.environ['PATH'],FLEET_CONF_DIR=str(self.root/'conf'),
                 FLEET_SKIP_GLOBAL_CONF='1',QUERY_LOG=str(self.root/'queries'))
        r=subprocess.run(['bash',str(Path(__file__).resolve().with_name('fleet-ticket.sh')),'find','--repo','org/repo','--marker','fixture-marker','--all'],env=env,text=True,capture_output=True)
        self.assertEqual(r.returncode,4,r.stderr)
        self.assertEqual(len((self.root/'queries').read_text().splitlines()),5)
        self.assertIn('incomplete',r.stderr)

    def test_unknown_task_filer_sends_no_create(self):
        fake=self.root/'fake';fake.mkdir();conf=self.root/'conf';conf.mkdir();(conf/'node.env').write_text('')
        gh=fake/'gh';gh.write_text('#!/bin/sh\n[ "$1 $2" != "issue create" ] || echo create >> "$CREATE_LOG"\nexit 0\n');gh.chmod(0o700)
        tmux=fake/'tmux';tmux.write_text('#!/bin/sh\nexit 1\n');tmux.chmod(0o700)
        env=dict(HOME=str(self.root),PATH=str(fake)+':'+os.environ['PATH'],FLEET_CONF_DIR=str(conf),
                 FLEET_SKIP_GLOBAL_CONF='1',FLEET_GH_WRITE_DIRECT='1',CREATE_LOG=str(self.root/'creates'))
        r=subprocess.run(['bash',str(Path(__file__).resolve().with_name('fleet-issue-file.sh')),'--repo','org/repo','--title','unknown task','--task','T7','--spawn'],env=env,text=True,capture_output=True)
        self.assertNotEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertIn('association incomplete',r.stderr)
        self.assertFalse((self.root/'creates').exists())


if __name__ == "__main__":
    unittest.main()
