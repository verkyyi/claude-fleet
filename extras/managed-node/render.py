#!/usr/bin/env python3
"""Render a single managed ACK node. Output is a kubectl-compatible JSON List."""
import argparse
import ipaddress
import json
import re

# the disk runtime the machine updater moves (#3212; the image only seeds it)
RUNTIME = '/var/db/fleet-node/runtime'
# the entry port (#3070): the only port the public door carries (#3213)
ENTRY_PORT = 22022
# ACK's cloud controller: a public CLB, the smallest spec, paid by traffic.
# `clcu` is the pay-by-use instance for an account that can no longer buy by spec.
LB = 'service.beta.kubernetes.io/alibaba-cloud-loadbalancer-'


# The egress guard (#3281). ACK's flannel enforces no NetworkPolicy, so the guard
# lives in the pod's own network namespace: an init container holding NET_ADMIN
# writes OUTPUT rules once, and the `fleet` container — root included — has no
# NET_ADMIN to undo them. Defaults are the hub's ACK cluster (kube-dns, pod and
# service ranges, the cloud metadata address); everything else private is cut,
# the public internet stays open, and inbound replies ride ESTABLISHED.
EGRESS = {
    'dns': '172.21.0.10',
    'metadata': '100.100.100.200/32',
    'pod_cidr': '172.20.0.0/16',
    'service_cidr': '172.21.0.0/20',
    'private': ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10', '169.254.0.0/16'],
}
EGRESS6_BLOCK = ['fc00::/7']


# The dev network (#3348): GitHub's git transport through the Singapore relay
# (extras/gh-relay), a repo the in-cluster CI mirror carries fetched from it, CN
# package mirrors. fleet-node-linux.py turns these into /etc/gitconfig and
# /etc/fleet-devnet.env for every login at each start.
GH_PROXY_RE = r'http://[A-Za-z0-9.-]+:[0-9]{1,5}'
GIT_MIRROR_RE = r'(git|https?)://[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._/-]+=https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git'

# The cluster's shared services (#3547, EPIC #3500 C2): the credential proxy's
# in-cluster Service (deploy/k8s/credproxy/fleet-workers) and the one egress
# (deploy/k8s/egress). Plain http only to a cluster-local name — the pass rides
# inside the cluster, never a subscription credential.
CENTRAL_RE = r'(https://[A-Za-z0-9.-]+|http://[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.svc\.cluster\.local)(:[0-9]{1,5})?'
EGRESS_PROXY_RE = r'http://[A-Za-z0-9.-]+:[0-9]{1,5}'
# The package caches (#3548, EPIC #3500 C3): fleet-npm:4873 · fleet-pypi:3141 ·
# fleet-goproxy:3000 in this namespace (deploy/k8s/caches). The pod carries the
# namespace; fleet-node-linux.py writes the three URLs into /etc/fleet-devnet.env.
NS_RE = r'[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'


def egress_allow(value):
    """'IP[/n]:PORT' -> (cidr, port): one in-cluster destination the guard lets through."""
    net, _, port = value.rpartition(':')
    if not port.isdigit() or not 0 < int(port) < 65536:
        raise ValueError('--egress-allow is IP[/n]:PORT, not %r' % value)
    return _net(net if '/' in net else net + '/32', '--egress-allow'), int(port)


def egress_rules(dns, blocked, allow=(), closed=False):
    """iptables-restore input: loopback, replies, DNS to kube-dns, each allowed
    destination (tcp), then REJECT each range — and, closed (#3547), everything
    else too: the pod reaches the outside only through the cluster's egress."""
    v4 = ['*filter', ':INPUT ACCEPT [0:0]', ':FORWARD ACCEPT [0:0]', ':OUTPUT ACCEPT [0:0]',
          '-A OUTPUT -o lo -j ACCEPT',
          '-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT',
          '-A OUTPUT -d %s/32 -p udp -m udp --dport 53 -j ACCEPT' % dns,
          '-A OUTPUT -d %s/32 -p tcp -m tcp --dport 53 -j ACCEPT' % dns]
    v4 += ['-A OUTPUT -d %s -p tcp -m tcp --dport %d -j ACCEPT' % a for a in allow]
    v4 += ['-A OUTPUT -d %s -j REJECT' % c for c in blocked]
    v4 += ['-A OUTPUT -j REJECT'] if closed else []
    v4 += ['COMMIT']
    v6 = ['*filter', ':INPUT ACCEPT [0:0]', ':FORWARD ACCEPT [0:0]', ':OUTPUT ACCEPT [0:0]',
          '-A OUTPUT -o lo -j ACCEPT',
          '-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT']
    v6 += ['-A OUTPUT -d %s -j REJECT' % c for c in EGRESS6_BLOCK]
    v6 += ['-A OUTPUT -j REJECT'] if closed else []
    v6 += ['COMMIT']
    return '\n'.join(v4), '\n'.join(v6)


