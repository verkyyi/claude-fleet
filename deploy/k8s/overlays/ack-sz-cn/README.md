# overlays/ack-sz-cn — the mainland execution region (task J7BN P1)

People's pods for **DeepSeek sessions** in the Shenzhen ACK cluster, registered
with the AWS hub (`core.tokenman.io`, [`../aws-k3s`](../aws-k3s)) as its second
cluster, **`ack-sz`**. This overlay is only the WORKER side of that cluster. The
hub stays on the EC2 box. A person applies it by hand. hub-deploy and the
release train never read it.

The hub rules are in `tokenledger/hub/api/fleet_region.go` (docs/dev/FLEET-HUB.md
«Mainland region»). A `cn` cluster takes only provider `deepseek`.
While a `cn` cluster is listed in `fleet.clusters`, a global machine refuses
`deepseek`. Only principals on `fleet.region_cn.people` may start one. A pod here
also carries `FLEET_EXEC_REGION=cn`, so its `fleet-claude.sh` starts only a
DeepSeek profile and its `fleet-codex.sh` refuses to start.

| Piece | What |
|---|---|
| `kustomization.yaml` | `serviceaccounts.yaml` + [`../../provisioner`](../../provisioner) + `credproxy/`; the provisioner on the mainland pool, pulling from ACR |
| `serviceaccounts.yaml` | `fleet-user` · `fleet-job` · `fleet-credproxy` (no token) · `fleet-ops` + its read-only Role (the same specs fleet-workers already holds) |
| `credproxy/` | `fleet-credproxy` (Service `:80` → `:8788`): `ccquota credproxy --direct`, one replica, no PDB, the hub at `https://core.tokenman.io`, its token from Secret `fleet-credproxy` |
| `template.json.tmpl` | the provisioner's template for `ack-sz`. It is not a kustomize resource: step 4 fills it and makes ConfigMap `fleet-provisioner` from it |

