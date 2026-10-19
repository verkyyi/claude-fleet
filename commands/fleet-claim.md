# /fleet-claim — the worker lifecycle: claim → charter → ground → work → ship

<!-- fleet skill · owner: worker -->

Claim the bound issue, load its charter, implement, open and merge your PR, report to your parent, then stop; a real blocker ends with ask + report instead.
You decide implementation, scope and when to land within these rails; no further approval is needed.
Every fleet step uses its `mcp__fleet__<name>` tool (Codex: the same tool on its `fleet` server), never the backing script; only a missing server permits the fallback in §排障.
Argument (`$ARGUMENTS`): none; resolve the issue from `@issue`, falling back to the `issue-<N>` worktree, never guess.
Background and incident references are in [WORKER.md](../docs/dev/WORKER.md); read it only when needed.

## 0. Resolve fleet + guard seat + read the issue — ONE call (run FIRST)

- Call **`mcp__fleet__brief`** with no arguments FIRST: it returns fleet/repo/base/merge method/seat, issue and comments, claim, charter layers, directive and `origin:`.
- Exit **0**: proceed; **2 ABORT**: not in a fleet, say so and stop; **3 REFUSE**: wrong seat, say so and stop; **4 FAIL**: no issue, say so and stop; **5**: issue read failed, fix or report it, never implement from a partial brief.
- `claim: HELD`: do nothing, never re-claim; `UNCLAIMED`: run exactly the claim command printed by the brief (`fleet-ticket.sh claim …` or `gh issue edit … --add-assignee @me`).
- Charter precedence is built-in §2 → gated repo `$FLEET_MAIN/.fleet/worker.md` (`FLEET_REPO_CHARTER=1`) → operator `~/.config/claude-fleet/fleets/<session>/worker.md`; later layers win; nothing printed means built-in only.
- Use only the repo resolved by the brief, follow its implementation directive, and retain `origin:` for the unconditional final report.

## 1. Ground yourself, then implement

- Read the full issue thread, its design/parent charter and the affected code; choose the implementation under §2.

### Ground cheaply — keep the broad sweep out of the main context

- Delegate broad read-only searches to `Explore` / `Plan` / `claude-code-guide` where available; no writing subagent or `isolation: worktree` (`hooks/agent-guard.py`); implementation belongs to this worker.
- Read targeted symbol ranges and `git log -p --follow` / `git log -S`, not whole files for narrow questions; enough grounding matters more than brevity.
- Read issues/PRs/checks through `mcp__fleet__gh` (`kind: issue|pr|checks`, `number`, `fields`, `max_age`); use `max_age: 0` or bare `gh` only for data the cache cannot supply; the merge gate is always `mcp__fleet__pr_verdict`.
- Waiting on another worker: `mcp__fleet-orch__await` (`issue: N`) if the dispatch group is mounted; `TIMEOUT` (3) means call again, it spawns one if none is live; otherwise read with `mcp__fleet__gh`, and report blocked if this prevents completion.

### Before you touch code: the 「改动前」 capture

- Call `mcp__fleet__evidence` (`action: line`) to read `上线证据:`; capture what it names BEFORE editing via `action: before`, `note` and exactly one of `file`, `text` or `pane`.
- No line (exit 1): use judgment, but capture at least one after-image or changed-command output at ship time; never reconstruct a before later.
- Use `mv: true` for `.playwright-mcp/` captures so the worktree stays clean; evidence stays outside git and belongs to the issue/EPIC.

## 2. The standing contract (built-in charter — the base layer)

