# 一个窗口一个 ID：节点账本与原生段

EPIC T497 的 C1。设计页：「会话与 hub 任务（T）的关系 · 设计稿」第 6 版（§3、§4.1、§4.2、§4.6）。
这一层目前**只双写**：旧 T 记录与执行权照旧，谁都不读这里做决定，直到 C7 打开切换开关。

## ID 与短码

- 完整 ID 就是窗口的 `@fleet_id`（UUIDv4，`fleet_fid_mint` 开窗时铸），形状不变。
- 短码 = `T-` + 完整 ID 的小写 Crockford base32 前缀（去掉 `i l o u`），默认 5 位；
  本登录已知的另一个 ID 与它同前缀时加长一位，以此类推（像 git 的短 SHA）。
- 「已知」= 账本里的 ID + `ids/.known`（hub 镜像回写，C2）+ 活着的窗口。
- 寻址接受短码或完整 ID：`fleet_win_for_addr`、`fleet-peer-send.sh`、MCP `send` 的 `to`。
  一个短码对上两个 ID 就拒绝并列出两个候选（rc 2），从不猜。输入大小写不敏感，`i/l/o` 按 `1/1/0` 读。
- 窗口上 `@task_short` 记它的短码（开窗时 `fleet-id.sh open` 盖，之后钩子补）。

## 账本

`$FLEET_CONF_DIR/ids/<ID>.ndjson`，一行一个事件，每个带 `(id, seq)`，追加时持 flock：

| 事件 | 谁写 | 内容 |
|---|---|---|
| `opened` | 两个 spawner（`dash-issue-session.sh` / `dash-raw-session.sh`，后台）；没有时由钩子补一条 `lazy` | agent（解析后的）· window · repo · title · key · task · short |
| `native` | SessionStart 钩子 | 新的一段（agent · 原生 id · trigger · seg），或 `compact: true` 给当前段记一次压缩 |
| `result` | `fleet-id.sh result`（C4 接 report） | state · summary · pr |
| `closed` | `fleet-id.sh close`（C4 接回收） | reason |

## 原生段怎么追加（§4.2）

`hooks/settings-hooks.json` 的 SessionStart（不带 matcher，每种 source 都跑）调 `fleet-id.sh hook`；
Codex 用同一张表，在每个线程的第一轮跑到它。

| 进来的 | 做什么 |
|---|---|
| Claude `startup` | 没有段 ⇒ 段 1（startup）；同一个原生 id ⇒ 不动；另一个 ⇒ 新段 resume |
| Claude `resume` | 另一个 id ⇒ 新段 resume，记下它原来属于哪个 ID 的哪一段（`from`），那一段还活着就记 `conflict` |
| Claude `clear` | 新段；handoff 周期打的 `/clear`（它盖的 `@id_next_trigger handoff:<epoch>`，10 分钟内有效，读即删；或 `@handoff_cycle`）⇒ handoff，否则 clear |
| Claude `compact` | 当前段压缩 +1，不开段 |
| Codex（`FLEET_CODEX_LAUNCHER_PID` 与窗口的 `@cc_launcher_pid` 对得上） | 另一个 id ⇒ 新段：startup ⇒ new（同窗口的新线程），resume ⇒ resume |
| 任意 | agent 与上一段不同 ⇒ transfer |

钩子永不挡 Agent、永不输出：不在 tmux、headless 的 `claude -p`、坏 stdin 都直接退出 0；
写不进账本时把这一段记在窗口的 `@id_retry`，下一次钩子先补写。`FLEET_ID_HOOK=0` 关掉它。

## 命令

```
fleet-id.sh get <ID | T-code> [--json]   ID、短码、opened、各段（agent · 原生 id · 起止 · trigger · 压缩次数）、结果
fleet-id.sh resolve <ID | T-code>        → 完整 ID；rc 1 没有，rc 2 有歧义（候选在 stderr）
fleet-id.sh short <ID>
fleet-id.sh open|native|result|close …   见脚本头
```

`bin/fleet-id-selftest.sh` 钉住 §4.6 的 S1、S3–S6、S11 与短码/寻址/钩子的规矩。
