# Subproject B — TokenLedger Interface Reorientation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the hub's top-level axis *billing relationship* rather than product name — one continuous surface with no Now/Review split, a consumption table keyed on `(provider, model)`, and `gateway` demoted to the reporting channel it actually is.

**Architecture:** The page keeps its module layout (`app.js` router, `scope.js` bar, `now.js` / `review.js` section renderers, `lib/*` pure helpers). What changes is that `view` stops existing: both renderers mount into one scrolling root, each keeping its own loader and refresh rhythm. The new consumption table is a new module reading the `provider` dimension subproject A shipped.

**Tech Stack:** Hand-written ES modules under `web/dist` embedded by `go:embed` — no npm, no build step. Tests: `node --test web/test/*.test.mjs` for pure helpers, `go test ./web/` for the embed self-check.

**Spec:** `docs/superpowers/specs/2026-09-12-tokenledger-provider-and-reorientation-design.md` (§4 and §8)

## Global Constraints

- **Never render one money kind added to another.** `lib/cost.js` offers `notionalCost` and `billedCost` and deliberately no `total()`. Real spend comes from the API's own `real_spend`, which is `subscription + gateway + vendor_bill`.
- **A source with cost and no tokens is legitimate.** `vendor_bill` has charged money, zero tokens, no per-app attribution. Render absent token cells as an absence (`—`), never `0`.
- **An empty provider is "not declared", never a vendor called unknown.** When a response carries `provider_note`, print it.
- **No new API endpoints.** Everything B needs shipped in A: `?provider=`, `by=provider`, `provider_note`, `real_spend`.
- **No identifier rename.** Command, module path, DB path, env vars stay `ccquota` (#7). Only user-facing copy says TokenLedger.
- **Embed anchors are structural ids, never product names or section titles** (#8, `web/embed_test.go`).
- Full check: `go test ./... && node --test web/test/*.test.mjs && gofmt -l .`

## Live data this is built against (2026-09-13, post-A)

```
by provider                        events    tokens   gateway billed
(not declared)                     434444   1.08e11   —
openai            (codex)            2022   248537722 —
dashscope.aliyuncs.com               1324     2048721 $0.235736
api.deepseek.com                       38       27924 unpriced
ark.cn-beijing.volces.com              10         680 unpriced
ai-relay.24hw.cn                       10         230 $0.000329
```

Five real providers; `vendor_bill` currently has zero rows, so its "cost without
tokens" path cannot be verified against production and **must** be covered by a
unit test instead (Task 3).

---

### Task 1: Retire `view` — one continuous surface

**Files:**
- Modify: `web/dist/index.html` (drop the tab buttons; one `<main>`)
- Modify: `web/dist/lib/state.js` (`DEFAULTS`, `parse`, `format`)
- Modify: `web/dist/app.js` (`route`, `load`)
- Modify: `web/dist/scope.js` (`renderNav` loses the tabs)
- Test: `web/test/state.test.mjs`

**Interfaces:**
- Consumes: nothing from A beyond what already ships.
- Produces: a hash grammar with no `view` segment — `#/` and `#/session/<id>`. Both loaders run on every route. Tasks 2-4 mount sections into the single root.

- [ ] **Step 1: Write the failing test**

Append to `web/test/state.test.mjs`:

```js
test('the hash has no view segment', () => {
  const s = parse('#/?sub=abc&span=7d');
  assert.equal(s.view, undefined);
  assert.equal(s.sub, 'abc');
  assert.equal(format(s), '#/?sub=abc&span=7d');
});

test('a session still round-trips', () => {
  const s = parse('#/session/abc-123?span=7d');
  assert.equal(s.session, 'abc-123');
  assert.equal(format(s), '#/session/abc-123?span=7d');
});

// Old links are the only reason anyone types a URL twice. They must land on
// the same page with the same scope, not on a blank one.
test('old #/now and #/review links keep their scope', () => {
  for (const old of ['#/now?sub=abc&span=7d', '#/review?sub=abc&span=7d']) {
    const s = parse(old);
    assert.equal(s.sub, 'abc', old);
    assert.equal(s.span, '7d', old);
    assert.equal(format(s), '#/?sub=abc&span=7d', old);
  }
});

test('an old review session link keeps its session', () => {
  const s = parse('#/review/session/abc-123');
  assert.equal(s.session, 'abc-123');
  assert.equal(format(s), '#/session/abc-123');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test web/test/state.test.mjs`
Expected: FAIL — `s.view` is `'now'`, and `format` emits `#/now?…`.

- [ ] **Step 3: Update the state module**

In `web/dist/lib/state.js`:

```js
export const DEFAULTS = Object.freeze({ session: null, sub: 'all', span: '30d', from: null, to: null, chips: {}, g1: 'project', g2: 'model', sort: 'tokens' });
```

Replace the path match in `parse` with one that accepts the old shape and
forgets it:

```js
  // `/now` and `/review` are consumed and dropped: the split they named is
  // gone, but links to it are in people's history and in chat logs, and a
  // shared link that lands on a blank page is how a rename loses data nobody
  // notices. Everything after it — the session id and the whole query string —
  // still resolves.
  const m = path.match(/^\/(?:now|review)?(?:\/session\/([^/?]+))?\/?$/);
  if (m && m[1]) s.session = decodeURIComponent(m[1]);
```

and in `format`:

```js
  const path = '#/' + (s.session ? 'session/' + encodeURIComponent(s.session) : '');
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test web/test/state.test.mjs`
Expected: PASS

- [ ] **Step 5: One root in the markup**

In `web/dist/index.html`, delete the `<nav class="views">` block entirely and
replace the two `<main>` elements with one:

```html
<header class="scope" id="scope">
  <div class="row1">
    <h1>TokenLedger</h1>
    <span class="spacer"></span>
    <button id="theme" title="Toggle light / dark">◐</button>
  </div>
  <div class="progress" id="progress" hidden></div>
</header>
<div class="wrap">
  <div id="banners"></div>
  <main id="page" aria-busy="false">
    <section id="spend"></section>
    <section id="live"></section>
    <section id="quota"></section>
    <section id="consumption"></section>
    <section id="analysis"></section>
    <section id="fleet"></section>
  </main>
  <footer id="footer"></footer>
</div>
```

Update the comment above `<header>`: the bar is now wordmark + theme only, and
scope still lives on each section's own controls widget.

- [ ] **Step 6: Drop the tab handlers**

In `web/dist/scope.js`'s `renderNav`, remove the two `#tab-now` / `#tab-review`
listeners and the `aria-selected` updates. Keep the theme toggle and the
`data-bound` guard exactly as they are.

- [ ] **Step 7: Run both renderers on every route**

In `web/dist/app.js`, `route()` loses the `hidden` toggles and the `onView`
handler; `load()` runs both:

```js
async function load() {
  const s = app.state;
  const nowR = renderNow($('#live'), s, app);
  const reviewR = renderReview($('#analysis'), s, app);
  const root = $('#page');
  root.setAttribute('aria-busy', 'true'); setBusy(true);
  const [a, b] = await Promise.all([
    loaders.now.run(nowR.fetchers, nowR.apply),
    loaders.review.run(reviewR.fetchers, reviewR.apply),
  ]);
  if (a && b) { root.setAttribute('aria-busy', 'false'); setBusy(false); }
}
```

Two loaders, not one, on purpose: the sections keep their different rhythms
(live on the stream and a 60 s timer; analysis on the brush and a 5 min timer),
and `seq.js`'s per-loader sequencing is what keeps a slow response from
overwriting a newer scope. Keep both `setInterval`s, dropping their
`state.view` conditions.

- [ ] **Step 8: Verify in a browser**

```bash
go build -o /tmp/ccq ./cmd/ccquota && /tmp/ccq hub --addr 127.0.0.1:8788 --no-auth --db ~/.ccquota/ccquota.db
```

Open `http://127.0.0.1:8788/`. Expect: one scrolling page, no tabs, and
`#/now?span=7d` redirecting to `#/?span=7d` with the span intact.

**If the local database is empty** (it is, on this machine — `~/.ccquota/ccquota.db`
is 0 bytes), point `--db` at a copy pulled from the hub, or accept empty-state
rendering and rely on Task 5's manual pass against production.

- [ ] **Step 9: Commit**

```bash
git add web/dist/index.html web/dist/lib/state.js web/dist/app.js web/dist/scope.js web/test/state.test.mjs
git commit -m "$(cat <<'EOF'
feat(web): 去掉 Now / Review 的切换 —— 一页连续，view 这个键不再存在

那道分界是按刷新节奏切的，不是按问题切的：「现在在烧多少」和「这段时间烧了多少」
是同一个问题的两个时间尺度，中间隔一个 tab 只会让人来回点。

两个 loader 保留，因为节奏确实不同（实时走事件流 + 60 秒，分析走 brush + 5 分钟），
而 seq.js 的按 loader 排序正是防止慢响应盖掉新作用域的东西。

旧链接 #/now 与 #/review 被吃掉而不是报错：那个分界没了，但链接还在别人的历史记录和
聊天记录里，而分享出去的链接落到空白页是改名最容易悄悄丢掉的东西。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: The spend headline — billing relationship as the top axis

**Files:**
- Create: `web/dist/spend.js`
- Modify: `web/dist/app.js` (fetch `/v1/summary`, mount into `#spend`)
- Modify: `web/dist/styles.css`
- Test: `web/test/spend.test.mjs` (new)

**Interfaces:**
- Consumes: `store.Filter`-scoped `/v1/summary` — `real_spend {subscription, gateway, vendor_bill, total, complete, missing}`, `cost[]`, `subscription_spend[]`, `real_spend_note`.
- Produces: `renderSpend(root, summary)`, and the pure helper `spendTerms(realSpend)` that Task 3 reuses for its billing-kind grouping.

- [ ] **Step 1: Write the failing test**

Create `web/test/spend.test.mjs`:

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { spendTerms } from '../dist/spend.js';

test('names only the terms that are non-zero', () => {
  const t = spendTerms({ currency: 'USD', subscription: 200, gateway: 12.8, vendor_bill: 0, total: 212.8, complete: true });
  assert.deepEqual(t.map((x) => x.key), ['subscription', 'gateway']);
});

// vendor_bill exists precisely because some spend never touches the gateway.
// Folding it into the gateway term would put a claim about provenance on a
// number that does not support it.
test('vendor_bill is its own term, never folded into gateway', () => {
  const t = spendTerms({ subscription: 0, gateway: 1, vendor_bill: 9, total: 10, complete: true });
  assert.deepEqual(t.map((x) => x.key), ['gateway', 'vendor_bill']);
  assert.equal(t.find((x) => x.key === 'vendor_bill').amount, 9);
});

test('all-zero spend yields no terms rather than three zeroes', () => {
  assert.deepEqual(spendTerms({ subscription: 0, gateway: 0, vendor_bill: 0, total: 0, complete: true }), []);
});

test('missing real_spend is an absence, not zero', () => {
  assert.deepEqual(spendTerms(null), []);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test web/test/spend.test.mjs`
Expected: FAIL — cannot find `../dist/spend.js`.

- [ ] **Step 3: Write the module**

Create `web/dist/spend.js`:

```js
// web/dist/spend.js — the one figure on the page that is money somebody paid.
//
// The top axis of this page is the BILLING RELATIONSHIP, not the product name.
// There are exactly two ways this deployment is charged — a subscription that
// bills monthly whether or not a token is spent, and metered spend that bills
// per call — and `gateway` is neither: it is the channel one of the metered
// sources reports through. Putting it on the top axis is what made the old
// page read as "Claude, plus some others".
import { el } from './lib/dom.js';
import { fmtUSD } from './lib/format.js';
import { notionalCost, unpricedEvents } from './lib/cost.js';

const LABEL = {
  subscription: 'subscriptions',
  gateway: 'metered · via the gateway',
  vendor_bill: 'metered · billed by the vendor directly',
};

/** spendTerms lists the non-zero terms of real spend, in display order.
 *
 *  A zero term is dropped rather than shown as $0.00: this deployment either
 *  has that kind of charge or it does not, and three rows of zero teach a
 *  reader nothing while making the two real ones harder to find. Terms are
 *  never merged — `vendor_bill` folded into `gateway` would put a claim about
 *  provenance on a figure that cannot support it. */
export function spendTerms(rs) {
  if (!rs) return [];
  return ['subscription', 'gateway', 'vendor_bill']
    .map((key) => ({ key, label: LABEL[key], amount: rs[key] || 0 }))
    .filter((t) => t.amount !== 0);
}

export function renderSpend(root, summary) {
  if (!summary) { root.replaceChildren(); return; }
  const rs = summary.real_spend;
  const terms = spendTerms(rs);
  const card = el('div', { class: 'card', id: 'real-spend' },
    el('h2', {}, 'What this actually cost'));

  card.appendChild(el('p', { class: 'figure' },
    rs ? fmtUSD(rs.total) + (rs.complete ? '' : ' ≥') : '—'));

  if (terms.length) {
    card.appendChild(el('p', { class: 'terms' },
      terms.map((t) => `${t.label} ${fmtUSD(t.amount)}`).join('  +  ')));
  }

  // The notional figure sits beside the total and outside it, labelled with
  // what it is. It is the biggest number on the page and the one nobody is
  // billed; printing it without that sentence is how it gets read as a bill.
  const notional = notionalCost(summary);
  if (notional) {
    card.appendChild(el('p', { class: 'hint' },
      `Not part of that total: ${fmtUSD(notional)} of API-equivalent cost for ` +
      `subscription work. Nobody is billed per token on a plan — the plan is the bill.`));
  }
  if (summary.real_spend_note) card.appendChild(el('p', { class: 'hint' }, summary.real_spend_note));
  if (rs && !rs.complete) {
    card.appendChild(el('p', { class: 'hint warn' },
      'Incomplete — ' + (rs.missing || []).join('; ')));
  }
  const unpriced = unpricedEvents(summary);
  if (unpriced) {
    card.appendChild(el('p', { class: 'hint' },
      `${unpriced} request(s) have no price data, so every figure here is a lower bound.`));
  }
  root.replaceChildren(card);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test web/test/spend.test.mjs`
Expected: PASS (4 tests)

- [ ] **Step 5: Mount it**

In `web/dist/app.js`, add a third loader and fetcher:

```js
const loaders = { now: createLoader(), review: createLoader(), spend: createLoader() };
```

and inside `load()`:

```js
  const spendR = {
    fetchers: [(signal) => app.api('/v1/summary?' + apiQuery(s, spanRange(s)), signal)],
    apply: ([r]) => renderSpend($('#spend'), r.status === 'fulfilled' ? r.value : null),
  };
```

`apiQuery` and the span→range helper already exist in `lib/state.js` and
`review.js`; if the range helper is not exported, export it from `lib/state.js`
rather than duplicating the arithmetic.

- [ ] **Step 6: Style the figure**

In `web/dist/styles.css`, beside the existing `.card` rules:

```css
#real-spend .figure { font-size: 2.6rem; font-weight: 650; margin: 4px 0 2px; letter-spacing: -0.02em; }
#real-spend .terms { color: var(--muted); margin: 0 0 10px; font-variant-numeric: tabular-nums; }
#real-spend .hint.warn { color: var(--warn, #c0703a); }
@media (max-width: 480px) { #real-spend .figure { font-size: 2rem; } }
```

Use whatever `--muted` / `--warn` custom properties the file already defines;
do not introduce a new palette.

- [ ] **Step 7: Full check and commit**

```bash
node --test web/test/*.test.mjs && go test ./web/
git add web/dist/spend.js web/dist/app.js web/dist/styles.css web/test/spend.test.mjs
git commit -m "$(cat <<'EOF'
feat(web): 头条换成「真的付了多少」—— 顶层轴从产品名改为计费关系

原来的头条是 Claude 的额度表盘，于是这个 hub 打开第一眼永远是「Claude 加上另外几个」。
真正分开这些钱的不是产品名，是计费关系：订阅按月收、按量按次收。gateway 两者都不是,
它是其中一种按量来源的上报通道。

三项分列不合并：vendor_bill 折进 gateway 会让一个关于出处的字段名去承载它撑不起的主张。
为零的项直接不显示 —— 三行 $0.00 教不会读者任何事，只会让真的那两行更难找。

名义成本挨着总额但在总额之外，并且写明它是什么：它是页面上最大的数字，也是没人被
收过的那个。不带那句话地印出来，就是它被读成账单的方式。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: The consumption table, keyed on `(provider, model)`

**Files:**
- Create: `web/dist/consumption.js`
- Create: `web/dist/lib/rows.js` (pure row assembly + sorting)
- Modify: `web/dist/app.js`
- Test: `web/test/rows.test.mjs` (new)

**Interfaces:**
- Consumes: `/v1/usage?by=provider` and `/v1/usage?by=model`, each returning `buckets[{key, label, events, tokens, cost[]}]` plus optional `provider_note`.
- Produces: `consumptionRows(providerBuckets, modelBuckets)` and `sortRows(rows, key)`; `renderConsumption(root, {provider, model})`.

Because no endpoint groups by two dimensions at once, the table's rows come
from the provider breakdown, and the model breakdown fills the per-provider
detail on expand — one extra request per expanded provider, scoped by
`?provider=`. That is cheaper and more honest than inventing a cross-product
client-side from two independent aggregates.

- [ ] **Step 1: Write the failing test**

Create `web/test/rows.test.mjs`:

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { consumptionRows, sortRows } from '../dist/lib/rows.js';

const gw = (n, cost) => ({ source: 'gateway', kind: 'billed', events: n, cost_usd: cost, unpriced_events: 0 });
const cc = (n, cost) => ({ source: 'claude', kind: 'notional', events: n, cost_usd: cost, unpriced_events: 0 });
const vb = (n, cost) => ({ source: 'vendor_bill', kind: 'billed', events: n, cost_usd: cost, unpriced_events: 0 });

test('a blank provider key is "not declared", never a vendor', () => {
  const [r] = consumptionRows([{ key: '', events: 5, tokens: 10, cost: [cc(5, 1)] }]);
  assert.equal(r.provider, '');
  assert.equal(r.providerLabel, 'not declared');
});

test('rows carry their billing kind so the two are never sorted together', () => {
  const rows = consumptionRows([
    { key: 'dashscope.aliyuncs.com', events: 5, tokens: 10, cost: [gw(5, 3)] },
    { key: '', events: 5, tokens: 99, cost: [cc(5, 900)] },
  ]);
  assert.equal(rows.find((r) => r.provider === 'dashscope.aliyuncs.com').kind, 'billed');
  assert.equal(rows.find((r) => r.provider === '').kind, 'notional');
});

// vendor_bill is charged money with no tokens at all. Zero tokens would read
// as "measured, and it was zero"; the truth is that this source does not
// count tokens.
test('a row with cost and no tokens reports tokens as absent, not zero', () => {
  const [r] = consumptionRows([{ key: 'ark.cn-beijing.volces.com', events: 3, tokens: 0, cost: [vb(3, 42)] }]);
  assert.equal(r.tokens, null);
  assert.equal(r.cost, 42);
});

// Sorting one kind of money against another produces exactly the blended
// reading the per-source split exists to prevent.
test('sorting by cost sorts within a kind and keeps the kinds apart', () => {
  const rows = consumptionRows([
    { key: 'a', events: 1, tokens: 1, cost: [gw(1, 5)] },
    { key: '', events: 1, tokens: 1, cost: [cc(1, 900)] },
    { key: 'b', events: 1, tokens: 1, cost: [gw(1, 50)] },
  ]);
  const sorted = sortRows(rows, 'cost');
  assert.deepEqual(sorted.map((r) => r.kind), ['billed', 'billed', 'notional']);
  assert.deepEqual(sorted.filter((r) => r.kind === 'billed').map((r) => r.provider), ['b', 'a']);
});

test('sorting by tokens puts absent last rather than treating it as zero', () => {
  const rows = consumptionRows([
    { key: 'a', events: 1, tokens: 0, cost: [vb(1, 1)] },
    { key: 'b', events: 1, tokens: 5, cost: [gw(1, 1)] },
  ]);
  assert.deepEqual(sortRows(rows, 'tokens').map((r) => r.provider), ['b', 'a']);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test web/test/rows.test.mjs`
Expected: FAIL — cannot find `../dist/lib/rows.js`.

- [ ] **Step 3: Write the row helper**

Create `web/dist/lib/rows.js`:

```js
// web/dist/lib/rows.js — turning a provider breakdown into table rows.
//
// The row key is (provider, model), not model. A gateway that fails over
// between vendors reaches one model id through several upstreams at several
// contracted prices, so a row keyed on the model alone would add two invoices
// together and show one plausible number.
import { activeSources, costOf, kindOf } from './cost.js';

const KIND_ORDER = { billed: 0, notional: 1, unknown: 2 };

/** consumptionRows flattens one breakdown into rows carrying the two facts a
 *  reader needs before comparing anything: which contract, and which kind of
 *  money. */
export function consumptionRows(buckets) {
  return (buckets || []).map((b) => {
    const sources = activeSources(b);
    const src = sources[0] || 'claude';
    const c = costOf(b, src);
    return {
      provider: b.key,
      // Empty is the reporting side declaring none. Naming it beats a blank
      // cell the reader has to interpret, and it must not look like a vendor.
      providerLabel: b.key || 'not declared',
      sources,
      kind: kindOf(src),
      events: b.events || 0,
      // null, not 0: vendor_bill is charged money that counts no tokens, and
      // 0 would claim it was measured.
      tokens: b.tokens ? b.tokens : null,
      cost: c.cost_usd || 0,
      unpriced: c.unpriced_events || 0,
    };
  });
}

/** sortRows orders rows without ever ranking one kind of money against
 *  another: kinds stay grouped, and the sort applies inside each group. */
export function sortRows(rows, key) {
  const within = (a, b) => {
    if (key === 'tokens') {
      // Absent sorts last in both directions — it is not a small number.
      if (a.tokens == null && b.tokens == null) return 0;
      if (a.tokens == null) return 1;
      if (b.tokens == null) return -1;
      return b.tokens - a.tokens;
    }
    if (key === 'cost') return b.cost - a.cost;
    return b.events - a.events;
  };
  return [...rows].sort((a, b) =>
    (KIND_ORDER[a.kind] - KIND_ORDER[b.kind]) || within(a, b));
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test web/test/rows.test.mjs`
Expected: PASS (5 tests)

- [ ] **Step 5: Write the table**

Create `web/dist/consumption.js` rendering into `#consumption`:

- One `<table>`; columns provider · billing · requests · tokens · cost.
- `providerLabel` in the first cell; when the row's provider is `''`, add the
  `provider_note` from the response as a `<p class="hint">` under the table
  rather than a per-cell tooltip — it explains a class of row, not one row.
- `billing` cell reads `metered` for `billed` and `subscription` for
  `notional`, with `title` giving `KIND_LABEL[kind]` so the underlying term is
  still discoverable.
- `tokens` cell renders `—` when `row.tokens == null`.
- `cost` cell uses `fmtCost` from `lib/format.js`, which already handles the
  `≥` prefix for unpriced events.
- A `<caption>` or heading paragraph states the sort rule in one sentence:
  *"Sorted within each billing kind — a metered charge and an API-equivalent
  estimate are not comparable amounts."*
- Sort controls set `?sort=` through `app.setState`, reusing the existing
  `SORTS` machinery in `lib/state.js`; add `'events'` to `SORTS` if absent.
- Expanding a provider row fetches `/v1/usage?by=model&provider=<key>&…` and
  renders the models beneath it. Guard against double-fetch with a
  `row.dataset.loaded` flag.

- [ ] **Step 6: Mount and check against production data**

Add the `by=provider` fetcher to `app.js`'s spend loader group and mount
`renderConsumption($('#consumption'), …)`.

```bash
go build -o /tmp/ccq ./cmd/ccquota
```

Verify against the live hub through the browser, or against the API directly:

```bash
curl -s -H "Authorization: Bearer $CCQUOTA_VIEWER_TOKEN" \
  "https://ccquota.24haowan.com/v1/usage?by=provider&account=all&since=30d&limit=50" \
  | python3 -m json.tool | head -40
```

Expect the five providers from the header table above, `dashscope` carrying a
billed figure and `deepseek` / `ark` unpriced.

- [ ] **Step 7: Commit**

```bash
node --test web/test/*.test.mjs && go test ./web/
git add web/dist/consumption.js web/dist/lib/rows.js web/dist/app.js web/test/rows.test.mjs
git commit -m "$(cat <<'EOF'
feat(web): 消耗明细按 (供应商, 模型) 成行 —— 同一模型两家上游是两行

行主键不是模型：网关会跨厂商 fallback，一个模型 id 对应多份合同多个价，
按模型合成一行等于把两张发票加起来给出一个看着很合理的数。

排序在计费种类**内部**进行，两类不互相比：拿按量的真账单去和订阅的名义估算排名次，
正是按 source 拆开这件事要防的那种混读。

没有 token 的行（vendor_bill 那一档）显示为缺席而不是 0 —— 0 是「量过了，是零」，
而真相是这个来源根本不计 token。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: The account control, and the end of the Claude fallback

**Files:**
- Modify: `web/dist/scope.js` (the subscription `<select>`)
- Modify: `web/dist/review.js:220` (the `['claude']` fallback)
- Test: `web/test/providers.test.mjs`

**Interfaces:**
- Consumes: `/v1/accounts` — each account carries `source`, `email`/`display_name`, `subscription_type`.
- Produces: `accountGroups(accounts)` in `lib/providers.js`, used by the control.

- [ ] **Step 1: Write the failing test**

Append to `web/test/providers.test.mjs`:

```js
import { accountGroups } from '../dist/lib/providers.js';

// On claude/codex an account is a subscription. On gateway it is a calling
// application — the shipper maps one APISIX consumer to one account. One
// control labelled "subscription" is wrong for half its own options.
test('accounts group by what an account MEANS for its source', () => {
  const g = accountGroups([
    { account_uuid: 'a', source: 'claude', email: 'x@y.z', subscription_type: 'max' },
    { account_uuid: 'b', source: 'gateway', display_name: 'AI 网关 · aicall' },
    { account_uuid: 'c', source: 'codex', email: 'q@r.s', subscription_type: 'prolite' },
  ]);
  assert.deepEqual(g.map((x) => x.label), ['Subscriptions', 'Calling applications']);
  assert.deepEqual(g[0].options.map((o) => o.value), ['a', 'c']);
  assert.deepEqual(g[1].options.map((o) => o.value), ['b']);
});

test('a single-kind hub gets one group, not an empty second one', () => {
  const g = accountGroups([{ account_uuid: 'a', source: 'claude', email: 'x@y.z' }]);
  assert.equal(g.length, 1);
});

test('no accounts yields no groups', () => {
  assert.deepEqual(accountGroups([]), []);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test web/test/providers.test.mjs`
Expected: FAIL — `accountGroups` is not exported.

- [ ] **Step 3: Implement**

In `web/dist/lib/providers.js`:

```js
/** accountGroups splits the account list by what an account MEANS for its
 *  source, because the word differs: on claude and codex it is a subscription
 *  somebody pays for monthly; on gateway it is one calling application, since
 *  the shipper maps one APISIX consumer to one account. A single flat list
 *  under one of those two words is wrong about the other half of its options.
 *  An empty group is omitted rather than rendered — a heading over nothing is
 *  a promise the hub cannot keep. */
export function accountGroups(accounts) {
  const kind = (a) => ((a.source || 'claude') === 'gateway' ? 'app' : 'sub');
  const label = { sub: 'Subscriptions', app: 'Calling applications' };
  const name = (a) => a.email || a.display_name || a.account_uuid;
  return ['sub', 'app']
    .map((k) => ({
      key: k,
      label: label[k],
      options: (accounts || []).filter((a) => kind(a) === k)
        .map((a) => ({ value: a.account_uuid, text: name(a) })),
    }))
    .filter((g) => g.options.length > 0);
}
```

In `scope.js`, replace the flat `<option>` loop with `<optgroup>`s built from
`accountGroups`, keeping the leading "All" option ungrouped. Drop the
`${a.source === 'codex' ? 'Codex · ' : 'Claude · '}` prefix — the group heading
now carries that meaning, and the prefix is the last place the UI asserts a
two-source world.

- [ ] **Step 4: Remove the Claude fallback**

In `web/dist/review.js:220`:

```js
  const sourceTiles = activeSources(d).map((src) => { … });
```

and immediately after, handle the empty case explicitly:

```js
  // No fallback to ['claude']. An empty scope is an empty scope; inventing a
  // Claude column for it is how this page came to read as Claude-first in the
  // first place.
  if (!sourceTiles.length) {
    card.appendChild(el('p', { class: 'empty' }, 'No usage in this selection.'));
  }
```

- [ ] **Step 5: Run tests and check the rendered control**

Run: `node --test web/test/*.test.mjs`
Expected: PASS. Then load the page and confirm the subscription select shows
two `<optgroup>`s against the live hub (it holds three Claude accounts, one
Codex account and five `gateway:*` applications).

- [ ] **Step 6: Commit**

```bash
git add web/dist/lib/providers.js web/dist/scope.js web/dist/review.js web/test/providers.test.mjs
git commit -m "$(cat <<'EOF'
feat(web): 账户选择器按「账户在这个来源里是什么」分组，并删掉 claude 兜底

同一个「账户」维度两边语义不同：claude / codex 那边是一份按月付钱的订阅，
gateway 那边是一个调用方应用（shipper 把一个 APISIX consumer 映射成一个账户）。
一个平铺列表不论用哪个词做标签，对另一半选项都是错的。

顺手删掉 review.js 里 activeSources 为空时硬回落到 ['claude'] 的那一行。
空作用域就是空作用域 —— 给它凭空造一列 Claude，正是这个面板当初变成「Claude 优先」
的方式。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Embed anchors, full verification, release

**Files:**
- Modify: `web/embed_test.go`
- Modify: `README.md`
- Test: everything

**Interfaces:**
- Consumes: all of the above.
- Produces: a released hub.

- [ ] **Step 1: Update the embed self-check**

Read `web/embed_test.go` first — per #8 its anchors must be structural ids, not
product names or section titles. Replace any anchor that no longer exists
(`tab-now`, `tab-review`) with the new structural ids from Task 1's markup:
`id="page"`, `id="spend"`, `id="consumption"`. Add a comment saying why these
and not the headings above them.

- [ ] **Step 2: Full local verification**

```bash
cd /Users/verkyyi/projects/ccquota-scratch-1
gofmt -l . | tee /tmp/fmt && test ! -s /tmp/fmt
go vet ./...
go test -race ./...
node --test web/test/*.test.mjs
```
Expected: all green — this is exactly the repo's CI job list.

- [ ] **Step 3: Manual pass against production data**

The live hub is the only place with multi-provider gateway rows.

```bash
go build -o /tmp/ccq ./cmd/ccquota
```

Point a local hub at a **snapshot copy** of production (never the live file) as
Task 6 of subproject A did, and walk the page: the spend headline names its
terms; the consumption table shows five providers with kinds apart; expanding
`dashscope.aliyuncs.com` lists its models; the account select shows two groups;
`#/now?span=7d` redirects with the span intact; the page holds up at 400 px.

- [ ] **Step 4: Update the README screenshot description and dashboard section**

The README describes the dashboard as two views. Rewrite that paragraph to
describe one surface, and say what the top axis is and why.

- [ ] **Step 5: Commit, PR, merge**

```bash
git add -A && git commit -m "..." && git push -u origin tokenledger-ui
gh pr create --base main --title "feat(web): TokenLedger 界面重排 —— 顶层轴是计费关系，不是产品名" --body "…"
```

- [ ] **Step 6: Release**

Follow `doc/k8s-yamls/ccquota/RUNBOOK.md` in the monorepo:

```bash
SHA=$(git rev-parse --short=8 HEAD)
docker buildx build --platform linux/amd64 --build-arg VERSION=prod-$SHA \
  -t registry.cn-shenzhen.aliyuncs.com/24haowan/ccquota:prod-$SHA --push .
kubectl -n new-deploy set image deploy/ccquota-hub \
  ccquota=registry-vpc.cn-shenzhen.aliyuncs.com/24haowan/ccquota:prod-$SHA
kubectl -n new-deploy rollout status deploy/ccquota-hub
```

No database migration this time, so no backup gate and no rollup rebuild. If
the pod sticks in `ContainerCreating`, the runbook's first step is
`kubectl -n new-deploy delete pod -l app=ccquota-hub`.

- [ ] **Step 7: Verify live**

Open `https://ccquota.24haowan.com/` and confirm the page renders one surface
with the five providers. Then re-check the two things a UI change can silently
break:

```bash
curl -s -H "Authorization: Bearer $TOK" "https://ccquota.24haowan.com/v1/usage?by=source&account=all&since=3650d"
```

Event and token counts must match the figures recorded in subproject A's
release notes; a UI release must not move them.

---

## Self-Review

**Spec coverage.** §4.1 (billing relationship as top axis) → Task 2. §4.2 (one
continuous surface, `view` retired, sections and rhythms) → Task 1. §4.3 (the
consumption table, `(provider, model)`, kind-scoped sort) → Task 3. §4.4 (the
account control) → Task 4. §4.5 (the Claude fallback) → Task 4 Step 4. §4.6
(embed anchors) → Task 5 Step 1. §8.2 (a row with cost and no tokens) → Task 3
Step 1, as a unit test, because production has no `vendor_bill` rows to check
it against.

**Placeholders.** Task 3 Step 5 and Task 5 Steps 4-5 describe rendering and
prose rather than giving literal code. That is deliberate for markup assembly
that follows patterns already established in `review.js`'s `sessionsCard` —
every behavioural rule those steps impose (absent vs zero, kind-scoped sort,
where the note goes) is pinned by a test in Step 1. The two spots that name a
lookup rather than a literal — the span→range helper in Task 2 Step 5 and the
current anchors in Task 5 Step 1 — say exactly which file to read.

**Type consistency.** `spendTerms(rs) -> [{key,label,amount}]` (Task 2) is used
only by Task 2. `consumptionRows(buckets) -> [{provider, providerLabel, sources,
kind, events, tokens|null, cost, unpriced}]` and `sortRows(rows, key)` (Task 3)
are used by `consumption.js` alone. `accountGroups(accounts) ->
[{key,label,options:[{value,text}]}]` (Task 4) is used by `scope.js` alone.
`DEFAULTS` loses `view` in Task 1 and nothing else reads it afterwards —
`app.js`'s `route()` and both `setInterval`s are updated in the same task.
