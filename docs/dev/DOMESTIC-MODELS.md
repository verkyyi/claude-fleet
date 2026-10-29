# 国内模型直连：评估与实现路线（任务 J7BN）

评估 · 2026-10-28 · **P0（DeepSeek harness）已上线**（#5498 + #5507）；P1–P3 待定

## 先看结论

原话的设想成立，而且测试已经上线：**Claude Code 这个 harness 已经能通过一个配置
开关（`FLEET_MODEL=deepseek`）在用户自己的节点上直接请求国内模型 DeepSeek**，
入口（WEB 的 agent 选择、Terminal 的会话入口）一个没动。国内模型直连、以及「只有
用海外模型才走海外中转」这条路由，现有架构已经具备——DeepSeek 是**国内 provider**，
永远直连 `api.deepseek.com`，从不骑新加坡中转；Claude / Codex 这些海外模型仍走中转。
剩下要做的不是再开一条入口，而是把「国内 provider」从一处写死泛化成一张表，再按需补
Codex harness 和「国内优先」的默认。

| 原话的诉求 | 现状 | 结论 |
| --- | --- | --- |
| 用 Codex / Claude Code 的 harness 请求国内模型 | Claude Code → DeepSeek（Anthropic 兼容）已上线，`FLEET_MODEL=deepseek\|deepseek-pro` | ✅ 已做到（P0） |
| 优先提供 DeepSeek harness 作为测试 | P0 就是这个测试，已合并 | ✅ 已上线 |
| 国内用户在国内 POD 上请求国内模型 | DeepSeek 请求直连 `api.deepseek.com/anthropic`，不骑中转 | ✅ 已做到（模型级） |
| 只有用海外模型才让请求走海外 | 按 provider 选路：DeepSeek=direct，Claude/Codex=relay | ✅ 已做到（模型级，见下） |
| 入口 WEB / Terminal 都不用变 | DeepSeek 是模型 profile，不是新 agent、新入口 | ✅ 已做到 |
| 大幅降低延迟（尤其只用国内模型时） | `chat_timing.go` 已按 mainland/all 分开计量；缺 per-provider 证据 | ⏳ 可测，待补证据 |

「只有用海外模型才让 agent 跑在海外节点」这句在现有架构里要读成**模型请求级**而非
**进程级**：agent 进程跑在用户自己的节点（家机器或个人 POD），决定「国内直连还是海外
中转」的是**请求所带的 provider**，不是 agent 搬不搬家。对「只用国内模型」的用户，
这条路从会话开始到结束都不碰中转，延迟收益已经拿在手里；只有选了 Claude/Codex 这类
海外 provider 的请求才走中转。

## 请求拆解与现状

原话逐句对应到代码：

1. **「Codex / Claude Code harness 都可以通过配置使用 Deepseek」** — 对了一半，P0 先
   做了 Claude Code 这一半。`bin/fleet-claude.sh` 的 `fleet_ds_profile()` 把
   `FLEET_MODEL=deepseek` / `deepseek-pro`（大小写不敏感，`--model deepseek*` 也算）
   识别成**模型 profile**：Claude Code 指向 DeepSeek 的 Anthropic 兼容 API
   （`ANTHROPIC_BASE_URL=http://127.0.0.1:<proxy>/deepseek`），模型 env 全部改成
   `deepseek-flash[1m]`（pro 为 `deepseek-v4-pro[1m]`），Haiku / 子代理为
   `deepseek-flash`。Codex 这一半（DeepSeek 的 OpenAI 兼容端点 + Codex 的
   `config.toml`）尚未做，是 P1。

2. **「优化入口，国内用户直接请求国内模型，但入口不用变」** — 入口没动，因为这是
   **模型选择**，不是新 agent。`/v1/node/agents` 仍然只列 `claude` 和 `codex`；
   DeepSeek 藏在 `FLEET_MODEL` 里。WEB 和 Terminal 的会话入口逻辑不变，只是模型档位
   多了一个可选值。

3. **「先优先提供 DeepSeek harness 作为测试」** — P0（#5498）就是这一句：hub vault 存
   `provider=deepseek, kind=api_key`（存的 key 就是租约，永不刷新，见
   `docs/dev/FLEET-HUB.md`「DeepSeek」一节）；`/v1/fleet/credproxy/resolve` 用 session
   pass 换 key；cluster credproxy 把 `/v1/proxy/deepseek/*` 直连
   `api.deepseek.com/anthropic`，永远不骑中转，`x-api-key` 重写，没有 429 rebind /
   Bedrock 回退。`#5507` 补了一个缺口：DeepSeek profile 在一个 `FLEET_AGENT=codex`
   的 fleet 上也能把 agent 选成 Claude（模型 profile 优先于 fleet 的 agent 默认）。

4. **「只有用海外模型才走海外节点 / 大幅降低延迟」** — 选路在
   `tokenledger/shared/credproxy/credproxy.go` 的 `target()`：`provider == DeepSeek`
   一律 `direct`（`DeepSeekURL`），Claude / Codex 走 `RelayURL`（新加坡中转）。延迟
   计量已有 `tokenledger/hub/api/chat_timing.go`，按 mainland / all 分 p50 / p90；
   缺的是**按 provider 拆**的证据（P3）。

## 可行性评估（回答「设计判断标准」）

按 `docs/dev/PRODUCT-DIRECTION.md` 的三问逐项答：

- **是否直接改善大陆用户的接入或服务稳定性？** 是。国内模型的请求全程不出境，不依赖
  中转可达性，延迟下降、故障面减小。这正是产品定位（「专门服务中国大陆的开发者与非
  开发者，解决国内接入不便捷」）的直接落点。
