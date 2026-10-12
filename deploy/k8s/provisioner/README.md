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
cluster, five minutes, single-use; five typed ops: `create-user-pod` (with the
pod's one-time machine join code, written into its join Secret) ·
`destroy-user-pod` (the join Secret too) · `set-limits` · `create-job` ·
`bind-user-pod` (a claimed spare pod's `fleet/principal` label — claude-fleet#3553)
(`bin/fleet_cluster_ticket.py`,
its Go twin `tokenledger/internal/control/cluster_ticket.go`). No manifest ever
crosses: the provisioner renders the pod itself and checks it again
(`off_template`) before the API server checks it a third time.

## Apply (a person, once; after the namespace exists)

```sh
NS=fleet-workers
# the template: the cluster's name (the hub's tickets say it), render.py's
# user-pod arguments, the Job image — every image by digest
cat > template.json <<EOF
{"cluster": "ack-sz", "namespace": "$NS",
 "user_pod": {"image": "$IMAGE", "hub": "$HUB", "storage_class": "$SC",
              "cred_central": "http://fleet-credproxy.$NS.svc.cluster.local",
              "egress_proxy": "http://fleet-egress.$NS.svc.cluster.local:3128",
              "cluster_caches": true, "pull_secrets": ["acr-pull"]},
 "job": {"image": "$JOB_IMAGE", "pull_secrets": ["acr-pull"]}}
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
