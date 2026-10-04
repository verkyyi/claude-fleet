// web/dist/lib/quota-rows.js — which windows a quota reading has, which one has
// stopped the account, and the order the card lists subscriptions in (#153).
//
// Pure: no DOM, no i18n. quota.js renders; this decides. It is its own module
// so the three rules the card turns on can be asserted without a browser.

/** A window's short name: `5H`, `7D`. Whole days first, then whole hours, then
 *  minutes — the same precedence lib/providers.js's windowName uses for the long
 *  form, so the two never disagree about what a window is called. */
export function shortLabel(minutes) {
  const n = Number(minutes);
  if (!n) return '';
  if (n % 1440 === 0) return `${n / 1440}D`;
  if (n % 60 === 0) return `${n / 60}H`;
  return `${n}M`;
}

/** quotaWindows lists a reading's windows, shortest first.
 *
 *  The two shapes /v1/limits answers in collapse here: Claude's fixed
 *  `five_hour` / `seven_day` pair, and the `windows` list Codex reports. Giving
 *  Claude's pair their minutes is what lets one rule — "shortest on the left" —
 *  lay out both, instead of a branch per provider. */
export function quotaWindows(v) {
  if (!v) return [];
  const out = Array.isArray(v.windows)
    ? v.windows.map((w) => ({ minutes: Number(w.minutes) || 0, w }))
    : [
        v.five_hour && { minutes: 300, w: v.five_hour },
        v.seven_day && { minutes: 10080, w: v.seven_day },
      ].filter(Boolean);
  return out.sort((a, b) => a.minutes - b.minutes);
}

const resetMs = (x) => Date.parse(x?.w?.resets_at) || 0;

/** blockedBy names the window that has stopped this account, or null.
 *
 *  Blocked is EITHER a window at or past 100% OR the provider saying so, and it
 *  has to be both. Only Codex sends `blocked`: Claude reports its windows and
 *  nothing else, so a card that trusted the flag alone printed a Claude account
 *  with a full seven-day window as "5-hour 0% healthy" — usable-looking, and
 *  unable to send a single token.
 *
 *  When more than one window is full, the one that resets LAST is the answer:
 *  the account is usable again only once every lock is open. When the provider
 *  says blocked but no window reads 100%, the fullest window is the best
 *  available guess at which one it means, the later reset breaking a tie. */
export function blockedBy(v, windows = quotaWindows(v)) {
  if (!v || !windows.length) return null;
  let hit = windows.filter((x) => Number(x.w.utilization) >= 100);
  if (!hit.length) {
    if (!v.blocked) return null;
    const top = Math.max(...windows.map((x) => Number(x.w.utilization) || 0));
    hit = windows.filter((x) => (Number(x.w.utilization) || 0) === top);
  }
  return hit.reduce((a, b) => (resetMs(b) > resetMs(a) ? b : a));
}

/** A window that cannot matter until the blocking one clears: shorter than it.
 *  With the seven-day window full, how soon the five-hour one refills changes
 *  nothing — none of it can be spent. A LONGER window than the blocking one
 *  still does (a full five-hour window refills into whatever the week has
 *  left), so it keeps its reading. */
export const isMoot = (x, blocking) => !!blocking && x !== blocking && x.minutes < blocking.minutes;

/** Blocked subscriptions last, soonest-back first; everyone else keeps the
 *  order they came in. Stable, so a group with nothing blocked is untouched. */
export function blockedLast(entries) {
  const at = (e) => {
    const b = blockedBy(e.limits);
    return b ? resetMs(b) || Number.MAX_SAFE_INTEGER : null;
  };
  return entries
    .map((e, i) => ({ e, i, at: at(e) }))
    .sort((x, y) => (x.at != null) - (y.at != null) || (x.at != null ? x.at - y.at : 0) || x.i - y.i)
    .map((x) => x.e);
}
