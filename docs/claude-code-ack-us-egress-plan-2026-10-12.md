# Claude Code 在 ACK 运行、由美国家庭网络出站：实施规划

日期：2026-10-12。选择：**现有美国家庭出口先行；本轮不购买云网关。**

## 决策与当前状态

采用“ACK 内统一出站代理 → 认证加密反向隧道 → 美国家庭网关 → 美国 AT&T 家庭网络”的路径。美国家庭网关主动连接 ACK 现有 HTTPS 入口，不要求家庭路由器开放入站端口，不新增公网负载均衡。

固定美国出口能减少出口位置变化、统一不同程序的网络路径。它不能证明大陆实际使用场景具有服务资格，也不能保证免封。美国购买地、账单与长期使用历史不是“一定不会暂停”的充分条件。Anthropic 没有公布“一账号一个固定 IP 即可安全”的规则，也没有可靠的美国/新加坡出口封禁率对照。

本轮已部署独立的 `fleet-us-egress` 反向网关与美国家庭网关守护、`fleet-egress` 统一代理；真实 ACK canary 已测试 API、登录平台、连接器、下载和遥测的 TLS 路径及禁止直连。**生产 worker 已重启，但尚未启用 Claude 生产流量**：运营者授权直接重启并要求暂时仅运行 Codex。节点订阅白名单只保留已允许的 Codex 订阅；Claude 凭据已通过受支持的 pool-sync 清除，登录默认代理设置为 Codex。未执行真实 Claude 账号测试。签名运行时的 CONNECT 改动仍需通过 PR、检查和正常发布。恢复 Claude 前还须验证 OAuth 刷新路径，特别是 Pod 之外的 hub/relay 刷新流量；不能把 CLI 代理设置视为这些流量已走美国的证明。

目标用户 的 home 保持 美国家庭网关。已暂停订阅 保持全局暂停；不增加各节点单独禁用，也不处理 已暂停订阅 恢复。

## 1. 实测与家庭出口可行性

美国家庭网关 对外 IP：`运营者私有清单中的出口地址`，US / California，AS7018 AT&T Enterprises, LLC。它是本次观测到的家庭出口，不是 ISP 承诺的永久静态地址。美国家庭网关 已关闭自动睡眠、开启断电后重启；家庭路由器和光猫仍是单点。

| 测量 | 结果 | 解释 |
| --- | --- | --- |
| ACK Pod → 家庭公网 TCP 22/80/443 | 超时 | 无入站映射，不能把公网 IP 直接当 CONNECT 服务使用 |
| ACK ↔ 美国家庭网关 认证 WSS ping | 33 个短时样本；最小 177.6 ms，中位 192.3 ms，P95 691.1 ms，最大 705.5 ms | 新建/恢复连接时测量；有尖峰，不能外推日常 P95 或 SLA |
| ACK → 美国家庭网关 → `api.anthropic.com` | TLS 506–1387 ms，首字节 909–1826 ms，HTTP 404 | 无凭证 HEAD 根路径；404 表示目标回答，不能证明订阅可用 |
| 同路径 → `platform.claude.com` | TLS 893–1115 ms，首字节 1186–1808 ms，HTTP 200 | 网络与证书验证通过；未执行登录 |
| 同路径 → GCS 官方 Claude Code `latest` | TLS 515–1308 ms，首字节 789–1688 ms，HTTP 200 | 下载元信息可达；不是大文件吞吐测试 |
| 同路径 → `claude.ai/login` | 首字节 614–838 ms，HTTP 403 | TLS 到达，页面拒绝无浏览器的 HEAD；不把它解释为账号被封或 OAuth 成功 |
| 同路径 → `downloads.claude.ai/` | 首字节 698–910 ms，HTTP 403 | 根路径响应不代表具体安装包是否可下载 |
| 带实际出站守卫的 canary | API、平台、MCP、bridge、GCS、遥测均完成 TLS；直连 IPv4/IPv6/元数据被阻断 | 验证代理路径和守卫；尚未验证真实 OAuth 生命周期 |
| 暂停 美国家庭网关 出口守护 | 代理返回 502；恢复后 API 又返回 404 | 无美国隧道时失败关闭，没有静默直连 |

MCP 根路径返回 404、bridge 根路径返回 426、遥测根路径返回 403，均只是无凭证 HEAD 的 HTTP 结果。它们证明 TLS 连接及传输路径，不证明真实连接器会话或遥测提交成功。测试没有使用被暂停的 已暂停订阅 订阅。

