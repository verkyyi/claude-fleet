#!/usr/bin/env python3
"""Shadow fixtures, never native-provider/authority acceptance."""
import copy
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import uuid
import shlex
import unittest
from unittest import mock

import fleet_reap_shadow as shadow
import fleet_runtime as runtime

C = dict(version=1, operation_id="11111111-1111-4111-8111-111111111111", task="T1",
         owner="alice", generation=1, attempt_id="task:T1:g1", provider="codex",
         worker_id="22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333")
I = dict(C, native_session="44444444-4444-4444-8444-444444444444", pid=42,
         birth="kernel-birth", executable="/native/codex", native_remote="unix:///private/socket", turn_id="t1")


def fixture():
    r = runtime.blank(now=100.)
    r.update(identity=I.copy(), source="codex:rpc")
    r["runtime"].update(state="idle", reason="")
    task = dict(id="T1", authority_version=1, owner="alice", generation=1,
                operation_id=C["operation_id"], attempt_id=C["attempt_id"],
                execution_owner=C["worker_id"], resolved_agent="codex", outcome="succeeded",
                task_blockers=dict(version=1, generation=1, items=[]))
    values = dict(task=task, report=dict(disposition="committed", outcome="succeeded", event_id="e1",
                  task="T1", owner="alice", generation=1, worker_id=C["worker_id"], durable=True),
                  children=dict(parent="T1",parent_session=C["worker_id"],parent_generation=1,children=[]),
                  processes=dict(complete=True, pending=[], unknown=[], fingerprint="tree1"),
                  pending_tool=dict(code=1, reason="no_pending"),
                  loop=[], delivery=[], transfer=[], migration=[], wake=[],
                  worktree=dict(clean=True, unpushed=False), draft="", outbox=[],
                  policy=dict(value="done:1m", satisfied=True), grace=dict(deadline=99.))
    layers = {k: dict(version=1, identity=I.copy(), source="fixture:"+k,
                     observed_at=100., expires_at=105., value=v) for k,v in values.items()}
    old = dict(version=1, identity=I.copy(), source="fixture:old-gate", observed_at=100.,
               expires_at=105., value=dict(eligible=True, reason=""))
    return dict(runtime=r, layers=layers, legacy=old)


