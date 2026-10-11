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


def egress_rules(dns, blocked):
    """iptables-restore input: loopback, replies, DNS to kube-dns, then REJECT each range."""
    v4 = ['*filter', ':INPUT ACCEPT [0:0]', ':FORWARD ACCEPT [0:0]', ':OUTPUT ACCEPT [0:0]',
          '-A OUTPUT -o lo -j ACCEPT',
          '-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT',
          '-A OUTPUT -d %s/32 -p udp -m udp --dport 53 -j ACCEPT' % dns,
          '-A OUTPUT -d %s/32 -p tcp -m tcp --dport 53 -j ACCEPT' % dns]
    v4 += ['-A OUTPUT -d %s -j REJECT' % c for c in blocked] + ['COMMIT']
    v6 = ['*filter', ':INPUT ACCEPT [0:0]', ':FORWARD ACCEPT [0:0]', ':OUTPUT ACCEPT [0:0]',
          '-A OUTPUT -o lo -j ACCEPT',
          '-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT']
    v6 += ['-A OUTPUT -d %s -j REJECT' % c for c in EGRESS6_BLOCK] + ['COMMIT']
    return '\n'.join(v4), '\n'.join(v6)


def egress_guard(image, dns, blocked, metadata):
    v4, v6 = egress_rules(dns, blocked)
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


