# Agent 配置从哪来：团队 / 个人 / 本机

EPIC #1855。一个会话拿到的每一项配置——工具连接（MCP）、设置、自动规则（hooks）、
技能（skills）、Codex 的键——都来自下面某一处。对人只讲三个词：**团队**、**个人**、
**本机**；另有 **fleet** 的默认值和加锁项。

## 两层模型

| 词 | 是什么 | 存在哪 | 谁能改 |
|---|---|---|---|
| **团队** | 全队共用的一份（#1726） | 入口（hub）`/v1/fleet/team-bundle`，每次 PUT 一个版本 | 操作者 |
| **个人** | 你自己的一份，跟着你走到每台机器（#1856） | 入口上，按你的 principal 存，每次改一个版本 | 只有你；操作者只能帮你退回到你自己的某一版 |
| **本机** | 这个登录自己文件里的值（`~/.claude.json`、`settings.json`、`config.toml`、技能目录） | 这台机器 | 你，直接改文件 |

团队、个人两层同构：同一份允许清单（`mcp` · `hooks` · `skills` · `claude_settings` ·
`codex_config`，个人层另有 `hook_scripts`），同一套凭据扫描（入口和机器两头都拒收
像密钥的值，指出哪一项），同一套版本 / base(409) / 退回语义。

## 合成顺序（高 → 低）

1. **fleet 加锁项** — `conf/agent-locked.list`（mod、fleet 自动规则、fleet 自己的工具连接），
   按 `FLEET_AGENT_LOCK`：`warn`（默认）用本机的值并标出，`enforce` 用 fleet 的
2. **本机** — 你在这台机器上明确改过的，优先
3. **个人**
4. **团队**
5. **fleet 默认** — `conf/agent-defaults/`

合成在 `bin/fleet-agent-team.py`：`sync`（install-sync 的 tick、客户端 shell 启动时）把
各层写进本机文件，只拿回自己写过、没人动过的；`session`（每次开会话）现合一遍，
补齐文件缺的、打指纹 `@agent_cfg`，并记下它跑的 fleet 版本 `@agent_ver`（#1895：
`~/.claude/fleet` 指向的版本目录 sha 前 12 位，没有版本目录时是 `git rev-parse HEAD`）。
`global/agent-cfg.expected` 是新开会话会拿到的那一份（每个 agent 一行 + 一行 `ver <sha>`）；
指纹不同 = **配置旧**（定义变了），指纹相同只是版本旧 = **待换新**——侧栏两种分开标，
doctor `agentcfg` 行分开数，`fleet-cfg-restart.sh` 两种一样闲时重开——Claude 和 Codex
一样（#1896：空闲满 10 分钟、无 /loop、无后台任务，Codex 另问一次 app-server；Claude
`--resume` 同一会话、Codex `codex resume` 同一 thread、同一 CODEX_HOME），重开后第一句
是「fleet 已从 X 更新到 Y」，`/fleet-history` 记 `reason=cfg-stale | ver-stale`。开会话不联网。每项的来源记在
`$FLEET_CONF_DIR/agent-effective.json`（`source` 字段机器可读：`default|team|personal|local`）。

旧和**会坏**是两回事（#2076，EPIC #2074 C3）：`session` 还把会话启动时读到的三样记下来——
交给它的 hook 表、mod 登记的工具清单、MCP 服务器——写成 `$FLEET_CONF_DIR/agentcfg/<sha>.json`
（按内容寻址，窗口选项 `@agent_cfg_manifest` 指着它）。`bin/fleet-oldcfg-check.sh <manifest>` 用
发版门（C2，`fleet-oldcfg-replay.py --manifest`）的同一判定对着当前安装静态比：hook 命令里的
`~/.claude/fleet/…` 路径没了、mod 工具在新 `TOOL_RE` 里没 handler、MCP 服务器的脚本没了 =
**broken**（会真坏：每轮 hook error、每次 spawn `no tool.call hook answered`）；只是新表 / 新 mod
多了它不知道的东西 = **stale**（只缺新功能）；三样一字不差 = **ok**。`--sweep` 把每个 fleet 里配置旧 /
待换新窗口的 manifest 各判一次，会坏的写进 `global/agent-cfg.broken`，`fleet_cfg_state` 读它：侧栏
那一行从黄「配置旧」变成红「**会坏·需重开**」，doctor `agentcfg` 行三种分开数（有会坏的就 WARN），
闲时重开照旧把它当配置旧处理。采集 tick 的 `agentcfg` 阶段每轮扫一遍；`fleet-install-apply.sh` 末尾的
`oldcfg:` 一步在挪版后立刻扫并点名会坏的和**在循环的**配置旧会话（窗口 · 仓库 · 单号 · 状态）——
循环的调度会话闲时重开永远不碰，你得找空自己重开；这一步不自动重开任何会话（#2068 B 不做）。
没有 manifest 的老窗口（#2076 之前开的）照旧算 stale，永远不红。

