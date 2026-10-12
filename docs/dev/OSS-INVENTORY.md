# 仓库里的内部名字和地址 · 清单（OSS-INVENTORY）

> 对内文档（`docs/dev/`）。由 issue #3571（EPIC #3569 C1）立账；表格部分由
> `bin/oss-scan.sh --inventory` 生成，手改无效——改规则表或允许清单后重新生成。

## 读数

在 `acc12055` 上（2026-10-12）：

```
$ bin/oss-scan.sh --summary
tree: 523 个文件 · 6945 处（允许清单另放过 10 个文件）
  by dir:   tokenledger 230 · bin 217 · docs 22 · deploy 14 · extras 13 · .github 7 · commands 4 · plugins 4 · (根) 3 · mod 3 · conf 2 · skills 2 · hooks 1 · shell 1
  by rule:  machine 398 个文件/4995 处 · gh-owner 117 个文件/587 处 · person 114 个文件/652 处 · corp-domain 101 个文件/336 处 · private-ipv4 47 个文件/177 处 · ts-net 30 个文件/101 处 · cloud 21 个文件/62 处 · user-home 13 个文件/20 处 · tailnet 7 个文件/15 处
  by class: config 67 个文件 · placeholder 456 个文件（含 config 的文件记 config）

$ bin/oss-scan.sh --history --summary
history: 0 处未确认 · 0 个提交
```

- **当前树：523 个文件**写着内部名字或地址（另有 10 个文件只剩允许清单放过的命中）。
  EPIC #3569 起草时的估计是 284 个——那次的模式没算两台 Mac 的短别名、
  所有者的 GitHub 名和几位真人的登录名；这里按规则表第一次跑出的数为准（EPIC 读数口径
  「以 C1 第一次跑出的数为准」）。其中 `machine` 一条就占 398 个文件，绝大多数是
  selftest / `*_test.go` 里拿这两个短别名当示例机器名。
- **历史：0 处未确认**（改动前 28 处）。28 处已逐条判定、逐条写进 `.gitleaks.toml`
  （见下「历史里像密钥的 28 处」）：**0 处真密钥**。
- **C8 换完占位之后（#3578，2026-10-12）**：文档、测试和注释里的机器名、地址、人名都换成了占位词，
  `placeholder` 一类归零；剩下的全是 `config`——部署覆盖层、发布工作流和 doc-preview 里运行时真要用的值，
  改成配置项是 C7（#3577）的事：

```
$ bin/oss-scan.sh --summary
tree: 21 个文件 · 62 处（允许清单另放过 60 个文件）
  by dir:   deploy 14 · .github 6 · skills 1
  by rule:  corp-domain 14 个文件/33 处 · cloud 12 个文件/23 处 · machine 2 个文件/3 处 · gh-owner 1 个文件/2 处 · private-ipv4 1 个文件/1 处
  by class: config 21 个文件 · placeholder 0 个文件（含 config 的文件记 config）
  豁免:     9 处（行尾 oss-ok:，不进门禁与基线）
```

## 门禁：新提交不再混进来（C2，#3572）

`.github/workflows/oss-scan.yml` 每个 PR 都跑（不设路径过滤），红了这样改：

- **`文件:行 规则 — 改成配置项或换成占位`**：这个 PR 新增的这一行命中了规则表。运行时用到的值
  改成配置项（我们自己的值放机器上的 `fleet.conf` 或部署覆盖层）；文档、测试、注释里的换成占位词
  （`mac-a` `mac-b` `linux-a` · `hub.example.com` · `relay.example.com` · `alice` `bob` · `example.ts.net`）。
- **确需保留的一行**：行尾写 `# oss-ok: <理由>`（`// oss-ok:`、`<!-- oss-ok:` 同样认），放行，
  但计数——`--summary` 的「豁免」行和门禁最后一行都报。
