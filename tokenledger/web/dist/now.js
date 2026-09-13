import { quotaGauges, highestQuota, collectorsCard, accountUsageCard, selectLive } from './providers.js';
// web/dist/now.js — the Now view: hero odometer, live strip, "am I about to
// hit the wall" gauges, and the collapsible Fleet tables.
//
// hero (applyCounter/pacSVG/dotStream/the odometer wheels/tickHero),
// renderLive, connectLive, wallCard, endpointRosterCard, endpointAccountsCard,
// switchesCard and the lossy/spanning/stale banners are ported from the old
// <script> block of web/dist/index.html (pre-Task-11), unchanged except for
// the structural moves the Task 11 brief calls for:
//   - two stored tiles ("tokens (range)" / "spend (range)") are dropped from
//     the live card — they move to Review's KPI strip (task 12);
//   - the three fleet tables move under a closed-by-default
//     <details class="fleet">, remembered in localStorage;
//   - live rows are filtered by the current chips, and a row/project-name
//     click sets a session/project chip instead of doing nothing;
//   - `state.account`/`state.range`/`state.tables` (the old page's flat,
//     global state) become `app.state.sub` / the fixed 5-request fetch list
//     below / gone entirely (rankedBars is now the only Now-view chart; there
//     is no per-card table toggle here) — Now has no time range of its own,
//     it is *right now*.
import { el, $, escapeHTML } from './lib/dom.js';
import { fmtInt, fmtFull, shortProject, ago } from './lib/format.js';
import { withChip } from './lib/state.js';
import { createScopeControls } from './scope.js';
import * as C from './charts.js';

// Now's scope-controls widget: subscription select + chips row, no span
// control — Now has no time range, it is *right now* (see the module
// comment above). Mounted on the "Am I about to hit the wall?" card, below
// (Task 15 nav restructure): that card is per-subscription by definition,
// the natural first-substantive-card home for Now's scope, the same way
// Review's Timeline card owns Review's. Built once, module-eval time, same
// persistent-node reasoning as heroWrapEl/liveWrapEl just below — its
// content is kept current by app.js's route() calling scope.js's
// renderScopeControls on every hashchange, independent of this view's own
// async load() cycle.
const nowScope = createScopeControls({ span: false });

/* ------------------------------------------------------- persistent nodes */

// The hero counter and the live strip are driven by the SSE stream, which
// keeps pushing independently of the fetch/apply cycle below. Rebuilding
// them from scratch on every apply() would reset the odometer wheels and
// drop frames mid-animation, so each is a single node built once and reused
// — apply() just re-includes the same reference among root's children.
const heroWrapEl = el('div', { class: 'hero-wrap' });
const liveWrapEl = el('div', { class: 'live-wrap' });


/* ------------------------------------------------------------------ utils */

/** accountLabel is THE display name for a subscription, everywhere on this
 *  view. Mirrors the server's own precedence (email, then display name, then
 *  the uuid) so the switcher and a table never disagree. */
function accountLabel(app, uuid) {
  if (!uuid) return '—';
  const a = (app.accounts || []).find((x) => x.account_uuid === uuid);
  if (!a) return uuid;
  return a.email || a.display_name || a.account_uuid;
}

function errMsg(reason) {
  return (reason && reason.message) || String(reason);
}

/** queryFailed is the per-card error state every fetcher in this view falls
 *  back to on its own — one bad request never blanks the rest of the page. */
function queryFailed(title, result) {
  return el('div', { class: 'card' }, el('h2', {}, title),
    el('div', { class: 'empty' }, 'Query failed: ' + errMsg(result.reason)));
}

/* ------------------------------------------------- hero counter (Q0) */

// The all-time token total, counting between measurements.
//
// Neither source of usage is per-token: a transcript records a turn when it
// ENDS, and a statusLine reports a session's running totals when it redraws.
// The finest real granularity is a turn, arriving up to a minute late. So this
// projects forward at the measured rate and re-anchors whenever a measurement
// lands. Every rule it obeys was decided by the server — this only animates.
const hero = {
  anchor: 0,        // last measured total
  anchorAt: 0,      // when it was measured (ms)
  perMs: 0,         // measured rate, tokens per millisecond
  until: 0,         // stop projecting after this (ms); 0 = do not project
  shown: 0,         // what is on screen; never decreases
  raf: 0,
};

