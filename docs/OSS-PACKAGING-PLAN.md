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

所以中立层里**大部分状态信号在两家都是原生一等**，不用退化到 pane 内容 checksum
启发式。这是收窄到两家的技术理由，不只是省事。

> ⚠️ **一个重要例外（#608 查证纠正，2026-09-13）：`needs` 信号在 Codex 上不存在。**
>
> **Codex 没有 `Notification` 事件。** 0.154 的 hook 集是 PreToolUse ·
> PermissionRequest · PostToolUse · Pre/PostCompact · SessionStart · SessionEnd ·
> UserPromptSubmit · SubagentStart/Stop · Stop · Interrupt —— 最接近的
> `PermissionRequest` 在 fleet 的 bypass 姿态下根本不会触发。
>
> 后果：**一个停下来等你回答的 Codex worker,在 dash 上显示为绿色 `done`**，
> 和任何正常结束的回合一模一样。
>
> 这打在要害上 —— 注意力路由是我们三个差异化之一，而它**恰恰在最有价值的那个信号
> （红色 `needs` + 响铃）上于 Codex 侧完全失效**。`working` / `done` 两家对等，
> `needs` 不对等。宣传跨 agent 时必须明写这一条。

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

### 适配器能力矩阵(公开声明,不许藏) ✅ 已上线 2026-09-13

