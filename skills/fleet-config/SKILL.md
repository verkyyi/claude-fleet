---
name: fleet-config
description: Change how a fleet role behaves by saying one sentence — 「让管家别自动答金额相关的问题」「编排会话加上企微存档」「管家换成 sonnet」「撤回」. Reads the merged definition and rule table, turns the sentence into the smallest change to the person's own layer, reads back 改哪一项：改前 → 改后, writes it to the hub when the person says yes. Use whenever the person asks to change a role's (orchestrator · steward · worker · epic-driver) model, effort, tools, external tools (MCP servers), instructions or a rule's tier, or to undo the last such change. In a worker's window it only reads.
---

# fleet-config — 在会话里说一句就改好

<!-- fleet skill -->

The person says what a role should do differently; you make it so on **their own layer**
(the person bundle on the hub, issue #2784) — every machine they run sessions on picks it
up, nothing to file, nothing to release (issue #2785, EPIC #2781 C4). Every write goes
through ONE script, `bin/fleet-role.py` (on a client: `fleet role …`); never edit
`agents/*.md`, `conf/role-rules.default.md`, `person-bundle.json` or
`$FLEET_CONF_DIR/roles/*.md` by hand for this.

## Who may write

The orchestrator, a scratch session, the person's own shell. **A worker's window (a batch
driver's too) only reads**: `fleet-role.py`'s writes exit 3 there — say so in one line
(「执行会话里只能看不能改——到编排会话里说」) and stop. Never try another road around it.
`fleet-role.py` lives in a full install (`~/.claude/fleet/bin/`, a worktree's `bin/`); a
computer with only the `fleet` client has no `fleet role` yet — there, say 「到编排会话里说」.

## 1. Read what is there now

```
fleet-role.py show <role> --sources        # the merged definition; each field's 自带 · 你的 vN · 本机 · 🔒
fleet-role.py rules --role <role>          # the merged rule table (编号 · 条件 · 动作 · 档位 · 关键词)
```

Roles: `orchestrator` 编排会话 · `steward` 管家 · `worker` 执行会话 · `epic-driver` 批次驱动.
A field marked 🔒 cannot be loosened by any layer — tell the person, don't try.

## 2. The sentence → the smallest change

| 人说 | 命令（先不带 `--yes`） |
|---|---|
| 换模型 / 思考档位 | `set <role> model sonnet` · `set <role> effort high` |
| 加外接工具（MCP） | `set <role> mcpServers <name> '{"command": "<launcher>", "env": {"X_TOKEN": "${X_TOKEN}"}}'`；登录里已有的那个：`set <role> mcpServers +<name>` |
| 去掉外接工具 | `set <role> mcpServers -<name>` |
| 加 / 减工具 | `set <role> tools +WebFetch` · `set <role> tools -Bash`（全工具的角色，减 = 进 disallowedTools） |
| 加一段说明 | `set <role> body '<那段话>'`（追加在「（你加的）」下）；整段换掉加 `--replace` |
| 改规则档 / 条件 / 关键词 | `rule-set <N> --tier ask`（`auto` 自己定 · `default` 到点按默认 · `ask` 必须问你 · `off` 删掉）；`--cond` `--action` `--keywords` 同理 |
| 加一条新规则 | `rule-set new --role steward --cond '…' --action '…' --tier ask [--keywords 'a, b']`（从 100 起编，编号不复用） |
| 把我改过的这项还回自带 | `unset <role> <项> [名字…]` · `rule-unset <N>` |
| 撤回 | `undo`（回到上一版；入口上是新的一版，所以撤回本身也能撤回） |

Pick the rule by reading the table: 「别自动答金额相关的问题」 is the steward's money row
or the default-answer row — find it, change its tier; when no row fits, `rule-set new`.
One sentence may need two commands; run them one by one, each through steps 3–4.

## 3. Read the change back, wait for yes

Run the command **without** `--yes` (exit 4, nothing written): it prints one line per
item that moves on the MERGED definition — `改 管家 · 模型：opus → sonnet`. Say those
lines to the person as they are, and wait. 「合起来没有变化」 = nothing to do, say so.

## 4. Write

The person says yes ⇒ the same command with `--yes`. It PUTs with the version it read
(a change made elsewhere meanwhile is re-read and redone once; a second conflict comes
back to you — tell the person, re-read, ask again), and this computer's copy updates at
once. Answer the person in the script's own words:

> 已改 管家 · 规则 14：问题带了建议或默认，到点没人答 → 必须问你（入口 v12）。
> 下次开管家生效；要现在生效说「重开管家」。

## Credentials — never

The person says 「把 token 写进去」 or pastes a key: **refuse, write nothing**. A key
never enters a configuration — the script refuses one anyway (exit 2, 「拒收，什么都没写」).
Say instead: a wrapper script reads it at start (as `bin/mcp-github.sh` reads
`gh auth token`), and the configuration names only the tool, its launch command and the
environment variable's NAME (`"${WECOM_TOKEN}"`); the value lives in their own login's
environment.

## Exit codes

0 written (or nothing to change) · 4 preview only, nothing written · 3 a worker's window
(or no hub — the message says which) · 2 refused here (bad value, a credential, a locked
or unknown field) · 1 the hub refused or did not answer.
