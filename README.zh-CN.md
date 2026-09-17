# claude-fleet

[English](README.md) | **简体中文**

**在一个终端里，指挥多个 Claude Code 会话并行开发。**

claude-fleet 把 **tmux、Claude Code、Git worktree 和 GitHub Issues** 串成一套开发工作流：一个任务对应一个窗口、一份独立工作目录；你在看板里分派任务、查看进度，把注意力放在需要你判断的地方。

例如，让一个会话修复登录问题，另一个补充导出功能的测试，再让一个完善文档。它们各自在自己的分支和工作目录里推进，通过 PR 交付；团队继续用 GitHub Issues 和 PR 留下需求、讨论和变更记录。

这个项目源于在一台常开的 Mac mini 上，同时运行约 7 个 Claude Code 会话的实践。

![claude-fleet 任务看板：集中查看会话状态、Issue、模型和上下文用量](docs/img/dashboard.svg)
![tmux 状态栏：快速识别正在工作、已完成和等待你处理的会话](docs/img/statusbar.svg)

<sub>截图来自真实 tmux 界面，使用演示仓库数据。界面中的部分标签和提示仍为英文。</sub>

[快速上手](#快速上手) · [中文团队工作流](#中文团队工作流) · [常用快捷键](#常用快捷键) · [配置与多仓库](#配置与多仓库) · [更多文档](#更多文档)

## 它能帮你做什么

- **并行推进多个任务。** 每个 worker（执行任务的 AI 会话）使用独立的 Git worktree，也就是同一仓库的一份独立工作目录；不同任务的未提交修改互不混在一起。
- **一眼看出谁需要你。** 青色转动符号表示正在工作，绿色 `✓` 表示一轮对话结束，红色 `!` 和铃声表示等待你处理，靛蓝色表示 `/loop` 正在等待下一轮。窗口按紧急程度排序。
- **从 Issue 直接开工。** 在 backlog（待办面板）选中 GitHub Issue，按回车即可创建 `issue-<编号>` 工作目录并启动 worker。面板支持预览、筛选和优先级调整。
- **集中查看进度。** dashboard（任务看板）展示会话状态、关联 Issue、模型、PR/CI 状态和可用的上下文用量信息。后台采集器维护缓存，看板读取缓存展示。
- **随时开一个探索会话。** 不确定需求时，先用 scratch（临时会话）讨论、实验；明确后可将同一会话绑定到 Issue，保留已有上下文继续实现。
- **管理收尾和长期运行。** worker 通过 PR 交付；后台清理符合条件的已结束任务。Claude Code 会话可通过 `/fleet-handoff` 保存交接信息，跨上下文窗口继续工作。

![GitHub 待办面板：按里程碑组织 Issue，并显示正在处理的任务](docs/img/backlog.svg)

## 快速上手

### 1. 准备环境

支持 macOS 和 Linux，分别使用 launchd 和 systemd 用户服务运行后台组件。先确认本机的 `claude` 能正常对话，并能访问团队使用的 GitHub 仓库。

| 依赖 | 用途 |
|---|---|
| Git | 分支、worktree 和代码交付 |
| tmux ≥ 3.2 | 承载多个会话、窗口和状态栏 |
| [fzf](https://github.com/junegunn/fzf) ≥ 0.45 | 交互式看板和弹窗 |
| [GitHub CLI（gh）](https://cli.github.com/)，已登录 | 读取和管理 Issues、PR、CI 状态 |
| Python 3 | 部分脚本和 hooks |
| [Claude Code](https://claude.com/claude-code)（`claude` 命令） | 执行开发任务，也用于辅助安装 |

可用 `gh auth status` 检查 GitHub 登录状态；未登录时先运行 `gh auth login`。核心功能不要求单独安装 `jq`；可选的 Claude Code 状态行需要它。Perl 的 `Time::HiRes` 也是可选依赖，用于更平滑的转动动画。

### 2. 让 Claude 按安装手册完成安装

```sh
git clone https://github.com/verkyyi/claude-fleet.git
cd claude-fleet
claude "请按照 docs/INSTALL.md 在这台机器上安装 claude-fleet，并用中文说明配置和验证结果。"
```

安装流程以 [docs/INSTALL.md](docs/INSTALL.md) 为准。Claude 会检查依赖，配置 `~/.claude/fleet/`、tmux、Claude Code hooks 和后台服务，并在修改前说明涉及的文件。准备好你的业务仓库名（如 `your-org/your-repo`）、本地路径和主分支信息。

安装后运行诊断，检查依赖、服务和安装版本：

```sh
sh ~/.claude/fleet/bin/fleet-doctor.sh
```

手动安装和卸载也见同一份[安装手册](docs/INSTALL.md)。手册目前是英文，可以让 Claude 用中文带你完成。

### 3. 为你的业务仓库启动 fleet

将下面的 `your-org/your-repo` 替换为团队实际使用的 GitHub 仓库：

```sh
~/.claude/fleet/bin/fleet-up.sh your-org/your-repo
```

它会在 `~/projects/your-repo` 克隆或复用匹配的仓库，创建并进入名为 `fleet-your-repo` 的 fleet。也可以在命令末尾加上已有仓库的路径。主分支优先从 GitHub 的默认分支读取。

一个 **fleet 对应一个 GitHub 仓库、一个 tmux session，以及一个独立的 tmux socket**。进入后看到的 `plan` 是承载看板的 hub（控制中心）；从这里打开任务会话。

安装好 `shell/cw.zsh` 中的快捷函数后，日常用 `cf` 返回已有 fleet：只有一个就直接进入，有多个则显示选择器。没有运行中的 fleet 时，它才会根据当前目录的仓库启动一个。

## 中文团队工作流

### 用中文写清楚任务和验收条件

在团队仓库创建 GitHub Issue，把背景、范围和验收条件写清楚。可以直接使用这样的中文描述：

```markdown
标题：修复订单列表切换筛选条件后页码未重置的问题

背景：
用户在第 3 页切换订单状态后，仍停留在第 3 页，可能看到空列表。

期望行为：
切换订单状态时回到第 1 页；刷新页面后保留当前筛选条件。

范围：
只调整订单列表页面，沿用现有接口和组件。

验收条件：
- 切换状态后，请求使用第 1 页。
- 普通翻页不受影响。
- 补充相关回归测试，并运行项目规定的检查。

沟通：
请使用简体中文说明进度、问题和 PR 内容，代码标识符遵循项目现有风格。
```

建议先用 2–3 个边界清楚、依赖较少的任务试跑。涉及同一接口或核心模块的修改，先约定依赖和合并顺序；worktree 隔离工作目录，最终合并仍可能有冲突。

### 从待办面板启动 worker

按 `prefix b` 打开 backlog，选中 Issue 后按 `Enter`。fleet 会创建独立 worktree、绑定并认领 Issue，再启动 worker 阅读需求并实现。

这里的 `prefix` 是你的 tmux 前缀键；没有改过时通常是 `Ctrl-b`。例如 `prefix b` 表示先按 `Ctrl-b`，松开后再按 `b`。

在 backlog 中，`Space` 展开 Issue 预览，`/` 开始筛选，`Ctrl-N` 快速创建一行 Issue。复杂任务适合先补全 Issue 正文，再交给 worker。

### 在看板里处理需要你判断的事

按 `prefix g` 回到看板，选中会话后按 `Enter` 进入。`prefix a` 跳到最需要你关注的窗口。

| 状态 | 含义 | 你可以做什么 |
|---|---|---|
| 青色转动符号 | 正在工作 | 继续查看其他任务 |
| 红色 `!` / 红色 `● N` | 有会话等待你处理 | 进入会话回答问题或处理阻塞 |
| 绿色 `✓` | 一轮对话结束 | 查看结果；是否完成交付以 PR/CI 为准 |
| 靛蓝色 | `/loop` 等待下一轮 | 按需查看循环任务 |
| 橙色 `● N` | 其他 fleet 有会话需要你 | 点击跳转；多个 fleet 等待时会显示选择器 |

### 通过 PR 交付

worker 的默认流程是：认领 Issue → 实现 → 验证 → 提交 PR → 检查通过后自行合并。主 checkout 受只读保护，代码修改发生在任务的 worktree 中；合并后的清理由后台组件处理。

**团队需要人工评审时，请在 GitHub 仓库设置必需评审和分支保护，并把交付要求写进项目约定。** 默认 worker 流程包含合并步骤，应与团队已有的 PR 规则配合使用。

### 需求还不明确时，先开 scratch

在看板底部输入一个名字，例如 `讨论订单导出`，然后按 `Enter`，会创建同名的空白 scratch 会话。名字支持中文和空格，最多显示 24 列，约 12 个常见汉字。进入会话后，再输入要讨论的需求。

**看板输入框中的文字是会话名，不会作为第一条提示词发送。** `Ctrl-S` 也可创建使用自动编号的 scratch。它同样拥有独立、可写的 worktree。

需求明确后，在这个 scratch 会话中让 agent 执行以下命令，即可创建 Issue 并原地转为 worker；请把标题和正文换成讨论确认的内容：

```sh
~/.claude/fleet/bin/fleet-issue-file.sh \
  --title "支持按筛选条件导出订单" \
  --body "在这里写入已确认的需求、范围和验收条件。" \
  --bind
```

已有 Issue 则用 `~/.claude/fleet/bin/fleet-bind.sh <Issue编号>` 绑定。这样可以沿用讨论时的上下文。

### 让中文沟通贯穿整个任务

无需额外开启中文开关：worker 的启动规则会要求它**使用 Issue 的语言回复**。会话恢复、自动交接和配额通知等自动化消息也带有保持原会话语言的指令，交接文档会记录语言。实现见 [bin/fleet-lang.sh](bin/fleet-lang.sh)。

中文团队可以用中文撰写 Issue、验收条件和评审意见，并在项目的 `CLAUDE.md` 中约定反馈和 PR 描述的语言；使用 Codex 时，对应的项目说明文件是 `AGENTS.md`。命令、配置键、代码标识符和标签名保留原文，方便直接操作和检索。例如优先级标签仍使用 `priority:p0`、`priority:p1`、`priority:p2`。

这里的中文支持包括文档、中文任务和会话语言保持；**看板、配置菜单及部分系统提示尚未全部汉化**。

### 多人、多机器如何协作

团队可以由一位操作者在常开的开发机上管理 fleet，也可以各自在自己的机器上运行 fleet，通过同一个 GitHub 仓库的 Issues 和 PR 共享进度。

启动 worker 时，fleet 默认会检查 Issue 的认领状态、认领评论和已有 PR，尽量避免另一台机器重复开工。这是尽力去重机制，并非分布式锁；同一任务仍应明确交给一个负责人或 worker。每台机器分别维护自己的安装和配置。

## 常用快捷键

| 位置 | 按键 | 用途 |
|---|---|---|
| tmux | `prefix a` | 跳到最需要你处理的窗口 |
| tmux | `prefix g` | 聚焦看板，再按一次切换全屏 |
| tmux | `prefix b` | 打开 GitHub 待办面板 |
| tmux | `prefix c` | 打开配置面板 |
| tmux | `prefix ?` | 查看完整快捷键说明 |
| 任意窗口 | `F9` | 返回 hub 的看板，并切换缩放 |
| 看板 | `Enter` | 输入框为空时进入选中会话；有文字时以它为名新建 scratch |
| 看板 | `Ctrl-N` | 创建 Issue 并启动关联 worker |
| 看板 | `Ctrl-S` | 新建自动命名的 scratch |
| 看板 | `Ctrl-V` | 切换此 fleet 新会话默认使用的 agent |
| 待办面板 | `Enter` / `Space` | 启动 Issue 任务 / 切换预览 |
| 待办面板 | `Ctrl-Y` | 循环调整优先级：无 → p2 → p1 → p0 |
| 看板或待办面板 | `?` | 查看快捷键说明 |

看板中的 `Ctrl-` 快捷键如果与个人 tmux 前缀冲突，会切换到对应的 `Alt-` 组合，以 `?` 显示的实际按键为准。

默认开启鼠标支持：点击底部 `⌂` 返回控制中心，点击 fleet 名切换仓库，点击用量数字查看用量和账号。窗口编号可能变化，按名字识别任务更可靠。

## 配置与多仓库

全局配置位于 `~/.claude/fleet/fleet.conf`，完整选项见 [fleet.conf.example](fleet.conf.example)。常用配置示例：

```sh
FLEET_REPO="your-org/your-repo"       # Issues 和 PR 所在仓库
FLEET_MAIN="$HOME/projects/your-repo" # 主 checkout，worktree 创建在它旁边
FLEET_BASE_BRANCH="main"             # 按仓库实际主分支填写
FLEET_GLOBAL_MAX_SESSIONS=8           # 本机并发会话总上限；试跑时可调小
FLEET_AGENT="claude"                 # 新会话默认使用的 agent
```

每个 fleet 的独立配置位于 `~/.config/claude-fleet/fleets/<session>/conf`，覆盖全局同名设置。日常可以通过 `prefix c` 修改，并注意当前编辑的是全局层还是当前 fleet。

一台机器可以同时运行多个仓库，各有自己的 fleet 和 tmux socket，后台采集服务共用。比如为第二个仓库启动 fleet：

```sh
~/.claude/fleet/bin/fleet-up.sh your-org/infra "$HOME/projects/infra"
```

查看所有 fleet：

```sh
~/.claude/fleet/bin/fleet-list.sh
```

需要从普通终端直接连接某一个 fleet 时，socket 和 session 都要使用列表中的实际名称，例如：

```sh
tmux -L fleet-infra attach -t fleet-infra
```

## 进阶功能

### Claude Code 插件与更新

slash commands、基础 skills 和 hooks 也可以通过本仓库提供的 Claude Code 插件安装：

```sh
claude plugin marketplace add verkyyi/claude-fleet
claude plugin install fleet@claude-fleet --scope user --yes
```

插件命令带命名空间，如 `/fleet:fleet-claim`；传统安装对应 `/fleet-claim`。fleet 会识别安装方式。**插件负责 Claude Code 侧的组件；tmux、脚本和后台服务仍需要按安装手册配置。**

插件可用 `/plugin update fleet` 更新。机器级安装通过 `/fleet-sync-install` 同步（插件安装时为 `/fleet:fleet-sync-install`，要求 `~/.claude/fleet` 是 Git checkout）；团队每台机器都要分别更新，用 `fleet-doctor.sh` 检查是否落后。

### 常用 Claude Code 命令

以下使用传统安装的命令名；插件安装时加上 `fleet:` 命名空间。

| 命令 | 用途 |
|---|---|
| `/fleet-claim` | worker 的完整任务流程，新启动的 worker 会运行它 |
| `/fleet-context` | 查看当前上下文占用及是否需要交接 |
| `/fleet-handoff` | 保存交接信息，清理上下文后继续任务 |
| `/fleet-history` | 在 hub 侧查看、恢复历史会话 |
| `/fleet-sync-install` | 将已合并的 claude-fleet 更新应用到本机安装 |

每个命令都有适用角色（worker、hub 或两者），详见 [commands/README.md](commands/README.md)。

### 可选能力

- **多账号与配额管理。** 支持为新启动的 Claude Code 会话选择账号、在触及额度后切换后续会话使用的账号。已经运行的会话不能直接热切换账号；用量统计中有本地估算值，不能当作官方账单。配置和边界见 [多账号说明](docs/MULTI-ACCOUNT.md)。
- **SSH 远程使用。** 可以从笔记本连接常开的开发机。项目的 URL 打开工具支持通过 SSH 隧道在本地浏览器打开链接，也有弹窗和剪贴板回退方式，见 [SSH 链接设置](README.md#opening-links-over-ssh)。
- **Codex worker。** 可通过看板 `Ctrl-V` 或 `FLEET_AGENT=codex` 选择 Codex。工作目录隔离、Issue 绑定和 PR/CI 管理共用，但 Claude Code 的上下文交接、会话恢复和配额管理尚未适配到 Codex。完整能力表由代码生成并检查，见 [Claude Code 与 Codex 对照](README.md#agents-claude-code-and-codex)。

## 使用边界

- 一个 fleet 对应一个 GitHub 仓库；多仓库请分别启动 fleet。当前待办和 PR 集成使用 GitHub。
- 独立 worktree 和 tmux socket 提供工作目录与服务层面的隔离，worker 仍会在本机执行命令。团队的项目权限、评审和部署约定需要照常配置。
- 部分状态信号可能有延迟，例如 Claude Code 的问题通知可能等待约一分钟。可选的 LLM 状态分类器会消耗 tokens，关闭它不影响其余核心功能。
- `plan`、`dash`、`backlog` 是面板窗口的保留名称；hub 当前只承载看板，没有常驻的指挥 agent。

## 更多文档

下列详细参考目前主要为英文；中文入口覆盖首次使用和团队工作流，具体机制可继续查阅：

| 文档 | 内容 |
|---|---|
| [安装与卸载](docs/INSTALL.md) | 完整安装流程、组件、后台服务和卸载 |
| [术语表](docs/TERMS.md) | fleet、hub、worker、collector 等概念 |
| [架构说明](docs/ARCHITECTURE.md) | 组件关系、多 fleet 与缓存隔离 |
| [状态机制](docs/STATE.md) | 会话状态如何产生、展示和纠正 |
| [任务清理](docs/CLEANUP.md) | PR 结束后的窗口和 worktree 生命周期 |
| [Issue 消息桥](docs/ISSUE-BRIDGE.md) | Issue 评论与运行中 worker 的消息传递 |
| [事件输出](docs/EMIT.md) | 可选的会话生命周期事件输出及数据范围 |
| [贡献指南](CONTRIBUTING.md) | Shell 脚本约定与检查要求 |

欢迎改进中文说明、补充团队实践。更新命令或功能时，请同步核对中英文 README。

## 许可证

MIT
