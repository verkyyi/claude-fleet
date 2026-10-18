#!/usr/bin/env python3
"""Read actual test Hub/node identities through existing authenticated APIs.

This runs as a trusted, traced probe inside the selected Hub's namespace. No
refresh-all, identity mutation, enrollment, attach record or launch receipt is
created. Inputs and evidence contain no bearer credential.
"""
import hashlib
import json
from pathlib import Path
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

from nogh_live_contract import require


# The live node read's own bound (above); the readiness window is await_ready's.
LIVE_READ_TIMEOUT = 6


class NotReady(Exception):
    """An exact original identity exists but its startup is not yet complete."""


def ready(condition):
    if not condition:
        raise NotReady()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_):
        raise ValueError('REDIRECT_REFUSED')


def reader(plan):
    base = plan['hub']['origin'].rstrip('/')
    token = (Path('/run/c9-control') / 'hub-token').read_text().strip()
    require(token and '\n' not in token and '\r' not in token, 'HUB_CREDENTIAL_REQUIRED')
    context = ssl.create_default_context(cafile='/run/c9-credentials/ca.pem')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
                                        urllib.request.HTTPSHandler(context=context))

    def get(path, raw=False):
        require(path.startswith('/') and not path.startswith('//'), 'API_PATH')
        request = urllib.request.Request(base + path, headers={'Authorization': 'Bearer ' + token})
        # A live fleet_status is the hub asking the node, whose fleet-control
        # read runs under the observer's strace: measured live well past 2 s
        # (#4625). Every other read is the hub's own.
        timeout = LIVE_READ_TIMEOUT if path.startswith('/v1/fleet/fleet_status') else 2
        try:
            with opener.open(request, timeout=timeout) as response:
                require(response.status == 200 and response.geturl() == base + path, 'API_RESPONSE')
                body = response.read(1024 * 1024 + 1)
                require(len(body) <= 1024 * 1024, 'API_RESPONSE_LIMIT')
        except urllib.error.HTTPError as exc:
            if exc.code == 503:
                raise NotReady() from None
            raise
        except urllib.error.URLError as exc:
            # Reset/aborted while a starting hub is busy under the observer
            # was seen live too (#4625): transient, bounded by the window.
            if isinstance(exc.reason, (ConnectionRefusedError, ConnectionResetError, ConnectionAbortedError,
                                       TimeoutError)):
                raise NotReady() from None
            raise
        except (TimeoutError, ConnectionResetError, ConnectionAbortedError):
            # A read that times out AFTER the connection is a bare TimeoutError,
            # not a URLError: the same not-yet-ready, never a refusal (#4625).
            raise NotReady() from None
        return body if raw else json.loads(body)
    return get


def exactly(values, condition, code, starting=False):
    matched = [value for value in values if condition(value)]
    if starting:
        ready(matched)
    require(len(matched) == 1, code)
    return matched[0]


def verify(plan, get):
    key = get('/v1/fleet/account-key', raw=True)
    require(key.startswith(b'ed25519 ') and
            'sha256:' + hashlib.sha256(key).hexdigest() == plan['hub']['key_digest'], 'HUB_KEY_CHANGED')
    who = get('/v1/me')
    require(who.get('role') in ('admin', 'operator'), 'NORMAL_OPERATOR_CREDENTIAL_REQUIRED')
    version = get('/version')
    commit = version.get('commit', '')
    require(isinstance(commit, str) and 7 <= len(commit) <= 40 and
            plan['hub']['commit'].startswith(commit), 'HUB_RUNNING_VERSION_CHANGED')
    nodes = get('/v1/nodes')['nodes']
    fleets = get('/v1/fleet/fleet_list')['fleets']
    accounts = get('/v1/fleet/accounts')['accounts']
    observed = []
    for ep in plan['endpoints']:
        if ep['role'] not in ('node-a', 'node-b'):
            continue
        expected = ep['binding']
        node = exactly(nodes, lambda n: n.get('endpoint_id') == expected['endpoint_id'], 'NODE_AMBIGUOUS', True)
        require(node.get('machine_id') == expected['machine_id']
                and node.get('hostname') == expected['hostname'] and node.get('os_user') == ep['login'],
                'NODE_BINDING_CHANGED')
        ready(node.get('connected') is True)
        require(node.get('compatible') is True, 'NODE_INCOMPATIBLE')
        fleet = exactly(fleets, lambda f: f.get('fleet_id') == expected['fleet_id'], 'FLEET_AMBIGUOUS', True)
        require(fleet.get('endpoint_id') == expected['endpoint_id']
                and fleet.get('machine_id') == expected['machine_id'] and fleet.get('os_user') == ep['login'],
                'FLEET_BINDING_CHANGED')
        ready(fleet.get('registered') is True and fleet.get('availability') == 'online')
        # Accounts.endpoint_id may name the admin endpoint that created a login;
        # ownership is the unique active (hostname, login), not that field.
        account = exactly(accounts, lambda a: a.get('hostname') == expected['hostname']
                          and a.get('login') == ep['login'] and a.get('state') == 'active', 'OWNER_AMBIGUOUS')
        require(account.get('principal_id') == expected['owner'], 'OWNER_CHANGED')
        status = get('/v1/fleet/fleet_status?fleet_id=' + urllib.parse.quote(expected['fleet_id'], safe=''))
        require(all(status.get(k) == v for k, v in
                (('fleet_id', expected['fleet_id']), ('machine_id', expected['machine_id']),
                 ('os_user', ep['login']), ('machine_name', expected['hostname']))), 'NODE_NOT_LIVE')
        ready(status.get('source') == 'live')
        observed.append(dict(role=ep['role'], binding=expected, login=ep['login'], source='live'))
    return dict(hub_commit=commit, hub_key_digest=plan['hub']['key_digest'], endpoints=observed)


def await_ready(plan, get, seconds=20):
    deadline = time.monotonic() + seconds
    while True:
        try:
            return verify(plan, get)
        except NotReady:
            require(time.monotonic() < deadline, 'IDENTITY_READINESS_TIMEOUT')
            time.sleep(min(0.1, deadline - time.monotonic()))
