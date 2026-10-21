#!/usr/bin/env python3
"""Render a single managed ACK node. Output is a kubectl-compatible JSON List."""
import argparse
import base64
import ipaddress
import json
import re
import sys

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

# A mirror only the people on its list may read (#4002): an internal repo. The
# mirror speaks git:// with no login and flannel enforces no NetworkPolicy, so the
# wall is each user pod's own egress guard: the mirror's address let through, its
# insteadOf (FLEET_GIT_MIRRORS) and the pod label fleet/mirror-<repo> are rendered
# ONLY into the pod of a login on that mirror's list. Anyone else's pod gets none
# of the three — the guard rejects the address, and git fetches GitHub through the
# egress with the person's own credentials (GitHub decides). One entry:
#   {"mirror": "git://HOST:PORT/PATH.git", "upstream": "https://github.com/OWNER/REPO.git",
#    "allow": "IP:PORT" (the mirror Service's ClusterIP), "logins": ["name", ...]}
# The list lives in the provisioner template's user_pod.private_mirrors (ConfigMap
# fleet-provisioner) or a hand render's --private-mirrors file; a running pod
# follows an edit through --mirror-grant (deploy/k8s/provisioner/README.md).
PRIVATE_MIRROR_KEYS = ('mirror', 'upstream', 'allow', 'logins')
MIRROR_LABEL = 'fleet/mirror-'


def private_mirrors_checked(entries):
    """The entries, checked: [{pair, upstream, dest, allow_rule, logins, label}]."""
    if not isinstance(entries, (list, tuple)):
        raise ValueError('private_mirrors is a list of {%s}' % ', '.join(PRIVATE_MIRROR_KEYS))
    out, seen = [], set()
    for e in entries:
        if not isinstance(e, dict) or sorted(e) != sorted(PRIVATE_MIRROR_KEYS):
            raise ValueError('a private mirror is {%s}, not %r' % (', '.join(PRIVATE_MIRROR_KEYS), e))
        pair = '%s=%s' % (e['mirror'], e['upstream'])
        if not all(isinstance(e[k], str) for k in ('mirror', 'upstream', 'allow')) \
                or not re.fullmatch(GIT_MIRROR_RE, pair):
            raise ValueError('a private mirror is git://HOST/PATH + https://github.com/OWNER/REPO.git, not %r' % pair)
        cidr, port = egress_allow(e['allow'])
        if not cidr.endswith('/32'):
            raise ValueError("a private mirror's allow is its one address IP:PORT, not %r" % e['allow'])
        logins = e['logins']
        if not isinstance(logins, list) or not all(isinstance(x, str) and re.fullmatch(POD_LOGIN_RE, x)
                                                   for x in logins):
            raise ValueError("a private mirror's logins are a list of login names, not %r" % (logins,))
        repo = e['upstream'].rsplit('/', 1)[1][:-len('.git')].lower()
        label = MIRROR_LABEL + repo
        if not re.fullmatch(r'[a-z0-9]([a-z0-9._-]{0,61}[a-z0-9])?', label.split('/', 1)[1]):
            raise ValueError('cannot make a pod label of the repo name %r' % repo)
        if e['upstream'] in seen:
            raise ValueError('the upstream %s has two private mirrors' % e['upstream'])
        seen.add(e['upstream'])
        out.append({'pair': pair, 'upstream': e['upstream'], 'dest': (cidr, port), 'logins': set(logins),
                    'allow_rule': '-A OUTPUT -d %s -p tcp -m tcp --dport %d -j ACCEPT' % (cidr, port),
                    'label': label})
    return out


def _private_conflicts(checked, git_mirrors, allow):
    """A private mirror the open settings would hand everyone: refused."""
    for m in checked:
        for g in git_mirrors:
            if g.partition('=')[2] == m['upstream']:
                raise ValueError('%s is a private mirror\'s upstream: it cannot be in --git-mirror too' % m['upstream'])
        net = ipaddress.IPv4Network(m['dest'][0])
        for cidr, port in allow:
            if port == m['dest'][1] and net.overlaps(ipaddress.IPv4Network(cidr)):
                raise ValueError('--egress-allow %s:%d opens the private mirror of %s to every pod'
                                 % (cidr, port, m['upstream']))


def private_mirror_grant(checked, login):
    """What the pod of `login` gets: the entries whose list names it."""
    return [m for m in checked if login in m['logins']]


def mirror_grant_patch(dep, entries):
    """A running user pod's Deployment -> the JSON patch that makes its mirror
    access what `entries` now say for its login (#4002): the template's
    fleet/mirror-* labels, FLEET_GIT_MIRRORS in each container that carries the
    login, the egress guard's allow lines. Anything not a private mirror's is left
    byte for byte; the patch tests the resourceVersion, so a Deployment changed in
    between is refused by the API server rather than overwritten."""
    checked = private_mirrors_checked(entries)
    if (dep.get('kind') != 'Deployment'
            or ((dep.get('metadata') or {}).get('labels') or {}).get('fleet/role') != 'user'):
        raise ValueError("--mirror-grant reads one user pod's Deployment (kubectl get deploy u-… -o json)")
    tpl = dep['spec']['template']
    spec = tpl['spec']
    login = ''
    for c in spec.get('containers') or []:
        for e in c.get('env') or []:
            if c['name'] == 'fleet' and e['name'] == 'FLEET_POD_LOGIN':
                login = e.get('value', '')
    if not re.fullmatch(POD_LOGIN_RE, login):
        raise ValueError('the Deployment names no pod login (FLEET_POD_LOGIN): not a #3757 user pod')
    granted = private_mirror_grant(checked, login)
    ours = {m['label'] for m in checked}
    labels = {k: v for k, v in (tpl['metadata'].get('labels') or {}).items() if k not in ours}
    labels.update({m['label']: '1' for m in granted})
    upstreams = {m['upstream'] for m in checked}
    ops = [{'op': 'test', 'path': '/metadata/resourceVersion', 'value': dep['metadata']['resourceVersion']},
           {'op': 'replace', 'path': '/spec/template/metadata/labels', 'value': labels}]
    for kind in ('initContainers', 'containers'):
        for i, c in enumerate(spec.get(kind) or []):
            env = c.get('env') or []
            if c['name'] == 'egress-guard':
                ops.append({'op': 'replace', 'path': '/spec/template/spec/%s/%d/command' % (kind, i),
                            'value': c['command'][:-1] + [_guard_regrant(c['command'][-1], checked, granted)]})
            if not any(e['name'] == 'FLEET_POD_LOGIN' for e in env):
                continue
            pairs = []
            for e in env:
                if e['name'] == 'FLEET_GIT_MIRRORS':
                    pairs = [t for t in e.get('value', '').split() if t.partition('=')[2] not in upstreams]
            pairs += [m['pair'] for m in granted]
            new = [e for e in env if e['name'] != 'FLEET_GIT_MIRRORS']
            if pairs:
                new.append({'name': 'FLEET_GIT_MIRRORS', 'value': ' '.join(pairs)})
            ops.append({'op': 'replace', 'path': '/spec/template/spec/%s/%d/env' % (kind, i), 'value': new})
    return ops


def _guard_regrant(script, checked, granted):
    lines = [ln for ln in script.split('\n') if ln not in {m['allow_rule'] for m in checked}]
    cut = next((i for i, ln in enumerate(lines) if re.fullmatch(r'-A OUTPUT -d \S+ -j REJECT', ln)), None)
    if cut is None:
        raise ValueError("the egress guard's script has no REJECT line to put an allow before")
    return '\n'.join(lines[:cut] + [m['allow_rule'] for m in granted] + lines[cut:])

