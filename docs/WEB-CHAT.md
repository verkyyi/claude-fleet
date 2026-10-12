# 浏览器里和会话对话 · 最小版（issue #3567）

一个人一条对话，在浏览器里（手机 Safari 也行）跟 Claude 说话。后端是 **Claude Agent SDK**，
跑在这个人自己的登录上，走 fleet 额度池的凭据代理 —— 和 fleet 会话里的 claude 同一条路。

## 用

```sh
bin/fleet-webchat.sh start            # 第一次会把锁定版本的 Agent SDK 装进 $FLEET_CONF_DIR/webchat/deps
bin/fleet-webchat.sh link             # 一次性登录链接（10 分钟），经 fleet-open 开到你自己电脑的浏览器
bin/fleet-webchat.sh link --tailnet   # 给手机：https://<本机 tailnet 名>:18961/login?c=…（只在 tailnet 里能开）
bin/fleet-webchat.sh status | stop
```

`--tailnet` 需要 `tailscale serve`。这个登录不是 tailscale 的 operator 时，由管理员跑一次
`sudo tailscale serve --bg --https=18961 http://127.0.0.1:18961`，路由会一直留着，之后 `link --tailnet` 直接用它。

## 页面

- 打开就是那一条对话，往上翻是历史；没有会话列表，不能新开或切换。
- 回复流式显示；每个工具步骤折叠成一行，点开看结果；`AskUserQuestion` 和权限确认显示成按钮。
- 模型下拉只有白名单：Sonnet 5.5（默认）· Opus 5.5 · Haiku 5.5。白名单是 `extras/web-chat/lib.mjs` 的 `MODELS`，
  由服务端校验，名单外的请求返回 400。
- 停止键停掉正在跑的这一轮。页面关掉或断线不会停掉这一轮，重新打开会接着显示，待答的按钮还在。

## 一条对话怎么一直连着

- 「这个人 → 当前 session id」存在 `$FLEET_CONF_DIR/webchat/conversation.json`。每一轮都 resume 它，
  服务重启或断线后也是同一条。
- 每轮结束后记下上下文用量；到窗口的 `FLEET_WEBCHAT_COMPACT_AT`（默认 0.8）时，在两轮之间后台跑一次
  Claude Code 自带的 `/compact`。下一轮会等它跑完。
- `/compact` 失败，或者某一轮报「上下文太长」，就**接力**：新开一个 session，把旧 session 的结尾带进第一句里
  （包在 `<fleet-webchat-relay>` 里，页面上不显示），旧 id 记进 `chain`。页面把整条 chain 的记录连起来显示。
- 这些都是 Claude Code 自己的记录（`~/.claude/projects/<目录>/<id>.jsonl`）。在终端里用
  `cd <目录> && claude --resume <id>` 可以读到、接着用，页面底部写着这条命令。

## 认证和凭据

每一轮用 `bin/fleet-session-cred.sh mint --provider claude --sid web-<pid>-<n>` 取一张**会话凭据**，
这一轮结束就 revoke。SDK 起的 `claude` 子进程只在环境变量里拿到它：

| 变量 | 值 |
|---|---|
| `ANTHROPIC_BASE_URL` | `http://127.0.0.1:<代理端口>`（共享凭据代理） |
| `CLAUDE_CODE_OAUTH_TOKEN` | 这一轮的 `fcp1.…` 会话凭据，不是订阅令牌 |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `1` |

`ANTHROPIC_API_KEY`、`ANTHROPIC_AUTH_TOKEN`、`FLEET_WORKER_CRED`、`TMUX*` 都会去掉。代理按请求从池子里选号、计量，
记到这个登录对应的人名下（`POST /v1/node/usage`），额度满了切号 —— 和 `bin/fleet-claude.sh` 一模一样。
代理关着（`fleet-session-cred.sh on` ≠ 0，或 mint 返回 3/4）时，按 CLI 的老路，用这个登录本身的身份。

凭据只在子进程的环境变量里：不进响应、不进 `server.log`、不进任何文件，也不出现在 argv 里。
另外，响应和日志写出去前都会过一遍 `redact()`，`fcp1.` / `sk-ant-` / `Bearer …` 形状的串会被替换掉。

## 只有本人能进

- 只绑 `127.0.0.1`，没有改它的选项。
- 进门要一次性链接，由 `fleet-webchat.sh link` 生成：它要出示 `admin.token`，这个文件是 0600，放在本登录 0700 的状态目录里，
  机器上的别的登录读不到，也就生成不了链接。
- 链接只能用一次，10 分钟内有效。用过之后种下 HttpOnly、SameSite=Strict 的 cookie，有效 30 天；cookie 只存 sha256。
- 没有 cookie 一律 403。不认识的 `Host` 返回 421（防 DNS rebinding）。POST 必须带页面自己加的头。

## 测试

`bin/fleet-webchat-selftest.sh` 用桩 SDK、桩 `fleet-session-cred.sh`、桩代理把服务真跑一遍，覆盖：
只绑 127.0.0.1、没有链接的人被拒、白名单由服务端执行、这一轮的请求带着发下来的会话凭据到了代理（池子在代理那里计量）、
sid 用完被 revoke、凭据和 admin token 不出现在任何响应、日志或文件里、重启后还是同一条对话、停止键。

## 不在这一版

网页终端、文件和图片上传、语音、多人共享一条会话、给 tmux 里正在跑的会话插话、并进入口 `/app`、微信登录。
