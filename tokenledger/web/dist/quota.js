// web/dist/quota.js — the quota band: subscription quota, grouped by provider,
// one line per subscription (#153). The card was titled with the question "am I
// about to hit the wall?" until #124; the question is still what it answers, it
// just stopped being printed.
//
// Lifted out of now.js by #95, and the move is the point rather than a tidy-up.
// The card used to be the first child of <details id="ops">, which is SHUT by
// default (app.js's storedOpsOpen: absent key means closed), so the one question
// on this page with a deadline — how much runway is left before work stops —
// was the one question a reader had to go looking for. Measured before the move:
// the default view was 6,998px of ledger, usage and progress, and the quota card
// was not on any of it. Everything else here answers in the past tense.
//
// Three things had to happen together, which is why this is a new module and
// not three edits:
//
//   1. It needed a band of its own (lib/nav.js's SECTIONS, index.html's
//      `data-band="quota"`), because #98 made a band the unit of both mounting
//      and fetching. A card that is "not in the fold" but has no band is a card
//      on every view, fetched on every view.
//   2. It could not take now.js's scope-controls widget with it. That widget was
//      hosted BY this card, which is what the issue calls the entanglement, and
//      it is now a page-level strip app.js owns (index.html's #scopebar).
//   3. Its list had to stop being flat — see quotaGroups in lib/providers.js.
//
// What did NOT change: the shape of /v1/limits, the definition of any window,
// and the rule that utilization is per subscription and never summed. This file
// renders; it does not arithmetic.
import { el, escapeHTML } from './lib/dom.js';
import { fmtFull } from './lib/format.js';
import { quotaGroups, windowName, sourceLabel, hasQuotaWindow } from './lib/providers.js';
import { quotaWindows, blockedBy, isMoot, blockedLast, shortLabel } from './lib/quota-rows.js';
import { SKIPPED } from './lib/seq.js';
import * as C from './charts.js';
import { t } from './lib/i18n.js';

/** A group heading is the provider's name and nothing else (#153).
 *
 *  It used to carry a count ("4 subscriptions") and a vocabulary line ("a fixed
 *  five-hour and seven-day pair"). Both went at the operator's direction: the
 *  subscriptions are right there to be counted, and since every window is now
 *  labelled `5H` / `7D` on its own row, the rows no longer need a sentence to
 *  say which vocabulary they speak. */
function groupHeading(source) {
  return el('div', { class: 'qgroup-head' }, el('span', { class: 'qgroup-name' }, sourceLabel(source)));
}

/** errMsg mirrors now.js's: a rejected fetch says what failed, and an Error
 *  that arrived without a message still says something. */
const errMsg = (reason) => (reason && reason.message) || String(reason || '');

/* --------------------------------------------------------------- one entry */

/** accountEntry is one subscription: its name, then its windows on ONE line.
 *
 *  The line is two cells, shortest window left (a third of the width), longest
 *  right (two thirds) — the week is the one that decides how much work is left,
 *  so it gets the room. A window the account does not have leaves its cell
 *  empty rather than closing the gap, so every row keeps the same columns. A
 *  reading with more than two windows continues on further lines of the same
 *  shape; none does today.
 *
 *  Blocked (#153): the window that has stopped the account shows BLOCKED and
 *  how long until it clears; a shorter window behind it is reduced to its
 *  label, because none of it can be spent until the longer one resets. The row
 *  keeps its height and its columns either way — see charts.js's windowCell.
 *
 *  `.qentry` is the unit the wide layout flows into two lanes (styles.css). */
function accountEntry(entry) {
  const out = [el('div', { class: 'qacct' }, entry.label || entry.account_uuid)];
  const v = entry.limits || {};
  if (!v.available) {
    out.push(el('div', { class: 'qempty' }, v.reason || t('wall.noReading')));
  } else {
    out.push(...windowLines(v));
  }
  return el('div', { class: 'qentry' }, ...out);
}