现有 SG 路径的单次观测：ACK → SG TCP 443 约 55 ms、美国家庭网关 → SG TLS 连接约 532 ms。这不是同条件、同样本量的美国/新加坡性能对照，不用于宣称美国更快。

**结论：家庭出口技术上可用，适合先试点。** 约 190 ms 的常见跨境 RTT 可用于交互请求；长响应生成耗时还受模型、上下文和服务负载影响。需要继续观察尖峰、家庭上行和长流，当前不能承诺持续稳定。第二轮平台 TLS 曾出现约 11 秒尖峰；已把 美国家庭网关 上游连接从顺序尝试改为并发尝试经验证的公网地址，避免某条 IPv6 路径超时阻塞 IPv4，仍需进一步实测。

## 2. 流量架构

```text
ACK worker
  Claude 模型请求 → 本机凭证代理 → 显式 Anthropic CONNECT ──┐
  OAuth / 登录 / refresh / MCP / bridge / 更新 / 遥测 ───────┤
             HTTPS_PROXY → fleet-egress → 强制美国父代理 ───┤
                                                        ▼
                                        fleet-us-egress:3128
                                                        │
             ACK 现有 TLS Ingress ← 美国家庭网关主动建立认证 WSS
                                                        │
                                                        ▼
                                         美国家庭网关 本地 DNS + 公网 TCP
                                                        │
                                                        ▼
                                        美国 AT&T 出口 → 目标服务

worker 守卫：仅允许 DNS、代理服务、明确的必要控制流；其余公网直连拒绝
隧道故障：请求失败 / 有限重试；不自动切换到国内或新加坡
```

隧道不解密 Claude 的 TLS，不修改官方客户端，不伪造设备或身份。专用隧道认证 token 只在启动时读取：ACK Kubernetes Secret、美国家庭网关 System Keychain。网关没有订阅 token，日志不记录授权头、提示词或代码正文。

初始为 16 条可复用的待命连接，每条服务一条上游 TCP 连接；请求最多等待 4 秒。它是初始配置，不是“支持 16 个用户”的结论：一个 CLI 可以同时建立多条连接。扩容需先测家庭带宽与网关资源，负载实验走 Fleet 的 loadgen 工具。

### 必须同时约束两条路径

1. **模型代理：** Python `http.client` 不会自动遵循 `HTTPS_PROXY`。因此加入 root 配置 `FLEET_CRED_ANTHROPIC_PROXY`，在真实 TLS 连接前执行 CONNECT。保留原始上游 SNI 与证书校验。启用后只有 trusted 节点可以走这一凭证路径，不能回退到 SG relay 或 central；untrusted/unknown 时拒绝。
2. **CLI 辅助流：** 提供大小写 HTTP(S) 代理环境，统一代理按域名映射美国父代理，并用 Pod 网络命名空间的 IPv4/IPv6 守卫拒绝绕过代理。仅设置环境变量不足以覆盖不遵循代理的程序。

已知强制域名包括 `.anthropic.com`、`.claude.ai`、`.claude.com`、`.claudeusercontent.com`、`.claudemcpcontent.com`、`storage.googleapis.com` 、npm registry、Homebrew formulae 主机与官方网络文档列出的两个 Datadog intake 主机。GCS 和 Datadog 是共享域名，代理无法在不解密 TLS 的情况下只区分其中 Claude 的路径，因而这些主机的所有受管请求都走美国。

未知且未允许的目标先拒绝，查阅所部署 CLI 版本的官方网络需求后更新白名单。未来端点不能靠今天的列表保证覆盖；域名拒绝告警和版本升级验收是长期工作的组成部分。

GitHub 统一代理的旧 SG 3128 父代理在本次测试中失败。新配置把 GitHub/GitHubusercontent/GHCR 一并映射到 美国家庭网关，以免关闭直连后开发流量中断；新 Deployment 完成滚动后，GitHub 三次复测为 504、200、200，npm registry 三次均为 200。这验证了新路由可用，也说明仍有需观察的抖动。Codex 的授权与出口策略需要保持独立验证，不能因本次 Claude 切换改变其凭证。

### Pod 之外的账号活动

“Pod 的全部相关流量”不等于“账号的所有来源”。hub 额度探测、管理节点刷新、其他节点的订阅使用、授权浏览器都是单独来源。第二阶段列出这些来源，并让目标账号的活动遵循同一出口策略；不得因为 home 迁到 美国家庭网关就认为它们已迁移。

浏览器在操作者自己的设备上运行，不能通过 Pod 代理自动改变其路径。真实登录和刷新需由实际使用者按官方流程验证。不要通过多账号轮换处理明确的组织暂停；已暂停订阅 继续停止使用，恢复由操作者处理。

