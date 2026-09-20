import { collectorsCard, accountUsageCard, selectLive, liveUnknown } from './providers.js';
// web/dist/now.js — the live half: hero odometer, live strip, the banners, and
// the operations tier's collector/roster/switch tables.
//
// It no longer draws the quota gauges. #95 moved that card to
// web/dist/quota.js and gave it a band; this file still SENDS the /v1/limits
// request (LIMITS_INDEX), because the limits banners it does draw read the same
// response.
//
// hero (applyCounter/pacSVG/dotStream/the odometer wheels/tickHero),
// renderLive, connectLive, endpointRosterCard and the lossy/spanning/stale
// banners are ported from the old <script> block of web/dist/index.html
// (pre-Task-11), unchanged except for the structural moves the Task 11 brief
// calls for:
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
//
// #100 then collapsed those three fleet tables into ONE, so the second bullet
// above describes a <details> that no longer exists. "What each machine is
// running" and "Subscription switches" were both keyed by endpoint_id, and so
// is the roster — three tables about one subject, two of them costing a request
// each to say something the third had room for. They are columns of the roster
// now (subscriptionCell / switchCell), and with a single table left the
// <details class="fleet"> wrapper went with them: it existed to group three
// cards, and #ops is already the fold.
import { el, $ } from './lib/dom.js';
import { fmtInt, fmtFull, shortProject, ago, windowOf } from './lib/format.js';
import { withChip } from './lib/state.js';
import { ownerLine, splitMuted } from './lib/findings.js';
import { muteControls } from './lib/mute.js';
import * as C from './charts.js';
import { t, withLocale } from './lib/i18n.js';

// This file used to own the page's second scope-controls widget, mounted on
// the "Am I about to hit the wall?" card because that card is per-subscription
// by definition. #95 moved both: the card is its own band (web/dist/quota.js)
// and the widget is the page's, mounted in the shell by app.js (#scopebar).
// The widget was never really Now's -- it was the page's, hosted by whatever
// card happened to be on screen -- and #98 proved it by leaving two views with
// no scope control at all.

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
    el('div', { class: 'empty' }, t('common.queryFailed', { error: errMsg(result.reason) })));
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
    // A BADGE, not a hero.
    //
    // This counter used to open the page at up to 40px with a 1.7em animated
    // character, under a full-width caption row. It is a lifetime token total:
    // it never goes down, it is not a bill, and nothing is decided by it — so
    // being the largest and liveliest thing on a ledger earned it attention no
    // other figure could compete with. Shrunk to one line, it still answers
    // "is the fleet moving" at a glance, which is the only question it was ever
    // good for.
    //
    // The caption moves inside the badge and shortens; the part that names the
    // scope moves to the title, because it repeats what the scope controls
    // directly above already say.
    //
    // #96 moved the badge again -- out of <main> and into the sticky top bar --
    // and shortened the caption to one word for it. The title is untouched and
    // has to stay untouched: it is where the figure's whole definition lives
    // (what is counted, over which scope and span, and that it is projected),
    // and a badge in a bar has room for a label, not for a definition.
    heroWrapEl.replaceChildren(el('div', {
      class: 'hero', id: 'hero-root',
      title: t('hero.title'),
    },
      el('div', { class: 'tm' }, pacSVG(), dotStream(),
        el('div', { class: 'odo', id: 'hero-odo' },
          // The tilde is the whole honesty marker: this figure is projected
          // between measurements and is not exact. One character, always present.
          el('span', { class: 'tilde' }, '~')),
        el('span', { class: 'k' }, t('hero.caption')))));
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

const liveState = { snap: null, es: null, key: null, retry: null, pending: false };
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
      title: t('live.row.filterTip'),
      onclick: () => app.setState(withChip(app.state, 'session', s.session_id)),
      onkeydown: (e) => { if (e.key === 'Enter') app.setState(withChip(app.state, 'session', s.session_id)); },
    },
    el('div', { class: 'who', title: s.cwd || '' },
      el('b', {
        onclick: (e) => { e.stopPropagation(); app.setState(withChip(app.state, 'project', s.cwd)); },
      }, where), ' ',
      el('span', {}, `${s.source === 'codex' ? t('live.row.codexPrefix') : t('live.row.claudePrefix')}${s.model || '?'}${s.effort ? ' · ' + s.effort : ''} · ${s.endpoint}${s.observed_at ? ' · ' + new Date(s.observed_at).toLocaleTimeString() : ''}`)),
    el('div', { class: 'rate' },
      `${fmtInt((s.input_tokens || 0) + (s.output_tokens || 0))}` +
      (s.tokens_per_min > 0 ? ` · ${fmtInt(Math.round(s.tokens_per_min))}/min` : ' · ' + (s.source === 'codex' ? t('live.row.noNewTokens') : t('live.row.idle')))),
    ctx == null ? el('span', {class:'hint'}, t('live.row.contextUnknown')) : el('div', { class: 'ctxbar', title: t('live.row.contextTip', { pct: ctx }) },
      el('i', { style: `width:${Math.min(100, ctx)}%` })));
}