/** windowLines lays a reading's windows out two to a line. */
function windowLines(v) {
  const ws = quotaWindows(v);
  const blocking = blockedBy(v, ws);
  const credits = creditsText(v);
  const cell = (x) => {
    if (!x) return el('div', { class: 'qcell' });
    const label = shortLabel(x.minutes) || stripProvider(windowName(x.w));
    if (x === blocking) return C.windowCell(label, x.w, { state: 'blocked', extra: credits });
    if (isMoot(x, blocking)) return C.windowCell(label, x.w, { state: 'moot' });
    return C.windowCell(label, x.w);
  };
  // One window: a day or longer sits in the long (right) cell, anything
  // shorter in the short one, so a Codex account reporting only its week lines
  // up under everyone else's 7D.
  const pairs = ws.length === 1
    ? [ws[0].minutes >= 1440 ? [null, ws[0]] : [ws[0], null]]
    : Array.from({ length: Math.ceil(ws.length / 2) }, (_, i) => [ws[2 * i], ws[2 * i + 1]]);
  return pairs.map(([a, b]) => el('div', { class: 'qrow' }, cell(a), cell(b)));
}

/** stripProvider drops windowName's leading "<provider> · " segment. Only the
 *  fallback for a window with no length to abbreviate reaches it now. */
function stripProvider(name) {
  const at = name.indexOf(' · ');
  return at > 0 ? name.slice(at + 3) : name;
}

/** A credit balance, in whole units (#153): "3,866", not "3866.9502100000".
 *  Shown after the BLOCKED capsule, the one place it changes what a reader does
 *  — a blocked Codex account with credits can still be spent. Rounded down, so
 *  it never claims a unit the account does not have. */
function creditsText(v) {
  const c = (v.credits || [])[0];
  if (!c) return '';
  const value = c.unlimited ? t('quota.credits.unlimited')
    : c.balance != null && isFinite(Number(c.balance)) ? Math.floor(Number(c.balance)).toLocaleString()
    : c.has_credits ? t('quota.credits.available') : t('quota.credits.none');
  return t('quota.credits', { value });
}

/* ------------------------------------------------------------------- card */

/** sharesBlock is "whose five-hour window is this", and it exists only on the
 *  single-subscription branch — endpoint_shares apportions ONE account's window
 *  across the machines that spent it, so it has no cross-account form. */
function sharesBlock(v) {
  const shares = (v.endpoint_shares || []).filter((s) => s.weighted_tokens > 0);
  if (!shares.length) return [];
  return [
    el('h2', { class: 'qsub' }, t('wall.whose')),
    C.rankedBars(shares.map((s) => ({
      key: s.label || s.endpoint_id,
      value: s.estimated_utilization,
      right: s.estimated_utilization.toFixed(1) + '%',
      tip: `<b>${escapeHTML(s.label || s.endpoint_id)}</b><br>` +
           `${escapeHTML(t('wall.share.ofWindow', { pct: (s.fraction_of_window * 100).toFixed(1) }))}<br>` +
           `${escapeHTML(t('wall.share.tokens', { tokens: fmtFull(s.tokens), events: s.events }))}<br>` +
           `<span style="opacity:.7">${escapeHTML(t('wall.share.estimate', { pct: s.estimated_utilization.toFixed(1) }))}</span>`,
    }))),
  ];
}

/** quotaCard is the whole card, in the two shapes /v1/limits answers in.
 *
 *  The cross-subscription shape is a LIST, never a total: two pools at 4% and
 *  19% are not 23% of anything. Grouping does not change that — a group is a
 *  heading over a list, and there is deliberately no per-group figure either. */
