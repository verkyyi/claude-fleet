# 两种 Agent 有什么不同

fleet 的会话可以跑 Claude Code，也可以跑 Codex CLI。两种 Agent 走**同一条路**
（EPIC T580）：开会话、认出起来了、递消息、交接 / 切换、回收，每一步都只有一份实现。
真正不同的地方写成一张表：`bin/fleet_agent_adapter.py` 的 `ADAPTERS`，每种 Agent
一行，每一列只记一件**确实不同**的事。shell 读它生成的副本 `bin/fleet-agent-adapter.sh`
（`--emit-sh` 逐字节生成，`fleet-launch-lib-selftest.sh` 守着两份一致）。

**规矩：新代码不按 Agent 名分叉，问表。** 不写 `[ "$AGENT" = codex ]`。一种 Agent
没有的步骤，就在表里写一个说「没有」的值（空 / 0），调用方走「没有」那条路。新的差别
加一列，不另开一个文件。

```sh
python3 bin/fleet_agent_adapter.py get codex deliver      # → queue
python3 bin/fleet_agent_adapter.py known codex            # exit 0
source bin/fleet-agent-adapter.sh; fleet_agent_get claude end   # → hook
```

本页先讲这张表：每列两边各填什么、为什么不同；再讲只有 Codex 有的部分
（app-server、TOML、rollout、用量采集），最后讲往原生能力迁移的边界还停在哪里。

## 差别表

下面按会话的一生分组。「为什么」一栏说明这是**上游 Agent 本身**的差别，
不是 fleet 的选择，所以只能写成表里的一列，不能抹平。

### 启动（C4 · T620）

一道门 `fleet-claude.sh` exec 表里写的 `launcher`。两个启动器共用
`bin/fleet-launch-lib.sh` 里的所有步骤（配置与每 fleet 覆盖层、信任、MCP 策略和 fleet
工具服务、组合配置和 `@agent_cfg` 标记、会话凭据和拒绝标记）。

| 列 | Claude | Codex | 为什么不同 |
|---|---|---|---|
| `launcher` | `fleet-claude.sh` | `fleet-codex.sh` | Codex 还要配 `CODEX_HOME`、TOML 钩子、私有 app-server、版本检查，这些只属于它 |
| `model_env` / `model_flag` | `FLEET_MODEL` / `--model` | `FLEET_CODEX_MODEL` / `-m` | 两家的模型名不一样，一个设置管不了两边 |
| `ready_check` | （无） | `fleet_codex_ready` | Claude 的登录在凭据代理那里检查；Codex 要先确认二进制和 home 能用 |
| `trust` | `claude-json` | `codex-toml` | 「信任这个目录吗？」的答案，Claude 写在 `~/.claude.json`（每次 spawn 都写），Codex 写在 `config.toml`（只在受信任的节点上写；其他情况下窗格会提示，并转成 `needs`） |
| `mcp` | `flags` | `config` | Claude 用 `--mcp-config` 文件挂载工具服务；Codex 只认 `-c mcp_servers.<name>=…` |
| `seed` | `slash` | `skill` | `/name args` 是 Claude Code 自己展开的；Codex 用 `$name` 调用技能（插件技能是 `$<plugin>:<name>`），没装这个技能就用 `conf/codex-preamble.md` 加命令原文展开成一段话 |
| `seed_words` | `1` | `0` | Claude 的第一轮是人的原话，流程由 SessionStart hook 带进来（`@seed_words`）；Codex 的 SessionStart 要等到第一轮才跑，带不进来，流程只能跟着原话一起作为第一轮 |

### 会话 ID 和「起来了」（C5 · T629）

一个窗口当前的会话 ID 只有一个读法：`session_id()` / `fleet_agent_session_id`，
依次看 `sid_window`、`sid_pending` 里的 `"session_id"`、`sid_thread`。不管从哪里听到，
都通过同一个见证 `fleet_id.hook` 落地，「起来了」就是 ID 的第一段。

