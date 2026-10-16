# C9 测试专用隔离与计数入口

`bin/nogh_live_driver.py --test-only` 为 [C9](TASK-ACCEPTANCE.md) 的一行提供
G3/G4 隔离与独立观测。它默认关闭；生产 `off_template`、生产 proxy 和
普通 `--egress-closed` 不会自动选择此实现。合并、配置通过、guard 安装和
真实观察是不同状态。完整 C9 的业务断言仍由现场 owner 判断。

这个入口不创建账号、不 join、不部署、不修改 task/launch、不补 receipt，也不
接管已经运行的 Hub 或 native。现场 owner 先通过正常管理入口准备独占测试资源；
从其原始创建响应绑定实际对象，再启动整棵测试进程树。无法把全部参与执行面置于
下述边界时，这个入口不适用，相关 live 行保持 NOT RUN。

## 运行边界

每次运行只执行 A1–A12 中一行，使用五个全新的 Pod：`hub`、`node-a`、
`node-b`、`proxy`、`dns`。两节点是正常登记的独立 endpoint/login，使用受支持的
无 root core 的 `user-pod`/foreground 路径。Hub、节点控制面、launcher、native、
客户端/浏览器及该行操作必须是各自 workload 的后代；不能从测试边界外再启动一份
客户端或浏览器并把它算进本次观察。

每个 Pod 的 init guard 等待绑定，然后安装其私有网络命名空间的规则。
主容器的独占 PID 1 启动 `strace → broker → workload/controls`，所有后代直到
退出都在观察中。没有 sidecar、共享 PID/network、host volume、自动挂载的 API token、
生命周期 hook 或 exec probe。准入拒绝 exec、port-forward、ephemeral container 和
Pod spec 更新；只有本次 controller 可以 attach 两个固定控制入口。

镜像必须有对应的普通登录（UID/GID 均至少 10000）。workload 无 capabilities，
启用 no-new-privileges；它不能访问 root-only 控制文件、计数通道和代理私钥。
工作目录和 HOME 是自己拥有的 `/tmp/c9-workload`。这里不创建登录，也不使用
生产 HOME。所需的已登记配置由 owner 从该测试登录的正常管理产物准备。

每行预算最多 55 秒；driver 正常工作最多 50 秒，预留退出核验，55 秒硬截止。
每个原始 Pod 还有 55 秒 active deadline，容器入口也有独立上限。准备镜像、登记
账号、创建测试 namespace 是 owner 的管理步骤；单次测试入口从首次预检到退出、
准备网络和清理均严格小于 60 秒。不要通过延长限制运行长场景；把 C9 的独立子场景
分别放入新的资源代次，保留它们与同一 A 行的关系。

## owner 需要准备的产物

构建 [测试 overlay](../../extras/managed-node/c9/Dockerfile)，构建上下文为源码根。
`C9_BASE` 是已验证的 managed-node 镜像 digest，`C9_SOURCE_SHA` 是完整提交 SHA。
镜像由正常发布入口产出；recipe 中记录最终 OCI digest，不接受 tag。
overlay 固定可信入口、strace 二进制摘要和源码版本。`build_digest()` 的规范化文件
摘要集合给出 `observer_digest`；同时 pin 每个 workload 文件的 SHA256。

在新的 `c9-<run UUID>` namespace 中，准备以下不可变对象。不要将真实凭据放入
recipe、Git、命令参数或公开记录。

| 对象名（每个 Pod 名为 `<name>`） | 内容与权限 |
|---|---|
| `<name>-workload` ConfigMap | `immutable: true`；可执行 `workload`，挂载 `/opt/fleet-c9`；proxy/dns 使用空对象，不能提供替换服务 |
| `<name>-credentials` Secret | `immutable: true`；普通 workload 自己的最小凭据与 `ca.pem`；0444，普通测试登录可读 |
| `<name>-control` Secret | `immutable: true`；`hub-token`、`provider-probe.json`；0400，仅可信控制程序可读 |
| `<proxy-name>-tls` Secret | `immutable: true`；`tls.crt`、`tls.key`；0400，独立挂载，仅可信 adapter 可读 |

`hub-token` 是测试 Hub 的正常 operator/admin 凭据，不能放进普通 workload Secret。
`ca.pem` 包含该测试 Hub 和 adapter 的 CA；adapter 证书覆盖精确允许的 HTTPS 域名。
外部 origin 仍以系统 CA 验证，使用 pin 的 IP 和原域名 SNI。`provider-probe.json`
是 owner 选定的真实成功请求，字段为 `url`、`method`（GET/POST）、`headers`、`body`
（字符串）；它仅存在 root-only Secret 中，成功必须有 2xx 和非空响应。

