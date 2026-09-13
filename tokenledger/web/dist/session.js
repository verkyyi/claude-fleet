// web/dist/session.js — the session detail overlay (Task 13).
//
// app.js calls renderDetail(root, state, app) on every route() while
// state.session is set (regardless of which view — now or review — is
// underneath), and closeDetail(root) otherwise. That means this module gets
// re-invoked on EVERY hash change while the panel is open, not just the one
// that opened it: switching a chip, the span, or the subscription while the
// panel is open all re-run renderDetail with the same session id. So a fetch
// is only re-issued when the (session, account) pair actually changes (see
// `key` below), and the Esc key / × button always act on the LATEST state —
// captured in the module-level `curState`/`curApp`, not whatever `state` was
// in scope when a button was built — otherwise closing after an unrelated
// state change (e.g. removing a chip while the panel is open) would silently
// revert that change.
//
// Data shape read from internal/api/review.go's handleSession and
// internal/store/rollup_query.go's SessionRow/Turn (read-only, sibling
// worktree — see task-13-report.md): GET /v1/sessions/<id>?account=<sub>
// returns `{session: SessionRow, turns: [Turn], pruned: bool}`. SessionRow's
// `tokens` is SUM(input+output+cache_read+cache_create) — thinking_tokens is
// deliberately NOT part of a token total anywhere in the backend
// (internal/store/query.go's tokenColumnsExpr) — so turnTokens() below sums
// the same four fields per turn, for the same reason cache_create is one
// field: Turn.CacheCreateTokens is already cache_create_5m + cache_create_1h
// collapsed server-side (rollup_query.go's SessionTurns query).
import { el } from './lib/dom.js';
import { fmtInt, fmtUSD, fmtCost, fmtFull, fmtPct, fmtDur, shortProject } from './lib/format.js';
import { KIND_LABEL, kindOf } from './lib/cost.js';
import * as C from './charts.js';

/* ------------------------------------------------------------------ state */

// `loadKey` is "<sessionId>|<account>" for whatever data is loaded or
// in-flight; closeDetail resets it to null so the next open always refetches
// (a stale skeleton is never reused across a close/reopen).
let loadKey = null;
let controller = null;
// The element focus should return to on close: whatever had focus right
// before the panel opened (almost always the sessions-table row that was
// clicked). Captured once per closed->open transition.
let lastFocus = null;
// Read by the Esc handler and by every close button, always the most recent
// renderDetail() call's arguments — see the module comment above.
let curState = null;
let curApp = null;
let escBound = false;

function closeNow() {
  curApp.setState({ ...curState, session: null });
}

function bindEscOnce(root) {
  if (escBound) return;
  escBound = true;
  addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !root.hidden) closeNow();
  });
}

/* --------------------------------------------------------------- helpers */

/** accountLabel mirrors now.js's own (server's email/display_name/uuid
 *  precedence) so the panel never disagrees with the scope bar's switcher. */
function accountLabel(app, uuid) {
  if (!uuid) return '—';
  const a = (app.accounts || []).find((x) => x.account_uuid === uuid);
  if (!a) return uuid;
  return a.email || a.display_name || a.account_uuid;
}

function sessionDuration(s) {
  const ms = new Date(s.ended) - new Date(s.started);
  return Number.isFinite(ms) && ms > 0 ? fmtDur(ms) : '—';
}

// Same four fields SessionRow.Tokens sums server-side — see module comment.
function turnTokens(t) {
  return (t.input_tokens || 0) + (t.output_tokens || 0) + (t.cache_read_tokens || 0) + (t.cache_create_tokens || 0);
}

function closeButton() {
  return el('button', { class: 'close', type: 'button', 'aria-label': 'Close', onclick: closeNow }, '×');
}

function errMsg(err) {
  return (err && err.message) || String(err);
}

/* ---------------------------------------------------------------- header */