function applyCounter(c) {
  if (!c) return;
  const measuredAt = new Date(c.measured_at).getTime();
  hero.anchor = c.tokens;
  hero.anchorAt = Number.isFinite(measuredAt) ? measuredAt : Date.now();
  hero.perMs = (c.tokens_per_min || 0) / 60000;
  hero.until = c.project_until ? new Date(c.project_until).getTime() : 0;

  if (!heroWrapEl.firstChild) {
    heroWrapEl.replaceChildren(el('div', { class: 'hero', id: 'hero-root' },
      el('div', { class: 'tm' }, pacSVG(), dotStream(),
        el('div', { class: 'odo', id: 'hero-odo' },
          // The tilde is the whole honesty marker: this figure is projected
          // between measurements and is not exact. One character, always present.
          el('span', { class: 'tilde' }, '~'))),
      el('div', { class: 'k' }, 'tokens consumed · selected account and source · all time')));
  }
  if (!hero.raf) tickHero();
}

/* The character: two half-discs rotating about the centre, the eye riding on
   the upper jaw. Same geometry as the badge renderer, in a 48x48 box. */
function pacSVG() {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 48 48'); svg.setAttribute('class', 'pac'); svg.setAttribute('aria-hidden', 'true');
  svg.innerHTML =
    '<g class="ju"><path d="M24,24 L42,24 A18,18 0 0 0 6,24 Z" fill="var(--tm-pac)"/>' +
    '<circle cx="28" cy="15.4" r="2.5" fill="var(--tm-eye)"/></g>' +
    '<g class="jl"><path d="M24,24 L42,24 A18,18 0 0 1 6,24 Z" fill="var(--tm-pac)"/></g>';
  return svg;
}
function dotStream() {
  const run = el('div', { class: 'run' });
  for (let i = 0; i < 8; i++) run.appendChild(el('i'));
  return el('div', { class: 'dots' }, run);
}

/* Odometer wheels. Each wheel is a strip of 0-9 three times over. A wheel only
   ever moves FORWARD, by (new - old) mod 10 cells, so 9->0 rolls on to the next
   lap rather than spinning back. When a wheel nears the end of its strip it is
   shifted back one lap from wherever it is RENDERED at that instant -- the
   strip repeats every 10 cells, so a shift of exactly 10 is invisible, even
   mid-transition. That is what keeps a counter that moves every frame from
   ever running off the strip or reversing. */
const LAP = 10, LAPS = 3;
const wheels = []; // [{el, strip, idx}] left to right; idx counts cells from the top
function wheelEl() {
  const strip = el('div', { class: 'strip' });
  for (let k = 0; k < LAP * LAPS; k++) strip.appendChild(el('span', {}, String(k % LAP)));
  return { el: el('div', { class: 'wheel' }, strip), strip, idx: 0 };
}
function renderedY(strip) {
  const m = getComputedStyle(strip).transform;
  if (!m || m === 'none') return 0;
  const parts = m.match(/matrix\(([^)]+)\)/);
  return parts ? parseFloat(parts[1].split(',')[5]) : 0;
}
function shiftBackOneLap(w) {
  const cell = w.el.clientHeight;
  const y = renderedY(w.strip) + LAP * cell; // one lap less negative: same pixels
  w.strip.classList.add('snap');
  w.strip.style.transform = 'translateY(' + y + 'px)';
  void w.strip.offsetHeight;
  w.strip.classList.remove('snap');
  w.idx -= LAP;
}
function setOdometer(n) {
  const odo = $('#hero-odo', heroWrapEl);
  if (!odo) return;
  const digits = String(Math.floor(Math.max(0, n)));
  // Grow on the left as the count gains digits; separators are rebuilt then.
  if (wheels.length !== digits.length) {
    while (wheels.length < digits.length) wheels.unshift(wheelEl());
    while (wheels.length > digits.length) wheels.shift();
    const kids = [odo.firstChild]; // the tilde
    wheels.forEach((w, i) => {
      const fromRight = wheels.length - 1 - i;
      kids.push(w.el);
      if (fromRight > 0 && fromRight % 3 === 0) kids.push(el('span', { class: 'sep' }, ','));
    });
    odo.replaceChildren(...kids);
  }
  const now = performance.now();
  for (let i = 0; i < digits.length; i++) {
    const w = wheels[i], d = +digits[i];
    const step = (d - (w.idx % LAP) + LAP) % LAP;
    if (step === 0) continue;
    // A wheel that changes again before its last roll could finish is
    // moving faster than a roll can show. Rolling it anyway makes the
    // rendered strip fall ever further behind its target -- until it is
    // translated clean out of the window. So a fast wheel snaps, frame by
    // frame, which is what a spinning odometer wheel looks like anyway; only
    // a wheel that has been still for a moment gets the roll.
    const fast = now - (w.lastAt || 0) < 500;
    w.lastAt = now;
    if (w.idx + step >= LAP * (LAPS - 1)) shiftBackOneLap(w);
    w.idx += step;
    if (fast) w.strip.classList.add('snap');
    w.strip.style.transform = 'translateY(-' + (w.idx * 1.28) + 'em)';
    if (fast) { void w.strip.offsetHeight; w.strip.classList.remove('snap'); }
  }
}