`workload` 接收一个位置参数：`start` 启动正常服务，`row:A<N>` 执行本行，
`stop` 正常停止它自己的服务。A4 还接收 `row:A4-denied`、`row:A4-restored`，分别执行
实际被拒绝和恢复后的 GitHub PR 门读取。后台服务、native 和子任务必须继承这棵树；
不能调用 Kubernetes exec、宿主守护、共享 tmux server 或其他运行中的测试资源。
workload 退出 0 只是命令完成，不能自己宣告 C9 PASS。业务证据由 owner 在受支持的
任务/权威 API 上核验；driver 不接受 workload 自报网络计数。

## recipe 与路由

精确 schema 在 [contract](../../bin/nogh_live_contract.py) 的 `validate()`。
所有输入文件是当前用户拥有的普通文件、0600、非 symlink；证据目录新建为 0700，
放在 Git 工作树之外。

| recipe 字段 | 约束 |
|---|---|
| `version`, `purpose` | `1`、`c9-disposable-test` |
| `run_id`, `generation`, `source_sha` | 本次 UUID、正整数代次、40 位 SHA |
| `namespace`, `namespace_uid`, `cluster_uid` | namespace 名、已创建 namespace 的真实 UID、`kube-system` 的真实 UID |
| `controller` | `system:serviceaccount:<namespace>:c9-controller`，专用 kubeconfig 的实际身份 |
| `expires_at`, `budget_seconds`, `row` | 一小时内过期的 Unix 时间、5–55 秒、A1–A12 中一行 |
| `hub` | `origin`（HTTPS，显式端口）、实际 account-key 的 `key_digest`、完整运行提交 `commit` |
| `endpoints` | 五个角色，逐项 `role/name/login/image/observer_digest/command_digest/tls_cert_digest/binding` |
| `routes` | render recipe 中必须为空；实际地址由 run 的新鲜 API 读取填入 |
| `probes` | 本次实际 GitHub IPv4/IPv6、旁路 IPv4 和端口；正控制不能与允许目的重叠 |

两节点的 `binding` 含 `endpoint_id/fleet_id/machine_id/hostname/owner`；其余角色为
null。仅 hub/node 有 `command_digest`，仅 proxy 有 `tls_cert_digest`，其他为 null。
未来 Pod UID/IP 不出现在 recipe 中。driver 从原始创建响应与新鲜 GET 一一核对，
写入 `uid/pod_ip/execution_generation:1`。相同名字的替换 Pod 不可继续。

独立 routes 文件是数组，每项仅有 `from/to/purpose/ip/port/protocol/origin`。
内部 `to` 是角色名，`ip:null`，绑定后换成该原始 Pod 的真实 IP。外部只能由 proxy
经 TCP/HTTPS 到 `provider-origin`、`forge-origin`，A4 可另列 `github-origin`。
origin 必须带精确端口；DNS 项 `origin:""`、`to:"dns"`、端口 53。为每个角色列出
Hub、proxy 和 DNS 的实际需要（DNS 要有 UDP/TCP 两项），以及正常节点 peer 路由。
不能填 CIDR、默认 DNS、共享 proxy、DoH/DoT 或直接外部 IP 旁路。

## 正式入口顺序

1. owner 在授权的测试集群创建 namespace、专用 controller/RBAC、已登记账号产物和
   上述 immutable 对象。controller 需要读取本次 namespace/Pod/artifact 和策略，
   attach 固定容器，并执行被拒绝的 exec/ephemeral 正控制；不能以泛 RBAC 拒绝代替
   已安装策略的拒绝。所有其他入口都应在本次资源创建前停止使用它们。
2. 在私有目录运行 render：

   ```sh
   umask 077
   python3 bin/nogh_live_driver.py --test-only render --recipe recipe.json --output rendered.json
   ```

   render 只写一个 Kubernetes List，不 apply。通过正常管理入口先安装其中的四个
   ValidatingAdmissionPolicy 及 bindings，等待各自 `observedGeneration` 和无警告的
   typeChecking。然后才创建 ServiceAccount 和五个 inert Pod；不要一次 apply 整个
   List 来省略这个顺序。集群需支持 admissionregistration.k8s.io/v1 的 VAP。