def egress_guard(image, dns, blocked, metadata, allow=(), closed=False):
    v4, v6 = egress_rules(dns, blocked, allow, closed)
    # nft first (Debian's default), legacy when the node's kernel has no nf_tables
    # for us; no backend that writes AND shows the metadata cut = the pod never
    # starts (fail closed). No IPv6 here is not a failure.
    script = '''set -eu
V4='%s'
V6='%s'
ok=
for b in nft legacy; do
  command -v iptables-$b-restore >/dev/null 2>&1 || continue
  printf '%%s\\n' "$V4" | iptables-$b-restore 2>/dev/null || continue
  iptables-$b -S OUTPUT | grep -qF -- '-d %s -j REJECT' || continue
  ok=$b; break
done
[ -n "$ok" ] || { echo 'egress-guard: no iptables backend took the rules' >&2; exit 1; }
printf '%%s\\n' "$V6" | ip6tables-$ok-restore 2>/dev/null || echo 'egress-guard: no IPv6 rules (no IPv6 here)' >&2
echo "egress-guard: rules in place ($ok)"
iptables-$ok -S OUTPUT
''' % (v4, v6, metadata)
    return {
        'name': 'egress-guard', 'image': image, 'command': ['/bin/sh', '-ec', script],
        'resources': {'requests': {'cpu': '10m', 'memory': '16Mi'}, 'limits': {'cpu': '200m', 'memory': '64Mi'}},
        'securityContext': {'runAsUser': 0, 'allowPrivilegeEscalation': False, 'readOnlyRootFilesystem': True,
                            'capabilities': {'drop': ['ALL'], 'add': ['NET_ADMIN', 'NET_RAW']},
                            'seccompProfile': {'type': 'RuntimeDefault'}},
        # the legacy backend's lock file (/run/xtables.lock)
        'volumeMounts': [{'name': 'egress-run', 'mountPath': '/run'}],
    }


def _net(value, flag):
    try:
        return str(ipaddress.IPv4Network(value, strict=True))
    except ValueError:
        raise ValueError('%s is an IPv4 CIDR, not %r' % (flag, value))


def entry_annotations(spec):
    a = {LB + 'address-type': 'internet', LB + 'charge-type': 'paybytraffic'}
    if spec == 'clcu':
        a[LB + 'instance-charge-type'] = 'PayByCLCU'
    else:
        a.update({LB + 'instance-charge-type': 'PayBySpec', LB + 'spec': spec})
    return a


def _checked(image, hub, storage_class, pull_secrets, egress, github_proxy, git_mirrors, cred_central,
             egress_proxy, egress_closed, cn_mirrors=False, cluster_caches=False, namespace=''):
    """The checks both templates share; returns the egress guard's (dns, blocked, metadata, allow)."""
    if not re.fullmatch(r'[^\s]+@sha256:[a-f0-9]{64}', image):
        raise ValueError('pin the deployed image by sha256 digest')
    if not hub.startswith('https://'):
        raise ValueError('use the hub HTTPS endpoint')
    if not re.fullmatch('[a-z0-9][a-z0-9.-]*', storage_class):
        raise ValueError('select an existing ACK CSI StorageClass')
    # ACK's password-free ACR plugin names its own Secret (acr-credential-<hash>, #3290)
    for name in pull_secrets:
        if not re.fullmatch(r'[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?', name):
            raise ValueError('--pull-secret is a Secret name in the namespace, not %r' % name)
    eg = dict(EGRESS, **(egress or {}))
    try:
        dns = str(ipaddress.IPv4Address(eg['dns']))
    except ValueError:
        raise ValueError('--egress-dns is an IPv4 address, not %r' % eg['dns'])
    metadata = _net(eg['metadata'], '--egress-metadata')
    blocked = [metadata, _net(eg['pod_cidr'], '--egress-pod-cidr'),
               _net(eg['service_cidr'], '--egress-service-cidr')]
    blocked += [_net(c, '--egress-private') for c in eg['private']]
    allow = [egress_allow(v) for v in eg.get('allow', ())]
    if github_proxy and not re.fullmatch(GH_PROXY_RE, github_proxy):
        raise ValueError('--github-proxy is http://HOST:PORT (extras/gh-relay), not %r' % github_proxy)
    for m in git_mirrors:
        if not re.fullmatch(GIT_MIRROR_RE, m):
            raise ValueError('--git-mirror is MIRROR_URL=https://github.com/OWNER/REPO.git, not %r' % m)
    if cred_central and not re.fullmatch(CENTRAL_RE, cred_central):
        raise ValueError('--cred-central is https://HOST or http://NAME.NS.svc.cluster.local[:PORT], not %r'
                         % cred_central)
    if egress_proxy and not re.fullmatch(EGRESS_PROXY_RE, egress_proxy):
        raise ValueError('--egress-proxy is http://HOST:PORT (deploy/k8s/egress), not %r' % egress_proxy)
    if cluster_caches and cn_mirrors:
        raise ValueError('--cluster-caches replaces --cn-mirrors: name one')
    if cluster_caches and not re.fullmatch(NS_RE, namespace):
        raise ValueError('--cluster-caches needs a namespace that is a DNS label, not %r' % namespace)
    if egress_closed and not egress_proxy:
        raise ValueError('--egress-closed needs --egress-proxy: closed with no way out is no machine')
    return dns, blocked, metadata, allow


