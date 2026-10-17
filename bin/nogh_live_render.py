#!/usr/bin/env python3
"""Explicit C9 test admission/template, separate from production off_template.

This renders only. The live owner prepares the namespace, immutable workload
ConfigMaps and credentials by normal management roads, creates inert pods, then
binds their actual UIDs/addresses before any workload starts. No apply helper.
"""
from nogh_live_contract import require, validate

GUARD_CAPS = ['NET_ADMIN', 'NET_RAW']
OBSERVER_CAPS = ['SYS_PTRACE', 'SETPCAP', 'CHOWN', 'DAC_OVERRIDE', 'FOWNER', 'SETUID',
                 'SETGID', 'SYS_CHROOT', 'KILL', 'AUDIT_WRITE', 'NET_BIND_SERVICE']


def security(caps):
    return dict(runAsUser=0, runAsGroup=0, allowPrivilegeEscalation=False,
                readOnlyRootFilesystem=True, capabilities=dict(drop=['ALL'], add=list(caps)),
                seccompProfile=dict(type='RuntimeDefault'))


def labels(plan, role):
    return {'fleet/c9-run': plan['run_id'], 'fleet/c9-generation': str(plan['generation']),
            'fleet/c9-role': role}


def pod(plan, endpoint):
    role, name = endpoint['role'], endpoint['name']
    env = [{'name': key, 'valueFrom': {'fieldRef': {'apiVersion': 'v1', 'fieldPath': field}}}
           for key, field in (('C9_POD_UID', 'metadata.uid'), ('C9_POD_NAME', 'metadata.name'),
                              ('C9_NAMESPACE', 'metadata.namespace'))]
    env.append(dict(name='C9_TEST_ONLY', value='1'))
    common = dict(image=endpoint['image'], imagePullPolicy='IfNotPresent', env=env, stdin=True,
                  stdinOnce=True, tty=False, terminationMessagePolicy='File',
                  terminationMessagePath='/dev/termination-log',
                  resources=dict(requests=dict(cpu='100m', memory='128Mi'),
                                 limits=dict(cpu='2', memory='2Gi')))
    state = dict(name='c9-state', mountPath='/run/fleet-c9')
    guard = dict(common, name='egress-guard', command=['/usr/local/bin/fleet-c9-guard'], args=[role],
                 securityContext=security(GUARD_CAPS), volumeMounts=[state])
    observed = dict(common, name='observed', command=['/usr/local/bin/fleet-c9-supervise'], args=[role],
                    securityContext=security(OBSERVER_CAPS + (['NET_ADMIN'] if role == 'proxy' else [])),
                    volumeMounts=[state, dict(name='c9-state', mountPath='/etc/resolv.conf',
                                              subPath='resolv.conf', readOnly=True),
                                  dict(name='workload', mountPath='/opt/fleet-c9', readOnly=True),
                                  dict(name='scratch', mountPath='/tmp'),
                                  dict(name='credentials', mountPath='/run/c9-credentials', readOnly=True),
                                  dict(name='control', mountPath='/run/c9-control', readOnly=True)])
    if role == 'proxy':
        observed['volumeMounts'].append(dict(name='proxy-private', mountPath='/run/c9-proxy-private', readOnly=True))
    spec = dict(restartPolicy='Never', activeDeadlineSeconds=55, terminationGracePeriodSeconds=0,
                serviceAccountName='c9-isolated', automountServiceAccountToken=False,
                hostNetwork=False, hostPID=False, hostIPC=False, shareProcessNamespace=False,
                # No cluster search paths or fallback resolver. The guard permits
                # DNS only to this run's explicit resolver, set in the binding.
                dnsPolicy='None', dnsConfig=dict(nameservers=['127.0.0.1'], searches=[],
                                                 options=[dict(name='attempts', value='1')]),
                enableServiceLinks=False, initContainers=[guard], containers=[observed],
                volumes=[dict(name='c9-state', emptyDir=dict(medium='Memory', sizeLimit='64Mi')),
                         dict(name='scratch', emptyDir=dict(sizeLimit='256Mi')),
                         dict(name='workload', configMap=dict(name=name + '-workload', defaultMode=0o555)),
                         dict(name='credentials', secret=dict(secretName=name + '-credentials', defaultMode=0o444)),
                         dict(name='control', secret=dict(secretName=name + '-control', defaultMode=0o400))])
    if role == 'proxy':
        spec['volumes'].append(dict(name='proxy-private', secret=dict(secretName=name + '-tls', defaultMode=0o400)))
    return dict(apiVersion='v1', kind='Pod', metadata=dict(name=name, namespace=plan['namespace'],
                labels=labels(plan, role)), spec=spec)


