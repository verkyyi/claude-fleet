# 原生 Agent 边界迁移

依据：[产品 Blueprint](PRODUCT-DIRECTION.md#fleet-与原生-agent-的最终职责边界)。
组件类别仍以 [COMPONENTS.md](COMPONENTS.md) 为唯一来源。

## 范围与状态

2026-10-16 操作者确认先写入边界，再按建议推进。首批是能力验证与兼容性盘点，
不是直接在生产启动参数后附加 `--worktree`，也不同时重写认证、会话系统或资源策略。
目标是减少 Fleet 重复职责，不承诺仅更换目录创建者就达到 1 秒草稿或 5 秒回复。

国内 drill 保持 Codex-only；Claude 的真实运行验证只在允许的境外环境进行。
不改变用户 POD 的运行配置，不关闭已有会话，不扩大信任，不改变完整 MCP 和 CPU/auth/权限守卫。

以下源码与探针证据来自隔离候选工作树，按独立 PR 送审；文档先行不表示所有实现已随本文合并或发布。
旧的 `issue-N` / `scratch-N` 会话继续按既有路径恢复，不批量改名或迁移目录。

## 原生能力依据

- [Codex 官方命令](https://learn.chatgpt.com/docs/developer-commands?surface=cli) 与 [Worktree 文档](https://learn.chatgpt.com/docs/environments/git-worktrees)：验证目标 CLI 的 `--worktree`，不能以桌面能力替代 CLI 证据。
- [Claude Worktree](https://code.claude.com/docs/en/worktrees) 与 [CLI](https://code.claude.com/docs/en/cli-reference)：原生 `--worktree`、恢复与目录生命周期；默认目录布局不等于 Fleet 的历史布局。
- [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp)、[App Server](https://learn.chatgpt.com/docs/app-server) 与 [Claude Hooks](https://code.claude.com/docs/en/hooks)：优先原生接口，不为获取状态而默认引入第二套常驻会话引擎。

官方接口会变化。证据须记录真实二进制版本、运行环境、调用方式与功能结果；
不能仅凭版本号比较或帮助中出现参数就开启生产路径。

## 分批推进

| 批次 | 工作 | 完成条件 |
|---|---|---|
| A：Worktree 兼容性 | 核实目标 CLI；以无凭据、无真实模型请求的 Git 夹具检查目录识别、守卫及原生生命周期；核对 native local 与 Fleet private-server 的能力差异，再在受准入约束的 drill 原生会话验证 | 真实目录、仓库、原生会话及账号环境可验证绑定；写入隔离、正常退出、异常恢复、保留修改与回退全部有证据 |
| B：原生创建适配 | 替换创建入口而非添加第二层创建；保存原生返回的实际路径；旧会话读取保持兼容 | 不双重创建/清理、不依赖目录前缀猜所有者；原生能力不足时明确回退旧实现或拒绝，不回退到可写主检出 |
| C：启动路径减法 | 对实际路径打点，删除重复解析/读取/调度；评估将非必需 Git 同步移出交互等待 | 与直接启动同机对照，首次与重复样本均保留；基准提交明确，用户要求最新时不能静默用旧代码 |
| D：事件与生命周期减法 | 按已验证的原生事件替换轮询、屏幕猜测和重复状态机 | 断连/重连、重复或丢失事件、退出/回合结束区别明确；缺失证据显示未知，不误报完成或删除会话 |
| E：原生插件所有权 | 通过原生 CLI 管理安装与开关，逐步移除每次启动的跨 Agent 翻译与重复 hook/MCP 装配 | 一份插件只有一个安装/加载所有者；既有选择、用户文件、完整 MCP 环境和 hook 信任保持；旧会话有兼容窗口 |

每批只替换已有职责，不新增池、编排或通用 Agent 抽象层。只有完成测量并证明原生能力不足后，
才另行评审最小兼容实现。旧 hook、工具及配置至少保留 CONTRIBUTING 要求的兼容周期。

## 首批代码盘点

以下为候选和依赖，不是已经批准直接删除的文件清单。

| 入口/能力 | 现状 | 替换条件 |
|---|---|---|
| `bin/dash-raw-session.sh` | 先做 authority/admission，再分配目录，随后创建窗口；存在准入 reservation 时禁止复用旧原生进程 | 保持准入与身份绑定；原生 Worktree 启动也必须经过此边界 |
| `fleet_scratch_alloc` / `fleet_worktree_create`（`bin/fleet-lib.sh`） | 同步 fetch，分配 `scratch-N`，创建 Git worktree 并运行 setup | 原生创建后不再调用一次 Fleet 创建；必须迁移所需 setup 配置，不能无意丢失项目文件、依赖或完整 MCP |
| `fleet_seat` / `fleet_scratch_key` 与 `bin/fleet-worktree.sh` | 部分座位、路径和身份使用历史命名约定 | 原生目录映射使用明确元数据与 Git 身份验证，不把任意目录前缀当授权 |
| `hooks/base-readonly-guard.py` | 保护主检出及其真实路径下的后代 | Codex 本次实测生成主检出之外的目录，现有守卫允许；不能因为 Claude 的嵌套布局未适配，就整体放行 `.claude` / `.codex` |
| `bin/fleet-restore.sh` / `bin/fleet-history.sh` | 恢复使用窗口与会话元数据，并兼容历史布局 | 写入真实工作目录、原生 ID 和账号 home；重启时恢复同一会话，不取最近修改的另一份历史 |
| `bin/fleet-codex.sh` | 已将恢复参数转成原生 resume/fork；与 Claude 共用的启动步骤已收进 `bin/fleet-launch-lib.sh`，真不同的写成适配表 `bin/fleet_agent_adapter.py`（T620） | 只剩 Codex 独有的薄适配（CODEX_HOME、TOML 钩子、posture、版本检查、`@codex_pending`）；不能声称原生恢复尚未接入 |
| `bin/fleet-codex-runtime.py` | 默认由 Fleet 启动私有 app-server，再执行 `codex --remote`；固定订阅禁止直接降级 `--no-daemon` | 当前原生 `--worktree` 不支持 remote TUI；先验证原生运行时能否保留账号验证、hook 归属、事件与协作，不能先绕过固定订阅检查 |
| `worktree-autoclean*` / `fleet-worktree-drop*` | 既有 Fleet 目录回收与安全检查 | 明确唯一清理所有者，原生管理目录不能被旧扫描器误删；未提交、未推送、活动会话及原生锁均纳入验证 |
| `bin/scratch-prefill.py` | 有界就绪探测与不发送的草稿粘贴 | 尚无已验收的两种 Agent 通用原生未发送草稿入口；不能用 prompt 自动提交代替，也不能仅删等待计时器 |

## 首批证据（2026-10-16）

- 本机：Codex `0.156.0` 帮助提供 `--worktree`；Claude Code `2.1.296` 帮助提供 `--worktree`。这只是能力声明。
- drill：只读查询实际测试容器，Codex `0.162.1` 帮助提供 `--worktree`。
  此时 drill 的 Fleet 版本是 `2d86e6dfa8c68efdf971980abaf6e940340b9217`，不是上一轮的 `c48dd07`；本批没有覆盖部署或变更调度。
- 当前代码盘点工作树基线为 `ee32cb73`。drill 已前移，因此本地兼容夹具与线上验收须分别标注，不能混称同一个版本通过。
- 新增 `bin/fleet-native-worktree-selftest.sh`：临时 HOME、真实 Git 仓库及两种目录布局；不启动 Agent、不读取凭据、不请求模型、不使用在线 tmux，不注册到 Fleet。
  同一夹具分别检查本地基线与 drill 已安装版本，各通过 11 项。通过表示现有约束被复现，不表示原生创建已适配。
- 已复现两处迁移障碍：主检出下的真实嵌套 Worktree 被 base-readonly 守卫拒绝；不含 `scratch-N` 的目录不会生成旧 scratch key。
  同时确认现有 `fleet_seat` 已能用明确的 issue/工作目录绑定识别无特定名称的 worker，不能把整个座位判断误称为只支持目录名。
  主检出写入、伪造原生目录名和指向主检出的符号链接仍被拒绝。
- 此阶段只验证目录布局；后续原生 CLI 证据见下节。完整 MCP 启动、面板重连和 POD 重建恢复仍未验收。

可复现的离线布局检查：

```sh
bash bin/fleet-native-worktree-selftest.sh
bash bin/fleet-native-worktree-selftest.sh /path/to/installed/fleet
```

可选参数只选择被检查的 Fleet 程序目录，所有 Git 写入与夹具提交都在临时目录中。
不通过时保留错误诊断，不修改被检查安装或放宽守卫。下一步先验证实际原生路径与会话绑定接口，
再添加最小适配；不能仅因嵌套布局被拒绝就先扩大只读守卫的例外范围。

本批验证记录：

| 检查 | 结果 |
|---|---|
| 新增布局夹具，本地 / drill 已安装版本 | 分别 11 项通过；未启动原生 Agent，不代表面板验收 |
| `bash bin/bash-guard-selftest.sh` | 全部通过 |
| `bash bin/fleet-worktree-root-selftest.sh` | 9 项通过 |
| `shellcheck bin/fleet-native-worktree-selftest.sh`、`git diff --check` | 通过 |
| `bash bin/docs-links-selftest.sh` | 810 个链接检查通过；新增文档的相对链接另行检查通过 |
| `bash bin/fleet-bin-inventory-selftest.sh` | 工具自测通过，仓库汇总失败：4 个既有 `nogh-task-*` 文件未归类；这些文件未被本批修改，新增夹具正确归入「构建与验证」 |

未宣称全量回归或 CI 通过；本批尚未提交、发布或切换用户会话的创建方式。

## Claude 原生嵌套 Worktree 的守卫适配

Claude 的原生目录位于主检出之下；不能用目录名白名单来解除只读保护，也不能为了避开
守卫而继续让 Fleet 再创建一份 Worktree。候选 `base-readonly-guard.py` 只为当前 cwd 的
真实 linked worktree 放行文件编辑：Git 返回的根目录与 common directory 必须匹配被保护
仓库，专有 metadata 必须位于该仓库的 worktrees 注册目录，其 `gitdir` 反向指针必须准确
指向当前根的 `.git` 文件。主检出、其他嵌套工作树、指回主检出的链接、复制/伪造 marker、
Git 重定向和当前 `.git` 身份文件仍拒绝。验证失败、Git 缺失或超时不授予这个例外。

外部工作树与普通允许路径不增加 Git 查询；只有目标命中受保护主检出、且 cwd 在其内部时
才验证一次，单次 hook 的多个目标复用结果。不增加缓存、目录创建者、后台服务或清理器。
此检查防止误写，不把可写的 Git 元数据宣称为租户安全边界；准入、仓库权限和进程绑定另行校验。

显式探针 `bin/fleet-native-claude-worktree-selftest.py` 使用真实 Claude CLI、临时 HOME 和
临时 Git 仓库。`--bare` 避免读取 OAuth/keychain；只向 loopback 端点发送假 key，端点恒定
返回 400。工具/MCP 为空，不生成模型回答，不操作用户文件。本机 `2.1.296` 的 18 项检查通过：
原生只创建一个真实嵌套 Worktree，原生 resume 从主检出恢复同一 session/cwd，不另建目录，
未提交修改保留；用实际 cwd 直接调用现有 Fleet 守卫，验证自身文件可写、主检出和身份 marker 拒绝。

```sh
python3 bin/fleet-native-claude-worktree-selftest.py --claude /path/to/claude
bash bin/fleet-native-worktree-selftest.sh
```

这不是 Fleet 创建入口切换，不是实际 hook 加载或完整 MCP 验收；`--bare` 只属于隔离测试，
不能进入生产默认参数。真实 TUI 的退出/保留/删除、native cwd 与 Fleet 任务身份关联、现有 setup
迁移、旧会话恢复与统一清理所有权仍须验收。国内节点的 Codex-only 范围与线上配置保持不变。

### 交互终端的原生目录生命周期

显式探针 `bin/fleet-native-claude-tui-selftest.py` 在自有 PTY 中运行真实 CLI，不使用
print-mode，也不启动 Fleet 面板。HOME、Git 仓库及信任均限于临时夹具；通过原生 onboarding
和信任界面确认该夹具，不预写用户的信任配置，不使用 bypass 参数。机器级配置存在时拒绝运行。
模型端点只绑定 loopback，所有请求用假 key 并返回 400，工具及 MCP 为空；不代表真实模型、
完整 MCP、生产账号或 Fleet 准入验收。非 bare 模式仍不能承诺跳过 macOS keychain reads。

```sh
python3 bin/fleet-native-claude-tui-selftest.py --claude /path/to/claude
```

Claude `2.1.296` 的实际交互行为区分目录名和会话显示名：

- `--worktree <name>` 只给目录命名；没有显示名且没有修改的会话正常退出后，原生会删除目录及分支。
  另加 `--name <title>` 的干净会话则提供保留选择。不能把窗口存在或 Worktree 有名字等同于持久保留。
- 含修改、未跟踪文件和未推送提交的夹具退出时显示 Keep/Remove；Keep 保留数据及原生所有权证据。
  只有明确选择 Remove 才删除该目录及分支，目录内指向外部的符号链接目标不被删除。
- Keep 后从保存目录执行 `--resume <ID>` 能恢复相同 ID 和 Git 绑定，但正常退出不再出现
  Worktree 清理选择；`--worktree <name> --resume <ID>` 从原仓库重新进入同一原生目录，
  不另建一层 Worktree，并恢复原生 Keep/Remove 选择。两种路径不能混称为相同生命周期。
- 中断测试在原生 transcript 的 user/assistant 记录已经可读后，才终止自有 CLI 进程；
  从已保存目录按精确 ID 恢复，检查未提交数据及 Git 绑定不变。这不证明首帧出现后立即崩溃、
  未落盘消息、宿主机断电或 POD 重建的恢复；首次未等 transcript 可读就中断时实际出现了
  `No conversation found`，不能隐藏该持久化边界。

探针等待真实 SessionStart 证据，不将输入框先绘制视为 hook 已完成。测试键盘节奏包含
onboarding 界面的稳定等待，不能用于启动性能统计。两个界面提示词可能触发多个原生 API
请求；证据逐个记录假 key 与请求路径，不把“两个提示词”误报为“只有两个 HTTP 请求”。
固定版本 Linux CI 使用同一探针并保存 JSON；以对应提交的终态结果为准。

这批只补齐原生行为证据，未切换创建或恢复入口。下一步适配必须明确选择原生生命周期，
由原生处理其 Keep/Remove；不能由 Fleet 截断退出提示后自行删目录，不能为恢复删除 held-seed
或准入限制，也不能把目录正常删除后回落主检出视为成功恢复。原有 session/window 记录继续复用，
不为上述差异新增目录生命周期服务。

### 原生创建入口候选：受管任务路径

`dash-raw-session.sh --native-worktree --node local --agent claude --task <accepted-task>`
是显式候选入口，不是默认安装或普通面板已经切换的声明。它仍要求真实的已接受 dispatch / launch
上下文、仓库准入及原有 CPU/容量/账号检查；只写创建意图，不运行 `git worktree add`。
现行有界 fetch 保留，随后记录所选 base ref 的提交；不通过省略版本契约换取速度。

- 原生 Claude 从所选主仓库启动，执行自己的 `--worktree`，并使用原生 `--name` 保留干净会话的退出选择。
  CLI 参数由既有任务 supervisor 在解析 held input 后加入，seed 不随原生创建命令发送。
  配置合并、MCP、模型、权限和账号入口不替换；没有为了设置 Worktree 而覆盖 `--settings`、停用 hooks。
- 创建意图只放在既有 tmux 窗口；实际 `@worktree` 由验证过的 SessionStart hook 写入。
  校验原生进程/任务代次、仓库 Git 身份、预期目录、base commit 和当前窗口意图之后，才发布运行证据。
  目录/分支已存在、重定向、Git 查询失败、base 改变或创建者不匹配均拒绝，不静默采用另一个目录。
- 原生目录名沿用 `scratch-<digits>` 以保留现有读者兼容，名字使用随机标识而不是第二套 Git 分配循环。
  不预填/补充旧 Worktree 池，不调用旧 allocator/setup，不在失败时使用 Fleet 的删除器回滚原生目录。
  名字只用于原生调用及旧显示兼容，不作为所有权证明。
- 从该任务的已保存 receipt 恢复时，要求创建意图与真实 Git 绑定仍然一致；使用精确 native ID，
  交由原生 `--worktree ... --resume ...` 重新进入同一目录与生命周期。用户已删除的目录不会自动重建，
  意图或绑定丢失不回落到可写主检出；迟到 hook 不会清空已经保存的创建者证据。

本候选明确拒绝未验证组合：远程自动选址、Codex、显式旧 setup/
依赖复制、transfer（含同 provider），以及用这个新建开关打开旧目录。它不静默禁用用户 setup 或降级到旧创建器。
这些仍是整个迁移的待办，不把只完成一条入口改写为总体目标完成。普通面板默认入口与旧会话继续走兼容路径；
不能在完整面板/MCP/认证/恢复与持久化验收之前把这个开关推广为默认。

显式 `bin/fleet-native-create-claude-selftest.py` 用真实 Claude、独立 tmux socket、临时 HOME/Git
运行实际 `fleet_launch.supervise` 和实际配置 hook；验证不预创建、创建者证据、窗口绑定、精确 resume、
新进程 incarnation、同一目录与编辑保留。任务 authority 与 finalize 在夹具内替代，不连生产 Hub，
因此它不是实际多副本准入/任务回收验收；也不是整个 Fleet launcher、面板或完整 MCP 验收。
工具及 MCP 为空，模型请求使用假 key 并由 loopback 拒绝，机器级配置存在时拒绝运行。

```sh
bash bin/fleet-native-create-selftest.sh
python3 bin/fleet-native-create-claude-selftest.py --claude /path/to/claude
```

### 原生创建入口候选：普通仓库准入路径

显式 `--native-worktree --node local --agent claude` 也可用于没有 accepted task 的普通仓库会话，
但必须启用既有仓库准入。入口仍执行 gate / finish，既有一次性 authority supervisor 执行
reserve / begin；缺少准入、冻结或不可用时拒绝，不退回直接执行、不伪造任务。
本批没有改变面板的默认创建方式，也没有新增后台目录服务。

- Claude 原生创建目录，Fleet 复用同一套创建意图和真实 Git 绑定验证；authority observe 成功后才写入实际目录。
- PID、进程出生标识、可执行文件、原生会话 ID 与目录意图在同一 reservation 内不可替换。
  退出必须以同一个 reservation 和已证明停止的原生身份报告，不把窗口消失作为停止证明。
- 保留未发送草稿，暂不接受此路径上的初始 prompt / seed；不为省时跳过准入、提前提交内容或使用旧目录池。
- 同一窗口的精确原生 resume 复用已有 receipt；活进程要求重连，错仓库/窗口/会话及丢失意图均拒绝。
- snapshot 的 `LAUNCH` 行覆盖 accepted task；普通原生路径把已有 `@authority_receipt` 保存为同一映射中的
  `AUTHORITY` 行。恢复须核对仓库、worker/window、原生会话和真实 Git 绑定，不从最新 transcript 猜测。
  这仍是显式候选，不等于真实面板或 POD 重建验收，不能据此默认推广。

源码回归使用真实临时 Git 仓库及替代进程/准入，覆盖直接和后台启动、草稿保留、拒绝、observe/stop
身份连续性和精确 resume；不把这些模拟证据等同于普通路径的真实 Claude、完整 MCP、生产 Hub 或延迟验收。

独立的真实运行夹具 `fleet-native-create-claude-selftest.py --fleet-launcher --local-authority`
进一步使用实际 Claude、Fleet 启动器、配置合并、原生 hooks 与核心 MCP，普通仓库 supervisor 不作替换。
准入 HTTP 服务仅在临时本机回环端口模拟，使用虚构 token，并检查仓库/worker、reservation 的
reserve → begin → observe → stopped 顺序，以及 observe 时进程真实存活、stopped 时同一身份已停止。
创建前准入时原生目录必须不存在；创建及同窗口精确 resume 各有独立 reservation，不构造 accepted task。

本夹具的 resume 保存已有 receipt 后销毁独立测试 tmux server，再通过实际恢复校验重建窗口绑定。
它不保留旧窗口选项、不重新创建目录；真实 `fleet-restore.sh` 的 snapshot/restore 映射另有替代 launcher 夹具验证。
两阶段均保留核心、用户与项目 MCP 和用户 hooks；native Keep 保留编辑，原生退出后已观测 MCP 全部结束。
原生输入框先显示未发送草稿，明确 Enter 后才允许模型请求；模型端点只以假凭据返回测试拒绝，不运行模型任务。
这些证据仍不等于完整生产恢复入口；gate/finish、生产 Hub、第三方 MCP、实际面板/POD 恢复和性能目标仍需验收。

### 真实 Fleet 启动器与原生配置验证

`fleet-native-create-claude-selftest.py --fleet-launcher` 在临时 HOME 中复制候选安装，运行实际
`fleet-claude.sh`、配置 composer、Fleet hook 表、插件和核心 MCP，不再用自制 `--settings` 覆盖原生配置，
也不传 `--strict-mcp-config` / 空工具集。只关闭夹具的自动预信任，临时仓库仍由原生 TUI 明确接受。
现有默认服务器名对应本地 stdio 假服务，另有用户级及项目级 MCP；真实第三方服务不在这个夹具中启动。

创建和销毁独立 tmux 后恢复两个阶段分别验证：Fleet receipt、用户 SessionStart hook、配置指纹、
所有夹具 MCP 的 initialize / tools/list、实际 cwd 和原生进程归属。用户 UserPromptSubmit hook 和
核心/用户/项目工具定义还须进入 native 请求；本地模型端点只返回 400，不执行工具或使用真实模型凭据。
每阶段只挂载一个核心 MCP，正常退出后已观测 MCP 进程均须结束；测试不以进程名猜测并清理机器上的其他服务。

这是实际 launcher/config 集成证据，不是第三方 MCP API、生产账号/Hub、完整面板或 POD 重建验收；
没有证明普通面板已经启用原生创建，也没有证明 1 秒/5 秒目标。核心 MCP 与用户配置保留，不把删工具作为提速办法。

```sh
python3 bin/fleet-native-create-claude-selftest.py --claude /path/to/claude --fleet-launcher
```

### 持久映射恢复

原生创建候选的恢复复用既有 `LAUNCH` 映射内的 context / receipt，不新增持久化文件类型或第二套目录索引。
快照解析器只对 receipt 与真实 Git 绑定一致的原生会话接纳主仓库内的 linked worktree；无证明的嵌套目录、
主检出、错误 provider / window / session 仍拒绝。会话 ID 取原生 receipt，不按最新 transcript 猜测。
恢复时再次核对窗口行、任务上下文与 Git 身份，再从 receipt 重建 `@native_worktree`，随后仍由既有
supervisor 校验当前任务所有权和新原生进程。旧 PID 的持久记录不是重启后进程仍活着的证明。

`fleet-native-restore-selftest.sh` 使用独立 tmux 的真实 snapshot/restore 与替代 launcher 验证映射往返和
错误 ID 不启动；真实 Claude supervisor 夹具另验证临时服务器销毁重建后的精确会话恢复与文件保留。
这不是完整 POD/账号/MCP/多副本 Hub 验收，也不使原生创建成为默认。旧映射没有原生 receipt 时继续走旧路径。

普通原生仓库会话的 `AUTHORITY<TAB>fleet_id<TAB>receipt` 记录同样只扩展现有 restore map，不新增数据库、
目录生命周期服务或另一份历史。快照仅收集带原生创建意图的普通准入窗口，旧非原生会话映射不变。
已有增量快照指纹也包含原生意图与准入回执，单独更新 reservation/进程证明不会被误判为无变化而跳过。
解析器与恢复启动前都校验该记录；重复、损坏、缺少意图、与 `LAUNCH` 冲突、错仓库/provider/window/session
以及 Git 绑定变化均拒绝，不能把缺少证明降级成普通 cwd 恢复。pullback 保留同一回执，不制造替代身份。
恢复后的 supervisor 仍需当前节点准入并核对 worker；旧 reservation 不是新的启动许可，旧 PID 不是存活证明，
本批不自动确认崩溃前尚未上报的停止状态、不改变 Hub 的冻结/迁移规则。

`fleet-native-restore-selftest.sh` 同时运行 accepted-task 与 ordinary-authority 两种实际映射流程，
覆盖精确回执往返、JSON 含竖线、错误会话以及坏/空/重复/冲突回执不启动。真实 Claude 普通准入夹具再验证
独立 tmux server 销毁后精确 resume、新进程身份、目录与编辑保留、完整原生配置和已观测 MCP 退出。
两类证据分别覆盖映射与真实运行；不能合称为真实生产面板或 POD 的完整端到端验收。

新增 `--restore-entrypoint` 隔离模式把两类证据串联：真实 session wrapper 启动 Claude，原生退出并选择
Keep 后调用实际 snapshot，销毁专用 tmux server，再由实际 restore 和 wrapper 恢复同一原生会话。
本机 57 项检查通过，覆盖新的进程身份、既有编辑、原生配置、MCP 和真实退出页；Linux CI 同步增加此路径。
夹具仅关闭退出页自动回收及快速退出分支，便于断言页面保留，不修改生产默认值或恢复探针时限。
准入仍为 loopback fixture，模型端点拒绝假凭据请求；不等同于生产认证、真实模型回复、运行中崩溃或面板性能验收。

该整链测试发现 tmux 3.7b 在无 UTF-8 locale 的环境下也会将格式内的 Tab 转为下划线，导致回执未进入快照。
候选改为一次批量读取 shell-quoted、带字段前缀的可打印格式，由 Python 解析，绝不执行字段内容；磁盘映射格式不变。
C locale 回归覆盖竖线、引号、反斜线、JSON 转义及空字段。取值或解析失败时保留原映射并报错，不发布残缺快照。

`--raw-entrypoint` 再把创建一端换成面板实际调用的 `dash-raw-session.sh --native-worktree`：准入、开窗、
草稿投递都走真实脚本，不再由夹具代建窗口或代按键。本机 60 项检查通过。这条链暴露了两处问题：
启动命令为 `FLEET_AUTHORITY_START` 加引号时调用了不存在的 `shq`，预留凭据丢失，supervisor 只好再申请一次；
现在就地转义，测试断言整条链只有创建与恢复各一次预留、准入零错误。另一处是草稿投递：7501 relay 下 Claude pane
的进程名是 shell，`scratch-prefill.py` 认不出输入归属，草稿永远等不到投递；#4620 改为采信 Agent 自己的
7501 idle（同时代表归属与输入框就绪），原生创建路径无需另写一套回执核对。
仍是 loopback 准入，不代表面板到窗口 48 秒的提速已经达成。

### SessionStart 的目录时序与恢复边界

显式 `--with-hooks` 模式取消夹具的 `--bare`，只加载通过 `--settings` 指定的临时
SessionStart 命令。临时 HOME、空 setting sources、假 API key、loopback 拒绝端点、空工具
及 MCP 保持；发现机器级 Claude 配置目录时拒绝运行。此模式不能继承 `--bare` 的
“跳过 keychain reads”保证，也不代表完整 Fleet hooks/MCP 或真实认证验收。

```sh
python3 bin/fleet-native-claude-worktree-selftest.py --claude /path/to/claude --with-hooks
```

本机 Claude `2.1.296` 的 49 项检查通过。此次是原生 CLI 真正调用 hook，不是直接传入
手写 payload；hook 通过既有 `fleet_launch.native_parent` / `root_native` 验证二进制、
进程出生时间与夹具 supervisor 归属，没有 mock 进程发现或修改线上 tmux。

| 调用路径 | SessionStart cwd | 后续 native init cwd | 原生 session ID |
|---|---|---|---|
| 主检出启动 `--worktree` | 新工作树 | 新工作树 | 新 ID |
| 主检出执行 `--resume <ID>` | **主检出** | 原工作树 | 同一 ID |
| 已保存的工作树执行 `--resume <ID>` | 原工作树 | 原工作树 | 同一 ID |

第二条在首次要求 hook 与 init 目录一致的探针中真实失败；因此不能简单把 SessionStart
的 cwd 当作“恢复已经完成”的工作目录证明。输出保留 `cwd_matches_init` 与两种目录，
后续版本若修正时序不要求继续出现旧行为。第三条同时验证不新建目录、不重置未提交修改。
同一原生 session ID 的恢复会产生新的进程 incarnation，旧 PID/birth 不能作为新进程凭证。

据此，原生创建迁移必须保存已验证的实际工作树，并从该目录恢复精确 native ID；
恢复时重新校验当前 Git 注册、仓库身份和原生进程，不用启动主检出、目录前缀或
`CLAUDE_PROJECT_DIR` 猜测所有权。缺失或错配的目录不得静默以可写主检出替代。
现有 Fleet restore 已优先使用保存的 `@worktree`，应复用其记录而不是新增恢复数据库。
该次探针尚未将实际 hook cwd 绑定到任务/准入 receipt，未切换创建入口，也未证明真实 TUI 的
同等时序；下一步仍须完成上述绑定与恢复拒绝路径，不能以这份离线记录解除上线门槛。

候选工作流 `native-claude-worktree` 在 GitHub-hosted Ubuntu 上分别运行 bare 与实际 hook
探针，使用官方 npm 平台包固定 `2.1.296` 并校验 SHA-512；不执行安装脚本，不使用账号凭据。
JSON 结果保存为 CI artifact。工作流存在不等于 Linux 验收通过，结果以对应提交的 job 为准。

### 复用既有回执绑定工作树

后续候选在 `fleet_launch.py` 与既有 local authority supervisor 内实现目录绑定，不新增
会话数据库、轮询服务、Worktree 创建者或清理者。窗口已有 `@worktree` 时，启动前通过
真实 Git 解析 root、private git directory 和 common directory，检查 linked-worktree
注册及 `gitdir` 反向指针。主检出、缺失目录、伪造/符号链接 marker 和错配注册拒绝；
查询清除继承的 `GIT_*` 重定向、关闭全局/系统 Git 配置，设置有限超时。

- 接受的任务：将三项路径放入既有 `@launch_receipt.worktree`，随既有任务 evidence 保存。
  SessionStart 的实际 cwd 必须解析为同一绑定。首次验明及投递前重检窗口/目录，不能只凭
  session ID 和活 PID 发布启动成功或投递 held seed。迟到 hook 不能替换或擦除已保存绑定。
- 本地准入：同一检查先于 reserve/begin；绑定放入现有 authority context/receipt，真实 hook
  必须通过目录检查才上报 observe。Hub 原有 PID/session identity 协议不扩展，不把本地
  路径冒称为 Hub 端验证过的目录授权；既有 legacy 输入投递语义也不因此变成 held-seed 协议。
- 恢复：新子进程显式使用已验证 root 作为 cwd，不继承 wrapper 留在主检出或其他目录的 cwd。
  已带绑定的任务回执在路径缺失、换树或变更注册时拒绝启动，不回退主检出、不猜另一会话。
  原生 ID、账号及任务代次仍由既有机制验证。曾经没有目录绑定的老回执与无仓库路径保持兼容；
  若窗口有既有 `@worktree`，在下一次受管启动补充绑定，不扫描或改写正在运行的老会话。

真实 Claude hook 探针扩展至 52 项：新增创建/显式目录恢复的 Git 绑定检查，以及从主检出
恢复时拒绝过早 cwd 的负例。隔离 tmux 的真实 wrapper/local-authority 测试另验证：wrapper
在主检出时，子进程仍从保存的工作树启动；误将主检出作为绑定时，不调用准入或启动 Agent。
后者使用假 native 程序，不宣称真实模型或面板验收。Python launch 回归还覆盖 Git 重定向、
反向指针错配、缺失 Git/超时、窗口换绑、旧回执兼容与缺少原生目录证明时不发布任务启动成功。

这些路径是绑定证据，不是原生生命周期所有者标记，也不是对可写 Git 元数据的租户隔离保证。
本批尚未切换原生创建入口、取消 Fleet setup、修改默认 MCP 或完成真实 TUI/部署验收。
后续由原生创建目录时，仍须在同一准入链中校验新路径与所选仓库，再写入这份既有绑定；
不能直接把一个未知 cwd 当成授权，也不能在已分配的 Fleet 工作树内再创建第二层工作树。

### 创建前 setup 的减法与迁移边界

盘点发现即使没有配置 `FLEET_WORKTREE_SETUP`，旧 `fleet_worktree_setup` 仍默认调用
依赖共享助手：扫描锁文件和其他工作树，尝试克隆已有 `node_modules`，单次有界预算为
60 秒。这是 Fleet 的额外准备工作，不是原生 Agent 必需的启动步骤，也不是原生 CLI
会自动替项目安装依赖的证据。

候选将自动共享改为显式 `FLEET_DEPS_SHARE=1`。未设置、空值、0 或非法值时，在调用
timebox/助手之前直接返回，不扫描、不克隆、不产生共享记录。已有显式 1、自定义
`FLEET_WORKTREE_SETUP`、直接执行 `fleet-deps-share.sh` 与 `--status` 均保留；不删除或
修改已有依赖树，不改 `FLEET_BASE_DEPS` 的显式/链接配置语义。Claude 与 Codex 共用的
旧目录分配入口都获得此减法，旧会话不需要重开。分类表将这些现有辅助工具归为按需，
不是新增组件或另一套依赖安装器。

这只证明默认启动少一轮预处理，不证明任务总耗时必然下降：依赖尚未安装时，首次项目
命令仍可能需要安装。依赖克隆加速的环境应显式保留 `FLEET_DEPS_SHARE=1`，并以完整项目
测试对照再决定是否关闭；不能用窗口更快出现掩盖后续安装时间。本批不修改任何已有登录配置。

下一步原生创建不能简单接回同一串 Fleet setup：

| 原职责 | 归属与边界 |
|---|---|
| 跟踪文件 checkout、分支及原生工作树注册 | 交给已验收的原生创建者；Fleet 不再先分配一层工作树 |
| 项目依赖安装 | 项目自己的命令和包管理器缓存；Fleet 不默认扫描、复制或安装 |
| 明确选用的预复制/共享 | 保留按需工具；不能把 `.worktreeinclude` 的文件复制误称为 lockfile 校验或 COW 克隆 |
| 本地忽略文件 | Claude 支持项目显式 `.worktreeinclude`；不替用户生成宽泛规则或自动复制凭据 |
| 现有自定义 setup | 不静默丢弃；特别是生成 Agent 配置/MCP 的 setup，不能迁到配置已加载后的 SessionStart 假装等价 |
| 起点与新鲜度 | Claude 的 native `fresh`/`head` 不等于任意 Fleet base 分支；显式最新代码要求不得被其缓存/失败回退静默替代 |

上述原生能力依据 [Claude Worktree 文档](https://code.claude.com/docs/en/worktrees)，尚非
本批真实创建入口的完整验收。本批只移除默认依赖预处理，不改模型、权限、准入、完整 MCP、
仓库起点或 fetch 策略，也不宣称达到 1 秒/5 秒目标。

### 原生清理所有权优先于 Fleet 回收

真实 Claude `2.1.296` 在 linked-worktree 的 Git metadata 内留下 `CLAUDE_BASE` 标记，
非交互会话结束后仍保留 Git 的 `locked` 文件。旧 `fleet_worktree_drop --force` 直接移动
目录，绕过 Git 的锁检查；同一原生夹具在父版本复现了这条错误路径。

候选改为由同一 `fleet_worktree_retire_metadata` 读取既有 metadata：存在 Git 锁或当前
已验证版本的 Claude 标记时拒绝 Fleet 回收，`--force` 仍只覆盖脏目录，不覆盖所有权。
直接 drop 在移除借用依赖链接、移动目录或同步删除之前检查；autoclean 在记录历史和回收
脱管进程之前检查；cleanup 与 idle-cleanup 在关窗、写终结历史或更新主检出之前拒绝。
不判断锁内 PID 是否过期，不替原生 Agent 解锁、删除标记或实现第二套原生清理器。

本机原生夹具扩展至 24 项：锁着时和显式解锁后，Fleet 强制回收都拒绝，目录注册与未提交
数据保持。Git 锁单独存在时同样保护普通工作树；普通 legacy 工作树在显式解锁后仍能按既有
路径回收。合成 janitor 测试还覆盖干净且已合并的原生目录不能被自动回收。

`CLAUDE_BASE` 是本次版本实测的保守保留信号，**不是稳定的通用 Agent 所有权 API**；
其存在只会拒绝删除，不能授予任何权限。新版本仍须重跑原生探针；缺失该标记不证明目录属于
Fleet。后续创建入口必须把已验证的原生生命周期所有者绑定到现有会话记录。此补丁不证明
并发创建/锁变化与 legacy 快速移动之间的原子性，也未切换创建入口或完成原生 TUI 删除验收。

依据：[Git Worktree 锁与回收](https://git-scm.com/docs/git-worktree)、
[Claude 原生 Worktree 生命周期](https://code.claude.com/docs/en/worktrees)。

## 原生 CLI 生命周期实测（2026-10-16 后续）

新增显式调用的 `bin/fleet-native-worktree-cli-selftest.py`。真实 Codex 在临时 HOME、临时 Git 仓库中运行，
不继承账号凭据、Fleet 会话或用户配置；仅信任测试仓库，使用 read-only sandbox。
推理流量定向 `127.0.0.1` 的临时端点，端点始终返回已知的 400 拒绝，不生成模型回答、不执行工具。
测试结束清理自己的临时目录与端点。此端点只在测试进程存活，不是产品组件或新增代理层。

```sh
bash bin/fleet-native-worktree-selftest.sh --native-cli
python3 bin/fleet-native-worktree-cli-selftest.py --codex /path/to/codex --fleet-root /path/to/fleet
```

默认布局自测仍不启动 Coding Agent。原生探针由操作者显式运行，输出 JSON，保留测试版本、精确原生 ID、
归一化的目录、每条检查及进程退出状态；不能把预期的 400 和测试报告中的 `pass` 当作模型调用成功。

已在本机 Codex `0.163.0` 和 drill Codex `0.162.1` 分别通过 25 项探针检查：

- `codex exec --worktree` 自行创建 `$CODEX_HOME/worktrees/<生成目录>/<仓库名>`，是主检出之外的 detached Worktree；原生 `session_meta` 保存精确 ID 与真实 cwd。
- 从已记录目录执行原生 `exec resume <精确ID>` 保留 ID、cwd，不额外创建 Worktree；原生 `exec fork <精确ID> --worktree` 创建不同 ID 与独立目录。
- 已知的推理失败退出、恢复与分叉之后，原目录的未提交文件仍保留，主检出未改变；所有推理尝试只到无 Authorization 的本机夹具。
- 实际 Codex 原生路径通过现有 base-readonly 守卫。因此「嵌套 Worktree 必须先改守卫」不适用于这次 Codex 路径，不能据上节布局夹具提前放宽守卫。
- 两个版本均明确拒绝 `codex --remote … --worktree`：`--worktree is only supported for local sessions`。当前 Fleet 默认路径正是 private app-server + remote TUI。
- 两个目标二进制导出的含 experimental 字段的 app-server JSON Schema 均未发现以 Worktree 命名的 schema；`ThreadStartParams` / `ThreadForkParams` 相关字段只有 `cwd`，未发现创建 Worktree 的参数。此证据不证明所有未公开接口都不存在，但不足以支持设计一个猜测的创建 RPC。

本次探针测试的是失败退出后的目录/会话生命周期；不是正常模型回合、真实 TUI、完整 MCP、Fleet 准入、生产性能或 POD 重建验收。
报告中的时间包括刻意制造的推理失败，仅供定位，不能与此前 48.4 秒草稿时间直接对比，也不证明达到 5 秒。

### 下一步由证据决定

先解决运行时所有权，而不是马上给 `dash-raw-session.sh` 附加 `--worktree`：

1. 核查目标二进制实际暴露的原生 app-server 协议，确认是否有受支持的 Worktree 创建/绑定接口；不能猜一个 RPC 或自行复制上游内部实现。
2. 若需要改用原生 local 运行时，逐项验证固定订阅身份、凭据隔离、SessionStart 所属进程、完整 MCP、原生事件和跨会话投递；不能仅通过 `--no-daemon` 绕开现有订阅证明。
3. 通过后只保留一处 Worktree 创建者，并把原生 ID / 实际 cwd 投影到 Fleet 已有恢复元数据；删除重复 fetch/alloc，不再另建目录池。
4. Claude 的目录布局、正常退出清理与恢复独立验收；Codex 的 local/remote 限制不外推到 Claude，国内 drill 不运行 Claude 会话。

当前代码中的原生 SessionStart 已记录 cwd，不需要再造一份会话数据库。
运行时原生化尚未完成；本阶段保持目标 active，不把探针通过视作架构重构完成。

### 首个运行时兼容性改动

`fleet-codex-runtime.py` 在创建临时 endpoint、调用 prepare 或启动任何子进程之前，
明确拒绝 private-runtime 路径中的原生 `--worktree`。原先该组合先启动 app-server，
再由 remote TUI 拒绝；现在保留既有 Fleet 目录创建路径，不以等待或自动降级掩盖不兼容。
`--` 后的同名字面文本不作为运行时选项，避免把用户文本误当成切换运行时的命令。

已有显式 embedded 路径保持兼容，但固定订阅仍禁止绕过 private-runtime 的身份验证。
此改动不是启用原生 Worktree，也不是建议用户加 `--no-daemon`。
`bash bin/fleet-codex-runtime-selftest.sh` 共 12 项通过，其中新增 5 项覆盖早拒绝无子进程、
prepare/目录分配零调用、字面参数、既有 embedded 透传和固定订阅拒绝。
测试使用有界假 Agent；真实模型、完整 MCP 与面板验收仍待运行时迁移之后执行。

本次同时重跑布局 11 项、旧 Worktree 9 项、文档 811 链接与两个相关 shell 的 shellcheck，均通过。
扩大检查 `fleet-codex-selftest.sh` 时，A–F3 通过，G 的「PATH 中不存在 Codex」夹具失败：
预期 127，实际 1 / `stdin is not a terminal`。该夹具到 G 前已删除其 stub runtime，
不经过本批修改的 `fleet-codex-runtime.py`；未修改此既有测试，也未宣称整个启动回归通过。

### 原生本地 TUI 与旁路后台不是同一个运行时

在本机 `0.163.0` 和 drill `0.162.1` 上追加了隔离的真实 PTY 探针：临时 HOME/CODEX_HOME、
临时仓库、无凭据、无真实模型，仅向本机拒绝端点发送固定测试文本。测试显式关闭
`features.daemon_auto_start`，同时使用 `--dangerously-bypass-hook-trust` 运行夹具的身份记录 hook；
这两个条件不能混同。不安装系统服务，也不连接既有用户 daemon。
在同一临时 CODEX_HOME 先启动自己拥有的 `app-server --listen unix://`，再启动不带
`--remote` 的 `codex --worktree`。它不是 Fleet 面板草稿验收，启动文本会提交给测试端点。

两个版本的观测一致：

- 本地 TUI 创建了原生 Worktree，SessionStart 记录精确会话 ID 与新 cwd；hook 继承的是 TUI 的测试标记，而非旁路后台的标记。
- 旁路后台 `thread/loaded/list` 为空；按同一 ID 调用 `thread/read` 能读到持久历史，但状态为 `notLoaded`。
- 推理请求仅到临时 `/v1/responses`，无 Authorization，返回预设拒绝；没有真实模型回答或工具执行。

因此，**同一 CODEX_HOME、能读到同一历史，不足以证明后台拥有这个正在运行的会话**。
不能用旁路后台的 `account/read` 替本地 TUI 证明实际运行身份，也不能据此假定事件和投递已经接通。
此结论限定于上述配置；尚未验证的自动 daemon 路径不据此判定支持或不支持。
现有凭据代理路径已经隔离每会话 CODEX_HOME 及其 `app-server-control`，无需再造一层 home 管理。

本轮不采用「本地 TUI 加一个仅用于验证的后台」方案，不改线上运行时或订阅校验。
探针结束清理自己的进程和端点；本机早期探针一次清理异常后，已通过工作目录与打开文件确认
残留后台仅属于临时夹具并终止，修正后的本机及 drill 探针正常退出。没有终止用户 daemon 或 Fleet 会话。

### 本地 Worktree 与原生后台可以共存，但启动参数决定实际归属

后续逐项对照推翻了「本地 Worktree 必然脱离可验证后台」这一推测；此前只证明了特定配置的旁路问题。
新增 `bin/fleet-native-local-runtime-selftest.py`：每个场景都是空 HOME、独立仓库和独立前台后台进程，
先启动原生默认 Unix socket，核对内核 peer PID，再用只读 `app-server daemon version` 确认
原生发现的 socket 和版本。只有已就绪、同版本的自有后台才启动 TUI；不调用 daemon start、
bootstrap、update 或 stop，不安装系统服务或包，也不连接现有用户后台。

本机 `0.163.0` 和测试节点 `0.162.1` 的 54 项检查通过；`daemon_auto_start=true` 写在临时配置中，三个场景均关闭
夹具 hooks 与 remote_plugin，使用同一无凭据的 loopback provider，唯一区别为下表的 CLI 参数：

| 本地 TUI 参数 | 自有后台的 loaded/list | 精确线程读取 | 原生状态通知 |
|---|---|---|---|
| 普通本地 TUI | 包含当前 ID | 非 notLoaded | 收到当前线程状态 |
| `--worktree` | 包含当前 ID | 非 notLoaded、cwd 是原生 Worktree | 收到当前线程状态 |
| `--worktree --dangerously-bypass-hook-trust` | 不包含当前 ID | 可读历史，但为 notLoaded | 无该线程状态 |

因此，**daemon 显示 running 不够；必须证明实际会话属于被验证的后台**。
原生目录与原仓库 Git common-dir/commit 相符，退出 TUI 后未提交测试文件保留，主检出不变。
每场景只有一次预期 400 请求，无凭据、无模型回答、无工具执行；systemError 不是成功完成。
固定版本 CI 还须对同一提交单独验证，不能从本机外推；测试节点仅运行临时目录夹具，未改在线安装。

下一步是把已经审阅的强制守卫移到只读管理层、可选 hook 交给原生信任，再验证移除全局 bypass 后
完整 Fleet 启动参数是否仍连接同一个后台。不能现在仅删这个参数：本探针没有验证真实守卫、完整 MCP、
固定订阅/代理凭据、准入 reservation、SessionStart 归属、面板未发送草稿或重连。
还需覆盖其它逐次 `-c`/profile/权限参数、共享与每会话 CODEX_HOME、退出和重建恢复。
不改在线启动路径，不放宽身份校验；保留 private-runtime 早拒绝，直到完整迁移通过。

```sh
python3 bin/fleet-native-local-runtime-selftest.py --codex /path/to/codex
```

### 逐次配置不是共享后台配置：启动参数矩阵

`--launch-flags` 扩展同一隔离探针，不增加生产运行时。原生 CLI 的参数含义参考
[官方命令说明](https://learn.chatgpt.com/docs/developer-commands)，以下归属结论来自实测，
不是根据参数文档推断。每个场景使用独立空 HOME、预先启动且内核 PID 已核对的后台，
实际 TUI 创建原生 Worktree、发出一次无凭据的 loopback 请求；固定 400 响应禁止推理。

本机 `0.163.0` 与测试节点 `0.162.1` 的 11 个场景、各 250 项检查通过；固定版本 CI
仍须对提交分别核对。测试节点只运行临时目录探针，未修改在线配置或用户会话：

| 参数/配置变化 | 实际后台拥有线程 | 模型及权限的验证 |
|---|---|---|
| 原有普通本地 / Worktree 对照 | 是 | 原生请求模型及 turn_context 与基础配置相符 |
| Worktree + hook-trust bypass | 否 | 可读历史不等于当前运行时 |
| Worktree + Fleet 三项普通 `-c` 默认值 | 否 | update 检查、hooks 开关、CLAUDE.md fallback，无真实 hook 脚本 |
| Worktree + `-c model="probe"`，与后台默认值完全相同 | 否 | 排除仅由配置值不同引起的推测 |
| 同样三项普通默认值预先放进原生 config.toml，无逐次 `-c` | 是 | 不改变原生后台选择 |
| 上述配置文件 + 原生 `--model` / `--sandbox` / `--ask-for-approval` | 是 | 当前线程使用指定值，后台基础模型和权限不变 |
| 仅原生 `--model`，或仅既有 approvals/sandbox bypass 参数 | 是 | 请求/turn_context 使用指定值，后台基础配置不变 |
| 原生 `--profile fixture`，或 profile + 普通 `-c` + 权限参数组合 | 否 | 原生 profile 与 CLI 覆盖值仍正确生效，但不属于已核对后台 |

因此仅移除 hook-trust bypass 仍不够，不能把已验证的旁路后台身份当作实际线程身份。
默认值应在原生配置/插件的安装更新边界管理，不在每次启动追加相同 `-c`；逐次模型和权限
优先原生专用参数。**不能为了共享后台而吞掉用户 profile/覆盖值、把账号合并到同一个 HOME，
或在已有会话运行时重写其共享配置。** 需要 profile 的路径在完成等价原生运行时身份证明前，
保留旧的明确支持/拒绝边界，不新增第二套 profile 解释器。

这仍不是完整 Fleet 参数集：真实 managed guards、可选插件、完整 MCP、每会话环境变量、
订阅/代理凭据、准入与恢复尚未在同一实际启动链路验收；并发不同会话的配置隔离也未由
逐场景单线程测试证明。保留现有认证与权限守门，不改上线启动方式，不宣称达成延迟目标。

```sh
python3 bin/fleet-native-local-runtime-selftest.py --launch-flags --codex /path/to/codex
```

### 共享后台的 MCP 环境不是逐客户端环境

显式探针 `bin/fleet-native-session-env-selftest.py` 同时保留两个真实本地 TUI，
各自创建原生 Worktree，并验证精确线程都属于同一个、内核 PID 已核对的原生后台。
三个进程的七项 Fleet 环境变量均赋不同的已知假值；空 HOME 内仅启动无副作用的夹具 MCP，
模型请求固定在 loopback 返回 400。它不运行真实 Fleet 工具、不读取真实凭据，也不是业务成功验收。

本机 `0.163.0` 与测试节点 `0.162.1` 各 30 项检查通过，测试节点的四个依赖源码哈希与候选一致；确认：
- 两个线程各有独立 MCP 进程、正确的原生 Worktree cwd，但七项环境值都来自**后台**，不是各自 TUI。
- 被检查的 MCP 环境没有 `CODEX_THREAD_ID` / `CODEX_SESSION_ID`；工具请求 `_meta.threadId` 带对应原生线程。
- 对第一线程调用时伪造 `_meta.threadId` 为第二线程，原生仍发出第一线程 ID，且复用第一线程的 MCP 进程；其他自定义 metadata 原样保留。
- 关闭第一个 TUI 不改变第二线程的工具归属；后台清理后本探针观察到的 MCP 进程退出，基础检出不变。

这是**共享后台迁移的阻断项**，不是现有逐会话私有后台泄露线上凭据的证据。
此前单后台插件 `env_vars` 测试只证明变量传递，不证明并发客户端身份隔离。
不得把 `FLEET_WORKER_CRED`、`FLEET_SESSION`、`TMUX_PANE`、角色等会话值作为共享后台默认值，
也不能靠重写后台环境或按 cwd 猜测归属来替代绑定。

原生线程 ID 是上下文路由线索，不是能力凭据：能访问该账号 RPC 的调用方仍可选择顶层 threadId，
其他 metadata 也可自行提供。后续须复用既有平台所有权/准入记录和签名能力验证，
证明原生 root 与 Fleet 会话、账号及能力的对应关系；未知、冲突、过期绑定拒绝执行，
并覆盖撤销、重连、并发创建和子 Agent。不能另造通用授权引擎或把模型提供的 ID 当证明。
并发本地 TUI root 如何与已准入的 Fleet 会话可靠关联仍未实现，旧运行时和全部守卫保持。

```sh
python3 bin/fleet-native-session-env-selftest.py --codex /path/to/codex
```

测试节点及固定版本 CI 必须核对同一源码；完整 MCP、真实凭据、面板、恢复和延迟目标
另做联合验收，不能由该离线夹具代替。

追加 `--hooks` 检查实际生命周期，而不把 MCP 证据外推为 Hook 已通过：

```sh
python3 bin/fleet-native-session-env-selftest.py --hooks --codex /path/to/codex
```

只在临时 HOME 为已审阅的无副作用夹具保存原生 trusted hash；闲置夹具后台重新加载后，
两个 TUI 分别置于独立监督进程下。没有 hook-trust bypass、真实 tmux 或平台准入调用。
本机 `0.163.0` 与测试节点 `0.162.1` 各通过 48 项检查，五个依赖源码哈希一致；
SessionStart 提供各自正确的 root/cwd，但十项夹具环境
（包括 launcher、launch context 和 authority context）全部来自共同后台。
复用现有 `fleet_launch.native_parent` 的真实进程识别，两个 Hook 均识别为同一个后台；
它不是任一 TUI 监督进程的后代，因此现有 `root_native` 验证拒绝这条归属证明。
这不是授权算法错误，也不能通过删除进程归属检查「修复」；共享后台的身份迁移仍未成立。

探针同时纠正就绪条件：原生后台还可能发出内部标题请求，单纯累计两次 HTTP 请求会在
第二个用户线程尚未进入首回合时提前返回。现在使用测试版本请求中的精确 root cache key
确认每个线程自己的 loopback 请求；内部请求不计为新会话就绪。这是固定版本夹具关联，
不是生产授权或新的启动探测协议。此前 MCP 进程/路由结论保留，但请求计数不能证明两条用户回合均已开始。

### 原生 fork 来源可以关联，但不是一次性准入

`--hooks --fork-seed` 扩展隔离并发夹具：通过原生 `thread/start` 创建空源线程，
用 `thread/name/set` 持久化，再启动真实本地 `codex fork <精确源 ID> --worktree`。
目录仍由原生创建，不复制上游 Git 实现，不根据最新文件或窗口标题猜测用户线程。

本机 `0.163.0` 的 70 项检查提供以下候选证据：
- 两个不同源线程分别产生独立用户 root/Worktree；`forkedFromId` 精确保留来源。
- 同步 SessionStart 中复用已有 Unix RPC 客户端、核对 native-parent 的内核 PID，
  能读取自己的原生 thread 元数据及 fork 来源，无需等待回调结束后再猜测关联。
- 原生允许再次 fork 同一个来源。因此源 ID **不是**一次性能力，不能跳过既有 reservation、
  owner/generation 和 capability 校验；重复或冲突认领必须由现有准入记录拒绝。
- 创建并命名源线程不发出模型请求，但每个源线程也启动配置的 MCP。这个准备步骤有成本，
  不能把它称为免费预分配，或在每次启动后无限保留空源线程。
- 原生 archive 能停止源线程与额外重复 fork 的夹具 MCP；随后原生 delete 删除这些精确拥有的
  空记录，不影响两个用户 fork。它们的来源 ID 仍可读，工具路由保持正确。
- 关闭第一条 TUI 后，用原生 resume 精确恢复其 fork，不创建额外 Worktree；第二条 TUI 保持运行。

```sh
python3 bin/fleet-native-session-env-selftest.py --hooks --fork-seed --codex /path/to/codex
```

这不是已接入的生产新建路径，也不将普通用户会话默认改为 fork。原生关系只能作为现有准入
记录的关联证据，不能单独授予凭据、选择终端或发布 accepted。共享后台环境仍不是逐会话环境；
Fleet launch/authority 的旧进程归属检查保持，尚未改为新收据格式。
接入前必须验证：准入原子认领与撤销、错误账号/后端拒绝、完整 MCP 按 root 取现有权限、
子 Agent 与恢复，以及共享后台仍存活时如何证明**某一线程**已停止。
TUI 退出、线程 unloaded 或父源记录被删，都不能单独释放执行额度或宣称任务完成。
此外须测量完整 MCP 下的准备成本、峰值进程数与原生直启对照；本夹具不证明 1 秒/5 秒目标。

## 完整目标的完成账本

### 默认配置发布交给原生 API，而不是继续扩展用户 TOML 编辑器

现有 `fleet-agent-defaults.py apply/check` 新增显式 native-remote/peer-PID 模式，
只针对一个已存在的 Codex home，要求 `--skip claude` 和独占维护窗口。默认值来源和
override 排除规则保持，缺失项才提交；通过已有 Unix RPC 客户端核对内核 PID（Linux 同时核对 UID）、
原生 base-user layer 文件路径和闲置状态，原生 `config/batchWrite` 负责 TOML 写入与
版本冲突处理。没有新增 TOML 合并器、配置策略表、常驻服务或失败时绕回旧写入器。
用法和并发边界见 [显式原生默认配置安装](CODEX-RUNTIME.md#native-default-installation-explicit-candidate)。

本机原生 `0.163.0` 的合并矩阵为 12 场景、287 检查；普通默认安装回归新增 native
协议与拒绝用例，15 组通过。包完整性、Linux 测试节点和固定版本 CI 分别验收，不能
以本机样本代替。原生版本针对配置语义，并非文件字节 CAS；注释修改仍可保留并写入，
字段值的并发修改则必须拒绝旧版本。闲置读取不是原子启动锁，尚不自动接入在线安装。

这是后续把稳定默认值从启动参数移到安装边界的候选，不等于已经删掉启动期 `-c`、
合并账号 home 或解除认证校验。完整 MCP、profile、托管守卫与真正面板路径仍需联合验收。

### 原生状态事件替代重复查询

源码候选的 `fleet-codex-attention.py` 不再每两秒重新建立 WebSocket 并读取 thread：
复用到现有私有后台的连接，消费原生 `thread/status/changed`；该连接收到精确线程的状态事件后，
只读校验降至每 30 秒。此前保留原有两秒读取频率，避免旧版本或不支持事件的后台退化；重连重新证明事件能力。
不增加服务；常规状态监测不调用 `thread/start` / `thread/resume`，也不增加常驻会话订阅。
新出现的问题详情仍由既有短连接路径读取，仅重放已加载线程的待处理请求，随后断开。
这只替换注意力监测；不把失败回合、失联或 `notLoaded` 当作任务成功。

- 本机 `0.163.0` 与 drill `0.162.1` 的隔离真实 app-server 均向未 resume 的连接广播状态事件。
  测试故意让模型请求在无凭据的本机端点返回 400，观测到 `active → systemError`，不是模型成功验收。
  同一源码候选在两处均只进行一次 initialize 和初始 thread/read，就消费了后续状态变化；
  保持原连接，未把失败状态写成 done。报告记录候选 attention / RPC 文件 SHA-256，均与当前工作树匹配。
- 身份仍按当前 launcher、精确 root UUID、账号 home 和 endpoint 绑定；其他线程事件丢弃。
  断线、半帧超时、畸形或过量事件只丢弃连接，保留已有需要用户处理的状态，随后重新获取快照。
- `thread/read` 仍是兜底校验，不以缓存取代账号或准入证明。原生请求的回答与权限处理路径未改动。
- 60 秒模拟时钟回归中，已证明事件投递的一条空闲会话从原先最多约 30 次连接/读取变为 1 次连接、2 次读取。
  这是监测调用次数，不是整体 CPU、面板草稿或模型回复的实测提速。
- 源码候选通过注意力 21 项回归，覆盖真实隔离 tmux 的身份竞态、显式 blocked 保留与未证明事件时的兼容读取；
  运行时 15 项回归包括空闲/心跳/分片/半帧断线处理，以及 TUI 正常/非零退出时关闭事件连接并清理自己的后台。
- 追加回归复现并修正了快照期间清空新事件的竞态：若读取期间收到的状态与快照冲突，保留原提示，下一次 tick 重读。
  不用可能过时的 idle 清空新审批，也不重新显示已经解决的提问；一致的事件无需额外读取。

尚未部署。完整 MCP、真实面板和生产空闲资源对比仍按后续验收矩阵执行。

### 上下文用量不是同一条广播

继续删除轮询前，单独验证[原生用量事件](https://learn.chatgpt.com/docs/app-server)：
`thread/status/changed` 能到达只初始化的观察连接，不代表
`thread/tokenUsage/updated` 也会广播给它。新增显式离线探针
`bin/fleet-native-usage-cli-selftest.py`，使用空 HOME、真实 app-server、三个有界测试回合，
模型端点仅在 `127.0.0.1` 返回合成 Responses，不带凭据、不执行工具。

本机 Codex `0.163.0` 通过 45 项检查：

- 只初始化以及只做 `thread/read` 的连接没有收到用量事件；创建线程的连接收到。
- 对已加载的精确线程做 `thread/resume` 后，观察连接收到用量；同一连接
  `thread/unsubscribe` 后不再收到，原控制连接仍收到。
- resume 前后线程 ID、model、approvalPolicy、sandbox 保持；只有显式发起的三个回合和
  三次本机请求，没有第二个线程或观察操作触发的推理。
- 每回合的 `last.totalTokens` 与累计 `total.totalTokens` 独立核对，分母取原生事件，
  不把累计用量当上下文，也不从状态广播推断未收到的数值。

上述 45 项在提交 `938c46c6` 的固定 Linux `0.162.1`
[CI 38974315185](https://github.com/verkyyi/claude-fleet/actions/runs/38974315185) 和测试节点临时目录中
也通过；测试节点探针及 RPC 文件 SHA-256 与提交一致，没有改安装或在线会话。

后续候选扩展至本机 `0.163.0` 的 87 项：本机端点先暂停返回，观察连接在原回合活动时
订阅、断连、重新订阅；释放响应后原控制连接与观察连接都收到同一回合完成和用量。
另一次真实代码模式工具调用发起审批，观察连接断连后请求仍待审批，重连只重放原请求；
它不回答、不批准、不取消。原控制连接明确拒绝，双方收到原生 resolution，临时 canary
不存在，线程与更改后的 on-request/只读沙箱策略保持。五个显式回合只有六次预期的
本机 Responses 请求，没有因观察而额外推理或创建第二个线程。

87 项新增断言仍须按新提交的固定版本 CI 和测试节点结果验收，不能沿用 45 项的通过记录。
此测试不启动真实 TUI，不证明完整 MCP、真实账号隔离、生产窗口身份竞态或性能。
上述探针本身不改变生产监测器，也没有提前删除 rollout 计量和兼容读取。

```sh
python3 bin/fleet-native-usage-cli-selftest.py --codex /path/to/codex
```

后续计量候选以 `FLEET_CODEX_NATIVE_USAGE=1` 显式试验，默认关闭。它复用注意力监测器
已有连接，不增后台服务：只订阅已加载且身份匹配的根线程，使用原生通知过滤，
将用量和模型设置交给已有 Meter/计量总线。收到有效用量后暂停 Meter 的 rollout 轮询；
连接断开、身份改变、事件异常或五秒监测租约到期就恢复旧读取。尚未持久化的新线程
可能拒绝 resume；重试成功也不能补造错过的用量，须等下一个原生事件。
审批请求永不由观察者回答，既有认证、完整 MCP、守卫和旧 hook 路径不变。

`--meter-candidate` 将实际 Monitor/Meter 接到离线原生探针，另外验证断线回退、重新订阅、
稳定阶段不读 rollout、最后一回应用量不混入累计值、原控制端仍收到文本而观察端过滤文本。
本机 `0.163.0` 和测试节点临时目录中的 `0.162.1` 已各通过 103 项，测试节点六个候选文件
SHA-256 与工作树一致，未改在线安装；固定版本 CI 仍须对提交后的同一候选单独验收。
测量出口与 tmux 身份是夹具，真实 tmux 写入竞态另有隔离回归；这些结果不等于
真实面板或长会话性能通过，也不删除其他 collector/context-command 的兼容读取。
运行方式、失败回退与停用见 [Codex Context](CODEX-RUNTIME.md#context)。

### 原生插件替代跨 Agent 翻译的证据

> **现状（T589，EPIC T580 C3）：桥已退。** `fleet-codex-plugins.py sync` 只在安装时跑，
> 用 Codex 原生安装器跟随 Claude 侧 `/plugin` 的记录（`marketplace add` · `add` · `remove`，只动本 marketplace），
> 并先清掉旧桥产物；启动器不再同步、不再传 `--plugin-dir`。四项验收的出处见
> [CODEX-RUNTIME «Native plugin migration»](CODEX-RUNTIME.md#native-plugin-migration)。下文是迁移前的证据记录。

[官方 CLI 文档](https://learn.chatgpt.com/docs/cli/reference) 已提供 `codex plugin` 与 marketplace 管理。
不能继续以「Codex 没有插件系统」作为逐次翻译的设计依据。本机 `0.163.0` 和 drill `0.162.1`
的临时 HOME/CODEX_HOME 夹具均验证：

- 原生 `plugin marketplace add` 能读取 `.claude-plugin/marketplace.json`；`plugin add/list/remove` 完成安装、启用查询与卸载。
- 原生安装自行将 Claude `commands/*.md` 转为缓存内的技能；`skills/list` 返回原始技能和转换后的命令技能，均带原生 pluginId。
- 实测命令技能名称为 `<plugin>:source-command-<command>`，不同于当前 Fleet 桥生成的别名；调用入口不能假定旧名称仍有效。
- `hooks/list` 发现插件的 SessionStart，来源为 plugin，但信任状态为 untrusted。只发现不代表已经获准执行；不能通过默认绕过信任完成迁移。
- 探针未创建模型回合、未启动 Claude、不读取用户凭据、不改变 live 插件、系统服务或完整 MCP 配置；只安装并移除夹具插件。

据此，E 批不再设计新的插件清单、命令转换器或 hook 合并器；优先直接使用原生安装器，
将安装/升级移到用户显式插件操作或受控安装阶段，而不是每次打开会话都重写技能和配置。
现有 `fleet-codex-plugins.py` 暂为兼容桥，不是新的长期所有者；不能因测试插件可安装就全部删除。

兼容桥已修正一个会破坏所有权的入口：`agent-overrides.json` 中声明 `codex.plugins`
（或父级 `codex`）后，`sync` 不再装配技能/MCP，`dirs` 现在也不再提供 Claude 插件目录给 hook 合并器。
此前只有前半生效，用户自行管理 Codex 插件时仍会注入旧 hooks，可能重复执行或绕过原生插件关闭选择。
三项新增回归先复现该失败，再验证默认覆盖文件、显式父级覆盖与未覆盖时的旧行为；含后续清理用例，兼容桥共 92 项通过。
这不是自动迁移：不删除旧技能/config，不改用户原生安装，也不替用户信任 hooks；清理与切换仍须完整验收。

新增显式运行的 `bin/fleet-native-plugin-cli-selftest.py`，在全新 HOME/CODEX_HOME 中
用原生 CLI 安装/卸载临时插件，实际启动夹具 MCP；不使用用户凭据，不创建模型回合，也不修改线上安装。
本机 `0.163.0` 与 drill `0.162.1` 各通过 106 项检查，三种环境配置结果一致：

| 插件 `.mcp.json` 写法 | 实际 MCP 进程结果 | 迁移结论 |
|---|---|---|
| 不声明环境传递 | Fleet 当前使用的七个会话环境变量全部缺失 | 不能直接安装现有插件后删除旧桥 |
| `env_vars: [变量名, …]` | 七个夹具值全部正确传入 | 可用原生白名单传递，不落盘真实凭据 |
| `env: {变量名: "${变量名}"}` | 收到 `${变量名}` 字面量，不是环境值 | 不能照搬其他 Agent 的变量插值假设 |

七个变量是 `TMUX`、`TMUX_PANE`、`FLEET_CONF_DIR`、`FLEET_SESSION`、`FLEET_WORKER_CRED`、
`FLEET_MCP_BIN`、`FLEET_MCP_ORCH`；测试全部使用已知假值，从不读取真实 worker credential。
这是目标版本的实测兼容证据，不是允许把所有宿主环境转交插件；未来只声明每个插件实际需要的变量名。
夹具同时验证原生技能、命令转换、hook 的 untrusted 状态及新建空线程后执行标记不存在。
[原生 hook 信任](https://learn.chatgpt.com/docs/hooks) 必须针对当前定义审阅；本次没有扩大信任，
该装卸夹具本身不证明受信任 hook 的执行、事件映射或完整 Fleet MCP 工具调用；单独的信任执行验证见后文。
夹具使用绝对路径指向自己的临时 MCP 程序，未据此宣称插件路径变量或跨机器打包已通过。

追加真实原生客户端验证，不再只看工具清单：

- 通过 `mcpServer/tool/call` 调用夹具工具成功；插件的 `tool_timeout_sec = 1` 能中止等待 2.5 秒的夹具调用。
  等串行夹具完成旧请求后再调用成功；不声称客户端超时会终止服务器内部工作，也不声称 1 秒是生产超时值。
- allowlist 夹具读取实际 `conf/mcp-orch.json`（派活组随核心，#4334）的命令/参数，仅在临时副本补 env_vars 和测试超时。
  真实 `fleet-mcp.py --group orch` 通过原生插件启动，shell 中的 FLEET_MCP_BIN 路径展开正常，七个工具仍可发现。
- 使用格式故意无效的假 worker 凭据调用 `children`，真实 Fleet MCP 返回 credential malformed / Nothing ran。
  证明该拒绝路径未被原生 MCP 绕过，不代表有效凭据、Hub 准入或所有工具已验收。
  HOME/config 均为临时目录，TMUX 指向不存在的夹具 socket；不接入 live tmux，也不修改线上插件。
- 本机复制工作树 MCP，drill 复制其已安装 MCP，到各自临时 bin 后执行；不修改源文件。
  原实现的审计日志默认跟随脚本位置，早期探针直接引用安装目录会写入运行日志；现已改为副本运行，
  并检查 `via=badcred` 审计记录留在临时目录。两者是兼容性验证，不宣称部署了同一源码候选。

原生开关与卸载也在新起的独立 app-server 上验证，不以缓存目录存在代替运行时结果：

- 单次原生 `-c plugins.native-fixture@fleet-probe.enabled=false` 的有效配置确实为 false，
  技能不再启用，插件 hooks 与 MCP 不再加载；退出后原安装仍为 enabled，未改持久配置。
- `plugin remove` 后，原生列表、有效配置、技能、hooks 和 MCP 均不再包含该插件。
  删除的是配置条目本身，不保留「用户卸载过」的标记，因此条目缺失不能作为重新桥接的理由。
- 不新增 Fleet 插件启停数据库，也不自己实现 Codex 的多层配置合并。
  一次受控迁移必须覆盖该登录的账号 homes，明确停止旧桥后再交由原生管理；
  原生安装/启用/关闭/卸载之后，旧桥不得因 Claude 侧仍启用而重新生成技能、MCP 或 hooks。
  既有 `codex.plugins` override 表达整条桥的退出；显式清理入口见下节，逐 home 的原生迁移验收仍未完成。
  不采用「看到原生 enabled=true 就自动切换，条目消失就切回 Claude」的推断式方案。

### 一次性旧桥清理

源码候选提供 `fleet-codex-plugins.py retire`，仅作为一次性迁移工具，不在启动或安装链上自动执行。
它不安装插件、不复制原生状态、不选择模型、不代替 hook 信任，也不自动修改 override。
操作顺序是：完成目标版本与所需插件的原生验收，保留旧安装与配置回退副本，
在旧会话已停止且满足至少一个发版周期兼容要求的迁移窗口，明确停止旧桥，再预览并执行清理。

1. 在现有 `agent-overrides.json` 中保留其他配置并加入 `codex.plugins`（父级 `codex` 也有效），
   确认 `sync` 与 `dirs` 都停止桥接；缺少该覆盖时，清理命令拒绝执行。
2. 默认覆盖安装器使用的账号 homes；可重复传 `--codex-home` 限定演练范围。
   单个 home 通过不代表整登录完成迁移；共享 skills/config 符号链接须先人工明确所有者。
3. 默认只打印预览，审阅后才显式加 `--apply`：

```sh
python3 bin/fleet-codex-plugins.py retire --codex-home /path/to/test-codex-home
python3 bin/fleet-codex-plugins.py retire --codex-home /path/to/test-codex-home --apply
```

可移除对象限定为：
- `fleet-plugin-*` 链接必须精确指向 Claude 原生安装记录所证明的该 marketplace 技能目录；关闭但仍安装的插件也可证明，查不到记录则拒绝猜测。
- 命令适配目录必须只有带 Fleet 生成标记的普通 `SKILL.md`；有额外文件或 SKILL.md 自身是链接则拒绝，不使用递归删除。
- MCP 只移除一对完整、顺序正确、无重复的旧桥 marker block，外部配置与原生插件开关不变。

所有 home 先完成预检再开始写入；不明链接、重复/缺失标记或第二个账号异常，均在写入前拒绝。
不将预检称为跨文件事务：执行期间仍须避免并发编辑/安装，磁盘写入失败时应保持桥关闭、检查结果并重试。
原生插件缓存、用户技能、其他 MCP 配置和 Claude 插件源文件不删除；成功后重复执行为零项。
隔离回归共 92 项通过，含预览不写入、多 home 预检、关闭插件的来源证明、用户文件保留、幂等及旧桥不再生成。
新增回归复现固定临时文件名被预置符号链接时会改写其他文件的风险；共享写入函数已改为同目录独占创建的随机临时文件，
保留既有文件权限，原子替换后清理临时文件；sync 与 retire 都不再跟随那个固定临时路径。
本批没有在任何真实账号 home 执行清理，尚不能称为完成原生所有权切换。

串联验证可显式运行：

```sh
python3 bin/fleet-native-plugin-cli-selftest.py --retire-bridge --codex /path/to/codex
```

它在同一个临时 home 中用真实旧桥生成链接、命令适配技能和 MCP marker block，
安装原生夹具插件，声明退出旧桥，预览并清理；随后实际启动原生 app-server 验证技能、hook 发现、
MCP 调用与超时。清理后 config 与旧桥生成前的快照逐字一致（快照取自原生插件已安装时）。
再通过原生关闭/卸载，并重新执行旧桥 sync/dirs，验证三类旧生成物均不复活。
该选项不创建模型回合、不信任 hooks、不访问 live tmux，不代表全部 Fleet 插件已完成真实身份与业务调用验收。
drill 使用上传到临时目录的源码候选与原生二进制，不替换已安装 Fleet；报告记录桥代码 SHA-256，避免混用版本证据。
同一桥源码候选在本机 `0.163.0` 与 drill `0.162.1` 各通过 172 项串联检查；两份报告的桥 SHA-256 均与当前源码匹配。

复测方式（显式使用目标原生二进制，不纳入无 Codex 环境的默认 CI）：

```sh
python3 bin/fleet-native-plugin-cli-selftest.py --codex /path/to/codex
```

切换前还须验证：真实 Fleet 插件 MCP 的超时、路径展开与完整调用，原生 hook 信任/变量/事件映射、
旧命令别名、各账号 home 的独立安装，以及原生关闭后不会被 Claude 同步重新启用。
同一插件的桥接技能、MCP 与 hooks 必须一并退出，且只清理可证明由 Fleet 生成的旧物；
用户自建文件与老会话至少保留既有兼容周期。默认不安装 EPIC 等按需插件；orchestrator 是会话模板，人起才有（steward 模板随 #4900 去掉）。

### 实际 orchestration 插件的原生包（已退役）

`fleet-orchestrate` 曾带一份 Codex 原生包，并用 `fleet-native-plugin-cli-selftest.py --package` /
`--package-role` 验收真实包加载与角色链路。编排改成普通会话模板（`spawn agent:orchestrator`，#4340）后，
插件条目、角色脚本与这两种验收方式一并删除（#4790 删掉了最后的空条目）；没有角色要接，
Codex 会话也只用原生历史/压缩和 `children` 取当前业务状态。

### 原生 hook 信任与实际执行

本机 `0.163.0` 的独立临时 HOME 中，先在原生 `/hooks` 界面审阅唯一的夹具 SessionStart 命令，
再用该条目的 trust 操作信任；没有选择全局信任，也没有使用 `--dangerously-bypass-hook-trust`。
界面将当前定义 hash 记录在原生 `hooks.state` 中，独立 app-server 随后识别为 trusted。
仅 `thread/start` 没有观察到执行标记，因此不再把创建空线程视为 hook 执行验收。

新增显式回归 `bin/fleet-native-hook-cli-selftest.py`：

```sh
python3 bin/fleet-native-hook-cli-selftest.py --codex /path/to/codex
```

本机 `0.163.0` 与 drill `0.162.1` 各通过 34 项；均为临时 home，不修改真实账号信任或插件。

- 夹具安装后 trust 为 untrusted，实际原生 `exec` 启动不会执行该 hook。
- 测试仅通过原生 `config/value/write` 在临时 home 中记录已审阅夹具的精确 hash，重启后确认 trusted；
  实际 SessionStart 随后执行，payload 的原生 session ID 与 `thread.started` 一致，source 为 startup。
- `PLUGIN_ROOT` / `CLAUDE_PLUGIN_ROOT` 均指向实际安装目录，两个 DATA 变量一致且非空，
  已知假的 `FLEET_SESSION` 正常传入。未使用或打印真实 worker credential。
- 修改安装副本中的 hook 命令定义后，原生状态变为 modified，旧信任不再允许执行；
  不把该结果扩大成「被调用脚本内容变化一定会使信任失效」。
- 每阶段都只向自有 localhost 端点请求一次并得到 HTTP 400，三个推理回合故意失败，没有真实模型回复。
  这验证 hook 生命周期，不代替终端面板、真实身份、PreCompact/PostToolUse 等其他事件或完整业务验收。

目标是由原生 Agent 管理信任状态。上述写入只属于隔离测试，不添加 Fleet 自动信任器或第二份 trust 数据库。
不能将这个隔离结果扩大成当前 Fleet 启动器已经满足目标：后续源码审计发现
`fleet-codex.sh` 仍无条件给 TUI 传入 `--dangerously-bypass-hook-trust`，旧测试也明确要求它存在。
该参数原先服务于 Fleet 内联守卫，并不是只授权 Fleet hooks 的名单。

```sh
python3 bin/fleet-native-hook-cli-selftest.py --probe-bypass --codex /path/to/codex
```

本机 `0.163.0` 与 drill `0.162.1` 各通过 47 项：在临时 HOME、原生插件和 localhost 失败推理端点中，
同一个 untrusted hook 不带参数时不执行，带参数的原生 `exec` 会执行，且原生存储仍显示 untrusted；
随后精确 hash 信任、定义变化失效仍成立。没有使用真实模型、凭据或线上信任配置。
上述首轮 47 项证明 embedded/exec 的绕过作用。随后补了独立的真实 remote TUI 验证：

```sh
python3 bin/fleet-native-hook-cli-selftest.py --remote-tui --probe-bypass --codex /path/to/codex
```

本机 `0.163.0` 与 drill `0.162.1` 各通过 58 项。每阶段启动自有 app-server，
原生 TUI 连接该 Unix socket，在自有 PTY 中运行，账号配置及插件都只在临时 HOME。
非审阅阶段要求原生 `thread/read` 的新线程回合确实 failed，并与实际 hook payload 的 session ID 一致；
历史线程排除，不用屏幕文字猜测回合成功。失败推理只访问自有 localhost HTTP 400 端点。

- untrusted：TUI 显示原生 hooks 审阅界面，没有执行 hook、没有发送推理请求；测试不确认信任。
- bypassed：仅 TUI 传入 bypass，后台不带此参数；未信任 hook 仍执行，原生信任记录仍为 untrusted。
- trusted：只有审阅过的夹具精确 hash 在临时 HOME 被信任，hook 执行，身份与当前原生线程一致。
- changed：命令定义改动后为 modified，重新出现审阅界面，hook 与推理均未运行。

因此 `server_flags` 不转发参数并不能隔离这个风险，真实 remote TUI 行为已证明 bypass 仍会生效。
同一探针还确认 CLI `-c hooks.SessionStart=...` 来源为 `sessionFlags`、`isManaged=false`、
`trustStatus=untrusted`；内联配置不是天然的管理员信任，不能简单删去 bypass 后假设平台守卫照常运行。
drill 首次 remote 探针在单次推理请求计数断言失败；补充诊断后重跑通过，尚未解释首次计数差异。
计数断言未放宽，也不把本次功能验证称为重复性或性能验收。

这是推广原生插件前必须解决的条件，不在本批贸然删除该参数，避免现有基础守卫被一起跳过。
下一步把平台守卫与可选插件信任分离，优先验证原生 managed hooks：
[官方说明](https://learn.chatgpt.com/docs/hooks)区分管理员托管 hooks 与需审阅的非托管 hooks。
必须证明平台守卫执行、拒绝和更新行为保持，同时未审阅插件不执行，才能去掉全局绕过。
不采用自动信任全部插件或关闭全部非托管 hooks 的办法，后者会破坏用户显式安装的扩展。
真实插件升级仍遵循原生审阅及受控发布；平台强制守卫与可选插件 hooks 不混为一类。

管理员层验收必须使用真正隔离的系统配置环境：本机 Docker 服务当前不可用，drill 的
`unshare --user --map-root-user --mount true` 被拒绝。没有因此写入在线 `/etc/codex` 或改其权限。
系统层要求的路径和优先级以[原生托管配置说明](https://learn.chatgpt.com/docs/enterprise/managed-configuration)为准，
后续需在隔离测试镜像/环境验收，不能把临时 CODEX_HOME 当作系统配置隔离。

2026-10-16 补测历史：测试 POD 的普通用户可跟踪自己创建的子进程，因此曾增加显式
`--managed-proot /path/to/proot` 探针选项，用 PRoot 只给测试子进程映射临时
`/etc/codex` 视图。脚本只在临时目录写 requirements 和 hook，检查映射标记在子进程可见、
在宿主路径不存在。PRoot 只是受控 fixture 的路径虚拟化，不是安全沙箱，不用于生产，
也不能提供性能样本；没有修改在线系统配置、seccomp、用户命名空间或账号信任。
测试工具来自 Debian 官方 HTTPS，按各包下载页的 SHA256 校验后解包在临时目录，不运行系统安装：

| 包 | SHA256 |
|---|---|
| [`proot_5.1.0-1.3+b1_amd64.deb`](https://packages.debian.org/trixie/amd64/proot/download) | `7ca9260edf1ca6666f9b33e1da551638055934d673117acd135ff5367f420744` |
| [`libtalloc2_2.4.3+samba4.22.11+dfsg-0+deb13u1_amd64.deb`](https://packages.debian.org/trixie/amd64/libtalloc2/download) | `b4cc8aa74c8b7c05a64efb6577acc955f522a8e39d8f37fe60b1b3fe6634ce96` |

该实验选项已在本 PR 内移除，改用下述原生挂载命名空间 CI；不把未发布的 PRoot 试验路径
留下作为额外适配层。包哈希仅保留为失败证据的追溯信息。

**此组合尚未通过，不是 managed hooks 验收成功。** Codex 0.162.1 的 `hooks/list`
确认 requirements hook 为 `source=system`、`isManaged=true`、`trustStatus=managed`，
插件仍独立显示 `untrusted`。但 exec 两次在信任插件后的 managed SessionStart 标记缺失；
remote TUI 一次出现两次本地请求；另一次 PRoot 外层退出码为 0，原生事件却明确 `turn.failed`。
保留退出码、精确线程 ID、一次请求和双 hook 执行断言，不通过放宽检查获得绿色。
这些异常尚不能归因于原生 Codex：需要在不经过 PRoot 的一次性 Linux 环境交叉验证，
先排除测试工具的退出码/并发进程行为。该历史试验未进入默认 CI，也未修改生产启动器。
同一候选不启用路径映射时，本机 Codex 0.163.0 与测试 POD 0.162.1 的
`--remote-tui --probe-bypass` 各 58 项通过；这只证明既有非 managed 回归仍通过，
不能证明上述异常必定由 PRoot 引起。
当时仍缺实际 PreToolUse 拒绝、配置覆盖/升级及完整面板验证；后续补测见下文，不能只凭此记录去掉全局 bypass。

交叉验证使用独立 `native-managed-hooks` CI：GitHub-hosted Ubuntu 24.04 一次性 VM，
固定官方 npm `@openai/codex@0.162.1-linux-x64` 包及 SHA512，不加载真实账号或模型服务。
先建立私有 mount namespace，只把 owned `/tmp/fleet-managed-system-*` 目录映射到该 namespace
的 `/etc/codex`，再降回普通用户且设置 no-new-privs，分别运行 exec 与 remote TUI 探针。
`--managed-system-dir` 拒绝 root、非 GitHub-hosted 环境、非临时/非 owned/非空目录、
未实际绑定到 `/etc/codex` 或与外层相同的 mount namespace。写入仍只针对 owned 临时路径。
外层检查自己的 mount namespace 未变且 `/etc/codex` 空目录未收到 fixture 文件，并移除这个
CI 专用空目录；不会连接集群或修改在线节点。新 CI 的结果必须单独审阅，不由 PRoot 结果推断。

第一次 CI 在定位 npm 包中的二进制路径时失败，尚未执行 managed 测试；按实际包布局修正后，
[CI 38967632989](https://github.com/verkyyi/claude-fleet/actions/runs/38967632989) 的 exec 44 项、
remote TUI 50 项通过。exec 中未审阅/修改过的插件不执行，managed SessionStart 仍执行；
remote TUI 的未审阅/修改状态先停在原生审阅门，受信任后 managed 与 plugin 两者均执行。
这排除了「managed 与插件必然无法共存」的推断，但不把 PRoot 的异常当作已定位的原生缺陷。

下一层探针用两次本地合成 Responses 事件驱动**原生**工具调用，不调用真实模型：
正对照让 `exec_command` 在临时目录写 canary；随后要求 managed PreToolUse 拦下相同写入，
核对 Bash 事件、工具调用 ID、原生线程 ID 和返回给原生循环的拒绝原因。还测试
`features.hooks=false` 覆盖尝试及 managed 命令更新后的新拒绝原因。仅该受控 fixture
使用 full-access 来排除沙箱自身拒绝造成的假阳性；生产权限、完整 MCP 与守卫配置不变。
这些新增断言在独立 CI 中运行。

完整边界探针在 [CI 38968843288](https://github.com/verkyyi/claude-fleet/actions/runs/38968843288)
通过：exec 99 项、remote TUI 109 项；允许对照实际写入，三个拒绝阶段均未写入，且当前拒绝原因
到达原生循环。未使用 hook trust bypass，也未关闭非 managed hooks。
更新场景由新启动的后端读取新版 requirements；不是已运行后端的热更新证明。
此前 remote 的额外请求已用 `thread_source=thread_title`、独立线程 ID、无工具及 title-only schema
识别为原生后台标题生成；对应固定版本的实现见
[thread_title.rs](https://github.com/openai/codex/blob/rust-v0.162.1/codex-rs/tui/src/app/thread_title.rs)。
探针对该线程仅返回本地失败、不驱动工具；主线程仍严格要求一次普通请求或两次合成工具请求，
审阅门前要求零请求。所有 hook 记录按原生 session ID 分开，后台 helper 不能覆盖主线程验收。
这不是放宽任意重试计数，也没有关闭原生标题能力来获得绿色。

下一批实现边界：把真正的平台强制守卫交给只读管理层；状态/标题跟随原生根线程事件，不将
所有 Fleet 生命周期钩子一股脑升为全系统强制 hook。上述只是受控 guard fixture，尚未证明
现有 bash/base-readonly 守卫、跨账号安装和更新回滚的实际接线全部通过；在这些条件通过前，
不改变现有启动器或宣称可安全删除全局 bypass。完整 MCP、真实面板与性能指标仍独立验收。

真实守卫补测将仓库内 `hooks/bash-guard.py` 原样复制到临时 managed 目录，并记录源文件
SHA-256。原生工具先在无该守卫的正对照中向 owned 本地 bare Git 仓库推送测试提交；再用
相同命令验证主分支强推被真实 exit-2 守卫拒绝，原生循环收到实际拒绝原因，目标 ref 未创建。
另测调用方 `features.hooks=false` 不能关闭该管理层守卫，以及非主分支推送仍然成功。
所有 Git 仓库均在临时目录，无网络 remote，不操作项目仓库或线上会话。这组断言纳入同一
exec / remote TUI CI；新增断言通过前不能沿用此前 99 / 109 项成绩作为其验收结果。
这仍不涵盖原生 `apply_patch` 的 base-readonly 接线或真实管理层安装、升级与回滚。

下一层补测通过已发布模型元数据提供的原生代码模式调用 `tools.apply_patch`，不伪造
PreToolUse 输入，也不依赖没有暴露给模型的内部工具。真实 `base-readonly-guard.py`
原样放入临时管理层；受保护目录和允许目录均为 owned 临时 Git 仓库/关联工作树。
覆盖无守卫正对照、主目录新增/修改/删除、符号链接别名、移入主目录、含合法与非法目标的
混合补丁、调用方关闭 hooks 的尝试，以及工作树内合法写入。被拒绝时要求文件内容不变、
没有部分落盘、真实拒绝理由返回原生代码模式；独立只读观察 hook 核对原生根线程、cwd
与完整补丁。观察 hook 只记录测试事件，不实现或替代守卫。这组新断言仍须以对应提交的
exec / remote TUI CI 为准，不把之前 Bash 守卫的通过结果当作文件编辑验收。

上述实际文件编辑与 Bash 守卫在提交 `ca7da4c0` 的
[CI 38970582088](https://github.com/verkyyi/claude-fleet/actions/runs/38970582088) 通过：
exec 260 项、remote TUI 283 项，计数包含既有信任和工具阶段，并非这么多个独立用户场景。

管理层配置开始复用 `fleet-hooks-emit.sh --target codex-managed`：从原有 hook 表及 Codex
映射读取已审阅的 `managed_commands`，只生成两类 PreToolUse 守卫，不复制策略、引入
新的常驻程序或自动信任可选插件。原生 CI 改为消费这个实际生成器的输出，手写配置只留在
对照/观察夹具。生成器只写 stdout，尚不安装、更改现有 requirements 或删除启动器 bypass。
操作入口和安装前置条件见 [原生守卫配置](CODEX-RUNTIME.md#managed-guard-configuration-candidate)。

镜像暂存候选复用 `extras/managed-node/image-stage.py`，把预览存在既有
`.release/staged.json` 的 `codex_managed_preview` 字段，不放行额外的未签名旁路文件。
构建和异版本 seed 时生成；同版本重启不重复生成。node-owned 预览绑定最终版本路径，
image-owned 个人 POD 预览绑定镜像种子而非登录用户可写的 PVC。缺守卫、错误登记或写入失败
不得推进 `current`；旧版兼容、重试和镜像回退走既有机制。此字段不是可信授权来源，
更不是系统策略已安装；实际激活必须重新从受信发布物生成并验收权限、既有策略合并、
会话生命周期与版本回收。详见 [镜像更新与恢复](MANAGED-LINUX.md#upgrade-and-recovery)。

### 启动期插件查询减法

旧启动路径连续运行 `sync` 与 `dirs` 两个 Python 进程，各自读取覆盖配置和已安装插件。
候选改为一次 `sync --print-dirs`：同步技能/MCP 后，把同一份已启用插件列表的 hook 目录交给启动器。
机器可读 stdout 只含目录，原有同步诊断移到 stderr；不增加缓存、驻留服务或第二份插件状态。
`sync` 和 `dirs` 旧命令均保留，安装器调用方式不变，原生所有权覆盖仍同时关闭同步与 hook 注入。

`fleet-codex-plugins-selftest.sh` 103 项通过，新增检查无插件不调用 Claude、一次查询、多个目录顺序、
覆盖后无查询，以及查询失败时不污染 stdout、不删除已有技能/MCP。
现有插件列表缓存已避免多数 Claude 进程启动，因此这里只声称删去一个 Python 启动及重复读取，
不将它说成「插件阶段减半」或生产草稿已经达到 1 秒。
临时 HOME 和受限 PATH 下的 launcher 回归 20 项通过；原生插件退桥串联回归 172 项通过。
这些仍是源码/隔离证据，不代替部署后实际面板测量；无在线安装或用户配置变更。

### 默认上下文管理交还 Agent

Worktree 的 local/remote 兼容性尚未解决，但默认上下文干预不依赖该迁移，可独立删除默认触发。
源码候选把 `FLEET_AUTO_HANDOFF_PCT` 与 `FLEET_COMPACT_PREP_PCT` 的未设置值改为 0：
不再默认在 55% 要求模型写恢复图并输入 `/compact`，也不在 80% 要求新建会话。
Codex 本身提供自动压缩阈值，未设置使用模型默认值，见
[官方配置说明](https://learn.chatgpt.com/docs/config-file/config-reference)。本批不写入或修改该原生设置。

- 删除的是 Fleet 默认触发，而非原生压缩、手动交接、跨节点迁移、原生 ID 记录或压缩后任务归属恢复。
- 用户已经设置的正百分比、Token 阈值、全局/每 Fleet 覆盖继续有效，不编辑线上配置，也不抹掉既有策略。
- 明确请求的 transfer 在 Stop 仍能获得 ready 信号；默认关闭不能短路正常状态、休眠证据或父会话报告。
- context 工具、技能和诊断同步说明：默认 50% / 80% 只是用量提示，旧 `WATCH` / `HANDOFF` 枚举为兼容保留，不再命令 Agent 自动交接。
- 默认 Codex Stop 不再为自动交接重复启动 `fleet-codex-session.py context --pct`；常规遥测和身份验证保留。
- 旧自动流程保留为显式启用的兼容功能；本批未发布，不代表用户 POD 或 drill 已切换默认行为。

同时修正 context 读数与 Stop 策略的对应关系：显式 Token 阈值按窗口上的原生 `@ctx_limit`
向上取整、上限 100，覆盖百分比；缺少该窗口大小时与 Stop 一样退回百分比。
否则 Token-only 配置会被新默认值错误显示为 OFF。只读工具不使用猜测的 200k 窗口激活策略。

源码候选验证：`context-ladder-defaults-selftest.sh` 17 项、`fleet-codex-session-selftest.sh` 15 项、
`fleet-mcp-selftest.sh` 35 项、`refocus-hook-selftest.sh` 8 项、当时的认领简报自测 26 项通过（#4898 起换成 `fleet-brief-selftest.sh`）；
`auto-handoff-selftest.sh`、`compact-prep-selftest.sh`、`ctx-token-line-selftest.sh`、
`fleet-context-selftest.sh` 与 `statusline-selftest.sh` 也通过。
默认路径在 55% / 80% / 99% 不启动 Fleet 压缩或交接，旧计数不重新启用它；
测试还覆盖显式配置、token-only、覆盖层、手动 transfer ready 和原生遥测读取不再重复启动。
这些是隔离功能回归，不是线上模型压缩质量或端到端性能验收。

本轮目标是优化 Fleet 与 Agent 的架构边界、消除职责重叠并改善稳定性与性能，
不缩减为 Worktree 可创建、某个局部测试通过或单次延迟达标。

| 能力域 | 已有证据 | 尚缺的完成证据 |
|---|---|---|
| Worktree 与原生运行时 | 真实二进制创建/失败退出/resume/fork 与目录保留；local/remote 冲突已复现 | 受准入保护的实际面板路径替换；唯一创建/清理所有者；正常退出、崩溃和重建恢复 |
| 历史与上下文 | 原生 ID/cwd 记录及 resume/fork 薄适配；默认阈值强制压缩/换会话已在候选移除，显式旧策略与手动交接回归通过 | 全部恢复/迁移入口盘点；部署后真实会话、原生压缩与旧会话连续性验收 |
| MCP 与扩展 | 原生安装、命令转换、技能/hook 发现和 MCP 握手已实测；七个会话变量须显式 env_vars，不能假定 env 插值 | 原生安装所有权切换、去重、信任、账号 home 与真实 MCP 路径/超时；完整工具权限和旧会话不回退 |
| 状态与交互 | private-server 状态/投递接口已验证；候选注意力监测使用原生事件并保留低频只读校验，身份/断线/错误状态回归通过 | 原生运行时迁移后的同等事件；完整面板输入/审批、回合状态与生产资源验收；其他不必要轮询盘点 |
| 模型与审批 | 边界已写明原生设置与平台准入分层 | 各启动/恢复入口配置一致性、既有用户覆盖值及负向权限验收 |
| 任务执行与协作 | 保留跨节点基础设施，编排角色不进入默认路径 | 默认安装与会话启动链路的完整审计；可选能力失败不影响普通会话 |
| 认证与租户隔离 | 已定位固定订阅身份验证依赖 private RPC，未绕过 | 原生运行时下的等价账号/凭据证明、过期刷新、多副本一致性及错误归属拒绝 |
| 托管、发布与性能 | 本批未改在线部署、资源或用户数据 | CI、真实 drill/两副本/重连/重建验收与正常发布；同配置直接原生启动对照及可重复端到端结果 |

任何一行尚缺证据，均不标记总体目标完成。现有无关回归失败独立记录，不通过降低验收范围消除。

### 管理层守卫安装候选：显式操作，不进入启动热路径

复用 `image-stage.py guards-install`，从既有守卫表重新生成配置，仅管理员显式调用；
暂存预览不是授权材料，stage/seed/boot 均不自动安装。检查 root 所有权、不可由其他用户
写入的目录/脚本/解释器，保留无关 requirements，遇到现存 hook 策略冲突拒绝覆盖。
固定到受保护的 `current/hooks`，个人 POD 使用镜像种子，不使用用户可写 PVC。
不添加新策略引擎、常驻服务或会话启动时扫描；不移除全局 bypass，不部署用户节点。

本批本机生命周期单测为 69 项通过，正向安装的 root 身份采用 mock；新增独立 CI
探针在一次性 Linux VM 的私有 mount namespace 内验证真实 root 文件和非 root 原生
读取。后者是否通过以对应 CI 结果为准，不能把单测替代原生验收。更新/回退路径单测
不等于线上发布、重建、旧会话兼容已经验收。具体命令和限制见
[原生守卫配置](CODEX-RUNTIME.md#managed-guard-configuration-candidate)。

## 默认读屏推理退出

（后续：屏幕分类器已随 #2543 整个删掉——`classify-sessions.sh` 及其 backend、
`CLASSIFY_*` 设置都不再存在；`classify-hook.sh` 留作静默退出的壳过了一版，已随
#4798 删掉。下面是 #4551 当时的记录。）

`CLASSIFY_BACKEND` 未设置时改为 `off`。默认不再为 Claude 或 Codex 的安静窗口
挑选 helper 凭据、抓取屏幕、调用另一个模型或写分类缓存/状态。原生状态事件、显式
pending request、已记录的调度与等待、CPU/auth/trust 保护保持原路径。

既有 `haiku` / `jev` / `shadow` 设置仍显式启用旧行为，包括各自的回退与身份竞态保护；
不替用户清空线上配置。旧 Stop hook 与 spinner 调用入口保留兼容周期，默认快速退出，
但仍有短命 shell 调用成本。`--prep-capture` 保留为独立文本转换，不需要凭据或模型。

这批不声称原生状态覆盖了所有自然语言意图：未记录的「等一会儿再做」不再被额外
LLM 猜成循环或待回答；只有有来源的状态进入默认路径。模型推断保留为按需旧功能，
不是新增统一 Agent 状态引擎。本地与 drill 的针对性回归、CI 和实际入口验收分别记录，
不能仅凭默认分支返回 0 宣称保护回归或性能目标通过。

## 验收矩阵

1. **隔离与身份**：独立目录可编辑，主检出与其他用户/会话目录受保护；伪造 `.git`、符号链接、路径逃逸和错误仓库绑定不得获得权限。
2. **数据保留**：正常退出、异常中断和 POD 重建后，未提交文件、未推送提交、原生会话历史及归属不丢失；退出会话不等价于删除工作目录。
3. **原生恢复**：准确 resume/fork，账号 home 一致；旧 Fleet 目录和新原生目录均可识别，不套用不兼容的恢复参数。
4. **真实入口**：终端 Fleet 面板新建 → 原生输入框出现 → 草稿保留且未发送 → 用户明确发送 → 原生完成 → 重连；不能以 `exec` 的一次成功代替。
5. **保护不退化**：CPU/额度/权限拒绝、凭据失效、仓库不可信、Hub 不可用均保持既有语义；两副本与重试幂等性按需要复测。
6. **计时**：区分面板派发、准入、fetch、目录创建/setup、窗口、原生输入框、草稿、显式发送及回复；使用单调时钟并明确远端时间的误差。空窗口不是输入框或草稿完成。
7. **公平对照**：同节点、同资源限制、同仓库提交、同 MCP/模型配置；直接原生启动也要经过等价的运行授权。分别报告首次与重复样本，不用模拟器或本机样本承诺生产延迟。
8. **推广与回退**：先独立工作树测试和 CI，再 drill 的真实面板，最后用户 POD；保留原版本和旧会话数据，出现身份/数据/权限回归立即停止推广。

本阶段不新增机器、不改资源规格、不改订阅权限、不停用 MCP，也不将现有认证代理的分布式职责交给单个 CLI。
