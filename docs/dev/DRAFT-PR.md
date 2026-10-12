# 草稿单：worker 只开草稿 PR，等批准再合（issue #3715）

平常的 worker 门禁一绿就自己合并。**草稿单**换了终点：worker 做完开一个
**draft PR**，`report waiting`（附 PR 链接）后停下；有人批准，PR 才转正、按常规门禁合并。
日报第二步「小改动提前开好草稿 PR，等发起人点『按方案做』再合」走的就是这条路。

## 标记：一行在 issue 正文里

```
<!-- fleet:draft-only -->                              等批准
<!-- fleet:draft-only approved=<UTC> by=<谁> -->        已批准：按门禁合并
<!-- fleet:draft-only rejected=<UTC> by=<谁> -->        已拒绝：PR 已关
```

派单方要 PR 正文带上的话（「日报回复 <日期>#<n>」、`<!-- daily-plan -->`）放在自己的一对标记里，
里面再有 HTML 注释也不会弄坏上面那行：

```
<!-- fleet:pr-note:begin -->
日报回复 2026-10-12#3
<!-- daily-plan -->
<!-- fleet:pr-note:end -->
```

不用标签：标签是固定分类（`fleet_labels_allowed`），正文标记跟着单子走，worker 的 brief 已经读到正文。
`bin/fleet-draft.sh` 是这行的唯一读写处（`block` · `scan` · `mark` · `state` · `gate` · `approve` · `reject`）。

## 怎么派

| 入口 | 写法 |
|---|---|
| `file_issue` 工具 | `draft: true`，或 `pr_note: "…"`（自带 draft） |
| `task` 工具 | 同上，要有 `repo` |
| `spawn` 工具（已有的单） | 同上：先 `fleet-draft.sh mark <N>`，标记失败就不开窗 |
| 脚本 | `fleet-issue-file.sh --draft [--pr-note T]` · `fleet-task-record.sh dispatch … --draft` · `fleet-draft.sh mark <N> [--pr-note T]` |

## worker 怎么做

`/fleet-claim` 的 brief 看到标记就印一节 `draft-only`：

- `WAITING` — `gh pr create --draft`，正文带上 `pr body must carry` 的原文，取「改动后」证据，
  `report state=waiting`（附 PR），停。不 `gh pr ready`，不 `pr_merge`。
- 批准作为下一轮到达（「批准（草稿单）：PR #X 已转正 …」）：`pr_verdict wait` → `pr_merge` → `report merged`。
- 拒绝作为下一轮到达：PR 已关，记下，停。

窗口的回收方式是默认的 `merged`：PR 没合就不收；被拒、PR 关掉后由清理照常收走。

## 门禁：绿了也不合

`fleet-pr-merge.sh` 在 verdict 读到 `READY` 之后再问 `fleet-draft.sh gate <PR>`：PR 的 head 是
`issue-<N>`、#N 正文的标记是等批准或已拒绝 ⇒ 打印 `DRAFT-ONLY`、退出 1，**不调 `gh pr merge`**。
所以就算 PR 被手动转正，未批准也合不进去。`FLEET_DRAFT_GATE=0` 是操作者的开关。
没有标记的单子一字不差照旧。

## 批准 / 拒绝

```
fleet-draft.sh approve <N> [--by 谁] [--merge]
fleet-draft.sh reject  <N> --reason "为什么" [--by 谁]
```

- `approve`：找 `issue-<N>` 上开着的 PR，`gh pr ready`，标记改成 approved，再用 `--to-worker`
  评论告诉 worker 按门禁合并。worker 已经不在了就加 `--merge`：在这里等门禁、用 `fleet-pr-merge.sh` 合。
- `reject`：PR 带理由关掉，标记改成 rejected，理由评论到单子上。
- 单子自己的 worker 窗口不能批准或拒绝自己（退出 2）。还没开 PR ⇒ 退出 3；不是草稿单 ⇒ 退出 4。

自测：`bin/fleet-draft-selftest.sh`（C 段即「带标记的 worker 门禁全绿也不合并」）。
