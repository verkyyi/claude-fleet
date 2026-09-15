// web/dist/app.js — boot, router, loader wiring.
import { parse, format, dataKey } from './lib/state.js';
import { createLoader } from './lib/seq.js';
import { renderNav, renderScopeControls, setBusy } from './scope.js';
import { renderNow } from './now.js';
import { renderReview, SUMMARY_INDEX } from './review.js';
import { renderSpend } from './spend.js';
import { renderConsumption } from './consumption.js';
import { renderRepo } from './repo.js';
import { apiQuery } from './lib/state.js';
import { extent, resolve } from './lib/brush.js';
import { renderDetail, closeDetail } from './session.js';
import { $, el, localizeShell } from './lib/dom.js';
import { t, withLocale, displayCurrency } from './lib/i18n.js';
import { useFxRate } from './lib/format.js';

export const app = {
  state: parse(location.hash),
  accounts: [],
  // Repositories a shipper has pushed progress for. Read once at boot: the
  // list changes when somebody points a new shipper at this hub, which is not
  // a per-minute event, and an empty list is the normal state of every hub
  // that never turned the feature on.
  repos: [],
  now: () => Date.now(),
  async api(path, signal) {
    // Every request carries the locale, in ONE place: the server's own notes
    // (real spend, price basis per source, the empty-provider explanation) come
    // back translated, and a caller that forgot to tag its path would print one
    // English paragraph in the middle of a Chinese card.
    const res = await fetch(withLocale(path), { headers: { Accept: 'application/json' }, signal });
    if (!res.ok) {
      let msg = `HTTP ${res.status}`;
      try { msg = (await res.json()).error || msg; } catch {}
      throw new Error(msg);
    }
    return res.json();
  },
  setState(next, { push = true } = {}) {
    const h = format(next);
    if (h === location.hash) return;
    if (push) history.pushState(null, '', h); else history.replaceState(null, '', h);
    route();
  },
};

const loaders = { now: createLoader(), review: createLoader(), consumption: createLoader(), repo: createLoader() };
let lastRendered = '';
// The progress tier's last results, kept so a presentation-only change can be
// drawn from them. See the `reuse` branch in load() for why.
let lastDataKey = null;
let lastRepoResults = null;

function route() {
  app.state = parse(location.hash);
  const s = app.state;
  if (!s.sub || (s.sub !== 'all' && !app.accounts.some((a) => a.account_uuid === s.sub && (!s.chips.source || (a.source || 'claude') === s.chips.source)))) {
    s.sub = 'all';
    // Fix the URL to match, not just the in-memory state: state.js's whole
    // premise is "there is no second copy of the state", and leaving the
    // hash on the unknown/invalid sub would silently re-run this same
    // correction on every reload or shared link. replaceState (not push):
    // this is a correction of the current entry, not a new navigation, and
    // it must not itself trigger another route() (replaceState fires no
    // hashchange), which would recurse into this same branch.
    const corrected = format(s);
    if (corrected !== location.hash) history.replaceState(null, '', corrected);
  }
  // Normalise the path the same way, for the same reason. parse() still
  // accepts the retired /now and /review prefixes so old links keep working,
  // but leaving one in the address bar means every copy of that link spreads
  // a path this build no longer emits. replaceState, not push: reading a
  // shared link is not a navigation the reader performed.
  const canonical = format(s);
  if (canonical !== location.hash) history.replaceState(null, '', canonical);
  // renderNav takes no handlers any more: with the view gone the bar has
  // nothing to invoke. These four belong to the scope-controls widgets.
  const cb = {
    onSub: (sub) => app.setState({ ...s, sub }),
    onSource: (source) => { const chips = { ...s.chips }; if (source) chips.source = source; else delete chips.source; app.setState({ ...s, chips }); },
    onSpan: (span) => app.setState({ ...s, span, from: null, to: null }),
    onChipRemove: (dim) => { const chips = { ...s.chips }; delete chips[dim]; app.setState({ ...s, chips }); },
    onClear: () => app.setState({ ...s, chips: {} }),
  };
  renderNav($('#scope'));
  // Updates EVERY section's scope-controls widget synchronously — see
  // scope.js's renderScopeControls doc comment.
  renderScopeControls(s, app.accounts, cb);
  if (s.session) renderDetail($('#detail'), s, app); else closeDetail($('#detail'));
  const key = format({ ...s, session: null });
  if (key !== lastRendered) {
    // Did this change alter what we ASK for, or only how we show it? Narrowing
    // the stalled table to one label changes neither request the progress tier
    // makes, so it redraws from the rows already in hand.
    const dk = dataKey(s);
    const reuse = lastDataKey === dk;
    lastRendered = key;
    lastDataKey = dk;
    load(reuse);
  }
}

