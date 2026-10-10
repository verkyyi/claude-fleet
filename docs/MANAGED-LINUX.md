# Managed Linux nodes and Aliyun ACK

The first Linux deployment is one managed machine, one non-sudo worker login,
and one persistent volume. The existing hub issues the machine and login
identities; the existing Singapore relay forwards Anthropic requests. macOS
continues to use its existing installer and launchd services.

The Linux bootstrap creates its first login. The macOS account-opening/removal
scripts are not used for Linux: do not enable remote admin account operations
on this first-version node. Adding tenants through the hub is outside this
single-login deployment.

## Native Linux

Use Debian 12 or Ubuntu with systemd, Python 3.9+, curl, git, zsh, openssh-server,
sudo, useradd/groupadd, and the runtime tools' shared libraries. The hub must
publish signed artifacts for this Linux architecture matching `release.json`.
An absent artifact is an installation failure, never permission to download a
different CLI version.

Generate **two trusted join codes** using the hub's operator endpoint
`POST /v1/fleet/nodes/join-codes`: one for the machine, one for its worker login.
The default managed code is trusted, one-use, and expires in one hour. Keep
codes in private temporary files, not shell history or source control. The
machine registers as `root`; the login registers as `fleet`. Their tokens must
remain different because the hub verifies each machine lane's login identity.

```sh
sudo bash bin/fleet-node-install.sh --hub https://YOUR-HUB \
  --join-file /private/machine-code --login fleet \
  --login-join-file /private/login-code --service systemd
sudo systemctl status claude-fleet-node.service
sudo /opt/claude-fleet/current/bin/fleet-node-supervisor.py status --check
```

Use a fresh login name. Its default UID/GID is 10002; `FLEET_NODE_UID` selects
another before the first install. The persisted `linux-tenant.json` refuses a
different UID or login on subsequent runs. The worker receives no sudo rule.
Root and the dedicated `fleetcred` account retain credentials outside HOME.

The supervisor owns the shared credential proxy and machine agent. It reads
the existing Fleet task templates and runs each account's jobs as that account.
Its systemd service starts at boot. Native runtime upgrades still use the
signed hub release updater.

## Build the ACK image

Build from a **published signed release containing the Linux implementation**.
Obtain the release public key through the established trusted distribution
channel. `ccquota release fetch` verifies the signature and artifact digests;
the image staging step checks the pinned artifact digests again.

```sh
bash extras/managed-node/prepare-image.sh \
  https://YOUR-HUB /private/release.pub RELEASE_COMMIT /tmp/fleet-node-image linux-amd64
docker build --platform linux/amd64 \
  -t registry.cn-shenzhen.aliyuncs.com/24haowan/fleet-managed-node:RELEASE_COMMIT \
  /tmp/fleet-node-image
docker push registry.cn-shenzhen.aliyuncs.com/24haowan/fleet-managed-node:RELEASE_COMMIT
```

The build context contains the verified release and public key, no join codes
or node credentials. Select the resulting image **digest** for deployment.
The image provides a fixed UID/GID 499 for `fleetcred`; the worker's UID/GID
are recreated consistently from their persisted declaration.

## ACK resources

Suggested first deployment: the existing ACK cluster hosting the hub, a separate
`fleet-workers` namespace, `fleet-linux-0`, 2 CPU / 8 GiB requested and 4 CPU /
16 GiB limits, and 100 GiB encrypted ESSD storage. Select an existing ACK CSI
StorageClass configured for encryption and supporting `ReadWriteOncePod`.
The renderer deliberately does not guess a StorageClass or downgrade access
mode. The headless Service is internal; no public load balancer is created.

```sh
python3 extras/managed-node/render.py \
  --image registry.cn-shenzhen.aliyuncs.com/24haowan/fleet-managed-node@sha256:IMAGE_DIGEST \
  --hub https://YOUR-HUB --storage-class YOUR_ENCRYPTED_ESSD_CLASS \
  > /tmp/fleet-linux.json
kubectl apply --dry-run=server -f /tmp/fleet-linux.json
```