What the template asks for: the managed-node image by digest, the hub, the
StorageClass `fleet-workers-essd-retain` (encrypted ESSD PL1, `WaitForFirstConsumer`
so the disk lands in the pool node's zone, `Retain`), the central credential
proxy, and the CN package mirrors (`cn_mirrors`: npmmirror · node dist ·
goproxy.cn · the tuna PyPI). There is no GitHub relay, because GitHub answers
directly from this cluster. Pulls use the ACR plugin's Secret. Each pod requests
0.5 vCPU / 3 GiB and is capped by default at `cpu=4,memory=8Gi,disk=30Gi`. It
carries `node_selector {fleet/region: cn}` and a toleration for
`fleet/region=cn:NoSchedule`, plus `exec_region: cn`. These three keys are new
in `extras/managed-node/render.py` (`pod_placement`). When the template leaves
them out, the pod renders byte for byte as before.

**Not here**, on purpose:
- No hub, Ingress or certificate.
- No fleet-egress, run egress or package caches. Pods go out directly, through
  their own egress guard.
- No NetworkPolicy, because ACK's flannel enforces none. The wall is each pod's
  egress guard: render.py's `EGRESS` defaults are this cluster's DNS, pod and
  Service ranges plus Alibaba's metadata address, and one allow line opens the
  credential proxy's ClusterIP:80.
- No throwaway Jobs or service runs: the template has no `job` or `svc` section.
- No door (see «Open» below).

## What fleet-workers already holds

The namespace is shared with the old ACK hub's layer:

| Object | Status | Effect of this overlay |
|---|---|---|
| Deployment `fleet-door` (2 pods) + Service `fleet-door` (LoadBalancer :22022) + Secrets `fleet-door`, `fleet-door-pub` | the old door, its `FLEET_HUB_URL` the old hub name | not touched |
| StatefulSet `fleet-linux` (0/0) | the retired shared node | not touched |
| ConfigMaps `fleet-private-mirrors`, `fleet-us-egress` + Secret `fleet-us-egress` | leftovers | not touched |
| ServiceAccounts `fleet-door` · `fleet-linux` · `fleet-egress` · `fleet-npm` · `fleet-pypi` · `fleet-goproxy` | leftovers | not touched |
| ServiceAccounts `fleet-user` · `fleet-job` · `fleet-credproxy` · `fleet-ops`, Role/RoleBinding `fleet-ops` | same spec as here | `unchanged` (server dry-run confirmed) |
| `acr-credential-<md5 of the ACR host>` ×5 | the ACR password-free plugin's Secrets, refreshed by it | the VPC endpoint's is used, by name |

New objects: the provisioner (SA, Role, Binding, nonce book, Service,
Deployment, PDB), the cluster-wide `ValidatingAdmissionPolicy`
`fleet-provisioner-template` and its binding, and `fleet-credproxy`
(Deployment + Service). No other ValidatingAdmissionPolicy in the cluster has
that name. No apply ever uses `--prune`.

## Apply (a person, once)

Use a checkout of a commit whose **stable release contains this PR and #5511**.
The provisioner runs the render.py inside its image, and an older image rejects
the template's new keys (`cannot render the user pod: … unexpected keyword`). The
pod runs its own image's runtime, so the region check in fleet-claude.sh and the
`FLEET_EXEC_REGION` line in `/etc/fleet-devnet.env` both come from the image as well.

```sh
NS=fleet-workers
HUB=https://core.tokenman.io
gh() { command gh "$@" -R verkyyi/claude-fleet; }
NODE_REPO=$(gh variable get NODE_IMAGE_BUILD_REPO)   # ACR's VPC endpoint, …/fleet-managed-node
ACR_PUSH=$(gh variable get HUB_PUSH_REPO)            # ACR's public endpoint, …/ccquota
ECR=$(gh variable get HUB_PUSH_REPO_AWS)             # the AWS hub's image repository
CCQUOTA_VPC=${NODE_REPO%/*}/ccquota                  # the same ACR namespace, VPC endpoint
PULL=acr-credential-$(python3 -c 'import hashlib,sys; print(hashlib.md5(sys.argv[1].encode()).hexdigest())' "${NODE_REPO%%/*}")
kubectl -n $NS get secret "$PULL" -o name    # must exist; it is what the overlay names
```

**1. Images.** The managed-node image is already in ACR: the release train's
`node image` job pushes `<NODE_REPO>:<TRAIN_SHA>`. Pin it by digest:

```sh
STABLE=$(curl -fsS $HUB/version | python3 -c 'import json,sys; print(json.load(sys.stdin)["stable"])')
NODE_IMAGE=$NODE_REPO@$(docker buildx imagetools inspect "$NODE_REPO:$STABLE" --format '{{json .Manifest}}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])')
```

With `FLEET_HUB_TARGET=aws-k3s`, the ccquota image goes to ECR. Set the repo
variable `HUB_MIRROR_ACR=1` (`gh variable set HUB_MIRROR_ACR --body 1`): the
train's `hub build` then copies each tag it pushes into ACR (`HUB_PUSH_REPO`),
registry to registry, and goes red unless the digest matches ECR's
([`deploy/aws/README.md`](../../../aws/README.md) «Repo variables»).

Fallback, for a tag built before the variable was set or a red copy: copy the
AWS hub's live tag into ACR by hand, with no local pull:

```sh
TAG=$(curl -fsS $HUB/version | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')   # prod-<sha7>
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin "${ECR%%/*}"
docker login "${ACR_PUSH%%/*}"        # an ACR account that may push to the namespace
docker buildx imagetools create --tag "$ACR_PUSH:$TAG" "$ECR:$TAG"
docker buildx imagetools inspect "$ACR_PUSH:$TAG"   # same digest as the ECR tag
```

**2. The credential proxy's token.** The hub accepts ONE credproxy token. Copy
the AWS hub's `CCQUOTA_FLEET_CREDPROXY_TOKEN` (Secret `ccquota-site-env` in
fleet-hub on the box; deploy/aws/README.md «Secrets»). Keep it off argv and out of
the repo: on the box, `kubectl -n fleet-hub get secret ccquota-site-env -o
jsonpath='{.data.CCQUOTA_FLEET_CREDPROXY_TOKEN}'`. Here, paste that base64 value
on stdin:

```sh
python3 -c 'import json,sys; print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":"fleet-credproxy","namespace":"fleet-workers"},"type":"Opaque","data":{"credproxy-token":sys.stdin.readline().strip()}}))' \
  | kubectl apply -f -
```

**3. The layer**, with the two placeholders filled:

```sh
kubectl kustomize deploy/k8s/overlays/ack-sz-cn \
  | sed -e "s#acr.invalid/fleet/fleet-managed-node:set-by-person\$#$NODE_IMAGE#" \
        -e "s#acr.invalid/fleet/ccquota:set-by-person\$#$CCQUOTA_VPC:$TAG#" > /tmp/ack-sz-cn.yaml
grep -n 'set-by-person\|acr.invalid' /tmp/ack-sz-cn.yaml && echo 'a placeholder is left' >&2
kubectl apply --dry-run=server -f /tmp/ack-sz-cn.yaml
kubectl apply -f /tmp/ack-sz-cn.yaml
kubectl -n $NS rollout status deploy/fleet-credproxy
```

The provisioner stays `ContainerCreating` until step 4 makes its ConfigMap.

**4. The provisioner's template** (+ the hub's account key) and its restart:

```sh
CP_IP=$(kubectl -n $NS get svc fleet-credproxy -o jsonpath='{.spec.clusterIP}')
sed -e "s#@MANAGED_NODE_IMAGE@#$NODE_IMAGE#" -e "s#@CREDPROXY_IP@#$CP_IP#" \
  deploy/k8s/overlays/ack-sz-cn/template.json.tmpl > /tmp/template.json
python3 -m json.tool /tmp/template.json >/dev/null
curl -fsS $HUB/v1/fleet/account-key > /tmp/account.pub
kubectl -n $NS create configmap fleet-provisioner --from-file=template.json=/tmp/template.json \
  --from-file=account.pub=/tmp/account.pub --dry-run=client -o yaml | kubectl apply -f -
kubectl -n $NS rollout restart deploy/fleet-provisioner
kubectl -n $NS rollout status deploy/fleet-provisioner
```

**5. fleet-ops, the cluster's link to the hub** (docs/dev/MANAGED-LINUX.md
«fleet-ops»). Take a join code from the hub's admin page, then redeem it with the
cluster's name as the hostname. The hub finds this link by `opsFor`, which is the
pod's hostname (`ack-sz`):

```sh
TOKEN=$(curl -fsS -X POST "$HUB/v1/node/join" -H 'Content-Type: application/json' \
  -d '{"code":"<码>","hostname":"ack-sz","os_user":"fleet-ops"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
kubectl -n $NS create secret generic fleet-ops --from-literal=token="$TOKEN"; unset TOKEN
python3 extras/managed-node/render.py --ops ack-sz --image "$NODE_IMAGE" --hub $HUB --pull-secret "$PULL" \
  | kubectl apply -f -
# optional: keep it on the mainland pool too (render.py --ops has no placement flags)
kubectl -n $NS patch deploy fleet-ops --type merge -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{"fleet/region":"cn"},"tolerations":[{"key":"fleet/region","operator":"Equal","value":"cn","effect":"NoSchedule"}]}}}}'
kubectl -n $NS logs deploy/fleet-ops | tail     # the agent's hello to the hub
```

**6. The hub's settings**, on the operator's seat (`fleet hub set`, audited).
Turn the region on before you list the cluster. Listing a `cn` cluster is the
switch that makes every global machine refuse DeepSeek, so do it last:

```sh
fleet hub get fleet.clusters                         # today's list, e.g. aws-k3s
fleet hub set fleet.spare_max.ack-sz 0               # no spare pods: a pod is made on assign
fleet hub set fleet.cluster_region.ack-sz cn
fleet hub set fleet.cred_pod_providers.ack-sz deepseek
fleet hub set fleet.region_cn.people <principal>     # comma-separated, or *
fleet hub set fleet.clusters aws-k3s,ack-sz          # the old list + ack-sz
```

