// web/dist/quota.js — the quota band: "am I about to hit the wall?", grouped by
// provider, with the current utilization as the biggest number on the card.
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
import { quotaGroups, quotaSourceOf, sourceMap, windowName, sourceLabel, hasQuotaWindow } from './lib/providers.js';
import { SKIPPED } from './lib/seq.js';
import * as C from './charts.js';
import { t } from './lib/i18n.js';

/** The vocabulary line under each group heading.
 *
 *  This is the whole reason the card is grouped rather than sorted. Claude and
 *  Codex do not report a quota in the same terms — Claude has a fixed five-hour
 *  and seven-day pair, Codex reports whatever windows its provider names plus a
 *  credit balance — and in one flat list the reader had to infer which
 *  vocabulary each row was speaking from the row itself. Said once per group, it
 *  costs one line and every row under it can stop explaining itself.
 *
 *  Keyed by source with a fallback rather than a lookup that can miss: a source
 *  added to QUOTA_SOURCES with no note here gets a heading and no subtitle,
 *  which is a missing sentence rather than a missing group. */
const GROUP_NOTE = { claude: 'quota.group.claude.note', codex: 'quota.group.codex.note' };

function groupHeading(source, count) {
  const note = GROUP_NOTE[source];
  return el('div', { class: 'qgroup-head' },
    el('span', { class: 'qgroup-name' }, sourceLabel(source)),
    el('span', { class: 'qgroup-count' },
      t(count === 1 ? 'quota.group.count.one' : 'quota.group.count.other', { n: count })),
    note ? el('span', { class: 'qgroup-note' }, t(note)) : null);
}

/** errMsg mirrors now.js's: a rejected fetch says what failed, and an Error
 *  that arrived without a message still says something. */
const errMsg = (reason) => (reason && reason.message) || String(reason || '');

/* --------------------------------------------------------------- one entry */

/** accountRows is one subscription: its name, then one row per window, then
 *  whatever its provider adds that is not a window (a credit balance, a blocked
 *  flag, the plan and observation time).
 *
 *  The non-window notes stay `.hint`s rather than becoming rows because they are
 *  not readings of a pool — a credit balance has no ceiling to be a percentage
 *  of, and rendering it at the weight of a utilization would put the card's
 *  biggest number on something that cannot fill up. */
function accountRows(entry, { showSource } = {}) {
  const out = [el('div', { class: 'qacct' }, entry.label || entry.account_uuid)];
  const v = entry.limits || {};
  if (!v.available) {
    out.push(el('div', { class: 'qempty' }, v.reason || t('wall.noReading')));
    return out;
  }
  out.push(...windowRows(v, { showSource }));
  out.push(...extraNotes(v));
  return out;
}

/** windowRows turns one reading into gauge rows, in the provider's own terms.
 *
 *  `showSource` controls exactly one thing: whether a Codex window keeps
 *  "Codex · " in its own name. lib/providers.js's windowName prefixes the
 *  limit's provider, which a row needs when it stands alone and does not when
 *  it sits under a heading that has just said it. So the caller passes whether
 *  it drew a heading, rather than which branch it is — both branches draw one
 *  now, and tying this to "am I the grouped branch" is how the single-
 *  subscription view ended up printing "Codex · 7-day window" three lines under
 *  the word "Codex". */
function windowRows(v, { showSource } = {}) {
  const rows = [];
  if (v.windows) {
    for (const w of v.windows) {
      const full = windowName(w);
      rows.push(C.gauge(showSource ? full : stripProvider(full), w));
    }
  } else {
    if (v.five_hour) rows.push(C.gauge(t('quota.fiveHour'), v.five_hour));
    if (v.seven_day) rows.push(C.gauge(t('quota.sevenDay'), v.seven_day));
  }
  return rows;
}

/** stripProvider drops windowName's leading "<provider> · " segment.
 *
 *  Done here, on the rendered string, rather than by giving windowName a flag:
 *  that function is the one place this build names a window and it is asserted
 *  on directly (web/test/providers.test.mjs), so the group's redundancy is the
 *  group's problem to solve. Falls through to the whole string when there is no
 *  separator, so a provider that stops prefixing loses nothing. */
function stripProvider(name) {
  const at = name.indexOf(' · ');
  return at > 0 ? name.slice(at + 3) : name;
}

/** extraNotes is everything a reading carries that is not a window: credits,
 *  the blocked flag, and Codex's plan/observation footer. Ported from the
 *  quotaGauges this file replaces, unchanged in content. */
function extraNotes(v) {
  const out = [];
  for (const c of v.credits || []) {
    out.push(el('p', { class: 'hint qnote' }, t('quota.credits', {
      id: c.limit_id,
      value: c.unlimited ? t('quota.credits.unlimited')
        : c.balance != null ? c.balance
        : c.has_credits ? t('quota.credits.available') : t('quota.credits.none'),
    })));
  }
  if (v.blocked) {
    out.push(el('p', { class: 'hint qnote' },
      t('quota.blocked', { reason: v.reason || t('quota.blocked.reported') })));
  }
  if (v.source === 'codex') {
    out.push(el('p', { class: 'hint qnote' }, t('quota.codexNote', {
      plan: v.plan || t('quota.codexAccount'),
      when: v.observed_at ? new Date(v.observed_at).toLocaleString() : t('common.unknownTime'),
    })));
  }
  return out;
}

/* ------------------------------------------------------------------- card */