# The cluster's shared services (#3547, EPIC #3500 C2): the credential proxy's
# in-cluster Service (deploy/k8s/credproxy/fleet-workers) and the one egress
# (deploy/k8s/egress). Plain http only to a cluster-local name — the pass rides
# inside the cluster, never a subscription credential.
CENTRAL_RE = r'(https://[A-Za-z0-9.-]+|http://[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.svc\.cluster\.local)(:[0-9]{1,5})?'
EGRESS_PROXY_RE = r'http://[A-Za-z0-9.-]+:[0-9]{1,5}'
# The hub's own Service (#4175): a pod's machine-to-hub calls (its control link,
# a session's pass, the svc run's ticket) dial it inside the cluster instead of
# the public door — whose host the egress lists no more than any other (#4112,
# #4172: 403). FLEET_HUB_URL stays the public address: the hub's identity, links
# for people. Plain http only to a cluster-local name, like the credential proxy
# (deploy/k8s/credproxy/fleet-workers already reaches the hub this way). The
# guard cuts the service range: the hub's ClusterIP:PORT goes in --egress-allow.
HUB_INTERNAL_RE = r'http://[a-z0-9]([a-z0-9-]*[a-z0-9])?\.[a-z0-9]([a-z0-9-]*[a-z0-9])?\.svc\.cluster\.local(:[0-9]{1,5})?'


def hub_internal_env(hub_internal):
    """[] (none named — byte for byte as before) or the one FLEET_HUB_INTERNAL_URL."""
    if not hub_internal:
        return []
    if not re.fullmatch(HUB_INTERNAL_RE, hub_internal):
        raise ValueError('--hub-internal is http://NAME.NS.svc.cluster.local[:PORT] (the hub\'s Service), not %r'
                         % hub_internal)
    return [{'name': 'FLEET_HUB_INTERNAL_URL', 'value': hub_internal}]
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


def c9_egress_guard(image, destinations, ingress=()):
    """Explicit C9 test profile; never selected by a production template.

    Only a NEW, exclusively owned test pod may use this init container. The
    C9 admission/binding gate must run before it. No wildcard/CIDR, implicit
    loopback, general DNS, or previously established outbound connection is
    allowed. DNS, when used, is an exact route to the run's pinned resolver.
    Both address families must install and read back; disabled IPv6 is not
    inferred from an ip6tables error. We never flush another owner's rules.
    """
    def checked(routes):
        result = []
        for route in routes:
            if not isinstance(route, dict) or set(route) != {'ip', 'port', 'protocol'}:
                raise ValueError('C9 route needs only ip, port and protocol')
            ip = ipaddress.ip_address(route['ip'])
            port, protocol = route['port'], route['protocol']
            if ip.is_unspecified or ip.is_multicast or getattr(ip, 'ipv4_mapped', None):
                raise ValueError('C9 needs a single canonical unicast address')
            if type(port) is not int or not 1 <= port <= 65535 or protocol not in ('tcp', 'udp'):
                raise ValueError('C9 route has an invalid transport')
            result.append((ip, port, protocol))
        return result

    outgoing, incoming = checked(destinations), checked(ingress)
    rules = []
    for family in (4, 6):
        lines = ['*filter', ':INPUT DROP [0:0]', ':FORWARD DROP [0:0]', ':OUTPUT DROP [0:0]',
                 ':C9_RESTORED - [0:0]',
                 '-A INPUT -m conntrack --ctstate ESTABLISHED --ctdir REPLY -j ACCEPT',
                 '-A OUTPUT -m conntrack --ctstate ESTABLISHED --ctdir REPLY -j ACCEPT']
        for chain, flag, routes in (('OUTPUT', '-d', outgoing), ('INPUT', '-s', incoming)):
            for ip, port, protocol in routes:
                if ip.version == family:
                    lines.append('-A %s %s %s/%d -p %s --dport %d -j ACCEPT' %
                                 (chain, flag, ip, ip.max_prefixlen, protocol, port))
        lines += ['-A OUTPUT -j C9_RESTORED', '-A OUTPUT -j REJECT', '-A INPUT -j REJECT', 'COMMIT']
        rules.append('\n'.join(lines))
    script = '''set -eu
# Refuse existing listeners/connections before changing this private namespace.
sockets=$(ss -H -t -u -a -n)
[ -z "$sockets" ] || { echo C9_EXISTING_SOCKET >&2; exit 1; }
ok=
for b in nft legacy; do
  command -v iptables-$b-restore >/dev/null 2>&1 || continue
  command -v ip6tables-$b-restore >/dev/null 2>&1 || continue
  # A nonempty ruleset belongs to somebody else: do not replace or flush it.
  current4=$(iptables-$b -S)
  current6=$(ip6tables-$b -S)
  printf '%%s\\n' "$current4" | awk '$1 != "-P" { exit 1 }' || exit 1
  printf '%%s\\n' "$current6" | awk '$1 != "-P" { exit 1 }' || exit 1
  ok=$b; break
done
[ -n "$ok" ] || { echo C9_NO_DUAL_STACK_BACKEND >&2; exit 1; }
printf '%%s\\n' '%s' | iptables-$ok-restore -w 1
printf '%%s\\n' '%s' | ip6tables-$ok-restore -w 1
iptables-$ok -S OUTPUT | grep -qFx -- '-P OUTPUT DROP'
ip6tables-$ok -S OUTPUT | grep -qFx -- '-P OUTPUT DROP'
echo C9_GUARD_READY
''' % tuple(rules)
    # Reuse the ordinary init container's bounded resources and capability set.
    guard = egress_guard(image, '192.0.2.53', [], '192.0.2.1/32')
    guard['command'] = ['/bin/sh', '-ec', script]
    return guard


def _egress_ranges(egress):
    """The egress guard's (dns, blocked, metadata, allow) from an egress dict over EGRESS."""
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
    return dns, blocked, metadata, allow


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
    dns, blocked, metadata, allow = _egress_ranges(egress)
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


# Each kind of pod runs as its own ServiceAccount, and none of them mounts a
# token (#3558, EPIC #3500 C16 · 共同约定 2): the accounts are
# deploy/k8s/fleet-workers/serviceaccounts.yaml's, every one with
# automountServiceAccountToken false — only fleet-ops (read) and
# fleet-provisioner (write, by template) carry one. A pod naming an account the
# namespace has not got is never created: apply fleet-workers first.
SA_NODE = 'fleet-linux'
SA_USER = 'fleet-user'
SA_DOOR = 'fleet-door'
SA_JOB = 'fleet-job'


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
                      'serviceAccountName': SA_NODE,
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
# The node's own disk (claude-fleet#4729). A container that asks for no
# ephemeral-storage is the kubelet's FIRST pick when the shared node runs short —
# usage above a request of 0 — so on 2026-10-18 a person's pod (1.6 MiB of it)
# and the door (100 KiB) were evicted for a disk other tenants filled. Each
# fleet container asks for what it holds and is capped, and a disk-backed
# emptyDir has a sizeLimit: past it only that pod goes, never the node's others.
# The person's work lives on the home disk (the PVC); /tmp is tmux's sockets and
# scratch. A pod's ceiling is the SUM of its containers' limits, so the fleet
# container's covers /tmp's.
USER_POD_TMP = '6Gi'
USER_POD_EPHEMERAL = {'fleet': {'requests': '1Gi', 'limits': '8Gi'},
                      'sshd': {'requests': '64Mi', 'limits': '1Gi'}}
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


def _ephemeral(res, eph):
    """`res` (requests / limits) with the container's ephemeral-storage added."""
    return {k: dict(v, **{'ephemeral-storage': eph[k]}) for k, v in res.items()}


def _user_pod_container_resources(limits):
    return _ephemeral({'requests': dict(USER_POD_REQUESTS),
                       'limits': {'cpu': limits['cpu'], 'memory': limits['memory']}}, USER_POD_EPHEMERAL['fleet'])


