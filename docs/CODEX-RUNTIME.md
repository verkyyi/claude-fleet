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

Context measurement does not activate Claude's auto-handoff directive on Codex.
The native Codex context cycle is a separate adapter.

## Messaging

`fleet-peer-send.sh -L SOCKET %PANE 'message'` and `fleet-report-parent.sh`
recognise Codex targets. They use the recorded UUID and CODEX_HOME and propagate
queue failures. Child reports are marked delivered only after a successful
queue operation.

Delivery currently requires that the worker was launched with an explicit
local `--remote unix://PATH` endpoint. The ordinary embedded CLI server has no
external queue endpoint. The adapter refuses that case rather than starting
another server and claiming the live worker received the message. It never
types message text into the terminal. TCP/remote-auth endpoints and Codex UUID
or PID targets outside a fleet pane are not yet supported.

No daemon is started and no account files are changed by these telemetry and
messaging adapters. The remaining runtime work is tracked in issue #734.