function headerNodes(s, app) {
  // A session's rollup row is scoped to ONE source, so its cost_usd is a
  // single kind of money -- but which kind changes what the number means, so
  // the tile says so rather than hardcoding "notional" as it used to.
  const kind = KIND_LABEL[s.cost_kind || kindOf(s.source)] || 'notional';
  const spendTile = C.kpiTile({
    label: `spend (${kind})`,
    value: fmtCost(s),
  });
  spendTile.title = [
    kind === 'billed'
      ? 'Billed per call: this figure is an actual charge, not an API-equivalent estimate.'
      : 'Notional: what these tokens would have cost at API rates. The subscription is what is actually billed.',
    s.unpriced_events > 0
      ? `${fmtFull(s.unpriced_events)} event(s) in this session have no price data — spend is a lower bound.`
      : null,
  ].filter(Boolean).join('\n\n');

  return [
    closeButton(),
    el('h2', { title: s.cwd || '' }, shortProject(s.cwd)),
    el('p', { class: 'hint' },
      `${s.os_user || '?'}@${s.endpoint || s.endpoint_id || '?'} · ${accountLabel(app, s.account_uuid)} · `,
      // title lists every model seen (SessionRow.Models, most tokens first),
      // same split review.js's session row already uses for its Model cell.
      el('span', { title: (s.models || []).join(', ') }, s.model || '—'),
      ` · started ${s.started ? new Date(s.started).toLocaleString() : '—'}`),
    el('div', { class: 'kpis' },
      C.kpiTile({ label: 'duration', value: sessionDuration(s) }),
      C.kpiTile({ label: 'turns', value: fmtFull(s.turns) }),
      C.kpiTile({ label: 'tokens', value: fmtInt(s.tokens) }),
      spendTile,
      C.kpiTile({ label: 'cache hit', value: fmtPct(s.cache_hit || 0) }),
      C.kpiTile({ label: 'subagent share', value: fmtPct(s.sidechain_share || 0) })),
  ];
}

/* ------------------------------------------------------------------ body */

function turnRow(t) {
  return el('tr', {},
    el('td', {}, new Date(t.ts).toLocaleTimeString()),
    el('td', {}, t.model || '—'),
    el('td', {}, t.effort || '—'),
    el('td', { class: 'num' }, fmtFull(t.input_tokens || 0)),
    el('td', { class: 'num' }, fmtFull(t.output_tokens || 0)),
    el('td', { class: 'num' }, fmtFull(t.cache_read_tokens || 0)),
    el('td', { class: 'num' }, fmtFull(t.cache_create_tokens || 0)),
    el('td', { class: 'num' }, fmtFull(t.thinking_tokens || 0)),
    // Turn.CostUSD is a Go *float64 — null means "no price data for this
    // model/tier at this time", which is a different fact from "$0.00" and
    // must not collapse into it (kpisCard/spendTile above make the same
    // distinction at the session level via unpriced_events).
    el('td', { class: 'num' }, t.cost_usd == null ? '—' : fmtUSD(t.cost_usd)),
    el('td', {}, t.is_sidechain ? '✓' : ''));
}

// FIX (execution review, minor): a large session (one real example ran
// 3,643 turns) rendered every one as its own <tr> with no cap at all —
// C.turnBars() below stays uncapped on purpose (it's one SVG, cheap
// regardless of turn count), but the table is real DOM nodes and a
// multi-thousand-row table is exactly the kind of thing this app already
// refuses to do everywhere else (the sessions table caps at 50 with "load
// more", breakdown cards cap at 12 with "show all"). TURN_PAGE caps the
// table the same way — except, unlike sessions' "load more", ALL of a
// session's turns are already in memory from the one /v1/sessions/<id>
// fetch (there is no turns-pagination endpoint), so "load more" here just
// reveals more of what's already local rather than issuing a new request.
const TURN_PAGE = 200;

