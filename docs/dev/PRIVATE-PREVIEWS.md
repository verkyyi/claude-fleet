# Fleet Preview · 私人实时预览

## 使用与范围

Task 详情的「Fleet Preview · 私人实时预览」访问这个 Task 正在运行的 HTTP/API/SSE/WebSocket 服务；
保存的 HTML/Markdown 继续使用 Space / 活页，没有新增 Artifact 存储。
预览只属于 Task 所有者，管理员没有代看入口。首次打开先到 Hub 登录，再回到独立的
预览 HTTPS origin。URL 本身不是访问密码。用户可在 Task 详情续期或关闭；关闭不停止
Worker 或应用。节点断线显示离线，连接失败返回 502/503。

V1 只接受同一托管账号的 Unix domain SOCK_STREAM HTTP 服务：
`~/.fleet-preview` 必须属于实际 UID、权限 0700；socket 属于该 UID、权限 0600。
注册只传 socket basename（例如 `app.sock`），不接受 URL、IP、TCP 端口、CONNECT
或 SOCKS。只有 TCP listener 的框架暂不支持。PF、SSH DisableForwarding 和凭据网关
没有例外变化，也不依赖 `ssh -L`。

Agent 在自己的已验证 Task 会话中使用：

```sh
fleet preview register app.sock
fleet preview list
fleet preview renew <preview-id>
fleet preview close <preview-id>
```

MCP `preview` 工具提供同样的 `register/list/renew/close`，身份来自当前已验证的
worker credential、node enrollment 和 Task，不能指定 owner、UID、login 或上游地址。
旧会话若工具清单未刷新，可使用 CLI，或按现有会话恢复流程重新打开。
初始租约 2 小时，默认每账号 3 个预览、32 个并发请求（包含 WS/SSE）、请求体 10 MiB；
与 Worker 并发数独立。关闭、到期、登录代际变化、节点重登记、Task 归属变更会拒绝新
请求，并在正常数据库响应时约 1 秒内关闭已有连接；数据库失联看门狗约 5 秒关闭。

试用租户需要有效且尚未耗尽的 trial、匹配的托管机器、active managed login 和自己的
真实 Task。仅有短聊天试用、没有这条 Task 身份路径的账号不能注册；未扩大一般 trial
页面权限。到期或重新分配会撤销预览。

## 最小应用

仓库的 `examples/private-preview/` 包含实际 listener 和浏览器热更新夹具。
Node 使用当前受 Vite 支持的 Node 版本（验证使用 Node 26）：

```sh
cd examples/private-preview
npm ci
node server.mjs                       # 原生 Node HTTP，example.sock
PREVIEW_SOCKET=express.sock node server.mjs --express
# 在对应 Agent Task 中 register 相应 basename，取得精确 hostname 后：
PREVIEW_SOCKET=vite.sock PREVIEW_HOST=<preview-id>.<preview-base-domain> node server.mjs --vite
```

Vite 是显式 opt-in：使用 middleware mode，把 HMR 绑定同一个 Unix HTTP server，
客户端 WSS 443、精确 allowedHosts；不会修改项目配置，也不承诺兼容所有框架。
每个示例都实现 POST `/api`、SSE `/events`、WS echo `/ws`。

Uvicorn：

```sh
python3 -m venv /tmp/preview-venv
/tmp/preview-venv/bin/pip install 'uvicorn[standard]'
mkdir -p "$HOME/.fleet-preview"
chmod 700 "$HOME/.fleet-preview"
umask 077
/tmp/preview-venv/bin/uvicorn app:app --uds "$HOME/.fleet-preview/uvicorn.sock"
# 服务启动后，在另一个终端执行，再注册：
chmod 600 "$HOME/.fleet-preview/uvicorn.sock"
```

Uvicorn 0.39 会主动把新建 socket 设成 0666，覆盖 umask；因此需要上面的显式 chmod。
父目录始终保持 0700，未设为 0600 的 socket 会被 helper 拒绝。

应用可保留 host-only Cookie 和自定义 X headers；代理移除平台 Cookie、Authorization、
转发身份 headers。响应禁止 Domain Cookie 和保留的平台 Cookie 名，保留应用 Cookie
并强制 Secure。预览禁用缓存、Service Worker 和嵌入；需要这些功能的应用不在 V1 范围。
开发代码与平台使用不同 registrable domain。应用脚本本身仍可设置普通父域 Cookie，
所以普通应用 Cookie 不作为平台身份；平台身份使用浏览器强制的 `__Host-` Cookie。

## 身份与连接边界

Hub 共享数据库保存租约、一次性 state/ticket、预览会话及并发名额；随机预览 ID 为
128 bit / 32 hex（单 DNS label），认证随机值为 256 bit / 64 hex，只存哈希。
票据短效、一次性且绑定 owner、preview、state、精确 callback；后续每次请求和 WS
握手都检查身份，长连接周期复核。Hub session 撤销、trial 到期、账号 generation、
node token rotation 均失效。任一副本处理页面或 relay 都读相同授权；relay 表仅存传输句柄。