- **「基线只许降」**：全树每条规则的命中数比 `conf/oss-scan.baseline` 多。C7 / C8 删掉命中后，
  用 `bin/oss-scan.sh --baseline > conf/oss-scan.baseline` 把数调低（门禁会提示「请把 … 调低」）。
- **gitleaks**：钉住版本、按 sha256 校验的 gitleaks 扫这个 PR 的提交（`bin/oss-scan.sh --commits
  <base>..HEAD`，用 `.gitleaks.toml`）；先对一个带假 GitHub 令牌的提交跑一次，必须红。

本地先看一眼：`bin/oss-scan.sh --gate origin/master`。演练：`docs/BREAK-IT.md` 的
`oss-internal-name-committed`。

## 规则表与允许清单（唯一一份）

- `conf/oss-scan.rules` —— 每行 `<rule-id>\t<ERE>\t<说明>`，外加 `#@keep`（仓库自己的名字
  `verkyyi/claude-fleet` 与占位词 `example.ts.net` 不算命中）。
  C2 门禁、C7 / C8 验收、C16 / C17 插件检查都读它，不各写一份。

  | rule-id | 找什么 |
  |---|---|
  | `tailnet` | 我们的 tailscale 私有网络名 |
  | `ts-net` | 任何 `*.ts.net` 机器名（MagicDNS） |
  | `corp-domain` | 公司域名、镜像命名空间、monorepo 名 |
  | `cloud` | 阿里云镜像仓库域名、地域、账号 id、ACK 集群 id |
  | `machine` | 我们的机器名和别名 |
  | `user-home` | 真实登录的 home 路径 |
  | `person` | 真人的名字 / 登录名 |
  | `gh-owner` | 所有者的 GitHub 名（仓库名本身除外） |
  | `private-ipv4` | 私网 / tailnet（CGNAT）IPv4 |
  | `public-ip` | 我们自己的公网 IPv4：集群出口、gh-relay（新加坡）、入口、官网、家里那条线的网段（#3631；地址只写在规则表里） |

- `conf/oss-scan.allow` —— `<path-glob>\t<rule-id|*>\t<理由>`，确需保留的才进，每行写理由：

  - `conf/oss-scan.rules` · `*` — 规则表本身：它写的就是要找的名字
  - `conf/oss-scan.allow` · `*` — 允许清单本身
  - `bin/oss-scan-selftest.sh` · `private-ipv4` — 自测在沙箱仓库里放一行假的私网地址，要的就是它被报出来
  - `LICENSE` · `person` — 版权人署名（MIT 许可证要求写明版权人）
  - `.claude-plugin/*.json` · `gh-owner` — 插件市场 / 插件清单的 owner、author 字段：公开发布的署名
  - `plugins/*/.claude-plugin/plugin.json` · `gh-owner` — 插件清单的 author 字段：公开发布的署名

## 三类归类

每一处命中归成三类之一（`bin/oss-scan.sh` 逐行判，文件的归类是它各行的并集）：

| 归类 | 判据 | 谁来改 |
|---|---|---|
| **config** 改成配置 | 程序、部署、CI 里真的会用到这个值的那一行 | C7：读配置，我们的值放进私有部署覆盖层或机器上的 `fleet.conf`；未设时读旧值一版（`# compat-1v`） |
| **placeholder** 换成占位 | selftest / `*_test.go` / fixture、文档（`*.md` `docs/`）、注释 | C8：换成占位词表 `mac-a` `mac-b` `linux-a` · `hub.example.com` · `relay.example.com` · `alice` `bob` · `example.ts.net` |
| **allow** 允许保留 | `conf/oss-scan.allow` 写了文件 + 规则 + 理由 | 不改；只许减少 |

一个文件同时有两类时记 `config + placeholder`：C7 改它的 config 行，C8 改其余。

## 历史里像密钥的 28 处