// Blanks a tile back to its placeholder and forgets the value tween would
// otherwise animate away from — without that, the first real reading would
// count up from a number that was never on screen.
function tileUnknown(node) {
  if (!node) return;
  delete node.dataset.v;
  node.textContent = '—';
}

function renderLive(snap, app) {
  liveState.snap = snap;
  applyCounter(snap && snap.counter);
  if (snap) snap = selectLive(snap, app.state.chips || {}, app.state.sub);
  const unknown = liveUnknown(snap);
  const active = !unknown && snap && snap.active_sessions > 0;

  if (!liveWrapEl.firstChild) {
    liveWrapEl.replaceChildren(el('div', { class: 'live' },
      el('div', { class: 'live-head' },
        el('span', { class: 'pulse', id: 'live-pulse' }),
        el('h2', {}, t('live.title')),
        el('span', { class: 'note', id: 'live-note' }, '')),
      // "Active" is a claim with a threshold inside it, and until now the page
      // made the claim without ever stating the threshold. The number comes
      // from the server on every snapshot rather than being restated here, so
      // the sentence cannot drift from the rule that produced the count.
      el('p', { class: 'hint', id: 'live-window' }, ''),
      el('div', { class: 'tiles' },
        // No "$ / hour": the live tiles describe subscription work, whose
        // per-hour dollar figure was an API-equivalent estimate of money nobody
        // is charged. Tokens per minute answers the same question ("how fast is
        // this burning") in the unit that is actually being consumed.
        C.tile('lv-sessions', t('live.tile.sessions')),
        C.tile('lv-tpm', t('live.tile.tpm')),
        C.tile('lv-stok', t('live.tile.inflight'))),
      el('div', { class: 'live-rows', id: 'live-rows' })));
  }

  const pulse = $('#live-pulse', liveWrapEl), note = $('#live-note', liveWrapEl);
  pulse.className = 'pulse' + (active ? '' : ' off');
  const upFor = unknown ? sinceStart(snap) : null;
  note.textContent = unknown
    ? (upFor == null ? t('live.coldNoTime') : t('live.cold', { ago: ago(upFor) }))
    : active
      ? t(snap.endpoints === 1 ? 'live.reporting.one' : 'live.reporting.other', { n: snap.endpoints })
      : t('live.noActivity');

  const windowEl = $('#live-window', liveWrapEl);
  if (windowEl) {
    windowEl.textContent = snap && snap.active_window_sec
      ? t('live.window', { window: windowOf(snap.active_window_sec) })
      : '';
  }

  if (!snap) return;

  const sessionsEl = $('#lv-sessions', liveWrapEl);
  const tpmEl = $('#lv-tpm', liveWrapEl), stokEl = $('#lv-stok', liveWrapEl);
  if (unknown) {
    // All three tiles come from the same nothing, so all three say so. Leaving
    // tokens/min at 0 beside an unknown session count would read as "nothing is
    // burning", which is the same unmeasured claim one column over.
    [sessionsEl, tpmEl, stokEl].forEach(tileUnknown);
  } else {
    C.tween(sessionsEl, snap.active_sessions, (v) => String(Math.round(v)));
    C.tween(tpmEl, snap.tokens_per_min, (v) => fmtInt(Math.round(v)));
    C.tween(stokEl, snap.session_tokens || 0, (v) => fmtInt(Math.round(v)));
  }

  const chips = app.state.chips || {};
  const all = snap.sessions || [];
  const rows = all.filter((s) => matchesChips(s, chips)).slice(0, 8);
  const rowsEl = $('#live-rows', liveWrapEl);
  if (!rows.length) {
    rowsEl.replaceChildren(el('div', { class: 'empty' },
      unknown ? t('live.coldRows') : all.length ? t('live.noMatch') : t('live.noSessions')));
    return;
  }
  rowsEl.replaceChildren(...rows.map((s) => liveRow(s, app)));
}

/** sinceStart is how long this hub's live store has been up, in seconds — the
 *  age of its ignorance while `ever_reported` is false. Null-safe because a
 *  hub predating the field sends no `started_at`, and "for a while" is a better
 *  answer there than "NaN seconds ago". */
function sinceStart(snap) {
  const t0 = snap && snap.started_at ? new Date(snap.started_at).getTime() : NaN;
  if (!isFinite(t0)) return null;
  return Math.max(0, (Date.now() - t0) / 1000);
}

/** connectLive subscribes to the hub's event stream, falling back to polling
 *  when the stream cannot be held open. Called once per scope (guarded by
 *  `liveState.key` in renderNow, below) — reconnecting on every render would
 *  thrash the connection every time a chip changes or the minute timer fires. */