function tickHero() {
  hero.raf = requestAnimationFrame(tickHero);
  const now = Date.now();

  // Projection has a deadline, set by the server from the last live report.
  // Past it the fleet is not known to be working, and a counter that keeps
  // climbing would be asserting work that is not happening.
  const live = hero.until > 0 && now < hero.until;
  const elapsed = live ? Math.max(0, now - hero.anchorAt) : 0;
  const target = hero.anchor + hero.perMs * elapsed;

  if (target > hero.shown) {
    // Ease toward the target rather than jumping, so a fresh measurement that
    // arrives well ahead of the projection lands smoothly.
    const gap = target - hero.shown;
    hero.shown += Math.max(gap * 0.12, Math.min(gap, 1));
  }
  // Never decreases. If the projection over-ran the truth, the number simply
  // waits for the truth to catch up rather than snapping backwards.

  setOdometer(hero.shown);
  const root = $('#hero-root', heroWrapEl);
  if (root) root.classList.toggle('stale', !live);
}

/* ------------------------------------------------------------------- live */

const liveState = { snap: null, es: null, key: null, retry: null };
const liveScopeKey = (app) => new URLSearchParams({account:app.state.sub || 'all', source:app.state.chips.source || ''}).toString();

/** matchesChips filters a live session against the current chips. Only the
 *  five dimensions a LiveSession actually carries (endpoint/os_user/cwd/
 *  model/session_id) are checked — branch and team chips do not narrow the
 *  live strip, since a live heartbeat carries neither. */
function matchesChips(s, chips) {
  if (chips.machine && s.endpoint_id !== chips.machine) return false;
  if (chips.login && s.os_user !== chips.login) return false;
  if (chips.project && s.cwd !== chips.project) return false;
  if (chips.model && s.model !== chips.model) return false;
  if (chips.source && (s.source || 'claude') !== chips.source) return false;
  if (chips.session && s.session_id !== chips.session) return false;
  return true;
}

function liveRow(s, app) {
  const where = s.worktree || shortProject(s.cwd) || s.session_id.slice(0, 8);
  const ctx = s.context_unknown ? null : Math.round(s.context_used_pct || 0);
  return el('div', {
      class: 'live-row', role: 'button', tabindex: '0',
      title: 'click to filter by this session',
      onclick: () => app.setState(withChip(app.state, 'session', s.session_id)),
      onkeydown: (e) => { if (e.key === 'Enter') app.setState(withChip(app.state, 'session', s.session_id)); },
    },
    el('div', { class: 'who', title: s.cwd || '' },
      el('b', {
        onclick: (e) => { e.stopPropagation(); app.setState(withChip(app.state, 'project', s.cwd)); },
      }, where), ' ',
      el('span', {}, `${s.source === 'codex' ? 'Codex · recent activity · ' : 'Claude · '}${s.model || '?'}${s.effort ? ' · ' + s.effort : ''} · ${s.endpoint}${s.observed_at ? ' · ' + new Date(s.observed_at).toLocaleTimeString() : ''}`)),
    el('div', { class: 'rate' },
      `${fmtInt((s.input_tokens || 0) + (s.output_tokens || 0))}` +
      (s.tokens_per_min > 0 ? ` · ${fmtInt(Math.round(s.tokens_per_min))}/min` : s.source === 'codex' ? ' · no new tokens' : ' · idle')),
    ctx == null ? el('span', {class:'hint'}, 'context unknown') : el('div', { class: 'ctxbar', title: `context ${ctx}%` },
      el('i', { style: `width:${Math.min(100, ctx)}%` })));
}

