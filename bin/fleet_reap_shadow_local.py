#!/usr/bin/env python3
"""One-shot adapters to existing local owners; never a lifecycle controller."""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import time

import fleet_launch as launch
import fleet_loop_mark as loopmark
import fleet_pending_tool as pending
import fleet_reap_policy as policy
import fleet_reap_shadow as proof

BIN = Path(__file__).absolute().parent
FIELDS = ("window_id", "@fleet_id", "@worktree", "@repo", "@norepo", "@cc_agent",
          "@loop", "@handoff_manifest", "@handoff_armed", "@agent_transfer_request",
          "@agent_transfer_until", "@migrating", "@worker_lifecycle", "@sleep_record",
          "@sleep_wake_deferred", "@reap_policy", "@claude_state_ts", "@reap_due",
          "@reap_seen", "@reap_state_ts", "@reap_key", "@reap_hold", "pane_pid")
ERRORS = (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError)


class LocalSources:
    def __init__(self, pane, socket, pr=None):
        self.pane, self.socket, self.pr = pane, socket, pr
        self.values = None
        self.conf = Path(os.environ.get("FLEET_CONF_DIR", Path.home()/".config/claude-fleet"))
        self.life = runpy.run_path(str(BIN/"fleet_worker_life.py"))
        self.clean = runpy.run_path(str(BIN/"fleet-cleanup-idle.py"))
        self.meta = self.snapshot()
        self.session = launch.option(pane, "?#{session_group},#{session_group},#{session_name}", socket)
        # Existing owner CLIs use named sockets. Do not silently redirect an
        # absolute socket or grouped view to another tmux server.
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", self.session) or (socket and socket != self.session):
            raise ValueError("local_owner_requires_matching_named_socket")
        self.env = dict(os.environ, TMUX="", TMUX_PANE="", FLEET_SESSION=self.session)
        self.identity = None
        self.config = None

    def shell(self, script, *args):
        return subprocess.check_output(["bash", "-c", '. "$1/fleet-lib.sh"; '+script,
            "shadow", str(BIN), *args], env=self.env, text=True, stderr=subprocess.PIPE, timeout=8).strip()

    def snapshot(self):
        text = launch.tmux("display-message", "-p", "-t", self.pane,
            "\x1f".join("#{"+k+"}" for k in FIELDS), socket=self.socket)
        values = text.split("\x1f")
        if len(values) != len(FIELDS):
            # tmux <=3.4 vis-escapes control separators; same bounded fallback
            # as Cleaner.snapshot. The end-of-collection comparison still fences
            # any field that changed during these individual reads.
            return {key:launch.option(self.pane,key,self.socket) for key in FIELDS}
        return dict(zip(FIELDS,values))

    def envelope(self, source, value, at, **kw):
        return dict(version=1, identity=self.identity, source=source, value=value,
                    observed_at=at, expires_at=at+proof.TTL, **kw)

    def config_read(self):
        if not self.meta["@repo"]:
            raise ValueError("missing_repository_stamp")  # resolver's legacy fallback would stamp it
        text = self.shell('fleet_load_conf "$2"; r=$(fleet_window_repo "$2" "$3") || exit 1; '
            'fleet_load_repo_conf "$2" "$r" || exit 1; '
            'printf "%s\\037%s\\037%s\\037%s" "$r" "$FLEET_MAIN" "${FLEET_BASE_BRANCH:-master}" "${FLEET_FORGE:-github}"',
            self.session, self.meta["window_id"])
        repo, main, base, forge = text.split("\x1f")
        if not repo or not Path(main).is_dir() or forge not in ("github","none"):
            raise ValueError("unknown_repository_binding")
        return dict(repo=repo,main=main,base=base,forge=forge)

    def worktree(self):
        wt = self.meta["@worktree"]
        if not wt or not self.config:
            raise ValueError("missing_worktree_binding")
        def git(*args):
            return subprocess.check_output(["git","-C",wt,*args],text=True,stderr=subprocess.PIPE,timeout=3).strip()
        registered = subprocess.check_output(["git","-C",self.config["main"],"worktree","list","--porcelain"],text=True,timeout=3)
        if "worktree "+wt not in registered.splitlines():
            raise ValueError("unregistered_worktree")
        head = git("rev-parse","HEAD")
        status = git("status","--porcelain")
        # No fetch; a missing upstream is unknown, not 'pushed'. Original refs
        # are included so a changed commit invalidates an earlier observation.
        upstream = git("rev-parse","@{upstream}")
        count = git("rev-list","--count",upstream+"..HEAD")
        if git("rev-parse","HEAD") != head:
            raise ValueError("worktree_changed")
        return dict(clean=not status, unpushed=int(count)>0, head=head, upstream=upstream,
                    status_digest=proof.digest(status))

    def processes(self):
        i = self.identity
        if not proof.complete(i):
            raise ValueError("missing_native_identity")
        table = pending.Processes.collect()  # #4474's only process-table reader
        source = dict(agent=i["provider"],pid=i["pid"],session_id=i["native_session"],
                      worktree=self.meta["@worktree"],codex_identity={})
        if i["provider"] == "codex":
            data = self.life["CODEX"]["identity"](self.pane,self.socket)
            if data.get("session_id") != i["native_session"] or data.get("remote") != i.get("native_remote"):
                raise ValueError("codex_source_changed")
            source.update(pid=int(data["owner"]),codex_identity=data,home=data["home"])
        table.ancestry(i["pid"],source["pid"])
        table.ancestry(source["pid"],int(self.meta["pane_pid"]))
        rows = {pid:(r["ppid"],Path(r["comm"]).name.lstrip("-")) for pid,r in table.rows.items() if 'Z' not in r["state"]}
        # Dependency injection into a private module instance: reuse #4318's
        # classifier verbatim with #4474's table. No second ps implementation.
        self.life["TRANSFER"]["process_rows"] = lambda: rows
        background=[]
        # Codex's non-strict mode has exact configured-helper classification;
        # Claude's strict mode retains unknown children rather than skipping them.
        self.life["quiet_processes"](source,background=background,strict=i["provider"]=="claude")
        tree=self.tree(table,source["pid"])
        return dict(complete=True,pending=background,unknown=[],tree=tree,fingerprint=proof.digest(tree))

    @staticmethod
    def tree(table,root):
        todo=[root]; seen=set(); tree=[]
        while todo:
            pid=todo.pop()
            if pid in seen: continue
            seen.add(pid);tree.append(table.proof(pid));todo.extend(table.kids[pid])
        return tree

    def leases(self):
        # The owner's path resolver mkdir -p's its directory. Require that it
        # already exists so an observation never creates lifecycle state.
        if not (self.conf/"rotating").is_dir():
            raise ValueError("rotation_store_unavailable")
        lease = Path(self.shell('fleet_rotate_lease_file "$2"',self.meta["@worktree"]))
        raw=lease.read_text() if lease.exists() else ""
        held=self.shell('if fleet_rotate_lease_held "$2"; then :; else r=$?; [ "$r" = 1 ] || exit "$r"; fi',self.meta["@worktree"])
        # Legacy fails open on malformed leases; shadow keeps the raw evidence.
        if raw and not re.fullmatch(r"\d+ \d+ \d+(?: [^\n]*)?\n?",raw):
            raise ValueError("malformed_rotation_lease")
        transfer=[v for v in (held,self.meta["@handoff_armed"],self.meta["@agent_transfer_request"]) if v]
        until=self.meta["@agent_transfer_until"]
        if until and (not until.isdigit() or int(until)>time.time()): transfer.append(until)
        if Path(str(lease)+".transfer-lock").exists(): transfer.append("transition-lock")
        return dict(transfer=transfer,migration=[v for v in (held,self.meta["@migrating"]) if v],
                    raw=raw)

    def outbox(self):
        directory=Path(self.shell('fleet_hub_outbox'))
        if not directory.is_dir(): raise ValueError("outbox_unavailable")
        result=[];count=0
        for folder in (directory,directory/"refused"):
            if not folder.exists(): continue
            with os.scandir(folder) as entries:
                for entry in entries:
                    count+=1
                    if count>1000: raise ValueError("outbox_observation_budget_exceeded")
                    if not entry.name.endswith(".json"): continue
                    with open(entry.path,"rb") as stream: text=stream.read(65537)
                    if len(text)>65536: raise ValueError("outbox_record_budget_exceeded")
                    data=json.loads(text)
                    if data.get("from")==self.identity.get("worker_id"):
                        result.append(dict(id=data.get("id"),kind=data.get("kind"),digest=proof.digest(data)))
        return sorted(result,key=proof.digest)

    @staticmethod
    def inbox_names(directory):
        result=[]
        with os.scandir(directory) as entries:
            for count,entry in enumerate(entries,1):
                if count>1000: raise ValueError("inbox_observation_budget_exceeded")
                if entry.name.endswith(".json"): result.append(entry.name)
        return sorted(result)

    def collect(self, identity):
        if self.values is not None:
            if not proof.exact(identity,self.identity): raise ValueError("collection_identity_changed")
            return
        self.identity=identity;self.values={}
        before=self.snapshot()
        if before!=self.meta: raise ValueError("local_binding_changed")
        try: self.config=self.config_read()
        except ERRORS: self.config=None
        def take(name, source, fn):
            at=time.time()
            try: self.values[name]=self.envelope(source,fn(),at)
            except ERRORS as exc:
                self.values[name]=self.envelope(source,None,at,unknown=True,reason=type(exc).__name__+":source_unavailable")
        take("worktree","git:registered-worktree",self.worktree)
        take("processes","fleet_worker_life.quiet_processes/fleet_pending_tool.Processes",self.processes)
        take("loop","fleet_loop_mark.status",lambda: [] if loopmark.status(
            self.meta["@loop"],self.meta["@handoff_manifest"])[0]=="none" else [self.meta["@loop"] or self.meta["@handoff_manifest"]])
        at=time.time()
        try:
            leases=self.leases()
            for name in ("transfer","migration"):
                self.values[name]=self.envelope("fleet_rotate_lease_held+window-markers",leases[name],at,
                                                raw_evidence=leases["raw"])
        except ERRORS:
            for name in ("transfer","migration"):
                self.values[name]=self.envelope("fleet_rotate_lease_held",None,at,unknown=True,reason="lease_source_unavailable")
        def wake():
            value=[v for v in (self.meta["@worker_lifecycle"],self.meta["@sleep_wake_deferred"]) if v]
            lock=self.life["root"](self.session)/("window-"+self.meta["window_id"][1:]+".lock")
            if lock.exists():
                with lock.open("rb") as stream:
                    try: fcntl.flock(stream,fcntl.LOCK_SH|fcntl.LOCK_NB)
                    except BlockingIOError: value.append("sleep-wake-delivery-lock-held")
            record=self.meta["@sleep_record"]
            if record:
                data=json.loads(Path(record).read_text())
                value.append(dict(state=data.get("state"),digest=proof.digest(data)))
            return value
        take("wake","fleet-sleep:phase-record",wake)
        def draft():
            data=self.life["INPUT"]["snapshot"](self.socket,self.pane,agent=self.meta["@cc_agent"])
            if data.get("state")!="empty": raise ValueError("draft_or_unknown")
            return ""
        take("draft","fleet-input.snapshot",draft)
        take("outbox","fleet_hub_outbox",self.outbox)
        at=time.time();pol=policy.parse(self.meta["@reap_policy"])
        deadline=None
        if pol and pol[0] in ("done","loop-end","at") and self.meta["@claude_state_ts"].isdigit():
            deadline=self.clean["Cleaner"].deadline(None,self.meta,pol)
        self.values["policy"]=self.envelope("fleet_reap_policy.parse",dict(value=self.meta["@reap_policy"],
            satisfied=deadline is not None and deadline<=at),at)
        if deadline is not None:
            try:
                tm=lambda *args:launch.tmux(*args,socket=self.socket)
                deadline=self.clean["notice"](tm,self.meta["window_id"],self.meta["@reap_key"],deadline,now=at,dry=True)
            except ERRORS: deadline=None
        self.values["grace"]=self.envelope("Cleaner.deadline+reap-notice",dict(deadline=deadline,
            notice=self.meta["@reap_due"],seen=self.meta["@reap_seen"]),at,unknown=deadline is None)
        # C6's authority resolution is the existing credential reader. Only its
        # hash enters this adapter, never a token, URL or replacement authority.
        take("report","C6:task_receipt",lambda: None)
        try:
            authority=subprocess.check_output(["bash",str(BIN/"fleet-task-record.sh"),"authority"],env=self.env,text=True,stderr=subprocess.PIPE,timeout=3).strip()
            scope=hashlib.sha256(authority.rstrip("/").encode()).hexdigest()
            self.values["report"]=proof.report_reader(self.conf/"control/state.sqlite3",scope)(identity)
        except (*ERRORS, proof.sqlite3.Error): pass
        # Local delivery inbox evidence is useful but not #4431's acceptance ACK.
        take("delivery","fleet_worker_life.inbox",lambda: self.inbox_names(self.life["Worker"](self.session,self.pane).inbox()))
        self.values["delivery"].update(unknown=True,reason="controller_acceptance_unavailable")
        observed=self.values["processes"]
        if isinstance(observed["value"],dict) and observed["value"].get("tree"):
            try:
                latest=self.tree(pending.Processes.collect(),observed["value"]["tree"][0]["pid"])
                if not proof.exact(latest,observed["value"]["tree"]):
                    observed.update(unknown=True,reason="process_tree_changed_during_collection")
            except ERRORS:
                observed.update(unknown=True,reason="process_tree_recheck_unavailable")
        if self.snapshot()!=before:
            for value in self.values.values(): value.update(unknown=True,reason="local_sources_changed_during_collection")

    def reader(self,name):
        def read(identity):
            self.collect(identity)
            return self.values[name]
        return read

    def legacy(self,identity):
        self.collect(identity);at=time.time()
        if not self.config: raise ValueError("missing_repository_binding")
        if not (self.conf/"rotating").is_dir(): raise ValueError("rotation_store_unavailable")
        if self.pr is not None:
            result=subprocess.run(["bash",str(BIN/"fleet-cleanup.sh"),str(self.pr),"--repo",self.config["repo"],"--auto","--dry-run"],
                env=self.env,cwd=self.config["main"],text=True,capture_output=True,timeout=15)
            token=result.stdout.strip()
            if result.returncode or not token.startswith(("skip:","dry:")): raise ValueError("legacy_gate_unavailable")
            eligible=token in ("dry:would-clean-merged","dry:would-reap-closed")
            source="fleet-cleanup.sh --auto --dry-run"
        else:
            args=dict(**self.config,session=self.session,socket_name=self.socket or self.session,
                dry_run=True,policy_only=False,window_repo=True)
            # Use the daemon's cwd/environment, not the observer's worker cwd:
            # candidate() deliberately refuses to close its own calling pane.
            script='''import json,runpy,sys,os,subprocess
from types import SimpleNamespace
sys.path.insert(0,os.path.dirname(sys.argv[1]))
m=runpy.run_path(sys.argv[1])
try:
    m["Cleaner"](SimpleNamespace(**json.loads(sys.argv[2]))).candidate(sys.argv[3])
except (OSError,ValueError,subprocess.SubprocessError,m["RateLimited"]) as exc:
    # Cleaner.main's existing policy: a failed source defers this candidate.
    detail=getattr(exc,"stdout",None) or getattr(exc,"stderr",None) or ""
    if isinstance(detail,bytes): detail=detail.decode(errors="replace")
    print("legacy-deferred:"+type(exc).__name__+":"+detail.strip()[:300])
'''
            result=subprocess.run(["python3","-c",script,str(BIN/"fleet-cleanup-idle.py"),json.dumps(args),self.meta["window_id"]],
                env=self.env,cwd=self.config["main"],text=True,capture_output=True,timeout=15)
            if result.returncode: raise ValueError("legacy_gate_unavailable")
            token=result.stdout.strip()
            eligible=any(line.startswith(("would-reap-","would-clean:done-no-pr")) for line in token.splitlines())
            source="Cleaner.candidate(dry_run=True)"
        return self.envelope(source,dict(eligible=eligible,reason=token or "legacy-retained",phase="pre-action-dry-run",
            unobserved_final_gates=["history-record/resume-verification","final-native-and-lease-recheck","atomic-action-boundary"]),at,
            unknown=self.snapshot()!=self.meta,reason="local_binding_changed")

    def readers(self):
        return {name:self.reader(name) for name in ("worktree","processes","loop","transfer","migration",
            "wake","draft","outbox","policy","grace","report","delivery")}