def _devnet_env(github_proxy, git_mirrors, cn_mirrors, cred_central, egress_proxy, cluster_caches=False,
                namespace=''):
    env = []
    if github_proxy:
        env.append({'name': 'FLEET_GITHUB_PROXY', 'value': github_proxy})
    if git_mirrors:
        env.append({'name': 'FLEET_GIT_MIRRORS', 'value': ' '.join(git_mirrors)})
    if cn_mirrors:
        env.append({'name': 'FLEET_CN_MIRRORS', 'value': '1'})
    if cluster_caches:
        env.append({'name': 'FLEET_CLUSTER_CACHES', 'value': namespace})
    if cred_central:
        # sessions route central; the node leases no token and keeps none (#3547)
        env.append({'name': 'FLEET_CRED_CENTRAL_URL', 'value': cred_central})
    if egress_proxy:
        env.append({'name': 'FLEET_EGRESS_PROXY', 'value': egress_proxy})
    return env


def _relay_env(relay):
    """The subscription relay this deployment runs (docs/dev/CRED-RELAY.md): the node
    carries none of its own (claude-fleet#3577); empty = none."""
    if not relay:
        return []
    if not re.fullmatch(r'https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._/-]*)?', relay):
        raise ValueError('--relay is https://HOST[/PATH], not %r' % relay)
    return [{'name': 'FLEET_CRED_RELAY_URL', 'value': relay}]


def _probes():
    return {
        'startupProbe': {'exec': {'command': ['test', '-f', '/run/fleet-node-ready']},
                         'periodSeconds': 10, 'failureThreshold': 90},
        'readinessProbe': {'exec': {'command': ['python3', '-I', RUNTIME + '/current/bin/fleet-node-linux.py',
                                               'ready']}, 'periodSeconds': 15},
        # the resident loop only (#3212): a supervisor restarting onto a new
        # release is never a reason to restart the container
        'livenessProbe': {'exec': {'command': ['python3', '-I', '/usr/local/lib/fleet-image-stage.py', 'live']},
                          'periodSeconds': 30, 'failureThreshold': 4},
    }


# root only for the switch into the login (and sshd's): never NET_ADMIN / NET_RAW,
# so the egress guard's rules stay put (#3281)
NODE_SECURITY = {'runAsUser': 0, 'allowPrivilegeEscalation': False,
                 'capabilities': {'drop': ['ALL'], 'add': ['CHOWN', 'DAC_OVERRIDE', 'FOWNER',
                     'SETUID', 'SETGID', 'KILL', 'NET_BIND_SERVICE', 'SYS_CHROOT', 'AUDIT_WRITE']},
                 'seccompProfile': {'type': 'RuntimeDefault'}}
VOLUMES = [('node', '/var/db/fleet-node'), ('credentials', '/var/db/fleet-cred'),
           ('homes', '/home'), ('logs', '/var/log/fleet-node')]


