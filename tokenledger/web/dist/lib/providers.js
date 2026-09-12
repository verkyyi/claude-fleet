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
