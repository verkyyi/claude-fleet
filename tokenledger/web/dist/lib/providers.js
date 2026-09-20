import { t } from './i18n.js';

export function selectLive(snap, chips = {}, account = 'all') {
  const sessions = (snap.sessions || []).filter(s =>
    (!account || account === 'all' || s.account === account) &&
    (!chips.source || (s.source || 'claude') === chips.source) &&
    (!chips.machine || s.endpoint_id === chips.machine) &&
    (!chips.login || s.os_user === chips.login) &&
    (!chips.project || s.cwd === chips.project) &&
    (!chips.model || s.model === chips.model) &&
    (!chips.session || s.session_id === chips.session));
  const out = {...snap, sessions, active_sessions:sessions.length, endpoints:new Set(sessions.map(s=>s.endpoint_id)).size,
    tokens_per_min:0,usd_per_hour:0,session_tokens:0,unpriced_sessions:0};
  for (const s of sessions) {
    out.tokens_per_min += s.tokens_per_min || 0; out.usd_per_hour += s.usd_per_hour || 0;
    out.session_tokens += (s.input_tokens || 0) + (s.output_tokens || 0);
    if (s.cost_unknown) out.unpriced_sessions++;
  }
  return out;
}

export function windowName(w) {
  const n = w.minutes;
  const span = !n ? t('quota.window')
    : n % 1440 === 0 ? t('quota.windowDays', { n: n / 1440 })
    : n % 60 === 0 ? t('quota.windowHours', { n: n / 60 })
    : t('quota.windowMinutes', { n });
  return `${w.limit_id === 'codex' ? 'Codex' : (w.label || w.limit_id)} · ${span}`;
}

export function pricingCoverage(d) {
  const total = Number(d.events || 0), unpriced = Number(d.unpriced_events || 0);
  const priced = Math.max(0, total - unpriced);
  return {total, unpriced, priced, percent: total > 0 ? (100 * priced / total).toFixed(2) + '%' : '—'};
}

// The login states this build knows how to name. An unrecognised state falls
// through to the "unavailable" wording rather than printing a bare identifier:
// a state name is an internal token, and "retry_pending" on a card answers
// nothing a reader can act on.
const LOGIN_STATES = ['valid', 'refresh_due', 'access_expired', 'refreshing',
  'retry_pending', 'reauth_required', 'no_credentials', 'unsupported'];

export function loginLabel(login) {
  const state = login?.state;
  return LOGIN_STATES.includes(state) ? t('login.' + state) : t('login.unavailable');
}

/** SOURCE_LABEL names a collector source for a human. Every source this build
 *  knows is listed: an unlabelled one falls through to its bare identifier,
 *  which is how `vendor_bill` used to read in the source picker. */
export const SOURCE_LABEL = {
  claude: 'Claude Code',
  codex: 'Codex',
  gateway: 'AI gateway',
  vendor_bill: 'Vendor invoice',
  voice: 'Voice, app-reported',
};

/** sourceLabel is what a human should READ for a source, in their language.
 *
 *  SOURCE_LABEL above stays as the English text because web/embed_test.go
 *  anchors on its shape (`claude: '`) to catch a source added to model.Sources
 *  with no label at all — a guard that has caught one real omission (`voice`)
 *  and must keep working. The translations live under `source.<id>` in the
 *  dictionaries, and web/test/i18n.test.mjs asserts the English side of the two
 *  never drifts apart. */
export const sourceLabel = (source) => {
  const key = 'source.' + source;
  const label = t(key);
  // t() returns the key itself when neither dictionary has it — which is
  // exactly the case SOURCE_LABEL exists to cover.
  return label === key ? (SOURCE_LABEL[source] || source) : label;
};

/** accountGroups splits the account list by what an account MEANS for its
 *  source, because the word differs. On claude and codex it is a subscription
 *  somebody pays for monthly; a vendor_bill "account" is likewise a billing
 *  relationship, an invoice. On gateway it is one CALLING APPLICATION, since
 *  the shipper maps one APISIX consumer to one account — and a voice account
 *  is that same thing reached another way: the application reports its own
 *  WebSocket calls, so the account names the caller, never a bill. A single
 *  flat list under either word is wrong about the other half of its options.
 *
 *  An empty group is omitted rather than rendered: a heading over nothing
 *  promises options this hub does not have. */
export function accountGroups(accounts) {
  const kind = (a) => (CALLER_SOURCES.has(UsageSource(a.source)) ? 'app' : 'sub');
  const label = { sub: t('accounts.subscriptions'), app: t('accounts.apps') };
  const name = (a) => a.email || a.display_name || a.account_uuid;
  return ['sub', 'app']
    .map((k) => ({
      key: k,
      label: label[k],
      options: (accounts || []).filter((a) => kind(a) === k)
        .map((a) => ({ value: a.account_uuid, text: name(a) })),
    }))
    .filter((g) => g.options.length > 0);
}

// A stored row written before the source column existed reads as Claude --
// the same rule model.UsageSource applies in Go. Kept local so this module
// stays free of imports beyond what it already has.
const UsageSource = (s) => s || 'claude';

// The sources whose "account" is a caller rather than a billing relationship.
// A set, not a comparison, because there are now two of them and the next one
// should be an entry here rather than another `||` nobody reads.
const CALLER_SOURCES = new Set(['gateway', 'voice']);

/** The sources whose account can have a QUOTA WINDOW — a pool with a ceiling
 *  and a reset. Everything else (a gateway caller, a voice application, a
 *  vendor invoice) is billed per call: no ceiling, no percentage, nothing to
 *  be near. This mirrors model.HasQuotaWindow in Go, and is an ALLOW-list for
 *  the same reason it is one there: a source added later has no window until
 *  somebody says it does, so it goes missing from a quota card — visible and
 *  harmless — rather than sitting on one forever claiming "no reading". */
const QUOTA_SOURCES = new Set(['claude', 'codex']);

export const hasQuotaWindow = (source) => QUOTA_SOURCES.has(UsageSource(source));

/** quotaAccounts splits a /v1/limits `per_account` list by whether the account
 *  could have a reading at all.
 *
 *  The endpoint answers for EVERY account the hub has seen — the accounts
 *  table is upserted on every ingest batch whatever its source — and that is
 *  the right shape for an API consumer. It is the wrong shape for a card whose
 *  title is the question "am I about to hit the wall?", because a calling
 *  application is not an answer to it. The split happens here, in the render
 *  layer, so MCP and API consumers keep the full list (#50).
 *
 *  `per_account` entries carry no source, so it is resolved through the hub's
 *  account list. An entry no account row matches counts as shown: the account
 *  list going stale between two fetches must not hide a real subscription, and
 *  the server's own reason on such an entry now says "billed per call" rather
 *  than "no reading available" anyway. */
export function quotaAccounts(perAccount, accounts) {
  const sourceOf = new Map((accounts || []).map((a) => [a.account_uuid, UsageSource(a.source)]));
  const shown = [], metered = [];
  for (const entry of perAccount || []) {
    const source = sourceOf.get(entry.account_uuid);
    if (source !== undefined && !hasQuotaWindow(source)) metered.push(entry);
    else shown.push(entry);
  }
  return { shown, metered };
}
