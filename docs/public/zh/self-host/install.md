# 安装与部署

> 这一篇在写（由 C9 补齐）。今天先照 [自托管 · 快速开始](quickstart.md) 在一台电脑上跑起来。

## 大纲

- 选哪种装法：只有一台电脑（本机模式）· 自己架入口连起几台机器（联机模式）
- 准备：系统、订阅、`claude` / `codex`、`gh`，入口需要的域名与证书
- 架入口：一个程序、一个端口；SQLite 或 Postgres；Kubernetes 通用清单与 `overlays/example`
- 入口的第一位管理员：在部署配置里写明谁是管理员
- 登录方式：微信、邮箱、GitHub，各需要哪些配置
- 加一台机器：在「机器」页拿加入码，在机器上执行一条命令
- 装客户端：`curl -fsSL https://hub.example.com/install | sh`
- 升级与回退：跟随稳定版
- 卸载