2026-10-12 在 ecae8bfa 上 `gitleaks git --redact`（全部提交）。只写位置，不贴原文；判定依据是把值按
形状检查：长度、是否含 FAKE / abcdef 之类的明文、能否解码出密钥体。结论：**0 处真密钥 · 0 处拿不准 ·
27 处测试假数据或误报 · 1 处真实主机公钥（非机密）**。每一条都按 commit + path + rule 写进
`.gitleaks.toml`（`condition = "AND"`，不按目录、不按整条规则），所以同一文件里新的密钥、
别的文件或别的提交里同样形状的东西照样报出来。

| # | 规则 | 位置（提交） | 判定 | 依据 |
|---|---|---|---|---|
| 1–2 | generic-api-key | `extras/managed-node/smoke.py:53`（4ad7c67f）· `:46`（a1514dc3） | 测试假数据 | 替身入口回的中转通行证，值里明文写着 fixture |
| 3 | aws-access-token | `bin/client-log-selftest.sh:63`（d5742450） | 测试假数据 | 脱敏测试的输入，值为 AKIA 加连续字母表 |
| 4–5 | private-key | `bin/fleet-break-it-selftest.sh:5433`（d5742450 · 8c94c870） | 测试假数据 | printf 模板；参数都带 FAKE，私钥体只有 openssh 头 + FAKE |
| 6, 10 | github-pat | `bin/client-log-selftest.sh:51`（02e5f79e · fd812984） | 测试假数据 | 值为 AbCdEf / abcdef 重复 |
| 7, 12 | private-key | `bin/doctor-bundle-selftest.sh:32`（d5742450 · 8c94c870） | 测试假数据 | 私钥体 70 字符，解码只有 openssh-key-v1 的通用开头，没有密钥材料 |
| 8, 13 | jwt | `bin/doctor-bundle-selftest.sh:44`（d5742450）· `:43`（8c94c870） | 测试假数据 | jwt.io 的公开示例 |
| 9, 11, 14 | aws-access-token · gitlab-pat | `bin/doctor-bundle-selftest.sh:45`（d5742450）· `:44`（8c94c870 ×2） | 测试假数据 | AKIA 加字母表、glpat 值含 FAKE |
| 15–16 | curl-auth-header | `tokenledger/internal/api/fleet_service_log_test.go:319`（f7a0ede2 · 7d9224e3） | 测试假数据 | Bearer 后的值就是期望结果 abc.def-ghi |
| 17, 18, 20, 21 | generic-api-key | `bin/fleet-release-publish-selftest.sh:105` · `:115`（efb05b86 · 66603aa7） | 测试假数据 | 发布令牌是普通英文词组，给替身入口用 |
| 19, 22 | generic-api-key | `bin/fleet-role-merge-selftest.sh:162`（4c21b98f · 30c966d5，HEAD 已无此文件） | 测试假数据 | API_KEY 值为 abcd1234… |
| 23 | aws-access-token | `tokenledger/internal/api/fleet_client_settings_test.go:98`（be6677e9） | 测试假数据 | AKIA 加字母表 |
| 24 | generic-api-key | `bin/fleet-hub-node-env-selftest.sh:53`（3b1dc054） | 测试假数据 | 值含 SECRET 与 abcdef |
| 25 | generic-api-key | `bin/fleet-node-join-selftest.sh:13`（91498a7f） | 误报 | 注释里的环境变量名，没有值 |
| 26 | generic-api-key | `bin/fleet-doctor-ingress-selftest.sh:71`（91c7b898，HEAD 里还在） | **真实主机公钥（非机密）** | 与一台托管机器的 ssh ed25519 主机公钥逐字相同。公钥不是凭据、不能登录、不用换；HEAD 里的由 C8 换成随机生成的假公钥，历史那条留在 allowlist |
| 27–28 | generic-api-key | `bin/fleet-issue-bridge-selftest.sh:183`（32ba5a80 · f6b6fd32） | 误报 | 环境变量名 + shell 变量（签名用测试密钥现算） |