Provision the namespace and its `acr-pull` image-pull Secret through your normal
registry credential workflow. Put the two newly issued join codes into a Secret
from private files, then apply the reviewed resources:

```sh
kubectl create namespace fleet-workers
kubectl -n fleet-workers create secret generic fleet-linux-join \
  --from-file=machine=/private/machine-code --from-file=login=/private/login-code
kubectl apply -f /tmp/fleet-linux.json
kubectl -n fleet-workers rollout status statefulset/fleet-linux --timeout=15m
```

After both identities are registered and the pod is ready, delete the join-code
Secret and private code files. The volume holds the issued identities, so a
replacement pod does not need a fresh join code. A failed verification of a
persisted identity stops bootstrap; it never silently registers another node.

The PVC retains `/var/db/fleet-node`, `/var/db/fleet-cred`, `/home`, and supervisor
logs. Temporary sockets and process state in `/run` are recreated. The machine
state also retains the SSH host key. Enrollment/runtime startup holds an
exclusive volume lock; a second process cannot concurrently operate this node.
Do not force-delete a pod while its old instance could still access its volume.

The container has no Kubernetes service-account token, privileged mode, host
mounts, host PID namespace, or host network. Its root bootstrap uses a limited
capability set to manage in-container users and drop to the worker/credential
accounts. Confirm this workload fits the namespace's admission policy.

## Hub, relay, and access

Use the hub HTTPS URL reachable from ACK. Allow egress to the hub and
`https://fleet-relay.24hw.cn`, as well as the Git/package services your work
needs. Node control connects outward to the hub. Interactive SSH additionally
needs a route from the Fleet client to the pod's internal Service, such as your
existing VPC/private access; registration alone does not provide that route.
The installer configures the hub SSH user CA and disables container password
and root SSH login.

The login's proxy settings live in root's
`/usr/local/lib/claude-fleet/credsep/fleet.conf`. The default relay is the existing
Singapore endpoint. Bootstrap requests a relay pass using the login's node
token and stores it under its isolated credential store. Reachability probing
selects `relay` when direct provider access is unavailable; configuring a relay
URL alone does not force the route. Use the existing proxy route diagnostics to
verify the actual path before accepting the node.

## Upgrade and recovery

Kubernetes owns the ACK runtime version. The supervisor omits its updater task,
and a manual updater tick refuses to resume even an old persisted switch while
`FLEET_NODE_UPDATE_OWNER=image`. The StatefulSet uses `OnDelete`: update its image
digest, arrange a suitable restart, and delete the pod normally. Roll back by
restoring the previous image digest and restarting again. The PVC stays.

On SIGTERM, the entrypoint saves Fleet's session snapshot before stopping the
supervisor. On startup it restores snapshots through the existing restore
script. Abrupt node loss can recover only previously persisted snapshots and
conversation history; memory and running processes do not survive. Every
container start has a new boot ID, preventing adoption of persisted PIDs that
now identify unrelated processes.

Readiness requires completed bootstrap, a healthy supervisor, its proxy/node
agent/sshd children, and no refused login lane. Liveness checks the supervisor
only; a hub outage should not restart an otherwise healthy pod.

## Acceptance evidence

CI runs the portable lifecycle contracts, existing managed-node regression
tests, and a Linux/root bootstrap smoke with real users and the shared proxy
against a loopback hub fixture. That proves OS integration, not a live ACK or
Anthropic request.

For a real deployment, record:

1. The hub reports the machine and worker login online and trusted, with compute
   enabled and credential separation healthy.
2. The worker's `fleet-cred-proxy.sh route --provider claude` selects `relay`, and
   Claude returns a response through Singapore. The worker cannot read the
   node/subscription credential store or obtain sudo.
3. Start a session, record its identity, and save its snapshot. Delete the pod
   normally; verify the same endpoint/login, worktree, conversation, and SSH
   host identity return without the join Secret.
4. Change the image digest, restart, and verify the declared runtime. Restore
   the prior digest and confirm rollback with the same identities and volume.

Do not label the node production-ready until those live checks pass.
