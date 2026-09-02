// web/dist/app.js — boot, router, loader wiring.
import { parse, format } from './lib/state.js';
import { createLoader } from './lib/seq.js';
import { renderNav, renderScopeControls, setBusy } from './scope.js';
import { renderNow } from './now.js';
import { renderReview } from './review.js';
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

const loaders = { now: createLoader(), review: createLoader() };
let lastRendered = '';

function route() {
  app.state = parse(location.hash);
  const s = app.state;
  if (!s.sub || (s.sub !== 'all' && !app.accounts.some((a) => a.account_uuid === s.sub))) {
    s.sub = app.accounts.length > 1 ? 'all' : (app.accounts[0]?.account_uuid || 'all');
  }
  // Handlers are shared by both calls below: renderNav only ever invokes
  // onView, renderScopeControls only ever invokes the other four — same
  // split the two functions had when this was one renderScope() call.
  const cb = {
    onView: (v) => app.setState({ ...s, view: v, session: null }),
    onSub: (sub) => app.setState({ ...s, sub }),
    onSpan: (span) => app.setState({ ...s, span, from: null, to: null }),
    onChipRemove: (dim) => { const chips = { ...s.chips }; delete chips[dim]; app.setState({ ...s, chips }); },
    onClear: () => app.setState({ ...s, chips: {} }),
  };
  renderNav($('#scope'), s, cb);
  // Updates EVERY view's scope-controls widget synchronously (whichever is
  // visible right now, and the hidden one so it stays correct for later) —
  // see scope.js's renderScopeControls doc comment.
  renderScopeControls(s, app.accounts, cb);
  $('#now').hidden = s.view !== 'now';
  $('#review').hidden = s.view !== 'review';
  if (s.session) renderDetail($('#detail'), s, app); else closeDetail($('#detail'));
  const key = format({ ...s, session: null });
  if (key !== lastRendered) { lastRendered = key; load(); }
}

async function load() {
  const s = app.state;
  const view = s.view;
  const root = $('#' + view);
  const r = view === 'now' ? renderNow(root, s, app) : renderReview(root, s, app);
  root.setAttribute('aria-busy', 'true'); setBusy(true);
  const ok = await loaders[view].run(r.fetchers, r.apply);
  if (ok) { root.setAttribute('aria-busy', 'false'); setBusy(loaders.now.inFlight || loaders.review.inFlight); }
}

async function boot() {
  try { app.accounts = await app.api('/v1/accounts'); }
  catch (err) { $('#banners').replaceChildren(el('div', { class: 'banner err' }, 'Cannot reach the hub: ' + err.message)); return; }
  addEventListener('hashchange', route);
  route();
  // Now refreshes its stored cards every minute; Review only when the brush
  // touches the right edge, every five minutes.
  setInterval(() => { if (app.state.view === 'now') load(); }, 60_000);
  setInterval(() => { if (app.state.view === 'review' && app.state.to == null) load(); }, 300_000);
}
boot();
