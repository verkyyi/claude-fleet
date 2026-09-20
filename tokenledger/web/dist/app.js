// web/dist/app.js — boot, router, loader wiring.
import { parse, format, dataKey, resolveSub } from './lib/state.js';
import { createLoader } from './lib/seq.js';
import { renderNav, renderScopeControls, setBusy, syncNav } from './scope.js';
import { renderNow, startLive } from './now.js';
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
  // Repositories a shipper has pushed progress for. Read once at boot, and NOT
  // on the critical path -- boot() lets the first screen render against this
  // empty list and fills it when the answer arrives. The list changes when
  // somebody points a new shipper at this hub, which is not a per-minute
  // event, and an empty list is the normal state of every hub that never
  // turned the feature on.
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
  // The page's one WRITE. Kept beside api() rather than inside the card that
  // needs it so there is a single place that knows the error shape -- a
  // handler's `{error: "..."}` body, which is what the operator has to be
  // shown when a write is refused.
  //
  // No locale tag: unlike api(), nothing here renders a server sentence into
  // the page except the error, and an error is more useful in whatever words
  // the server logged it under.
  async post(path, body) {
    const res = await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      let msg = `HTTP ${res.status}`;
      try { msg = (await res.json()).error || msg; } catch {}
      throw new Error(msg);
    }
    return res.json();
  },
  // refresh re-runs every loader against the CURRENT scope, bypassing the
  // reuse gate in route(). A write the viewer just made changes what the
  // server would answer without changing the hash, so there is nothing for
  // route() to notice -- see lib/mute.js, which is the only caller.
  refresh() { return load(false); },
  setState(next, { push = true } = {}) {
    const h = format(next);
    if (h === location.hash) return;
    if (push) history.pushState(null, '', h); else history.replaceState(null, '', h);
    route();
  },
};

const loaders = { now: createLoader(), review: createLoader(), consumption: createLoader(), repo: createLoader() };
let lastRendered = '';
// What the last load ASKED FOR. Compared against the next one to tell a change
// that needs new rows from one that only re-draws the rows already in hand --
// see the `reuse` branch in route(). Each loader keeps its own last results;
// seq.js's replay() is what hands them back.
let lastDataKey = null;