3. 保存真正的创建输出。若 kubectl 按对象输出多个 JSON，可用 `jq -s
   '{apiVersion:"v1",kind:"List",items:.}'` 只加 List 容器；不能改对象 UID、状态或
   构造创建回执。等待原始 init guard 正在运行，立即调用：

   ```sh
   python3 bin/nogh_live_driver.py --test-only run \
     --recipe recipe.json --routes routes.json --created created.json \
     --kubeconfig controller.kubeconfig --evidence /private/c9/new-run
   ```

   Pod 的 deadline 从原始创建起计时，不能留着惯性复用；超时后需 owner 正常准备
   新的一代。driver 不重启、不重新创建、不把未知原始对象接管成成功。
4. driver 核验实际集群/namespace、原始 Pod、digest、策略和 immutable artifact，
   现场证明 exec/ephemeral 被命名策略拒绝，然后绑定 guard。只有双栈安装成功才能
   启动 observed；attach 后 hello 握手防止丢失 ready。
5. 等真实 Hub 和两节点的正常身份 API 就绪。Hub key/运行版本、endpoint、fleet、
   machine、login、owner 必须吻合，targeted status 必须来自 live。仅启动未就绪可
   有界重试，身份冲突立即拒绝；没有全量 refresh 或身份修补。
6. 五个角色逐一独立执行非零拒绝正控制：GitHub 域名/直接 v4/v6、UDP/TCP DNS、
   proxy 旁路、PATH/绝对路径 gh、execveat、sendmsg/sendmmsg。再执行真实 Hub 和
   provider 成功正控制，之后才进入正式行。控制缺失、意外成功或观察丢失都失败。

## 观察、协议和退出

默认 DROP 同时作用于 IPv4/IPv6 INPUT/FORWARD/OUTPUT；仅精确路线和受限回复放行。
已有 socket 或已有非 policy 规则会拒绝安装；从不 flush 共享规则。DNS 只回答本次
静态映射，没有上游；adapter 终止 TLS 并逐请求检查 authority，拒绝透明 CONNECT、
重定向造成的新目的和 framing 歧义。支持 HTTP/1.1（包括响应流）和验证过的 WebSocket
升级及帧；不支持 HTTP/2-only、压缩 WebSocket 扩展或 chunked 请求，遇到它们失败，
不能把失败当成 provider 允许控制成功。

observer 记录 execve/execveat、clone/exit、connect/sendto/sendmsg/sendmmsg、已有
socket 上的 write/writev/sendfile/splice，失败尝试也计数。io_uring_setup 注入 ENOSYS
并要求真实正控制；io_uring_enter、成功的 namespace/FD 注入拒绝。SCM_RIGHTS 仅接收
strace `-yy` 在内核边界解码为普通文件、pipe、anon inode 或 Unix socket 的描述符；
Internet socket 传递、缺类型或截断控制消息拒绝，不能用应用给出的类型补齐。
FD/OFD 并发排序不确定、未知 strace 格式、非主线程 exec 特殊生命周期、丢事件、
缺 EOF 或未退出后代都不能 PASS。原始 trace 只在内存中解析，不保存 argv/env、
请求 payload、token 或原始错误文本。

A4 的 GitHub 路线最初不安装、DNS 也不回答；仅 `row:A4-restored` 由可信 supervisor
打开其私有精确链，离开区间立即撤销。被拒绝和恢复读取分别计数，不能合成零区间。
所有普通正式行及收尾区间都要求 GitHub/unknown/拒绝计数为零。

成功需原始 Pod 全部 Succeeded、原始 imageID、restartCount 0、正常退出和完整流
关闭。失败/取消只关闭自己打开的 attach；独占 PID 1 退出及 Pod deadline 约束其
后代。driver 随后在剩余预算内核对原始 UID 的终态，不 delete 资源、不按宿主 PID
扫描杀进程；无法证明终止时回执明确 `NOT VERIFIED`，退出 125。owner 根据真实 UID
检查并通过正常管理入口清理保留的对象，最后卸载该 run 的策略，不能把未知清理状态
转写为成功。

证据包含 0600 `manifest.json`、`observations.json` 和 `receipt.json`。回执分列
`config/installed/live/cleanup`，成功矩阵是 `g3_g4:PASS`、`live:OBSERVED`、
`c9:OWNER VERDICT REQUIRED`。owner 还须结合每行实际业务/原生证据给出 C9 判定。
CI 的离线契约、私有 Linux namespace 和本地 TLS 测试均不是 live 证据。
