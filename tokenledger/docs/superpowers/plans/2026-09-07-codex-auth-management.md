# Codex 自动续期、多账号管理与界面说明

用户已授权实施并沿用先 mini Hub、后各机器 agent 的升级顺序。

## 已实现

- 通过官方 App Server `account/read` 的 `refreshToken:true` 在原登录目录续期；到期前 24 小时检查，保留刷新后的官方文件，不复制 refresh token，也不产生模型调用。
- 每个目录使用进程锁：多个受管 Codex 会话可同时使用共享锁，登录和续期使用独占锁。直接启动的 Codex 不参与 ccquota 锁；实际凭据写入仍由官方 CLI 处理。
- 网络/协议临时失败采用持久化退避；明确的刷新凭据失效、撤销或重用停止自动重试，直到观察到新凭据。
- 兼容旧 CLI 返回空账户、仅在 stderr 报告刷新拒绝的行为。诊断只做有界、内存内的已知错误分类，原文不进入日志、Hub 或状态文件。
- 账号注册文件位于各 OS 用户的 `~/.ccquota/codex-profiles.json`，只保存名称与目录；新账号独立存放于 `~/.codex-accounts/NAME`。agent 每轮发现新增目录并沿用已有游标。
- 显式注册/登录记录匹配当前凭据的观察时间，覆盖登录后立即启动、早于下次扫描的首个会话；更换凭据不会继承旧观察记录，既有历史不回填。
- 命令：`ccquota codex list/add/login/use/run/refresh`。`use` 选择新受管会话的默认账号，不改变正在运行的会话或普通 `codex` 命令。
- 启动受管账号时清理环境中的 API/access token 身份覆盖，明确使用 file 凭据。
- Now 的采集卡展示邮箱、套餐、账号目录名称、默认选择、登录/续期状态、时间和管理命令；额度代查独立显示。
- Review 的 KPI 展示请求计价覆盖率、分子分母及未计价原因。SQLite 同一读事务保证原因合计和分母一致；已清理明细的历史请求单独标注，仍计入 token 与请求总数。

## 验证与实机发现

- Go 全量测试和 vet；Codex、agent、store、API 的 race 检查通过。
- 浏览器模块测试包含 13,792 / 14,325 = 96.28% 的请求数口径、空数据和未知费用。
- 进程级假 App Server 测试覆盖刷新写回、两个进程竞争、共享会话锁、撤销/暂时故障、旧 CLI 的空账户响应、刷新错误脱敏，以及账号目录隔离。
- 注册发现测试确认命名已有目录不会更换游标或重放历史。
- mini `24haowan` 通过官方 CLI 0.149.0 实际续期成功：2026-09-08 00:50 UTC 刷新，access token 到期为 2026-09-18 00:50 UTC。
- mini `verkyyi` 与 `verkydev` 的旧刷新凭据已被拒绝。0.149.0 与 0.153.4 均确认不能继续刷新，需要分别完成官方登录；不会通过复制其他机器凭据恢复。
- 当前环境的浏览器与原生 UI 控制不可用，无法代为完成两份旧登录的交互授权。已有有效登录继续提供该账户的额度数据。
- 已将 MacBook `verkyyi` 及 mini 上上述三个现有登录目录注册为 `personal`，保留原始目录和账号归属。

## 使用

```sh
ccquota codex list
ccquota codex run personal
ccquota codex add work
ccquota codex login work
ccquota codex use work
ccquota codex run
```

在 mini 相应 OS 用户下运行 `ccquota codex login personal --device-auth` 可恢复旧登录。浏览器需要用户完成官方授权；无需把 token 粘贴给 ccquota 或 Hub。

登录启动器使用所选账号目录作为工作目录，避免 `sudo -H` 保留 SSH 用户的目录后误读该用户的项目配置；普通 `run` 仍使用当前项目目录。例如：

```sh
ssh -t macmini 'sudo -H -u verkydev /usr/local/bin/ccquota codex login personal --device-auth'
```

## 来源

- [OpenAI 认证说明](https://learn.chatgpt.com/docs/auth)
- [App Server 认证与刷新接口](https://learn.chatgpt.com/docs/app-server#authentication-modes)
- [CODEX_HOME 与环境变量](https://learn.chatgpt.com/docs/config-file/environment-variables)

部署记录在对应 release 目录中保存，包含源码/二进制散列、升级前备份和线上验收。
