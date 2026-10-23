"""One bounded native Subagent sample for the existing opt-in cycle harness.

No model/runtime starts here. The owning Probe supplies its existing private
runtime, owner stop, receipt and finally. This is not a production controller.
"""
import hashlib
import json
import os
from pathlib import Path
import runpy
import shlex
import signal
import sys
import time
import uuid


class SampleRefused(RuntimeError):
    pass


def spawned_child(root_sid, turns):
    calls = [item for turn in turns for item in turn.get('items', [])
             if item.get('type') == 'collabAgentToolCall' and item.get('tool') == 'spawnAgent']
    if not calls:
        return None
    if len(calls) != 1:
        raise SampleRefused('sample requires exactly one native spawn')
    call = calls[0]
    if call.get('status') == 'inProgress':
        return None
    ids = call.get('receiverThreadIds', [])
    if (call.get('status') != 'completed' or call.get('senderThreadId') != root_sid
            or len(ids) != 1 or ids[0] == root_sid):
        raise SampleRefused('native spawn identity not confirmed')
    if str(uuid.UUID(ids[0])) != ids[0]:
        raise SampleRefused('native child ID is not canonical')
    return ids[0]


def running_tool(root_sid, child_sid, child, turns, script, ready_line):
    if child.get('id') != child_sid or child.get('parentThreadId') != root_sid:
        raise SampleRefused('native child does not belong to this root')
    if child.get('status', {}).get('type') != 'active':
        return None
    for turn in turns:
        if turn.get('status') != 'inProgress':
            continue
        for item in turn.get('items', []):
            if (item.get('type') == 'commandExecution' and item.get('status') == 'inProgress'
                    and str(script) in item.get('command', '')
                    and ready_line in (item.get('aggregatedOutput') or '').splitlines()):
                return dict(turn_id=turn['id'], item_id=item['id'], native_process_id=item.get('processId'))
    return None