| 列 | Claude | Codex | 为什么不同 |
|---|---|---|---|
| `sid_source` | `hook` | `thread` | Claude 启动和每次 /clear 都跑 SessionStart；Codex 0.162 只在线程第一轮才跑，所以由 runtime 的 follower 向私有 server 要 `thread/started`（见下文「app-server」） |
| `clear_said` | `1` | `0` | Claude 启动时会说 `source=clear`；Codex 不说，同一窗口里出现新 ID 就当作 /clear（`fleet_id.next_native`） |
| `sid_window` | `@cc_session_id` | `@codex_session_id` | 窗口选项名 |
| `sid_pending` | （无） | `@codex_pending` | Codex 用 resume 打开时，到第一个 hook 之前只知道「打开的是哪一个」 |
| `sid_thread` | （无） | `@codex_thread_id` | 最后的兜底 |
| `preset_sid_flag` | `--session-id` | （无） | 只有 Claude 能用 fleet 预先选好的 ID 开新会话 |

`fleet-agent-witness-selftest.py` 把启动、第一轮前的启动、clear、重开各在两种 Agent 上跑一遍。

### 恢复、fork、记录

| 列 | Claude | Codex | 为什么不同 |
|---|---|---|---|
| `resume_flag` | `--resume <id>` | `resume <id>` | 一个是 flag，一个是子命令 |
| `fork_flag` / `fork_replaces` | `--fork-session` / `0` | `fork` / `1` | Claude 在 resume 后面加 fork；Codex 用 `fork` 这个词替换 `resume` |
| `continue_flag` | `--continue` | （无） | Codex 没有「接着这里最新的一个」，只能开新的 |
| `from_pr_flag` | `--from-pr` | （无） | 只有 Claude 能重开做出某个 PR 的那次会话 |
| `transcript` | `project` | `home` | Claude 的记录在登录账号的 `~/.claude/projects/<cwd>/<id>.jsonl`，可以归档；Codex 的 rollout 在它自己的账号 home 里，history 行的 12–14 列记下这个 home |
| `park_resume` | `1` | `1` | 空闲停放后包装器明确 resume 原对话号；Codex 使用原账号 home 中的 thread，不 fork |
| `park_exit` | `typed` | `paste` | 同一 pty 中继发送 `/exit` + Enter；Codex 用 bracketed paste，避免 Enter 被吸收成换行 |
| `park_probe` | `inbox` | `native-input` | Claude 的 `park.v1`；Codex 原生 idle、队列为空且终端输入框确认为空。后台工作检查仍共用原生 inventory，未知即不停 |

### 递消息（C6 · T626）

所有往活会话里送的消息（`fleet-peer-send.sh`、子会话回报、digest、peer 队列重放、
hub relay）都走 `fleet_agent_deliver`（`bin/fleet-lib.sh`）。结果码两边一样：
0 交出 · 3 暂存（对方现在接不了：记到窗口身份下，稍后重放）· 1 拒绝。Codex 原来的暂存码是 4，
读的一方再认一版。

| 列 | Claude | Codex | 为什么不同 |
|---|---|---|---|
| `deliver` | `inbox` | `queue` | Claude 进程有 peer inbox socket；Codex 的消息进私有 app-server 的线程队列（`fleet-codex-session.py send`），窗口没跟上 /clear 时就暂存。两边都不往终端里敲字 |

### 交接和切换（C7 · T630）

交接（同一种 Agent，换一个新上下文）和切换（Claude ↔ Codex）走同一条路：`fleet-transfer.sh`。
表里只写源会话从哪里读、目标会话怎么启动。

| 列 | Claude | Codex | 为什么不同 |
|---|---|---|---|
| `transfer_source` | `registry` | `thread` | Claude 从进程的会话登记加 projects 记录里读源；Codex 从窗口的原生线程身份、rollout、账号 home 读 |
| `home_flag` | （无） | `--codex-home` | 只有 Codex 有要随身带的账号 home |
| `account_env` | `FLEET_ACCOUNT_LABEL:label` | `FLEET_CODEX_PROFILE:profile` | 指定目标账号时用哪个变量传 |
| `loop_settled` | `loop-mark` | `thread-idle` | 两轮之间怎么算 `looping` 已经停稳：Claude 看 Stop hook 按窗格 `@loop` 写下的标记；Codex 看原生线程是否空闲、上一轮是否完成 |
| `exit_paste` | `0` | `1` | Codex 的输入框会把连续敲进去的回车当成换行，所以 `/exit` 要整段 bracketed paste 进去 |
| `armed_cycle` | `1` | `0` | Claude 挂着的 `@handoff_armed` 是原地换上下文，切换不能抢在它前面；Codex 挂着的就是这次切换本身 |
| `native_cron` | `1` | `0` | Claude 自己的调度器里有定时任务，无仓库会话切换时要带走（CronList）；Codex 没有，循环由 fleet 管 |
| `bind_proof` | `session` | `process` | 怎么证明目标起来了：Claude 看窗格里绑定的原生会话；Codex 看窗格下有没有这个进程（指定账号或无仓库身份时也看会话） |
| `account_resume` | `1` | `0` | 只有 Claude 能换一个账号重开同一个会话（`--native-resume`） |