function renderLive(snap, app) {
  liveState.snap = snap;
  applyCounter(snap && snap.counter);
  if (snap) snap = selectLive(snap, app.state.chips || {}, app.state.sub);
  const active = snap && snap.active_sessions > 0;

  if (!liveWrapEl.firstChild) {
    liveWrapEl.replaceChildren(el('div', { class: 'live' },
      el('div', { class: 'live-head' },
        el('span', { class: 'pulse', id: 'live-pulse' }),
        el('h2', {}, 'Right now'),
        el('span', { class: 'note', id: 'live-note' }, '')),
      el('div', { class: 'tiles' },
        C.tile('lv-sessions', 'active / recent sessions'),
        C.tile('lv-tpm', 'tokens / min'),
        C.tile('lv-uph', '$ / hour (notional)'),
        C.tile('lv-stok', 'tokens in flight')),
      el('div', { class: 'live-rows', id: 'live-rows' })));
  }

  const pulse = $('#live-pulse', liveWrapEl), note = $('#live-note', liveWrapEl);
  pulse.className = 'pulse' + (active ? '' : ' off');
  note.textContent = active
    ? `${snap.endpoints} endpoint${snap.endpoints === 1 ? '' : 's'} reporting · updates as sessions work`
    : 'No recent activity. Codex uses log observations; Claude uses statusLine heartbeats.';

  if (!snap) return;
  C.tween($('#lv-sessions', liveWrapEl), snap.active_sessions, (v) => String(Math.round(v)));
  C.tween($('#lv-tpm', liveWrapEl), snap.tokens_per_min, (v) => fmtInt(Math.round(v)));
  if (snap.active_sessions > 0 && snap.unpriced_sessions === snap.active_sessions) $('#lv-uph',liveWrapEl).textContent = '—';
  else C.tween($('#lv-uph', liveWrapEl), snap.usd_per_hour, (v) => (snap.unpriced_sessions ? '≥ $' : '$') + v.toFixed(2));
  C.tween($('#lv-stok', liveWrapEl), snap.session_tokens || 0, (v) => fmtInt(Math.round(v)));

  const chips = app.state.chips || {};
  const all = snap.sessions || [];
  const rows = all.filter((s) => matchesChips(s, chips)).slice(0, 8);
  const rowsEl = $('#live-rows', liveWrapEl);
  if (!rows.length) {
    rowsEl.replaceChildren(el('div', { class: 'empty' },
      all.length ? 'No live sessions match the current chips.' : 'no sessions reporting'));
    return;
  }
  rowsEl.replaceChildren(...rows.map((s) => liveRow(s, app)));
}

/** connectLive subscribes to the hub's event stream, falling back to polling
 *  when the stream cannot be held open. Called once (guarded by
 *  `liveStarted` in renderNow, below) — reconnecting on every render would
 *  thrash the connection every time a chip changes or the minute timer fires. */
function connectLive(app) {
  if (liveState.es) liveState.es.close();
  try {
    const key = liveScopeKey(app);
    const es = new EventSource('/v1/live/stream?' + key);
    liveState.es = es;
    es.onmessage = (e) => { if (liveState.es !== es || liveScopeKey(app) !== key) return; try { renderLive(JSON.parse(e.data), app); } catch {} };
    es.onerror = () => {
      // EventSource reconnects on its own; a poll keeps the numbers moving
      // meanwhile rather than freezing on the last frame.
      if (liveState.es !== es) return;
      es.close(); liveState.es = null;
      clearTimeout(liveState.retry); liveState.retry = setTimeout(() => connectLive(app), 5000);
    };
  } catch {
    clearTimeout(liveState.retry); liveState.retry = setTimeout(async () => {
      const key = liveScopeKey(app);
      try { const snap = await app.api('/v1/live?' + key); if (key === liveScopeKey(app)) renderLive(snap, app); } catch {}
      connectLive(app);
    }, 5000);
  }
}

/* ------------------------------------------------------------- wall (Q1) */