节点复用 outbound relay，按需启动轻量 `preview-pipe`，先降权到实际租户 UID，再查
kernel UID 的 home。逐级 openat/O_NOFOLLOW 检查路径，fchdir 固定目录；连接前后
比对 socket inode，并在任何应用字节发送前检查实际 peer UID（macOS LOCAL_PEERCRED，
Linux SO_PEERCRED）。root/system、其他 UID、symlink 或非私人路径拒绝。

安全保证是**零应用字节到其他 UID/root**，包括 socket 替换和 ABA。inode 检查是纵深
防御，不承诺同 UID 服务 inode 永久不变；同 UID 应用本来就在允许的边界内，也可以自行
实现转发。helper 不以 root 解释租户代码，不启动每 Worker 常驻代理。

## 部署清单（由 root 发布）

默认 `CCQUOTA_PREVIEW_BASE_DOMAIN` 为空，功能不可用，不退回 Hub 同源。本 PR 不改变
生产配置。发布前由部署负责人准备：

- `CCQUOTA_PREVIEW_BASE_DOMAIN`：明确的 DNS 后缀，与 Hub 使用不同 registrable domain；
  只接受精确 `<32-hex-id>.<suffix>` Host，无任意 Host/URL 回退。
- `CCQUOTA_FLEET_PUBLIC_URL`：真实 HTTPS Hub origin，所有副本一致。
- `CCQUOTA_PREVIEW_HUB_ALIASES`：可选逗号分隔的旧 Hub 精确 DNS Host（同一 Hub site）。
  现有 ccquota alias 若仍有客户端使用，需要显式列入，例如 `ccquota.example.com`，
  不从任意请求 Host 推导。健康探针允许非预览 Host 的 GET/HEAD `/healthz`、`/readyz`；
  现有内部 replica hop 必须带有效 replica token，预览 origin 永不进入 Hub 路由。
- wildcard DNS 与证书覆盖 `*.<preview-base-domain>`；TLS 由现有 ingress/LB 终止，
  保留原 Host，支持 WS Upgrade 与流式响应，关闭缓存／响应缓冲，合理长连接超时。
  ingress/LB 的 callback access log 必须关闭 query 或脱敏 state/ticket；Hub logRequests
  已不记录 query，但上层代理不能记录一次性票据。
- Hub 各副本共享同一 SQLite（单机）或 PostgreSQL 数据库及现有 replica 设置／密钥。
  数据库迁移通过 EnsureNodes 自动建表。无需浏览器到 node 的入口。
- 更新 Hub、节点 ccquota 与 fleet CLI/MCP；节点需公布 `preview-uds-v1` capability。
  复用现有 outbound node relay 和降权执行能力，不增常驻服务、PF 规则或 SSH 转发。
- 唯一设置注册表中的 `fleet.preview_limits` 可配置 JSON `default/accounts/nodes/groups`，
  字段 `previews/connections/lease_seconds/body_bytes`；scope 分别使用账号 principal、
  机器 hostname、现有 endpoint team。各层取更严格的值，0 继承，不能超过 V1 上限。

## 验证夹具

```sh
(cd tokenledger/hub && go test ./api ./store -run 'TestPreview' -count=1)
(cd tokenledger/agent && go test ./... -run '^TestPreview' -count=1)
(cd tokenledger/e2e && go test -run '^TestPreview' -count=1)
```

多 UID 对抗：从 agent 模块编译 `go test -c -o /tmp/preview-agent.test`，由有权限的
测试负责人执行 `FLEET_PREVIEW_TEST_UIDS=<uid-a>,<uid-b> /tmp/preview-agent.test
-test.run '^TestPreviewTwoUIDs$' -test.v`。测试使用已存在的两个普通 UID，不创建账号；
macOS 使用 `/Users` 下临时目录，Linux 使用 `/` 下临时目录（都避开可写祖先），退出清理。
覆盖实际同 UID 成功、异 UID/root 直接连接、socket 替换 ABA、symlink ABA，服务端断言零
应用字节。未以 root 运行会明确 skip，不能把 skip 当验收通过。

浏览器使用仅本地的 TLS fixture，Chromium host resolver 映射保留真实 HTTPS hostname，
不修改 hosts、DNS 或证书。先开示例 Vite（固定测试 hostname 仅用于夹具）：

```sh
cd examples/private-preview
PREVIEW_SOCKET=fixture.sock PREVIEW_HOST=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.preview.example.net node server.mjs --vite
```

另一个终端从 `tokenledger/e2e`：

```sh
FLEET_PREVIEW_TEST_SOCKET=fixture.sock FLEET_PREVIEW_BROWSER_FIXTURE=/tmp/fleet-preview-browser.json \
  go test -run '^TestPreviewHTTP' -v -count=1 -timeout 20m
```

再从示例目录运行 `node browser-check.mjs`（Linux 可设置 `CHROME_PATH`）。脚本实际修改并
还原 `message.js`，等待 Vite update frame，确认 DOM 更新且没有重新加载 document，
验证 POST/SSE，截图写到 `/tmp/fleet-preview-hmr-{desktop,mobile}.png`。
夹具文件含仅测试身份，权限 0600，不提交／分享；删除该文件结束夹具，测试继续验证撤销
已有 WS 并清理。停掉示例进程。设置 `FLEET_PREVIEW_TEST_SOCKET` 也可对原生 Node、Express、
Uvicorn 执行同一套真实 relay POST/SSE/WS 验证。