# A request with no subresource (a Pod CREATE) has NO subResource key: CEL
# errors on it and failurePolicy Fail denies the Pod, so every read is has()-
# guarded (live, #4625).
# One container's rule, applied to containers and initContainers SEPARATELY: the
# API server types the two lists apart, so `containers + initContainers` has no
# `_+_` overload and the whole policy fails its typeChecking (live, #4625).
CONTAINER_RULE = ("c.image in %s && "
                  "!has(c.lifecycle) && !has(c.livenessProbe) && !has(c.readinessProbe) && !has(c.startupProbe) && "
                  "c.securityContext.allowPrivilegeEscalation == false && "
                  "(!has(c.securityContext.privileged) || !c.securityContext.privileged) && "
                  "c.securityContext.readOnlyRootFilesystem && c.securityContext.capabilities.drop == ['ALL'] && "
                  "c.securityContext.seccompProfile.type == 'RuntimeDefault' && "
                  "(!has(c.securityContext.procMount) || c.securityContext.procMount == 'Default') && "
                  "!has(c.securityContext.seLinuxOptions)")


def admission(plan):
    """One run's explicit API-server contract; not a production exception.

    Scope is the literal new test namespace, all callers. Blocking exec is
    essential: /proc polling cannot detect every short-lived injected process.
    The controller compares this exact policy and binding from authenticated
    API reads and requires the API server's successful type-check status.
    """
    name, namespace = 'fleet-c9-' + plan['run_id'], plan['namespace']
    names = '[' + ','.join(repr(e['name']) for e in plan['endpoints']) + ']'
    images = '[' + ','.join(repr(e['image']) for e in plan['endpoints']) + ']'
    expressions = [
        ("request.operation != 'CONNECT' || (has(request.subResource) && request.subResource == 'attach' && "
         "object.container in ['egress-guard', 'observed'] && request.name in " + names +
         " && request.userInfo.username == " + repr(plan['controller']) +
         " && (!has(object.tty) || !object.tty))",
         'C9 forbids exec and port-forward; control is attach to the fixed supervisor only'),
        ("!has(request.subResource) || request.subResource != 'ephemeralcontainers'", 'C9 forbids injected processes'),
        ("request.resource.resource != 'pods' || request.operation in ['CONNECT', 'DELETE'] || ("
         "object.metadata.name in " + names + " && object.spec.restartPolicy == 'Never' && "
         "object.spec.activeDeadlineSeconds <= 55 && object.spec.automountServiceAccountToken == false && "
         "object.spec.serviceAccountName == 'c9-isolated' && "
         "(!has(object.spec.hostNetwork) || !object.spec.hostNetwork) && "
         "(!has(object.spec.hostPID) || !object.spec.hostPID) && "
         "(!has(object.spec.hostIPC) || !object.spec.hostIPC) && "
         "(!has(object.spec.shareProcessNamespace) || !object.spec.shareProcessNamespace) && "
         "(!has(object.spec.ephemeralContainers) || object.spec.ephemeralContainers.size() == 0) && "
         "object.spec.containers.size() == 1 && object.spec.initContainers.size() == 1 && "
         "object.spec.containers[0].name == 'observed' && "
         "object.spec.containers[0].command == ['/usr/local/bin/fleet-c9-supervise'] && "
         "object.spec.initContainers[0].name == 'egress-guard' && "
         "object.spec.initContainers[0].command == ['/usr/local/bin/fleet-c9-guard'] && "
         "object.spec.initContainers[0].securityContext.capabilities.add == " + repr(GUARD_CAPS) + " && "
         "object.spec.containers[0].securityContext.capabilities.add == "
         "(object.spec.containers[0].args == ['proxy'] ? " + repr(OBSERVER_CAPS + ['NET_ADMIN']) +
         " : " + repr(OBSERVER_CAPS) + ") && "
         + " && ".join("object.spec.%s.all(c, %s)" % (field, CONTAINER_RULE % images)
                       for field in ('containers', 'initContainers')) + " && "
         "object.spec.volumes.all(v, !has(v.hostPath) && !has(v.persistentVolumeClaim) && "
         "!has(v.projected) && (has(v.emptyDir) || has(v.configMap) || has(v.secret))))",
         'C9 permits only its bounded, exclusive observer template'),
        ("request.resource.resource != 'pods' || request.operation != 'UPDATE' || "
         "(has(request.subResource) && request.subResource == 'status') || object.spec == oldObject.spec", 'C9 pod spec is immutable'),
        ("!(request.resource.resource in ['configmaps','secrets']) || "
         "(request.operation != 'DELETE' && has(object.immutable) && object.immutable)",
         'C9 artifacts are immutable and cannot be replaced while the policy is installed'),
    ]
    for ep in plan['endpoints']:
        expressions.append((
            "request.resource.resource != 'pods' || request.operation in ['CONNECT','DELETE'] || "
            "object.metadata.name != " + repr(ep['name']) + " || "
            "(object.spec.containers[0].image == " + repr(ep['image']) +
            " && object.spec.initContainers[0].image == " + repr(ep['image']) +
            " && object.spec.containers[0].args == " + repr([ep['role']]) +
            " && object.spec.initContainers[0].args == " + repr([ep['role']]) + ")",
            'C9 role and image are fixed for each original Pod'))
    # Separate typed resources. Putting Pod, Secret and CONNECT option objects
    # into one CEL policy makes valid fields undefined for another resource.
    groups = [
        ('pods', ['CREATE', 'UPDATE', 'DELETE'], ['pods', 'pods/ephemeralcontainers'],
         [expressions[i] for i in (1, 2, 3)] + expressions[5:]),
        ('attach', ['CONNECT'], ['pods/attach'], [expressions[0]]),
        ('exec', ['CONNECT'], ['pods/exec', 'pods/portforward'],
         [('false', 'C9 forbids injected execution and port forwarding')]),
        ('artifacts', ['CREATE', 'UPDATE', 'DELETE'], ['configmaps', 'secrets'], [expressions[4]]),
    ]
    objects = []
    for suffix, operations, resources, validations in groups:
        policy_name = name + '-' + suffix
        policy = dict(apiVersion='admissionregistration.k8s.io/v1', kind='ValidatingAdmissionPolicy',
                      metadata=dict(name=policy_name), spec=dict(failurePolicy='Fail',
                      matchConstraints=dict(matchPolicy='Equivalent', namespaceSelector={}, objectSelector={},
                             resourceRules=[dict(apiGroups=[''], apiVersions=['v1'],
                             operations=operations, resources=resources, scope='*')]),
                      matchConditions=[dict(name='exact-test-namespace', expression='request.namespace == ' + repr(namespace))],
                      validations=[dict(expression=expression, message=message) for expression, message in validations]))
        binding = dict(apiVersion='admissionregistration.k8s.io/v1', kind='ValidatingAdmissionPolicyBinding',
                       metadata=dict(name=policy_name), spec=dict(policyName=policy_name, validationActions=['Deny']))
        objects.extend([policy, binding])
    return objects