// Spec §3.3: wall gauges are per subscription and ignore chips entirely (a
// machine/project/model/etc. chip narrows the OTHER cards; utilization here
// is always the whole subscription's, because that is what the account's
// rate limit actually tracks). chipsIgnoredHint says so, on this card, only
// when there is something to ignore — it would be noise on every load
// otherwise.
function chipsIgnoredHint(chips) {
  if (!chips || !Object.keys(chips).some((k) => k !== 'source')) return null;
  return el('p', { class: 'hint' },
    'Quota follows the selected source and account. Project and machine filters apply to usage details; gauges cover the whole subscription.');
}

function wallCard(limits, chips) {
  // The cross-subscription shape is a LIST, never a total: two pools at 4% and
  // 19% are not 23% of anything.
  if (limits && Array.isArray(limits.per_account)) {
    const card = el('div', { class: 'card' },
      el('h2', {}, 'Am I about to hit the wall?'),
      el('p', { class: 'hint' }, limits.note),
      nowScope.el,
      chipsIgnoredHint(chips));
    if (limits.worst) {
      card.appendChild(el('p', { class: 'hint', style: 'margin-top:-8px' },
        `Closest to its limit: ${limits.worst.label} at ` +
        `${highestQuota(limits.worst.limits).toFixed(1)}%.`));
    }
    for (const entry of limits.per_account) {
      card.appendChild(el('h2', { style: 'margin-top:20px' }, entry.label));
      if (!entry.limits.available) {
        card.appendChild(el('div', { class: 'empty' }, entry.limits.reason || 'No reading available.'));
        continue;
      }
      card.append(...quotaGauges(entry.limits));
    }
    return card;
  }

  const card = el('div', { class: 'card' },
    el('h2', {}, 'Am I about to hit the wall?'),
    el('p', { class: 'hint' },
      'Exact, account-wide, and already covering every device on the subscription.'),
    nowScope.el,
    chipsIgnoredHint(chips));

  if (!limits.available) {
    // No gauge at all. A 0% bar rendered the same as a live one is the failure
    // this project exists to avoid.
    card.appendChild(el('div', { class: 'empty' },
      'No reading available — see the notice above.'));
    return card;
  }

  card.append(...quotaGauges(limits));

  for (const s of limits.scoped || []) {
    if (!s.model && !s.surface) continue;
    card.appendChild(C.gauge(`${s.model || s.surface} · weekly`, s));
  }

  const shares = (limits.endpoint_shares || []).filter((s) => s.weighted_tokens > 0);
  if (shares.length) {
    card.appendChild(el('h2', { style: 'margin-top:24px' }, 'Whose 5-hour window is it'));
    card.appendChild(el('p', { class: 'hint' },
      `Estimated split of the ${limits.five_hour.utilization.toFixed(1)}% above, by weighted spend.`));
    card.appendChild(C.rankedBars(shares.map((s) => ({
      key: s.label || s.endpoint_id,
      value: s.estimated_utilization,
      right: s.estimated_utilization.toFixed(1) + '%',
      tip: `<b>${escapeHTML(s.label || s.endpoint_id)}</b><br>` +
           `${(s.fraction_of_window * 100).toFixed(1)}% of this window's spend<br>` +
           `${fmtFull(s.tokens)} tokens · ${s.events} turns<br>` +
           `<span style="opacity:.7">≈ ${s.estimated_utilization.toFixed(1)}% of the limit (estimate)</span>`,
    }))));
  }
  return card;
}

// wallCardFromResult does NOT delegate a rejected result to queryFailed()
// the way every other card on this view does (Task 15 fix round). Those
// other cards own no persistent state; this one hosts nowScope.el, the
// scope-controls widget Now mounts here (see the module comment above and
// scope.js's createScopeControls) precisely because Now has no span control
// to fall back on -- it is the ONLY place Now can change subscription or
// chips at all. queryFailed()'s error card has no room for it, and
// applyNow()'s replaceChildren() would detach the widget from the live DOM
// along with the rest of the failed card, stranding the viewer with the one
// control that view has. So a rejection here builds its own card, with the
// same h2 and nowScope.el every other branch of wallCard() carries, and
// only the body below them is the error state.
function wallCardFromResult(result, chips) {
  if (result.status === 'rejected') {
    return el('div', { class: 'card' },
      el('h2', {}, 'Am I about to hit the wall?'),
      nowScope.el,
      el('div', { class: 'empty' }, 'Query failed: ' + errMsg(result.reason)));
  }
  return wallCard(result.value, chips);
}