# A person's pod runs as that person (#3757, EPIC #3500 C16 · its second half):
# one login, fixed when the pod is made (the spare's fleetu<N>, or a moved
# person's own name and number). Two containers —
#   fleet   the node as the login: supervisor, node program, the login's own
#           credential proxy, tmux and every session; runAsNonRoot, ALL dropped,
#           nothing added. Credentials route to the cluster proxy (--cred-central
#           is required: no fleetcred role user, nothing leased into the pod), and
#           the runtime is the image's (FLEET_NODE_UPDATE_OWNER=image): a new
#           release is a new image, the provisioner's to roll.
#   sshd    the login step and nothing else: root with only what sshd needs to
#           take a key, set up a terminal and become the login (POD_SSHD_CAPS),
#           on 2222 so it needs no NET_BIND_SERVICE; the Service's 22 maps to it.
# /etc/passwd and /etc/group are the image's plus the login's line, written once
# by the pod-etc init — neither root nor the login (65534) — into an emptyDir
# both containers mount read-only: nobody in the pod can make themselves uid 0.
# No shared process namespace: `ps` in fleet shows the login alone, in sshd root
# and the login it switched to.
POD_SSHD_PORT = 2222
POD_SSHD_CAPS = ['CHOWN', 'SETUID', 'SETGID', 'SYS_CHROOT', 'KILL', 'AUDIT_WRITE']
POD_ETC_UID = 65534
# where a pod's sshd keeps its host key across rebuilds (T743): a subPath of the
# person's own disk that only the sshd container (root) mounts
POD_SSHD_KEEP = '/var/lib/fleet-sshd-key'
POD_SSHD_KEY_SCRIPT = (
    'K=%(k)s\nchmod 700 "$K"\n'
    'if [ ! -s "$K/host" ]; then rm -f "$K/host.pub"; ssh-keygen -q -t ed25519 -N "" -C fleet-pod -f "$K/host"; fi\n'
    'if [ ! -s "$K/host.pub" ]; then ssh-keygen -y -f "$K/host" > "$K/host.pub.tmp"; mv "$K/host.pub.tmp" "$K/host.pub"; fi\n'
    'chown 0:0 "$K/host" "$K/host.pub"; chmod 600 "$K/host"; chmod 644 "$K/host.pub"\n'
    'chmod 711 /run/sshd-key\ncp "$K/host" /run/sshd-key/host; cp "$K/host.pub" /run/sshd-key/host.pub\n'
    'chmod 600 /run/sshd-key/host; chmod 644 /run/sshd-key/host.pub\n') % {'k': POD_SSHD_KEEP}
POD_UID_RANGE = (1000, 60000)
POD_LOGIN_RE = r'(?=[a-z0-9]*[a-z])[a-z0-9]{2,16}'
POD_RESERVED = ('root', 'admin', 'daemon', 'nobody', 'guest', 'shared', 'fleetcred', 'sshd', 'fleet')
SEED_LINUX = '/opt/claude-fleet/seed/current/bin/fleet-node-linux.py'
# what pod-etc writes (fleet-node-linux.py pod-etc) and where each container sees it
POD_ETC_FILES = {'passwd': '/etc/passwd', 'group': '/etc/group', 'gitconfig': '/etc/gitconfig',
                 'fleet-devnet.env': '/etc/fleet-devnet.env'}


def pod_login(login, uid):
    if not isinstance(login, str) or not re.fullmatch(POD_LOGIN_RE, login) or login in POD_RESERVED:
        raise ValueError('--login is 2-16 of a-z0-9 with a letter, not a reserved name; not %r' % login)
    if not isinstance(uid, int) or isinstance(uid, bool) or not POD_UID_RANGE[0] <= uid < POD_UID_RANGE[1] \
            or uid == POD_ETC_UID:
        raise ValueError('--uid is a login\'s number, %d-%d; not %r' % (POD_UID_RANGE + (uid,)))
    return login, uid


def _etc_mounts(names):
    return [{'name': 'pod-etc', 'mountPath': POD_ETC_FILES.get(n, '/etc/ssh/' + n), 'subPath': n,
             'readOnly': True} for n in names]


