# ccquota badges & boards — design

**Date:** 2026-09-01
**Status:** proposed design, pre-implementation — **no code written**
**Approach:** a local `ccquota badge` command, three small additions to the hub
that already exists, and exactly one genuinely new service (`ccquota badges`,
public, GitHub OAuth)

---

## 1. Problem

ccquota tells one operator what their fleet spent. Three things it cannot do:

1. **Show a figure durably.** `/share` is a revocable link to a redacted page —
   right for handing a number to one person, wrong for a badge that sits in a
   README for a year.
2. **Allocate cost inside a company.** A team wants to know which repo, which
   machine and which engineer the spend went to.
3. **Let an individual show what they have spent**, on a profile that is not
   ccquota's.

## 2. What already exists

An earlier draft of this design proposed `ccquota board` as a new self-hosted
service for internal cost allocation. **That service is already built**: it is
the hub. A company self-hosts one hub, every engineer's agent enrols against it,
and the dashboard already aggregates the four dimensions an internal board is
for. Measured on a live two-machine, five-login deployment:

| the internal-board question | already answered by |
|---|---|
| which person costs what | `by=user` |
| which repo costs what | `by=project` |
| which machine costs what | `by=endpoint` |
| which subscription | `by=account` |
| in notional dollars | every dimension carries `cost_usd` |

So the internal case needs **three additions to the hub**, not a new service:

1. a **team** dimension (the one grouping that does not exist),
2. a **`/u/<person>`** page,
3. **badge** routes, from the shared renderer.

That leaves three surfaces:

| | `ccquota badge` | the hub (existing) | `ccquota badges` |
|---|---|---|---|
| what | a local command | what a company already runs | one public instance |
| network | **none** | inside a company | public |
| auth | n/a | viewer token (existing) | GitHub OAuth |
| data | local totals | **rich** — projects, people, machines, cost | **minimal** (§5.1) |
| new code | small | small (three additions) | the only new service |

The remaining separation is still load-bearing, for a reason an earlier draft
missed: the threat models are **inverted**. A public destination must never
carry project paths — they are client names. The hub's dashboard shows them in
full, correctly, because it is behind a viewer token inside a company.

## 3. Non-goals

- **A global public leaderboard.** Token count measures spend, not output: a
  loop replaying a large cached context out-ranks every real engineer, cheaply,
  and quota is a shared rate-limited resource. Making the public surface
  per-person removes the ranking entirely rather than policing it with rules.
- **Verification of submitted figures.** ccquota reads local transcripts and
  nothing signs them. GitHub makes a *handle* unforgeable; it does not make a
  *number* true. Every surface must say so rather than imply an audit.
- **Treating tokens as productivity.** Stated as a non-goal because it is the
  way an internal board actually fails. Not by cheating — inside a team that is
  socially checked — but by Goodhart: read as a performance ranking, it makes
  people avoid the tool or pad their usage, and either destroys the cost data it
  exists to provide. §6 is designed against this.

## 4. Architecture

**A hosted service is not required for the headline use case.** Measured:

| URL | content-type | usable as a README image |
|---|---|---|
| `raw.githubusercontent.com/<u>/<u>/main/x.svg` | `image/svg+xml` | yes |
| `gist.githubusercontent.com/.../raw` | `text/plain` | no — fine as data, not the image |
| `img.shields.io/...` | `image/svg+xml` | yes, from a URL you supply |

### Layer 1 — `ccquota badge` (local, no network)

```
ccquota badge --out ccquota.svg --theme dark --period all
ccquota badge --json --out ccquota.json      # shields.io endpoint schema
```

Renders from the local hub's totals. No server, no account, no submission. Every
other layer publishes what this produces, so building it first makes the feature
useful before any service exists.

### Layer 2 — publishing (all serverless)

| target | how | trade-off |
|---|---|---|
| own profile repo | commit the SVG; relative path or `raw.githubusercontent.com` | you own everything; needs a scheduled commit |
| gist + shields.io | write the JSON to a gist; point shields at it | no repo churn; depends on shields.io |
| own hub | serve it from a hub already publicly reachable | nothing new to run; most hubs are not public |

### Layer 3 — the hub, extended (internal) and one new public service

```
  the hub a company already runs
  ──────────────────────────────
  by user / project / endpoint / account, with cost   ◄── exists today
       + team dimension, /u/<person>, badge routes    ◄── the three additions
       │
       ├── ccquota badge ──► SVG file ──► committed / gisted / served locally
       │
       └── POST /v1/submit ──► badges (public, OAuth, MINIMAL payload only)
```

### 4.1 Packages

| package | used by | responsibility |
|---|---|---|
| `internal/badge` | hub, badges, `ccquota badge` | SVG + shields JSON rendering, self-contained |
| `internal/submit` | badges | the public payload type and its validation |
| `internal/badges` | badges | GitHub OAuth, per-person page |

No `internal/board` package: the hub's existing store and query layer already
does that work.

## 5. Payload

Only ONE payload type is needed now, because the internal case never submits
anywhere — it reads the hub's own database directly. That removes a whole
protocol, its validation, and the risk of an internal payload reaching a public
service.

What survives from the earlier draft is the reasoning: the public payload is
defined **from scratch**, not derived from the hub's internal model. Redacting a
rich struct loses over time — each field added later is exposed by default, and
the destination is permanent and public.

