# /fleet-epic-report — what the batch actually did, as a page you can read

<!-- fleet skill · owner: hub -->

PHASE 3 of the EPIC trio. Reconstructs a finished (or abandoned) EPIC from
GitHub and the fleet's own records, renders a reader-friendly HTML page, hosts it
on this machine's tailnet, and posts a durable summary back onto the EPIC issue.
Read-only against the repo except for that one closing comment.

**Argument** (`$ARGUMENTS`): the EPIC issue number. Optional — with none, resolve
the most recently updated `epic` issue in this fleet. Works on any past EPIC, not
just the one that just ended, so a report can be re-run after the fact.

## 0. Resolve fleet + guard seat (run FIRST, every time)

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"
SEAT=$(fleet_seat)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown}"
```

- **No fleet** → **ABORT**: *"not inside a fleet — run this from a fleet session."*
- **Wrong seat** — `owner: hub`: refuse when `$SEAT` is `worker`.

## 1. Gather — five sources, no invention

- **The parent**: charter, the `<!-- fleet:epic-tick -->` comment stream (the
  batch's own minute-by-minute log), the 待决 section.
- **The members**: every sub-issue — state, labels (`blocked` and why), its PR,
  merge time, and deploy state where the fleet has one. A member filed by
  `/fleet-epic-plan` carries a **上线证据** line in its body (issue #809): that
  line names the evidence the worker was asked to leave — a URL, a command's
  output, a pane — and is what to look for per member (issue #810).
- **The spend proxy**: **worker × hours**, from each member's window lifetime
  (spawn → reap) as recorded in `/fleet-history` and the tick log.
- **The quota trace**: the 5h% / week% snapshots the tick lines carry.
- **The evidence**: what each member looks like live, as its own worker captured
  it (issue #810) — `~/.claude/fleet/bin/fleet-evidence.sh list --epic <N>`
  prints one row per capture (`member · stage · ts · path · note`) and a `none`
  row for a member with nothing. The stages are `before` / `after` — the
  worker's, taken at the same URL / command / pane the member's `上线证据:` line
  named, before touching code and after the PR was open — and `live`, which is
  yours (step 2). **Collect, never create**: a missing before/after is not
  re-shot and not staged; the member is reported as **无证据**, in those words.

**A hard limit to state plainly in the page, not to paper over:** this fleet
cannot attribute tokens to an issue. There is no session→spend join yet
(issue #625), so "cost per issue" is **worker-hours**, and the quota curve is
**pool-wide** — it includes whatever else ran on those accounts. Say that on the
page. A number presented as a token attribution when it is an occupancy proxy is
worse than no number, because the next batch would be planned against it.

## 2. Build the page

Before writing any chart, load the `dataviz` skill; before the page itself, load
`artifact-design`. This is a document somebody reads at breakfast, not a log dump.
Start from the shared frame — `cat ~/.claude/skills/epic-page/template.html` —
the same `<style>` and section ids the batch's design page used (issue #809), so
the operator reads plan and report as one document; swap the plan-only sections
(`#signoff`) for the report's own (verdict, quota curve, obstacles), and fill the
report-only block inside each member card — the `.proof` grid under its
`上线证据` line (issue #810, below).

What earns its place:

- **The verdict, first.** Completed / not completed / blocked, in counts, above
  the fold. Whether the batch achieved the thing the charter said.
- **Per member**: what it was, what shipped (PR link), how long its worker held a
  slot, and for anything unfinished — *why*, quoted from the tick log or the
  `blocked` reason, not paraphrased.
- **The quota curve** over the batch, annotated where an account was benched or a
  window was waited out. The waits are the interesting part: they are where the
  batch's wall-clock went.
- **Obstacles.** Every retry, every red that turned out to be the gate rather than
  the change, every 待决 that parked a worker. This section is the report's real
  payload — it is what makes the next batch cheaper.
- **Per member, 「上线后长什么样」** — inside that member's card (`#members` ›
  `.ob#m-<key>`), under its `上线证据` line, the frame's `.proof` grid: three
  columns **改动前 · 改动后 · 已上线**, each cell an `<img>`, a `<pre>` (a
  command's output, a `tmux capture-pane -p`) or a `.none` placeholder, with the
  capture's note and UTC stamp as the caption. The FORM is whatever the member's
  `上线证据:` line chose (issues #809/#810). A dash before/after pair remains the
  right form for a fleet-side change — one form among several, not the
  definition of "graphically": this skill ships to web products too, and a report
  on one that shows only the dash has shown nothing.
  - **改动前 / 改动后** come from the workers through `fleet-evidence.sh` (step 1).
    A missing stage is a `.none` cell reading **无证据**. Do not take a "before"
    now — the change has landed, and the picture would be fiction.
  - **已上线** is yours, once. When the fleet has a deploy signal
    (`FLEET_DEPLOY_REF` / `FLEET_DEPLOY_CHECK`, #541) and the member's deploy state
    is green, capture ONE shot from prod along the same line the worker followed,
    and store it where a re-run of this report finds it again:
    `~/.claude/fleet/bin/fleet-evidence.sh live --issue <M> --epic <N> --note '…' <file>`
    (`-` for a command's output on stdin, `--pane <t>` for a TUI). No deploy
    signal, not yet green, or prod unreachable from this machine → a `.none` cell
    reading **未取到** and the reason. Reachability is an egress fact, not a
    constant: the monorepo's smoke suite says prod needs a China-reachable host,
    while a 2026-09-19 probe from the macbook got HTTP 200 — try once, report what
    happened.
  - **Getting the files into the page**:
    `~/.claude/fleet/bin/fleet-evidence.sh export --epic <N> <dir-of-the-report-html>`
    copies every file to `<dir>/evidence/<M>/…` and prints the same rows with
    RELATIVE paths — reference those (`<img src="evidence/42/after-….png">`).
    doc-preview copies a relative `<img src>` file beside the served page (as it
    already did for Markdown images), so the pictures ride along to the tailnet
    URL. A playwright-MCP screenshot lands under the worktree (`.playwright-mcp/`):
    that is a source to hand to `fleet-evidence.sh live`, not a path to reference.
- **Proposed next batch**: the theme's leftovers plus what this batch surfaced,
  as a suggestion for `/fleet-epic-plan`, explicitly not a decision.

## 3. Publish

**Artifact publishing is hook-blocked inside fleet sessions** (issue #526/#527) —
use doc-preview, which is the repo-shipped skill for exactly this:

```sh
~/.claude/skills/doc-preview/share.sh <report.html>
```

Relay the READY tailnet URL to the operator.

Then post the **durable half** as one comment on the EPIC issue: the verdict
counts, the completed/unfinished/blocked lists, the obstacles, the URL, and per
member which evidence exists — the `dir:` path from its worker's 📎 comment, or
**无证据**. The tailnet URL dies with the next reboot; the comment is what
survives, so it must stand on its own without the page. `gh` cannot attach an
image to a comment, so the paths ARE the evidence's durable half; the files stay
under `$FLEET_CONF_DIR/fleets/<sess>/epic/<N>/evidence/`. Do **not** commit the
report or the evidence into the repo — this skill ships to team repos too, and a
batch report is not their artifact (committing evidence under a repo path is a
deliberate opt-in that does not exist yet; follow-up #816).

## 4. Close the loop

If every member is resolved, close the EPIC issue with the summary comment as its
closing note. Leave it open when anything is still `blocked`, and say which.

## 5. Report (keep it short)

One line: the URL, the verdict counts, and the suggested next theme.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only. Read-only except for one
comment (and closing the EPIC when it is genuinely done). Never invent a number
the fleet cannot measure — an honest worker-hours figure labelled as such beats a
token attribution this fleet has no way to compute.
