# Auto-triage — one line → a triaged issue

> **Optional, opt-in per fleet.** Off by default. Set `FLEET_AUTO_TRIAGE=1` for a
> fleet to turn it on. Needs `claude` on `PATH` (and `gh` for the label/milestone
> whitelist). Issue #235.

Filing a good issue is friction: a title, a body, the right milestone, a type
label, a priority. The one-line capture (`⌃n` in the backlog, or `prefix+n`
quick-dispatch) is fast precisely because it skips all that — you type one line
and it files. **Auto-triage** keeps that speed but fills the rest in for you: one
line in, a well-formed issue out.

When `FLEET_AUTO_TRIAGE=1`, the capture path runs a single `claude -p` pass
(`bin/fleet-triage.sh`) that turns your line into:

- **a refined title** — concise, specific, imperative (auto-elaborate);
- **an elaborated body** — a few sentences of what/why/scope, folding in any
  rough notes you typed (auto-elaborate);
- **a component milestone** — the fleet repo's milestones *are* its component
  taxonomy (auto-classify);
- **a type label** — `bug` / `enhancement` / `documentation` / … (auto-classify);
- **a priority tier** — `priority:p0|p1|p2`, the *same* label the autofill
  dispatcher ranks by and the backlog rows now tag + sort by (auto-priority).

Off (the default), or with no `claude` on `PATH`, the capture is exactly as
before: raw, fast, zero-token. Auto-triage only ever *adds*.

## The validation rail (why a hallucination can't break a capture)

An LLM will occasionally suggest a milestone or label that doesn't exist. The
helper is built so that never reaches `gh`:

- `bin/fleet-triage.sh` fetches the repo's **real** milestone + label sets (via
  `gh api`, once per capture) and passes them to the model as the ONLY allowed
  choices.
- Whatever the model returns is then **validated against those sets**. A
  milestone or label that isn't a verbatim (case-insensitive) match is **dropped,
  never invented** — so the `gh issue create --milestone/--label` that follows
  cannot fail on a bad name.
- Control/routing labels (`steward-control`, `blocked`, `scout`, `duplicate`,
  `wontfix`, `invalid`) are **stripped** from the classify output, and the
  priority tier comes only from the model's dedicated `PRIORITY` field — so
  triage can add a type label + one priority tier, and can never mislabel a fresh
  issue into the control plane.

Net: worst case, triage adds *less* than it could (a dropped guess), never
something wrong or something that wedges the create.

## Cost & gating

One `claude -p` call per issue you capture — small, on `haiku` by default
(`FLEET_AUTO_TRIAGE_MODEL`), and only on the **fast path** when a human files an
issue. It is not a background sweep, so it is single-writer by nature (the capture
process) and needs no daemon, no lease, no disk gate. Like the other
token-spenders (`FLEET_AUTOFILL`, `FLEET_ISSUE_BRIDGE`, `FLEET_WATCH`) it is
opt-in per fleet.

## Config

| Key | Default | What |
|---|---|---|
| `FLEET_AUTO_TRIAGE` | `0` (off) | `1` runs the triage pass on the one-line capture for this fleet |
| `FLEET_AUTO_TRIAGE_MODEL` | `haiku` | model the pass runs on (`claude -p --model`) |

Both are per-fleet (set in `$FLEET_CONF_DIR/<session>.conf`, or globally in
`fleet.conf`) and appear in the `prefix+c` config modal under **triage**.

## Priority management in the backlog (companion to auto-triage)

Auto-triage sets priority automatically; you also manage it by hand from the
panel:

- **See it** — each row carries a colored `p0`/`p1`/`p2` tag (read from the
  collector's `labels_<slug>` cache — no extra `gh` call). Rows are sorted by
  priority tier within each milestone, so the top of a group is what to do next.
- **Set it** — `⌃y` on a highlighted issue cycles its priority label one step and
  wraps: **none → p2 → p1 → p0 → none** (`bin/dash-issue-priority.sh`). No popup,
  no confirm — it edits the label, optimistically updates the cache so the tag
  repaints at once, and reconciles in the background.

## Scope / what this is not

This ships auto-triage as an **inline** pass on the fast capture path. A
**background triage daemon** that sweeps issues filed *outside* the fleet (e.g.
straight on GitHub) and triages them after the fact is a natural follow-up — it
would reuse `bin/fleet-triage.sh` unchanged, wrapped in the same single-writer +
disk-gated + rate-limited daemon shape as `bin/fleet-dispatch.sh`. Not built here.

## Files

| File | Role |
|---|---|
| `bin/fleet-triage.sh` | the LLM triage pass + validation rail (one `claude -p` call → a validated title/body/milestone/labels block) |
| `bin/dash-issue-new.sh` | the capture path — calls the helper when `FLEET_AUTO_TRIAGE=1`, applies the result on `gh issue create` |
| `bin/dash-issue-priority.sh` | `⌃y` priority cycle (label swap + optimistic cache) |
| `bin/tmux-issues-rows.sh` | priority tag + in-milestone priority sort |
| `bin/fleet-triage-selftest.sh` · `bin/dash-issue-priority-selftest.sh` | hermetic tests |