## 加锁

加锁项是 fleet 自己赖以运转的东西，本机 / 个人 / 团队都盖不住它（`enforce` 下）。
个人自动规则只能**加**（路径 `claude.hooks.personal.<Event>.<key>`，不受
`claude.hooks` 锁连带），不能改写命令、关不掉 fleet 的拦截——见 #1858。
同一批个人自动规则在 Codex 会话里也生效（#1864）：`codex.hooks.personal.<Event>.<key>`，
不受 `codex.hooks` 锁连带；`session codex` 把它们接在 fleet 自己那张表后面，一个事件一行
`c hooks.<Event>=[…]`。Codex 没有的事件（如 `Notification`）或工具（如 `Artifact`）不带，
启动行出一条 note 说明。

## 一行说清来源

有个人层时，三处打印**同一行**，都转印 `fleet-agent-team.py status --short`，不自拼：

```
团队 v12 · 个人 v3 · 本机独有 2 项（fleet config promote 可带走）
```

- `fleet doctor`（承载机 `fleet-doctor.sh` 的 `agents` 行；客户端 `fleet-agent-bundle.py doctor`）
- 开会话时的启动行（`fleet-claude: 配置 …` / `fleet-codex: 配置 …`）
- `fleet config show` 的第一行

「本机独有 N 项」= `fleet config show` 里来源为「本机」的行数，由同一段合成代码数出，
两边永远一致。这些项只在这台机器上，换机器不会跟过去——用 `fleet config promote` 带走。
层已关（`agent-overrides.json` 的 `"team": "off"` / `"personal": "off"`）显示「已关」，
没有该层显示「无」。

**没有个人层**（入口没有、这个人没写过、登录没绑人）时，这一行不出现：doctor 和启动行与之前逐字节相同
（`fleet-agent-team-selftest.sh` L、`fleet-agent-cfg-selftest.sh` A–F 守着）。

## 命令速查

| 想做 | 命令 |
|---|---|
| 看每一项从哪来 | `fleet config show [ITEM]`（`--json` 给脚本） |
| 加 / 改 / 删个人配置 | `fleet config add\|set\|rm --personal KIND NAME [VALUE\|--file F]` |
| 把本机某一项带走 | `fleet config promote ITEM [--yes]` |
| 个人配置的版本 / 退回 | `fleet config history` · `fleet config restore N` |
| 导出 / 导入（给新人一份起点、留备份） | `fleet config export [--personal\|--team] > f.json` · `fleet config import f.json [--merge] [--yes]` |
| 团队配置（操作者） | `fleet config … --team`（即 `fleet-agent-team.py put\|restore\|history`） |
| 这台机器现在用哪版 | `fleet-agent-team.py status [--short]` |
| 立刻同步一次 | `fleet-agent-team.py sync` |
| 某层整层不要 | `~/.config/claude-fleet/agent-overrides.json`：`{"team": "off"}` / `{"personal": "off"}` |

KIND：`mcp` · `settings` · `codex` · `skills` · `hooks` · `hook_scripts`。
MCP 里的凭据只写 `${VAR}` 引用，值由你登录的环境提供。

导出文件就是那一层的配置本身，外加一个 `"_from": "personal vN"` 的注释键（导入时剥掉）。导入是一次写入（基于当前版本），先过和每次写入同一套检查（带密钥的文件整份拒收，指出哪一项），列出差异（`+` 新增 · `~` 改动 · `-` 删除），加 `--yes` 才写；`--merge` 只加不删。导入期间那一层被别人改过就拒绝，重跑看新的差异。
