# Install and deploy

This page is for the person on a self-hosting team who does the deployment. When you are through, you will have:

- your own **hub** (one container on a Linux server, or a set of replicas on Kubernetes), with the web console on it;
- **machines** connected to the hub — Mac or Linux — where sessions run;
- the **client** on every member's computer;
- a way to upgrade and roll back: every part follows the same version, `stable`.

With only one computer and no colleagues to create accounts for, you need no hub: install local mode as in [Self-host · Quickstart](quickstart.md).

The addresses and names in the examples below are placeholders: the hub `https://hub.example.com`, machines `mac-a` `linux-a`, the admin `alice`. Replace them with your own.

## 0. What you need

| What | Notes |
|---|---|
| A domain name and an HTTPS certificate | The hub's address, for example `hub.example.com`. Machines and clients accept HTTPS only. |
| Somewhere to run the hub | A Linux server with Docker (a single container, with HTTPS from a reverse proxy — see [§1.5](#15-option-one-a-single-container)), or a Kubernetes cluster with ingress-nginx. The hub is small: 1 core and 1 GB of memory is enough for a small team. |
| Somewhere to build the image | A computer with Docker (with BuildKit / buildx) and `git` that can fetch base images and Go dependencies. On Ubuntu: `sudo apt install docker.io docker-buildx`. |
| At least one sign-in method | **Have it ready before you start**: with none, the hub does not start, or starts and the admin cannot get in. One or more of: a GitHub OAuth app (its Client ID / secret, callback set to the hub's address); an SMTP server that can send mail (host, port, user, password, and a sender address **already enabled** at your provider — a cloud mail service verifies the sending domain first); a WeChat Open Platform website app (AppID / AppSecret; review takes days). See [§1.4](#14-sign-in-methods). |
| Machines to run sessions | macOS or Linux (Debian 12 / Ubuntu with systemd), each with an administrator account that can `sudo`. |
| Subscriptions | A Claude subscription (Pro / Max / Team) or a ChatGPT subscription. Each person can bring their own, or an admin can connect some to the hub for everyone to share. |

## 1. Set up the hub

The hub is one program, `ccquota hub`, listening on one port (8787) and keeping its data in one SQLite file (or Postgres instead).

### 1.1 Build the image

The hub's image is built from source, **from the `stable` commit** — machines' upgrade packages are signed by the hub, and the hub signs only a version built from the same source as itself (see [§4](#4-upgrading)).

```sh
git clone https://github.com/verkyyi/claude-fleet.git
cd claude-fleet
git checkout stable
TAG=$(git rev-parse --short HEAD)
bin/fleet-client-pack.sh
docker build --build-arg VERSION=$TAG -t registry.example.com/fleet/ccquota:$TAG tokenledger/
docker push registry.example.com/fleet/ccquota:$TAG
```

- `bin/fleet-client-pack.sh` packs the files clients and machines download into the image; without this step `docker build` refuses.
- `VERSION` is the version name the hub reports at `/version`; a commit id is easiest to match up.
- The image carries the programs macOS and Linux (amd64 / arm64) machines download, so the build takes a few minutes. With the hub on one machine only, you need not push the image to a registry.
- It needs BuildKit: the Dockerfile uses `--platform=$BUILDPLATFORM`, and `docker build` without buildx fails with `"" is an invalid OS component`. Ubuntu's `docker.io` does not include it; install `docker-buildx`.
- By default the build fetches Go dependencies through `goproxy.cn` (from mainland China the official proxy often stalls). Building elsewhere, or to avoid it, add `--build-arg GOPROXY=https://proxy.golang.org,direct`.

### 1.2 Generate the keys

Generate them in a directory only you can read. **These files never go into any repository**:

```sh
umask 077 && mkdir -p ~/fleet-secrets && cd ~/fleet-secrets   # umask first, so the directory itself is 0700
ssh-keygen -t ed25519 -N '' -C fleet-user-ca -f ca     # the key that signs connection certificates: ca + ca.pub
openssl rand -base64 32 > cred-key                      # the key of the subscription credential vault
openssl rand -hex 24 > viewer-token                     # the read-only password of the usage page
docker run --rm --user "$(id -u)" -v "$PWD:/out" --entrypoint ccquota \
  registry.example.com/fleet/ccquota:$TAG release keygen --out /out/release-key   # the key that signs upgrade packages
```

| File | Used for | If lost / leaked |
|---|---|---|
| `ca` | Signs short-lived connection certificates for members and machines | Leaked: generate a new one; everyone signs in once more |
| `cred-key` | Encrypts the subscription credentials stored in the hub | **Do not change it**: once changed, every stored credential is unreadable and every subscription has to be connected again |
| `viewer-token` | The read-only password of the usage page | Just generate a new one |
| `release-key` | Signs machines' upgrade packages; a machine remembers its public key the first time it connects | Leaked: generate a new one; every machine trusts it once more |

`release keygen` prints the public key; note it down — it is the one you will see on the machines.

With `release-key` set, every release package the hub builds also needs the programs whose versions `release.json` pins (Codex, tmux and so on); without them it refuses to build the package (422). Have them ready first, as in "Programs a release package needs" at the end of [§1.3](#13-required-settings).

> Today the signing key lives in the hub. It will change to "the signing key exists only in the release pipeline, with an offline root key that can revoke it"; this section will be updated then.

### 1.3 Required settings

The hub reads only environment variables. A minimal working set:

| Key | Example | Notes |
|---|---|---|
| `CCQUOTA_FLEET` | `1` | Turns the fleet features on |
| `CCQUOTA_FLEET_PUBLIC_URL` | `https://hub.example.com` | The hub's public address, used by machines and clients |
| `CCQUOTA_PUBLIC_URL` | `https://hub.example.com` | The same, for sign-in redirects |
| `CCQUOTA_GITHUB_ADMINS` | `alice` | Admins' GitHub usernames, comma-separated |
| `CCQUOTA_ADMINS` | `alice@example.com` | Admins who do not use GitHub: email addresses, comma-separated. **Use an address you really receive mail at** — the first admin gets in with the code sent there; left on the `example.com` placeholder, the hub says so and refuses to start |
| `CCQUOTA_FLEET_ADMIN_USERS` | `alice` | The system login name of the administrator account on the machines: the hub sends account creation and removal only to a machine program running as it |
| `CCQUOTA_VIEWER_TOKEN` | the contents of `viewer-token` | The read-only password of the usage page |
| `CCQUOTA_FLEET_SSH_CA_KEY` | `/secrets/ca` | Path of the connection certificate key |
| `CCQUOTA_FLEET_CRED_KEY_FILE` | `/secrets/cred-key` | Path of the credential vault key |
| `CCQUOTA_FLEET_RELEASE_KEY` | `/secrets/release-key` | Path of the upgrade package signing key; unset, machines do not upgrade automatically |
| `CCQUOTA_FLEET_RELEASE_DIR` | `/data/releases` | Where upgrade packages go; required once the signing key is set |
| `CCQUOTA_FLEET_RELEASE_ARTIFACTS` | `/data/release-artifacts` | The directory holding the programs a release package needs; required once the signing key is set, see "Programs a release package needs" below |
| `CCQUOTA_FLEET_RELEASE_PLATFORMS` | `darwin-arm64 linux-amd64` | Which systems / architectures your machines are, space-separated; unset, only `darwin-arm64` is prepared |
| `CCQUOTA_FLEET_OAUTH_REFRESH_VIA` | `node` | Machines renew the subscriptions' sign-ins; the hub itself never contacts the subscription provider |

Optional:

| Key | Notes |
|---|---|
| `CCQUOTA_DB_URL` | Postgres instead of SQLite: `postgres://user:password@host:5432/db?sslmode=require` |
| `CCQUOTA_FLEET_UPSTREAM_HUB` | Follow another hub's releases (the official hub, say) instead of GitHub; set together with `CCQUOTA_FLEET_RELEASE_DIR` and `CCQUOTA_FLEET_RELEASE_ROOT`. See [§4.3](#43-choosing-which-version-to-follow) |
| `CCQUOTA_FLEET_STABLE_REPO` | Whose `stable` to look up on GitHub; **GitHub is asked only when this is set**. See [§4.3](#43-choosing-which-version-to-follow) |
| `CCQUOTA_FLEET_CRED_RELAY_URL` | A relay the subscription traffic goes through (only needed where the subscription provider does not serve your region, for example mainland China); unset, it connects directly. How to set up the relay: [§1.8](#18-deploying-in-mainland-china) |
| `CCQUOTA_FLEET_PUBLISH_TOKEN` | The password (a secret) that allows pushing `stable` to the hub. Once pushed to, the hub no longer asks GitHub for `stable`; useful for a hub in mainland China, see [§4.4](#44-when-the-hub-cannot-reach-github) |
| `CCQUOTA_METER_ORIGINS` | Web origins allowed to read usage; unset, none |

At start-up the hub prints one line, "未配置 &lt;key&gt;" (not configured), for every address key left unset; fill them in from those lines.

#### Programs a release package needs

Everything a machine installs when it upgrades comes from the hub's release package: `fleet` itself, `ccquota`, and the Claude Code, Codex and tmux whose versions `release.json` at the repository's root pins. `ccquota` is in your image already; the rest go into the directory `CCQUOTA_FLEET_RELEASE_ARTIFACTS` names, each file named `<name>-<version>-<system>-<arch>`, for example `codex-0.162.1-darwin-arm64`, `tmux-3.7c-linux-amd64` (Codex also needs a `codex-code-mode-host-…` of the same version). When Claude Code is missing the hub fetches it from npm by itself (the registry is `CCQUOTA_FLEET_RELEASE_NPM`).

With one missing, the hub refuses to build that version's package; the error names the missing files and the command below. There are two sources; pick one:

- **Fetch them from another hub**: when you know a hub that already has this version's release package (another hub of the same team, or one the publisher of the `stable` you follow gave you). There is **no** official public hub; without such an address, go straight to "Put them in place yourself" below.
- **Put them in place yourself**: from Codex's and tmux's own official releases, as in the last part of this section.

##### Fetch them from another hub

That hub serves every file publicly at `/v1/fleet/release/<commit>/artifacts/<name>`, and its signed manifest lists each file's size and sha256. The command below checks the manifest's signature against that hub's public key first, then each sha256, and puts a file in the directory only when it matches:

```sh
UP=https://upstream.example.com                     # the hub you know; with none, skip to "Put them in place yourself"
SHA=$(git rev-parse stable)                         # the commit §1.1 built the image from
curl -fsS $UP/v1/fleet/release/key > upstream-release.pub   # its release public key; check it with the publisher once
python3 bin/fleet-release-fetch.py --hub $UP --pubkey upstream-release.pub \
  --artifacts --platforms "darwin-arm64 linux-amd64" $SHA /srv/fleet/data/release-artifacts
```

- One line per file: `got <name>` just fetched, `kept <name>` already there and unchanged. A wrong file is replaced; a signature or sha256 that does not match refuses the whole run and writes nothing.
- The directory is `/data/release-artifacts` inside the hub's container (under §1.5's data volume); on Kubernetes it sits on the data volume too. After §1.5 the data volume belongs to uid 10001, so running this again needs `sudo`, followed by `sudo chown -R 10001 /srv/fleet/data/release-artifacts`.
- Give `--platforms` the same set as `CCQUOTA_FLEET_RELEASE_PLATFORMS`.
- Run it again before every upgrade (when `stable` moves to another commit); it fetches only the new version's files.
- Once they are in place, `curl -fsS https://hub.example.com/v1/fleet/release/artifacts` lists what the hub now has.

##### Put them in place yourself

For when there is no upstream hub. Run this in the repository copy §1.1 built the image from (`git checkout stable`, with `bin/fleet-client-pack.sh` already run); every version is read from `release.json`:

| Artifact | Where it comes from | How it becomes the file in the directory |
|---|---|---|
| `codex-<version>-<system>-<arch>` | `codex-<triple>.tar.gz` on Codex's official release page `github.com/openai/codex/releases/tag/rust-v<version>` | Unpack it; it holds one file, `codex-<triple>`; rename that |
| `codex-code-mode-host-<version>-<system>-<arch>` | `codex-code-mode-host-<triple>.tar.gz` on the same page | The same: unpack `codex-code-mode-host-<triple>` and rename it |
| `tmux-<version>-<system>-<arch>` | §1.1's `fleet-client-pack.sh` has already downloaded it by `conf/vendor-tmux.lock` and checked its sha256, at `tokenledger/hub/api/fleetclient/pack/vendor/tmux-<platform>` | Copy it under the new name; no build of your own |
| `claude-<version>-<system>-<arch>` | Nothing to put in place: the hub fetches it from npm itself | — |

How a system / architecture maps to the names on each side (Codex's musl builds: statically linked, they run on any Linux):

| `<system>-<arch>` | Codex's `<triple>` | tmux's `<platform>` |
|---|---|---|
| `darwin-arm64` | `aarch64-apple-darwin` | `macos-arm64` |
| `darwin-amd64` | `x86_64-apple-darwin` | `macos-x86_64` |
| `linux-amd64` | `x86_64-unknown-linux-musl` | `linux-x86_64` |
| `linux-arm64` | `aarch64-unknown-linux-musl` | `linux-arm64` |

All in one go (keep only the lines for what is in your `CCQUOTA_FLEET_RELEASE_PLATFORMS`; downloads from GitHub often break off in mainland China, and `--retry` retries by itself):

```sh
A=/srv/fleet/data/release-artifacts                 # /data/release-artifacts inside the hub's container
v() { python3 -c 'import json,sys;print(json.load(open("release.json"))["components"][sys.argv[1]]["version"])' "$1"; }
CX=$(v codex) TM=$(v tmux) T=$(mktemp -d)
mkdir -p "$A"
while read -r plat triple tplat; do
  for n in codex codex-code-mode-host; do
    curl -fL --retry 8 --retry-delay 5 --retry-all-errors -o "$T/$n.tar.gz" \
      "https://github.com/openai/codex/releases/download/rust-v$CX/$n-$triple.tar.gz" &&
    tar xzf "$T/$n.tar.gz" -C "$T" && install -m 0755 "$T/$n-$triple" "$A/$n-$CX-$plat" || echo "failed: $n $plat"
  done
  install -m 0755 "tokenledger/hub/api/fleetclient/pack/vendor/tmux-$tplat" "$A/tmux-$TM-$plat" || echo "failed: tmux $plat"
done <<'EOF'
darwin-arm64 aarch64-apple-darwin      macos-arm64
linux-amd64  x86_64-unknown-linux-musl linux-x86_64
EOF
rm -rf "$T"; ls -l "$A"
```

- A `failed: …` line means that one file is not in place; run the block again (files already in place are overwritten with the same ones).
- A platform's tmux missing from `pack/vendor/`: `fleet-client-pack.sh` failed to download that one; run it again (it goes to GitHub too).
- Once they are in place, `curl -fsS https://hub.example.com/v1/fleet/release/artifacts` should list three for each of your platforms (`codex` · `codex-code-mode-host` · `tmux`), and the hub can sign and build this version's package. Before every upgrade ([§4.2](#42-how-an-upgrade-goes)), run it again when the versions in `release.json` have changed.

These two tables, and §1.4's keys, are registered in the repository's settings list `conf/fleet.conf.reference`, in the "The hub's own settings" section at the end (the address keys in the section above it), one line per key: what it is for, whether it is required, whether it is a secret. Where this page and that list differ, the list wins.

### 1.4 Sign-in methods

Configure at least one; the sign-in page offers as many as you configure (always in the order WeChat, email, GitHub). **Secret values live only in environment variables or a Kubernetes Secret.**

| Method | Keys | Where to get them |
|---|---|---|
| GitHub | `CCQUOTA_GITHUB_CLIENT_ID` · `CCQUOTA_GITHUB_CLIENT_SECRET` | GitHub → Settings → Developer settings → OAuth Apps → New, with the callback URL `https://hub.example.com/auth/github/callback` |
| Email | `CCQUOTA_SMTP_URL` (`smtp://user:password@host:587`, or `smtps://…:465`) · `CCQUOTA_SMTP_FROM` | Any SMTP that can send, for example a cloud provider's mail service |
| WeChat (scan on a computer) | `CCQUOTA_WECHAT_WEB_APPID` · `CCQUOTA_WECHAT_WEB_SECRET` | A "website app" on the WeChat Open Platform (it goes through review) |
| WeChat (opened inside WeChat) | `CCQUOTA_WECHAT_MP_APPID` · `CCQUOTA_WECHAT_MP_SECRET` | A service account's web authorization |
| Without GitHub | `CCQUOTA_SESSION_SECRET` | Generate it yourself: `openssl rand -hex 32` |

Each pair must be complete: with only half of one, the hub refuses to start. An email setting that does not work only logs a line; everything else carries on.

Apart from the people listed as admins above, **everyone needs an invite to get in** ([§3.1](#31-creating-accounts-for-members)).

### 1.5 Option one: a single container

For one Linux server. The hub listens only on the machine itself, and a reverse proxy (Caddy, nginx) takes HTTPS to `127.0.0.1:8787`. On a new server without one, Caddy is the least work and gets its own certificate: `sudo apt install caddy` on Ubuntu / Debian — apt's 2.6 is enough for the hub (only [§1.8](#18-deploying-in-mainland-china)'s relay needs 2.10 or later).

```sh
sudo mkdir -p /srv/fleet/data/release-artifacts && sudo chown -R 10001 /srv/fleet/data   # the image runs as uid 10001
sudo cp ~/fleet-secrets/{ca,cred-key,release-key} /srv/fleet/ && sudo chown 10001 /srv/fleet/{ca,cred-key,release-key}

cat > /srv/fleet/hub.env <<'EOF'
CCQUOTA_FLEET=1
CCQUOTA_FLEET_PUBLIC_URL=https://hub.example.com
CCQUOTA_PUBLIC_URL=https://hub.example.com
CCQUOTA_GITHUB_ADMINS=alice
CCQUOTA_FLEET_ADMIN_USERS=alice
CCQUOTA_FLEET_SSH_CA_KEY=/secrets/ca
CCQUOTA_FLEET_CRED_KEY_FILE=/secrets/cred-key
CCQUOTA_FLEET_RELEASE_KEY=/secrets/release-key
CCQUOTA_FLEET_RELEASE_DIR=/data/releases
CCQUOTA_FLEET_RELEASE_ARTIFACTS=/data/release-artifacts
CCQUOTA_FLEET_RELEASE_PLATFORMS=darwin-arm64 linux-amd64
CCQUOTA_FLEET_OAUTH_REFRESH_VIA=node
EOF
# secret values go in a separate file only root can read
sudo sh -c 'umask 077; cat > /srv/fleet/hub.secret.env' <<EOF
CCQUOTA_VIEWER_TOKEN=$(cat ~/fleet-secrets/viewer-token)
CCQUOTA_GITHUB_CLIENT_ID=<your OAuth app's Client ID>
CCQUOTA_GITHUB_CLIENT_SECRET=<its Client secret>
EOF

docker run -d --name fleet-hub --restart unless-stopped \
  -p 127.0.0.1:8787:8787 \
  -v /srv/fleet/data:/data \
  -v /srv/fleet/ca:/secrets/ca:ro -v /srv/fleet/cred-key:/secrets/cred-key:ro \
  -v /srv/fleet/release-key:/secrets/release-key:ro \
  --env-file /srv/fleet/hub.env --env-file /srv/fleet/hub.secret.env \
  registry.example.com/fleet/ccquota:$TAG --retention-days=60
```

The reverse proxy must allow long connections: machines' control channels and sessions' streamed output stay open for tens of minutes. For Caddy one block is enough:

```
hub.example.com {
	reverse_proxy 127.0.0.1:8787 {
		flush_interval -1
	}
}
```

For Caddy put this block in `/etc/caddy/Caddyfile` and `sudo systemctl reload caddy`. With nginx, turn `proxy_buffering` off, set `proxy_read_timeout` / `proxy_send_timeout` to `3600s` and `client_max_body_size` to `64m`, and forward the WebSocket upgrade headers.

All the data is in `/srv/fleet/data/ccquota.db`. **Never copy this file while the hub is running**; for backups see [§5.1](#51-the-hub).

### 1.6 Option two: Kubernetes

The repository's `deploy/k8s/` is a set of generic manifests: `base/` is two replicas + Postgres with zero-downtime rolling updates; `components/sqlite-single/` swaps that for one replica + a data volume. Your own values go in an overlay in your own **deployment repository**; `base/` is never edited:

```sh
mkdir -p ~/fleet-deploy && cp -r deploy/k8s/base deploy/k8s/components ~/fleet-deploy/
mkdir -p ~/fleet-deploy/overlays && cp -r deploy/k8s/overlays/example ~/fleet-deploy/overlays/mine
```

In `overlays/mine/`, change three files and add one:

- `ingress-hosts.yaml`: your domain and TLS Secret name.
- `deployment-env.yaml`: the addresses and admins from the table in §1.3; without a relay delete the `CCQUOTA_FLEET_CRED_RELAY_URL` entry, and delete `CCQUOTA_METER_ORIGINS` if you do not need it.
- A new `release-key.yaml` (the signing key):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ccquota-hub
spec:
  template:
    spec:
      containers:
        - name: ccquota
          env:
            - name: CCQUOTA_FLEET_RELEASE_KEY
              value: /etc/ccquota-release/key
            - name: CCQUOTA_FLEET_RELEASE_DIR
              value: /data/releases
            - name: CCQUOTA_FLEET_RELEASE_ARTIFACTS
              value: /data/release-artifacts
            - name: CCQUOTA_FLEET_RELEASE_PLATFORMS
              value: darwin-arm64 linux-amd64
          volumeMounts:
            - name: release-key
              mountPath: /etc/ccquota-release
              readOnly: true
      volumes:
        - name: release-key
          secret:
            secretName: ccquota-release-key
            defaultMode: 0440
```

- Replace `kustomization.yaml` whole with the following (one volume + SQLite, recommended for a small team):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: fleet-hub
resources:
  - ../../base
components:
  - ../../components/sqlite-single        # one volume, SQLite; for Postgres delete these two lines
images:
  - name: ccquota
    newName: registry.example.com/fleet/ccquota
    newTag: abc1234                        # the TAG from §1.1
  - name: busybox
    newName: registry.example.com/fleet/busybox
patches:
  - path: deployment-env.yaml
  - path: ingress-hosts.yaml
  - path: release-key.yaml
  # without the "updating" page (deploy/k8s/updating/) remove the annotation that points at it
  - target: {kind: Ingress, name: ccquota-hub}
    patch: |-
      - op: remove
        path: /metadata/annotations/nginx.ingress.kubernetes.io~1default-backend
```

  - For two replicas + Postgres: delete the two `components:` lines; `/data/releases` then has no volume, so mount a small one of its own for `CCQUOTA_FLEET_RELEASE_DIR` and `CCQUOTA_FLEET_RELEASE_ARTIFACTS`.
  - With the "updating" page installed (what a browser sees during the tens of seconds of a release), delete the last entry.
  - The data volume uses the cluster's default storageclass (the one marked `(default)` in `kubectl get storageclass`). For another, add an entry under `patches:`: `target: {kind: PersistentVolumeClaim, name: ccquota-data}`, a JSON patch with `op: add`, `path: /spec/storageClassName`, `value: <your storageclass>`.

The secrets are created by a person and never go into any repository:

```sh
NS=fleet-hub
kubectl create namespace $NS
cd ~/fleet-secrets
kubectl -n $NS create secret generic ccquota-ssh-ca --from-file=ca=./ca
kubectl -n $NS create secret generic ccquota-fleet-cred-key --from-file=key=./cred-key
kubectl -n $NS create secret generic ccquota-release-key --from-file=key=./release-key
kubectl -n $NS create secret generic ccquota \
  --from-literal=viewer-token="$(cat viewer-token)" \
  --from-literal=github-client-id='<Client ID>' --from-literal=github-client-secret='<Client secret>'
# only the Postgres form needs:
kubectl -n $NS create secret generic ccquota-db \
  --from-literal=db-url='postgres://…?sslmode=require' --from-literal=replica-token="$(openssl rand -hex 32)"
```

The sign-in keys in `deployment-env.yaml`'s `env:` reference the `ccquota` Secret, never a value:

```yaml
            - name: CCQUOTA_GITHUB_CLIENT_ID
              valueFrom: {secretKeyRef: {name: ccquota, key: github-client-id}}
            - name: CCQUOTA_GITHUB_CLIENT_SECRET
              valueFrom: {secretKeyRef: {name: ccquota, key: github-client-secret}}
```

Then:

```sh
kubectl kustomize ~/fleet-deploy/overlays/mine > /tmp/hub.yaml   # look at the rendered result first
kubectl apply -f /tmp/hub.yaml
kubectl -n $NS rollout status deploy/ccquota-hub
```

The SQLite form must be one replica with `Recreate`: two processes writing one file corrupt the database.

### 1.7 Check the hub

```sh
curl -fsS https://hub.example.com/healthz          # ok
curl -fsS https://hub.example.com/version          # the image version, stable's commit
curl -sS  https://hub.example.com/install | head -1 # #!/bin/sh — the client install script
```

- `/install` answers with a sentence starting `# ` (HTTP 503) instead of a script: the hub cannot hand out the client yet, and the sentence says why — no sign-in method configured yet ([§1.4](#14-sign-in-methods)), or no `CCQUOTA_FLEET_SSH_CA_KEY`. Add it and restart the hub. The start-up log carries the same sentence (`fleet: /install is off: …`).
- `/version` has no `stable` but a `stable_problem`: the hub cannot ask GitHub for `stable`; the sentence gives the reason and the way out, see [§4.4](#44-when-the-hub-cannot-reach-github).
- It opens from inside the cloud's network, but `curl` from outside gets `Connection reset`, or HTTP answers with the cloud provider's "Non-compliance ICP Filing" page or similar: the hub is in a mainland China data centre and its domain has no ICP filing, so the provider blocks it by SNI (another port makes no difference); see the first row of [§1.8](#18-deploying-in-mainland-china).

Then open `https://hub.example.com` in a browser and sign in as one of the admins listed in §1.3: a self-hosted hub opens straight onto the console (there is no website front page). Signed out, a browser is taken to `/app/signin`; a non-browser request such as `curl` gets HTTP 401 and `{"error":"a viewer token is required"}` for `/` — that is expected, not a broken hub.

If it does not start, read the container's log (`docker logs fleet-hub` / `kubectl -n $NS logs deploy/ccquota-hub`): a missing key, or a sign-in method only half configured, is named on the first screen, key and all.

### 1.8 Deploying in mainland China

With the hub and machines in mainland China, a few places take one more step:

| What | Why | How |
|---|---|---|
| The hub's domain | Mainland data centres block a domain without an ICP filing by SNI: from outside, 443 (or any other port) gets only a reset and HTTP gets the provider's "not filed" page, while the cloud's internal network works | With the hub in a mainland data centre, the domain must already have an ICP filing and be connected to that cloud (Alibaba Cloud calls it 接入备案; a filing made with another provider must be connected again); if you cannot, put the hub in a data centre outside the mainland or in Hong Kong / Macau, and keep the machines in the mainland as before |
| Base images for the build | Docker Hub (`golang`, `alpine`) often cannot be pulled directly | Set `"registry-mirrors"` (your cloud provider's mirror) in the build machine's `/etc/docker/daemon.json`, `sudo systemctl restart docker`, then build |
| Go dependencies for the build | The official proxy often stalls when reached directly | Already through `goproxy.cn` by default ([§1.1](#11-build-the-image)) |
| Which commit `stable` is | The hub's anonymous questions to GitHub get rate-limited | Push `stable` to the hub ([§4.4](#44-when-the-hub-cannot-reach-github)) |
| The programs a release package needs | You have no Codex or tmux artifacts of your own | Fetch them from a hub that has this version ([§1.3](#13-required-settings), "Programs a release package needs") |
| Claude Code in the release package | By default the hub fetches it from registry.npmjs.org first | Give the hub `CCQUOTA_FLEET_RELEASE_NPM="https://registry.npmmirror.com https://registry.npmjs.org"` to try the mainland mirror first (every package is checked by its sha512) |
| Subscription traffic | Claude and ChatGPT do not serve mainland China | Set up a **relay** abroad; the hub and the machines both go out through it (below) |

The relay is a small Linux server abroad (Debian / Ubuntu, `python3`, systemd, Caddy 2.10 or later). It stores no credentials and does two things only: it lets a request through on a **pass** the hub issued, then forwards the request unchanged to the subscription provider. Whether to let it through is asked of the hub every time (through a checking process on the relay itself, which remembers the passes it just let through for the few minutes a hub restart takes).

Below, `relay.example.com` stands for the relay's domain and `hub.example.com` for the hub.

**1. On the relay: install the checking process first.** The files are all in the repository's `extras/cred-relay/`:

```sh
# on the relay, in a copy of the repository
sudo install -D -m 0755 extras/cred-relay/fleet-relay-check.py /usr/local/lib/fleet-relay/fleet-relay-check.py
sudo install -m 0644 bin/fleet_ed25519.py /usr/local/lib/fleet-relay/fleet_ed25519.py
sudo install -m 0644 extras/cred-relay/fleet-relay-check.service /etc/systemd/system/
sudo systemctl edit fleet-relay-check        # two lines: [Service] and Environment=FLEET_HUB_URL=https://hub.example.com
sudo systemctl daemon-reload && sudo systemctl enable --now fleet-relay-check
curl -s http://127.0.0.1:2091/healthz        # ok
```

**2. On the relay: then the Caddy site.** Not the other way round: a Caddy that starts first asks a checking process that does not exist yet, and refuses every request.

```sh
sudo cp extras/cred-relay/Caddyfile /etc/caddy/Caddyfile
sudo systemctl edit caddy                    # two lines: [Service] and Environment=FLEET_RELAY_SITE=relay.example.com
sudo -u caddy caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

Validate as the `caddy` user: validating as root creates log files owned by root, and caddy then fails to start. Firewall: 80 and 443 open to everyone (the pass is the gate; 80 is only for the certificate), 22 only to you.

**3. On the hub: turn the relay on.** In [§1.2](#12-generate-the-keys)'s directory, generate two more keys:

```sh
cd ~/fleet-secrets && umask 077
openssl rand -base64 32 > session-cred-key   # the hub signs relay passes for itself and for sessions
openssl rand -base64 32 > relay-sign-key     # signs machines' relay passes, valid for 4 hours
```

Give the hub these keys (mount the key files as in §1.5 / §1.6, never write the values):

| Key | Value | Notes |
|---|---|---|
| `CCQUOTA_FLEET_CRED_RELAY_URL` | `https://relay.example.com` | The relay's address |
| `CCQUOTA_FLEET_SESSION_CRED_KEY_FILE` | `/secrets/session-cred-key` | A secret |
| `CCQUOTA_FLEET_RELAY_SIGN_KEY_FILE` | `/secrets/relay-sign-key` | A secret; it works without it too, but passes then never expire |
| `CCQUOTA_FLEET_OAUTH_REFRESH_VIA` | `relay` | The hub renews the subscriptions' sign-ins through the relay (instead of §1.3's `node`) |
| `CCQUOTA_GITHUB_OAUTH_VIA` | `relay` | Set only when you sign in with GitHub and the hub cannot reach github.com |

With `…_VIA=relay` set but the relay address or `SESSION_CRED_KEY` missing, the hub refuses to start and names the one missing. Upgrade the relay first, then deploy the hub.

**4. Machines: go out through the relay.** A machine gets relay passes only once the hub marks it **trusted**; every login that runs sessions needs the relay's address (`FLEET_CRED_RELAY_URL=https://relay.example.com`). How to bring it along when you add a machine: [§2](#2-add-machines).

**5. Acceptance.** No credentials needed:

```sh
curl -s https://relay.example.com/healthz                                                         # ok
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://relay.example.com/anthropic/v1/messages   # 403: no pass
curl -s -o /dev/null -w '%{http_code}\n' https://relay.example.com/v1/models                       # 404: not an open proxy
```

On the relay, `sudo grep -rEc 'sk-ant-|eyJhbGci|Bearer ' /var/log/caddy/ /etc/caddy/` should give 0 everywhere: the logs record only the path prefix, the status and the byte count.

Whoever manages the hub and the relay can follow the repository's `plugins/fleet-infra/skills/sg-relay-setup/SKILL.md` step by step (moving, revoking and rolling back are in it too).

## 2. Add machines

Sessions run on machines ("service nodes" in the console). Each machine has a card on the hub, and the hub places new sessions where there is room.

### 2.1 Mac

1. Console → **Service nodes & clients** → **Add service node**, and give it a name (for example `mac-a`). The page gives a one-line command containing a one-time join code, **valid for one hour**.
2. On that Mac, open a terminal as the administrator account and paste the line. It looks like:

   ```sh
   curl -fsSL https://hub.example.com/install/bin/fleet-node-install.sh | sudo bash -s -- --hub https://hub.example.com --join <join-code>
   ```

3. It prints one line per step: 检查 · 加入 · 发布公钥 · 期望状态 · ccquota · 运行时 · 机器钥匙 · 角色用户 · ssh CA · 删号通道 · 核心 · 守护 · 入口 (check · join · publish the public key · expected state · ccquota · runtime · machine key · role user · ssh CA · account-removal channel · core · daemon · hub). Each line is `✓`, `跳过` (skipped: already in place) or `✗` (failed; the next line says how to run it again). The last line is `已收敛` (converged).
4. `mac-a` appears on the **Service nodes & clients** page, and the dialog says it has joined fleet.

Requirements: macOS's own `/usr/bin/python3` (if missing, run `xcode-select --install` first), `curl`, administrator rights.

**Removing accounts needs one more permission**: System Settings → General → Sharing → Remote Login → ⓘ → turn on "Allow full disk access for remote users". The install's 删号通道 (account-removal channel) line reminds you; without it creating accounts works but removing them cannot.

### 2.2 Linux

A Linux machine needs **one** join code from joining to its first account:

1. **Install the dependencies.** Requirements: Debian 12 or Ubuntu (with systemd), Python 3.9 or later, and `curl` `git` `zsh` `openssh-server` `sudo`. On Debian / Ubuntu, all at once:

   ```sh
   sudo apt-get install -y python3 curl git zsh openssh-server sudo
   ```

2. **Get a join code**: Console → **Service nodes & clients** → **Add service node**, and give it a name (for example `linux-a`). The page gives a one-line command; the one-time join code is **valid for one hour**.
3. **Join**: paste that line on the Linux machine as an account that can `sudo`:

   ```sh
   curl -fsSL https://hub.example.com/install/bin/fleet-node-install.sh | sudo bash -s -- --hub https://hub.example.com --join <join-code>
   ```

   It prints one line per step as on a Mac (Linux has two more, 开号 (account creation) and 中转 (relay), and no 删号通道). This machine has no account yet, so the last line is **not** `已收敛` (converged) but:

   ```text
   已加入，还没有账号：这台（linux-a）的节点程序在等入口派第一个号。下一步在入口做——
     控制台「使用者」→ 生成邀请命令（设置「新使用者在哪些服务节点上开登录名」写 linux-a），或
     fleet hub accounts assign <身份 id> --host linux-a
     开号在这台上由节点程序自己做；账号开出来之前，这台不跑任何会话。
   ```

   (Joined, no account yet: this machine's node program is waiting for the hub to send its first account. The next step is on the hub — Console **Users** → **Invite command**, with the setting for which service nodes new users get a login on set to `linux-a`; or `fleet hub accounts assign <identity id> --host linux-a`. The node program creates the account on this machine itself; until it exists, this machine runs no session.)

4. **Create the first account**: follow those lines ([Creating and removing accounts](../admin/accounts.md)). The hub sends the account creation to this machine, its node program creates the account itself, and the console shows queued → being created → done, usually within a minute or two. Then run step 3's command again and the last line is `已收敛`.

**The relay**: when the hub has `CCQUOTA_FLEET_CRED_RELAY_URL` set ([§1.3](#13-required-settings)), it hands the address to the machine as it joins, and every account later created on it goes through the relay with nothing written by hand on the machine. If the hub got its relay after the machine joined, run step 3's command again on the machine (no new join code needed): the 中转 line writes it into the existing accounts. Without a relay on the hub, that line does not appear.

The installer sets directories to 0755 and files to 0644 itself, whatever your shell's `umask`. The runtime is installed in `/opt/claude-fleet`, and the daemon is `claude-fleet-node.service`:

```sh
systemctl status claude-fleet-node.service
```

### 2.3 Checking and repairing

On the machine:

```sh
fleet doctor --machine
```

One line per part, PASS / WARN / FAIL; the exit code is the number of FAILs, and 0 means all is well.

**Repairing is running the same command again**: steps already in place print `跳过` (skipped) and only the missing ones are done; while the hub still accepts the machine, no new join code is used up. If the join code has expired, get another from the console.

### 2.4 Maintenance and removal

- **Maintenance**: machine card → **Maintenance** → start maintenance. New sessions are no longer placed on it, and running ones carry on to the end; when it is fixed, **End maintenance**. Put a machine in maintenance before shutting it down or taking it offline.
- **Removal**: machine card → **Remove**. The hub revokes the machine's key and places no more sessions on it; what is installed on the machine stays, and to join again you run §2.1 / §2.2 once more.

## 3. Members and clients

### 3.1 Creating accounts for members

- **Console**: **Users** → **Invite command**. With a GitHub username filled in, the invite is for that person only; left empty, it is for the first person to use it.
- **Command line** (on a signed-in client):

  ```sh
  fleet hub invite            # prints one install line to send a new colleague; once they install it, they are in
  fleet hub accounts          # each person and the machines they have an account on
  ```

Creating an account (a system account for the person on some machine) is sent by the hub to the machine to do; the console shows it queued → being created → done.

### 3.2 Installing the client

Every member, on their own computer (macOS, Linux, or WSL on Windows):

```sh
curl -fsSL https://hub.example.com/install | sh
```

- It installs to `~/.local/bin/fleet` and brings its own tmux. It opens `fleet` straight away when installed.
- The first time it asks you to sign in: a browser opens the hub's sign-in page (or the terminal shows a QR code); sign in the way the hub offers and choose **Confirm**. A connection certificate lasts 12 hours and renews itself.
- For this computer to run sessions too, add `--host`: `curl -fsSL https://hub.example.com/install | sh -s -- --host`.

To check:

```sh
fleet doctor     # the "fleet" row: version, hub, tmux, certificate
fleet update     # the version this computer runs and the stable it follows
```

How members use it from there: [Member · Quickstart](../member/quickstart.md) and [Everyday use](../member/usage.md).

## 4. Upgrading

### 4.1 What stable is

Every part of fleet — the hub, the machines, the clients — follows the same version: the tag called `stable` in the repository. `stable` moves forward only after a commit has passed every check (the tests on both Linux and macOS, and the replay check before a release), so it is the version "fit to give to other people", not the latest commit.

```sh
fleet update stable      # the stable commit your hub reports
curl -fsS https://hub.example.com/version
```

### 4.2 How an upgrade goes

1. **The hub goes first.** Build the image from the new `stable` as in [§1.1](#11-build-the-image), take a database snapshot as in [§5.1](#51-the-hub), then switch the tag:
   - Single container: `docker pull` the new image, `docker rm -f fleet-hub`, and run §1.5's `docker run` again with the new tag.
   - Kubernetes: change `newTag` in `overlays/mine/kustomization.yaml` and `kubectl apply`.
2. **Machines follow by themselves.** Once the hub has switched, it signs the new version and tells every machine; machines also ask every 5 minutes. An upgrade is: download, verify the signature, switch as a whole, check itself 30 seconds later — and one more FAIL than before switches it back to the previous version automatically.
3. **Clients follow by themselves.** Every time `fleet` opens (at most once an hour) it asks the hub, prepares the new version in the background and switches when idle; when it only takes effect after a reopen, the top says so ("ready · takes effect next time").

Until the hub's image changes, machines stay on the old version and never wander: the hub signs only a version built from the same source as itself.

To see who is behind (on a machine):

```sh
fleet doctor --installs   # every install on this machine vs stable; more than 30 minutes behind is a WARN
```

### 4.3 Choosing which version to follow

The version a hub hands its machines and clients comes from the first of these that has one:

1. **A release pushed to the hub**: by the release train (or by you, with `bin/fleet-release-publish.sh` — see [§4.4](#44-when-the-hub-cannot-reach-github)). Once pushed to, the hub trusts only what is pushed.
2. **An upstream hub**: with `CCQUOTA_FLEET_UPSTREAM_HUB` set, the hub takes that hub's signed releases, keeps each whole (manifest, signature, runtime, programs) in its own release store and hands them to its own machines. GitHub is not involved.
3. **GitHub**: only with `CCQUOTA_FLEET_STABLE_REPO=<org>/<repo>` set does the hub ask GitHub for that repository's `stable`.
4. **The image**: none of the above — only the client built into the image is served, and machines do not upgrade automatically.

With nothing set, the hub never asks GitHub. `stable_source` in `curl -fsS https://hub.example.com/version` says which one is in use right now: `release` · `upstream` · `github` · `image`.

**Following the official hub** (the least work, and unaffected when GitHub is down):

```
CCQUOTA_FLEET_UPSTREAM_HUB=https://official-hub
CCQUOTA_FLEET_RELEASE_DIR=/data/releases
CCQUOTA_FLEET_RELEASE_ROOT=ed25519 <the line at the official hub's /v1/fleet/release/key>
```

Copy `CCQUOTA_FLEET_RELEASE_ROOT` once (`curl -fsS https://official-hub/v1/fleet/release/key`): the hub checks every release the upstream hands it against this key and refuses one whose signature does not match — `stable_problem` says why. Such a hub signs nothing itself, so leave `CCQUOTA_FLEET_RELEASE_KEY` unset. The hub looks at the upstream when someone reads `/version` (at most once every 5 minutes), follows it forward, and never goes back.

**Gating it yourself**: fork the repository, move the `stable` tag on your fork (only ever to commits you have checked), and give the hub

```
CCQUOTA_FLEET_STABLE_REPO=<your-org>/claude-fleet
```

or leave it unset and push each commit you have checked to the hub yourself (step 2 of [§4.4](#44-when-the-hub-cannot-reach-github)).

### 4.4 When the hub cannot reach GitHub

A hub with `CCQUOTA_FLEET_STABLE_REPO` set that has never been pushed `stable` asks `api.github.com` anonymously every 5 minutes: "which commit is `stable` now". With the hub in mainland China its outgoing address is often shared by many people, and GitHub's allowance for anonymous requests (60 an hour) is soon spent; it answers 403. Then:

- `curl -fsS https://hub.example.com/version` has no `stable`, and `stable_problem` says "GitHub rate-limited …";
- the hub's log has one line every 5 minutes: `fleet: stable lookup: … HTTP 403 … — GitHub rate-limited this hub's anonymous stable lookup`.

The way out is to **push `stable` to the hub**: once pushed to, the hub trusts only what is pushed and never asks GitHub again:

1. Generate a password (`openssl rand -hex 32`), put it in the hub's secrets as `CCQUOTA_FLEET_PUBLISH_TOKEN` (`hub.secret.env` for a single container, the Secret on Kubernetes), and restart the hub.
2. Push from a repository copy that can reach the hub:

   ```sh
   cd claude-fleet && git fetch origin --tags && git checkout stable
   read -rs FLEET_PUBLISH_TOKEN && export FLEET_PUBLISH_TOKEN      # paste the same password; it is not echoed
   bin/fleet-release-publish.sh $(git rev-parse HEAD) --hub https://hub.example.com
   ```

   The hub checks the commit and the files itself and need not trust this computer; pushing the same commit again answers `already`.
3. `stable` in `curl -fsS https://hub.example.com/version` is now this commit, and `stable_problem` is gone.

For every later upgrade ([§4.2](#42-how-an-upgrade-goes)), push the new commit as in step 2. The password is read only from the environment: never put it on a command line or commit it to a repository.

## 5. Rolling back

### 5.1 The hub

**Take a snapshot before every image change.** The database runs in WAL mode, so copying it while it runs gives a broken file; use SQLite's `VACUUM INTO`:

```sh
# single container: with sqlite3 (3.27 or later) on the host
sqlite3 /srv/fleet/data/ccquota.db "VACUUM INTO '/srv/fleet/data/backup-$(date -u +%Y%m%dT%H%M%SZ).db'"
```

For the Postgres form use the database's own backups (a cloud database's automatic backups, or `pg_dump`).

To check a new image before switching, run its self-check against a copy of the snapshot — it exits when done, listens on no port and never touches the live database:

```sh
cp /srv/fleet/data/backup-<time>.db /tmp/check.db && chown 10001 /tmp/check.db
docker run --rm -v /tmp/check.db:/data/check.db -v /srv/fleet/ca:/secrets/ca:ro \
  -v /srv/fleet/cred-key:/secrets/cred-key:ro -v /srv/fleet/release-key:/secrets/release-key:ro \
  --env-file /srv/fleet/hub.env --env-file /srv/fleet/hub.secret.env \
  -e CCQUOTA_FLEET_RELEASE_DIR=/tmp/releases \
  --entrypoint ccquota registry.example.com/fleet/ccquota:<new-tag> hub --check --db /data/check.db
```

Switch only on exit code 0.

**Rolling back** = switching back to the old tag (single container: run `docker run` again with the old tag; Kubernetes: put `newTag` back and `apply`). If the new version has already changed the database schema (the upgrade log shows a migration), the old image cannot read the new database, and the snapshot has to go back too:

```sh
docker stop fleet-hub
mv /srv/fleet/data/ccquota.db /srv/fleet/data/ccquota.db.bad
cp /srv/fleet/data/backup-<time>.db /srv/fleet/data/ccquota.db && chown 10001 /srv/fleet/data/ccquota.db
rm -f /srv/fleet/data/ccquota.db-wal /srv/fleet/data/ccquota.db-shm
# then run §1.5's docker run again with the old tag
```

Whatever happened in the hub after the snapshot (new sign-ins, new session records) goes back in time with it. The same for the Kubernetes SQLite form: first `kubectl -n $NS scale deploy/ccquota-hub --replicas=0`, swap the file on the data volume, then scale back to 1.

### 5.2 Machines

Automatic: every machine keeps the previous version, switches itself back when the check after a switch finds a new FAIL, and skips that version. Once the hub goes back to an older image, machines follow the version the hub signs; no machine needs handling one by one.

### 5.3 Clients

Usually nothing to do: they follow the hub. If you really must go back to the previous version by hand:

```sh
ls ~/.claude/fleet.versions/          # one directory per version; .prev records the previous one
ln -sfn ~/.claude/fleet.versions/<previous> ~/.claude/fleet
```

## 6. Uninstalling

- **A member's client**: `fleet quit`, then `fleet logout`; delete `~/.local/bin/fleet`, `~/.claude/fleet`, `~/.claude/fleet.versions`, `~/.local/share/claude-fleet-vendor` (the tmux the install brought), and the PATH line the install added to your shell's configuration file.
- **A machine**: first **Maintenance** in the console and wait for its sessions to finish, then **Remove**. There is no one-command uninstall for the runtime on a machine yet.
- **The hub**: stop the container (`docker rm -f fleet-hub`) or delete the namespace (`kubectl delete namespace fleet-hub`). The data is in `/srv/fleet/data` or on the data volume / in the database; keeping it is your call.

## Next

- Connecting subscriptions, creating accounts, quota, machines: [Admin handbook](../admin/index.md)
- Stuck: [Troubleshooting](../troubleshooting.md)
- Isolation and credentials: [Security and isolation](../security.md)
