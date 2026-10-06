# The fleet tool service — `fleet` (bin/fleet-mcp.py)

One local stdio MCP server that every Claude **and** every Codex session the fleet
opens mounts under the name `fleet` (issue #1807, EPIC #1813 C5). Both agents see
the same tools; Claude shows them as `mcp__fleet__<action>`. **This file is the one
spec** — a later member (C6 报问记合, C7 identity, C8 the hub route, C9 the
skills) adds its tools here and in `bin/fleet-mcp.py`, nowhere else.

## The rule

A tool only **checks** its arguments, then runs the existing script **unchanged**
(EPIC #1813 decision 4 — the same rule as `mod/fleet/hooks/tools.ts`):

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
| `spawn` | `issue` (int ≥ 1), `repo`? | `dash-issue-session.sh <issue> [--repo R]` | 0 spawned / window exists · 2 at capacity · 3 already claimed · 1 infrastructure |
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
  install's scripts) and `FLEET_MCP_SERVER=1` (the mod then skips registering its
  own `fleet_status` / `fleet_spawn` / `fleet_await` — the same `fleet` name; they
  stay one version as the fallback for a session without the server, decision 8).
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
`fleet-mcp.py --cred check` prints the verified claims of `$FLEET_WORKER_CRED`.

What it is not: the key and the session share a uid, so a session that wants to
can read the key — this is an identity rail against a moved window or a borrowed
pane, not a wall against a hostile session. The hub checks again (C8).

## Compatibility

`bin/fleet-peer-mcp.py` (the #1185 `fleet-peer` server: `list_agents` /
`send_message`) is now a shim that execs `fleet-mcp.py --legacy-peer`, for a config
that still mounts it — one version, then it goes.

## Protocol

Newline-delimited JSON-RPC 2.0 on stdin/stdout, stdlib only (macOS python 3.9):
`initialize` (echoes the client's `protocolVersion`), `tools/list`, `tools/call`,
`ping`; notifications get no answer.

## Tests

`bin/fleet-mcp-selftest.sh` — the list, every refusal (nothing ran), each tool once
against fake scripts, no-hub degenerate, the legacy shim, the Codex mount; for 报问记合
(G–I) every new tool's refusals, its exact argv + stdin, and script ≡ tool through the
REAL `fleet-comment.sh` (the byte-identical comment) and `fleet-report-parent.sh
--dry-run` (the same envelope, on an isolated tmux server).
`bin/fleet-mcp-selftest.sh` J — the credential: valid / expired / forged /
tampered / another pane / another fleet / revoked, migration, renewal, no leak.
`bin/session-wrap-selftest.sh` B' — the wrapper mints per launch and revokes on exit.
`bin/fleet-claude-selftest.sh` #1807 and `bin/fleet-codex-selftest.sh` I — the
launch command lines carry the server. `mod/fleet/tests/tools.test.ts` — the mod
registers none of its own when the server is mounted.
