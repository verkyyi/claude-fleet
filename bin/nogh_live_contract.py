#!/usr/bin/env python3
"""C9 test-only identity, network and observation contract (#4523).

Validation is PREPARED, never installed or live-accepted. This module does not
accept application-supplied counters, attach to existing processes, or mutate
cluster resources. The live supervisor owns observation and feeds the ledger.
All diagnostics are fixed codes: never echo a config value or syscall payload.
"""
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import time
import uuid
from urllib.parse import urlsplit

ROWS = tuple('A%d' % n for n in range(1, 13))
ROLES = {'hub', 'node-a', 'node-b', 'proxy', 'dns'}
DENY_CONTROLS = {'github-name', 'github-v4', 'github-v6', 'dns-udp', 'dns-tcp',
                 'proxy-bypass', 'gh-path', 'gh-absolute', 'execveat', 'sendmsg', 'sendmmsg'}
ALLOW_CONTROLS = {'hub', 'provider'}
COUNTERS = ('github_cli', 'github_network', 'unknown', 'dns_denied', 'proxy_denied',
            'allow_hub', 'allow_provider', 'allow_forge', 'allow_dns', 'io_uring_fenced')
DIGEST = re.compile(r'sha256:[0-9a-f]{64}\Z')
NAME = re.compile(r'[a-z][a-z0-9-]{0,62}\Z')


class Refused(ValueError):
    """Fixed, non-secret failure code."""


def require(ok, code):
    if not ok:
        raise Refused(code)


def keys(value, fields, code):
    require(isinstance(value, dict) and set(value) == set(fields.split()), code)