def resources(image, hub, storage_class, namespace='fleet-workers', size='100Gi',
              entry_host='', entry_spec='slb.s1.small', egress=None, pull_secrets=('acr-pull',),
              github_proxy='', git_mirrors=(), cn_mirrors=False, cred_central='', egress_proxy='',
              egress_closed=False, cluster_caches=False, relay=''):
    dns, blocked, metadata, allow = _checked(image, hub, storage_class, pull_secrets, egress, github_proxy,
                                             git_mirrors, cred_central, egress_proxy, egress_closed,
                                             cn_mirrors, cluster_caches, namespace)
    if entry_host and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{0,252}', entry_host):
        raise ValueError('--entry-host is the load balancer address (an IP or a DNS name)')
    if entry_spec != 'clcu' and not re.fullmatch(r'slb\.s[0-9]\.[a-z0-9]+', entry_spec):
        raise ValueError('--entry-lb-spec is a CLB spec (slb.s1.small) or clcu')
    labels = {'app.kubernetes.io/name': 'fleet-managed-node'}
    # the namespace's network rules know a user pod by this (deploy/k8s/fleet-workers);
    # the template only — a StatefulSet's selector never changes
    pod_labels = dict(labels, **{'fleet/role': 'user'})
    mounts = [{'name': 'data', 'mountPath': path, 'subPath': sub} for sub, path in VOLUMES]
    env = [{'name': 'FLEET_HUB_URL', 'value': hub},
           {'name': 'FLEET_MACHINE_JOIN_FILE', 'value': '/run/fleet-join/machine'},
           # no primary login (#3526): every login is a person's, opened by the
           # hub's account op and rebuilt from linux-tenants/ at each start
           {'name': 'FLEET_NODE_LOGIN', 'value': 'none'},
           # the entry port's sshd (keys from the hub's list only, #3070)
           {'name': 'FLEET_ENTRY', 'value': '1'},
           {'name': 'FLEET_ENTRY_PORT', 'value': str(ENTRY_PORT)}]
    env += _devnet_env(github_proxy, git_mirrors, cn_mirrors, cred_central, egress_proxy, cluster_caches,
                       namespace)
    env += _relay_env(relay)
    if entry_host:
        # the door's address: on ACK the egress the hub sees is the NAT's, so the
        # entry reach report must name the load balancer (fleet_entry_reach.go)
        env.append({'name': 'CCQUOTA_FLEET_NODE_ROUTES', 'value': 'entry=%s:%d' % (entry_host, ENTRY_PORT)})
    container = dict({
        'name': 'fleet', 'image': image,
        'env': env,
        'resources': {'requests': {'cpu': '1', 'memory': '4Gi'}, 'limits': {'cpu': '2', 'memory': '8Gi'}},
        'securityContext': NODE_SECURITY,
        'ports': [{'name': 'ssh', 'containerPort': 22}, {'name': 'entry', 'containerPort': ENTRY_PORT}],
        'volumeMounts': mounts + [{'name': 'join', 'mountPath': '/run/fleet-join', 'readOnly': True}],
    }, **_probes())
    meta = {'name': 'fleet-linux', 'namespace': namespace}
    # The public door (#3213): the entry port alone. The system sshd's 22 stays
    # on the headless Service, inside the cluster; Local keeps the client's own
    # address for the entry sshd's log and its cut (#3070).
    door = {'apiVersion': 'v1', 'kind': 'Service',
            'metadata': {'name': 'fleet-linux-entry', 'namespace': namespace,
                         'annotations': entry_annotations(entry_spec)},
            'spec': {'type': 'LoadBalancer', 'externalTrafficPolicy': 'Local', 'selector': labels,
                     'ports': [{'name': 'entry', 'protocol': 'TCP', 'port': ENTRY_PORT,
                                'targetPort': ENTRY_PORT}]}}
    return [
        {'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': namespace}},
        {'apiVersion': 'v1', 'kind': 'Service', 'metadata': meta,
         'spec': {'clusterIP': 'None', 'selector': labels, 'ports': [{'name': 'ssh', 'port': 22}]}},
        door,
        {'apiVersion': 'apps/v1', 'kind': 'StatefulSet', 'metadata': meta,
         'spec': {'serviceName': 'fleet-linux', 'replicas': 1,
                  'selector': {'matchLabels': labels}, 'updateStrategy': {'type': 'OnDelete'},
                  'persistentVolumeClaimRetentionPolicy': {'whenDeleted': 'Retain', 'whenScaled': 'Retain'},
                  'template': {'metadata': {'labels': pod_labels}, 'spec': {
                      'automountServiceAccountToken': False, 'terminationGracePeriodSeconds': 120,
                      'imagePullSecrets': [{'name': n} for n in pull_secrets],
                      'initContainers': [egress_guard(image, dns, blocked, metadata, allow, egress_closed)],
                      'containers': [container],
                      'volumes': [{'name': 'join', 'secret': {'secretName': 'fleet-linux-join',
                                                           'optional': True, 'defaultMode': 256}},
                                  {'name': 'egress-run', 'emptyDir': {'medium': 'Memory', 'sizeLimit': '1Mi'}}]}},
                  'volumeClaimTemplates': [{'metadata': {'name': 'data'}, 'spec': {
                      'accessModes': ['ReadWriteOncePod'], 'storageClassName': storage_class,
                      'resources': {'requests': {'storage': size}}}}]}},
    ]


# One person's pod (#3550, EPIC #3500 C5). Its name is its stable hostname, the
# hub's machine name for it: u-<nonce> — a generic name, never the person's.
USER_POD_RE = r'u-[a-z0-9]{4,20}'
# what an idle pod is promised; the ceiling is the person's (the hub's setting
# fleet.user_pod_limits.<principal>, the same cpu=…,memory=…,disk=… text)
USER_POD_REQUESTS = {'cpu': '250m', 'memory': '1536Mi'}
USER_POD_LIMITS = {'cpu': '2', 'memory': '6Gi', 'disk': '50Gi'}
_CPU_RE = r'([1-9][0-9]{0,2}|[1-9][0-9]{0,5}m)'
_BYTES_RE = r'[1-9][0-9]{0,5}(Mi|Gi|Ti)'
_UNIT = {'Mi': 1, 'Gi': 1024, 'Ti': 1024 * 1024}


