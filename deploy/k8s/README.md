# deploy/k8s — the hub's manifests

The hub (`tokenledger/`, the `ccquota` image) runs as one Deployment. Two shapes
(issue #2125, EPIC #2119): the **base** is two replicas on a managed Postgres,
released one pod at a time — 0 seconds down; **production** runs the
`components/sqlite-single` shape — one replica on one SQLite data disk,
`Recreate` — until the switch (RUNBOOK.md «换库»), which deletes one line from
`overlays/prod/kustomization.yaml`. These manifests moved here from `24haowan-monorepo/doc/k8s-yamls/ccquota/`
(EPIC #1982 C1, issue #1983); the monorepo copy is read-only from then on.

```
base/              environment-free: Deployment (2 replicas, rolling, Postgres), Service,
                   Ingress, PodDisruptionBudget, pricing ConfigMap
components/sqlite-single/
                   the single SQLite shape: 1 replica, Recreate, the PVC, disk-watch
overlays/prod/     namespace new-deploy, ACR image, hostnames + TLS, production settings;
                   `components: [sqlite]` until the switch
overlays/kind/     the rolling drill on a throwaway kind cluster (hub-rolling.yml)
updating/          the 「正在更新」 page the Ingress falls back to during a release (installed by a person)
RUNBOOK.md         when the pod will not come up, the data disk, the two secrets
```

## Release = merge, batched

A merge to `master` that touches `tokenledger/**` or `deploy/k8s/**` starts
[`hub-deploy`](../../.github/workflows/hub-deploy.yml). Nobody approves the run
(environment `prod` admits master only, no reviewer — issue #2013).

**Cadence** (issue #2052) — a push does not deploy at once. Its `gate` job holds
until master has been **quiet for `QUIET_MINUTES` (10)** — no newer
`tokenledger/` / `deploy/k8s/` commit — **and `MIN_GAP_MINUTES` (30)** have
passed since the last successful release (the newest success of environment
`prod`). When a newer such commit lands while it holds, the run stands down
green (summary: 已合并到后面的发布): that commit's run is already queued behind
it in the `prod` concurrency group and ships both. So an evening of fifteen
merges is one or two releases, not fifteen restarts. The two constants sit at
the top of the workflow. **Emergency release** (a fix, a rollback) =
Actions → hub-deploy → Run workflow: `workflow_dispatch` never holds and is
never paused.

Once it goes, the deploy job:

1. packs the client (`bin/fleet-client-pack.sh`) and builds `tokenledger/` for
   linux/amd64, pushed as `registry.cn-shenzhen.aliyuncs.com/24haowan/ccquota:prod-<sha7>`
   (`VERSION=prod-<sha7>`, which is what `/version` reports);
2. renders `overlays/prod` with that tag (the manifests carry the placeholder
   `set-by-hub-deploy`; the live tag is never committed);
   — and reads the render's **shape** (`release.sh shape`): `sqlite` or
   `postgres`, never a mix (a disk with two replicas is refused before anything
   changes). Steps 3–4 are the sqlite shape's only: on Postgres RDS keeps the
   backups, and a rolling release never stops an old pod before a new one is
   ready;
3. snapshots the database (`/data/backup-hubdeploy-<UTC>-<previous tag>.db`,
   the newest 3 kept);
4. **checks the new image before the switch** (issues #2050, #2052): the new
   image runs as an ephemeral container in the live pod — the render's env /
   envFrom / args, the live pod's volume mounts (Secrets, CA, credential key,
   pricing, `/data`) — and runs `ccquota hub --check` on a copy of that
   snapshot (`/data/rehearse-<run>.db`, deleted afterwards). `--check` starts
   the hub as far as serving and stops there: it runs the pending migrations,
   then every startup check the hub refuses to start without — the GitHub
   sign-in pair (one half ⇒ refuse), the SSH CA and credential-vault keys,
   `--pricing`, the routes, the SPOT and
   refresh settings — and exits 0 without binding a port or touching the live
   database. A Secret key the env names but the Secret lacks fails the
   container's own start (CreateContainerConfigError) — red too. Anything red
   stops the release before the apply — the live pod never stopped, the job is
   red, the summary says 没部署. A volume only the render mounts (a running pod
   takes no new one) is named as a warning and first tried by the real start.
   An image older than `--check` (a rollback tag) is rehearsed with
   `--migrate-only`. Drills: `workflow_dispatch` with `simulate_check_failure`
   (half a GitHub pair) or `simulate_migration_failure`;
5. starts the **availability probe** (`probe.sh`, issue #2125): once a second
   `GET /healthz` + `POST /v1/deploy-probe` (one real database write) on the
   first address, until step 7 / the rollback is done; then records the live
   image, `kubectl apply`s the render, waits for the rollout (sqlite: 3 minutes
   — with `Recreate` the old pod is already gone, so a longer wait is a longer
   503 before the rollback; postgres: 8 minutes, the old pods serve meanwhile);
6. checks every address for `/healthz` = 200 **and** `/version` naming this
   commit **and** a whole entry — `GET /install` 200 with a `#!` first line,
   `/version` naming `stable`, `POST /v1/fleet/login/start` not 404 (issue
   #2060: a deploy that lost its overlay config otherwise passes) — up to ~2
   minutes each;
7. stops the probe and writes the run's summary page — its row
   `downtime_seconds=<n>` is the seconds of the release in which either probe
   was not 2xx (a write probe's 404 is an image from before the endpoint,
   counted apart); then and, when repo variable
   `HUB_DEPLOY_NOTIFY_ISSUE` names an issue, comments there. The summary is
   reporting only: if it fails, the job stays green and the notice still says
   what the release did.

**Rolling** (the base, after the switch): `maxUnavailable 0`, `maxSurge 1` —
a third pod starts, gets traffic only once `/readyz` says its database answers
and has every migration the image knows, and only then does an old one go: its
`preStop` sleeps 5 s while the endpoint removal reaches the ingress, then
SIGTERM and up to `CCQUOTA_SHUTDOWN_GRACE` (25 s) for the requests it already
took. A release that never gets ready leaves both old pods serving until the
rollback. The PodDisruptionBudget keeps one replica through a node drain, and
the spread puts them on two nodes. No disk, so nothing gets stuck attaching.
The drill is [`hub-rolling`](../../.github/workflows/hub-rolling.yml) on every
PR that touches a release: kind, two replicas + Postgres, three releases, a
deleted pod, a broken release + rollback, `downtime_seconds=0` or red.

**During a sqlite release** the hub has no ready pod for a few tens of seconds
(`Recreate`). The Ingress's `default-backend` annotation sends those requests
to [`updating/`](updating/README.md): a browser gets a bilingual
「ClaudeFleet 正在更新，一分钟内回来 / is updating — back in a minute」 page
that reloads every 15 s; `/v1/*`, `/mcp`, `/install`, `/healthz`, `/version`
and anything not asking for HTML get `503` + `Retry-After: 30` + a short JSON
body, so agents and clients retry as before. Until a person has installed it,
hub-deploy drops the annotation from its render (warning in the run).

Nothing on any machine: no docker, no registry login, no kubeconfig.

**Automatic rollback** — when the rollout or the health check fails, the job
`kubectl set image`s the image that was live before it started, waits for that
rollout, checks it answers healthy, and goes red. Only the image goes back: the
manifests stay master's, and a migration the new image already ran stays run —
the summary names the snapshot taken just before, and restoring it is a
person's job (RUNBOOK.md). A first deploy (no live Deployment) or a redeploy of
the tag already live has nothing to go back to; the job says so and goes red.

**The summary** (the run's page, every run): live tag → new tag, the commits
between (`git log --oneline <old>..<new> -- tokenledger deploy/k8s`; a deploy of
an older tag lists what comes off instead), whether `tokenledger/internal/store`
added schema-changing lines (a heuristic — it says 可能有, read the diff), the
ccquota container's env before → after, the manifests' diff, the snapshot path,
and whether it rolled back. The logic lives in
[`.github/actions/hub-release/release.sh`](../../.github/actions/hub-release/release.sh)
(`--selftest` runs on every PR).

**Pause** — repo variable `HUB_DEPLOY_PAUSED=1`
(`gh variable set HUB_DEPLOY_PAUSED --body 1`): a push to master deploys
nothing; the run is green and its summary says 已暂停. Delete the variable
(`gh variable delete HUB_DEPLOY_PAUSED`) to resume — the commits merged while
paused go out with the next push, or run the workflow by hand. A manual
`workflow_dispatch` is never paused.

**Notify** — repo variable `HUB_DEPLOY_NOTIFY_ISSUE=<N>`: every release
(published / rolled back / failed) leaves one comment on issue N with the run's
link, using the job's own `GITHUB_TOKEN` (`issues: write`, nothing more). Unset =
no comment.

**Manual rollback** — Actions → hub-deploy → Run workflow, `tag` = the old
`prod-<sha7>` (the snapshot step names the tag each snapshot was taken from).
It deploys that image with master's manifests. A rollback across a database
migration also needs the matching snapshot restored — RUNBOOK.md.

**Rollback drill** — Run workflow with `simulate_unhealthy` ticked and `tag` =
any existing `prod-<sha7>` OTHER than the live one (an older one is fine; the
live tag would leave nothing to roll back to). It deploys that tag, treats the
health check as failed, rolls back to the live image, and goes red; `/version`
afterwards names the live commit again. Untick `snapshot` if you do not want a
snapshot for the drill.

**Concurrency** — one deploy at a time; a running one is never cancelled (a
cancelled sqlite rollout leaves the hub down), a newer run waits and
replaces any run still only waiting. A run still holding for the quiet period
stands down by itself when a newer commit lands (above).

**Never `kubectl apply -k overlays/prod` by hand**: the placeholder tag does not
exist, and on the sqlite shape the hub would go down. To redeploy, run the
workflow. The one exception is the switch itself (RUNBOOK.md «换库»).

## Who may do what

- GitHub: the deploy job runs only in environment `prod` — master only, no
  reviewer (issue #2013: the job rolls itself back instead). The repository holds no credential (`gh secret list` is
  empty); the job trades its OIDC token for STS as RAM role
  `gha-claudefleet-deploy` (trusts `sub=repo:verkyyi/claude-fleet:environment:prod`
  only).
- Aliyun: `gha-prod-kubeconfig` (a temporary kubeconfig) + `gha-claudefleet-acr-push`
  (pull/push `24haowan/ccquota` only).
- Cluster: Role `new-deploy/claudefleet-deployer` (24haowan-monorepo#11751) —
  the hub's Deployment, Service, Ingress, the `ccquota-pricing` ConfigMap, a
  read of the `ccquota-data` PVC, pod exec for the snapshot, and patch on
  `pods/ephemeralcontainers` for the pre-switch check (issues #2050, #2052 —
  without it the check refuses and nothing is released; the Secrets the check
  container reads are resolved by the kubelet, never by the Role), and `list`
  on pods (which is how it sees whether the updating page runs), and the
  credential proxy's Deployment `ccquota-credproxy`, which a good release rolls
  to the same image (issue #2092), and — once production is on the rolling
  shape — the hub's PodDisruptionBudget (issue #2125; the sqlite render has
  none, so until the switch the Role needs nothing new). No Secret, no
  RBAC. The updating page's own objects are not in the Role: a person applies
  them (updating/README.md).
  The Role lives in 24haowan-monorepo, not here. The credential-proxy line it
  needs (until it has it, the release skips the proxy with a warning) is the
  name added to its first rule:

  ```yaml
  - apiGroups: [apps]
    resources: [deployments]
    resourceNames: [ccquota-hub, ccquota-credproxy]
    verbs: [get, list, watch, patch, update]
  ```

  The PDB line the switch needs, added before it (RUNBOOK.md «换库»):

  ```yaml
  - apiGroups: [policy]
    resources: [poddisruptionbudgets]
    verbs: [create]                     # create cannot be narrowed by name
  - apiGroups: [policy]
    resources: [poddisruptionbudgets]
    resourceNames: [ccquota-hub]
    verbs: [get, list, watch, patch, update]
  ```

  So a change to the PVC (growing the disk) or to a Secret is a person's, with
  an admin kubeconfig — RUNBOOK.md.

## Addresses

`https://claudefleet.24haowan.com` is the hub's address (`CCQUOTA_FLEET_PUBLIC_URL`,
so `/install` hands it to new clients). `https://ccquota.24haowan.com` stays
served until every client has moved; both are in `overlays/prod/ingress-hosts.yaml`.
