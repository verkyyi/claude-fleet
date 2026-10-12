# 自托管 · 快速开始

目标：在你自己的一台电脑上装好 fleet，开出第一个会话，大约 10 分钟。这条路不需要入口；以后要连起几台机器、给同事开号，再看 [安装与部署](install.md)。

## 准备

- 一台 macOS 或 Linux 电脑，能上网，有终端（Mac 上推荐 iTerm2）。
- 一个 Claude 订阅（Pro / Max / Team），或一个 ChatGPT 订阅（用 Codex）。用订阅登录，不需要 API 密钥。
- 装好 Claude Code 命令行 `claude`（或 Codex 命令行 `codex`），并且用订阅登录过一次。
- 想让会话自己开 PR：装好 `gh` 并执行过 `gh auth login`。只对话、不碰代码仓库的话可以先不装。

tmux 由安装脚本自己带，不用先装。

## 1. 安装

```sh
curl -fsSL https://raw.githubusercontent.com/verkyyi/claude-fleet/stable/bin/fleet-install.sh | sh -s -- --no-hub --host
```

- `--no-hub`：只用这一台，不连入口（本机模式）。
- `--host`：这台电脑自己跑会话（承载）。不加的话，之后也能用 `fleet host on` 打开。

装好后命令在 `~/.local/bin/fleet`。终端说找不到 `fleet` 的话，开一个新终端窗口再试。

## 2. 打开客户端

在终端里敲 `fleet`，回车。

第一次打开时列表是空的，底下写着 `No sessions — type a name`。

## 3. 开出第一个会话

1. 敲一个名字，比如 `hello`，回车。
2. 右边打开一个新会话，里面是 Claude Code。给它一句话，比如「你好，介绍一下你能做什么」。
3. 看到它的回复，就走通了。

## 4. 记住一个键

**⌘P**（iTerm2；别的终端用 **⌃空格** 或 **F12**）打开总面板：所有会话都在这里，选一行就切过去；最上面一行写一句话，就是交给一个新会话的新任务。

关掉终端窗口不会停掉会话，下次敲 `fleet` 回到原样。要彻底退出客户端，用 `fleet quit`（会话照样在跑）。

## 5. 让会话在代码仓库里干活（可选）

在 ⌘P 里选 **添加仓库…**，填 `<owner>/<repo>`。仓库会放到 `~/projects/<repo>`；之后新建会话时选这个仓库，会话就在它自己的副本里改代码、开 PR，不碰你的主目录。

## 下一步

- 每天怎么用：[日常使用](../member/usage.md)
- 连起几台机器、自己架入口、给同事开号：[安装与部署](install.md)
- 卡住了：[故障排查](../troubleshooting.md)