def user_pod_resources(image, hub, storage_class, name, namespace='fleet-workers', limits=None, egress=None,
                       pull_secrets=('acr-pull',), github_proxy='', git_mirrors=(), cn_mirrors=False,
                       cred_central='', egress_proxy='', egress_closed=False, cluster_caches=False, relay='',
                       login='', uid=0, private_mirrors=(), hub_internal=''):
    """One person's pod: a Deployment (one replica, Recreate), its ClusterIP
    Service (22, reached only through the cluster's door — C4) and its home disk
    (ReadWriteOncePod). Inside: one login, the one it was made for (--login /
    --uid; the hub's account op opens it, any other name is refused), tmux, the
    node program as that login, sshd for the login step; the machine-level loops
    are the cluster's (FLEET_NODE_PROFILE=user-pod). No Kubernetes credential, no
    fleet/principal label — the provisioner writes that once the pod is ready.
    `private_mirrors` (#4002): the mirrors only their lists may read; this pod
    gets the ones whose list names its login, and nothing of the others.
    `hub_internal` (#4175): the hub's Service its machine-to-hub calls dial."""
    dns, blocked, metadata, allow = _checked(image, hub, storage_class, pull_secrets, egress, github_proxy,
                                             git_mirrors, cred_central, egress_proxy, egress_closed,
                                             cn_mirrors, cluster_caches, namespace)
    private = private_mirrors_checked(private_mirrors)
    _private_conflicts(private, git_mirrors, allow)
    if not re.fullmatch(USER_POD_RE, name):
        raise ValueError('--user-pod is u-<nonce> (4-20 of a-z0-9), not %r' % name)
    if not re.fullmatch(r'[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?', namespace):
        raise ValueError('--namespace is a namespace name, not %r' % namespace)
    if not login:
        raise ValueError('--user-pod needs --login and --uid: a person\'s pod is built for its one login (#3757)')
    login, uid = pod_login(login, uid)
    granted = private_mirror_grant(private, login)
    git_mirrors = list(git_mirrors) + [m['pair'] for m in granted]
    allow = list(allow) + [m['dest'] for m in granted]
    if not cred_central:
        raise ValueError('--user-pod needs --cred-central: the pod holds no subscription credential (#3757)')
    limits = limits or dict(USER_POD_LIMITS)
    labels = {'app.kubernetes.io/name': 'fleet-user-pod', 'fleet/role': 'user', 'fleet/pod': name}
    select = {'fleet/pod': name}
    meta = {'name': name, 'namespace': namespace, 'labels': labels}
    devnet = _devnet_env(github_proxy, git_mirrors, cn_mirrors, cred_central, egress_proxy, cluster_caches,
                         namespace)
    who = [{'name': 'FLEET_POD_LOGIN', 'value': login}, {'name': 'FLEET_POD_UID', 'value': str(uid)}]
    env = [{'name': 'FLEET_HUB_URL', 'value': hub},
           {'name': 'FLEET_MACHINE_JOIN_FILE', 'value': '/run/fleet-join/machine'},
           {'name': 'FLEET_NODE_LOGIN', 'value': 'none'},
           # the door is the cluster's one (C4): no entry port here
           {'name': 'FLEET_ENTRY', 'value': '0'},
           {'name': 'FLEET_NODE_PROFILE', 'value': 'user-pod'},
           # the machine hello says CapUserPod: the hub's machine is this pod
           {'name': 'FLEET_USER_POD', 'value': '1'},
           # the image's runtime: the login cannot (and need not) switch it
           {'name': 'FLEET_NODE_UPDATE_OWNER', 'value': 'image'},
           {'name': 'HOME', 'value': '/home/' + login}] + who
    env += hub_internal_env(hub_internal)
    env += devnet
    env += _relay_env(relay)
    # fresh dicts each time: no two containers share one object (a patch of one stays its own)
    drop = lambda: {'drop': ['ALL']}  # noqa: E731
    rt = lambda: {'type': 'RuntimeDefault'}  # noqa: E731
    data = [{'name': 'data', 'mountPath': path, 'subPath': sub} for sub, path in VOLUMES]
    shared = [{'name': 'tmp', 'mountPath': '/tmp'}]
    fleet = dict({
        'name': 'fleet', 'image': image, 'env': env,
        'resources': _user_pod_container_resources(limits),
        'securityContext': {'runAsUser': uid, 'runAsGroup': uid, 'runAsNonRoot': True,
                            'allowPrivilegeEscalation': False, 'capabilities': drop(), 'seccompProfile': rt()},
        'volumeMounts': data + shared + _etc_mounts(['passwd', 'group', 'gitconfig', 'fleet-devnet.env'])
                        + [{'name': 'run', 'mountPath': '/run'},
                           {'name': 'join', 'mountPath': '/run/fleet-join', 'readOnly': True},
                           # the sshd's host.pub (claude-fleet#4149): a relayed login
                           # meets that sshd, so the heartbeat carries its key
                           {'name': 'sshd-key', 'mountPath': '/run/sshd-key', 'readOnly': True}],
    }, **_probes())
    # sshd: a host key of its own, made ONCE and kept on the person's disk (T743 —
    # a new one each start was 「REMOTE HOST IDENTIFICATION HAS CHANGED」 on every
    # pod rebuild): only this container mounts its subPath; a lost .pub is derived
    # back, a present key never replaced. The copy in /run/sshd-key is what sshd
    # reads and the heartbeat hands on (the jump's inner login checks it, #4193)
    sshd = {
        'name': 'sshd', 'image': image,
        'command': ['/bin/sh', '-ec', POD_SSHD_KEY_SCRIPT + 'exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config'],
        'resources': _ephemeral({'requests': {'cpu': '50m', 'memory': '64Mi'}, 'limits': {'cpu': '1', 'memory': '1Gi'}},
                                USER_POD_EPHEMERAL['sshd']),
        'securityContext': {'runAsUser': 0, 'allowPrivilegeEscalation': False,
                            'capabilities': {'drop': ['ALL'], 'add': list(POD_SSHD_CAPS)}, 'seccompProfile': rt()},
        'ports': [{'name': 'ssh', 'containerPort': POD_SSHD_PORT}],
        'readinessProbe': {'tcpSocket': {'port': POD_SSHD_PORT}, 'periodSeconds': 10},
        # what the person runs over ssh (the 看台, a shell, scp) runs here as
        # the login: its home and /tmp (tmux's sockets) are the fleet container's
        'volumeMounts': [m for m in data if m['subPath'] == 'homes']
                        + [dict(m, readOnly=True) for m in data if m['subPath'] == 'node']
                        + shared + _etc_mounts(['passwd', 'group', 'gitconfig', 'fleet-devnet.env', 'sshd_config'])
                        + [{'name': 'sshd-key', 'mountPath': '/run/sshd-key'},
                           {'name': 'data', 'mountPath': POD_SSHD_KEEP, 'subPath': 'sshd-hostkey'}],
    }
    etc = {
        'name': 'pod-etc', 'image': image,
        'command': ['/usr/bin/python3', '-I', SEED_LINUX, 'pod-etc', '--out', '/pod-etc'],
        'env': who + devnet,
        'resources': {'requests': {'cpu': '10m', 'memory': '16Mi'}, 'limits': {'cpu': '200m', 'memory': '64Mi'}},
        'securityContext': {'runAsUser': POD_ETC_UID, 'runAsGroup': POD_ETC_UID, 'runAsNonRoot': True,
                            'allowPrivilegeEscalation': False, 'readOnlyRootFilesystem': True,
                            'capabilities': drop(), 'seccompProfile': rt()},
        'volumeMounts': [{'name': 'pod-etc', 'mountPath': '/pod-etc'}],
    }
    return [
        {'apiVersion': 'v1', 'kind': 'PersistentVolumeClaim', 'metadata': meta,
         'spec': {'accessModes': ['ReadWriteOncePod'], 'storageClassName': storage_class,
                  'resources': {'requests': {'storage': limits['disk']}}}},
        {'apiVersion': 'v1', 'kind': 'Service', 'metadata': meta,
         'spec': {'type': 'ClusterIP', 'selector': select,
                  'ports': [{'name': 'ssh', 'protocol': 'TCP', 'port': 22, 'targetPort': 'ssh'}]}},
        {'apiVersion': 'apps/v1', 'kind': 'Deployment', 'metadata': meta,
         # Recreate: the home disk is ReadWriteOncePod — the old pod lets go first
         'spec': {'replicas': 1, 'strategy': {'type': 'Recreate'}, 'revisionHistoryLimit': 2,
                  'selector': {'matchLabels': select},
                  'template': {'metadata': {'labels': dict(labels, **{m['label']: '1' for m in granted})}, 'spec': {
                      'hostname': name, 'enableServiceLinks': False,
                      'serviceAccountName': SA_USER,
                      'automountServiceAccountToken': False, 'terminationGracePeriodSeconds': 120,
                      # the disk is the login's: its group on every file the kubelet
                      # hands over, changed only when the top is not already its
                      'securityContext': {'fsGroup': uid, 'fsGroupChangePolicy': 'OnRootMismatch',
                                          'seccompProfile': rt()},
                      'imagePullSecrets': [{'name': n} for n in pull_secrets],
                      'initContainers': [egress_guard(image, dns, blocked, metadata, allow, egress_closed), etc],
                      'containers': [fleet, sshd],
                      'volumes': [{'name': 'data', 'persistentVolumeClaim': {'claimName': name}},
                                  # 0440 with fsGroup: the login reads its machine join code
                                  {'name': 'join', 'secret': {'secretName': name + '-join',
                                                           'optional': True, 'defaultMode': 0o440}},
                                  {'name': 'pod-etc', 'emptyDir': {'medium': 'Memory', 'sizeLimit': '1Mi'}},
                                  {'name': 'tmp', 'emptyDir': {'sizeLimit': USER_POD_TMP}},
                                  {'name': 'run', 'emptyDir': {'medium': 'Memory', 'sizeLimit': '16Mi'}},
                                  {'name': 'sshd-key', 'emptyDir': {'medium': 'Memory', 'sizeLimit': '1Mi'}},
                                  {'name': 'egress-run', 'emptyDir': {'medium': 'Memory', 'sizeLimit': '1Mi'}}]}}}},
    ]


# The cluster's one door (#3549, EPIC #3500 C4): ONE load balancer for every
# person whose home is their own pod. Two replicas of the image in door mode —
# the entry port's sshd (keys only, the hub's list, PerSourcePenalties) with ONE
# account, the jump: a person's key opens a tunnel to their own pod's Service and
# nothing else (design #4181 A2; the per-login accounts and the door's key to the
# pods went with T647). Its Secret (DOOR_SECRET) holds what every replica
# shares: the host key and the node token.
DOOR_NAME = 'fleet-door'
DOOR_SECRET = 'fleet-door'
# its disk (#4729): state holds the runtime the image stages at each start
# (~1.3 GiB), logs the node's own; asked for and capped like a user pod's
DOOR_STATE = '4Gi'
DOOR_LOGS = '1Gi'
DOOR_EPHEMERAL = {'requests': '2Gi', 'limits': '6Gi'}


def door_resources(image, hub, namespace='fleet-workers', replicas=2, entry_spec='slb.s1.small',
                   pull_secrets=('acr-pull',), entry_host=''):
    """The door: its LoadBalancer Service (22022 alone, externalTrafficPolicy
    Local — the client's own address for PerSourcePenalties and the record) and
    its Deployment. No disk, no login, no Kubernetes credential. entry_host is
    the load balancer's address once it has one (--entry-host): the door's
    `entry reach` hands it to the hub, which otherwise knocks on the cluster's
    NAT egress and finds the door unreachable — and a person's pod then gets no
    door route at all (claude-fleet#4112)."""
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
    if entry_host and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{0,252}', entry_host):
        raise ValueError('--entry-host is a host name or an IPv4 address, not %r' % entry_host)
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
    if entry_host:
        env.append({'name': 'CCQUOTA_FLEET_NODE_ROUTES', 'value': 'entry=%s:%d' % (entry_host, ENTRY_PORT)})
    tcp = {'tcpSocket': {'port': ENTRY_PORT}}
    container = {
        'name': 'door', 'image': image, 'env': env,
        'resources': _ephemeral({'requests': {'cpu': '50m', 'memory': '64Mi'}, 'limits': {'cpu': '1', 'memory': '512Mi'}},
                                DOOR_EPHEMERAL),
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
                      'serviceAccountName': SA_DOOR,
                      'automountServiceAccountToken': False, 'enableServiceLinks': False,
                      'terminationGracePeriodSeconds': 30,
                      'imagePullSecrets': [{'name': n} for n in pull_secrets],
                      # two replicas, two machines when the cluster has them
                      'affinity': {'podAntiAffinity': {'preferredDuringSchedulingIgnoredDuringExecution': [
                          {'weight': 100, 'podAffinityTerm': {'topologyKey': 'kubernetes.io/hostname',
                                                              'labelSelector': {'matchLabels': {'fleet/role': 'door'}}}}]}},
                      'containers': [container],
                      'volumes': [{'name': 'state', 'emptyDir': {'sizeLimit': DOOR_STATE}},
                                  {'name': 'logs', 'emptyDir': {'sizeLimit': DOOR_LOGS}},
                                  {'name': 'secret', 'secret': {'secretName': DOOR_SECRET, 'defaultMode': 0o400}}]}}}},
    ]


