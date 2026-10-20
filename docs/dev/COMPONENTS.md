# 组件分类

本表是组件类别的唯一来源（EPIC #4322），承接组件盘点草稿 §1–§5，按该批
发起人的最终拍板订正；程序归属盘点（#4328）引用这里的组件名。
判断依据是 [产品方向](PRODUCT-DIRECTION.md)。核心是必要能力；按需是可选扩展；
移除是已决定退出的能力或默认行为（理由注明是否已完成）；待定须由发起人决定。
**类别不代表当前安装状态**：表内注明尚未收尾的默认项，登记不等于授权删除。

本批保留执行会话及其工作树、协作、合并守卫；编排和管家的特殊实现下一批才移除。
已有用户设置和旧规则块不自动收回。免确认运行本批不改，隔离策略另批决定。

2026-10-16 原生边界补充：上述「保留」指产品能力，不承诺永久保留重复实现。
按 [Blueprint 的最终职责边界](PRODUCT-DIRECTION.md#fleet-与原生-agent-的最终职责边界) 分批迁移，
具体替换清单与验收见 [原生 Agent 边界迁移](NATIVE-AGENT-BOUNDARY.md)。
执行会话、跨节点协作、持久化和安全准入仍保留；原生 Worktree、resume/fork、MCP 与事件能力优先复用。
此补充不自动更改下表待定项、现有用户配置或在线安装；每批替换通过验收后再更新实现归属。

## 会话默认配置与钩子

| 组件 | 类别 | 理由 |
|---|---|---|
| Claude 模型与界面默认项（`effortLevel`、`outputStyle`、`theme`、`tui`） | 移除 | #4323 已从新装默认文件移除四项；用户已有值保留，回归审计逐项检测。 |
| 免确认运行（Claude `bypassPermissions` / `skipDangerousModePermissionPrompt`；Codex `approval_policy` / `sandbox_mode`） | 待定 | 待发起人定：本批明确不改，随托管隔离环境一起决定；守卫只防手滑，不构成安全隔离。 |
| Codex 思考档位（`model_reasoning_effort`）及其它模型设置 | 待定 | 待发起人定：当前 Codex 仍填入 `high`；本批四键指标仅指 Claude，不能把读数 0 解释成两种模型的全部设置都原生。 |
| 登录 MCP 默认包（context7 / playwright / github / fetch） | 待定 | 待发起人定：当前两种代理的配置仍默认填入四个服务；本批不改变安装包。 |
| 会话状态钩子（`set-claude-state.sh`） | 核心 | 执行会话仍属核心；工作、等待、退出状态用于恢复和回收，保留既有钩子。 |
| 会话恢复与事件记录（`fleet-codex-session.py`、`fleet-emit.sh`、`handoff-latch-reset-hook.sh`、`fleet_loop_mark.py`、历史/退出/压缩钩子） | 核心 | 维持会话身份、连续性和生命周期；本批不拆执行会话的恢复与合并流程。 |
| 存活原生会话的观察登记（`fleet_native_observe.py`） | 核心 | #4510：原执行不重启，fresh 核实原 kernel/RPC/账号/reservation 后补登记；旧 hook 与消息消费单独报告。 |
| 操作者设备位置（`mod/fleet/hooks/where.ts` / `bin/fleet-where-hook.sh`） | 核心 | 发起人 2026-10-15 拍板 5：保留「你在哪台设备」，让会话知道当前设备及打开网页、接收文件等能力。 |
| 压缩后任务恢复（`bin/refocus-hook.sh`） | 核心 | 只在执行会话压缩后补回任务说明，保证原任务持续执行（EPIC #4322 统计口径）。 |
| 上下文阈值自动干预（Stop 中的 auto-handoff / compact-prep） | 按需 | 原生 Agent 默认负责压缩；Fleet 的两个百分比阈值默认 0，不自动写恢复图、输入 `/compact` 或切换会话。显式百分比/Token 配置保留，手动交接、跨节点迁移和任务归属恢复仍属核心。源码候选已改，尚未发布。 |
| 登录说明规则块（`CLAUDE.md` / `AGENTS.md` 的 `fleet:agent-defaults` 块） | 移除 | 不再默认写入或检查；已有块原样保留，用户可用 `fleet-agent-defaults.py strip` 按需删除。执行会话仍由技能携带规则，守卫照常生效（#3125）。 |
| 命令误操作守卫（`hooks/bash-guard.py` 的删除、强推、广域信号检查） | 核心 | 防止共享宿主上的误操作；不能替代进程或账号隔离。 |
| 执行会话守卫（`bash-guard.py` 的 tmux/桥接规则、`base-readonly-guard.py`、`agent-guard.py`） | 核心 | 基础检出只读和跨会话协作边界保持；嵌套原生 Worktree 只按 Git 根/common directory/注册反向指针验证当前目录，不按目录名前缀放行，不增加创建或清理所有者。`fleet-hooks-emit.sh --target codex-managed` 从既有表生成两项已审阅 Codex 守卫的原生配置，不新增策略引擎。候选生成不等于在线安装，旧入口保留。 |
| 文档发布守卫（`hooks/artifact-guard.py`） | 核心 | 轮换账号下 Artifact 的访问归属不可靠，给操作者读的页面通过 `show` / `open` 送到他的电脑。 |
| 会话内 mod（`mod/fleet` 的 usage / where / state） | 核心 | 提供用量、操作者位置及会话状态。 |
| 会话内 mod（inbox / progress / compose 等其余部分） | 待定 | 待发起人定：逐文件评估必要性，本批不按草稿推测拆除。 |
| Codex 上下文计量适配（`fleet-codex-session.py` Meter / `conf/statusline.sh`） | 核心 | 将原生读数投影到既有计量总线；显式候选复用注意力连接，收到有效事件时暂停重复 rollout 轮询，失联回退。不新增常驻服务、不默认启用，不改变其他 collector 的待定类别。 |
| Fleet MCP（status / where / context / open / show） | 核心 | 代理读取状态和向操作者送达内容的统一接口。 |
| 执行会话与跨会话协作 MCP（brief / task / spawn / await / children / send / report / ask / pr_verdict / pr_merge） | 核心 | 发起人明确保留跨会话协作基础设施；每个会话都挂载派发组（#4703）。任务只认 hub 的任务记录 `T<n>`，不认领、不评论 GitHub issue（EPIC #4895）。 |
| 编排 MCP 挂载组（`conf/mcp-orch.json`） | 核心 | 每个会话都挂载（#4703 撤掉了 #4334 的 `@agent_spawn` 门）；底层协作接口，和编排模板无关。 |

## 可选插件

编排是普通会话模板（`spawn agent:orchestrator`），不是插件；下表的可选插件新装都不带。`fleet` 核心包和 `mod/fleet` 不属于下表的可选插件计数。

| 组件 | 类别 | 理由 |
|---|---|---|
| EPIC 批次（`fleet-epic`） | 按需 | 用户选择才安装；一个 EPIC 是 hub 的父任务，成员是子任务（#4957），不碰 GitHub issue。 |
| 浏览器（`fleet-browser`） | 按需 | 用户选择浏览器能力后安装，不进入普通默认。 |
| 基础设施运维（`fleet-infra`） | 按需 | 运维人员主动安装；既有代码明确拒绝把它列为托管默认。 |

## 命令与技能

| 组件 | 类别 | 理由 |
|---|---|---|
| 执行会话（worker start hook） | 核心 | 发起人拍板 2 覆盖草稿的按需建议；按任务记录开工、正常 PR/合并流程保持，说明书按 #4325 瘦身。 |
| 上下文连续性（`fleet-handoff` / `fleet-compact-resume` / `fleet-context` / `handoff`） | 核心 | 保留同一任务的上下文与恢复能力。 |
| 会话迁移与历史（`fleet-move` / `fleet-history`） | 核心 | 支持跨节点连续工作与已关闭会话恢复。 |
| 首次使用（`fleet-onboard`） | 核心 | 提供首次使用入口。 |
| 安装同步（`fleet-sync-install`） | 核心 | 操作者维护版本的入口；执行会话不得自行同步在线安装。 |
| 内容送达与阅读（`fleet-open`） | 按需 | 需要打开页面或阅读文档时调用；目前技能仍随核心包配送，类别不表示已拆包。 |
| 仓库接入与帮助（`fleet-add-repo` / `fleet-help`） | 按需 | 使用对应能力时调用；目前随包配送，后续拆包不在本单范围。 |
| 命令模板（`commands/_template*.md`） | 待定 | 待发起人定：核实内部脚手架与运行时引用后再决定去留。 |

## 后台进程

| 组件 | 类别 | 理由 |
|---|---|---|
| 凭据代理（cred-proxy） | 核心 | 会话访问订阅的统一入口。 |
| 额度观察（quotawatch） | 核心 | 提供用量及额度可见性；每分钟的巡查单元已退休（T549），它的四件杂事并入状态对账。 |
| 版本维护（install-sync / base-sync） | 核心 | 跟随稳定版本及维护基础检出；版本激活由既有发布流程负责。 |
| 宿主清理与保护（memguard / diskguard / cleanup / worktree-autoclean） | 核心 | 维持共享宿主稳定，回收退出会话资源；Git 锁和已识别的原生 Worktree 所有权先于 Fleet 回收，不能因目录干净/已合并或 `--force` 而接管原生清理。 |
| 休眠（sleep） | 移除 | 已于 T548（EPIC T542 C8）删除：闲着的会话就是闲着；`fleet-sleep*` 与 `fleet_sleep_*` 只剩一版兼容转发。 |
| 收集与账本观察（collect / ledger-watch） | 待定 | 待发起人定：逐项区分计量、恢复必需的数据和可选遥测。 |
| 终端状态与节点连接（spinner / peerlink） | 待定 | 待发起人定：草稿建议按需，但现有看台、状态恢复和跨机链路也使用它们，须先核实再拆。 |

## Web、宿主与附加集成

| 组件 | 类别 | 理由 |
|---|---|---|
| Hub（`tokenledger`） | 核心 | 接入、计量与任务调度。 |
| Web 接入（web-chat / web-console） | 核心 | 产品近期的网页使用入口。 |
| 承载节点（managed-node） | 核心 | 提供任务执行环境；托管镜像候选沿用版本暂存、种子复制与回退，在既有 staged 元数据内保存未启用的原生守卫预览。既有 image stager 增加显式 root-only 守卫安装入口，保留现存策略、冲突拒绝，不自动激活。个人 POD 使用镜像种子，不把可写 PVC 当管理层代码；原生权限 CI 和线上生命周期独立验收。 |
| 接入中继（cred-relay / gh-relay） | 核心 | 支持现有接入路径，保持凭据只在启动时读取的边界。 |
| 网页主题（fleet-theme） | 核心 | Web 产品共享界面。 |
| 构建与验证（ci-runner / workflows / 默认安装审计） | 核心 | 仓库内部质量保障，不是给使用者默认启用的插件。显式原生 local-runtime 探针验证 TUI/Worktree/后台实际归属；launch-flags 矩阵核对逐次配置边界；session-env 探针核对并发 MCP/Hook 归属及可选 fork 来源、原生清理和重连，不替代业务授权验收。不安装 daemon、不改变生产运行时选择。显式原生用量订阅探针仅在隔离夹具和固定版本 CI 验证事件边界，不引入生产订阅服务。原生 Claude Worktree/SessionStart 探针使用固定版本与临时离线夹具，不接管会话生命周期。 |
| 操作者终端集成（iterm2 / laptop-url-opener.sh） | 按需 | 按操作者设备能力使用。 |
| 企业微信通知（wecom-webhook-notify.sh） | 按需 | 用户自行选择的通知集成。 |

## 退役项

| 组件 | 类别 | 理由 |
|---|---|---|
| SPOT 执行节点（spot-node） | 移除 | 入口在集群 SPOT 机器上自起自释的执行节点（#1428）一台都没跑过；镜像、入口控制器、`fleet_spot_nodes`（迁移 3 删表）和 `spot-node` CI 一起删掉（#4797）。搬空一台要下线的机器仍是 `fleet-evacuate.sh`。 |
| 退役自动化标签（`autoland` / `autofill`） | 移除 | 对应自动合并与自动开工机制已退役。旧会话的 `autofill` 来源名继续可读（#4326）。 |
| GitHub issue 驱动层 | 移除 | EPIC #4895：任务只认 hub 的 `T<n>` 记录，归人不归仓库；GitHub 只托管代码和 PR。issue 的认领与收尾、GitHub 守护进程与 gh 缓存、自动开故障单与管家、本地 tmux 仪表盘与面板、预热会话、hub 单据和周边工具都已删（批 0–5）。 |

## 默认安装审计

运行 `bash bin/fleet-default-audit-selftest.sh`。它在临时 HOME 通过真实安装器安装
代理配置包，再走普通宿主的安装应用路径（不装守护进程，Claude 插件 CLI 用本地替身）。
来源为本分支的文件，不读在线登录的设置，不联网安装插件，不触碰在线 tmux。
stdout 只输出四行 `指标<TAB>整数`；任何非零或安装失败都退出 1。
stderr 是检查诊断与负向回归结果，不属于指标行。两条安装路径分别读数，
每项输出两次读数的较大值，宿主重合并不能掩盖客户端默认项。

| 指标 | 计数口径 | 期望 |
|---|---|---|
| `model_ui_settings` | 安装后 Claude settings.json 中四键 `effortLevel` / `outputStyle` / `theme` / `tui` 的存在项数；不是 Codex 全部配置的指标 | 0 |
| `instruction_blocks` | Claude CLAUDE.md 与 Codex AGENTS.md 的 `fleet:agent-defaults` 规则块总段数；一个 begin/end 块只算一段，孤立 end 也不能漏报 | 0 |
| `conversation_hooks` | Claude 安装钩子及 Codex 实际发出的启动钩子中，未列入审阅过的核心清单的钩子；where、refocus、worker seed 和守卫/生命周期钩子保留 | 0 |
| `enabled_plugins` | 普通登录安装后启用的可选插件 ID 去重数（插件 CLI 状态及 enabledPlugins 设置）；不含核心包/mod，不代表托管登录的反馈例外 | 0 |

四键各有一腿负向回归：改沙盒中的默认文件，经真实填充程序写入新配置，读数必须变为 1。
可独立演示 `bash bin/fleet-default-audit-selftest.sh --inject-key effortLevel`，应输出首项 1
并退出 1。规则块、旧 whats-new、新钩子、prompt 钩子及启用插件也有非零检测。
新增钩子必须先在本表归类，再更新审计里的核心允许清单；不能自动从钩子表生成允许清单。

自测由 `run-selftests.sh` 自动发现；脚本列出安装器、默认文件、合并程序、钩子表、
Codex 映射和插件管理器的文件依赖，相关改动会进入 PR 的自测选择。
四项 0 只证明上表口径，不声称所有待定项已收尾，也不证明在线版本已同步。

## 程序文件归属

补充程序层的共用组件；这里的类别沿用上文产品边界，不改变默认安装或授权删除。

| 组件 | 类别 | 理由 |
|---|---|---|
| 终端看台与薄客户端 | 核心 | #3008 合并后的会话访问、列表和交互入口；按设备可选的 iTerm2 集成仍归上表。 |
| 配置与插件装配 | 核心 | 读取配置、装配代理和可选插件的共用机制；显式 Codex 原生默认值安装候选复用原生配置层及 batchWrite，平台只选缺失项和既有排除项，不另写用户 TOML。尚不自动启用；不代表被装配的插件本身必选。 |
| 账号与代理启动 | 核心 | Claude/Codex 的启动、账号选择、凭据隔离及信任校验，承载现有执行会话；`fleet_launch.py` 在投递任务前验证原生进程、会话及既有窗口绑定的 Git 工作树，并保留接受代次的恢复边界（#4393）；不接管原生目录创建或清理。 |
| 项目依赖复用 | 按需 | 显式选择的依赖克隆/链接辅助；默认新会话不扫描或预复制依赖，不替代项目安装命令和包管理器缓存；保留已有显式配置与旧命令。 |

下面是盘点工具读取的归属规则，按顺序首个匹配；名称前缀必须唯一对应上方组件表。
模式相对于 `bin/`，以空格分开，支持 shell 风格通配符。不得用 `*` 总兜底把新文件
隐去：有引用但没有归属的程序会报「未归类」并退出 1；没有引用者列待复核候选。
自测先继承被测程序归属，跨组件自测归「构建与验证」，不独立制造产品类别。
调用口径、候选理由与生成方法见 [程序文件盘点](BIN-INVENTORY.md)。

<!-- bin-inventory:rules -->
| 组件名前缀 | bin/ 文件模式 | 说明 |
|---|---|---|
| 操作者设备位置 | `fleet-where-hook* fleet-client-where* fleet-client-lease* fleet-client-who*` | 当前设备及租约 |
| 压缩后任务恢复 | `refocus-hook*` | 压缩恢复 |
| 登录说明规则块 | `fleet-agent-defaults*` | 已退出默认，保留显式清理 |
| 会话状态钩子 | `set-claude-state*` | 状态写入 |
| 会话恢复与事件记录 | `classify-* fleet-codex-session* fleet-id.sh fleet-id-selftest* fleet-id-results-selftest* fleet-id-migrate-selftest* fleet_id.py fleet-emit* handoff-latch-reset-hook* fleet_loop_mark* precompact-hook* session-end-hook* fleet-restore* .fleet-restore* fleet-state-* fleet-status* fleet-sessions-snapshot* fleet-transcript* fleet-idle-* fleet-loop* fleet_cron* fleet_sample* fleet_timing* fleet_runtime.py fleet-compat* fleet-stream-resume*` | 状态、历史与恢复；mod 的 lifecycle/state 钩子通过 fleet_runtime.py 记录原生运行态观察 |
| 上下文连续性 | `fleet-ladder-log* fleet-context* fleet-compact* fleet-handoff* fleet-transfer* .fleet-transfer* fleet_transfer*` | 上下文与代理交接 |
| 会话迁移与历史 | `fleet-move* fleet-history* fleet-migrate* dash-migrate* dash-restore-session*` | 迁移与恢复历史 |
| 首次使用 | `fleet-onboard* fleet-guide* fleet-doctor-onboard*` | 新人入口与验收 |
| 内容送达与阅读 | `fleet-open* fleet_open* fleet-show* open-url*` | 打开与文件送达 |
| 仓库接入与帮助 | `fleet-repo.sh fleet-repo-* fleet_repo_authority* dash-repo-add*` | 仓库注册与选择；显式分阶段选择这个 login 的人的任务权威（#4395、#4901），没有常驻进程 |
| EPIC 批次 | `fleet-epic* epic-page*` | 批次工作流 |
| 浏览器 | `fleet-browser*` | 浏览器插件 |
| 操作者终端集成 | `fleet-iterm* fleet-tcc*` | 设备集成 |
| 凭据代理 | `fleet-cred-proxy* fleet-proxy-quota*` | 订阅代理 |
| 额度观察 | `fleet-quota* usage-*` | 额度与用量 |
| 项目依赖复用 | `fleet-deps-*` | 显式依赖克隆/链接，不属于默认会话启动 |
| 版本维护 | `fleet-install* fleet-base-sync* fleet-update* fleet-versions* fleet-stable* fleet-sync-logins* fleet-release* fleet-dist-source* fleet-src-digest* fleet-bootstrap-cache* fleet-brew-perms* fleet-shared-dirs* fleet-login-bootstrap* fleet-login-install* fleet-host-install* fleet-dev-mode*` | 安装、版本与包 |
| 宿主清理与保护 | `fleet-cleanup* fleet-reconcile-tick* fleet-diskguard* fleet-memguard* fleet-loadgen* fleet-heavy* fleet-worktree-drop* fleet-window-reap* fleet-reap* fleet_reap* worktree-autoclean* dash-reap* fleet-worker-stop* fleet-orphan-reports* fleet-park* fleet_park*` | 资源、退出与停放 |
| 休眠（ | `fleet-sleep* fleet_sleep*` | 休眠的一版兼容转发 |
| 收集与账本观察 | `fleet-collect* fleet-ledger* tmux-dash-collect*` | 收集与账本 |
| 终端状态与节点连接 | `tmux-spinner* fleet-render-watch.py fleet-peerlink* fleet-peer-list* fleet-peer-queue* fleet-row-remote*` | 状态与节点连接；spinner 的 shell 入口加载配置后 exec Python 主循环，复用 render-watch 的常驻 control transport、可见性和有界等待 |
| Hub（ | `fleet-hub* fleet_hub* fleet-login* fleet-logout* fleet-relogin* fleet-users* fleet-tenant* fleet-admin* fleet_admin* hub-session* fleet-route* fleet-connect* fleet-task-record* fleet_cluster_ticket* fleet_managed.py` | Hub、账号接入及任务记录 |
| Web 接入 | `fleet-webchat* fleet-webterm* web-console* site-*` | 网页与站点 |
| 承载节点 | `fleet-node* fleet_node* fleet-spotlight* fleet-evacuate* fleet-provisioner* fleet-host* fleet-machine* fleet-svc* fleet-service* fleet-services* fleet-job* fleet_job* fleet-daemon* fleet-launchd* fleet-wallpaper*` | 节点与宿主服务 |
| 接入中继 | `fleet-relay* fleet-peer-cert* fleet-peer-trust* fleet-trust* fleet_ed25519* fleet_tls*` | 中继与节点信任 |
| 配置与插件装配 | `fleet-conf* fleet_config* fleet-config* fleet-settings* fleet-hook* fleet-agent-bundle* fleet-agent-team* fleet-agent-def* fleet_agent_allow* fleet-plugins* fleet-codex-plugins* fleet-cfg-restart* mcp-fetch* mcp-github*` | 配置与插件注册 |
| 账号与代理启动 | `fleet-account* .fleet-account* fleet_agent_argv* fleet_agent_mcp* fleet-manual-sub* fleet-codex* fleet_codex* fleet-claude* fleet_dispatch.py fleet_launch.py fleet-model* fleet-cred* fleet-creds* fleet-credsep* fleet-session-cred* fleet-redact* fleet_redact* fleet-lang*` | 代理、账号与凭据；投递及会话启动入口通过 fleet_dispatch 解析、校验已接受的代理选择 |
| Fleet MCP（ | `fleet-mcp* fleet-peer-mcp* fleet-doctor* fleet-control* fleet_control*` | 工具读写与诊断 |
| 执行会话与跨会话协作 MCP | `fleet_worker_life* fleet-answer* fleet-await* fleet-children* fleet-brief* fleet-pr-* fleet-report-parent* fleet-peer-send* fleet-permission* fleet-dialog* fleet_dialog* fleet-ask* fleet_ticket_url* fleet-task* fleet_task_control.py fleet_task_recovery.py fleet-wait-reeval* fleet-land* fleet-gate-check* fleet-workflow-perms*` | 任务与协作、PR 和合并；brief 读任务记录（#4898 起不再认领 issue），await/children/report-parent 通过 fleet_task_control.py 协作，task-record/hub-node 通过 fleet_task_recovery.py 保存并重放已接受任务的回执 |
| 执行会话（ | `fleet-worker-start-hook* fleet-worktree* fleet-session-wrap* fleet-session-command* fleet-session-shell-agent* fleet-run* dash-issue-session* dash-raw-session* scratch-prefill* fleet-home-session* fleet-home-template* fleet-lib.sh fleet_iso.py session-shell/* fleet-degenerate* fleet_native_observe.py fleet_native_registration.py fleet_native_continue.py` | 执行会话与共用运行库 |
| 终端看台与薄客户端 | `fleet fleet-entry* fleet-up* fleet-down* fleet-attach* fleet-term* fleet-thin* fleet_thin* fleet-client* fleet_clientlog* fleet-session-cli* fleet-session-page* fleet-view* fleet_view* fleet-remote-view* fleet-topbar* fleet-list* fleet-keys* fleet_keys* fleet-door* fleet-input* fleet-compose* fleet-quick* fleet-ui-* fleet-palette* fleet-panel* fleet_panel* fleet-pane* fleet-popup* fleet-pending-tool* fleet_pending_tool.py fleet_status_evidence.py fleet-human-menu* fleet-window-carry* fleet-alerts* fleet_notify* fleet_needs_detail* fleet_sidefx* dash-* tmux-* .tmux-* reapply-tmux*` | 看台、交互与窗口；pending-tool 壳、spinner 和回收观察共用 fleet_pending_tool.py，fleet_view.py 通过 fleet_status_evidence.py 展示同源状态证据 |
| 构建与验证 | `*-selftest* selftest-* run-selftests* ci-* tokenledger-* go-test-* go-ci-cache* client-e2e* docs-* fleet-bin-inventory* fleet-break-it* break-it-durations.txt fleet-ci-* fleet-shard* fleet-train* fleet-durations-drift* fleet-macos-watch* fleet-oldcfg* oss-scan* nogh-task-acceptance.py nogh-task-boundary-test.py nogh-task-browser.mjs nogh-task-deny-probe.py nogh_live_*` | 盘点、构建、回归与发布检查；task-acceptance 工作流调用 nogh-task-acceptance.py，后者执行 PR 边界、浏览器与拒绝探针三个隔离验收程序；nogh_live_* 是 C9（#4562）默认关闭的隔离观测验收模块，由 nogh-live-selftest 与 task-acceptance 调用；go-test-shard.sh · go-test-durations.sh · go-ci-cache.py 是 Go 测试的按耗时分片、耗时表与缓存读数（#4817） |
<!-- /bin-inventory:rules -->
