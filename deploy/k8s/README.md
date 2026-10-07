# deploy/k8s — the hub's manifests

The hub (`tokenledger/`, the `ccquota` image) runs as one Deployment on one data
disk. These manifests moved here from `24haowan-monorepo/doc/k8s-yamls/ccquota/`
(EPIC #1982 C1, issue #1983); the monorepo copy is read-only from then on.

```
base/              environment-free: Deployment, Service, Ingress, PVC, pricing ConfigMap
overlays/prod/     namespace new-deploy, ACR image, hostnames + TLS, production settings
RUNBOOK.md         when the pod will not come up, the data disk, the two secrets
```

## Release = merge

A merge to `master` that touches `tokenledger/**` or `deploy/k8s/**` starts
[`hub-deploy`](../../.github/workflows/hub-deploy.yml). @verkyyi approves the run
once (environment `prod`), then it:

1. packs the client (`bin/fleet-client-pack.sh`) and builds `tokenledger/` for
   linux/amd64, pushed as `registry.cn-shenzhen.aliyuncs.com/24haowan/ccquota:prod-<sha7>`
   (`VERSION=prod-<sha7>`, which is what `/version` reports);
2. renders `overlays/prod` with that tag (the manifests carry the placeholder
   `set-by-hub-deploy`; the live tag is never committed);
3. snapshots the database (`/data/backup-hubdeploy-<UTC>-<previous tag>.db`,
   the newest 3 kept);
4. `kubectl apply`s the render, waits for the rollout;
5. reads `/version` on every address until it names this commit.

Nothing on any machine: no docker, no registry login, no kubeconfig.

**Rollback** — Actions → hub-deploy → Run workflow, `tag` = the old
`prod-<sha7>` (the snapshot step names the tag each snapshot was taken from).
It deploys that image with master's manifests. A rollback across a database
migration also needs the matching snapshot restored — RUNBOOK.md.

**Never `kubectl apply -k overlays/prod` by hand**: the placeholder tag does not
exist, and with `Recreate` the hub would go down. To redeploy, run the workflow.

## Who may do what

- GitHub: the deploy job runs only in environment `prod` — master only, each run
  approved by @verkyyi. The repository holds no credential (`gh secret list` is
  empty); the job trades its OIDC token for STS as RAM role
  `gha-claudefleet-deploy` (trusts `sub=repo:verkyyi/claude-fleet:environment:prod`
  only).
- Aliyun: `gha-prod-kubeconfig` (a temporary kubeconfig) + `gha-claudefleet-acr-push`
  (pull/push `24haowan/ccquota` only).
- Cluster: Role `new-deploy/claudefleet-deployer` (24haowan-monorepo#11751) —
  the hub's Deployment, Service, Ingress, the `ccquota-pricing` ConfigMap, a
  read of the `ccquota-data` PVC, pod exec for the snapshot. No Secret, no RBAC.
  So a change to the PVC (growing the disk) or to a Secret is a person's, with
  an admin kubeconfig — RUNBOOK.md.

## Addresses

`https://claudefleet.24haowan.com` is the hub's address (`CCQUOTA_FLEET_PUBLIC_URL`,
so `/install` hands it to new clients). `https://ccquota.24haowan.com` stays
served until every client has moved; both are in `overlays/prod/ingress-hosts.yaml`.
