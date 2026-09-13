# teamcli 调研

> 调研日期：2026-09-12 · 全部结论基于一手资料（GitHub 仓库本体、README、`docs/designs/*`、源码、GitHub API、npm registry）。二手来源已单独标注。

## 结论（5 行）

1. **叫 `teamcli` 的腾讯开源项目不存在。** 在 `Tencent` / `TencentCloud` / `Tencent-Hunyuan` / `TencentBlueKing` / `TencentOpen` / `tencent-connect` 六个 org 下搜索 `teamcli`，命中数全部为 0（`gh api search/repositories?q=org:<org>+teamcli`）。
2. 用户实际指的几乎可以确定是 **[`Tencent/teamai-cli`](https://github.com/Tencent/teamai-cli)** —— TeamAI，slogan「Make Every Team AI Native」，MIT，TypeScript，⭐4274。名字被记混成了 "teamcli"。
3. 它**不是**「团队 agent 统一 repo」意义上的 *运行时编排器*，而是一套 **Git 原生的「团队 AI 配置 + 知识」分发层**：把 Skills / Rules / Docs / Hooks / MCP / env 放进一个 git 仓库，`push → MR → review 合并 → SessionStart hook 自动 pull` 下发到每个人本地的 30+ 种 agent CLI。
4. 「团队」= **多个人共享同一套 agent 配置与知识库**；**不包含**任务分发、backlog、谁在做什么的跨人可见性、并发 agent 编排 —— 这些在源码里完全搜不到。与 claude-fleet 基本**正交**，不是竞品。
5. 值得借鉴：双 anchor（worktree 感知）的数据分区模型、原子锁配方、friction 评分的 Stop hook、迁移时「先落 .gitignore 再 rename」的凭据保护、单份 mcp.yaml 翻译成各工具原生格式。claude-fleet 在编排、配额、隔离上远胜于它。

---

## 一、`teamcli` —— 死胡同，明确不存在

逐 org 验证（`gh api`，`total_count`）：

| org | `teamcli` 命中 |
|---|---|
| `Tencent` | 0 |
| `TencentCloud` | 0 |
| `Tencent-Hunyuan` | 0 |
| `TencentBlueKing` | 0 |
| `TencentOpen` | 0 |
| `tencent-connect` | 0 |

全网 `gh search repos teamcli --limit 30` 的结果全是无关个人项目（`TeamClips`、`teamclicker`、`Inkagnedo/teamCLI` 等，star 数 0–3），没有任何一个属于腾讯或与 coding agent 相关。

**结论：报告其余部分讨论的是 `Tencent/teamai-cli`。**

---

## 二、`Tencent/teamai-cli`（TeamAI）—— 真身

### 2.1 Identity

| 项 | 值 | 来源 |
|---|---|---|
| 仓库 | [`Tencent/teamai-cli`](https://github.com/Tencent/teamai-cli) | `gh repo view` |
| 描述 | `Make Every Team AI Native` | 同上 |
| License | **MIT**（`LICENSE` 头部写明 "Tencent is pleased to support the open source community by making teamai-cli available… licensed under MIT"；GitHub API 因文件含腾讯前言而识别为 `other`） | [LICENSE](https://github.com/Tencent/teamai-cli/blob/main/LICENSE) |
| Stars / Forks | **4274 / 283** | `gh repo view`（2026-09-12） |
| 语言 | TypeScript（4.88 MB），少量 Python / JS | `gh repo view --json languages` |
| GitHub 仓库创建 | 2026-04-27 | `createdAt` |
| **首个 commit** | **2026-03-03** —— `Initial release: tad v0.1.0`，次日即 `Rename tad → teamai` | `git log --reverse` |
| 最后 commit | **2026-09-12**（调研当天） | `git log -1` |
| commit 总数 | **745** | `git rev-list --count HEAD` |
| 主要作者 | `jeffyxu@tencent.com` —— 555/745 commits（两个 identity 合计），其余为社区与腾讯同事 | `git shortlog -sne` |
| 发版节奏 | latest `v0.23.1`（2026-09-09），已到 `v0.24.0-beta.9`（2026-09-12）；**几乎每天一个 beta** | [Releases](https://github.com/Tencent/teamai-cli/releases) |
| npm | [`teamai-cli`](https://www.npmjs.com/package/teamai-cli)，近 30 天下载 **6421** | `api.npmjs.org/downloads/point/last-month` |
| Open issues | 28 | `gh api repos/Tencent/teamai-cli` |

**活跃度判定：非常高。** 内部自 2026-03 起 dogfooding，2026-09 初对外开源（该「9 月 7 日开源」的时间点仅见于二手来源 [explainx.ai](https://www.explainx.ai/blog/tencent-teamai-cli-git-based-team-skills-2026)，但与 GitHub 仓库 4 月建库、9 月 star 暴涨、首 commit 3 月的一手事实一致）。

### 2.2 它自称解决什么问题

README 原文（[README.md](https://github.com/Tencent/teamai-cli/blob/main/README.md)）：

> TeamAI manages your team's skills, rules, MCP, and knowledge across Claude Code, Codex, CodeBuddy, WorkBuddy, OpenCode, Cursor, and other AI agents.

中文版（[README.zh-CN.md](https://github.com/Tencent/teamai-cli/blob/main/README.zh-CN.md)）：

> TeamAI 统一管理团队的 Skills、Rules、MCP 和知识，驾驭 Claude Code、Codex、CodeBuddy、WorkBuddy、OpenCode、Cursor 等 AI Agents。

三层产品架构（README「产品架构」表格原文）：

| 层 | 要解决的问题 | 当前 CLI 中的体现 |
|----|--------------|-------------------|
| **Team Execution** | 让每个 Agent 按团队的方式工作 | `init` / `pull` / `push`，skills、rules、agents、hooks、MCP、env |
| **Team Context** (beta) | 让每个 Agent 理解整个团队 | recall、learnings、代码知识图谱、teamwiki |
| **Team Improvement** (beta) | 让每一次执行都成为团队能力的积累 | 基于摩擦信号的经验分享、sessions、digest、dashboard |

Team Execution 的一句话口号：**「One Team. One Harness. Every Agent.」**

### 2.3 Architecture —— 它到底怎么工作

**形态：一个 npm 全局 CLI**（`npm i -g teamai-cli`，bin 名 `teamai`），commander 驱动，无常驻服务端。核心依赖只有 `simple-git` / `yaml` / `zod` / `fs-extra` / `tree-sitter-wasms`（[package.json](https://github.com/Tencent/teamai-cli/blob/main/package.json)）。

**它是 CLI wrapper 吗？不是。它是「配置/知识 registry + 分发器 + 检索器」三合一**，源码 `src/` 下 100+ 个模块，没有任何「代理转发 agent 调用」的逻辑。

#### 数据流

```
teamai push → 建分支 + 开 MR → reviewer 批准并合并
                                       ↓
            SessionStart hook → teamai pull → 写入本地各 AI 工具目录
```
（[README.md「How It Works」](https://github.com/Tencent/teamai-cli/blob/main/README.md)）

#### 团队仓库（共享，git 托管）存什么

README「What Gets Shared」表：`skills/<name>/SKILL.md`、`rules/*.md`、`docs/`、`agents/<name>.yaml`、`culture.md`（团队使命/价值观，注入每个 agent 的 CLAUDE.md / AGENTS.md）、`claudemd/*.md`、`env/`（明确标注 **do not put secrets here**）、`hooks/hooks.yaml`、`mcp/mcp.yaml`、`teamai.yaml`（npm 包 + Claude Code 插件声明）。

再加上运行期产物：`members/<user>.yaml`、`stats/*.yaml`、`sessions/`、`votes/<user>.yaml`、`learnings/`、`manifest/roles.yaml`、`teamwiki/`。

#### 本机数据存哪 —— 这是设计最讲究的一块

一手设计文档 [`docs/designs/data-directory-layout.md`](https://github.com/Tencent/teamai-cli/blob/main/docs/designs/data-directory-layout.md) 记载：原先机器数据放在业务仓库内 `<repo>/.teamai/`，实测 **18 MB**（team-repo clone 12 MB + skill 资源 4.1 MB + 搜索索引 1.8 MB），造成三个问题：工作区残留、worktree/子目录失明、跨项目数据混淆。

现在改为：

```
/path/to/my-project/              # 业务仓库 —— ZERO teamai residue
├── .claude/skills/  .claude/rules/   # 按工具下发的资源（在 workspaceRoot）
└── src/

~/.teamai/projects/<slug>/        # 按项目分区的机器数据
├── config.yaml
├── state.json
├── anchor                        # slug 是单向 sha256，此文件是唯一反查
└── team-repo/                    # 团队仓库的 clone
```

**核心模型是「两个 anchor」**（文档原文）：

```
projectAnchor  = `git worktree list --porcelain` 的第一条（主 worktree）
                 → 仓库与其所有 worktree 共享的稳定身份；机器数据按它分区
workspaceRoot  = `git rev-parse --show-toplevel`（当前 checkout，每个 worktree 不同）
                 → project-scope 的 AI 工具资源必须写到这里
```

文档给出了为什么资源必须落 `workspaceRoot` 的一手理由：

> every AI tool (Claude, Codex, CodeBuddy, OpenCode) discovers project resources by scanning up from the launch directory to the *current* repository root. None of them follows `git-common-dir` back to the main checkout, and gitignored files do not appear in a fresh worktree.

以及为什么用 `git worktree list` 而不是 `git-common-dir`：`--separate-git-dir` 会让 common dir 落在 checkout 之外导致**跨仓库碰撞**；且 `--git-common-dir` 在主仓库里返回**相对路径**。两个 anchor 都做 `realpath` 归一化，避免 macOS `/tmp → /private/tmp` 把一个 checkout 看成两个。

#### 知识检索（Team Context）

- `teamai recall <query>`：**BM25 + graph-boost** 打分检索 `learnings/`。默认**关闭**，需 `sharing.recall.enabled: true` 或 `teamai recall enable`。
- 开启后 `pull` 会把内建 `teamai-recall` **subagent** 部署到各工具的 `agents/` 目录；agent 在任务前调用它，子 agent 先跑 `teamai recall --check` 做相关性预检，不相关就整个跳过检索。
- `teamai codebase --extract` 用 **WASM tree-sitter**（纯 JS 依赖，无需原生工具链）解析 TS/JS、Python、Go 的 `import`/调用点/`implements`，产出 `DEPENDS_ON` / `REFERENCES` / `IMPLEMENTS` 边（tag `code-ast`）；其余语言走正则启发式（tag `code-heuristic`）。AST 失败则降级并记录 `AST_UNAVAILABLE` gap，`TEAMAI_SKIP_AST=1` 可强制启发式。
- 设计原型见 [`docs/designs/git-native-memory.md`](https://github.com/Tencent/teamai-cli/blob/main/docs/designs/git-native-memory.md)，明确借鉴 [vectorize-io/hindsight](https://github.com/vectorize-io/hindsight) 的 retain/recall/reflect，知识飞轮为「写入 → 索引 → 搜索 → 投票 → 排序 → 更好的搜索」。

#### 工程细节里两个值得单独点名的实现

1. **原子锁**（`src/update.ts` `acquireLock`）：旧实现是 check-then-write，两个进程会同时认为「没锁」。重写为 `writeFile(path, payload, { flag: 'wx' })`（即 `O_CREAT|O_EXCL`），payload 是 `{ pid, startedAt, owner }`，`owner` 是随机 token；`EEXIST` 时只回收 **stale** 锁（`process.kill(pid,0)` 判死），回收动作本身**序列化在一个原子创建的 sentinel 之后**并以 rename 落地；`releaseLock` 只在磁盘上的 `owner` 仍等于本进程 token 时才删除。
2. **迁移时的凭据保护**（`src/migrate.ts`）：copy → verify → 原子 rename，然后退休旧目录时，**先把一份内容为 `*` 的 `.gitignore` 写进 legacy 目录，再 rename 成 `.teamai.bak`**。文档原文解释了原因：老安装常常只靠仓库根的 `.teamai/` 规则保护，而该规则**不匹配 `.teamai.bak/`**，不先落 gitignore 就会让明文 `env`/`token` 暴露给下一次 `git add`。

### 2.4 「团队」这部分具体怎么做的 —— 逐条回答

| 关注点 | teamai-cli 的做法 | 一手依据 |
|---|---|---|
| **多人共享 agent 配置** | ✅ 核心能力。一个 git 仓库存全部 harness，`pull` 翻译写入每个人本地各工具的原生目录 | README「What Gets Shared」 |
| **共享 vs 每人私有状态** | 共享：team repo 的 `skills/` `rules/` 等。私有：`~/.teamai/projects/<slug>/`（config、state、clone、索引）+ `~/.teamai/`（`usage.jsonl`、`votes/`、`dashboard/`、`apikey`）。`learnings/` 根目录全员共享，`learnings/<project-id>/` 仅该项目成员同步 | `data-directory-layout.md`；README「Learnings isolation」 |
| **分发粒度控制** | 四个正交维度：`teamai roles`（role → namespace，只同步本角色 skill）、`teamai tags`（按 tag 订阅）、`teamai projects`（把工作目录绑到逻辑项目）、`teamai source`（订阅别的团队/组织的公共 skill repo）。另有 `teamai skill exclude` 让成员剔除不需要的 skill | README「Distribution Controls」 |
| **任务/backlog 跨人分发** | ❌ **完全没有。** 在 `src/`、README、usage-guide 中 grep `assign` / `backlog` / `dispatch task` / `work queue` 均**零命中** | 源码 grep |
| **谁在做什么的可见性** | ⚠️ **只有单机视角。** `teamai dashboard` 起的是一个**本机 HTTP server**，读 `~/.teamai/dashboard/events.jsonl`，`fs.watch` + SSE 推送，显示的是**你自己**的 live sessions 和本地 7 天趋势。跨人只有 `teamai members`（读 team repo 的 `members/*.yaml` 花名册）和 `teamai digest`（周报，聚合 `stats/*.yaml`）—— 都是**事后汇总，不是实时在做什么** | `src/dashboard.ts`；`src/members.ts`；`src/digest.ts` |
| **Review / merge 流程** | 复用 git 托管方自身的 MR/PR。`teamai push` → `generateBranchName(username)` → 提交 → push 分支 → 调 provider 建 PR（`src/push.ts`），失败也保留分支让人手工开。支持 **GitHub / GitLab / GitCode / CNB / TGit / 私有 Git**（`src/providers/`） | `src/push.ts`, `src/providers/` |
| **成本 / 配额按人核算** | ⚠️ **只有事后估算，无任何配额管控。** PostToolUse hook → `teamai track` → 追加 `~/.teamai/usage.jsonl`；SessionStart 顺带上报到 team repo `stats/<user>.yaml`；`teamai digest` 出 7 天成功率/prompt 数/活跃时长/**estimated cost**/cache/纠正次数趋势。价格表 `src/model-pricing.ts` 是**硬编码的 Anthropic 公开价**，带版本戳 `PRICE_TABLE_VERSION = 'anthropic-2026-09-09'`，注释明确 **"Subscription and enterprise discounts are excluded"**，且成本以整数 micro-dollar 存储、**价格表变更后绝不重算历史** | `src/usage-tracker.ts`, `src/model-pricing.ts`, `src/digest.ts` |
| **auth / secrets** | git 模式下**没有自己的鉴权**——完全靠 git 托管方的凭据，谁能 push 团队仓库谁就能改全队配置。`env/` 文档明确写 **"do not put secrets here"**。HTTP 模式（只读消费者）有 Bearer key：`~/.teamai/apikey` 以 **0600** 写入，或 `TEAMAI_API_TOKEN`；注释声明 key **"NEVER stored in teamai.yaml / local config and NEVER reported in any payload"** | `src/api-key.ts`；usage-guide |
| **隐私** | session 摘要做 redact，且**默认不上传** prompt 行，需 `--include-prompt` 显式开启（注释：`redact()` is best-effort）。usage JSONL 只有 skill 名 + 时间戳，不含对话内容。sessions 保留 90 天 | `src/save-session.ts`；`team-intelligence-platform.md` §Security |

#### Team Improvement 里最有意思的一个机制：friction 评分

README 原文：

> When a session ends, the Stop hook scores it by **friction** — signals that the session hit something worth remembering: you interrupted or corrected the AI, denied a tool call, or the AI had to retry failing tools. A long-but-routine session (lots of tool calls, no friction) does not trigger; a session where you actually fought a problem does.

命中后打印类似：

```
[teamai] This session may contain a problem worth documenting: you interrupted the AI twice, the AI retried failing tools 8 times.
Consider running /teamai-share-learnings to summarize what you learned and share it with your team.
```

每个 session **最多提示一次**；团队可用 `sharing.contributeHint.enabled: false` 关闭而保留 Stop hook 其余功能。

### 2.5 支持哪些 agent CLI，怎么抽象

**内建注册表 `KNOWN_AGENTS`（`src/known-agents.ts`）共 34 项**，抽象方式极其朴素：每个 agent 只记录一个 `skillsPath`（相对 HOME 的 skills 目录），运行时与 `teamConfig.toolPaths` 合并、用户配置优先。注释承认列表来源：*"Sourced from the iamzhihuix/skills-manage project's supported-platforms table."*

- **coding**：`claude`(.claude/skills)、`claude-internal`、`tclaude`、`codex`、`codex-internal`、`tcodex`、`cursor`、`joycode`、`codebuddy`、`gemini`、`aider`、`amp`、`augment`、`copilot`、`factory`、`hermes`、`junie`、`kilocode`、`kiro`、`ob1`、`opencode`、`qoder`、`qwen`、`trae`、`trae-cn`、`windsurf`、`zcode`、`dsh`(DeepSeek Harness)
- **lobster 家族**：`openclaw`、`qclaw`、`easyclaw`、`autoclaw`、`workbuddy`
- **central**：`agents`(.agents/skills)

抽象的三个层次：
1. **Skills/Rules/Docs** = 纯文件拷贝到 `~/.<tool>/skills` 或 `<project>/.<tool>/skills` —— 所以支持面才能铺这么宽。
2. **MCP** = 团队仓库里写一份 `mcp/mcp.yaml`，`pull` 时**翻译成每个工具的原生格式**（`src/resources/mcp-format.ts` 有 `detectMcpFormat` / `renderJsonEntry` / `renderCodexBlock`，Codex 是 TOML 块，其余是 JSON）。
3. **Hooks** = 按工具注入（`src/hooks.ts`、`openclaw-hooks.ts`、`opencode-hooks.ts`、`hermes-hooks.ts`），有单独的 `hook-dispatch` 入口统一分流。

README 的能力矩阵只对 **11 个** agent 给出逐特性打勾（Claude Code / Codex / Cursor / CodeBuddy / WorkBuddy / OpenCode / OpenClaw / Hermes / DeepSeek Harness / Qoder / ZCode）。**支持是分层的**：Claude Code、Codex、Cursor、CodeBuddy、Qoder 13 项全绿；WorkBuddy 缺 `agents`；OpenClaw 缺 agents/hooks/mcp 和全部 Team Improvement；Hermes 还缺 rules；DeepSeek Harness 只剩 skills/docs + Team Context。usage-guide 明确提示 **JoyCode 和 Gemini CLI 不支持 lifecycle hooks，因此不会自动同步，必须手工 `teamai pull`**。

### 2.6 5 人团队怎么真正用起来

一手 [usage-guide.md](https://github.com/Tencent/teamai-cli/blob/main/docs/usage-guide.md)：

**管理员（一次）**：在任意 git 托管上建一个共享仓库，**给成员写权限**，然后 `teamai init https://github.com/yourorg/yourrepo`。没有现成仓库的话，从 [teamai-hub](https://github.com/teamai-hub) org 的模板仓库 `Use this template`（目前该 org 只有 `template-backend` 一个真模板，⭐10）。

**成员（每人一次）**：
```bash
npm install -g teamai-cli
cd /path/to/my-project
teamai init https://github.com/yourorg/yourrepo      # project scope（默认）
# 或 teamai init <url> --scope user                   # user scope，装到 ~/
```
之后**每次开 AI session 自动 `pull`**，无需手动操作。

**三种部署模式**：
- **project scope**（默认）：资源落业务仓库的 `.claude/` 等，机器数据在 `~/.teamai/projects/<slug>/`。
- **user scope**：资源落 `~/.claude/skills` 等，机器数据在 `~/.teamai/`。
- **self（单仓）模式**：业务仓库**本身就是**团队仓库，知识 commit 到 main 上随 clone 走；机器数据仍分区外置。`members`/`sessions`/`stats` 走 `teamai-reports` 孤儿分支的 worktree。
- **HTTP 模式**：`teamai init --http <endpoint> --token <key>`，**只读消费者**，`push`/`contribute`/`remove` 不可用，不需要 git clone。

**假设的基础设施**：一个所有人可读、reviewer 可合的 git 仓库（GitHub/GitLab/GitCode/CNB/TGit/私有 Git），Node.js + npm，以及支持 lifecycle hooks 的 agent。**不需要**任何服务端、数据库或中心化服务。

### 2.7 明确不做的事 & 暴露出的缺口

**一手写明的 NOT in Scope**（[`docs/designs/team-intelligence-platform.md`](https://github.com/Tencent/teamai-cli/blob/main/docs/designs/team-intelligence-platform.md) §NOT in Scope）：

> - Contributor Leaderboard — 竞争性排名可能影响团队文化
> - Cross-team skill marketplace — 需要跨团队认证/授权机制
> - Real-time dashboards (web UI) — CLI 工具不需要 web 前端
> - Auto-generated skill README — 低优先级
> - ML-based recommendations — 简单频率推荐已足够
> - Cursor PostToolUse hook — 等 Cursor hook API 稳定后再支持

（注：其中 "Real-time dashboards (web UI)" 这条后来被推翻了——`teamai dashboard` 已经实现并写进 README，说明这份非目标清单是 3 月的历史快照。）

**`data-directory-layout.md` §Explicitly out of scope**：`teamai migrate` / `gc` / `--revert` 命令；跨项目共享的 team-repo clone；**P1 迁移后不支持降级**（老版本会把已分区的安装当成未初始化，`.teamai.bak/` 是唯一手工回滚路径）。文档还说明 teamai **从不自动回收** orphan 分区，只由 `status --all` 标出让人手工 `rm -rf`，且判定只认 `anchor` 文件——**没有 anchor 的分区一律标 `unknown` 而绝不标 ORPHAN**，理由是「we never recommend deleting data we cannot confirm is dead」。

**open issues 暴露的真实缺口**（[issues](https://github.com/Tencent/teamai-cli/issues)）：

- [#532](https://github.com/Tencent/teamai-cli/issues/532) **`teamai pull` 会递归删除它自己没安装过的本地 skill 目录（含 git 追踪的文件）** —— 真实的数据丢失 bug，仍 open。
- [#484](https://github.com/Tencent/teamai-cli/issues/484) / [#485](https://github.com/Tencent/teamai-cli/issues/485) / [#486](https://github.com/Tencent/teamai-cli/issues/486)：正在把 `members`/`sessions`/`votes`/`stats` 和 `learnings/` 从 `main` 挪到独立分支（`teamai-reports` / `teamai-learnings`，后者直推不走 PR）—— 说明「所有东西一个仓库一个分支」的原始设计已经撑不住了。
- [#341](https://github.com/Tencent/teamai-cli/issues/341) 提议做一个 **基于 Go 的管理后端（零 Git 接入）** —— 等于承认「必须会用 git」是采用门槛。[#517](https://github.com/Tencent/teamai-cli/issues/517) 则是「给没接触过 Git 的用户」的接入提示词 RFC。
- [#352](https://github.com/Tencent/teamai-cli/issues/352) 提议把 codebase graph 改成可插拔的 GraphProvider，**「停止自研多语言抽取」** —— 自研 AST 抽取这条路走得吃力。
- [#405](https://github.com/Tencent/teamai-cli/issues/405)、[#407](https://github.com/Tencent/teamai-cli/issues/407)、[#408](https://github.com/Tencent/teamai-cli/issues/408) 都还是 Proposal 状态，说明 Team Context / Team Improvement 两层确实仍是 beta。

---

## 三、被排除的其它候选身份（供对照）

| 候选 | 真实身份 | 是否「团队 agent 统一 repo」 |
|---|---|---|
| **Tencent CodeBuddy / CodeBuddy Code** | 腾讯自研的 coding agent **产品**（闭源），在 teamai-cli 里是**被分发的目标之一**（`.codebuddy/skills`） | ❌ 是 agent 本身，不是统一入口 |
| **Tencent WorkBuddy 开放平台** | 腾讯的 agent 生态/开放平台，同样是 teamai-cli 的**下发目标**（`.workbuddy/skills`，lobster 家族） | ❌ 同上 |
| **腾讯云 CodeBuddy CLI** | CodeBuddy 的 CLI 形态，仍是 agent 本体 | ❌ |
| [**Tencent/LoopForge**](https://github.com/Tencent/LoopForge) | *"Resumable multi-agent development workflows for coding agents (CodeBuddy, Codex, Cursor, Claude Code)"*，Python，⭐32，建于 2026-07-28 | ⚠️ **精神上最接近 claude-fleet**（可恢复的多 agent 工作流），但体量极小，且是「工作流」不是「团队 repo」 |
| [**Tencent/SkillHone**](https://github.com/Tencent/SkillHone) | 持续的 agent skill 演化，决策落成本地 git issue/PR/wiki，⭐149 | ⚠️ 相邻，聚焦单 skill 质量演化而非团队分发 |

**最贴合「团队 agent 统一 repo / 团队级 coding agent 统一入口」这个说法的，就是 `Tencent/teamai-cli`。** 它确实是「一个 repo 统一团队的 agent 配置」，只是「统一入口」指的是**配置面**的统一，不是**执行面**的统一。

---

## 对 claude-fleet 的可借鉴点

### 一句话定位差异

**teamai-cli 解决的是「一个团队的 N 个人，如何共享同一套 agent 配置与经验」；claude-fleet 解决的是「一个人，如何同时驱动 N 个 agent session 干活」。** 两者几乎正交——teamai 在**人**这一维扩展，fleet 在**并发 session** 这一维扩展。如果用户以为它是 fleet 的竞品，那是误判；但它在「配置分发」这条 fleet 目前偏手工的链路上确实有可偷的东西。

### A. 值得偷的具体机制

1. **`push → MR → merge → SessionStart 自动 pull` 这条传播轨道。**
   我们现在是 `/fleet-sync-install` **手工**把合并后的 tooling 重新贴到 live install（memory 里 `fleet-deploy-state-confs`、`auto-handoff-nudge-never-fired` 都记着「live only after /fleet-sync-install」这个坑——#562 合了但不 sync 就等于没合）。teamai 把这一步做成 **SessionStart hook 自动执行 + 原子锁串行化**，成员零操作。我们完全可以在 SessionStart hook 里跑一次「base checkout 已合并 → live install 落后」的检测并自动 apply（或至少在 dash 上亮一个 `sync↓` 标记），把「合了但没生效」这个反复踩的坑封死。

2. **双 anchor 模型 —— 对我们是直接命中。**
   `projectAnchor = git worktree list --porcelain 第一条` / `workspaceRoot = git rev-parse --show-toplevel`，前者做**跨 worktree 共享的稳定身份**，后者做**必须逐 worktree 落地的资源位置**。claude-fleet 是重度 worktree 用户（每个 issue 一个 `issue-<N>` worktree）。更值钱的是他们踩过并写下来的两条事实：
   - **没有任何 AI 工具会顺着 `git-common-dir` 回溯到主 checkout**，且 **gitignored 的文件不会出现在新建的 worktree 里** —— 这正是 memory 里 `fork-worktree-edit-guard`（fork worktree 落在 `repo/.claude/worktrees` 导致 Write/Edit 被拒）那一类问题的根因描述。
   - `--separate-git-dir` 会让 `git-common-dir` 的父目录在无关仓库间**碰撞**，`--git-common-dir` 在主仓库还返回相对路径。我们任何按「仓库身份」做 keying 的脚本（ledger 去重、transcript-dir 映射）都应该改用 `git worktree list --porcelain` 首条 + `realpath`。

3. **原子锁配方。**
   `writeFile(path, payload, {flag:'wx'})`（`O_CREAT|O_EXCL`）+ payload 带随机 `owner` token + `EEXIST` 时仅回收 `process.kill(pid,0)` 判死的 stale 锁 + **回收本身序列化在一个原子 sentinel 之后并以 rename 落地** + `releaseLock` 只删 owner 匹配的锁。我们的 daemon（quotawatch 60s tick、cleanup、autofill dispatcher）多处并发触碰同一状态，这套「绝不误删别人的锁」的配方可以直接照搬成 `fleet-lib.sh` 的一个函数。

4. **friction 评分的 Stop hook —— 比我们现在的 handoff 触发信号更聪明。**
   我们的 auto-handoff 用**上下文百分比**触发（`@ctx_pct`，还踩过 `/clear` 后过期成环的坑，#571/#573）。teamai 用的是**摩擦信号**：用户打断/纠正、拒绝工具调用、工具失败重试次数——「长但顺利的 session 不触发，真正搏斗过的才触发」，且**每 session 最多提示一次**、团队可单独关掉提示而保留 hook 其余功能。这套信号对我们判断「这个 worker 值不值得写一条 learning / 要不要提醒操作员介入」比 ctx% 有用得多，而且这些信号 transcript 里本来就有。

5. **迁移/改名时先落 `.gitignore` 再 rename。**
   把内容为 `*` 的 `.gitignore` 写进旧目录**之后**再 `mv` 成 `.bak`，因为仓库根的 `.teamai/` 规则不匹配 `.teamai.bak/`。我们任何会把含凭据的目录改名/备份的脚本（fleet.conf 里有 `CCQUOTA_VIEWER_TOKEN`）都该照做这一步。

6. **单份 `mcp.yaml` → 翻译成各工具原生格式。**
   memory 里 `fleet-concurrency-and-mcp-posture` 记着「两个 fleet 各自 MCP 白名单」是手工维护的。teamai 的 `detectMcpFormat` / `renderJsonEntry` / `renderCodexBlock`（Codex 走 TOML 块、其余走 JSON）+ `entryHash` 幂等对账，是一个现成的「一处声明、多处落地」实现思路。

7. **成本账本的两个不变量。**
   价格表带版本戳（`PRICE_TABLE_VERSION = 'anthropic-2026-09-09'`），成本存**整数 micro-dollar**，且**价格表更新后绝不重算历史**。ccquota 的历史数据应该有同样的不变量，否则改一次价格表历史曲线就变形了。

8. **`status --all` 的孤儿判定纪律。**
   只凭 `anchor` 文件判定 ORPHAN，缺 anchor 一律标 `unknown` 而**绝不**标可删；且**永不自动回收**。这条「不能证明它死了就不建议删」的保守纪律，值得抄进我们的 cleanup/reap 逻辑——memory 里 `closed-pr-reap-restore-needs-reopen` 正是一次自动回收判断过激的教训。

### B. 我们已经做得更好的地方（不必回头看它）

1. **真正的并发编排。** claude-fleet = N 个并发 worker，一个 tmux window 一个、各自独立 worktree、GitHub issue 当 backlog、autofill dispatcher 在有空位时自动派活。teamai-cli **完全没有这一层**——源码里 `assign`/`backlog`/`dispatch task` 零命中，它的 `orchestrat` 命中全是「并行调 Claude 生成 wiki 文档」这种内部用途。
2. **谁在做什么的实时可见性。** 我们的 dash 是**每个 fleet 的实时全景**（每个 window 状态 + 仓库级 PR map + deploy state）。teamai 的 `dashboard` 是**单机单人**的 HTTP server，只看得到自己；跨人只有花名册和周报这种事后汇总。
3. **配额治理是闭环的。** 我们有账号轮转（`fleet-account.sh migrate`）、70% peer 告警 / 85% bench+搬迁、60s `quotawatch` daemon + heartbeat + `⚠ quota stale`、per-model 限流时的就地 `/model` 降级（#569/#570）。teamai 只是**事后按公开价估算**成本，明说不含订阅折扣，**没有任何管控、轮转或熔断**。
4. **爆炸半径隔离。** 一个 fleet ≡ 一个 tmux session ≡ 一个独立 socket，任何 worker 的致命信号只打掉自己那台 server。teamai 没有任何运行时隔离概念——它根本不运行 agent。
5. **跨上下文边界的接力。** `/fleet-handoff` + Stop-hook 分类器把一个长任务跨 session 传下去。teamai 的 session 处理终点是「写一篇 learning 给团队看」，不是「把活接着干完」。
6. **它的分发层还有真实的数据丢失 bug**（#532：`pull` 递归删除它没装过的本地 skill 目录，含 git 追踪文件）。如果要借鉴，借**机制**，不要借它的 `pull` 实现。

### C. 一个可能的组合姿势

teamai-cli 和 claude-fleet 在同一台机器上**不冲突**，甚至互补：teamai 负责把团队约定（skills/rules/hooks/mcp）灌到 `~/.claude/`，fleet 负责把 N 个 worker 开起来用这些约定干活。唯一要当心的是 **#532** 和「`pull` 会改写 `~/.claude/skills`」这件事——fleet 自己也在管 `~/.claude/fleet` 与 skills，两者同时写同一棵目录树需要先划清边界。
