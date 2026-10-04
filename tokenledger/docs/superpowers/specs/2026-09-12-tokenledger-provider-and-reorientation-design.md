# TokenLedger: the provider dimension, and a hub that is not Claude-first — design

Date: 2026-09-12. Status: approved in brainstorming (P2′ layout; subproject A
before subproject B); awaiting spec review.

Supersedes nothing. Builds on `2026-09-02-ccquota-dashboard-redesign-design.md`
(the Now/Review split this document removes) and on PR #10 (the per-source cost
split this document extends rather than relaxes).

## 1. Why

The product was renamed TokenLedger in #7 and the cost model was split by source
in #10, but the hub still reads as a Claude-subscription monitor with two other
sources bolted on. Two separate defects, one structural and one arithmetic.

### 1.1 `source` is one column doing three jobs

|            | collector channel | billing relationship | vendor / model family |
|------------|-------------------|----------------------|-----------------------|
| `claude`   | CC transcript     | subscription (notional) | Anthropic — 1:1 |
| `codex`    | Codex log         | subscription (notional) | OpenAI — 1:1 |
| `gateway`  | external push     | per call (billed)    | **N vendors × N models — collapsed** |

The first two columns hold for all three rows. The third holds only for the
first two. Presenting `gateway` as a peer of `claude` and `codex` therefore puts
a black box beside two concrete products, and the dashboard's source tabs,
source chips and per-source KPI tiles all inherit that error.

Measured on the live hub (`ccquota.24haowan.com`, 90 days to 2026-09-13):

```
model                         events   tokens  unpriced   billed_usd
qwen-plus                         25    91305        16     0.003575
deepseek-v4-flash                 26    23701        26     0.000000
deepseek-chat                      2     3661         2     0.000000
qwen-flash                        18      772         8     0.000005
doubao-seed-2-0-mini-260428        5      337         5     0.000000
anthropic/claude-haiku-4.5         5      115         3     0.000094
qwen-vl-plus                       5      104         3     0.000006
qwen-vl-ocr                        4       88         2     0.000002
qwen3-max                          5       75         3     0.000013
text-embedding-v4                  5       10         3     0.000000
                                 100   120168        71     0.003695
```

`anthropic/claude-haiku-4.5` is the load-bearing row. It is a Claude model
billed per call through the gateway, while the same model family is also being
consumed under a subscription and reported as notional. **A model family is not
a billing relationship**, and the current top-level axis conflates them.

### 1.2 Gateway cost is priced on an under-specified key

`internal/pricing/gateway.go` prices a gateway event with:

```go
r, ok := g.rates[Normalize(e.Model)]   // key: model id alone
```

The gateway's own source of truth does not agree. `core/ai-gateway/catalog.json`
(in the `24haowan-monorepo`) keys every model by **vendor and model**:

```
dashscope/qwen-flash   dashscope/qwen3-max   dashscope/qwen-plus
dashscope/qwen-vl-plus dashscope/qwen-vl-ocr dashscope/text-embedding-v4
deepseek/deepseek-v4-flash            ark/doubao-seed-2-0-mini-260428
```

with four configured upstreams — `dashscope`, `deepseek`, `ark`, `openrouter` —
and alias chains that **fail over across vendors**:

```
chat-fast  → dashscope/qwen-flash → deepseek/deepseek-v4-flash → ark/doubao-…
chat-smart → dashscope/qwen3-max  → deepseek/deepseek-v4-flash
voice-chat → dashscope/qwen-plus  → deepseek/deepseek-v4-flash
vision     → dashscope/qwen-vl-plus → ark/doubao-…
```

So one logical call can be served by any of three vendors depending on who is
up, and the same model id is reachable through more than one upstream at more
than one contracted price. The hub flattens `vendor/model` to a bare `model` and
prices every vendor at whichever rate `--pricing` last defined for that id.

This is not a display defect. Gateway `cost_usd` carries `CostKind == billed` —
the one column in this hub whose figure is asserted to be an invoice. The
overrides file cannot express the distinction either: `gateway.models` is a flat
`map[string]Rates`.

Today the blast radius is small (71 of 100 events are unpriced, total $0.0037,
because `gatewayRates` ships empty). It grows with every rate an operator adds.

### 1.3 The data needed to fix it is already arriving

`smoke/ai-gateway-ccquota-ship.js:183` in the monorepo already sends it:

```js
details: { model_provider: providerOf(row), billing_mode: 'metered' }
```

