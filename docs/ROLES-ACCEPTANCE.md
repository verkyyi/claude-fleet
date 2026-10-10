# 角色与规则 · 三台机器验收（EPIC #2781 C7，issue #2788）

这一页是「角色配置」这批的收尾：本机设置里管角色的开关搬进你的那一层，然后在
**macmini、mini2（两台托管机器）和你的 MacBook** 上各做一遍 A–D 四项，结果记进下面的表。
时间按发起人拍板 9：**核心成员全部合并、stable 移过之后的第一个工作日上午，你在场**；
C 项（断开入口）每台 15 分钟内恢复。

## 0. 开始前

| 检查 | 命令 | 要看到 |
|---|---|---|
| 三台都在同一个版本 | `fleet doctor --installs` | runtime、每个登录、每个客户端壳都 = stable |
| 入口已重部署（C3 · C6 是入口改动） | 浏览器开入口的 `/config` | 有「角色与规则」一栏 |
| 你的登录绑定了人 | `fleet role show orchestrator --sources` | 不报「这个登录没有绑定到人」 |

## 1. 搬：`fleet-conf.sh migrate` 的 roles 步

每台机器、每个托管登录各跑一次（`fleet-install-apply.sh` 的 `conf` 步和客户端壳启动时也会自己跑；
手跑是为了看清楚它做了什么）：

```sh
~/.claude/fleet/bin/fleet-conf.sh migrate --dry-run   # 先看：would move … / would comment out …
~/.claude/fleet/bin/fleet-conf.sh migrate             # 再做
~/.claude/fleet/bin/fleet-conf.sh migrate             # 第二次：什么都不说，入口版本号不变
```

搬什么、留什么：

| 变量 | 去处 |
|---|---|
| `FLEET_ORCH_MODEL` · `FLEET_ORCH_EFFORT` | 你那一层的 `orchestrator.model` / `.effort` |
| `FLEET_STEWARD_MODEL` · `FLEET_STEWARD_EFFORT` | `steward.model` / `.effort` |
| `FLEET_MODEL` | `worker.model` 和 `epic-driver.model`（空值 = `inherit`，用登录自己的默认） |
| `FLEET_ORCH_CODEX_MODEL` · `FLEET_STEWARD_CODEX_MODEL` · `FLEET_SUBAGENT_MODEL` | **留在 fleet.conf**：覆盖层没有「Codex 模型」「子代理档」这一项，migrate 只列出来 |
| `FLEET_ORCHESTRATOR` · `FLEET_STEWARD`（开关）、节拍、名额、停放阈值 | 留在 fleet.conf（这台机器自己的事） |
| 仓库 conf（`repos/<slug>.conf`）里的 `FLEET_MODEL` | 留着：按仓库的，不归角色 |

规则（`bin/fleet-role.py` 的 `migrate-conf`）：

- 值和自带定义一样 → 只把那一行注释掉，不写入口。
- 入口上你那一层**已经**写了这一项（别的机器先搬过、或你说过一句）→ 你的为准，本机这一行只注释掉。
  同一个人多台机器，先说的算，后搬的机器不会盖掉。
- 其余 → 一次 PUT 写进你那一层，备注「从 <机器> 的 fleet.conf 迁入」，原行注释掉，
  `fleet.conf.bak-<时间>` 留底。
- 入口连不上 → 要写入口的那几行原样留着（它们照旧生效），下次 migrate 再搬；`fleet-conf.sh` 照常退出 0。
- 值不是一个字面量（`"${X:-opus}"`）→ 原样留着，提示你手动 `fleet role set …`。

搬完之后 `fleet doctor` 的 `roles` 行不再说「本机还有角色变量」。没搬完它 WARN，并列出哪几个。
旧变量这一版还读（`# compat-1v: 下一批删`）。

## 2. 四项验收

### A · 说一句改（MacBook → mini2）

1. 在 MacBook 上 ⌘N 进编排会话，说「管家用 Sonnet」。它念出「管家 · 模型：opus → sonnet」，你说好，
   它回「已改 …（入口 vN）」。**记下这一刻的时间 t0。**