def _cpu_milli(q):
    return int(q[:-1]) if q.endswith('m') else int(q) * 1000


def _mebi(q):
    return int(q[:-2]) * _UNIT[q[-2:]]


def user_pod_limits(text=''):
    """'cpu=2,memory=6Gi,disk=50Gi' (any subset; '' = the defaults) -> the dict.
    A ceiling under what the pod is promised idle is refused."""
    got = dict(USER_POD_LIMITS)
    for part in [x.strip() for x in text.split(',') if x.strip()]:
        k, _, v = part.partition('=')
        k, v = k.strip(), v.strip()
        if k not in got:
            raise ValueError('--limits takes cpu=, memory=, disk=; not %r' % k)
        if not re.fullmatch(_CPU_RE if k == 'cpu' else _BYTES_RE, v):
            raise ValueError('--limits %s=%r: cpu is cores (2) or millicores (500m), memory/disk N{Mi,Gi,Ti}' % (k, v))
        got[k] = v
    if _cpu_milli(got['cpu']) < _cpu_milli(USER_POD_REQUESTS['cpu']):
        raise ValueError('--limits cpu=%s is under the idle request %s' % (got['cpu'], USER_POD_REQUESTS['cpu']))
    if _mebi(got['memory']) < _mebi(USER_POD_REQUESTS['memory']):
        raise ValueError('--limits memory=%s is under the idle request %s'
                         % (got['memory'], USER_POD_REQUESTS['memory']))
    if _mebi(got['disk']) < 1024:
        raise ValueError('--limits disk=%s: at least 1Gi' % got['disk'])
    return got


def _user_pod_container_resources(limits):
    return {'requests': dict(USER_POD_REQUESTS),
            'limits': {'cpu': limits['cpu'], 'memory': limits['memory']}}


def user_pod_resources(image, hub, storage_class, name, namespace='fleet-workers', limits=None, egress=None,
                       pull_secrets=('acr-pull',), github_proxy='', git_mirrors=(), cn_mirrors=False,
                       cred_central='', egress_proxy='', egress_closed=False, cluster_caches=False, relay=''):
    """One person's pod: a Deployment (one replica, Recreate), its ClusterIP
    Service (22, reached only through the cluster's door — C4) and its home disk
    (ReadWriteOncePod). Inside: one login (the hub's account op opens it — a
    second is refused), tmux, the node program, sshd; the machine-level loops are
    the cluster's (FLEET_NODE_PROFILE=user-pod). No Kubernetes credential, no
    fleet/principal label — the provisioner writes that once the pod is ready."""
    dns, blocked, metadata, allow = _checked(image, hub, storage_class, pull_secrets, egress, github_proxy,
                                             git_mirrors, cred_central, egress_proxy, egress_closed,
                                             cn_mirrors, cluster_caches, namespace)
    if not re.fullmatch(USER_POD_RE, name):
        raise ValueError('--user-pod is u-<nonce> (4-20 of a-z0-9), not %r' % name)
    if not re.fullmatch(r'[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?', namespace):
        raise ValueError('--namespace is a namespace name, not %r' % namespace)
    limits = limits or dict(USER_POD_LIMITS)
    labels = {'app.kubernetes.io/name': 'fleet-user-pod', 'fleet/role': 'user', 'fleet/pod': name}
    select = {'fleet/pod': name}
    meta = {'name': name, 'namespace': namespace, 'labels': labels}
    env = [{'name': 'FLEET_HUB_URL', 'value': hub},
           {'name': 'FLEET_MACHINE_JOIN_FILE', 'value': '/run/fleet-join/machine'},
           {'name': 'FLEET_NODE_LOGIN', 'value': 'none'},
           # the door is the cluster's one (C4): no entry port here
           {'name': 'FLEET_ENTRY', 'value': '0'},
           {'name': 'FLEET_NODE_PROFILE', 'value': 'user-pod'},
           # the machine hello says CapUserPod: the hub's machine is this pod
           {'name': 'FLEET_USER_POD', 'value': '1'}]
    env += _devnet_env(github_proxy, git_mirrors, cn_mirrors, cred_central, egress_proxy, cluster_caches,
                       namespace)
    env += _relay_env(relay)
    container = dict({
        'name': 'fleet', 'image': image, 'env': env,
        'resources': _user_pod_container_resources(limits),
        'securityContext': NODE_SECURITY,
        'ports': [{'name': 'ssh', 'containerPort': 22}],
        'volumeMounts': [{'name': 'data', 'mountPath': path, 'subPath': sub} for sub, path in VOLUMES]
                        + [{'name': 'join', 'mountPath': '/run/fleet-join', 'readOnly': True},
                           {'name': 'door', 'mountPath': '/run/fleet-door', 'readOnly': True}],
    }, **_probes())
    return [
        {'apiVersion': 'v1', 'kind': 'PersistentVolumeClaim', 'metadata': meta,
         'spec': {'accessModes': ['ReadWriteOncePod'], 'storageClassName': storage_class,
                  'resources': {'requests': {'storage': limits['disk']}}}},
        {'apiVersion': 'v1', 'kind': 'Service', 'metadata': meta,
         'spec': {'type': 'ClusterIP', 'selector': select,
                  'ports': [{'name': 'ssh', 'protocol': 'TCP', 'port': 22, 'targetPort': 22}]}},
        {'apiVersion': 'apps/v1', 'kind': 'Deployment', 'metadata': meta,
         # Recreate: the home disk is ReadWriteOncePod — the old pod lets go first
         'spec': {'replicas': 1, 'strategy': {'type': 'Recreate'}, 'revisionHistoryLimit': 2,
                  'selector': {'matchLabels': select},
                  'template': {'metadata': {'labels': labels}, 'spec': {
                      'hostname': name, 'enableServiceLinks': False,
                      'automountServiceAccountToken': False, 'terminationGracePeriodSeconds': 120,
                      'imagePullSecrets': [{'name': n} for n in pull_secrets],
                      'initContainers': [egress_guard(image, dns, blocked, metadata, allow, egress_closed)],
                      'containers': [container],
                      'volumes': [{'name': 'data', 'persistentVolumeClaim': {'claimName': name}},
                                  {'name': 'join', 'secret': {'secretName': name + '-join',
                                                           'optional': True, 'defaultMode': 256}},
                                  # the door's public key (C4, #3549): the one key this
                                  # pod's sshd takes, read at each login — a rotated
                                  # Secret is the new key, no restart
                                  {'name': 'door', 'secret': {'secretName': DOOR_PUB_SECRET,
                                                           'optional': True, 'defaultMode': 0o444}},
                                  {'name': 'egress-run', 'emptyDir': {'medium': 'Memory', 'sizeLimit': '1Mi'}}]}}}},
    ]


