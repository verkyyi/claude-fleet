# Codex runtime adapters

`fleet-codex.sh` gives each launch an owner PID. The shared hook table calls
`fleet-codex-session.py` at SessionStart and Stop; it is a no-op in Claude
sessions. SessionStart records the exact root session UUID, CODEX_HOME,
transcript path and model in one `@codex_identity` JSON option. Hooks from an old
launcher cannot overwrite a replacement. Stop refreshes only the current UUID.

Codex 0.162 runs SessionStart only at a thread's first turn, so the identity
does not wait for it (T629, EPIC T580 C5). The runtime's follower
(`fleet-codex-session.py` `Follow`, ticked once a second by
`fleet-codex-runtime.py`) asks the window's private server for the TUI's thread
while the launch has named none and stamps it (`witness`: same launcher, no
`@codex_session_id` yet); on a `thread/started` after that it re-points the
window (`follow`, a `/clear` or `/new`). Both add the ID's segment through the
ONE witness Claude's SessionStart also feeds, `fleet_id.hook` — startup, resume
when it is the thread the launch was opened for, clear — so a dispatched task
reads as started before anyone speaks. The adapter table says where each agent's
conversation id comes from (`sid_source`), whether its start says /clear
(`clear_said`), and `session_id` / `fleet_agent_session_id` is the one reader of
a window's current id. `fleet-agent-witness-selftest.py` runs the start, the
start before the first turn, the clear and the reopen once per agent.

