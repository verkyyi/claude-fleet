# deploy/aws/k3s-box — the box installs itself

The why, the cost, the Secrets and the roll-back are in [../README.md](../README.md).
This directory is what runs on the box.

| File | What |
|---|---|
| `user-data.yaml` | EC2 user data (cloud-init): writes `/etc/fleet-core/deploy.env` (no secret in it), clones this repo to `/opt/claude-fleet` at `FLEET_REPO_REF` (a branch or tag), runs `bootstrap.sh`; output in `/var/log/fleet-core-bootstrap.log` |
| `bootstrap.sh` | as root: k3s (`K3S_CHANNEL`, or `INSTALL_K3S_VERSION`) → awscli → the ECR pull secret and its 6-hourly timer → cert-manager (and the EBS CSI driver for `STORAGE_CLASS=gp3`) through k3s' helm controller → the Secrets (`/etc/fleet-core/secrets`, generated once, the Postgres URL from SSM) → `deploy/k8s/overlays/aws-k3s` with its placeholders filled → the provisioner's template. Every step looks before it acts |
| `restore-user-data.yaml` | EC2 user data for a box rebuilt from a snapshot: pins the old k3s node name (README «A lost box») |
| `rollout-drill.sh` | as root, at a quiet time: `rollout restart` of the hub with machines connected; PASS when every link is back and the worst `hub_restart` gap is under 10 s |

```sh
sudo /opt/claude-fleet/deploy/aws/k3s-box/bootstrap.sh          # install / repair / upgrade
sudo /opt/claude-fleet/deploy/aws/k3s-box/bootstrap.sh apply    # the overlay + template only
sudo /opt/claude-fleet/deploy/aws/k3s-box/bootstrap.sh render   # print the render, change nothing
sudo /opt/claude-fleet/deploy/aws/k3s-box/rollout-drill.sh 3    # three rolling restarts
```

A new hub release: push the image, set `HUB_IMAGE` in `/etc/fleet-core/deploy.env`,
`bootstrap.sh apply`. A new overlay: `git -C /opt/claude-fleet pull`, `bootstrap.sh apply`.
