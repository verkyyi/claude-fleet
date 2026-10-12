#!/usr/bin/python3 -I
"""fleet-provisioner.py — the one service in a cluster that writes to Kubernetes
(issue #3558, EPIC #3500 C16 · 共同约定 2).

  serve [--listen HOST:PORT]   the Deployment's process (default :8790):
                               POST /v1/op with a ticket as the body · GET /healthz
  once <ticket>                one op from the command line (drills, a person)

It is never connected to the hub and takes nothing but a ticket: fleet-ops
(read-only) hands over what the hub sent. A ticket (bin/fleet_cluster_ticket.py)
is the hub's account key's, for THIS cluster, short-lived and single-use — the
nonce is spent in the ConfigMap fleet-provisioner-nonces before anything is
done. The ops are typed, never a manifest:

  create-user-pod  pod limits      render.py's user pod (PVC · Service · Deployment)
  destroy-user-pod pod             those three, each only if it is a user pod's
  set-limits       pod limits      that pod's Deployment, nobody else's
  create-job       pod repo ref    render.py's throwaway Job for that pod

Everything it would send is first held to the template here (off_template —
the admission policy's own rules, deploy/k8s/provisioner/policy.yaml, which the
API server applies again to every request this account makes). Its Role is
deployments · services · persistentvolumeclaims · jobs in its own namespace,
and the one ConfigMap; no pod, no Secret, no other namespace.

Exit (once): 0 done · 3 refused (one stderr line why; nothing done) · 1 failed
(the API said no or is unreachable; a re-ask signs a fresh ticket) · 2 usage.

Settings (the Deployment's): FLEET_PROVISIONER_CONF (template.json — the
cluster's name, the namespace, render.py's user-pod arguments, the Job image),
FLEET_PROVISIONER_PUB (the hub's account key, `ed25519 <base64>`),
FLEET_PROVISIONER_API (default https://kubernetes.default.svc) and
FLEET_PROVISIONER_SA_DIR (its token and CA).
"""
import argparse
import http.server
import importlib.util
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fleet_cluster_ticket as ticket  # noqa: E402
from fleet_cluster_ticket import Refused  # noqa: E402

RENDER = os.path.join(HERE, '..', 'extras', 'managed-node', 'render.py')
BOOK = 'fleet-provisioner-nonces'
# a spent nonce is kept this long past its exp; by then the ticket is refused as expired
KEEP_PAST_EXP = 86400
MAX_BODY = 8192

# The template, as the admission policy holds it (deploy/k8s/provisioner/policy.yaml):
# keep the two in step.
ROLES = ('user', 'job')
SERVICE_ACCOUNT = {'Deployment': 'fleet-user', 'Job': 'fleet-job'}
# the user pod's container caps (render.NODE_SECURITY) and its egress guard's
CAPS = {'CHOWN', 'DAC_OVERRIDE', 'FOWNER', 'SETUID', 'SETGID', 'KILL', 'NET_BIND_SERVICE', 'SYS_CHROOT',
        'AUDIT_WRITE', 'NET_ADMIN', 'NET_RAW'}
DIGEST = re.compile(r'^[^\s]+@sha256:[a-f0-9]{64}$')
PATHS = {
    'PersistentVolumeClaim': '/api/v1/namespaces/%s/persistentvolumeclaims',
    'Service': '/api/v1/namespaces/%s/services',
    'Deployment': '/apis/apps/v1/namespaces/%s/deployments',
    'Job': '/apis/batch/v1/namespaces/%s/jobs',
}