async function load(reuse = false) {
  const s = app.state;
  const root = $('#page');
  // Both sections render on every route. Two loaders, not one, because the
  // rhythms genuinely differ -- status refreshes on the event stream and a
  // 60s timer, analysis only when the brush touches the right edge -- and
  // seq.js's per-loader sequencing is what stops a slow response from
  // overwriting a newer scope.
  const nowR = renderNow($('#status'), s, app);
  const reviewR = renderReview($('#analysis'), s, app);
  // Same range the analysis section resolves, so the consumption table and the
  // charts below it are answering about one period. Duplicating the arithmetic
  // here would let the two drift apart the first time the brush logic changes.
  const range = resolve({ from: s.from, to: s.to }, s.span, app.now());
  const consumptionR = {
    fetchers: [(signal) => app.api('/v1/usage?' + apiQuery(s, {
      from: range.from, to: range.to, omitDim: 'provider',
      extra: { by: 'provider', limit: 50 },
    }), signal)],
    apply: ([r]) => renderConsumption($('#consumption'), r, s, app, range),
  };
  // The progress tier renders only where a shipper has pushed something. A
  // hub that never turned the feature on must look exactly as it did before
  // it landed -- no empty card, no band, no extra request per route.
  const repoR = renderRepo($('#repo'), s, app, app.repos);
  const band = $('#repo-band');
  if (band) band.hidden = !repoR;
  // Applied SYNCHRONOUSLY on a presentation-only change, and that is the whole
  // point: measured against the deployed hub, re-fetching this tier to hide
  // some of its own rows took 4.4 seconds, and for those 4.4 seconds the
  // toggle the reader had just pressed still showed its old value. A control
  // that misreports its own state is worse than one that is merely slow.
  //
  // The 60-second refresh and the repo picker both call load() with no
  // argument, so neither can be served a stale page from here.
  const repoDone = !repoR ? Promise.resolve(true)
    : reuse && lastRepoResults ? (repoR.apply(lastRepoResults), Promise.resolve(true))
    : loaders.repo.run(repoR.fetchers, (results) => { lastRepoResults = results; repoR.apply(results); });
  root.setAttribute('aria-busy', 'true'); setBusy(true);
  const [a, b, c, d] = await Promise.all([
    loaders.now.run(nowR.fetchers, nowR.apply),
    loaders.consumption.run(consumptionR.fetchers, consumptionR.apply),
    loaders.review.run(reviewR.fetchers, (results) => {
      // The spend headline reads the summary this loader already fetched.
      const r = results[SUMMARY_INDEX];
      renderSpend($('#spend'), r && r.status === 'fulfilled' ? r.value : null);
      reviewR.apply(results);
    }),
    repoDone,
  ]);
  if (a && b && c && d) {
    root.setAttribute('aria-busy', 'false');
    setBusy(loaders.now.inFlight || loaders.review.inFlight || loaders.consumption.inFlight || loaders.repo.inFlight);
  }
}

// The operations tier remembers whether it was open, per viewer.
//
// localStorage rather than the URL: the scope in the URL is what a link MEANS
// ("this account, this window"), and pasting a link should not also reach into
// how the recipient had their page folded. Same storage pattern the chart/table
// toggles already use, and the same tolerance for it being unavailable -- a
// private window throws on access, and the page must still open.
const OPS_KEY = 'ccquota-ops-open';

function wireOpsFold() {
  const ops = $('#ops');
  if (!ops) return;
  try { ops.open = localStorage.getItem(OPS_KEY) === '1'; } catch {}
  ops.addEventListener('toggle', () => {
    try { localStorage.setItem(OPS_KEY, ops.open ? '1' : '0'); } catch {}
  });
}

async function boot() {
  // The shell's own strings first, before any fetch: a slow hub must not leave
  // the page's furniture in one language while the cards arrive in another.
  localizeShell(t);
  wireOpsFold();
  // The display rate and the account list, TOGETHER.
  //
  // Both must be in hand before the first render — the rate because a card that
  // drew at no rate beside one that drew at a rate would show the same money
  // two ways on one screen, the accounts because route() resolves the
  // subscription against them. But neither depends on the other, so they go out
  // at the same time.
  //
  // They used to be sequential, and it cost a whole round trip on the critical
  // path for exactly the viewers who need the rate: measured against the
  // deployed hub, one request is ~600ms from outside the cluster, so a Chinese
  // viewer waited ~600ms staring at an empty page before the account fetch even
  // started. It was invisible in local testing, where the same hop is 4ms —
  // which is precisely why it shipped.
  //
  // Failure of the rate is not an error state: a hub with no route to an FX
  // feed shows every figure in the currency it was billed in, which is the
  // truthful rendering anyway. Failure of the accounts IS, and only that one
  // stops the boot.
  const display = displayCurrency();
  const fxReq = display === 'USD'
    ? Promise.resolve(null)
    : app.api(`/v1/fx?base=USD&target=${encodeURIComponent(display)}`).catch(() => null);
  const accountsReq = app.api('/v1/accounts');
  // Third request, sent at the same time as the other two and awaited after
  // them. It depends on nothing, and #30 is the standing lesson about what
  // putting a dependency-free request on the critical path costs a viewer
  // outside the cluster: a whole round trip staring at an empty page.
  //
  // Failure is not an error state, for the same reason a missing FX feed is
  // not: a hub with no repo data is a working hub, and it is also what every
  // hub predating this feature looks like.
  const reposReq = app.api('/v1/repos').catch(() => []);
  try { app.accounts = await accountsReq; }
  catch (err) { $('#banners').replaceChildren(el('div', { class: 'banner err' }, t('app.unreachable', { error: err.message }))); return; }
  useFxRate(await fxReq);
  app.repos = await reposReq;
  addEventListener('hashchange', route);
  route();
  // The stored cards refresh every minute; the analysis section only when the
  // brush is at the right edge, every five minutes.
  setInterval(async () => {
    try { app.accounts = await app.api('/v1/accounts'); route(); } catch {}
    load();
  }, 60_000);
  setInterval(() => { if (app.state.to == null) load(); }, 300_000);
}
boot();
