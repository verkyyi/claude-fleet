---
name: fleet-help
description: Teach a person how to USE fleet, one step at a time, for the device they are on right now. Use when someone asks how to do something in fleet — connect (the Mac client, a phone over Termius, their address, device keys, the keys page, changing the home machine); the ⌘P panel and the client's keys, the phone's ⌃] keys; a new session or 派一件事, seeing a session's state, opening its shell, leaving and coming back to a session; where their quota and usage are; or a common fault (cannot connect, Chinese shows as garbage, the list stopped updating). Not for a newcomer's first PR (/fleet-onboard), Claude Code's own settings or key bindings (update-config, keybindings-help), or changing what fleet does.
---

# fleet-help — how to use fleet, one step at a time

<!-- fleet skill · owner: either -->

Someone asked how to do something in fleet. Answer like a person standing next to
them: for **the device they are holding**, **one step**, then wait. The facts live
in `docs/` — this skill only says where (issue #3216). Never answer from memory:
read the section the index names, every time, so the answer is today's.

## 1. Where are they? — before the first word

Call **`mcp__fleet__where`** with `json: true` (the one reader — never guess a
device). Read `os`, `terminal`, `caps`, `via`, and `clients` when there are several:

| They are on | Tell it as |
|---|---|
| `os` iOS / iPadOS / Android, or `terminal` Termius / Blink, or `caps` only `link` | the **phone**: Termius taps — ⌃ is the Ctrl key on the extra-key row, then `]`, then a letter; a page is a link to tap |
| `os` macOS with `terminal` iTerm2 (`caps` has `iterm2`) | the **Mac**: one key, ⌘P (everything else is a row in it); a page you can open for them with `mcp__fleet__open` |
| another terminal (Terminal.app, ssh from elsewhere) | **prefix keys** (prefix /, prefix n …) — `docs/dev/CLIENT.md` «The keys», right-hand column |
| exit 3 (nobody connected) or the question names another device («用手机怎么…») | ask which device in one short question, or take the one they named |

The question wins over the reading: «手机上怎么…» asked from the Mac is about the phone.

## 2. Find the section, read it, then answer

| They ask about | Read |
|---|---|
| connecting from a phone, first time (Termius, keys page, the four things) | `docs/dev/CLIENT.md` § 「手机：Termius 四样」 · `docs/dev/MULTI-MACHINE-OPS.md` § 「一个人第一次从手机连」 |
| their address, the entry port, what a connection with no command does | `docs/dev/CLIENT.md` § 「Your address: no command = the 看台」 · `docs/dev/MANAGED-NODE.md` § 「16. 入口端口」 |
| device keys: add, revoke, lost phone | `docs/dev/CLIENT.md` § 「手机：Termius 四样」 (step 4) |
| changing the home machine | `docs/dev/MULTI-MACHINE-OPS.md` § 「手动换家」 |
| the address stopped working after the home's internet changed | `docs/dev/MULTI-MACHINE-OPS.md` § 「宽带换了公网地址」 |
| connecting from the Mac, which machine `fleet` picks, a named machine | `docs/dev/CLIENT.md` § 「On a phone — the same road as the Mac」 · `docs/dev/MULTI-MACHINE-OPS.md` § 「6. 速查」 |
| ⌘P: what it lists, its row keys, the `>` commands | `docs/dev/CLIENT.md` § 「⌘P — sessions and actions」 |
| the one default key (⌘P · ⌃空格 · F12 · ⌃] p), getting another key back or changing one (`FLEET_KEYS_EXTRA` …) | `docs/dev/CLIENT.md` § 「One key + the panel」 |
| every key of the old client (⌘↑↓ ⌘[ ⌘] ⌘↩ ⌘Q …) | `docs/dev/CLIENT.md` § 「The keys」 |
| the phone's keys (⌃空格 · F12 · ⌃] p, the letters you can add), tapping them in Termius or Blink | `docs/dev/CLIENT.md` § 「The keys: one, to open the panel」 · `docs/dev/CLIENT.md` § 「Termius (iPhone)」 |
| a new session | `docs/dev/CLIENT.md` § 「A new session」 · `docs/dev/CLIENT.md` § 「A new session in one command」 |
| 派一件事 / hand a task to a worker | `docs/dev/CLIENT.md` § 「派一件事」 |
| a session's state, who is waiting on them | `docs/dev/CLIENT.md` § 「⌘P — sessions and actions」 (the 状态 column, the waiting ones first) · `docs/dev/STATE.md` § 「The states」 |
| the session's shell | `docs/dev/CLIENT.md` § 「⌃\ — the session's shell, and back」 |
| leaving, quitting, coming back to a session | `docs/dev/CLIENT.md` § 「放到后台 and 退出 fleet」 · `docs/dev/CLIENT.md` § 「会话结束了」 |
| copying text out of a session | `docs/dev/CLIENT.md` § 「复制」 |
| quota and usage | `docs/dev/CLIENT.md` § 「额度和用量在哪看」 |
| cannot connect | `docs/dev/CLIENT.md` § 「连不上」 |
| Chinese shows as `_` or boxes | `docs/dev/CLIENT.md` § 「中文乱码」 |
| the list stopped updating, a row cannot be opened | `docs/dev/CLIENT.md` § 「列表停住」 |