function connectLive(app) {
  if (liveState.es) liveState.es.close();
  try {
    const key = liveScopeKey(app);
    const es = new EventSource(withLocale('/v1/live/stream?' + key));
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

/* ------------------------------------------------------- moved out: quota */

// The "am I about to hit the wall?" card lived here, from Task 11 until #95.
// It is web/dist/quota.js now, and it is its own band rather than the first
// child of the operations fold.
//
// What stayed behind is the REQUEST. /v1/limits is still fetched by this file's
// loader (LIMITS_INDEX below), because the same response also feeds the two
// limits banners in buildBanners, which are not in any band -- so the fetch
// cannot follow the card without either duplicating the request or making the
// banners depend on a band being mounted. app.js hands the slot to
// renderQuota, the same way it hands review.js's summary slot to renderSpend.
/* --------------------------------------------------------------- alerts */

// /v1/findings's contract (a backend fix landing alongside Review's, task
// 12): the response is an envelope shaped like handleSummary's —
// `{account_uuid, all_accounts, since, until, view, findings: [...]}`, with
// `since`/`until` omitted for `view=now` (which has no meaningful window)
// and `findings` always an array, never null. Read tolerantly regardless:
// if the body is still a bare array (whichever order this and the backend
// fix land in), treat it as the findings list directly.
function alertsCard(result, app) {
  if (result.status === 'rejected') {
    return el('div', { class: 'card findings' }, el('h2', {}, t('alerts.title')),
      el('div', { class: 'empty' }, t('common.queryFailed', { error: errMsg(result.reason) })));
  }
  const data = result.value || {};
  const findings = Array.isArray(data) ? data : (data.findings || []);
  // Spec §4 item 1: the Alerts card is hidden when empty, not shown with a
  // reassuring "nothing unusual" message — a healthy fleet should not carry
  // a permanent card at the top of Now. (A rejected query above still shows
  // its own error card; "empty" here means the query succeeded and found
  // nothing, not that it failed.)
  if (!findings.length) return null;
  const { live, muted } = splitMuted(findings);
  // A card of nothing but silenced alerts is still worth showing -- that IS
  // the state of the fleet, and hiding it would make a muted alert look
  // resolved. But it must not sit at the top of Now looking urgent, so the
  // fold below stays closed and the heading says how many.
  const card = el('div', { class: 'card findings' }, el('h2', {}, t('alerts.title')));
  for (const f of live) card.appendChild(alertRow(f, app));
  if (muted.length) card.appendChild(mutedTail(muted, app));
  return card;
}

function alertRow(f, app) {
  // A stale agent is the alert this matters most to: "go make the agent on
  // that machine live again" is useless without a name attached, and the hub
  // knows it. An alert with no owner (a hot rate-limit window belongs to a
  // subscription, not a person) simply prints no such line.
  const owner = ownerLine(f);
  return el('div', { class: 'f' },
    el('span', { class: 'dot ' + (f.severity || 'info') }),
    el('div', {},
      el('div', {}, el('b', {}, f.title)),
      f.detail ? el('div', { class: 'muted' }, f.detail) : null,
      owner ? el('div', { class: 'owner' }, owner) : null,
      muteControls(f, app)));
}

// mutedTail folds the silenced alerts away without deleting them. <details>,
// not a class that hides them: it is the one collapse the platform gives a
// keyboard and a screen reader for free, and the summary states the count so
// the fold is readable while closed.
function mutedTail(muted, app) {
  const d = el('details', { class: 'muted-tail' },
    el('summary', {}, t('findings.mutedCount', { n: muted.length })));
  for (const f of muted) d.appendChild(alertRow(f, app));
  return d;
}

/* ------------------------------------------------------------------ fleet */

// STALE_ENDPOINT_SEC is the one definition of "this machine has gone quiet".
//
// It mirrors internal/findings/findings.go's StaleAfter, which is what raises
// the stale_agent alert. This table used to dim a row after 600s while that
// alert waited an hour, so the same endpoint could be greyed out here and
// unremarkable in the Alerts card directly above it — two thresholds for one
// word, on one page. web/dist has no build step and cannot import the Go
// constant, so web/embed_test.go asserts this literal still matches it.
//
// Not the live card's window: that one is about a SESSION's heartbeat, it is
// minutes rather than an hour, and the card states it (see renderLive). Nor the
// limits banner's 600s, which ages a rate-limit reading, not an endpoint.
const STALE_ENDPOINT_SEC = 3600;

/** lastSwitchByEndpoint reduces the switch log to the NEWEST switch per machine.
 *
 *  The server sends them newest first, but this compares timestamps rather than
 *  trusting that order: a column that silently showed a machine's OLDEST switch
 *  would be worse than no column at all, and the cost of not depending on it is
 *  one comparison. */
function lastSwitchByEndpoint(switches) {
  const m = new Map();
  for (const s of switches || []) {
    const prev = m.get(s.endpoint_id);
    if (!prev || new Date(s.observed_at) > new Date(prev.observed_at)) m.set(s.endpoint_id, s);
  }
  return m;
}

/** switchCell is the roster's "last switch" column — the attribution seam,
 *  printed on the machine the seam runs through.
 *
 *  This used to be a resident card of its own ("Subscription switches"). It was
 *  never wrong, it just had nowhere to lead: there is no action attached to a
 *  switch and no way to repair one, because rows ingested before it keep their
 *  old attribution for good (README's "Known limits"). So it is not deleted and
 *  must not be — a seam the page hides is a page that is quietly wrong — but it
 *  does not earn a card and a table. As a column it is strictly easier to read
 *  than it was: the switch now sits on the row of the machine it happened to,
 *  instead of in a separate table that repeated the machine's name to say so. */
function switchCell(sw, app) {
  if (!sw) return el('span', { style: 'color:var(--ink-3)' }, '—');
  const secs = Math.max(0, (Date.now() - new Date(sw.observed_at)) / 1000);
  const from = accountLabel(app, sw.from_account), to = accountLabel(app, sw.to_account);
  return el('div', { title: `${new Date(sw.observed_at).toLocaleString()} · ${from} → ${to}` },
    el('div', {}, ago(secs)),
    el('div', { class: 'muted' }, `${from} → ${to}`));
}

/** subscriptionCell is the roster's "subscription" column.
 *
 *  Closed (`accounts` null) it prints the endpoint's OWN login, which is the one
 *  account /v1/endpoints carries. Opened, it prints every subscription that
 *  machine has been SEEN running — the list that used to be the card "what each
 *  machine is running".
 *
 *  Deliberately a list, and deliberately not a switch. Claude Code takes its
 *  account from each process's environment, not from the machine, so one machine
 *  routinely runs several subscriptions at the same instant and "the current
 *  account" is a value that does not exist. Collapsing the list into one is what
 *  would manufacture a switch history out of ordinary concurrency — which is
 *  exactly why this column and the switch column beside it are different
 *  questions and are never merged. */
function subscriptionCell(e, app, accounts) {
  const own = accountLabel(app, e.account_uuid);
  const rows = accounts ? accounts.get(e.endpoint_id) : null;
  if (!rows || !rows.length) return el('span', { title: e.account_uuid || '' }, own);
  return el('div', {}, rows.map((r) => {
    // accountLabel falls back to the uuid for a subscription the page has no
    // /v1/accounts row for; the endpoint-accounts row carries its own name, so
    // prefer that over printing a raw uuid at the reader.
    const l = accountLabel(app, r.account_uuid);
    return el('div', { title: r.account_uuid },
      l === r.account_uuid ? (r.account_name || r.account_uuid) : l, ' ',
      el('span', { class: 'muted' },
        r.origin === 'login' ? t('endpoints.ownLogin') : t('endpoints.seenInSession')));
  }));
}

// rosterTable is the roster's rows on their own, so the "show retired" and
// "show subscriptions" toggles can swap them without rebuilding the card's
// headings around them.
//
// A retired endpoint is greyed out and says when it was retired in the
// "last seen" column's place, because for a retired endpoint that is the
// honest answer: it is not late reporting, it is not coming back.
//
// `view.switches` is a Map or null, and null means the column is not drawn at
// all — see endpointRosterCard for why "no switch has happened here" is a
// column that should not exist rather than a column full of dashes.
function rosterTable(endpoints, app, view) {
  const seam = view.switches;
  return el('div', { class: 'scroll' }, el('table', {},
    el('thead', {}, el('tr', {},
      el('th', {}, t('endpoints.col.name')), el('th', {}, t('endpoints.col.subscription')), el('th', {}, t('endpoints.col.platform')),
      el('th', {}, t('endpoints.col.cc')), el('th', {}, t('endpoints.col.agent')),
      el('th', {}, t('endpoints.col.lastSeen')),
      seam ? el('th', {}, t('endpoints.col.lastSwitch')) : null,
      el('th', {}, t('endpoints.col.excluded')))),
    el('tbody', {}, endpoints.map((e) => {
      const secs = e.last_seen ? (Date.now() - new Date(e.last_seen)) / 1000 : null;
      const stale = secs == null || secs > STALE_ENDPOINT_SEC;
      const dropped = (e.dropped_pre_account || 0) + (e.dropped_beyond_backfill || 0);
      const retired = !!e.retired_at;
      return el('tr', retired ? { class: 'retired' } : {},
        el('td', { title: e.hostname || '' }, e.label || e.endpoint_id),
        el('td', {}, subscriptionCell(e, app, view.accounts)),
        el('td', {}, e.os ? `${e.os}/${e.arch}` : '—'),
        el('td', {}, e.cc_version || '—'),
        el('td', {}, e.agent_version || '—'),
        el('td', { style: stale || retired ? 'color:var(--ink-3)' : '' },
          retired
            ? t('endpoints.retiredOn', { date: new Date(e.retired_at).toLocaleDateString() })
            : secs == null ? t('endpoints.neverReported') : ago(secs)),
        seam ? el('td', {}, switchCell(seam.get(e.endpoint_id), app)) : null,
        el('td', { style: dropped ? '' : 'color:var(--ink-3)' },
          dropped ? t('endpoints.droppedTurns', { n: fmtInt(dropped) }) : '—'));
    }))));
}

/** endpointRosterCard lists the fleet, hiding retired endpoints behind a
 *  toggle.
 *
 *  Hidden by DEFAULT because that is the whole point of retiring one: a
 *  machine that was decommissioned should stop being something an operator has
 *  to recognise and dismiss every time they read the roster. Shown on request
 *  because "where did it go" is the next question, and a row that vanished
 *  with no way back is how you get someone opening the database.
 *
 *  The toggle is built like the ⊞ table toggle in charts.js and for the same
 *  reasons: `aria-expanded` says which state it is in and is rewritten on
 *  every click, and `aria-controls` points at the table it swaps. The retired
 *  rows are fetched lazily, on first reveal — the page's own roster fetch
 *  stays active-only, so `app.endpoints`, the scope picker's machine chips and
 *  the lossy-history banner keep meaning "the live fleet".
 *
 *  Since #100 there are TWO such toggles, built the same way for the same
 *  reasons. The second one reveals the per-machine subscription list, and it is
 *  lazy for a sharper reason than the first: making it lazy is what took
 *  /v1/endpoint-accounts off the operations tier's default path. It used to be
 *  sent on every open to fill a resident card answering a question ("which
 *  subscriptions does this machine run") that matters when you are chasing a
 *  specific machine and never otherwise. A request nobody reads is the cost;
 *  a click is the price of reading it. */
function endpointRosterCard(endpoints, app, state, switchesR) {
  // A rejected switch query and an empty one are NOT the same answer, and the
  // difference is the whole reason this page shows switches at all. Empty means
  // "no machine in scope has switched", which is information. Rejected means the
  // seam could not be read — and a seam that is silently absent is precisely the
  // failure README's "Known limits" says this page exists to prevent.
  const seamOK = switchesR.status === 'fulfilled';
  const switches = seamOK ? (switchesR.value || []) : [];
  // Drawn only when a switch has actually happened in scope. The old card did
  // the same thing by rendering null when empty; as a column it costs a column
  // of dashes instead of a card, so the same rule is worth keeping.
  const seam = switches.length ? lastSwitchByEndpoint(switches) : null;

  const card = el('div', { class: 'card' },
    el('h2', {}, t('endpoints.title')),
    el('p', { class: 'hint' }, t('endpoints.hint')),
    el('p', { class: 'hint' }, t('endpoints.staleHint', { window: windowOf(STALE_ENDPOINT_SEC) })),
    seam ? el('p', { class: 'hint' }, t('endpoints.switchHint')) : null,
    seamOK ? null : el('p', { class: 'hint' }, t('endpoints.switchUnavailable')));

  if (!endpoints.length) {
    card.appendChild(el('div', { class: 'empty' }, t('endpoints.empty')));
    return card;
  }

  // The two reveals are independent, and either can be on while the other
  // flips, so both read one redraw rather than each rebuilding the table from
  // its own idea of the current state.
  let retired = false, withRetired = null;
  let subs = false, byEndpoint = null;
  const view = () => ({ switches: seam, accounts: subs ? byEndpoint : null });
  const body = rosterTable(endpoints, app, view());
  body.id = 'endpoint-roster';
  const redraw = () => body.replaceChildren(
    ...rosterTable(retired && withRetired ? withRetired : endpoints, app, view()).childNodes);

  const scope = () => {
    const acct = encodeURIComponent((state && state.sub) || 'all');
    const source = encodeURIComponent((state && state.chips && state.chips.source) || '');
    return `account=${acct}&source=${source}`;
  };

  const retiredBtn = el('button', {
    class: 'tbl', type: 'button',
    title: t('endpoints.showRetired'),
    'aria-label': t('endpoints.showRetired'),
    'aria-expanded': 'false',
    'aria-controls': body.id,
    onclick: async () => {
      retired = !retired;
      retiredBtn.setAttribute('aria-expanded', String(retired));
      if (retired && withRetired === null) {
        try {
          withRetired = await app.api(`/v1/endpoints?${scope()}&include=retired`);
        } catch {
          // A failed reveal must not leave the button claiming it is showing
          // something it is not.
          withRetired = null;
          retired = false;
          retiredBtn.setAttribute('aria-expanded', 'false');
          return;
        }
      }
      redraw();
    },
  }, '⊟');

  const subsBtn = el('button', {
    class: 'tbl', type: 'button',
    title: t('endpoints.showAccounts'),
    'aria-label': t('endpoints.showAccounts'),
    'aria-expanded': 'false',
    'aria-controls': body.id,
    onclick: async () => {
      subs = !subs;
      subsBtn.setAttribute('aria-expanded', String(subs));
      if (subs && byEndpoint === null) {
        try {
          const rows = await app.api(`/v1/endpoint-accounts?${scope()}&limit=200`);
          byEndpoint = new Map();
          for (const r of rows || []) {
            if (!byEndpoint.has(r.endpoint_id)) byEndpoint.set(r.endpoint_id, []);
            byEndpoint.get(r.endpoint_id).push(r);
          }
        } catch {
          byEndpoint = null;
          subs = false;
          subsBtn.setAttribute('aria-expanded', 'false');
          return;
        }
      }
      redraw();
    },
  }, '⊞');

  // One anchored row, not two absolutely-positioned buttons: `.card .tbl` pins
  // itself to the card's top right, so a second one would land exactly on the
  // first. See styles.css's `.card .tbls`.
  card.append(el('div', { class: 'tbls' }, subsBtn, retiredBtn), body);
  return card;
}
function endpointRosterCardFromResult(result, app, state, switchesR) {
  if (result.status === 'rejected') return queryFailed(t('endpoints.title'), result);
  return endpointRosterCard(result.value, app, state, switchesR);
}

// Two cards and a fold used to live here, and #100 removed all three.
//
// "What each machine is running" (/v1/endpoint-accounts) and "Subscription
// switches" (/v1/account-switches) were tables keyed by endpoint_id, sitting
// beside a roster keyed by endpoint_id. Each repeated the machine's name to say
// which machine it was talking about, and each cost a request on every open of
// the operations tier. Neither was WRONG, which is why neither was simply
// deleted: they are the roster's "subscription" and "last switch" columns now,
// and the one request that is still unconditional is the one that draws a
// column (switches). The subscription list moved behind the roster's ⊞, which
// is what took its request off the default path.
//
// The <details class="fleet"> around them went too. It grouped three cards; one
// card is not a group, and #ops is already the fold — a fold inside a fold, with
// its own heading above the card's own heading, was asking the reader to open
// two doors to reach one table.

/* --------------------------------------------------------------- banners */

/** No banner here is closable, and none should be: every one of them reports
 *  something that is currently WRONG (history excluded, a limits reading
 *  unavailable or stale) and goes away by being fixed, so a close button would
 *  hide a fault rather than acknowledge a caveat.
 *
 *  There used to be one exception — the all-subscriptions caveat, a STANDING
 *  condition, which is why #92 gave banners a dismiss key and localStorage
 *  (lib/dismiss.js) to remember it in. #125 deleted that banner: it said, at
 *  the top of the screen, what the quota card said seventy lines further down
 *  in the same viewport. The whole dismissal mechanism left with it, since it
 *  had arrived for that banner alone and had no second caller. */
function banner(kind, title, msg) {
  return el('div', { class: 'banner' + (kind === 'err' ? ' err' : '') },
    el('span', { class: 'ico' }, kind === 'err' ? '✕' : '!'),
    el('div', { class: 'msg' }, el('b', {}, title + ' '), msg));
}

/** limitsBannerApplies is the ONE predicate for "a banner outside the fold
 *  needs /v1/limits". renderNow reads it to decide whether to send that
 *  request at all while the operations tier is closed, and buildBanners reads
 *  the same one to decide whether to draw the banner -- written once so the
 *  two cannot drift into "fetched but never read", or worse, "read but never
 *  fetched".
 *
 *  Nothing below is scoped to one subscription when sub is 'all', so neither
 *  limits banner has anything to say; the wall gauges that DO read this result
 *  live inside the fold. */
const limitsBannerApplies = (state) => state.sub !== 'all';

function buildBanners(state, endpointsR, limitsR) {
  const banners = [];
  const endpoints = endpointsR.status === 'fulfilled' ? endpointsR.value : [];

  // What the agents refused to attribute. A total that quietly excludes
  // history is its own kind of lie, so it is stated before anything else.
  const lossy = endpoints.filter((e) => e.dropped_pre_account > 0 || e.dropped_beyond_backfill > 0);
  for (const e of lossy) {
    const bits = [];
    if (e.dropped_pre_account > 0) {
      bits.push(t('banner.droppedPreAccount', {
        n: fmtFull(e.dropped_pre_account),
        range: e.earliest_dropped ? t('banner.backTo', { date: e.earliest_dropped.slice(0, 10) }) : '',
      }));
    }
    if (e.dropped_beyond_backfill > 0) {
      bits.push(t('banner.droppedBeyondBackfill', { n: fmtFull(e.dropped_beyond_backfill), window: e.backfill_limit }));
    }
    banners.push(banner('warn', t('banner.excludesHistory', { name: e.label || e.hostname }), bits.join('; ') + '.'));
  }

  // "Nothing below is scoped to one subscription" used to be stated here too,
  // as a dismissible warn banner. Gone (#125) -- not because the claim stopped
  // being true, but because one screenful said it twice: the quota card opened
  // with the server's `note` from the same /v1/limits response, seventy lines
  // down and still above the fold, on the same trigger (account=all). Two
  // identical warnings in one viewport teach a reader to skip both, so the
  // pair went together; quota.js is where the second one was.
  //
  // The claim itself is not lost: the per-subscription gauges ARE the shape of
  // "these do not add up", and /v1/limits still carries `note` for the API and
  // MCP callers that have no gauges to look at.

  if (limitsR.status === 'fulfilled' && limitsBannerApplies(state)) {
    const limits = limitsR.value;
    if (!limits.available) {
      banners.push(banner('warn', t('banner.limitsUnavailable.title'),
        t('banner.limitsUnavailable.body', { reason: (limits.reason || '').replace(/\.?$/, '.') })));
    } else if (limits.stale_seconds > 600) {
      banners.push(banner('warn', t('banner.limitsStale.title'),
        t('banner.limitsStale.body', { ago: ago(limits.stale_seconds) })));
    }
  }
  return banners;
}

/* ------------------------------------------------------------------- main */

function applyNow(root, state, app, results, opsOpen) {
  // limitsR still lands here even though no card in this file draws it: the two
  // limits banners do, and they are in no band (see NEEDED's row 1).
  const [findingsR, limitsR, endpointsR, switchesR, collectorsR, accountUsageR] = results;

  // scope.js resolves a "machine" chip's label from this on its next render.
  if (endpointsR.status === 'fulfilled') app.endpoints = endpointsR.value;

  $('#banners').replaceChildren(...buildBanners(state, endpointsR, limitsR));

  const endpoints = endpointsR.status === 'fulfilled' ? endpointsR.value : [];
  const roster = endpointRosterCardFromResult(endpointsR, app, state, switchesR);

  // The stray-null bug this guards against: replaceChildren stringifies a
  // bare `null` argument into a literal "null" text node instead of skipping
  // it, so every card here (all of which can legitimately be null-ish only
  // through a future edit) is filtered before it reaches the DOM.
  // Alerts mount ABOVE the tiers, not inside this one. Everything else here is
  // operational detail that the page now folds away by default, and an alert
  // inside a fold is an alert nobody sees.
  const alerts = alertsCard(findingsR, app);
  const alertsRoot = $('#alerts');
  if (alertsRoot) alertsRoot.replaceChildren(...(alerts ? [alerts] : []));

  // The token badge mounts in the top BAR, not in this (folded) block — #96
  // moved #pulse out of <main> and into <header id="scope">. The lookup is
  // document-wide and always was, so nothing here changes: what matters is that
  // #pulse is still written in the shell, which is what makes it a mount point
  // this module's own state can be reset around (renderNow clears heroWrapEl on
  // a scope change; it never unmounts it).
  const pulseRoot = $('#pulse');
  if (pulseRoot && heroWrapEl.parentNode !== pulseRoot) pulseRoot.replaceChildren(heroWrapEl);

  // Everything above this line is drawn from the three requests that go out
  // whatever the fold is doing, and it draws into #alerts, #pulse and #banners
  // -- which belong to no band and are therefore on EVERY view (index.html says
  // why). Everything below reads a result that was only ASKED FOR when the
  // operations tier is live (see renderNow's NEEDED table) -- so with the tier
  // closed we stop here rather than hand a card a SKIPPED slot and have it
  // print "no readings" about a question nobody asked. Cards already in the DOM
  // from a previous open stay as they are, invisible; the next open re-fetches
  // and redraws them.
  //
  // `root` is #status, and since #98 it is null whenever the operations band is
  // not mounted at all. Checked as well as `opsOpen` rather than instead of it:
  // the two cannot currently disagree (app.js derives both from one `shown` set
  // computed after the mount), and this is the line that keeps a later edit
  // from making them disagree silently.
  if (!opsOpen || !root) return;

  root.replaceChildren(...[
    liveWrapEl,
    collectorsCard(collectorsR, endpoints, app.accounts),
    accountUsageCard(accountUsageR, app.accounts),
    roster,
  ].filter(Boolean));
}

/** LIMITS_INDEX is the /v1/limits slot in the fetcher list below.
 *
 *  Exported because the response is read by THREE things that live in three
 *  different places: this file's limits banners (no band), web/dist/quota.js's
 *  card (the quota band), and nothing in the operations fold any more. app.js
 *  is where those are reassembled, so it needs the position by name rather than
 *  by a `1` that silently means something else after the next insertion. Same
 *  pattern, and the same reason, as review.js's SUMMARY_INDEX. */
export const LIMITS_INDEX = 1;

/** NEEDED says, per fetcher position below, whether that request has anything
 *  to render RIGHT NOW. `shown` is app.js's live-band set.
 *
 *  This file's six requests do not all serve one band, which is the whole
 *  reason this table exists rather than a flat "skip them all when the fold is
 *  shut": three of them are the only source for things that belong to NO band
 *  and are therefore on every view, and deferring those would trade a fast first
 *  screen for a page that is quietly wrong about itself.
 *
 *    0  findings         -> #alerts, which floats above the tiers on purpose
 *                           (applyNow says why: an alert inside a fold is an
 *                           alert nobody sees)
 *    1  limits           -> the QUOTA BAND's card (#95) AND the two limits
 *                           banners, which are in no band -- see
 *                           limitsBannerApplies. It used to be "the wall gauges
 *                           inside the fold", and moving that card out of the
 *                           fold is exactly why this row no longer mentions ops
 *                           at all: the operations tier reads nothing from it.
 *    2  endpoints        -> #banners' lossy-history warning (no band), and
 *                           app.endpoints, which scope.js reads for a machine
 *                           chip's label and review.js for its group-by
 *    3  account-switches \  the roster's "last switch" column, the collector
 *    4  collectors       |  card and the account-usage card -- all inside the
 *    5  account-usage    /  fold and nowhere else
 *
 *  There were seven until #100. /v1/endpoint-accounts was slot 3, and it is not
 *  in this table any more because it is no longer sent from here at all: the
 *  roster's ⊞ fetches it on demand (endpointRosterCard). A request that only
 *  ever filled a card the reader had to go looking for does not belong on the
 *  path that every open of the operations tier pays for.
 */
const NEEDED = [
  () => true,
  (shown, state) => shown.has('quota') || limitsBannerApplies(state),
  () => true,
  (shown) => shown.has('ops'),
  (shown) => shown.has('ops'),
  (shown) => shown.has('ops'),
];

export function renderNow(root, state, app, shown) {
  const liveKey = liveScopeKey(app);
  if (liveState.key !== liveKey) {
    liveState.key = liveKey; liveState.snap = null;
    hero.anchor = hero.shown = hero.until = hero.perMs = 0;
    wheels.length = 0; heroWrapEl.replaceChildren(); liveWrapEl.replaceChildren();
    // Armed here, opened by startLive() below. The stream used to be opened on
    // this line, synchronously, from inside the first route() -- which put a
    // connection that is then held for the whole session into the middle of the
    // first screen's burst, on a protocol that allows six per origin.
    clearTimeout(liveState.retry); liveState.pending = true;
  } else if (liveState.snap) renderLive(liveState.snap, app);

  const acct = encodeURIComponent(state.sub || 'all');
  const source = encodeURIComponent(state.chips.source || '');
  const get = (path) => (signal) => app.api(path, signal);
  const fetchers = [
    get(`/v1/findings?view=now&account=${acct}&source=${source}`),
    get(`/v1/limits?account=${acct}&source=${source}`),
    get(`/v1/endpoints?account=${acct}&source=${source}`),
    get(`/v1/account-switches?account=${acct}&source=${source}&limit=20`),
    get(`/v1/collectors?account=${acct}&source=${source}`),
    get(`/v1/account-usage?account=${acct}&source=${source}`),
  ].map((f, i) => (NEEDED[i](shown, state) ? f : null));
  const opsOpen = shown.has('ops');
  return { fetchers, apply: (results) => applyNow(root, state, app, results, opsOpen) };
}

/** startLive opens the event stream, and app.js calls it AFTER the first
 *  screen's fetches have settled rather than renderNow calling it before they
 *  start.
 *
 *  Deferred, but NOT gated on the operations fold, and the difference matters:
 *  the stream feeds the live strip inside the fold *and* the lifetime token
 *  badge in #pulse, which is not in the fold at all -- it is the page's one
 *  ambient "is the fleet still moving" signal, and folded away it answers
 *  nothing. So what this removes is the stream competing with the first screen
 *  for one of six connections, not the badge itself. The badge's first frame
 *  lands about one round trip later than it used to.
 *
 *  That last sentence became load-bearing at #96, which moved #pulse into the
 *  sticky top bar: a badge arriving a round trip late is a badge arriving after
 *  the page has been laid out against the bar it now lives in, and that bar's
 *  height is --navh (scope.js's navHeight), the offset everything the page
 *  scrolls to lands against. Handled where it belongs rather than here: the
 *  badge is sized not to change the bar's height at all (styles.css's
 *  `.scope #pulse`), with #98's ResizeObserver on the bar as the net. Deferring
 *  the stream stays the right call; it is just no longer free of consequences
 *  elsewhere. */
export function startLive(app) {
  if (!liveState.pending) return;
  liveState.pending = false;
  connectLive(app);
}
