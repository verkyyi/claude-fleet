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
| `.github/actions/hub-acr/acr.js` | 6 | cloud 4 · corp-domain 2 | config + placeholder |
| `.github/actions/hub-acr/action.yml` | 2 | corp-domain 2 | placeholder |
| `.github/actions/hub-kubeconfig/action.yml` | 3 | cloud 2 · corp-domain 1 | config + placeholder |
| `.github/actions/hub-kubeconfig/oidc.js` | 7 | cloud 6 · corp-domain 1 | config + placeholder |
| `.github/workflows/hub-deploy.yml` | 4 | cloud 1 · corp-domain 3 | config |
| `.github/workflows/release-train.yml` | 4 | corp-domain 4 | config |
| `.github/workflows/stable-publish.yml` | 1 | corp-domain 1 | config |
| `CLAUDE.md` | 1 | machine 1 | placeholder |
| `CONTRIBUTING.md` | 1 | machine 1 | placeholder |
| `LICENSE` | — | — | allow |
| `bin/agent-ver-selftest.sh` | 3 | machine 3 | placeholder |
| `bin/ask-words-selftest.sh` | 4 | machine 4 | placeholder |
| `bin/backlog-utf8-safe-selftest.sh` | 1 | corp-domain 1 | placeholder |
| `bin/cfg-stale-selftest.sh` | 4 | machine 4 | placeholder |
| `bin/client-log-selftest.sh` | 10 | machine 9 · private-ipv4 1 | placeholder |
| `bin/codex-matrix-selftest.sh` | 2 | person 2 | placeholder |
| `bin/cross-send-selftest.sh` | 3 | machine 3 | placeholder |
| `bin/dash-issue-new-spawn-selftest.sh` | 4 | machine 4 | placeholder |
| `bin/dash-issue-new.sh` | 3 | machine 3 | placeholder |
| `bin/dash-popup-selftest.sh` | 1 | machine 1 | placeholder |
| `bin/dash-reap-hub-selftest.sh` | 4 | machine 4 | placeholder |
| `bin/dash-remote-rows-selftest.sh` | 80 | gh-owner 1 · machine 79 | placeholder |
| `bin/doc-preview-share-selftest.sh` | 10 | ts-net 10 | placeholder |
| `bin/doctor-bundle-selftest.sh` | 1 | machine 1 | placeholder |
| `bin/entry-e2e-selftest.sh` | 3 | private-ipv4 3 | placeholder |
| `bin/fixtures/claim-grounding/worker.jsonl` | 3 | machine 3 | placeholder |
| `bin/fleet` | 5 | machine 5 | placeholder |
| `bin/fleet-account-selftest.sh` | 1 | person 1 | placeholder |
| `bin/fleet-account.sh` | 1 | person 1 | placeholder |
| `bin/fleet-admit-selftest.sh` | 10 | machine 10 | placeholder |
| `bin/fleet-alerts-selftest.sh` | 4 | machine 4 | placeholder |
| `bin/fleet-break-it-ci-selftest.sh` | 2 | machine 2 | placeholder |
| `bin/fleet-break-it-cred-sep-selftest.sh` | 6 | machine 6 | placeholder |
| `bin/fleet-break-it-cred-shared-selftest.sh` | 3 | machine 2 · person 1 | placeholder |
| `bin/fleet-break-it-entry-selftest.sh` | 6 | private-ipv4 6 | placeholder |
| `bin/fleet-break-it-hub-selftest.sh` | 11 | corp-domain 1 · machine 10 | placeholder |
| `bin/fleet-break-it-node-selftest.sh` | 37 | gh-owner 14 · machine 10 · person 12 · user-home 1 | placeholder |
| `bin/fleet-break-it-peerlink-selftest.sh` | 66 | machine 63 · private-ipv4 1 · ts-net 2 | placeholder |
| `bin/fleet-break-it-selftest.sh` | 73 | corp-domain 1 · gh-owner 1 · machine 57 · person 14 | placeholder |
| `bin/fleet-break-it-thin-client-selftest.sh` | 5 | gh-owner 1 · person 1 · private-ipv4 3 | placeholder |
| `bin/fleet-brew-perms.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-browser-selftest.sh` | 5 | machine 5 | placeholder |
| `bin/fleet-children-selftest.sh` | 22 | machine 22 | placeholder |
| `bin/fleet-children.py` | 2 | machine 2 | config |
| `bin/fleet-claim-brief-selftest.sh` | 16 | gh-owner 16 | placeholder |
| `bin/fleet-claude.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-cleanup-daemon-selftest.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-cleanup-daemon.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-client-actions-selftest.sh` | 6 | ts-net 6 | placeholder |
| `bin/fleet-client-badge-selftest.sh` | 4 | machine 3 · person 1 | placeholder |
| `bin/fleet-client-badge.sh` | 5 | gh-owner 4 · person 1 | placeholder |
| `bin/fleet-client-layout-selftest.sh` | 18 | gh-owner 1 · machine 17 | placeholder |
| `bin/fleet-client-lease.py` | 2 | private-ipv4 2 | config |
| `bin/fleet-client-live-update-selftest.sh` | 6 | machine 4 · person 2 | placeholder |
| `bin/fleet-client-place-selftest.sh` | 51 | gh-owner 1 · machine 41 · person 9 | placeholder |
| `bin/fleet-client-place.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-client-route-selftest.sh` | 25 | machine 22 · person 2 · private-ipv4 1 | placeholder |
| `bin/fleet-client-solo-selftest.sh` | 37 | machine 37 | placeholder |
| `bin/fleet-client-switcher-selftest.sh` | 6 | machine 6 | placeholder |
| `bin/fleet-client-update-selftest.sh` | 2 | machine 2 | placeholder |
| `bin/fleet-client-upload.py` | 1 | machine 1 | config |
| `bin/fleet-client-where-selftest.sh` | 28 | gh-owner 7 · machine 7 · private-ipv4 9 · tailnet 1 · ts-net 4 | placeholder |
| `bin/fleet-client-where.sh` | 3 | gh-owner 2 · machine 1 | placeholder |
| `bin/fleet-collect-git-budget-selftest.sh` | 1 | corp-domain 1 | placeholder |
| `bin/fleet-compose-latency-selftest.sh` | 10 | machine 10 | placeholder |
| `bin/fleet-compose-selftest.sh` | 40 | machine 40 | placeholder |
| `bin/fleet-conf-selftest.sh` | 14 | machine 14 | placeholder |
| `bin/fleet-connect-hostkey-selftest.sh` | 3 | machine 3 | placeholder |
| `bin/fleet-connect-route-selftest.sh` | 98 | machine 65 · person 4 · private-ipv4 21 · tailnet 3 · ts-net 5 | placeholder |
| `bin/fleet-connect-selftest.sh` | 4 | machine 4 | placeholder |
| `bin/fleet-connect.py` | 5 | machine 3 · private-ipv4 2 | config + placeholder |
| `bin/fleet-cred-policy-selftest.sh` | 11 | machine 11 | placeholder |
| `bin/fleet-cred-proxy.py` | 1 | corp-domain 1 | config |
| `bin/fleet-creds-import.sh` | 2 | machine 2 | placeholder |
| `bin/fleet-credsep-selftest.sh` | 9 | corp-domain 9 | placeholder |
| `bin/fleet-credsep.py` | 4 | machine 4 | config + placeholder |
| `bin/fleet-credsep.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-debug-desk-selftest.sh` | 6 | person 6 | placeholder |
| `bin/fleet-debug-prompt-selftest.sh` | 6 | machine 6 | placeholder |
| `bin/fleet-deps-share.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-doctor-host-selftest.sh` | 11 | private-ipv4 11 | placeholder |
| `bin/fleet-doctor.sh` | 15 | gh-owner 3 · machine 10 · person 2 | config + placeholder |
| `bin/fleet-drill-selftest.sh` | 19 | gh-owner 1 · machine 18 | placeholder |
| `bin/fleet-drill.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-entry-lang-selftest.sh` | 3 | private-ipv4 3 | placeholder |
| `bin/fleet-entry.sh` | 1 | corp-domain 1 | placeholder |
| `bin/fleet-epic-backstop-selftest.sh` | 22 | gh-owner 3 · machine 19 | placeholder |
| `bin/fleet-epic-backstop.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-epic-heartbeat.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-epic-preflight.sh` | 1 | corp-domain 1 | placeholder |
| `bin/fleet-evidence.sh` | 1 | corp-domain 1 | placeholder |
| `bin/fleet-feedback-selftest.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-home-session-selftest.sh` | 7 | gh-owner 1 · machine 6 | placeholder |
| `bin/fleet-host-selftest.sh` | 3 | machine 3 | placeholder |
| `bin/fleet-host-tune-selftest.sh` | 4 | private-ipv4 4 | placeholder |
| `bin/fleet-hub-admin-selftest.sh` | 60 | corp-domain 5 · gh-owner 12 · machine 35 · person 8 | placeholder |
| `bin/fleet-hub-latency.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-hub-selftest.py` | 5 | machine 4 · person 1 | placeholder |
| `bin/fleet-hub-sessions.sh` | 3 | machine 3 | placeholder |
| `bin/fleet-install-apply.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-install-join-selftest.sh` | 22 | machine 21 · private-ipv4 1 | placeholder |
| `bin/fleet-install-selftest.sh` | 1 | gh-owner 1 | placeholder |
| `bin/fleet-install-sync.sh` | 4 | machine 3 · person 1 | placeholder |
| `bin/fleet-install-version.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-installs.sh` | 2 | machine 2 | placeholder |
| `bin/fleet-issue-file-selftest.sh` | 2 | machine 2 | placeholder |
| `bin/fleet-issue-file.sh` | 1 | machine 1 | config |
| `bin/fleet-lib.sh` | 19 | gh-owner 1 · machine 17 · person 1 | placeholder |
| `bin/fleet-login-bootstrap-selftest.sh` | 1 | gh-owner 1 | placeholder |
| `bin/fleet-login-new-selftest.sh` | 83 | corp-domain 4 · gh-owner 6 · person 69 · user-home 4 | placeholder |
| `bin/fleet-login-new.sh` | 5 | corp-domain 1 · machine 4 | placeholder |
| `bin/fleet-login-remove-selftest.sh` | 2 | machine 2 | placeholder |
| `bin/fleet-login-remove.sh` | 5 | machine 5 | placeholder |
| `bin/fleet-login-selftest.sh` | 4 | machine 2 · private-ipv4 2 | placeholder |
| `bin/fleet-login.py` | 2 | machine 2 | config |
| `bin/fleet-mcp-selftest.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-move.sh` | 2 | machine 2 | config + placeholder |
| `bin/fleet-node-drill.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-node-hosted-selftest.sh` | 8 | machine 4 · private-ipv4 4 | placeholder |
| `bin/fleet-node-linux-selftest.py` | 46 | corp-domain 31 · person 1 · private-ipv4 14 | placeholder |
| `bin/fleet-node-linux.py` | 3 | corp-domain 3 | config + placeholder |
| `bin/fleet-node-maintenance-selftest.sh` | 13 | gh-owner 3 · machine 10 | placeholder |
| `bin/fleet-node-maintenance.sh` | 4 | gh-owner 1 · machine 3 | placeholder |
| `bin/fleet-node-revoke-selftest.sh` | 4 | machine 4 | placeholder |
| `bin/fleet-node-selftest.sh` | 5 | machine 5 | placeholder |
| `bin/fleet-node-shell-retire-selftest.sh` | 2 | machine 2 | placeholder |
| `bin/fleet-node-supervisor-selftest.py` | 83 | gh-owner 36 · machine 9 · person 28 · private-ipv4 10 | placeholder |
| `bin/fleet-node-supervisor.py` | 13 | gh-owner 1 · machine 10 · person 1 · private-ipv4 1 | config + placeholder |
| `bin/fleet-node-trust-selftest.sh` | 11 | machine 11 | placeholder |
| `bin/fleet-node-trust.sh` | 2 | machine 2 | placeholder |
| `bin/fleet-node-update-selftest.py` | 26 | gh-owner 1 · machine 4 · person 20 · user-home 1 | placeholder |
| `bin/fleet-node-update.py` | 5 | gh-owner 1 · machine 4 | config + placeholder |
| `bin/fleet-oldcfg-check-selftest.sh` | 5 | machine 5 | placeholder |
| `bin/fleet-oldcfg-check.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-oldcfg-replay.py` | 1 | machine 1 | config |
| `bin/fleet-onboard-drill-selftest.sh` | 58 | machine 58 | placeholder |
| `bin/fleet-onboard-drill-steps-selftest.sh` | 5 | machine 5 | placeholder |
| `bin/fleet-onboard-drill.sh` | 8 | machine 8 | placeholder |
| `bin/fleet-onboard-judge.sh` | 2 | machine 2 | placeholder |
| `bin/fleet-onboard-selftest.sh` | 4 | person 4 | placeholder |
| `bin/fleet-open-laptop-selftest.sh` | 23 | machine 23 | placeholder |
| `bin/fleet-open-selftest.sh` | 15 | machine 2 · private-ipv4 2 · ts-net 11 | placeholder |
| `bin/fleet-peer-cert-selftest.sh` | 85 | gh-owner 13 · machine 62 · person 6 · private-ipv4 1 · ts-net 3 | placeholder |
| `bin/fleet-peer-cert.sh` | 3 | machine 3 | placeholder |
| `bin/fleet-peer-trust.sh` | 4 | gh-owner 1 · machine 3 | placeholder |
| `bin/fleet-peerlink-selftest.sh` | 52 | machine 43 · private-ipv4 6 · ts-net 3 | placeholder |
| `bin/fleet-peerlink.py` | 2 | machine 2 | config |
| `bin/fleet-phone-mcp-selftest.sh` | 3 | machine 3 | placeholder |
| `bin/fleet-phone-mcp.py` | 5 | gh-owner 1 · machine 4 | config |
| `bin/fleet-popup-selftest.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-quick-dispatch-selftest.sh` | 4 | machine 4 | placeholder |
| `bin/fleet-quick-dispatch.py` | 1 | machine 1 | config |
| `bin/fleet-quickopen.py` | 2 | machine 2 | config |
| `bin/fleet-quit-selftest.sh` | 6 | machine 6 | placeholder |
| `bin/fleet-relay-cred-selftest.sh` | 12 | machine 12 | placeholder |
| `bin/fleet-relay-cred.sh` | 3 | machine 3 | placeholder |
| `bin/fleet-release-selftest.sh` | 18 | machine 18 | placeholder |
| `bin/fleet-release.sh` | 2 | machine 2 | config + placeholder |
| `bin/fleet-remote-view-selftest.sh` | 29 | gh-owner 2 · machine 22 · person 5 | placeholder |
| `bin/fleet-remote-view.sh` | 13 | machine 13 | placeholder |
| `bin/fleet-report-stats.py` | 1 | gh-owner 1 | config |
| `bin/fleet-restore.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-services-selftest.sh` | 29 | machine 18 · person 9 · ts-net 2 | placeholder |
| `bin/fleet-session-cli-selftest.sh` | 52 | gh-owner 1 · machine 38 · person 8 · ts-net 5 | placeholder |
| `bin/fleet-session-cli.py` | 3 | machine 3 | config |
| `bin/fleet-session-wrap.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-shell-selftest.sh` | 101 | gh-owner 2 · machine 94 · person 5 | placeholder |
| `bin/fleet-shell-warm-selftest.sh` | 63 | gh-owner 1 · machine 50 · person 12 | placeholder |
| `bin/fleet-shell.sh` | 4 | machine 4 | placeholder |
| `bin/fleet-sidebar-menu.sh` | 3 | machine 3 | placeholder |
| `bin/fleet-sidebar-place-selftest.sh` | 36 | gh-owner 7 · machine 29 | placeholder |
| `bin/fleet-sidebar-selftest.sh` | 35 | machine 35 | placeholder |
| `bin/fleet-sidebar.py` | 13 | machine 13 | config + placeholder |
| `bin/fleet-spotlight-selftest.sh` | 4 | gh-owner 2 · machine 1 · person 1 | placeholder |
| `bin/fleet-spotlight.sh` | 2 | machine 2 | placeholder |
| `bin/fleet-status-7501-selftest.sh` | 2 | machine 2 | placeholder |
| `bin/fleet-status-replay-selftest.sh` | 2 | machine 2 | placeholder |
| `bin/fleet-switch-selftest.sh` | 13 | machine 13 | placeholder |
| `bin/fleet-tcc-disclaim.py` | 1 | machine 1 | config |
| `bin/fleet-thin-notify-selftest.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-topbar.py` | 2 | machine 2 | config |
| `bin/fleet-trust-selftest.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-trust.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-ui-lang.sh` | 2 | machine 2 | config |
| `bin/fleet-view-actions-selftest.sh` | 10 | machine 10 | placeholder |
| `bin/fleet-view-c7-selftest.sh` | 19 | machine 19 | placeholder |
| `bin/fleet-view-firstframe-selftest.sh` | 1 | machine 1 | placeholder |
| `bin/fleet-view-hub-fresh-selftest.sh` | 4 | machine 4 | placeholder |
| `bin/fleet-view-selftest.sh` | 22 | machine 20 · person 2 | placeholder |
| `bin/fleet-win-name-selftest.sh` | 5 | corp-domain 1 · gh-owner 1 · machine 3 | placeholder |
| `bin/fleet-worker-records-selftest.sh` | 12 | machine 12 | placeholder |
| `bin/fleet-worker-records.sh` | 3 | machine 3 | placeholder |
| `bin/fleet_control.py` | 1 | machine 1 | placeholder |
| `bin/fleet_decision.py` | 1 | machine 1 | config |
| `bin/fleet_view.py` | 3 | machine 3 | config |
| `bin/forkless-hotpath-selftest.sh` | 2 | corp-domain 2 | placeholder |
| `bin/hub-nudge-selftest.sh` | 2 | machine 2 | placeholder |
| `bin/hub-place-selftest.sh` | 169 | machine 169 | placeholder |
| `bin/hub-progress-selftest.sh` | 15 | machine 15 | placeholder |
| `bin/hub-relay-selftest.sh` | 11 | machine 11 | placeholder |
| `bin/hub-sessions-cert-scope-selftest.sh` | 6 | machine 6 | placeholder |
| `bin/hub-sessions-loop-selftest.sh` | 1 | machine 1 | placeholder |
| `bin/install-version-selftest.sh` | 8 | machine 8 | placeholder |
| `bin/issue-lease-selftest.sh` | 25 | machine 25 | placeholder |
| `bin/needs-notify-selftest.sh` | 4 | machine 4 | placeholder |
| `bin/newcomer-cn.sh` | 3 | corp-domain 1 · machine 1 · person 1 | config + placeholder |
| `bin/notify-selftest.sh` | 14 | machine 14 | placeholder |
| `bin/open-url.sh` | 1 | machine 1 | placeholder |
| `bin/operator-send-selftest.sh` | 4 | machine 4 | placeholder |
| `bin/oss-scan-selftest.sh` | — | — | allow |
| `bin/repo-view-all-selftest.sh` | 1 | corp-domain 1 | placeholder |
| `bin/scratch-pool-selftest.sh` | 1 | machine 1 | placeholder |
| `bin/session-title-selftest.sh` | 16 | machine 16 | placeholder |
| `bin/session-tokens-selftest.sh` | 3 | machine 3 | placeholder |
| `bin/shell-switch-repaint-selftest.sh` | 18 | machine 13 · person 5 | placeholder |
| `bin/shell-unbreakable-selftest.sh` | 5 | machine 3 · person 2 | placeholder |
| `bin/sidebar-batch-view-selftest.sh` | 4 | corp-domain 2 · gh-owner 1 · machine 1 | placeholder |
| `bin/sidebar-caret-tap-selftest.sh` | 2 | machine 2 | placeholder |
| `bin/sidebar-machine-tag-selftest.sh` | 17 | machine 17 | placeholder |
| `bin/sidebar-slot-selftest.sh` | 2 | machine 2 | placeholder |
| `bin/task-line-selftest.sh` | 4 | machine 4 | placeholder |
| `bin/tmux-dash-collect.sh` | 1 | corp-domain 1 | placeholder |
| `bin/tmux-dashboard-rows.sh` | 14 | machine 14 | placeholder |
| `bin/tmux-status-selftest.sh` | 61 | gh-owner 3 · machine 54 · person 4 | placeholder |
| `bin/tmux-status.sh` | 2 | machine 2 | placeholder |
| `bin/topbar-ctx-selftest.sh` | 3 | machine 3 | placeholder |
| `bin/worker-locate-selftest.sh` | 9 | machine 9 | placeholder |
| `bin/worktree-autoclean.sh` | 1 | corp-domain 1 | placeholder |
| `commands/fleet-handoff.md` | 1 | corp-domain 1 | placeholder |
| `commands/fleet-history.md` | 1 | gh-owner 1 | placeholder |
| `commands/fleet-move.md` | 2 | machine 2 | placeholder |
| `commands/fleet-sync-install.md` | 1 | machine 1 | placeholder |
| `conf/oss-scan.rules` | — | — | allow |
| `conf/tmux-shell-stage.conf` | 1 | machine 1 | placeholder |
| `conf/tmux-shell.conf` | 1 | machine 1 | placeholder |
| `deploy/k8s/README.md` | 8 | cloud 1 · corp-domain 7 | placeholder |
| `deploy/k8s/RUNBOOK.md` | 12 | cloud 3 · corp-domain 9 | placeholder |
| `deploy/k8s/base/ccquota-pricing.yaml` | 2 | cloud 1 · corp-domain 1 | config + placeholder |
| `deploy/k8s/credproxy/README.md` | 1 | corp-domain 1 | placeholder |
| `deploy/k8s/credproxy/prod/deployment-env.yaml` | 1 | corp-domain 1 | config |
| `deploy/k8s/credproxy/prod/ingress-hosts.yaml` | 5 | corp-domain 5 | config |
| `deploy/k8s/credproxy/prod/kustomization.yaml` | 2 | cloud 1 · corp-domain 1 | config |
| `deploy/k8s/overlays/prod/debug-volume.yaml` | 1 | cloud 1 | config |
| `deploy/k8s/overlays/prod/deployment-env.yaml` | 9 | corp-domain 5 · gh-owner 2 · machine 2 | config + placeholder |
| `deploy/k8s/overlays/prod/ingress-hosts.yaml` | 7 | corp-domain 7 | config + placeholder |
| `deploy/k8s/overlays/prod/kustomization.yaml` | 4 | cloud 2 · corp-domain 2 | config |
| `deploy/k8s/overlays/prod/release-volume.yaml` | 2 | cloud 2 | config + placeholder |
| `deploy/k8s/updating/README.md` | 3 | corp-domain 3 | placeholder |
| `deploy/k8s/updating/prod/kustomization.yaml` | 2 | cloud 1 · corp-domain 1 | config |
| `docs/ARCHITECTURE.md` | 1 | machine 1 | placeholder |
| `docs/BREAK-IT.md` | 136 | corp-domain 11 · gh-owner 10 · machine 95 · person 18 · private-ipv4 1 · user-home 1 | placeholder |
| `docs/CLIENT.md` | 17 | corp-domain 3 · gh-owner 1 · machine 13 | placeholder |
| `docs/CRED-RELAY.md` | 10 | corp-domain 10 | placeholder |
| `docs/CRED-SEPARATE.md` | 6 | corp-domain 2 · machine 4 | placeholder |
| `docs/DECISIONS.md` | 1 | machine 1 | placeholder |
| `docs/DEFAULTS-AUDIT.md` | 12 | gh-owner 2 · machine 8 · person 2 | placeholder |
| `docs/EMIT.md` | 1 | gh-owner 1 | placeholder |
| `docs/FLEET-HUB.md` | 26 | machine 25 · ts-net 1 | placeholder |
| `docs/FLEET-MCP.md` | 2 | machine 2 | placeholder |
| `docs/INSTALL.md` | 8 | gh-owner 2 · machine 6 | placeholder |
| `docs/LOCAL-AND-HUB.md` | 3 | machine 3 | placeholder |
| `docs/MANAGED-LINUX-DRILL.md` | 59 | corp-domain 15 · gh-owner 2 · machine 25 · person 15 · private-ipv4 1 · user-home 1 | placeholder |
| `docs/MANAGED-LINUX.md` | 29 | cloud 3 · corp-domain 10 · machine 9 · person 1 · private-ipv4 6 | placeholder |
| `docs/MANAGED-NODE.md` | 24 | corp-domain 6 · gh-owner 6 · machine 9 · person 3 | placeholder |
| `docs/MULTI-ACCOUNT.md` | 1 | person 1 | placeholder |
| `docs/MULTI-MACHINE-OPS.md` | 71 | corp-domain 1 · gh-owner 4 · machine 64 · person 2 | placeholder |
| `docs/OSS-PACKAGING-PLAN.md` | 18 | corp-domain 2 · gh-owner 6 · machine 2 · person 8 | placeholder |
| `docs/PHONE-MCP.md` | 44 | gh-owner 17 · machine 13 · person 7 · tailnet 3 · ts-net 3 · user-home 1 | placeholder |
| `docs/RESEARCH-CRED-PROXY.md` | 2 | gh-owner 2 | placeholder |
| `docs/ROLES-ACCEPTANCE.md` | 10 | machine 10 | placeholder |
| `docs/SHARED-MACHINE.md` | 4 | machine 4 | placeholder |
| `extras/cred-relay/Caddyfile` | 2 | corp-domain 2 | config + placeholder |
| `extras/cred-relay/fleet-relay-check.py` | 1 | corp-domain 1 | config |
| `extras/cred-relay/fleet-relay-check.service` | 1 | corp-domain 1 | config |
| `extras/gh-relay/README.md` | 3 | corp-domain 1 · machine 1 · private-ipv4 1 | placeholder |
| `extras/gh-relay/gh-relay.py` | 1 | private-ipv4 1 | config |
| `extras/gh-relay/gh-relay.service` | 3 | private-ipv4 3 | config + placeholder |
| `extras/iterm2/install.sh` | 2 | machine 2 | placeholder |
| `extras/iterm2/test_fleet_open.py` | 7 | machine 7 | config |
| `extras/laptop-url-opener.sh` | 1 | machine 1 | placeholder |
| `extras/managed-node/render.py` | 5 | private-ipv4 5 | config |
| `extras/managed-node/smoke.py` | 8 | corp-domain 8 | placeholder |
| `extras/spot-node/README.md` | 7 | cloud 3 · corp-domain 3 · machine 1 | placeholder |
| `extras/workflows/newcomer-cn.yml` | 5 | corp-domain 2 · machine 2 · person 1 | config + placeholder |
| `fleet.conf.example` | 11 | corp-domain 1 · machine 10 | placeholder |
| `hooks/bash-guard.py` | 1 | machine 1 | placeholder |
| `mod/fleet/tests/progress.test.tsx` | 3 | gh-owner 3 | placeholder |
| `mod/fleet/tests/state.test.ts` | 2 | machine 2 | placeholder |
| `mod/fleet/tests/where.test.ts` | 5 | gh-owner 3 · machine 2 | placeholder |
| `plugins/fleet-browser/.claude-plugin/plugin.json` | — | — | allow |
| `plugins/fleet-browser/skills/fleet-browser/SKILL.md` | 1 | machine 1 | placeholder |
| `plugins/fleet-epic/.claude-plugin/plugin.json` | — | — | allow |
| `plugins/fleet-epic/commands/fleet-epic-run.md` | 4 | machine 4 | placeholder |
| `plugins/fleet-feedback/.claude-plugin/plugin.json` | — | — | allow |
| `plugins/fleet-orchestrate/.claude-plugin/plugin.json` | — | — | allow |
| `plugins/fleet-orchestrate/skills/fleet-orchestrate/SKILL.md` | 1 | machine 1 | placeholder |
| `plugins/fleet-steward/.claude-plugin/plugin.json` | — | — | allow |
| `plugins/fleet-steward/tests/sheet-fixture.ts` | 5 | corp-domain 5 | placeholder |
| `shell/cw.zsh` | 2 | gh-owner 1 · machine 1 | placeholder |
| `skills/doc-preview/render.mjs` | 2 | machine 2 | config |
| `skills/doc-preview/share.sh` | 1 | machine 1 | placeholder |
| `tokenledger/README.md` | 36 | cloud 1 · corp-domain 1 · gh-owner 5 · machine 28 · private-ipv4 1 | placeholder |
| `tokenledger/cmd/ccquota/hub.go` | 2 | cloud 2 | config |
| `tokenledger/cmd/ccquota/hub_test.go` | 4 | gh-owner 2 · private-ipv4 2 | placeholder |
| `tokenledger/cmd/ccquota/lease_test.go` | 6 | machine 6 | placeholder |
| `tokenledger/cmd/ccquota/move_test.go` | 10 | machine 10 | placeholder |
| `tokenledger/cmd/ccquota/place_test.go` | 29 | machine 29 | placeholder |
| `tokenledger/cmd/ccquota/tls_test.go` | 17 | machine 5 · private-ipv4 2 · tailnet 2 · ts-net 8 | placeholder |
| `tokenledger/docs/superpowers/plans/2026-09-01-ccquota-badges-boards.md` | 12 | gh-owner 12 | placeholder |
| `tokenledger/docs/superpowers/plans/2026-09-01-ccquota.md` | 1 | gh-owner 1 | placeholder |
| `tokenledger/docs/superpowers/plans/2026-09-02-ccquota-dashboard-redesign.md` | 19 | gh-owner 18 · machine 1 | placeholder |
| `tokenledger/docs/superpowers/plans/2026-09-07-codex-auth-management.md` | 4 | corp-domain 1 · gh-owner 2 · machine 1 | placeholder |
| `tokenledger/docs/superpowers/plans/2026-09-07-codex-parity.md` | 12 | corp-domain 2 · gh-owner 3 · machine 2 · tailnet 2 · ts-net 2 · user-home 1 | placeholder |
| `tokenledger/docs/superpowers/plans/2026-09-12-provider-dimension.md` | 21 | cloud 17 · corp-domain 1 · gh-owner 2 · user-home 1 | placeholder |
| `tokenledger/docs/superpowers/plans/2026-09-13-tokenledger-ui.md` | 14 | cloud 6 · corp-domain 6 · gh-owner 1 · user-home 1 | placeholder |
| `tokenledger/docs/superpowers/specs/2026-09-12-tokenledger-provider-and-reorientation-design.md` | 5 | cloud 2 · corp-domain 3 | placeholder |
| `tokenledger/docs/superpowers/specs/2026-09-19-cost-per-issue-seam-design.md` | 2 | corp-domain 2 | placeholder |
| `tokenledger/internal/agent/beat_parts.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/agent/beat_parts_test.go` | 3 | machine 3 | placeholder |
| `tokenledger/internal/agent/fleet_test.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/agent/gitrepo_test.go` | 20 | gh-owner 20 | placeholder |
| `tokenledger/internal/agent/lane_state_test.go` | 1 | person 1 | placeholder |
| `tokenledger/internal/agent/node_accounts.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/agent/node_accounts_test.go` | 4 | corp-domain 4 | placeholder |
| `tokenledger/internal/agent/node_compute_test.go` | 2 | gh-owner 1 · machine 1 | placeholder |
| `tokenledger/internal/agent/node_creds_test.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/agent/node_entry_test.go` | 1 | private-ipv4 1 | placeholder |
| `tokenledger/internal/agent/node_machine_accounts.go` | 1 | corp-domain 1 | placeholder |
| `tokenledger/internal/agent/node_machine_accounts_test.go` | 5 | corp-domain 3 · person 2 | placeholder |
| `tokenledger/internal/agent/node_routes.go` | 5 | machine 1 · private-ipv4 3 · ts-net 1 | config + placeholder |
| `tokenledger/internal/agent/node_routes_test.go` | 13 | private-ipv4 11 · ts-net 2 | placeholder |
| `tokenledger/internal/agent/relay_test.go` | 3 | machine 3 | placeholder |
| `tokenledger/internal/agent/runas.go` | 2 | machine 2 | placeholder |
| `tokenledger/internal/agent/runas_unix.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/agent/runas_unix_test.go` | 2 | gh-owner 1 · machine 1 | placeholder |
| `tokenledger/internal/api/access.go` | 1 | corp-domain 1 | config |
| `tokenledger/internal/api/access_test.go` | 2 | ts-net 2 | placeholder |
| `tokenledger/internal/api/admin_pages_test.go` | 14 | gh-owner 1 · machine 11 · ts-net 2 | placeholder |
| `tokenledger/internal/api/admin_people_test.go` | 15 | gh-owner 10 · machine 3 · person 2 | placeholder |
| `tokenledger/internal/api/admin_views_test.go` | 10 | gh-owner 10 | placeholder |
| `tokenledger/internal/api/app_page_test.go` | 2 | machine 2 | placeholder |
| `tokenledger/internal/api/cost_source_test.go` | 1 | gh-owner 1 | placeholder |
| `tokenledger/internal/api/credential_label_test.go` | 1 | person 1 | placeholder |
| `tokenledger/internal/api/findings_i18n_test.go` | 2 | machine 2 | placeholder |
| `tokenledger/internal/api/fleet_accounts.go` | 4 | corp-domain 1 · gh-owner 1 · machine 2 | placeholder |
| `tokenledger/internal/api/fleet_accounts_test.go` | 118 | corp-domain 5 · gh-owner 33 · machine 77 · person 3 | placeholder |
| `tokenledger/internal/api/fleet_alerts_test.go` | 35 | gh-owner 8 · machine 27 | placeholder |
| `tokenledger/internal/api/fleet_attachment_test.go` | 28 | machine 24 · person 4 | placeholder |
| `tokenledger/internal/api/fleet_cert_selfcheck_test.go` | 9 | machine 9 | placeholder |
| `tokenledger/internal/api/fleet_certs.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/api/fleet_certs_test.go` | 19 | gh-owner 5 · machine 11 · private-ipv4 1 · ts-net 2 | placeholder |
| `tokenledger/internal/api/fleet_ci_runners_test.go` | 9 | machine 9 | placeholder |
| `tokenledger/internal/api/fleet_client_actions_test.go` | 5 | machine 4 · ts-net 1 | placeholder |
| `tokenledger/internal/api/fleet_client_place.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/api/fleet_client_place_test.go` | 105 | machine 102 · person 3 | placeholder |
| `tokenledger/internal/api/fleet_client_settings_test.go` | 2 | machine 2 | placeholder |
| `tokenledger/internal/api/fleet_client_test.go` | 14 | gh-owner 2 · machine 10 · person 2 | placeholder |
| `tokenledger/internal/api/fleet_compute.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/api/fleet_compute_probe_test.go` | 74 | machine 56 · person 18 | placeholder |
| `tokenledger/internal/api/fleet_compute_test.go` | 57 | machine 47 · person 10 | placeholder |
| `tokenledger/internal/api/fleet_cpu_busy_test.go` | 26 | machine 20 · person 6 | placeholder |
| `tokenledger/internal/api/fleet_cred_policy_test.go` | 33 | machine 33 | placeholder |
| `tokenledger/internal/api/fleet_credproxy_test.go` | 2 | machine 2 | placeholder |
| `tokenledger/internal/api/fleet_creds_test.go` | 13 | machine 13 | placeholder |
| `tokenledger/internal/api/fleet_credsep_test.go` | 14 | gh-owner 8 · machine 6 | placeholder |
| `tokenledger/internal/api/fleet_debug_test.go` | 9 | machine 7 · person 2 | placeholder |
| `tokenledger/internal/api/fleet_debug_ticket_test.go` | 3 | person 2 · private-ipv4 1 | placeholder |
| `tokenledger/internal/api/fleet_devices_test.go` | 57 | machine 40 · person 16 · ts-net 1 | placeholder |
| `tokenledger/internal/api/fleet_down_test.go` | 25 | corp-domain 1 · gh-owner 3 · machine 8 · person 9 · user-home 4 | placeholder |
| `tokenledger/internal/api/fleet_drill_test.go` | 71 | gh-owner 3 · machine 68 | placeholder |
| `tokenledger/internal/api/fleet_entry.go` | 1 | corp-domain 1 | placeholder |
| `tokenledger/internal/api/fleet_entry_autoname_test.go` | 3 | corp-domain 1 · machine 2 | placeholder |
| `tokenledger/internal/api/fleet_entry_defaults_test.go` | 5 | corp-domain 2 · machine 3 | placeholder |
| `tokenledger/internal/api/fleet_entry_device_test.go` | 11 | machine 11 | placeholder |
| `tokenledger/internal/api/fleet_entry_dns.go` | 2 | corp-domain 2 | placeholder |
| `tokenledger/internal/api/fleet_entry_dns_test.go` | 13 | corp-domain 2 · machine 11 | placeholder |
| `tokenledger/internal/api/fleet_entry_page_test.go` | 6 | corp-domain 2 · machine 4 | placeholder |
| `tokenledger/internal/api/fleet_entry_reach.go` | 2 | private-ipv4 2 | config + placeholder |
| `tokenledger/internal/api/fleet_entry_reach_test.go` | 22 | machine 11 · private-ipv4 11 | placeholder |
| `tokenledger/internal/api/fleet_entry_test.go` | 36 | machine 35 · person 1 | placeholder |
| `tokenledger/internal/api/fleet_feedback_github_test.go` | 3 | machine 1 · person 2 | placeholder |
| `tokenledger/internal/api/fleet_feedback_reply_test.go` | 40 | machine 30 · person 10 | placeholder |
| `tokenledger/internal/api/fleet_feedback_test.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/api/fleet_home_current_test.go` | 26 | machine 26 | placeholder |
| `tokenledger/internal/api/fleet_home_login_test.go` | 85 | gh-owner 9 · machine 46 · person 27 · private-ipv4 2 · user-home 1 | placeholder |
| `tokenledger/internal/api/fleet_hostkeys_test.go` | 3 | machine 1 · ts-net 2 | placeholder |
| `tokenledger/internal/api/fleet_hub_quota.go` | 1 | corp-domain 1 | config |
| `tokenledger/internal/api/fleet_hub_quota_test.go` | 2 | person 2 | placeholder |
| `tokenledger/internal/api/fleet_invites_test.go` | 4 | machine 4 | placeholder |
| `tokenledger/internal/api/fleet_join.go` | 1 | machine 1 | config |
| `tokenledger/internal/api/fleet_join_test.go` | 15 | gh-owner 13 · machine 2 | placeholder |
| `tokenledger/internal/api/fleet_leases.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/api/fleet_leases_test.go` | 53 | gh-owner 2 · machine 51 | placeholder |
| `tokenledger/internal/api/fleet_maintenance.go` | 2 | machine 2 | placeholder |
| `tokenledger/internal/api/fleet_maintenance_test.go` | 72 | machine 67 · person 3 · private-ipv4 2 | placeholder |
| `tokenledger/internal/api/fleet_move_test.go` | 47 | machine 43 · person 4 | placeholder |
| `tokenledger/internal/api/fleet_multirepo_test.go` | 38 | corp-domain 3 · machine 31 · person 4 | placeholder |
| `tokenledger/internal/api/fleet_node_identity_test.go` | 36 | corp-domain 2 · gh-owner 8 · machine 25 · person 1 | placeholder |
| `tokenledger/internal/api/fleet_node_login.go` | 5 | gh-owner 2 · machine 1 · person 2 | placeholder |
| `tokenledger/internal/api/fleet_node_login_test.go` | 39 | gh-owner 10 · machine 9 · person 18 · user-home 2 | placeholder |
| `tokenledger/internal/api/fleet_node_pool_test.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/api/fleet_node_retire_test.go` | 1 | gh-owner 1 | placeholder |
| `tokenledger/internal/api/fleet_node_tasks_test.go` | 1 | person 1 | placeholder |
| `tokenledger/internal/api/fleet_oauth_refresh_test.go` | 4 | machine 4 | placeholder |
| `tokenledger/internal/api/fleet_open_pick_test.go` | 82 | gh-owner 16 · machine 66 | placeholder |
| `tokenledger/internal/api/fleet_opening.go` | 2 | machine 2 | placeholder |
| `tokenledger/internal/api/fleet_opening_test.go` | 54 | gh-owner 10 · machine 44 | placeholder |
| `tokenledger/internal/api/fleet_orchestrator_test.go` | 3 | machine 3 | placeholder |
| `tokenledger/internal/api/fleet_peer_certs.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/api/fleet_peer_certs_test.go` | 46 | machine 39 · person 7 | placeholder |
| `tokenledger/internal/api/fleet_peer_list_test.go` | 13 | machine 9 · person 3 · ts-net 1 | placeholder |
| `tokenledger/internal/api/fleet_person_budget_test.go` | 7 | machine 1 · person 6 | placeholder |
| `tokenledger/internal/api/fleet_person_bundle_test.go` | 7 | machine 5 · person 2 | placeholder |
| `tokenledger/internal/api/fleet_person_roles_test.go` | 8 | machine 7 · person 1 | placeholder |
| `tokenledger/internal/api/fleet_personal.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/api/fleet_personal_test.go` | 50 | machine 48 · person 2 | placeholder |
| `tokenledger/internal/api/fleet_place_fallback_test.go` | 67 | machine 63 · person 4 | placeholder |
| `tokenledger/internal/api/fleet_place_score_test.go` | 43 | machine 42 · person 1 | placeholder |
| `tokenledger/internal/api/fleet_place_test.go` | 204 | machine 195 · person 9 | placeholder |
| `tokenledger/internal/api/fleet_principal_logins_test.go` | 64 | corp-domain 10 · gh-owner 24 · machine 30 | placeholder |
| `tokenledger/internal/api/fleet_progress_test.go` | 2 | machine 2 | placeholder |
| `tokenledger/internal/api/fleet_recent_test.go` | 45 | machine 44 · person 1 | placeholder |
| `tokenledger/internal/api/fleet_rekey_test.go` | 25 | corp-domain 15 · gh-owner 2 · machine 8 | placeholder |
| `tokenledger/internal/api/fleet_relay.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/api/fleet_relay_cred_test.go` | 28 | machine 28 | placeholder |
| `tokenledger/internal/api/fleet_relay_test.go` | 34 | machine 30 · person 4 | placeholder |
| `tokenledger/internal/api/fleet_release_push_test.go` | 7 | machine 7 | placeholder |
| `tokenledger/internal/api/fleet_release_train_test.go` | 3 | machine 3 | placeholder |
| `tokenledger/internal/api/fleet_relogin_cert_test.go` | 4 | machine 3 · ts-net 1 | placeholder |
| `tokenledger/internal/api/fleet_routes_test.go` | 31 | machine 15 · private-ipv4 5 · ts-net 11 | placeholder |
| `tokenledger/internal/api/fleet_service_ctl_test.go` | 7 | machine 7 | placeholder |
| `tokenledger/internal/api/fleet_service_log_test.go` | 11 | machine 11 | placeholder |
| `tokenledger/internal/api/fleet_services_test.go` | 15 | machine 15 | placeholder |
| `tokenledger/internal/api/fleet_session_cred_test.go` | 25 | machine 21 · person 4 | placeholder |
| `tokenledger/internal/api/fleet_sessions_test.go` | 38 | machine 34 · person 4 | placeholder |
| `tokenledger/internal/api/fleet_spare.go` | 2 | machine 1 · person 1 | placeholder |
| `tokenledger/internal/api/fleet_spare_test.go` | 46 | gh-owner 3 · machine 43 | placeholder |
| `tokenledger/internal/api/fleet_spot_test.go` | 21 | machine 14 · person 7 | placeholder |
| `tokenledger/internal/api/fleet_stale_admin_test.go` | 21 | gh-owner 10 · machine 11 | placeholder |
| `tokenledger/internal/api/fleet_stream_test.go` | 11 | machine 11 | placeholder |
| `tokenledger/internal/api/fleet_summary_test.go` | 27 | machine 27 | placeholder |
| `tokenledger/internal/api/fleet_tasks_test.go` | 29 | machine 29 | placeholder |
| `tokenledger/internal/api/fleet_team_bundle_test.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/api/fleet_team_push_test.go` | 5 | machine 5 | placeholder |
| `tokenledger/internal/api/fleet_test.go` | 37 | machine 37 | placeholder |
| `tokenledger/internal/api/fleet_tickets_test.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/api/fleet_trust.go` | 2 | machine 2 | placeholder |
| `tokenledger/internal/api/fleet_trust_test.go` | 28 | machine 28 | placeholder |
| `tokenledger/internal/api/fleet_usage_silent.go` | 1 | person 1 | placeholder |
| `tokenledger/internal/api/fleet_usage_silent_test.go` | 8 | gh-owner 2 · machine 1 · person 5 | placeholder |
| `tokenledger/internal/api/fleet_version_test.go` | 4 | machine 4 | placeholder |
| `tokenledger/internal/api/fleet_worker_assert_test.go` | 26 | machine 24 · person 2 | placeholder |
| `tokenledger/internal/api/fleet_worker_records_test.go` | 6 | machine 5 · person 1 | placeholder |
| `tokenledger/internal/api/fleet_write.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/api/fleet_write_test.go` | 81 | machine 70 · person 11 | placeholder |
| `tokenledger/internal/api/fleet_write_tools_test.go` | 78 | machine 74 · person 4 | placeholder |
| `tokenledger/internal/api/github_auth_test.go` | 15 | gh-owner 15 | placeholder |
| `tokenledger/internal/api/github_oauth_relay_test.go` | 2 | machine 2 | placeholder |
| `tokenledger/internal/api/hub_settings.go` | 4 | corp-domain 2 · machine 2 | config + placeholder |
| `tokenledger/internal/api/hub_settings_legacy_test.go` | 7 | corp-domain 3 · machine 4 | placeholder |
| `tokenledger/internal/api/hub_users_api_test.go` | 22 | corp-domain 5 · gh-owner 6 · machine 9 · private-ipv4 2 | placeholder |
| `tokenledger/internal/api/identity_pairs_test.go` | 1 | gh-owner 1 | placeholder |
| `tokenledger/internal/api/machine_role_test.go` | 4 | machine 4 | placeholder |
| `tokenledger/internal/api/me_quota_test.go` | 1 | gh-owner 1 | placeholder |
| `tokenledger/internal/api/me_usage_answer_test.go` | 9 | gh-owner 3 · machine 6 | placeholder |
| `tokenledger/internal/api/me_usage_test.go` | 2 | gh-owner 2 | placeholder |
| `tokenledger/internal/api/meter.go` | 3 | corp-domain 3 | config + placeholder |
| `tokenledger/internal/api/meter_test.go` | 4 | corp-domain 4 | placeholder |
| `tokenledger/internal/api/node_detail_test.go` | 38 | gh-owner 1 · machine 33 · tailnet 2 · ts-net 2 | placeholder |
| `tokenledger/internal/api/node_machine_accounts_test.go` | 18 | machine 13 · person 5 | placeholder |
| `tokenledger/internal/api/node_machine_test.go` | 54 | gh-owner 1 · machine 39 · person 14 | placeholder |
| `tokenledger/internal/api/node_route_test.go` | 35 | machine 27 · person 6 · private-ipv4 2 | placeholder |
| `tokenledger/internal/api/nodes.go` | 2 | machine 2 | placeholder |
| `tokenledger/internal/api/nodes_sys_test.go` | 16 | machine 16 | placeholder |
| `tokenledger/internal/api/nodes_test.go` | 9 | gh-owner 1 · machine 8 | placeholder |
| `tokenledger/internal/api/pagelang_test.go` | 3 | gh-owner 3 | placeholder |
| `tokenledger/internal/api/pagetext.go` | 2 | machine 2 | config |
| `tokenledger/internal/api/person_logins.go` | 2 | gh-owner 1 · person 1 | placeholder |
| `tokenledger/internal/api/person_logins_test.go` | 30 | corp-domain 7 · gh-owner 2 · machine 17 · person 4 | placeholder |
| `tokenledger/internal/api/pool_usage_test.go` | 10 | machine 7 · person 3 | placeholder |
| `tokenledger/internal/api/replica_state_test.go` | 2 | machine 2 | placeholder |
| `tokenledger/internal/api/review_test.go` | 2 | gh-owner 2 | placeholder |
| `tokenledger/internal/api/roles_test.go` | 8 | gh-owner 8 | placeholder |
| `tokenledger/internal/api/server.go` | 1 | corp-domain 1 | placeholder |
| `tokenledger/internal/api/server_test.go` | 7 | machine 7 | placeholder |
| `tokenledger/internal/api/sessions_count_test.go` | 1 | gh-owner 1 | placeholder |
| `tokenledger/internal/api/sessions_unknown_test.go` | 44 | machine 38 · person 6 | placeholder |
| `tokenledger/internal/api/ssh_relay.go` | 3 | machine 3 | placeholder |
| `tokenledger/internal/api/ssh_relay_replica_test.go` | 6 | machine 6 | placeholder |
| `tokenledger/internal/api/ssh_relay_test.go` | 5 | machine 5 | placeholder |
| `tokenledger/internal/api/tailscale.go` | 1 | private-ipv4 1 | config |
| `tokenledger/internal/api/testdata/entry_keys_375.html` | 2 | machine 2 | placeholder |
| `tokenledger/internal/control/control.go` | 3 | corp-domain 2 · machine 1 | placeholder |
| `tokenledger/internal/control/login_test.go` | 5 | corp-domain 3 · gh-owner 2 | placeholder |
| `tokenledger/internal/credproxy/credproxy_test.go` | 1 | private-ipv4 1 | placeholder |
| `tokenledger/internal/credvault/credvault_test.go` | 4 | machine 4 | placeholder |
| `tokenledger/internal/credvault/kms.go` | 3 | cloud 2 · private-ipv4 1 | config |
| `tokenledger/internal/credvault/refresh.go` | 1 | corp-domain 1 | config |
| `tokenledger/internal/credvault/refresh_test.go` | 8 | machine 8 | placeholder |
| `tokenledger/internal/dns/dns.go` | 6 | corp-domain 3 · person 3 | placeholder |
| `tokenledger/internal/dns/dnspod.go` | 1 | corp-domain 1 | config |
| `tokenledger/internal/dns/dnspod_test.go` | 9 | corp-domain 4 · person 5 | placeholder |
| `tokenledger/internal/findings/findings_test.go` | 12 | machine 4 · person 8 | placeholder |
| `tokenledger/internal/fleetid/fleetid_test.go` | 8 | corp-domain 1 · gh-owner 6 · user-home 1 | placeholder |
| `tokenledger/internal/mcp/roles_test.go` | 2 | gh-owner 2 | placeholder |
| `tokenledger/internal/release/fetch.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/sshca/sshca_test.go` | 6 | gh-owner 1 · machine 2 · person 3 | placeholder |
| `tokenledger/internal/sshca/sshd_test.go` | 2 | machine 2 | placeholder |
| `tokenledger/internal/store/cost_guard_test.go` | 4 | gh-owner 4 | placeholder |
| `tokenledger/internal/store/fleet_accounts.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/store/fleet_cred_policy_test.go` | 3 | machine 3 | placeholder |
| `tokenledger/internal/store/fleet_node_conns_test.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/store/fleet_spot.go` | 2 | machine 2 | placeholder |
| `tokenledger/internal/store/fleet_version_test.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/store/fleet_worker_records.go` | 1 | machine 1 | placeholder |
| `tokenledger/internal/store/gitrepo_test.go` | 19 | gh-owner 19 | placeholder |
| `tokenledger/internal/store/resolve.go` | 1 | person 1 | placeholder |
| `tokenledger/internal/store/resolve_test.go` | 4 | person 4 | placeholder |
| `tokenledger/internal/store/rollup_query_test.go` | 1 | gh-owner 1 | placeholder |
| `tokenledger/internal/store/sources_test.go` | 1 | cloud 1 | placeholder |
| `tokenledger/web/dist/admin/settings.js` | 1 | machine 1 | config |
| `tokenledger/web/dist/landing.html` | 3 | corp-domain 2 · machine 1 | placeholder |
| `tokenledger/web/dist/lib/admin.js` | 5 | machine 2 · person 3 | placeholder |
| `tokenledger/web/test/admin.test.mjs` | 70 | corp-domain 5 · gh-owner 13 · machine 32 · person 17 · ts-net 3 | placeholder |
| `tokenledger/web/test/machine-role.test.mjs` | 11 | machine 8 · person 3 | placeholder |
| `tokenledger/web/test/machine-view.test.mjs` | 14 | corp-domain 4 · machine 6 · tailnet 2 · ts-net 2 | placeholder |
| `tokenledger/web/test/pages.test.mjs` | 52 | gh-owner 3 · machine 36 · person 13 | placeholder |
| `tokenledger/web/test/router.test.mjs` | 6 | machine 6 | placeholder |
| `tokenledger/web/test/services.test.mjs` | 11 | machine 5 · person 4 · ts-net 2 | placeholder |
| `tokenledger/web/test/svc-log.test.mjs` | 3 | machine 2 · ts-net 1 | placeholder |
| `tokenledger/web/test/usage-view.test.mjs` | 9 | gh-owner 4 · machine 3 · person 2 | placeholder |