# The cluster's central patrol (#3734, EPIC #3500 C1's cloud half): ONE fleet-ops
# for the whole cluster, the managed-node image's own ccquota as a plain agent —
# no boot, no supervisor, no root, no disk. Its node token (a join code redeemed
# with the cluster's name as the hostname, MANAGED-LINUX.md «fleet-ops») is the
# Secret fleet-ops, handed to the agent down a pipe (CCQUOTA_TOKEN_FD), never its
# environment. Its hostname IS the cluster's name — what the hub's fleet.clusters
# and every fleet_cluster_pods row say — and its hello lists cluster_ops: it
# carries provisioner tickets, reads Jobs back (#3552, #3553) and sends every
# user pod's own reading up the link (#3734). The account is the read-only
# fleet-ops (deploy/k8s/fleet-workers/serviceaccounts.yaml), so this is the one
# pod here that mounts a token. Labelled fleet/role: control — the only caller
# the provisioner lets in (networkpolicy.yaml provisioner-in / control-out).
SA_OPS = 'fleet-ops'
OPS_NAME = 'fleet-ops'
OPS_SECRET = 'fleet-ops'
OPS_UID = 10001
OPS_CCQUOTA = '/opt/claude-fleet/seed/current/bin/ccquota'
OPS_SECURITY = {'runAsNonRoot': True, 'runAsUser': OPS_UID, 'runAsGroup': OPS_UID,
                'allowPrivilegeEscalation': False, 'readOnlyRootFilesystem': True,
                'capabilities': {'drop': ['ALL']}, 'seccompProfile': {'type': 'RuntimeDefault'}}
CLUSTER_RE = r'[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'


def ops_resources(image, hub, cluster, namespace='fleet-workers', provisioner='', pull_secrets=('acr-pull',)):
    """fleet-ops: one Deployment (one replica, Recreate — two would be two ops
    links for one cluster). Nothing listens; it only dials the hub."""
    if not image or not hub or not cluster:
        raise ValueError('--ops needs --image, --hub and the cluster name')
    if not re.fullmatch(r'[^\s]+@sha256:[a-f0-9]{64}', image):
        raise ValueError('pin the deployed image by sha256 digest')
    if not re.fullmatch(r'https://[^\s/]+(/[^\s]*)?', hub):
        raise ValueError('--hub is https://…')
    if not re.fullmatch(CLUSTER_RE, cluster):
        raise ValueError('--ops is the cluster name the hub knows (a-z 0-9 -), not %r' % cluster)
    if not re.fullmatch(r'[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?', namespace):
        raise ValueError('--namespace is a namespace name, not %r' % namespace)
    provisioner = provisioner or 'http://fleet-provisioner.%s.svc.cluster.local:8790' % namespace
    if not re.fullmatch(r'https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?', provisioner):
        raise ValueError('--provisioner is http://HOST[:PORT], not %r' % provisioner)
    labels = {'app.kubernetes.io/name': 'fleet-ops', 'fleet/role': 'control'}
    meta = {'name': OPS_NAME, 'namespace': namespace, 'labels': labels}
    env = [{'name': 'CCQUOTA_HUB_URL', 'value': hub},
           {'name': 'CCQUOTA_FLEET', 'value': '1'},
           # coordinate only: nothing is placed on it, no session runs here
           {'name': 'CCQUOTA_FLEET_COMPUTE', 'value': '0'},
           {'name': 'CCQUOTA_FLEET_SSH_RELAY', 'value': '0'},
           {'name': 'CCQUOTA_FLEET_CHAT', 'value': '0'},
           {'name': 'CCQUOTA_FLEET_TERM', 'value': '0'},
           {'name': 'CCQUOTA_FLEET_PROVISIONER', 'value': provisioner},
           {'name': 'HOME', 'value': '/work'}]
    # the token down a pipe, never the environment (claude-fleet#1971)
    run = ('exec 3< /run/fleet-ops/token\n'
           'CCQUOTA_TOKEN_FD=3 exec %s agent --state /work/state --sources claude' % OPS_CCQUOTA)
    container = {
        'name': 'ops', 'image': image, 'command': ['/bin/sh', '-ec', run], 'env': env,
        'resources': {'requests': {'cpu': '20m', 'memory': '64Mi'}, 'limits': {'cpu': '500m', 'memory': '256Mi'}},
        'securityContext': OPS_SECURITY,
        'volumeMounts': [{'name': 'work', 'mountPath': '/work'}, {'name': 'tmp', 'mountPath': '/tmp'},
                         {'name': 'secret', 'mountPath': '/run/fleet-ops', 'readOnly': True}],
    }
    return [
        {'apiVersion': 'apps/v1', 'kind': 'Deployment', 'metadata': meta,
         'spec': {'replicas': 1, 'revisionHistoryLimit': 2, 'strategy': {'type': 'Recreate'},
                  'selector': {'matchLabels': {'app.kubernetes.io/name': 'fleet-ops'}},
                  'template': {'metadata': {'labels': labels}, 'spec': {
                      # the hub knows this link by the cluster's name (opsFor)
                      'hostname': cluster,
                      'serviceAccountName': SA_OPS,
                      'automountServiceAccountToken': True, 'enableServiceLinks': False,
                      'securityContext': {'fsGroup': OPS_UID},
                      'terminationGracePeriodSeconds': 10,
                      'imagePullSecrets': [{'name': n} for n in pull_secrets],
                      'containers': [container],
                      'volumes': [{'name': 'work', 'emptyDir': {}},
                                  {'name': 'tmp', 'emptyDir': {}},
                                  {'name': 'secret', 'secret': {'secretName': OPS_SECRET, 'defaultMode': 0o440,
                                                                'items': [{'key': 'token', 'path': 'token'}]}}]}}}},
    ]


# A throwaway Job (#3558, EPIC #3500 C16; its runner is C7's): no key, no home,
# no token, not root. Named after the ticket's nonce, so a replayed create is
# AlreadyExists; labelled fleet/owner (never fleet/pod — the owner pod's Service
# selects that label, and a Job must never answer for the person's sshd).
JOB_SECURITY = {'runAsNonRoot': True, 'runAsUser': 10001, 'runAsGroup': 10001, 'allowPrivilegeEscalation': False,
                'readOnlyRootFilesystem': True, 'capabilities': {'drop': ['ALL']},
                'seccompProfile': {'type': 'RuntimeDefault'}}


# What each kind of Job gets (#3552, C7): its ceiling, its deadline, its
# network. open = the package caches, the git mirror and the cluster's one
# egress (HTTPS_PROXY); closed (untrusted) = the caches and the mirror only —
# no egress label, so job-out's rules are all it has. browser adds a /dev/shm.
JOB_KINDS = {
    'build': {'cpu': '2', 'memory': '4Gi', 'deadline': 3600, 'net': 'open'},
    'test': {'cpu': '2', 'memory': '4Gi', 'deadline': 3600, 'net': 'open'},
    'browser': {'cpu': '2', 'memory': '4Gi', 'deadline': 1800, 'net': 'open', 'shm': '1Gi'},
    'load': {'cpu': '4', 'memory': '4Gi', 'deadline': 1800, 'net': 'open'},
    'untrusted': {'cpu': '1', 'memory': '2Gi', 'deadline': 900, 'net': 'closed'},
}
JOB_CMD_RE = r'[^\x00-\x1f\x7f]{1,2000}'
# the runner inside the image (bin/fleet-job-runner.sh in the managed-node image)
JOB_RUNNER = '/opt/claude-fleet/seed/current/bin/fleet-job-runner.sh'
JOB_MIRROR_RE = r'(git|https?)://[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._/-]*\{repo\}[A-Za-z0-9._/-]*'


