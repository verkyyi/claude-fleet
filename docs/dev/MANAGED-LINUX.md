# Managed Linux nodes and Aliyun ACK

A managed Linux machine hosts several non-sudo logins on one persistent volume
(EPIC #3208). The existing hub issues the machine and each login's identity;
the existing Singapore relay forwards Anthropic requests. macOS continues to
use its existing installer and launchd services.

An ACK node has **no primary login** (issue #3526): every login on it is a
person's, assigned on the hub and rebuilt from the volume at each start
(«No primary login» below). A native install may still open a first login with
`--login`. Every login is opened and removed on the machine by ONE road, `fleet-node-linux.py login` (root) — the
Linux twin of `fleet-login-new.sh` / `fleet-login-remove.sh`, with the same
steps, exit codes and last line; nothing else on the machine runs `useradd` /
`userdel`:

```sh
sudo /opt/claude-fleet/current/bin/fleet-node-linux.py login open acme \
  --full-name 'Alice' --join-file /private/login-code
sudo /opt/claude-fleet/current/bin/fleet-node-linux.py login list
sudo /opt/claude-fleet/current/bin/fleet-node-linux.py login remove drill2 --keep-home
```

(Inside the ACK container the runtime is on the volume:
`/var/db/fleet-node/runtime/current/bin/…` — see «Upgrade and recovery».)

- `open`: OS user → home (0700) → install → the login's own node identity
  (join code) → credential separation as a tenant of the shared proxy →
  `account adopt` → its fleet started. A name is 2–16 of `a-z0-9` with at least
  one letter (`control.ValidCreateLogin`); a digit may lead (`acme` — only
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
fleet hub accounts assign gh:2987262 --host linux-a --login acme
fleet hub accounts                      # … linux-a:active:separated
fleet hub accounts remove gh:2987262 --host linux-a
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
  environment. Anything else — another op, `root`, `fleet` (the hub reserves it;
  the old primary login's name, refused with or without one),
  `fleetcred` or a reserved name, an all-digit or flag-shaped name, a full name
  with a control character, a malformed join code — is refused `BAD_ARGS` with
  one log line and nothing runs (BREAK-IT `linux-hub-other-root-op`). A digit
  may lead only for a name the person already holds on another machine
  (`acme`). `:` and `,` in a full name become spaces (passwd's separators).
- The op is written into the login's declaration (`"op"`): the same op again
  (a re-ask, a resume after the node program restarted) goes on where it
  stopped; a login another op or a person made answers 3 (exists — adopt it
  only if it is theirs). A create that fails after its own run declared the
  login is rolled back with `login remove --delete-home`.
- Its book is `/var/db/fleet-node/agent/_machine/account-ops.json`; the daemon
  holds a node-program reload while an op in it runs, and an answer the hub has
  not acked goes out again on the next connection.

## No primary login

(issue #3526) The image used to open its own login, `fleet` (UID 10002), at
every start (`FLEET_NODE_LOGIN=fleet`). Nothing dispatched to it — the hub
reserves the name and never assigns it (#3417) — yet it ran a full fleet of its
own (~54 processes and a warm pool on linux-a) beside the people's logins.

Now `FLEET_NODE_LOGIN` empty or `none` means the machine has none, and both the
image (`Dockerfile`) and the manifest (`render.py`) say `none`. A container start
is machine-level work only — `boot` (every login `linux-tenants/` declares, with
its number), `lib_owner_heal`, `route_heal`, `fleet node install` with no
`--login` (machine join, the shared credential proxy, the entry sshd, the
supervisor) — then each declared login's `bootstrap`, one person's failure never
the machine's. Nothing is opened: a login exists only because the hub's account
op (or `login open`) declared it. The machine's own identity is root's
`machine.env` token, never a login's; readiness reads the machine's children
(node agent, shared proxy, sshd), never a login. BREAK-IT `linux-no-primary-regrows`.

Taking an old node's `fleet` login away, once it runs a release with this:

```sh
R=/var/db/fleet-node/runtime/current/bin
sudo python3 -I $R/fleet-node-linux.py login remove fleet --keep-home   # home → /home/.attic/fleet-<UTC>.tar.gz
sudo python3 -I $R/fleet-node-linux.py login list                       # fleet gone; the others ok
```

`login remove` takes it off the hub (`node leave`) too. Then recreate the pod
once (`kubectl -n fleet-workers delete pod linux-a` — about a minute
offline for everyone on it, so pick a time nobody is) and check `id fleet` fails
and `ps -u 10002` is empty: nothing brings it back.

## Native Linux

Use Debian 12 or Ubuntu with systemd, Python 3.9+, curl, git, zsh, openssh-server,
sudo, useradd/groupadd, and the runtime tools' shared libraries. The hub must
publish signed artifacts for this Linux architecture matching `release.json`.
An absent artifact is an installation failure, never permission to download a
different CLI version.
The entry port (`FLEET_ENTRY=1`) also needs OpenSSH 9.8+ (`PerSourcePenalties`):
Debian 12's 9.2 runs everything else, but its entry never listens — use Debian 13.

Generate **two trusted join codes** using the hub's operator endpoint
`POST /v1/fleet/nodes/join-codes`: one for the machine, one for its first login
(native only — an ACK node needs the machine's alone).
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

## The ACK image

**The release train builds it** (issue #3855): every release it ships, its
`node image` job builds that release's image in the cluster and pushes
`<NODE_IMAGE_REPO>:<release commit>` — nobody builds one by hand. Read the
digest off the train run's summary (「节点镜像」), or ask the registry:

```sh
docker buildx imagetools inspect registry.example.com/acme/fleet-managed-node:RELEASE_COMMIT
```

How: the job runs on `fleet-ack`, an Actions Runner Controller scale set for
this repo in the cluster's runner namespace (`deploy/k8s/runners/`), beside the
cluster's BuildKit daemon — native amd64, the hub and the registry's VPC
endpoint a hop away. `extras/managed-node/train-build.sh` checks the release's
manifest against the checkout's `conf/release-keys/root.pub`, takes its
`ccquota-linux-amd64` by the signed sha256, runs `prepare-image.sh` with it and
builds with `buildctl` (CN package mirrors; the registry's layer cache
`:buildcache`). GitHub's release assets and dl.k8s.io crawl from there, so the
Dockerfile's `tools` stage (the sha256-pinned toolchain) is pushed separately by
the train's `node tools` job from a GitHub-hosted runner, tagged
`tools-<hash of the stage's text>` (`tools-tag.sh`) — once per pin change — and
the cluster build takes it as `TOOLS=<repo>@<digest>`. Push credentials are the
job's GitHub OIDC token traded for a short ACR login as a RAM role that may push
this one repository (`.github/actions/hub-acr`, role
`gha-claudefleet-node-image`, environment `node-image`, master only). The
deployment names the repository in the repo variables `NODE_IMAGE_REPO` (public
name) and `NODE_IMAGE_BUILD_REPO` (the VPC name the cluster pushes to); unset =
the two jobs are skipped. A red `node image` never holds a release back — stable
has already moved; the next train builds again, or build by hand (below).

### By hand

The same build anywhere outside CN, from a **published signed release
containing the Linux implementation**. Obtain the release public key through
the established trusted distribution channel (`conf/release-keys/root.pub` is
the root every release chains to). `ccquota release fetch` verifies the
signature and artifact digests; the image staging step checks the pinned
artifact digests again.

```sh
bash extras/managed-node/prepare-image.sh \
  https://YOUR-HUB /private/release.pub RELEASE_COMMIT /tmp/fleet-node-image linux-amd64
docker buildx build --platform linux/amd64 --load \
  -t registry.example.com/acme/fleet-managed-node:RELEASE_COMMIT \
  /tmp/fleet-node-image
docker push registry.example.com/acme/fleet-managed-node:RELEASE_COMMIT
```

`buildx`, not the classic builder: on Apple Silicon the classic one takes a
cached arm64 base for `--platform linux/amd64`, which Rosetta cannot run. The
context holds every artifact the image's `stage` takes — each tool and its
helpers (`image-stage.py need <dir> amd64` is the list); prepare-image.sh checks
it and, when the caller's ccquota's `--pinned` left one out (a ccquota older than
#3017 drops helpers), fetches the release whole and keeps only those (issue #3554).

The image is Debian 13 (trixie, OpenSSH 10.0); its build fails unless
`sshd -T` shows `persourcepenalties`, so an image whose entry port could not
listen is never pushed.

The build context contains the verified release and public key, no join codes
or node credentials. Select the resulting image **digest** for deployment.
The image provides a fixed UID/GID 499 for `fleetcred`; every login's UID/GID
is recreated at each start from its declaration on the volume (`boot`).

## ACK resources

Suggested first deployment: the existing ACK cluster hosting the hub, a separate
`fleet-workers` namespace, `linux-a`, 1 CPU / 4 GiB requested and 2 CPU /
8 GiB limits (what the live node runs), and 100 GiB encrypted ESSD storage. Select an existing ACK CSI
StorageClass configured for encryption and supporting `ReadWriteOncePod`.
The renderer deliberately does not guess a StorageClass or downgrade access
mode. The headless Service (the system sshd's 22) stays internal; the one public
Service is the door, `fleet-linux-entry`, carrying only the entry port 22022
(«Hub, relay, and access»).

```sh
python3 extras/managed-node/render.py \
  --image registry.example.com/acme/fleet-managed-node@sha256:IMAGE_DIGEST \
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
normal registry credential workflow. Put the newly issued machine join code into a Secret
from a private file (no login code: the pod opens no login of its own — «No
primary login»), then apply the reviewed resources:

```sh
kubectl create namespace fleet-workers
kubectl -n fleet-workers create secret generic fleet-linux-join \
  --from-file=machine=/private/machine-code
kubectl apply -f /tmp/fleet-linux.json
kubectl -n fleet-workers rollout status statefulset/fleet-linux --timeout=15m
```

After the machine's identity is registered and the pod is ready, delete the join-code
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
| reject the VPC / private ranges (the node's own included) | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16` | `--egress-private` |
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

### Dev network

(issue #3348) From the cluster's CN egress `https://github.com` times out, so
git cannot clone, fetch or push, while `api.github.com`, npmmirror and
goproxy.cn answer. Three render flags fix it for every login on the machine,
with no hand step per login:

| Flag | What the node does at each start (`fleet-node-linux.py`) |
|---|---|
| `--github-proxy http://203.0.113.211:3128` | `/etc/gitconfig`: `http.https://github.com/.proxy` — git's github.com traffic through the Singapore relay (`extras/gh-relay`, CONNECT to GitHub hosts :443 from the cluster egress only). The image's `gh` wrapper reads the same address from `/etc/fleet-devnet.env` and sets `HTTPS_PROXY` for gh alone. |
| `--git-mirror git://git-mirror.arc-runners.svc.cluster.local/acme-monorepo.git=https://github.com/acme-org/acme-monorepo.git` (repeatable) | `/etc/gitconfig`: `url.<mirror>.insteadOf <upstream>` — fetches come from the in-cluster CI mirror — and an identity `url.<upstream>.pushInsteadOf <upstream>`, so pushes still go to GitHub through the relay. |
| `--cluster-caches` | in place of `--cn-mirrors` in the cluster layout (#3548): `/etc/fleet-devnet.env` points npm / pnpm / yarn / corepack at `fleet-npm`, pip and uv at `fleet-pypi`, Go at `fleet-goproxy` then goproxy.cn — the namespace's package caches, «Package caches» below. render.py refuses both flags together |
| `--cn-mirrors` | `/etc/fleet-devnet.env`: npmmirror (npm · pnpm · yarn · corepack), the node dist mirror (nvm · fnm), goproxy.cn + `sum.golang.google.cn`. Every shell exports it (`/etc/profile.d/fleet-devnet.sh`, read by zshenv and bash.bashrc); a value the login already has wins. |
| `--egress-allow 172.21.x.y:9418` | the egress guard lets that one in-cluster tcp destination through (before the Service-range cut) — the git-mirror Service's ClusterIP. Nothing else in-cluster. |

A remote must name the upstream as `https://github.com/OWNER/REPO.git` with **no
explicit `pushurl`**: git rewrites an explicit pushurl with `insteadOf` too, so it
would push to the read-only mirror. `git remote -v` shows the mirror for fetch and
GitHub for push. `gh` uses its own auth; git's credential helper is the login's
(`gh auth setup-git`).

The image carries node 24 (+ corepack's pnpm / yarn), fnm (reads `.nvmrc` on cd
in an interactive shell; a login with its own `~/.nvm` keeps nvm), go, kubectl and
the aliyun CLI, each fetched at build time and checked by sha256.

## Hub, relay, and access

Use the hub HTTPS URL reachable from ACK. Allow egress to the hub and
`https://relay.example.com`, as well as the Git/package services your work
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
door's address is only the load balancer's: a `<name>.cf.example.com` record is
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
kubectl -n fleet-workers delete pod linux-a          # never --force
kubectl -n fleet-workers wait pod/linux-a --for=condition=Ready --timeout=15m
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

## Shared services: credential proxy and egress

(issue #3547, EPIC #3500 C2) The cluster runs ONE credential proxy and ONE way
out for every user pod, beside them in `fleet-workers`; upgrading either never
rebuilds a user pod.

| Service | What | Manifests |
|---|---|---|
| `fleet-credproxy:80` | the cluster credential proxy (`ccquota credproxy`): takes a session's hub pass (`fcp-h1.`), asks the hub which account it is bound to, puts that account's short-lived token on the request and forwards it through the Singapore relay. 2 replicas, PDB, rolling `maxUnavailable: 0`, no Ingress | `deploy/k8s/credproxy/fleet-workers` |
| `fleet-egress:3128` | a CONNECT proxy: pod range only, 443 only, a host allow-list (provider endpoints, GitHub, package sources), GitHub through `extras/gh-relay`. 2 replicas, PDB | `deploy/k8s/egress` |
| network rules | default deny; `fleet/role=user` → kube-dns, the two services, the hub's address | `deploy/k8s/fleet-workers/networkpolicy.yaml` |

`kubectl kustomize deploy/k8s/fleet-workers` renders all three
(`deploy/k8s/credproxy/README.md` «fleet-workers» for the token Secret and the
image pins). flannel enforces no NetworkPolicy, so on this cluster the walls that
hold are the pod's own guard and the egress's source check; the policies are the
same contract for a CNI that enforces them.

A user pod uses them through three render flags:

| Flag | What the node does |
|---|---|
| `--cred-central http://fleet-credproxy.fleet-workers.svc.cluster.local` | every login's root route settings carry `FLEET_CRED_CENTRAL_URL` (its host on `FLEET_CRED_ALLOW_HOSTS`); every login's store and node agent settings say `CCQUOTA_FLEET_CREDS=0`, so the node program leases nothing into the pod; and each start deletes every subscription credential file the volume still holds — each store's `accounts/` tokens, hub-managed Codex `auth.json`, the pool index, the shared proxy's pool (the node token, the relay pass and the hub passes stay: they are the login's identity). The local proxy takes plain `http` for the central route only, and only to a `NAME.NS.svc.cluster.local` name |
| `--egress-proxy http://fleet-egress.fleet-workers.svc.cluster.local:3128` | `/etc/fleet-devnet.env`: `HTTPS_PROXY` / `HTTP_PROXY` (both cases) and `NO_PROXY=localhost,127.0.0.1,::1,.svc,.cluster.local` for every login, the gh wrapper's road when no `--github-proxy` is named; `/etc/gitconfig`: `http.proxy` for every host |
| `--egress-closed` (needs `--egress-proxy`) | the guard's last rule rejects everything else (IPv4 and IPv6): the pod reaches the outside only through its `--egress-allow` destinations |

With `--egress-closed`, name each destination the node itself needs, before the
range cuts: the two Services' ClusterIPs and the hub's address.

```sh
kubectl -n fleet-workers get svc fleet-credproxy fleet-egress -o jsonpath='{range .items[*]}{.spec.clusterIP}{"\n"}{end}'
dig +short hub.example.com            # the hub (also the NetworkPolicy's ipBlock)
python3 extras/managed-node/render.py … \
  --cred-central http://fleet-credproxy.fleet-workers.svc.cluster.local \
  --egress-proxy http://fleet-egress.fleet-workers.svc.cluster.local:3128 --egress-closed \
  --egress-allow CREDPROXY_IP:80 --egress-allow EGRESS_IP:3128 --egress-allow HUB_IP:443 \
  --github-proxy http://fleet-egress.fleet-workers.svc.cluster.local:3128 > /tmp/fleet-linux.json
```

The machine itself must be marked untrusted at the hub
(`fleet-node-trust.sh set linux-a untrusted`): the hub then refuses it any
lease, and every session's route is central (an unreachable hub is `unknown`,
also central — closed, never open).

**Switching linux-a** (the migration's first step): apply the shared layer
→ mark the machine untrusted → render with the flags → `kubectl apply` →
`kubectl -n fleet-workers delete pod linux-a` (never `--force`). A session
that was started before the switch holds a local session credential, not a hub
pass, and gets 403 on the central route until it is reopened (↵ on its recovery
page resumes the same conversation); the pod replace restarts every session
anyway. So the switch goes in a window the people on the machine were told of.
After it, `kubectl -n fleet-workers rollout restart deploy/fleet-credproxy` is a
non-event for a running session.

Check it, in the pod:

```sh
env | grep -i token                                   # nothing (as root in the fleet container and as a login)
python3 -I ~/.claude/fleet/bin/fleet-cred-scan.py scan --no-hub   # routes=0
find /var/db/fleet-cred -name .credentials.json -o -name auth.json   # nothing
curl -sS --noproxy '*' -m3 https://registry.npmjs.org/   # refused (the guard)
curl -sS -o /dev/null -w '%{http_code}\n' https://github.com/   # 200, through fleet-egress
```

BREAK-IT `cred-in-user-pod`.

## Package caches

(issue #3548, EPIC #3500 C3) Installing a package or starting a session's MCP
servers never fetches from the internet at that moment: `deploy/k8s/caches` runs
three read-through caches in `fleet-workers` — `fleet-npm:4873` (Verdaccio,
npmmirror upstream), `fleet-pypi:3141` (devpi, Tsinghua), `fleet-goproxy:3000`
(Athens, goproxy.cn) — each a StatefulSet of two replicas with a disk apiece, a
PDB and `sessionAffinity: ClientIP` (a pod's second install hits the replica its
first one filled). `kubectl kustomize deploy/k8s/fleet-workers` carries them
beside the credential proxy and the egress; `deploy/k8s/caches/README.md` has the
images, the upstreams and the checks.

A user pod uses them with `render.py --cluster-caches` (above). With
`--egress-closed`, add each cache's ClusterIP to `--egress-allow`
(`IP:4873`, `IP:3141`, `IP:3000`) as for the credential proxy. One replica gone
costs nothing but a cold cache; Go falls through to goproxy.cn on any error
(`GOPROXY=…|https://goproxy.cn|direct`).

The image preinstalls the default MCP servers (`conf/agent-defaults`): context7,
playwright and server-github globally through npm, `mcp-server-fetch` as a uv tool
(`/usr/local/bin`). `npx -y <package>` runs the global copy with no registry
round trip; the `@latest` spec (playwright) asks `fleet-npm` once, in the
cluster; `bin/mcp-fetch.sh` runs an installed `mcp-server-fetch` before `uvx`.
A login whose `~/.claude.json` already names other commands keeps them (the
defaults only fill).

Git: fetches from the CI's mirror (`--git-mirror git://git-mirror.arc-runners…`,
«Dev network»); the network rules let a user pod reach `arc-runners` on 9418.

## User pods

(issue #3550, EPIC #3500 C5) Each person gets a pod of their own: their home
disk, tmux, sessions and warm sessions, their keys, a thin node program — and a
ceiling set per person. `render.py --user-pod u-<nonce> --login <name> --uid <n>
--cred-central <url>` renders it instead of the shared node (all four are
required — see «Run as the person» below):

| Object | What |
|---|---|
| `PersistentVolumeClaim u-<nonce>` | the home disk, `ReadWriteOncePod`, sized by the ceiling's `disk` |
| `Service u-<nonce>` | `ClusterIP`, port 22 only — reached through the cluster's one door (C4), never a load balancer of its own |
| `Deployment u-<nonce>` | one replica, `Recreate` (the old pod lets the disk go first); the pod's `hostname` is `u-<nonce>` — the hub's machine name for it, never the person's |

Inside: `FLEET_NODE_PROFILE=user-pod` — the supervisor runs no machine-level loop
(diskguard, memguard, orphans, shared-dirs: they are the cluster's one ops copy)
and no task at all; its one child is the node program. `FLEET_ENTRY=0`: no entry
port. One login, the one the pod was made for: the hub's account op opens it,
any other name is refused (3, `this pod is <login>'s alone`), and a remove is
refused too — the pod goes instead (the provisioner's `destroy-user-pod`). `FLEET_USER_POD=1`: the machine hello lists `CapUserPod`, and the
hub's roster marks the row `user_pod`. No ServiceAccount token. Labels
`fleet/role=user` and `fleet/pod=u-<nonce>`; `fleet/principal` is written by the
provisioner once the pod is ready, never rendered.

What an idle pod is promised: 0.25 core · 1.5 GB. The ceiling is the person's —
the hub setting `fleet.user_pod_limits.<principal>` (`cpu=2,memory=6Gi,disk=50Gi`
by default; the hub stores every key spelled, refuses a value under the idle
request) — and `--limits` takes that same text:

```sh
python3 extras/managed-node/render.py --image "$IMAGE" --hub "$HUB" --storage-class "$SC" \
  --user-pod u-k3x9q2 --login fleetu7 --uid 10002 --limits 'cpu=2,memory=6Gi,disk=50Gi' \
  --cred-central http://fleet-credproxy.fleet-workers.svc.cluster.local \
  --egress-proxy http://fleet-egress.fleet-workers.svc.cluster.local:3128 | kubectl apply -f -
# move one person's ceiling: only that Deployment rolls
kubectl -n fleet-workers patch deploy u-k3x9q2 --type strategic \
  -p "$(python3 extras/managed-node/render.py --limits-patch --limits 'cpu=4,memory=8Gi')"
```

`--limits-patch` prints the cpu/memory half only, from the WHOLE value (the keys
it omits are the defaults); a bigger `disk` is a re-render (the claim grows if
the StorageClass allows expansion). The machine join code goes in the Secret
`u-<nonce>-join` (key `machine`), as `fleet-linux-join` does for the shared node.

### Run as the person

(issue #3757, EPIC #3500 C16 · its second half) Nothing in a person's pod runs as
root but sshd's login step: `ps -o user= -e | sort -u` is the login alone in the
`fleet` container, root alone in `sshd` (root and the login while somebody is
logged in).

| Container | Runs as | What |
|---|---|---|
| `egress-guard` (init) | root, NET_ADMIN · NET_RAW | the egress guard's rules, once («Egress guard»), then gone |
| `pod-etc` (init) | 65534 — neither root nor the login | `fleet-node-linux.py pod-etc` from the IMAGE's seed: `/etc/passwd` and `/etc/group` as the image has them plus the login's one line (`<login>:*:<uid>:<uid>::/home/<login>:/bin/zsh`), `/etc/gitconfig` and `/etc/fleet-devnet.env` («Dev network»), sshd's whole config — into an emptyDir both containers mount **read-only**, file by file. A name or number the image already has (root's, sshd's) is refused before a byte is written |
| `fleet` | the login's UID, `runAsNonRoot`, ALL dropped, nothing added, `no_new_privs` | the node: supervisor, node program, the login's own credential proxy, tmux, every session |
| `sshd` | root, only CHOWN · SETUID · SETGID · SYS_CHROOT · KILL | `sshd -D -f` pod-etc's config: port 2222 (the Service's 22 maps to it — no NET_BIND_SERVICE), a host key made at each start (the door never pins one), `UsePAM no`, `PermitRootLogin no`, `AllowUsers <login>`, the door's key alone, then `fleet-entry.sh`. What the person runs over ssh (the 看台, a shell, scp) runs here as the login: it mounts the home and `/tmp` (tmux's sockets) of the `fleet` container, the runtime read-only |

No shared process namespace. The pod's `fsGroup` is the login's: the kubelet hands
the disk over in its group (`OnRootMismatch`).

**The login is fixed when the pod is made** — a spare's `fleetu<N>` (C8: every
fresh pod uses UID 10002, one pod holds one login), a moved person's own name and
number (C10). The cluster ticket's `create-user-pod` carries `login` + `uid`
(`bin/fleet_cluster_ticket.py`, `control.ClusterTicket`); there is no useradd in a
pod.

**What changed against a shared node** (`fleet-node-linux.py` · `pod_own()`,
`FLEET_POD_LOGIN` / `FLEET_POD_UID`):

- `foreground` runs as the login: the PVC lock, `fleet-node-install.sh` (which
  skips the role user, the ssh CA, the root core and the admin seat on a pod —
  `POD`), the resident loop for the one login the disk declares. A disk declaring
  another login stops it.
- `login open` (the hub's create, under the node program — which runs as the
  login, so its commands need no setuid) writes no passwd, no fleetcred store and
  no shared proxy: the node token in the login's own `~/.config/claude-fleet/node.env`
  (`CCQUOTA_FLEET_CREDS=0`), its `fleet.conf` saying `FLEET_CRED_SEPARATE=0` and
  `FLEET_CRED_CENTRAL_URL=<the cluster proxy>`, then `account adopt` of itself.
  It ends **`credsep: central`** (`control.CredsepCentral`): the pod holds no
  subscription credential, so there is nothing to separate — a pod's readiness is
  `central`, not `separated`. Refused (5) unless the process holds no capability
  and has `no_new_privs` (`pod_privileges`, the kernel's word — not a sudoers read).
- **The runtime is the image's** (`FLEET_NODE_UPDATE_OWNER=image`): the login
  cannot switch it and the pod runs no update task — a new release is a new image,
  and moving a pod onto it is the provisioner's to roll (the pod's sessions come
  back through restore). The image's seed is copied to the disk at each start.
- The readiness probe asks for the node program once a login is declared.

An image older than this change has no `pod-etc`: the init fails and the pod never
starts — render a user pod only with an image built after it. A user pod that ran
as root (before #3757) is not converted in place: its disk's files are root's;
move the person (C10) onto a new one.

BREAK-IT `root-in-user-pod`: the template, the provisioner's guard and pod-etc on
this machine (`bin/fleet-break-it-cluster-selftest.sh`); the pod running on kind —
`id` / `ps` in both containers, `/etc/passwd` read-only, a real ssh login with the
door's key landing as the login and root's refused
(`deploy/k8s/provisioner/kind-drill.sh`); the install and `login open` as a real
non-root uid with no capability on a Linux runner (`extras/managed-node/smoke.py`).

### Moving a person onto their own pod

(issue #3554, EPIC #3500 C10) A person who lives on the shared node moves to a pod
of their own with their name, number, home and sessions as they were, and one
interruption: `bin/fleet-move-to-pod.sh <phase> <login> --principal gh:<n> -- <render.py args>`,
run by someone holding the cluster (KUBECONFIG) and the hub's operator token
(`CCQUOTA_VIEWER_TOKEN`). Each phase can be run again; `all` runs check → verify.

| Phase | What | The person |
|---|---|---|
| `check` | the source's declaration (UID, op), home size, pinned sessions, attached clients | — |
| `prepare` | the pod's disk + Service (render.py with the login's OWN UID), a machine join code from the hub straight into `u-<nonce>-join` on kubectl's stdin, and a seeder pod on the disk (the login's UID, no capability, no token) | — |
| `stop` | refused while any client is attached; `fleet-node-linux.py login stop <login>` on the source: snapshot save, `account forget`, every process of the UID stopped — the home, the declaration and the credential store stay. Never `fleet-down`: a fleet marked down (`restore.down`) is one the snapshot restore skips | **the interruption starts** |
| `copy` | the home over two `kubectl exec` tars (numeric owners), without `.codex/tmp` and the proxy's throwaway Codex homes (links into the source's runtime); then `node.env` (a link into the shared node's credential store — `env_read`'s O_NOFOLLOW would refuse it), `node.pub.env` and `credsep.json` cleared, as a fresh pod has none; file counts compared | |
| `start` | the seeder goes, the Deployment is applied, Ready waited for | |
| `open` | `fleet hub accounts assign <p> --host u-<nonce> --login <login> --own-name`: the node program's create → `pod_login_open` (its own token, `credsep: central`); a digit-leading login is created as the person's existing one while the source row is still active. First `fleet.cred_allow.node.<source>` is copied to `fleet.cred_allow.node.u-<nonce>` (the pod's endpoint enrolls by that hostname) and read back — before the login exists, since a machine with no key is open to every subscription; a source with no list is refused (3) unless `--allow-list-none` | |
| `home` | `PUT /v1/fleet/entry/home?principal=…` → the door's table and the person's name follow | **ends** |
| `verify` | every session the source pinned is a window (`@fleet_id`) on the pod | — |
| `retire` | after acceptance only: `fleet hub accounts remove <p> --host <source> --delete` (the source archives the home in its attic; the source's disk is a retain class) | — |

The timeline (`<UTC> <phase> <word>`, `~/.local/state/fleet-move-to-pod/<login>/timeline`)
is what the issue records. Back out before `home`: the `login open` line `stop`
printed (`FLEET_LOGIN_OP_ID=<op>`) brings the login back on the source; delete the
`u-<nonce>` objects. Run it on a drill login first. `fleet-move-to-pod-selftest.sh`.

## The door

(issue #3549, EPIC #3500 C4) The cluster has ONE public way in for everyone whose
home is their own pod: the door. A person connects as always —
`ssh <login>@<name>.<zone> -p 22022`, their phone or their computer — and
the door hands them to their own pod. `render.py --door` renders it:

| Object | What |
|---|---|
| `Service fleet-door` | `LoadBalancer`, 22022 alone, `externalTrafficPolicy: Local` (the client's own address for `PerSourcePenalties` and the record) |
| `Deployment fleet-door` | 2 replicas of the image with `FLEET_NODE_PROFILE=door`: no disk, no login, no node program, no Kubernetes token — the supervisor with its entry child in **door mode** |

Door mode is the entry port (#3070) with three changes
(`fleet-node-supervisor.py`, `FLEET_DOOR=1`):

- its table is `GET /v1/node/entry-routes` — every person whose home is a pod
  `u-<nonce>`: the login, that person's own keys, and the pod's Service. Only a
  machine the hub setting `fleet.door` names reads it (403 for any other, 404 with
  no setting). A login two pods claim is in neither row: the door never guesses.
  The door pulls it every `FLEET_ENTRY_EVERY` (15 s in door mode) — it has no node
  program to hear the push;
- an empty table (nobody's home is a pod yet — the first deploy) still listens:
  its probes are tcp on 22022, so the config stays with `AllowUsers fleet-door-closed`,
  a name no hub login can carry, and nobody gets in until the first route comes
  (issue #3554, BREAK-IT `door-empty-table`);
- each login is a **door account** it makes itself (no home, shell `/bin/bash`,
  group `fleet-door`, GECOS `fleet-door`); a login the machine already had is never
  taken;
- its `ForceCommand` is `bin/fleet-door.sh`: it reads the ONE Service the table
  names for the login sshd let in and runs
  `ssh <login>@u-<nonce>.<ns>.svc.cluster.local` with the door's own key — the
  command, sftp and a terminal go on as they came, the person's key fingerprint,
  label and address ride along (`FLEET_DOOR_*`). Nothing the person sends picks
  the pod, and the door forwards nothing (`DisableForwarding yes`).

A user pod's sshd takes the door's key alone (`05-fleet-door.conf`,
`fleet-node-linux.py`): `AuthorizedKeysFile none`, `AuthorizedKeysCommand /bin/cat
/run/fleet-door/door.pub` (the Secret `fleet-door-pub`, read at each login — a new
key works the moment the Secret changes, no pod restarts), no CA, no forwarding,
and every arrival is `bin/fleet-entry.sh` — no command on a terminal is the 看台,
as on a home's entry port. The network rules let only the door reach a pod's 22
(`deploy/k8s/fleet-workers/networkpolicy.yaml`: `user-in`, `door-in`, `door-out`).

DNS: a person whose home is a pod gets the door's address — the hub's entry-dns
loop points `<name>.cf` at the first door the outside can reach (`entry reach`,
as any home). Every arrival is the door sshd's own log line, sent to the hub as the
entry's record (`POST /v1/node/entry-audit`).

Setting it up (once):

```sh
NS=fleet-workers
ssh-keygen -q -t ed25519 -N '' -C fleet-door-host -f door-host
ssh-keygen -q -t ed25519 -N '' -C fleet-door -f door-key
# the door's node token: a join code for a machine named fleet-door, redeemed as root
TOKEN=$(curl -fsS -X POST "$HUB/v1/node/join" -H 'Content-Type: application/json' \
  -d '{"code":"<码>","hostname":"fleet-door","os_user":"root"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
kubectl -n $NS create secret generic fleet-door --from-file=host_ed25519_key=door-host \
  --from-file=id_ed25519=door-key --from-literal=token="$TOKEN"
kubectl -n $NS create secret generic fleet-door-pub --from-file=door.pub=door-key.pub
unset TOKEN; rm -f door-host door-key       # the Secret is the only copy
# the hub: this machine is the door
curl -fsS -X PUT "$HUB/v1/fleet/settings" -H "Authorization: Bearer $ADMIN" \
  -d '{"key":"fleet.door","value":"fleet-door"}'
python3 extras/managed-node/render.py --door --image "$IMAGE" --hub "$HUB" | kubectl apply -f -
```

Changing the door's key to the pods: a new pair, both Secrets updated (`kubectl
create secret … --dry-run=client -o yaml | kubectl apply -f -`), then
`kubectl -n $NS rollout restart deploy/fleet-door` — every pod takes only the new
key from its next login. BREAK-IT `door-wrong-pod` drills the door on a real sshd.

## Cluster permissions

(issue #3558, EPIC #3500 C16 · 共同约定 2) Every service in fleet-workers has
exactly the permission it needs — for almost all of them, none:

| Account | Who runs as it | Kubernetes |
|---|---|---|
| `fleet-user` | a person's pod (`render.py --user-pod`) | none, no token |
| `fleet-job` | a throwaway Job (`render.py --job`) | none, no token |
| `fleet-door` · `fleet-linux` | the door · the shared node | none, no token |
| `fleet-credproxy` · `fleet-egress` · `fleet-npm` · `fleet-pypi` · `fleet-goproxy` | the shared services | none, no token |
| `fleet-ops` | the central patrol (#3734) | read: pods and their metrics |
| `fleet-provisioner` | `bin/fleet-provisioner.py` | write — Deployments · Jobs · Services · PVCs in fleet-workers, held to the template |

Each account AND each pod says `automountServiceAccountToken: false`
(`deploy/k8s/fleet-workers/serviceaccounts.yaml`; render.py's templates carry it
and the account's name). A user pod's egress guard already rejects the service
and pod ranges, so the API server is not even reachable from it.

The provisioner is never connected to the hub. fleet-ops hands it what the hub
sent, and it acts only on a **cluster ticket**: the hub's account key (C15's)
under the domain `fleet-cluster-ticket-v1`, `c1.<payload>.<sig>`, for this
cluster, five minutes, its nonce spent once in the ConfigMap
`fleet-provisioner-nonces` before anything is done. The ops are typed —
`create-user-pod {pod, limits, login, uid}` · `destroy-user-pod {pod}` · `set-limits {pod,
limits}` · `create-job {pod, repo, ref}` — never a manifest: it renders render.py's
template itself, checks it (`off_template`), and the API server checks it again
with the `ValidatingAdmissionPolicy` `fleet-provisioner-template` (`deploy/k8s/provisioner/policy.yaml`):
images by digest, no privilege or escalation, ALL caps dropped and only the user
pod's own added, no host namespaces, no hostPath or projected volume, no token,
the fixed account, ClusterIP Services, fleet-workers only, and only objects
labelled `fleet/role: user|job` — before and after a change. A destroy checks all
three objects are the pod's before it deletes any.

A Job (`render.py --job`, C7 runs things in it): the image by digest, `runAsNonRoot`
(uid 10001), ALL caps dropped, a read-only root with `/work` and `/tmp` as
emptyDirs, no token, no home disk; named `job-<nonce[:12]>` so a replayed create
is AlreadyExists; labelled `fleet/owner` (never `fleet/pod`, which the owner's
Service selects); the network rules let it reach DNS, the package caches and the
CI git mirror only.

A person's pod is root only in sshd's login step (#3757, «Run as the person»): the
policy and `off_template` let only a container named `sshd` (CHOWN · SETUID ·
SETGID · SYS_CHROOT · KILL) and the `egress-guard` init (NET_ADMIN · NET_RAW) add a
capability, and every other container of a Deployment must say `runAsNonRoot` and
a `runAsUser` that is not 0.

`deploy/k8s/provisioner/README.md` applies it. BREAK-IT `sa-token-in-user-pod`
and `provisioner-off-template` drill both halves — on this machine
(`bin/fleet-break-it-cluster-selftest.sh`) and on kind, with every account's
`kubectl auth can-i --list` on the run's summary page
(`.github/workflows/cluster-perms.yml`).

## Spare pods

(issue #3553, EPIC #3500 C8) A cluster keeps pods started ahead of the people
who will use them, so a newcomer's first sign-in only binds one: a database
write and two pushes, not a pod start, a useradd and a credential setup. Three
hub settings and one agent variable turn it on:

| Where | What |
|---|---|
| hub `fleet.spares` | `on` (the same switch as a machine's spare logins) |
| hub `fleet.clusters` | the clusters that keep spare pods, by the name their fleet-ops reports |
| hub `fleet.spare_max.<cluster>` | how many (default `fleet.spare_max`, 2), within `fleet.node_user_cap.<cluster>` (10) − the pods people hold |
| hub `CCQUOTA_FLEET_ACCOUNT_KEY` | the account-op key — every ticket is signed with it (C15/C16); none = no pool |
| fleet-ops `CCQUOTA_FLEET_PROVISIONER` | the provisioner's address; the agent's hello lists `cluster_ops` and it carries tickets there unopened |

What the hub does (`tokenledger/internal/api/fleet_spare_pods.go`):

- **Refill**: three records — principal `spare:<cluster>:<nonce>`, its login
  `fleetu<N>` pending on the pod `u-<nonce>`, the pod row in
  `fleet_cluster_pods` — and one `create-user-pod` ticket carrying the pod's
  one-time machine join code (trusted, managed, bound to `u-<nonce>`), which the
  provisioner writes into the Secret `u-<nonce>-join` before the pod. The pod's
  node joins with it and is sent its login's create like any machine's; **ready**
  = that create came back `credsep: separated` (or `central` in a user pod,
  #3757). Not ready within 15 minutes, or failed: the pod is destroyed, the row
  stays failed, and the cluster gets no more until the operator `forget`s it.
- **Claim**: placement (`fleet.auto_assign` naming the cluster) or the
  operator's assign naming it hands the oldest ready pod to the person — the
  machine spare's own claim, audited `spare.claim` — makes it their 家 (the
  door's table and their name follow at once), and sends `bind-user-pod`
  (`fleet/principal=<principal with : as .>`) plus `set-limits` when they have a
  ceiling of their own. No ready pod: a pod of their own is started under their
  own login — slower, never refused.
- **Remove**: never a wash. The hub clears its own half of the person first
  (node tokens and session passes, relay credential, leases, 家, unused join
  codes — the recycle list), then `destroy-user-pod` deletes the Deployment,
  Service, home PVC and join Secret; the login is `removed`, the pod row `gone`,
  `spare.destroy` audited, and the pool refills with a NEW pod. A `forget` of a
  login whose pod still stands is refused: remove it first.
- **Off** — spares off, no `fleet.clusters`, no account key, or no ops link up —
  nothing is created, claimed or sent (`TestSparePodsOffAddsNothing`).

Not yet: the home directory is not archived to object storage before the
destroy (#3772). BREAK-IT `spare-pod-leaks` drills it on this machine (the
provisioner against a stand-in API + the hub's Go test) and on kind
(`deploy/k8s/provisioner/kind-drill.sh`).

## Throwaway Jobs

(issue #3552, EPIC #3500 C7) A session in a person's pod hands a full test run,
a big build, browser automation, a load test or untrusted code to a Job that is
deleted when it is done — so it does not slow the person's other sessions, and
code nobody vetted never runs beside their keys:

```sh
fleet job run --kind test -- make test          # build | test | browser | load | untrusted
fleet job run --kind untrusted --detach -- ./their-script.sh
fleet job status job-0123456789ab
fleet job logs job-0123456789ab [--follow]
```

The road (`bin/fleet-job.sh` → `bin/fleet_job.py`):

- **Ask**: `POST /v1/node/jobs {repo, ref, kind, cmd}` with the login's own node
  credential (`tokenledger/internal/api/fleet_jobs.go`). The hub takes the
  caller's machine as the pod — a live `fleet_cluster_pods` row — never a pod it
  names, signs a `create-job` ticket (pod · repo · commit · kind · one command
  line) and carries it down the cluster's ops link like every other cluster op;
  `job.create` audited. The commit must be on the remote (the Job fetches it from
  the mirror): `fleet job run` defaults to HEAD and refuses one no remote branch
  holds.
- **Run**: the provisioner renders `render.py`'s Job for that kind
  (`job_resources`, `JOB_KINDS`) and the template's `job` settings, and runs
  `bin/fleet-job-runner.sh` in the managed-node image: the commit fetched from
  `job.git_mirror`, the command by `sh -c`, npm / pip / Go from the cluster's
  caches (`job.caches`), whatever it leaves in `$FLEET_JOB_OUT` packed at the
  end of its log.
- **Read back**: `GET /v1/node/jobs/<job>?offset=N` — the hub sends
  `cluster_job {job, owner, offset}` down the ops link; fleet-ops reads the Job
  and its pod's log with its own read-only account (Role: jobs, pods/log) and
  answers only for a Job labelled `fleet/owner` the asking pod
  (`internal/agent/node_cluster_job.go`, `CCQUOTA_FLEET_KUBE_API` /
  `CCQUOTA_FLEET_KUBE_SA_DIR` override the in-cluster defaults). The client
  prints the log as it comes and unpacks the outputs into the worktree's
  `.fleet-job/<job>/` (in `.git/info/exclude`).

| kind | CPU · memory | deadline | network |
|---|---|---|---|
| build · test | 2 · 4Gi | 1 h | DNS, caches, git mirror, the egress (3128) |
| browser | 2 · 4Gi, `/dev/shm` 1Gi | 30 min | same |
| load | 4 · 4Gi | 30 min | same |
| untrusted | 1 · 2Gi | 15 min | DNS, caches, git mirror — **no public internet** |

Every kind: `fleet-job`, no token, only emptyDirs (no home disk, no Secret),
uid 10001, read-only root, ALL capabilities dropped, `backoffLimit 0`, deleted
`job.ttl` seconds (600) after it ends, its log with it. An open kind carries
`fleet/job-net: open`, which `job-out-open` lets reach the egress; untrusted has
no such label, so `job-out` is all it gets. The template's `job` block:

```json
"job": {"image": "<managed-node image by digest>", "pull_secrets": ["acr-pull"],
        "git_mirror": "git://<mirror>/{repo}.git", "caches": true,
        "egress_proxy": "http://fleet-egress.fleet-workers.svc.cluster.local:3128",
        "deadline": 3600, "ttl": 600}
```

Not yet: a commit that is only local (an uploaded snapshot), and a per-person
cap on Jobs at once — the namespace's ResourceQuota bounds the total. A read
landing on a hub replica without the ops link answers 503 and the client tries
again. BREAK-IT `job-sees-keys` drills it on this machine (the provisioner
against a stand-in API, the runner in an untrusted Job's environment, the hub's
Go test) and on kind (a test and an untrusted Job run, find nothing, and are
deleted).

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
script. A restore that does not bring every pinned session back is not fatal
(#3289): the snapshot is renamed `sessions.snapshot.failed-<UTC>` as evidence,
one line goes to the container log, and the machine still goes ready —
`restore.map` stays, so the diskguard tick's auto-restore reopens what it can
(BREAK-IT `linux-restore-crashloop`). Abrupt node loss can recover only previously persisted snapshots and
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

The real-person walk on linux-a (a login opened from the hub, connected
from a computer and a phone, Claude answering, a drill login removed and checked
gone) followed the drill sheet `MANAGED-LINUX-DRILL.md`, step by step (a one-off
record, removed in #3576 — it is in git history).
