---
name: fleet-browser
description: Open web pages and finish OAuth on the person's own computer from a remote fleet session — an MCP server's authorization, /login, a dev server's page. Use when an authorization asks to "paste the callback URL", a browser opened on the wrong machine, or the person asks to turn the fleet browser on, off, or check it.
---

# fleet-browser — 远程会话里授权像本地一样完成

会话跑在一台机器上（比如 macmini），人的浏览器在另一台电脑上。需要回调到
`localhost:<端口>` 的授权（MCP 授权、`/login`、本地开发服务器预览），回调会落到
人自己电脑的 localhost，连不上会话。

**打开后：** 会话要打开网页时，在你的电脑上打开；回调需要时，在你的 ssh 连接上
临时转发那一个端口，用完即关。每次转发都在你的屏幕上提示一行（哪个端口、为哪个
会话、什么时候关），并记日志。

## 开关（默认关）

    ~/.claude/fleet/bin/fleet-browser.sh status
    ~/.claude/fleet/bin/fleet-browser.sh on      # = claude plugin install/enable fleet-browser@claude-fleet
    ~/.claude/fleet/bin/fleet-browser.sh off     # = claude plugin disable fleet-browser@claude-fleet

在**跑会话的那个登录**上开（会话所在的机器）。新开的会话生效；已开的会话要
`/fleet-handoff` 或重开。关掉后什么都不转发，和以前完全一样。

## 它怎么做到的

- 会话拿到 `BROWSER=~/.claude/fleet/bin/fleet-browser.sh`：Claude Code 打开网页时
  运行 `$BROWSER <url>`（Linux 上的 Codex 也读它；macOS 上的 Codex 不读，它的授权
  仍要手动粘贴回调地址）。本插件的 SessionStart hook 把同一个 BROWSER 写进 Bash
  工具的环境（`gh auth login --web`、开发服务器的「打开浏览器」）。
- `fleet-open.sh --browser` 认出授权页里回调到本机 loopback 的 `redirect_uri` 端口，
  你的客户端（瘦客户端 `fleet`，或带租约的完整客户端）先把**同一个端口**转发回会话
  所在机器，再打开授权页。你在浏览器里点一次同意就完成。
- 回调服务一停（或 10 分钟到，`FLEET_OPEN_CALLBACK_SECS`）转发就关掉。

## 日志

- 会话这边：`~/.config/claude-fleet/logs/browser.log`（时间 · 结果 · 域名 · 回调端口，不记 URL）
- 你的电脑：`~/.cache/claude-fleet/forwards.log`（瘦客户端）或客户端临时目录的 `forwards.log`
