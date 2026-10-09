# 决定的格式（DECISIONS）

执行会话提的每个问题都写清四件事：**要定什么、建议怎么定、不答按什么走、几点截止**；到点没人答，
管家按建议答给它，并在批次 parent 上记一笔「默认拍板」，你随时可以翻案（issue #2669，EPIC #2668 C1）。

**`bin/fleet_decision.py` 是唯一的读写者**：解析、渲染、到期判定、写回都只在它里面；别处要读一个问题，
调它，不要自己 grep 评论。

## 提问：`ask` 的四个可选字段

`mcp__fleet__ask`（`bin/fleet-mcp.py` `tool_ask`）在 `question` / `kind` / `issue` 之外多收：

| 字段 | 意思 | 缺省 |
|---|---|---|
| `suggest` | 你会怎么定、为什么 | — |
| `default` | 到点没人答按什么走 | 等于 `suggest`（「到点按建议走」） |
| `due` | 截止：ISO 时间，或时长 `90m` / `4h` / `1d` | 4 小时；问的时候或截止落在 23:00–08:00，顺延到早上 9:00 |
| `class` | `normal` · `never:rule` · `never:money` · `never:publish` | 按关键词判 |

夜里按**人的**钟：`FLEET_DECISION_TZ`（IANA 名，如 `Asia/Shanghai`），不设就是本机时区。

贴到单上的评论：

```
⛔ blocked: 试水名单先发 20 家还是 50 家？

- 建议：20 家：批次约定写了先小后大
- 不答按：20 家：批次约定写了先小后大
- 截止：10-09 18:05（到点按上面走，随时可翻案）

<!-- fleet:ask v=1 id=<uuid> asked=<ISO> due=<ISO> kind=normal item=<q> suggest=<q> default=<q> -->
```

标记里的值都做了百分号编码（没有空格、没有 `-->`），所以解析是逐字的，不靠上面那几行人看的字。

**关掉 = 逐字节如今天**：一个新字段都没给、且管家关着（`FLEET_STEWARD`，缺省跟
`FLEET_ORCHESTRATOR`，再缺省跟 `FLEET_HOST`）时，评论就是今天那一行 `⛔ blocked: …`。管家开着时，
没给字段的问题也带标记，那一行的「不答按」写「等你」。

## 一行

`item · suggest · default · due(ISO) · src · kind`，外加 `id`、`asked`、`url`（原话评论）和 `state`：

- `src` = `gh:owner/repo#N`（下一批加 `hub:N`），`url` = 那条评论的地址；
- `kind` = `normal` 或 `never:rule|money|publish`；
- `state` = `open` · `answered` · `defaulted`。之后有一条带 `fleet:answer row=<id>` 的评论（到期默认的带
  `by=default`），或一条人直接在 GitHub 上写的回复（没有 `fleet:from` 标记），或一条直达的决定（首行
  `决定…`，见下），这行就不再是 `open`。执行会话自己后来的记录不算回答。

没有标记的 `⛔ blocked:` 评论（旧会话、本格式之前的）也读成一行：`id` 为 `legacy-<hash>`，默认为空 →
「等你」，永不到期。

## 永不默认

改铁律（`CLAUDE.md` 约定、`docs/BREAK-IT.md` 删行）、花钱、对外发布三类**一次都不被默认**：

- 提问方声明 `class: never:*`；或
- 关键词兜底：问题 / 建议 / 默认里出现 `CLAUDE.md` · `AGENTS.md` · `BREAK-IT` · 铁律 · 改约定 · 删约定（rule）、
  付费 · 花钱 · 云机器 · 购买 · 充值 · 账单 · 预算 · billing · purchase（money）、`stable` · 发布 · 对外 ·
  公开 · publish · release（publish）——任一命中即 `never`，声明的 `normal` 压不过它。

`never` 行不进 `due`；`due --apply` 拿到这样一行时再判一次，什么都不贴。BREAK-IT 行
`decision-never-defaulted`。

