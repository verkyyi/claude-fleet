# ccquota board & badges — design

**Date:** 2026-09-01
**Status:** proposed design, pre-implementation
**Approach:** a local `ccquota badge` command as the foundation — no service
required — plus two optional roles: `ccquota board` (self-hosted, internal,
token auth) and `ccquota badges` (public, GitHub OAuth, per-person)

---

## 1. Problem

ccquota tells one operator what their fleet spent. Two things it cannot do:

1. **Share a figure durably.** `/share` is a revocable link to a redacted page —
   right for handing a number to one person, wrong for a badge that sits in a
   README for a year.
2. **Compare across people.** A company wants per-engineer cost visibility; an
   individual wants to show what they have spent.

These are **two different products** and an earlier draft of this design
conflated them. The tell was a `--auth=github|token` flag: a single service that
needed two authentication models was a single service doing two jobs.

|  | `ccquota board` | `ccquota badges` |
|---|---|---|
| runs | self-hosted, inside a company | one public instance, operated by the project |
| auth | operator-minted tokens (as `enroll` does today) | GitHub OAuth |
| identity | whoever the operator enrolled | unforgeable GitHub handle |
| purpose | cost visibility among colleagues | show a figure on a profile |
| exposure | behind a firewall | public by design |
| view | a wall of participants | one page per person |

## 2. Goals

- A **badge** renderable on a GitHub profile README, a project README, a GitHub
  Pages site, or anywhere that renders an image — **without requiring a hosted
  service**, because for this use case none is needed.
- A **public per-person page** the badge links to.
- An **internal wall** a company self-hosts, with no GitHub dependency and no
  public exposure.
- Both open source in this repo, sharing the renderer and payload.

## 3. Non-goals

- **A public leaderboard.** Token count measures spend, not output or skill: a
  loop replaying a large cached context out-ranks every real engineer, cheaply,
  and quota is a shared rate-limited resource. Making the public side
  per-person removes the ranking surface entirely rather than adding rules to
  police it. The internal wall lists colleagues who can sanity-check each other,
  which is a different thing.
- **Verification of submitted figures.** ccquota reads local transcripts and
  nothing signs them, so no protocol makes a submission trustworthy. GitHub
  makes a *handle* unforgeable; it does not make a *number* true. Both surfaces
  must say so rather than imply an audit that does not exist.
- **Per-project or per-machine detail.** See §6.

## 4. Architecture

**A hosted service is not required for the headline use case.** Measured:

| URL | content-type | usable as a README image |
|---|---|---|
| `raw.githubusercontent.com/<u>/<u>/main/x.svg` | `image/svg+xml` | yes |
| `gist.githubusercontent.com/.../raw` | `text/plain` | no — fine as data, not as the image |
| `img.shields.io/...` | `image/svg+xml` | yes, rendered from a URL you supply |

So the design is three layers, and only the first is required.

### Layer 1 — `ccquota badge` (local, no network)

```
ccquota badge --out ccquota.svg --theme dark --period all
ccquota badge --json --out ccquota.json      # shields.io endpoint schema
```

Renders from the local hub's own totals. No server, no account, no submission.
This is the foundation: every other layer is a way of *publishing* what this
produces, and building it first means the feature is useful before any service
exists.

### Layer 2 — publishing (pick one, all serverless)

| target | how | trade-off |
|---|---|---|
| own profile repo | commit the SVG; reference it relatively or via `raw.githubusercontent.com` | you own everything; needs a commit on a schedule |
| gist + shields.io | write the JSON to a gist; README points shields at it | no repo churn; depends on shields.io |
| own hub | serve it from a hub that is already publicly reachable | nothing new to run; most hubs are not public |

### Layer 3 — `ccquota badges` (optional hosted instance)

Buys exactly two things: **zero setup** — no token, no repo push, no scheduled
job — and a canonical **`/u/<handle>` page** for the badge to link to. It is
sugar, not a prerequisite, and every open question in §11 applies only to it.

### Alongside — `ccquota board` (self-hosted, internal)

Unchanged and independent: operator-minted tokens, a wall of colleagues,
`/u/<handle>`, and badges from the same renderer. No GitHub dependency, so it
works air-gapped.

```
  a person's hub
  ──────────────
  holds the totals
       │
       ├── ccquota badge ──► an SVG file ──► committed / gisted / served locally
       │                                     (no service anywhere)
       │
       └── POST /v1/submit ──► board (internal, token)  or  badges (public, OAuth)
                                    │                            │
                              wall + /u/ + badge            /u/ + badge
```

### 4.1 Shared code

