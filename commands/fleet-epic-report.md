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

## 1. Gather — four sources, no invention

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
(`#signoff`) for the report's own (verdict, quota curve, obstacles).

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
- **Where a change is visible in the TUI**, a before/after `tmux capture-pane -p`
  pair in a monospace block. This fleet has no web UI; its interface is the dash,
  so "graphically" means showing the dash.
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
counts, the completed/unfinished/blocked lists, the obstacles, and the URL. The
tailnet URL dies with the next reboot; the comment is what survives, so it must
stand on its own without the page. Do **not** commit the report into the repo —
this skill ships to team repos too, and a batch report is not their artifact.

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
