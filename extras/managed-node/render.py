#!/usr/bin/env python3
"""Render a single managed ACK node. Output is a kubectl-compatible JSON List."""
import argparse
import json
import re

# the disk runtime the machine updater moves (#3212; the image only seeds it)
RUNTIME = '/var/db/fleet-node/runtime'
# the entry port (#3070): the only port the public door carries (#3213)
ENTRY_PORT = 22022
# ACK's cloud controller: a public CLB, the smallest spec, paid by traffic.
# `clcu` is the pay-by-use instance for an account that can no longer buy by spec.
LB = 'service.beta.kubernetes.io/alibaba-cloud-loadbalancer-'


def entry_annotations(spec):
    a = {LB + 'address-type': 'internet', LB + 'charge-type': 'paybytraffic'}
    if spec == 'clcu':
        a[LB + 'instance-charge-type'] = 'PayByCLCU'
    else:
        a.update({LB + 'instance-charge-type': 'PayBySpec', LB + 'spec': spec})
    return a


def resources(image, hub, storage_class, namespace='fleet-workers', size='100Gi',
              entry_host='', entry_spec='slb.s1.small'):
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
        'resources': {'requests': {'cpu': '2', 'memory': '8Gi'}, 'limits': {'cpu': '4', 'memory': '16Gi'}},
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
                      'imagePullSecrets': [{'name': 'acr-pull'}], 'containers': [container],
                      'volumes': [{'name': 'join', 'secret': {'secretName': 'fleet-linux-join',
                                                           'optional': True, 'defaultMode': 256}}]}},
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
    p.add_argument('--entry-lb-spec', default='slb.s1.small', help='CLB spec, or clcu (pay by use)')
    args = p.parse_args()
    print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': resources(
        args.image, args.hub, args.storage_class, args.namespace,
        entry_host=args.entry_host, entry_spec=args.entry_lb_spec)}, indent=2))
