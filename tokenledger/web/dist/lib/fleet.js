// web/dist/lib/fleet.js — the roster's claude-fleet column, as text.
//
// One login, one line: which commit its claude-fleet install is on and how far
// that trails the trunk, relayed by the agent from fleet-install-version.sh
// (issue #157; claude-fleet#644). Pure — no DOM; now.js's rosterTable draws
// what this returns.
//
// Two readings look alike and are not, and this file exists to keep them apart:
//
//   - fleet_head === ''      → the login never reported an install. A dash.
//   - fleet_behind === null  → it reported, and the COUNT could not be read
//                              (no upstream, fetch refused). "unknown", with
//                              the script's own reason in the tooltip. Never
//                              0: rendering null as current is exactly the
//                              bug the null exists to prevent (claude-fleet#635).
//
// `fetched: false` is the third honest state: the count was read against the
// remote ref the install already had, up to a sync period old, so it is said
// out loud rather than presented as fresh.
import { t } from './i18n.js';
import { ago } from './format.js';

/** FLEET_STALE_SEC is how much older than the endpoint's own `last_seen` the
 *  fleet reading may be before the cell greys out. The agent re-reads every
 *  few minutes and the login batch that carries it goes out at least every
 *  minute, so an hour's gap means the login stopped reporting the install
 *  (Claude logged out; agent downgraded), not that the install is slow. */
export const FLEET_STALE_SEC = 3600;

/** fleetCell turns one /v1/endpoints row into the column's content, or null
 *  when the login never reported an install (draw a dash).
 *
 *  Returns { text, flag, title, stale }:
 *    text  — "0164208 · 12 behind", "0164208 · unknown", …, with "(not
 *            fetched)" appended when the count is against a stale ref;
 *    flag  — null, or { verdict: 'STUCK'|'OFF', text } when the install-sync
 *            daemon is not following, so the row can carry a marker;
 *    title — the tooltip: the script's reason for an unknown, the follow
 *            sentence behind a flag, and when the reading was taken;
 *    stale — true when the reading is much older than the endpoint's last
 *            report (see FLEET_STALE_SEC). */
export function fleetCell(e, now = Date.now()) {
  if (!e || !e.fleet_head) return null;
  const head = e.fleet_head;
  const behind = e.fleet_behind == null ? null : Number(e.fleet_behind);
  const verdict = e.fleet_verdict || '';

  let text;
  if (behind == null) {
    text = t('endpoints.fleet.unknown', { head });
  } else if (verdict === 'AHEAD') {
    text = t('endpoints.fleet.ahead', { head });
  } else if (verdict === 'DIVERGED') {
    text = t('endpoints.fleet.diverged', { head, n: behind });
  } else if (behind === 0) {
    text = t('endpoints.fleet.current', { head });
  } else {
    text = t('endpoints.fleet.behind', { head, n: behind });
  }
  // A known count read without a fetch may be up to a sync period old. That
  // applies to "current" most of all — "current (not fetched)" is the honest
  // reading of an install that has not looked at the trunk lately.
  if (behind != null && !e.fleet_fetched) text += ' ' + t('endpoints.fleet.noFetch');

  const follow = e.fleet_follow || '';
  const flag = follow === 'STUCK' ? { verdict: follow, text: t('endpoints.fleet.stuck') }
    : follow === 'OFF' ? { verdict: follow, text: t('endpoints.fleet.off') }
    : null;

  const lines = [];
  if (behind == null && e.fleet_error) lines.push(e.fleet_error);
  if (flag) lines.push(flag.text + (e.fleet_follow_text ? ': ' + e.fleet_follow_text : ''));

  const seenSecs = e.fleet_seen_at ? (now - new Date(e.fleet_seen_at)) / 1000 : null;
  const lastSecs = e.last_seen ? (now - new Date(e.last_seen)) / 1000 : null;
  const stale = seenSecs != null && lastSecs != null && seenSecs - lastSecs > FLEET_STALE_SEC;
  if (seenSecs != null) {
    lines.push(t(stale ? 'endpoints.fleet.stale' : 'endpoints.fleet.seenAgo', { ago: ago(seenSecs) }));
  }

  return { text, flag, title: lines.join('\n'), stale };
}
