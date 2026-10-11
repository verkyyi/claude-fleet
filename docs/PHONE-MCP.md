# 手机 MCP：一份常驻，给自己所有的登录用（#3247）

人的手机（Xiaomi 17 Pro Max）USB 接在 mini2 上，由 `mcp-server-mobile` 经 adb 驱动。以前每个会话各起一份：
`ssh -T m4 phone-mcp` → stdio，一个会话一个 adb 客户端（和 #3221 同一个根因），连不上 mini2 的登录就没有手机。

现在 **只有一份**，由管理员登录 `verkyyi` 在 mini2 上常驻，人的每个登录经 tailnet 连它：

```
各登录的 Claude Code / Codex ──http + Bearer──▶ mini2 tailnet:47230  (fleet-phone-mcp.py serve：鉴权代理)
                                                    └──▶ 127.0.0.1:47231  mcp-server-mobile --listen
                                                                └──▶ adb server tcp:5037（属于 verkyyi；sms-watch 也用它）
```

- **只听本机和 tailnet 地址**（`127.0.0.1` + `tailscale ip -4`），从不听 `*`；路由器不转发，不上公网。
  tailnet 还没起来时代理每 15 秒再试一次绑定。`--bind 0.0.0.0` 直接拒绝。
- **令牌**：`~verkyyi/.config/fleet-phone/tokens.json`（0600），代理改了文件就重读，不用重启。
  没带令牌或令牌不对 = 401，记一行 `denied <来源 IP>`（日志里从不出现令牌）；令牌不往 mcp-server-mobile 传。
- **adb**：服务用自己那份去掉隔离属性的 adb（从 Homebrew cask 复制，和 sms-watch 是同一版本——版本不同的
  adb 客户端会把服务端杀掉重起）。起来时若 5037 上的服务端是别的登录起的，能 `sudo -n` 就把它停掉自己接手，
  不能就在日志里点名一次（照样共用）。
- **客户端**：Claude Code 是用户级 `phone` = `{type: http, url, headersHelper}`——helper
  （`fleet-phone-mcp.py client header`）从 `~/.config/fleet-phone/client.json`（0600）读令牌，配置里没有令牌；
  Codex 没有 helper，`config.toml` 里一段带标记的 `[mcp_servers.phone]`（`http_headers`，人允许把自己的密钥放进
  自己的配置），按文本改，其余每一行原样。

## ⚠️ 几个会话同时用会互相干扰

手机只有一块屏幕、一份输入。两个会话同时点、同时输入，会点到对方打开的页面上、把字输进对方的输入框。
**同一时间只让一个会话操作手机**；要并行的活，排队做。

## 装（管理员，在 mini2 上，一次）

```sh
# 1. verkyyi 自己的一份 mobile-mcp（和 verky 那份同版本）
sudo -u verkyyi -H /opt/homebrew/bin/npm install --prefix /Users/verkyyi/.local/opt/mobile-mcp @mobilenext/mobile-mcp@1.0.9

# 2. 登记给整机守护（开机即起、退出即重起；不写 LaunchAgent，见 MANAGED-NODE §10/§13）
sudo -u verkyyi -H fleet service add phone-mcp -- \
    /usr/bin/python3 "/Library/Application Support/claude-fleet/current/bin/fleet-phone-mcp.py" serve
sudo -u verkyyi -H fleet service ls          # phone-mcp 在跑

# 3. adb 服务端交给 verkyyi（verky 的 sms-watch 下一次 adb 调用就连上它）
sudo pkill -u verky -f 'adb .*fork-server'; sudo -u verkyyi -H fleet service restart phone-mcp
sleep 20; ps -axo user=,command= | grep '[f]ork-server'   # 只剩一个，属于 verkyyi

# 4. 防火墙（2026-10-11 是关的）开着的话，放行 python3 进站（只在 tailnet 地址上听）
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
```

## 配每个登录（管理员；令牌只走管道）

URL 用 mini2 的 tailnet 全名：`http://mini2.tail435588.ts.net:47230/mcp`。

```sh
PM="/Library/Application Support/claude-fleet/current/bin/fleet-phone-mcp.py"
URL=http://mini2.tail435588.ts.net:47230/mcp
# mini2 上的两个登录
for u in verkyyi verky; do
  sudo -u verkyyi -H /usr/bin/python3 "$PM" token | sudo -u $u -H /usr/bin/python3 "$PM" client set --url $URL
done
# macmini 上的两个登录（在能 ssh 到两台的管理员终端里）
for u in verkyyi verky; do
  ssh mini2 "sudo -u verkyyi -H /usr/bin/python3 '$PM' token" \
    | ssh macmini "sudo -u $u -H /usr/bin/python3 '$PM' client set --url $URL"
done
```

`client set` 先 `claude mcp remove phone -s user` 再 `add-json`，旧的 ssh/stdio 配置随之换掉；已经开着的会话要重开才换。
别人的登录不配。`client show` 看配了什么（令牌打码），`client unset` 撤掉。

## 换令牌

```sh
sudo -u verkyyi -H /usr/bin/python3 "$PM" rotate        # 旧令牌再管用 10 分钟（--grace 秒）
# 10 分钟内把上面「配每个登录」那段再跑一遍
```

Claude Code 每次连接都跑 helper，新文件写下去就生效；Codex 在下一次启动时读新的 `config.toml`。

## 验收

```sh
claude mcp list | grep phone                  # 四个登录：phone … (HTTP) - ✔ Connected
codex mcp list | grep phone                   # url + Bearer（打码）
sudo -u verkyyi -H /usr/bin/python3 "$PM" status   # proxy up · phone mcp up · adb server verkyyi · token 年龄
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://mini2.tail435588.ts.net:47230/mcp   # 另一台、不带令牌：401
sms-watch --test                              # verky：照常推送
```

mini2 重启后：守护拉起 `phone-mcp`，`status` 三行都是 up、adb 属于 verkyyi（sms-watch 抢先起了服务端时，日志里有一行
`WARN adb server on 5037 is verky's`——按装的第 3 步停掉一次）。

`bin/fleet-phone-mcp-selftest.sh` 钉住：鉴权、流式转发、换令牌的宽限、拒绝通配绑定、Codex 配置的文本改写、令牌不进 argv / 日志。