def job_resources(image, pod, repo, ref, nonce, namespace='fleet-workers', pull_secrets=('acr-pull',),
                  deadline=3600, kind='test', cmd='true', mirror='', caches=False, egress_proxy='',
                  runner=JOB_RUNNER, ttl=600):
    """One Job: the image (by digest) runs `cmd` once on one commit of one repo
    for the session in <pod>; its writable places are two emptyDirs (/work,
    /tmp). `mirror` is where the commit is fetched from (a URL with {repo});
    `caches` points npm / pip / Go at the cluster's caches; an open kind gets
    `egress_proxy` as its HTTPS_PROXY, untrusted never does."""
    if not re.fullmatch(r'[^\s]+@sha256:[a-f0-9]{64}', image):
        raise ValueError('pin the job image by sha256 digest')
    if not re.fullmatch(USER_POD_RE, pod):
        raise ValueError('a Job serves a u-<nonce> pod, not %r' % pod)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9._-]{1,100}', repo):
        raise ValueError('--job-repo is OWNER/NAME, not %r' % repo)
    if not re.fullmatch(r'[0-9a-f]{40}', ref):
        raise ValueError('--job-ref is a 40-hex commit, not %r' % ref)
    if not re.fullmatch(r'[0-9a-f]{32}', nonce):
        raise ValueError('a Job is named by its ticket nonce (32 hex), not %r' % nonce)
    if not re.fullmatch(r'[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?', namespace):
        raise ValueError('--namespace is a namespace name, not %r' % namespace)
    if kind not in JOB_KINDS:
        raise ValueError('--job-kind is one of %s, not %r' % ('|'.join(JOB_KINDS), kind))
    if not re.fullmatch(JOB_CMD_RE, cmd):
        raise ValueError('--job-cmd is one printable line of 1-2000 characters')
    if mirror and not re.fullmatch(JOB_MIRROR_RE, mirror):
        raise ValueError('--job-mirror is git|http(s)://HOST[:PORT]/…{repo}…, not %r' % mirror)
    if egress_proxy and not re.fullmatch(r'http://[A-Za-z0-9.-]+(:[0-9]{1,5})?', egress_proxy):
        raise ValueError('--egress-proxy is http://HOST[:PORT], not %r' % egress_proxy)
    if not re.fullmatch(r'/[A-Za-z0-9._/-]+', runner):
        raise ValueError('the job runner is an absolute path, not %r' % runner)
    k = JOB_KINDS[kind]
    name = 'job-' + nonce[:12]
    labels = {'app.kubernetes.io/name': 'fleet-job', 'fleet/role': 'job', 'fleet/owner': pod,
              'fleet/job-kind': kind}
    if k['net'] == 'open':
        labels['fleet/job-net'] = 'open'
    env = [{'name': 'FLEET_JOB_REPO', 'value': repo}, {'name': 'FLEET_JOB_REF', 'value': ref},
           {'name': 'FLEET_JOB_OWNER', 'value': pod}, {'name': 'FLEET_JOB_KIND', 'value': kind},
           {'name': 'FLEET_JOB_CMD', 'value': cmd}, {'name': 'HOME', 'value': '/work'}]
    if mirror:
        env.append({'name': 'FLEET_JOB_MIRROR', 'value': mirror.replace('{repo}', repo)})
    if caches:
        env.append({'name': 'FLEET_CLUSTER_CACHES', 'value': namespace})
    if egress_proxy and k['net'] == 'open':
        env.append({'name': 'FLEET_EGRESS_PROXY', 'value': egress_proxy})
    mounts = [{'name': 'work', 'mountPath': '/work'}, {'name': 'tmp', 'mountPath': '/tmp'}]
    volumes = [{'name': 'work', 'emptyDir': {'sizeLimit': '20Gi'}}, {'name': 'tmp', 'emptyDir': {'sizeLimit': '2Gi'}}]
    if k.get('shm'):
        mounts.append({'name': 'shm', 'mountPath': '/dev/shm'})
        volumes.append({'name': 'shm', 'emptyDir': {'medium': 'Memory', 'sizeLimit': k['shm']}})
    container = {
        'name': 'job', 'image': image, 'command': ['/bin/sh', runner],
        'env': env,
        'resources': {'requests': {'cpu': '250m', 'memory': '512Mi'},
                      'limits': {'cpu': k['cpu'], 'memory': k['memory']}},
        'securityContext': JOB_SECURITY,
        'workingDir': '/work',
        'volumeMounts': mounts,
    }
    return [{'apiVersion': 'batch/v1', 'kind': 'Job',
             'metadata': {'name': name, 'namespace': namespace, 'labels': labels},
             'spec': {'backoffLimit': 0, 'activeDeadlineSeconds': min(int(deadline), k['deadline']),
                      'ttlSecondsAfterFinished': int(ttl),
                      'template': {'metadata': {'labels': labels}, 'spec': {
                          'serviceAccountName': SA_JOB, 'automountServiceAccountToken': False,
                          'enableServiceLinks': False, 'restartPolicy': 'Never',
                          'securityContext': {'runAsNonRoot': True, 'runAsUser': 10001, 'runAsGroup': 10001,
                                              'fsGroup': 10001, 'seccompProfile': {'type': 'RuntimeDefault'}},
                          'imagePullSecrets': [{'name': n} for n in pull_secrets],
                          'containers': [container],
                          'volumes': volumes}}}}]


# A service run's throwaway environment (#4005, the SPACE EPIC C3): one Job per
# run attempt, for a service principal (svc:<name>) — never a person's pod. It
# holds no key of anyone's: no token, no home, no PVC, not root; its only Secret
# is its own one-time key to the hub (svc-r<n>-a<k>-token, owned by the Job, so it
# goes with it). Three containers on one network namespace:
#
#   egress-guard  closed (render.py's guard): DNS and the template's allow lines
#                 alone — the run egress proxy and the credential proxy by
#                 ClusterIP; the metadata address, the pod / service ranges and
#                 every private range are REJECTed, and so is the rest
#   fetch         the runner's `fetch`: the template (agent.md, by digest) and the
#                 inputs from the hub with the key, written under /work, and the
#                 model pass (bound to this run, good until its deadline) on a
#                 memory emptyDir
#   run           the runner's `run`: Claude Code, -p --agent report, its tools
#                 WebSearch / WebFetch / Read / Write and nothing else; /out goes
#                 back to the hub (POST /v1/node/svc-runs/<R>/result, the same key)
#
# activeDeadlineSeconds is the run's deadline, backoffLimit 0 (a retry is the
# hub's: a new attempt, a new Job), ttlSecondsAfterFinished 300 — five minutes
# after it ends there is no Job, no pod, no file of it.
SVC_RUNNER = '/opt/claude-fleet/seed/current/bin/fleet-svc-runner.py'
SVC_RUN_RE = r'R[1-9][0-9]{0,15}'
SVC_NAME_RE = r'[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?'
SVC_TOKEN_RE = r'fsj_[a-z2-7]{52}'
SVC_TOKEN_KEY = 'token'
SVC_DEADLINE = (60, 3600)
SVC_TTL = 300


def svc_run_name(run, attempt):
    """The Job of run R<n> attempt k: svc-r<n>-a<k>."""
    if not re.fullmatch(SVC_RUN_RE, run or ''):
        raise ValueError('a service run is R<n>, not %r' % run)
    if isinstance(attempt, bool) or not isinstance(attempt, int) or not 1 <= attempt <= 9:
        raise ValueError('a run attempt is 1-9, not %r' % (attempt,))
    return 'svc-%s-a%d' % (run.lower(), attempt)