### 回收（C8 · T631）

回收两边走同样的门、同样的关闭流程。`fleet-agent-end-selftest.py` 把正常退出、被杀、
残留 daemon、残留工作各在两种 Agent 上跑一遍。

| 列 | Claude | Codex | 为什么不同 |
|---|---|---|---|
| `end` | `hook` | `exit` | 怎么知道人走了：Claude 看 SessionEnd hook 的 `prompt_input_exit\|logout`（启动器 exec 了 Agent，拿不到退出码）；Codex 看启动器等到的退出码 0（它的 SessionEnd 对线程切换也报 `reason=other`，#730）→ `fleet_launch_end` → `session-end-hook.sh --agent-exit codex <pid>` |
| `procs` / `proc_js` | `claude` / `claude-code/cli.js` | `codex codex-real` / `@openai/codex/` | `fleet-reap-live.py` 找 Agent 进程时用的名字（`agent_of_process` 是唯一的读法） |
| `bg_probe` | `pid` | `native` | 上一轮结束后还有没有活：Claude 看进程的 Bash 工具子进程；Codex 通过 app-server 问它自己的清单，回答不是干净的 idle 就不回收（常驻 MCP 和辅助服务是基础设施，不算活，#4318） |
| `daemon` / `cred_home` | （无） | `app-server` / `codex-homes` | Codex 会话结束后会留下一个带会话凭据的 app-server；`_fleet_agent_cred_daemons` 通过 `cred-proxy/codex-homes/<sid>` 找到它，在凭据撤销后清掉 |

## 加第三种 Agent

1. 在 `ADAPTERS` 加一行，**每一列**都填上（没有这一步就填空或 0），然后运行
   `fleet_agent_adapter.py --emit-sh > bin/fleet-agent-adapter.sh`。
2. 写它的 `launcher`，source `fleet-launch-lib.sh`，只写它自己独有的部分。
3. 如果它有一件表里装不下的差别，加一列：写进 docstring 的 Columns 说明，所有读的地方都改成问这一列。
   不要在调用的地方写 `if agent == …`。
4. 每条路的 selftest（`fleet-launch-lib-selftest.sh`、`fleet-agent-witness-selftest.py`、
   `fleet-agent-end-selftest.py`、transfer 的几个 selftest）都按 Agent 循环，新的一行会被自动跑到。

## 只有 Codex 有的部分

下面这些不是表里的一列，因为只有 Codex 有。它们全在 `fleet-codex.sh` 和
`fleet-codex-*.py` 里，不会漏进共用的路。

### app-server：每个窗格一个私有 server

- **运行时。** `fleet-codex-runtime.py` 为每个窗格起一个私有的本地 `codex app-server`，
  TUI 以 `--remote unix://PATH` 连上它。socket 目录放在 `/tmp` 下，权限 0700（macOS 的 Unix 路径长度有限）。
  另有一个 guardian 守着 server，盯着一个只有 supervisor 持有的 pipe：supervisor 就算被 SIGKILL，
  pipe 一断 server 也会退出。不起共享 daemon，不开网络监听，不改账号配置。
  `FLEET_CODEX_SERVER=0` 退回嵌入式启动，只用来排错；那时没有原生状态通道，也没有消息投递。
