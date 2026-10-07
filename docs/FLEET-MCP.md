# The fleet tool service — `fleet` (bin/fleet-mcp.py)

One local stdio MCP server that every Claude **and** every Codex session the fleet
opens mounts under the name `fleet` (issue #1807, EPIC #1813 C5). Both agents see
the same tools; Claude shows them as `mcp__fleet__<action>`. **This file is the one
spec** — a later member (C6 报问记合, C7 identity, C8 the hub route, C9 the
skills) adds its tools here and in `bin/fleet-mcp.py`, nowhere else.

## The rule

A tool only **checks** its arguments, then runs the existing script **unchanged**
(EPIC #1813 decision 4 — the rule the mod's retired `tools.ts` kept):

- an unknown argument, a missing one, a wrong type, an out-of-range number, a
  malformed `repo`, a `repo` this fleet does not host, an unknown tool → refused
  with the reason, `isError: true`, text ending `Nothing ran.` — and nothing ran;
- a valid call runs the script and hands back its **exit code, stdout and stderr
  as they came** (`structuredContent: {command, exit, stdout, stderr}`; the text is
  `exit <rc> · <script>` then the output). A non-zero exit is data, not an error:
  `spawn` exit 2 is "at capacity", `await` exit 3 is "still running".

Caps, claim dedup, the origin gate and every guard live in the scripts — once.
No hub is needed for any tool (EPIC #1813 rule 1): with no hub configured all of
them are listed and run locally.

## Tools

| tool | arguments | runs | exit codes |
|---|---|---|---|
| `status` | — | `tmux display-message` (this window's line) + `fleet-children.sh` + `fleet-repo.sh list` | read-only |
| `children` | — | `fleet-children.sh --json` | the script's |
| `repos` | — | `fleet-repo.sh list` (`structuredContent.repos` = the parsed `owner/name` list) | the script's |
| `agents` | — | `tmux list-windows` of this fleet, `fleet-children.sh --json`, `fleet_origin_key` | read-only; each row `key · issue · agent · state · is_self/is_parent/is_child` |
| `spawn` | `issue` (int ≥ 1), `repo`?, `reap`? | `dash-issue-session.sh <issue> [--repo R] [--reap P]` | 0 spawned / window exists · 2 at capacity · 3 already claimed · 1 infrastructure |
| `set_reap` | `policy` (`merged[:<dur>]` · `done[:<dur>]` · `loop-end` · `at:<HH:MM\|ISO>` · `keep`) | `fleet-reap-policy.sh set <policy>` — this window's `@reap_policy` (issue #1902) | 0 set · 2 not a policy · 1 no window |
| `await` | `issue`, `repo`?, `timeout`? (1–570 s, default 540) | `fleet-await.sh <issue> --timeout T [--repo R]` | 0 MERGED · 3 TIMEOUT (call again) · others per the script |
| `send` | `to` (`issue:<N>` · `scratch-<N>` · `parent`), `text` | `fleet-peer-send.sh <target> -` (text on stdin) | `{delivered}` · `{queued}` (exit 3) · `{ended}` (exit 2 + stdout) |

### 报 问 记 合 (issue #1808, EPIC #1813 C6)

The rest of a worker's day — the commands `commands/fleet-claim.md` used to have
it type. Each argument is one flag of the script; a body or a doc travels on
**stdin**, never through argv. Arguments that only make sense together are checked
together (refused, nothing ran): `evidence before|after` takes exactly one of
`file` / `text` / `pane`; `post` / `line` take none; `mv` needs a `file`; `slug` is
`path`'s, `doc` / `issue` are `check`'s; `until_merged` / `timeout` need `wait`.

| tool | arguments | runs | exit codes |
|---|---|---|---|
| `report` 报 | `state` (`merged` · `blocked` · `failed` · `stopped` · `waiting`), `pr`?, `summary`?, `dry_run`? | `fleet-report-parent.sh --state S [--pr N] [--summary T] [--dry-run]` | 0 reported / no parent · 3 queued (delivered later — don't resend) · 1 refused; `merged` is checked against the PR's real state |
| `ask` 问 | `question`, `kind`? (`question` · `permission`), `issue`? (default the window's `@issue`; none → refused) | `fleet-comment.sh <issue> --note --body-file -` with `⛔ blocked: <question>` (`⛔ blocked — needs authorization: …` for `permission`), **then** `set-claude-state.sh blocked` — stamped even if the comment failed | the comment's; `structuredContent.state` is the stamp's. The answer arrives as the next turn by the existing channels (issue-bridge, a prompt) |
| `comment` 记 | `issue`, `body`, `mode`? (`note` default · `to-worker`), `close`?, `repo`? | `fleet-comment.sh <issue> --note\|--to-worker [--close] [--repo R] --body-file -` | the script's. `note` is RECORD-ONLY |
| `evidence` 记 | `action` (`line` · `before` · `after` · `post`), `file` \| `text` \| `pane`, `name`?, `note`?, `mv`?, `issue`? | `fleet-evidence.sh <action> [--issue M] [--note …] [--name F] [--mv] [--pane T] [<file> \| -]` (`text` on stdin as `-`) | 0 ok · 1 none / failure · 2 usage · 4 no issue |
| `handoff` 记 | `action` (`path` · `find` · `repo` · `check`), `slug`?, `doc`?, `issue`? | `fleet-handoff-file.sh <action> [--slug S]` · `check - [--issue N]` (doc on stdin) | 0 · 1 none · 3 check findings (advice) · 4 ambiguous |
| `pr_verdict` 合 | `pr`, `repo`?, `wait`?, `until_merged`?, `timeout`? (1–570 s, default 540 with `wait`) | `fleet-pr-verdict.sh <PR> [--repo R] [--wait --timeout T [--until-merged]]` | 0 READY · 1 any other verdict · 2 error · 3 TIMEOUT (call again) |
| `pr_merge` 合 | `pr`, `repo`? | `fleet-pr-merge.sh <PR> [--repo R]` (the fleet's merge method) | 0 MERGED · 1 not READY / refused · 2 error |

### The rest of a worker skill (issue #1811, EPIC #1813 C9)

What `commands/fleet-claim.md`, `fleet-handoff.md`, `fleet-compact-resume.md` and
`fleet-context.md` still had a session type by path. With these the worker-run
steps of every skill name a **tool**, never a script (`bin/skill-tools-selftest.sh`
lints it): a script path appears only under a heading marked `运营者` or `排障`.

| tool | arguments | runs | exit codes |
|---|---|---|---|
| `brief` | `kind`? (`claim` default · `resume`), `issue`?, `repo`?, `no_comments`? (claim only) | `fleet-claim-brief.sh [--issue N] [--repo R] [--no-comments]` · `fleet-compact-resume.sh --brief` | claim: 0 go · 2 not in a fleet · 3 wrong seat · 4 no issue · 5 the read failed |
| `file_issue` | `title`, `body`?, `labels`? (comma list), `priority`? (`p0`–`p3`), `parent`?, `spawn`? \| `bind`?, `breakage`? \| `breakage_key`?, `repo`? | `fleet-issue-file.sh --title T [--body B] [--label L]… [--priority P] [--parent N] [--repo R] [--spawn\|--bind] [--breakage\|--breakage-key K]` | 0 · 2 usage · 3 unknown label · 4 spawn with no live parent · 5 the breakage already has an open issue (its URL on stdout, a 「同一故障」 comment left on it; issue #2078) · 1 failure |
| `gh` | `kind` (`issue` · `pr` · `checks`), `number`, `fields`?, `max_age`? (≥ 0), `repo`? | `fleet-gh.sh issue view\|pr view\|pr checks <N> [--repo R] [--json F] [--max-age S]` | the script's |
| `context` | `json`? | `fleet-context.sh [--json]` | 0 OK · 1 another verdict · 2 nothing to read |
| `transfer` | `action` (`check` · `arm` · `export_loop`); `to` (`claude` · `codex`) for check/arm; `handoff` + `loop`? for arm; `transcript` + `output` for export_loop | `fleet-transfer.sh --session S --window $TMUX_PANE --to T --dry-run` · `… --handoff DOC [--loop L] --after-turn` · `fleet-loop.py from-claude --transcript F --output F` | the script's |
| `handoff` `arm` | `doc` (a stored file's path) \| `issue` (+ `repo`?) | `fleet-handoff-cycle.sh --pane $TMUX_PANE --doc D \| --issue N [--repo R]`, **detached** — the call returns at once with its pid; it must be the turn's last call | 0 armed |
| `where` | `json`? | `fleet-client-where.sh [--json]` | 0 named · 3 nobody connected · 1 could not tell |
| `whats_new` | `from`?, `to`? (shas; default this session's `@agent_ver` → the current version) | `fleet-whats-new.sh --full [<from> [<to>]]` | 0 printed · 1 nothing changed / no version |
| `show` | `file`, `inline`? | `fleet-show.sh [--inline] -- <file>` | 0 SENT · 2 PATH (say the path) |
| `open` | `target` (URL · `:port[/path]` · file) | `fleet-open.sh -- <target>` | 0 sent / copied · 2 fallback:path |

`file_issue`'s body goes as `--body` (the script takes no stdin); it never passes
through a shell. `--` before a file / target keeps a name starting with `-` a name.

### In a skill

A worker step names the tool as `mcp__fleet__<tool>` — the name Claude shows; a
Codex session reaches the same tool on its `fleet` server. The script stays the
implementation and the 排障 path (`FLEET_MCP=0`, a session without the server);
it is written only under a `运营者` / `排障` heading. Operator skills
(`fleet-epic-*`, `fleet-sync-install`, `fleet-move`, `fleet-history`,
`fleet-onboard`) keep their script form — the operator is not a worker session.

Reverse delivery is untouched (EPIC #1813 rule 3): a report the parent cannot take
waits in the peer queue / hub outbox, an answer comes back through the issue-bridge
or a prompt — no tool polls for one.

`repo` is `owner/name` of a repo **this fleet hosts** — checked against
`fleet-repo.sh list` before anything runs. Omitted = the window's repo, as the
script decides.

## How a session gets it

The definition lives once, in **`conf/mcp-worker.json`**:

```json
{"mcpServers": {"fleet": {"command": "bash",
  "args": ["-c", "exec python3 \"${FLEET_MCP_BIN:-$HOME/.claude/fleet/bin}/fleet-mcp.py\""]}}}
```

- **Claude** — `bin/fleet-claude.sh` adds `--mcp-config=<install>/conf/mcp-worker.json`
  (the `=` form, #476). It is **additive**: next to every configured server when
  `FLEET_MCP_CONFIG` is unset, next to the allowlist when it is set (`none`
  included), and not added again when the allowlist already names a `fleet`
  server. It exports `FLEET_MCP_BIN=<install>/bin` (the server runs THIS
  install's scripts) and `FLEET_MCP_SERVER=1` — which tells the mod the service is
  here, so it registers no tool of its own (decision 8; mod 0.4.0, issue #1812).
  **A session launched before the service** (`--plugin-dir` only, no
  `--mcp-config`; every pane from before #1828 that was never reopened) has no
  `FLEET_MCP_SERVER`, and its tool list — registered once at ITS start — still
  carries the mod's `fleet_status` / `fleet_spawn` / `fleet_await`: a hot reload of
  the mod swaps the code, never the list. So the mod keeps them as the **fallback**
  (issue #2057, mod 0.4.1, `mod/fleet/hooks/tools.ts`): without `FLEET_MCP_SERVER=1`
  it registers the three from `fleet-mcp.py --spec status spawn await` (the service's
  own schemas, so there is one copy) and forwards every call to
  `fleet-mcp.py --call <tool> <json>` — the same identity check, argument check,
  script and call log as a `tools/call` (logged `road=call`). When the forward
  itself cannot run (no `python3`, the install's `bin/` gone, a usage exit) the
  answer is one actionable line: reopen the session (`/fleet-handoff`, or `claude
  --resume`) so it mounts the service, or run the script by hand meanwhile. A served
  session sees nothing of this — no spec read, nothing registered, no second
  `fleet` tool.
- **Codex** — `bin/fleet-codex.sh` adds `-c "$(fleet-mcp.py --mount codex)"`:
  `mcp_servers.fleet={command, args, env_vars, tool_timeout_sec}` derived from the
  same file, after any allowlist policy and before the caller's `-c`. Codex hands a
  server only a short env allowlist, so `env_vars` forwards `TMUX`, `TMUX_PANE`,
  `FLEET_CONF_DIR`, `FLEET_SESSION`, `FLEET_WORKER_CRED`, `FLEET_MCP_BIN`; `tool_timeout_sec=600` lets a
  blocking `await` finish (Codex's default is 60 s).
- **Off** — `FLEET_MCP=0`, a caller's own `--mcp-config` / `--strict-mcp-config`
  (Claude), or no `conf/mcp-worker.json` / `fleet-mcp.py` beside `bin/`: nothing is
  added and the argv is byte for byte what it was.

## Identity — the worker credential (issue #1809, EPIC #1813 C7)

Every session the fleet opens carries its own short-lived credential, and every
tool call is made **as that session**: no more working out who is calling from
the window's options, which drift when a window moves or a pane is not the one
the session lives in.

**Issued** by `bin/fleet-session-wrap.sh` — the one door every session opens
through (spawn, restore, migrate, move, transfer, the warm pool, a wake) — once
per launch: `fleet-mcp.py --cred mint` prints it to the wrapper, which exports it
as **`FLEET_WORKER_CRED`** for that launch only; the agent hands it to this server
(Claude: inherited; Codex: `env_vars` forwards the NAME). It is never in an argv,
a file, a config, a log, a comment or a tmux option (`fleet-mcp-selftest.sh` J
greps for it). **Revoked** when the agent exits (`--cred revoke` puts its nonce on
the revoked list). A migrated or moved session is launched again on its new
window and so gets a fresh credential for the **same** `worker_id` — and an older
one still holds there, since it names the session, not the pane.

**Format** — `fwc1.<base64url claims>.<base64url HMAC-SHA256>`, signed with this
login's key `$FLEET_CONF_DIR/worker-cred/key` (0600, made on first mint). Claims:

| claim | what |
|---|---|
| `v` | 1 |
| `fleet` | the fleet (its socket label — the same for a warm-pool or view session) |
| `fid` | the session's lifelong `@fleet_id` — its IDENTITY (#1646) |
| `fleet_uuid` | the fleet UUID (`fleet_uuid`), empty on a machine with none |
| `key` · `repo` · `issue` · `origin` | what the session was at issue time (informative; a scratch bound later keeps its `fid`) |
| `iat` · `exp` | issued · expires: **24 h**, renewed hourly in the server's memory while it holds (decision 7) |
| `nonce` | what the revoked list (`$FLEET_CONF_DIR/worker-cred/revoked`, nonces only) names |

`worker_id` = `<fleet_uuid>/<fid>` (`fid` alone without a fleet UUID) — the same
string `fleet_worker_id` prints.

**Checked on every call, before the arguments** — a credential that is present
and does not hold refuses the call (`isError`, `… Nothing ran.`), read-only tools
included:

| refused when | text |
|---|---|
| malformed / not this login's key / tampered | `credential is malformed` · `signature does not verify` |
| past `exp` | `credential expired` |
| its nonce is revoked | `credential was revoked (its session exited)` |
| called from another fleet | `credential is for fleet X, this pane is in Y` |
| called from a pane whose window is not the credential's session | `this pane's window (…) is not the credential's session (…)` |

**Scope** — what a holder may do, given the pane IS its session:

| tool | scope |
|---|---|
| `status` `children` `repos` `agents` | read: this session's view |
| `spawn` `await` | only as **itself** the parent — the script stamps the child's `@origin` from this pane, and the pane is pinned to the credential's session |
| `send` | only within **this fleet**: local keys (`issue:<N>` / `scratch-<N>` / `parent`), never a `wid:` address |
| `report` `ask` `evidence` `handoff` | only **itself** — `fleet-report-parent.sh` reports the calling pane, pinned the same way |

**No credential** (a person in a shell, a session launched before this, `FLEET_MCP=0`):
the call runs as before, by the window's options — and is logged `via=marker`.

**The call log** — `<install>/logs/mcp-calls.log` (`FLEET_MCP_LOG`), one line per
call, never the credential:

```
2026-10-06T12:00:00-0700 tool=spawn via=cred who=<fleet uuid>/<fleet_id> verdict=exit=0
2026-10-06T12:00:05-0700 tool=spawn via=badcred who=<the window's @fleet_id> verdict=refused why="this pane's window … is not the credential's session …"
2026-10-06T12:01:00-0700 tool=status via=marker who=<@fleet_id or window name> verdict=ok
```

`via=cred` ÷ all is the EPIC's 「工具调用里认得出是哪个执行会话的」.
`fleet-mcp.py --cred check` prints the verified claims of `$FLEET_WORKER_CRED`. `--cred assert` prints
the session's OWN worker assertion (the hub on, the credential holding) — what
`bin/fleet-session-cred.sh` hands `POST /v1/fleet/session-cred` to borrow a session
pass on an untrusted machine (claude-fleet#1972).

What it is not: the key and the session share a uid, so a session that wants to
can read the key — this is an identity rail against a moved window or a borrowed
pane, not a wall against a hostile session. The hub checks again (C8, below).

## The hub route — a worker assertion (issue #1810, EPIC #1813 C8)

Whether a call goes through the hub is the **node's** configuration, never the
session's: the tools look the same either way (EPIC #1813 rule 2). When this
fleet runs with the hub (`fleet_hub_on` — the fleet conf's / environment's
`CCQUOTA_FLEET=1`) **and** the node has its token (`$CCQUOTA_TOKEN`, else
`node.env`), the three tools whose script may act on another machine hand that
script a **worker assertion** — who the call is for, signed by the node — in
**`$FLEET_WORKER_ASSERT`**, the environment only:

| tool | how it reaches the hub | lifetime |
|---|---|---|
| `spawn` · `await` | `dash-issue-session.sh` → `fleet_hub_place` → `ccquota place`, header `X-Fleet-Worker` on `POST /v1/node/place` | 10 min |
| `send` | `fleet-peer-send.sh` → `fleet_hub_put` → the relay's `worker` field (outbox → agent → hub) | 24 h — a relay may wait in the outbox while the hub is away |

**Only a call whose credential held** gets one (C7): no credential, a hub that is
off, no node token, no fleet UUID → nothing is minted and nothing about the hub is
read. **With no hub configured not one network request is made** — not by the
server, not by anything it runs on its behalf (`fleet-mcp-selftest.sh` K traps
every socket). A cross-machine call through a hub that cannot be reached fails in
its script as it always has; everything local runs unchanged.

**Format** — `fwa1.<base64url claims>.<base64url HMAC-SHA256>`, keyed with
`HashToken(node token)` (SHA-256 hex): the hub already stores exactly that, so it
verifies without a new secret, and nothing but the node holding the token (or the
hub) can sign. Claims: `v` 1 · `worker_id` (`<fleet UUID>/<fid>`) · `fleet_uuid` ·
`fid` · `key` (the session's key **now** — a relay's `from` names it by that) ·
`repo` · `issue` · `origin` · `node` (this host's short name) · `iat` · `exp`.

**The hub** (`tokenledger/internal/api/fleet_worker_assert.go`) adds a caller
kind, the 执行会话 — a node's call made for one of its sessions:

| the assertion | answer |
|---|---|
| absent | the node's own call, byte for byte as before |
| not signed with this node's token hash · tampered · expired · `exp-iat` over 24 h · malformed | **401** `UNAUTHENTICATED` (a relay: refused) — never read as "no assertion" |
| a session of a fleet this node does not run · a start whose `origin_wid` is not that session (by fid or key) · a relay whose `from` is not that session | **404** `NOT_FOUND` — a session acts only as itself: what it opens is its own child |
| holds | the call runs; a start with no `origin_wid` gets the session's |

Every such call — refused ones too — writes `worker_id` and `worker_key` beside
the node's `actor` in **`fleet_audit`**, and a placed start's journal row
(`fleet_operations.worker_id`) names the session. So the audit line for
「执行会话 issue-N @ m5 → 在 m4 上开会话」 reads
`actor=node:<login>@m5 worker_key=issue-N action=place outcome=REMOTE m4 done`.
The envelope sent to the target node is unchanged (its `fields()` check is
strict). The call log marks a call that handed one out with ` hub=asserted`.

Needs, to take effect: the hub deployed with this change, and on each node a
`ccquota` (place) and agent (relay) built from it. An older `ccquota` / agent
drops the assertion — the node's own call, exactly as before.

## The old road — closed (issue #1812, EPIC #1813 C10)

A **worker** seat reaches the fleet through these tools, not by running the
script a tool wraps. `hooks/bash-guard.py` holds ONE table (`_DIRECT_TOOLS`,
script → tool) and judges two roads with it: a Bash statement whose **command**
is one of the scripts below (the live install's copy or a bare name — a `grep`
of it, or a worktree's own `bin/` under test, is not a call), and a call to one
of the mod's old tools by its MCP name (`mcp__fleet__fleet_status|spawn|await`
→ `status` / `spawn` / `await`; `hooks/settings-hooks.json` routes those names to
the guard, Codex never had them) — in a session that HAS the service
(`FLEET_MCP_SERVER=1`). In a session with none (launched before #1828) those three
are the mod's fallback and its only road (issue #2057, «How a session gets it»):
logged `fallback`, never blocked, whatever the mode.

**The fallback is kept by a gate, not by memory** (issue #2075, EPIC #2074 C2):
before `fleet-stable.sh move`, `bin/fleet-oldcfg-replay.py` replays what a session
of the current stable registered — every mod tool of its `tools.ts` through the new
`tools.ts`'s `TOOL_RE` and `fleet-mcp.py --call`, every tool its `fleet` server
listed against the new server's `tools/list`, every hook command of its table —
and a tool with no handler refuses the move (`oldcfg:`). #2068's rules say what a
handler is: forward it, or answer how to reopen (CONTRIBUTING «老会话兼容»).

| script | tool |
|---|---|
| `fleet-children.sh` · `fleet-repo.sh list` | `children` · `repos` |
| `dash-issue-session.sh` · `fleet-await.sh` · `fleet-peer-send.sh` | `spawn` · `await` · `send` |
| `fleet-report-parent.sh` · `set-claude-state.sh blocked` · `fleet-comment.sh` | `report` · `ask` · `comment` |
| `fleet-evidence.sh` · `fleet-handoff-file.sh` | `evidence` · `handoff` |
| `fleet-pr-verdict.sh` · `fleet-pr-merge.sh` | `pr_verdict` · `pr_merge` |
| `fleet-claim-brief.sh` · `fleet-issue-file.sh` · `fleet-gh.sh` | `brief` · `file_issue` · `gh` |

`FLEET_DIRECT_SCRIPTS` (env, or `fleet.conf`) picks what happens:

- `log` (the default — the week of record): allowed, one line appended to
  `logs/mcp-bypass.log`: `<UTC>\tlogged\tissue=<N>\tscript=<s>\ttool=<t>` — never
  the command line (a comment body is not a log's business);
- `block` (after the week, once the log reads clean): refused, exit 2, naming the
  tool to call; logged `blocked`;
- `off`: neither.

`FLEET_ALLOW_DIRECT_SCRIPTS=1` (env or inline) is the escape hatch: allowed and
logged `hatch`. Only `fleet_seat` = `worker` counts: the operator's hub
(`FLEET_HUB=1`), a scratch draft and a person's own shell are never logged or
blocked, and a guard that cannot read the seat lets the call through. The
week's count is `grep -c $'\tlogged\t' logs/mcp-bypass.log`.

## Compatibility

`bin/fleet-peer-mcp.py` (the #1185 `fleet-peer` server: `list_agents` /
`send_message`) is now a shim that execs `fleet-mcp.py --legacy-peer`, for a config
that still mounts it — one version, then it goes.

## A new version, taken between calls (issue #1898, EPIC #1906 C5)

The install is a link to one version (`~/.claude/fleet → fleet.versions/<sha>/`,
#1894). Before each request, and every `FLEET_MCP_RELOAD_POLL_S` (30 s) while the
client is quiet, the server compares the file it was launched as (the link path,
never resolved) with the one it runs — another real path, inode, size or mtime is a
new version. Requests are served one at a time, so a call in flight always finishes
on the old code first. The new file must answer `fleet-mcp.py --probe` (its tool
names, exit 0); then the server `os.execv`s it: same pid, same stdin/stdout, so the
MCP connection never drops, and the credential rides in the environment as it is
(renewed in place). Request bytes already read but not served pass to the new
process through a 0600 carry file it deletes at once. The new process sends
`notifications/tools/list_changed`.

| Client | On `list_changed` | So a running session… |
|---|---|---|
| Claude Code (2.1.292, tested) | re-lists at once — **only** when `initialize` declared `tools.listChanged` (it does since #1898) | gets the new tools on its next turn; a session that met an older server keeps its list until reopened |
| Codex (0.160, `codex-rs/rmcp-client`) | logs it, keeps its first list | keeps its tool list; the exec still moves its tools' scripts onto the new version. New tools reach it through the C4 notice + C3 idle reopen |

A version that fails its probe is refused (`tool=(reload) verdict=refused` in
`logs/mcp-calls.log`) and the running one keeps serving; each exec logs
`verdict=exec` and `verdict=resumed` under the one pid. `FLEET_MCP_RELOAD=0` turns
it off. The legacy `fleet-peer` shim never reloads.

## What changed, told at the next turn (issue #1897, EPIC #1906 C4)

A session that keeps working across a version move is not reopened (C3 only
reopens an idle one), so it is TOLD: `hooks/settings-hooks.json`'s
`UserPromptSubmit` runs `fleet-whats-new.sh --hook` — Claude and Codex alike
(`hooks/codex-map.json`) — and when the expected version (`agent-cfg.expected`'s
`ver` line, C2) differs from the one this session last heard of (`@ver_told`,
else its launch `@agent_ver`), it hands the agent a note of at most five lines as
`hookSpecificOutput.additionalContext`, then stamps `@ver_told=<sha>` so the same
version is never told twice:

```
fleet 已从 69be1df 更新到 7c2a0e1，和你有关的：
· 新工具 fleet.whats_new
· 技能 /fleet-claim：交付前多一步 fleet.evidence after
· 守卫：直接敲 fleet-comment.sh 会被记录，请用 fleet.comment
另有 6 项内部改动。
```

Relevant = a tool added or retired (`TOOLS` of the two versions), a commit that
touches `docs/FLEET-MCP.md`, a worker-owned skill (`owner: worker`) or a guard
(`hooks/*guard.py`, `bin/tmux-shim/`, the hook table); everything else is counted.
A rollback is one line. Only at a turn boundary — nothing in a running turn is
interrupted. No `ver` expected, no pane, or no move ⇒ nothing (as before); a session
with neither stamp is baselined silently. `FLEET_WHATS_NEW=0` turns it off; each
note is logged in `logs/whats-new.log`. `whats_new` prints the full list any time.

## Protocol

Newline-delimited JSON-RPC 2.0 on stdin/stdout, stdlib only (macOS python 3.9):
`initialize` (echoes the client's `protocolVersion`, declares `tools.listChanged`),
`tools/list`, `tools/call`, `ping`; notifications get no answer. The server sends
one notification of its own: `notifications/tools/list_changed`, after a reload.

## Tests

`bin/fleet-mcp-selftest.sh` — the list, every refusal (nothing ran), each tool once
against fake scripts, no-hub degenerate, the legacy shim, the Codex mount; for 报问记合
(G–I) every new tool's refusals, its exact argv + stdin, and script ≡ tool through the
REAL `fleet-comment.sh` (the byte-identical comment) and `fleet-report-parent.sh
--dry-run` (the same envelope, on an isolated tmux server); L the C9 tools the same way,
and `handoff arm` answering before its detached helper ends.
`bin/skill-tools-selftest.sh` — no worker-run skill step names a `~/.claude/fleet/bin`
script, and every `mcp__fleet__<tool>` a skill names is a real tool.
`bin/fleet-mcp-selftest.sh` J — the credential: valid / expired / forged /
tampered / another pane / another fleet / revoked, migration, renewal, no leak.
`bin/fleet-mcp-selftest.sh` M — a new version between calls: the in-flight call
finishes on the old code, exec keeps pid + connection + credential, `list_changed`,
the new tool listed, a broken version refused, the quiet poll, `FLEET_MCP_RELOAD=0`.
`bin/whats-new-selftest.sh` — the C4 note: ≤ 5 lines, unrelated-only = one line,
overflow, rollback, told once per version per session (`@ver_told`), the Codex
wiring, the `whats_new` tool, and the degenerate (no `ver` / no move ⇒ nothing).
`bin/fleet-mcp-selftest.sh` K — the hub route: assertion only with hub + token +
credential, its signature and claims, zero network with no hub, `fleet_hub_put`'s
`worker`. Hub: `TestWorkerAssertion*` (`internal/api/fleet_worker_assert_test.go`)
— valid → placed + audited + journalled, forged → 401, out of scope → 404, the
relay; `TestPlaceCarriesWorkerAssertion` (`cmd/ccquota`).
`bin/session-wrap-selftest.sh` B' — the wrapper mints per launch and revokes on exit.
`bin/fleet-claude-selftest.sh` #1807 and `bin/fleet-codex-selftest.sh` I — the
launch command lines carry the server. `mod/fleet/tests/lifecycle.test.ts`
«fallback tools» + `tests/tools.test.ts` + `bin/fleet-mod-selftest.sh` E — with the
service the mod registers no tool; without it the three, from `--spec`, every call
forwarded to `--call`, no schema / check / script of its own, the retreat message
when the forward cannot run (issue #2057). `bin/fleet-mcp-selftest.sh` N — `--spec`
is the `tools/list` entry byte for byte; `--call` runs the same argv, prints the
same text, exit 0 / 1 / 2, logs `road=call`.
`bin/fleet-oldcfg-replay-selftest.sh` — the release gate (issue #2075): a deleted
hook script, a dropped `TOOL_RE` handler, a tool gone from the server, a hook
erroring or hanging — each red and named, restored green, old == new green at
once; J replays this repo's own table against its live tree. `fleet-stable-selftest.sh`
I — the refusal (`oldcfg:`, tag untouched, `--dry-run` too) and `--force` + its log
line; `fleet-break-it-selftest.sh` `oldcfg-deleted-hook` does it through the real
`move` on a rig repo.
`bin/bash-guard-selftest.sh` «direct-script rail» — the old road (above): a worker
seat logged / blocked, the operator seat and the hatch passing, the MCP road with
the service, the fallback without it (logged `fallback`, never blocked).
