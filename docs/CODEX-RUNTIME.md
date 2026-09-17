# Codex runtime adapters

`fleet-codex.sh` gives each launch an owner PID. The shared hook table calls
`fleet-codex-session.py` at SessionStart and Stop; it is a no-op in Claude
sessions. SessionStart records the exact root session UUID, CODEX_HOME,
transcript path and model in one `@codex_identity` JSON option. Hooks from an old
launcher cannot overwrite a replacement. Stop refreshes only the current UUID.

## Context

Run `bash ~/.claude/fleet/bin/fleet-context.sh` inside a Codex worker, or inspect
a saved session with `fleet-context.sh --agent codex --session UUID --json` and
the appropriate CODEX_HOME. The dashboard uses the same reader.

The reader validates the rollout's session metadata against the requested UUID,
then reads at most the last 2 MiB. It uses the latest token-count event's
`last_token_usage.total_tokens` and `model_context_window`. Cached input is
already included; session cumulative usage is not current context. Missing,
incomplete or unrecognised data stays unknown. Codex caches include fleet,
window, launcher and root UUID, so a new session never displays Claude's cwd
cache or a predecessor's context. The rollout format is an upstream internal
interface; fixture tests pin the supported 0.154 shape.

`FLEET_AUTO_HANDOFF_PCT` requests a native Codex context cycle at a clean Stop.
Write durable notes and run `fleet-transfer.sh --window PANE --to codex
--handoff NOTES --after-turn`. The existing transfer controller retains the
account home, transcript provenance and worktree. See [session transfer](SESSION-TRANSFER.md).

## Messaging

`fleet-peer-send.sh -L SOCKET %PANE 'message'` and `fleet-report-parent.sh`
recognise Codex targets. They use the recorded UUID and CODEX_HOME and propagate
queue failures. Child reports are marked delivered only after a successful
queue operation.

Fleet pane launches now create one private local app-server and connect the TUI
to its `unix://PATH` endpoint. Hook commands inherit that pane's environment;
configuration overrides reach both processes, and hook support is explicitly
enabled. The queue sender reaches this same server. It never types message text
into the terminal. TCP/remote-auth endpoints and Codex UUID or PID targets
outside a fleet pane are not yet supported.

`fleet-codex-runtime.py` supervises the TUI. A separate guardian owns the server
and watches a pipe held only by the supervisor: EOF shuts the server down even
if the supervisor is SIGKILLed. The private socket directory is mode 0700 under
`/tmp` to stay within macOS's Unix-path limit. Normal TUI exit keeps the shared
close-on-exit policy; crashes and signal exits remain visible. No shared daemon
or network listener is started, and no account config is rewritten.

`FLEET_CODEX_SERVER=0` preserves the embedded launch for troubleshooting; live
queue delivery then reports that no endpoint is available. An explicitly supplied
`--remote` endpoint retains its existing lifecycle. Profiles require Python 3.11+
so their TOML layer can also be applied to the server; ordinary launches work on
the existing Python baseline. The remaining parity work is tracked in #734.

The optional `fleet-codex-rpc.py` helper makes bounded local JSON-RPC reads through
the Unix WebSocket endpoint. `codex app-server proxy` is a raw byte relay and
does not turn newline JSON into WebSocket frames. Runtime tests cover the real
wire framing, including masking, fragmentation, ping/pong and RPC failures.

## Recovery and history

Crash snapshots and the closed-session ledger preserve the provider, exact root
UUID, CODEX_HOME and rollout path. The ledger watcher captures these before a
window disappears. A missing identity stays an unknown Codex session; it never
selects a Claude transcript from the same worktree. Old Claude rows and maps
remain readable without conversion.

`fleet-restore.sh` resumes Codex with its saved account home. `fleet-history.sh
resume KEY` and the dashboard restore action use native `codex fork UUID` by
default; `--no-fork` selects `codex resume UUID`. The shared launcher accepts
`--agent codex --codex-home PATH --resume UUID [--fork-session]` as well. If the
account home or exact rollout has been removed, history is review-only. Recovery
does not copy credentials or silently substitute another account.

## Startup and warm scratch panes

`FLEET_MCP_CONFIG` also applies to Codex. `none` disables configured MCP servers,
apps/connectors and automatic skill-driven MCP installation. A shared
`mcpServers` JSON allowlist translates stdio/HTTP definitions, including headers.
`FLEET_CODEX_MCP_CONFIG` overrides that policy and accepts native `mcp_servers`
JSON or a TOML file (Python 3.11+). An explicitly empty override keeps native
Codex defaults. Unsupported shared transports/fields and failed enumeration
stop the launch instead of silently loading the full MCP set.

`FLEET_CODEX_SUBAGENT_MODEL` defaults to a fleet-pinned Codex worker model;
`inherit` or empty preserves native selection. `FLEET_CODEX_SUBAGENT_EFFORT`
sets native reasoning effort. Explicit caller `-c` values win. Policies reach
both the private app-server and TUI without editing account configuration.
`FLEET_CODEX_HOME` optionally pins a pre-existing account home for new workers.

`FLEET_SCRATCH_POOL` now warms either provider. Pool launches load the owning
fleet's config even before their window moves into that fleet. The Codex probe
waits for a stable empty input, verifies launcher ownership, types one character,
and verifies that Ctrl-U clears it. It never presses Enter or sends a model
request. Trust dialogs, stale owners and shell remnants cannot become ready.
Claims check provider, account home, window size and age; an unavailable warm
entry falls back to the normal cold launch.
