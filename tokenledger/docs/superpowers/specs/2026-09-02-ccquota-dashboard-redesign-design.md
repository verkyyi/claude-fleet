# ccquota hub dashboard redesign — design

Date: 2026-09-02. Status: approved in brainstorming (layout A, time control T3,
Review view as proposed); awaiting spec review.

## 1. Why

The internal hub dashboard (`web/dist/index.html`, served at `/` on the mini)
was built one card at a time and never revisited as a whole. Measured against
the live hub on 2026-09-02:

- **Wrong scope after two quick changes.** Selecting one subscription and then
  "All" within 300 ms left the select and banner saying "All" while every card
  showed single-subscription data. The eleven requests a change fires are never
  cancelled or sequenced, and the 60-second auto-refresh races the user's clicks
  the same way.
- **No loading state.** A change silently keeps the old numbers until all
  requests land; at 90 days the history request alone takes 3.2 s.
- **Scope is applied unevenly.** "Right now", "What each machine is running" and
  "Subscription switches" ignore the subscription filter.
- **Nothing is in the URL.** Reload resets to All/7d; nothing is shareable.
- **Only two filters exist** (subscription, four fixed ranges), the header is not
  sticky on a ~4500 px page, and clicking a bar does nothing.
- **A stray `null` text node** renders between two cards (a card that returns
  `null` is passed straight to `replaceChildren`).
- **Most of the data goes unshown.** The store holds token composition (97 % of
  all tokens are cache reads), effort, entrypoint, sidechain, thinking tokens,
  branch, 12 k limit snapshots (utilization history), and 25 k sessions with
  start/end times. The page shows a truncated session UUID and one "by model"
  bar.

The operator's own words: the filter mechanism is hard to understand; redesign
the filtering and the layout, and use the data that is already collected.

## 2. Goals and non-goals

Goals:

1. One scope model that every card obeys, visible in one place, encoded in the
   URL, and free of the race.
