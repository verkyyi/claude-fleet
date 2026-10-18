#!/usr/bin/env python3
"""One bounded C9 row on the owner's ORIGINAL inert test resources.

No creation, enrollment, deployment, task repair or delete operation is offered.
The owner prepares immutable artifacts and Pods through normal management, and
keeps the original create response privately. This driver binds fresh API reads,
attaches only to the fixed trusted entrypoints, then requires terminal Pods.
"""
import argparse
import copy
import hashlib
import json
import os
import re
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

from nogh_live_contract import (COUNTERS, Refused, ROLES, canonical, fingerprint, read_private,
                                require, validate, write_private, bind_observed)
from nogh_live_observer import PHASES, phase_timeout
from nogh_live_evidence import check as check_evidence, row_coverage
from nogh_live_render import admission, check_pod, render


# A control reply (guard, ready, marked, evidence) comes at once; a phase
# result waits for the broker's own bound on that phase (#4630: a fixed 5 s
# could not carry a real row or the hub's identity readiness).
REPLY_SECONDS = 5


def reply_seconds(expected, phase):
    return phase_timeout(phase) + REPLY_SECONDS if expected == 'result' else REPLY_SECONDS


def schedule(row):
    return list(PHASES[:PHASES.index('row:A1')]) + ['row:' + row] + \
        (['row:A4-denied', 'row:A4-restored'] if row == 'A4' else []) + ['end']


class Cluster:
    def __init__(self, config, deadline):
        require(Path(config).is_file() and not Path(config).is_symlink()
                and Path(config).stat().st_mode & 0o777 == 0o600, 'PRIVATE_KUBECONFIG_REQUIRED')
        self.prefix = ['kubectl', '--kubeconfig', str(Path(config).resolve()), '--request-timeout=2s']
        self.deadline = deadline

    def remaining(self, cap=2):
        left = min(cap, self.deadline - time.monotonic())
        require(left > 0, 'DEADLINE_EXCEEDED')
        return left

    def command(self, args, data=None):
        result = subprocess.run(self.prefix + args, input=data, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=self.remaining())
        require(result.returncode == 0 and len(result.stdout) <= 4 * 1024 * 1024, 'CLUSTER_READ_FAILED')
        return json.loads(result.stdout)

    def get(self, kind, name, namespace=None):
        args = ['get', kind, name, '-o', 'json']
        if namespace:
            args += ['--namespace', namespace]
        return self.command(args)

    def attach(self, plan, ep, container):
        return Channel(self.prefix + ['attach', ep['name'], '--namespace', plan['namespace'],
                       '--container', container, '--stdin', '--quiet', '--pod-running-timeout=2s'], self)


class Channel:
    def __init__(self, argv, cluster):
        self.cluster = cluster
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, close_fds=True)
        self.buffer = bytearray()
        self.total = 0

    def send(self, value):
        self.process.stdin.write(canonical(value) + b'\n')
        self.process.stdin.flush()

    def receive(self, expected, phase=None):
        while b'\n' not in self.buffer:
            ready, _, _ = select.select([self.process.stdout], [], [],
                                        self.cluster.remaining(reply_seconds(expected, phase)))
            require(ready, 'OBSERVER_CHANNEL_TIMEOUT')
            block = os.read(self.process.stdout.fileno(), 65536)
            require(block, 'OBSERVER_CHANNEL_EOF')
            self.total += len(block)
            require(self.total <= 4 * 1024 * 1024, 'OBSERVER_CHANNEL_LIMIT')
            self.buffer.extend(block)
        line, _, rest = self.buffer.partition(b'\n')
        self.buffer = bytearray(rest)
        value = json.loads(line)
        require(value.get('type') == expected and (phase is None or value.get('phase') == phase),
                'OBSERVER_CHANNEL_SEQUENCE')
        return value

    def close(self):
        if self.process.stdin and not self.process.stdin.closed:
            # A cancel sent to an observer that already finished leaves its
            # bytes buffered; closing flushes them into a gone pipe. That must
            # not escape `finally` and swallow the run's own refusal and its
            # receipt (live, #4625: A11 sealed, then BROKENPIPEERROR).
            try: self.process.stdin.close()
            except (BrokenPipeError, OSError): pass
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=0.1)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=0.1)


