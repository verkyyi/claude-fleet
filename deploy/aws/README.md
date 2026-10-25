# deploy/aws — the hub's core on one EC2 box (k3s, us-west-2)

A **10-person trial** of the hub outside China (task PNWW): one EC2 instance
running k3s, one small RDS Postgres, one Elastic IP, the address
`core.tokenman.io`. It is not production — production is the Shenzhen ACK
deployment (`deploy/k8s/overlays/prod`, in the private deploy repo, released by
the train's hub-deploy), and nothing here changes it: the overlay is new
(`deploy/k8s/overlays/aws-k3s`), `deploy/k8s/base` is untouched, and hub-deploy
never renders or applies this tree.

```
deploy/k8s/overlays/aws-k3s/   the kustomize overlay (hub · workers · issuer · traefik)
deploy/aws/k3s-box/
  user-data.yaml               EC2 user data: writes deploy.env, clones the repo, runs bootstrap
  bootstrap.sh                 k3s · cert-manager · ECR pull secret · Secrets · overlay · template (idempotent)
  rollout-drill.sh             a rolling restart with machines connected, read back from the hub
```

## What runs where

| Where | What |
|---|---|
| EC2 (one box, Ubuntu 24.04) | k3s (one server node): traefik (k3s' own, ports 80/443), servicelb, local-path, metrics-server, kube-router NetworkPolicy; cert-manager (Let's Encrypt, HTTP-01) |
| namespace `fleet-hub` | the hub `ccquota-hub` — **two replicas** on the same node, rolling one at a time (`maxSurge 1`, `maxUnavailable 0`, `preStop` 5 s, 25 s grace), the PodDisruptionBudget; Ingress `core.tokenman.io` (http→https), certificate `core-tls` |
| namespace `fleet-workers` | `fleet-credproxy` (the cluster credential proxy, direct to the providers — no relay), `fleet-provisioner` (the one writer, its admission policy), the accounts and network rules for people's pods `u-<nonce>` |
| made later, by the hub | each person's pod `u-<nonce>` (render.py through the provisioner): **0.5 vCPU / 3 GiB requested**, ceiling 2 vCPU / 6 GiB, a **20 GiB** home disk |
| RDS (db.t4g.micro, Postgres) | the hub's database (`CCQUOTA_DB_URL`) — the only state that matters besides the Secrets |
| ECR | the hub image (`fleet/ccquota`) and the managed-node image (`fleet/managed-node`) |
| Route 53 / any DNS | `core.tokenman.io` → the Elastic IP |

**Egress is direct.** In the US there is no fleet-egress, no US egress parent,
no relay and no package caches: a person's pod goes out to the internet itself.
Its own egress guard (render.py's init container) and the NetworkPolicy
(`user-out`) still cut the metadata address `169.254.169.254` and every private
range — the VPC, k3s' pod (10.42/16) and service (10.43/16) ranges — but the two
in-cluster roads it needs: the credential proxy and the hub's Service.

## Cost (us-west-2, on demand, per month)

| Item | ≈ |
|---|---|
| EC2 m7g.xlarge (4 vCPU, 16 GiB, arm64) | $119 |
| RDS db.t4g.micro + 20 GiB gp3 | $14 + $2 |
| Elastic IP (public IPv4) | $4 |
| Root EBS gp3, 200 GiB (k3s, images, local-path homes) | $16 |
| ECR (a few GB) · data out ($0.09/GB) | a few $ |
| **Total** | **≈ $155–160** |

**Read this before buying the m7g.xlarge** — the asked shape does not hold 10
people at once:

- **Fit.** 10 pods × 3 GiB requested = 30 GiB, 10 × 0.5 vCPU = 5 vCPU; the core
  (two hubs, two proxies, two provisioners, traefik, cert-manager, k3s) asks for
  about 2.5 GiB and 0.6 vCPU. An m7g.xlarge (≈ 14.5 GiB / 3.9 vCPU allocatable)
  schedules **3** people's pods at that size. For 10 at once: r7g.2xlarge
  (8 vCPU / 64 GiB, ≈ $313) — or keep the box and lower the promise
  (`USER_POD_REQUESTS=cpu=250m,memory=1Gi` fits 10 on the m7g.xlarge; the ceiling
  stays 2 vCPU / 6 GiB, so idle people cost little and busy ones share).
- **Architecture.** m7g is arm64. The hub image builds for arm64 as is (its
  Dockerfile cross-compiles), but **the managed-node image is amd64-only**
  (`extras/managed-node/Dockerfile` fetches the amd64 Go, kubectl and aliyun
  tarballs), so people's pods cannot run on an arm64 box until that image is made
  multi-arch. For a trial with pods: **m7i.xlarge (amd64, ≈ $147)** or r7i.2xlarge;
  for the hub alone (no `MANAGED_NODE_IMAGE`), arm64 is fine.

## Deploy

Once, by a person with the AWS account (nothing here touches a cloud resource
by itself):

1. **ECR**: repositories `fleet/ccquota` and `fleet/managed-node`. Build and push
   the hub image for the box's architecture (from a checkout):

   ```sh
   bin/fleet-client-pack.sh                      # the client the hub serves at /install
   TAG=aws-$(git rev-parse --short=7 HEAD)
   docker buildx build --platform linux/arm64 \
     --build-arg VERSION=$TAG --build-arg GOPROXY=https://proxy.golang.org,direct \
     -t <acct>.dkr.ecr.us-west-2.amazonaws.com/fleet/ccquota:$TAG --push tokenledger/
   ```

   (`--platform linux/amd64` on an x86 box.) The managed-node image: copy the
   train's build into ECR by digest (`docker buildx imagetools create`), amd64.
2. **RDS**: Postgres 16, db.t4g.micro, in the box's VPC, its security group open
   to the box only. Put the URL (`postgres://user:pass@host:5432/fleet?sslmode=require`)
   in SSM Parameter Store as a SecureString, e.g. `/fleet-core/db-url`.
3. **IAM instance role** for the box: `AmazonEC2ContainerRegistryReadOnly`, and
   `ssm:GetParameter` + `kms:Decrypt` on that parameter. Set the instance's
   metadata **hop limit to 1** (IMDSv2 required): then only the host — the ECR
   refresh, the bootstrap — reaches the role, never a pod. (`STORAGE_CLASS=gp3`
   needs the EBS CSI controller to reach it too: hop limit 2 plus
   `AmazonEBSCSIDriverPolicy` — a pod-reachable role; local-path is the default
   for that reason.)
4. **Security group**: 80 and 443 from anywhere (Let's Encrypt's HTTP-01 needs
   80), 22022 from anywhere once the door runs (people's `fleet connect`), SSH 22
   (or SSM) from you only. **6443 closed.**
5. **Launch** Ubuntu 24.04, root volume 200 GiB gp3, with
   [`k3s-box/user-data.yaml`](k3s-box/user-data.yaml) as user data after filling
   its `deploy.env` (HUB_IMAGE, MANAGED_NODE_IMAGE by digest, ACME_EMAIL).
   Attach the Elastic IP; point `core.tokenman.io` at it **before** the
   bootstrap asks for the certificate (a miss just retries — cert-manager keeps
   trying). It starts on Let's Encrypt **staging**; once
   `k3s kubectl -n fleet-hub get certificate` says Ready, set
   `LETSENCRYPT_SERVER=prod` in `/etc/fleet-core/deploy.env` and run
   `bootstrap.sh apply`.

`bootstrap.sh` (as root on the box) is the one command for everything after:
first install, a repair, a new hub image (`HUB_IMAGE=…` in deploy.env, then
`bootstrap.sh apply` — a rolling release). `bootstrap.sh render` prints the
render with every placeholder filled and changes nothing.

### Secrets

None is in the repo. `bootstrap.sh` keeps them in `/etc/fleet-core/secrets`
(root, 0700) and applies them as Secrets every run. **Back that directory up**
(the credential vault key and the CAs cannot be recovered; losing them means
re-entering every account credential and re-trusting every machine).

| Secret (namespace) | Keys | From |
|---|---|---|
| `ccquota-db` (fleet-hub) | `db-url`, `replica-token` | `db-url`: yours (SSM `DB_URL_SSM_PARAM`, or the file) · `replica-token`: generated |
| `ccquota` (fleet-hub) | `viewer-token` | generated — the hub's admin token |
| `ccquota-ssh-ca`, `ccquota-ssh-host-ca` (fleet-hub) | `ca` | generated (`ssh-keygen -t ed25519`), two separate keys |
| `ccquota-fleet-cred-key` (fleet-hub) | `key` | generated (`openssl rand -base64 32`) |
| `ccquota-account-key` (fleet-hub) | `key` | generated (`openssl genpkey -algorithm ed25519`) — signs the provisioner's tickets |
| `ccquota-site-env` (fleet-hub) | one key per `CCQUOTA_*` variable | `secrets/site.env` (yours: the GitHub sign-in pair `CCQUOTA_GITHUB_CLIENT_ID` / `CCQUOTA_GITHUB_CLIENT_SECRET`, anything else) + the generated `CCQUOTA_FLEET_CREDPROXY_TOKEN` and `CCQUOTA_FLEET_SESSION_CRED_KEY` |
| ConfigMap `ccquota-site` (fleet-hub) | `CCQUOTA_FLEET_ADMIN_USERS`, `CCQUOTA_GITHUB_ADMINS`, … | `secrets/site.conf` (yours; names, not secrets — kept off the public tree) |
| `fleet-credproxy` (fleet-workers) | `credproxy-token` | the same generated token as the hub's |
| `ecr-pull` (both) | `.dockerconfigjson` | the instance role, refreshed every 6 h (`fleet-ecr-pull.timer`) |
| `fleet-ops` (fleet-workers) | `token` | a join code, by hand (below) |

The GitHub OAuth app's callback is `https://core.tokenman.io/…` as in
docs/public's self-host guide; without a sign-in method the hub runs but
`/install` answers 503 and says why.

### People's pods (after the hub answers)

The bootstrap writes the provisioner's template (`ConfigMap fleet-provisioner`:
the managed-node image, `https://core.tokenman.io`, k3s' DNS / pod / service
ranges, EC2's metadata address, the two in-cluster roads, `requests`
0.5 vCPU / 3 GiB, default ceiling `disk=20Gi`). Two steps stay a person's, as on
ACK (docs/dev/MANAGED-LINUX.md «fleet-ops», «The door», «Spare pods»):

```sh
# fleet-ops: the cluster's link to the hub (a join code from the hub's admin page)
kubectl -n fleet-workers create secret generic fleet-ops --from-literal=token="$TOKEN"
python3 extras/managed-node/render.py --ops aws-k3s --image "$MANAGED_NODE_IMAGE" \
  --hub https://core.tokenman.io --pull-secret ecr-pull | kubectl apply -f -
# the door (k3s' servicelb binds 22022 on the box)
python3 extras/managed-node/render.py --door --image "$MANAGED_NODE_IMAGE" \
  --hub https://core.tokenman.io --pull-secret ecr-pull --entry-host core.tokenman.io | kubectl apply -f -
# the hub's settings: fleet.clusters=aws-k3s, fleet.spares=on (the admin page or PUT /v1/fleet/settings)
```

Not set up on this box: throwaway Jobs and service runs (no egress proxy for
them; `default-deny` keeps any job pod closed), private git mirrors, the
「正在更新」 page (nginx-only — with two replicas there is always one up), the
ACK nginx's `limit-rps 20` (traefik has no limit here).

**To verify on the box** (cannot be checked from a laptop): that k3s'
local-path provisioner binds the pods' `ReadWriteOncePod` claims (if a claim
stays Pending, use `STORAGE_CLASS=gp3`); that the HTTP-01 challenge passes
through traefik with the redirect middleware; that render.py's pods run under
kube-router's NetworkPolicy as they do under ACK's (which enforces none).

## Long links across a hub release

Node agents and browser relays hold websockets to a hub pod; before this, a
rolling release simply exited that pod under every link it held (EOF), and none
of the link's own cleanup ran. Now (`tokenledger/hub/api/link_drain.go`): when a
**replica** (`CCQUOTA_REPLICA` set — the Postgres shape, as here) gets SIGTERM
after its `preStop` took it out of the Service, it

1. refuses new node connects with `503` + `Retry-After: 1` (a dial that still
   lands on it goes elsewhere);
2. closes every node link with `1012 service restart`, spread over 2 s, and waits
   — inside the 25 s grace — until every session on them has ended, so the
   roster, the link's claim, in-flight account ops and the relays it carried are
   cleaned up, and the drop is booked `hub_shutdown`;
3. only then exits (the hub also waits for its HTTP Shutdown now, instead of
   exiting the moment `Serve` returns).

The agent dials again after its quick redial (0.5–1 s) and lands on the replica
that is up (`maxUnavailable 0`: the new pod is Ready before the old one goes).
**Honestly: a link is still re-dialled once per release** — a websocket cannot
move between processes, and a front (traefik, or a gateway of our own) cannot
splice an established websocket onto another hub without a resumable link
protocol. What changes is that the hand-over is orderly and measured, not an EOF.
A single hub (the sqlite shape, production today) is untouched: it has nowhere
to hand links to, and its `Recreate` successor waits on its exit.
`TestDrainLinksHandsTheLinkOver` pins it; on the box,
[`k3s-box/rollout-drill.sh`](k3s-box/rollout-drill.sh) restarts the hub with
machines connected and fails unless every link is back (and the worst
`hub_restart` gap is under 10 s). What still drops every link: restarting
traefik or k3s itself, or the box — it is one box.

Zero-reconnect would need make-before-break in the agent (on `1012`, open the
new link and wait for its welcome before letting the old one go — the hub
already lets a newer link of the same endpoint supersede the old one) or a
resumable session layer in a separate gateway process. Neither is in this change.

## Roll back

- **The hub image**: put the previous tag back in `HUB_IMAGE` and run
  `bootstrap.sh apply` (or `k3s kubectl -n fleet-hub rollout undo deploy/ccquota-hub`).
  A migration the new image already ran stays run: take an RDS snapshot before
  a release (`aws rds create-db-snapshot`) and restore it to go back across one.
- **The overlay**: check out the previous ref in `/opt/claude-fleet`, `bootstrap.sh apply`.
- **The whole box**: terminate it. The state is RDS + `/etc/fleet-core/secrets`;
  a new box with the same user data, the same SSM parameter and the secrets
  directory restored comes back as the same hub. People's home disks (local-path)
  live on the box's root volume — snapshot it, or use `gp3` if they must outlive it.