/* --------------------------------------------------------------- alerts */

// /v1/findings's contract (a backend fix landing alongside Review's, task
// 12): the response is an envelope shaped like handleSummary's —
// `{account_uuid, all_accounts, since, until, view, findings: [...]}`, with
// `since`/`until` omitted for `view=now` (which has no meaningful window)
// and `findings` always an array, never null. Read tolerantly regardless:
// if the body is still a bare array (whichever order this and the backend
// fix land in), treat it as the findings list directly.
function alertsCard(result) {
  if (result.status === 'rejected') {
    return el('div', { class: 'card findings' }, el('h2', {}, 'Alerts'),
      el('div', { class: 'empty' }, 'Query failed: ' + errMsg(result.reason)));
  }
  const data = result.value || {};
  const findings = Array.isArray(data) ? data : (data.findings || []);
  // Spec §4 item 1: the Alerts card is hidden when empty, not shown with a
  // reassuring "nothing unusual" message — a healthy fleet should not carry
  // a permanent card at the top of Now. (A rejected query above still shows
  // its own error card; "empty" here means the query succeeded and found
  // nothing, not that it failed.)
  if (!findings.length) return null;
  const card = el('div', { class: 'card findings' }, el('h2', {}, 'Alerts'));
  for (const f of findings) {
    card.appendChild(el('div', { class: 'f' },
      el('span', { class: 'dot ' + (f.severity || 'info') }),
      el('div', {},
        el('div', {}, el('b', {}, f.title)),
        f.detail ? el('div', { class: 'muted' }, f.detail) : null)));
  }
  return card;
}

/* ------------------------------------------------------------------ fleet */

function endpointRosterCard(endpoints, app) {
  const card = el('div', { class: 'card' },
    el('h2', {}, 'Endpoints'),
    el('p', { class: 'hint' },
      'Every machine reporting in, which subscription it is on, and what it could not ' +
      'attribute. An agent that stops reporting is the usual reason a total looks too low.'));

  if (!endpoints.length) {
    card.appendChild(el('div', { class: 'empty' }, 'No endpoints enrolled yet.'));
    return card;
  }
  card.appendChild(el('div', { class: 'scroll' }, el('table', {},
    el('thead', {}, el('tr', {},
      el('th', {}, 'Name'), el('th', {}, 'Subscription'), el('th', {}, 'Platform'),
      el('th', {}, 'Claude Code'), el('th', {}, 'Agent'),
      el('th', {}, 'Last seen'), el('th', {}, 'Excluded'))),
    el('tbody', {}, endpoints.map((e) => {
      const secs = e.last_seen ? (Date.now() - new Date(e.last_seen)) / 1000 : null;
      const stale = secs == null || secs > 600;
      const dropped = (e.dropped_pre_account || 0) + (e.dropped_beyond_backfill || 0);
      return el('tr', {},
        el('td', { title: e.hostname || '' }, e.label || e.endpoint_id),
        el('td', { title: e.account_uuid || '' }, accountLabel(app, e.account_uuid)),
        el('td', {}, e.os ? `${e.os}/${e.arch}` : '—'),
        el('td', {}, e.cc_version || '—'),
        el('td', {}, e.agent_version || '—'),
        el('td', { style: stale ? 'color:var(--ink-3)' : '' },
          secs == null ? 'never reported' : ago(secs)),
        el('td', { style: dropped ? '' : 'color:var(--ink-3)' },
          dropped ? `${fmtInt(dropped)} turns` : '—'));
    })))));
  return card;
}
function endpointRosterCardFromResult(result, app) {
  if (result.status === 'rejected') return queryFailed('Endpoints', result);
  return endpointRosterCard(result.value, app);
}