**7. A person's pod.** No automatic road places anyone on a `cn` cluster. The
operator's assign names it, and with no spare ready that starts a pod of the
person's own (`placeOnCluster`):

```sh
fleet hub accounts assign <principal> --host ack-sz
kubectl -n $NS get deploy,pod,pvc -l fleet/role=user -o wide     # on the fleet/region=cn node
```

## Verify

- `kubectl -n $NS get pods -o wide`: `fleet-credproxy`, `fleet-provisioner` ×2,
  `fleet-ops` and each `u-<nonce>` are on the `fleet/region=cn` node; the PVC is `Bound`.
- `kubectl -n $NS logs deploy/fleet-credproxy`: no `resolve` errors. One line per
  request (`principal`, `worker_id`, `account`, `status`) once a session runs.
- In a pod: `kubectl -n $NS exec deploy/u-<nonce> -c fleet -- sh -c 'echo $FLEET_EXEC_REGION; grep -E "EXEC_REGION|GOPROXY|PIP_INDEX" /etc/fleet-devnet.env'`
  prints `cn`, then the region and mirror lines.
- `kubectl -n $NS exec deploy/u-<nonce> -c fleet -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://fleet-credproxy.fleet-workers.svc.cluster.local/healthz` prints `200`.
  The same against another Service's ClusterIP is refused (`Connection refused`, the guard's REJECT).
- The person opens a DeepSeek session there (`--model deepseek`): it answers. A
  Claude / Codex start there is refused with one line (`fleet_launch_refused region`).
- `fleet hub get fleet.clusters` lists `ack-sz`, and the hub's `/nodes` page shows `ack-sz`'s ops link up.

## Rollback

Reverse order, and the hub goes first, so nothing is placed on a cluster being taken down:

```sh
fleet hub set fleet.clusters aws-k3s                 # global machines take DeepSeek again at once
fleet hub accounts remove <principal> --host u-<nonce>   # each pod here: the hub's destroy-user-pod
fleet hub unset fleet.cluster_region.ack-sz; fleet hub unset fleet.cred_pod_providers.ack-sz
fleet hub unset fleet.spare_max.ack-sz; fleet hub unset fleet.region_cn.people
kubectl -n $NS delete deploy fleet-ops secret fleet-ops
kubectl delete -f /tmp/ack-sz-cn.yaml --ignore-not-found   # also deletes the shared SAs/Role: see below
kubectl -n $NS delete configmap fleet-provisioner secret fleet-credproxy
```

`kubectl delete -f` also deletes `fleet-user`, `fleet-job`, `fleet-credproxy`,
`fleet-ops` and the `fleet-ops` Role, which predate this overlay. To keep them,
delete only the new objects: `deploy/fleet-provisioner deploy/fleet-credproxy
svc/fleet-provisioner svc/fleet-credproxy sa/fleet-provisioner role/fleet-provisioner
rolebinding/fleet-provisioner cm/fleet-provisioner-nonces pdb/fleet-provisioner` and
`validatingadmissionpolicy,validatingadmissionpolicybinding fleet-provisioner-template`.
The StorageClass keeps (`Retain`) every home disk a destroyed pod leaves behind:
`kubectl get pv | grep fleet-workers` lists them, and they are deleted by hand.

## Open

- **Login road.** There is no door here, so a person reaches the pod over the
  hub's relay (`CapPodRelay`, BREAK-IT `pod-relay-loopback`). A door for `ack-sz`
  would be `render.py --door --hub $HUB …` and a new LoadBalancer. The old
  `fleet-door` still points at the old hub name and is left as it is.
- **Pool size.** One 4c16g node. Each pod requests 0.5 vCPU / 3 GiB, so after
  the credential proxy, the provisioner and fleet-ops, about three to four pods fit.
