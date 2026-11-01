# deploy/aws — the hub's core on one EC2 box (k3s, us-west-2)

A **10-person trial** of the hub outside China (task PNWW): one EC2 instance
running k3s, one small RDS Postgres, one Elastic IP, the address
`core.tokenman.io`. Production is the Shenzhen ACK deployment
(`deploy/k8s/overlays/prod`, in the private deploy repo, released by the train's
hub-deploy) until repo variable `FLEET_HUB_TARGET` says `aws-k3s` — then the
release train ships the hub here instead ([«The release train»](#the-release-train)).
The overlay is its own (`deploy/k8s/overlays/aws-k3s`), `deploy/k8s/base` is
untouched, and with `FLEET_HUB_TARGET` unset hub-deploy never touches this box.

```
deploy/k8s/overlays/aws-k3s/   the kustomize overlay (hub · workers · issuer · traefik)
deploy/aws/k3s-box/
  user-data.yaml               EC2 user data: writes deploy.env, clones the repo, runs bootstrap
  bootstrap.sh                 k3s · cert-manager · ECR pull secret · Secrets · overlay · template (idempotent)
  rollout-drill.sh             a rolling restart with machines connected, read back from the hub
  restore-user-data.yaml       user data for a box rebuilt from a snapshot (pins the k3s node name)
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

   (`--platform linux/amd64` on an x86 box.) The managed-node image: the release
   train copies each release's build into ECR by digest (job `node image · AWS`,
   repo variables `NODE_IMAGE_REPO_AWS` = `<acct>.dkr.ecr.us-west-2.amazonaws.com/tokenman/managed-node`
   and `AWS_NODE_IMAGE_ROLE_ARN` — a role trusted for the `node-image` environment
   alone, ECR push on that one repository) and points the provisioner's template
   at it (`node image · AWS template`: `bin/fleet-hub-aws-deploy.sh node-image`,
   MANAGED_NODE_IMAGE in deploy.env + `bootstrap.sh apply`, task APVZ). With the
   hub setting `fleet.user_pod_roll=on` the hub then rolls the old pods, a batch at
   a time. For the first box, copy it by hand the same way (`docker buildx imagetools create`), amd64.
2. **RDS**: Postgres 16, db.t4g.micro, in the box's VPC, its security group open
   to the box only. Put the URL (`postgres://user:pass@host:5432/fleet?sslmode=require`)
   in SSM Parameter Store as a SecureString, e.g. `/fleet-core/db-url`.
3. **IAM instance role** for the box: `AmazonEC2ContainerRegistryReadOnly`,
   `ssm:GetParameter` + `kms:Decrypt` on that parameter, and
   `AmazonSSMManagedInstanceCore` (the SSM agent — Ubuntu's AMIs ship it — must be
   registered for the release train to reach the box). Set the instance's
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

## The release train

With repo variable **`FLEET_HUB_TARGET=aws-k3s`** the release train ships the hub
to this box instead of ACK, with the same guarantees (one commit = `TRAIN_SHA`;
never backwards — `bin/fleet-train-hub.sh` reads this hub's `/version`; the hub
and stable from the same commit; no redeploy when the image's source,
`deploy/k8s/`, the site and the console are unchanged; a red stage holds the
lane). Unset or `ack` = the ACK road, byte for byte.

| Stage | aws-k3s |
|---|---|
| every stage's hub (`FLEET_HUB_URL` in release-train.yml) | `FLEET_HUB_URL_AWS`, else `https://core.tokenman.io` |
| `hub build` (hub-deploy.yml phase build) | ubuntu-24.04, buildx, `HUB_AWS_PLATFORM` (default `linux/amd64`), pushed to `HUB_PUSH_REPO_AWS:prod-<sha7>` labelled `org.opencontainers.image.revision=<TRAIN_SHA>`; ECR login through GitHub's OIDC token → `AWS_DEPLOY_ROLE_ARN` |
| `hub` (phase deploy) | job `deploy-aws` (`deploy` is skipped): the pause gate · `fleet-train-hub.sh` (only forward) · `fleet-train-prebuild.sh verify` on ECR (the tag still the build's digest, revision `TRAIN_SHA`) · the image pinned `<repo>:<tag>@<digest>` · `bin/fleet-hub-aws-deploy.sh deploy` · `release.sh health` on `HUB_URLS_AWS` (else `FLEET_HUB_URL_AWS`, else `https://core.tokenman.io`) · on a red health check `fleet-hub-aws-deploy.sh rollback` |
| the hand road (Actions → hub-deploy → Run workflow) | the same job; `tag=prod-<sha7>` deploys an image already in ECR (the rollback) |

`bin/fleet-hub-aws-deploy.sh` finds the box — `AWS_BOX_INSTANCE_ID`, else the
ONE running instance tagged `Name=tokenman-core` (`AWS_BOX_TAG`; none or two is
refused, nothing sent) — and sends one `AWS-RunShellScript` command through SSM
(root on the box): fetch the commit into the box's checkout (`AWS_BOX_REPO_DIR`,
default `/home/ubuntu/src`, git run as that directory's owner), record the live
`deploy.env` + checkout (`deploy.env.prev`, `deploy.env.prev-ref`), check out the
commit detached, set `HUB_IMAGE` in `/etc/fleet-core/deploy.env`, run
`bootstrap.sh apply` (it waits for the rollout). A failed apply puts the recorded
release back and applies it again; the job waits for the command, prints the
box's stdout / stderr, and is red on anything but Success (a command still
running after 30 minutes is cancelled). BREAK-IT `train-aws-ssm-fails`.

### Repo variables

To change Tokenman's WeChat application notifications, first deploy a hub that
supports `ccquota hub --probe-wx-newreq`, then run **Actions → hub-wx-notify →
Run workflow** on `master`, choosing `operation=apply`. Supply the registered category 1273 template 61558
ID, `thing1=platform,thing2=person,time4=time`, the registered one-time 30803
subscription ID, and one existing administrator's GitHub login. The administrator
must have a followed service-account identity. This sends one labelled test.

The workflow uses the same `prod` OIDC role, instance and production concurrency
lane as hub-deploy. It calls `bin/fleet-hub-aws-deploy.sh wx-notify`; no local AWS
keys are needed. The embedded `fleet-wx-config.py` first checks the live binary,
recipient, registered template fields and JS-SDK ticket without sending. It then
backs up `$SECRETS_DIR/site.env` (default `/etc/fleet-core/secrets/site.env`) in a mode-0700 `wx-notify-backup-*`
directory on the same host (file mode 0600), and atomically changes only:

- `CCQUOTA_WX_TPL_NEWREQ`
- `CCQUOTA_WX_TPL_NEWREQ_FIELDS`
- `CCQUOTA_WX_SUB_REVIEW`

It runs `bootstrap.sh apply`, explicitly restarts the hub (Secret env changes
alone do not restart pods), waits for the old pods to disappear, and verifies
all current pods use the requested values. Finally it sends one real new-request
template message through the existing gateway. Success prints a receipt with
`sent: true` and `errcode: 0`. Failures restore the original file, apply/restart
again and verify the original live values; a failed rollback is explicitly red.
Backups stay on the box; neither site.env nor credentials enter job logs or
artifacts. Do not hard-cancel a running transaction: forced termination or host
loss can interrupt rollback; use the retained backup on that host to recover.
After any uncertain result, run the same workflow with `operation=inspect`
(the default) first. This compares only the three named keys on disk, in each
running pod and in the latest backup, printing boolean matches. It changes no
files and sends no messages. Each apply/rollback stage is named in the log,
including both the original failure and any rollback failure; raw command
output remains captured on the host.
The inspection also identifies explicit Deployment env keys and compares each
key separately. A missing site.env key may inherit a ConfigMap value; rollback
therefore checks the effective values captured from all pods before mutation,
not just values present in the file. Disagreeing starting pods refuse a rollout.
The helper resolves `SECRETS_DIR` from the same root-owned `deploy.env` that
bootstrap sources, and inspection reports that resolved path. Changing a file
under the default path has no effect when bootstrap uses another directory.

The role needs the same `ssm:SendCommand` permission on the target instance and
`AWS-RunShellScript` document, plus `ssm:GetCommandInvocation` and
`ssm:CancelCommand` on `*` as below. `ec2:DescribeInstances` is needed only when
`AWS_BOX_INSTANCE_ID` is unset. It does not need Secrets Manager or Parameter
Store reads for this change. A valid SDK ticket does **not** prove the public
platform's JS-SDK domain registration: confirm the domain used by `/apply` in
the platform and exercise “审批结果通知我” inside WeChat separately.

| Variable | Value |
|---|---|
| `FLEET_HUB_TARGET` | `aws-k3s` (the switch; unset = ACK) |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/gha-claudefleet-hub-deploy` (a variable — an ARN is no secret; a secret of the same name is read too) |
| `HUB_PUSH_REPO_AWS` | `<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/tokenman/ccquota` |
| `AWS_REGION` | optional, default `us-west-2` |
| `AWS_BOX_INSTANCE_ID` | optional: `i-…`; unset = the one running instance tagged `Name=tokenman-core` (`AWS_BOX_TAG` changes the tag) |
| `AWS_BOX_REPO_DIR` | optional, default `/home/ubuntu/src` (the box's checkout `bootstrap.sh` runs from) |
| `HUB_AWS_PLATFORM` | optional, default `linux/amd64`; `linux/arm64` for a Graviton box |
| `HUB_MIRROR_ACR` | optional: `1` = after the ECR push, `hub build` also logs into ACR (`.github/actions/hub-acr`) and copies the same tag into `HUB_PUSH_REPO` (ACR's public endpoint, `…/ccquota`), registry to registry, red unless the digest matches — for the mainland region ([`../k8s/overlays/ack-sz-cn`](../k8s/overlays/ack-sz-cn/README.md)); unset = no copy |
| `FLEET_HUB_URL_AWS` | optional, default `https://core.tokenman.io` (the train's stages) |
| `HUB_URLS_AWS` | optional: the addresses the health check reads, space-separated (default `FLEET_HUB_URL_AWS`) |

### The release train's role

One IAM role, assumed by both hub-deploy jobs (`build` and `deploy-aws`; both run
in environment `prod`, which only `master` may use). First add GitHub's OIDC
provider to the account once (`token.actions.githubusercontent.com`, audience
`sts.amazonaws.com`). Trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:verkyyi/claude-fleet:environment:prod"
        }
      }
    }
  ]
}
```

Permission policy (`<INSTANCE_ID>` = the box; to follow a replaced box without
editing the policy, use `arn:aws:ec2:us-west-2:<ACCOUNT_ID>:instance/*` with the
condition `"StringEquals": {"ssm:resourceTag/Name": "tokenman-core"}` instead):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "EcrLogin", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    {
      "Sid": "EcrPushTheHub",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
        "ecr:DescribeImages", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload", "ecr:PutImage"
      ],
      "Resource": "arn:aws:ecr:us-west-2:<ACCOUNT_ID>:repository/tokenman/ccquota"
    },
    {
      "Sid": "RunOnTheBox",
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": [
        "arn:aws:ec2:us-west-2:<ACCOUNT_ID>:instance/<INSTANCE_ID>",
        "arn:aws:ssm:us-west-2::document/AWS-RunShellScript"
      ]
    },
    {
      "Sid": "WatchTheCommand",
      "Effect": "Allow",
      "Action": ["ssm:GetCommandInvocation", "ssm:CancelCommand"],
      "Resource": "*"
    },
    { "Sid": "FindTheBox", "Effect": "Allow", "Action": "ec2:DescribeInstances", "Resource": "*" }
  ]
}
```

What the role cannot do: pull or push any other repository, run any other
document, reach any other instance, read a parameter or a secret. Whoever can
run commands on the box is root there — keep `prod` restricted to `master`.

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
- **The whole box**: see [«A lost box»](#a-lost-box) — rebuild it from its
  latest snapshot.

## A lost box

What lives only on the box: `/etc/fleet-core` (the credential vault key, the
two SSH CAs, the generated tokens — losing them means re-entering every account
credential and re-trusting every machine), people's home disks (local-path,
under `/var/lib/rancher/k3s/storage`) and the releases volume. RDS holds the
rest and keeps its own 7-day point-in-time backups.

| Copy | Where | Kept |
|---|---|---|
| The root volume | EBS snapshots by a Data Lifecycle Manager policy on volumes tagged `backup=tokenman-core-daily`: every 6 h and daily | 8 six-hourly · 14 daily |
| `/etc/fleet-core` | an encrypted tarball in the backups bucket (`box-secrets/`, versioned, SSE-KMS) — written by hand after a secret changes: `ssh box 'sudo tar -C /etc -czf - fleet-core' \| aws s3 cp - s3://<bucket>/box-secrets/<box>-etc-fleet-core.tgz --sse aws:kms` | old versions 180 days |
| The database | RDS automated backups | 7 days, to the second |

The root volume carries the tag `k3s-node=<node name>` and the policy copies
tags, so every snapshot says which hostname its k3s knew.

**Rebuild** (needs the AWS account; the box itself is gone):

1. Pick the newest snapshot of the old root volume
   (`aws ec2 describe-snapshots --owner-ids self --filters Name=tag:project,Values=tokenman-core`).
   Register an image from it (`aws ec2 register-image … --block-device-mappings
   '[{"DeviceName":"/dev/sda1","Ebs":{"SnapshotId":"snap-…","VolumeType":"gp3"}}]'
   --boot-mode uefi-preferred --ena-support`).
2. Launch it — any zone of the region — with the old instance's profile, security
   group and key, metadata hop limit 1, and
   [`k3s-box/restore-user-data.yaml`](k3s-box/restore-user-data.yaml) as user
   data with `__K3S_NODE__` replaced by the snapshot's `k3s-node` tag. Tag it
   `Name=tokenman-core`.
3. Move the Elastic IP to it. k3s comes up as the same node on the new private
   IP; the hub, the proxies, the provisioner and every home pod start from the
   volume as they were.
4. Tag the new root volume `backup=tokenman-core-daily` and
   `k3s-node=<node name>` so the snapshots continue.

If the database is lost too, restore it first (`aws rds
restore-db-instance-to-point-in-time --use-latest-restorable-time`), and point
`ccquota-db`'s `db-url` (and `/etc/fleet-core/secrets*/db-url`) at the new
endpoint before moving the Elastic IP.

**Drill, 2026-10-26** — rebuilt from a snapshot into another zone, with a
point-in-time copy of the database, both in security groups that reached
nothing but each other (no Elastic IP, no instance profile, no egress to the
internet), then torn down: the node came back under its old name on a new IP,
all 4 home disks bound and mounted (~200 MB each), and the hub answered `/readyz`
**4 min 18 s** after the image was registered, its data matching production
(accounts, tasks, endpoints equal; usage rows within the restore point). The
first full snapshot of the 145 GB volume took about 75 minutes; later ones are
incremental. Without the pinned hostname every home pod would have stayed
Pending.

### One human portal (T1112)

Set `CCQUOTA_PORTAL=https://portal.example.com`,
`CCQUOTA_PORTAL_ALIASES=old.example.com quota.example.com` and
`CCQUOTA_WECHAT_PUBLIC_URL=https://old.example.com` in the hub's `site.conf`
(ConfigMap `ccquota-site`), then roll the hub. Leave
`CCQUOTA_FLEET_PUBLIC_URL` and `fleet.node_url` unchanged. Unset `CCQUOTA_PORTAL`
to restore the previous behavior. Keep the trusted-edge host lists and TLS
routes: aliases still serve WeChat, OAuth callbacks and existing clients.

