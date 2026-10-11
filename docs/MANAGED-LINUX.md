# Managed Linux nodes and Aliyun ACK

A managed Linux machine hosts several non-sudo logins on one persistent volume
(EPIC #3208). The existing hub issues the machine and each login's identity;
the existing Singapore relay forwards Anthropic requests. macOS continues to
use its existing installer and launchd services.

The Linux bootstrap opens the first login. Every later login is opened and
removed on the machine by ONE road, `fleet-node-linux.py login` (root) — the
Linux twin of `fleet-login-new.sh` / `fleet-login-remove.sh`, with the same
steps, exit codes and last line; nothing else on the machine runs `useradd` /
`userdel`:

```sh
sudo /opt/claude-fleet/current/bin/fleet-node-linux.py login open 24haowan \
  --full-name 'Arvin' --join-file /private/login-code
sudo /opt/claude-fleet/current/bin/fleet-node-linux.py login list
sudo /opt/claude-fleet/current/bin/fleet-node-linux.py login remove drill2 --keep-home
```

(Inside the ACK container the runtime is on the volume:
`/var/db/fleet-node/runtime/current/bin/…` — see «Upgrade and recovery».)

- `open`: OS user → home (0700) → install → the login's own node identity
  (join code) → credential separation as a tenant of the shared proxy →
  `account adopt` → its fleet started. A name is 2–16 of `a-z0-9` with at least
  one letter (`control.ValidCreateLogin`); a digit may lead (`24haowan` — only
  here is `useradd` given its bad-name flag).
- `remove`: stop its fleet → `node leave` on the hub → `account forget` →
  `fleet-credsep.py purge` → kill its processes → archive the home to
  `/home/.attic/<login>-<UTC>.tar.gz` (root 600, dropped after 30 days;
  `--delete-home` skips it) → `userdel` / `groupdel`.
- `list`: one line per login, `<login> <uid> <home> <state>` (`ok` · `missing`
  · `mismatch` · `no-home`).

Exit 0 done · 2 bad argument · 3 the login exists already (made outside this
road, or by another hub op) · 4 no such login (remove) · 5 the name is already
an administrator / has sudo — `fleet-login-new.sh` / `fleet-login-remove.sh`'s
codes, so the node program reads one answer from either system; open's last
line is `credsep: separated|pending — …|not separated`, remove's
`credsep: purged`.

**Numbers never move and are never reused.** Each login is declared on the
volume, `/var/db/fleet-node/linux-tenants/<login>.json` (`{login, uid, gid,
home, since}`, root 0600). UIDs start at 10002 and only grow (`.next-uid`); a
removed login's number goes to `.retired` and is never handed out again — the
same name opened again is a new person with a new number. `/etc/passwd` lives
in the image layer and is gone on every container start, so the entrypoint's
first step is `fleet-node-linux.py boot`: every declared group and user back
with its number, home and shell, before the supervisor starts. A home owned by
any other number stops the boot with an error; it is never chowned. A volume
from the single-login version has its `linux-tenant.json` moved to
`linux-tenants/<login>.json` (the old file kept as `.bak`).

## Opening and closing a login from the hub

On a Mac the hub's account ops go to the admin login's agent (it has sudo).
A managed Linux machine has no such login, so **the machine's own node program
opens and closes its logins** (issue #3210, EPIC #3208 C2): the same assign /
remove on the hub, the same `fleet_accounts` row going `pending → creating →
active` (or `remove_pending → removing → removed`), the same result and last
`credsep:` line.

```sh
fleet hub accounts assign gh:2987262 --host fleet-linux-0 --login 24haowan
fleet hub accounts                      # … fleet-linux-0:active:separated
fleet hub accounts remove gh:2987262 --host fleet-linux-0
```

- `fleet node install` on Linux writes `FLEET_NODE_ACCOUNT_OPS=1` into
  `machine.env` (`FLEET_NODE_ACCOUNT_OPS=0` on the command takes it out; the
  daemon reloads the node program when it changes). Only then does
  `ccquota agent --machine` list `CapLoginJoin` in its machine hello and take
  an `account_op` on the machine's own half of the link. A Mac's node program
  never does — its hello is byte for byte as before and an account op sent to
  it is refused `NOT_ADMIN`.
- The hub treats that link as the account-op node for **its own hostname
  only**, and as nothing more: it is not an admin (no SSH CA, no refresh relay,
  no spare logins).
- The node program runs exactly two argvs, as root:
  `python3 -I <current>/bin/fleet-node-linux.py login open <login> [--full-name N]`
  and `… login remove <login> --keep-home|--delete-home`. The join code
  (`FLEET_LOGIN_JOIN_CODE`) and the op (`FLEET_LOGIN_OP_ID`) travel in its
  environment. Anything else — another op, `root`, the service login (`fleet`),
  `fleetcred` or a reserved name, an all-digit or flag-shaped name, a full name
  with a control character, a malformed join code — is refused `BAD_ARGS` with
  one log line and nothing runs (BREAK-IT `linux-hub-other-root-op`). A digit
  may lead only for a name the person already holds on another machine
  (`24haowan`). `:` and `,` in a full name become spaces (passwd's separators).
- The op is written into the login's declaration (`"op"`): the same op again
  (a re-ask, a resume after the node program restarted) goes on where it
  stopped; a login another op or a person made answers 3 (exists — adopt it
  only if it is theirs). A create that fails after its own run declared the
  login is rolled back with `login remove --delete-home`.
- Its book is `/var/db/fleet-node/agent/_machine/account-ops.json`; the daemon
  holds a node-program reload while an op in it runs, and an answer the hub has
  not acked goes out again on the next connection.

## Native Linux

Use Debian 12 or Ubuntu with systemd, Python 3.9+, curl, git, zsh, openssh-server,
sudo, useradd/groupadd, and the runtime tools' shared libraries. The hub must
publish signed artifacts for this Linux architecture matching `release.json`.
An absent artifact is an installation failure, never permission to download a
different CLI version.
The entry port (`FLEET_ENTRY=1`) also needs OpenSSH 9.8+ (`PerSourcePenalties`):
Debian 12's 9.2 runs everything else, but its entry never listens — use Debian 13.

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

The installer's `--login` opens the first login through `login open`. Its
UID/GID comes from the allocator (10002 on a fresh volume); `FLEET_NODE_UID`
pins it on the first install, and its declaration refuses a different UID on
subsequent runs. No login receives a sudo rule.
Root and the dedicated `fleetcred` account retain credentials outside HOME.

The supervisor owns the shared credential proxy and machine agent. It reads
the existing Fleet task templates and runs each account's jobs as that account.
Its systemd service starts at boot. Native runtime upgrades still use the
signed hub release updater.
After installing the hub SSH CA, native installs reload the active SSH service.

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

The image is Debian 13 (trixie, OpenSSH 10.0); its build fails unless
`sshd -T` shows `persourcepenalties`, so an image whose entry port could not
listen is never pushed.

The build context contains the verified release and public key, no join codes
or node credentials. Select the resulting image **digest** for deployment.
The image provides a fixed UID/GID 499 for `fleetcred`; every login's UID/GID
is recreated at each start from its declaration on the volume (`boot`).

## ACK resources

Suggested first deployment: the existing ACK cluster hosting the hub, a separate
`fleet-workers` namespace, `fleet-linux-0`, 1 CPU / 4 GiB requested and 2 CPU /
8 GiB limits (what the live node runs), and 100 GiB encrypted ESSD storage. Select an existing ACK CSI
StorageClass configured for encryption and supporting `ReadWriteOncePod`.
The renderer deliberately does not guess a StorageClass or downgrade access
mode. The headless Service (the system sshd's 22) stays internal; the one public
Service is the door, `fleet-linux-entry`, carrying only the entry port 22022
(«Hub, relay, and access»).

```sh
python3 extras/managed-node/render.py \
  --image registry.cn-shenzhen.aliyuncs.com/24haowan/fleet-managed-node@sha256:IMAGE_DIGEST \
  --hub https://YOUR-HUB --storage-class YOUR_ENCRYPTED_ESSD_CLASS \
  --pull-secret PULL_SECRET_NAME \
  [--entry-host LB_ADDRESS] > /tmp/fleet-linux.json
kubectl apply --dry-run=server -f /tmp/fleet-linux.json
```

Name the namespace's image-pull Secret with `--pull-secret` (repeatable; the
default `acr-pull` is only right where you created one by that name). On ACK
with the password-free ACR plugin the Secret is the plugin's own,
`acr-credential-<hash>` — find it with
`kubectl -n fleet-workers get secret | grep acr-credential`; a wrong name leaves
the pod in `ImagePullBackOff` (issue #3290). Elsewhere, provision it through your
normal registry credential workflow. Put the two newly issued join codes into a Secret
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

### Egress guard

(issue #3281) The hub's ACK cluster runs flannel, which enforces no
NetworkPolicy, so without a guard any process in the pod — an ordinary login
included — could fetch the worker node's RAM-role credentials from the cloud
metadata address and open connections to every other namespace's pods and
Services. The guard lives in the pod's own network namespace: the init
container `egress-guard` (the same image, which carries `iptables`; capabilities
`NET_ADMIN` + `NET_RAW` only, read-only root) loads one `iptables-restore`
OUTPUT table and exits. The `fleet` container never holds `NET_ADMIN` or
`NET_RAW`, so nothing in it — root included — can flush or change the rules.

In order:

| Rule | Default | Flag |
|---|---|---|
| accept loopback, and replies (`ESTABLISHED,RELATED`) | — | — |
| accept DNS (udp + tcp 53) to kube-dns | `172.21.0.10` | `--egress-dns` |
| reject the cloud metadata address | `100.100.100.200/32` | `--egress-metadata` |
| reject the pod range | `172.20.0.0/16` | `--egress-pod-cidr` |
| reject the service range (`kubernetes` is `172.21.0.1`) | `172.21.0.0/20` | `--egress-service-cidr` |
| reject the VPC / private ranges (the node is `10.0.1.240`) | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16` | `--egress-private` |
| everything else — the public internet — is allowed | | |

IPv6 gets the same loopback / reply rules and rejects `fc00::/7` (the pod has no
global IPv6 today; a node without IPv6 skips it with a note). `REJECT` answers at
once, so a blocked connection fails fast instead of hanging. The guard tries
the nft backend, then legacy, and checks the metadata rule is really listed; if
neither backend takes the table, the init container exits 1 and the pod never
starts — closed, never open. Inbound is untouched: the door's 22022 (through the
load balancer, `externalTrafficPolicy: Local`) and the in-cluster 22 are answered
on established connections. The hub, the relay, GitHub, npm and Anthropic are
all public addresses.

Read the cluster's real ranges before rendering for another cluster: the
service range is in the error `kubectl create service clusterip x --tcp=80
--clusterip=1.1.1.1 --dry-run=server` prints, the pod range in each node's
`spec.podCIDR`, kube-dns in `kubectl -n kube-system get svc kube-dns`. Check it
from inside the pod, as root in the `fleet` container and as a login:

```sh
curl -m3 http://100.100.100.200/            # refused
curl -m3 -k https://kubernetes.default.svc  # refused
iptables -F                                 # Permission denied (no NET_ADMIN)
curl -m3 https://YOUR-HUB/version           # works
```

BREAK-IT `linux-egress-metadata`.

## Hub, relay, and access

Use the hub HTTPS URL reachable from ACK. Allow egress to the hub and
`https://fleet-relay.24hw.cn`, as well as the Git/package services your work
needs. Node control connects outward to the hub.

**The door** (issue #3213, EPIC #3208 C6). People reach this machine from
outside through ONE public port, the entry port 22022 — the same second sshd a
Mac home runs (#3070, docs/MANAGED-NODE.md §16): keys only, and only the keys
the hub lists for a login whose home this machine is (root's
`/var/db/fleet-node/entry/keys/<login>`, never `~/.ssh`); no password, no
keyboard-interactive, no root, no admin login. `render.py` makes it a second
Service, `fleet-linux-entry`: `type: LoadBalancer`, TCP 22022 only,
`externalTrafficPolicy: Local` (the entry sshd sees the client's own address,
which the key-revoke cut relies on), and ACK annotations for a public CLB of the
smallest spec paid by traffic (`--entry-lb-spec slb.s1.small`; `clcu` for an
account that can only buy pay-by-use instances). The container's system sshd
(22, PAM, the hub SSH CA) stays on the headless Service — inside the cluster,
never on the load balancer. The installer still disables its password and root
login.

The pod runs with `FLEET_ENTRY=1` / `FLEET_ENTRY_PORT=22022`, and — once the
load balancer has an address — `CCQUOTA_FLEET_NODE_ROUTES=entry=<LB address>:22022`.
That route is not optional on ACK: the hub knocks on the address a reach report
comes from, which here is the cluster's NAT egress, so without it the door is
reported unreachable. The route rides the supervisor's environment into the
node program's `entry reach`, which hands it to the hub as `entry_host`. The
door's address is only the load balancer's: a `<name>.cf.24haowan.com` record is
written by the hub only for a person whose home this machine is (#3067's rule).

The address does not exist until the CLB does, so the door goes up in two
passes (OnDelete: nothing restarts until the pod is deleted):

```sh
# 1. the Service alone, to obtain the load balancer's address
python3 extras/managed-node/render.py --image …@sha256:IMAGE_DIGEST --hub https://YOUR-HUB \
  --storage-class YOUR_ENCRYPTED_ESSD_CLASS > /tmp/fleet-linux.json
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); \
  d["items"]=[i for i in d["items"] if i["metadata"]["name"]=="fleet-linux-entry"]; \
  json.dump(d,open(sys.argv[2],"w"))' /tmp/fleet-linux.json /tmp/fleet-linux-door.json
kubectl apply --dry-run=server -f /tmp/fleet-linux-door.json
kubectl apply -f /tmp/fleet-linux-door.json
kubectl -n fleet-workers get svc fleet-linux-entry -w      # until EXTERNAL-IP is set
# 2. everything, naming that address; then replace the pod (its volume stays)
python3 extras/managed-node/render.py … --entry-host LB_ADDRESS > /tmp/fleet-linux.json
kubectl apply --dry-run=server -f /tmp/fleet-linux.json
kubectl apply -f /tmp/fleet-linux.json
kubectl -n fleet-workers delete pod fleet-linux-0          # never --force
kubectl -n fleet-workers wait pod/fleet-linux-0 --for=condition=Ready --timeout=15m
```

Check it: the machine's `fleet-node-supervisor.py entry reach` (or the node page)
says the hub reached the door at the load balancer, with the host key it
expects; from a computer outside ACK, `ssh -p 22022 -o
PreferredAuthentications=password <login>@LB_ADDRESS` is refused and the login's
registered key lands on its 看台 (BREAK-IT `linux-entry-weak-door`, plus the
`entry-*` rows run against the address). When the door cannot be reached — a
firewall, a CLB outage — the `fleet` client falls through its routes (entry <
tailnet < another direct line < relay, #3067 共同约定 8) to the hub's relay, which
needs nothing from ACK but the node's outward connection.

The login's proxy settings live in root's
`/usr/local/lib/claude-fleet/credsep/fleet.conf`. The default relay is the existing
Singapore endpoint. Bootstrap requests a relay pass using the login's node
token and stores it under its isolated credential store. Reachability probing
selects `relay` when direct provider access is unavailable; configuring a relay
URL alone does not force the route. Use the existing proxy route diagnostics to
verify the actual path before accepting the node.

Claude accounts come from the hub as on a Mac login: the login's settings
(`logins/<login>.env` and the store's `node.env`) carry `CCQUOTA_FLEET_CREDS=1`,
so the machine's node program leases the pool ∩ allowlists for it, files each
token in the shared proxy and writes only the `hub:<label>` marker into the
login's `accounts/` (issue #3211). Every container start re-runs `prepare`,
which adds the line to a store written before it, token untouched. Check it with
`fleet-control-read.sh ready` as the login: `creds` reads `true`.

## Upgrade and recovery

The machine follows `stable` by itself, with the same updater as a Mac
(`fleet-node-update.py`, docs/MANAGED-NODE.md §7) — issue #3212. The runtime lives
on the persistent volume, `FLEET_NODE_ROOT=/var/db/fleet-node/runtime`
(`<sha>/`, `current`, `.prev` — the Mac `<root>`'s shape); the image's release is
only a **seed** at `/opt/claude-fleet/seed/<sha>`. The entrypoint
(`/usr/local/lib/fleet-image-stage.py boot`) copies it onto the volume when the
volume has no `current`, or when the image's signed `seq` is newer than the
disk's and the updater is at rest (`update.json` phase idle), then starts
`<disk current>/bin/fleet-node-linux.py foreground`. A container restart never
puts the image's older version back (BREAK-IT `linux-image-pins-old`).

`FLEET_NODE_UPDATE_OWNER=node` (the image's default) keeps the supervisor's
`update` task and its restart request, and the machine's node program lists
`CapRelease`, so a new stable starts the update at once. A switch stages the
release, moves `current`, re-links every login's `~/.claude/fleet` and asks the
supervisor to restart; `foreground` is a resident loop that starts the supervisor
again from the re-read `current` — the container, its tmux servers and every
session stay. The machine doctor after the switch decides: a FAIL the old version
did not have rolls everything back and skips that release. `/usr/local/bin`'s
tmux / claude / codex / ccquota and the image's PATH point at the disk's
`current/`, never the image's. The hub's `CCQUOTA_FLEET_RELEASE_PLATFORMS` lists
`linux-amd64`, so a release without the Linux artifacts is neither built nor
moved to stable (`fleet-stable.sh move` refuses, `artifacts:`).

The image is rebuilt only when the system layer changes (Debian, OpenSSH,
python). The StatefulSet uses `OnDelete`: update its image digest, arrange a
suitable restart, and delete the pod normally — a newer image's seed is taken on
that start, an older one is ignored. `FLEET_NODE_UPDATE_OWNER=image` turns the
self-update off: the supervisor omits its updater task (a manual tick refuses to
resume even a persisted switch), the boot always puts the image's version in
`current`, and credential-pool synchronization runs as its own task. The PVC
stays either way. Each activation relinks every login's runtime and reapplies its
hooks and settings before restoring sessions; a failed apply remains pending for
retry.

On SIGTERM, the entrypoint saves every login's Fleet session snapshot before stopping the
supervisor. On startup it restores snapshots through the existing restore
script. Abrupt node loss can recover only previously persisted snapshots and
conversation history; memory and running processes do not survive. Every
container start has a new boot ID, preventing adoption of persisted PIDs that
now identify unrelated processes.

Readiness requires completed bootstrap, a healthy supervisor, its proxy/node
agent/sshd children, and no refused login lane. Liveness checks the resident
loop only (its heartbeat, `/run/fleet-node-loop`): neither a hub outage nor a
supervisor restarting onto a new release restarts the pod. A supervisor that
dies more than 10 times in 10 minutes ends the loop, and Kubernetes restarts
the container.

## Acceptance evidence

CI runs the portable lifecycle contracts, existing managed-node regression
tests (including image replacement, rollback and failed-apply retry), and a
Linux/root installer smoke with real users, SSH CA validation and the shared proxy
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

The real-person walk on fleet-linux-0 (a login opened from the hub, connected
from a computer and a phone, Claude answering, a drill login removed and checked
gone) follows [MANAGED-LINUX-DRILL.md](MANAGED-LINUX-DRILL.md), step by step.