- **身份。** SessionStart 把根会话 UUID、CODEX_HOME、rollout 路径、模型写进一个
  `@codex_identity` JSON；旧启动器的 hook 改不了新启动器的值。Codex 第一轮之前不跑 SessionStart，
  所以 runtime 每秒推一次 follower（`fleet-codex-session.py` `Follow`）：启动器还没指明线程时，
  向 server 要 TUI 的线程（`witness`）；之后再看到 `thread/started`（一次 /clear 或 /new），
  就把窗口改指过去（`follow`）。
- **注意力。** `fleet-codex-attention.py` 在一条连接上收 `thread/status/changed`，
  只把记下的那个根 UUID 投到 fleet 的状态上；等待输入或审批 ⇒ `needs` 和响铃。这条连接收到过匹配的事件后，
  再降到每 30 秒对一次账；在那之前保持两秒一读。断线、半帧、畸形事件只丢掉这条连接，
  不会把请求当成已解决；worker 明确写的 `blocked` 不会被清掉。
- **回答。** 面板的回答键、`fleet-answer.sh` 和 `fleet-permission.sh` 用只读元数据的
  `thread/resume` 重放待处理请求（不开新轮次）。`request_token` 覆盖启动器、线程、请求 ID 和内容；
  成功的标志是 `serverRequest/resolved`。自动拒绝要显式打开（`FLEET_ALLOW_AUTO_DENY=1`），
  fleet 从不替人批准。
- **改模型。** `fleet-codex-model.sh switch|limits` 通过原生设置 API 给空闲 worker 换模型，
  不重启；`limits` 打印线程的原生额度桶。
- **RPC。** `fleet-codex-rpc.py` 通过 Unix WebSocket 做有界的 JSON-RPC 读取，处理掩码、分片、
  ping/pong。`codex app-server proxy` 只转发原始字节，不能代替它。
- **不支持的组合。** 原生 `--worktree` 只能用于本地会话，不能和 `--remote` 一起用：runtime
  在起 server 之前就拒绝，不悄悄退回去。worktree 仍然由 fleet 创建。

### TOML：Codex 只认它自己的配置格式

- **钩子。** 共用的 `hooks/settings-hooks.json` 通过 `hooks/codex-map.json` 映射过去
  （`fleet-hooks-emit.sh`），在启动时以 `-c hooks.*` 传入；PreCompact 没有对应事件，丢掉。
  启动器带 `--dangerously-bypass-hook-trust`，这是为了让 fleet 的 hook 和插件 hook 能跑。
  这个旁路还不能拿掉（见下文「迁移边界」）。
- **只按文本补。** 默认包 `conf/agent-defaults/codex/config.default.toml`
  （`approval_policy`、`sandbox_mode`、`model_reasoning_effort`、MCP 服务器）只补缺的键，
  把 `config.toml` **当文本**改，用户已有的行逐字节不动。macOS 的 python 3.9 没有 `tomllib`，
  所以绝不重新序列化。另有一个显式候选：
  `fleet-agent-defaults.py apply --codex-native-remote unix://… --codex-native-peer-pid PID --skip claude`
  通过原生 `config/batchWrite`（带 `expectedVersion`）写，只用于维护窗口和空闲后台，失败了不退回旧写法。
  它没接进正常安装。
- **MCP。** `FLEET_MCP_CONFIG` 两边都管；Codex 这边把共享的 `mcpServers` 允许清单翻译成
  `mcp_servers`。`FLEET_CODEX_MCP_CONFIG` 可以直接给原生 JSON 或 TOML（要 Python 3.11+）。
  翻译不了的字段会让启动失败，不会悄悄加载全部。会话变量只能通过 `env_vars` 传给插件 server。
  `FLEET_CODEX_SUBAGENT_MODEL` / `_EFFORT` 管子 Agent 的模型和推理强度。
- **插件。** 还是只在 Claude Code 的 `/plugin` 装一次。`fleet-install-apply.sh` 运行
  `fleet-codex-plugins.py sync`，用 Codex 自己的 `codex plugin marketplace add|add|remove` 跟上；
  启动时什么都不写。第一次 sync 会清掉旧桥留下的 `fleet-plugin-*` 和标记块。
  `agent-overrides.json` 里的 `codex.plugins` 可以把插件交还给这个登录账号自己管（T589）。