The portal keeps the sandbox runtime positioning, with Sign in opening the
existing WeChat QR / email / GitHub choices, plus request access and (when
`fleet.trial` is on) trial. Its homepage follows the browser's language until
the person changes the language link; the existing `cf_lang` cookie remembers
that choice across the site and sign-in pages. The old Chinese page remains
available inside WeChat. Redirects vary by User-Agent and are not shared-cacheable.
Only known page paths move; unknown paths, `/auth/*`, `/fleet/*`, `/v1/*`,
`/install*`, WebSocket upgrades and preview hosts keep their handlers.

Service-account QR + polling is same-origin and needs no new OAuth target.
Silent authorization entered from the portal inside WeChat starts on the
configured WeChat origin **before** setting its host-only flow cookie. Keep
workbench's existing `fleet=<WeChat origin>/auth/wechat/relay-cb` target; no new
`WX_OAUTH_RELAY_TARGETS` entry is required for this route. Do not change `fleet`
to the portal: that would break the retained Chinese site's cookie. A future
independent portal relay route would need its own target and signature name.
Email sign-in links remain on the initiating host because they are bound to
that browser's cookie; ordinary invitations and notification emails use the
portal. WeChat templates and customer-service text use the WeChat origin.

Space must add the portal origin to `SPACE_FIRST_PARTY_EMBED_ORIGINS`, preserving
existing origins. Provisioning now requests the portal as an additional embed
origin. `CCQUOTA_FLEET_CHAT_FRAME_ORIGINS` is the reverse direction (origins
allowed to frame the hub): retain the Space origins there; add a portal origin
only if that portal itself will frame the hub.

For GA's TCP + PROXY protocol route, Traefik must accept PROXY only from GA's
configured source ranges and construct X-Forwarded-For from that source.
The hub's client-IP readers use the rightmost public address (skipping private
replica hops); the trusted Shenzhen forwarded-host route uses its normalized
edge source. Verify the actual source against a probe's known egress and the
hub request log, as well as GA DNS resolution, alias 301, WeChat 200 and API
non-redirects, after deployment.