# The cluster's one door (#3549, EPIC #3500 C4): ONE load balancer for every
# person whose home is their own pod. Two replicas of the image in door mode —
# the entry port's sshd (keys only, the hub's list, PerSourcePenalties) whose
# ForceCommand hands each login to its own pod's Service (bin/fleet-door.sh).
# Its Secret (DOOR_SECRET) holds what every replica shares: the host key, the
# key to the pods and the node token; the pods mount DOOR_PUB_SECRET (the key's
# public half alone).
DOOR_NAME = 'fleet-door'
DOOR_SECRET = 'fleet-door'
DOOR_PUB_SECRET = 'fleet-door-pub'


def door_resources(image, hub, namespace='fleet-workers', replicas=2, entry_spec='slb.s1.small',
                   pull_secrets=('acr-pull',)):
    """The door: its LoadBalancer Service (22022 alone, externalTrafficPolicy
    Local — the client's own address for PerSourcePenalties and the record) and
    its Deployment. No disk, no login, no Kubernetes credential."""
    if not image or not hub:
        raise ValueError('--door needs --image and --hub')
    if not re.fullmatch(r'[^\s]+@sha256:[a-f0-9]{64}', image):
        raise ValueError('pin the deployed image by sha256 digest')
    if not re.fullmatch(r'https://[^\s/]+(/[^\s]*)?', hub):
        raise ValueError('--hub is https://…')
    if not re.fullmatch(r'[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?', namespace):
        raise ValueError('--namespace is a namespace name, not %r' % namespace)
    if not 1 <= replicas <= 5:
        raise ValueError('--door-replicas is 1-5')
    if entry_spec != 'clcu' and not re.fullmatch(r'slb\.s[0-9]\.[a-z0-9]+', entry_spec):
        raise ValueError('--entry-lb-spec is a CLB spec (slb.s1.small) or clcu')
    labels = {'app.kubernetes.io/name': 'fleet-door', 'fleet/role': 'door'}
    meta = {'name': DOOR_NAME, 'namespace': namespace, 'labels': labels}
    env = [{'name': 'FLEET_HUB_URL', 'value': hub},
           {'name': 'FLEET_NODE_PROFILE', 'value': 'door'},
           {'name': 'FLEET_NODE_LOGIN', 'value': 'none'},
           {'name': 'FLEET_DOOR', 'value': '1'},
           {'name': 'FLEET_ENTRY', 'value': '1'},
           {'name': 'FLEET_ENTRY_PORT', 'value': str(ENTRY_PORT)},
           {'name': 'FLEET_DOOR_NAMESPACE', 'value': namespace},
           {'name': 'FLEET_DOOR_SECRET', 'value': '/run/fleet-door'}]
    tcp = {'tcpSocket': {'port': ENTRY_PORT}}
    container = {
        'name': 'door', 'image': image, 'env': env,
        'resources': {'requests': {'cpu': '50m', 'memory': '64Mi'}, 'limits': {'cpu': '1', 'memory': '512Mi'}},
        'securityContext': NODE_SECURITY,
        'ports': [{'name': 'entry', 'containerPort': ENTRY_PORT}],
        'volumeMounts': [{'name': 'state', 'mountPath': '/var/db/fleet-node'},
                         {'name': 'logs', 'mountPath': '/var/log/fleet-node'},
                         {'name': 'secret', 'mountPath': '/run/fleet-door', 'readOnly': True}],
        'startupProbe': dict(tcp, periodSeconds=5, failureThreshold=60),
        'readinessProbe': dict(tcp, periodSeconds=10),
        'livenessProbe': {'exec': {'command': ['python3', '-I', '/usr/local/lib/fleet-image-stage.py', 'live']},
                          'periodSeconds': 30, 'failureThreshold': 4},
    }
    return [
        {'apiVersion': 'v1', 'kind': 'Service', 'metadata': dict(meta, annotations=entry_annotations(entry_spec)),
         'spec': {'type': 'LoadBalancer', 'externalTrafficPolicy': 'Local', 'selector': {'fleet/role': 'door'},
                  'ports': [{'name': 'entry', 'protocol': 'TCP', 'port': ENTRY_PORT, 'targetPort': ENTRY_PORT}]}},
        {'apiVersion': 'apps/v1', 'kind': 'Deployment', 'metadata': meta,
         'spec': {'replicas': replicas, 'revisionHistoryLimit': 2,
                  'selector': {'matchLabels': {'fleet/role': 'door'}},
                  'template': {'metadata': {'labels': labels}, 'spec': {
                      'automountServiceAccountToken': False, 'enableServiceLinks': False,
                      'terminationGracePeriodSeconds': 30,
                      'imagePullSecrets': [{'name': n} for n in pull_secrets],
                      # two replicas, two machines when the cluster has them
                      'affinity': {'podAntiAffinity': {'preferredDuringSchedulingIgnoredDuringExecution': [
                          {'weight': 100, 'podAffinityTerm': {'topologyKey': 'kubernetes.io/hostname',
                                                              'labelSelector': {'matchLabels': {'fleet/role': 'door'}}}}]}},
                      'containers': [container],
                      'volumes': [{'name': 'state', 'emptyDir': {}},
                                  {'name': 'logs', 'emptyDir': {}},
                                  {'name': 'secret', 'secret': {'secretName': DOOR_SECRET, 'defaultMode': 0o400}}]}}}},
    ]