function quotaCard(result, accounts) {
  const card = el('div', { class: 'card quota-card' }, el('h2', {}, t('wall.title')));

  if (result.status === 'rejected') {
    card.appendChild(el('div', { class: 'empty' },
      t('common.queryFailed', { error: errMsg(result.reason) })));
    return card;
  }
  const limits = result.value;

  if (limits && Array.isArray(limits.per_account)) {
    // ...and it is a list of SUBSCRIPTIONS. /v1/limits answers for every
    // account the hub has ever ingested, gateway callers and vendor invoices
    // included, because that is the right shape for an API consumer. This card
    // lists SUBSCRIPTION quota, and a calling application billed per call has
    // none: it has no ceiling to be near, so a heading over "no reading
    // available" here claimed a gap that does not exist (#50).
    const { groups, metered } = quotaGroups(limits.per_account, accounts);
    const shownSet = new Set(groups.flatMap((g) => g.entries.map((e) => e.account_uuid)));

    // Nothing opens this branch any more. #125 removed the server's "never
    // summed" note, #124 the chips hint, and #153 the last one, "Closest to its
    // limit: …" -- at the operator's direction: a blocked subscription already
    // says so on its own row, and the rest are one glance down the 7D column.
    // `worst` and `note` still ship on the response for API and MCP callers.

    // Filtered down to nothing says something, and it is not the blank the
    // card would otherwise render: every account in view is metered.
    if (!shownSet.size && metered.length) {
      card.appendChild(el('div', { class: 'empty' }, t('wall.meteredOnly')));
    }
    // Blocked subscriptions go to the end of their group, soonest-back first
    // (#153): the ones that can take work are the ones worth reading first. The
    // group itself does not move -- a blocked Claude account stays under Claude.
    for (const g of groups) {
      card.appendChild(el('div', { class: 'qgroup' },
        groupHeading(g.source),
        ...blockedLast(g.entries).map((e) => accountEntry(e))));
    }
    return card;
  }

  // One subscription in scope. No grouping to do — but the group heading stays,
  // because its subtitle is the window vocabulary and a reader looking at a
  // single Codex account needs it at least as much as one comparing five.
  //
  // It is now the FIRST thing under the title: the two hints that stood between
  // them -- "exact, account-wide, covering every device" and the chips-ignored
  // note -- both went with #124, so this branch opens on the reading itself.
  if (!limits.available) {
    // No gauge at all. A 0% bar rendered the same as a live one is the failure
    // this project exists to avoid.
    card.appendChild(el('div', { class: 'empty' }, t('wall.noReadingSeeNotice')));
    return card;
  }

  const source = limits.source || 'claude';
  const heading = hasQuotaWindow(source) ? groupHeading(source) : null;
  const rows = windowLines(limits);
  // A model-scoped weekly window gets a line of its own, named for its model:
  // it is not the account's 5H or 7D and must not sit in either column.
  for (const s of limits.scoped || []) {
    if (!s.model && !s.surface) continue;
    rows.push(el('div', { class: 'qrow qrow-named' },
      C.windowCell(t('quota.scopedWeekly', { name: s.model || s.surface }), s)));
  }
  card.appendChild(el('div', { class: 'qgroup' }, heading, el('div', { class: 'qentry' }, ...rows)));
  card.append(...sharesBlock(limits));
  return card;
}

/** renderQuota draws the band's one card.
 *
 *  `result` is app.js's now-loader slot for /v1/limits (now.js's LIMITS_INDEX),
 *  not a fetch of its own: the same response feeds the two limits banners, which
 *  are not in any band, so asking twice would be one request spent to render
 *  what is already in hand. Same arrangement the ledger headline has with
 *  review.js's summary. */
export function renderQuota(root, result, app) {
  // A SKIPPED slot is a question nobody asked, not an answer of "nothing" — the
  // distinction lib/seq.js's SKIPPED exists to make. The mount point being on
  // the page should mean the request went out (app.js gates both on the same
  // `shown` set), so this is the line that keeps a future edit from making them
  // disagree by drawing "no readings" about a fetch that never happened. Leave
  // whatever is already here; the next load redraws it.
  if (!result || result.status === SKIPPED) return;
  root.replaceChildren(quotaCard(result, app.accounts));
}