## 命令

```
fleet_decision.py ask-body --question Q [--suggest S] [--default D] [--due T] [--class K] [--head question|permission]
fleet_decision.py parse  (--repo R --issue N | --comments-json FILE|-)      一行一个 JSON
fleet_decision.py render [--demo] [--rows FILE|-] [--id UUID] [--samples FILE]  Markdown 表 + 标记（+ 抽样区）
fleet_decision.py due    [--rows FILE|- | --repo R --issue N…] [--now ISO] [--apply]
fleet_decision.py record --row JSON --parent owner/repo#N                  「默认拍板」
```

`render` 出的决定单（管家交给编排会话的那张）：

```
| # | 事项 | 建议 | 不答按 | 截止 | 来源 |
|---|---|---|---|---|---|
| 1 | 试水名单先发 20 家还是 50 家？ | 20 家 | 20 家 | 10-09 18:05 | [gh:verkyyi/claude-fleet#2701](…) |
| 2 | 要不要开一台云机器跑抓取？ | 不开，用 mini2 | 等你（永不默认：花钱） | — | [gh:verkyyi/claude-fleet#2702](…) |

<!-- fleet:decision v=1 id=<uuid> -->
```

### 只读区 `samples`（抽样，issue #2678）

批次结束（管家的「待你动手」那一遍看到它的 EPIC 关了）后的下一拍，管家读 `fleet-evidence.sh export
--epic N`，在留了**改动后**证据的成员里随机抽 1 个（按批次播种，`bin/fleet_sample.py`），文件拷到
`fleets/<sess>/steward/samples/<owner-name.N>/`，当拍自己发出决定单——不等模型、也不需要有开着的行。
抽样不是决定行：不编号、不进 `decide` 数、没有人答它。当天之后的每张决定单都带着当天的抽样：

```
### 抽样：做完的批次，抽一个成员看它的改动后

- o/r#2668 → #2678 · 决定单出现抽样区 · 2026-10-09T10:00:00Z
  `…/steward/samples/o-r.2668/evidence/2678/after-….txt`
  ```
  （文字证据的前 8 行；图片是 ![说明](路径)）
  ```
  <!-- fleet:sample epic=o/r#2668 member=2678 -->
```

一个成员都没有改动后证据：那一条写「o/r#N：K 个成员里没有一个留了改动后证据」——绝不拿改动前顶替。
`render --samples FILE`（JSON 数组）出同样的区；没有抽样时 `render` 逐字节如前。
自测：`bin/fleet-steward-sample-selftest.sh`。

`due --apply` 对每一行到期的问题做两件事，各最多一次（已有标记就跳过）：

1. 在执行会话自己的单上 `fleet-comment.sh --to-worker`：「到点没人答，按建议定：…」+
   `<!-- fleet:answer row=<id> by=default -->` —— 它下一轮就收到；
2. 在那张单的 EPIC parent 上 `--note`：「默认拍板：owner/repo#N「问题」→ 按「默认」」+ 建议、截止、原话链接、
   怎么翻案 + `<!-- fleet:default-decided row=<id> -->`。没有 parent 就只做第 1 步。

写 GitHub 都经 `fleet-comment.sh`（它走 `fleet_gh_write`）；读经 `fleet-gh.sh`（缓存优先）。

## 直达的决定

人直接点开某个执行会话、在里面说了一个决定：执行会话把它写回自己的单，正文首行 `决定（直达）：…`
（`mcp__fleet__comment`，`mode: note`）。管家以单子为准，这条评论也让那一行读成 `answered`。

## 文案

所有人看得到的字走 `bin/fleet-ui-lang.sh` 的 `decision_*` 键，脚本里不写死。

自测：`bin/fleet-decision-selftest.sh`；`ask` 的字段与「关掉逐字节如今天」：`bin/fleet-mcp-selftest.sh` O。