## 3. 分阶段推进与交付标准

| 阶段 | 工作 | 当前状态 / 完成标准 |
| --- | --- | --- |
| A：独立网络试点 | 家庭出口确认、认证 WSS、统一 CONNECT、自动重连、短时测试 | 已部署并完成上述测试；继续监控稳定性 |
| B：代码与发布 | root 强制 CONNECT、启动路由、trusted 门、TLS/SNI、无回退测试；独立 PR → 正常签名发布 | 实现与本地验证中；不可覆盖线上签名运行时 |
| C：受管 worker 切换 | 记录旧配置与 Pod UID；保护会话；更新 OnDelete 模板及根路由；配置辅助代理与硬守卫 | 生产尚未切换；模板变化不影响旧 Pod，不能以 apply 成功冒充生效 |
| D：真实 CLI 验收 | 在正常授权账号上执行一次开发任务、流式输出、真实 refresh、MCP、更新；核查拒绝日志 | 不使用 已暂停订阅；必须由实际 CLI 与进程环境验收 |
| E：账号活动统一 | 盘点 hub 探测、其他登录/节点、刷新、浏览器；明确账号和席位归属 | 未在本轮网络试点中改动；完成后才可称账号路径一致 |
| F：持续运行 | 24–72 小时网络观察，7–14 天正常开发；按数据决定是否增加美国云备用 | 稳定观察不是免封证明；本轮不购云 |

切换步骤必须使用线上有效配置，不能把仓库里尚未部署的中心 credproxy、缓存或 NetworkPolicy 当作既有服务。目前生产 worker `受管 worker` 使用本机 shared credential proxy；集群原先没有通用 egress，出站守卫允许公网、拒绝私网。已有 CLI 不会因部署新 Service 自动改变代理环境。

生产上线前：

- 列出当前 worker 登录、活跃会话、不可中断任务和 snapshot 恢复能力；保留 UID、入口和 PVC。
- 独立 PR 检查通过并合入，等待正常 release train 的 Linux/macOS 检查、签名发布与 stable 推进；不 force，不改不可变 runtime 目录。
- 将 `FLEET_ANTHROPIC_PROXY`、`FLEET_EGRESS_PROXY` 写进 StatefulSet 模板；使用明确 IP:port 允许项为代理、DNS、必要控制服务放行。root 的 login route config 维持强制 API 路径，容器重建由 route healing 重建。
- 先验证必要控制流、Codex/GitHub/包管理，再启用生产闭合守卫。ACK flannel 不执行 NetworkPolicy，单加一份 NetworkPolicy 不能作为验收。
- 在保护会话的维护步骤中让 CLI 重新读取环境；不要强杀 sibling tmux。OnDelete 的生产 Pod 重建会中断进程，snapshot 可恢复会话上下文，但不保证恢复每个任意后台进程。
- 从实际 worker 及真实 CLI 核查：模型经显式 CONNECT、辅助流经美国父代理、直连拒绝、IPv6 无旁路；监控所有被拒域名。

## 4. 验收目标与运维

以下是建议目标，不是已经达成的服务承诺：

| 项目 | 目标 |
| --- | --- |
| 出口一致性 | 测试矩阵的所有 Claude 路径都到预期美国出口；没有直连或 SG 回退 |
| 断路测试 | 隧道/网关停机时，应受控的直连成功次数为 0；恢复后不改账号即可重连 |
| 可用性 | 先观察 72 小时，连接成功率目标 ≥99.5%；再按任务的重要性确定正式 SLO |
| 延迟 | 热连接 RTT P50 <250 ms、P95 <400 ms；当前短样本 P95 未达此目标，需要进一步测量 |
| 流式 | 正常工作中连续 30–60 分钟的流与空闲连接恢复，不丢任务状态；不人为制造模型负载 |
| 刷新 | 完整正常 token 生命周期至少一次；不手动输出或拷贝 token |
| 路由告警 | `/healthz` 无美国连接、502、连接池耗尽、域名拒绝、家庭 IP/国家改变 |
| 隐私 | 只记录主机、路由、状态、时延和字节数；不记录凭证/正文 |

网关的 Kubernetes Ready 仅表示进程能接受重新连接；美国连接是否可用以 `/healthz` 与实际 CONNECT 为准。这一区分避免隧道掉线后入口关闭造成恢复死锁。

