# 安全策略 · Security Policy

## 报告漏洞 · Reporting a vulnerability

**请不要开公开 issue。** 只有一条路：**GitHub 私密漏洞报告**——仓库页 → Security → [Report a vulnerability](https://github.com/verkyyi/claude-fleet/security/advisories/new)。只有你和维护者看得到。我们不设报告邮箱。

请写上：影响哪个组件（客户端、托管机器、入口）、哪个版本（`fleet doctor` 里 `fleet` 那一行写的版本）、怎么复现、你看到的后果。有利用代码的话附上，但请只在你自己的机器和账号上试。

**Please do not open a public issue.** Report privately through GitHub's
[private vulnerability reporting](https://github.com/verkyyi/claude-fleet/security/advisories/new)
— it is the only channel; there is no security mailbox.
Include the component (client, managed machine, hub), the version (the
`fleet` row of `fleet doctor`), steps to reproduce and the impact.

## 多久回复 · Response times

| 阶段 | 时限 |
|---|---|
| 确认收到 | 3 个工作日内 |
| 初步判断（是否成立、严重程度） | 7 天内 |
| 修复上线 | 严重的尽快，一般不超过 30 天；修好后发布新的 stable，并在 GitHub Security Advisories 公开说明 |

We acknowledge within 3 business days, give a first assessment within 7 days,
and ship a fix as a new `stable` release (usually within 30 days, sooner for
critical issues), followed by a published GitHub Security Advisory. We credit
reporters who want to be named.

## 支持的版本 · Supported versions

fleet 的发布就是 git 标签 `stable` 所指的那个提交；每台机器自动跟随它。安全修复只做在：

| 版本 | 支持 |
|---|---|
| 当前 `stable` | ✅ |
| 上一个 `stable` | ✅（修复会随下一个 stable 一起到） |
| 更早的提交 | ❌ 请先升级（`fleet update`） |

A release is the commit the `stable` git tag points at, and every machine
follows it automatically. Security fixes cover the current `stable` and the one
before it; anything older, please `fleet update` first.

## 范围 · Scope

在范围内：本仓库的代码——客户端 `fleet`、托管机器上的守护与脚本、入口 `ccquota`（`tokenledger/`）、部署清单（`deploy/`）。

不在范围内：Claude Code、Codex、GitHub 等上游产品本身的漏洞（请报给它们）；需要先拿到某台机器 root 或管理员账号才能做的事；拒绝服务与社会工程。

谁能看到什么、凭据放在哪、各活多久：见对外文档 [安全与隔离](docs/public/zh/security.md)。
