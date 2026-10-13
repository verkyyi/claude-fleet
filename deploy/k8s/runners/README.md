# deploy/k8s/runners — this repo's runners in the cluster

`fleet-ack` is an [Actions Runner Controller](https://github.com/actions/actions-runner-controller)
scale set for this repository, so a job can run **inside the cluster** (issue
#3855). Its one user today is the release train's `node image` job
(`runs-on: fleet-ack`), which builds the managed node image of each release
beside the cluster's BuildKit daemon — native amd64, the hub and the registry's
VPC endpoint a hop away — instead of on a Mac across the Pacific
(docs/dev/MANAGED-LINUX.md «The ACK image»).

It rides an ARC that is already there and is not ours: the controller in
`arc-systems` (0.14.x, watching `arc-runners`), the runner image, the node pool,
`buildkitd:1234` with its client TLS Secret `buildkit-client-tls`. Adding
`fleet-ack` changes none of them, and none of the other scale sets.

| Piece | What |
|---|---|
| `AutoscalingRunnerSet fleet-ack` | 0–2 runners, started per job and gone after it (ephemeral); the node pool's tolerations / affinity as the neighbours'; `BUILDKIT_HOST` + `BUILDKIT_TLSDIR` set |
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