以后 `--history` 报出新的一条：先按形状判定；是真的就**立刻作废换新**（历史不改写，EPIC #3569 拍板 3），
确认是假的才进 `.gitleaks.toml`，同样按 commit + path + rule。

## 怎么重跑

```
bin/oss-scan.sh                     # 每处一行：文件:行:规则:归类
bin/oss-scan.sh --summary           # 文件数 · 按目录 / 规则 / 归类
bin/oss-scan.sh -- plugins/x        # 只看某个路径
bin/oss-scan.sh --history --summary # 历史里还没确认的（要 gitleaks）
bin/oss-scan.sh --inventory         # 下面这张表
```

自测：`bin/oss-scan-selftest.sh`。

## 逐个文件

| 文件 | 处 | 规则 | 归类 |
|---|---:|---|---|
| `.claude-plugin/marketplace.json` | — | — | allow |
| `.claude-plugin/plugin.json` | — | — | allow |
| `.github/actions/hub-acr/acr.js` | 4 | cloud 4 | config |
| `.github/actions/hub-kubeconfig/action.yml` | 2 | cloud 2 | config |
| `.github/actions/hub-kubeconfig/oidc.js` | 5 | cloud 5 | config |
| `.github/workflows/hub-deploy.yml` | 4 | cloud 1 · corp-domain 3 | config |
| `.github/workflows/release-train.yml` | 4 | corp-domain 4 | config |
| `.github/workflows/stable-publish.yml` | 1 | corp-domain 1 | config |
| `LICENSE` | — | — | allow |
| `bin/client-log-selftest.sh` | — | — | allow |
| `bin/entry-e2e-selftest.sh` | — | — | allow |
| `bin/fleet-break-it-entry-selftest.sh` | — | — | allow |
| `bin/fleet-break-it-peerlink-selftest.sh` | — | — | allow |
| `bin/fleet-break-it-thin-client-selftest.sh` | — | — | allow |
| `bin/fleet-client-route-selftest.sh` | — | — | allow |
| `bin/fleet-client-where-selftest.sh` | — | — | allow |
| `bin/fleet-connect-route-selftest.sh` | — | — | allow |
| `bin/fleet-doctor-host-selftest.sh` | — | — | allow |
| `bin/fleet-entry-lang-selftest.sh` | — | — | allow |
| `bin/fleet-host-tune-selftest.sh` | — | — | allow |
| `bin/fleet-install-join-selftest.sh` | — | — | allow |
| `bin/fleet-login-selftest.sh` | — | — | allow |
| `bin/fleet-node-hosted-selftest.sh` | — | — | allow |
| `bin/fleet-node-linux-selftest.py` | — | — | allow |
| `bin/fleet-node-supervisor-selftest.py` | — | — | allow |
| `bin/fleet-open-selftest.sh` | — | — | allow |
| `bin/fleet-peer-cert-selftest.sh` | — | — | allow |
| `bin/fleet-peerlink-selftest.sh` | — | — | allow |
| `bin/oss-scan-selftest.sh` | — | — | allow |
| `conf/compat-ours.conf` | — | — | allow |
| `conf/oss-scan.allow` | — | — | allow |
| `conf/oss-scan.rules` | — | — | allow |
| `deploy/k8s/RUNBOOK.md` | — | — | allow |
| `deploy/k8s/base/ccquota-pricing.yaml` | — | — | allow |
| `deploy/k8s/caches/fleet-workers/kustomization.yaml` | 6 | cloud 3 · corp-domain 3 | config |
| `deploy/k8s/credproxy/fleet-workers/deployment-env.yaml` | 1 | corp-domain 1 | config |
| `deploy/k8s/credproxy/fleet-workers/kustomization.yaml` | 2 | cloud 1 · corp-domain 1 | config |
| `deploy/k8s/credproxy/prod/deployment-env.yaml` | 1 | corp-domain 1 | config |
| `deploy/k8s/credproxy/prod/ingress-hosts.yaml` | 5 | corp-domain 5 | config |
| `deploy/k8s/credproxy/prod/kustomization.yaml` | 2 | cloud 1 · corp-domain 1 | config |
| `deploy/k8s/egress/base/fleet-egress.py` | — | — | allow |
| `deploy/k8s/egress/fleet-workers/deployment-env.yaml` | 1 | private-ipv4 1 | config |
| `deploy/k8s/egress/fleet-workers/kustomization.yaml` | 2 | cloud 1 · corp-domain 1 | config |
| `deploy/k8s/overlays/prod/debug-volume.yaml` | 1 | cloud 1 | config |
| `deploy/k8s/overlays/prod/deployment-env.yaml` | 7 | corp-domain 4 · gh-owner 2 · machine 1 | config |
| `deploy/k8s/overlays/prod/ingress-hosts.yaml` | 5 | corp-domain 5 | config |
| `deploy/k8s/overlays/prod/kustomization.yaml` | 4 | cloud 2 · corp-domain 2 | config |
| `deploy/k8s/overlays/prod/release-volume.yaml` | 1 | cloud 1 | config |
| `deploy/k8s/updating/prod/kustomization.yaml` | 2 | cloud 1 · corp-domain 1 | config |
| `docs/dev/MANAGED-LINUX.md` | — | — | allow |
| `extras/gh-relay/README.md` | — | — | allow |
| `extras/gh-relay/gh-relay.py` | — | — | allow |
| `extras/gh-relay/gh-relay.service` | — | — | allow |
| `extras/managed-node/render.py` | — | — | allow |
| `extras/web-chat/ui/dist/assets/index-62DAmW9a.js` | — | — | allow |
| `plugins/fleet-browser/.claude-plugin/plugin.json` | — | — | allow |
| `plugins/fleet-epic/.claude-plugin/plugin.json` | — | — | allow |
| `plugins/fleet-feedback/.claude-plugin/plugin.json` | — | — | allow |
| `plugins/fleet-infra/.claude-plugin/plugin.json` | — | — | allow |
| `plugins/fleet-orchestrate/.claude-plugin/plugin.json` | — | — | allow |
| `plugins/fleet-steward/.claude-plugin/plugin.json` | — | — | allow |
| `skills/doc-preview/render.mjs` | 2 | machine 2 | config |
| `tokenledger/README.md` | — | — | allow |
| `tokenledger/cmd/ccquota/hub_test.go` | — | — | allow |
| `tokenledger/cmd/ccquota/tls_test.go` | — | — | allow |
| `tokenledger/docs/superpowers/plans/2026-09-12-provider-dimension.md` | — | — | allow |
| `tokenledger/docs/superpowers/plans/2026-09-13-tokenledger-ui.md` | — | — | allow |
| `tokenledger/docs/superpowers/specs/2026-09-12-tokenledger-provider-and-reorientation-design.md` | — | — | allow |
| `tokenledger/internal/agent/node_entry_test.go` | — | — | allow |
| `tokenledger/internal/agent/node_routes_test.go` | — | — | allow |
| `tokenledger/internal/api/fleet_certs_test.go` | — | — | allow |
| `tokenledger/internal/api/fleet_debug_ticket_test.go` | — | — | allow |
| `tokenledger/internal/api/fleet_entry_reach_test.go` | — | — | allow |
| `tokenledger/internal/api/fleet_home_login_test.go` | — | — | allow |
| `tokenledger/internal/api/fleet_maintenance_test.go` | — | — | allow |
| `tokenledger/internal/api/fleet_routes_test.go` | — | — | allow |
| `tokenledger/internal/api/hub_users_api_test.go` | — | — | allow |
| `tokenledger/internal/api/node_route_test.go` | — | — | allow |
| `tokenledger/internal/credproxy/credproxy_test.go` | — | — | allow |
| `tokenledger/internal/credvault/kms.go` | — | — | allow |
| `tokenledger/internal/store/sources_test.go` | — | — | allow |