- **托管守卫（候选，管理员手动运行）。** `fleet-hooks-emit.sh --target codex-managed` 只打印两条
  已审阅的 PreToolUse 守卫 TOML 片段。`image-stage.py guards-install <current> /etc/codex [--check]`
  重新生成后，原子地并进 `/etc/codex/requirements.toml`；要求 release、目录、脚本、解释器都是 root
  所有、其他用户不可写，遇到冲突的 hook 策略就拒绝。macOS 上要先 `install -d /etc/codex`，
  并用 `_TomlSubset` 严格子集读 TOML（不认识的写法就拒绝）。stage、seed、boot 都不会调用它。
  它不是沙箱，也不会拿掉启动器的旁路。
- **全屏。** 0.156 起默认 `tui.fullscreen_transcript`，fleet 不传任何 `tui.*`。
  Codex 会接管鼠标，所以聊天历史不在 tmux scrollback 里；读 scrollback 的地方
  （停放快照、限额横幅扫描、transfer 失败转储）对 Codex 窗口只能看到一屏，要看历史就读 rollout。
  拖选复制走 `tmux load-buffer -w` → OSC 52。

### rollout：Codex 的记录和版本钉

- **上下文。** `fleet-context.sh`（也可以 `--agent codex --session UUID --json`）先核对 rollout 的
  session meta 是否就是要的 UUID，然后只读最后 2 MiB，取最新 token-count 事件的
  `last_token_usage.total_tokens` 和 `model_context_window`。缓存输入已经算在里面，会话累计量不等于当前上下文；
  缺数据就显示「未知」，不当作 0。缓存按 fleet、窗口、启动器、根 UUID 分开存，新会话不会读到前一个会话的值。
- **版本钉。** rollout 是上游的内部格式，只保证 release 钉住的版本：
  `fleet-codex-runtime.py` 的 `SUPPORTED_ROLLOUT_VERSIONS`（按组件前缀匹配，`0.162` 包括 `0.162.x`）。
  `fleet-codex-runtime.py version-check` 返回 0 已验证 / 1 未验证 / 2 没装；doctor 有 `codex` 这一行；
  版本未验证时仍然启动，但会警告一行，并在 `@codex_identity` 里写 `version_warning`。
  只有 rollout 夹具在新版本上通过后，才把它加进这个常量。
- **恢复和历史。** 崩溃快照和已关闭会话的记录保存 provider、根 UUID、CODEX_HOME、rollout 路径。
  `fleet-history.sh resume` 默认用原生 `codex fork UUID`（`--no-fork` 改用 `codex resume`）。
  home 或 rollout 没了，就只能看不能恢复。不复制凭据，也不悄悄换账号。缺身份的就是「未知的 Codex 会话」，
  绝不拿同一个 worktree 里的 Claude 记录顶上。
- **休眠。** 钉住的版本跑在私有 server 上时，休眠的依据是原生「轮次完成」和完成时间
  （`FLEET_CODEX_NATIVE_COMPLETION`，只在版本检查通过后由启动器设置）；其他情况仍然看 Stop hook 的证据。
  休眠前的各项检查一项都不跳过，没有完成证据就拒绝休眠。

### 用量采集

- **测量总线。** 和 Claude 一样，只有 `conf/statusline.sh` 一个写入者：Codex 的 hook 调
  `--from codex pct= limit= model= effort=`（effort 读 rollout 的 `turn_context`，读不到再读 `config.toml`），
  标记 `@ctx_src codex`，自己不另写任何东西。
- **额度。** 开了凭据代理时，`fleet-proxy-quota.sh` 把代理记下的速率限制头以 `--from proxy`
  交给总线，Claude 和 Codex 走的是同一条路。
- **原生用量（试点，默认关）。** `FLEET_CODEX_NATIVE_USAGE=1` 让注意力连接用只读元数据的
  `thread/resume` 订阅已加载的根线程，把原生用量交给 Meter；有效期间续一个 5 秒租约，停掉 rollout 轮询。
  断线、身份变化、事件畸形，或者 monitor 卡住，都会退回 rollout 读法。只初始化的观察连接**收不到**
  `thread/tokenUsage/updated`，所以必须先 resume。验证：`fleet-native-usage-cli-selftest.py [--meter-candidate]`。