// Deliberately a list per machine. Claude Code takes its account from the
// process environment, so one machine+login runs several subscriptions at the
// same time; collapsing that into a single "current account" is what used to
// manufacture a switch history out of ordinary concurrency.
function endpointAccountsCard(rows) {
  if (!rows || !rows.length) return null;

  const byEndpoint = new Map();
  for (const r of rows) {
    if (!byEndpoint.has(r.endpoint_id)) byEndpoint.set(r.endpoint_id, []);
    byEndpoint.get(r.endpoint_id).push(r);
  }
  const concurrent = [...byEndpoint.values()].filter((v) => v.length > 1).length;

  const card = el('div', { class: 'card' },
    el('h2', {}, 'What each machine is running'),
    el('p', { class: 'hint' },
      concurrent
        ? `${concurrent} of ${byEndpoint.size} endpoint(s) run more than one subscription at once. ` +
          `That is normal — the account comes from each process's environment, not the machine.`
        : `Each endpoint is running a single subscription.`));

  card.appendChild(el('div', { class: 'scroll' }, el('table', {},
    el('thead', {}, el('tr', {},
      el('th', {}, 'Machine'), el('th', {}, 'Login'), el('th', {}, 'Subscription'),
      el('th', {}, 'How'), el('th', {}, 'First seen'), el('th', {}, 'Last seen'))),
    el('tbody', {}, rows.map((r) => el('tr', {},
      el('td', {}, r.endpoint_name || r.endpoint_id),
      el('td', {}, r.os_user || '—'),
      el('td', { title: r.account_uuid }, r.account_name || r.account_uuid),
      el('td', {}, r.origin === 'login' ? 'its own login' : 'seen in a session'),
      el('td', {}, new Date(r.first_seen).toLocaleString()),
      el('td', {}, new Date(r.last_seen).toLocaleString())))))));
  return card;
}
function endpointAccountsCardFromResult(result) {
  if (result.status === 'rejected') return queryFailed('What each machine is running', result);
  return endpointAccountsCard(result.value);
}

function switchesCard(switches, app, endpoints) {
  if (!switches || !switches.length) return null;

  const card = el('div', { class: 'card' },
    el('h2', {}, 'Subscription switches'),
    el('p', { class: 'hint' },
      'Machines that logged OUT of one subscription and INTO another. Turns recorded ' +
      'before a switch keep their old attribution and cannot be corrected — these are ' +
      'the seams where historical figures stop being reliable. Running several ' +
      'subscriptions side by side is not a switch; see what each machine is running.'));

  const epByID = {};
  for (const e of (endpoints || [])) epByID[e.endpoint_id] = e.label || e.hostname;

  card.appendChild(el('div', { class: 'scroll' }, el('table', {},
    el('thead', {}, el('tr', {},
      el('th', {}, 'When'), el('th', {}, 'Machine'), el('th', {}, 'From'), el('th', {}, 'To'))),
    el('tbody', {}, switches.map((s) => el('tr', {},
      el('td', {}, new Date(s.observed_at).toLocaleString()),
      el('td', {}, epByID[s.endpoint_id] || s.endpoint_id),
      el('td', { title: s.from_account }, accountLabel(app, s.from_account)),
      el('td', { title: s.to_account }, accountLabel(app, s.to_account))))))));
  return card;
}
function switchesCardFromResult(result, app, endpoints) {
  if (result.status === 'rejected') return queryFailed('Subscription switches', result);
  return switchesCard(result.value, app, endpoints);
}

/** fleetCard wraps the three roster tables in a closed-by-default <details>,
 *  its open state remembered per browser. */
function fleetCard(roster, epAccounts, switches) {
  let open = false;
  try { open = localStorage.getItem('ccquota-fleet') === '1'; } catch {}
  const det = el('details', { class: 'fleet', open: open ? '' : false },
    el('summary', {}, 'Fleet'),
    roster, epAccounts, switches);
  det.addEventListener('toggle', () => {
    try { localStorage.setItem('ccquota-fleet', det.open ? '1' : '0'); } catch {}
  });
  return det;
}

/* --------------------------------------------------------------- banners */

function banner(kind, title, msg) {
  return el('div', { class: 'banner' + (kind === 'err' ? ' err' : '') },
    el('span', { class: 'ico' }, kind === 'err' ? '✕' : '!'),
    el('div', { class: 'msg' }, el('b', {}, title + ' '), msg));
}

