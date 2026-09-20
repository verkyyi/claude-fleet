// web/dist/lib/findings.js — the one renderer for a finding's attribution.
//
// A finding answers "what happened". `owner` answers the question the page
// could not answer before it existed: WHO to go to about it. It arrives from
// GET /v1/findings (and MCP get_findings) as `{ user, team }`, either half
// optional, and the key is ABSENT when the hub does not know — which is the
// normal case, not an error: a finding about a model, a project or a whole
// period has no single owner, and inventing one would send somebody after work
// that is not theirs.
//
// Two views print findings (Now's Alerts card, Review's Findings card) and this
// is shared between them so the wording cannot drift into two versions of the
// same line. Kept as a pure string function, with no DOM and no module-level
// locale, so it is testable and so each caller wraps it in its own element.
import { t } from './i18n.js';

// ownerLine renders `f.owner` as one short line, or null when there is nothing
// to say. Null, not an empty string: the callers append it conditionally and a
// blank <div> would take up a row and a border for no content.
//
// A user with no team is the normal state of an unallocated endpoint, and a
// team with no user happens too, so all three combinations render.
export function ownerLine(f) {
  const o = (f && f.owner) || {};
  const user = typeof o.user === 'string' ? o.user.trim() : '';
  const team = typeof o.team === 'string' ? o.team.trim() : '';
  if (user && team) return t('findings.owner.both', { user, team });
  if (user) return t('findings.owner.user', { user });
  if (team) return t('findings.owner.team', { team });
  return null;
}

// ---------------------------------------------------------------- muting

// A finding an operator has silenced arrives with `muted` = {until, note, by}
// and WITHOUT it otherwise, exactly as `owner` works. The key's absence is the
// whole test — there is no `muted: false` to guard against, and asking for one
// would let a future null slip through as "muted".
//
// The server also ranks muted findings after every live one and outside their
// cap (internal/findings/findings.go's finish), so the muted ones are always a
// contiguous TAIL. splitMuted relies on that only for efficiency of reading,
// not for correctness: it partitions rather than slicing at the boundary, so a
// response that interleaved them would still render correctly.
export function isMuted(f) {
  return !!(f && f.muted && typeof f.muted === 'object');
}

export function splitMuted(list) {
  const live = [], muted = [];
  for (const f of list || []) (isMuted(f) ? muted : live).push(f);
  return { live, muted };
}

// muteLine says WHEN the silence ends, and who chose it. The expiry is the
// point: a muted finding that only said "muted" would be indistinguishable
// from a deleted one, and the reason every mute expires is so that nobody has
// to wonder whether an alert is gone or merely quiet.
//
// `now` is injected so this is testable without a clock, and defaults to the
// real one for the two callers.
export function muteLine(f, now = Date.now()) {
  if (!isMuted(f)) return null;
  const until = Date.parse(f.muted.until);
  const by = typeof f.muted.by === 'string' ? f.muted.by.trim() : '';
  // An unparseable or already-past expiry should not print a negative
  // countdown. The server does not send one (it filters on the clock before
  // annotating), so this is the belt to that braces: say it is muted, and
  // decline to invent a duration.
  const left = Number.isFinite(until) ? until - now : NaN;
  const when = Number.isFinite(left) && left > 0 ? humanLeft(left) : null;
  if (when && by) return t('findings.muted.byFor', { by, left: when });
  if (when) return t('findings.muted.for', { left: when });
  if (by) return t('findings.muted.by', { by });
  return t('findings.muted.plain');
}

// humanLeft renders a remaining duration at the coarsest unit that is still
// honest: "2d", "5h", "20m". Rounded DOWN, so a mute never claims more time
// than it has — "1h" that is really 1h59m is a pleasant surprise; "2h" that
// expires in 61 minutes is a lie the operator plans around.
function humanLeft(ms) {
  const m = Math.floor(ms / 60000);
  if (m >= 1440) return t('findings.muted.days', { n: Math.floor(m / 1440) });
  if (m >= 60) return t('findings.muted.hours', { n: Math.floor(m / 60) });
  return t('findings.muted.minutes', { n: Math.max(1, m) });
}
