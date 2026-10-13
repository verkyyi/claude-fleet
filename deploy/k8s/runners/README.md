# deploy/k8s/runners — this repo's runners in the cluster

`fleet-ack` is an [Actions Runner Controller](https://github.com/actions/actions-runner-controller)
scale set for this repository, so a job can run **inside the cluster** (issue
#3855). Its users: the release train's `node image` job (`runs-on: fleet-ack`),
which builds the managed node image of each release beside the cluster's BuildKit
daemon — native amd64, the hub and the registry's VPC endpoint a hop away —
instead of on a Mac across the Pacific (docs/dev/MANAGED-LINUX.md «The ACK
image»); and, when the repo variable `FLEET_TRAIN_RUNNER=fleet-ack` asks, the
train's **Linux test shards** (issue #3864, below).

It rides an ARC that is already there and is not ours: the controller in
`arc-systems` (0.14.x, watching `arc-runners`), the runner image, the node pool,
`buildkitd:1234` with its client TLS Secret `buildkit-client-tls`. Adding
`fleet-ack` changes none of them, and none of the other scale sets.

| Piece | What |
|---|---|
| `AutoscalingRunnerSet fleet-ack` | 2 idle by day (0 at night), 64 at most, started per job and gone after it (ephemeral); on the `fleet-ci` node pool only; image `fleet-ci-runner`; `BUILDKIT_HOST` + `BUILDKIT_TLSDIR` set |
| `Role` / `RoleBinding fleet-ack-gha-rs-manager` | what the controller's account needs in the namespace to run the set (the chart's own) |
| `ServiceAccount fleet-ack-runner` | the runner pod's: no API rights, no token mounted |
| `Secret claude-fleet-runners-app` | the GitHub App that registers runners for this repo only (`github_app_id`, `github_app_installation_id`, `github_app_private_key`) — created by a person, never in a file |

A job on it gets nothing from the cluster but the build daemon: registry pushes
are its own short OIDC login (`.github/actions/hub-acr`, a RAM role that may push
one repository, environment `node-image`, master only).

## Apply / change

`fleet-ack.example.yaml` is the shape; ours (our registry and pull secrets) is
the private deploy repo's `k8s/runners/fleet-ack.yaml` (claude-fleet#3630).

```sh
kubectl -n arc-runners get secret claude-fleet-runners-app   # the App's Secret first
kubectl apply --dry-run=server -f k8s/runners/fleet-ack.yaml
kubectl apply -f k8s/runners/fleet-ack.yaml
kubectl -n arc-systems get pods | grep fleet-ack              # its listener: Running
```

The manifest is the `gha-runner-scale-set` chart's 0.14.2 output (the
`app.kubernetes.io/version` label must match the controller's version — move
both together). Remove: `kubectl delete -f …` (the controller unregisters the
set from GitHub).

## The train's Linux shards on fleet-ack (issue #3864)

| Piece | What |
|---|---|
| node pool `fleet-ci` (`fleet-ci-nodepool.example.json`) | spot, 16 cores (several instance types against a stock-out), autoscaled **0–3** — the cluster's cap is 10 nodes and the rest is not ours; label + taint `fleet-ci=true`, so only fleet-ack's pods land there. A runner pod asks 1 vCPU / 2 GiB ⇒ about 14 a node |
| image `fleet-ci-runner` (`extras/ci-runner/`) | the cluster's ARC runner image + what the selftests reach for (tmux, zsh, fzf, shellcheck, Go 1.25 with tokenledger's modules, Node 22, …) + the actions a shard uses; tag = `extras/ci-runner/tag.sh`, built and pushed by `.github/workflows/ci-runner-image.yml` on fleet-ack only when the tag is new (role `gha-claudefleet-ci-runner`, environment `ci-runner`) |
| `fleet-git-mirror` (`fleet-ci.example.yaml`) | a read-only mirror of this repo on the always-on CI node; a shard fetches TRAIN_SHA there (repo variable `FLEET_TRAIN_GIT_MIRROR`, e.g. `git://fleet-git-mirror.arc-runners:9418/claude-fleet.git`), GitHub when it does not have it within ~30 s |
| `fleet-ci-prepull` | the runner image pulled onto each fleet-ci node as it joins |
| `fleet-ack-night` | minRunners 0 from 01:00 to 08:00 Beijing (the pool then empties to 0 by itself), 2 at 08:00 |
| environment `fleet-ack-probe` | the train's `Linux 选机器` job: var `FLEET_RUNNERS_APP_ID` + secret `FLEET_RUNNERS_APP_KEY` (the runner app above, master only) — it reads the repo's runner list, nothing else |

Switch: repo variable `FLEET_TRAIN_RUNNER` — empty = the Linux half on
`ubuntu-latest` exactly as before; `fleet-ack` = the cluster first. No online
fleet-ack runner (night, the set scaled to 0, the controller down, no token) ⇒
`ubuntu-latest`, the summary says 「深圳不可用，退回 GitHub」 (BREAK-IT
`train-ack-down`). A shard whose spot node is reclaimed mid-job is rerun on
`ubuntu-latest` as `Linux rescue / shard K` and the train ships (BREAK-IT
`train-ack-reclaimed`).

A new runner image: change `extras/ci-runner/`, merge — `ci-runner image` pushes
`fleet-ci-runner:<tag>` — then point the scale set's `template` image **and** the
prepull DaemonSet at that tag in the private deploy repo and apply. A shard on an
older image warns 「this runner's image is …」 on its summary and runs anyway.

```sh
aliyun cs POST /clusters/<cluster>/nodepools --body "$(cat fleet-ci-nodepool.json)"
kubectl apply -f k8s/runners/fleet-ci.yaml          # mirror, prepull, night schedule
kubectl apply -f k8s/runners/fleet-ack.yaml         # the set on fleet-ci, the new image
gh variable set FLEET_TRAIN_GIT_MIRROR --body 'git://fleet-git-mirror.arc-runners:9418/claude-fleet.git'
gh variable set FLEET_TRAIN_RUNNER --body fleet-ack  # empty it to go back to GitHub's
```