def identifier(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except (ValueError, AttributeError):
        return False


def digest(value):
    return isinstance(value, str) and bool(DIGEST.fullmatch(value))


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def fingerprint(value):
    return 'sha256:' + hashlib.sha256(canonical(value)).hexdigest()


def read_private(path):
    """No symlink or permissive file can carry the binding used to act."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600
                and info.st_uid == os.getuid() and info.st_size <= 1024 * 1024, 'PRIVATE_FILE_REQUIRED')
        with os.fdopen(fd, 'rb', closefd=False) as source:
            return json.load(source)
    finally:
        os.close(fd)


def write_private(path, value):
    """Exclusive creation: an old generation's receipt is never overwritten."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as target:
        target.write(canonical(value) + b'\n')
        target.flush()
        os.fsync(target.fileno())


def address(value):
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        raise Refused('EXACT_IP_REQUIRED') from None
    require(str(ip) == value and not ip.is_unspecified and not ip.is_multicast
            and not getattr(ip, 'ipv4_mapped', None), 'EXACT_IP_REQUIRED')
    return ip


def origin(value):
    require(isinstance(value, str) and len(value) <= 253, 'EXACT_ORIGIN_REQUIRED')
    try:
        parsed = urlsplit(value)
        port = parsed.port
        require(parsed.scheme in ('https', 'http', 'git') and parsed.hostname and port
                and not parsed.username and not parsed.password and not parsed.query
                and not parsed.fragment and parsed.path in ('', '/')
                and parsed.hostname == parsed.hostname.lower()
                and '*' not in parsed.netloc, 'EXACT_ORIGIN_REQUIRED')
        return parsed.hostname, port
    except ValueError:
        raise Refused('EXACT_ORIGIN_REQUIRED') from None


LABEL = r'(?:[a-z0-9]([-a-z0-9.]{0,61}[a-z0-9])?/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?'
LABEL_VALUE = r'(?:[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?'


def placement(value):
    """Where a run's Pods may land (#4625): a nodeSelector naming 1-4 exact
    labels and up to 4 NoSchedule tolerations of an exact key=value taint.
    Only scheduling, never a capability; a cluster's production nodes stay
    out because the owner's recipe names a test node."""
    keys(value, 'node_selector tolerations', 'PLACEMENT_FIELDS')
    selector, tolerations = value['node_selector'], value['tolerations']
    require(isinstance(selector, dict) and 1 <= len(selector) <= 4
            and all(isinstance(k, str) and re.fullmatch(LABEL, k) and isinstance(v, str)
                    and re.fullmatch(LABEL_VALUE, v) for k, v in selector.items()), 'PLACEMENT_SELECTOR')
    require(isinstance(tolerations, list) and len(tolerations) <= 4, 'PLACEMENT_TOLERATIONS')
    for t in tolerations:
        keys(t, 'key value', 'PLACEMENT_TOLERATIONS')
        require(isinstance(t['key'], str) and re.fullmatch(LABEL, t['key']) and isinstance(t['value'], str)
                and re.fullmatch(LABEL_VALUE, t['value']), 'PLACEMENT_TOLERATIONS')


def validate(plan, now=None, *, bound=True):
    """The same strict schema is used at render, bind, start and seal.

    Actual UIDs come from the owner's normal creation road, never from labels.
    Names and labels alone cannot authorize adopting an already running pod.
    """
    fields = ('version purpose run_id generation source_sha namespace namespace_uid '
              'cluster_uid expires_at budget_seconds controller row hub endpoints routes probes')
    keys(plan, fields + (' placement' if 'placement' in plan else ''), 'PLAN_FIELDS')
    if 'placement' in plan:
        placement(plan['placement'])
    require(plan['version'] == 1 and plan['purpose'] == 'c9-disposable-test', 'TEST_ONLY')
    require(identifier(plan['run_id']) and identifier(plan['namespace_uid'])
            and identifier(plan['cluster_uid']), 'RUN_IDENTITY_REQUIRED')
    require(plan['namespace'] == 'c9-' + plan['run_id'], 'PRODUCTION_TARGET_REFUSED')
    require(plan['controller'] == 'system:serviceaccount:' + plan['namespace'] + ':c9-controller',
            'EXCLUSIVE_CONTROLLER_REQUIRED')
    require(type(plan['generation']) is int and plan['generation'] > 0, 'GENERATION_REQUIRED')
    require(isinstance(plan['source_sha'], str)
            and re.fullmatch(r'[0-9a-f]{40}', plan['source_sha']), 'SOURCE_REQUIRED')
    now = time.time() if now is None else now
    require(type(plan['expires_at']) in (int, float) and now < plan['expires_at'] <= now + 3600,
            'PLAN_EXPIRED_OR_UNBOUNDED')
    require(type(plan['budget_seconds']) is int and 5 <= plan['budget_seconds'] <= 55, 'BUDGET_REQUIRED')
    require(plan['row'] in ROWS, 'ONE_ROW_REQUIRED')
    keys(plan['hub'], 'origin key_digest commit', 'HUB_IDENTITY_REQUIRED')
    origin(plan['hub']['origin'])
    require(plan['hub']['origin'].startswith('https://') and digest(plan['hub']['key_digest'])
            and re.fullmatch(r'[0-9a-f]{40}', plan['hub']['commit']), 'HUB_IDENTITY_REQUIRED')
    endpoints = plan['endpoints']
    require(isinstance(endpoints, list) and len(endpoints) == len(ROLES), 'ALL_SURFACES_REQUIRED')
    roles, uids, ips, bindings = set(), set(), set(), set()
    for ep in endpoints:
        keys(ep, 'role name login binding image observer_digest command_digest tls_cert_digest' +
             (' uid pod_ip execution_generation' if bound else ''), 'ENDPOINT_FIELDS')
        require(ep['role'] in ROLES and ep['role'] not in roles, 'DUPLICATE_ROLE')
        require(isinstance(ep['name'], str) and NAME.fullmatch(ep['name']), 'RESOURCE_NAME')
        require(isinstance(ep['login'], str) and NAME.fullmatch(ep['login']), 'FULL_BINDING_REQUIRED')
        if ep['role'] in ('node-a', 'node-b'):
            binding = ep['binding']
            keys(binding, 'endpoint_id fleet_id machine_id hostname owner', 'FULL_BINDING_REQUIRED')
            require(identifier(binding['fleet_id']) and all(isinstance(binding[k], str) and
                    re.fullmatch(r'[a-zA-Z0-9_.:@-]{1,128}', binding[k]) for k in
                    ('endpoint_id', 'machine_id', 'hostname', 'owner')), 'FULL_BINDING_REQUIRED')
            require(binding['endpoint_id'] not in bindings, 'SHARED_ENDPOINT_REFUSED')
            bindings.add(binding['endpoint_id'])
        else:
            require(ep['binding'] is None, 'NON_NODE_BINDING_REFUSED')
        require(isinstance(ep['image'], str) and len(ep['image']) <= 253
                and re.fullmatch(r'[a-zA-Z0-9./:_-]+@sha256:[0-9a-f]{64}', ep['image']), 'IMAGE_DIGEST_REQUIRED')
        require(digest(ep['observer_digest']) and
                (digest(ep['command_digest']) if ep['role'] in ('hub', 'node-a', 'node-b') else
                 ep['command_digest'] is None), 'BINARY_DIGEST_REQUIRED')
        require(digest(ep['tls_cert_digest']) if ep['role'] == 'proxy' else ep['tls_cert_digest'] is None,
                'PROXY_CERTIFICATE_REQUIRED')
        if bound:
            require(identifier(ep['uid']) and ep['uid'] not in uids, 'SHARED_RESOURCE_REFUSED')
            require(type(ep['execution_generation']) is int and ep['execution_generation'] == 1,
                    'EXECUTION_GENERATION_REQUIRED')
            ip = address(ep['pod_ip'])
            require(not ip.is_loopback and ep['pod_ip'] not in ips, 'SHARED_NETWORK_REFUSED')
            uids.add(ep['uid']); ips.add(ep['pod_ip'])
        roles.add(ep['role'])
    require(roles == ROLES, 'ALL_SURFACES_REQUIRED')
    routes = plan['routes']
    if not bound:
        require(routes == [], 'UNBOUND_RECIPE_HAS_NO_ROUTES')
        return fingerprint(plan)
    require(isinstance(routes, list) and 1 <= len(routes) <= 128, 'EXACT_ROUTES_REQUIRED')
    seen, purposes = set(), set()
    for route in routes:
        keys(route, 'from to purpose ip port protocol origin', 'ROUTE_FIELDS')
        require(route['from'] in roles and route['to'] in roles | {'provider-origin', 'forge-origin', 'github-origin'},
                'UNOWNED_ROUTE')
        require(route['purpose'] in ('hub', 'provider', 'dns', 'forge', 'peer', 'github_restored'),
                'UNKNOWN_ROUTE_PURPOSE')
        address(route['ip'])
        require(type(route['port']) is int and 0 < route['port'] < 65536
                and route['protocol'] in ('tcp', 'udp'), 'EXACT_TRANSPORT_REQUIRED')
        key = (route['from'], route['ip'], route['port'], route['protocol'])
        require(key not in seen, 'AMBIGUOUS_ROUTE')
        seen.add(key); purposes.add(route['purpose'])
        if route['to'] in roles:
            target = next(ep for ep in endpoints if ep['role'] == route['to'])
            require(route['ip'] == target['pod_ip'], 'ROUTE_BINDING_CHANGED')
        else:
            require(route['from'] == 'proxy' and route['protocol'] == 'tcp'
                    and route['purpose'] in ('provider', 'forge', 'github_restored')
                    and route['origin'].startswith('https://'), 'DIRECT_OR_SHARED_EGRESS_REFUSED')
        if route['purpose'] == 'dns':
            require(route['to'] == 'dns' and route['port'] == 53 and route['origin'] == '',
                    'SHARED_RESOLVER_REFUSED')
        else:
            host, port = origin(route['origin'])
            require(port == route['port'], 'ORIGIN_PORT_MISMATCH')
            is_github = any(host == d or host.endswith('.' + d) for d in
                            ('github.com', 'githubusercontent.com', 'githubassets.com', 'github.io'))
            require((is_github and route['to'] == 'github-origin' and route['purpose'] == 'github_restored'
                     and plan['row'] == 'A4') or (not is_github and route['purpose'] != 'github_restored'
                                                and route['to'] != 'github-origin'), 'GITHUB_ALLOW_REFUSED')
    require({'hub', 'provider', 'dns', 'forge'} <= purposes, 'INCOMPLETE_ALLOW_ROUTES')
    probes = plan['probes']
    keys(probes, 'github_ipv4 github_ipv6 bypass_ipv4 bypass_port', 'PROBE_FIELDS')
    require(address(probes['github_ipv4']).version == 4 and address(probes['github_ipv6']).version == 6
            and address(probes['bypass_ipv4']).version == 4, 'PROBE_ADDRESS')
    # 53 is counted as DNS and 80/443 as GitHub, never as the unknown the
    # proxy-bypass control must produce (#4630).
    require(type(probes['bypass_port']) is int and 0 < probes['bypass_port'] < 65536
            and probes['bypass_port'] not in (53, 80, 443), 'PROBE_PORT')
    require(all((r['ip'], r['port']) not in ((probes['github_ipv4'], 443), (probes['github_ipv6'], 443),
                                           (probes['bypass_ipv4'], probes['bypass_port'])) for r in routes
                if r['purpose'] != 'github_restored'),
            'DENY_PROBE_IS_ALLOWED')
    return fingerprint(plan)


def bind_observed(plan, observed, now=None):
    """Compare a fresh API read to the exact original objects, not recreated names.

    Callers supply the result of their own authenticated GET, not an application's
    claimed observation. This is only a preflight; runtime coverage is separate.
    """
    plan_hash = validate(plan, now)
    keys(observed, 'cluster_uid namespace pods', 'OBSERVATION_FIELDS')
    require(observed['cluster_uid'] == plan['cluster_uid'], 'CLUSTER_CHANGED')
    ns = observed['namespace']
    require(ns.get('metadata', {}).get('uid') == plan['namespace_uid']
            and ns.get('metadata', {}).get('name') == plan['namespace'], 'NAMESPACE_CHANGED')
    pods = observed['pods']
    require(isinstance(pods, list) and len(pods) == len(ROLES), 'RESOURCE_COVERAGE')
    indexed = {p.get('metadata', {}).get('uid'): p for p in pods}
    require(len(indexed) == len(pods), 'RESOURCE_COVERAGE')
    for ep in plan['endpoints']:
        pod = indexed.get(ep['uid'], {})
        meta, spec = pod.get('metadata', {}), pod.get('spec', {})
        require(meta.get('name') == ep['name'] and meta.get('namespace') == plan['namespace']
                and not meta.get('deletionTimestamp'), 'RESOURCE_CHANGED')
        labels = meta.get('labels', {})
        require(labels.get('fleet/c9-run') == plan['run_id']
                and labels.get('fleet/c9-generation') == str(plan['generation'])
                and labels.get('fleet/c9-role') == ep['role'], 'RESOURCE_GENERATION_CHANGED')
        require(not any(spec.get(k) for k in ('hostNetwork', 'hostPID', 'hostIPC',
                                             'shareProcessNamespace', 'ephemeralContainers')),
                'SHARED_NAMESPACE_REFUSED')
        require(spec.get('automountServiceAccountToken') is False, 'API_TOKEN_REFUSED')
        containers = spec.get('containers', [])
        require(len(containers) == 1 and containers[0].get('name') == 'observed'
                and containers[0].get('image') == ep['image'], 'UNOBSERVED_CONTAINER')
        c = containers[0]
        require(not any(c.get(k) for k in ('lifecycle', 'livenessProbe', 'readinessProbe', 'startupProbe')),
                'OUTSIDE_EXEC_REFUSED')
        require(c.get('command') == ['/usr/local/bin/fleet-c9-supervise'] and c.get('args') == [ep['role']],
                'UNOBSERVED_ENTRYPOINT')
        for volume in spec.get('volumes', []):
            require(not set(volume) - {'name', 'emptyDir', 'secret', 'configMap', 'downwardAPI'},
                    'SHARED_VOLUME_REFUSED')
        require(pod.get('status', {}).get('podIP') == ep['pod_ip'], 'ADDRESS_DRIFT')
    return dict(config='PREPARED', installed='NOT VERIFIED', live='NOT RUN', plan_digest=plan_hash)


class Interval:
    """Supervisor-owned per-endpoint interval; no zero from an empty stream."""
    def __init__(self, plan, role, row, serial):
        self.plan_digest = validate(plan)
        require(role in ROLES and row in ROWS and type(serial) is int and serial > 0, 'INTERVAL_IDENTITY')
        self.binding = next(ep for ep in plan['endpoints'] if ep['role'] == role)
        self.run_id, self.generation = plan['run_id'], plan['generation']
        self.role, self.row, self.serial = role, row, serial
        self.counters = dict.fromkeys(COUNTERS, 0)
        self.sequence = 0
        self.ready = self.ended = self.eof = False
        self.root_seen = False
        self.live_pids = set()
        self.controls = {}
        self.failure = None

    def refuse(self, code):
        self.failure = self.failure or code
        raise Refused(code)

    def event(self, event):
        """Only the independent observer calls this, after sanitizing metadata."""
        try:
            return self._event(event)
        except Refused as exc:
            self.failure = self.failure or str(exc)
            raise

    def _event(self, event):
        if self.failure:
            self.refuse('OBSERVATION_ALREADY_FAILED')
        keys(event, 'run_id generation endpoint_uid execution_generation interval seq kind data', 'EVENT_FIELDS')
        expected = (self.run_id, self.generation, self.binding['uid'],
                    self.binding['execution_generation'], self.serial, self.sequence + 1)
        actual = tuple(event[k] for k in ('run_id', 'generation', 'endpoint_uid',
                                         'execution_generation', 'interval', 'seq'))
        if actual != expected or self.eof:
            self.refuse('LATE_STALE_OR_LOST_EVENT')
        self.sequence += 1
        kind, data = event['kind'], event['data']
        if self.ended and kind != 'eof':
            self.refuse('EVENT_AFTER_END')
        if kind == 'ready':
            if self.ready or self.sequence != 1 or data != {'coverage': 'exclusive-pid-namespace',
                                                            'inherited_sockets': 0, 'io_uring': 'ENOSYS'}:
                self.refuse('COVERAGE_UNPROVEN')
            self.ready = True
        elif not self.ready:
            self.refuse('OBSERVER_NOT_READY')
        elif kind == 'fork':
            keys(data, 'pid parent', 'PROCESS_FIELDS')
            if type(data['pid']) is not int or data['pid'] <= 0 or data['pid'] in self.live_pids:
                self.refuse('UNKNOWN_PROCESS')
            if (self.root_seen and data['parent'] not in self.live_pids) or \
                    (not self.root_seen and data['parent'] != 0):
                self.refuse('UNOWNED_PROCESS')
            self.root_seen = True
            self.live_pids.add(data['pid'])
        elif kind == 'exit':
            keys(data, 'pid', 'PROCESS_FIELDS')
            if data['pid'] not in self.live_pids:
                self.refuse('UNKNOWN_PROCESS')
            self.live_pids.remove(data['pid'])
        elif kind == 'attempt':
            keys(data, 'pid category count', 'ATTEMPT_FIELDS')
            if data['pid'] not in self.live_pids or data['category'] not in COUNTERS:
                self.refuse('UNCLASSIFIED_ATTEMPT')
            if type(data['count']) is not int or not 1 <= data['count'] <= 1024:
                self.refuse('INVALID_COUNT')
            self.counters[data['category']] += data['count']
        elif kind == 'end':
            if self.ended or self.live_pids or data != {'pending_syscalls': 0, 'command_exit': 0}:
                self.refuse('INCOMPLETE_END')
            self.ended = True
        elif kind == 'eof':
            if not self.ended or data != {'observer_exit': 0}:
                self.refuse('OBSERVER_LOST')
            self.eof = True
        else:
            self.refuse('UNKNOWN_EVENT')

    def seal(self):
        require(not self.failure and self.ready and self.ended and self.eof
                and self.root_seen and self.sequence >= 5, 'OBSERVATION_INCOMPLETE')
        require(not any(self.counters[k] for k in COUNTERS[:5]), 'FORBIDDEN_ATTEMPT')
        return dict(run_id=self.run_id, generation=self.generation, endpoint_uid=self.binding['uid'],
                    execution_generation=self.binding['execution_generation'], role=self.role,
                    row=self.row, interval=self.serial, plan_digest=self.plan_digest,
                    events=self.sequence, counters=self.counters.copy(), observation='COMPLETE',
                    live='NOT RUN')  # positive controls + every surface/row are a separate gate
