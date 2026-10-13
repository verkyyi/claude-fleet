# 安装与部署

这一篇写给自托管团队里负责部署的那个人。照着做完，你会有：

- 一个自己的**入口**（一台 Linux 上的一个容器，或 Kubernetes 里的一组副本），网页控制台也在它上面；
- 接在入口上的**机器**——Mac、Linux 都行，会话在这些机器上跑；
- 每位成员电脑上的**客户端**；
- 一套升级和回滚的办法：所有部分都跟着同一个版本号 `stable` 走。

只有一台电脑、不需要给同事开号的话，不必架入口，照 [自托管 · 快速开始](quickstart.md) 装本机模式即可。

下文例子里的地址、名字都是占位：入口 `https://hub.example.com`、机器 `mac-a` `linux-a`、管理员 `alice`。换成你自己的。

## 0. 准备

| 要什么 | 说明 |
|---|---|
| 一个域名和 HTTPS 证书 | 入口的地址，例如 `hub.example.com`。机器和客户端都只认 HTTPS。 |
| 跑入口的地方 | 一台装了 Docker 的 Linux（单机容器），或一个带 ingress-nginx 的 Kubernetes 集群。入口很小：1 核、1 GB 内存够一个小团队。 |
| 构建镜像的地方 | 一台有 Docker、`git` 的电脑，能拉 Go 依赖。 |
| 至少一种登录方式 | GitHub OAuth 应用、一个能发信的 SMTP（邮箱登录），或微信开放平台的网站应用。见 [§1.4](#14-登录方式)。 |
| 跑会话的机器 | macOS 或 Linux（Debian 12 / Ubuntu，带 systemd），每台有一个能 `sudo` 的管理员账号。 |
| 订阅 | Claude 订阅（Pro / Max / Team）或 ChatGPT 订阅。可以每人自带，也可以由管理员接进入口给大家共用。 |

## 1. 架入口

入口是一个程序：`ccquota hub`，监听一个端口（8787），数据放在一个 SQLite 文件里（也可以换成 Postgres）。

### 1.1 构建镜像

入口的镜像从源码构建，**用 `stable` 那一个提交**——机器的升级包由入口签名，入口只给和它自己同一份源码的版本签名（见 [§4](#4-升级)）。

```sh
git clone https://github.com/verkyyi/claude-fleet.git
cd claude-fleet
git checkout stable
TAG=$(git rev-parse --short HEAD)
bin/fleet-client-pack.sh
docker build --build-arg VERSION=$TAG -t registry.example.com/fleet/ccquota:$TAG tokenledger/
docker push registry.example.com/fleet/ccquota:$TAG
```

- `bin/fleet-client-pack.sh` 把客户端和机器要下载的文件装进镜像；少了这一步 `docker build` 会拒绝。
- `VERSION` 是入口在 `/version` 上报的版本名，用提交号最方便对照。
- 镜像里带着 macOS 与 Linux（amd64 / arm64）机器要下载的程序，构建要几分钟。只在一台机器上跑入口时，镜像推不推仓库都行。
- 构建默认经 `goproxy.cn` 拉 Go 依赖（境内直连官方代理常会卡住）。在境外构建、或不想经过它，加 `--build-arg GOPROXY=https://proxy.golang.org,direct`。

### 1.2 生成钥匙

在一个只有你能读的目录里生成，**这些文件不进任何仓库**：

```sh
mkdir -p ~/fleet-secrets && cd ~/fleet-secrets && umask 077
ssh-keygen -t ed25519 -N '' -C fleet-user-ca -f ca     # 连接证书的签发钥匙：ca + ca.pub
openssl rand -base64 32 > cred-key                      # 订阅凭据保险箱的钥匙
openssl rand -hex 24 > viewer-token                     # 用量页的只读口令
docker run --rm --user "$(id -u)" -v "$PWD:/out" --entrypoint ccquota \
  registry.example.com/fleet/ccquota:$TAG release keygen --out /out/release-key   # 升级包的签名钥匙
```

| 文件 | 用途 | 丢了 / 泄露了 |
|---|---|---|
| `ca` | 给成员和机器签短期连接证书 | 泄露：重新生成，所有人重新登录一次 |
| `cred-key` | 加密入口里存的订阅凭据 | **不要换**：换了以后已存的凭据全部读不出来，要重新接一遍订阅 |
| `viewer-token` | 用量页的只读口令 | 重新生成即可 |
| `release-key` | 给机器的升级包签名；机器第一次连上时记住它的公钥 | 泄露：重新生成，每台机器重新信任一次 |

`release keygen` 会把公钥打印出来，记下它，机器上看到的就是这一个。

设了 `release-key`，入口每打一个发布包，还要有 `release.json` 钉住版本的几个程序（Codex、tmux 等）；没有就拒绝打包（422）。先照 [§1.3](#13-必填配置) 末尾「发布包要的程序」备好。

> 今天签名钥匙放在入口里。以后会改成「签名钥匙只在发版流程里，另有一把离线保存的根钥匙能作废它」，到时这一节会更新。

### 1.3 必填配置

入口只读环境变量。下面是一套最小可用的配置：

| 键 | 例子 | 说明 |
|---|---|---|
| `CCQUOTA_FLEET` | `1` | 打开 fleet 功能 |
| `CCQUOTA_FLEET_PUBLIC_URL` | `https://hub.example.com` | 入口的公开地址，机器和客户端都用它 |
| `CCQUOTA_PUBLIC_URL` | `https://hub.example.com` | 同上，登录回跳用 |
| `CCQUOTA_GITHUB_ADMINS` | `alice` | 管理员的 GitHub 用户名，逗号分隔 |
| `CCQUOTA_ADMINS` | `alice@example.com` | 不用 GitHub 的管理员：邮箱地址，逗号分隔 |
| `CCQUOTA_FLEET_ADMIN_USERS` | `alice` | 机器上那个管理员账号的系统登录名：入口只把「开号」「删号」发给以它运行的机器程序 |
| `CCQUOTA_VIEWER_TOKEN` | `viewer-token` 的内容 | 用量页的只读口令 |
| `CCQUOTA_FLEET_SSH_CA_KEY` | `/secrets/ca` | 连接证书钥匙的路径 |
| `CCQUOTA_FLEET_CRED_KEY_FILE` | `/secrets/cred-key` | 凭据保险箱钥匙的路径 |
| `CCQUOTA_FLEET_RELEASE_KEY` | `/secrets/release-key` | 升级包签名钥匙的路径；不设则机器不会自动升级 |
| `CCQUOTA_FLEET_RELEASE_DIR` | `/data/releases` | 升级包放哪；设了签名钥匙就必须设 |
| `CCQUOTA_FLEET_RELEASE_ARTIFACTS` | `/data/release-artifacts` | 发布包要的程序放在哪个目录；设了签名钥匙就要有，见下面「发布包要的程序」 |
| `CCQUOTA_FLEET_RELEASE_PLATFORMS` | `darwin-arm64 linux-amd64` | 你的机器是哪几种系统 / 架构，空格分隔；不设只备 `darwin-arm64` |
| `CCQUOTA_FLEET_OAUTH_REFRESH_VIA` | `node` | 订阅的登录状态由机器去续，入口自己不连订阅商 |

可选：

| 键 | 说明 |
|---|---|
| `CCQUOTA_DB_URL` | 用 Postgres 而不是 SQLite：`postgres://用户:密码@主机:5432/库?sslmode=require` |
| `CCQUOTA_FLEET_STABLE_REPO` | 跟哪个仓库的 `stable`；不设就跟官方仓库。见 [§4.3](#43-自己决定跟哪一版) |
| `CCQUOTA_FLEET_CRED_RELAY_URL` | 订阅流量经过的中转地址（订阅商不服务你所在地区时才需要，例如在国内）；不设就直连。中转怎么架见 [§1.8](#18-国内部署) |
| `CCQUOTA_FLEET_PUBLISH_TOKEN` | 允许把 `stable` 推给入口的口令（密钥）。推过一次，入口就不再去 GitHub 问 `stable`；入口在国内时用得上，见 [§4.4](#44-入口问不到-github-时) |
| `CCQUOTA_METER_ORIGINS` | 允许读用量的网页来源；不设就没有 |

入口启动时，每个没配的地址类键会打一行「未配置 &lt;键&gt;」，照着补即可。

#### 发布包要的程序

机器升级时装的每一样都来自入口的发布包：`fleet` 本身、`ccquota`，以及仓库根目录 `release.json` 钉住版本的 Claude Code、Codex、tmux。`ccquota` 就在你的镜像里；其余几样要放进 `CCQUOTA_FLEET_RELEASE_ARTIFACTS` 指的目录，文件名是 `<名字>-<版本>-<系统>-<架构>`，例如 `codex-0.162.1-darwin-arm64`、`tmux-3.7c-linux-amd64`（Codex 还要一个同版本的 `codex-code-mode-host-…`）。Claude Code 缺了入口会自己从 npm 拉（源见 `CCQUOTA_FLEET_RELEASE_NPM`）。

缺一个，入口拒绝打这一版的包，报错写着缺哪几个名字和下面这条命令。最省事的来源是**任何一个已经有这一版发布包的入口**（例如你跟随的 `stable` 的发布方）：它在 `/v1/fleet/release/<提交号>/artifacts/<名字>` 公开提供每个文件，并在签了名的清单里写着每个文件的大小和 sha256。下面这条命令先用那个入口的公钥核清单的签名，再逐个核 sha256，对得上才放进目录：

```sh
UP=https://upstream.example.com                     # 已经有这一版发布包的入口
SHA=$(git rev-parse stable)                         # §1.1 构建镜像的那一个提交
curl -fsS $UP/v1/fleet/release/key > upstream-release.pub   # 它的发布公钥，和发布方核对一次
python3 bin/fleet-release-fetch.py --hub $UP --pubkey upstream-release.pub \
  --artifacts --platforms "darwin-arm64 linux-amd64" $SHA /srv/fleet/data/release-artifacts
```

- 每个文件打一行：`got <名字>` 刚取到，`kept <名字>` 已经在、核过没变。不对的文件会被换掉；签名或 sha256 对不上就整条拒绝，什么都不写。
- 目录是入口容器里的 `/data/release-artifacts`（§1.5 的数据盘下面），Kubernetes 上同样放在数据盘上。
- `--platforms` 和 `CCQUOTA_FLEET_RELEASE_PLATFORMS` 写同一组。
- 每次升级前（`stable` 换了提交）再跑一次，只会取新版本的文件。
- 不想从别的入口取，也可以自己按上面的文件名放进去：Codex 来自它的官方发布页，tmux 照仓库的 `conf/vendor-tmux.lock` 构建。放好后 `curl -fsS https://hub.example.com/v1/fleet/release/artifacts` 列出入口现在有哪些。

这两张表和 §1.4 的键都登记在仓库的设置总表 `conf/fleet.conf.reference` 末尾「The hub's own settings」一段（地址类在它上面一段），每键一行：用途、必填与否、是不是密钥。表与它不一致时以它为准。

### 1.4 登录方式

至少配一种，配了几种登录页就给几种（顺序固定：微信、邮箱、GitHub）。**密钥类的值只放在环境变量或 Kubernetes Secret 里**。

| 方式 | 键 | 去哪儿拿 |
|---|---|---|
| GitHub | `CCQUOTA_GITHUB_CLIENT_ID` · `CCQUOTA_GITHUB_CLIENT_SECRET` | GitHub → Settings → Developer settings → OAuth Apps → New，回调地址填 `https://hub.example.com/auth/github/callback` |
| 邮箱 | `CCQUOTA_SMTP_URL`（`smtp://用户:密码@主机:587`，或 `smtps://…:465`）· `CCQUOTA_SMTP_FROM` | 任何能发信的 SMTP，例如云厂商的邮件服务 |
| 微信（电脑扫码） | `CCQUOTA_WECHAT_WEB_APPID` · `CCQUOTA_WECHAT_WEB_SECRET` | 微信开放平台的「网站应用」（要过审核） |
| 微信（微信里打开） | `CCQUOTA_WECHAT_MP_APPID` · `CCQUOTA_WECHAT_MP_SECRET` | 服务号的网页授权 |
| 不用 GitHub 时 | `CCQUOTA_SESSION_SECRET` | 自己生成：`openssl rand -hex 32` |

每一对都要配齐：只配一半，入口拒绝启动。邮箱配置不能用时只记一行日志，其余照常。

除了上面列为管理员的人，**谁都要有邀请才能进来**（[§3.1](#31-给成员开号)）。

### 1.5 方式一：单机容器

适合一台 Linux 服务器。入口只听本机，HTTPS 由你已有的反向代理（Caddy、nginx）接到 `127.0.0.1:8787`：

```sh
mkdir -p /srv/fleet/data && sudo chown 10001 /srv/fleet/data     # 镜像以 uid 10001 运行
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
# 密钥类的值另放一个只有 root 能读的文件
sudo sh -c 'umask 077; cat > /srv/fleet/hub.secret.env' <<EOF
CCQUOTA_VIEWER_TOKEN=$(cat ~/fleet-secrets/viewer-token)
CCQUOTA_GITHUB_CLIENT_ID=<你的 OAuth 应用的 Client ID>
CCQUOTA_GITHUB_CLIENT_SECRET=<它的 Client secret>
EOF

docker run -d --name fleet-hub --restart unless-stopped \
  -p 127.0.0.1:8787:8787 \
  -v /srv/fleet/data:/data \
  -v /srv/fleet/ca:/secrets/ca:ro -v /srv/fleet/cred-key:/secrets/cred-key:ro \
  -v /srv/fleet/release-key:/secrets/release-key:ro \
  --env-file /srv/fleet/hub.env --env-file /srv/fleet/hub.secret.env \
  registry.example.com/fleet/ccquota:$TAG --retention-days=60
```

反向代理要放开长连接：机器的控制通道和会话的流式输出会一连几十分钟。Caddy 一行就够：

```
hub.example.com {
	reverse_proxy 127.0.0.1:8787 {
		flush_interval -1
	}
}
```

nginx 的话关掉 `proxy_buffering`，`proxy_read_timeout` / `proxy_send_timeout` 设到 `3600s`，`client_max_body_size` 设到 `64m`，并转发 WebSocket 升级头。

数据都在 `/srv/fleet/data/ccquota.db`。**不要在入口运行时直接复制这个文件**，备份见 [§5.1](#51-入口)。

### 1.6 方式二：Kubernetes

仓库的 `deploy/k8s/` 是一套通用清单：`base/` 是两副本 + Postgres，零停机滚动发布；`components/sqlite-single/` 换成单副本 + 一块数据盘。你自己的值放在你自己的**部署仓库**里的一个覆盖层，不改 `base/`：

```sh
mkdir -p ~/fleet-deploy && cp -r deploy/k8s/base deploy/k8s/components ~/fleet-deploy/
mkdir -p ~/fleet-deploy/overlays && cp -r deploy/k8s/overlays/example ~/fleet-deploy/overlays/mine
```

在 `overlays/mine/` 里改三个文件、加一个：

- `ingress-hosts.yaml`：你的域名和 TLS Secret 名。
- `deployment-env.yaml`：§1.3 表里的地址和管理员；不要中转就删掉 `CCQUOTA_FLEET_CRED_RELAY_URL` 那一项，不需要 `CCQUOTA_METER_ORIGINS` 也删掉。
- 新建 `release-key.yaml`（签名钥匙）：

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

- `kustomization.yaml` 整个换成下面这样（小团队推荐的一块盘 + SQLite 形态）：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: fleet-hub
resources:
  - ../../base
components:
  - ../../components/sqlite-single        # 一块盘、SQLite；要 Postgres 就删掉这两行
images:
  - name: ccquota
    newName: registry.example.com/fleet/ccquota
    newTag: abc1234                        # §1.1 的 TAG
  - name: busybox
    newName: registry.example.com/fleet/busybox
patches:
  - path: deployment-env.yaml
  - path: ingress-hosts.yaml
  - path: release-key.yaml
  # 没装「正在更新」页（deploy/k8s/updating/）就去掉指向它的注解
  - target: {kind: Ingress, name: ccquota-hub}
    patch: |-
      - op: remove
        path: /metadata/annotations/nginx.ingress.kubernetes.io~1default-backend
```

  - 要两副本 + Postgres：删掉 `components:` 两行；`/data/releases` 那时没有盘，给 `CCQUOTA_FLEET_RELEASE_DIR` 和 `CCQUOTA_FLEET_RELEASE_ARTIFACTS` 另挂一块小盘。
  - 装了「正在更新」页（发布那几十秒里浏览器看到的提示页）就删掉最后一项。
  - 数据盘用集群默认的 storageclass（`kubectl get storageclass` 里标 `(default)` 的那个）。要用别的，在 `patches:` 里加一项：`target: {kind: PersistentVolumeClaim, name: ccquota-data}`，JSON patch `op: add`、`path: /spec/storageClassName`、`value: <你的 storageclass>`。

密钥由人建，不进任何仓库：

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
# 只有 Postgres 形态需要：
kubectl -n $NS create secret generic ccquota-db \
  --from-literal=db-url='postgres://…?sslmode=require' --from-literal=replica-token="$(openssl rand -hex 32)"
```

登录方式的键在 `deployment-env.yaml` 的 `env:` 里引用 `ccquota` 这个 Secret，不写值：

```yaml
            - name: CCQUOTA_GITHUB_CLIENT_ID
              valueFrom: {secretKeyRef: {name: ccquota, key: github-client-id}}
            - name: CCQUOTA_GITHUB_CLIENT_SECRET
              valueFrom: {secretKeyRef: {name: ccquota, key: github-client-secret}}
```

然后：

```sh
kubectl kustomize ~/fleet-deploy/overlays/mine > /tmp/hub.yaml   # 先看一眼渲染结果
kubectl apply -f /tmp/hub.yaml
kubectl -n $NS rollout status deploy/ccquota-hub
```

SQLite 形态必须是一个副本、`Recreate`：两个进程同时写一个文件会把库写坏。

### 1.7 检查入口

```sh
curl -fsS https://hub.example.com/healthz          # ok
curl -fsS https://hub.example.com/version          # 镜像版本、stable 的提交号
curl -sS  https://hub.example.com/install | head -1 # #!/bin/sh —— 客户端安装脚本
```

- `/install` 回的是一句以 `# ` 开头的话（HTTP 503）而不是脚本：入口还发不了客户端，原因就在那句话里——还没配任何登录方式（[§1.4](#14-登录方式)），或者没配 `CCQUOTA_FLEET_SSH_CA_KEY`。补上、重启入口即可。启动日志里也有同一句（`fleet: /install is off: …`）。
- `/version` 里没有 `stable`、却有 `stable_problem`：入口问不到 GitHub 上的 `stable`，那句话说了原因和办法，见 [§4.4](#44-入口问不到-github-时)。

然后用浏览器打开 `https://hub.example.com`，以 §1.3 里列的管理员身份登录：自托管的入口打开就是控制台（没有官网首页）。

启动不起来时看容器日志（`docker logs fleet-hub` / `kubectl -n $NS logs deploy/ccquota-hub`）：缺钥匙、登录方式只配了一半，都会在第一屏说清楚是哪个键。

### 1.8 国内部署

入口和机器在国内时，有几处要多做一步：

| 什么 | 为什么 | 做法 |
|---|---|---|
| 构建拉 Go 依赖 | 直连官方代理常卡住 | 默认已经经 `goproxy.cn`（[§1.1](#11-构建镜像)） |
| `stable` 是哪个提交 | 入口匿名问 GitHub 会被限流 | 把 `stable` 推给入口（[§4.4](#44-入口问不到-github-时)） |
| 发布包要的程序 | 自己没有 Codex、tmux 的制品 | 从已有这一版的入口取（[§1.3](#13-必填配置)「发布包要的程序」） |
| 发布包里的 Claude Code | 入口默认先从 registry.npmjs.org 拉 | 入口设 `CCQUOTA_FLEET_RELEASE_NPM="https://registry.npmmirror.com https://registry.npmjs.org"`，先走国内镜像（每个包都按 sha512 核过） |
| 订阅流量 | Claude、ChatGPT 不服务国内 | 架一台海外**中转**，入口和机器都经它出去（本节下文） |

中转是一台海外的小 Linux（Debian / Ubuntu，`python3`、systemd，Caddy 2.10 以上）。它不存任何凭据，只做两件事：凭入口签发的**通行证**放行，再把请求原样转给订阅商。放行与否每次都问入口（经本机一个核验进程，入口重启的几分钟里它记得刚放行过的通行证）。

下面用 `relay.example.com` 代表中转的域名，`hub.example.com` 代表入口。

**1. 中转机：先装核验进程。** 文件都在仓库的 `extras/cred-relay/`：

```sh
# 在中转机上，仓库副本里
sudo install -D -m 0755 extras/cred-relay/fleet-relay-check.py /usr/local/lib/fleet-relay/fleet-relay-check.py
sudo install -m 0644 bin/fleet_ed25519.py /usr/local/lib/fleet-relay/fleet_ed25519.py
sudo install -m 0644 extras/cred-relay/fleet-relay-check.service /etc/systemd/system/
sudo systemctl edit fleet-relay-check        # 写两行：[Service] 和 Environment=FLEET_HUB_URL=https://hub.example.com
sudo systemctl daemon-reload && sudo systemctl enable --now fleet-relay-check
curl -s http://127.0.0.1:2091/healthz        # ok
```

**2. 中转机：再装 Caddy 站点。** 顺序不能反：Caddy 先起来会去问一个还不存在的核验进程，所有请求都被拒。

```sh
sudo cp extras/cred-relay/Caddyfile /etc/caddy/Caddyfile
sudo systemctl edit caddy                    # 写两行：[Service] 和 Environment=FLEET_RELAY_SITE=relay.example.com
sudo -u caddy caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

用 `caddy` 用户校验：以 root 校验会建出 root 的日志文件，caddy 随后起不来。防火墙：80、443 对所有来源开放（门禁靠通行证，80 只为签证书），22 只对你自己。

**3. 入口：打开中转。** 在 [§1.2](#12-生成钥匙) 的目录里再生成两把钥匙：

```sh
cd ~/fleet-secrets && umask 077
openssl rand -base64 32 > session-cred-key   # 入口给自己和会话签中转通行证
openssl rand -base64 32 > relay-sign-key     # 给机器签 4 小时有效的中转通行证
```

入口加这几个键（钥匙按 §1.5 / §1.6 的办法以文件挂进去，不写值）：

| 键 | 值 | 说明 |
|---|---|---|
| `CCQUOTA_FLEET_CRED_RELAY_URL` | `https://relay.example.com` | 中转的地址 |
| `CCQUOTA_FLEET_SESSION_CRED_KEY_FILE` | `/secrets/session-cred-key` | 密钥 |
| `CCQUOTA_FLEET_RELAY_SIGN_KEY_FILE` | `/secrets/relay-sign-key` | 密钥；不设也能用，通行证就不会过期 |
| `CCQUOTA_FLEET_OAUTH_REFRESH_VIA` | `relay` | 订阅的登录状态由入口经中转续（替代 §1.3 的 `node`） |
| `CCQUOTA_GITHUB_OAUTH_VIA` | `relay` | 只在用 GitHub 登录、入口又连不上 github.com 时设 |

设了 `…_VIA=relay` 却缺中转地址或 `SESSION_CRED_KEY`，入口拒绝启动并说出缺哪个。先升级中转，再部署入口。

**4. 机器：经中转出去。** 机器要被入口标为**可信**才领得到中转通行证；每个跑会话的登录都要知道中转地址（`FLEET_CRED_RELAY_URL=https://relay.example.com`）。怎么在加机器时带上它，见 [§2](#2-加机器)。

**5. 验收。** 不需要任何凭据：

```sh
curl -s https://relay.example.com/healthz                                                         # ok
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://relay.example.com/anthropic/v1/messages   # 403：没有通行证
curl -s -o /dev/null -w '%{http_code}\n' https://relay.example.com/v1/models                       # 404：不是开放代理
```

中转机上 `sudo grep -rEc 'sk-ant-|eyJhbGci|Bearer ' /var/log/caddy/ /etc/caddy/` 应全为 0：日志只记路径前缀、状态和字节数。

管理入口和中转的人可以照仓库里 `plugins/fleet-infra/skills/sg-relay-setup/SKILL.md` 一步步做（迁移、撤销、回滚也在里面）。

## 2. 加机器

会话跑在机器上（控制台里叫「服务节点」）。每台机器在入口上有一张卡片，入口按空位把新会话放过去。

### 2.1 Mac

1. 控制台 → **服务节点与客户端** → **加服务节点**，填一个名字（例如 `mac-a`）。页面给出一行命令，里面带一个一次性的加入码，**一小时内有效**。
2. 在这台 Mac 上，用管理员账号打开终端，粘贴那一行。它长这样：

   ```sh
   curl -fsSL https://hub.example.com/install/bin/fleet-node-install.sh | sudo bash -s -- --hub https://hub.example.com --join <加入码>
   ```

3. 它一步一行地打印：检查 · 加入 · 发布公钥 · 期望状态 · ccquota · 运行时 · 机器钥匙 · 角色用户 · ssh CA · 删号通道 · 核心 · 守护 · 入口。每行是 `✓`、`跳过`（已经好了）或 `✗`（失败，下面一行写着怎么重跑）。最后一行是 `已收敛`。
4. 「服务节点与客户端」页上出现 `mac-a`，对话框里写「mac-a 已加入 fleet」。

要求：macOS 自带的 `/usr/bin/python3`（没有的话先 `xcode-select --install`）、`curl`、管理员权限。

**删号要多一步授权**：系统设置 → 通用 → 共享 → 远程登录 → ⓘ → 打开「允许远程用户完全磁盘访问」。安装时「删号通道」一行会提醒你；不开的话开号照常，删号做不了。

### 2.2 Linux

一台 Linux 机器从加入到开出第一个号，只要**一个**加入码：

1. **装好依赖**。要求：Debian 12 或 Ubuntu（带 systemd）、Python 3.9 以上，以及 `curl` `git` `zsh` `openssh-server` `sudo`。Debian / Ubuntu 上一次装齐：

   ```sh
   sudo apt-get install -y python3 curl git zsh openssh-server sudo
   ```

2. **拿加入码**：控制台 → **服务节点与客户端** → **加服务节点**，填一个名字（例如 `linux-a`）。页面给出一行命令，一次性加入码**一小时内有效**。
3. **加入**：用一个能 `sudo` 的账号在这台 Linux 上粘贴那一行：

   ```sh
   curl -fsSL https://hub.example.com/install/bin/fleet-node-install.sh | sudo bash -s -- --hub https://hub.example.com --join <加入码>
   ```

   它和 Mac 一样一步一行地打印（Linux 上多「开号」「中转」两行，没有「删号通道」）。这台还没有任何账号，所以最后**不会**说「已收敛」，而是：

   ```text
   已加入，还没有账号：这台（linux-a）的节点程序在等入口派第一个号。下一步在入口做——
     控制台「使用者」→ 生成邀请命令（设置「新使用者在哪些服务节点上开登录名」写 linux-a），或
     fleet hub accounts assign <身份 id> --host linux-a
     开号在这台上由节点程序自己做；账号开出来之前，这台不跑任何会话。
   ```

4. **开第一个号**：照那几行做（[开号与删号](../admin/accounts.md)）。入口把开号发给这台，这台的节点程序自己建账号，控制台上「排队开号」→「开号中」→ 完成，一般一两分钟。之后重跑第 3 步的命令，最后一行就是 `已收敛`。

**中转**：入口配了 `CCQUOTA_FLEET_CRED_RELAY_URL`（[§1.3](#13-必填配置)）时，加入时入口把这个地址交给机器，之后在这台上开的每个账号都自动走它，不用到机器上手写。入口是加入以后才配的中转，就在这台上重跑第 3 步的命令（不用新加入码），「中转」一行会把它写进已有的账号。入口没配中转，这一行不出现。

安装程序自己把目录设成 0755、文件 0644，不受你 shell 的 `umask` 影响。运行时装在 `/opt/claude-fleet`，守护进程是 `claude-fleet-node.service`：

```sh
systemctl status claude-fleet-node.service
```

### 2.3 检查与修复

在机器上：

```sh
fleet doctor --machine
```

每个部件一行 PASS / WARN / FAIL；退出码是 FAIL 的个数，0 就是好的。

**修复就是重跑同一行命令**：已经好的步骤打印 `跳过`，只补缺的那一步；入口还认这台机器时不消耗新的加入码。加入码过期了就回控制台再拿一个。

### 2.4 维护和移除

- **维护**：机器卡片 → **维护** → **开始维护**。新会话不再放到这台，正在跑的照常跑完；修好后 **结束维护**。关机、断网前先进维护。
- **移除**：机器卡片 → **移除**。入口作废这台机器的钥匙，不再往它上面放会话；机器上装的东西留着，重新加入时再跑一次 §2.1 / §2.2 即可。

## 3. 成员和客户端

### 3.1 给成员开号

- **控制台**：**使用者** → **生成邀请命令**。填了 GitHub 用户名，邀请就只给这个人用；空着就是给第一个用它的人。
- **命令行**（在已登录的客户端上）：

  ```sh
  fleet hub invite            # 打印一行安装命令，发给新同事；他装好就自动进来
  fleet hub accounts          # 每个人和他在哪台机器上有账号
  ```

开号（在某台机器上给这个人开一个系统账号）由入口发给机器去做，控制台上会显示「排队开号」→「开号中」→ 完成。

### 3.2 装客户端

每位成员在自己的电脑（macOS、Linux，Windows 用 WSL）上：

```sh
curl -fsSL https://hub.example.com/install | sh
```

- 装到 `~/.local/bin/fleet`，自带 tmux。装好后会直接打开 `fleet`。
- 第一次打开要登录：浏览器打开入口的登录页（或终端里显示一个二维码），用入口提供的方式登录、点「确认签发」。连接证书 12 小时有效，到期自动续。
- 想让这台电脑自己也跑会话，加 `--host`：`curl -fsSL https://hub.example.com/install | sh -s -- --host`。

检查：

```sh
fleet doctor     # 「fleet」一行：版本、入口、tmux、证书
fleet update     # 这台电脑跑的版本和它跟的 stable
```

成员之后怎么用，看 [成员 · 快速开始](../member/quickstart.md) 和 [日常使用](../member/usage.md)。

## 4. 升级

### 4.1 stable 是什么

fleet 的每一部分——入口、机器、客户端——都跟着同一个版本号：仓库里叫 `stable` 的那个标签。`stable` 只在一个提交通过了全部检查（Linux 和 macOS 两边的测试、发版前的回放检查）之后才往前挪，所以它是「可以给别人用」的那一版，不是最新的提交。

```sh
fleet update stable      # 入口告诉你的 stable 提交号
curl -fsS https://hub.example.com/version
```

### 4.2 一次升级怎么走

1. **入口先走**。用新的 `stable` 照 [§1.1](#11-构建镜像) 构建镜像，再按 [§5.1](#51-入口) 先给库做一份快照，然后换标签：
   - 单机容器：`docker pull` 新镜像，`docker rm -f fleet-hub`，用新标签重跑 §1.5 的 `docker run`。
   - Kubernetes：改 `overlays/mine/kustomization.yaml` 的 `newTag`，`kubectl apply`。
2. **机器自己跟**。入口换好后，它给新版本签名并通知每台机器；机器每 5 分钟也会自己问一次。一次升级是：下载、验签、整体切换、30 秒后自检，自检多出一个 FAIL 就自动切回上一版。
3. **客户端自己跟**。每次打开 `fleet` 时（至多一小时一次）问入口，在后台准备好新版，空闲时切换；要重开才生效时，顶上会写「新版已就绪 · 下次打开生效」。

入口没换镜像时，机器停在旧版、不会乱跳：入口只给和自己同一份源码的版本签名。

看谁还落后（在一台机器上）：

```sh
fleet doctor --installs   # 这台机器上每一份安装 vs stable，落后超过 30 分钟记 WARN
```

### 4.3 自己决定跟哪一版

默认跟官方仓库的 `stable`。想自己把关：fork 这个仓库，在你的 fork 上移动 `stable` 标签（只挪到你验过的提交），并给入口设

```
CCQUOTA_FLEET_STABLE_REPO=<你的组织>/claude-fleet
```

设成 `off` 则入口完全不问 GitHub，只发镜像里自带的那一版客户端，机器不会自动升级。

### 4.4 入口问不到 GitHub 时

没推过 `stable` 的入口，每 5 分钟匿名去问一次 `api.github.com`：「`stable` 现在是哪个提交」。入口在国内时，出口地址常和很多人共用，GitHub 给匿名请求的额度（每小时 60 次）很快被用完，答 403。这时：

- `curl -fsS https://hub.example.com/version` 里没有 `stable`，`stable_problem` 写着「GitHub rate-limited …」；
- 入口日志每 5 分钟一行 `fleet: stable lookup: … HTTP 403 … — GitHub rate-limited this hub's anonymous stable lookup`。

办法是**把 `stable` 推给入口**，推过一次之后入口就只认推来的，再也不问 GitHub：

1. 生成一个口令（`openssl rand -hex 32`），作为 `CCQUOTA_FLEET_PUBLISH_TOKEN` 放进入口的密钥（单机容器放 `hub.secret.env`，Kubernetes 放 Secret），重启入口。
2. 在一份能访问入口的仓库副本里推：

   ```sh
   cd claude-fleet && git fetch origin --tags && git checkout stable
   read -rs FLEET_PUBLISH_TOKEN && export FLEET_PUBLISH_TOKEN      # 粘贴同一个口令，不回显
   bin/fleet-release-publish.sh $(git rev-parse HEAD) --hub https://hub.example.com
   ```

   入口自己核对提交和文件，不需要信任这台电脑；同一个提交再推一次答 `already`。
3. `curl -fsS https://hub.example.com/version` 的 `stable` 就是这个提交，`stable_problem` 不见了。

以后每次升级（[§4.2](#42-一次升级怎么走)）照第 2 步推新的提交即可。口令只从环境读，不要写进命令行或提交进仓库。

## 5. 回滚

### 5.1 入口

**每次换镜像之前先做快照**。数据库是 WAL 模式，运行中直接复制会得到一份坏文件，要用 SQLite 的 `VACUUM INTO`：

```sh
# 单机容器：在宿主机上用 sqlite3（3.27 以上）
sqlite3 /srv/fleet/data/ccquota.db "VACUUM INTO '/srv/fleet/data/backup-$(date -u +%Y%m%dT%H%M%SZ).db'"
```

Postgres 形态用数据库自己的备份（云数据库的自动备份，或 `pg_dump`）。

想在切换前先验一下新镜像，用快照的一份副本跑它的自检——跑完就退出，不监听端口，不碰正式库：

```sh
cp /srv/fleet/data/backup-<时间>.db /tmp/check.db && chown 10001 /tmp/check.db
docker run --rm -v /tmp/check.db:/data/check.db -v /srv/fleet/ca:/secrets/ca:ro \
  -v /srv/fleet/cred-key:/secrets/cred-key:ro -v /srv/fleet/release-key:/secrets/release-key:ro \
  --env-file /srv/fleet/hub.env --env-file /srv/fleet/hub.secret.env \
  -e CCQUOTA_FLEET_RELEASE_DIR=/tmp/releases \
  --entrypoint ccquota registry.example.com/fleet/ccquota:<新标签> hub --check --db /data/check.db
```

退出码 0 才切。

**回滚** = 换回旧标签（单机容器：用旧标签重跑 `docker run`；Kubernetes：`newTag` 改回去再 `apply`）。如果新版本已经改过库结构（升级日志里有 migration），旧镜像读不了新库，还要换回快照：

```sh
docker stop fleet-hub
mv /srv/fleet/data/ccquota.db /srv/fleet/data/ccquota.db.bad
cp /srv/fleet/data/backup-<时间>.db /srv/fleet/data/ccquota.db && chown 10001 /srv/fleet/data/ccquota.db
rm -f /srv/fleet/data/ccquota.db-wal /srv/fleet/data/ccquota.db-shm
# 再用旧标签重跑 §1.5 的 docker run
```

快照之后入口里新发生的事（新登录、新会话记录）会随快照一起回到过去。Kubernetes 的 SQLite 形态同理：先 `kubectl -n $NS scale deploy/ccquota-hub --replicas=0`，在数据盘上换文件，再扩回 1。

### 5.2 机器

自动的：每台机器保留上一版，切换后自检出了新的 FAIL 就自己切回去，并跳过那一版。入口退回旧镜像后，机器跟着入口签的版本走，不用逐台处理。

### 5.3 客户端

一般不用管，它跟着入口。确实要手动退回上一版：

```sh
ls ~/.claude/fleet.versions/          # 每一版一个目录，.prev 记着上一版
ln -sfn ~/.claude/fleet.versions/<上一版> ~/.claude/fleet
```

## 6. 卸载

- **成员的客户端**：`fleet quit`，再 `fleet logout`；删掉 `~/.local/bin/fleet`、`~/.claude/fleet`、`~/.claude/fleet.versions`、`~/.local/share/claude-fleet-vendor`（安装时带的 tmux），以及安装时加进 shell 配置文件的那一行 PATH。
- **机器**：先在控制台 **维护**、等会话跑完，再 **移除**。机器上的运行时目前没有一键卸载命令。
- **入口**：停掉容器（`docker rm -f fleet-hub`）或删掉命名空间（`kubectl delete namespace fleet-hub`）。数据在 `/srv/fleet/data` 或数据盘 / 数据库里，你决定留不留。

## 下一步

- 接订阅、开号、配额、看机器：[管理员手册](../admin/index.md)
- 卡住了：[故障排查](../troubleshooting.md)
- 隔离与凭据：[安全与隔离](../security.md)