def render():
    spec = importlib.util.spec_from_file_location('fleet_render', RENDER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def off_template(o, ns):
    """Why o is not something the provisioner may send, or None."""
    meta = o.get('metadata') or {}
    kind = o.get('kind')
    if kind not in PATHS:
        return 'kind %s is not the template\'s' % kind
    if meta.get('namespace') != ns:
        return 'namespace %r, not %r' % (meta.get('namespace'), ns)
    if (meta.get('labels') or {}).get('fleet/role') not in ROLES:
        return '%s %s carries no fleet/role user|job label' % (kind, meta.get('name'))
    s = o.get('spec') or {}
    if kind == 'Service':
        if s.get('type', 'ClusterIP') != 'ClusterIP' or s.get('externalIPs') or s.get('externalName'):
            return 'a Service the template makes is ClusterIP only'
        return None
    if kind == 'PersistentVolumeClaim':
        return 'a claim from a data source is not the template\'s' if s.get('dataSource') or s.get('dataSourceRef') else None
    tpl = s.get('template') or {}
    if (tpl.get('metadata', {}).get('labels') or {}).get('fleet/role') != meta['labels']['fleet/role']:
        return 'pod template\'s fleet/role differs from its owner\'s'
    p = tpl.get('spec') or {}
    for k in ('hostNetwork', 'hostPID', 'hostIPC', 'shareProcessNamespace'):
        if p.get(k):
            return '%s is not the template\'s' % k
    if p.get('automountServiceAccountToken') is not False:
        return 'the pod must not mount a service account token'
    if p.get('serviceAccountName') != SERVICE_ACCOUNT[kind]:
        return 'a %s runs as %s, not %r' % (kind, SERVICE_ACCOUNT[kind], p.get('serviceAccountName'))
    if p.get('nodeName') or p.get('hostAliases') or p.get('ephemeralContainers'):
        return 'nodeName / hostAliases / ephemeralContainers are not the template\'s'
    for v in p.get('volumes') or []:
        if set(v) - {'name', 'emptyDir', 'persistentVolumeClaim', 'secret'}:
            return 'volume %s: only emptyDir, a claim or a Secret' % v.get('name')
    psc = p.get('securityContext') or {}
    for c in (p.get('initContainers') or []) + (p.get('containers') or []):
        if not DIGEST.match(c.get('image') or ''):
            return 'container %s: the image is pinned by digest' % c.get('name')
        sc = c.get('securityContext') or {}
        if sc.get('privileged') or sc.get('allowPrivilegeEscalation') is not False:
            return 'container %s: no privilege, no escalation' % c.get('name')
        if (sc.get('seccompProfile') or psc.get('seccompProfile') or {}).get('type') != 'RuntimeDefault':
            return 'container %s: seccomp RuntimeDefault' % c.get('name')
        caps = sc.get('capabilities') or {}
        if 'ALL' not in (caps.get('drop') or []):
            return 'container %s: drops ALL capabilities' % c.get('name')
        add = set(caps.get('add') or [])
        if kind == 'Job' and add:
            return 'a Job adds no capability'
        if add - CAPS:
            return 'container %s: capability %s is not the template\'s' % (c.get('name'), ' '.join(sorted(add - CAPS)))
        if kind == 'Job':
            if not (sc.get('runAsNonRoot') or psc.get('runAsNonRoot')) or not sc.get('readOnlyRootFilesystem'):
                return 'a Job runs non-root on a read-only root'
            if (sc.get('runAsUser', psc.get('runAsUser')) or 0) == 0:
                return 'a Job never runs as uid 0'
    return None


class API(object):
    """The Kubernetes API with this pod's own token — the one credential it has."""

    def __init__(self, base=None, sa_dir=None):
        self.base = (base or os.environ.get('FLEET_PROVISIONER_API') or 'https://kubernetes.default.svc').rstrip('/')
        sa = sa_dir or os.environ.get('FLEET_PROVISIONER_SA_DIR') or '/var/run/secrets/kubernetes.io/serviceaccount'
        self.token_file = os.path.join(sa, 'token')
        ca = os.path.join(sa, 'ca.crt')
        self.ctx = ssl.create_default_context(cafile=ca) if os.path.exists(ca) else None

    def call(self, method, path, body=None, ctype='application/json'):
        """(status, decoded body); a transport failure raises OSError."""
        with open(self.token_file) as f:  # re-read: the kubelet rotates it
            token = f.read().strip()
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method,
                                     headers={'Authorization': 'Bearer ' + token, 'Content-Type': ctype,
                                              'Accept': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=20, context=self.ctx) as r:
                st, raw = r.status, r.read()
        except urllib.error.HTTPError as e:
            st, raw = e.code, e.read()
        try:
            return st, json.loads(raw or b'{}')
        except ValueError:
            return st, {'message': raw[:200].decode('utf-8', 'replace')}


class Failed(Exception):
    pass


def _ok(st, out, what):
    if st >= 300:
        raise Failed('%s: HTTP %d %s' % (what, st, (out or {}).get('message', '')[:200]))


def spend(api, ns, nonce, exp, now):
    """Mark nonce spent in the namespace's book — once, whichever replica asks."""
    path = '/api/v1/namespaces/%s/configmaps/%s' % (ns, BOOK)
    for _ in range(5):
        st, cm = api.call('GET', path)
        _ok(st, cm, 'the nonce book')
        data = dict(cm.get('data') or {})
        if nonce in data:
            raise Refused('ticket already used (nonce %s)' % nonce)
        data = {k: v for k, v in data.items() if not (v.isdigit() and now > int(v) + KEEP_PAST_EXP)}
        data[nonce] = str(exp)
        st, out = api.call('PUT', path, {'apiVersion': 'v1', 'kind': 'ConfigMap', 'data': data,
                                         'metadata': {'name': BOOK, 'namespace': ns,
                                                      'resourceVersion': cm['metadata']['resourceVersion']}})
        if st == 409:
            continue  # another replica wrote first: read again
        _ok(st, out, 'the nonce book')
        return
    raise Failed('the nonce book kept changing under us')


def user_pod_of(api, ns, kind, name):
    """The object when it is a user pod's, None when it is gone; Refused when a
    thing of that name is somebody else's."""
    st, o = api.call('GET', (PATHS[kind] % ns) + '/' + name)
    if st == 404:
        return None
    _ok(st, o, '%s %s' % (kind, name))
    labels = (o.get('metadata') or {}).get('labels') or {}
    if labels.get('fleet/role') != 'user' or labels.get('fleet/pod') != name:
        raise Refused('%s %s is not a user pod\'s' % (kind, name))
    return o


def create(api, ns, objs):
    for o in objs:
        why = off_template(o, ns)
        if why:
            raise Refused('off the template: ' + why)
    done = []
    for o in objs:
        st, out = api.call('POST', PATHS[o['kind']] % ns, o)
        if st == 409:
            done.append('%s %s exists' % (o['kind'], o['metadata']['name']))
            continue
        _ok(st, out, 'create %s %s' % (o['kind'], o['metadata']['name']))
        done.append('%s %s' % (o['kind'], o['metadata']['name']))
    return done


def act(t, conf, api, r=None):
    """Run one checked ticket; the list of what was done."""
    r = r or render()
    ns = conf.get('namespace', 'fleet-workers')
    op, pod = t['op'], t['pod']
    if op == 'create-user-pod':
        kw = dict(conf.get('user_pod') or {})
        kw['pull_secrets'] = tuple(kw.get('pull_secrets') or ('acr-pull',))
        try:
            objs = r.user_pod_resources(name=pod, namespace=ns, limits=r.user_pod_limits(t['limits']), **kw)
        except (ValueError, TypeError) as e:
            raise Refused('cannot render the user pod: %s' % e)
        return create(api, ns, objs)
    if op == 'create-job':
        if user_pod_of(api, ns, 'Deployment', pod) is None:
            raise Refused('no user pod %s to run a Job for' % pod)
        job = conf.get('job') or {}
        try:
            objs = r.job_resources(job.get('image', ''), pod, t['repo'], t['ref'], t['nonce'], ns,
                                   pull_secrets=tuple(job.get('pull_secrets') or ('acr-pull',)),
                                   deadline=int(job.get('deadline', 3600)))
        except (ValueError, TypeError) as e:
            raise Refused('cannot render the Job: %s' % e)
        return create(api, ns, objs)
    if op == 'set-limits':
        try:
            patch = r.user_pod_limits_patch(r.user_pod_limits(t['limits']))
        except ValueError as e:
            raise Refused(str(e))
        if user_pod_of(api, ns, 'Deployment', pod) is None:
            raise Refused('no user pod %s' % pod)
        st, out = api.call('PATCH', (PATHS['Deployment'] % ns) + '/' + pod, patch,
                           'application/strategic-merge-patch+json')
        _ok(st, out, 'patch Deployment %s' % pod)
        return ['Deployment %s limits %s' % (pod, t['limits'])]
    if op == 'destroy-user-pod':
        # check all three first: a name that is somebody else's stops the whole op
        found = [(k, user_pod_of(api, ns, k, pod)) for k in ('Deployment', 'Service', 'PersistentVolumeClaim')]
        done = []
        for kind, o in found:
            if o is None:
                continue
            st, out = api.call('DELETE', (PATHS[kind] % ns) + '/' + pod,
                               {'apiVersion': 'v1', 'kind': 'DeleteOptions', 'propagationPolicy': 'Background',
                                'preconditions': {'uid': o['metadata']['uid']}})
            if st != 404:
                _ok(st, out, 'delete %s %s' % (kind, pod))
            done.append('%s %s deleted' % (kind, pod))
        return done
    raise Refused('not a provisioner op: %s' % op)


def load_conf():
    path = os.environ.get('FLEET_PROVISIONER_CONF') or '/etc/fleet-provisioner/template.json'
    with open(path) as f:
        conf = json.load(f)
    if not isinstance(conf, dict) or not conf.get('cluster'):
        raise ValueError('%s names no cluster' % path)
    return conf


def handle(text, conf=None, api=None, now=None):
    """(rc, one line): 0 done · 3 refused · 1 failed."""
    conf = conf or load_conf()
    api = api or API()
    now = int(time.time()) if now is None else now
    ns = conf.get('namespace', 'fleet-workers')
    try:
        pub = ticket.read_pub(os.environ.get('FLEET_PROVISIONER_PUB') or '/etc/fleet-provisioner/account.pub')
        t = ticket.check(pub, text.strip(), conf['cluster'], now)
        spend(api, ns, t['nonce'], t['exp'], now)
        done = act(t, conf, api)
    except Refused as e:
        return 3, 'refused: %s' % e
    except (Failed, OSError) as e:
        return 1, 'failed: %s' % e
    return 0, '%s %s: %s' % (t['op'], t['pod'], '; '.join(done) or 'nothing to do')


class Handler(http.server.BaseHTTPRequestHandler):
    conf = None

    def reply(self, code, obj):
        body = (json.dumps(obj) + '\n').encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/healthz':
            return self.reply(200, {'ok': True})
        self.reply(404, {'error': 'not found'})

    def do_POST(self):
        if self.path != '/v1/op':
            return self.reply(404, {'error': 'not found'})
        n = int(self.headers.get('Content-Length') or 0)
        if not 0 < n <= MAX_BODY:
            return self.reply(413, {'refused': 'a ticket is 1-%d bytes' % MAX_BODY})
        rc, line = handle(self.rfile.read(n).decode('utf-8', 'replace'), self.conf)
        print('fleet-provisioner: %s' % line, file=sys.stderr, flush=True)
        self.reply({0: 200, 3: 403}.get(rc, 502), {'ok': rc == 0, 'result': line})

    def log_message(self, *_a):
        pass  # one line per op above, never the ticket


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('serve')
    s.add_argument('--listen', default=':8790')
    o = sub.add_parser('once')
    o.add_argument('ticket')
    a = p.parse_args(argv)
    try:
        conf = load_conf()
    except (OSError, ValueError) as e:
        print('fleet-provisioner: no template: %s' % e, file=sys.stderr)
        return 2
    if a.cmd == 'once':
        rc, line = handle(a.ticket, conf)
        print('fleet-provisioner: %s' % line, file=sys.stderr if rc else sys.stdout)
        return rc
    host, _, port = a.listen.rpartition(':')
    Handler.conf = conf
    srv = http.server.HTTPServer((host, int(port)), Handler)
    print('fleet-provisioner: serving %s for cluster %s' % (a.listen, conf['cluster']), file=sys.stderr, flush=True)
    srv.serve_forever()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
