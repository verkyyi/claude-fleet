---
description: Design one ordinary Task — explain the problem, intended behavior, implementation and acceptance on a shared page.
---

# /fleet-task-plan — 一个 Task 的设计页

<!-- fleet skill · owner: task -->

把用户的目标写成可直接实施的设计方案。复杂工作仍是一个 Task，由负责它的
Agent 自行使用原生 Subagent 或 inline 完成；不创建 EPIC、Batch、Parent–Child
关系或专属 driver。`fleet-epic` 包名和 `epic-page` 文件路径暂留兼容旧安装，
它们只提供通用页面模板，不代表新的任务集合。

`$ARGUMENTS` 是用户的主题，可带 `--repo <owner/name>`。已有当前任务与主题时
直接沿用；信息缺失时先读上下文并完成不依赖答案的调查。

## 1. 读取现状与任务环境

先读现有界面、实现、任务正文和用户约束。方案中的原因须有可核验的代码、日志、
原生事件或复现证据；新功能说明当前行为及预期变化。不要为了写方案创建新会话。

需要确定仓库时使用现有 resolver；变量只在当前 shell 调用中有效：

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
TASK_FLEET=$(fleet_current_session)
fleet_load_conf "$TASK_FLEET"
TASK_REPO=$(fleet_target_repo "$TASK_FLEET" "<explicit repo or empty>")
TASK_REPO_RC=$?
```

`TASK_REPO_RC=4` 表示需用户选择仓库，`1` 表示该仓库不在 Fleet 中；不要猜测。
只写设计页不要求 Hub 在线。确需新建独立 Task 时，再读取
`fleet-task-record.sh authority` 验证 Hub；失败时保留方案，不改用 GitHub issue。

## 2. 制作方案与最终效果

使用同一页面的两层阅读结构：表层为用户展示问题、目标、最终行为、风险与必要选择；
展开后完整提供技术方案、文件位置、接口约束、实施顺序及验收方法。

```sh
cp ~/.claude/fleet/plugins/fleet-epic/skills/epic-page/task-page.example.json <scratchpad>/task-<slug>.json
python3 ~/.claude/fleet/bin/fleet-task-page.py render <scratchpad>/task-<slug>.json -o <scratchpad>/task-<slug>.html
```

填入本次任务内容，不沿用示例的事实。界面变化使用「改前 / 改后」：
`compare: {"before": {"html": "…"}, "states": [{"label": "运行中", "html": "…"}]}`
可表达多个最终状态。渲染器和
`plugins/fleet-epic/skills/epic-page/SKILL.md` 管理公共样式。核心字段：

| 内容 | 字段与要求 |
| --- | --- |
| 问题与原因 | `problem`、`cause.steps`；证据跟随其支持的原因，未知写明未知 |
| 新功能 | `kind: feature`；说明现在的行为与为什么需要调整 |
| 目标与范围 | `metrics`、`charter.do/dont`；每个指标有现状、目标及测量方法 |
| 解决方案 | `members` 是页面里的实施项，不是 Hub 子任务；每项写最终行为与技术细节 |
| 界面变化 | 实施项的 `compare` 放当前真实界面及最终落地原型，覆盖相关尺寸与状态 |
| 风险 | `risks`、`risks_tech`；具体失败方式及处理办法 |
| 需要决定 | `signoff` 只列真正未决且阻止相应工作的选择；已有授权不再请求确认 |
| 验收 | `evidence` 写场景、证据来源和通过标准；完成状态必须有实际验证证据 |

标题、摘要、状态标记尽量简短。无额外信息的行不要显示展开箭头。不要把技术字段
直接堆在界面表层。原型按最终实现设计，保留当前产品的交互惯例。

```sh
~/.claude/fleet/bin/epic-page-surface.sh --lint <scratchpad>/task-<slug>.html
```

检查 lint 的每项提示，修复实际问题。生产验收截图须来自实际部署并记录版本、时间、
页面或会话身份；设计原型、模拟 API 和本地构建只能作为各自阶段的证据。
Web 通常检查 390 与 1440 宽度；tmux 面板按真实 iTerm2 显示验证，不以网页 Terminal
截图替代。需要登录的只读截图使用现有 `fleet-console-ticket.sh` 路径。

## 3. 交付页面与接收修改

用户要求发布到 Space 时，`publish_file` 默认私密，更新同一个 `proposal_id`。
只有用户已授权通知或推送时才发送；避免重复通知。没有 Space 工具时，使用
`doc-preview` / Fleet `open` 将页面交给用户，不在远端机器直接运行 `open`。

需要页内反馈可使用 `replies` 与 `replies_done` 表。**当前 Task 的 Agent**读取和
处理意见，记录采纳或未采纳原因，不安排独立协调者、周期轮询或订阅回报系统。

没有未决批准事项且用户已授权实施时继续做；不能把沉默、计时器到期或默认选项
当作新的批准。修改写回同一方案和同一页面，不另建第二份真相。

## 4. 在当前 Task 实施，或按授权创建独立 Task

已有当前 Task 时直接使用这份方案继续工作。需要完整文字版时：

```sh
python3 ~/.claude/fleet/bin/fleet-task-page.py body <scratchpad>/task-<slug>.html \
  --link <page-link> > <scratchpad>/task-<slug>.md
```

保留两个阅读层的内容。正文超过接口限制时保留目标、约束和验收，并引用完整方案；
不要仅因页面卡片多或正文长就自动拆成多个 Task。

只有用户授权且确需独立环境或交付边界时，使用 `task` 工具创建普通 Task，提供
标题、正文和仓库；不指定 Parent、driver 或集合。记录新 Task 与设计页的对应关系。

结束时说明方案地址、已完成内容、验证结果及剩余阻塞。任务产物和原生会话历史保留，
不建立额外的完成回报通道。
