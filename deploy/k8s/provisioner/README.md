# deploy/k8s/provisioner — the one writer in fleet-workers

(claude-fleet#3558, EPIC #3500 C16 · 共同约定 2) In the cluster exactly one
service may change Kubernetes: `fleet-provisioner` (`bin/fleet-provisioner.py`).
Everything else in fleet-workers runs as its own account with no token
(`../fleet-workers/serviceaccounts.yaml`), and fleet-ops reads only.

| Piece | What |
|---|---|
| `provisioner.yaml` | its ServiceAccount; a Role on Deployments · Jobs · Services · PVCs in fleet-workers, create / delete (never read) of Secrets — held by the policy to a user pod's join Secret `<pod>-join` (claude-fleet#3553) — and the nonce book (`fleet-provisioner-nonces`, get/update only); the book; the Deployment (2 replicas, non-root, read-only root) and its ClusterIP Service on 8790 |
| `policy.yaml` | the `ValidatingAdmissionPolicy` `fleet-provisioner-template` (Kubernetes ≥ 1.30) that holds every request the account makes to render.py's template |
| `kind-drill.sh` | the cluster half of BREAK-IT `sa-token-in-user-pod`, `provisioner-off-template` and `spare-pod-leaks` (`.github/workflows/cluster-perms.yml`) |

It takes a ticket and nothing else — `POST /v1/op`, the ticket as the body, from
fleet-ops (`fleet/role: control`) alone. A ticket is the hub's account key's
(the admin seat's, `GET /v1/fleet/account-key`) under its own domain, for THIS
cluster, five minutes, single-use; five typed ops: `create-user-pod` (pod,
limits, the pod's one login + UID — #3757 — and its one-time machine join code,
written into its join Secret) ·
`destroy-user-pod` (the join Secret too) · `set-limits` · `create-job` ·
`bind-user-pod` (a claimed spare pod's `fleet/principal` label — claude-fleet#3553) ·
`create-svc-run` / `delete-svc-run` (a service run's Job and its key Secret — claude-fleet#4005)
(`bin/fleet_cluster_ticket.py`,
its Go twin `tokenledger/internal/control/cluster_ticket.go`). No manifest ever
crosses: the provisioner renders the pod itself and checks it again
(`off_template`) before the API server checks it a third time.

## Apply (a person, once; after the namespace exists)

```sh
NS=fleet-workers
# the template: the cluster's name (the hub's tickets say it), render.py's
# user-pod arguments, the Job image — every image by digest. A user pod's own
# guard cuts the Service range, so the two in-cluster roads it uses are named in
# egress.allow by ClusterIP: the egress proxy (git / gh to GitHub) and the git
# mirror (fetches of the repos it carries — a fetch that had neither hung the
# warm pool, #3999). One git_mirrors entry per mirrored repo.
EGRESS_IP=$(kubectl -n $NS get svc fleet-egress -o jsonpath='{.spec.clusterIP}')
MIRROR_IP=$(kubectl -n arc-runners get svc fleet-git-mirror -o jsonpath='{.spec.clusterIP}')
cat > template.json <<EOF
{"cluster": "ack-sz", "namespace": "$NS",
 "user_pod": {"image": "$IMAGE", "hub": "$HUB", "storage_class": "$SC",
              "cred_central": "http://fleet-credproxy.$NS.svc.cluster.local",
              "egress_proxy": "http://fleet-egress.$NS.svc.cluster.local:3128",
              "git_mirrors": ["git://fleet-git-mirror.arc-runners:9418/claude-fleet.git=https://github.com/verkyyi/claude-fleet.git"],
              "egress": {"allow": ["$EGRESS_IP:3128", "$MIRROR_IP:9418"]},
              "cluster_caches": true, "pull_secrets": ["acr-pull"]},
 "job": {"image": "$IMAGE", "pull_secrets": ["acr-pull"],
         "git_mirror": "git://$GIT_MIRROR/{repo}.git", "caches": true,
         "egress_proxy": "http://fleet-egress.$NS.svc.cluster.local:3128"}}
EOF
curl -fsS "$HUB/v1/fleet/account-key" > account.pub
kubectl -n $NS create configmap fleet-provisioner --from-file=template.json --from-file=account.pub
# the whole layer: accounts and fleet-ops' Role first (a pod naming a missing
# account is never created), then the services, the provisioner, its policy
# ($MANAGED_NODE_IMAGE: the managed-node image by digest — the provisioner's image)
kubectl kustomize deploy/k8s/fleet-workers \
  | sed "s#image: fleet-provisioner-image\$#image: $MANAGED_NODE_IMAGE#" | kubectl apply -f -
```

Check it: `kubectl -n $NS auth can-i --list --as system:serviceaccount:$NS:<account>`
for each account — only `fleet-provisioner` lists a write. The user pods, the
door and the shared node (render.py) name their accounts too: apply this layer
before them.

## Private mirrors — a repo only a list of people may read (#4002)

The in-cluster git mirrors speak `git://` with no login, and ACK's flannel
enforces no NetworkPolicy, so whoever can reach a mirror's address can clone it.
For a public repo that is fine (`git_mirrors` + `egress.allow`, every pod). For an
internal repo the wall is each user pod's own egress guard: `private_mirrors`
lists the mirror, its Service's ClusterIP and the logins that may read it, and
render.py gives a pod the guard's allow line, the `insteadOf` and the label
`fleet/mirror-<repo>` **only when its login is on that list**. Anyone else's pod
gets none of the three: the guard rejects the address and git fetches GitHub
through the egress with the person's own credentials — GitHub decides. A private
mirror's address in the open `egress.allow`, or its upstream in `git_mirrors`, is
refused at render.

**The list lives in the cluster only** — never in this repo (it names internal
repos and people): ConfigMap `fleet-private-mirrors` in fleet-workers, key
`private-mirrors.json`, a JSON list:

```json
[{"mirror": "git://git-mirror.arc-runners:9418/acme-monorepo.git",
  "upstream": "https://github.com/acme-org/acme-monorepo.git",
  "allow": "172.21.x.y:9418",
  "logins": ["alice", "bob"]}]
```

`allow` is the mirror Service's ClusterIP (`kubectl -n arc-runners get svc <mirror>`),
`logins` the pod logins (`FLEET_POD_LOGIN` of a user pod, the `--login` it was
rendered with) — a person is on the list by login, nothing else.

```sh
NS=fleet-workers
# read / edit the list (an admin, from the cluster's kubectl)
kubectl -n $NS get cm fleet-private-mirrors -o jsonpath='{.data.private-mirrors\.json}' > private-mirrors.json
$EDITOR private-mirrors.json        # add or remove a login in "logins"
kubectl -n $NS create cm fleet-private-mirrors --from-file=private-mirrors.json --dry-run=client -o yaml | kubectl apply -f -
# a NEW pod: the provisioner's template carries the same list, and a hand render takes the file
jq --slurpfile pm private-mirrors.json '.user_pod.private_mirrors = $pm[0]' template.json > t && mv t template.json
python3 extras/managed-node/render.py … --user-pod u-… --login <name> --uid <n> --private-mirrors private-mirrors.json
# a RUNNING pod (its access follows the list; the pod restarts, the home disk stays)
kubectl -n $NS get deploy u-<nonce> -o json \
  | python3 extras/managed-node/render.py --mirror-grant private-mirrors.json > grant.json
kubectl -n $NS patch deploy u-<nonce> --type=json --patch-file grant.json
```

`--mirror-grant` touches only the template's `fleet/mirror-*` labels,
`FLEET_GIT_MIRRORS` and the guard's allow lines, and tests the Deployment's
resourceVersion (a Deployment changed in between is refused, re-run it). Check a
pod: `kubectl -n $NS exec deploy/u-<nonce> -c fleet -- git ls-remote <mirror URL> HEAD`
answers for a listed login and is refused (`Connection refused`, the guard's
REJECT) for anyone else. The provisioner also refuses a Job of a listed repo for a
pod whose login is not on its list (#4002). What the guard does not cover: a pod
with no egress guard (a Job, the shared node, another namespace's workload) can
still reach the mirror while the CNI enforces no NetworkPolicy.

## Service runs — one Job per run, then nothing (#4005)

`create-svc-run` {run, attempt, svc, deadline, token} renders `render.py
svc_run_resources` from the template's `svc` section and makes the Job
`svc-r<n>-a<k>`, then its key Secret `svc-r<n>-a<k>-token` (one key `token`, the
hub's one-time key for this run) owned by the Job — the garbage collector takes
it with the Job, `ttlSecondsAfterFinished` after it ends. `delete-svc-run` deletes
that Job, only when its labels say it is a service run's. The policy lets a Job
mount no Secret but a run's own key and no disk at all, and lets only a run's
`egress-guard` init be root (NET_ADMIN NET_RAW, read-only root).

```sh
NS=fleet-workers
# the two roads a run's closed guard lets through, by ClusterIP
RUN_EGRESS_IP=$(kubectl -n $NS get svc fleet-egress-run -o jsonpath='{.spec.clusterIP}')
CENTRAL_IP=$(kubectl -n $NS get svc fleet-credproxy -o jsonpath='{.spec.clusterIP}')
jq --arg img "$IMAGE" --arg hub "$HUB" --arg a "$RUN_EGRESS_IP:3128" --arg b "$CENTRAL_IP:80" \
  '.svc = {image: $img, hub: $hub, pull_secrets: ["acr-pull"], ttl: 300,
           cred_central: "http://fleet-credproxy.fleet-workers.svc.cluster.local",
           egress_proxy: "http://fleet-egress-run.fleet-workers.svc.cluster.local:3128",
           egress: {allow: [$a, $b]}}' template.json > t && mv t template.json
kubectl -n $NS create configmap fleet-provisioner --from-file=template.json --from-file=account.pub \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n $NS rollout restart deploy/fleet-provisioner
```

`$IMAGE` is the managed-node image by digest (python3, iptables, the runner and the
pinned Claude Code in its seed). On the hub: `CCQUOTA_FLEET_SVC_CLUSTER=<the
cluster's name>` (docs/dev/FLEET-HUB.md «A service run's environment»). Check a run:
`kubectl -n $NS get jobs,pods -l fleet/svc=livepage` — while it runs, and nothing
five minutes after it ends.