class SubagentSample:
    def __init__(self, probe):
        self.probe = probe
        self.script = probe.root / 'subagent-sleep.py'
        self.ready = probe.root / 'subagent-ready.json'
        self.finished = probe.root / 'subagent-finished'
        self.nonce = uuid.uuid4().hex
        self.observed = None
        self.stop_at = None

    def prompt(self):
        if self.script.exists():
            raise SampleRefused('subagent prompt is one-shot')
        self.script.write_text(
            'import json,os,time\nfrom pathlib import Path\n'
            'row={"nonce":%r,"pid":os.getpid()}\n' % self.nonce +
            'text=json.dumps(row,sort_keys=True)\n'
            'with Path(%r).open("x") as output: output.write(text)\n' % str(self.ready) +
            'print("T970_SUBAGENT_READY "+text,flush=True)\n'
            'time.sleep(90)\n'
            'with Path(%r).open("x") as output: output.write(%r)\n' % (str(self.finished), self.nonce))
        self.script_hash = hashlib.sha256(self.script.read_bytes()).hexdigest()
        command = shlex.join([sys.executable, str(self.script)])
        return ('This is a bounded isolated native Subagent acceptance. Explicitly spawn exactly ONE ordinary '
                'Subagent, inheriting your model. Its only work: execute the following exact command in the '
                'foreground and wait for it to finish; do not inspect or modify its script, do not fork, '
                'daemonize, use MCP/network, or delegate further. It sleeps for 90 seconds without CPU work. '
                'Child must make no other tool calls except waiting for this command. Command: ' + command +
                '\nYou, the root, must use native wait for that child; do not run its command yourself, '
                'do not close or interrupt it, and do not return a final answer before it finishes. '
                'An external fixture will stop this Task. Do not create Teams, services, files or other work.')

    def discover(self, ref):
        p = self.probe
        if self.observed:
            return dict(ready=True, **self.observed)
        facts = p.observe(ref)
        history = facts.get('history', {})
        if not history.get('readable') or facts.get('components') != ['client', 'server']:
            return dict(ready=False)
        snap = facts['snapshot']
        fid = snap['execution_owner'].split('/')[1]
        rows = p.tmux('list-panes', '-a', '-F', '#{@fleet_id}\t#{pane_id}').splitlines()
        panes = [row.split('\t')[1] for row in rows if row.split('\t')[0] == fid]
        if len(panes) != 1:
            raise SampleRefused('sample pane identity unavailable')
        identify = runpy.run_path(str(p.bin / 'fleet-codex-session.py'))['identity']
        identity = identify(panes[0], p.socket)
        if not identity:
            return dict(ready=False)
        if identity.get('session_id') != history['sid'] or Path(identity['home']).resolve() != p.codex:
            raise SampleRefused('sample native runtime identity changed')
        launch = p.control.execution.launch(ref)
        roots = {item['component']: item['process'] for item in launch['native']}
        from fleet_task_execution import _kernel_process
        from fleet_native_proc import descendant
        for proof in roots.values():
            if _kernel_process(proof['pid']) != proof:
                raise SampleRefused('native root PID/birth changed')
        rpc = runpy.run_path(str(p.bin / 'fleet-codex-rpc.py'))['Client']
        client = rpc(identity['remote'], timeout=5, peer_pid=roots['server']['pid'])
        try:
            root_sid = history['sid']
            root = client.call('thread/read', dict(threadId=root_sid, includeTurns=False))['thread']
            turns = client.call('thread/turns/list', dict(threadId=root_sid, limit=20,
                                sortDirection='desc', itemsView='full')).get('data', [])
            child_sid = spawned_child(root_sid, turns)
            if not child_sid or not self.ready.exists():
                return dict(ready=False)
            if root.get('id') != root_sid:
                raise SampleRefused('root native thread identity changed')
            waiting = any(turn.get('status') == 'inProgress' and any(
                item.get('type') == 'collabAgentToolCall' and item.get('tool') == 'wait'
                and item.get('status') == 'inProgress' and item.get('senderThreadId') == root_sid
                and item.get('receiverThreadIds') == [child_sid]
                for item in turn.get('items', [])) for turn in turns)
            if root.get('status', {}).get('type') != 'active' or not waiting:
                return dict(ready=False)
            child = client.call('thread/read', dict(threadId=child_sid, includeTurns=False))['thread']
            child_turns = client.call('thread/turns/list', dict(threadId=child_sid, limit=20,
                                      sortDirection='desc', itemsView='full')).get('data', [])
            if self.ready.is_symlink() or self.script.is_symlink():
                raise SampleRefused('bounded helper files changed identity')
            try:
                marker = json.loads(self.ready.read_text())
            except json.JSONDecodeError:
                return dict(ready=False)  # writer has not closed its ready file
            if (set(marker) != {'nonce', 'pid'} or marker['nonce'] != self.nonce
                    or type(marker['pid']) is not int or marker['pid'] <= 1
                    or hashlib.sha256(self.script.read_bytes()).hexdigest() != self.script_hash):
                raise SampleRefused('bounded helper identity changed')
            tool = running_tool(root_sid, child_sid, child, child_turns, self.script,
                                'T970_SUBAGENT_READY ' + json.dumps(marker, sort_keys=True))
            if tool is None:
                return dict(ready=False)
            process = _kernel_process(marker['pid'])
            if not descendant(process['pid'], roots['server']['pid']) or self.finished.exists():
                raise SampleRefused('child tool is not a live descendant of the owned server')
            transcript = Path(child.get('path') or '').resolve(strict=True)
            if not transcript.is_relative_to(p.root):
                raise SampleRefused('child transcript escaped fixture')
            with transcript.open() as stream:
                meta = json.loads(stream.readline())
            if meta.get('type') != 'session_meta' or meta.get('payload', {}).get('id') != child_sid:
                raise SampleRefused('child transcript identity mismatch')
            self.observed = dict(task=ref, operation_id=snap['operation_id'], root_sid=root_sid,
                                 child_sid=child_sid, child_parent=child['parentThreadId'], tool=tool,
                                 tool_process=process, native_roots=roots, child_transcript=str(transcript),
                                 observe_until=time.monotonic() + 95)
            p.manifest['subagent'] = dict(self.observed, exact_child_ownership=True)
            p.save()
            return dict(ready=True, **self.observed)
        finally:
            client.close()

    def before_stop(self, ref):
        from fleet_task_execution import _kernel_process
        if not self.observed or self.observed['task'] != ref or self.stop_at is not None:
            raise SampleRefused('subagent stop requires one observed owned sample')
        proof = self.observed['tool_process']
        if _kernel_process(proof['pid']) != proof or self.finished.exists():
            raise SampleRefused('child tool ended before Task stop')
        self.stop_at = time.monotonic()
        return dict(child_running_before_stop=True)

    def after_stop(self, ref, stop):
        from fleet_task_execution import _session_root_exit_evidence
        if not self.observed or self.observed['task'] != ref or self.stop_at is None:
            raise SampleRefused('no observed child stop boundary')
        snapshot = self.probe.control.execution.read(ref)
        if snapshot['cancel_request'] != stop or snapshot['operation_id'] != self.observed['operation_id']:
            raise SampleRefused('stop does not target the observed child root')
        proof = self.observed['tool_process']
        exited = _session_root_exit_evidence(proof)
        roots = {name: _session_root_exit_evidence(root)
                 for name, root in self.observed['native_roots'].items()}
        result = dict(exact_child_ownership=True, tool_exit_evidence=exited,
                      native_root_exit_evidence=roots, finished_marker=self.finished.exists(),
                      observation_complete=time.monotonic() >= self.observed['observe_until'],
                      scope='observed ordinary child and its bounded foreground tool; not Teams/services')
        # Once the server is gone its cached "active" state is not liveness.
        # Preserve exact child history separately, without resuming that thread.
        transcript = Path(self.observed['child_transcript'])
        result['child_history_sha256'] = hashlib.sha256(transcript.read_bytes()).hexdigest()
        if exited and 'tool_exit_observed_seconds' not in self.probe.manifest['subagent']:
            self.probe.manifest['subagent']['tool_exit_observed_seconds'] = time.monotonic() - self.stop_at
        result['child_lifecycle_confirmed'] = bool(result['observation_complete'] and exited
                                                  and all(roots.values()) and not result['finished_marker'])
        self.probe.manifest['subagent'].update(result)
        self.probe.save()
        return result

    def cleanup(self):
        """Fallback only, after evidence: exact observed helper PID/birth."""
        from fleet_task_execution import _kernel_process, _session_root_exit_evidence
        if not self.observed:
            if self.ready.exists():
                raise SampleRefused('unobserved helper ownership; no process guessed')
            return False
        proof = self.observed['tool_process']
        if _session_root_exit_evidence(proof):
            return False
        if _kernel_process(proof['pid']) != proof:
            raise SampleRefused('helper birth changed before cleanup')
        os.kill(proof['pid'], signal.SIGKILL)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if _session_root_exit_evidence(proof):
                return True
            time.sleep(.02)
        raise SampleRefused('owned helper cleanup unconfirmed')