def svc_run_resources(image, run, attempt, svc, deadline, hub, cred_central, egress_proxy,
                      namespace='fleet-workers', egress=None, pull_secrets=('acr-pull',), ttl=SVC_TTL,
                      runner=SVC_RUNNER, hub_internal=''):
    """[the Job] of one service run attempt. `egress['allow']` names the two
    in-cluster roads the closed guard lets through (the run egress proxy and the
    credential proxy, IP:PORT each); `egress_proxy` is the run egress proxy's URL
    (the hub and the open web go through it), `cred_central` the credential proxy,
    `hub_internal` (#4175) the hub's Service the runner asks in its place (its
    ClusterIP:PORT then in egress['allow'])."""
    name = svc_run_name(run, attempt)
    if not re.fullmatch(r'[^\s]+@sha256:[a-f0-9]{64}', image):
        raise ValueError('pin the svc run image by sha256 digest')
    if not re.fullmatch(SVC_NAME_RE, svc or ''):
        raise ValueError('a service principal\'s name is a DNS label, not %r' % svc)
    if isinstance(deadline, bool) or not isinstance(deadline, int) or not SVC_DEADLINE[0] <= deadline <= SVC_DEADLINE[1]:
        raise ValueError('a run deadline is %d-%d seconds, not %r' % (SVC_DEADLINE + (deadline,)))
    if not re.fullmatch(r'https://[A-Za-z0-9.-]+(:[0-9]{1,5})?', hub or ''):
        raise ValueError('the hub is https://HOST[:PORT], not %r' % hub)
    hub_internal_env(hub_internal)
    if not re.fullmatch(CENTRAL_RE, cred_central or ''):
        raise ValueError('the credential proxy is https://HOST or http://NAME.NS.svc.cluster.local[:PORT], not %r'
                         % cred_central)
    if not re.fullmatch(EGRESS_PROXY_RE, egress_proxy or ''):
        raise ValueError('the run egress proxy is http://HOST:PORT, not %r' % egress_proxy)
    if not re.fullmatch(NS_RE, namespace):
        raise ValueError('--namespace is a namespace name, not %r' % namespace)
    if not re.fullmatch(r'/[A-Za-z0-9._/-]+', runner):
        raise ValueError('the svc runner is an absolute path, not %r' % runner)
    for n in pull_secrets:
        if not re.fullmatch(r'[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?', n):
            raise ValueError('a pull Secret is a Secret name, not %r' % n)
    dns, blocked, metadata, allow = _egress_ranges(egress)
    if not allow:
        raise ValueError("a run's guard is closed: egress.allow names the run egress proxy and the "
                         'credential proxy (IP:PORT) — with neither it reaches nothing')
    labels = {'app.kubernetes.io/name': 'fleet-svc-run', 'fleet/role': 'job', 'fleet/job-kind': 'svc',
              'fleet/job-net': 'svc', 'fleet/svc': svc, 'fleet/run': run, 'fleet/attempt': str(attempt)}
    env = [{'name': 'FLEET_SVC_RUN', 'value': run}, {'name': 'FLEET_SVC_ATTEMPT', 'value': str(attempt)},
           {'name': 'FLEET_SVC_DEADLINE', 'value': str(deadline)}, {'name': 'FLEET_SVC_HUB', 'value': hub_internal or hub},
           {'name': 'FLEET_SVC_CENTRAL', 'value': cred_central},
           {'name': 'FLEET_SVC_KEY_FILE', 'value': '/run/fleet-svc-key/' + SVC_TOKEN_KEY},
           # the hub and the open web through the run egress proxy; the credential
           # proxy straight (a cluster name)
           {'name': 'HTTPS_PROXY', 'value': egress_proxy}, {'name': 'https_proxy', 'value': egress_proxy},
           {'name': 'NO_PROXY', 'value': '.svc.cluster.local,.svc'}, {'name': 'no_proxy', 'value': '.svc.cluster.local,.svc'},
           {'name': 'HOME', 'value': '/tmp/home'}, {'name': 'TMPDIR', 'value': '/tmp'},
           {'name': 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC', 'value': '1'},
           {'name': 'DISABLE_AUTOUPDATER', 'value': '1'}]
    sc = dict(JOB_SECURITY)
    small = {'requests': {'cpu': '10m', 'memory': '32Mi'}, 'limits': {'cpu': '200m', 'memory': '128Mi'}}
    mounts = [{'name': 'work', 'mountPath': '/work'}, {'name': 'out', 'mountPath': '/out'},
              {'name': 'tmp', 'mountPath': '/tmp'}, {'name': 'pass', 'mountPath': '/run/fleet-svc'},
              {'name': 'key', 'mountPath': '/run/fleet-svc-key', 'readOnly': True}]
    fetch = {'name': 'fetch', 'image': image, 'command': ['/usr/bin/python3', '-I', runner, 'fetch'],
             'env': env, 'resources': small, 'securityContext': sc, 'workingDir': '/work', 'volumeMounts': mounts}
    main = {'name': 'run', 'image': image, 'command': ['/usr/bin/python3', '-I', runner, 'run'],
            'env': env, 'resources': {'requests': {'cpu': '250m', 'memory': '512Mi'},
                                      'limits': {'cpu': '1', 'memory': '2Gi'}},
            'securityContext': sc, 'workingDir': '/work', 'volumeMounts': mounts}
    guard = egress_guard(image, dns, blocked, metadata, allow, closed=True)
    return [{'apiVersion': 'batch/v1', 'kind': 'Job',
             'metadata': {'name': name, 'namespace': namespace, 'labels': labels},
             'spec': {'backoffLimit': 0, 'activeDeadlineSeconds': deadline, 'ttlSecondsAfterFinished': int(ttl),
                      'template': {'metadata': {'labels': labels}, 'spec': {
                          'serviceAccountName': SA_JOB, 'automountServiceAccountToken': False,
                          'enableServiceLinks': False, 'restartPolicy': 'Never',
                          # the guard is root for its rules alone; every other
                          # container says runAsNonRoot itself
                          'securityContext': {'runAsUser': 10001, 'runAsGroup': 10001, 'fsGroup': 10001,
                                              'seccompProfile': {'type': 'RuntimeDefault'}},
                          'imagePullSecrets': [{'name': n} for n in pull_secrets],
                          'initContainers': [guard, fetch],
                          'containers': [main],
                          'volumes': [{'name': 'work', 'emptyDir': {'sizeLimit': '1Gi'}},
                                      {'name': 'out', 'emptyDir': {'sizeLimit': '64Mi'}},
                                      {'name': 'tmp', 'emptyDir': {'sizeLimit': '2Gi'}},
                                      {'name': 'pass', 'emptyDir': {'medium': 'Memory', 'sizeLimit': '1Mi'}},
                                      {'name': 'egress-run', 'emptyDir': {'medium': 'Memory', 'sizeLimit': '1Mi'}},
                                      # 0440 with fsGroup: the runner reads its key
                                      {'name': 'key', 'secret': {'secretName': name + '-token', 'defaultMode': 0o440,
                                                                 'items': [{'key': SVC_TOKEN_KEY,
                                                                            'path': SVC_TOKEN_KEY}]}}]}}}}]


def svc_run_key_secret(job, namespace, token, owner_uid=''):
    """The Job's one Secret: its one-time key to the hub, owned by the Job (the
    garbage collector takes it with it)."""
    m = re.fullmatch(r'svc-(r[1-9][0-9]{0,15})-a([1-9])', job or '')
    if not m:
        raise ValueError('a run key belongs to a svc-r<n>-a<k> Job, not %r' % job)
    if not re.fullmatch(SVC_TOKEN_RE, token or ''):
        raise ValueError('a run key is fsj_ + 52 of base32, not the given one')
    meta = {'name': job + '-token', 'namespace': namespace,
            'labels': {'fleet/role': 'job', 'fleet/job-kind': 'svc', 'fleet/run': 'R' + m.group(1)[1:],
                       'fleet/attempt': m.group(2)}}
    if owner_uid:
        meta['ownerReferences'] = [{'apiVersion': 'batch/v1', 'kind': 'Job', 'name': job, 'uid': owner_uid,
                                    'blockOwnerDeletion': False}]
    # data, not stringData: what admission sees is what was sent
    return {'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque', 'metadata': meta,
            'data': {SVC_TOKEN_KEY: base64.b64encode(token.encode()).decode()}}


# A person's pod's containers, each on the one image (#4174): the inits, then the two
USER_POD_IMAGE_CONTAINERS = (('initContainers', ('egress-guard', 'pod-etc')), ('containers', ('fleet', 'sshd')))


def user_pod_image_patch(image):
    """The patch that moves one pod onto image (kubectl patch deploy <name>
    --type strategic; the provisioner's roll-user-pod, #4174): the image of its
    four containers, by name, nothing else — Recreate, so the old pod lets go of
    the disk first and the sessions come back through restore."""
    if not re.fullmatch(r'[^\s]+@sha256:[a-f0-9]{64}', image or ''):
        raise ValueError('--image-patch needs an --image pinned by digest, not %r' % image)
    return {'spec': {'template': {'spec': {k: [{'name': n, 'image': image} for n in names]
                                           for k, names in USER_POD_IMAGE_CONTAINERS}}}}


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
    p.add_argument('--private-mirrors', default='', metavar='FILE',
                   help='a JSON list of mirrors only their logins may read (#4002): '
                        '[{"mirror", "upstream", "allow": "IP:PORT", "logins": [...]}] - --user-pod only')
    p.add_argument('--mirror-grant', default='', metavar='FILE',
                   help="read a running user pod's Deployment (kubectl get deploy u-... -o json) on stdin and print "
                        'the JSON patch that makes its private-mirror access what FILE says for its login')
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
    p.add_argument('--hub-internal', default='', metavar='URL',
                   help="the hub's in-cluster Service (http://ccquota-hub.new-deploy.svc.cluster.local): a "
                        "--user-pod's / --svc-run's machine-to-hub calls dial it; --hub stays the public address "
                        "(#4175). Its ClusterIP:PORT goes in --egress-allow")
    p.add_argument('--egress-closed', action='store_true',
                   help='the guard rejects the public internet too: out only through --egress-allow destinations '
                        "(the egress and credproxy Services' ClusterIPs, the hub's address)")
    # one person's pod (#3550; docs/dev/MANAGED-LINUX.md «User pods»)
    p.add_argument('--user-pod', default='', metavar='u-NONCE',
                   help="render one person's pod (Deployment + Service + home disk) instead of the shared node")
    p.add_argument('--login', default='', metavar='NAME',
                   help="the pod's one login (the spare's fleetu<N>, or a moved person's own name): its node runs "
                        'as it, never root (#3757)')
    p.add_argument('--uid', type=int, default=0, metavar='N', help="that login's number (%d-%d)" % POD_UID_RANGE)
    p.add_argument('--limits', default='', metavar='cpu=2,memory=6Gi,disk=50Gi',
                   help="the pod's ceiling: the hub's fleet.user_pod_limits.<principal> value (default %s)"
                        % ','.join('%s=%s' % kv for kv in USER_POD_LIMITS.items()))
    # the cluster's one door (#3549; docs/dev/MANAGED-LINUX.md «The door»)
    p.add_argument('--door', action='store_true',
                   help="render the cluster's one door (LoadBalancer + Deployment) instead of a node")
    p.add_argument('--door-replicas', type=int, default=2)
    p.add_argument('--ops', default='', metavar='CLUSTER',
                   help="the cluster's one fleet-ops, named as the hub knows the cluster (#3734)")
    p.add_argument('--provisioner', default='', metavar='URL',
                   help="fleet-ops' provisioner (default http://fleet-provisioner.<namespace>.svc.cluster.local:8790)")
    # a throwaway Job (#3558; docs/dev/MANAGED-LINUX.md «Cluster permissions») — the
    # provisioner renders the same from a create-job ticket
    p.add_argument('--job', default='', metavar='u-NONCE',
                   help='render one throwaway Job for this pod (needs --image, --job-repo, --job-ref, --job-nonce)')
    p.add_argument('--job-repo', default='')
    p.add_argument('--job-ref', default='')
    p.add_argument('--job-nonce', default='')
    p.add_argument('--job-kind', default='test', help='|'.join(JOB_KINDS))
    p.add_argument('--job-cmd', default='true', help='the one command line the Job runs (sh -c)')
    p.add_argument('--job-mirror', default='', help='where the commit is fetched from: git://HOST/…{repo}…')
    # a service run's Job (#4005): the provisioner renders the same from a create-svc-run ticket
    p.add_argument('--svc-run', default='', metavar='R<n>',
                   help='render one service run attempt\'s Job (needs --image, --hub, --cred-central, '
                        '--egress-proxy and the run egress / credential proxy as --egress-allow)')
    p.add_argument('--svc-attempt', type=int, default=1)
    p.add_argument('--svc-name', default='livepage', help="the service principal's name (svc:<name>)")
    p.add_argument('--svc-deadline', type=int, default=900, help='seconds (%d-%d)' % SVC_DEADLINE)
    p.add_argument('--limits-patch', action='store_true',
                   help='print only the patch that moves --limits on a running pod (rolls that pod alone)')
    p.add_argument('--image-patch', action='store_true',
                   help='print only the patch that moves a running pod onto --image (rolls that pod alone, #4174)')
    args = p.parse_args()
    egress = {'dns': args.egress_dns, 'metadata': args.egress_metadata, 'pod_cidr': args.egress_pod_cidr,
              'service_cidr': args.egress_service_cidr,
              'private': [c.strip() for c in args.egress_private.split(',') if c.strip()],
              'allow': args.egress_allow}
    try:
        private = []
        for path in (args.mirror_grant, args.private_mirrors):
            if path:
                with open(path) as f:
                    private = json.load(f)
        if args.mirror_grant:
            print(json.dumps(mirror_grant_patch(json.load(sys.stdin), private), indent=2))
            raise SystemExit(0)
        if private and not args.user_pod:
            raise ValueError('--private-mirrors is per login: a --user-pod only (a shared node has many logins)')
        if args.image_patch:
            print(json.dumps(user_pod_image_patch(args.image), indent=2))
            raise SystemExit(0)
        if args.limits_patch:
            print(json.dumps(user_pod_limits_patch(user_pod_limits(args.limits)), indent=2))
            raise SystemExit(0)
        if args.door:
            items = door_resources(args.image, args.hub, args.namespace, args.door_replicas, args.entry_lb_spec,
                                   pull_secrets=args.pull_secrets or ['acr-pull'], entry_host=args.entry_host)
            print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': items}, indent=2))
            raise SystemExit(0)
        if args.ops:
            items = ops_resources(args.image, args.hub, args.ops, args.namespace, args.provisioner,
                                  pull_secrets=args.pull_secrets or ['acr-pull'])
            print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': items}, indent=2))
            raise SystemExit(0)
        if args.svc_run:
            items = svc_run_resources(args.image, args.svc_run, args.svc_attempt, args.svc_name, args.svc_deadline,
                                      args.hub, args.cred_central, args.egress_proxy, args.namespace, egress=egress,
                                      pull_secrets=args.pull_secrets or ['acr-pull'], hub_internal=args.hub_internal)
            print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': items}, indent=2))
            raise SystemExit(0)
        if args.job:
            items = job_resources(args.image, args.job, args.job_repo, args.job_ref, args.job_nonce, args.namespace,
                                  pull_secrets=args.pull_secrets or ['acr-pull'], kind=args.job_kind,
                                  cmd=args.job_cmd, mirror=args.job_mirror, caches=args.cluster_caches,
                                  egress_proxy=args.egress_proxy)
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
                                       cluster_caches=args.cluster_caches, relay=args.relay,
                                       login=args.login, uid=args.uid, private_mirrors=private,
                                       hub_internal=args.hub_internal)
        else:
            items = resources(args.image, args.hub, args.storage_class, args.namespace,
                              entry_host=args.entry_host, entry_spec=args.entry_lb_spec, egress=egress,
                              pull_secrets=args.pull_secrets or ['acr-pull'], github_proxy=args.github_proxy,
                              git_mirrors=args.git_mirror, cn_mirrors=args.cn_mirrors,
                              cred_central=args.cred_central, egress_proxy=args.egress_proxy,
                              egress_closed=args.egress_closed, cluster_caches=args.cluster_caches, relay=args.relay)
    except (ValueError, OSError) as e:
        p.error(str(e))
    print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': items}, indent=2))