2. 在 mini2 上让管家下一次开起来（它在安静时刻会自己续开；要立刻验：说「重开管家」）。
3. mini2 上读：`fleet role render steward --kv | grep '^model'` → `model	sonnet`；
   管家窗口的 `@model` 也是 sonnet（侧栏顶行 / `fleet ls`）。**记下看到的时间 t1。**
4. 通过 = t1 − t0 写进表；改回：说「撤回」。

### B · 在入口上改（手机）

1. 改之前在 mini2 上：`python3 ~/.claude/fleet/bin/fleet_decision.py ask-body --question '这份报价要不要发' --suggest 发 | grep -o 'kind=[a-z:%0-9A-F]*'`
   → `kind=normal`。
2. 手机打开入口 `/config` →「角色与规则」→ 规则 17（花钱，`never:money`）的关键词加上「报价」，保存。
3. 等不到一分钟（推送 + 拉取），同一条命令 → `kind=never%3Amoney`（管家对含「报价」的问题判 ask、从不按默认）。
4. 通过 = 第 3 步读到 never:money；改回：页面上撤回到上一版。

> issue 原文写「规则 9」：编号是 C5 落地前排的，那时还没有表；今天管「花钱」的是 17 号。

### C · 断开入口（macmini）

1. 屏蔽入口域名（需要管理员：`sudo sh -c 'echo "127.0.0.1 <入口域名>" >> /etc/hosts'`），**记时间**。
2. macmini 上照常开一个执行会话（`fleet-issue-file.sh --spawn` 或 ⌘N 让编排会话派一单）：会话开得出来，
   `fleet role show worker --sources` 照常有「你的 vN」。
3. `fleet doctor` 的 `roles` 行写「拉到 <时间>（多久前）」；超过一天才 WARN。
4. 恢复 `/etc/hosts`，15 分钟内；`fleet doctor` 的 `roles` 行下一拍回到最新。
5. 通过 = 第 2 步会话开出来、第 3 步说出缓存多旧。

### D · 派单查得到规则（任一台）

1. 在编排会话里派 3 单（一个快活、一个只建单不开工、一个派给 Codex 的机械活）。
2. 读：
   ```sh
   for n in <三个单号>; do gh issue view $n --repo <仓库> --json body -q .body | grep -o '<!-- fleet:rule n=[0-9]* v=[^ ]* -->'; done
   ```
   三张都有，且每张的正文末尾有「按规则 N 派发」。
3. 通过 = 3/3。没注明规则的单子会有「未注明规则」一行，并记在 `logs/rules.log`。

## 3. 上线证据

三台机器上：

```sh
fleet role show orchestrator --sources
```

输出逐字相同（同一个人、同一份入口层、同一份自带定义），贴进 PR 和下表下面。

## 4. 记录表

| 机器 | 搬（变量 → 去处） | 第二次 migrate 无新版本 | A（t1−t0） | B | C（恢复用时） | D | `show --sources` 相同 |
|---|---|---|---|---|---|---|---|
| macmini | | | — | | | | |
| mini2 | | | | | — | | |
| MacBook | | | — | | — | | |

（A 在 MacBook 说、mini2 上看；B 在 mini2 读；C 在 macmini 做；D 任一台。一格「—」= 这台不做这一项。）

## 5. 演练（BREAK-IT）

issue 列的三行，前两行在 C2 / C3 已经落地（名字不同），第三行这一单新加；
`bin/fleet-break-it-selftest.sh <id>` 各跑一遍：

| issue 里的名字 | BREAK-IT 里的行 | 谁加的 |
|---|---|---|
| `role-overlay-bad`（坏覆盖层 ⇒ 用上一份好的） | `role-overlay-broken` | C2 #2783 |
| `role-hub-down`（入口不通 ⇒ 用缓存） | `person-hub-down` | C3 #2784 |
| `role-unlock`（覆盖层试图放开守门项 ⇒ 被锁回） | `role-unlock` | C7 #2788 |
