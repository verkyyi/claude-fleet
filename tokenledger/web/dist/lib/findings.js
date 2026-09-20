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
