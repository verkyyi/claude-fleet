// web/dist/lib/fleetnav.js — the way from the home page to the fleet pages
// (连接 / 我的会话 / 机器节点), as a decision over /v1/fleet/me. No DOM:
// app.js draws what this returns into the shell's #fleetnav.
//
// Why a decision and not three static links (claude-fleet#1458): the pages
// are per-person. 连接 lists the machines YOUR login is active on and signs
// a certificate for it; 我的会话 lists YOUR sessions. A colleague who has
// signed in but has no login anywhere yet would open two empty pages and
// learn nothing from either — so the nav tells them the one thing the pages
// cannot: nobody has placed them on a machine yet, ask the operator. The
// operator's own doors (token, tailnet) are not a person and see everything,
// so they get every page, the roster included.
//
// `me` is the /v1/fleet/me body, or null when the hub has no fleet module
// (the route 404s) or could not be reached — both render as nothing, which
// is what every hub predating the fleet module looks like.

/** FLEET_LINKS is every fleet page, in nav order. `person` says a signed-in
 *  colleague gets it; the operator gets all of them. */
export const FLEET_LINKS = Object.freeze([
  { href: '/connect', key: 'fleet.connect', person: true },
  { href: '/sessions', key: 'fleet.sessions', person: true },
  { href: '/nodes', key: 'fleet.nodes', person: false },
]);

/** NOTE_UNASSIGNED is the i18n key printed in place of the links for a
 *  person the hub has placed nowhere yet. */
export const NOTE_UNASSIGNED = 'fleet.unassigned';

/** fleetNav decides what the home page shows:
 *    { links: [{href, key}], note: i18n key | null, login: string | null }
 *
 *  - no fleet module (me == null)          → nothing
 *  - the operator's door (!signed_in)      → every page
 *  - a person with an ACTIVE login         → 连接 + 我的会话, with the login
 *  - a person placed nowhere yet           → the unassigned note, no links
 *
 *  "Active" is the hub's word (store.AccountActive): a pending or failed row
 *  has no machine to connect to, and FleetScope shows that person nothing
 *  either, so the nav and the pages agree. */
export function fleetNav(me) {
  if (!me || typeof me !== 'object') return { links: [], note: null, login: null };
  const pick = (all) => FLEET_LINKS.filter((l) => all || l.person).map(({ href, key }) => ({ href, key }));
  if (!me.signed_in) return { links: pick(true), note: null, login: null };
  const active = Array.isArray(me.accounts) && me.accounts.some((a) => a && a.state === 'active');
  if (active) return { links: pick(false), note: null, login: (me.principal && me.principal.login) || null };
  return { links: [], note: NOTE_UNASSIGNED, login: null };
}
