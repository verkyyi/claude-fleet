# claude-fleet

[English](README.md) | **简体中文**

**设计蓝图：**[Fleet 产品方向与设计原则](docs/dev/PRODUCT-DIRECTION.md)是后续产品设计的依据。下文介绍当前实现。

**共享团队的 AI 订阅，让会话在云端跑。**

claude-fleet 只做两件事：**订阅共享**——一个小团队的 Claude、ChatGPT/Codex 订阅合成一个池子，按余量计量和分配；**云端 Runtime**——Claude Code 和 Codex CLI 的会话跑在托管机器上，一件任务一个会话、一份独立的 Git worktree，合上笔记本也照常干活。你从终端（`fleet`）、手机或网页控制台接进来。

**任务是 hub 上的一条记录 `T<n>`，归人，不归仓库。** 你说要做什么（⌘P 面板的 ⚡ 行、网页控制台，或在别的会话里用 `task` 工具），入口先记下这条记录，再开出做这件事的会话。指定了仓库的任务在该仓库的 worktree 里改代码、提交 PR——**GitHub 只托管代码和 PR**；不认领、不评论、不关闭 GitHub issue。不绑仓库的任务（做页面、写文档、对话）完全不需要 GitHub。

核心工作流使用 CLI 的**订阅登录，无需另配模型 API Key**。多个订阅放进 hub 的池子，由凭据代理按请求替会话挑（Claude 与 Codex 一样）。详见[能力表](README.md#agents-claude-code-and-codex)。

项目来自一台常开 Mac mini 上的持续开发实践。本机 Transcript 核算记录到：**历史峰值 25 个 Claude 主 Session，在 25 份独立任务目录中并行处理任务**（2026 年 9 月 1 日）；另一次记录中，至少 **15 个任务连续并行约 14.46 分钟**。统计的是 CLI 处理轮次重叠，详见[实证数据与统计口径](docs/dev/USAGE-EVIDENCE.md#中文说明)。

**只想用、不想部署？** 使用说明在 [`docs/public/zh/`](docs/public/zh/index.md)：成员、管理员、自托管各有入口。

[快速上手](#快速上手) · [小团队并行工作流](#小团队并行工作流) · [实证数据](docs/dev/USAGE-EVIDENCE.md#中文说明) · [常用快捷键](#常用快捷键) · [配置与多仓库](#配置与多仓库) · [订阅与额度](#订阅账号池与额度管理) · [更多文档](#更多文档)

## 它能帮你做什么

- **并行推进多个任务。** 每件任务一个会话；指定了仓库的，再给它一份独立的 Git worktree（同一仓库的一份独立工作目录），不同任务的未提交修改互不混在一起。
- **一眼看出谁需要你。** 青色转动符号表示正在工作，绿色 `✓` 表示一轮对话结束，红色 `!` 和铃声表示等待你处理，靛蓝色表示 `/loop` 正在等待下一轮。任务列表把需要你的会话排在前面。
- **在哪都能接着看。** `fleet` 打开看台：右边是当前会话，旁边是任务列表，⌘P 面板里切换会话、派任务、回答问题、开 shell。别的机器上的会话也在同一个列表里；手机和网页控制台看到的是同一套。
- **一个订阅池。** hub 的订阅放在凭据代理后面，按请求挑，订阅满了不会让会话停下；每个会话自己的剩余 % 就在它的窗口上。接入 TokenLedger（`ccquota`）后还可以在额度见顶时暂停入口远程开会话。详见[订阅与额度管理](#订阅账号池与额度管理)。
- **管理收尾和长期运行。** 会话通过 PR 交付，门禁全绿后自己合并、在任务记录上回报；后台清理合并后的窗口和 worktree。Claude Code 会话可通过 `/fleet-handoff` 保存交接信息，跨上下文窗口继续工作。

## 快速上手

### 1. 准备环境

支持 macOS 和 Linux，分别使用 launchd 和 systemd 用户服务运行后台组件。先确认本机的 `claude` 能正常对话。

| 依赖 | 用途 |
|---|---|
| Git | 分支、worktree 和代码交付 |
| tmux ≥ 3.2 | 承载多个会话、窗口和状态栏 |
| [fzf](https://github.com/junegunn/fzf) ≥ 0.59 | 弹窗里的选择器 |
| [GitHub CLI（gh）](https://cli.github.com/)，已登录 | 只有放在 GitHub 上的仓库才要：推代码、开 PR、看 CI、合并 |
| Python 3 | 部分脚本和 hooks |
| [Claude Code](https://claude.com/claude-code)（`claude` 命令） | 执行开发任务，也用于辅助安装 |

仓库在 GitHub 上时，可用 `gh auth status` 检查 GitHub 登录状态，未登录时先运行 `gh auth login`；仓库在别处（其他代码托管、ssh 上的裸仓库、本机文件夹）就不需要 `gh`——fleet 自己并主干。核心功能不要求单独安装 `jq`；可选的 Claude Code 状态行需要它。Perl 的 `Time::HiRes` 也是可选依赖，用于更平滑的转动动画。

### 2. 让 Claude 按安装手册完成安装

```sh
git clone https://github.com/verkyyi/claude-fleet.git
cd claude-fleet
claude "请按照 docs/dev/INSTALL.md 在这台机器上安装 claude-fleet，并用中文说明配置和验证结果。"
```

安装流程以 [docs/dev/INSTALL.md](docs/dev/INSTALL.md) 为准。Claude 会检查依赖，配置 `~/.claude/fleet/`、tmux、Claude Code hooks 和后台服务，并在修改前说明涉及的文件。准备好你的业务仓库名（如 `your-org/your-repo`）、本地路径和主分支信息。只想在一台电脑上试用，也可以照 [自托管 · 快速开始](docs/public/zh/self-host/quickstart.md) 用一行命令装。

安装后运行诊断，检查依赖、服务和安装版本：

```sh
sh ~/.claude/fleet/bin/fleet-doctor.sh
```

手动安装和卸载也见同一份[安装手册](docs/dev/INSTALL.md)。手册目前是英文，可以让 Claude 用中文带你完成。

### 3. 为你的业务仓库启动 fleet

将下面的 `your-org/your-repo` 替换为团队实际使用的仓库：

```sh
~/.claude/fleet/bin/fleet-up.sh your-org/your-repo
```

它会在 `~/projects/your-repo` 克隆或复用匹配的仓库，把它登记进这个登录唯一的 fleet。也可以在命令末尾加上已有仓库的路径。主分支优先从 GitHub 的默认分支读取。

**一个登录一个 fleet**：一个 tmux session、一个独立的 tmux socket，这个登录用到的所有仓库都在里面（`fleet-repo.sh add` 再加）。之后每天用 `fleet` 进来。

<a id="中文团队工作流"></a>

## 小团队并行工作流

### 拆成可以独立交付的任务

例如同时推进登录修复、订单导出测试和部署文档：各派一件任务，各自一个会话，在任务列表里看进度。需要改同一接口时，先明确依赖和合并顺序；并行数量由任务可拆分程度、机器资源、订阅余量和团队评审能力共同决定。

### 写清楚任务和验收条件

派任务时把背景、范围和验收条件写进任务的原话里——这段话就是任务记录的正文，会话第一轮读到的就是它。可以直接这样写：

```markdown
修复订单列表切换筛选条件后页码未重置的问题

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
```

建议先用 2–3 个边界清楚、依赖较少的任务试跑。涉及同一接口或核心模块的修改，先约定依赖和合并顺序；worktree 隔离工作目录，最终合并仍可能有冲突。

### 派任务

按 ⌘P（手机或别的终端：`⌃] p`）打开面板，选「⚡ 新会话」，写下任务、选仓库和 Agent。入口先写下任务记录 `T<n>`，再在合适的机器上开出会话。会话之间也能互相派：在会话里用 `task` 工具，结果回报给派它的那个会话。

### 在面板里处理需要你判断的事

面板按「你该做什么」分组：等你的在最上面，选中那一行就看到它在问什么，`Tab` →「回答…」不用切过去就能答。

| 状态 | 含义 | 你可以做什么 |
|---|---|---|
| 青色转动符号 | 正在工作 | 继续查看其他任务 |
| 红色 `!` | 有会话等待你处理 | 回答问题或处理阻塞 |
| 绿色 `✓` | 一轮对话结束 | 查看结果；是否完成交付以 PR/CI 和任务记录为准 |
| 靛蓝色 | `/loop` 等待下一轮 | 按需查看循环任务 |

### 通过 PR 交付

会话的默认流程是：读任务记录 → 实现 → 验证 → 提交 PR → 门禁全绿后自行合并 → 在任务记录上回报。主 checkout 受只读保护，代码修改发生在任务的 worktree 中；合并后的清理由后台组件处理。

**团队需要人工评审时，请在 GitHub 仓库设置必需评审和分支保护，并把交付要求写进项目约定。** 默认流程包含合并步骤，应与团队已有的 PR 规则配合使用。

### GitHub 不通的时候

任务、会话、订阅和看台都走入口，不受影响；只有推代码、开 PR、看 CI 和合并在等，通了以后会自己接上。详见 [故障排查 · GitHub 连不上的时候](docs/public/zh/troubleshooting.md#github-连不上的时候)。

### 让中文沟通贯穿整个任务

无需额外开启中文开关：会话的启动规则会要求它**使用任务原话的语言回复**。会话恢复、自动交接和配额通知等自动化消息也带有保持原会话语言的指令，交接文档会记录语言。实现见 [bin/fleet-lang.sh](bin/fleet-lang.sh)。

中文团队可以用中文写任务、验收条件和评审意见，并在项目的 `CLAUDE.md` 中约定反馈和 PR 描述的语言；使用 Codex 时，对应的项目说明文件是 `AGENTS.md`。命令、配置键和代码标识符保留原文，方便直接操作和检索。

### 多人、多机器如何协作

任务归人：每个人的任务记录在入口上，会话开在入口分给他的机器上；别的机器上的会话出现在同一个列表里。同一个仓库的代码和 PR 在 GitHub 上汇合。

## 常用快捷键

| 在哪 | 按键 | 用途 |
|---|---|---|
| Mac 上的 iTerm2 | `⌘P` | 打开面板：切换会话、派任务、回答、开 shell、退出 |
| 手机或别的终端 | `⌃] p` | 同上 |
| 面板 | `↵` | 切到选中的会话 |
| 面板 | `Tab` | 选中行的操作（回答、改名、回收、开 shell…） |
| 面板 | `?` | 图例 |

完整的键和自定义见 [日常使用](docs/public/zh/member/usage.md) 和 [客户端说明](docs/dev/CLIENT.md)。

## 配置与多仓库

全局配置位于 `~/.claude/fleet/fleet.conf`，常用项见 [fleet.conf.example](fleet.conf.example)，全部选项与默认值见 [conf/fleet.conf.reference](conf/fleet.conf.reference)。常用配置示例：

```sh
FLEET_REPO="your-org/your-repo"       # 第一个仓库：代码和 PR 所在
FLEET_MAIN="$HOME/projects/your-repo" # 主 checkout，worktree 创建在它旁边
FLEET_BASE_BRANCH="main"             # 按仓库实际主分支填写
FLEET_GLOBAL_MAX_SESSIONS=8           # 本机并发会话总上限；试跑时可调小
FLEET_AGENT="claude"                 # 新会话默认使用的 agent
```

每个仓库的配置在 `~/.config/claude-fleet/fleets/<session>/repos/<slug>.conf`，覆盖全局同名设置。再加一个仓库：

```sh
~/.claude/fleet/bin/fleet-repo.sh add your-org/infra "$HOME/projects/infra"
~/.claude/fleet/bin/fleet-repo.sh list
```

所有仓库在同一个 fleet、同一个任务列表里，按仓库分组。一台机器上要再跑一个互相隔离的 fleet，就用另一个登录。

## 订阅账号池与额度管理

会话不自己挑订阅。开着凭据代理时，每个会话启动时从这个登录的代理拿一张会话凭据，由**池子**（hub 上的订阅）按请求挑用哪个；订阅满了由池子换，会话原地接着跑。没有池子时，会话用这个登录自己登着的账号，和以前一样。Claude Code 和 Codex 都是这样。

```sh
fleet account add --provider claude --label work    # 登录一个订阅，交给 hub
~/.claude/fleet/bin/fleet-account.sh whoami         # 当前会话实际用的订阅
sh ~/.claude/fleet/bin/fleet-doctor.sh              # 看 credproxy / credsep / modelcap 几行
```

每个会话自己的剩余 % 就在它的窗口上（客户端顶行）。单个模型到了上限不等于订阅到顶：状态对账任务会在会话自己的输入框里用 `/model` 原地换到 `FLEET_MODEL_FALLBACK`（默认 `opus`），换不成功才重启 + 恢复。

**远程开会话的额度闸门**是另一回事，默认关闭：

```sh
# 写在 fleet.conf；选择闸门判断哪个订阅。
FLEET_QUOTA_GATE=1
FLEET_QUOTA_CEILING=90
# FLEET_QUOTA_ACCOUNT="<订阅uuid>"  # 也可填 "all"；未设置时采用 ccquota 的默认账号
```

它只管 hub 发来的开会话和恢复。没有 ccquota、hub 不通或读不到额度时闸门放行，不是硬性的花费上限。详见[订阅文档](docs/dev/MULTI-ACCOUNT.md)。

## 进阶功能

### Claude Code 插件与更新

slash commands、基础 skills 和 hooks 也可以通过本仓库提供的 Claude Code 插件安装：

```sh
claude plugin marketplace add verkyyi/claude-fleet
claude plugin install fleet@claude-fleet --scope user --yes
```

插件命令带命名空间，如 `/fleet:fleet-history`；传统安装对应 `/fleet-history`。fleet 会识别安装方式。**插件负责 Claude Code 侧的组件；tmux、脚本和后台服务仍需要按安装手册配置。**

插件可用 `/plugin update fleet` 更新。机器级安装通过 `/fleet-sync-install` 同步（插件安装时为 `/fleet:fleet-sync-install`，要求 `~/.claude/fleet` 是 Git checkout）；团队每台机器都要分别更新，用 `fleet-doctor.sh` 检查是否落后。

### 常用 Claude Code 命令

以下使用传统安装的命令名；插件安装时加上 `fleet:` 命名空间。

| 命令 | 用途 |
|---|---|
| `/fleet-context` | 查看当前上下文占用及是否需要交接 |
| `/fleet-handoff` | 保存交接信息，清理上下文后继续任务 |
| `/fleet-history` | 查看、恢复历史会话 |
| `/fleet-sync-install` | 将已合并的 claude-fleet 更新应用到本机安装 |

每个命令都有适用角色（worker、hub 或两者），详见 [commands/README.md](commands/README.md)。

### 可选能力

- **统一 MCP 管理多台机器。** 可选的 [Fleet Hub](docs/dev/FLEET-HUB.md) 集中注册 MINI 等 SSH 主机，让授权 Agent 查询 Fleet、启动 worker、按跨 handoff / 账号迁移仍稳定的 worker 身份给它发消息、优雅停止与恢复、修改指定配置，并跟踪操作结果。支持本机 stdio、OAuth HTTP，以及通过私有 HTTPS 使用授权令牌的常驻服务。
- **SSH 远程使用。** 可以从笔记本连接常开的开发机。项目的 URL 打开工具支持通过 SSH 隧道在本地浏览器打开链接，也有弹窗和剪贴板回退方式，见 [SSH 链接设置](README.md#opening-links-over-ssh)。
- **Codex worker。** 派任务时选 Codex，或用 `FLEET_AGENT=codex` 设为默认。工作目录隔离、任务绑定和 PR/CI 管理共用；完整能力表见 [Claude Code 与 Codex 对照](README.md#agents-claude-code-and-codex)。

## 使用边界

- 一个登录一个 fleet，装着这个登录的所有仓库；任务记录在入口上，代码和 PR 在 GitHub（或别的 git 地址）上。
- 独立 worktree 和 tmux socket 提供工作目录与服务层面的隔离，会话仍会在所在机器上执行命令。团队的项目权限、评审和部署约定需要照常配置。
- 部分状态信号可能有延迟，例如 Claude Code 的问题通知可能等待约一分钟。
- `home`、`dash`、`plan`、`backlog` 是面板窗口的保留名称；没有常驻的指挥 agent，编排会话由人按需开（`spawn agent:orchestrator`）。

## 更多文档

下列详细参考目前主要为英文；中文入口覆盖首次使用和团队工作流，具体机制可继续查阅：

| 文档 | 内容 |
|---|---|
| [安装与卸载](docs/dev/INSTALL.md) | 完整安装流程、组件、后台服务和卸载 |
| [术语表](docs/dev/TERMS.md) | fleet、hub、任务记录、worker、collector 等概念 |
| [架构说明](docs/dev/ARCHITECTURE.md) | 组件关系、多 fleet 与缓存隔离 |
| [Fleet Hub](docs/dev/FLEET-HUB.md) | 跨机器 MCP 入口、机器注册、授权与操作记录 |
| [状态机制](docs/dev/STATE.md) | 会话状态如何产生、展示和纠正 |
| [订阅与额度](docs/dev/MULTI-ACCOUNT.md) | 池子替会话挑订阅、模型上限、额度闸门与排错 |
| [任务清理](docs/dev/CLEANUP.md) | PR 结束后的窗口和 worktree 生命周期 |
| [事件输出](docs/dev/EMIT.md) | 可选的会话生命周期事件输出及数据范围 |
| [贡献指南](CONTRIBUTING.md) | Shell 脚本约定与检查要求 |

欢迎改进中文说明、补充团队实践。更新命令或功能时，请同步核对中英文 README。

## 许可证

MIT
