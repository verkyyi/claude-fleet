---
name: mac-node-prep
description: 把一台新 Mac 准备成能无人值守跑会话的机器——在它加入入口（mac-node-enroll）之前：关睡眠、Spotlight、Siri、iCloud 同步、自动更新，开自动登录和远程登录，装命令行工具，并预先点掉会卡住无人值守步骤的授权弹窗。用于「新 Mac 上架」「机器老是睡着 / 断线」「装机卡在授权框」「机器 CPU 被 Spotlight 吃满」。只给管理机器的人用。
---

# mac-node-prep — 新 Mac 上架前的准备

占位：`<NODE>` 这台机器的名字 · `<ADMIN_LOGIN>` 它的管理员登录。没有值就问人，不猜。
权威出处：`docs/HOST.md`「An unattended Mac」「All at once: fleet-host-tune.sh」「Verify」；
`docs/MANAGED-NODE.md` §6（完全磁盘访问、远程登录）、§19（Spotlight）；`docs/BREAK-IT.md` 行
`tcc-prompt-wedge`、`node-fda-probe-hang`。这里只列顺序和判据，细节以它们为准。

## 什么时候用

- 一台 Mac 第一次要变成托管机器，或重装系统之后——在 `mac-node-enroll` 之前走完。
- 已上架的机器反复睡着、断电后不回来、负载被 `mds*` / `spotlightknowledged` 撑高。
- 装机或开号时屏幕上弹出授权框、没人点，步骤卡住。

## 先查什么

在这台 Mac 上，用 `<ADMIN_LOGIN>` 登录（屏幕前或 ssh）：

```sh
sw_vers; uname -m                         # macOS 版本与芯片
dscl . -read /Groups/admin GroupMembership # 你是管理员
xcode-select -p                            # 命令行工具在不在（/usr/bin/python3 要它）
fdesetup status                            # FileVault：无人值守要 Off 才能自动登录
pmset -g | grep -E '^\s*(sleep|autorestart|womp)'
mdutil -a -s                               # 各卷索引状态
systemsetup -getremotelogin                # 需要 sudo
```

机器上已有 fleet 时，`bash ~/.claude/fleet/bin/fleet-host-tune.sh`（= `--plan`，什么都不改）一次列出现在 → 目标 → 命令。

## 步骤

1. **命令行工具**：`xcode-select --install`（屏幕前点「安装」）。没有它 `fleet-node-install.sh` 停在「检查」一步。
2. **一条命令做能用命令做的**（已装 fleet 时）：
   `bash ~/.claude/fleet/bin/fleet-host-tune.sh --apply`（逐项问 y/N；`--yes` 不问）——
   spotlight · nofile · sleep · siri · network（双网卡只留有线）。每个 CHANGE 行打印它的撤销命令，**记下来**。
   还没装 fleet：照 `docs/HOST.md` 手动执行同样几条：
   ```sh
   sudo pmset -a sleep 0 autorestart 1 womp 1
   sudo systemsetup -setrestartfreeze on
   sudo mdutil -a -i off && sudo mdutil -a -E
   ```
3. **命令做不了、要人在设置里点的**（`fleet-host-tune.sh` 明说不管）：
   - FileVault 关（`fdesetup status` = Off）——无人值守机器靠机房做物理安全；带出门的笔记本不要关。
   - 系统设置 › 用户与群组 › 自动登录 → fleet 跑在的那个登录。
   - 系统设置 › 通用 › 共享 › 远程登录：开；ⓘ 里打开「允许远程用户完全磁盘访问」，允许名单加 `<ADMIN_LOGIN>`。
   - Apple 账户：退出，或至少关 iCloud 云盘、通讯录、日历、提醒、备忘录、照片。
   - 系统设置 › 通用 › 软件更新 › 自动更新：关「安装 macOS 更新」（系统升级由人挑时间做；fleet 自己的部件由更新器跟发布版走）。
   - 锁屏 / 屏保：显示器可以睡，但别让「需要密码」把无人值守的 GUI 授权步骤挡在锁屏后。
   - 系统设置 › 通用 › 登录项：去掉会开窗口的程序；控制台只跑 fleet 的 tmux。
4. **授权弹窗——先点掉，别等它卡住**：开号脚本碰到受保护的东西时 macOS 弹框，屏幕前没人点，整机经 sandboxd 的检查会挂住（BREAK-IT `tcc-prompt-wedge`）。
   上架时人在场，把需要的授权一次给齐：入网（`mac-node-enroll`）装完后照 `docs/MANAGED-NODE.md` §6「要人做一次（每台机器）」给管理员 agent 加「完全磁盘访问」，给守护的 python3 加同样的授权。
5. 托管机器上 Spotlight 由守护的 `spotlight` 任务每小时关一次；要保留：`sudo touch /var/db/fleet-node/spotlight.keep`。

## 怎么验收

- `bash ~/.claude/fleet/bin/fleet-host-tune.sh` 说 `nothing to change`。
- `fleet doctor` 的机器部分：`sleep` · `siri` · `spotlight` · `nofile` · `network` 为 PASS（`icloud` 退出账户前是 INFO）：
  `bash ~/.claude/fleet/bin/fleet-doctor.sh 2>&1 | grep -E '^\s*\S+\s+(spotlight|nofile|sleep|siri|icloud|network)'`
- 拔电再上电（或 `sudo shutdown -r now`）：不碰键盘，几分钟内 ssh 能进、自动登录的会话在。
- 入网之后再看一次：`fleet doctor --machine` 全绿，`fleet-node-supervisor.py status --check` 退出 0（6 = 授权框卡住，按第 4 步处理）。

## 怎么回滚

- `fleet-host-tune.sh` 每行打印的撤销命令照着跑；常用的：
  `sudo pmset -a sleep <分钟>`、`sudo pmset -a autorestart 0 womp 0`、`sudo systemsetup -setrestartfreeze off`、`sudo mdutil -a -i on`。
- 自动登录、FileVault、iCloud、自动更新：在同一个设置面板里改回去。
- 授权已经卡住（`status --check` 退出 6）：点掉框；`kill -9` 用户级 `tccd`；还卡就 `sudo killall -9 sandboxd`。
- 一台机器本来就要睡（笔记本）：`FLEET_DOCTOR_SLEEP=0` 让体检别再报，不要改回整套设置。
