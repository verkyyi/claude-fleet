# web-term：手机上用的网页终端（原型，#3837）

EPIC #3836 的 C1。手机浏览器打开一页，看到的是**真终端**（xterm.js），里面跑的就是官方 `claude`，不重画界面。
专门对付手机上用 Claude Code 最难受的地方——输入：

- **底部输入框**：中文拼音 / 九宫格 / 手写 / 系统语音听写 / 粘贴都在一个普通输入框里完成，
  按「发送」才把整段文字写进终端。程序开了 bracketed paste（Claude Code、bash/zsh 都开）就整段作为一次粘贴，
  多行不会被拆成多次回车；回车在 40ms 后单独发。输入法组字时的回车归输入法，不会把拼音发出去。
- **键栏**：Esc · ⇧Tab（切模式）· ↑ ↓ · ⏎ · 1 2 3（选项）· ^C · Ctrl（粘滞：再按一个字母）· Tab · ← → · / · @ ·
  「填入」（只填不回车）。按键不抢输入框的焦点，键盘不会收起。
- **滑动翻历史**：程序开了鼠标上报（tmux `mouse on`、Claude Code 全屏模式）就发滚轮，tmux 里即进入翻页模式
  （Esc / q 退出）；否则滚 xterm 自己的历史。点一下终端 = 收起键盘看全屏。
- **直通**：右上角切换，键盘直接逐键打进终端（桌面默认开，手机默认关）。
- **断线重连**：默认命令是 `tmux -u -L webterm new-session -A -s main`（自己的 socket，不碰任何 fleet），
  切网、锁屏回来自动重连，回到同一处。
- 键盘弹起时按 `visualViewport` 收高，输入框始终在键盘上方；可「添加到主屏幕」全屏用。

## 起

```sh
python3 extras/web-term/server.py                 # 默认 :8377，跑 tmux（没有 tmux 就跑登录 shell）
python3 extras/web-term/server.py -- claude       # 直接跑 claude（不经 tmux，断线即结束）
# 接一个 fleet 会话：建一个 grouped 视图（自己的当前窗口，不影响别人看的那一个）
python3 extras/web-term/server.py -- tmux -L <fleet> new-session -A -t <fleet> -s '<fleet>@view-web'
```

启动打印一次性链接 `http://127.0.0.1:8377/?t=<令牌>`；打开后换成 HttpOnly cookie，地址栏里不再带令牌。
`WEBTERM_TOKEN=<固定值>` 可以让重启后链接不变。只用 Python 标准库（macOS 自带 python3.9 可跑），无需 npm。

**只听 127.0.0.1，没有任何选项能放宽。** 手机经你自己的通道进来：

- **Tailscale（推荐）**：在跑服务的机器上 `tailscale serve --bg 8377`，手机（同一 tailnet）打开
  `https://<机器名>.<tailnet>.ts.net/?t=<令牌>`。只在 tailnet 内可见、自带 HTTPS。关：`tailscale serve --https=443 off`。
- **SSH 端口转发**：Termius 等里加一条本地转发 8377 → 127.0.0.1:8377，手机打开 `http://127.0.0.1:8377/?t=<令牌>`。

## 真机清单（C1 的验收）

在 iOS Safari 与安卓 Chrome 上各走一遍，跑着 Claude Code 的提示框：

| 项 | iOS | 安卓 |
|---|---|---|
| 全拼输入「你好，世界」发送：整段到达、不丢字、不上屏拼音 | | |
| 九宫格输入同上 | | |
| 手写输入同上 | | |
| 系统语音听写一段话发送 | | |
| 粘贴多行（3 行以上）：作为一条提示，不被拆开 | | |
| 组字过程中按回车：只上屏候选，不发送 | | |
| 键栏 ⇧Tab 切模式、Esc 打断、1/2/3 选权限选项 | | |
| Ctrl → c 打断正在跑的命令 | | |
| 键盘弹起时输入框在键盘上方，终端跟着收高 | | |
| 上下滑动翻历史（tmux 翻页模式 / Claude 全屏的对话） | | |
| 锁屏 1 分钟再回来：自动重连回到同一画面 | | |
| 添加到主屏幕后全屏打开 | | |

## 不在这一版

经 hub 登录与转发（C2/C3）、会话列表与按状态换键栏（C4）、截图上传（C5）、推送（C6）——见 #3836。

自测：`bin/fleet-webterm-selftest.sh`。xterm.js 5.5.0 及插件放在 `ui/vendor/`（MIT，`LICENSE.xterm`），不连 CDN。