class Shadow(unittest.TestCase):
    def proof(self, data=None, now=101.):
        return shadow.project(data or fixture(), now=now)

    def test_complete_is_still_not_actionable(self):
        data=fixture(); original=copy.deepcopy(data); p=self.proof(data)
        self.assertTrue(p["candidate_clear"])
        self.assertFalse(p["actionable"])
        self.assertEqual(p["reason"], "not-actionable:no-atomic-boundary")
        self.assertFalse(p["runtime"]["reclaim"]["eligible"])
        self.assertEqual(data,original)

    def test_long_tool_ci_attention_stop_and_merged_background(self):
        for state in ("active","ask","approval","interrupted","unknown"):
            d=fixture(); d["runtime"]["runtime"]["state"]=state
            self.assertIn("runtime",self.proof(d)["retained"])
        cases=dict(pending_tool=dict(code=0, reason="pending"), loop=["scheduled"],
                   children=[dict(outcome="unknown")], processes=dict(complete=True,pending=[42],unknown=[],fingerprint="tree2"),
                   delivery=["inflight"], transfer=["held"], migration=["lease"], wake=["reserved"],
                   worktree=dict(clean=False,unpushed=False), report=dict(disposition="progress"),
                   draft="unsent",outbox=["unacked"],policy=dict(value="keep",satisfied=True), grace=dict(deadline=104.))
        for name,value in cases.items():
            d=fixture(); d["layers"][name]["value"]=value
            with self.subTest(name=name): self.assertIn(name,self.proof(d)["retained"])

    def test_missing_stale_remote_malformed_and_old_mod_retain(self):
        for name in shadow.DIMENSIONS:
            d=fixture(); del d["layers"][name]
            self.assertIn(name,self.proof(d)["retained"])
            d=fixture(); d["layers"][name]["expires_at"]=100.5
            p=self.proof(d); self.assertEqual(p["dimensions"][name]["observed_at"],100.)
            self.assertEqual(p["dimensions"][name]["reason"],"expired")
            self.assertEqual(p["dimensions"][name]["last_known"],d["layers"][name]["value"])
        for value in (None,[],True,dict(version=99),dict(identity={})):
            d=fixture(); d["layers"]["processes"]=value
            self.assertIn("processes",self.proof(d)["retained"])

    def test_blocker_resolution_does_not_clear_attention(self):
        d=fixture(); t=d["layers"]["task"]["value"]
        scope=dict(task="T1",owner="alice",repo="",ticket_ref="",generation=1,worker_id=C["worker_id"])
        item=dict(scope=scope,blocker_id="dependency",state="active")
        t["task_blockers"]["items"]=[item]
        self.assertIn("blockers",self.proof(d)["retained"])
        item["state"]="resolved";d["runtime"]["runtime"]["state"]="approval"
        p=self.proof(d);self.assertNotIn("blockers",p["retained"]);self.assertIn("runtime",p["retained"])

    def test_recheck_turn_process_and_lease_races(self):
        old=self.proof()
        for name in ("turn", "processes", "transfer", "wake"):
            d=fixture()
            if name=="turn": d["runtime"]["identity"]["turn_id"]="t2"
            elif name=="processes": d["layers"][name]["value"]["fingerprint"]="new-tree"
            else: d["layers"][name]["value"]=["new-lease"]
            p=shadow.recheck(old,d,now=102.)
            self.assertFalse(p["previous_valid"],name);self.assertFalse(p["actionable"])
        self.assertFalse(shadow.recheck(old,fixture(),now=106.)["previous_valid"])
        p=shadow.recheck(old,fixture(),now=102.)
        self.assertTrue(p["previous_valid"]);self.assertFalse(p["actionable"])
        d=fixture();d["legacy"]["expires_at"]=102.
        self.assertFalse(shadow.recheck(self.proof(d),d,now=103.)["previous_valid"])
        disconnected=fixture();del disconnected["layers"]["processes"]
        p=shadow.recheck(old,disconnected,now=102.)
        self.assertIn("processes",p["retained"])
        self.assertEqual(p["dimensions"]["processes"]["previous_evidence"]["observed_at"],100.)

    def test_legacy_comparison_requires_same_exact_identity(self):
        d=fixture();d["layers"]["draft"]["value"]="unsent"
        self.assertEqual(self.proof(d)["comparison"],"legacy-clear_candidate-retain")
        for key in I:
            d=fixture();d["legacy"]["identity"][key]="changed"
            self.assertEqual(self.proof(d)["comparison"],"incomparable")

    def test_identity_types_and_source_times(self):
        d=fixture();d["layers"]["loop"]["identity"]["generation"]=True
        self.assertIn("loop",self.proof(d)["retained"])
        d=fixture();d["runtime"]["version"]=99
        p=self.proof(d)
        self.assertEqual(p["dimensions"]["runtime"]["observed_at"],100.)
        self.assertIn("runtime",p["retained"])
        d=fixture();d["layers"]["task"]["value"]["id"]="T2"
        self.assertIn("blockers",self.proof(d)["retained"])
        for key in ("operation_id","attempt_id"):
            d=fixture();d["layers"]["task"]["value"][key]="foreign"
            self.assertIn("task",self.proof(d)["retained"])
        d=fixture();d["layers"]["report"]["value"]["outcome"]="failed"
        self.assertIn("report",self.proof(d)["retained"])
        old=self.proof();self.assertFalse(shadow.recheck(old,fixture(),now=99.)["previous_valid"])

    def test_real_c6_database_reader_does_not_ack_or_expire(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"state.sqlite3"
            with sqlite3.connect(path) as db:
                db.execute("CREATE TABLE operations (action,request,result,status,updated)")
                payload=fixture()["layers"]["report"]["value"]
                db.execute("INSERT INTO operations VALUES (?,?,?,?,?)",("task_receipt",
                    json.dumps(dict(scope="scope",action="report",task="T1",payload=payload)),
                    json.dumps(dict(receipt=dict(disposition="committed"))),"committed",50.))
            before=path.read_bytes()
            with mock.patch.object(shadow.time,"time",return_value=100.):
                evidence=shadow.report_reader(path,"scope")(I)
            self.assertEqual(evidence["evidence_at"],50.)
            d=fixture();d["layers"]["report"]=evidence
            self.assertNotIn("report",self.proof(d)["retained"])
            self.assertEqual(path.read_bytes(),before)
            wrong=shadow.report_reader(path,"other-hub")(I)
            self.assertTrue(wrong["unknown"])

    def test_read_reuses_oracle_and_retains_missing_adapters(self):
        d=fixture()
        with mock.patch.object(shadow.runtime,"read",return_value=d["runtime"]) as native, \
             mock.patch("fleet_reap_shadow_local.LocalSources",side_effect=ValueError("unknown local source")), \
             mock.patch.object(shadow.pending,"read_panes",return_value=[]) as panes, \
             mock.patch.object(shadow.pending,"observe",side_effect=lambda reader: reader()) as oracle, \
             mock.patch.object(shadow,"raw_call",return_value={}), \
             mock.patch.object(shadow.time,"time",return_value=101.):
            p=shadow.read("%42",socket="isolated")
        self.assertEqual(native.call_count,2);oracle.assert_called_once();panes.assert_called_once_with("isolated")
        self.assertIn("processes",p["retained"]);self.assertIn("report",p["retained"])
        self.assertEqual(p["comparison"],"incomparable")

    def test_isolated_socket_real_child_invalidates_proof(self):
        # Kernel/process integration, explicitly NOT a Claude/Codex native test.
        # The only process table implementation is #4474's shared Processes.
        with tempfile.TemporaryDirectory(prefix="reap-shadow-") as tmp:
            root=Path(tmp); sock=str(root/"tmux.sock")
            env=dict(os.environ,HOME=tmp,TMUX="",TMUX_PANE="")
            tm=["tmux","-S",sock]
            pid=None; pids=[]
            try:
                subprocess.run(tm+["-f","/dev/null","new-session","-d","-s","isolated","sleep 30"],env=env,check=True)
                pid=int(subprocess.check_output(tm+["display-message","-p","-t","isolated:","#{pane_pid}"],env=env,text=True))
                table=shadow.pending.Processes.collect()
                proof=table.proof(pid)
                d=fixture(); d["layers"]["processes"]["value"]["fingerprint"]=shadow.digest(proof)
                old=self.proof(d)
                # Start a real child of this isolated server, never a live pane.
                subprocess.run(tm+["new-window","-d","-t","isolated:","sleep 30"],env=env,check=True)
                pids=list(map(int,subprocess.check_output(tm+["list-panes","-a","-F","#{pane_pid}"],env=env,text=True).split()))
                table=shadow.pending.Processes.collect()
                d["layers"]["processes"]["value"].update(pending=pids,fingerprint=shadow.digest([table.proof(p) for p in pids]))
                current=shadow.recheck(old,d,now=102.)
                self.assertFalse(current["previous_valid"]);self.assertIn("processes",current["retained"])
            finally:
                subprocess.run(tm+["kill-server"],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            # No forgotten server/child; completion is evidence, not just a trap.
            for child in set(pids + ([pid] if pid else [])):
                deadline=time.monotonic()+3
                while time.monotonic()<deadline:
                    try: os.kill(child,0)
                    except ProcessLookupError: break
                    time.sleep(.05)
                with self.assertRaises(ProcessLookupError): os.kill(child,0)
            self.assertNotEqual(subprocess.run(tm+["list-sessions"],env=env,capture_output=True).returncode,0)

    def test_local_owners_and_real_legacy_dry_run(self):
        from fleet_reap_shadow_local import LocalSources
        with tempfile.TemporaryDirectory(prefix="shadow-owners-") as tmp:
            root=Path(tmp).resolve();main=root/"base";wt=root/"work-scratch-999"
            session="scratch-shadow-"+uuid.uuid4().hex[:8];tm=["tmux","-L",session]
            env={k:os.environ[k] for k in ("PATH","LANG","TERM","SHELL","TMPDIR") if k in os.environ}
            env.update(HOME=str(root),FLEET_CONF_DIR=str(root/"conf"),TMUX="",TMUX_PANE="")
            def command(*args):
                return subprocess.check_output(args,env=env,text=True,stderr=subprocess.PIPE).strip()
            command("git","init","-b","master",str(main))
            command("git","-C",str(main),"config","user.name","Fixture")
            command("git","-C",str(main),"config","user.email","fixture@example.invalid")
            (main/"tracked").write_text("clean\n")
            command("git","-C",str(main),"add","tracked");command("git","-C",str(main),"commit","-m","fixture")
            command("git","-C",str(main),"update-ref","refs/remotes/origin/master","HEAD")
            command("git","-C",str(main),"worktree","add","-b","scratch-999",str(wt))
            command("git","-C",str(wt),"config","branch.scratch-999.remote",".")
            command("git","-C",str(wt),"config","branch.scratch-999.merge","refs/heads/master")
            conf=root/"conf";directory=conf/"fleets"/session;directory.mkdir(parents=True)
            (directory/"conf").write_text("FLEET_REPO=fixture/reap\nFLEET_MAIN="+shlex.quote(str(main))+"\nFLEET_BASE_BRANCH=master\nFLEET_FORGE=none\n")
            (conf/"rotating").mkdir();(conf/"control/hub-outbox").mkdir(parents=True)
            try:
                command(*tm,"-f","/dev/null","new-session","-d","-s",session,"sleep 30")
                pane=command(*tm,"display-message","-p","-t",session+":","#{pane_id}")
                for key,value in {"@repo":"fixture/reap","@raw":"1","@worktree":str(wt),"@reap_policy":"keep",
                                  "@fleet_id":C["worker_id"].split("/")[1],"@claude_state":"done","@claude_state_ts":str(int(time.time())-1000)}.items():
                    command(*tm,"set-option","-w","-t",pane,key,value)
                with mock.patch.dict(os.environ,env,clear=True):
                    local=LocalSources(pane,session)
                    local.identity=I;local.config=local.config_read()
                    self.assertEqual(local.worktree()["unpushed"],False)
                    (wt/"tracked").write_text("dirty\n")
                    self.assertFalse(local.worktree()["clean"])
                    self.assertEqual(local.leases()["transfer"],[])
                    command(*tm,"set-option","-w","-t",pane,"@migrating","fixture")
                    local=LocalSources(pane,session);local.identity=I;local.config=local.config_read()
                    self.assertEqual(local.leases()["migration"],["fixture"])
                    # A direct owner result, not a caller-invented bool. Keep is
                    # the actual old path's retained decision without any writes.
                    local.values={}
                    options=command(*tm,"show-options","-w","-t",pane)
                    gate=local.legacy(I)
                    self.assertFalse(gate["value"]["eligible"])
                    self.assertIn("Cleaner.candidate",gate["source"])
                    self.assertEqual(command(*tm,"show-options","-w","-t",pane),options)
            finally:
                subprocess.run(tm+["kill-server"],env=env,capture_output=True)


if __name__ == "__main__": unittest.main()
