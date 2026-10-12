---
name: login-lifecycle
description: 在托管机器上给一个人开号、删号、回收备用登录——优先从入口（`fleet hub accounts assign|remove`）做，入口做不了时在机器上用 fleet-login-new.sh / fleet-login-remove.sh；开号前看备用、删号前归档家目录。用于「给某人开个号」「这个人走了，删号」「入口一直显示删除中 / 开号中」「备用登录不补」。只给管理机器的人用。
---

# login-lifecycle — 开号与删号

占位：`<HUB_URL>` 入口 · `<NODE>` 机器名 · `<LOGIN>` 登录名 · `<PRINCIPAL>` 入口里的人（如 `gh:<id>`）·
`<ADMIN_LOGIN>` 机器的管理员登录。名字只用人给的，不猜。
权威出处：`docs/dev/SHARED-MACHINE.md` §1、§6、「The whole walk in one command (smoke test)」、「Offboarding a person」；
`docs/dev/MANAGED-NODE.md` §3（`spare_accounts`）、§6「删号要完全磁盘访问」「删号不再等这个授权：走本机 ssh」；
Linux 机器见 `docs/dev/MANAGED-LINUX.md`「Opening and closing a login from the hub」。

## 什么时候用

- 一个人要在某台机器上有自己的登录；一个人离开，删掉他的登录。
- 入口的账号行停在「开号中 / 删除中 / 坏了」不动。
- 机器的备用登录（预先开好、领了就用）不补、或回收后不干净。

## 先查什么

```sh
fleet hub machines        # 每台：备用 N · 已用 M / 上限 K，回收中 / 坏了
fleet hub accounts        # 每个人在哪台、什么状态
```

- 机器到了上限（`fleet.node_user_cap.<NODE>`）就换一台或先删一个。
- 删号前问清：**家目录留不留**（默认归档到 `/Users/Shared/offboarded/`，只有管理员能读）。
- 机器没有「完全磁盘访问」授权时删号走本机 ssh 一路（`mac-node-prep` 第 4 步、`mac-node-enroll` 第 4 步）；远程登录的「允许完全磁盘访问」关着会退出 7。

## 步骤

**开号（首选入口）**
1. `fleet hub accounts assign <PRINCIPAL> --host <NODE> [--login <LOGIN>]`——有备用就当场领（变成他的），没有就新开（托管 Mac 上十几分钟）。
2. `fleet hub accounts` 看这一行到「就绪」。

**开号（入口不可用时，在机器上，以 `<ADMIN_LOGIN>` 运行，不加 sudo）**
1. 预演：`~/.claude/fleet/bin/fleet-login-new.sh <LOGIN> --full-name "<全名>" --pubkey <他的公钥文件> --share-pool`
2. 照做：同一行加 `--apply`。最后一行应是 `credsep: separated`。没给 `--pubkey` 会生成临时钥匙写进欢迎信（`~/<LOGIN>-onboard/`），交给本人后让他换成自己的。
3. 要交给整机守护：见 `mac-node-enroll` 第 3 步 `account adopt`。

**删号（首选入口）**
1. `fleet hub accounts remove <PRINCIPAL> --host <NODE>`，然后 `fleet hub accounts` 看到这一行消失。

**删号（在机器上）**
1. 预演：`~/.claude/fleet/bin/fleet-login-remove.sh <LOGIN>`
2. 照做：加 `--apply`（默认 `--keep-home` 先归档；`--delete-home` 不归档，确认过才用）。
   退出码：3 拒绝 · 4 没有这个登录 · 6 服务还没挪走（先 `account release`）· 7 远程登录没开完全磁盘访问。

**备用登录**
- 开关和数量：`fleet hub set fleet.spares …`、`fleet.spare_max`（默认 2）；单台：入口机器页的期望状态 `spare_accounts`。
- 坏掉的备用不会自动补：查明原因后 `fleet hub accounts forget …`。
- 回收后复用前查干净：`sudo ~/.claude/fleet/bin/fleet-login-reset-check.py <LOGIN>` → `reset: clean`。

## 怎么验收

- 开号：本人用自己的钥匙 `ssh <LOGIN>@<NODE>` 能进；以他的身份 `~/.claude/fleet/bin/fleet-doctor.sh | grep onboard` PASS；
  `dscl . -read /Groups/com.apple.access_ssh GroupMembership` 里有他。
- 删号：`id <LOGIN>` 报没有此用户；`com.apple.access_ssh` 里没有他的名字；入口不再列他；归档文件在（`--keep-home` 时）。
- 整条路走一遍（新机器或怀疑开删号坏了）：`~/.claude/fleet/bin/fleet-login-smoke.sh`——开一个临时登录、走完、删掉。

## 怎么回滚

- 开错了：照「删号」走一遍（新号没有数据，可用 `--delete-home`）。
- 删错了且保留了家目录：用同名重新开号，再从 `/Users/Shared/offboarded/<LOGIN>-*.tar.gz` 恢复他要的文件（只恢复他的文件，不恢复 `.claude` 里的凭据池）。
- `--delete-home` 删掉的家目录找不回：这是删号前必须问清的原因。
- 入口一直「删除中」：先看机器上 `fleet-login-remove.sh <LOGIN>` 预演说什么；授权卡住按 `mac-node-prep`「怎么回滚」的授权框处理。
