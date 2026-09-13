# claude-fleet + ccquota — 小团队开源方案打包计划

> 数据快照 2026-09-12/13。调研底稿：[RESEARCH-TEAMCLI.md](RESEARCH-TEAMCLI.md)、
> [RESEARCH-TEAM-AGENT-LANDSCAPE.md](RESEARCH-TEAM-AGENT-LANDSCAPE.md)。

## 结论

**拆三块发，不发整体。** 把唯一站得住的那块（跨机器配额合并视角）绑死在正在塌的
赛道（并行编排）上，是这个方案最大的风险。

定位一句话：

> 我们卖的不是「并行跑 agent」—— 上游 Claude Code 在 2026 年把这件事做进了产品。
> 我们卖的是「**一个小团队，用手上有限的几份订阅，跨 Claude Code 与 Codex 两种 agent，
> 让十几个跑了几天的 session 不失控、且没有一份额度闲置**」：
> 配额编排、注意力路由、跨 context 续命 —— 这三件事在整张开源图上仍然是空的。

其中**配额编排是最直接的成本卖点**：创业团队统一采购 N 份订阅、**订阅归 TEAM
不归个人**，池化 + 动态编排把「各自撞墙、各自闲置」变成一个整体额度池。而「Claude 池耗尽 → 溢出到 Codex」的
跨 provider 编排，整张 landscape 图上没有第二家 ——
**双 agent 不是为了兼容性好看,是为了让两家的订阅额度互为溢出池。**
详见[四之二](#四之二配额编排团队额度池核心卖点)。

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

精确受众：**统一采购 N 份订阅、池化给全队用的小创业团队(3–8 人)**。
订阅归 TEAM 不归个人，成本由公司承担，成员从池子里取用。

若团队改用 Anthropic 的 **Claude for Teams** 席位制，官方就有 per-user spend 报表
和 admin 限额，ccquota 的价值大幅缩水 —— 但见
[成本对照](#风险登记--成本对照不阻塞设计)：按每美元额度算，席位制未必划算。

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

## 四之二、配额编排:团队额度池(核心卖点)

**一支小队手上有 N 份订阅,现状是各自撞墙、各自闲置。** 池化 + 动态编排把它们变成
一个整体额度池 —— 这是本方案对小团队最直接的成本价值,也是整张 landscape 图上
没人做完整的一块。

### 为什么池化能省钱:并发上限来自订阅数,不是机器数

关键机制（ccquota README 实测）：**Claude Code 按 process 读 `CLAUDE_CODE_OAUTH_TOKEN`**，
所以一台机器上并排的多个 session 可以跑在不同订阅上 —— 开发机上实测同时跑三份。

于是一台共享 mini 的有效并发不由机器决定，由池里的订阅数决定：

```
单份 Max：5h 窗口撞顶 → 整台机器的 fleet 停摆,等 reset
N 份池化：任一份撞顶 → 新 spawn 落到还有余量的那份,fleet 不停
```

对 3–8 人的小队，这是「买 8 份 Pro 各自闲置」与「池化后跑满」的差别。

### 四条机制

| # | 机制 | 状态 |
|---|---|---|
| ① | **token 池 + owner 标签** —— 池化但仍按人归因 | 池已有（`~/.config/claude-fleet/accounts/<label>`）；**owner 元数据是缺口** |
| ② | **相位错开**：N 份账号的 5h 窗口按 `5h / N` 错开启动 | **缺口。偷 clauth** |
| ③ | **跨 provider 溢出**：Claude 池耗尽 → Codex 池 | **缺口。真正的头条** |
| ④ | **公平份额**：争用时按贡献 plan 定优先级 | **缺口。全图无人做** |

#### ① 订阅归团队,归因仍要保留(但换了目的)

**订阅由团队统一采购、统一归属 TEAM,不归因到个人** —— 这是创业团队的实际形态，
也让「谁出的额度」这个问题消失了。但归因本身不能取消，只是目的变了：

| 轴 | 目的 | 是否排名 |
|---|---|---|
| **按 team** | 预算、成本核算 | 是，这是要看的数 |
| **按 person** | 只为发现异常（某个 `/loop` 在吃全队额度） | **否,刻意不排名** |

**ccquota 已经正好是这个模型**，不用另造：

- `ccquota team --endpoint <id> --set <team>` 把开销归到团队
- **归属只能在 hub 侧设定,endpoint 永不自报** —— 否则一台机器可以把自己的开销
  挪到别的团队预算上
- 团队在**查询时**解析而非写死在每条记录上，所以重新归属会移动**整段历史**
- 一旦有团队归属，dashboard 以团队维度打头，每个 OS login 有自己的 `/u/<login>` 页，
  **两者都刻意不带排名** —— ccquota README 自己写明：当成人均绩效榜会因 Goodhart
  失效（人们要么躲着不用，要么刷量），两种结果都会毁掉它存在的意义（提供成本数据）

缺口只剩一个：**给池里的每个 token 打标签**，让「这轮任务烧的是池里哪一份订阅」
可查 —— 不是为了向谁结算，是为了知道池子里哪一份先见底、相位错开该怎么排。

没有这一层，池化会退化成公地悲剧 —— 这是比合规更现实的失败模式。

#### ② 相位错开

池子越大收益越明显：8 份账号若同时启动，5h 窗口会同时耗尽同时 reset，
出现整段空窗。按 `5h / 8 = 37.5min` 错开首次启动，池子的可用余量就被摊平成一条直线。

#### ③ 跨 provider 溢出 —— 双 agent 的真正商业价值

```
现在：Claude 账号 A 满 → 换账号 B → 池空 → bench
加后：Claude 账号 A 满 → 换账号 B → 池空 → 换 Codex 池 → 都空 → bench
```

配额治理最接近的 [clauth](https://github.com/uwuclxdy/clauth)（149★）只在 Claude
一家内部切账号。**跨 provider 的动态编排没有第二家。**

这才是「不仅支持 Claude，还支持 Codex」的商业价值：
**双 agent 不是为了兼容性好看,是为了让两家的订阅额度互为溢出池。**

⚠️ 技术前置：Codex 侧无账号轮转（认证是 `codex login`，无 token env 等价物，
见[适配器能力矩阵](#适配器能力矩阵公开声明不许藏)），所以这一级是「换 agent」，
不是「换 Codex 的第 N 个账号」。要做 Codex 侧池化，得先解决多 `~/.codex` home
的切换。

#### ④ 争用策略:按工作优先级,不按出资

订阅归团队之后，「谁贡献了什么 plan」不再是问题 —— 池子空了该让谁先跑，
变成一个纯粹的**调度**问题。全图没人做过。

两条正交的策略，建议都做：

1. **按工作优先级分配** —— backlog 里已有的 `p0/p1/p2` 标签直接当池子的优先级。
   池子紧张时 p0 先拿，p2 排队。这条几乎免费：优先级数据已经在 issue 上。
2. **人均熔断** —— 单个 OS login 在一个 5h 窗口内最多吃池子的 X%，防止一个
   跑飞的 `/loop` 把全队额度清空。这是池化模型里**唯一必要的人均限制**，
   而且它是熔断器不是配额，不构成绩效排名。

> 注意这两条都**不需要**知道谁出的钱 —— 订阅归团队，调度只看「这活多急」和
> 「这个人是不是跑飞了」。

### 风险登记 + 成本对照(不阻塞设计)

**风险**：供应商条款禁止跨人共享账号凭据（[Anthropic 消费者条款](https://www.anthropic.com/legal/consumer-terms)
明文；OpenAI 对 Plus/Pro 同）。团队统一采购但注册在个人邮箱下的订阅同样落在这一条里。
**团队自担,不作为本方案的设计约束。**

**成本对照(值得在 README 里算清楚,因为这是卖点的底气)**：
官方的团队方案是席位制（Claude for Teams / ChatGPT Business），每席位额度较低；
而 Max 档的额度倍率远高于席位价差。**按「每美元可用额度」算,少数几份 Max 池化
通常显著优于同价位的 N 个席位** —— 这大概率才是本方案真正的经济学，
而不是「省掉几个席位费」。

⚠️ 上线前用**当期实际定价**重算一遍再写进 README；定价与额度倍率都会变。

唯一仍待决：公开 README 的措辞 —— 中性的「团队账号池 / team account pool」
还是「共享队友订阅」。这是产品定位选择，见[非目标](#九非目标)。

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

## 十一、执行与落地

### 排序原则

1. **先证伪,再开发。** 最贵的假设用最便宜的方式先验，否定了就省下几个月。
2. **先用做完的那块试水。** ccquota 已公开、已是团队形态、0 star ——
   用它测市场，再决定要不要投几个月改 fleet。
3. **开发可并行,落地必须串行。** 瘦身那几条动的是你每天在用的机器。

### 跨仓库的操作性前提

23 条跨三个仓库，而 **fleet 是一 session 一 repo**：

| 仓库 | 涉及 issue | 起法 |
|---|---|---|
| `verkyyi/claude-fleet` | 大多数 | 已有 fleet |
| `verkyyi/ccquota` | 18（归因）、M1 全部 | **需要 `bin/fleet-up.sh verkyyi/ccquota` 起第三个 fleet** |
| 团队 config repo | M4 | 还不存在，M4 时新建 |

---

### M0 — 先证伪(约半天,零代码)

三条全是查证。**任何一条被否定都会改变后面的路线**，所以必须在写代码前做完。

| # | 要验什么 | 否定了会怎样 |
|---|---|---|
| 22 | 用**当期定价**重算「N 份 Max 池化 vs N 个席位」的每美元可用额度 | 成本卖点的措辞要重写；若席位制更划算，整个 ccquota 定位塌一半 |
| — | 复验「一机多 token 并发」：ccquota 当年实测同跑三份，**现在还成立吗** | 这是池化省钱的**物理前提**。不成立则 M2 整个作废 |
| — | 原生 worktree 的四道检查**是否真覆盖**我们 `base-readonly-guard.py` 的威胁模型 | 决定 #4 能不能删。**不成立就别删**——那是在用文档承诺换掉一个在跑的安全件 |

### M1 — 用已经做完的那块试水(1–2 天)

ccquota 不需要等 fleet。它已经公开、已经有 `team --set` 的团队归属模型、
已经是 hub/agent 架构。要做的只是**把 README 主线从「用量监控」换成
「团队订阅池的成本可见性」**，然后发出去。

- 改 README 开头与 Why 段，主线换成 M0 算出来的成本对照
- 受众边界照[第二章](#受众边界必须写进-readme)写清楚
- 发一次（HN / X / 相关 subreddit 任选），看有没有人接

**这一步的价值是信息,不是代码**：花 1–2 天知道市场在不在，比闷头改三个月 fleet 划算。

### M2 — 让池子真的成为池子(核心差异化)

这组是方案的卖点，**hands-on,不要 autofill** —— 每条都含调度判断。

```
18 池内 token 打标签 + 接 ccquota team --set   ← 先做,其余都要读这个标签
     ↓
19 相位错开 5h/N          20 争用策略(p0/p1/p2 + 人均熔断)
     ↓
17 跨 provider 溢出 → Codex   ← 头条功能,可先上「换 agent」版
     ↓
21 Codex 侧多 ~/.codex home 池化   ← 17 的完整版前置,可延后
```

### M3 — 让第二个人装得上

| 批次 | issue | 并行? |
|---|---|---|
| 先单独跑 | 1 `@claude_state` → `@agent_state` | **必须独占** —— 碰所有文件，和任何人并行都会冲突 |
| 然后 | P0#3 mini 改 N 个 OS login | 独立，但要停机窗口 |
| 瘦身 | 4 删 base-readonly-guard · 5 删 janitor · 6 `.worktreeinclude` · 7 用量代理→OTEL · 8 → plugin | 开发并行（可 autofill），**落地一条一条来** |
| 收尾 | 2 能力矩阵进 README | 随时 |

⚠️ **瘦身的落地纪律**：每条 land 后 `/fleet-sync-install` + 冒烟，确认 fleet 没炸再 land 下一条。
这几条删的是安全件和守护进程，串行落地 + 每步可回滚，比一次推五条省事得多。

### M4 — 团队层

9 `scope:` 轴 + 10 `memory promote` + 11 config repo 双 target 物化。
新建第三个仓库时再起对应 fleet。

---

### 并行策略:哪些能丢给 autofill

memory 记着 autofill 已在两个 fleet armed（打 `autofill` 标签 → 有空位就自动起
worker+PR），全局 cap 10。

| 适合 autofill | 必须 hands-on |
|---|---|
| 6 `.worktreeinclude`、7 OTEL、8 plugin 物化 —— 机械、边界清楚 | M0 三条（是判断，不是实现） |
| 2 能力矩阵进 README | M2 全部（含调度判断） |
| 12 Codex context %（探索性但独立） | 1 rename（独占）、4/5（删安全件，要人来判断） |

### 完整 issue 索引

**M0** 22（定价重算）+ 两条复验（待建 issue）
**M1** ccquota README 主线重写（待建 issue）
**M2** 17 跨 provider 溢出 · 18 token 标签+team 归因 · 19 相位错开 · 20 争用策略 · 21 Codex 池化
**M3** 1 `@agent_state` 正名 · 2 能力矩阵进 README · 3 mini 改 N 个 OS login ·
4 删 base-readonly-guard · 5 删 janitor · 6 `.worktreeinclude` · 7 用量代理→OTEL ·
8 commands+hooks→plugin
**M4** 9 `scope:` 轴 · 10 `memory promote`+密钥扫描 · 11 config repo 双 target 物化
**其他** 12 Codex context%/handoff · 13 配额裁决接口中立化 · 14 clauth 相位错开 ·
15 friction Stop hook · 16 双 anchor worktree 检测 · 23 README 措辞决策

> 14 与 19 是同一件事（clauth 的相位错开），建 issue 时合并。