- **Work only in this worktree.** Never edit/commit the base checkout; the base guard in `hooks/base-readonly-guard.py` enforces it.
- Comment via `mcp__fleet__comment` (`issue`, `body`), omitting `repo` to use this window's repo; default `mode: note` is RECORD-ONLY, not delivered to a worker.
- To reach a peer use `mcp__fleet-orch__send` (`to: issue:<N>`, `text`) where mounted, or `mcp__fleet__comment` (`mode: to-worker`); read the delivery receipt/stderr, never assume a posted comment arrived.
- Never address a peer by `<sess>:<idx>` or drive its pane with `tmux send-keys` (`hooks/bash-guard.py`); `FLEET_ALLOW_SENDKEYS=1` is for fleet plumbing only; isolated test sockets may be driven freely.
- Close a no-PR/research issue with `mcp__fleet__comment` (`close: true`), never bare `gh issue close --comment`.
- **Spot something else? Three moves**: a worker may spawn (#4591) but never `bind` (`bin/fleet-bind.sh`); one worktree, one issue, one PR.
- **Fix in place** only if ALL hold: blocks your done condition; same repo and deploy path (ships in this PR); small/local, roughly tens of lines with a test; no open issue/live owner; no shared API, protocol, schema, release/deploy or credential contract; name it in one PR-body line.
- **File and spawn it** if it blocks you but fails any condition: `mcp__fleet__file_issue` (`parent: <your issue>`, `spawn: true`), then `mcp__fleet-orch__await` it (its report comes to you); not worth doing now ⇒ file without `spawn`, `mcp__fleet__ask` + `mcp__fleet__report` (`state: blocked`) naming it.
- **File bare** if it does not block you: `mcp__fleet__file_issue` (`title`, optional `body`, no `spawn`); related work gets `parent: N`, unrelated work omits `parent`; no outcome report for an unrelated filing.
- **Let the Agent manage its context.** `/fleet-context` or `mcp__fleet__context` reports usage; with `auto_handoff_pct=0`, `WATCH` / `HANDOFF` are advisory, not instructions to clear or replace the session. Use `/fleet-handoff` when requested or when an explicit Fleet handoff policy is enabled.

**Done = ship it AND land it.** Run these steps in order:

1. **Verify** per the repo's `CLAUDE.md` / `README` / workflows; when PR CI runs the suite, CI is the verdict: don't run the suite locally; only reproduce a specific CI failure locally (`bin/run-selftests.sh <name>` here, never full gate or `--changed`).
   - If brief says `land: fleet` (`FLEET_LAND=fleet`), commit everything, call `mcp__fleet__pr_verdict` then `mcp__fleet__pr_merge` with no `pr`; it rebases/checks/fast-forwards the base; skip steps 2–3, report `merged` without `pr`; `FAILING`: fix/commit/retry, `CONFLICT`: rebase on `origin/<base>`, `BEHIND`/`PENDING`: call `pr_merge` again.
2. **Push**: commit all work, require empty `git status --porcelain`, then `git push -u origin issue-<N>`.
3. **Open (or update) the PR**: `gh pr create --repo <brief repo> --base <brief base> --fill` (or `gh pr edit`); body must contain `Closes #<issue>`, a short summary and verification; apply the draft-only rule below when present.
4. **Capture the 「改动后」 evidence** while the PR is open and before landing: `mcp__fleet__evidence` (`action: after`, `note`, exactly one of `file|text|pane`, `mv: true` for Playwright files), using the same subject as before; then `mcp__fleet__evidence` (`action: post`) to record all paths/notes once.
5. **Land it once the gate is green.** Read `mcp__fleet__pr_verdict` (`pr`) and branch on its verdict:
   - **READY** (exit 0): ONE `mcp__fleet__pr_merge` (`pr`) rechecks, merges with this fleet's method and deletes the remote branch only after success; require confirmed **MERGED** (exit 0); it falls back to REST under GraphQL limits, so don't wait for quota reset.
   - Never chain `push --delete` after merging; on failure fix/push/read the gate/retry, never delete an unmerged branch.
   - **PENDING**: call `mcp__fleet__pr_verdict` (`pr`, `wait: true`) instead of polling; **TIMEOUT** (exit 3) is undetermined, re-wait or report a genuinely stuck gate as blocked.
   - **BEHIND**: `gh pr update-branch <PR> --repo <brief repo>`, then re-read the verdict.
   - **FAILING / CONFLICT**: once notify the parent with `mcp__fleet__report` (`state: failed`, `pr`, `summary: 'RED: CI failure or merge conflict; fixing it'`), then fix/push/re-read; never merge red, use `--admin`, or force-push the base.
   - **Base branch itself red** (same failing check on base head, diff did not touch its subject): do not fix here; call `mcp__fleet__file_issue` (`breakage: true`, no `spawn`); exit 0 filed, exit 5 deduplicated, both return the ONE issue to wait for, never file another.
   - Wait for that breakage with `mcp__fleet-orch__await` if mounted, else `mcp__fleet__gh` (`kind: issue`) between `mcp__fleet__pr_verdict` (`wait: true`) reads; then re-read your gate; only `breakage: true` selects breakage deduplication.
   - **BLOCKED**: required review/branch protection is a real blocker; use the blocked outcome below and stop, never bypass it.
6. **Report to whoever spawned you** immediately after confirmed merge: always call `mcp__fleet__report` (`state: merged`, `pr`, `summary: 'one or two lines: change and parent-relevant notes'`), even if `origin: none` or the parent has closed; auto-merge armed is not MERGED.
   - `reported` (0) means delivered; no parent is silent success; `orphaned` (0) becomes a reminder; `queued` (3) will deliver later, don't resend; `undelivered` (1) means nothing arrived or waits, say so in the final line; another-machine parent uses the same tool.
7. **Then stop.** Cleanup owns the worktree/window/local branch; do not start new work here; file follow-ups separately and never make your merge live yourself.

- **A draft-only ticket stops at the draft.** If brief says `draft: WAITING`, run steps 1–4 with `gh pr create --draft`, copy its `pr body must carry` lines verbatim beside `Closes #<issue>`, call `mcp__fleet__report` (`state: waiting`, `pr`, summary with link), then stop; never `gh pr ready` or `pr_merge` before approval (`DRAFT-ONLY` gate).
- Draft approval arrives as 「批准（草稿单）…」 after `fleet-draft.sh approve <issue>`: resume step 5 (`pr_verdict` with `wait: true`, `pr_merge`, `report merged`); rejection 「拒绝（草稿单）…」 closes the PR, note it and stop.
- **Merged is not live, and making it live is not yours.** Never `/fleet-sync-install`, `bin/fleet-install-apply.sh` or `fleet-sync-logins.sh` against the live install; take branch evidence from this worktree and note 「已上线证据待 hub 批末同步后取」; EPIC closing sync and stable-following install are the driver's/operator's responsibility.
- **Host for the operator with doc-preview, never an Artifact.** Use `~/.claude/skills/doc-preview/share.sh <file.md|file.html>` and relay/open its READY URL per that skill; Artifact publishing is blocked by `hooks/artifact-guard.py`, reading/commenting on existing artifacts is fine.
- **Show the operator a file on THEIR terminal, never `open` it here**: `mcp__fleet__show` (`file`, optionally `inline: true`); `saved:<path>` (0) says where it landed on their computer, `unconfirmed` (0) no receipt, `failed:<why>` (4) not taken, `PATH` (2) means give the path; Markdown/HTML to read uses doc-preview.
- **Open a page in the operator's browser with `fleet-open`, never `open`**: `mcp__fleet__open` (`target: URL|:port[/path]|file`); `share.sh --open` combines hosting/opening; interpret `sent:iterm2`, `sent:tunnel`, `fallback:copied` per that skill.
- **A temp server binds 127.0.0.1 and dies with your work**: e.g. `python3 -m http.server --bind 127.0.0.1`, `vite --host 127.0.0.1`, `next dev -H 127.0.0.1`; stop it afterward, never widen its bind to share.
- **An `rm` path never starts with a bare variable**: `rm -f "${P:?}"/*`, never `$P/*` (bash-guard denies it, #4637).
- **Blocked = say why, never stall silently.** Unblock yourself when possible; otherwise `mcp__fleet__ask` (`question`, `kind: permission` only for needed authorization, `suggest` with reason; `default`/`due` are hints only — nobody answers at a deadline), then `mcp__fleet__report` (`state: blocked`, `summary`, `pr` if one exists), then stop.
- The question also goes to your parent session (the result's `parent` says whether it was told); a new turn clears blocked state, so ask again before stopping if its input did not resolve the blocker.
- Record a direct operator decision with `mcp__fleet__comment`, first line `决定（直达）：<what>`.
- **A `[child-report]` arriving in YOUR pane: acknowledge, don't take over.** Note it and return to your issue; no reply, opening its PR or adopting its follow-up; if needed read `mcp__fleet__status` or `mcp__fleet-orch__children` ONCE; only clear a blocker that is actually yours, in your worktree or by filing.

## 3. Report + proceed

Say one line: issue number/title, newly claimed or already held, charter layers (built-in / + repo / + overlay); then implement and finish with §2's merged or blocked outcome, without asking whether to proceed.
Operate only on this fleet's repo, sessions and ledgers.
Never run destructive tmux on the live fleet socket; use an isolated `tmux -L scratch` / `-S <sock>` for tests (`shell/cw.zsh` guard; `FLEET_ALLOW_TMUX_DESTROY=1` only for a legitimate live-server exception).

## 排障 — scripts, for when a tool is not enough

See [WORKER.md · 排障](../docs/dev/WORKER.md#排障--scripts-for-when-a-tool-is-not-enough) for a missing fleet server or load experiments; use `bin/fleet-loadgen.sh`, never a hand-written load loop/trap.
