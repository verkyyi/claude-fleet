// web/dist/app.js — boot, router, loader wiring.
import { parse, format } from './lib/state.js';
import { createLoader } from './lib/seq.js';
import { renderNav, renderScopeControls, setBusy } from './scope.js';
import { renderNow } from './now.js';
import { renderReview, SUMMARY_INDEX } from './review.js';
import { renderSpend } from './spend.js';
import { renderConsumption } from './consumption.js';
import { apiQuery } from './lib/state.js';
import { extent, resolve } from './lib/brush.js';
import { renderDetail, closeDetail } from './session.js';
import { $, el } from './lib/dom.js';

export const app = {
  state: parse(location.hash),
  accounts: [],
  now: () => Date.now(),
  async api(path, signal) {
    const res = await fetch(path, { headers: { Accept: 'application/json' }, signal });
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

const loaders = { now: createLoader(), review: createLoader(), consumption: createLoader() };
let lastRendered = '';

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
  if (key !== lastRendered) { lastRendered = key; load(); }
}

async function load() {
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
  root.setAttribute('aria-busy', 'true'); setBusy(true);
  const [a, b, c] = await Promise.all([
    loaders.now.run(nowR.fetchers, nowR.apply),
    loaders.consumption.run(consumptionR.fetchers, consumptionR.apply),
    loaders.review.run(reviewR.fetchers, (results) => {
      // The spend headline reads the summary this loader already fetched.
      const r = results[SUMMARY_INDEX];
      renderSpend($('#spend'), r && r.status === 'fulfilled' ? r.value : null);
      reviewR.apply(results);
    }),
  ]);
  if (a && b && c) {
    root.setAttribute('aria-busy', 'false');
    setBusy(loaders.now.inFlight || loaders.review.inFlight || loaders.consumption.inFlight);
  }
}

async function boot() {
  try { app.accounts = await app.api('/v1/accounts'); }
  catch (err) { $('#banners').replaceChildren(el('div', { class: 'banner err' }, 'Cannot reach the hub: ' + err.message)); return; }
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