| package | used by | responsibility |
|---|---|---|
| `internal/badge` | `badge`, `board`, `badges` | SVG + shields JSON rendering, self-contained |
| `internal/submit` | `board`, `badges` | the `Entry` payload type and its validation |
| `internal/board` | `board` | token auth, wall |
| `internal/badges` | `badges` | GitHub OAuth, per-person page |

## 5. Submission contract

```jsonc
{
  "tokens":       69845943231,
  "turns":        267607,
  "period":       "all",            // all | 30d | 7d
  "model_mix":    [ {"model":"claude-opus-5","tokens":54000000000} ],
  "generated_at": "2026-09-01T21:00:00Z",
  "agent_version":"c5eaeff"
}
```

**The handle is never in the body.** It comes from the authenticated token —
GitHub-derived on `badges`, operator-assigned on `board`. A payload that can
name its own row is a payload that can overwrite someone else's.

## 6. What a submission may never contain

The exclusion list `/share` already enforces, applied at the submission boundary:

| may appear | never appears |
|---|---|
| tokens, turns, period | project paths (client names) |
| model mix | machine names, OS logins |
| handle (from the token) | session ids, git branches |
| | account emails or uuids |
| | utilization percentages |

`Entry` is defined from scratch, not derived from `model.UsageEvent` or
`ShareView`. Redacting a rich struct loses over time: each field added later is
exposed by default, and the destination here is **permanent and public**, not a
link someone chose to hand over. A field appears only by being written into
`Entry` on purpose.

Utilization is excluded deliberately: it is a percentage of a plan-dependent
allowance, so publishing it leaks plan tier by inference while telling a reader
nothing useful about the person.

## 7. The badge

**The constraint that shapes it:** an SVG loaded through `<img>` — what a README,
a profile page and a Pages site all do — is a sandboxed context. No scripts, no
external fonts, no external CSS, no network. Everything inline. GitHub proxies
through camo, which strips cookies, so the URL must be publicly readable with no
auth and must tolerate aggressive caching.

```
GET /badge/<handle>.svg?theme=dark|light&period=all|30d
Cache-Control: public, max-age=300
```

- Fonts: a system stack, never a webfont — a webfont simply will not load here.
- Themes: an explicit `?theme=`. `prefers-color-scheme` inside an SVG-as-image is
  inconsistently supported and camo caches one copy for everyone, so README
  authors use the documented `<picture>` pattern with two URLs.
- Staleness: camo caches, so a badge is **not live**. It carries a period label,
  never a timestamp that will be wrong on someone's profile for a week.

## 8. Pages

- **`/u/<handle>`** (both roles): one person. Totals, model mix, trend, and a
  plain statement that figures are self-reported. This is the "show off" page
  and the badge's link target.
- **`/`** (board only): the wall. Sorted by **most recently active**, never by
  tokens, and with no rank numbers — a page sorted by tokens is a ranking
  whatever it is called. `badges` has no such page by construction.

## 9. Failure modes

| failure | behaviour |
|---|---|
| service unreachable from a hub | submission dropped, retried next tick. Nothing is queued: an aggregate is a snapshot and a stale one has no value |
| submit-token revoked | 401; the hub logs and stops until reconfigured |
| a handle stops submitting | the row keeps its last figure with an explicit "last updated"; never zeroed, which would read as "spent nothing" |
| unknown handle on a badge | 404 with a generic SVG, never a zeroed badge |
| no entries yet | the page says so rather than rendering an empty leaderboard |

## 10. Testing

| area | test |
|---|---|
| payload | a submission carrying project paths / machine names / emails is rejected, asserted against a seeded fixture — the `/share` pattern, with a control that a legitimate submission still succeeds |
| handle | a body claiming a different handle cannot overwrite another row |
| badge | contains no external reference at all — no `@import`, no `href` to a font or image; a known input renders a stable SVG |
| local badge | `ccquota badge` produces a valid SVG with no network access at all, asserted by running it against a store with no hub configured |
| shields JSON | matches the documented endpoint schema |
| badge caching | cache headers present and bounded |
| wall ordering | sorted by recency; a control asserts a high-token stale row does not float to the top |
| role separation | `badges` exposes no wall route; `board` requires no GitHub configuration to start |

## 11. Open questions

1. **Where does the public instance run, and who pays?** Hosting, display-name
   moderation and uptime are an ongoing commitment distinct from shipping code.
2. **Anthropic's terms** on publishing usage figures — worth checking before
   promoting a public instance rather than assuming.
3. **Retention and deletion.** How long a row survives after submissions stop,
   and self-service deletion (it should exist).
4. **GitHub avatars.** Hotlinking `avatars.githubusercontent.com` on the public
   page is convenient but sends a viewer's IP to GitHub; caching them locally
   avoids that at the cost of storage.
