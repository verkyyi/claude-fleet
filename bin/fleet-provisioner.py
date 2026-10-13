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

  create-user-pod  pod limits join render.py's user pod (PVC · Service · Deployment)
                   login uid      built for its one login (#3757), and its join
                                  Secret u-<nonce>-join (#3553); the template's
                                  user_pod.private_mirrors reach it only when
                                  their list names that login (#4002)
  destroy-user-pod pod             those three, each only if it is a user pod's,
                                   and the join Secret
  set-limits       pod limits      that pod's Deployment, nobody else's
  create-job       pod repo ref    render.py's throwaway Job for that pod: the
                   kind cmd        ticket's kind and command line, the template's
                                   job.{image, git_mirror, caches, egress_proxy,
                                   deadline, ttl} (#3552); refused for a repo of
                                   user_pod.private_mirrors whose list does not
                                   name the pod's login (#4002)
  bind-user-pod    pod principal   a claimed pod's fleet/principal label (#3553)
  create-svc-run   run attempt svc render.py's svc Job for one service run (#4005):
                   deadline token  the template's svc.{image, hub, cred_central,
                                   egress_proxy, egress, pull_secrets, ttl}; then
                                   its key Secret svc-r<n>-a<k>-token, owned by
                                   the Job (it goes with it)
  delete-svc-run   run attempt     that Job, only if it is a svc run's (its
                                   Secret and pod follow)

Everything it would send is first held to the template here (off_template —
the admission policy's own rules, deploy/k8s/provisioner/policy.yaml, which the
API server applies again to every request this account makes). Its Role is
deployments · services · persistentvolumeclaims · jobs in its own namespace,
the one ConfigMap, and create / delete (never read) of a pod's join Secret; no
pod, no other Secret, no other namespace.

Exit (once): 0 done · 3 refused (one stderr line why; nothing done) · 1 failed
(the API said no or is unreachable; a re-ask signs a fresh ticket) · 2 usage.

Settings (the Deployment's): FLEET_PROVISIONER_CONF (template.json — the
cluster's name, the namespace, render.py's user-pod arguments, the Job image),
FLEET_PROVISIONER_PUB (the hub's account key, `ed25519 <base64>`),
FLEET_PROVISIONER_API (default https://kubernetes.default.svc) and
FLEET_PROVISIONER_SA_DIR (its token and CA).
"""
import argparse
import base64
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
# A person's pod runs as its login (#3757): root only in `sshd`, with only these
# (render.POD_SSHD_CAPS), and in the `egress-guard` init with only its two; every
# other container is runAsNonRoot, not uid 0, and adds nothing.
ROOT_CAPS = {'sshd': {'CHOWN', 'SETUID', 'SETGID', 'SYS_CHROOT', 'KILL'},
             'egress-guard': {'NET_ADMIN', 'NET_RAW'}}
DIGEST = re.compile(r'^[^\s]+@sha256:[a-f0-9]{64}$')
PATHS = {
    'PersistentVolumeClaim': '/api/v1/namespaces/%s/persistentvolumeclaims',
    'Service': '/api/v1/namespaces/%s/services',
    'Deployment': '/apis/apps/v1/namespaces/%s/deployments',
    'Job': '/apis/batch/v1/namespaces/%s/jobs',
    'Secret': '/api/v1/namespaces/%s/secrets',
}
JOIN_KEY = 'machine'
SVC_KEY = 'token'


def join_secret(pod, ns, code):
    """The pod's join Secret (render.py mounts u-<nonce>-join, key machine):
    its one-time machine join code, the only thing in it."""
    return {'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque',
            'metadata': {'name': pod + '-join', 'namespace': ns,
                         'labels': {'fleet/role': 'user', 'fleet/pod': pod}},
            # data, not stringData: what admission sees is what was sent
            'data': {JOIN_KEY: base64.b64encode(code.encode()).decode()}}


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
    if kind == 'Secret':
        labels = meta['labels']
        keys = set(o.get('stringData') or {}) | set(o.get('data') or {})
        if labels.get('fleet/role') == 'job':
            # a service run's key (#4005): svc-r<n>-a<k>-token, one key, owned by its Job alone
            job = svc_job_name(labels)
            if not job or meta.get('name') != job + '-token':
                return 'a Job\'s Secret is a service run\'s key, svc-r<n>-a<k>-token'
            if o.get('type', 'Opaque') != 'Opaque' or o.get('stringData') or keys != {SVC_KEY}:
                return 'a run key is Opaque and holds only %r' % SVC_KEY
            for ref in meta.get('ownerReferences') or []:
                if ref.get('kind') != 'Job' or ref.get('name') != job:
                    return 'a run key is owned by its own Job alone'
            return None
        if labels.get('fleet/role') != 'user' or meta.get('name') != '%s-join' % labels.get('fleet/pod'):
            return 'a Secret the template makes is a user pod\'s join Secret, <fleet/pod>-join'
        if o.get('type', 'Opaque') != 'Opaque' or keys != {JOIN_KEY}:
            return 'a join Secret is Opaque and holds only %r' % JOIN_KEY
        return None
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
    svc_job = kind == 'Job' and meta['labels'].get('fleet/job-kind') == 'svc'
    if svc_job and svc_job_name(meta['labels']) != meta.get('name'):
        return 'a service run\'s Job is svc-r<n>-a<k>, its fleet/run and fleet/attempt'
    for v in p.get('volumes') or []:
        if set(v) - {'name', 'emptyDir', 'persistentVolumeClaim', 'secret'}:
            return 'volume %s: only emptyDir, a claim or a Secret' % v.get('name')
        if kind == 'Job' and 'persistentVolumeClaim' in v:
            return 'volume %s: a Job mounts no disk' % v.get('name')
        if kind == 'Job' and 'secret' in v and not (svc_job and (v['secret'] or {}).get('secretName') == meta['name'] + '-token'):
            return 'volume %s: a Job mounts no Secret but a service run its own key' % v.get('name')
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
        guard = svc_job and c.get('name') == 'egress-guard'
        if kind == 'Job' and add and not (guard and not add - ROOT_CAPS['egress-guard']):
            return 'a Job adds no capability (a service run\'s egress guard its two)'
        if kind == 'Deployment' and c.get('name') in ROOT_CAPS:
            if add - ROOT_CAPS[c['name']]:
                return 'container %s: capability %s is not the template\'s' % (
                    c['name'], ' '.join(sorted(add - ROOT_CAPS[c['name']])))
        elif kind == 'Deployment':
            if add:
                return 'container %s adds a capability: only sshd\'s login step and the egress guard do' % c.get('name')
            if not (sc.get('runAsNonRoot', psc.get('runAsNonRoot'))) \
                    or (sc.get('runAsUser', psc.get('runAsUser')) or 0) == 0:
                return 'container %s may run as root: a person\'s pod is root only in sshd' % c.get('name')
        if kind == 'Job' and not guard:
            if not (sc.get('runAsNonRoot') or psc.get('runAsNonRoot')) or not sc.get('readOnlyRootFilesystem'):
                return 'a Job runs non-root on a read-only root'
            if (sc.get('runAsUser', psc.get('runAsUser')) or 0) == 0:
                return 'a Job never runs as uid 0'
        if guard and not sc.get('readOnlyRootFilesystem'):
            return 'a run\'s egress guard runs on a read-only root'
    return None


def svc_job_name(labels):
    """svc-r<n>-a<k> from a run's fleet/run and fleet/attempt labels, or ''."""
    run, att = labels.get('fleet/run') or '', labels.get('fleet/attempt') or ''
    if labels.get('fleet/job-kind') != 'svc' or not re.fullmatch(r'R[1-9][0-9]{0,15}', run) \
            or not re.fullmatch(r'[1-9]', att):
        return ''
    return 'svc-%s-a%s' % (run.lower(), att)


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


def pod_login_of(dep):
    """The one login a user pod's Deployment was rendered for (#3757), or ''."""
    for c in ((dep.get('spec') or {}).get('template') or {}).get('spec', {}).get('containers') or []:
        if c.get('name') == 'fleet':
            for e in c.get('env') or []:
                if e.get('name') == 'FLEET_POD_LOGIN':
                    return e.get('value') or ''
    return ''


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
    op, pod = t['op'], t.get('pod', '')
    if op == 'create-user-pod':
        kw = dict(conf.get('user_pod') or {})
        kw['pull_secrets'] = tuple(kw.get('pull_secrets') or ('acr-pull',))
        try:
            objs = r.user_pod_resources(name=pod, namespace=ns, limits=r.user_pod_limits(t['limits']),
                                        login=t['login'], uid=t['uid'], **kw)
        except (ValueError, TypeError) as e:
            raise Refused('cannot render the user pod: %s' % e)
        # the join Secret first: the pod mounts it at its start
        return create(api, ns, [join_secret(pod, ns, t['join'])] + objs)
    if op == 'create-job':
        owner = user_pod_of(api, ns, 'Deployment', pod)
        if owner is None:
            raise Refused('no user pod %s to run a Job for' % pod)
        # a repo only a list may read from its mirror (#4002): no Job of it for a
        # pod whose login is not on that list
        try:
            private = r.private_mirrors_checked((conf.get('user_pod') or {}).get('private_mirrors') or [])
        except ValueError as e:
            raise Refused('the template\'s private_mirrors: %s' % e)
        login = pod_login_of(owner)
        upstream = ('https://github.com/%s.git' % t['repo']).lower()  # dist-ok: a ticket's repo as an upstream URL, compared, never fetched
        for m in private:
            if m['upstream'].lower() == upstream and login not in m['logins']:
                raise Refused('%s is mirrored for a list, and %s (login %r) is not on it' % (t['repo'], pod, login))
        job = conf.get('job') or {}
        try:
            objs = r.job_resources(job.get('image', ''), pod, t['repo'], t['ref'], t['nonce'], ns,
                                   pull_secrets=tuple(job.get('pull_secrets') or ('acr-pull',)),
                                   deadline=int(job.get('deadline', 3600)), kind=t['kind'], cmd=t['cmd'],
                                   mirror=job.get('git_mirror', ''), caches=bool(job.get('caches')),
                                   egress_proxy=job.get('egress_proxy', ''), ttl=int(job.get('ttl', 600)))
        except (ValueError, TypeError) as e:
            raise Refused('cannot render the Job: %s' % e)
        return create(api, ns, objs)
    if op == 'create-svc-run':
        return create_svc_run(api, ns, conf.get('svc') or {}, t, r)
    if op == 'delete-svc-run':
        name = r.svc_run_name(t['run'], t['attempt'])
        st, o = api.call('GET', (PATHS['Job'] % ns) + '/' + name)
        if st == 404:
            return ['Job %s gone' % name]
        _ok(st, o, 'Job %s' % name)
        if svc_job_name((o.get('metadata') or {}).get('labels') or {}) != name:
            raise Refused('Job %s is not a service run\'s' % name)
        st, out = api.call('DELETE', (PATHS['Job'] % ns) + '/' + name,
                           {'apiVersion': 'v1', 'kind': 'DeleteOptions', 'propagationPolicy': 'Background',
                            'preconditions': {'uid': o['metadata']['uid']}})
        if st != 404:
            _ok(st, out, 'delete Job %s' % name)
        return ['Job %s deleted' % name]
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
        # the join Secret: never read (the Role has no get), deleted by name;
        # the admission policy refuses the delete unless it is a user pod's
        st, out = api.call('DELETE', (PATHS['Secret'] % ns) + '/' + pod + '-join',
                           {'apiVersion': 'v1', 'kind': 'DeleteOptions'})
        if st != 404:
            _ok(st, out, 'delete Secret %s-join' % pod)
            done.append('Secret %s-join deleted' % pod)
        return done
    if op == 'bind-user-pod':
        if user_pod_of(api, ns, 'Deployment', pod) is None:
            raise Refused('no user pod %s to bind' % pod)
        st, out = api.call('PATCH', (PATHS['Deployment'] % ns) + '/' + pod,
                           {'metadata': {'labels': {'fleet/principal': t['principal']}}},
                           'application/strategic-merge-patch+json')
        _ok(st, out, 'label Deployment %s' % pod)
        return ['Deployment %s fleet/principal=%s' % (pod, t['principal'])]
    raise Refused('not a provisioner op: %s' % op)


def create_svc_run(api, ns, svc, t, r):
    """A service run's Job, then its key Secret owned by it (#4005)."""
    try:
        job = r.svc_run_resources(svc.get('image', ''), t['run'], t['attempt'], t['svc'], t['deadline'],
                                  svc.get('hub', ''), svc.get('cred_central', ''), svc.get('egress_proxy', ''),
                                  namespace=ns, egress=svc.get('egress') or {},
                                  pull_secrets=tuple(svc.get('pull_secrets') or ('acr-pull',)),
                                  ttl=int(svc.get('ttl', r.SVC_TTL)))[0]
        key = r.svc_run_key_secret(job['metadata']['name'], ns, t['token'], 'uid')
    except (ValueError, TypeError) as e:
        raise Refused('cannot render the service run: %s' % e)
    for o in (job, key):
        why = off_template(o, ns)
        if why:
            raise Refused('off the template: ' + why)
    name = job['metadata']['name']
    st, out = api.call('POST', PATHS['Job'] % ns, job)
    if st == 409:  # a replayed create: the Job that is there
        st, out = api.call('GET', (PATHS['Job'] % ns) + '/' + name)
        _ok(st, out, 'Job %s' % name)
        if svc_job_name((out.get('metadata') or {}).get('labels') or {}) != name:
            raise Refused('Job %s is not a service run\'s' % name)
        done = ['Job %s exists' % name]
    else:
        _ok(st, out, 'create Job %s' % name)
        done = ['Job %s' % name]
    key['metadata']['ownerReferences'][0]['uid'] = (out.get('metadata') or {}).get('uid', '')
    st, o = api.call('POST', PATHS['Secret'] % ns, key)
    if st == 409:
        return done + ['Secret %s exists' % key['metadata']['name']]
    _ok(st, o, 'create Secret %s' % key['metadata']['name'])
    return done + ['Secret %s' % key['metadata']['name']]


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
    return 0, '%s %s: %s' % (t['op'], t.get('pod') or t.get('run', ''), '; '.join(done) or 'nothing to do')


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