def user_pod_limits_patch(limits):
    """The patch that moves one pod's ceiling (kubectl patch deploy <name>
    --type strategic): only that Deployment rolls, nobody else's."""
    return {'spec': {'template': {'spec': {'containers': [
        {'name': 'fleet', 'resources': _user_pod_container_resources(limits)}]}}}}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--image', default='')
    p.add_argument('--hub', default='')
    p.add_argument('--relay', default='', metavar='URL',
                   help="the deployment's subscription relay (https://relay.example.com); empty = none")
    p.add_argument('--storage-class', default='')
    p.add_argument('--namespace', default='fleet-workers')
    p.add_argument('--entry-host', default='',
                   help="the door's load balancer address (kubectl get svc fleet-linux-entry); "
                        'empty until the CLB exists')
    p.add_argument('--pull-secret', action='append', dest='pull_secrets',
                   help='image-pull Secret in the namespace (repeatable; default acr-pull). On ACK: '
                        'kubectl -n fleet-workers get secret | grep acr-credential')
    p.add_argument('--entry-lb-spec', default='slb.s1.small', help='CLB spec, or clcu (pay by use)')
    # the egress guard's ranges (#3281; docs/dev/MANAGED-LINUX.md «Egress guard»)
    p.add_argument('--egress-dns', default=EGRESS['dns'], help='kube-dns ClusterIP: the one private address allowed (53)')
    p.add_argument('--egress-metadata', default=EGRESS['metadata'], help='cloud metadata address, cut')
    p.add_argument('--egress-pod-cidr', default=EGRESS['pod_cidr'], help="the cluster's pod range, cut")
    p.add_argument('--egress-service-cidr', default=EGRESS['service_cidr'], help="the cluster's service range, cut")
    p.add_argument('--egress-private', default=','.join(EGRESS['private']),
                   help='comma-separated VPC / private ranges, cut')
    p.add_argument('--egress-allow', action='append', default=[], metavar='IP[/n]:PORT',
                   help='an in-cluster destination the guard lets through, tcp (repeatable) - e.g. the '
                        "git-mirror Service's ClusterIP:9418")
    # the dev network (#3348; docs/dev/MANAGED-LINUX.md «Dev network»)
    p.add_argument('--github-proxy', default='', help="git's and gh's road to GitHub: http://RELAY:3128 (extras/gh-relay)")
    p.add_argument('--git-mirror', action='append', default=[], metavar='MIRROR=UPSTREAM',
                   help='fetch UPSTREAM (https://github.com/OWNER/REPO.git) from MIRROR; pushes stay on GitHub (repeatable)')
    p.add_argument('--cn-mirrors', action='store_true',
                   help='npmmirror / goproxy.cn / node dist mirror for every login (a pod outside the cluster '
                        'layout; in it, --cluster-caches)')
    p.add_argument('--cluster-caches', action='store_true',
                   help="every login's npm / pip / Go packages from the cluster's caches in --namespace "
                        '(fleet-npm:4873, fleet-pypi:3141, fleet-goproxy:3000 - deploy/k8s/caches)')
    # the cluster's shared services (#3547; docs/dev/MANAGED-LINUX.md «Shared services»)
    p.add_argument('--cred-central', default='', metavar='URL',
                   help='the cluster credential proxy (http://fleet-credproxy.fleet-workers.svc.cluster.local): '
                        'every session routes central, no subscription credential is leased into or kept in the pod')
    p.add_argument('--egress-proxy', default='', metavar='URL',
                   help="every login's HTTPS_PROXY: the cluster's one egress (http://fleet-egress.fleet-workers.svc.cluster.local:3128)")
    p.add_argument('--egress-closed', action='store_true',
                   help='the guard rejects the public internet too: out only through --egress-allow destinations '
                        "(the egress and credproxy Services' ClusterIPs, the hub's address)")
    # one person's pod (#3550; docs/dev/MANAGED-LINUX.md «User pods»)
    p.add_argument('--user-pod', default='', metavar='u-NONCE',
                   help="render one person's pod (Deployment + Service + home disk) instead of the shared node")
    p.add_argument('--limits', default='', metavar='cpu=2,memory=6Gi,disk=50Gi',
                   help="the pod's ceiling: the hub's fleet.user_pod_limits.<principal> value (default %s)"
                        % ','.join('%s=%s' % kv for kv in USER_POD_LIMITS.items()))
    # the cluster's one door (#3549; docs/MANAGED-LINUX.md «The door»)
    p.add_argument('--door', action='store_true',
                   help="render the cluster's one door (LoadBalancer + Deployment) instead of a node")
    p.add_argument('--door-replicas', type=int, default=2)
    p.add_argument('--limits-patch', action='store_true',
                   help='print only the patch that moves --limits on a running pod (rolls that pod alone)')
    args = p.parse_args()
    egress = {'dns': args.egress_dns, 'metadata': args.egress_metadata, 'pod_cidr': args.egress_pod_cidr,
              'service_cidr': args.egress_service_cidr,
              'private': [c.strip() for c in args.egress_private.split(',') if c.strip()],
              'allow': args.egress_allow}
    try:
        if args.limits_patch:
            print(json.dumps(user_pod_limits_patch(user_pod_limits(args.limits)), indent=2))
            raise SystemExit(0)
        if args.door:
            items = door_resources(args.image, args.hub, args.namespace, args.door_replicas, args.entry_lb_spec,
                                   pull_secrets=args.pull_secrets or ['acr-pull'])
            print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': items}, indent=2))
            raise SystemExit(0)
        missing = [f for f in ('image', 'hub', 'storage_class') if not getattr(args, f)]
        if missing:
            p.error('the following arguments are required: ' + ', '.join('--' + f.replace('_', '-') for f in missing))
        if args.user_pod:
            items = user_pod_resources(args.image, args.hub, args.storage_class, args.user_pod, args.namespace,
                                       limits=user_pod_limits(args.limits), egress=egress,
                                       pull_secrets=args.pull_secrets or ['acr-pull'],
                                       github_proxy=args.github_proxy, git_mirrors=args.git_mirror,
                                       cn_mirrors=args.cn_mirrors, cred_central=args.cred_central,
                                       egress_proxy=args.egress_proxy, egress_closed=args.egress_closed,
                                       cluster_caches=args.cluster_caches, relay=args.relay)
        else:
            items = resources(args.image, args.hub, args.storage_class, args.namespace,
                              entry_host=args.entry_host, entry_spec=args.entry_lb_spec, egress=egress,
                              pull_secrets=args.pull_secrets or ['acr-pull'], github_proxy=args.github_proxy,
                              git_mirrors=args.git_mirror, cn_mirrors=args.cn_mirrors,
                              cred_central=args.cred_central, egress_proxy=args.egress_proxy,
                              egress_closed=args.egress_closed, cluster_caches=args.cluster_caches, relay=args.relay)
    except ValueError as e:
        p.error(str(e))
    print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': items}, indent=2))