def check_pod(plan, endpoint, actual):
    """Compare all security-relevant expected fields, allowing API defaults only."""
    expected = pod(plan, endpoint)
    omitted_zeroes = {('hostNetwork',), ('hostPID',), ('hostIPC',), ('dnsConfig', 'searches'),
                      ('containers', '*', 'tty'), ('initContainers', '*', 'tty')}
    def contains(want, have, path=()):
        if isinstance(want, dict):
            return isinstance(have, dict) and all(
                (k not in have and path + (k,) in omitted_zeroes and not v) or
                (k in have and contains(v, have[k], path + (k,))) for k, v in want.items())
        if isinstance(want, list):
            return isinstance(have, list) and len(want) == len(have) and all(
                contains(x, y, path + ('*',)) for x, y in zip(want, have))
        return want == have
    require(contains(expected['spec'], actual.get('spec')), 'TEST_TEMPLATE_CHANGED')
    spec = actual['spec']
    for c in spec['containers'] + spec['initContainers']:
        require(not any(c.get(k) for k in ('lifecycle', 'livenessProbe', 'readinessProbe', 'startupProbe')),
                'OUTSIDE_EXEC_REFUSED')
        require(not c.get('securityContext', {}).get('privileged'), 'PRIVILEGED_REFUSED')
        require(not set(c) - set(expected['spec']['containers'][0]) - {'name', 'terminationMessagePath',
                'terminationMessagePolicy'}, 'CONTAINER_EXTRA_FIELDS')
        require(not set(c['securityContext']) - set(security([])), 'SECURITY_CONTEXT_EXTRA_FIELDS')
    require(not any(spec.get(k) for k in ('securityContext', 'hostAliases', 'runtimeClassName',
            'hostUsers', 'imagePullSecrets', 'overhead')), 'POD_EXTRA_EXECUTION_SURFACE')
    require(not spec.get('ephemeralContainers'), 'TEST_TEMPLATE_CHANGED')


def render(plan, test_only=False):
    require(test_only is True, 'EXPLICIT_TEST_ONLY_REQUIRED')
    # A recipe names immutable artifacts and normal enrolled identities. It
    # deliberately has NO predicted Pod UID/IP; only fresh GET can bind those.
    validate(plan, bound=False)
    return admission(plan) + [dict(apiVersion='v1', kind='ServiceAccount',
            metadata=dict(name='c9-isolated', namespace=plan['namespace']), automountServiceAccountToken=False)] + \
        [pod(plan, ep) for ep in plan['endpoints']]