- **订阅。** Codex 启动时不在本登录账号的多个账号里挑（T560，和 Claude 一样）：有凭据代理就由池子挑，
  每个会话一次，遇到 429 就换账号重发；`fleet-cred-proxy.sh standing --provider codex` 显示还能落到哪些账号；
  `FLEET_CODEX_QUOTA_GATE=1` 在没有可用账号时拒绝启动。`FLEET_CODEX_HOME`、`--codex-home`、恢复身份都能钉住账号；
  `--codex-profile` 在 `ccquota codex run` 下运行，整个生命周期持有登录锁。不要复制 `auth.json`：
  refresh token 每用一次就轮换，两份副本会互相把对方登出。

## 迁移边界：哪些还没交给原生

方向是能用 Agent 原生能力的地方就不重复造（[产品 Blueprint](PRODUCT-DIRECTION.md#fleet-与原生-agent-的最终职责边界)，
组件类别以 [COMPONENTS.md](COMPONENTS.md) 为准）。已经交出去的：插件（Codex 原生安装，T589）、
注意力（原生事件）、默认上下文管理（`FLEET_AUTO_HANDOFF_PCT` / `FLEET_COMPACT_PREP_PCT` 默认 0，
压缩交给 Agent）、读屏分类器（#2543 删掉）。还停着的有三处，每处卡在哪里都有探针证据：

- **worktree。** 两家 CLI 都有 `--worktree`，但 Codex 的只能用于本地会话，而 fleet 的默认路径是私有
  server 加 remote TUI；app-server 协议里也没有创建 worktree 的参数。所以目录仍由
  `fleet_worktree_create` 创建，只有一个创建者。原生目录在主检出之外，现有的 base-readonly 守卫允许，
  不需要放宽。
- **hook 信任旁路。** 原生 `/hooks` 信任按定义 hash 记录，改了定义就失效；但带
  `--dangerously-bypass-hook-trust` 的本地 TUI 不属于被验证的后台。旁路要等托管守卫进了只读管理层、
  可选 hook 交给原生信任之后才能拿掉。
- **共享后台。** 共享 app-server 的 MCP 进程继承的是**后台**的环境，不是每个客户端的；
  请求元数据里的线程 ID 只是上下文，不是凭据。所以会话凭据、身份、角色绝不放进共享后台的环境，
  每个窗格仍然一个私有 server。

显式运行的探针（空 HOME、无凭据、只请求 loopback 端点，不是模型成功的验收）：

```sh
bash bin/fleet-native-worktree-selftest.sh [--native-cli]
python3 bin/fleet-native-worktree-cli-selftest.py --codex PATH --fleet-root PATH
python3 bin/fleet-native-local-runtime-selftest.py --codex PATH [--launch-flags|--native-config]
python3 bin/fleet-native-session-env-selftest.py [--hooks [--fork-seed]]
python3 bin/fleet-native-hook-cli-selftest.py --codex PATH [--remote-tui --probe-bypass]
python3 bin/fleet-native-plugin-cli-selftest.py [--retire-bridge]
python3 bin/fleet-native-usage-cli-selftest.py --codex PATH [--meter-candidate]
python3 bin/fleet-native-guard-install-selftest.py
python3 bin/fleet-native-claude-worktree-selftest.py --claude PATH   # Claude 侧，只在境外环境
python3 bin/fleet-native-claude-tui-selftest.py --claude PATH
```

再交出去一块之前要过的验收：隔离与身份（主检出、伪造的 `.git`、符号链接、路径逃逸都拿不到权限）·
数据保留（退出、中断、POD 重建都不丢未提交的改动和会话归属）· 准确恢复（resume/fork 落在同一个账号 home）·
真实入口（面板新建 → 输入框 → 草稿未发送 → 明确发送 → 完成 → 重连，不能拿一次 `exec` 代替）·
保护不退化（CPU / 额度 / 权限 / 凭据 / 信任 / Hub 不可用时语义不变）· 分段计时、同配置公平对照 ·
先在工作树和 CI 验，再上 drill，最后上用户 POD，出现回归立刻停。国内 drill 只跑 Codex。
