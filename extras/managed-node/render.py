#!/usr/bin/env python3
"""Render a single managed ACK node. Output is a kubectl-compatible JSON List."""
import argparse
import json
import re


def resources(image, hub, storage_class, namespace='fleet-workers', size='100Gi'):
    if not re.fullmatch(r'[^\s]+@sha256:[a-f0-9]{64}', image):
        raise ValueError('pin the deployed image by sha256 digest')
    if not hub.startswith('https://'):
        raise ValueError('use the hub HTTPS endpoint')
    if not re.fullmatch('[a-z0-9][a-z0-9.-]*', storage_class):
        raise ValueError('select an existing ACK CSI StorageClass')
    labels = {'app.kubernetes.io/name': 'fleet-managed-node'}
    volumes = [('node', '/var/db/fleet-node'), ('credentials', '/var/db/fleet-cred'),
               ('homes', '/home'), ('logs', '/var/log/fleet-node')]
    mounts = [{'name': 'data', 'mountPath': path, 'subPath': sub} for sub, path in volumes]
    container = {
        'name': 'fleet', 'image': image,
        'env': [{'name': 'FLEET_HUB_URL', 'value': hub},
                {'name': 'FLEET_MACHINE_JOIN_FILE', 'value': '/run/fleet-join/machine'},
                {'name': 'FLEET_LOGIN_JOIN_FILE', 'value': '/run/fleet-join/login'}],
        'resources': {'requests': {'cpu': '2', 'memory': '8Gi'}, 'limits': {'cpu': '4', 'memory': '16Gi'}},
        'securityContext': {'runAsUser': 0, 'allowPrivilegeEscalation': False,
                            'capabilities': {'drop': ['ALL'], 'add': ['CHOWN', 'DAC_OVERRIDE', 'FOWNER',
                                'SETUID', 'SETGID', 'KILL', 'NET_BIND_SERVICE', 'SYS_CHROOT', 'AUDIT_WRITE']},
                            'seccompProfile': {'type': 'RuntimeDefault'}},
        'ports': [{'name': 'ssh', 'containerPort': 22}],
        'volumeMounts': mounts + [{'name': 'join', 'mountPath': '/run/fleet-join', 'readOnly': True}],
        'startupProbe': {'exec': {'command': ['test', '-f', '/run/fleet-node-ready']},
                         'periodSeconds': 10, 'failureThreshold': 90},
        'readinessProbe': {'exec': {'command': ['python3', '-I', '/opt/claude-fleet/current/bin/fleet-node-linux.py',
                                               'ready']}, 'periodSeconds': 15},
        'livenessProbe': {'exec': {'command': ['python3', '-I', '/opt/claude-fleet/current/bin/fleet-node-linux.py', 'live']}, 'periodSeconds': 30, 'failureThreshold': 4},
    }
    meta = {'name': 'fleet-linux', 'namespace': namespace}
    return [
        {'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': namespace}},
        {'apiVersion': 'v1', 'kind': 'Service', 'metadata': meta,
         'spec': {'clusterIP': 'None', 'selector': labels, 'ports': [{'name': 'ssh', 'port': 22}]}},
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
    args = p.parse_args()
    print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': resources(
        args.image, args.hub, args.storage_class, args.namespace)}, indent=2))