// Spec §3.3: quota gauges are per subscription and ignore chips entirely (a
// machine/project/model/etc. chip narrows the OTHER cards; utilization here
// is always the whole subscription's, because that is what the account's
// rate limit actually tracks). chipsIgnoredHint says so, on this card, only
// when there is something to ignore — it would be noise on every load
// otherwise.
function chipsIgnoredHint(chips) {
  if (!chips || !Object.keys(chips).some((k) => k !== 'source')) return null;
  return el('p', { class: 'hint' }, t('wall.chipsIgnored'));
}

/** worstLine names the subscription closest to its ceiling — and, since #95,
 *  which provider it is.
 *
 *  The provider is not decoration. On this hub one person's Claude and Codex
 *  subscriptions share an email, so "closest to its limit: verky.yi@gmail.com at
 *  100.0%" named a row that appears TWICE on the card and did not say which of
 *  the two it meant. Now that the card is grouped, the line has to say which
 *  group to look in or it points at two places at once.
 *
 *  Still only rendered when the named subscription survived the shown/metered
 *  filter: "closest to its limit: X" naming a heading the viewer cannot find is
 *  worse than no line at all. */
function worstLine(worst, shownSet, sourceOf) {
  if (!worst || !shownSet.has(worst.account_uuid)) return null;
  return el('p', { class: 'hint' }, t('wall.closest', {
    label: worst.label,
    source: sourceLabel(quotaSourceOf(worst, sourceOf)),
    pct: highest(worst.limits).toFixed(1),
  }));
}

/** highest is api.LimitsView.HighestUtilization, in the render layer: the one
 *  number that stands for a reading with several windows. Blocked counts as
 *  full, the same way the Go side counts it. */
function highest(v) {
  if (v?.blocked) return 100;
  return Math.max(v?.five_hour?.utilization || 0, ...(v?.windows || []).map((w) => w.utilization));
}

/** sharesBlock is "whose five-hour window is this", and it exists only on the
 *  single-subscription branch — endpoint_shares apportions ONE account's window
 *  across the machines that spent it, so it has no cross-account form. */
function sharesBlock(v) {
  const shares = (v.endpoint_shares || []).filter((s) => s.weighted_tokens > 0);
  if (!shares.length) return [];
  return [
    el('h2', { class: 'qsub' }, t('wall.whose')),
    el('p', { class: 'hint' }, t('wall.whoseHint', { pct: v.five_hour.utilization.toFixed(1) })),
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
function quotaCard(result, chips, accounts) {
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
    // included, because that is the right shape for an API consumer. This
    // card's title is a question, and a calling application billed per call is
    // not one of its answers: it has no ceiling to be near, so a heading over
    // "no reading available" here claimed a gap that does not exist (#50).
    const { groups, metered } = quotaGroups(limits.per_account, accounts);
    const sourceOf = sourceMap(accounts);
    const shownSet = new Set(groups.flatMap((g) => g.entries.map((e) => e.account_uuid)));

    // .filter(Boolean), and it is not defensive padding: append() stringifies a
    // bare `null` argument into a literal "null" TEXT NODE rather than skipping
    // it, and chipsIgnoredHint returns null on every load with no chips -- which
    // is most of them. Caught in the browser on the first render of this card,
    // where it printed "null" between the note and the closest-to-its-limit
    // line. now.js carries the same guard, with the same note, for the same
    // reason.
    card.append(...[el('p', { class: 'hint' }, limits.note), chipsIgnoredHint(chips)].filter(Boolean));
    const worst = worstLine(limits.worst, shownSet, sourceOf);
    if (worst) card.appendChild(worst);

    // Filtered down to nothing says something, and it is not the blank the
    // card would otherwise render: every account in view is metered.
    if (!shownSet.size && metered.length) {
      card.appendChild(el('div', { class: 'empty' }, t('wall.meteredOnly')));
    }
    for (const g of groups) {
      card.appendChild(el('div', { class: 'qgroup' },
        groupHeading(g.source, g.entries.length),
        ...g.entries.flatMap((e) => accountRows(e))));
    }
    return card;
  }

  // One subscription in scope. No grouping to do — but the group heading stays,
  // because its subtitle is the window vocabulary and a reader looking at a
  // single Codex account needs it at least as much as one comparing five.
  card.append(...[el('p', { class: 'hint' }, t('wall.exact')), chipsIgnoredHint(chips)].filter(Boolean));

  if (!limits.available) {
    // No gauge at all. A 0% bar rendered the same as a live one is the failure
    // this project exists to avoid.
    card.appendChild(el('div', { class: 'empty' }, t('wall.noReadingSeeNotice')));
    return card;
  }

  const source = limits.source || 'claude';
  const heading = hasQuotaWindow(source) ? groupHeading(source, 1) : null;
  const rows = [...windowRows(limits, { showSource: !heading })];
  for (const s of limits.scoped || []) {
    if (!s.model && !s.surface) continue;
    rows.push(C.gauge(t('quota.scopedWeekly', { name: s.model || s.surface }), s));
  }
  card.appendChild(el('div', { class: 'qgroup' }, heading, ...rows, ...extraNotes(limits)));
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
export function renderQuota(root, result, state, app) {
  // A SKIPPED slot is a question nobody asked, not an answer of "nothing" — the
  // distinction lib/seq.js's SKIPPED exists to make. The mount point being on
  // the page should mean the request went out (app.js gates both on the same
  // `shown` set), so this is the line that keeps a future edit from making them
  // disagree by drawing "no readings" about a fetch that never happened. Leave
  // whatever is already here; the next load redraws it.
  if (!result || result.status === SKIPPED) return;
  root.replaceChildren(quotaCard(result, state.chips, app.accounts));
}
