# 自托管 · 快速开始

目标：在你自己的一台电脑上装好 fleet，开出第一个会话，大约 10 分钟。有入口就从入口装；没有入口也能只用这一台。以后要连起几台机器、给同事开号，再看 [安装与部署](install.md)。

## 准备

- 一台 macOS 或 Linux 电脑，能上网，有终端（Mac 上推荐 iTerm2）。
- 一个 Claude 订阅（Pro / Max / Team），或一个 ChatGPT 订阅（用 Codex）。用订阅登录，不需要 API 密钥。
- 装好 Claude Code 命令行 `claude`（或 Codex 命令行 `codex`），并且用订阅登录过一次。
- 想让会话自己开 PR：装好 `gh` 并执行过 `gh auth login`。只对话、不碰代码仓库的话可以先不装。

tmux 由安装脚本自己带，不用先装。

## 1. 安装

**从入口装**（你们团队的入口，或照 [安装与部署](install.md) 自己架的）：装的是入口签过名的版本，装机、以后跟版、起 Claude / Codex 都不找 GitHub。

```sh
curl -fsSL https://hub.example.com/install | sh -s -- --host
```

`hub.example.com` 换成你的入口地址。

- `--host`：这台电脑自己跑会话（承载）。不加的话，之后也能用 `fleet host on` 打开。

> **备注：没有入口、只用这一台**——直接从 GitHub 装：
>
> ```sh
> curl -fsSL https://raw.githubusercontent.com/verkyyi/claude-fleet/stable/bin/fleet-install.sh | sh -s -- --no-hub --host
> ```
>
> `--no-hub`：不连入口（本机模式）。这条路装和以后跟版都找 GitHub；GitHub 连不上时 `fleet update` 说「GitHub 不通，留在当前版」，不会一直等。

装好后命令在 `~/.local/bin/fleet`。终端说找不到 `fleet` 的话，开一个新终端窗口再试。

装完会在这个终端里直接打开客户端。没有终端的地方（管道、CI、远程脚本）装完说一句「没有终端，跳过打开客户端」，退出码是 0——之后在终端里敲 `fleet` 打开。

全部参数和自动化用的环境变量（`FLEET_INSTALL_HOST=0|1` 等同 `--host`，`FLEET_INSTALL_HUB=0` 等同 `--no-hub`）：

```sh
curl -fsSL https://hub.example.com/install | sh -s -- --help
```

## 2. 打开客户端

在终端里敲 `fleet`，回车。

第一次打开时列表是空的，底下写着 `No sessions — type a name`。

## 3. 开出第一个会话

1. 敲一个名字，比如 `hello`，回车。
2. 右边打开一个新会话，里面是 Claude Code。给它一句话，比如「你好，介绍一下你能做什么」。
3. 看到它的回复，就走通了。

## 4. 记住一个键

**⌘P**（iTerm2；别的终端和手机用 **F12** 或 **⌃] p**）打开总面板：所有会话都在这里，选一行就切过去；最上面一行写一句话，就是交给一个新会话的新任务。

关掉终端窗口不会停掉会话，下次敲 `fleet` 回到原样。要彻底退出客户端，用 `fleet quit`（会话照样在跑）。

## 5. 让会话在代码仓库里干活（可选）

在 ⌘P 里选 **添加仓库…**，填 `<owner>/<repo>`。仓库会放到 `~/projects/<repo>`；之后新建会话时选这个仓库，会话就在它自己的副本里改代码、开 PR，不碰你的主目录。

GitHub 仓库名的大小写不影响任务创建或迁移；已有仓库配置和工作目录保留原名。
创建失败时查看提示的具体原因：`frozen` 表示迁移尚未完成，输入/注册错误需要检查所选仓库，
`HTTP 401/403` 需要检查承载机器的认证与权限，入口不可用则等服务恢复后重试。
无需为了大小写重新添加仓库或手动解除冻结。

任务由谁来派，是**你这个人**的设置，不按仓库分：切到 hub 之后，你在所有仓库里的新任务都由 hub 派发；
同一个仓库里别人的会话不受影响，也不会挡你。新添加的仓库不单独选，跟着你走。

**新开的账号默认就是 hub**：入口给你开号（邀请、申请通过、管理员添加）时就写好了，你的机器第一次连上入口就会跟上，
第一次在 ⌘P 或 `task` 里派活就由 hub 派发，下面的迁移步骤不用做。

在这之前就有账号、还在旧方式上的人，要把任务交给 hub，先在你的任一承载机器上保存私有迁移清单：

```sh
~/.claude/fleet/bin/fleet-repo.sh authority --dry-run > /private/path/my-manifest.json
```

（后面加 `owner/repo` 只是把清单里的列表缩到那个仓库。）检查清单里你的承载机器、执行者和阻塞项，然后按顺序：

1. **冻结**：`--freeze --manifest /private/path/my-manifest.json`，暂停你的新开工；
2. **收尾**：让你正在跑的会话写好交接后结束，在原节点确认原生进程已停止
   （`--settle --apply` 一次结清本机已结束的启动记录）；
3. **切换**：重新保存 `--dry-run`，阻塞项清零后带新清单执行 `--apply`；
4. **回退**：`--rollback`，同样先冻结、刷新清单，并等 hub 已接受的任务结束且释放执行权。

你的机器不具备能力、离线或执行者状态不明时，切换会被拒绝。你的其他登录会自动跟上。清单包含机器和任务引用，请勿公开。

这只改变任务控制。单子设置、GitHub 代码托管和 PR 检查保持原样；任务完成后，PR 仍可能在等 GitHub。

## 下一步

- 每天怎么用：[日常使用](../member/usage.md)
- 连起几台机器、自己架入口、给同事开号：[安装与部署](install.md)
- 卡住了：[故障排查](../troubleshooting.md)
