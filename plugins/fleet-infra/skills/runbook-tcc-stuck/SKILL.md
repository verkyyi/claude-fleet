---
name: runbook-tcc-stuck
description: 托管 Mac 上 macOS 隐私授权（TCC）卡死的故障手册——屏幕上没人点的授权框把 tccd / sandboxd 堵住，之后删号报 -14120「disallowed by sandbox」或 eDSPermissionError、入口一直「删除中」、开号挂住；怎么认出来、怎么解开、怎么给固定身份一次授权让它不再发生。用于「删号一直删除中」「dscl 报 disallowed by sandbox」「体检 node 行说 TCC 卡住 / 没有完全磁盘访问」「codesign 行 WARN」「开号卡在授权框」。只给管理机器的人用，要能登上那台 Mac 的屏幕或 admin 的 ssh。
---

# runbook-tcc-stuck — 授权弹窗卡死

占位：`<MAC>` 那台托管 Mac · `<ADMIN>` 它的管理员登录名 · `<LOGIN>` 卡住的账号 · `<RT>` 运行时根目录
`/Library/Application Support/claude-fleet`。
权威出处：`docs/dev/MANAGED-NODE.md` §6「删号要完全磁盘访问」「删号不再等这个授权：走本机 ssh」「管理员 agent 一个固定签名身份」；
`docs/dev/BREAK-IT.md` 行 `node-fda-probe-hang` · `tcc-disclaim-sigpipe` · `login-remove-dscl-denied` · `codesign-identity-switch`
（和 #3167 那一行）；`bin/fleet-node-supervisor.py` 的 `tcc_stuck_line` / `fda_line`；`bin/fleet-tcc-disclaim.py`；
`bin/fleet_node_codesign.py`。新机器上架时预先点掉授权框见 [mac-node-prep]；删号本身见 [login-lifecycle]。

**机制，一段话**：macOS 按「签名身份 + 路径」记授权。一个没授权过的程序碰受保护的东西（删用户、读别人的家），用户级
`tccd` 弹框并**一直等**；`sandboxd` 的同步审批队列没有超时、全堵在它后面；之后整台机器经 sandboxd 的检查都挂住——删任何
用户都报 `-14120 disallowed by sandbox`，连 `sudo dscl` 也一样。重启 `opendirectoryd` 没用，重启整机只管到下一次。
fleet 的三道防线：账号脚本经 `fleet-tcc-disclaim.py` 起（只拒不弹）；删号没有完全磁盘访问时走本机 ssh；管理员 agent 跑一个
固定签名身份的固定路径，授权一次跨版本有效。

## 什么时候用

- 入口里某个账号一直「删除中 / removing」，或开号很久没结果。
- `fleet doctor` 的 `node` 行：FAIL「macOS 隐私检查（TCC）卡住了」，或 WARN「没有完全磁盘访问」。
- `fleet doctor --machine` 的 `codesign` 行 WARN（没有固定身份 / 没签上）、`admin-agent` 行 WARN。
- 删号脚本最后几行写着 `eDSPermissionError`、`-14120`、`disallowed by sandbox`。

## 先查什么

在 `<MAC>` 上（admin 的 ssh）：

```sh
sudo python3 "<RT>/current/bin/fleet-node-supervisor.py" status            # fda / tcc 那一行
sudo python3 "<RT>/current/bin/fleet-node-supervisor.py" status --check; echo rc=$?   # 4 没有完全磁盘访问 · 6 TCC 卡住
fleet doctor --machine | grep -E 'codesign|admin-agent|daemon'
sudo python3 "<RT>/current/bin/fleet-node-update.py" codesign              # 固定身份的 CN、sha1、指定要求
pgrep -fl 'TCC.framework/Support/tccd'                                      # 各登录的用户级 tccd
```

- 退出码 **6**（卡住）：FDA 探针连续 `FLEET_NODE_TCC_STUCK`（默认 2）次超时——这才是「卡死」，多半有一个没人点的框。
- 退出码 **4**（没有完全磁盘访问）：不是卡死，是少一次授权；删号会改走本机 ssh，那条路也不通时才失败。
- 一次超时记为「未知」（`fda.timeout`），不是「没有权限」，不用动。

## 步骤

1. **TCC 卡住（退 6）——先解开**，按顺序，好了就停：
   1. 屏幕前（屏幕共享或本人）看控制台登录的桌面：有授权框就点「不允许」（不知道是谁要的就别点允许）。
   2. 杀掉各登录的用户级 tccd（launchd 会拉起）：`sudo kill -9 $(pgrep -f 'TCC.framework/Support/tccd$')`。
   3. 还卡：`sudo killall -9 sandboxd`（launchd 会拉起）。
   4. 再不行才重启整机——它只管到下一次，后面第 3 步必须做。
2. **卡住期间积压的删号**：入口会重试；急的话 admin 的 ssh 手跑一次（ssh 会话自带完全磁盘访问，当「允许远程用户完全磁盘访问」开着）：
   `sudo "<RT>/current/bin/fleet-login-remove.sh" <LOGIN> --delete-home --apply`。
3. **让它不再发生——给固定身份授权一次**（每台机器一次，人在屏幕前点；程序拿不到）：
   1. `sudo python3 "<RT>/current/bin/fleet-node-update.py" codesign` 打出身份；`no identity yet` 就
      `sudo python3 "<RT>/current/bin/fleet-node-update.py" codesign ensure`，或等更新器下一轮。
   2. 系统设置 › 隐私与安全性 › 完全磁盘访问 › ＋，⌘⇧G 输入 `<RT>/agent/ccquota`，加上并打开开关。
   3. 守护的进程链（launchd 起的苹果签名 `python3`）：`node` 行 WARN 点名的那个程序同样加进完全磁盘访问。
   4. 重启：`sudo launchctl kickstart -k system/com.ccquota.agent.<ADMIN>`、`sudo launchctl kickstart -k system/com.claude-fleet.node`。
4. **本机 ssh 删号的路**（没有完全磁盘访问时的兜底）：系统设置 › 通用 › 共享 › 远程登录 打开，ⓘ 里「允许远程用户完全磁盘访问」
   打开，跑删号的 admin 在远程登录的允许名单里。钥匙由 `fleet node install` 和每次删号自己设（幂等），不用手写。
5. **从不**：点「允许」一个你认不出的请求；删掉 `/var/db/fleet-node/codesign/`（换身份 = 所有授权作废，从第 3 步重来）；
   为了绕开把账号脚本改成不经 `fleet-tcc-disclaim.py` 起。

## 怎么验收

- `fleet-node-supervisor.py status --check` 退 0；`fleet doctor` 的 `node` 行 PASS（没有 TCC / 完全磁盘访问的字样）。
- `fleet doctor --machine`：`codesign` 行 PASS 写出身份和要求，`admin-agent` 行 PASS。
- 入口里那个账号从「删除中」消失；或在入口开一个备用登录再删掉，两步都在几分钟内完成（见 [login-lifecycle]）。

## 怎么回滚

- 第 1 步只杀会被 launchd 拉起的系统进程，没有要回滚的。
- 撤回授权：系统设置 › 完全磁盘访问 里关掉开关——节点程序下一次就又经 `fleet-tcc-disclaim.py` 绕开、删号改走 ssh，行为回到授权前。
- 关掉本机 ssh 删号：关「允许远程用户完全磁盘访问」或远程登录；删号回到直删，没有完全磁盘访问时会失败并在脚本最后一行给出 admin 手跑的命令。