function buildBanners(state, endpointsR, limitsR) {
  const banners = [];
  const endpoints = endpointsR.status === 'fulfilled' ? endpointsR.value : [];

  // What the agents refused to attribute. A total that quietly excludes
  // history is its own kind of lie, so it is stated before anything else.
  const lossy = endpoints.filter((e) => e.dropped_pre_account > 0 || e.dropped_beyond_backfill > 0);
  for (const e of lossy) {
    const bits = [];
    if (e.dropped_pre_account > 0) {
      bits.push(`${fmtFull(e.dropped_pre_account)} turn(s) older than this subscription` +
        (e.earliest_dropped ? ` (back to ${e.earliest_dropped.slice(0, 10)})` : '') +
        ' — they cannot belong to it, so they are excluded');
    }
    if (e.dropped_beyond_backfill > 0) {
      bits.push(`${fmtFull(e.dropped_beyond_backfill)} turn(s) beyond the ${e.backfill_limit} backfill window`);
    }
    banners.push(banner('warn', `${e.label || e.hostname} excludes history.`, bits.join('; ') + '.'));
  }

  if (state.sub === 'all') {
    // Nothing below is scoped to one subscription; say so once, at the top.
    banners.push(banner('warn', 'Showing all subscriptions.',
      'Tokens are summed across them, and so is each SOURCE\'s cost. Cost is never summed ' +
      'across sources — a Claude figure is an API-equivalent estimate, a gateway figure is a ' +
      'real per-call charge. Rate-limit utilization is not summed either: each subscription is ' +
      'a separate quota pool and is shown separately.'));
  }

  if (limitsR.status === 'fulfilled' && state.sub !== 'all') {
    const limits = limitsR.value;
    if (!limits.available) {
      banners.push(banner('warn', 'Account-wide limits unavailable.',
        (limits.reason || '').replace(/\.?$/, '.') +
        ' The usage totals below are still accurate; only the quota gauges are missing.'));
    } else if (limits.stale_seconds > 600) {
      banners.push(banner('warn', 'Limits reading is stale.',
        `Last read ${ago(limits.stale_seconds)}. An agent may have stopped polling.`));
    }
  }
  return banners;
}

/* ------------------------------------------------------------------- main */

function applyNow(root, state, app, results) {
  const [findingsR, limitsR, endpointsR, epAcctR, switchesR, collectorsR, accountUsageR] = results;

  // scope.js resolves a "machine" chip's label from this on its next render.
  if (endpointsR.status === 'fulfilled') app.endpoints = endpointsR.value;

  $('#banners').replaceChildren(...buildBanners(state, endpointsR, limitsR));

  const endpoints = endpointsR.status === 'fulfilled' ? endpointsR.value : [];
  const fleet = fleetCard(
    endpointRosterCardFromResult(endpointsR, app),
    endpointAccountsCardFromResult(epAcctR),
    switchesCardFromResult(switchesR, app, endpoints));

  // The stray-null bug this guards against: replaceChildren stringifies a
  // bare `null` argument into a literal "null" text node instead of skipping
  // it, so every card here (all of which can legitimately be null-ish only
  // through a future edit) is filtered before it reaches the DOM.
  root.replaceChildren(...[
    alertsCard(findingsR),
    heroWrapEl,
    wallCardFromResult(limitsR, state.chips),
    liveWrapEl,
    collectorsCard(collectorsR, endpoints, app.accounts),
    accountUsageCard(accountUsageR, app.accounts),
    fleet,
  ].filter(Boolean));
}

export function renderNow(root, state, app) {
  const liveKey = liveScopeKey(app);
  if (liveState.key !== liveKey) {
    liveState.key = liveKey; liveState.snap = null;
    hero.anchor = hero.shown = hero.until = hero.perMs = 0;
    wheels.length = 0; heroWrapEl.replaceChildren(); liveWrapEl.replaceChildren();
    clearTimeout(liveState.retry); connectLive(app);
  } else if (liveState.snap) renderLive(liveState.snap, app);

  const acct = encodeURIComponent(state.sub || 'all');
  const source = encodeURIComponent(state.chips.source || '');
  const get = (path) => (signal) => app.api(path, signal);
  const fetchers = [
    get(`/v1/findings?view=now&account=${acct}&source=${source}`),
    get(`/v1/limits?account=${acct}&source=${source}`),
    get(`/v1/endpoints?account=${acct}&source=${source}`),
    get(`/v1/endpoint-accounts?account=${acct}&source=${source}&limit=200`),
    get(`/v1/account-switches?account=${acct}&source=${source}&limit=20`),
    get(`/v1/collectors?account=${acct}&source=${source}`),
    get(`/v1/account-usage?account=${acct}&source=${source}`),
  ];
  return { fetchers, apply: (results) => applyNow(root, state, app, results) };
}
