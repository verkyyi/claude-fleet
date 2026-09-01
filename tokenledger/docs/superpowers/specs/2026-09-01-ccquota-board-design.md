# ccquota board — design

**Date:** 2026-09-01
**Status:** proposed design, pre-implementation
**Approach:** a fourth role on the existing binary (`ccquota board`), GitHub OAuth
identity, aggregates-only submissions, a static SVG badge for any README

---

## 1. Problem

ccquota tells one operator what their fleet spent. Two things it cannot do:

1. **Share a figure durably.** The share page (`/share`) is a revocable link to a
   redacted page — right for handing a number to one person, wrong for a badge
   that lives in a README for a year.
2. **Compare across people.** A company wants per-engineer cost visibility, and
   an individual wants to show what they have spent. Both need a place where
   several people's aggregates sit side by side.

## 2. Goals

- A **badge** at a stable public URL, renderable on a GitHub profile README, a
  project README, a GitHub Pages site, or anywhere else that renders an image.
- A **wall** — one page showing the people on a board.
- **Self-hostable by a company** as an internal board, with the public instance
  being the same software, deployed once.
- Ship as part of the open-source project, not as a private service.

## 3. Non-goals

- **A competitive ranking.** Token count measures spend, not output or skill: a
  loop replaying a large cached context out-ranks every real engineer, cheaply.
  A board whose optimal strategy is burning quota is not worth building, and
  quota is a shared rate-limited resource. The wall shows people; it does not
  crown one.
- **Verification of submitted numbers.** ccquota reads local transcripts and
  nothing signs them, so no protocol can make a submission trustworthy. GitHub
  identity makes a handle unforgeable; it does not make the number true. The
  wall must say so rather than imply an audit that does not exist.
- **Per-project or per-machine detail.** See §7.

## 4. Architecture

A fourth role on the same binary, alongside `report` / `agent` / `hub`:

```
ccquota board --addr :8080 --db board.db --github-client-id ... 
```

One binary, one install story. A company self-hosts the board exactly as it
self-hosts the hub; the public instance is the same code with a domain.

```
   person's hub                          board service
   ────────────                          ─────────────
   holds the totals                      GitHub OAuth  ──► handle
        │                                mints submit-token (shown once)
        │  POST /v1/board/submit                │
        │  Bearer <submit-token>                ▼
        └──────────────────────────────►  aggregates (SQLite)
                                                │
                                    ┌───────────┴───────────┐
                                    ▼                       ▼
                              GET /  (the wall)     GET /badge/<handle>.svg
```

### 4.1 Components

| component | responsibility |
|---|---|
| `internal/board` | OAuth flow, submit-token issue/verify, aggregate store, wall + badge handlers |
| `internal/board.Entry` | the submission payload — a type built from scratch, never the internal model with fields hidden |
| `internal/badge` | SVG rendering, self-contained |
| hub submitter | opt-in; posts the hub's aggregate on a slow timer |

## 5. Identity

**A row is a person**, aggregating all their hubs and machines. A company with
one shared hub still gets one row per engineer, which is the internal-board use.

**GitHub OAuth**, because a public board's failure mode is impersonation: the
first time someone claims a well-known handle, the board is worthless. GitHub
supplies the handle and it cannot be claimed by anyone else.

`--auth=github|token`, defaulting to `github`. An internal deployment that
cannot register an OAuth app, or is air-gapped, uses `token` mode: the operator
mints participant tokens the way `ccquota enroll` already mints endpoint tokens.
Without this, self-hosting requires github.com reachability, which defeats the
internal use for exactly the companies most likely to want it.

## 6. Submission contract

```jsonc
{
  "handle":      "verkyyi",          // from the token, never from the payload
  "tokens":      69845943231,
  "turns":       267607,
  "period":      "all",              // all | 30d | 7d
  "model_mix":   [ {"model":"claude-opus-5","tokens":54000000000}, ... ],
  "generated_at":"2026-09-01T21:00:00Z",
  "agent_version":"c5eaeff"
}
```

The handle is taken from the authenticated token, never from the body. A payload
that could name its own row is a payload that can overwrite someone else's.

## 7. What a submission may never contain

The same exclusion list `/share` already enforces, applied at the submission
boundary:

| shown | never shown |
|---|---|
| tokens, turns, period | project paths (client names) |
| model mix | machine names, OS logins |
| handle | session ids, git branches |
| | account emails or uuids |
| | utilization percentages (see below) |

`Entry` is defined from scratch rather than derived from `model.UsageEvent` or
`ShareView`. Redacting a rich struct loses over time: every field added later is
exposed by default, and here the destination is a **permanent public wall**, not
a link someone chose to hand over. A field can appear only by being written into
`Entry` on purpose.

Utilization is excluded deliberately. It is a percentage of an allowance that
differs per plan, so publishing it leaks plan tier by inference and says nothing
useful about the person.

## 8. The badge

**Constraint that shapes everything:** an SVG loaded through `<img>` — which is
what a README, a profile page and a Pages site all do — is a sandboxed context.
No scripts, no external fonts, no external CSS, no network. Everything inline.
GitHub additionally proxies through camo, which strips cookies, so the badge URL
must be publicly readable with no auth.

```
GET /badge/<handle>.svg?theme=dark|light&period=all|30d
Cache-Control: public, max-age=300
```

- Fonts: a system stack (`-apple-system, Segoe UI, Helvetica, Arial, sans-serif`),
  never a webfont.
- Themes: an explicit `?theme=` parameter. `prefers-color-scheme` inside an
  SVG-as-image is inconsistently supported and camo caches one copy for
  everyone, so README authors use the documented `<picture>` pattern with two
  URLs instead.
- Staleness: camo caches, so a badge is **not live** and must not imply it is.
  The badge carries a period label, not a timestamp that will be wrong.

## 9. The wall

One page, all participants. Sorted by **most recently active**, not by tokens —
a page sorted by tokens is a ranking whatever it is called, and re-creates the
incentive §3 rejects. No rank numbers.

Each row: handle, avatar, tokens, turns, model mix, last updated. The page states
plainly that figures are self-reported and unverified.

## 10. Failure modes

| failure | behaviour |
|---|---|
| board unreachable from a hub | submission is dropped; the hub retries next tick. Nothing is queued: an aggregate is a snapshot, and a stale one has no value |
| submit-token revoked | 401; the hub logs and stops until reconfigured |
| a handle stops submitting | the row keeps its last figure with an explicit "last updated"; it is never zeroed, which would read as "spent nothing" |
| board has no entries | the wall says so rather than rendering an empty leaderboard |
| badge requested for an unknown handle | 404 with a generic SVG, never a zeroed badge |

## 11. Testing

| area | test |
|---|---|
| payload | a submission carrying project paths / machine names / emails is rejected or stripped, asserted against a seeded fixture — the `/share` pattern |
| handle | a body claiming a different handle cannot overwrite another row |
| badge | renders with no external references at all (no `@import`, no `href` to a font or image); a known input produces a stable SVG |
| badge staleness | cache headers present and bounded |
| wall ordering | sorted by recency, not by tokens — a control asserts a high-token stale row does not float to the top |
| auth | `token` mode and `github` mode both gate submission; an unauthenticated POST is refused |

## 12. Open questions

1. **Where does the public instance run, and who pays for it?** Hosting,
   moderation of display names, and uptime are an ongoing commitment distinct
   from shipping the code.
2. **Anthropic's terms** on publishing usage figures and on tooling that
   encourages consumption — worth checking before promoting a public instance,
   rather than assuming.
3. **Retention.** How long a row survives after someone stops submitting, and
   whether deletion is self-service (it should be).
