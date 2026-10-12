# macmini US reverse egress

The US macmini initiates 16 authenticated WSS connections to the existing ACK HTTPS ingress.
The cluster CONNECT service borrows one connection per TCP tunnel; macmini resolves and opens
the public upstream. The tunnel carries opaque TLS bytes and preserves the upstream certificate
and SNI. No home-router inbound port, public CONNECT listener, TLS interception, subscription
credential, or new LoadBalancer is required.

`us-egress.py gateway` reads its authentication token from a Kubernetes Secret at startup.
`client-run.sh` reads the same dedicated tunnel token from macOS System Keychain at startup.
Neither endpoint stores a subscription token. Provision this tunnel token through encrypted stdin,
never command arguments, config files, manifests in git, or logs. The gateway Secret is
`fleet-workers/fleet-us-egress`, key `token`; Keychain account and service are `fleet-us-egress`.

Download the public universal wheel, verifying the hash in `requirements.txt`. Render:

```sh
python3 extras/us-egress/render.py --image REGISTRY/IMAGE@sha256:DIGEST \
  --wheel /path/websockets-12.0-py3-none-any.whl > /tmp/fleet-us-egress.yaml
kubectl apply --dry-run=server -f /tmp/fleet-us-egress.yaml
kubectl apply -f /tmp/fleet-us-egress.yaml
```

The renderer includes the public wheel in the ConfigMap and installs it offline in an init container.
Default namespace is `fleet-workers`; it shares the existing TLS server at
`claudefleet.24haowan.com`, using only the exact `/_fleet/us-egress` path. If deploying with a
separate TLS server, use `--tls-secret` with an existing secret in that namespace. Do not copy a
production TLS private key between namespaces or bypass admission rules.

On macmini, after provisioning System Keychain, install the connector from the reviewed source:

```sh
sudo python3 extras/us-egress/install-macos.py --wheel /path/websockets-12.0-py3-none-any.whl
```

The installer registers `com.claude-fleet.us-egress` in Fleet's supported root-owned
`/var/db/fleet-node/keep-labels` extension so the supervisor retains this dedicated daemon.
It only replaces/restarts that daemon. The token is absent from its plist.

Observability: `/livez` is gateway-process readiness, so ingress can receive reconnecting clients
throughout an outage. `/healthz` returns 503 without an authenticated US connector. CONNECT also
returns 502 when none is available; there is no direct or Singapore fallback. Kubernetes readiness
alone therefore does **not** prove the US link is available. Monitor `/healthz` and real CONNECT.
JSON logs contain target hostname, status, time, source and link RTT; no headers or payloads.

The US host rejects private, mixed public/private and multicast DNS answers. The cluster accepts
CONNECT only from the configured Pod CIDR, to approved domains and TCP 443. Authentication covers
the WSS connector. The cluster CONNECT listener itself relies on source CIDR and workload network
isolation; ACK flannel's NetworkPolicy limitations must be accounted for. 16 lanes are an initial
concurrency setting, not a capacity claim; busy requests wait at most four seconds for a lane.

`deploy/k8s/egress/fleet-workers` maps Claude's API, auth, connectors, downloads and known telemetry
domains to this US parent, and maps GitHub there as well. `FLEET_EGRESS_REQUIRE_VIA` rejects a
configuration missing a required parent. Mandatory Anthropic credential traffic is selected by
root's `FLEET_CRED_ANTHROPIC_PROXY` config; only a trusted node can use that credential route and
neither relay nor central is a fallback. Generic proxy environment variables alone are insufficient
for Python `http.client`, so the credential proxy uses an explicit CONNECT connection.

Managed-node startup also merges proxy variables into root Claude managed settings, preserving existing permission policy, so background supervisors do not depend on whichever shell starts them first.

Managed-node rendering supports `--anthropic-proxy http://HOST:PORT`. Pair it with the existing
`--egress-proxy`, `--egress-closed`, and exact destination `--egress-allow` settings. Preserve required
hub/control destinations and test them before changing an existing worker's guard. A root route
already stored in `credsep/<login>.conf` survives route healing if the Pod env has not yet changed;
Pod replacement must carry the env settings in the StatefulSet template. CLI processes read network
environment at startup and need a controlled restart; changing root proxy settings cannot update
an already-running CLI's auxiliary traffic. Never overwrite a signed immutable runtime.

Validation:

```sh
bash bin/fleet-anthropic-egress-selftest.sh
PYTHONPATH=/path/to/unpacked/wheel python3 extras/us-egress/selftest.py
```

The first verifies TLS/SNI, certificate mismatch, no direct retry, root-only policy, trust gates,
route persistence, renderer integration and generic parent failure. The second checks connector
403, target suffix spoofing, no connector, remote rejection, private DNS and byte preservation.
For production acceptance additionally run a closed-egress canary in ACK, stop only the connector,
verify 502 and blocked IPv4/IPv6 direct access, restore it, and observe reconnection. Short public
endpoint probes do not verify OAuth refresh, account eligibility, long streams or sustained capacity.