function turnsTable(turns) {
  const tbody = el('tbody', {}, turns.slice(0, TURN_PAGE).map(turnRow));
  const table = el('div', { class: 'scroll' }, el('table', {},
    el('thead', {}, el('tr', {},
      el('th', {}, 'Time'), el('th', {}, 'Model'), el('th', {}, 'Effort'),
      el('th', { class: 'num' }, 'Input'), el('th', { class: 'num' }, 'Output'),
      el('th', { class: 'num' }, 'Cache read'), el('th', { class: 'num' }, 'Cache create'),
      el('th', { class: 'num' }, 'Thinking'), el('th', { class: 'num' }, '$'), el('th', {}, 'Sub'))),
    tbody));

  const moreWrap = el('div', {});
  let shown = Math.min(TURN_PAGE, turns.length);
  const drawMore = () => {
    moreWrap.replaceChildren();
    if (shown >= turns.length) return;
    moreWrap.appendChild(el('a', {
      href: '#', style: 'display:inline-block;margin-top:10px',
      onclick: (e) => {
        e.preventDefault();
        const next = turns.slice(shown, shown + TURN_PAGE);
        tbody.append(...next.map(turnRow));
        shown += next.length;
        drawMore();
      },
    }, `load more (${turns.length - shown} left)`));
  };
  drawMore();

  return el('div', {}, table, moreWrap);
}

function bodyNode(turns, pruned) {
  const wrap = el('div', {});
  wrap.appendChild(el('h2', { style: 'margin-top:20px' }, `Model requests (${fmtFull(turns.length)})`));
  const details = turns.find(t => t.details)?.details;
  if (details) {
    wrap.appendChild(el('p', {class:'hint'}, `${details.model_provider || 'provider unknown'} · client ${details.client_version || 'unknown'} · ${details.billing_mode || 'billing unknown'} · account: ${(details.account_basis || 'unassigned').replaceAll('_',' ')}`));
    const bases = [...new Set(turns.map(t => t.details?.price_basis).filter(Boolean))];
    wrap.appendChild(el('p', {class:'hint'}, bases.join(' · ')));
  }
  if (pruned) {
    wrap.appendChild(el('div', { class: 'empty' }, 'Turns older than the retention window are gone.'));
    return wrap;
  }
  if (!turns.length) {
    wrap.appendChild(el('div', { class: 'empty' }, 'No turns recorded.'));
    return wrap;
  }

  const chartTurns = turns.map((t) => ({
    tokens: turnTokens(t), model: t.model, sidechain: t.is_sidechain,
    ts: t.ts, effort: t.effort, cost_usd: t.cost_usd,
  }));
  wrap.appendChild(C.turnBars(chartTurns));

  wrap.appendChild(turnsTable(turns));
  if (details) wrap.appendChild(el('details', {}, el('summary', {}, 'Request provenance and cache writes'),
    el('div', {}, turns.slice(-100).map(t => el('p', {class:'hint'}, `${t.request_id || 'legacy request'} · turn ${t.details?.turn_id || 'unknown'} · root ${t.details?.root_turn_id || 'unknown'} · cache writes ${t.details?.cache_write_input_tokens == null ? 'unknown' : fmtInt(t.details.cache_write_input_tokens)} · tier ${t.details?.service_tier || 'not recorded'}`)))));
  return wrap;
}

/* ------------------------------------------------------------------- main */

function refocusClose(root) {
  const t = root.querySelector('.close');
  if (t) t.focus();
}

function renderSkeleton(root) {
  root.replaceChildren(closeButton(), el('div', { class: 'empty' }, 'Loading…'));
}

// FIX (review, Finding 1): the previous version checked
// `document.activeElement === document.body` AFTER replaceChildren() and
// treated that as proof the panel's own DOM removal had stripped focus. It
// isn't proof — `.detail` is a non-modal side drawer with no backdrop, so
// the rest of Review stays clickable while a fetch is in flight, and a
// click on any non-focusable patch of that page (e.g. a card's padding)
// ALSO leaves activeElement on body. That made the panel steal focus back
// to its close button exactly when data arrived, even though the user had
// deliberately clicked away. Fixed by checking a fact instead of guessing
// from the aftermath: capture whether focus was actually inside the panel
// BEFORE the mutation that might rip it out, and only restore it in that
// case. If focus was already elsewhere (or nowhere) at that moment, it is
// left alone.
function renderError(root, err) {
  const hadFocus = root.contains(document.activeElement);
  root.replaceChildren(closeButton(), el('div', { class: 'empty' }, 'Query failed: ' + errMsg(err)));
  if (hadFocus) refocusClose(root);
}