`providerOf` returns the upstream hostname with the port stripped —
`dashscope.aliyuncs.com`, `ark.cn-beijing.volces.com` — chosen deliberately over
the route name, because (the shipper's own comment) alias chains fail over and
only the upstream says who actually served the call.

`store.go:489` includes `details_json` in the `usage_events` INSERT for every
source, so **these values are already persisted** — they are simply inside a
JSON blob that no query can group by. No ingest contract change and no
cross-repo coordination is required, and history can be backfilled.

### 1.4 Two further facts that constrain the UI

- **`account_uuid` means something different per source.** The hub holds
  `gateway:smoke`, `gateway:open_api`, `gateway:aicall`, `gateway:ai_voice_agent`,
  `gateway:ai_site` — display name `AI 网关 · <consumer>`. The shipper maps one
  APISIX consumer to one account. On `claude`/`codex` an account is a
  subscription; on `gateway` it is a calling application. One control labelled
  "subscription" cannot serve both.
- **No gateway collector exists.** `/v1/collectors` returns none, and no scanner
  or agent path produces `SourceGateway`. Gateway health is the freshness of an
  external CronJob push, not a collector state.

## 2. Goals and non-goals

Goals:

1. **A gateway cost figure is priced on the contract that produced it** —
   `(provider, model)`, not `model`.
2. **`provider` is a first-class, groupable dimension**, backfilled from the
   `details_json` already in the database.
3. **The hub's top-level axis is billing relationship, not product name.** No
   source is the default; `claude` stops being the fallback.
4. **`gateway` appears as what it is** — a reporting channel — and not as a peer
   of the two subscriptions.
5. **The Now/Review tab split is removed**; one continuous surface.
6. No figure of one money kind is ever added to another. PR #10's discipline is
   extended to a new axis, never relaxed.

Non-goals:

- **No new collector source.** This work adds none. (`model.Sources` gained
  `vendor_bill` in #12, which landed while this was in flight — see §8.)
- **No alias dimension.** The alias a caller asked for (`chat-fast`) is not
  shipped and answering "how much did failover cost me" needs a new field from
  the shipper. Recorded in §7 as follow-up; explicitly out of scope.
- **No FX change.** The pinned CNY/USD constant and its disclosure rules stand.
- **No identifier rename.** Command, module path, DB path and env vars remain
  `ccquota`, per #7.
- **No currency conversion for subscription plans.** Unchanged.

## 3. Subproject A — the provider dimension and the pricing fix

Ships first and alone. The interface cannot show a provider column that has no
data behind it, and a rearranged dashboard cannot rescue a wrong number.

### 3.1 What `provider` is

The string the reporting side declared, stored verbatim. For gateway events that
is the upstream hostname. **The hub does not map hostnames to vendor slugs and
does not guess.** A rate is a contract term this build cannot know — the same
rule `gatewayRates` already follows by shipping empty — and a hostname→vendor
table maintained here would be a second, silently-drifting source of truth
beside `catalog.json`.

On `claude` the field is empty. On `codex` it is whatever `session_meta.model_provider`
declared (`internal/scan/codex.go:200`), which is already `openai` in practice
and which `internal/pricing/codex.go:33` already gates on.

Empty is a legitimate value meaning **not declared**. It is rendered as such,
never as a vendor named "unknown" and never merged into a neighbour.

### 3.2 Storage

1. `usage_events.provider TEXT NOT NULL DEFAULT ''` — one more entry in the
   `migrate()` list in `store.go`; plain `ALTER TABLE ADD COLUMN`.
2. **Backfill from data already held:**
   ```sql
   UPDATE usage_events
      SET provider = COALESCE(json_extract(details_json, '$.model_provider'), '')
    WHERE provider = '' AND details_json <> '{}';
   ```
3. `usage_hourly.provider` must join the PRIMARY KEY, and SQLite cannot alter
   one. Follow `migrateSources` exactly: rename the table, recreate it from
   `schema.sql`, `INSERT … SELECT` the old columns with `''` for the new one,
   drop the old table, recreate the indexes — all inside the existing
   transaction.

   The rollup backfill is **not** reconstructed from `usage_events`: raw events
   are pruned and rollup history outlives them, so pre-migration rollup rows
   keep `provider = ''`. That is honest — those rows genuinely predate the
   dimension. A migration note records it, and §3.6 makes the UI say so rather
   than showing a silently-too-small provider total.

   Because the backfill in step 2 *can* run over surviving raw events, the two
   paths disagree for any period where raw events still exist but the rollup
   predates the migration. `rollup_equiv_test.go` compares the two; it is
   extended to assert the disagreement is confined to `provider` and that both
   still agree on tokens, events and cost.
4. `rollupInsertSQL` and every read path that names hourly columns gain
   `provider`.

### 3.3 Dimension and filter

- `store.ByProvider Dimension = "provider"`, with `column()` returning
  `"provider"`.
- `Filter.Provider` + `eq("provider", …)` in `filter.go`.
- `?provider=` on the query API, and a `provider` argument on the MCP usage
  tools, described as: *the upstream that actually served the call; on a gateway
  with failover this is not derivable from the model id.*

### 3.4 Pricing

`gatewayRates` becomes keyed on `(provider, model)`. The overrides file grows a
nested form and keeps the flat one:

```json
{"gateway": {
  "rates_as_of": "2026-09-12",
  "cny_per_usd": 7.09, "cny_per_usd_as_of": "2026-09-12",
  "models": { "qwen-plus": {"input": 0.8, "output": 2.0} },
  "providers": {
    "dashscope.aliyuncs.com":    { "label": "阿里云百炼",
      "models": { "qwen-plus": {"input": 0.8, "output": 2.0} } },
    "ark.cn-beijing.volces.com": { "label": "火山方舟",
      "models": { "deepseek-v4-flash": {"input": 0.5, "output": 1.5} } }
  }
}}
```

Lookup order in `gatewayCost`:

1. `providers[event.provider].models[Normalize(model)]` — the contract that
   actually served the call.
2. `models[Normalize(model)]` — the flat table, meaning *this price holds for
   every provider*.
3. Unpriced, with a basis naming which key was missing.

The flat form is kept because it is the honest way to say "one price, whoever
serves it", not merely for compatibility. What it must never do is answer a
lookup for a provider that has its own block — so a provider block is
authoritative for the models it names, and step 2 is reached only when the
provider declares no rate for that model.

`price_basis` names the provider whenever one was used, so a stored figure
discloses which contract produced it. `label` is display only and never affects
a rate. Validation extends the existing rules: positive input/output, no cache
rates, `rates_as_of` required when any rate is present.

**Guard test (the point of the subproject):** two providers, same model id,
different rates → two events → two different costs. This fails on today's code.

### 3.5 Aggregates

`CostBySource` is unchanged: money kinds are still split by source, and provider
is a grouping axis *within* the billed kind, never a fourth kind. A provider
breakdown returns the same `cost` list shape, so `lib/cost.js` reads it with no
new concepts.

### 3.6 Provenance

Every provider-grouped response carries a note when any bucket is
`provider = ''`, distinguishing the two reasons — the source declares no
provider (`claude`), and the rows predate the dimension (pre-migration rollup).
The UI prints it; it is not left to the reader to notice a bucket labelled blank.

## 4. Subproject B — the interface

Ships after A. Layout P2′, approved in brainstorming.

### 4.1 The top-level axis is billing relationship

Two buckets, always, whatever sources exist:

- **subscription** — billed monthly whether or not a token is spent; token cost
  is notional.
- **metered** — billed per call; the token cost *is* the invoice.

`gateway` is not on the top axis. It appears in exactly two places: as a
per-row attribute (*reported via the gateway*), and in collection health as a
push channel with a freshness reading — no collector state, because there is no
collector.

### 4.2 Structure

One continuous surface. The Now/Review tabs are removed; `state.js`'s `view`
key is retired, and its slot in the hash is dropped with a redirect for old
links. Sections, top to bottom:

1. **Real spend** — `subscription + metered`, with the two terms shown and the
   notional figure printed beside it, labelled as not part of the sum. The
   existing `real_spend` / `RealSpendOver` computation is reused unchanged.
2. **Live** — the current `Right now` block, unchanged in behaviour.
3. **Subscription quota** — the gauges, one group per subscription. Metered
   providers have no gauge and say why ("billed per call — no quota").
4. **Consumption** — the table below.
5. **Usage analysis** — timeline, breakdowns, model mix, sessions. Existing
   Review cards, re-parented.
6. **Fleet and collection** — endpoints, collectors, account switches, and the
   gateway push channel's freshness.

Each section keeps its own refresh rhythm: live on the stream, the stored cards
on the existing 60 s timer, analysis on the brush.

### 4.3 The consumption table

Row key is **(provider, model)**. Columns: provider (with `--pricing` label when
one exists, else the raw string, else *not declared*), model, billing (subscription /
metered), tokens, cost — the cost cell carrying its kind, as `fmtCost` already
renders it.

Two rows for the same model id under two providers is the correct and expected
output; it is what the deployment's failover actually does. Sortable by tokens
and by cost. Cost sorting is **within one billing kind only** — a control that
ranked a notional figure against a billed one would produce exactly the blended
reading PR #10 removed. When the scope spans both kinds, sorting by cost sorts
within each group and the groups stay apart.

### 4.4 The account control

Labelled by what an account means for the sources in scope: *subscription* for
claude/codex, *calling application* for gateway. When the scope spans both, the
control groups its options under those two headings rather than presenting one
flat list under one wrong word.

### 4.5 What stops privileging Claude

- `review.js:220` — `activeSources(d).length ? … : ['claude']` — the hard
  fallback goes; an empty scope renders an empty state, not a Claude column.
- `scope.js:137,146` — `(a.source || 'claude')` stays as the storage-compat
  reading of a blank stored source, but no longer selects a default view.
- Source becomes an ordinary filter alongside provider and model, not a mode.

### 4.6 Embed self-check

`web/embed_test.go` asserts anchors in the built page. Per #8 those anchors must
not be product names or section titles that a rename will move. New anchors are
structural ids (`#real-spend`, `#consumption`), and the test is updated in the
same commit that moves them.

## 5. Testing

Subproject A:

- `pricing`: two providers × one model id → two costs; provider block beats flat
  table; flat table used when the provider declares nothing; unpriced basis
  names the missing key; nested and flat overrides both validate; a provider
  block with a bad rate rejects the whole file.
- `store`: `ByProvider` groups; the filter narrows; the backfill populates from
  `details_json`; the `usage_hourly` rebuild preserves every pre-existing row
  and total; `rollup_equiv_test.go` extended per §3.2.
- `cost_guard_test.go`: provider grouping produces no new money kind and no
  cross-kind sum.
- `api` / `mcp`: `?provider=`, the argument, and the §3.6 note.

Subproject B:

- `web/test/*.mjs` for the pure helpers: (provider, model) row keying, the
  kind-scoped sort, the account-control grouping.
- `web/embed_test.go` for the new anchors.
- Manual pass against the live hub before release, since it is the only place
  with real multi-provider gateway rows.

## 6. Release

Two releases, A then B, each verified against the live hub before the next
starts. A's migration is one-way (the `usage_hourly` rebuild); the deploy takes
a database backup first — `~/.ccquota/backups/` is already in use — and the
migration is exercised against a copy of the production database before it runs
against production.

## 7. Follow-up, not in scope

1. **Alias dimension.** `chat-fast` and its siblings are what callers ask for;
   the hub only sees the model that served the request after failover. "What did
   `chat-fast` cost, and how much of that was failover to a pricier vendor" needs
   the shipper to send the alias. Cross-repo; worth doing after B.
2. **Rate coverage.** 71 of 100 gateway events are unpriced because
   `--pricing` is nearly empty. A dimension that prices correctly still reports
   almost nothing until the operator states the contracts. Separate, and A's
   coverage reporting is what will make the gap visible.
3. **Provider labels from the catalog.** `catalog.json` already holds vendor
   slugs; a generator could emit the `--pricing` provider block from it rather
   than having both maintained by hand.

## 8. Reconciliation with `vendor_bill` (#12)

#12 landed a fourth source while this was being built: `vendor_bill`, spend read
straight off a vendor's invoice for asynchronous task APIs whose data path never
touches the gateway. Three consequences, none of which change the design:

1. **The provider dimension is unaffected mechanically.** `vendor_bill` is
   classified `CostBilled` like the gateway, so provider remains a grouping axis
   inside the billed kind and adds no money kind. The guard in
   `cost_guard_test.go` covers it because it derives the expected kind from
   `model.CostKind` rather than listing sources.

2. **It strengthens subproject B's premise.** `vendor_bill` has real charged
   money, **no tokens at all**, and no per-app attribution. A top-level axis of
   "source" would give it a column that is empty in every token cell; an axis of
   *billing relationship* puts it exactly where it belongs, beside the gateway
   under `metered`. §4.3's consumption table must therefore tolerate a row with
   cost and no tokens — rendered as an absence, never as zero tokens.

3. **It is the source where a provider is most obviously meaningful,** since a
   bill is by definition one vendor's. Its collector does not exist yet (it lives
   in `24haowan-monorepo`); when it is built it should set `provider` to the
   vendor it is billing for. `ProviderNote` says so, so a blank there reads as
   "the collector did not state it" rather than "this spend has no vendor".

`real_spend` now has three terms (subscription + gateway + vendor_bill). §4.2's
headline reuses `RealSpendOver` unchanged and therefore picks this up for free;
the copy beside it names whichever terms are non-zero rather than a fixed two.
