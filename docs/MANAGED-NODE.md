# 托管机器：身份、信任与期望状态

EPIC #2329 共同约定 1：**机器的期望状态在入口。** 入口为每台托管机器存一份
「应有的样子」；机器上的守护每个周期把实际状态收敛到它，`fleet doctor` 的机器部分
就是两者的差。这份文档是那份「应有的样子」的约定——C2（#2214）建了它，C3–C6 读它。
加一个字段，先改这里。

## 1. 机器的身份 = 入口发的令牌，不是机器名

一台机器在入口的身份是它加入时换到的**节点令牌**（一个 endpoint，`ep_…`）。
机器名（hostname）是 agent 自己报的，谁都能报成别的——所以**信任记在身份上**。

| 从哪来 | `trust_source` | 说明 |
|---|---|---|
| 托管加入码 | `join_code` | 操作者在入口「机器」页点「添加机器」生成；码里写明可信 + 角色 `managed`，一次性、1 小时 |
| 操作者 | `operator` | `PUT /v1/fleet/nodes/<ep>/desired` 带 `trust` |
| 机器名（旧规则） | `machine_name` | `fleet.node_trust.<机器>`，只对**用这个名字加入**的 endpoint 生效；`# compat-1v`，一个发布版后删 |
| 冒用的机器名 | `name_borrowed` | 报的名字是可信机器，但它不是用这个名字加入的 → 不可信、审计一行 |

判定顺序（`internal/api/fleet_trust.go` `nodeTrust`，唯一一处）：

1. 操作者把它报的机器名标了 `untrusted` → 不可信（操作者的话只会收回信任）；
2. endpoint 自己的信任（加入码 / 操作者）→ 照它，不管报什么名字；
3. 旧规则：名字可信 **且** 与 `endpoints.enrolled_host`（加入时的名字，没给就是第一次上报的名字；加入时没报名字记 `?`）同一台 → 可信；
4. 其余不可信。

## 2. 加入码

```
POST /v1/fleet/nodes/join-codes      （操作者）
  {"label": "m4"?, "trusted": true?, "role": "managed"?, "kind": "fixed"?}
→ {"code": "fj_…", "expires_at": …, "command": "…", "trust": "trusted", "role": "managed"}
```

- 缺省：`trusted: true`、`role: managed`、1 小时；`trusted: false` 发不带信任的码。
- 旧路由 `POST /v1/fleet/join-codes` 照旧：不带信任、10 分钟。
- 码只存哈希；兑换（`POST /v1/node/join`）与登记 endpoint 在一个事务里，一次、过期即拒。
- 加入码不进任何 issue、评论、提交、日志（共同约定 8）。
- `command` 目前是 `fleet-node-join.sh` 那一行；C1（#2330）的 `sudo fleet node install --join <码>` 上线后换成它。

## 3. 期望状态

```
GET /v1/fleet/nodes/<ep>/desired     （操作者）
PUT /v1/fleet/nodes/<ep>/desired     （操作者；只有操作者能写）
GET /v1/node/desired                 （机器自己，节点令牌）
```

GET 的回答：

```json
{
  "endpoint_id": "ep_…",
  "version": 3,
  "release": "4ffae0a5…",
  "components": {"ccquota": "prod-02e8161b", "claude": "2.1.3", "codex": "0.10.0", "runtime": "4ffae0a5"},
  "accounts": ["verkyyi", "24haowan"],
  "spare_accounts": 2,
  "trust": "trusted",
  "trust_source": "join_code",
  "role": "managed",
  "updated_at": "2026-10-08T03:00:00Z",
  "updated_by": "…"
}
```

| 字段 | 含义 | 约束 |
|---|---|---|
| `version` | 入口每写一次 +1；0 = 从没写过 | 入口给，不可写 |
| `release` | 这台跑的发布版（stable 标签所在提交） | 标签或提交，≤ 80 |
| `components` | 各部件钉住的版本：`ccquota` `claude` `codex` `runtime` … | ≤ 32 项，名字小写，版本 `[A-Za-z0-9.+_-]` |
| `accounts` | 这台应有的系统账号 | ≤ 64，系统登录名 |
| `spare_accounts` | 备好的空账号数 | 0–32 |
| `trust` / `trust_source` / `role` | 身份上的信任与角色（§1） | PUT 里可带 `trust`：`trusted` / `untrusted` / `""`（回到机器名规则） |

PUT 的请求体就是上面可写的字段，外加可选的 `if_version`（读到的版本；对不上 `409 version_conflict`，什么都不写）。
未知字段 `400`——凭据不会有地方落脚。每次写审计一行（`node_desired`），改信任另记一行（`node_trust`，`endpoint:<ep>`）。

## 4. 机器报「收敛到哪了」

心跳（`control.Heartbeat`）带：

```json
"desired": {"version": 3, "release": "4ffae0a5…", "diff": "codex 0.9.0 → 0.10.0"}
```

- `version`：上次收敛完成时读到的期望版本；
- `release`：实际在跑的发布版；
- `diff`：还差什么，一行；空 = 已一致。

不管理任何东西的旧 agent 不带这个字段，入口的名册也就不显示期望 / 实际两栏——一字不差。
名册每个节点多出 `trust_source`、`role`、`desired {want, reached, want_release, release, diff}`；
入口「机器」页的卡片显示「可信 · 来自加入码」和期望 / 实际两栏。

## 5. 一个版本内新旧并存

- 旧节点没有身份信任：照旧按机器名，但只认它加入时的名字（`machine_name`）。
- 迁移时 `enrolled_host` 用每个 endpoint 当时报的名字补齐，所以 m4 / m5 现有的登录一个都不掉。
- 下一批删旧规则（`# compat-1v: 下一批删`）：那时每台机器都已凭托管加入码重新加入（C1 / C8）。
