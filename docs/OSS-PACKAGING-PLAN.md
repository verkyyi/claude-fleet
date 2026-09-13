# claude-fleet + ccquota — 小团队开源方案打包计划

> 数据快照 2026-09-12/13。调研底稿：[RESEARCH-TEAMCLI.md](RESEARCH-TEAMCLI.md)、
> [RESEARCH-TEAM-AGENT-LANDSCAPE.md](RESEARCH-TEAM-AGENT-LANDSCAPE.md)。

## 结论

**拆三块发，不发整体。** 把唯一站得住的那块（跨机器配额合并视角）绑死在正在塌的
赛道（并行编排）上，是这个方案最大的风险。

定位一句话：

> 我们卖的不是「并行跑 agent」—— 上游 Claude Code 在 2026 年把这件事做进了产品。
> 我们卖的是「**一个小团队，在一台共享机器上，用有限的订阅配额，跨 Claude Code 与
> Codex 两种 agent，让十几个跑了几天的 session 不失控**」：配额调度、注意力路由、
> 跨 context 续命 —— 这三件事在整张开源图上仍然是空的。

## 一、赛道判断:并行编排正在被上游吃掉

| 项目 | star | 状态（`gh api` 核实） |
|---|---:|---|
| [vibe-kanban](https://github.com/BloopAI/vibe-kanban) | 28,064 | README 第 19 行 **"Vibe Kanban is sunsetting"**；`main` 最后 commit 2026-04-24 |
| [gastown](https://github.com/gastownhall/gastown) | 18,033 | 主干停在 7 月 |
| [claude-squad](https://github.com/smtg-ai/claude-squad) | 8,472 | 近 3 个月 6 个 commit |
| [container-use](https://github.com/dagger/container-use) | 4,041 | 近 3 个月 7 个 commit |
| [crystal](https://github.com/stravu/crystal) | 3,115 | 2026-02 改名 Nimbalyst 转闭源，repo 冻结 |
| [uzi](https://github.com/devflowinc/uzi) | 582 | 停在 2025-06-04，死了 15 个月 |

吃掉它的是 Claude Code 自己：`claude --worktree`、`.worktreeinclude`、worktree
越界的四道强制检查、marker + `git worktree lock` 的 sweep、Agent Teams
（含 `teammateMode: "tmux"`）、8 个 OTEL metrics、plugin marketplace。

**→ 不做 vibe-kanban #2。**

## 二、上游的两条结构性边界 = 我们的位置

1. **跨机器 / 跨订阅的配额合并视图。**
   [官方 costs 文档](https://code.claude.com/docs/en/costs)原文：`/usage` 的数字
   *"computed from local session history on this machine, so usage from other
   devices or claude.ai is not included"*；`/insights` 同样 *"Sessions from other
   devices and claude.ai aren't included"*。per-user 报表只有 Teams/Enterprise
   （席位制）和 Console(API) 有。
   **一队人各用个人 Pro/Max 订阅时，第一方没有任何跨机合并视图。**
   这不是没做，是归因方式决定的 —— 结构性、可持续。

2. **注意力路由。**
   整张图上所有人都在解决「怎么并行跑」，**没人解决「N 个跑着的 session 谁该先看」**。

### 受众边界(必须写进 README)

若团队上了 Anthropic 的 **Claude for Teams** 席位制，官方就有 per-user spend 报表
和 admin 限额，ccquota 价值大幅缩水。精确受众是 **「一队人各用个人 Pro/Max 订阅」**。
这真实且常见，但不是普适卖点,不许当普适卖点宣传。

## 三、三块拆分

### ① ccquota —— 立刻可独立发（成本最低、护城河最深）

已经是团队形态：endpoint = (machine, user) 对、`ccquota enroll` 每人一个、
hub 侧 `team --set` 归属（机器不能自报团队，否则能把开销挪到别人预算）、
`budget --json` 给调度器可分支的裁决、且刻意反 Goodhart（团队看板不排名）。

唯一竞品 [clauth](https://github.com/uwuclxdy/clauth)（149★ Rust，日更）覆盖了
单机多账号切换那一半，**没有跨机器合并视角**。

### ② claude-fleet —— 先瘦身，再打包，不要原样开源

现状：40,308 行 shell / 188 个脚本 / 82 个 `FLEET_*` 开关 / 54KB 安装手册。
**五个人的团队装不上。**

### ③ 团队层 —— 借 teamai-cli 的 git 模型,不自建 server

[Tencent/teamai-cli](https://github.com/Tencent/teamai-cli)（⭐4,275，MIT，TypeScript）
证明了模式成立：一个 git 仓库存配置 → MR review → SessionStart 自动 pull → 物化到
各工具原生目录。无服务端。

我们已有的、它完全没有的：**GitHub issue = backlog，assignee = claim**
（源码搜 `assign`/`backlog`/`dispatch task` 零命中）。这是多会话抢任务时的正确锁。

> ⚠️ **借模型,别抄实现**：teamai-cli 的 `pull` 有真实数据丢失 bug
> （[#532](https://github.com/Tencent/teamai-cli/issues/532)：递归删除它没安装过的
> 本地 skill 目录，含 git 追踪文件），且直接改写 `~/.claude/skills`，与 fleet 自管
> 的目录树有冲突面。

## 四、跨 agent:只做 Claude Code + Codex

### 为什么两家就够,以及为什么恰好是这两家

teamai-cli 注册了 34 个 agent CLI，但 README 只对 **11 个**逐特性打勾，
Gemini CLI / JoyCode 因为**没有 lifecycle hooks** 根本做不了自动同步 ——
它的 agent 抽象只记一个 `skillsPath`。**藏着能力分级是它最大的诚信问题。**

而 Claude Code + Codex 有一个技术上的运气（`bin/fleet-codex.sh` 头注，
codex-cli 0.154 实测）：

> **Codex 的 hook 系统就是 Claude Code 的 schema** —— 同事件名、同 stdin JSON
> （`tool_name` "Bash" 带 `tool_input.command`，"apply_patch" 带 patch 文本）、
> exit 2 阻断、hook 继承 pane env 含 `$TMUX_PANE`。

所以中立层里**最难的那块（实时状态信号）在两家都是原生一等**，不用退化到 pane
内容 checksum 启发式。这是收窄到两家的技术理由，不只是省事。

### 中立性分层(按我们栈的实际代码核过)

| 层 | 中立性 | 依据 |
|---|---|---|
| git worktree + 分支命名 | **100%** | 就是个目录 |
| GitHub issue = backlog / assignee = claim / PR = review | **100%** | 跑的是 `gh`，不是 agent |
| tmux window = session + 每 fleet 一 socket 的爆炸半径隔离 | **100%** | 就是个进程待在 pane 里 |
| 注意力路由**渲染**（urgency 排序、glyph、红点） | **100%** | 读 tmux window option |
| 注意力**信号源** | **两家都一等** | hook schema 相同 |
| context % / handoff | 适配层，Codex 缺 | Codex 无可读 transcript 等价物 |
| 配额裁决 | 适配层，**接口中立** | fleet 只问「还有余量吗」→ yes/no |
| 配置物化 | 适配层 | 各家路径与能力不同 |
| memory | 存储中立，装载适配 | markdown 文件天然可移植 |

**设计规则：接缝放在「裁决」和「option」上,不放在「数据」上。**
已经做对了一半 —— `@claude_state` 就是这个接缝（**应改名 `@agent_state`**）；
`budget --json` 给 yes/no 而非 token 数，这是对的，别改。

### 适配器能力矩阵(公开声明,不许藏)

`FLEET_AGENT=codex` 路径（issue #547）已实现的与未实现的，逐条来自 `bin/fleet-codex.sh`：

| 能力 | Claude Code | Codex | 备注 |
|---|:--:|:--:|---|
| worktree / `@issue` 绑定 / claim-at-spawn / PR map / cleanup / session cap | ✅ | ✅ | 「worker 路径其余部分本来就 agent-agnostic」 |
| hook 状态信号 → dash 上色 | ✅ | ✅ | 同 schema；`-c hooks.<Event>=[…]` 内联到本 install 路径 |
| 两条 bypass-permissions 护栏 | ✅ | ✅ | `--dangerously-bypass-approvals-and-sandbox` + `--dangerously-bypass-hook-trust` |
| 项目文档 | CLAUDE.md | AGENTS.md | `project_doc_fallback_filenames` 让 Codex 读 CLAUDE.md |
| slash command 种子 | 原生展开 | 转译 | Codex 无 slash；`conf/codex-preamble.md` + `commands/<name>.md` 展开成散文 |
| SessionEnd 关窗 | ✅ | ❌ | Codex 每次结束都报 `reason=other`，分不出 `/exit` 与 `/clear` → 退化到 cleanup daemon 轮询 |
| `/fleet-handoff` + 自动 nudge | ✅ | ❌ | 读 Claude transcript |
| `/fleet-context` + dash ctx % | ✅ | ❌ | 同上 |
| 账号轮转 / 配额采集 | ✅ | ❌ | Codex 认证是 `codex login`，无 `CLAUDE_CODE_OAUTH_TOKEN` 等价物 |
| per-model cap 就地 `/model` 切换 | ✅ | ❌ | Codex 模型名 ≠ Claude alias；`FLEET_CODEX_MODEL → -m` |
| Stop 分类器 | ✅ | ❌ | 读 Claude transcript |
| MCP 配置 / subagent model | ✅ | ❌ | 有意跳过 |

**两条真缺口**（值得当 roadmap 写出来，而不是含糊过去）：
1. **跨 context 续命在 Codex 上没有** —— 而这是我们三个差异化之一。
2. **配额治理在 Codex 上没有** —— Codex 的额度模型与 Claude 订阅不同构，
   跨 provider 只能靠**裁决接口**中立，数据层各做各的。

## 五、配置共享管线

一个 source-of-truth git 仓库 → MR review → 物化到各 agent 原生目录。

**Claude Code 的 plugin 只是物化目标之一,不是分发机制本身。**
（这修正了本方案早期的一个错误建议：「打成 plugin 走 marketplace」会加深单 agent
绑定。plugin 的便利要拿，绑定不要。）

- Claude Code target：plugin（commands/agents/skills/hooks/mcpServers 一并），
  `/plugin update` 顺带拿到 SessionStart 自动更新
- Codex target：AGENTS.md + `~/.codex/config.toml` + 内联 `-c hooks.*`

## 六、本地 MEMORY → 团队 MEMORY

### 实测样本(本 repo 的 memory 目录,29 条 / 128K)

```
20  type: project
 6  type: feedback
 3  type: reference
```

**关键发现：现有的 4 种 `type:` 不能用来判断能否共享 —— 它是错的轴。**

- `type: project` 里既有 `run-selftests-needs-devnull-stdin`（纯工具坑，全队都该
  知道）、`tmux-34-escapes-control-bytes-in-formats`（上游 bug 事实），
  **也有** `fleet-autofill-armed`、`fleet-deploy-state-confs`（这台机器的 armed
  状态，共享出去就是错的）
- `type: feedback` 里既有 `operator-ipad-tap-first`（纯个人偏好），
  **也有** `artifact-blocked-use-doc-preview`（普适工具约束，全队适用）

粗数约 **60% 可共享 / 40% 不能**。

### 泄密面是真实的,不是理论风险

- `ccquota-hub-and-peer-channel` 直接写了 `CCQUOTA_VIEWER_TOKEN` 与其文件路径
- `account-rotation-*` 含订阅账号邮箱
- ccquota 自己的 README 已认过同类问题：dashboard 不可分享，因为
  *"project paths (which are client names)"*

**→ review gate 是必需的,不是可选的。** 恰好又是 git + MR，与配置共享同一条管线。

### 设计:正交的 `scope:` 轴 + 晋升管线

```yaml
---
name: run-selftests-needs-devnull-stdin
description: ...
metadata:
  type: project            # 保留:是什么
  scope: team              # 新增:能给谁 —— personal | machine | team
---
```

管线：本地 memory 照常累积 → 打 `scope: team` 的走 `memory promote` 开 MR →
合并进团队仓库 → 各人 SessionStart 与团队 memory 一并装载。
**个人的那 40% 永远不出本机。**

跨 agent：memory 是 markdown，**存储天然可移植**，不中立的只有「物化到哪、谁会在
session start 自动读」—— 与 skills 同一个适配问题，不是新问题。

> 附带收益：**团队 memory 本质上就是「还没来得及写进 CLAUDE.md 的那些 repo 事实」**。
> 晋升流程给了口口相传的知识一个变成文档的出口。

## 七、瘦身清单(原生已覆盖,该删)

| fleet 里的东西 | 原生等价物 | 处置 |
|---|---|---|
| `hooks/base-readonly-guard.py` | worktree 隔离的四道强制检查 | **删**。原生更严：还拦 `git -C` / `--git-dir` / `GIT_DIR` 重定向，且不可关闭 |
| worktree janitor（每小时） | marker + `git worktree lock` 的定期 sweep | **删**。原生更安全，marker+lock 比条件推断可靠 |
| 各 worker 手工复制 `.env` 进 worktree | `.worktreeinclude` | **换** |
| 本地 token 用量代理 | `/usage` 官方百分比 + OTEL | **换**。OTEL 中立可留，`/usage` 仅作 Claude 适配器 |
| `conf/statusline.sh` 自算 context | statusline 原生 context + `prompt_cache` 字段 | **换** |
| `commands/*.md` + 五条 hook 手工同步 | plugin（作为物化目标） | **换**，收益最大 |

保留：**issue↔branch 绑定语义**（原生没有，是真价值）。

## 八、该偷的(按性价比)

1. **[clauth](https://github.com/uwuclxdy/clauth) 的相位错开** —— 各账号 5h 窗口按
   `5h / 账号数` 错开启动。我们没做，纯赚。
2. **SessionStart 自动更新** —— 用 `/plugin update` 实现，别抄 teamai-cli 的 `pull`。
3. **teamai-cli 的双 anchor worktree 检测**
   （`git worktree list --porcelain` 首条 vs `rev-parse --show-toplevel`）。
   附带两条硬事实：没有 AI 工具会顺 `git-common-dir` 回溯主 checkout；
   gitignored 文件不出现在新 worktree 里。
4. **friction 评分的 Stop hook**（打断 / 拒绝工具 / 失败重试计分，每 session 最多提示
   一次）—— 比纯 ctx% 的 handoff 触发聪明。原生 `/insights` 已做类似的事，可先白嫖。
5. **[gh-aw](https://github.com/github/gh-aw) 的 `safe-outputs` 二段式**
   （agent 只读 + 写操作走收窄权限的独立 job）—— 比 worker 直接 `gh pr merge` 安全。
6. **成本账本不变量**（teamai-cli）：价格表带版本戳、存整数 micro-dollar、
   **改表后绝不重算历史**。

## 九、非目标

- 不做第 3 个 agent 适配（Gemini CLI 等）直到 Claude+Codex 两家都到位
- 不自建团队 server / SSO / 审计 —— GitHub 就是协调基座
- 不做容器 / 网络级隔离（container-use、coder 做得更好）
- 不做 diff review UI —— review 留在 GitHub PR
- 不拿 star 数当成功指标：`obra/superpowers` 285,822★ 无 eval harness，
  `microsoft/skills` 3,011★ 有 CI eval harness。**skills 类目里 star 是社交货币,
  不是质量信号。** 用 `claude plugin eval` 通过率。

## 十、共享 mini 的正确形态

**N 个 OS login,不是一个 login 跑 N 个 fleet。**
tmux socket 本来就 per-uid；ccquota 明确要求每个 OS login 一个 agent
（*"on most systems it could not read the others anyway"*）。
现在共用一个 login 的话，**配额归因是错的**。这是配方不是代码，但必须先改。

## 十一、可执行 issue 拆分

**P0 — 先让两个 agent 对等**
1. `@claude_state` → `@agent_state` 改名（接缝正名，纯机械改动）
2. 适配器能力矩阵落进 README，公开声明分级（反 teamai-cli 的藏匿）
3. mini 改 N 个 OS login + 每人一个 ccquota enroll token

**P1 — 瘦身（每条一个 issue）**
4. 删 `base-readonly-guard.py`，切原生 worktree 检查
5. 删 janitor，切原生 marker + `git worktree lock` sweep
6. `.env` 复制 → `.worktreeinclude`
7. 用量代理 → OTEL（中立）+ `/usage`（Claude 适配器）
8. `commands/*.md` + hooks → plugin 物化目标

**P2 — 团队层**
9. memory frontmatter 加 `scope:` 轴 + 全量回填分类
10. `memory promote` 命令 + MR 模板 + 密钥扫描 gate
11. 配置 source-of-truth 仓库 + 双 target 物化（plugin / AGENTS.md）

**P3 — 补 Codex 缺口**
12. Codex 的 context % 与 handoff（需先解决无 transcript 的读取问题）
13. 配额裁决接口中立化，Codex provider 适配

**P4 — 偷来的**
14. clauth 相位错开
15. friction 评分 Stop hook
16. 双 anchor worktree 检测