function route() {
  app.state = parse(location.hash);
  const s = app.state;
  // Which subscription is this state actually looking at? state.js owns that
  // rule -- route()'s job is only to make the state, and then the URL, agree
  // with its answer. It still corrects an unknown or out-of-scope sub, and it
  // now SELECTS the only subscription on a hub that has one rather than leaving
  // it on 'all' (#92), which nothing could ever leave.
  s.sub = resolveSub(s, app.accounts);
  // Fix the URL to match, not just the in-memory state: state.js's whole
  // premise is "there is no second copy of the state", and leaving the hash on
  // the unknown sub -- or on the omitted-because-default 'all' just resolved
  // away from -- would silently re-run this same correction on every reload or
  // shared link. The same call normalises the path, for the same reason:
  // parse() still accepts the retired /now and /review prefixes so old links
  // keep working, but leaving one in the address bar means every copy of that
  // link spreads a path this build no longer emits.
  //
  // replaceState, not push: this is a correction of the current entry, not a
  // navigation the reader performed, and it must not itself trigger another
  // route() (replaceState fires no hashchange), which would recurse.
  const canonical = format(s);
  if (canonical !== location.hash) history.replaceState(null, '', canonical);
  // The bar takes one handler again (#97). It had none while the page had no
  // views to switch between; now each nav entry names one, and pressing it
  // moves `view` and NOTHING else -- the spread is what keeps the reader's
  // subscription, span, chips and repo filter across the switch, and `view`
  // being a presentation key (state.js) is what keeps the switch free.
  const onView = (view) => app.setState({ ...s, view });
  // These five belong to the scope-controls widgets.
  const cb = {
    onSub: (sub) => app.setState({ ...s, sub }),
    onSource: (source) => { const chips = { ...s.chips }; if (source) chips.source = source; else delete chips.source; app.setState({ ...s, chips }); },
    onSpan: (span) => app.setState({ ...s, span, from: null, to: null }),
    onChipRemove: (dim) => { const chips = { ...s.chips }; delete chips[dim]; app.setState({ ...s, chips }); },
    onClear: () => app.setState({ ...s, chips: {} }),
  };
  renderNav($('#scope'), { onView });
  // Updates EVERY section's scope-controls widget synchronously — see
  // scope.js's renderScopeControls doc comment.
  renderScopeControls(s, app.accounts, cb);
  if (s.session) renderDetail($('#detail'), s, app); else closeDetail($('#detail'));
  const key = format({ ...s, session: null });
  if (key !== lastRendered) {
    // Did this change alter what we ASK for, or only how we show it? Narrowing
    // the stalled table to one label, or re-sorting the consumption table by
    // tokens, changes not one request URL on the page -- so every tier redraws
    // from the rows already in hand and the whole click costs zero requests.
    // It is the page-wide answer, not the progress tier's: the other three
    // loaders in load() used to go out unconditionally underneath the band
    // that had just redrawn itself for free.
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
  //
  // Both are also told whether the operations tier is OPEN, and they answer by
  // leaving the requests that only fill it unsent -- eight of this page's
  // requests exist to fill a box that is closed by default. Read live rather
  // than captured once: the fold's own toggle handler calls load() again, so
  // opening it is what sends them, and every refresh after that keeps them
  // coming because the fold is still open.
  const ops = opsOpen();
  lastLoadOps = ops;
  const nowR = renderNow($('#status'), s, app, ops);
  const reviewR = renderReview($('#analysis'), s, app, ops);
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
  // The spend headline reads the summary this loader already fetched -- folded
  // in here rather than at the call site so the reuse path below gets it too.
  const reviewApply = (results) => {
    const r = results[SUMMARY_INDEX];
    renderSpend($('#spend'), r && r.status === 'fulfilled' ? r.value : null);
    reviewR.apply(results);
  };
  // The progress tier renders only where a shipper has pushed something. A
  // hub that never turned the feature on must look exactly as it did before
  // it landed -- no empty card, no band, no extra request per route.
  const repoDone = loadRepoTier(s, reuse);
  root.setAttribute('aria-busy', 'true'); setBusy(true);
  const [a, b, c, d] = await Promise.all([
    runOrReplay(loaders.now, nowR.fetchers, nowR.apply, reuse),
    runOrReplay(loaders.consumption, consumptionR.fetchers, consumptionR.apply, reuse),
    runOrReplay(loaders.review, reviewR.fetchers, reviewApply, reuse),
    repoDone,
  ]);
  // The event stream opens HERE, once the first screen is off the wire -- not
  // from inside renderNow, before it. It is held for the whole session, so
  // opening it during the burst spent one of the origin's six connections for
  // the entire time the page was trying to use all six. now.js's startLive is
  // a no-op unless a render armed it, and it is deliberately not gated on the
  // fold: the stream also feeds the token badge outside it. Every loader above
  // resolves (seq.js settles rather than throws), so this line is always
  // reached.
  startLive(app);
  if (a && b && c && d) {
    root.setAttribute('aria-busy', 'false');
    setBusy(loaders.now.inFlight || loaders.review.inFlight || loaders.consumption.inFlight || loaders.repo.inFlight);
  }
}

/** runOrReplay is the ONE gate between "this change needs new rows" and "this
 *  change re-draws rows we already have", and every tier on the page now goes
 *  through it. It used to be one tier: #36 taught the progress band to redraw
 *  synchronously, which is why the stalled table's filter stopped lying about
 *  its own state -- but the three loaders beside it still went out
 *  unconditionally, so filtering that table by a label kept costing 17
 *  requests. The control was honest and the network was not.
 *
 *  `reuse` is route()'s verdict on the STATE (did the dataKey move?); seq.js's
 *  replay() has the last word on the RESULTS (does what we kept cover what
 *  this round would ask?), and answers false when it does not. So a change
 *  that genuinely moves the data -- a new span, a dragged brush, a chip, a
 *  different group-by -- never reaches the replay at all, and one that arrives
 *  while the fold has outrun the cache falls through to a real fetch. */
function runOrReplay(loader, fetchers, apply, reuse) {
  if (reuse && loader.replay(fetchers, apply)) return Promise.resolve(true);
  return loader.run(fetchers, apply);
}

/** loadRepoTier draws the progress band and its cards, and is the ONE place
 *  that does -- load() calls it on every route, and boot() calls it again if
 *  /v1/repos turns out to hold something after the first screen has already
 *  rendered without it. Re-running the whole load() there instead would re-ask
 *  every other question on the page to answer this one.
 *
 *  The tier renders only where a shipper has pushed something. A hub that never
 *  turned the feature on must look exactly as it did before it landed -- no
 *  empty card, no band, no extra request per route. */
function loadRepoTier(s, reuse) {
  const repoR = renderRepo($('#repo'), s, app, app.repos);
  const band = $('#repo-band');
  if (band) band.hidden = !repoR;
  // ...and the nav entry that points at that band goes with it. Same call
  // decides both, one line apart, because a nav offering a destination the page
  // does not have is the specific failure #54 set out to avoid. It is also why
  // boot()'s late /v1/repos comes back through HERE and not through a bare
  // renderRepo: a band that appears without its nav entry is that same failure
  // wearing the other face.
  syncNav();
  if (!repoR) return Promise.resolve(true);
  // Applied SYNCHRONOUSLY on a presentation-only change, and that is the whole
  // point: measured against the deployed hub, re-fetching this tier to hide
  // some of its own rows took 4.4 seconds, and for those 4.4 seconds the
  // toggle the reader had just pressed still showed its old value. A control
  // that misreports its own state is worse than one that is merely slow.
  //
  // The 60-second refresh and the repo picker both call load() with no
  // argument, so neither can be served a stale page from here.
  return runOrReplay(loaders.repo, repoR.fetchers, repoR.apply, reuse);
}

// The operations tier remembers whether it was open, per viewer.
//
// localStorage rather than the URL: the scope in the URL is what a link MEANS
// ("this account, this window"), and pasting a link should not also reach into
// how the recipient had their page folded. Same storage pattern the chart/table
// toggles already use, and the same tolerance for it being unavailable -- a
// private window throws on access, and the page must still open.
const OPS_KEY = 'ccquota-ops-open';

/** opsOpen is what the two loaders ask before deciding which of their requests
 *  to send. Read from the DOM rather than a mirrored variable so there is no
 *  second copy of the fold's state to fall out of step with the element the
 *  reader actually clicked -- and it is false before wireOpsFold runs, which is
 *  the safe direction: a load that beat the restore sends the small set. */
function opsOpen() {
  const ops = $('#ops');
  return !!(ops && ops.open);
}

/** What the last load()'s fetch plan assumed the fold was doing, or null if no
 *  load has run yet. The toggle handler below needs it to tell an open the
 *  READER performed from the one wireOpsFold performs on their behalf. */
let lastLoadOps = null;

function wireOpsFold() {
  const ops = $('#ops');
  if (!ops) return;
  try { ops.open = localStorage.getItem(OPS_KEY) === '1'; } catch {}
  ops.addEventListener('toggle', () => {
    try { localStorage.setItem(OPS_KEY, ops.open ? '1' : '0'); } catch {}
    // Opening the tier is what ASKS for its eight requests; until now they were
    // never sent. Closing it needs no load: what is already drawn stays, and
    // the next load simply stops refreshing it.
    //
    // This fires for a programmatic open too, which is what the section nav
    // does -- scope.js's goToSection sets `open` on the way to scrolling there,
    // so the nav entry fetches the tier as well as reveals it.
    //
    // The condition is "the last load planned for a CLOSED fold", not "the fold
    // is open", and the difference is a doubled first screen. A <details> fires
    // toggle ASYNCHRONOUSLY, so the `open` wireOpsFold restores from
    // localStorage above lands here as an event of its own -- after boot()'s
    // route() has already loaded, with the fold open, having fetched
    // everything. Measured before this guard: an ops-open viewer sent 36
    // requests where they used to send 20. Reading what the last load actually
    // planned for tells the two opens apart:
    //   null  -- no load yet (the restore beat route()); route()'s own load is
    //            coming and will see an open fold. Nothing to do.
    //   true  -- that load already fetched the tier. Nothing to do.
    //   false -- the reader just opened a fold the last load left out. Fetch.
    if (ops.open && lastLoadOps === false) load();
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
  // Third request, sent at the same time as the other two and awaited by
  // NOBODY -- see the .then() below route(). It depends on nothing and nothing
  // on the first screen depends on it, and #30 is the standing lesson about
  // what putting a dependency-free request on the critical path costs a viewer
  // outside the cluster: a whole round trip staring at an empty page.
  //
  // Failure is not an error state, for the same reason a missing FX feed is
  // not: a hub with no repo data is a working hub, and it is also what every
  // hub predating this feature looks like.
  const reposReq = app.api('/v1/repos').catch(() => []);
  try { app.accounts = await accountsReq; }
  catch (err) { $('#banners').replaceChildren(el('div', { class: 'banner err' }, t('app.unreachable', { error: err.message }))); return; }
  useFxRate(await fxReq);
  addEventListener('hashchange', route);
  route();
  // route() does NOT wait for /v1/repos, and that is the half of #30's lesson
  // that never landed. Sending it in parallel bought nothing while the line
  // below still read `app.repos = await reposReq` above route(): the whole
  // first screen sat behind a request that decides ONE thing -- whether one
  // optional band appears -- and on every hub nobody ever pointed a shipper
  // at, decides that the band stays hidden. A round trip to render nothing.
  //
  // Arriving late breaks nothing, because the tier was already built to render
  // as nothing: the first route() drew it from the empty list and hid the band
  // and its nav entry, exactly as it does on a hub with no repos. A non-empty
  // answer then draws it for real, and that is the only case that costs the two
  // repo requests. A failure still resolves to [] via the .catch above, so
  // there is no branch for it here -- a hub with no repo data is a working hub.
  reposReq.then((repos) => {
    app.repos = Array.isArray(repos) ? repos : [];
    if (app.repos.length) loadRepoTier(app.state, false);
  });
  // The stored cards refresh every minute; the analysis section only when the
  // brush is at the right edge, every five minutes.
  setInterval(async () => {
    try { app.accounts = await app.api('/v1/accounts'); route(); } catch {}
    load();
  }, 60_000);
  setInterval(() => { if (app.state.to == null) load(); }, 300_000);
}
boot();
