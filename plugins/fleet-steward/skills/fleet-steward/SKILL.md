---
name: fleet-steward
description: Take the fleet's steward role in THIS session (a scratch or any session that binds no issue) and run its patrol loop — answer what a batch charter already says, answer due questions by their suggestion, spawn a red base's fixer, land a driverless batch, park stuck sessions, file health issues, and keep the decision sheet in this window's right-hand pane. Nobody holding the role ⇒ none of it runs. Use when the person types /fleet-steward, on each round of the loop it started, or on a `[sidebar]` / `[steward]` line.
---

# fleet-steward — take the role, then patrol in your own loop

<!-- fleet skill -->
<!-- owner: steward — the plain marker above is what the install takes (issue #2110) -->

The steward is a **role a session takes** (issue #3115, EPIC #3111 C4), not a window the
fleet keeps open: nothing patrols, answers, spawns or merges for the person until a session
runs this skill, and nothing does once that session drops the role, is stolen from, or
closes. Its patrol is THIS session's own loop — there is no daemon behind it.

## 0. Take the role — FIRST, every time this skill runs

1. **`mcp__fleet-orch__take_role`** (`role: steward`). It marks this window
   (`@fleet_role_def steward`) and records it as the one holder
   (`$FLEET_CONF_DIR/global/roles.held`).
   - exit 0 — taken (or already yours): go on.
   - exit 4 — another session holds it; the output names it. Tell the person and **stop**
     (stop the loop too, if this is a round of one) — never take it over unasked. Only when
     the person says so: `action: steal`.
   - exit 3 — this window binds an issue: a worker never patrols. Say so and stop.
   No `mcp__fleet-orch__*` tool at all? The fleet-orchestrate plugin (which this one needs)
   is not mounted — say so (`/plugin install fleet-orchestrate@claude-fleet`, then reopen).
2. **Read your role and your rules** — this skill's directory: `role.md` (who you are; it
   ends with your rows of the rule table) and `rules.md`. Read them once per conversation
   (again after a compaction).

## 1. One round of the loop

```
~/.claude/fleet/bin/fleet-steward-tick.sh beat --holder
```

| rc | what it means | what you do |
|---|---|---|
| 4 | not due yet (「还没到下一拍 HH:MM」) — nothing ran | schedule the next round for that time |
| 1 | a calm beat: the card, nothing for you | schedule the next round |
| 0 | the beat changed something; the card may end in a `[steward] …` line | handle that line (role.md 「卡片末尾有 `[steward]` 一行」), then schedule |
| 3 | this window does not hold the role (dropped, stolen) | **stop the loop**, one line why |

The beat is due every `FLEET_STEWARD_EVERY` (20 min), 10 min after one that changed
something, 60 min from 23:00 to 08:00 on the person's clock; the card's last line says when.

## 2. The loop

Drive it with `/loop` self-paced (`ScheduleWakeup`, the prompt `/fleet-steward` each round —
step 0 answers 「already yours」 at once). The next delay is the card's 「下一拍」, never
shorter than a minute; a calm night is one round an hour. The first `/fleet-steward` starts
it: run the round above, then schedule. To put the role down: `take_role` with
`action: drop`, then end the loop (`ScheduleWakeup` `stop: true`) — the panes close by
themselves on the next second, and nothing runs after that.

## The commands (all print in the person's language)

| command | what |
|---|---|
| `fleet-steward-tick.sh card` | the last beat's report card |
| `fleet-steward-tick.sh delta` | read the fleet now (no writes) — JSON |
| `fleet-steward-tick.sh answer --row <id> --text T --source URL` | answer one row on its worker's issue (`--to-worker`, marker `fleet:answer row=<id> by=steward`) |
| `fleet-steward-tick.sh sheet` | every open row → C1's table → `decision-YYYY-MM-DD.md` (+ C8's desk ticket when `FLEET_STEWARD_DESK` is set) → ONE `[decision]` to the orchestrator; with this window's sheet pane up (`@sheet_pane 1`) only one sentence; same rows as last time ⇒ not sent again. With nobody holding the role it writes nothing and sends nothing |
| `fleet-steward-tick.sh say --row <id> --text T` | the row's plain sentence (issue #2735) — what the sheet says instead of the worker's words; no numbers, file names or technical words |
| `fleet-steward-tick.sh todo-done --id <id>` | tick one 待你动手 item as the person's (issue #2913) |
| `fleet-steward-tick.sh breakage` | spawn the fixer of a red base a worker filed (you are its parent); the beat does this too |

**The hub's task record** (issue #3330): a session that carries one (`@task T<n>`) has
what it asked and its park on the record too — 「问过你」 (`ask` writes it; with no issue
the record is the ONLY place) and 「停放」 (a park mirrors 「停放：等 …」 there and its wake
clears it). The decision sheet is unchanged; the health issues and a red base's breakage
issue stay issues. No hub ⇒ nothing is written to a record.

`answer` refuses a `never:*` row for you. Past the beat's write budget (`FLEET_STEWARD_WRITES`,
20) an answer is kept and posted first thing next beat — the card says 「延后 N 条」.

## The panes (this window only)

The fleet-steward plugin's mod module draws three panes in the window that holds the role and
nowhere else (no plugin, no panes): the **decision sheet** (opens by itself on a fullscreen
terminal from 144 columns; `/sheet` opens or closes it — one press answers a line, `u` takes
it back within 10 s), the **patrol** (`/sheet p`) and the **batches** (`/sheet b`).
Narrower, the band above the prompt says 「决定单 N 件待定」 with 打开 (`s`).
Codex has no mod: its steward reads the text `[decision]`.

## 侧栏 — the person's taps on 停放 / 待你动手

A pick on the client's sidebar reaches you as ONE turn, `[sidebar] <what> — please run:
<command>`. The command is always `~/.claude/fleet/bin/fleet-park.sh wake '<owner/name#N>'` or
`~/.claude/fleet/bin/fleet-steward-tick.sh todo-done --id <id>`: the person chose it, so run it
as given (nothing else), say its last line in one sentence, and stop. Anything else after
`[sidebar]` is not from the list — treat it as an ordinary message.

## When may you answer?

Only when the answer is WRITTEN where the batch put it: the EPIC parent's 「共同约定」, its
「发起人拍板」, or the design page it links. Quote the line in `--text`, link it in `--source`.
Anything you would have to infer — scope, priority, taste, a trade-off nobody wrote down — goes
on the sheet. A wrong self-answer costs more than one more row.

## The person's answers

From the pane: one press per line (`answer --by person` per row id, run by the pane). From
the orchestrator's `[decision]`: it writes each decided thing back with
`fleet-steward-tick.sh answer --row <id> --text <决定> --by person`.