function renderLoaded(root, data, app) {
  const hadFocus = root.contains(document.activeElement);
  const s = data.session || {};
  root.replaceChildren(...headerNodes(s, app), bodyNode(data.turns || [], !!data.pruned));
  if (hadFocus) refocusClose(root);
}

export function renderDetail(root, state, app) {
  curState = state;
  curApp = app;
  root.setAttribute('aria-label', 'Session detail');
  bindEscOnce(root);

  const justOpened = root.hidden;
  if (justOpened) {
    lastFocus = document.activeElement;
    root.hidden = false;
  }

  const key = state.session + '|' + (state.sub || 'all') + '|' + (state.chips.source || '');
  if (key !== loadKey) {
    loadKey = key;
    if (controller) controller.abort();
    const ctrl = new AbortController();
    controller = ctrl;
    renderSkeleton(root);
    const acct = encodeURIComponent(state.sub || 'all');
    app.api(`/v1/sessions/${encodeURIComponent(state.session)}?account=${acct}&source=${encodeURIComponent(state.chips.source || '')}`, ctrl.signal)
      .then((data) => { if (ctrl === controller) renderLoaded(root, data, app); })
      .catch((err) => {
        if (ctrl !== controller || (err && err.name === 'AbortError')) return;
        renderError(root, err);
      });
  }

  // Only steal focus on the actual closed->open transition — switching to a
  // different session while the panel is already open must not yank focus
  // away from wherever the user currently is (e.g. the row they just
  // clicked, which is `lastFocus`'s new value on the NEXT open anyway).
  if (justOpened) refocusClose(root);
}

// isRendered is "is this actually laid out right now", not just "does it
// exist in the DOM": offsetParent is null for an element that is
// display:none OR has a display:none/hidden ancestor, which is exactly the
// state of review.js's non-active sessions-table row shape (see
// fallbackFocusTarget below) — a plain querySelector match on the other one
// says nothing about whether .focus() will actually do anything.
function isRendered(el) {
  return !!el && el.offsetParent !== null;
}

// FIX (review, Finding 2): the old fallback selector was
// `#sessions tbody tr[role="button"]`, which querySelector happily finds
// even when it is not the thing actually on screen: review.js renders the
// sessions table as `<tr>` rows on desktop and `.srow` cards on mobile
// (styles.css's `@media (max-width:720px)` swap hides one via display:none),
// and the whole `#review` subtree carries `hidden` when the panel was
// opened while `view=now` (app.js's route()). Either way the old code
// handed `.focus()` a node it could not actually focus, so the `||`
// fallback to `#sessions` never fired and focus silently stayed on
// <body> — reachable only via a deep link straight to `#/<view>/session/
// <id>`, where there is no prior click for `lastFocus` to hold. Checking
// isRendered() at each step picks whichever candidate is genuinely on
// screen, so `.focus()` on it actually works.
function fallbackFocusTarget() {
  const row = document.querySelector('#sessions tbody tr[role="button"]');
  if (isRendered(row)) return row;
  const card = document.querySelector('#sessions .srow');
  if (isRendered(card)) return card;
  const panelCard = document.getElementById('sessions');
  if (isRendered(panelCard)) return panelCard;
  return document.body;
}

// focusEl gives a non-interactive container (`#sessions`, or the
// document.body last resort above) a temporary tabindex so it can actually
// receive focus, the same trick already used for the sessions-card fallback
// before this fix existed.
function focusEl(el) {
  if (!el) return;
  if (!el.hasAttribute('tabindex') && el.tabIndex < 0) el.setAttribute('tabindex', '-1');
  el.focus();
}

export function closeDetail(root) {
  if (root.hidden) return;
  if (controller) { controller.abort(); controller = null; }
  loadKey = null;
  root.hidden = true;
  root.replaceChildren();

  const target = (lastFocus && document.contains(lastFocus) && isRendered(lastFocus))
    ? lastFocus
    : fallbackFocusTarget();
  lastFocus = null;
  focusEl(target);
}