- **是否可以复用官方接口、原生能力或标准扩展？** 是。没有自造协议：DeepSeek 官方提供
  Anthropic 兼容端点（P0 用的 `/anthropic`），Claude Code 原生的
  `ANTHROPIC_BASE_URL` + `CLAUDE_CODE_OAUTH_TOKEN` 就够，无需改 Claude Code 本体；未来
  Codex 侧复用 DeepSeek 的 OpenAI 兼容端点 + Codex 原生 `config.toml`。
- **是否必须进入默认核心，还是应当可选？** 可选。`FLEET_MODEL` 是显式开关，不设就还是
  原来的 Claude/Codex 行为，不静默替换模型或厂商（符合设计原则 3「不静默替换模型」）。

一个值得点明的边界（产品方向里「国内节点只运行 Codex；Claude 等地区不可用服务只在境外
节点」）：P0 证明 **harness 与模型是可分离的**——地区约束落在 **provider** 上，不在
harness 上。Claude Code 指向 DeepSeek 时并不使用 Anthropic 的地区受限服务，因此不违反
「Claude 服务只在境外」；它只是把「Claude Code 这个客户端」接到了「地区可用的国内模型」
上。这正是原话「用 Codex/Claude Code 的 harness 请求国内模型」的成立前提。若要把这条
正式写进产品方向，建议单独确认一次措辞，不随本文假设。

## 剩下的如何实现（P1–P3，均未做）

P0 是「先试一个」。下面是把这条试通的路线泛化、并补上证据的完整清单。每一项都标了
改动点、验收和归类（按 `CONTRIBUTING.md` 的四类）。

### P1 · Codex harness 也接 DeepSeek（OpenAI 兼容）

**归类：按需**（显式 profile，不默认启用）。

- 改动点：cluster credproxy 的 `target()` 今天 `provider == Codex` 只会走
  `CodexURL`（中转）。加一个 DeepSeek 的 OpenAI 兼容目标（`api.deepseek.com` 的
  `/v1` 或 `/openai` 风格端点），让 Codex 的请求在 `FLEET_MODEL=deepseek` 下也直连国内；
  `bin/fleet-codex.sh` 增加对称的 profile（`config.toml` 指向代理的 `/deepseek-openai`
  之类路径，`x-api-key` 用 session pass 换来的 key）。
- 验收：`FLEET_AGENT=codex` + `FLEET_MODEL=deepseek` 开出的会话，Codex 逐轮请求落在
  国内直连、不进中转；无 pass / 无中心代理时拒绝启动（与 Claude 侧同一条门）；国内
  drill（见 `docs/dev/AGENT-ADAPTER.md`，国内只跑 Codex）加一条 DeepSeek 路径的探针。
- 前提：先确认 DeepSeek 的 OpenAI 兼容端点与 Codex 期望的响应形状（尤其是
  `chatgpt-account-id` / 模型名映射）兼容，否则先做一个夹具验透再进正常路径。

### P2 · 把「国内 provider」从写死泛化成一张表

**归类：按需 → 待定**（先只是把 DeepSeek 的特判改成数据，再谈新增厂商）。

- 改动点：`credproxy.go` 的 `target()` 现在是一句 `case provider == DeepSeek`。抽成一个
  provider → 路由的配置（`direct` / `relay`，direct 的 base URL，以及重写规则是
  `x-api-key` 还是 `Authorization`），hub 下发、代理读表。这样新增国内厂商（通义、智谱、
  Kimi、豆包等，凡有 Anthropic 或 OpenAI 兼容端点）只加配置不加代码。
- 验收：不回归现有三种 provider 的路由（DeepSeek=direct、Claude/Codex=relay）；新增一个
  fixture provider 只靠配置就能直连；`docs/dev/CRED-SEPARATE.md` 的「共同约定」表同步。
- 注意：设计原则 3「新增厂商逐一验证，不追求覆盖数量」。泛化只解决**怎么加**，不承诺
  一次加多个。

### P3 · 国内优先默认 + per-provider 延迟证据

**归类：待定**（默认策略涉及「是否静默改模型」的产品判断，先出证据再定默认）。

- 证据先行：`chat_timing.go` 已有 mainland/all 分层的 p50/p90，把计量维度再加一列
  provider（deepseek / claude / codex），让「只用国内模型时延迟更低」有数可依，而不是
  一句话。上线后按真实用户路径采集，不拿夹具数外推。
- 默认策略（需单独确认，不在本文拍板）：对「探测为国内」的登录，是否把新会话默认
  `FLEET_MODEL` 指到国内 provider。若做，必须显式可改、可见，绝不静默替换（设计原则
  3）；海外模型仍是显式选择，选了就走中转。这与「入口不用变」一致：只是默认值，不是
  新入口。

## 边界与不做的事

- 不把 agent 进程按模型搬到海外节点：现有模型是「节点归用户、请求按 provider 选路」，
  这已经满足「国内用户低延迟、海外模型仍可用」；按模型迁移进程是另一个更重的调度问题，
  没有真实需求前不做。
- 不一次引入多家国内厂商：P0 只测了 DeepSeek 一家，其余等 P2 泛化后逐一验证。
- 不改变默认模型行为：`FLEET_MODEL` 未设时行为与 P0 之前一致。
- 不新开 WEB / Terminal 入口，不动 `/v1/node/agents` 的 agent 列表。

## 相关文档

- 产品方向与设计原则（判断标准出处）：`docs/dev/PRODUCT-DIRECTION.md`
- P0 的凭据分离与 hub 两处记录：`docs/dev/CRED-SEPARATE.md`、`docs/dev/FLEET-HUB.md`
- 两种 agent 的国内迁移边界：`docs/dev/AGENT-ADAPTER.md`