### 5.1 `submit.PublicEntry` — for `badges`

```jsonc
{
  "tokens": 69845943231, "turns": 267607, "period": "all",
  "model_mix": [ {"model":"claude-opus-5","tokens":54000000000} ],
  "generated_at": "2026-09-01T21:00:00Z", "agent_version": "c5eaeff"
}
```

The handle comes from the authenticated token, **never from the body** — a
payload that can name its own row can overwrite someone else's.

Never present: project paths, machine names, OS logins, session ids, git
branches, account emails or uuids, utilization. Utilization is excluded because
it is a percentage of a plan-dependent allowance, so publishing it leaks plan
tier by inference while telling a reader nothing about the person.

### 5.2 The internal dimensions — no payload at all

Projects, people, endpoints and notional cost are already in the hub's store and
already on its dashboard. Nothing is submitted, so nothing needs a schema, a
transport, or a filter. The only new dimension is **team**.

## 6. The internal view (three additions to the hub)

**1. A team dimension.** The one grouping the hub lacks. Teams map from enrolled
endpoints, assigned by the operator in hub config — an endpoint cannot declare
its own team, for the same reason a submission cannot declare its own handle.
Implemented as another `store.Dimension`, so it inherits the existing query,
API and dashboard machinery.

**2. `/u/<person>`.** One page per OS login, linkable and badge-able.

**3. Badge routes**, from the shared renderer, so an internal repo README can
carry a badge served by the company's own hub.

**Framing.** When teams are configured, the landing view groups team → project →
person, with no rank numbers or podium. This is aimed at how an internal board
actually fails: not cheating, which a team socially checks, but Goodhart. Read
as a performance ranking it makes people avoid the tool or pad their usage, and
either destroys the cost data it exists to provide.

**Air-gapped by construction** — the hub already makes no outbound calls beyond
Anthropic's own endpoints.

## 7. The public badges service

`/u/<handle>` and `/badge/<handle>.svg`. **No wall route exists**, so there is no
global ranking surface to police. GitHub OAuth makes the handle unforgeable.

## 8. The badge

**The constraint that shapes it:** an SVG loaded through `<img>` — what a README,
a profile and a Pages site all do — is a sandboxed context. No scripts, no
external fonts, no external CSS, no network. Everything inline. GitHub proxies
through camo, which strips cookies, so the URL must be publicly readable and
tolerate aggressive caching.

```
GET /badge/<handle>.svg?theme=dark|light&period=all|30d
Cache-Control: public, max-age=300
```

- Fonts: a system stack. A webfont will not load here at all.
- Themes: an explicit `?theme=`. `prefers-color-scheme` inside an SVG-as-image is
  inconsistently supported and camo caches one copy for everyone, so README
  authors use the documented `<picture>` pattern with two URLs.
- Staleness: camo caches, so a badge is **not live**. It carries a period label,
  never a timestamp that will be wrong on a profile for a week.

## 9. Failure modes

| failure | behaviour |
|---|---|
| service unreachable | submission dropped, retried next tick. Nothing queued: an aggregate is a snapshot and a stale one has no value |
| token revoked | 401; the hub logs and stops until reconfigured |
| a row stops submitting | keeps its last figure with an explicit "last updated"; never zeroed, which would read as "spent nothing" |
| unknown handle on a badge | 404 with a generic SVG, never a zeroed badge |
| no entries yet | the page says so rather than rendering an empty board |
| internal payload sent to the public service | rejected by type, not by filter |

## 10. Testing

| area | test |
|---|---|
| type separation | the public endpoint rejects an `InternalEntry`; control — it accepts a valid `PublicEntry` |
| public payload | a submission carrying project paths / machine names / emails is rejected, against a seeded fixture (the `/share` pattern) |
| identity | a body claiming a different handle or team cannot overwrite another row |
| badge | no external reference at all — no `@import`, no `href` to a font or image; a known input renders a stable SVG |
| local badge | `ccquota badge` produces a valid SVG with no network access whatsoever |
| shields JSON | matches the documented endpoint schema |
| board framing | the default view is teams, not people; no rank numbers are rendered |
| role separation | `badges` exposes no wall route; `board` starts with no GitHub configuration |

## 11. Open questions

1. **Where does the public instance run, and who pays?** Hosting, display-name
   moderation and uptime are an ongoing commitment distinct from shipping code.
   Layer 1 ships without answering this.
2. **Anthropic's terms** on publishing usage figures — worth checking before
   promoting a public instance rather than assuming.
3. **Retention and deletion**, on both services; self-service deletion should
   exist.
4. **GitHub avatars** on the public page: hotlinking sends a viewer's IP to
   GitHub; caching locally costs storage.
5. **Does the internal board need auth for *viewing*?** Behind a firewall may be
   enough for some companies and not others; per-person cost data is sensitive
   in a way the public payload deliberately is not.

## 12. Sequencing

1. `internal/badge` + `ccquota badge` — useful alone, no service, nothing in §11
   blocks it.
2. The hub's three additions — team dimension, `/u/<person>`, badge routes. This
   completes the internal case, which has a concrete asking user.
3. `internal/submit` + `ccquota badges` — last, because §11.1 (who hosts and
   pays) and §11.2 (Anthropic's terms) must be answered before promoting a
   public instance.