Read with a targeted range (`grep -n` the heading, then `sed -n` to the next one),
not the whole file. Nothing in the table fits? `grep -n` across `docs/*.md` and
`docs/dev/TERMS.md` for the person's word. The docs do not say it either? Say so
plainly — never invent a key, a menu item or a page — and file it bare with
`mcp__fleet__file_issue` (a 「怎么用」 gap in `docs/`), no `spawn`.

**Pages on the hub.** `<入口>` in the docs is the hub's address: `FLEET_HUB_URL`
in `~/.config/claude-fleet/fleet.conf` (`grep '^FLEET_HUB_URL' …`). Give the full
link: the keys page `<入口>/fleet/keys`, 设备与 SSH `<入口>/connect`, 我的额度
`<入口>/quota`, 我的用量 `<入口>/usage`. On the Mac you may open it for them
(`mcp__fleet__open`); on a phone, write the link — they tap it.

## 3. How to answer

- **One step, then stop.** Say what to do and what they should see when it worked,
  then wait for 「好了」 or what they saw instead. Number the steps so they know
  how many are left («第 2 步，共 4 步»).
- **In their words and their device's words**: the button's own label, the tap on
  a phone, the chord on the Mac. Never a script path, a tmux option or an issue
  number unless they asked why.
- **Their exact values**: their address, their port, their login — read them (the
  keys page shows them; `mcp__fleet__where`'s `host` is the home they are on), never
  a placeholder they must fill in.
- **When it did not work**, go to the troubleshooting section the index names
  before guessing; the doctor rows it names (`fleet doctor`) say where it stopped.
- **Explain, don't change.** This skill changes nothing: no setting written, no
  key added for them, no session closed. When the fix is theirs to make, walk
  them through it; when it needs an operator (a router, a machine), say who.

## 4. What is not this skill's

| They want | Go to |
|---|---|
| their first PR in their own repo, as a newcomer | `/fleet-onboard` |
| Claude Code's own settings, permissions, hooks | `update-config` |
| Claude Code's key bindings (`~/.claude/keybindings.json`) | `keybindings-help` |
| which model / effort / MCP an agent gets, team and personal layers | `fleet config` (`docs/dev/AGENT-CONFIG.md`) |
| continue this conversation fresh, or in Codex | `/fleet-handoff` |
| a closed session from earlier | `/fleet-history` |
| fleet to behave differently | a new issue — this skill teaches what fleet does today |

## 5. Keeping it true

`bin/fleet-help-selftest.sh` holds every `docs/<file>.md` § 「…」 above to a
heading or a bold lead that still exists, and every `<入口>/…` page to a route the
hub serves. A change a person will notice — a key, a page, a step — updates the
section here or its doc in the same PR (CONTRIBUTING «面向用户的改动»).

## 排障 — no `fleet` tool in this session

`~/.claude/fleet/bin/fleet-client-where.sh --json` prints the same reading as
`mcp__fleet__where` (exit 3: nobody connected).
