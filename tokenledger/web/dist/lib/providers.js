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
  const span = !n ? 'window' : n % 1440 === 0 ? `${n / 1440}-day window` : n % 60 === 0 ? `${n / 60}-hour window` : `${n}-minute window`;
  return `${w.limit_id === 'codex' ? 'Codex' : (w.label || w.limit_id)} · ${span}`;
}

export function pricingCoverage(d) {
  const total = Number(d.events || 0), unpriced = Number(d.unpriced_events || 0);
  const priced = Math.max(0, total - unpriced);
  return {total, unpriced, priced, percent: total > 0 ? (100 * priced / total).toFixed(2) + '%' : '—'};
}

export function loginLabel(login) {
  const labels = {valid:'Signed in', refresh_due:'Renewal due', access_expired:'Access expired · renewal pending',
    refreshing:'Renewing login', retry_pending:'Renewal retry scheduled', reauth_required:'Sign-in required',
    no_credentials:'No file login', unsupported:'Login mode unsupported'};
  return labels[login?.state] || 'Login status unavailable';
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
  const label = { sub: 'Subscriptions', app: 'Calling applications' };
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