美国家庭网关 出口服务通过 Fleet 支持的 root `keep-labels` 注册，防止守护把未登记的 LaunchDaemon 归档。职责建议：操作者负责家庭 ISP/供电和出口变更判断，Fleet 运维负责网关/证书/隧道 token、CLI 域名表和发布。尚未接入自动告警通知；先建立只读健康与日志面板，再决定通知渠道，不能把“建议监控”算成已部署。

家庭线路主要风险：IP 动态变化、家庭上行拥塞、ISP 断线、路由器重启、美国家庭网关 系统更新、Ingress 证书/入口故障、跨境线路抖动。美国家庭网关 暂停服务时就停止该 Claude 路径，业务从持久化任务状态恢复或使用独立获准的工具。

## 5. 月成本与美国云备用

价格是官方公开基础套餐，2026-10-12 查询；不含税、备份、额外带宽、ACK 费用、订阅/模型费用或人力。实际账单以供应商和账户为准。

| 方案 | 基础月费 | 流量 / 适用性 |
| --- | --- | --- |
| 现有 美国家庭网关 + 家庭网络 | 新增 VM 月费 $0 | 另计家庭电费、ISP 流量上限/升级、ACK 跨境流量与运维；当前不需新增 LB |
| AWS Lightsail Linux **含公网 IPv4**，512 MB | $5 | 1 TB 传输额度；轻量备用下限，内存余量需测 |
| Lightsail 含 IPv4，1 GB | $7 | 2 TB；建议列为轻量美国云备用候选 |
| Lightsail 含 IPv4，2 GB | $12 | 3 TB；并发与监控余量更大 |
| DigitalOcean Basic，512 MiB | $4 | 500 GiB outbound；适合轻量备份，需测 ACK 线路 |
| DigitalOcean Basic，1 GiB | $6 | 1000 GiB outbound；另一轻量候选 |
| DigitalOcean Basic，2 GiB | $12 | 更大余量；确认具体套餐当期 transfer quota |

Lightsail 静态 IP 在正确关联到实例时包含在套餐中；不要用 IPv6-only 的低价作为 IPv4 网关报价。Lightsail 的入站与出站均计入传输额度，超额出站收费，美国区域起点 $0.09/GB。DO 应按它的 outbound 规则核算。

定义 T 为每月 ACK↔目标服务的上传+下载总量：转发网关通常有约 T 入站和 T 出站，因此 Lightsail quota 消耗可粗估为 2T，加上隧道开销；DO 的 outbound 可粗估 T，加上开销。举例 T=600 GB/月，Lightsail 约 1.2 TB 额度消耗，$5/1 TB 的档位可能不够；$7/2 TB 更有余量。这个例子不是实际观测流量。

家庭电费可用 `新增平均功率 W × 24 × 30 ÷1000 × 电价` 估算。ACK 端的隧道传输仍可能产生中国出口带宽费用，家庭方案不是网络总成本为零。先记录一周实际字节量，再做采购预算。

云备用不应随机或自动频繁切换：两个美国 IP 仍然不同。默认家庭主出口，备用通过健康和地域检查后显式切换，保留时间与原因。任何方案都不能保证两个出口对账号风控没有影响。

## 6. 回滚与账号限制

回滚新增代理或配置前先停止依赖美国出口的 Claude 路径；**不自动回退国内/SG**。保留 PVC、会话、原路由快照和 gateway 配置。只停止本轮新增的出口守护/Deployment，不动其他登录的 tmux。

代码回滚走 PR 与签名版本；root 配置回滚有记录。若要恢复历史网络行为，必须明确决定其账号与地区影响，不能由 502 自动触发。已暂停订阅 继续暂停，目标用户 home 不随网络回滚迁回国内。

社交媒体案例可以识别故障模式，不能提供可信封禁概率。V2EX 的集中订阅案例、住宅出口失败自述、GitHub 中国用户暂停案例，以及 X/LINUX DO 的稳定出口经验都存在混杂与样本偏差。之前的独立研究报告列出来源和访问限制；本规划采用其证据分级，不把“美国住宅出口有人成功”推导成长期免封保证。

## 官方参考

- [Claude Code 网络配置与允许域名](https://code.claude.com/docs/en/network-config)
- [Claude Code 认证方式](https://code.claude.com/docs/en/authentication)
- [Anthropic 支持地区](https://www.anthropic.com/supported-countries)
- [消费者条款](https://www.anthropic.com/legal/consumer-terms)
- [组织暂停与复核](https://support.claude.com/en/articles/8241253-why-was-my-account-disabled)
- [Lightsail 官方价格](https://aws.amazon.com/lightsail/pricing/)
- [DigitalOcean Droplets 官方价格](https://www.digitalocean.com/pricing/droplets)
