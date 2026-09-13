# 团队 coding agent 工具链 landscape 调研

> 调研日期 2026-09-12/13。所有 star / commit 数据来自当日 `gh api repos/<owner>/<repo>`，
> 均为一手核对，不是转述榜单。二手来源（博客、聚合文章）单独标 **[二手]**。

## 结论（先看这 8 行）

1. **2025 年那批"worktree 并行编排器"几乎团灭。** vibe-kanban（28k★）已公告
   [sunsetting](https://github.com/BloopAI/vibe-kanban/blob/main/README.md)、crystal（3.1k★）
   2026-02 [改名 Nimbalyst 转闭源](https://github.com/stravu/crystal)、uzi 停在 2025-06。
   claude-squad / container-use 还活着但三个月只有 6–7 个 commit。**这个赛道被上游吃掉了。**
2. **吃掉它的是 Claude Code 自己。** 原生已有 `claude --worktree` / `EnterWorktree` /
   `isolation: worktree`、worktree 越界写入的四道强制检查、定期 worktree 清扫、
   Agent Teams（共享任务表 + mailbox + `teammateMode: "tmux"` 分屏）、cross-session messaging。
3. **遥测这一层也已经原生化**：8 个 OTEL metrics + 6 类 log events + beta tracing，
   加上 `/usage` 的 plan 用量条与归因、`/insights`。
4. **但原生方案有两条硬边界**：(a) 任务表是 **session-scoped、纯本地、从不上传、一个 session 一个 team**；
   (b) 用量视角是 **org / API-key / 本机**，没有"一个人手里 N 个订阅账号的池子"这个概念。
5. **这两条边界正好是 claude-fleet + ccquota 站的位置。** GitHub issue 作为唯一且持久的 backlog、
   多订阅账号池的主动配额调度，在整张图里没有第二个开源实现（唯一接近的是
   [clauth](https://github.com/uwuclxdy/clauth)，149★，单人单机视角）。
6. **我们真正在重复造的轮子有 9 个**（worktree 守卫、janitor、分屏、跨会话消息、用量代理、
   statusline context 条……），清单在最后一节，逐条给了原生替代。
7. **别人有我们没有的**：容器/网络级沙箱（container-use、coder、E2B）、diff review UI + inline
   评论回传、真正的多人 server（coder、OpenHands）、CI 侧 agent（gh-aw、claude-code-action）、
   配置分发的 marketplace 打包。
8. **整张图最大的空白是"注意力"**：所有工具都在解决"怎么并行跑"，几乎没人解决
   "7 个跑着的 session 里，人应该先看哪一个"。这恰好是 fleet 的 urgency-sorted windows 在做的事。

---

## 1. 并行 / 多会话 agent 编排（worktree-per-task、session manager、tmux fleet）

这是 claude-fleet 的正面赛道。**结论是：题目里给的"已知起点"清单里，一半已经死了或转闭源。**

| 项目 | License | ★ | 最后一次 default-branch commit | 活跃度 | 一句话 |
|---|---|---|---|---|---|
| [Claude Code 原生](https://github.com/anthropics/claude-code)（`--worktree` + Agent Teams） | 无 OSS license（repo 只是 issue tracker，二进制闭源） | 144,864 | 2026-09-13 | 极活跃 | 上游把这一层做进产品了 |
| [gastownhall/gastown](https://github.com/gastownhall/gastown) | MIT | 18,033 | 2026-07-23 | 主干停了约 7 周 | Go，"Mayor / Rig / Polecat / Hook" 一套隐喻，hook = git worktree |
| [smtg-ai/claude-squad](https://github.com/smtg-ai/claude-squad) | AGPL-3.0 | 8,472 | 2026-08-20（近 3 月仅 6 commit） | 维护模式 | tmux + worktree，最接近 fleet 的形态 |
| [dagger/container-use](https://github.com/dagger/container-use) | Apache-2.0 | 4,041 | 2026-08-12（近 3 月仅 7 commit） | 放缓，自标 experimental | MCP server，每 agent 一个容器 + 一条 git branch |
| [BloopAI/vibe-kanban](https://github.com/BloopAI/vibe-kanban) | Apache-2.0 | 28,064 | **2026-04-24** | ⚠️ **已公告 sunsetting** | README 顶部就是 "Vibe Kanban is sunsetting" |
| [stravu/crystal](https://github.com/stravu/crystal) | MIT | 3,115 | **2026-02-26** | ⚠️ **已弃用** | 2026-02 改名 [Nimbalyst](https://nimbalyst.com/) 转闭源桌面产品 |
| [devflowinc/uzi](https://github.com/devflowinc/uzi) | MIT | 582 | **2025-06-04** | ⚠️ **死了 15 个月** | 当年最早那批 worktree runner |
| [imbue-ai/sculptor](https://github.com/imbue-ai/sculptor) | MIT | 230 | 2026-09-11 | 活跃 | 桌面 app，源码开放但 README 明说暂不接外部贡献 |
| [andyrewlee/amux](https://github.com/andyrewlee/amux) | MIT | 160 | 2026-09-03 | 活跃但小 | 纯 TUI |
| [majiayu000/harness](https://github.com/majiayu000/harness) / [himkt/cafleet](https://github.com/himkt/cafleet) | MIT | 70 / 51 | 2026-09-12 / 09-13 | 太早期 | 和我们同名同形，可观察不可依赖 |
| Conductor（conductor.build） | — | — | — | — | **没找到对应开源仓库**，按闭源商业 Mac app 处理，不在本表 |

### 真正该细看的三个

#### Claude Code 原生 worktree + Agent Teams —— 最重要的一条

来源：[worktrees 文档](https://code.claude.com/docs/en/worktrees)、[agent-teams 文档](https://code.claude.com/docs/en/agent-teams)。

**做了什么**：`claude --worktree <name>` 直接在 `.claude/worktrees/<name>/` 开一个 worktree、
新分支 `worktree-<name>`，默认从 remote default branch 切（`worktree.baseRef: "fresh" | "head"`）；
`claude --worktree "#1234"` 可以直接从某个 PR 的 head 开 worktree。会话里 Claude 可以用
`EnterWorktree` / `ExitWorktree` 工具进出；subagent 加 frontmatter `isolation: worktree` 就永久隔离。
`.worktreeinclude`（gitignore 语法）把 `.env` 这类未跟踪文件复制进新 worktree。
非 git 的 VCS 用 `WorktreeCreate` / `WorktreeRemove` hook 顶替。

**隔离是强制的，不是约定**：会话在 worktree 里时，Claude Code 拦四类调用 ——
(1) 指向 main checkout 的 `Edit`/`Write`/`NotebookEdit`；(2) 工作目录落在 main checkout 的
Bash/PowerShell/Monitor 命令；(3) 通过 `git -C` / `--git-dir` / `GIT_DIR` / `GIT_WORK_TREE` / 先 `cd`
把 git 重定向回 main checkout；(4) **命令文本无法静态证明 git 留在 worktree 内时直接拒**（这条关不掉）。

**清理也是原生的**：Claude Code 给自己建的每个 worktree 在 git metadata 里写 marker，
定期 sweep 按 `cleanupPeriodDays` 删掉 subagent/background 的 worktree，有改动/未推 commit 的留着；
agent 运行期间持 `git worktree lock`，被 kill 的 session 留下的锁由 sweep 释放。

**Agent Teams**（`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`，v2.1.178+）：一个 lead + 若干 teammate，
每个 teammate 是独立 context window 的完整 Claude 会话；共享任务表带依赖和 **file-locking 的 claim**；
mailbox 是 `~/.claude/teams/{team}/inboxes/{agent}.json`；`teammateMode: "tmux" | "iterm2" | "auto" | "in-process"`
—— **官方文档明确推荐 tmux 分屏，还写了 "Orphaned tmux sessions" 的排障段落**。
配套 hook：`TeammateIdle` / `TaskCreated` / `TaskCompleted`，exit code 2 可以打回。

**团队故事**：弱。文档白纸黑字写了 —— team 是 **session-scoped**（`session-<前8位 session id>`）、
任务表 **"persists locally and is never uploaded"**、**one team per session**、**no nested teams**、
**in-process teammate 不支持 `/resume` / `/rewind`**、lead 终身固定不可转让。
也就是说这是"一个人一次会话内的并行"，不是"一个团队跨天跨人的 backlog"。

**值得偷 / 值得避**：
- 偷：worktree 越界的**四道强制检查**比我们 `hooks/base-readonly-guard.py` 严得多（我们没有拦 `git -C` 重定向这一路）。
- 偷：`.worktreeinclude` 这个把 gitignored 文件带进 worktree 的机制，比我们各 worker 自己 `cp .env` 干净。
- 偷：worktree 上打 marker + `git worktree lock`，比我们 janitor 靠"merged + clean + 没 pane 附着"三条件推断安全。
- 避：把 backlog 放在 `~/.claude/tasks/` 这种本地、session 派生、不上传的地方 —— 换台机器、换个人就没了。

#### smtg-ai/claude-squad（AGPL-3.0，8,472★）

Go 写的 TUI，依赖 tmux + gh，每个 task 一个隔离 git workspace，支持 Claude Code / Codex /
Gemini / Aider。和 fleet 形态最像，但只有 TUI 里的一个 list，没有 tmux status bar 的注意力信号、
没有 GitHub issue 绑定、没有账号池。**近 3 个月只有 6 个 commit**（最新那个是
"recover instances whose tmux session died with the server"，2026-08-20），按维护模式看待。
**AGPL-3.0 意味着不能拿它的代码**。

#### dagger/container-use（Apache-2.0，4,041★）

不是 session manager，是一个 **MCP server**：每个 agent 拿到一个新容器 + 自己的 git branch，
人用 `git checkout <branch>` 审工作，可以"drop into any agent's terminal"接管。
这是唯一一个把**隔离做到文件系统/进程级**而不是 git worktree 级的成熟开源实现。
近 3 个月 7 个 commit，README 仍挂 `stability-experimental` 徽章。

**值得偷**：agent 的完整命令历史与日志可回放（"see what agents actually did, not just what they claim"）
—— 我们的 ledger 记的是结果，不是过程。
**值得避**：把它当编排器用会失望，它没有多会话视图，没有注意力信号。

---

## 2. 团队共享的 agent 配置 / skill & prompt registry

这一层的答案很明确：**格式已经标准化（AGENTS.md），分发已经产品化（plugin marketplace），
剩下的全是内容仓库。** 这是 2025→2026 变化最大的一块。

| 项目 | License | ★ | 最后 commit | 是什么 |
|---|---|---|---|---|
| [Claude Code plugin marketplaces](https://code.claude.com/docs/en/plugin-marketplaces)（原生） | 产品特性 | — | — | `.claude-plugin/marketplace.json` + managed settings 强制 |
| [agentsmd/agents.md](https://github.com/agentsmd/agents.md) | MIT | 24,322 | 2026-09-10 | AGENTS.md 格式规范本身 |
| [obra/superpowers](https://github.com/obra/superpowers) | MIT | 285,819（fork 25,571） | 2026-08-12 | 最大的 skills 框架 + 方法论 |
| [hesreallyhim/awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code) | NOASSERTION | 53,947 | 2026-09-13 | awesome-list 长成了事实上的索引 |
| [wshobson/agents](https://github.com/wshobson/agents) | MIT | 39,598 | 2026-09-07 | 94 plugins / 202 agents / 183 skills / 105 commands，一份 Markdown 源产出 5 种 harness |
| [davila7/claude-code-templates](https://github.com/davila7/claude-code-templates) | MIT | 30,670 | 2026-09-12 | 配置 + 监控 CLI |
| [anthropics/skills](https://github.com/anthropics/skills) | 无 license 字段 | 176,006 | 2026-09-10 | 官方 Agent Skills 仓库 |
| [microsoft/skills](https://github.com/microsoft/skills) | MIT | 3,011 | 2026-09-11 | 175 skills + AGENTS.md 模板 + MCP 配置，`npx skills add microsoft/skills` |

### 原生机制：marketplace + managed settings（这就是"团队怎么共享"的标准答案）

来源：[plugin-marketplaces 文档](https://code.claude.com/docs/en/plugin-marketplaces)。

- 仓库根放 `.claude-plugin/marketplace.json`（必填 `name` / `owner` / `plugins`，每个 plugin 必填
  `name` / `source`）。
- 成员 `/plugin marketplace add owner/repo` + `/plugin install <plugin>@<marketplace>`。
- 一个 plugin 可以同时装 **skills / commands / agents / hooks / mcpServers / lspServers** ——
  也就是说 claude-fleet 的 `commands/*.md` + 五条 hook 完全可以打包成一个 plugin。
- source 支持 相对路径 / `github` / `url` / `git-subdir` / `npm` / `archive` / `command`。
- 组织强制：managed settings 里的 `extraKnownMarketplaces`（预注册）、`enabledPlugins`（默认开启）、
  `strictKnownMarketplaces`（白名单；空数组 `[]` = 全面封锁）、`pluginSuggestionMarketplaces`、
  `disableCommandPluginSources`。
- 另外 [worktree 文档](https://code.claude.com/docs/en/worktrees)提到：**project scope 装的 plugin
  在同一 repo 的所有 worktree 里自动生效**（v2.1.200+），不用每个 worktree 重装。

**团队故事**：这一层是这次调研里**团队故事最完整**的 —— 有版本、有分发、有组织级强制、有 scope。

**值得偷**：把 fleet 的 commands + hooks 打成一个 plugin，用 marketplace 分发，
`/fleet-sync-install` 就能从"手工 git pull + 合并 hooks 到一台机器"降级成
`/plugin update`。这是我们目前最重的自建管道之一。
**值得避**：`{"source": "command", ...}` 这种任意命令型 plugin source；组织侧应该
`disableCommandPluginSources: true`。

### AGENTS.md 的现状

[agents.md](https://github.com/agentsmd/agents.md)（MIT，24.3k★，2026-09-10）把"给 agent 的 README"
标准化了。同期出现的还有 [google-labs-code/design.md](https://github.com/google-labs-code/design.md)
（Apache-2.0，27,871★）—— 把视觉规范也标准化给 coding agent。**对 3–8 人小团队的实际启示**：
仓库里的 `CLAUDE.md` / `AGENTS.md` 是唯一零成本、跨 harness、天然版本化的共享层，
优先把知识放这里，工具化的东西再往 plugin 走。

**一个值得避的坑**：`obra/superpowers` 285k★ / 25.5k fork 这种数字说明
"skills 仓库"已经彻底变成了社交货币。star 数在这一类里**不构成质量信号**，
选内容仓库要看 eval / test harness（`microsoft/skills` 有 CI 跑 evals 和 skill-evaluation，是少数）。

---

## 3. Agent 成本 / 配额 / 用量遥测（ccquota 所在的生态位）

| 项目 | License | ★ | 最后 commit | 状态 / 一句话 |
|---|---|---|---|---|
| [Claude Code 原生 OTEL](https://code.claude.com/docs/en/monitoring-usage) | 产品特性 | — | — | 8 metrics + 6 log events + beta tracing |
| [Claude Code `/usage`](https://code.claude.com/docs/en/costs) | 产品特性 | — | — | plan 用量条 + 归因 + behavior flags + loop 行 |
| [ccusage/ccusage](https://github.com/ccusage/ccusage)（原 ryoppippi/ccusage） | NOASSERTION | 18,517 | 2026-09-13 | 活跃；已迁 org 并用 Rust 重写；读本地 JSONL 算 token/成本 |
| [Maciek-roboblog/Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) | MIT | 8,701 | 2026-06-27 | ⚠️ 近 2.5 个月无 commit |
| [ColeMurray/claude-code-otel](https://github.com/ColeMurray/claude-code-otel) | MIT | 497 | **2025-06-17** | ⚠️ **demoware**：整个仓库只有 2025-06-17 一天的提交，此后 15 个月零更新 |
| [BerriAI/litellm](https://github.com/BerriAI/litellm) | NOASSERTION | 58,594 | 2026-09-13 | 极活跃；Claude Code 官方文档自己点名的 LLM gateway |
| [uwuclxdy/clauth](https://github.com/uwuclxdy/clauth) | MIT | 149 | 2026-09-12 | 🎯 **和 ccquota + fleet-account 重叠度最高的东西** |

### 原生已经做到哪一步（这决定了 ccquota 在重复什么）

**OTEL**（[monitoring-usage](https://code.claude.com/docs/en/monitoring-usage)）：
`CLAUDE_CODE_ENABLE_TELEMETRY=1` + 标准 OTLP env。
- Metrics（8 个）：`claude_code.session.count`、`lines_of_code.count`、`pull_request.count`、
  `commit.count`、`cost.usage`(USD)、`token.usage`、`code_edit_tool.decision`、`active_time.total`。
- Log events（6 个）：`user_prompt`、`assistant_response`、`tool_result`、`api_request`、
  `api_error`、`api_refusal`。
- Beta tracing（`CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`）：`claude_code.interaction` /
  `llm_request` / `tool` / `tool.blocked_on_user` / `tool.execution` / `hook` 六种 span，
  W3C trace context 会通过 `TRACEPARENT` 传进 Bash 子进程。
- 基数控制：`OTEL_METRICS_INCLUDE_SESSION_ID` / `_VERSION` / `_ACCOUNT_UUID` / `_ENTRYPOINT` /
  `_REPOSITORY` 等。managed settings 定义 `OTEL_EXPORTER_OTLP_*` 时会在启动时**删掉开发者自设的冲突变量**，
  防止绕过公司 collector。
- ⚠️ **原生不含聚合后端**：没有 dashboard、没有 org 级汇总，"必须自己在 Datadog/Honeycomb/自建
  collector 里 filter `organization.id`"。

**`/usage`**（[costs](https://code.claude.com/docs/en/costs)）对订阅用户已经相当厚：
plan 用量条、把最近用量**归因到 skill / subagent / plugin / 单个 MCP server**、
behavior flags（long context、cache miss 占比 ≥10% 就标）、**每个 `/loop` 的 token 行**、
`d`/`w` 切 24h / 7d、prompt cache 命中率行。还有 `/insights` 生成 HTML 报告到
`~/.claude/usage-data/report.html`。
⚠️ **但它明说："computed from local session history on this machine, so usage from other devices
or claude.ai is not included."** —— 单机视角。

**API 侧**：[Claude Code Analytics API](https://platform.claude.com/docs/en/build-with-claude/claude-code-analytics-api)
（Admin API key，Console/API 组织）和 Enterprise Analytics API（`read:analytics`，Enterprise 组织）
给每人每天的聚合指标。**[二手]** 据 [Faros](https://www.faros.ai/blog/claude-code-analytics) /
[Finout](https://www.finout.io/blog/anthropics-enterprise-analytics) 等文章，
Enterprise Analytics 数据从 2026-01-01 起、约 1 天延迟、保留 90 天。
⚠️ **这两个 API 对 Pro/Max 个人订阅完全不适用** —— 没有 org，就没有 admin key。

**新增的一条自动化**：`autoContinueAtUsageLimit`（managed setting）+ `/rate-limit-options`
让 Claude Code 撞限额后**自己等到 reset 再继续**（v2.1.234+）。这是原生版的"被拒后处理"。

### clauth —— 必须认真看的那一个

[uwuclxdy/clauth](https://github.com/uwuclxdy/clauth)，MIT，149★，Rust，2026-04 建、2026-09-12 仍在推。
README 自述（一手）：

- 一键在多个 Claude Code 账号间切换（OAuth Pro/Max/Team/Enterprise 或自定义 endpoint），自动识别 plan tier
- 实时 5h / 7d rate-limit 条 + 全局 token dashboard + Claude status incident feed
- **沿 fallback chain 自动切换**，带 weekly-window 和 spend-ceiling 闸门；
  opted-in 账号**排队错开启动，让各账号的 5h 窗口相隔 `5h / 账号数` 打开**
- 多账号用隔离 config dir **并行**跑
- **MCP plugin**：活着的会话可以列出/切换账号，甚至把整个 prompt（含 headless）委派给另一个账号
- `clauth daemon` 无 TUI 跑刷新 + 自动切换循环，发布 `status.json`；`--listen` 可以把这个 feed
  和账号切换**通过 HTTPS 服务给另一台机器**

**这几乎是 `fleet-account.sh` + `fleet-quotaguard.sh` + quotawatch + ccquota hub 的合集。**
差别在：clauth 是**单人单机**的账号管家，没有"N 个并行 session 各自绑哪个账号"这一层
（fleet 的 `@cc_account` / `fleet-account.sh whoami <wid>` / per-model cap 的就地 `/model` 切换）；
也没有跨机器的 fleet 视角。

**值得偷**：
- **错开 5h 窗口的启动排队**（`5h / accounts` 间隔）—— 这是个我们没有的、非常聪明的调度：
  我们目前是"撞墙才换"或"85% 才搬"，没有主动把各账号的窗口**相位错开**。
- `status.json` + `--listen` 的形态：ccquota hub 现在是自建 HTTP 服务 + viewer token，
  clauth 用同一个二进制兼做 daemon 和 server，部署面更小。

**值得避**：把账号切换做成 MCP tool 暴露给会话自己调 —— 会话可以自己换账号，
在 fleet 这种多会话环境里等于放弃了集中调度。

### ccquota 在重复什么 / 补了什么

| | 原生 / 其他开源已有 | ccquota 独有 |
|---|---|---|
| 单 session token & 成本 | ✅ `/usage`、OTEL `token.usage`/`cost.usage`、ccusage | — |
| 本机跨 session 汇总 | ✅ ccusage、`/usage`（24h/7d） | — |
| 5h / 7d 官方限额百分比 | ✅ `/usage` plan bars（仅本机、仅当前账号） | — |
| **多订阅账号池的合并视角** | ❌ 只有 clauth 接近 | ✅ |
| **跨机器汇总（mini + 笔记本）** | ❌（`/usage` 明说不含其他设备） | ✅ hub |
| **把限额喂回调度器**（autofill gate、pre-emptive switch） | 部分：`autoContinueAtUsageLimit` 是等待，不是换账号 | ✅ `FLEET_QUOTA_GATE` / 85% bench+move |

---

## 4. 自托管的共享 agent 开发环境（"一台共享机器、很多 agent、可控爆炸半径"）

| 项目 | License | ★ | 最后 commit | 一句话 |
|---|---|---|---|---|
| [coder/coder](https://github.com/coder/coder) | AGPL-3.0 | 14,447 | 2026-09-11 | 唯一成熟的"自托管多人 + agent"控制面 |
| [e2b-dev/E2B](https://github.com/e2b-dev/E2B) | Apache-2.0 | 13,767 | 2026-09-10 | agent 代码执行沙箱（面向产品内嵌，不是 dev box） |
| [dagger/container-use](https://github.com/dagger/container-use) | Apache-2.0 | 4,041 | 2026-08-12 | 每 agent 一容器 + 一 branch，MCP 接入 |
| [devcontainers/spec](https://github.com/devcontainers/spec) | CC-BY-4.0 | 5,712 | 2026-03-20 | 规范本身；稳定但不是"活跃开发" |
| [daytonaio/daytona](https://github.com/daytonaio/daytona) | 无 license 字段 | 71,722 | **2026-06-25** | ⚠️ 近 2.5 个月无 commit，且已从 dev-env 转向 "AI 生成代码的运行基础设施" |
| [coder/agentapi](https://github.com/coder/agentapi) | MIT | 1,502 | **2026-05-27** | ⚠️ 近 4 个月无 commit；给 Claude Code/Goose/Aider/Codex 套 HTTP API |

### coder/coder —— 这一格里唯一严肃的多人方案

AGPL-3.0，14.4k★，日更。`docs/ai-coder/` 下的目录结构（一手，`gh api contents`）就是它的产品边界：
`agents/`、`agent-relay/`、`agent-firewall/`、`ai-gateway/`、`ai-governance.md`、`mcp-server.md`、
`ide-agents.md`、`best-practices.md`。

从[文档](https://coder.com/docs/ai-coder)读到的关键设计：
- **Coder Agents**：*agent loop 跑在 control plane，不在 workspace 里* ——
  "the agent loop runs in the Coder control plane on your infrastructure rather than inside the
  workspace, so workspaces can be completely network isolated"。workspace 里不需要 LLM API key，
  也不需要装 agent 软件。
- **Agent Relay**：云端 agent 连回自托管 workspace，workspace 内一个 worker 进程执行 tool call。
- **Agent Firewall**（Premium）：进程级的网络 + 命令策略。
- **AI Governance**（Premium）：审计轨迹 + 策略强制。

**团队故事：满分。** 真正的 server、多用户、SSO、审计、per-workspace 隔离。
这是本次调研里唯一一个"3–8 人真的可以一起用"的基础设施。
**代价**：AGPL-3.0 + 关键的 agent 治理功能在 Premium；而且它的模型是"每人一个 workspace"，
不是"一台共享 mini 上很多 session"。

**值得偷**：*把 agent loop 移出被操作的环境* 这个方向和我们相反 —— 我们是 agent 和代码
在同一台 mini 上。如果哪天要给第二个人开账号，这是唯一严肃的参考架构。
**值得避**：为了 3 个人上一整套 control plane + Postgres + 模板系统。

### "共享 mini + 很多 agent" 这个具体形态，开源界基本是空白

- container-use / E2B 解决**隔离**，不解决**多会话调度和注意力**。
- coder 解决**多人和治理**，但假设的是每人一个 workspace、有 IT 在运维。
- Claude Code 原生有 [sandboxing](https://code.claude.com/docs/en/sandboxing)（文件系统隔离，
  允许 worktree 里的 git 写进共享 `.git`），但那是单机单会话的沙箱。

claude-fleet 的"每 fleet 一个 tmux socket（`tmux -L <session>`）作为爆炸半径护栏"
在公开资料里**没有看到第二个实现**。gastown 的 rig / claude-squad 的 instance 都共用一个 tmux server。

---

## 5. Agent 任务路由 / backlog 集成

| 项目 | License | ★ | 最后 commit | 一句话 |
|---|---|---|---|---|
| [anthropics/claude-code-action](https://github.com/anthropics/claude-code-action) | MIT | 8,857 | 2026-09-12 | GitHub PR/issue 里 @claude；跑在自己的 runner 上 |
| [github/gh-aw](https://github.com/github/gh-aw) | MIT | 5,130 | 2026-09-12 | GitHub 官方的 agentic workflow：Markdown+YAML 编译成 Actions |
| [OpenHands/OpenHands](https://github.com/OpenHands/OpenHands)（原 All-Hands-AI） | MIT | 87,688 | 2026-09-12 | 最大的开源 agent 平台，有 server 有多人 |
| [openai/codex](https://github.com/openai/codex) | Apache-2.0 | 123,640 | 2026-09-13 | Codex CLI，`vibe-kanban`/`claude-squad`/`cafleet` 都把它当第二 harness |
| [aaif-goose/goose](https://github.com/aaif-goose/goose)（原 block/goose） | Apache-2.0 | 54,174 | 2026-09-11 | 可扩展 agent，MCP 原生 |
| [MrLesk/Backlog.md](https://github.com/MrLesk/Backlog.md) | MIT | 6,716 | 2026-09-12 | Markdown-native 任务板，任务就是 git 里的文件 |
| [SWE-agent/SWE-agent](https://github.com/SWE-agent/SWE-agent) | MIT | 20,310 | **2026-07-16** | ⚠️ 学术出身（NeurIPS 2024），节奏放缓 |
| [Aider-AI/aider](https://github.com/Aider-AI/aider) | Apache-2.0 | 48,919 | **2026-05-22** | ⚠️ **近 4 个月无 commit**；**[二手]** 多份 2026 综述仍把它列为主力，与提交记录不符 |

### github/gh-aw —— GitHub 官方，和我们的 issue-as-backlog 最正面相关

一个 agentic workflow = **Markdown 正文（告诉 agent 做什么）+ YAML frontmatter（trigger、权限、
工具、engine）**，`gh aw compile` 编译成普通的 `.lock.yml` GitHub Actions workflow。
内置 engine：Copilot、Claude Code、Codex、Gemini、Pi。
**安全模型是这里最值得学的**：agent job **默认只读且沙箱化**，所有对 GitHub 的写操作
走单独的、权限收窄的 `safe-outputs` job 去校验后再落。

⚠️ 诚实标注：`>= 0.83.3, < 0.85.4` 有过一个安全公告
（[GHSA-8h78-hpm7-29gg](https://github.com/github/gh-aw/security/advisories/GHSA-8h78-hpm7-29gg)），
相关 release 已下架。

**值得偷**：`safe-outputs` 这个"agent 只读 + 写操作单独收窄权限"的二段式，比我们
"worker 自己 `gh pr merge`"安全得多。我们的 `bin/fleet-pr-verdict.sh` 是同一思路的雏形。
**值得避**：把整条链路搬到 Actions —— 我们的长跑 session（`/loop`、跨 context 的 handoff）
在 runner 的时间盒里跑不动。

### MrLesk/Backlog.md —— 和我们"issue 即 backlog"的正面对照

MIT，6,716★，日更，作者自陈"几乎全部代码由 AI agent 通过 Backlog.md 自己写的"。
核心主张（一手 README）：瓶颈不是写代码而是**人的注意力**，所以设了**三个 review checkpoint**：
审 spec → 审 plan → 审 code，并且 **"one task = one context window = one PR"**。
任务是仓库里的 Markdown 文件，完成后作为永久记录留在 git 里。

**和 claude-fleet 的差别**：它把 backlog 放**仓库内**（纯文件，天然版本化、离线、可 review），
我们放**GitHub issue**（跨仓库可见、有 assignee 做 claim 原语、有 milestone/label、
但依赖 `gh` 在线）。两者都能满足 3–8 人团队；它的优势是 review 链路更显式，
我们的优势是 assignee 天然就是并发 claim 锁。

**值得偷**："one task = one context window = one PR" 这句话应该直接写进我们的 worker charter ——
它把"任务该切多大"从直觉变成了可检查的规则。

---

## claude-fleet 的坐标

### 我们做了、这张图上其他人没做的

1. **GitHub issue 是唯一入口、且是持久的 backlog。**
   Agent Teams 的任务表是 `~/.claude/tasks/<session-派生名>/`、**本地、不上传、一 session 一 team、
   lead 不可转让、in-process teammate 不能 `/resume`**（[官方限制清单](https://code.claude.com/docs/en/agent-teams#limitations)）。
   Backlog.md 放仓库里，但没有 assignee 这种天然的并发 claim 原语。
   我们用 **issue assignee 即 claim**（`bin/fleet-claim-brief.sh` 一次 `gh` 往返读全），
   这在多会话抢任务时是正确的锁。
2. **多订阅账号池的调度。** 全网唯一接近的是 [clauth](https://github.com/uwuclxdy/clauth)（149★）。
   `fleet-account.sh migrate/whoami/quota`、85% bench+move、per-model cap 的**就地 `/model` 切换**
   （进程/后台 agent/context 全保留，~5s），这些没有第二家。
   原生只到 `autoContinueAtUsageLimit`（撞墙后等 reset），不换账号。
3. **注意力路由。** urgency-sorted windows（needs > done > working > looping > idle）、
   红 `● N` / 跨 fleet 橙 `● N`、`prefix a` 跳最急的窗口。
   **整张图里所有人都在解决"怎么并行跑"，没人解决"N 个跑着的 session 谁该先看"。**
   Backlog.md 的 README 把注意力认成了瓶颈，但它的答案是 review checkpoint，不是实时信号。
4. **每 fleet 一个 tmux socket 的爆炸半径护栏**（`tmux -L <session>`，#159）。
   claude-squad、gastown、Agent Teams 的 tmux 模式都共用一个 server ——
   官方文档甚至专门写了 "Orphaned tmux sessions" 的排障段。
5. **跨 context window 的续命**（`/fleet-handoff` + 自动 nudge）。
   原生只有 `/compact`、"resume from a summary"，没有"写一份自足的交接文档然后 `/clear` 接上"。
6. **没有常驻 orchestrator。** operator 从 hub 派活、worker 自己开 PR 自己落。
   Agent Teams 的 lead 是一个必须一直在的进程，且终身不可转让 —— 它是"会话内的团队"，
   我们是"机器上的车间"。

### 他们做了、我们没有的

1. **文件系统 / 网络级隔离。** 我们只有 git worktree + hook 守卫；
   [container-use](https://github.com/dagger/container-use) 每 agent 一个容器，
   [coder](https://coder.com/docs/ai-coder) 有进程级 Agent Firewall 且 workspace 可完全断网。
2. **Diff review UI + inline 评论回传 agent。** vibe-kanban / Sculptor / Nimbalyst 都有；
   我们的 review 全在 GitHub PR 上，没有"在同一个界面里指着某一行说这里改"。
3. **真正的多人。** 我们全部状态在一台 mini 的 tmux window options + 本地文件里；
   第二个人看不到 fleet。coder / OpenHands 有 server、SSO、审计。
4. **CI 侧 agent。** [gh-aw](https://github.com/github/gh-aw) 的 `safe-outputs`
   二段式（agent 只读 + 写操作走收窄权限的独立 job）比我们的 worker 直接 `gh pr merge` 安全。
5. **配置分发的打包。** 别人用 plugin marketplace 一条命令装；
   我们 `/fleet-sync-install` 是 git pull + 重载 daemon + 重新 merge hooks 到一台机器。
6. **跨 harness。** claude-squad / cafleet / [wshobson/agents](https://github.com/wshobson/agents)
   一份源产出 5 种 harness；我们有 `@cc_agent` 和 `Ctrl-V` 切 `claude ▸ / codex ▸`，但深度只到启动命令。

### 诚实清单：我们在重复造、而上游现在已经原生提供的

| claude-fleet 里的东西 | 原生等价物 | 差距 |
|---|---|---|
| `cw` / `dash-issue-session.sh` 建 `issue-<N>` worktree | `claude --worktree <name>`、`--worktree "#1234"`、`worktree.baseRef` | 原生不能按 issue 号命名分支、不能绑 issue；**我们的绑定语义仍有价值** |
| `hooks/base-readonly-guard.py`（base checkout 只读） | worktree 隔离的四道强制检查 | ⚠️ **原生更严**：还拦 `git -C` / `--git-dir` / `GIT_DIR` 重定向，以及"命令形状无法静态证明"就拒（不可关闭）。我们没有这几路 |
| worktree janitor（每小时，merged+clean+无 pane） | 原生 sweep：worktree 上写 marker、按 `cleanupPeriodDays` 扫、运行期 `git worktree lock` | ⚠️ **原生更安全**，marker + lock 比条件推断可靠 |
| 各 worker 自己把 `.env` 复制进 worktree | `.worktreeinclude`（gitignore 语法，只复制被 ignore 的文件） | 直接可以换掉 |
| tmux 一窗口一 session + 分屏 | Agent Teams `teammateMode: "tmux" / "iterm2" / "auto"` | 原生是 session 内、不可持久；我们的是机器级、跨天。**不重叠，但形态撞了** |
| ainbox / `fleet-comment.sh --to-worker` / issue bridge | [cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging) + Agent Teams mailbox（`~/.claude/teams/{team}/inboxes/{agent}.json`） | 原生只在同一台机器 + 同一 team；我们跨 fleet。**部分重叠** |
| 本地 token 用量代理（output×1 + input×0.25 + cache-write×0.25 + cache-read×0.02） | `/usage` 的 plan 用量条 + OTEL `claude_code.token.usage` / `cost.usage` | ⚠️ **这个代理现在基本没必要了**：`/usage` 给的是官方限额百分比，不是估算。我们的 scrape-banner 路子应该换成读 `/usage` |
| `conf/statusline.sh` 的 context mini-bar | [statusline 原生 context window usage + `prompt_cache` 字段](https://code.claude.com/docs/en/statusline) | 原生已给结构化字段，我们不必自己算 |
| haiku 分类器纠正 hook 状态 | `TeammateIdle` / `TaskCreated` / `TaskCompleted` hook（exit 2 可打回） | 只在 Agent Teams 下有；我们的 `/loop` 场景原生仍不覆盖 |
| `commands/*.md` + 五条 hook 的手工同步 | plugin marketplace（`.claude-plugin/marketplace.json`，一个 plugin 可含 commands/agents/skills/hooks/mcpServers） | 直接可以换掉，收益最大 |

### 如果只改三件事

1. **把 base-readonly-guard + janitor 换成原生 worktree 隔离与 sweep**，
   只保留 issue↔branch 的绑定语义。少维护两个自建安全件，且拿到更严的检查。
2. **把 fleet 打包成一个 plugin，走 marketplace 分发**，`/fleet-sync-install` 退化成 `/plugin update`。
   这同时解决了"第二个人怎么装"。
3. **把用量代理换成 `/usage` + OTEL**，让 ccquota 只做原生做不到的那一件事 ——
   **多订阅账号池的跨机器合并视角与主动调度**。顺带偷 clauth 的
   "各账号 5h 窗口相位错开 `5h / 账号数`"这个启动排队。

### 一句话定位

> 市面上的开源方案在解决"**怎么让多个 agent 同时跑**"，上游 Claude Code 在 2026 年把这件事做进了产品；
> claude-fleet 真正在解决的是"**一个人 / 一个小团队，在一台共享机器上，用有限的订阅配额，
> 让十几个跑了几天的 session 不失控**" —— 配额调度、注意力路由、跨 context 续命，
> 这三件事在这张图上仍然是空的。

---

<sub>调研方法：`gh api repos/*`（star / license / pushed_at / 默认分支 commit 日期）、
`gh search repos`（按 star 排序的赛道扫描）、各仓库 README 原文（`gh api .../readme` base64 解码）、
[code.claude.com/docs](https://code.claude.com/docs) 与 [platform.claude.com/docs](https://platform.claude.com/docs) 官方文档。
标 **[二手]** 的是博客/聚合文章。数据快照日期 2026-09-12/13，star 与 commit 会漂移。</sub>