2. Two top-level views with different rhythms: **Now** (seconds, "am I about to
   hit the wall, what is running") and **Review** (a selected period, "where did
   it go, how efficiently, what stands out").
3. Drill-down by clicking, on seven dimensions, with the current drill-down
   always visible as chips.
4. Surface the collected-but-unshown data as concrete cards, plus a small set of
   machine-generated findings.
5. Every Review request answers in well under a second at 90 days, on the mini.

Non-goals (unchanged by this work):

- `/u/<login>`, `/share`, `/badge/*`, `/embed/*`, the public-badge design, the
  MCP server's existing tools, the agent, ingest, identity, limits polling.
- Any hosted or public instance.
- Adding prices for unpriced models (`claude-fable-5-1` is missing from the
  pricing table today; the dashboard will *say so*, fixing it is a separate
  one-line change because stored `cost_usd` is not recomputed).
- A frontend build pipeline. The dashboard stays hand-written files embedded by
  `go build`.

## 3. Information architecture

```
┌ sticky ──────────────────────────────────────────────────────────────┐
│ ccquota   [Now] [Review]        [All 3 subscriptions ▾] [7d|30d|90d] │
│ filters: [machine: macbook ×] [model: claude-opus-5 ×] [clear]       │
└──────────────────────────────────────────────────────────────────────┘
  Now                                  Review
  ─ alerts                             ─ 1 timeline + brush
  ─ hero odometer                      ─ 2 KPI strip (with deltas)
  ─ wall gauges per subscription       ─ 3 findings
  ─ right now (live sessions)          ─ 4 two breakdowns (group-by each)
  ─ ▸ fleet (collapsed)                ─ 5 efficiency      6 model mix over time
                                       ─ 7 when (heatmap)  8 wall history
                                       ─ 9 sessions table → session detail
```

Routing is hash-based so the Go server needs no route changes and the existing
path routes (`/u/`, `/share`) are untouched:

- `#/now?…` and `#/review?…`. An empty hash means `#/now`.
- `#/review/session/<id>?…` opens the session detail over Review.

### 3.1 URL state (the single source of truth)

| param | values | meaning |
|---|---|---|
| `sub` | `all` or an account uuid | subscription scope. Default `all` when >1 account, else the one account |
| `span` | `7d` `30d` `90d` | the timeline's extent, ending now. Default `30d` |
| `from`, `to` | RFC3339 UTC | the brush selection inside the span. Both absent ⇒ the default selection: the last 7 days of the span (the whole span when `span=7d`). `from` present and `to` absent ⇒ the right edge is "now" and moves with time (this is how a selection that touches the right edge is encoded, including the whole span, which is `from` = span start). Both present ⇒ a fixed window |
| `machine` | endpoint id | drill-down chip |
| `login` | os_user | drill-down chip |
| `project` | cwd (full path, URL-encoded) | drill-down chip |
| `model` | model id | drill-down chip |
| `branch` | git_branch | drill-down chip |
| `team` | team | drill-down chip |
| `session` | session id | drill-down chip |
| `g1`, `g2` | a dimension name | the two breakdown cards' group-by. Default `project`, `model` |
| `sort` | `tokens` `cost` `started` `duration` `turns` | sessions table sort. Default `tokens` |

The compare period is not a parameter: it is always the period of the same
length immediately before `from`. Theme and per-card "show as table" live in
`localStorage`, not the URL.

`state.js` owns the codec: `parse(hash) → State` and `format(State) → hash`,
pure functions, round-trip tested. Every control writes to the URL
(`history.pushState` for view/brush/chip changes, `replaceState` for sort and
group-by) and the app re-renders from `hashchange`. There is no second copy of
the state.

### 3.2 Scope bar

- Sticky at the top on every viewport. Row 1: view tabs · subscription select ·
  span segmented control. Row 2 (only when chips exist): chips + "clear".
- On ≤ 720 px row 1 wraps, chips scroll horizontally, and the tabs stay in
  view.
- A 2 px progress bar under the scope bar is visible while any request for the
  current state is in flight; `main` gets `aria-busy="true"` and cards dim to
  60 % opacity. Old data stays visible under the dimming. There is no spinner
  that replaces content.

### 3.3 Drill-down contract

- Dimensions: **machine, login, project, model, branch, team, session**.
- Clicking a row in any breakdown adds the chip for that dimension; clicking a
  live session row adds its `session` chip; in the sessions table the project
  and login cells add their chips while the rest of the row opens the session
  detail (§5.9). One value per dimension: clicking another value of the same
  dimension replaces it. Clicking the chip's × removes it.
- Chips are ANDed. Every request on both views carries every chip, with one
  exception: a breakdown card grouped by dimension X omits the X chip from its
  own request (faceted-search convention) and highlights the selected row, so
  the user can switch values without clearing.
- Subscription is scope, not a chip: it has its own control and applies to
  everything, including limits.
- Now honours chips for live sessions (filtered client-side on endpoint /
  os_user / cwd / model / session). Wall gauges are per subscription and ignore
  chips; the card says so in its hint when chips are present.
- Findings honour chips: the runaway session, cache-hit and spend rules run on
  the filtered set. Fleet-level findings (stale agent) do not.

### 3.4 Requests and the race

`loader.js`:

```
seq += 1; const mine = seq;
controller?.abort(); controller = new AbortController();
const results = await Promise.allSettled(requests.map(r => fetch(r, {signal})));
if (mine !== seq) return;            // a newer state superseded this load
render(results);
```

- Every response is applied only if its `seq` is still current; superseded
  responses are dropped even if they arrive after the newer ones.
- A failed request renders that card's error state ("Query failed: …") and
  leaves the other cards alone. One failure no longer blanks the page.
- Refresh cadence: Now re-subscribes to `/v1/live/stream` (unchanged) and
  reloads its stored cards every 60 s; Review reloads only on state change,
  and every 5 minutes when `to` is "now" (the brush touches the right edge).
  A timed reload uses the same `seq` mechanism, so it can never overwrite a
  newer user-initiated load.

## 4. Now view

Top to bottom:

1. **Alerts** — the Now findings (§7.2), rendered as a compact list with the
   severity dot; hidden when empty.
2. **Hero odometer** — unchanged (`counter.go`, `tokenman`).
3. **Am I about to hit the wall?** — unchanged logic (`wallCard`, incl. the
   estimated endpoint shares of the 5-hour window). Subscription-scoped.
4. **Right now** — the live tiles minus the two stored tiles (`tokens (range)`
   and `spend (range)` move to Review's KPI strip). Live rows are filtered by
   chips; each row is clickable (adds `session` chip and, on the row's project
   name, `project`).
5. **Fleet** — a `<details>` (closed by default, state remembered in
   `localStorage`) holding the three existing tables unchanged: endpoint
   roster, what each machine is running, subscription switches. All three are
   subscription-scoped now: the two list endpoints gain an `account` parameter.

## 5. Review view

All numbers in Review are for the brush selection `[from, to)`, under the
subscription scope and chips. "prev" means the equal-length period ending at
`from`.

### 5.1 Timeline + brush

- Bars of tokens per bucket across the whole `span`, stacked by model (top 6
  models by tokens in the span, the rest folded into "other"). Bucket size by
  span: 7d → 1 h (168 bars), 30d → 6 h (120 bars), 90d → 1 day (90 bars).
- The brush is a draggable window over the bars (pointer events, works with
  touch); its edges snap to bucket boundaries. Dragging the body moves it;
  dragging an edge resizes it; double-click selects the whole span. The caption
  under it reads `selected 08-26 → 09-02 (7d) · compared with the 7d before`.
- Changing the span keeps the selection if it still fits, else resets to the
  default selection.
- Brush changes are debounced 250 ms before they load; the caption updates
  immediately.
- Data: `GET /v1/history?granularity=<hour|6h|day>&stack=model&since=<span
  start>&until=now` + scope + chips.

### 5.2 KPI strip

Seven tiles, each with the value for the selection and a delta against prev
(`+12 %`, coloured red for more spend / green for less, neutral for ratios):

| tile | formula |
|---|---|
| tokens | Σ(input + output + cache_create_5m + cache_create_1h + cache_read) |
| spend | Σ cost_usd (notional); a ⚠ when `unpriced_events > 0` |
| turns | Σ events |
| sessions | COUNT DISTINCT session_id |
| cache hit | cache_read / (cache_read + input + cache_create_5m + cache_create_1h) |
| $ per 1M output | cost_usd / output × 10⁶ |
| subagent share | sidechain_tokens / tokens |

Data: `GET /v1/summary?…&compare=1`.

### 5.3 Findings

The list from `GET /v1/findings` (§7), max 8, severity first. Each finding is
one sentence plus an action link that applies the finding's scope (e.g. adds
the `session` chip and scrolls to the sessions table, or opens the session
detail). Empty state: "Nothing unusual in this period."

### 5.4 Two breakdowns

Two identical cards side by side (stacked on mobile). Each has a segmented
group-by control — `project · login · machine · model · branch · team` — stored
in `g1` / `g2`. Rows: label, bar, `tokens · $`, and a small `vs prev` delta.
The request asks for 50 rows; the card renders 12 and a "show all 50" link
reveals the rest without a new request. Rows are clickable (chip). The row matching
the card's own dimension chip is highlighted. Team only appears in the control
when any endpoint has a team.

Data: two `GET /v1/usage?by=<g>&compare=1` requests (compare adds
`prev_tokens` / `prev_cost_usd` per bucket).

### 5.5 Efficiency

- A single stacked bar of token composition: cache read · cache create ·
  output · input · thinking, with percentages in the legend and absolute counts
  on hover.
- Three small distributions from `/v1/summary`: effort (`xhigh` / `high` /
  unset → "default"), entrypoint (`cli` / `sdk-cli`), turns in subagents vs
  main thread.
- `$ per 1M output` by model (from the breakdown by model) so the most
  expensive context is visible.

### 5.6 Model mix over time

Stacked area of tokens per bucket by model over the **selection** (same bucket
rule as the timeline, from the same `/v1/history` response filtered to the
selection). Legend lists models in fixed palette order.

### 5.7 When — hour × weekday heatmap

7 rows × 24 columns of tokens, in the browser's local time zone, folded
client-side from `GET /v1/history?granularity=hour` over the selection.
Sequential single-hue scale; hover shows tokens and turns. Under it one
generated sentence: the busiest window and the quietest 4-hour window ("quiet
02:00–06:00 local"). Selections shorter than 48 hours show a bar per hour
instead of a grid.

### 5.8 Wall history

One line per subscription of the 5-hour utilization over the selection, red
segments where ≥ 90 %, with the 7-day utilization as a fainter second line.
Under the chart per subscription: "3 critical episodes · 9 h 40 m in critical
(prev 2 h 10 m)". Data: `GET /v1/limits/history`. Limit snapshots exist from
2026-09-01; earlier selections show the card's empty state with that date.

### 5.9 Sessions

A sortable table: started · project · login@machine · model · duration · turns
· tokens · $ · cache hit · subagent %. Default sort tokens desc, 50 rows, "load
more". Clicking a row opens the session detail (§6). Clicking the project or
login cell adds that chip instead. On ≤ 720 px the table becomes stacked
cards. Data: `GET /v1/sessions`.

### 5.10 Tables

Each chart card keeps an accessible table view behind a small ⊞ toggle in its
corner (replacing the global "Tables" button). The toggle state is remembered
per card in `localStorage`.

## 6. Session detail

`#/review/session/<id>`: an overlay panel over Review (Esc / × closes, URL goes
back). Header: project, login@machine, subscription, primary model, started,
duration, turns, tokens, cost, cache hit, subagent share. Body: a bar per turn
(tokens, coloured by model; sidechain turns hatched) with hover details, and a
compact turn table (time, model, effort, input, output, cache read, cache
create, thinking, $). Data: `GET /v1/sessions/<id>`. If the raw turns were
pruned (retention), the header still renders from the rollup and the body says
"turns older than the retention window are gone".

## 7. Findings engine

`internal/findings`. Input: the resolved scope (account, filter, `[from,to)`),
its prev period, and the store. Output: `[]Finding{Severity, Kind, Title,
Detail, Scope map[string]string, Link string}`. Severity ∈ `critical`,
`warning`, `info`. Sorted by severity then magnitude; capped at 8. Every rule is
a pure function of query results, with a positive and a negative fixture and a
mutation check (the fixture that must fire is re-run with the triggering value
removed, and must then not fire).

### 7.1 Review findings

| kind | fires when | severity |
|---|---|---|
| `runaway_session` | a session in the selection has tokens ≥ max(20 × median session tokens in the selection, 100 M). Median over sessions with ≥ 2 turns | critical |
| `unpriced_model` | any model has `unpriced_events > 0` in the selection | warning |
| `time_in_critical` | a subscription's 5-hour utilization was ≥ 90 % for > 0 s in the selection; **critical** when > 10 % of the selection | warning / critical |
| `cache_hit_drop` | a project with ≥ 200 turns in both periods whose cache-hit ratio fell ≥ 5 points vs prev | info |
| `spend_spike` | tokens in the selection ≥ 1.5 × prev and ≥ 1 B; reported once globally and once for the top contributing project if that project alone is ≥ 1.5 × its own prev | info |

Wording is fixed per kind (templates in Go, covered by the fixtures), e.g.
"session c008ca75 burned 1.03 B tokens — 28× the median session (…/scratch-28,
claude-opus-5, 6 h 12 m)".

### 7.2 Now findings (alerts)

| kind | fires when | severity |
|---|---|---|
| `window_high` | any subscription's 5-hour utilization ≥ 75 % (critical at ≥ 90 %) | warning / critical |
| `stale_agent` | an enrolled endpoint's `last_seen` is > 1 h ago (or null) | warning |
| `live_runaway` | a live session has > 200 M tokens in flight | warning |

Served by `GET /v1/findings?view=now`.

## 8. Backend

### 8.1 Hourly rollup

New table, maintained in the same transaction as `InsertEvents`:

```sql
CREATE TABLE IF NOT EXISTS usage_hourly (
  hour          TEXT NOT NULL,   -- 'YYYY-MM-DDTHH:00:00Z'
  account_uuid  TEXT NOT NULL,
  endpoint_id   TEXT NOT NULL,
  session_id    TEXT NOT NULL DEFAULT '',
  os_user       TEXT NOT NULL DEFAULT '',
  cwd           TEXT NOT NULL DEFAULT '',
  model         TEXT NOT NULL DEFAULT '',
  git_branch    TEXT NOT NULL DEFAULT '',
  effort        TEXT NOT NULL DEFAULT '',
  entrypoint    TEXT NOT NULL DEFAULT '',
  is_sidechain  INTEGER NOT NULL DEFAULT 0,
  events                 INTEGER NOT NULL DEFAULT 0,
  input_tokens           INTEGER NOT NULL DEFAULT 0,
  output_tokens          INTEGER NOT NULL DEFAULT 0,
  cache_create_5m_tokens INTEGER NOT NULL DEFAULT 0,
  cache_create_1h_tokens INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens      INTEGER NOT NULL DEFAULT 0,
  thinking_tokens        INTEGER NOT NULL DEFAULT 0,
  cost_usd               REAL    NOT NULL DEFAULT 0,
  unpriced_events        INTEGER NOT NULL DEFAULT 0,
  min_ts                 TEXT NOT NULL,
  max_ts                 TEXT NOT NULL,
  PRIMARY KEY (hour, account_uuid, endpoint_id, session_id, os_user, cwd,
               model, git_branch, effort, entrypoint, is_sidechain)
);
CREATE INDEX IF NOT EXISTS idx_hourly_account_hour ON usage_hourly(account_uuid, hour);
CREATE INDEX IF NOT EXISTS idx_hourly_session ON usage_hourly(account_uuid, session_id);
```

- Each *inserted* (not deduped) event does one upsert: `ON CONFLICT DO UPDATE
  SET events = events + 1, … , min_ts = min(min_ts, excluded.min_ts), max_ts =
  max(max_ts, excluded.max_ts)`.
- `rollup_meta(version INTEGER)` holds the rollup schema version. On `Open`, if
  the table is empty while `usage_events` is not, or the version differs, the
  hub rebuilds it with one `INSERT … SELECT … GROUP BY` and logs the row count
  and duration. `ccquota hub --rebuild-rollup` forces it.
- `PruneEvents` leaves the rollup alone (its comment already promises this), so
  Review keeps working past the retention window; only per-turn detail is lost.
- **Measured** on a 292,753-event snapshot of the live hub: the rollup is
  **31,164 rows** with `session_id` in the key — a 9.4× reduction. The budget
  was every Review query < 300 ms at `span=90d`; warm, eight of the nine come
  in at **35–172 ms**, and `/v1/findings` does **not**: ~454 ms. That endpoint
  runs about nine store queries in series and the store holds a single SQLite
  connection, so they cannot overlap. It is accepted over budget rather than
  chased, because the cards load independently — the other eight paint while it
  works — and because closing the gap means restructuring the gatherer, which
  buys less than it costs. Narrower spans are cheaper (30 d ≈ 395 ms,
  7 d ≈ 244 ms; `view=now` is 5 ms).
- Equivalence is enforced by a property test: for random filters and ranges on
  a seeded store, every aggregate from the rollup equals the same aggregate
  computed directly from `usage_events`.

### 8.2 Filter

```go
type Filter struct {
    Account  string    // uuid or AllAccounts; "" is refused as today
    Start, End time.Time
    Endpoint, OSUser, CWD, Model, Branch, Team, Session string // "" = no constraint
}
```

`filter.where(alias)` builds the clause from a whitelist of columns; team is
`endpoint_id IN (SELECT endpoint_id FROM endpoints WHERE team = ?)`. Every store
query in this design takes a `Filter`; the existing `UsageBy` / `History` gain
`Filter`-taking variants and the old signatures delegate to them, so `/u/`,
`/share`, badges and MCP are untouched.

### 8.3 Endpoints (all `viewerOnly`)

Common query parameters on every endpoint below: `account` (uuid | `all`),
`since`, `until` (RFC3339 or `7d`-style, as today), and the chips
`endpoint`, `user`, `project`, `model`, `branch`, `team`, `session`. Unknown
parameters are ignored; a malformed time is a 400 with `{"error": …}`.

| endpoint | change |
|---|---|
| `GET /v1/usage` | + chips; `by` gains `effort`, `entrypoint`; `compare=1` adds `prev_tokens`, `prev_cost_usd`, `prev_events` per bucket (prev period, same keys) |
| `GET /v1/history` | + chips; `granularity` gains `6h`; `stack=model` adds `stack: [{key, tokens}]` per bucket (top 6 + `other`); existing `by_model` kept |
| `GET /v1/summary` | new. `{events, tokens, sessions, cost_usd, unpriced_events, input_tokens, output_tokens, cache_read_tokens, cache_create_tokens, thinking_tokens, sidechain_tokens, sidechain_events, effort: [{key, events, tokens}], entrypoint: [{key, events, tokens}], prev: {…same scalar fields}}` (`prev` only with `compare=1`) |
| `GET /v1/limits/history` | new. `points` (default 400). `{accounts: [{account_uuid, label, points: [{t, five_hour_pct, seven_day_pct}], critical_seconds, critical_episodes, prev_critical_seconds}]}`. Downsampled per account by bucketing time into `points` slots and keeping the **max** per slot (peaks survive). Critical time is summed over gaps between consecutive ≥ 90 % snapshots, each gap capped at 10 min so a polling outage is not counted as critical |
| `GET /v1/sessions` | new. `sort`, `limit` (default 50, max 500), `offset`. `[{session_id, account_uuid, endpoint_id, endpoint, os_user, cwd, model, models, started, ended, turns, tokens, cost_usd, unpriced_events, output_tokens, cache_hit, sidechain_tokens, sidechain_share}]`. `model` is the model with the most tokens; `models` lists all |
| `GET /v1/sessions/{id}` | new. `{session: {…as above}, turns: [{ts, model, effort, input_tokens, output_tokens, cache_read_tokens, cache_create_tokens, thinking_tokens, cost_usd, is_sidechain}], pruned: bool}` |
| `GET /v1/findings` | new. `view=review` (default) or `now`. `[{severity, kind, title, detail, scope: {…chip params}, link}]` |
| `GET /v1/live` and the stream | each session gains `os_user` (from `endpoints`) so chips can filter it |
| `GET /v1/account-switches`, `GET /v1/endpoint-accounts` | + `account` scope |

Bucket keys for `history` stay the existing `strftime` strings; `6h` buckets
use `YYYY-MM-DDTHH` of the bucket start (00, 06, 12, 18).

### 8.4 MCP

Four thin tools over the same store calls, same parameter names as the HTTP
API: `usage_summary`, `list_sessions`, `get_session`, `get_findings`. Findings
are the "insight" surface an agent can ask for.

### 8.5 Static assets

`serveUI` keeps serving `web/dist` via `http.ServeContent` (MIME by extension
already works for `.js` / `.css`) and adds `Cache-Control: no-cache` so a
redeploy is seen on the next reload.

## 9. Frontend

Files under `web/dist`, ES modules, no bundler:

| file | responsibility |
|---|---|
| `index.html` | shell: scope bar, `#now`, `#review`, `#detail`, tooltip; loads `app.js` as a module |
| `styles.css` | the existing palette and tokens, plus scope bar, chips, brush, heatmap, KPI, overlay |
| `app.js` | boot, router (`hashchange`), `loader` (seq/abort), view switching |
| `lib/state.js` | URL ⇄ state codec; chip and scope → query-string mapping (pure) |
| `lib/brush.js` | bucket math, snapping, default selection, span change rules (pure) |
| `lib/fold.js` | hourly series → local dow×hour grid; quiet/busy window sentences (pure) |
| `lib/format.js` | `fmtInt`, `fmtUSD`, `shortProject`, `relTime`, `ago`, deltas (pure) |
| `lib/dom.js` | `el`, tooltip, `escapeHTML` |
| `charts.js` | rankedBars, stackedBars (timeline), stackedArea, heatmap, lines, kpi tile, composition bar, table view |
| `scope.js` | scope bar, chips, brush wiring |
| `now.js` | Now view (ported cards) |
| `review.js` | Review view |
| `session.js` | session detail overlay |
| `user.html`, `share.html` | untouched |

Pure modules under `lib/` have no DOM access and are tested with Node's
built-in runner (`node --test web/test`), which needs no packages. CI gains a
job that runs it.

Rendering rules carried over from the current page: fixed palette order, ≥ 2
series never rely on colour alone (legend), the tilde on projected numbers, no
number on every bar, honest empty states, cost always labelled notional.

Accessibility: every chart card has the table toggle; the brush is keyboard
operable (arrow keys move the selection by one bucket, shift+arrow resizes);
`aria-busy` during loads; the scope bar controls are real `<select>` /
`<button>` elements.

## 10. Testing

Go (`go test -race ./...` as today):

- `store`: rollup upsert vs direct aggregation (property test over random
  filters/ranges); backfill produces identical rows to incremental upserts;
  `Filter` whitelist refuses unknown columns; `Sessions` aggregation (start /
  end / primary model / cache hit); `LimitsHistory` downsampling keeps peaks
  and caps gaps.
- `api`: each new or changed handler against an in-memory seeded store,
  including chip parameters, `compare=1`, malformed times → 400.
- `findings`: per rule a positive fixture, a negative fixture, the mutation
  check, and the template text.
- `mcp`: the four new tools list and call.

Node (`node --test web/test`): `state` round-trip and defaults; chip → query
mapping including the self-exclusion rule; `brush` snapping, default selection,
span change; `fold` local-time folding across a DST boundary and the
busy/quiet sentences; `loader` sequencing (a slow older response is dropped,
an aborted request is not rendered as an error).

Manual, against a local hub on a copy of the mini DB, before deploy:

1. Today's race: switch subscription then back within 300 ms → final page
   matches the select (no "Showing all" banner over single-account cards).
2. Reload restores view, scope, brush, chips, group-bys; back/forward walk
   through them.
3. Drill down machine → project → session detail and back; the chips row and
   every card agree.
4. 90-day span: every Review request < 300 ms in the network panel, except
   `/v1/findings` at ~454 ms (see §8.1 — measured and accepted).
5. Phone width (390 px): scope bar reachable while scrolled; brush works by
   touch; sessions render as cards.
6. Both themes; no `null` text anywhere.

## 11. Rollout

Deploy to the mini as documented in the 2026-09-02 handoff (build arm64, copy
to both binary paths, `codesign`, re-allow in the application firewall,
`bootout` + `bootstrap`). First start backfills the rollup and logs it; the
dashboard is available throughout (the old UI is replaced atomically with the
binary). Rollback is the previous binary; `usage_hourly` and `rollup_meta` are
additive and ignored by it.

## 12. Sequencing

1. **Backend foundation** — rollup + backfill + `Filter`; `summary`,
   `sessions`, `sessions/{id}`, `limits/history` endpoints; chips on `usage` /
   `history`; tests. Deployable on its own (no UI change).
2. **Shell** — module split, router and URL state, loader with sequencing,
   scope bar with chips, Now view ported, Fleet collapsed, the `null` fix.
   Deployable: same information as today, race fixed.
3. **Review** — timeline + brush, KPI strip, breakdowns, efficiency, model mix,
   heatmap, wall history, sessions + detail.
4. **Findings** — engine, `/v1/findings`, Review card, Now alerts, MCP tools,
   README update, deploy.

Each step is one PR-sized unit with its own tests; the implementation plan
follows this order.

## 13. Open questions

Both open measurements are now closed, in §8.1: the rollup is 31,164 rows on
the live hub's data, and every Review request at `span=90d` is inside the
300 ms budget except `/v1/findings` at ~454 ms, which is accepted over budget
for the reasons given there.

One thing the measurement changed rather than merely recorded: it exposed that
`runaway_session` — the engine's only `critical` rule — could never fire,
because the gatherer handed `runaway()` the top 500 sessions and the rule takes
its median from whatever slice it is given. On real data that median was 1,025×
the population's (93,951,176 vs 91,684), pushing the threshold to 1.88 B tokens
against a largest-ever session of 1.24 B. §7's threshold now reads against a
median computed in SQL over the whole population. The lesson is the one this
project keeps re-learning: a rule that samples its own baseline is not a rule,
and only real data shows it.
