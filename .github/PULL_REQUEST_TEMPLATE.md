<!-- 换成这个 PR 的说明：改了什么、为什么、怎么验证的。`Closes #N` 让 fleet 把单子合上。 -->

## 老会话兼容（CONTRIBUTING «老会话兼容»，issues #2068 / #2075）

- [ ] 没动「启动时固定」的部分 — hook 表 `hooks/settings-hooks.json`、mod 登记的工具 `mod/fleet/hooks/tools.ts`、MCP `conf/mcp-worker.json`、fleet 托管的 settings；或动了，但给上一版的老会话留了兼容（转发壳 / 兜底 handler / 可操作的报错，至少一个发版周期），`python3 bin/fleet-oldcfg-replay.py --new-dir .` 绿
