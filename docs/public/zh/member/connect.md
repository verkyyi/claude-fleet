# 电脑和手机上怎么连

会话跑在 tokenman 的设备上，不在你的电脑或手机上。你的电脑和手机只是打开它们的窗口：同一个账号，在哪台设备上打开，看到的都是同一套会话。要在终端里敲的命令，都集中在这一篇。

## 电脑上（Mac 或 Linux）

**第一次**：把管理员发来的那一行粘进终端，回车。管理员自己装，用入口地址后面加 `/install`：

```sh
curl -fsSL https://hub.example.com/i/<邀请码> | sh     # 成员：邀请里的那一行
curl -fsSL https://hub.example.com/install | sh        # 管理员
```

装完会打开 tokenman，请你登录一次：终端里出现一个链接或二维码，用浏览器打开或手机扫，用微信、邮箱或 GitHub 登录，点 **确认签发**。看到 `✓ 证书 · ✓ 已登记到入口` 就连上了。

**之后每天**：在终端敲

```sh
fleet          # 打开，回到上次的样子
fleet quit     # 只退出这台电脑上的窗口，会话照常干活
```

Mac 上推荐用 iTerm2，⌘P 打开总面板；别的终端和手机用 `F12` 或 `⌃] p`。tokenman 只占这一个键（iTerm2 里 F12 照旧归会话），其余都在面板里。

## 关掉电脑会怎样

| 你做了什么 | 会话 | 回来时 |
|---|---|---|
| 关掉终端窗口、合上笔记本、断网 | 照常干活 | 敲 `fleet`，回到原样 |
| 面板里选「退出 tokenman」，或敲 `fleet quit` | 照常干活（只退了你这台电脑上的客户端） | 敲 `fleet` |
| 换一台电脑 | 照常干活 | 在新电脑上装好、登录（同一个账号），敲 `fleet`，会话全都在 |

登录一次管 12 小时，到期这台电脑自己续；续不上时客户端会请你再扫一次码。

## 手机上（iOS 或 Android）

手机上用 **Termius**（iOS / Android 都有）连到你自己的地址，看到的就是电脑上那一套会话。第一次设置一次，大约 5 分钟：

1. 在浏览器里打开入口，登录后点导航里的 **从手机连**（地址是 `https://<入口>/fleet/keys`，比如 `https://hub.example.com/fleet/keys`）。
2. 照页面走六步：装 Termius → 在 Termius 里生成钥匙 → 把公钥贴回页面 → 在 Termius 新建主机（地址、端口、用户名、钥匙四项，页面上每项都有复制按钮）→ 连接，信任主机钥匙 → 连上后按 `F12` 或 `⌃] p` 打开面板。
3. 你的地址形如 `<名字>.<入口给的域名>`（比如 `alice.fleet.example.com`），页面上写着；端口也以页面上写的为准。

之后在手机上：

- 打开面板：`F12` 或 `⌃] p`（先按 Ctrl+]，再按 p）。在 Termius 键盘上方那一排（扩展键）里加一个 `F12`，点一下就开。
- 屏幕窄时面板自动全屏，点一行就切过去。
- 换手机、丢了手机：在入口的 **我的连接** 页撤掉那把钥匙，立刻就连不上了。

- 只要命令行、不要面板：在 Termius 这台主机的设置里加一个环境变量 `LC_FLEET_ENTRY`，值 `shell`，连上就是家里机器上自己的命令行（电脑上：`ssh -p <端口> -o SetEnv=LC_FLEET_ENTRY=shell <用户名>@<你的地址>`）。在命令行里输入 `fleet` 回面板。
- 在家里机器的命令行里直接敲 `claude` 或 `codex`，用的就是 tokenman 的共享订阅（第一行会写「共享订阅」）；想用自己的账号就 `touch ~/.fleet-pool-off`。
- 换了家（家换到另一台机器）：用页面上那个所有人共用的地址连的，什么都不用改，主机钥匙也不变。用「高级：直连这台机器」那条连的，那个地址跟着家走——换家后后面是新家那台机器，手机会问一次新的主机钥匙，和页面上写的指纹对得上再接受。两台在同一个路由器后面时，要把路由器的端口转发改到新家，页面上写着它在家里网络的地址。
- 手机报「主机钥匙变了」、不知道怎么认：Termius 里 设置 → Known Hosts → 删掉那个地址那一条 → 重新连，指纹和 **从手机连** 页上的一致再点 Continue；电脑上 `ssh-keygen -R '[地址]:端口'` 后重连（`fleet` 自己会从入口拿最新的钥匙，不用手动认）。对不上就别认，告诉管理员。

## 从你自己的 AI Agent 管（Claude Code、Codex、Gemini CLI、claude.ai）

你平时用的 Agent 可以替你看、替你管 tokenman 里的会话：问它「tokenman 里有什么要我处理？」，让它给某个会话回一句、回答会话的提问、停掉一个，或者在 Claude / Codex 上新开几个。它经 MCP 连 `https://<入口>/mcp`，身份就是**你**——只看得到你自己的会话、只做你允许的事，随时可以收回。

**浏览器登录（claude.ai、Claude Code、Gemini CLI）**：加上地址，批准一次就行。

```sh
claude mcp add --transport http tokenman https://hub.example.com/mcp   # Claude Code；之后 /mcp → 登录
```

- claude.ai、Claude 桌面版或手机版：设置 → Connectors → 添加自定义连接器 → `https://hub.example.com/mcp` → 登录。
- Gemini CLI，写在 `~/.gemini/settings.json`：`"mcpServers": {"tokenman": {"httpUrl": "https://hub.example.com/mcp", "oauth": {"enabled": true}}}`。

登录页会列出它要什么；不想给的去掉勾，再选能连多久（默认 30 天）。

**或者用个人钥匙（Codex、脚本、任何 Agent）**：控制台 **我的 → Agent → 连接**，选 Agent 和它能做的事，复制给你的那段配置。钥匙只显示一次；放在环境变量里，别写进会分享的文件。Codex 写在 `~/.codex/config.toml`：

```toml
[mcp_servers.tokenman]
url = "https://hub.example.com/mcp"
bearer_token_env_var = "TOKENMAN_TOKEN"
```

**它能做什么**——每个连接各自选：看你的会话和任务（一定有）、给会话发消息、新开会话、停止和恢复会话、替你回答权限提问（默认不给，勾了它就能以你的名义批准操作）。

**收回**：**我的 → Agent → 收回**，它下一次调用就被拒。每个连接都写着上次什么时候用过。
