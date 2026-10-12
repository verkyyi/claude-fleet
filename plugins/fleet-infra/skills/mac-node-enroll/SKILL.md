---
name: mac-node-enroll
description: 让一台准备好的 Mac 加入入口、成为托管机器——拿加入码、跑一条 `fleet node install --join`、把账号交给整机守护、体检全绿；同一条命令也是修复。用于「新 Mac 入网」「托管机器装了一半」「重新加入」「把一台机器退出托管」。先走 mac-node-prep。只给管理机器的人用。
---

# mac-node-enroll — Mac 入网

占位：`<HUB_URL>` 入口地址（机器上读 `grep FLEET_HUB_URL ~/.config/claude-fleet/fleet.conf`，或问人）·
`<NODE>` 机器名 · `<LOGIN>` 要交给守护的登录 · `<ADMIN_LOGIN>` 管理员登录。
权威出处：`docs/MANAGED-NODE.md` §2 加入码、§6 一个节点程序（`account adopt` / `release`）、§7「机器体检」、
§8 一条命令装成托管机器、§15 破坏能力 = 登录的能力。下面不复述步骤表，以 §8 为准。

## 什么时候用

- `mac-node-prep` 走完的新 Mac 要接进入口。
- 托管机器某一步坏了或装了一半——**同一条命令再跑一遍就是修**，已满足的步骤「跳过」。
- 一个登录要交给 / 退出整机守护；一台机器要退出托管。

## 先查什么

```sh
curl -fsS <HUB_URL>/healthz                    # 入口在
ls /var/db/fleet-node/machine.env 2>/dev/null  # 已有 = 这台入过网，再跑是修复，不必新码
dscl . -read /Groups/admin GroupMembership     # 管理员是谁（§15：管理员登录不交给守护）
```

- 加入码：入口「机器」页 › 「添加机器」（托管、可信）。一次性、1 小时内有效；**不贴进 issue、评论、聊天**。
- 要交给守护的登录必须**不是管理员**（adopt 对管理员退出 5）。

## 步骤

1. 干净的 Mac（还没有 fleet）——用入口页给出的那一行：
   ```sh
   curl -fsSL <HUB_URL>/install/bin/fleet-node-install.sh | sudo bash -s -- --hub <HUB_URL> --join <码>
   ```
   已有 fleet：`sudo fleet node install --join <码> [--hub <HUB_URL>]`。
   码不想出现在命令行：`--join-file <文件>`（读后删除）。
2. 看每一步的结论（检查 · 加入 · 发布公钥 · 期望状态 · ccquota · 运行时 · 角色用户 · ssh CA · 守护 …）。
   一步失败就停在那，打印原因和重跑命令——修好原因后**原样重跑**，不要手动补后面的步骤。
3. 把每个要跑会话的登录交给守护（先 `--dry-run` 看一眼）：
   ```sh
   sudo "/Library/Application Support/claude-fleet/current/bin/fleet-node-supervisor.py" account adopt <LOGIN> --dry-run
   sudo "/Library/Application Support/claude-fleet/current/bin/fleet-node-supervisor.py" account adopt <LOGIN>
   ```
   令牌过期就加 `--rejoin`。
4. 人在屏幕前做一次授权（§6「要人做一次（每台机器）」）：给管理员 agent 和守护的 python3「完全磁盘访问」，
   然后 `sudo launchctl kickstart -k system/com.ccquota.agent.<ADMIN_LOGIN>`。

## 怎么验收

- `fleet doctor --machine`：runtime · ccquota · claude · codex · tmux · daemon · cache · credsep · install · codesign 全 PASS，退出码 0（= FAIL 个数）。
- `sudo …/fleet-node-supervisor.py status --check` 退出 0（1 过时 · 2 没装 · 4 没完全磁盘访问 · 5 卡住 · 6 授权框卡住）；
  `… account list` 列出交过去的登录；`… tenants --check` 无管理员租户。
- 每个交过去的登录：`fleet doctor` 的 `node` · `update` · `tenants` · `spotlight` 行 PASS。
- 入口：`fleet hub machines` 里有 `<NODE>`，状态在线；从入口往它派一个会话能回话。

## 怎么回滚

- 把一个登录还回去：`sudo …/fleet-node-supervisor.py account release <LOGIN>`（它的启动项从 attic 放回；还有服务在跑退出 6）。
- 卸掉守护：`sudo …/fleet-node-supervisor.py uninstall`（状态留在 `/var/db/fleet-node`，再装即恢复）。
- 让入口不再认这台机器：管理员在自己电脑上（环境里有 `CCQUOTA_VIEWER_TOKEN`）
  `~/.claude/fleet/bin/fleet-node-revoke.sh <NODE>[:<LOGIN>] --reason <原因>`。**撤销不可逆**，要回来就新码重新加入。
- 一个登录自己离开：`fleet node leave [--hub-only] [--dry-run]`。
- 升级坏了不用手动回滚：更新器换版后体检出现新的 FAIL 会把整套退回上一版（§7）。
