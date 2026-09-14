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