The opt-in offline `fleet-native-local-runtime-selftest.py --launch-flags`
compares native worktree ownership with per-launch config, profiles and dedicated
model/permission flags. A running daemon and readable history do not prove that
it owns the TUI: even an unchanged `-c model=...` can select an embedded runtime.
The configuration-file control and dedicated flags are tested separately, with
request/turn metadata and unchanged backend defaults. See the
[launch-boundary matrix](NATIVE-AGENT-BOUNDARY.md#逐次配置不是共享后台配置启动参数矩阵).
Do not discard user profiles, rewrite a live shared home, or remove fixed-account
verification to make a session fit the shared-backend path. No launcher behavior
changes in this probe; full MCP, credentials, guards and concurrent sessions
still require integrated acceptance.

## Shared-backend MCP identity (migration gate)

The explicit offline `fleet-native-session-env-selftest.py` keeps two native
local TUIs alive against one verified backend and calls an inert MCP tool for
each native worktree. Distinct MCP processes inherit the backend's fixture
environment, not each client's session values. Native request metadata carries
the routed thread ID, but this is context, not a credential: an RPC caller can
still choose the target thread, and arbitrary other metadata survives.

Do not move session-scoped worker credentials, terminal identity or roles into
a shared backend environment. Adoption requires a verified native-root-to-Fleet
ownership/capability binding, with the existing authorization and revocation
checks intact. Concurrent admission correlation is not implemented by this
probe. Unknown or stale bindings must not execute tools. The current private
runtime remains unchanged; this result is not evidence of a live credential leak.
See the [concurrency boundary](NATIVE-AGENT-BOUNDARY.md#共享后台的-mcp-环境不是逐客户端环境).

Add `--hooks` to inspect reviewed fixture SessionStart callbacks under two
independent TUI supervisors. The existing native-parent verifier identifies
the shared backend, not either supervisor's descendant; launcher and admission
context environment also belongs to that backend. Do not remove ancestry checks
or infer a platform launch binding from a thread ID/cwd. The fixture correlates
each root's own loopback request instead of counting unrelated title requests.

The additional `--hooks --fork-seed` fixture creates and names empty native
threads, then runs local `codex fork <id> --worktree`. A synchronous callback can
read its exact `forkedFromId` through the PID-verified backend. Reusing the source
is allowed by native Codex, so this relationship is not one-use authorization.
The fixture also accounts for the source's extra MCP process, retires owned empty
sources through native archive/delete, and resumes the user fork without another
worktree. No production launch mode is added. Existing admission/capability
binding and per-thread stop evidence remain required before adoption; neither
TUI exit nor a shared backend PID alone proves that execution stopped.

## Managed guard configuration (candidate)

The candidate renderer derives native managed hooks from the existing
`hooks/settings-hooks.json` and `hooks/codex-map.json`. It does not introduce a
second policy table. `managed_commands` explicitly selects the two reviewed
guard commands; matchers still come from the source table and Codex mapping.

To inspect the proposed configuration without installing it:

```sh
bash bin/fleet-hooks-emit.sh --target codex-managed \
  --managed-dir /opt/fleet-reviewed-guards --python /usr/bin/python3
```

This prints a TOML fragment only. It does not create paths, copy scripts, read
credentials, merge administrator policy, or write `/etc/codex`. Do not overwrite
an existing `requirements.toml` with this fragment. The named directory and
interpreter are eventual installation paths, not proof of ownership or trust.
Managed paths must be absolute and normalized; shell quoting preserves spaces
and apostrophes. Guard commands use an absolute Python interpreter with `-I`.

The fragment requires native hooks and contains only the reviewed PreToolUse
guards. Missing, duplicated, dropped or unsupported guard wiring fails before
any output. Plugin directories and partial event selection are rejected.
Optional plugin hooks retain native review; lifecycle, title and state hooks
are not promoted to system-managed trust. Existing `codex` and `claude` targets
retain their output and remain the production launch path.

The native managed-hooks CI consumes this renderer's output for real Bash and
code-mode file-edit tests. Installation remains gated on administrator-owned
scripts and interpreter, cross-account isolation, preservation of existing
requirements, native effective-config checks, upgrade and rollback. Neither
the renderer nor the guards establish a filesystem sandbox. No launcher bypass
is removed by this change. See [migration evidence](NATIVE-AGENT-BOUNDARY.md).

The candidate managed-image stager records this preview in its existing
`.release/staged.json` metadata, regenerating paths when an image seeds a
different runtime version. Image-owned personal POD previews use the read-only
image seed, not the login-owned PVC runtime. The preview is informational and
must not be copied into system policy as an authorization shortcut. See
[image upgrade and recovery](MANAGED-LINUX.md#upgrade-and-recovery).

The explicit installer candidate reuses the image stager; stage, seed and boot
do **not** invoke it. An administrator can inspect a protected, already staged
release with:

```sh
/usr/bin/python3 -I /opt/fleet/current/extras/managed-node/image-stage.py \
  guards-install /opt/fleet/current /etc/codex --check
```

On a Mac managed node the same command runs against the root runtime. Codex
reads `/etc/codex/requirements.toml` on every Unix, macOS included (the
`/etc` link resolves to `/private/etc`); a forced MDM preference
`com.openai.codex` `requirements_toml_base64`, when an organisation sets one, is
a further layer this installer neither writes nor reads. macOS ships no
`/etc/codex`, so the administrator creates it first:

```sh
sudo install -d -o root -g wheel -m 0755 /etc/codex
sudo /usr/bin/python3 -I "/Library/Application Support/claude-fleet/current/extras/managed-node/image-stage.py" \
  guards-install "/Library/Application Support/claude-fleet/current" /etc/codex --check
```

macOS's `/usr/bin/python3` is 3.9, which has no `tomllib`. The installer then
reads TOML through its own strict subset (`_TomlSubset` in `image-stage.py`:
tables, arrays of tables, one-line strings, booleans, decimal numbers, arrays,
one-line inline tables). Whatever it accepts it reads exactly as `tomllib`
does (`fleet-node-linux-selftest.py` holds the two together); anything outside
the subset — multi-line strings, dates, hex numbers, a reopened table — is
refused and nothing changes. The interpreter checks are unchanged: the release,
`/etc/codex` and `/usr/bin/python3` must still be root-owned and not writable
by other users.

Omitting `--check` atomically installs the requirements. This is an administrative
operation, not a launch-time repair. Both directories must already exist. The
release, symlink and ancestor directories, guard scripts and system interpreters
must be root-owned and not writable by other users. No test-environment variable
relaxes these checks. The existing verified release publisher remains the source
of trust; the installer does not perform a new signature verification.

Use the protected root runtime `current` for node-owned installs, or the protected
image-seed `current` for image-owned personal PODs, **never their writable PVC**.
The installed commands follow that stable anchor through an update or rollback;
publishers must retain compatible guard entrypoints. A changed hook table needs
administrator reconciliation rather than silent replacement. Live rollout,
rebuild, root-publisher ownership and old-session compatibility remain acceptance
gates, not results of a temporary fixture.

Installation regenerates the reviewed policy rather than trusting the staged
preview. It preserves unrelated parsed requirements, refuses conflicting hook
policy, malformed TOML or unsupported value types, and does not disable optional
plugin hooks. The first merge canonicalizes TOML formatting and drops comments;
an identical policy is kept byte-for-byte. Check-only writes nothing. Publication
uses a directory lock, rechecks the active release and prior bytes, and replaces
the file atomically. A post-replacement filesystem-sync error can report failure
after publication: inspect the file before retrying. This is not protection
against a malicious root administrator or a general policy rollback service.

`fleet-native-guard-install-selftest.py` is an explicit disposable GitHub-hosted
Linux CI probe: a private mount namespace holds root-owned fixture files, then
an unprivileged native backend reads them with user hooks disabled. It uses no
credentials or inference. Local lifecycle tests mock positive root ownership;
they do not substitute for this native permission/configuration check. Neither
test activates live policy or removes the launcher's hook-trust bypass.

## Native default installation (explicit candidate)

The existing default installer can delegate Codex configuration publication to
the native `config/batchWrite` API instead of editing user TOML itself:

```sh
python3 bin/fleet-agent-defaults.py apply --root /path/to/fleet \
  --codex-home /absolute/owned/codex-home --skip claude \
  --codex-native-remote unix:///absolute/owned/native.sock \
  --codex-native-peer-pid NATIVE_PID --dry-run
```

Supply the PID of an already running **idle maintenance backend** for exactly
that home. The adapter does not discover, start or stop backends. Remove
`--dry-run` only during an explicit maintenance window with new launches held;
use `check` instead of `apply` to report missing defaults without writing.
The existing RPC client verifies the kernel's Unix peer PID (and Linux peer UID), and the native base-user layer must
name the requested home's `config.toml`. Shared configuration symlinks, wrong
homes, active backends and malformed/unavailable native responses fail closed;
there is no silent fallback to the legacy writer. Loaded threads are checked
before planning and publication, but those reads are **not** an atomic launch
lock: operational exclusion of concurrent launches is still required.

The source remains `conf/agent-defaults/codex/config.default.toml`, with existing
override exclusions. Existing top-level values and same-name MCP servers remain
the user's, including explicit false/empty values. The native parser owns the
user file; missing values are sent in one batch with its `expectedVersion` and
`reloadUserConfig=false`. Native version checking is semantic, not a bytewise
file lock: a comment-only edit need not invalidate it. The probe verifies comment
preservation and refusal of a stale version after a value changes. No automatic
retry overwrites a newer configuration. A transport failure after submission can
leave the result unknown; inspect through native `config/read` before retrying.
An accepted user-file write does not override higher-priority managed policy.

This mode requires `--skip claude`; Claude installation and the ordinary legacy
path remain unchanged. Skill completeness checks still run. The shared RPC
helper ships in the agent bundle and client manifest. Nothing enables this mode
in normal installation or session startup yet. Full guards, auth, MCP and live
maintenance acceptance remain prerequisites for adoption and removal of launch
overrides; this is not a production latency result.

The explicit offline `fleet-native-local-runtime-selftest.py --native-config`
exercises dry-run, check, native publication/idempotency, wrong PID/home refusal,
an inert dotted-name MCP entry, semantic conflict handling and loaded-thread
refusal, then verifies actual local TUI/Worktree ownership. No real credentials,
inference or external MCP services are used.

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
interface; fixture tests pin the supported 0.162 shape — the release pin is
the only version supported, an older Codex is named as such (T588).

The native usage-event migration is not enabled by default. A passive status-observer
connection does not automatically receive token usage: the offline native
probe distinguishes initialize/read-only, resume and unsubscribe, and keeps
last-response usage separate from cumulative totals. It also exercises observer
reconnection during a held response and a real pending command approval; only
the original controller declines the command, and the canary must remain absent. Run
`python3 bin/fleet-native-usage-cli-selftest.py --codex /path/to/codex` explicitly;
it uses an empty HOME and a loopback synthetic endpoint, not real credentials
or inference. See [subscription evidence and remaining gates](NATIVE-AGENT-BOUNDARY.md#上下文用量不是同一条广播).

**Native usage pilot.** `FLEET_CODEX_NATIVE_USAGE=1` on a candidate private-runtime
launch lets the existing attention connection subscribe to its exact, already
loaded root thread using metadata-only `thread/resume`. This is not a second
server or inference request. The observer never answers approvals or starts a
turn. It asks the native server to suppress irrelevant item/text deltas on this
connection only; the original controller and approval clients retain theirs.
Helpers, title threads, unloaded threads and unknown sources are not subscribed.

The existing Meter projects native last-response usage, context limit, model
and effort onto the same measurement bus. Cumulative usage and cached input
are not added to live context. Once valid native usage is available, the
monitor renews a five-second lease and Meter skips its rollout polling. A fresh
thread may not yet have a persisted rollout: a rejected resume retains the
fallback, and a successful subscription does not invent missed usage. Until the
next usable native event, the old reader remains authoritative. Disconnect,
malformed events, changed launcher/root/account/endpoint, or a stalled monitor
restore fallback. This lease measures monitor progress, not upstream model
health. Missing counts or denominator remain unknown, never fabricated zero.
Native writes recheck identity and use an owner/root guard in the tmux command
queue. After fallback, equal native readings are published again rather than
being suppressed by an obsolete deduplication cache.

Unset the pilot variable for future launches to retain the original behavior.
This candidate does not change installed environments, hooks, authentication,
MCP, resource limits or the separate collector/context-command readers.
Validate with `python3 bin/fleet-native-usage-cli-selftest.py --meter-candidate`:
it runs the actual Monitor/Meter against a native server, but replaces the tmux
identity and measurement sink with fixtures. A separate isolated tmux test
checks write guards. Neither proves real-panel latency or production savings.

**Version pin.** The verified versions live in one constant,
`SUPPORTED_ROLLOUT_VERSIONS` in `fleet-codex-runtime.py` (prefix match on whole
components: `0.162` covers `0.162.x`). `fleet-codex-runtime.py version-check`
compares `codex --version` against it — exit 0 verified, 1 unverified, 2 not
installed or unreadable, one line of explanation. `fleet-doctor.sh` shows it as
the `codex` row (PASS / WARN / INFO). `fleet-codex.sh` runs the same check once
per launch: an unverified version still launches, with one stderr warning and
`version_warning` in `@codex_identity`. Pin with
`npm i -g @openai/codex@0.162.1`; `FLEET_CODEX_VERSION_CHECK=0` silences the
check. Add a version to the constant only after the rollout fixtures pass on it.

## Fullscreen chat (composer at the bottom)

Up to 0.155 Codex's main chat is always **inline**: an inline viewport drawn
right under the cursor, every finished message pushed into the terminal's native
scrollback. `tui.alternate_screen` / `--no-alt-screen` only decided whether the
OVERLAYS (diff, approval, transcript, resume picker) used the alternate screen —
`#{alternate_on}` stayed 0 and the composer sat under the last output, mid-screen
on a short conversation (issue #3157). Nothing in tmux or the fleet turned it
off; there was no fullscreen to turn on. 0.156 added the fullscreen renderer,
`tui.fullscreen_transcript` (default `true`), and the release pins 0.162.1, so
every fleet launch — new, resume, fork — comes up on the alternate screen with
the composer on the last rows. The fleet passes no `tui.*` setting: a person's
own `/tui` choice («Scrollback») is theirs, and under tmux `alternate_screen =
"auto"` means fullscreen (only Apple Terminal answering the DA probe over ssh
switches it off — inside tmux the answer is tmux's).

What changes with it:

- **Looking back.** Fullscreen Codex captures the mouse (any-event, SGR), so the
  wheel scrolls Codex's own transcript (PgUp/PgDn, `/` search too); tmux's
  copy-mode history no longer holds the chat. Pane scrapes that read scrollback
  (`capture-pane -S -…`: the park snapshot, limit-banner sweeps, a transfer's
  failure dump) see one screen for a Codex window — the rollout is the history.
- **Copying.** A drag selects in Codex; it copies on release (tmux ⇒
  `copy_on_select` auto) through `tmux load-buffer -w`, which the node / stage /
  shell confs forward as OSC 52 (`set-clipboard on` + `Ms`) to the person's
  terminal. iTerm2's own selection still works with its bypass modifier (⌥-drag).
- **⌘P and the 看台's keys** are tmux key tables, read before the pane — unchanged.

`FLEET_AUTO_HANDOFF_PCT` is opt-in (default 0 / off). Without an explicit Fleet
threshold, Codex owns native compaction and Fleet does not request a replacement
conversation at 80% context. Existing positive thresholds still request a Codex
context cycle at a clean Stop; no native model or compaction setting is rewritten.
Write durable notes and run `fleet-transfer.sh --window PANE --to codex
--handoff NOTES --after-turn`. The existing transfer controller retains the
account home, transcript provenance and worktree. See [session transfer](SESSION-TRANSFER.md).

## Messaging

Every message into a live session — `fleet-peer-send.sh -L SOCKET %PANE 'message'`,
`fleet-report-parent.sh`, a digest, the peer queue's replay, a hub relay — takes ONE
road for both agents: `fleet_agent_deliver` (`bin/fleet-lib.sh`, T626). Only «how it
is put in» differs, and that is the agent adapter table's `deliver` column
(`bin/fleet_agent_adapter.py`): a Claude takes it on its process's peer inbox
(`inbox`), a Codex window on its app-server thread queue (`queue`,
`fleet-codex-session.py send`, the recorded thread and CODEX_HOME). One outcome code
for both: 0 handed over · 3 held (nobody there to take it now — a Codex window not on
the thread it names after a /clear, a server that does not answer, a Claude whose
inbox will not answer: queued for the window's identity and replayed) · 1 refused.
The Codex sender's held code was 4; readers take 4 for one more version. Child
reports are marked delivered only after a successful hand-over.

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

Finished Codex windows can be reaped while their configured MCP servers remain
running. The reap gate verifies the current launcher/session, a completed idle
native turn and exact MCP launch arguments; it excludes only verified service
entrypoints and bundled helpers. Jobs beneath those processes, active tools,
unfinished goals/children and active loops still retain the window. Missing or
changed identity, an unavailable endpoint or an incomplete native inventory
also retain it. A legacy embedded launch without a private endpoint therefore
needs a normal session recovery before this gate can establish that it is idle.

Reaping is one road for both agents (T631, EPIC T580 C8): where they differ is
the adapter table's (`bin/fleet_agent_adapter.py`), never a branch on the name.
`end` says how the walk-away is heard — Claude's SessionEnd hook
(`prompt_input_exit|logout`), Codex's launcher exit 0 (`fleet_launch_end` →
`session-end-hook.sh --agent-exit codex <pid>`; `--codex-exit` forwards one
version) — and both then pass the same gates and the same close. `procs` /
`proc_js` name the agent processes `fleet-reap-live.py` looks for; `bg_probe` is how `fleet_window_bg_busy` asks a finished turn's
leftover work (`pid`: the agent's Bash-tool children; `native`: the inventory
above, unknown ⇒ kept); `daemon` / `cred_home` let `_fleet_agent_cred_daemons`
sweep the app-server a proxied session leaves behind once its credential is
revoked. `bin/fleet-agent-end-selftest.py` runs exit · killed · daemon · work
once per agent.

Native `--worktree` is local-session-only in the tested CLI releases and cannot
be added to this private `--remote` path. The runtime refuses that combination
before starting its server or invoking launch preparation; it does not silently
fall back to an unverified local runtime. Existing Fleet-created worktrees remain
the supported path pending the [native boundary migration](NATIVE-AGENT-BOUNDARY.md).

An offline native TUI probe now distinguishes local runtime ownership from
remote-mode restrictions. With an already-running, kernel-verified default
socket and daemon auto-start enabled in an empty test home, local `--worktree`
can belong to that server. Adding `--dangerously-bypass-hook-trust` instead
leaves it outside that server's loaded-thread inventory, despite readable
history and a running daemon. Run
`python3 bin/fleet-native-local-runtime-selftest.py --codex /path/to/codex`
explicitly to reproduce the three-way control. It installs no daemon package
or service, sends only synthetic loopback requests and cleans up its own
processes. Test hooks and plugins are disabled to isolate the argument effect;
this is not permission to disable production safeguards or remove the bypass
before managed guards and optional native hook trust are verified. Full launch
arguments, credentials, MCP, session registration and panel delivery remain
migration gates, not proven by the fixture.

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

For the verified Codex 0.162.1 release on a private Unix app-server, sleep uses
the native completed turn and its completion timestamp instead of collecting
duplicate Stop-hook evidence. The launcher sets the internal
`FLEET_CODEX_NATIVE_COMPLETION` capability only after its version check succeeds;
inherited capabilities are discarded. Other versions, disabled version checks,
non-private runtimes and Claude retain the existing Stop evidence path.
This does not skip sleep eligibility checks: exact conversation, process,
worktree and transcript binding, native idle state, goals, child agents, tools,
hook trust, idle grace and empty input are still verified before hibernation.
Missing native completion evidence refuses sleep rather than guessing.

State hooks submit their related tmux option writes in one command queue. Missing
optional evidence/detail fields do not stop later writes; non-Stop events still
invalidate old completion evidence, and Stop still evaluates all wait reasons.
The hook's state label is not proof that the native turn has completed.

## Startup

**One road for both agents** (T620, EPIC T580 C4). The one door, `fleet-claude.sh`,
execs the launcher the adapter table names (`bin/fleet_agent_adapter.py`, its shell
copy `bin/fleet-agent-adapter.sh` generated by `--emit-sh`). Both launchers source
`bin/fleet-launch-lib.sh` for every step they share — the configuration and per-fleet
overlay, trust, the MCP policy and the fleet tool service, the composed
configuration and its `@agent_cfg` stamps, the session credential and its refusal
marks — and ask the table, never an agent's name, wherever the agents really differ
(the resume / fork / model spelling, how a `/name` seed is taken, which option holds
the conversation id, park-resume, native worktrees, the login check). What
`fleet-codex.sh` keeps is Codex's own: `CODEX_HOME`, the hooks as `-c hooks.*` TOML,
`project_doc_fallback_filenames`, the full-access posture, the version check and
`@codex_pending`. `bin/fleet-launch-lib-selftest.sh` runs the same window-mark,
access, CLI-isolation, resume-spelling and refusal assertions once per agent.


The terminal panel's new-task row opens its composer. Activating **Open with
draft** opens a scratch with the typed text as an **unsent draft**. It does not
start a worker flow or press Enter.
Repository drafts retain hub placement and a dedicated `draft` field preserves
the text independently of the shorter window label. The client uses the `draft`
placement action so an older hub refuses instead of silently losing the text;
an older node rejects the unsupported field. Upgrade hub and nodes before clients.
Task dispatches, automation, and `--prompt` starts keep their seeded behavior. Drafts and submitted seeds cannot be combined.

The panel forwards its resolved agent even when it matches the default, avoiding
a second selection lookup after Enter. Node-side policy checks still apply.

While a launch is pending, the panel checks its result at most every 50 ms within
the existing input/redraw deadline. Idle polling and redraw frequency are
unchanged. The headless draft sender skips loading unused display translations;
interactive composition remains localized.

The detached dispatch process calls the already-loaded canonical compose sender
directly, rather than starting another Python interpreter. Placement still runs
through `fleet-client-place.sh`; each send uses private output files, without
redirecting process-global stdout/stderr. Placement refusals, receipts, draft
preservation and repository/client focus retain the same handling.

The raw launcher obtains the validated dispatch envelope and resolved provider
from one resolver process. Without a client lease or action key, local placement
skips loading the unused HTTP/signing modules and hub connection reader, and uses
the existing node adapter. Draft and attachment validation still precede this decision.
When both are present, hub errors still fail closed; admission, ownership and
provider checks remain on the launch path.

Measure panel acceptance to **draft ready**, then deliberate Enter to first token
and complete reply separately. Human editing time is not runtime latency. A
window appearing is not agent readiness, and draft-only opening is not a completed
model response. Model, effort, MCP configuration and concurrent workload must
accompany any five-second claim.

Credential-free session homes keep `app-server-control` private, just like
temporary runtime state. Linking that directory from the real account home makes
native Codex refuse startup; renewing a mirror replaces only that legacy symlink,
never the real account's directory or another session's sockets.

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

## Which subscription a Codex session runs on

A Codex launch never picks among this login's accounts (T560, EPIC T542 C5 —
the same as Claude since T550). Through this login's credential proxy
(`FLEET_CRED_PROXY=1`) the pool picks: the default home (`~/.codex`) holds no
credential on a credential-separated login, so a session started there names no
account and the proxy picks one per session, as it does for Claude (issue #4606,
issue #2412) — skipping an account at its limit, keeping a session on its account
while it has room, and on a `usage_limit_reached` 429 marking that account out
until its reset and sending the same request on one with room.
`fleet-cred-proxy.sh standing --provider codex` says which accounts a pick may
land on and when an exhausted one comes back; when none may, the launch prints
that line, and `FLEET_CODEX_QUOTA_GATE=1` refuses it. The central road skips the
same accounts on the hub (its pick by headroom and the cluster proxy's 429
rebind). With no proxy the session runs on its home's own login.

`FLEET_CODEX_HOME` pins the fleet's home (`~/.codex-accounts/<L>` stays pinned to
`<L>` through the proxy); an explicit `--codex-home` and a recorded recovery
identity take precedence; a handoff that NAMED a ccquota profile
(`--codex-profile`) runs under `ccquota codex run`, which holds the profile's
login lock for the whole launcher/server/TUI lifetime. Nothing else pins one: the
`FLEET_FAILOVER=1` launch pin (`fleet-account.sh profile`), the local pool
(`fleet-codex-account.sh`, `FLEET_CODEX_ACCOUNTS`), its quota collector, gate and
idle migration are gone — an old conf that still names them changes nothing
(`fleet-conf.sh migrate` comments them out). To use one Codex subscription from
another OS login, log that login in on its own (`ccquota codex login <name>
--device-auth`) or hand it to the hub's pool (`fleet-account.sh add --provider
codex`) rather than copying `auth.json`: the refresh token rotates on use, so two
copies log each other out. `fleet-transfer.sh --to codex --codex-home DIR` is
still there for an explicit transfer.

## Operator attention and answers

The attention monitor consumes native `thread/status/changed` notifications on
one connection to the existing private server. Regular status observation does
not start or resume a thread. Fetching pending question details still uses the
existing short-lived, loaded-thread-only replay path. Only the exact recorded root UUID is projected into the
Fleet attention indicator; launcher, account home and endpoint changes discard
the old connection. Once that connection has delivered a matching native status
event, an initial read and a 30-second reconciliation cover reconnects or missed
events. Until event delivery is demonstrated, reads retain the existing
two-second cadence on the reused connection; older servers do not silently lose
attention responsiveness. Reconnects must establish event delivery again.
The supervisor closes the monitor when its TUI exits.

Event processing is bounded; malformed, partial or excessive input drops the
connection without declaring a request resolved. Unavailable, unloaded and
failed native states are not successful completion. Existing conditional tmux
writes still protect replacement launchers and explicit blocked declarations.
If a status notification received during a reconciliation contradicts its
snapshot, neither is used to clear attention: the next tick rereads native
state. Events received during the read are not silently discarded.
This changes attention monitoring only: native question replies, approval
decisions, admission, MCP configuration and turn-completion acceptance retain
their existing checks.

The private runtime observes the exact live thread's native status using the
event stream and reconciliation above. Waiting for user input or approval sets the dashboard's `needs` state,
question/permission subtype and bell. Resolving that wait clears only native
attention; a worker's explicit `blocked` state is preserved. Embedded mode
(`FLEET_CODEX_SERVER=0`) has no native status/reply channel.

The dashboard answer key opens a Codex-specific popup. It rejoins the already
loaded thread with a metadata-only `thread/resume`, which replays pending server
requests. It never starts a new conversation or turn. Questions support choices,
free text and masked secret input where requested. Escape cancels the popup
without replying. Permission/MCP prompts show their native details for review.

The shell interface uses the same native path:

```sh
bin/fleet-answer.sh --session myfleet --show @12 --json
bin/fleet-answer.sh --session myfleet --answer @12 --request-token TOKEN 1 'text:some answer'
bin/fleet-permission.sh --session myfleet --show @12 --json
FLEET_ALLOW_AUTO_DENY=1 bin/fleet-permission.sh --session myfleet --deny @12 --request-token TOKEN
```

`TOKEN` is the `request_token` from the displayed request. It covers the launcher,
thread, request ID and contents. Replies recheck the worker identity and refuse
already-resolved requests; success requires `serverRequest/resolved`. Supported
refusals are command execution, file changes, additional permissions and MCP
elicitations. Refusal is opt-in; no native approval or permission grant is sent.
The fleet's default bypass posture normally produces no command/file approval
prompt, but a stricter caller configuration can.

## Model changes

Use the native settings API to change an idle worker without restarting it:

```sh
bin/fleet-codex-model.sh switch --session myfleet --window @12 --to MODEL --dry-run
bin/fleet-codex-model.sh switch --session myfleet --window @12 --to MODEL
bin/fleet-codex-model.sh limits --session myfleet --window @12
```

The switch binds the exact launcher/thread and refuses active work or pending
handoffs. It changes only the native model setting, reads it back, and leaves
account, permissions and conversation intact. Native settings notifications also
update the attached Codex TUI. This requires the private worker server. `limits`
prints the thread's native quota buckets (usage only). The quota-triggered
automatic fallback (`FLEET_CODEX_MODEL_FALLBACK` / `FLEET_CODEX_MODEL_LIMIT_IDS`)
left with the local account registry (T560).

## Native plugin migration

Codex's own plugin manager holds the optional plugins (T589, EPIC T580 C3). They
are still installed in one place, Claude Code's `/plugin`; at install time
`fleet-install-apply.sh` runs `bin/fleet-codex-plugins.py sync`, which follows
that record in every Codex home with the native installer — `codex plugin
marketplace add` (the same source Claude added), `codex plugin add` for a plugin
Claude has installed and enabled that the home lacks or holds at another
version, `codex plugin remove` for one of our marketplace's plugins Claude no
longer has. A launch writes nothing and passes no `--plugin-dir`: skills
(`<plugin>:<skill>`), converted commands (`<plugin>:source-command-<c>`), hooks
and `.mcp.json` servers are Codex's own. A `/name` seed for a plugin skill
becomes `$<plugin>:<name>`; one for a plugin command is expanded from Codex's
cached copy of the command file.

The first sync retires what the old bridge wrote — a `fleet-plugin-*` link into
Claude's plugin cache or this tree's `plugins/`, a marked single-file adapter,
the `config.toml` marker block — and says, never touches, a personal entry.
`codex.plugins` in `agent-overrides.json` leaves the login's Codex plugins to the
login. The four migration acceptances and where each is held:

| Acceptance | Held by |
|---|---|
| hook trust — a plugin hook is untrusted until reviewed; the fleet launcher's `--dangerously-bypass-hook-trust` runs it, as it ran the bridge's injected hooks | `fleet-native-hook-cli-selftest.py --remote-tui --probe-bypass` |
| MCP environment / timeout — a plugin server gets the session env only by `env_vars`, and its `tool_timeout_sec` holds | `fleet-native-plugin-cli-selftest.py` (bare · allowlist · expanded) |
| invocation names — `<plugin>:<skill>`, `<plugin>:source-command-<c>` | same, and `fleet-codex-plugins-selftest.sh` E |
| single owner — one sync clears the bridge and installs natively; nothing at launch | `fleet-native-plugin-cli-selftest.py --retire-bridge` (native-managed-hooks CI), `fleet-codex-plugins-selftest.sh` B/G |

See [the native boundary migration](NATIVE-AGENT-BOUNDARY.md).