def resources(image, hub, storage_class, namespace='fleet-workers', size='100Gi',
              entry_host='', entry_spec='slb.s1.small', egress=None, pull_secrets=('acr-pull',)):
    if not re.fullmatch(r'[^\s]+@sha256:[a-f0-9]{64}', image):
        raise ValueError('pin the deployed image by sha256 digest')
    if not hub.startswith('https://'):
        raise ValueError('use the hub HTTPS endpoint')
    if not re.fullmatch('[a-z0-9][a-z0-9.-]*', storage_class):
        raise ValueError('select an existing ACK CSI StorageClass')
    if entry_host and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{0,252}', entry_host):
        raise ValueError('--entry-host is the load balancer address (an IP or a DNS name)')
    if entry_spec != 'clcu' and not re.fullmatch(r'slb\.s[0-9]\.[a-z0-9]+', entry_spec):
        raise ValueError('--entry-lb-spec is a CLB spec (slb.s1.small) or clcu')
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
    labels = {'app.kubernetes.io/name': 'fleet-managed-node'}
    volumes = [('node', '/var/db/fleet-node'), ('credentials', '/var/db/fleet-cred'),
               ('homes', '/home'), ('logs', '/var/log/fleet-node')]
    mounts = [{'name': 'data', 'mountPath': path, 'subPath': sub} for sub, path in volumes]
    env = [{'name': 'FLEET_HUB_URL', 'value': hub},
           {'name': 'FLEET_MACHINE_JOIN_FILE', 'value': '/run/fleet-join/machine'},
           {'name': 'FLEET_LOGIN_JOIN_FILE', 'value': '/run/fleet-join/login'},
           # the entry port's sshd (keys from the hub's list only, #3070)
           {'name': 'FLEET_ENTRY', 'value': '1'},
           {'name': 'FLEET_ENTRY_PORT', 'value': str(ENTRY_PORT)}]
    if entry_host:
        # the door's address: on ACK the egress the hub sees is the NAT's, so the
        # entry reach report must name the load balancer (fleet_entry_reach.go)
        env.append({'name': 'CCQUOTA_FLEET_NODE_ROUTES', 'value': 'entry=%s:%d' % (entry_host, ENTRY_PORT)})
    container = {
        'name': 'fleet', 'image': image,
        'env': env,
        'resources': {'requests': {'cpu': '1', 'memory': '4Gi'}, 'limits': {'cpu': '2', 'memory': '8Gi'}},
        # never NET_ADMIN / NET_RAW: the egress guard's rules stay put (#3281)
        'securityContext': {'runAsUser': 0, 'allowPrivilegeEscalation': False,
                            'capabilities': {'drop': ['ALL'], 'add': ['CHOWN', 'DAC_OVERRIDE', 'FOWNER',
                                'SETUID', 'SETGID', 'KILL', 'NET_BIND_SERVICE', 'SYS_CHROOT', 'AUDIT_WRITE']},
                            'seccompProfile': {'type': 'RuntimeDefault'}},
        'ports': [{'name': 'ssh', 'containerPort': 22}, {'name': 'entry', 'containerPort': ENTRY_PORT}],
        'volumeMounts': mounts + [{'name': 'join', 'mountPath': '/run/fleet-join', 'readOnly': True}],
        'startupProbe': {'exec': {'command': ['test', '-f', '/run/fleet-node-ready']},
                         'periodSeconds': 10, 'failureThreshold': 90},
        'readinessProbe': {'exec': {'command': ['python3', '-I', RUNTIME + '/current/bin/fleet-node-linux.py',
                                               'ready']}, 'periodSeconds': 15},
        # the resident loop only (#3212): a supervisor restarting onto a new
        # release is never a reason to restart the container
        'livenessProbe': {'exec': {'command': ['python3', '-I', '/usr/local/lib/fleet-image-stage.py', 'live']},
                          'periodSeconds': 30, 'failureThreshold': 4},
    }
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
                  'template': {'metadata': {'labels': labels}, 'spec': {
                      'automountServiceAccountToken': False, 'terminationGracePeriodSeconds': 120,
                      'imagePullSecrets': [{'name': n} for n in pull_secrets],
                      'initContainers': [egress_guard(image, dns, blocked, metadata)],
                      'containers': [container],
                      'volumes': [{'name': 'join', 'secret': {'secretName': 'fleet-linux-join',
                                                           'optional': True, 'defaultMode': 256}},
                                  {'name': 'egress-run', 'emptyDir': {'medium': 'Memory', 'sizeLimit': '1Mi'}}]}},
                  'volumeClaimTemplates': [{'metadata': {'name': 'data'}, 'spec': {
                      'accessModes': ['ReadWriteOncePod'], 'storageClassName': storage_class,
                      'resources': {'requests': {'storage': size}}}}]}},
    ]


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--image', required=True)
    p.add_argument('--hub', required=True)
    p.add_argument('--storage-class', required=True)
    p.add_argument('--namespace', default='fleet-workers')
    p.add_argument('--entry-host', default='',
                   help="the door's load balancer address (kubectl get svc fleet-linux-entry); "
                        'empty until the CLB exists')
    p.add_argument('--pull-secret', action='append', dest='pull_secrets',
                   help='image-pull Secret in the namespace (repeatable; default acr-pull). On ACK: '
                        'kubectl -n fleet-workers get secret | grep acr-credential')
    p.add_argument('--entry-lb-spec', default='slb.s1.small', help='CLB spec, or clcu (pay by use)')
    # the egress guard's ranges (#3281; docs/MANAGED-LINUX.md «Egress guard»)
    p.add_argument('--egress-dns', default=EGRESS['dns'], help='kube-dns ClusterIP: the one private address allowed (53)')
    p.add_argument('--egress-metadata', default=EGRESS['metadata'], help='cloud metadata address, cut')
    p.add_argument('--egress-pod-cidr', default=EGRESS['pod_cidr'], help="the cluster's pod range, cut")
    p.add_argument('--egress-service-cidr', default=EGRESS['service_cidr'], help="the cluster's service range, cut")
    p.add_argument('--egress-private', default=','.join(EGRESS['private']),
                   help='comma-separated VPC / private ranges, cut')
    args = p.parse_args()
    egress = {'dns': args.egress_dns, 'metadata': args.egress_metadata, 'pod_cidr': args.egress_pod_cidr,
              'service_cidr': args.egress_service_cidr,
              'private': [c.strip() for c in args.egress_private.split(',') if c.strip()]}
    try:
        items = resources(args.image, args.hub, args.storage_class, args.namespace,
                          entry_host=args.entry_host, entry_spec=args.entry_lb_spec, egress=egress,
                          pull_secrets=args.pull_secrets or ['acr-pull'])
    except ValueError as e:
        p.error(str(e))
    print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': items}, indent=2))