def same_resource(want, actual):
    require(actual.get('metadata', {}).get('uid') == want['metadata']['uid']
            and actual.get('metadata', {}).get('generation') == want['metadata'].get('generation')
            and actual.get('spec') == want.get('spec'), 'ADMISSION_CHANGED')
    if want['kind'] in ('ConfigMap', 'Secret'):
        require(actual.get('immutable') is True and actual['metadata'].get('resourceVersion') ==
                want['metadata']['resourceVersion'], 'ARTIFACT_CHANGED')


def prove_injection_denied(cluster, recipe, pod):
    """A live API denial while ONLY the inert guard is running, before bind."""
    result = subprocess.run(cluster.prefix + ['exec', pod['metadata']['name'], '--namespace', recipe['namespace'],
                            '--container', 'egress-guard', '--', '/usr/bin/true'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=cluster.remaining())
    require(result.returncode != 0 and len(result.stderr) < 65536
            and ('fleet-c9-' + recipe['run_id'] + '-exec').encode() in result.stderr
            and b'C9 forbids injected execution' in result.stderr, 'EXEC_ADMISSION_NOT_ENFORCED')
    candidate = copy.deepcopy(pod)
    candidate['spec']['ephemeralContainers'] = [dict(name='c9-denied-probe', image=pod['spec']['containers'][0]['image'],
                                                    command=['/usr/bin/true'])]
    path = '/api/v1/namespaces/%s/pods/%s/ephemeralcontainers?dryRun=All' % (recipe['namespace'], pod['metadata']['name'])
    result = subprocess.run(cluster.prefix + ['replace', '--raw', path, '-f', '-'], input=canonical(candidate),
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=cluster.remaining())
    require(result.returncode != 0 and len(result.stderr) < 65536
            and ('fleet-c9-' + recipe['run_id'] + '-pods').encode() in result.stderr
            and b'C9 forbids injected processes' in result.stderr, 'EPHEMERAL_ADMISSION_NOT_ENFORCED')


def preflight(cluster, recipe, created):
    validate(recipe, bound=False)
    require(created.get('kind') == 'List' and isinstance(created.get('items'), list), 'ORIGINAL_CREATE_RESPONSE')
    originals = {p['metadata']['name']: p for p in created['items'] if p.get('kind') == 'Pod'}
    require(set(originals) == {e['name'] for e in recipe['endpoints']}, 'ORIGINAL_CREATE_COVERAGE')
    who = cluster.command(['auth', 'whoami', '-o', 'json'])
    require(who.get('status', {}).get('userInfo', {}).get('username') == recipe['controller'], 'CONTROLLER_CHANGED')
    ns = cluster.get('namespace', recipe['namespace'])
    require(ns['metadata']['uid'] == recipe['namespace_uid'] and
            ns['metadata'].get('labels', {}).get('fleet/c9-purpose') == 'disposable-test', 'NAMESPACE_CHANGED')
    root = cluster.get('namespace', 'kube-system')
    require(root['metadata']['uid'] == recipe['cluster_uid'], 'CLUSTER_CHANGED')
    anchors = []
    for expected in admission(recipe):
        actual = cluster.get(expected['kind'], expected['metadata']['name'])
        require(actual.get('spec') == expected['spec'], 'ADMISSION_CONTRACT_MISSING')
        if expected['kind'] == 'ValidatingAdmissionPolicy':
            status = actual.get('status', {})
            require(status.get('observedGeneration') == actual['metadata']['generation'] and
                    isinstance(status.get('typeChecking'), dict) and
                    not status['typeChecking'].get('expressionWarnings'), 'ADMISSION_NOT_TYPECHECKED')
        anchors.append(actual)
    for ep in recipe['endpoints']:
        artifacts = [('ConfigMap', '-workload'), ('Secret', '-credentials'), ('Secret', '-control')]
        if ep['role'] == 'proxy':
            artifacts.append(('Secret', '-tls'))
        for kind, suffix in artifacts:
            actual = cluster.get(kind, ep['name'] + suffix, recipe['namespace'])
            require(actual.get('immutable') is True and actual['metadata'].get('uid') and
                    actual['metadata'].get('resourceVersion'), 'IMMUTABLE_ARTIFACT_REQUIRED')
            # Credential bytes are neither retained in evidence nor emitted.
            anchors.append(dict(kind=kind, metadata=actual['metadata'], immutable=True))
    if 'image_pull_secret' in recipe:
        actual = cluster.get('Secret', recipe['image_pull_secret'], recipe['namespace'])
        require(actual.get('immutable') is True and actual.get('type') == 'kubernetes.io/dockerconfigjson'
                and set(actual.get('data', {})) == {'.dockerconfigjson'} and actual['metadata'].get('uid')
                and actual['metadata'].get('resourceVersion'), 'PULL_SECRET_REQUIRED')
        anchors.append(dict(kind='Secret', metadata=actual['metadata'], immutable=True))
    pods = cluster.command(['get', 'pods', '--namespace', recipe['namespace'], '-o', 'json'])['items']
    require({p['metadata']['name'] for p in pods} == set(originals), 'FOREIGN_TEST_WORKLOAD')
    plan = copy.deepcopy(recipe)
    for ep in plan['endpoints']:
        original = originals[ep['name']]
        actual = next(p for p in pods if p['metadata']['name'] == ep['name'])
        require(original['metadata']['uid'] == actual['metadata']['uid'], 'ORIGINAL_POD_REPLACED')
        check_pod(plan, ep, actual)
        status = actual.get('status', {})
        initial = status.get('initContainerStatuses', [])
        require(len(initial) == 1 and initial[0]['name'] == 'egress-guard'
                and initial[0].get('restartCount') == 0 and 'running' in initial[0].get('state', {})
                and initial[0].get('imageID', '').endswith(ep['image'].split('@')[1])
                and not any('running' in c.get('state', {}) or 'terminated' in c.get('state', {})
                            for c in status.get('containerStatuses', [])), 'POD_ALREADY_EXECUTED_OR_UNVERIFIED')
        ep.update(uid=actual['metadata']['uid'], pod_ip=status['podIP'], execution_generation=1)
    prove_injection_denied(cluster, recipe, pods[0])
    return plan, pods, anchors, ns


def bind_routes(plan, routes):
    """Owner's exact route recipe uses roles, never a guessed future Pod IP."""
    require(isinstance(routes, list), 'ROUTE_RECIPE')
    result = []
    targets = {e['role']: e['pod_ip'] for e in plan['endpoints']}
    for route in routes:
        route = dict(route)
        if route.get('to') in targets:
            require(route.get('ip') is None, 'INTERNAL_ADDRESS_MUST_BE_OBSERVED')
            route['ip'] = targets[route['to']]
        result.append(route)
    plan['routes'] = result
    validate(plan)


def wait_observed(cluster, plan):
    while True:
        ready = True
        pods = cluster.command(['get', 'pods', '--namespace', plan['namespace'], '-o', 'json'])['items']
        for ep in plan['endpoints']:
            pod = next((p for p in pods if p['metadata']['uid'] == ep['uid']), {})
            check_pod(plan, ep, pod)
            require(pod.get('status', {}).get('podIP') == ep['pod_ip'], 'POD_ADDRESS_CHANGED')
            states = pod.get('status', {}).get('containerStatuses', [])
            if not states or 'running' not in states[0].get('state', {}):
                require(not states or 'terminated' not in states[0].get('state', {}), 'SUPERVISOR_EXITED')
                ready = False
            else:
                require(states[0].get('restartCount') == 0 and
                        states[0].get('imageID', '').endswith(ep['image'].split('@')[1]), 'SUPERVISOR_IMAGE_CHANGED')
        if ready:
            return
        time.sleep(cluster.remaining(0.1))


def seal(plan, proofs):
    require(set(proofs) == ROLES, 'OBSERVATION_COVERAGE')
    phases = schedule(plan['row'])
    matrix = {role: {phase: {} for phase in phases} for role in ROLES}
    allowed = set(COUNTERS) | {'allow_github_restored', 'success_provider', 'success_forge', 'success_github_restored'}
    for ep in plan['endpoints']:
        proof = proofs[ep['role']]
        require(proof.get('observer') == 'COMPLETE' and proof.get('processes', 0) > 0
                and proof.get('endpoint_uid') == ep['uid'] and proof.get('execution_generation') == 1
                and proof.get('generation') == plan['generation'] and proof.get('plan_digest') == validate(plan)
                and set(proof.get('intervals', {})) == set(phases), 'OBSERVATION_BINDING_OR_COVERAGE')
        require(proof.get('command_results') == {phase: 0 for phase in phases if phase != 'end'},
                'CONTROL_OR_ROW_FAILED')
        for phase, counts in proof['intervals'].items():
            require(set(counts) <= allowed and all(type(v) is int and v >= 0 for v in counts.values()), 'COUNTER_FORMAT')
            matrix[ep['role']][phase].update(counts)
    # Add protocol metadata only after every syscall interval has been copied;
    # endpoint order must not overwrite another gateway's attribution.
    for ep in plan['endpoints']:
        proof = proofs[ep['role']]
        for event in proof.get('gateway', []):
            require(ep['role'] in ('dns', 'proxy') and set(event) - {'detail'} == {'type', 'source', 'category', 'phase'}
                    and ('detail' not in event or (isinstance(event['detail'], str)
                                                   and re.fullmatch(r'[A-Z0-9_]{1,64}', event['detail'])))
                    and event['source'] in ROLES and event['phase'] in phases and event['category'] in allowed,
                    'GATEWAY_COVERAGE')
            counts = matrix[event['source']][event['phase']]
            counts[event['category']] = counts.get(event['category'], 0) + 1
    forbidden = {'github_cli', 'github_network', 'unknown', 'dns_denied', 'proxy_denied',
                 'allow_github_restored', 'success_github_restored'}
    for role, intervals in matrix.items():
        require(intervals['startup'].get('io_uring_fenced', 0) > 0, 'IO_URING_CONTROL_MISSING')
        for phase, counts in intervals.items():
            if phase.startswith('deny:'):
                control = phase.split(':')[1]
                category = 'github_cli' if control in ('gh-path', 'gh-absolute', 'execveat') else \
                    'unknown' if control == 'proxy-bypass' else 'github_network'
                require(counts.get(category, 0) > 0, 'DENY_CONTROL_MISSING')
            elif phase == 'row:A4-denied':
                # The intentional denied PR read is a separate nonzero interval.
                require(not any(counts.get(c, 0) for c in
                                ('unknown', 'allow_github_restored', 'success_github_restored')),
                        'A4_DENIED_SCOPE_CHANGED')
            elif phase == 'row:A4-restored':
                require(not any(counts.get(c, 0) for c in ('unknown', 'dns_denied', 'proxy_denied')),
                        'RESTORED_UNKNOWN_DESTINATION')
            else:
                require(not any(counts.get(c, 0) for c in forbidden), 'ZERO_INTERVAL_CONTAMINATED')
        require(intervals['allow:hub'].get('allow_hub', 0) > 0 and
                intervals['allow:provider'].get('success_provider', 0) > 0, 'ALLOW_CONTROL_MISSING')
    if plan['row'] == 'A4':
        require(any(matrix[r]['row:A4-denied'].get('github_cli', 0) > 0 for r in ROLES)
                and any(matrix[r]['row:A4-restored'].get('success_github_restored', 0) > 0 for r in ROLES),
                'A4_REAL_DENIED_AND_RESTORED_READ_REQUIRED')
    return dict(row=plan['row'], matrix=matrix, g3_g4='PASS', live='OBSERVED',
                c9='OWNER VERDICT REQUIRED', plan_digest=validate(plan))


def terminal_snapshot(cluster, plan, success=True):
    pods = cluster.command(['get', 'pods', '--namespace', plan['namespace'], '-o', 'json'])['items']
    for ep in plan['endpoints']:
        pod = next((p for p in pods if p['metadata']['uid'] == ep['uid']), {})
        check_pod(plan, ep, pod)
        status = pod.get('status', {})
        require(status.get('phase') in (('Succeeded',) if success else ('Succeeded', 'Failed'))
                and status.get('podIP') == ep['pod_ip'], 'POD_NOT_TERMINAL')
        for name, field in (('observed', 'containerStatuses'), ('egress-guard', 'initContainerStatuses')):
            values = status.get(field, [])
            require(len(values) == 1 and values[0]['name'] == name and values[0].get('restartCount') == 0
                    and values[0].get('imageID', '').endswith(ep['image'].split('@')[1])
                    and 'terminated' in values[0].get('state', {})
                    and (not success or values[0]['state']['terminated'].get('exitCode') == 0),
                    'EXECUTION_LIFETIME_CHANGED')


def terminal(cluster, plan, success=True):
    # Attach EOF precedes kubelet's status update. Keep the original identity
    # checks on each read; only a still-running original Pod is retryable.
    while True:
        try:
            terminal_snapshot(cluster, plan, success)
            return
        except Refused as exc:
            if str(exc) != 'POD_NOT_TERMINAL':
                raise
            time.sleep(cluster.remaining(0.1))


def run(args):
    started = time.monotonic()
    cluster = Cluster(args.kubeconfig, started + 50)
    evidence = Path(args.evidence)
    require(not any((parent / '.git').exists() for parent in evidence.resolve().parents),
            'EVIDENCE_MUST_BE_OUTSIDE_GIT')
    evidence.mkdir(mode=0o700, exist_ok=False)
    channels, guards, plan = {}, {}, None
    success = False
    result = dict(config='NOT VERIFIED', installed='NOT VERIFIED', live='NOT RUN', cleanup='NOT VERIFIED')
    try:
        recipe = read_private(args.recipe)
        validate(recipe, bound=False)
        cluster.deadline = started + min(50, recipe['budget_seconds'] - 3)
        plan, pods, anchors, ns = preflight(cluster, recipe, read_private(args.created))
        bind_routes(plan, read_private(args.routes))
        bind_observed(plan, dict(cluster_uid=plan['cluster_uid'], namespace=ns, pods=pods))
        write_private(evidence / 'manifest.json', plan)
        result['config'] = 'PREPARED'
        for ep in plan['endpoints']:
            guards[ep['role']] = cluster.attach(plan, ep, 'egress-guard')
            guards[ep['role']].send(plan)
        for ep in plan['endpoints']:
            receipt = guards[ep['role']].receive('guard')
            require(receipt.get('endpoint_uid') == ep['uid'] and receipt.get('plan_digest') == validate(plan)
                    and receipt.get('installed') is True, 'GUARD_RECEIPT_CHANGED')
        result['installed'] = 'VERIFIED'
        wait_observed(cluster, plan)
        for ep in plan['endpoints']:
            channels[ep['role']] = cluster.attach(plan, ep, 'observed')
            channels[ep['role']].send(dict(action='hello', phase='startup'))
        for channel in channels.values():
            channel.receive('ready', 'startup')
        for phase in schedule(plan['row']):
            if phase != 'startup':
                for channel in channels.values(): channel.send(dict(action='mark', phase=phase))
                for channel in channels.values(): channel.receive('marked', phase)
            action = 'finish' if phase == 'end' else 'run'
            for channel in channels.values(): channel.send(dict(action=action, phase=phase))
            if phase != 'end':
                for channel in channels.values():
                    require(channel.receive('result', phase).get('exit') == 0, 'CONTROL_OR_ROW_FAILED')
        bundles = {role: channel.receive('workload-evidence') for role, channel in channels.items()}
        proofs = {role: channel.receive('observation') for role, channel in channels.items()}
        for role, bundle in bundles.items():
            check_evidence(plan, role, bundle, proofs[role])
        # Retain complete exports even if a later row/terminal gate fails. Their
        # capture status is distinct from the run receipt and business verdict.
        write_private(evidence / 'workload-evidence.json', bundles)
        result['workload_evidence_digest'] = fingerprint(bundles)
        row_coverage(plan, bundles)
        for channel in channels.values():
            require(channel.process.wait(timeout=cluster.remaining(2)) == 0 and not channel.buffer,
                    'OBSERVATION_CHANNEL_NOT_CLOSED')
        for anchor in anchors:
            same_resource(anchor, cluster.get(anchor['kind'], anchor['metadata']['name'],
                                             anchor['metadata'].get('namespace')))
        terminal(cluster, plan)
        result.update(seal(plan, proofs), cleanup='TERMINATED; OWNER RETAINS RESOURCES')
        write_private(evidence / 'observations.json', proofs)
        success = True
        return 0
    except BaseException as exc:
        result['failure'] = str(exc) if isinstance(exc, Refused) else 'C9_RUN_UNAVAILABLE'
        # Closing attach reaches the exclusive PID1's EOF/cancellation path.
        # Its Pod deadline is a second boundary. Never delete an adopted object
        # or kill a process selected by host PID, name, user or shared cgroup.
        return 125
    finally:
        if not success:
            for channel in channels.values():
                try: channel.send(dict(action='cancel', phase='end'))
                except (OSError, ValueError): pass
        for channel in [*channels.values(), *guards.values()]: channel.close()
        if not success and (channels or guards) and plan:
            try:
                cluster.deadline = started + min(54, plan['budget_seconds'])
                terminal(cluster, plan, success=False)
                result['cleanup'] = 'TERMINATED; OWNER RETAINS RESOURCES'
            except BaseException:
                result['cleanup'] = 'NOT VERIFIED; ORIGINAL POD DEADLINE RETAINED'
        result['elapsed_seconds'] = round(time.monotonic() - started, 3)
        require(result['elapsed_seconds'] < 60, 'ENTRY_BUDGET_EXCEEDED')
        write_private(evidence / 'receipt.json', result)
        print(json.dumps({k: result[k] for k in ('config', 'installed', 'live', 'cleanup')}))


def digests(workload=None, hub_key=None):
    """The recipe's hand-computed fields (#4630), from the same code the guard
    checks: observer_digest is runtime.build_digest over this checkout's files.
    created.json is not computed: it is `kubectl create -f <render output>
    -o json`'s own response, kept unedited."""
    from nogh_live_runtime import build_digest
    file_digest = lambda path: 'sha256:' + hashlib.sha256(Path(path).read_bytes()).hexdigest()
    result = dict(observer_digest=build_digest())
    if workload:
        result['command_digest'] = file_digest(workload)
    if hub_key:
        require(Path(hub_key).read_bytes().startswith(b'ed25519 '), 'HUB_KEY_FORMAT')
        result['key_digest'] = file_digest(hub_key)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    template = sub.add_parser('render')
    template.add_argument('--recipe', required=True)
    template.add_argument('--output', required=True)
    sums = sub.add_parser('digests', help='print the recipe digests from local files; reads no cluster')
    sums.add_argument('--workload', help='the workload binary baked at /opt/fleet-c9/workload (command_digest)')
    sums.add_argument('--hub-key', help="the hub's /v1/fleet/account-key response body, saved as is (key_digest)")
    live = sub.add_parser('run')
    for field in ('recipe', 'routes', 'created', 'evidence', 'kubeconfig'):
        live.add_argument('--' + field, required=True)
    parser.add_argument('--test-only', action='store_true', required=True)
    args = parser.parse_args()
    require(args.test_only, 'EXPLICIT_TEST_ONLY_REQUIRED')
    if args.action == 'digests':
        print(json.dumps(digests(args.workload, args.hub_key), indent=1, sort_keys=True))
        return 0
    if args.action == 'render':
        write_private(args.output, dict(apiVersion='v1', kind='List', items=render(read_private(args.recipe), True)))
        return 0
    def stop(*_):
        raise Refused('CANCELLED_OR_DEADLINE')
    signal.signal(signal.SIGALRM, stop)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    signal.alarm(55)
    return run(args)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Refused, OSError, ValueError) as exc:
        # Only an identifier: the code, else the exception class (#4625).
        code = str(exc) if isinstance(exc, Refused) and re.fullmatch(r'[A-Z0-9_]{1,64}', str(exc)) \
            else type(exc).__name__.upper()[:64]
        print('C9 entry refused (%s); live NOT RUN' % code, file=sys.stderr)
        sys.exit(125)