> [#608](https://github.com/verkyyi/claude-fleet/issues/608) → PR #615 已合并并同步上线。
> README 现有完整矩阵，且**由 CI 守着不漂**：表是从 `bin/fleet-codex.sh` 旁的
> `MATRIX` 块生成的，`bin/codex-matrix.sh --check` 在 CI 里失败于任何漂移。
>
> 矩阵还区分了两类 ❌，这个区分很重要：
> - **Codex 的限制** —— 例如无 `Notification` 事件、`SessionEnd` 永远 `reason=other`
> - **我们的适配器缺口** —— 例如 `/fleet-handoff`：*"the mechanism is not missing
>   on Codex, the adapter is"*；MCP：*"Deliberately skipped, **not** a Codex limit"*


`FLEET_AGENT=codex` 路径（issue #547）已实现的与未实现的，逐条来自 `bin/fleet-codex.sh`：

| 能力 | Claude Code | Codex | 备注 |
|---|:--:|:--:|---|
| worktree / `@issue` 绑定 / claim-at-spawn / PR map / cleanup / session cap | ✅ | ✅ | 「worker 路径其余部分本来就 agent-agnostic」 |
| hook 状态信号 → dash 上色 | ✅ | ✅ | 同 schema；`-c hooks.<Event>=[…]` 内联到本 install 路径 |
| 两条 bypass-permissions 护栏 | ✅ | ✅ | `--dangerously-bypass-approvals-and-sandbox` + `--dangerously-bypass-hook-trust` |
| 项目文档 | CLAUDE.md | AGENTS.md | `project_doc_fallback_filenames` 让 Codex 读 CLAUDE.md |
| fleet command 种子 | 原生展开 | 原生 skill | Codex 从 `$CODEX_HOME/skills/<name>/SKILL.md` 触发 `$fleet-claim`；旧版/未同步 home 才回退到 `conf/codex-preamble.md` + `commands/<name>.md` |
| SessionEnd 关窗 | ✅ | ✅ | Codex thread end 仍不关窗；launcher 等 CLI 成功退出后走共享 close-on-exit |
| `/fleet-handoff` + 自动 nudge | ✅ | ✅ | Codex 直接跑 transfer/controller 脚本；自动 nudge 走同一条 native handoff path |
| `/fleet-context` + dash ctx % | ✅ | ✅ | SessionStart 记录 Codex UUID/CODEX_HOME，rollout token telemetry 提供读数 |
| 账号轮转 / 配额采集 | ✅ | ✅ | 多 CODEX_HOME + native quota collector；认证仍是 `codex login` |
| per-model cap 就地 `/model` 切换 | ✅ | ✅ | Codex 用 native thread/settings/update；显式 limit-id 映射后验证 |
| Stop 分类器 | ✅ | ✅ | 共享 Stop hook + agent-aware rubric；native attention / explicit blocker 优先 |
| MCP 配置 / subagent model | ✅ | ✅ | `FLEET_MCP_CONFIG`/`FLEET_CODEX_MCP_CONFIG` 转成 Codex policy；subagent knobs 独立 |

> 历史备注：本计划早期把「Codex 跨 context 续命」和「Codex 配额治理」
> 视为真缺口；后续实现已经补上，当前能力以 `bin/fleet-codex.sh` 的
> MATRIX block 和 README 生成表为准。

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

#### ② 相位错开 ✅ 已完成 2026-09-14（PR #617）

> **实施时挖出一个更根本的 bug：池子根本没在轮着用。**
> 旧排名把 5h 与 7d 当同一份预算比（`100 - max(5h,7d)`），于是 **5h 窗口一点没用过**
> 的账号得分反而更低：
> ```
> ly297@georgetown.edu     5h  0% · 7d 80%   headroom 20   ← 整个 5h 窗口闲置
> verky@24helpful.com   ●  5h 77% · 7d 51%   headroom 23   ← 每次 spawn 继续堆这里
> ```
> 新排名 `5h余量×2 + 7d余量` → 同样两行变成 **220 vs 95**。
> 依据：**5h 窗口过期作废**，没花完的部分在 reset 时蒸发；周额度只是放在那里。
> 上线后 `●` 当即从 `verky@24helpful` 移到 `ly297`。
>
> 分层安全取向（派工时明确要求不自落、留给操作员 review）：排名修正默认生效
> （正在流血的伤口，且仍受 `CEILING` 门控）；相位 hold 需 `phase --plan --apply`
> 主动武装；quotawatch 自动重排默认关；hold 永远 fail-open（两遍 `pick_active`）。
> 一行回滚 `FLEET_ACCOUNT_PICK=minmax`。
>
> **上线后实测（2026-09-14，三个 fleet 共 12 个 worker 窗口的账号分布）：**
> ```
> 修复前   17 verky@24helpful · 1 verky.yi · 1 ly297     ← 全压在一份上
> 修复后    7 ly297 · 5 verky@24helpful · 1 verky.yi      ← 真的在轮着用
> ```
> 同期 `ly297` 的 7d 用量从 8% 涨到 17%（此前四小时纹丝不动），`●` 也移了过去。
> **排名修正是有效的,不只是理论上更对。**
>
> ⚠️ 未验证路径（PR 自陈）：quotawatch 自动重排块没在真实 daemon tick 跑过；
> `migrate` 只做代码推理未实跑；相位的真实收益要一整个 5h 周期才看得出。


池子越大收益越明显：8 份账号若同时启动，5h 窗口会同时耗尽同时 reset，
出现整段空窗。按 `5h / 8 = 37.5min` 错开首次启动，池子的可用余量就被摊平成一条直线。

#### ③ 跨 provider 溢出 —— 双 agent 的真正商业价值

2026-09-17 源码复核与实施边界见[订阅额度续接方案](SUBSCRIPTION-FAILOVER-PLAN.md)：
复用 ccquota、fleet-account、quotawatch、migrate、transfer 和 loop，扩展到运行中
会话及 Claude ⇄ Codex 两个方向。以下是目标行为，跨类自动切换尚未完成。

```
现在：Claude 账号 A 满 → 换账号 B → 池空 → bench
目标：当前 Agent 的账号 A 满 → 同类账号 B → 跨 Agent 可用账号 → 都不可用则等待
```

配额治理最接近的 [clauth](https://github.com/uwuclxdy/clauth)（149★）只在 Claude
一家内部切账号。**跨 provider 的动态编排没有第二家。**

这才是「不仅支持 Claude，还支持 Codex」的商业价值：
**双 agent 不是为了兼容性好看,是为了让两家的订阅额度互为溢出池。**

技术前置已缩小：ccquota 已提供 Codex 多 profile 登录、独立 home 和额度查询；
Fleet PR #747 已记录准确的 Codex UUID/home/rollout 并支持恢复及上下文续接。
剩余工作是接入 Fleet 账号策略、固定迁移目标、补 Codex 换订阅和反向交接，以及
额度受阻状态下的循环续接。不能仅设置新 home 后假定旧会话可以原生 resume。

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
  `/plugin update` 替代手工 copy+merge ✅ **已上线（#611，PR 见下）**
- Codex target：AGENTS.md + `~/.codex/config.toml` + 内联 `-c hooks.*`
  ✅ **hook 表已同源**（`bin/fleet-hooks-emit.sh` + `hooks/codex-map.json`）

> ⚠️ **更正一条早期记述：「plugin 白拿 SessionStart 自动更新」是错的。**
> 实测（claude 2.1.x）：自动更新是 **marketplace 级**、第三方 marketplace **默认关**，
> 要在 `settings.json` 的 `extraKnownMarketplaces` 里显式 `"autoUpdate": true`；
> 开了之后更新在会话启动后延迟若干分钟落地，且 **只对下一个会话生效**，不改当前会话。
> 另外 `enabledPlugins` 单独不会拉取外部源 —— 新机器第一次仍要跑一次
> `claude plugin install`。所以它封的是「**别人**的机器忘了同步」，不是「**这个**会话
> 立刻拿到新版」。
>
> 真正白拿的是 **版本号**：plugin.json 不写 `version` 时，安装版本就是 marketplace 的
> commit sha（实测 `frontend-design` 装成 `da823e86c8fe`），于是每个合并的 commit 都是
> 新版本，`/plugin update` 必定落地 —— 不需要任何人记得 bump。

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

## 七、瘦身清单 —— 大部分已被证伪(2026-09-13)

> ⚠️ **本章原本是方案里最大的工作量来源,查证后大幅缩水。**
> 调研 agent 报告的「原生更严 / 原生更安全」比错了对象。

### 根因:我们的 worktree 不是 Claude Code 建的

[官方 worktree 文档](https://code.claude.com/docs/en/worktrees)原文：

> The sweep leaves a worktree in place in these cases: … **You created the
> worktree yourself with `git worktree add`**, even if you then ran a
> `--worktree <name>` session in it and backgrounded that session.
>
> Claude Code writes a marker into the git metadata of every worktree it creates
> with git, and **the sweep keeps any worktree without one**.

`.worktreeinclude` 同样只适用于 *"every worktree **Claude Code creates** with git:
`--worktree` worktrees, subagent worktrees, and parallel sessions in the desktop app"*。

我们的 worktree 由 `cw` / `dash-issue-session.sh` 用 `git worktree add` 建 —— 无 marker。
**所有原生 worktree 机制按设计都不认它们。**

这是个二选一，不能逐条绕过：

| 路线 | 代价 |
|---|---|
| **保留自建 worktree 管理**（现状） | 自己维护 guard + janitor + env 复制 |
| 改用 `claude --worktree` spawn | 失去 `issue-<N>` 分支命名与 issue 绑定 —— 而这正是我们的核心价值 |

### 逐条结论

| 原计划 | 结论 |
|---|---|
| 删 `hooks/base-readonly-guard.py` | ❌ **废**。威胁模型不同（原生防「session 越出自己的 worktree」，我们防「任何人编辑 base checkout」），且 hub/scratch 本就跑在 base 里、无 worktree 边界可言；还兼管 Codex 的 `apply_patch` |
| 删 worktree janitor | ❌ **废**。原生是**按年龄**（`cleanupPeriodDays`）扫它自己建的 worktree；我们是**按合并态 + 存活态**扫所有 worktree。见下方判据对照 |
| `.env` 复制 → `.worktreeinclude` | ❌ **废**。原生只处理它自己建的 worktree |
| 本地 token 用量代理 → `/usage` + OTEL | ✅ **仍有效**。与 worktree 来源无关。OTEL 中立可留，`/usage` 仅作 Claude 适配器 |
| `conf/statusline.sh` 自算 context | ✅ **仍有效**。原生已给结构化 `prompt_cache` 字段 |
| `commands/*.md` + 五条 hook → plugin | ✅ **仍有效,且收益最大**。与 worktree 无关 |

### janitor 判据对照(为什么原生替不了)

`bin/worktree-autoclean.sh` 删一个 worktree 要求**同时**满足：

1. 不是主 worktree
2. 分支不在 `FLEET_PROTECTED_RE` 里
3. 没有活 worker 绑定它 —— 没有活 pane 绑 `@issue=<N>`，**且**没有活 pane 的 cwd 在其中（#353：`@issue` 身份检查与 cwd 无关，所以 cwd 游走到子目录的忙碌 worker 不会被误杀）
4. **没有活的 fleet tmux server cwd 在其中**（#509：server 会把自己 chdir 进它 spawn 的 pane，删掉它所在的目录会让它卡在一个被删的 inode 上，**该 server 之后所有 spawn 全废**）
5. 干净（未提交算脏，**未跟踪也算脏**）
6. **已合并** —— GitHub 上该分支有 MERGED 的 PR，或分支尖是 `origin/<base>` 的祖先

附加行为，原生一件都没有：
- 删除 `issue-<N>` worktree 时**自动关闭绑定的 issue #N** —— 给那些落地时没写 `Closes #N` 的 PR 兜底
- **被保留的 worktree 也扫孤儿进程**（#469：实测 11 个进程在窗口关闭 2 天后仍活着，其中 2 个把一个核跑满）
- tmux 没跑时**整体跳过**（看不到谁在用，就不动）
- 多 fleet：活 pane 集合跨 fleet 共享，任一 session 开着的 worktree 在所有 fleet 都受保护

原生只有：marker + `git worktree lock` + 按 `cleanupPeriodDays` 的年龄阈值。
**没有合并态概念**（会删掉未合并的工作）、**没有 tmux 存活概念**（#509 那类事故它看不见）。

### 净结论

瘦身能做的只剩 **OTEL / statusline / plugin 三条**，而且它们本来就与 worktree 无关。
M3 的工作量因此**显著下降**，但「让第二个人装得上」的目标没变 —— 只是路径从
「删掉自建件」变成「把自建件打包好」。

## 八、该偷的(按性价比)

1. **[clauth](https://github.com/uwuclxdy/clauth) 的相位错开** —— 各账号 5h 窗口按
   `5h / 账号数` 错开启动。我们没做，纯赚。
2. **SessionStart 自动更新** —— 用 `/plugin update` 实现，别抄 teamai-cli 的 `pull`。
   ⚠️ 不是白拿的，要 marketplace 侧 `autoUpdate: true`；见[第五章](#五配置共享管线)的更正。
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

## 九之二、多机器的版本漂移(2026-09-14 实测发现)

**`/fleet-sync-install` 是 per-machine 且手动的,所以第二台机器会静默落后。**

实测：操作员问「mini 上的 fleet 是最新的吗」，查下来 **macmini 的 live install 落后
28 个提交**（停在 PR #539），缺了 #603 base branch 修正、#617 配额排名修正、
#608 能力矩阵 —— 而 mini 正是那台跑长时任务的共享机器。没有任何信号提示过它落后。

同步它要手工处理：fast-forward + 5 个改动的 launchd 单元重载 + 1 个**新** daemon
（quotawatch）模板化并 bootstrap + 3 个 commands + 1 个 skill 目录镜像。
同步后 doctor 从「1 WARN」到 21 PASS 全绿（顺带修掉 memory 里挂了很久的
macmini 信任 TODO）。

### 对打包方案的影响

| | |
|---|---|
| **这是打包前的真问题** | 一个 5 人团队有 5+ 台机器。按现在的机制，每台都要有人记得手工跑 `/fleet-sync-install`，而落后了**没有任何提示** |
| **[#611](https://github.com/verkyyi/claude-fleet/issues/611)（plugin 分发）封掉了一半** ✅ | plugin 覆盖 commands / skills / hook 表这半边：marketplace 开 `autoUpdate` 后别的机器自己跟上，不用谁记得跑 `/fleet-sync-install`。**但只有这半边** —— `bin/`、`conf/`、daemon 住在稳定的 `~/.claude/fleet`（plugin 安装路径带版本号、每次更新都变，launchd 单元和 tmux bind 没法指进去），那半边仍然是 per-machine 手工的 |
| **本机自知** ✅ 已上线（[#635](https://github.com/verkyyi/claude-fleet/issues/635)） | `fleet-doctor.sh` 新增 `install` 行：`bin/fleet-install-version.sh` fetch 一个分支后比 `HEAD…origin/<trunk>`，落后就 WARN 出提交数 + 修复命令（`pull --ff-only` → `/fleet-sync-install`），ahead/diverged/dirty 一并报。**fetch 失败报 `UNKNOWN` 而不是 0** —— 「安静」曾经就等于「绿」，这条就是那个 bug。只给人工调用；collector 的 60s tick 用 `--no-fetch`（免费，且自报 `fetched: no`） |
| **跨机器可见** ⏳ 消费方待落（[tokenledger#157](https://github.com/verkyyi/tokenledger/issues/157)） | doctor 仍然只体检本机 —— 而落后的那台你今天根本没登。落点已经确定且**不需要新服务**：TokenLedger hub 的 `store.Endpoint` 行已经带 `Hostname` / `MachineID` / `CCVersion` / `AgentVersion` / `LastSeen`，紧挨着再加一个 fleet 版本字段即可（agent 侧执行 `fleet-install-version.sh --json --no-fetch --no-logins` 取值，随已有心跳上报）。**本仓库这边已经做完**（[#644](https://github.com/verkyyi/claude-fleet/issues/644)）：`--json` 的 key 集合与取值形状是消费方可以硬编码的契约 —— `behind` 读不到是 `null` 不是 0、`follow_verdict` 是 #1123 的固定 token —— 由 `install-version-selftest.sh` 的 H 段钉死，改名先在这边红。**采集 / 上报 / 存储 / 展示在 `verkyyi/tokenledger`，不在本仓库**，已按上面的契约立单 tokenledger#157（含改哪些文件） |

> ⚠️ 排查时的坑：非交互 SSH 的 PATH 不含 `/opt/homebrew/bin`，doctor 会误报
> tmux/fzf/gh/claude 全部 not found。远程体检要走 `zsh -lc`。

## 九之三、团队协作:跨 fleet / 跨设备 / 多人

拓扑：一个人多台设备、多个人同一个 repo、每人多个 fleet —— **唯一的共享状态是 repo 的 issues**。

### 能从「企业功能」白拿的:managed-settings.json 根本不看计划

它是**机器上的一个文件**（macOS `/Library/Application Support/ClaudeCode/`、
Linux `/etc/claude-code/`），**不需要组织账号、不看订阅计划**
（[官方文档](https://code.claude.com/docs/en/managed-settings)）。给的是完整的强制策略层：

| 能力 | 作用 |
|---|---|
| `allowManagedPermissionRulesOnly` | 只认管理员的 permission 规则，用户自己的 allow 全丢 |
| `allowedMcpServers` / `managedMcpServers` | MCP 白名单 |
| `availableModels` | 模型限制 |
| marketplace 约束 | 只许装认可的 plugin |
| hooks / sandbox locks | 强制护栏 |
| `policyHelper` | 可执行程序**动态**算策略 |

**[#611](https://github.com/verkyyi/claude-fleet/issues/611) plugin 分发解决「装什么」，
managed settings 解决「不许改什么」** —— 互补，不重复。而且它比自建同步可靠：用户改不掉。

真正复刻不了的只有 **server-managed settings**（远程下发，endpoint 版要去每台机器放文件）、
**Analytics API / per-user spend**、**SSO / 席位**。但 Analytics 这条**我们已经赢了一半** ——
第一方对订阅用户根本不提供跨机器合并，ccquota 做的正是这个。身份则 GitHub 已经是了。

### 最紧急的裂缝:claim 是布尔锁,永不过期

`bin/dash-issue-session.sh:213` 的判据就一句：

```sh
cs=$(gh issue view "$num" --json assignees,state --jq '"\(.assignees|length)\t\(.state)"')
```

**`assignees` 非空 → 拒绝 spawn。** 没有时间、没有持有者身份、没有存活性。
脚本头注自己承认了失败模式：*"a dead/abandoned peer worker that left the issue
assigned+marked forever"*，唯一出路是人工 `--force`。

一个人用会发现；**N 个人跨设备时死 claim 静默累积** —— 一条挂着 assignee 的 issue，
你分不清是「有人在做」还是「三天前某台机器关机了」。而 issues 是**唯一**的共享状态，
这把锁不可靠，整个协作模型就不可靠。2026-09-14 的 triage 扫描已抓到一条实例（#565）。

**租约设计**：claim 带有效期，持有者活着续期，不续自动失效。存在**一条固定评论里原地编辑**
（`<!-- fleet-lease: owner=… until=… -->`），GitHub 保留编辑历史、不刷屏、人机都可读。
三个关键点：**续期方是 collector 不是 worker**（collector 按 `@issue` 绑定判存活更准，
且是一次批量调用）；**过期 ≠ 立刻抢**（要宽限期 + 抢占留痕）；
**读不到 GitHub 时保持 fail-open**（与现有 dedup 一致，离线宁可重复劳动也不要全线卡死）。

### 参考:主流工具在团队维度做到哪

- **Claude Code Agent Teams** —— 任务表 session-scoped、**纯本地、从不上传**、一 session 一 team。
  是「会话内的团队」不是「跨设备的团队」
- **cross-session messaging** —— 同一台机器限定
- **coder / OpenHands** —— 有真 server + SSO + 审计，但要运维一整套基础设施
- **整张 OSS 图上没人做跨设备的 agent session presence** —— 若要做，**复用已在跨机器聚合的
  ccquota hub，不要新建第二个服务**

### 别做

自建 SSO（GitHub 就是身份）· 自建审计（issue/PR 历史就是审计）·
复刻 Analytics（ccquota 已覆盖第一方给不了的那半）。

## 十、共享 mini 的正确形态

**N 个 OS login,不是一个 login 跑 N 个 fleet。**
tmux socket 本来就 per-uid；ccquota 明确要求每个 OS login 一个 agent
（*"on most systems it could not read the others anyway"*）。
现在共用一个 login 的话，**配额归因是错的**。这是配方不是代码，但必须先改。

**Runbook：[SHARED-MACHINE.md](SHARED-MACHINE.md)**（#609）—— 建 login → Claude 首登 → hub enroll →
每人一个 ccquota LaunchAgent → 每 login 一个 fleet → 验收清单。

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
| `verkyyi/tokenledger` | 18（归因）、M1 全部 | ✅ **`fleet-tokenledger` 已存在**，直接用 |
| 团队 config repo | M4 | 还不存在，M4 时新建 |

#### TokenLedger 的「四名一体」—— 每次都绕，写一次

2026-09-14 那次改名只改了**仓库名和 fleet 名**，标识符一个没动，所以同一个东西有四个名字，
四个都还在用：

| 维度 | 今天的名字 |
|---|---|
| GitHub 仓库 | `verkyyi/tokenledger` |
| 本地检出 | `~/projects/ccquota` |
| fleet session / socket | `fleet-tokenledger`（`tmux -L fleet-tokenledger`、`dash-issue-session.sh <N> fleet-tokenledger`；base branch `main`） |
| 命令 / Go module / env 前缀 | **全是 `ccquota`** —— 二进制 `ccquota`、`module github.com/verkyyi/ccquota`、`CCQUOTA_HUB_URL` / `CCQUOTA_ACCOUNT` / `CCQUOTA_VIEWER_TOKEN` |

⚠️ 两个照着新名字会扑空的地方：**`go install` 必须用旧 module 路径**
（`go.mod` 里就是 `github.com/verkyyi/ccquota`，标识符 cutover 没做，见 #629 的约束）；
按改名前的 fleet 名去 `tmux -L` 也扑空 —— `fleet_sockets` 里只有 `fleet-tokenledger`。

#### 决定:不把 TokenLedger 合进 claude-fleet（2026-09-14 评估，结论已定）

评估过一次，结论是**不合并**，两边继续各自发布。理由和支撑事实记在这里，
免得下一个读这份文档的人再论证一遍：

- **依赖严格单向**：fleet → TokenLedger。TokenLedger 的 Go 代码**零依赖** fleet
  （全仓库 `*.go` / `go.mod` 里没有任何 `claude-fleet` 或 `FLEET_` 引用）。
  合并会凭空造出一条反向耦合
- **接口面很小且已枚举完**，不需要靠同仓库来维持：
  `ccquota budget [--ceiling|--account|--json|--timeout]` + **`exit 3` = hold**
  + `CCQUOTA_HUB_URL` / `CCQUOTA_ACCOUNT` / `CCQUOTA_VIEWER_TOKEN`
  + `FLEET_QUOTA_BIN`（**换实现的接缝** —— fleet 侧早就没有硬编码路径）
- **真实调用点只有 3 个**（`"$CCQUOTA"` 实际被执行的位置，不含 `command -v` 探测）：
  `bin/fleet-account.sh` 的 `quota_fetch()` 与 `cmd_quota() --json`、
  `bin/fleet-quotaguard.sh` 的 `run_ccquota()`
- **不合并的真正理由**：合并会把**唯一已经站得住的那块**（TokenLedger 已公开、
  已是团队形态）绑死在 fleet 这条还在验证的赛道上。这正是[开篇结论](#结论)
  「拆三块发，不发整体」已经否决过一次的事 —— 合并等于把它悄悄撤销

---

### M0 — 先证伪(约半天,零代码) ✅ 已完成 2026-09-13

| # | 验什么 | 结论 |
|---|---|---|
| 22 | 当期定价下「N 份 Max 池化 vs N 个席位」的每美元额度 | ✅ **强力证实且已定稿**（Max 20x=$200 已确认） |
| — | 「一机多 token 并发」现在是否仍成立 | ✅ **实测成立**：19 个 window 跨 3 个 fleet 同时跑在 **3 个不同账号**上 |
| — | 原生 worktree 检查是否覆盖 `base-readonly-guard.py` | ❌ **证伪 —— #4 作废**，见[瘦身清单](#七瘦身清单原生已覆盖该删) |

#### 成本对照（claude.com/pricing，月付，2026-09-13）

| 方案 | 月成本 | 总额度（相对 Pro） | 每美元额度 | 可池化 |
|---|---:|---:|---:|:--:|
| 5 × Team Standard 席位 | $125 | ~5x | 0.040 | ❌ 各自封顶 |
| 5 × Team Premium 席位 | $625 | ~25x | 0.040 | ❌ 各自封顶 |
| **2 × Max 20x 池化** | **$400** | **40x** | **0.100** | ✅ 全池共享 |

**$400 池化拿到 40x；$625 买席位只拿到 25x,且不能互相调剂。**
每美元额度差 2.5 倍 —— 还没算池化消除闲置的收益（席位制下一个人休假，
他那份额度就是纯浪费）。

> ✅ Max 20x = **$200/mo**，操作员 2026-09-13 确认（官网页面两行都显示
> "From $100" 是抓取混行）。上表数字即最终值，可直接用于 README。

#### 并发实测（2026-09-13，本机）

```
fleet-claude-fleet       ×6   verky@24helpful.com
fleet-24haowan-monorepo  ×11  verky@24helpful.com ×9 · verky.yi@gmail.com ×1 · ly297@georgetown.edu ×1
fleet-tokenledger        ×1   verky@24helpful.com
```

三个账号同时在跑，证实 `CLAUDE_CODE_OAUTH_TOKEN` 仍是 per-process 生效。
**池化省钱的物理前提成立,M2 不作废。**

### M1 — 用已经做完的那块试水 ✅ 已完成 2026-09-13

README 改写已落 main（ccquota PR #18 → #19，commit `3f29d7d`）。六条验收全过：
中性开篇 "Books for a team account pool"、成本对照表、受众边界单独成段
（还主动写了**不适用**人群）、跨机器差异化引文、反 Goodhart 设计保留、措辞红线未碰。

> ⚠️ **踩到的坑（值得记住）**：worker 干完活却落在 `dashboard-redesign` 上，
> 因为 `~/.config/claude-fleet/fleets/fleet-tokenledger/conf`（当时还是旧 fleet 名）的
> `FLEET_BASE_BRANCH="dashboard-redesign"` —— fleet-up.sh 建 fleet 时抓了当时
> checkout 所在的分支，而默认分支是 `main`。那是条落后 main 5 个提交的废分支，
> 成果等于石沉大海，靠 PR #19 才捞回来。
>
> **这与 ccquota 自己 PR #11 修过的是同一类 bug**（「push 触发器指向真正的主干
> —— 57 个提交没被 push-CI 验过，因为它指着一条两周没动的分支」）。第二次犯。
> ✅ **已修复并上线 2026-09-13**（#603 → PR #604 → `/fleet-sync-install`）：
> 新增 `fleet_resolve_base_branch()`（优先级 flag > gh default > origin/HEAD >
> checkout > main，22 项 selftest 全过）、`fleet-up.sh` 在不一致或读不到默认分支时
> **大声警告**、`fleet-doctor.sh` 新增 `base` 检查行。该 fleet 的 conf 已改回
> `main`，doctor 现在三个 fleet 全 PASS：
> ```
> PASS base  fleet-24haowan-monorepo: … base "master" is the repo default
> PASS base  fleet-tokenledger:       … base "main"   is the repo default
> PASS base  fleet-claude-fleet:      … base "master" is the repo default
> ```
>
> 💡 产品启示：**`fleet-up.sh` 不该默认拿当前 checkout 的分支当 base**，
> 应取仓库的 default branch（或至少在两者不一致时警告）。这是打包给团队用之前
> 必须修的 —— 陌生人装上之后踩这个坑，会以为整个工具不工作：他的 worker 看起来
> 都在正常跑、PR 都在正常合，但主干上什么都没变。这是最难自查的一类失败。
> → [claude-fleet#603](https://github.com/verkyyi/claude-fleet/issues/603) ✅ 已由 autofill
> 自动接走、修复、落地并同步上线。**这是 autofill 端到端跑通的第一个完整闭环。**

发布动作（HN / X / subreddit）**尚未做**，等操作员决定。

ccquota 不需要等 fleet。它已经公开、已经有 `team --set` 的团队归属模型、
已经是 hub/agent 架构。要做的只是**把 README 主线从「用量监控」换成
「团队订阅池的成本可见性」**，然后发出去。

**措辞已定（操作员 2026-09-13）：中性「团队账号池 / team account pool」** ——
描述机制（一个 hub 管 N 份订阅、按余量调度、团队维度看预算），
成本对照表照登，不点破凭据来源。

- 改 README 开头与 Why 段，主线换成 M0 定稿的成本对照表
- 受众边界照[第二章](#受众边界必须写进-readme)写清楚
- 发一次（HN / X / 相关 subreddit 任选），看有没有人接

**这一步的价值是信息,不是代码**：花 1–2 天知道市场在不在，比闷头改三个月 fleet 划算。

### M2 — 让池子真的成为池子(核心差异化)

这组是方案的卖点，**hands-on,不要 autofill** —— 每条都含调度判断。

**backlog 已全部建好（2026-09-13）**：

| issue | 内容 | 依赖 |
|---|---|---|
| ~~[#598](https://github.com/verkyyi/claude-fleet/issues/598)~~ | ~~相位错开 `5h / N`~~ | ✅ **已完成并上线**（PR #617）—— 顺带挖出并修掉更根本的 bug，见下 |
| [#600](https://github.com/verkyyi/claude-fleet/issues/600) | 池内 token 打标签 + 接 ccquota team 归因 | #598 要读它的窗口起点 |
| [#601](https://github.com/verkyyi/claude-fleet/issues/601) | 争用策略：issue 优先级 + 人均熔断 | 独立 |
| [#599](https://github.com/verkyyi/claude-fleet/issues/599) | **跨 provider 溢出；方案扩展为运行中会话双向续接** | 复用现有 transfer/loop，见[审查方案](SUBSCRIPTION-FAILOVER-PLAN.md) |
| [#602](https://github.com/verkyyi/claude-fleet/issues/602) | Codex 侧多 home 池化：接入已有 ccquota profile/额度能力 | 完整双向“同类优先”策略的前置；认证与采集已有基础 |

> 顺序调整：原定 18 先做（「其余都要读这个标签」），但查证发现 `@cc_account`
> 窗口 option 与 `fleet-account.sh list` 的 per-account 5h/7d% **已经存在**，
> 标签基础大体已有。真正空白的是**用它来调度**，所以改由最独立的 19 领头。
>
> 📌 实测发现的真问题（2026-09-13）：三份账号里几乎所有 window 都压在
> `verky@24helpful.com` 一份上 —— **不是相位问题,是根本没在轮着用**。
> 这让 19 的价值比原先估计的更高。

### M3 — 让第二个人装得上

**backlog 已全部建好（2026-09-13）**，瘦身三条证伪后只剩 5 条：

| issue | 内容 | 并行? |
|---|---|---|
| [#607](https://github.com/verkyyi/claude-fleet/issues/607) | `@claude_state` → `@agent_state` 正名 | ⚠️ **必须独占** —— 碰几乎所有文件 |
| [#609](https://github.com/verkyyi/claude-fleet/issues/609) | mini 改 N 个 OS login | 独立；**后面所有 per-person 功能的地基** |
| ~~[#611](https://github.com/verkyyi/claude-fleet/issues/611)~~ | ~~commands+hooks → plugin~~ | ✅ **已完成** —— 仓库根即 plugin（`.claude-plugin/`），commands+skills+hooks 一并；Codex hook 表同源；INSTALL 第 8 步收成两行命令 |
| [#610](https://github.com/verkyyi/claude-fleet/issues/610) | 用量代理 → `/usage` + OTEL | 可 autofill |
| ~~[#608](https://github.com/verkyyi/claude-fleet/issues/608)~~ | ~~能力矩阵进 README~~ | ✅ **已完成**（PR #615，含 CI 防漂） |

~~删 base-readonly-guard · 删 janitor · `.worktreeinclude`~~ —— 三条已证伪，见[第七章](#七瘦身清单--大部分已被证伪2026-09-13)。

⚠️ **落地纪律**：#607 开工前确认没有别的 PR 在途，落地后立刻 `/fleet-sync-install`，
期间别派其他 worker。其余几条开发可并行，**落地仍一条一条来** —— 每条 land 后
sync-install + 冒烟，确认 fleet 没炸再下一条。

### M4 — 团队层

**backlog 已全部建好（2026-09-13）**：

| issue | 内容 | 依赖 |
|---|---|---|
| [#612](https://github.com/verkyyi/claude-fleet/issues/612) | memory frontmatter 加正交 `scope:` 轴 + 29 条全量回填 | 无 |
| [#613](https://github.com/verkyyi/claude-fleet/issues/613) | `memory promote` + 密钥扫描 gate | #612 |
| [#614](https://github.com/verkyyi/claude-fleet/issues/614) | config source-of-truth 仓库 + 双 target 物化 | #611（plugin） |

⚠️ #612 的安全默认很重要：**缺 `scope:` 时默认 `personal`** —— 漏标不该导致泄露。

---

### 派工的流程教训（2026-09-14 实测）

**① 两条 issue 改同一文件时,提前警告没用 —— 要串行派工。**
#623（dash pin，改排序键）与 #624（父行聚合，改 flex span）同时 autofill，都动
`bin/tmux-dashboard-rows.sh`。我提前给两边发了冲突预警，但**先落地的那条必然让后者变
`DIRTY`** —— 预警改变不了这个。真正有效的是落地后立刻发**精确的解冲突指令**
（"冲突在排序键那段，保留 #623 的 `pinned` 档，把你的计数并进 flex span"），
worker 自己 rebase 掉了，没浪费一轮。
**→ 派工前先查文件重叠，重叠就串行；若已并行，落地后立刻给后者精确指令。**

**② fleet pane 里不能直接 `gh issue comment`。**
`bash-guard.py` 会拦，必须走 `bin/fleet-comment.sh <issue> --note|--to-worker`。
且对**正在跑**的 worker 要用 `--to-worker` —— `--note` 只落在 issue 上，
已经读过 issue 的 worker 看不到。

### 并行策略:哪些能丢给 autofill

memory 记着 autofill 已在两个 fleet armed（打 `autofill` 标签 → 有空位就自动起
worker+PR），全局 cap 10。

| 适合 autofill | 必须 hands-on |
|---|---|
| 6 `.worktreeinclude`、7 OTEL、8 plugin 物化 —— 机械、边界清楚 | M0 三条（是判断，不是实现） |
| 2 能力矩阵进 README | M2 全部（含调度判断） |
| 12 Codex context %（探索性但独立） | 1 rename（独占）、4/5（删安全件，要人来判断） |

### 完整 issue 索引

全部 backlog 已于 2026-09-13 建成 GitHub issue。

| 里程碑 | issue | 状态 |
|---|---|---|
| **M0** | 定价重算 · 并发复验 · 原生 worktree 覆盖面 | ✅ 全部完成（无需 issue，直接查证） |
| **M1** | ccquota#16 README 主线改写 | ✅ 已落 main（PR #18 → #19） |
| **M2** | [#598](https://github.com/verkyyi/claude-fleet/issues/598) 相位错开 · [#600](https://github.com/verkyyi/claude-fleet/issues/600) token 标签+team 归因 · [#601](https://github.com/verkyyi/claude-fleet/issues/601) 争用策略 · [#599](https://github.com/verkyyi/claude-fleet/issues/599) **跨 provider 溢出（头条）** · [#602](https://github.com/verkyyi/claude-fleet/issues/602) Codex 多 home | ⬜ 待派工（hands-on） |
| **M3** | [#607](https://github.com/verkyyi/claude-fleet/issues/607) `@agent_state` 正名 · [#609](https://github.com/verkyyi/claude-fleet/issues/609) mini 多 OS login · [#610](https://github.com/verkyyi/claude-fleet/issues/610) OTEL | ⬜ 待派工（[#608](https://github.com/verkyyi/claude-fleet/issues/608) 能力矩阵 ✅ · [#611](https://github.com/verkyyi/claude-fleet/issues/611) plugin ✅ 已完成） |
| **M4** | [#612](https://github.com/verkyyi/claude-fleet/issues/612) `scope:` 轴 · [#613](https://github.com/verkyyi/claude-fleet/issues/613) `memory promote` · [#614](https://github.com/verkyyi/claude-fleet/issues/614) config 双 target | ⬜ |
| **计划外（用它 → 被它咬到 → 修它）** | 两轮共 **18 条已落地** —— 全清单见[下一节](#计划外产出清单两轮18-条) | ✅ 已上线双机同步 · 在途 [#660](https://github.com/verkyyi/claude-fleet/issues/660) |
| **团队协作方向** | ✅ claim 租约已建 [#631](https://github.com/verkyyi/claude-fleet/issues/631)（2026-09-14，待派工）· ⬜ managed-settings.json 作团队策略基线（未建 issue）· ⬜ 复用 ccquota hub 做跨设备 presence（未建 issue） | 🔶 部分已建 · 见[第九之三章](#九之三团队协作跨-fleet--跨设备--多人) |
| **待派工** | [#622](https://github.com/verkyyi/claude-fleet/issues/622) 常驻只读 triage worker（阶段 1） | ⬜ 要起常驻 session，需操作员点头 |
| **已证伪作废** | 删 base-readonly-guard · 删 janitor · `.worktreeinclude` | ❌ 见第七章 |
| **其他（低优先）** | Codex context%/handoff · 配额裁决接口中立化 · friction Stop hook · 双 anchor worktree 检测 | ⬜ 未建 issue |

> 「相位错开」原本在两处重复（旧编号 14 与 19），已合并为 #598。

---

### 计划外产出清单（两轮，18 条）

「计划外」在这里是**排他定义**：不来自 2026-09-13 建的那 13 条 backlog，而是
**在用这套东西的过程中被它咬到、然后回头修掉**的。两轮合计 **18 条已落地**，
全部双机同步上线。

**第一轮 · 2026-09-13 → 09-14（4 条）**

| issue | 落地 PR | 一句话 |
|---|---|---|
| [#603](https://github.com/verkyyi/claude-fleet/issues/603) | [#604](https://github.com/verkyyi/claude-fleet/pull/604) | fleet-up 的 base branch 取了当前 checkout 的分支 —— 应取仓库 default branch |
| [#620](https://github.com/verkyyi/claude-fleet/issues/620) | [#621](https://github.com/verkyyi/claude-fleet/pull/621) | fleet 的自动化注入把中文会话带回英文 —— 改成「保持原语言」而不是翻译 |
| [#623](https://github.com/verkyyi/claude-fleet/issues/623) | [#627](https://github.com/verkyyi/claude-fleet/pull/627) | dash 把指定 session PIN 在列表顶部，子窗口跟着走 |
| [#624](https://github.com/verkyyi/claude-fleet/issues/624) | [#626](https://github.com/verkyyi/claude-fleet/pull/626) | dash 父行显示子 worker 的聚合进度（3/5 ✓），数据本来就在 |

**第二轮 · 2026-09-14 → 09-15（14 条）**

| issue | 落地 PR | 一句话 |
|---|---|---|
| [#628](https://github.com/verkyyi/claude-fleet/issues/628) | [#632](https://github.com/verkyyi/claude-fleet/pull/632) | 读不到限额的账号被当成 0% 已用 —— 永不 bench，还是 migrate 的首选落点 |
| [#636](https://github.com/verkyyi/claude-fleet/issues/636) | [#638](https://github.com/verkyyi/claude-fleet/pull/638) | collector 停摆时 dash 静默显示两小时前的世界 —— 状态栏出声 + 限流自愈 |
| [#552](https://github.com/verkyyi/claude-fleet/issues/552) | [#650](https://github.com/verkyyi/claude-fleet/pull/650) | git 阶段砍掉没人读的 `git status` + 全程限时轮转（26 个 worktree 7s→2s） |
| [#639](https://github.com/verkyyi/claude-fleet/issues/639) | [#652](https://github.com/verkyyi/claude-fleet/pull/652) | 每个 interval 单元有调度心跳 + 阈值相对自身 interval + 自愈升级阶梯 |
| [#653](https://github.com/verkyyi/claude-fleet/issues/653) | [#655](https://github.com/verkyyi/claude-fleet/pull/655) | `fleet_timebox` 改对墙钟 + 逐 phase 预算 + tick 总预算 + 截断处轮转 |
| [#640](https://github.com/verkyyi/claude-fleet/issues/640) | [#645](https://github.com/verkyyi/claude-fleet/pull/645) | worker 卡在权限弹窗时四条通道全失效 —— 红灯分 `?`/`⊘`，不 attach 也能答 |
| [#656](https://github.com/verkyyi/claude-fleet/issues/656) | [#657](https://github.com/verkyyi/claude-fleet/pull/657) | 远程答题链路：`perm` 误判改由 transcript 裁决，折行不再让 screen gate 拒发 |
| [#658](https://github.com/verkyyi/claude-fleet/issues/658) | [#659](https://github.com/verkyyi/claude-fleet/pull/659) | 红灯会自己散 —— 事件写入的状态开始对照 transcript 校正 |
| [#544](https://github.com/verkyyi/claude-fleet/issues/544) | [#661](https://github.com/verkyyi/claude-fleet/pull/661) | closed-unmerged 回收先证明「session 没了」，而不是「PR 关了」 |
| [#635](https://github.com/verkyyi/claude-fleet/issues/635) | [#646](https://github.com/verkyyi/claude-fleet/pull/646) | doctor 报 live install 落后主干多少提交（mini 落后 28 个而两台全绿） |
| [#629](https://github.com/verkyyi/claude-fleet/issues/629) | [#641](https://github.com/verkyyi/claude-fleet/pull/641) | 补 ccquota 的获取方式，外链改到改名后的 `verkyyi/tokenledger` |
| [#642](https://github.com/verkyyi/claude-fleet/issues/642) | [#643](https://github.com/verkyyi/claude-fleet/pull/643) | 「不合并 TokenLedger」的评估结论进文档 |
| [#625](https://github.com/verkyyi/claude-fleet/issues/625) | [#654](https://github.com/verkyyi/claude-fleet/pull/654) | 会话生命周期事实可选外发 —— 把「花了多少」和「做成了什么」接上 |
| [#648](https://github.com/verkyyi/claude-fleet/issues/648) | [#649](https://github.com/verkyyi/claude-fleet/pull/649) | dash 子任务默认折叠，←/→ 展开收缩（live 和 landed 两个视图都嵌套） |

**在途 1 条**：[#660](https://github.com/verkyyi/claude-fleet/issues/660) —— selftest 不隔离真实 `fleet.conf`，
在 live install 上跑整套有 6 条假失败，干净检出全绿。

### 一条有数据的结论:计划外产出压过计划内产出

这一节不是记账。**它是这份方案自己跑出来的结论**，而且直接决定该向读者推荐什么工作方式。

#### 数据（截至 2026-09-15，两轮独立样本）

| | 计划内（2026-09-13 的 backlog） | 计划外（用它 → 被咬 → 修它） |
|---|---|---|
| 条目 | 13（M2 5 · M3 5 · M4 3） | 18 已落地（+1 在途） |
| 同期已落地 | **3** —— [#598](https://github.com/verkyyi/claude-fleet/issues/598) 相位错开 · [#608](https://github.com/verkyyi/claude-fleet/issues/608) 能力矩阵 · [#611](https://github.com/verkyyi/claude-fleet/issues/611) plugin | **18** |
| 仍 ⬜ | 10 | — |

⚠️ 不要把它读成「落地率 23% vs 100%」—— 那个比较是假的：计划外这一列**按定义**
只包含已经修掉的东西，被咬到但没修的不会出现在表里。真正站得住的信号是**绝对产出**：
同一段时间、同一批 worker，计划内落 3 条，计划外落 18 条。

#### 而且计划外这批的质量更高 —— 一条完整的根因链

[#636](https://github.com/verkyyi/claude-fleet/issues/636)（dash 静默显示两小时前的世界）→ [#552](https://github.com/verkyyi/claude-fleet/issues/552)（git 阶段每个
monorepo worktree 要跑几分钟，拖长整个 tick）→ [#653](https://github.com/verkyyi/claude-fleet/issues/653)（真正的根因：
`fleet_timebox` 数的是 `sleep` 次数、不是墙钟 —— 负载越高，预算膨胀得越厉害，
**预算在最需要收紧的时候最松**）。

- **起点是一个症状，不是一个需求。** 没有任何 backlog 条目会指向
  `bin/fleet-lib.sh` 里那个 `while` 循环 —— 你得先被它骗过一次。
- **它一路证伪了两个更省事的假设**（D 状态阻塞、`fleet_kill_tree` 杀不干净），
  这种排除只有在真机上跑着的时候才做得了。
- **结果是可量的**：collect 从「dash 静默 103 分钟不更新」「一轮要 514 秒」，
  压到 tick 硬上界 120s、实测周期 128–245s（节奏模型 `cycle = tick 时长 + 60s`，
  6 个连续样本误差 ≤3s）。链条上还顺手改掉了一个**被误判的病因** —— #636 当时归咎于
  launchd 把 collector pend 住了，#653 采到 6 个连续 tick 后证明不是：空档恒定 ~61s，
  `runs` 少就是 tick 太长。**不跑它，连这个更正都不会发生。**

同一轮里 [#640](https://github.com/verkyyi/claude-fleet/issues/640) / [#656](https://github.com/verkyyi/claude-fleet/issues/656) / [#658](https://github.com/verkyyi/claude-fleet/issues/658) 是**同一个死锁的三个切面**
（worker 被弹窗拦住 → 四条通道都够不着它 → 红灯自己散不掉），也全是被咬出来的。

#### 对读者的含义

1. **先让它跑起来，让它咬你。** backlog 是对「什么重要」的猜测；一次 103 分钟的
   静默停摆是证据。证据比猜测便宜，也比猜测准。
2. **backlog 不是进度条。** M2/M3/M4 大部分仍 ⬜ 并不等于停滞 —— 同期落了 18 条，
   而且改的是每天都在踩的东西。
3. **但 backlog 不能删。** 计划外产出**清一色是修复**。方向性的东西
   （跨 provider 溢出 [#599](https://github.com/verkyyi/claude-fleet/issues/599)、团队层 M4）不会被咬出来，只会被规划出来。
   两条线是互补的，不是替代。
4. **得有低摩擦的归档渠道，「被咬到」才会变成 issue。** 这批东西几乎都是在**别的活
   干到一半**时冒出来的 —— 能当场 file 掉，它才会存在。fleet 里这是一条命令
   （`bin/fleet-issue-file.sh`，可 `--parent` 挂成子任务、`--spawn` 直接起 worker），
   而且**不只操作员能用**：[#552](https://github.com/verkyyi/claude-fleet/issues/552)
   就是 worker 在做别的事时顺手 file 的，上表里至少 7 条带着 fleet filer 的来源标记。
   如果 file 一条 issue 要切窗口、要想标题、要等操作员批，它们里的大多数只会变成
   一句抱怨然后消失。

第 4 条是给打包方案的直接结论：**「任何一个 session 都能当场 file issue（必要时直接 spawn）」
不是便利功能，它是上面那条产出主线的前提** —— 打包时不能把它当可选件砍掉。
