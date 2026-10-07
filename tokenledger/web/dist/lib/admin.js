// web/dist/lib/admin.js — what the five admin pages compute from the hub's
// answers, with no DOM (claude-fleet#1990): Subscriptions' cards, pool
// headroom and the add-a-subscription wait, Machines' cards and the join-code
// wait, Users' rows, Settings' switches and Audit's days. The page scripts
// (subscriptions.js, nodes.js, users.js, settings.js, audit.js) fetch and
// draw; web/test/admin.test.mjs pins these.
//
// Every word goes through t() (lib/i18n.js); stored audit text is shown as
// the hub recorded it, never translated.
import { t, fmtDate } from './i18n.js';

const toMs = (v) => (typeof v === 'number' ? v : Date.parse(v || ''));

/** pct is a utilization (0–1 or 0–100, the hub has sent both) as 0–100. */
export function pct(u) {
  if (u == null || u === '') return null;
  const n = Number(u);
  if (!Number.isFinite(n) || n < 0) return null;
  return Math.min(100, Math.round(n <= 1 ? n * 100 : n));
}

/** level is a bar's colour: ok under 70, warn under the skip threshold, bad at it. */
export const level = (p, skip = 85) => (p == null ? '' : p >= skip ? 'bad' : p >= 70 ? 'warn' : '');

/** fmtIn is how long until a time: "in 1h 18m" / "1 小时 18 分后"; '' when past or unknown. */
export function fmtIn(at, now = Date.now()) {
  const ms = toMs(at);
  if (!Number.isFinite(ms) || ms <= now) return '';
  const m = Math.round((ms - now) / 60000);
  if (m < 60) return t('ui.adm.inM', { m: Math.max(1, m) });
  if (m < 48 * 60) return t('ui.adm.inHM', { h: Math.floor(m / 60), m: m % 60 });
  return t('ui.adm.inD', { d: Math.round(m / 1440) });
}

/** provOf is claude | codex for an account (a Codex account's uuid says so). */
export const provOf = (uuid, source) => (String(source || '').toLowerCase() === 'codex' || String(uuid || '').startsWith('codex:') ? 'codex' : 'claude');

/** windowsOf is a LimitsView's 5-hour and weekly windows, Codex's included. */
export function windowsOf(lim) {
  if (!lim || lim.available === false) return { h5: null, h7: null };
  let h5 = lim.five_hour || null, h7 = lim.seven_day || null;
  for (const w of Array.isArray(lim.windows) ? lim.windows : []) {
    const mins = Number(w.minutes) || 0;
    if (!h5 && (mins === 300 || /5h|five|primary/i.test(w.id || w.label || ''))) h5 = w;
    else if (!h7 && (mins === 10080 || /week|seven|secondary/i.test(w.id || w.label || ''))) h7 = w;
  }
  const v = (w) => (w ? { p: pct(w.utilization), resets: w.resets_at || null } : null);
  return { h5: v(h5), h7: v(h7) };
}

const norm = (s) => String(s || '').trim().toLowerCase();

/**
 * isStandIn is an account key that is not a subscription's own identity: a
 * reset-schedule fingerprint (win_…) or a source's unattributed pool
 * (codex:local). Such a row can sit beside the real account, so it never
 * counts as "the one account" a lone credential belongs to.
 */
export const isStandIn = (uuid) => /^win_/.test(String(uuid || '')) || /:local$/.test(String(uuid || ''));

/** credKey is a credential's identity: provider/account. */
export const credKey = (c) => `${c.provider}/${c.account}`;

/**
 * subscriptions joins what the hub knows about each subscription into one
 * card each: its usage (/v1/limits?account=all), its account (/v1/accounts),
 * the pool credential the vault holds for it (/v1/fleet/credentials), whether
 * an admin paused it, and how many live sessions run on it (/v1/live). A pool
 * credential no usage names yet is a card of its own. Claude first, then
 * Codex, each by label.
 *
 * The hub manages what its vault holds (claude-fleet#2127): every card says
 * `managed` — true for a pool credential's card, false for an account the
 * agents report usage for but no vault credential pairs with (a teammate's
 * own login, a win_… fingerprint, codex:local). The page counts only the
 * managed ones and files the rest under 未纳管.
 *
 * A credential the hub could name the account of (account_uuid — a Codex
 * credential's, from its id_token) goes on that card first (claude-fleet#2127:
 * a second Codex account broke the guess below). The rest is by label, which
 * is whatever the operator typed at import — "gmail" for
 * verky.yi@gmail.com, "default" for the one Codex login — so it is matched to
 * an account of the SAME provider in three passes (claude-fleet#2104: four
 * real subscriptions showed as eight cards beside their own credentials):
 *   1. exactly: label, display label, e-mail, its local part or the uuid;
 *   2. by e-mail domain ("gmail" ↔ @gmail.com), only when one account fits;
 *   3. a provider with ONE pool credential and ONE real account: the same one.
 * A guess that fits two accounts matches neither — a spare credential stays a
 * card of its own rather than wearing someone else's usage.
 */
export function subscriptions({ limits, accounts, creds, paused, live } = {}) {
  const per = (limits && Array.isArray(limits.per_account)) ? limits.per_account : [];
  const accts = new Map((Array.isArray(accounts) ? accounts : []).map((a) => [a.account_uuid, a]));
  const pool = ((creds && creds.credentials) || []).filter((c) => c.principal_id === 'pool' && c.provider !== 'github');
  const pausedSet = new Set(((creds && creds.paused) || paused || []).map(String));
  const n = {};
  for (const s of (live && Array.isArray(live.sessions)) ? live.sessions : []) if (s.account) n[s.account] = (n[s.account] || 0) + 1;
  const used = new Set();
  const rows = per.map((pa) => {
    const a = accts.get(pa.account_uuid) || {};
    const label = pa.label || a.label || a.display_name || a.email || pa.account_uuid;
    return { pa, a, label, prov: provOf(pa.account_uuid, (pa.limits && pa.limits.source) || a.source), cred: null };
  });
  const take = (r, c) => { r.cred = c; used.add(credKey(c)); };
  const free = (prov) => pool.filter((c) => !used.has(credKey(c)) && (c.provider === 'codex' ? 'codex' : 'claude') === prov);
  // 0. by identity: the account the hub says the credential belongs to (a
  //    Codex credential's from its id_token; a Claude one's recorded at import)
  for (const r of rows) {
    const c = free(r.prov).find((x) => x.account_uuid && x.account_uuid === r.pa.account_uuid);
    if (c) take(r, c);
  }
  // 1. exact
  for (const r of rows) {
    if (r.cred) continue;
    const email = r.a.email;
    const keys = [norm(r.label), norm(email), norm(String(email || '').split('@')[0]), norm(r.pa.account_uuid)];
    const c = free(r.prov).find((x) => keys.includes(norm(x.account)));
    if (c) take(r, c);
  }
  // 2. e-mail domain, unique
  const domainOf = (email) => { const d = norm(String(email || '').split('@')[1]); return d ? [d, d.split('.')[0]] : []; };
  for (const c of pool) {
    if (used.has(credKey(c))) continue;
    const prov = c.provider === 'codex' ? 'codex' : 'claude';
    const fit = rows.filter((r) => !r.cred && r.prov === prov && domainOf(r.a.email).includes(norm(c.account)));
    if (fit.length === 1) take(fit[0], c);
  }
  // 3. one credential, one real account
  for (const prov of ['claude', 'codex']) {
    const creds = pool.filter((c) => (c.provider === 'codex' ? 'codex' : 'claude') === prov);
    const real = rows.filter((r) => r.prov === prov && !isStandIn(r.pa.account_uuid));
    if (creds.length === 1 && real.length === 1 && !used.has(credKey(creds[0])) && !real[0].cred) take(real[0], creds[0]);
  }
  const out = [];
  for (const { pa, label, prov, cred, a } of rows) {
    const w = windowsOf(pa.limits);
    out.push({
      id: pa.account_uuid, label, prov,
      plan: (pa.limits && pa.limits.plan) || a.subscription_type || '',
      h5: w.h5, h7: w.h7, available: !!(pa.limits && pa.limits.available !== false), reason: (pa.limits && pa.limits.reason) || '',
      sessions: n[pa.account_uuid] || 0, cred: cred || null, paused: !!(cred && pausedSet.has(cred.account)), managed: !!cred,
      // When the reading was taken, and by whom — the hub through the relay or
      // a node — with why the hub's is missing (claude-fleet#2169).
      readAt: (pa.limits && pa.limits.observed_at) || '', readVia: (pa.limits && pa.limits.read_via) || '',
      readNote: (pa.limits && pa.limits.read_note) || '',
    });
  }
  for (const c of pool) {
    if (used.has(credKey(c))) continue;
    out.push({ id: 'cred:' + credKey(c), label: c.account, prov: c.provider === 'codex' ? 'codex' : 'claude', plan: '',
      h5: null, h7: null, available: false, reason: '', sessions: 0, cred: c, paused: pausedSet.has(c.account), managed: true });
  }
  return out.sort((x, y) => (x.prov === y.prov ? String(x.label).localeCompare(String(y.label)) : x.prov === 'claude' ? -1 : 1));
}

/** state is a card's chip: paused, full (at or past the skip threshold) or active. */
export function subState(s, skip = 85) {
  if (s.paused) return 'paused';
  const top = Math.max(s.h5 ? s.h5.p || 0 : 0, s.h7 ? s.h7.p || 0 : 0);
  return top >= skip ? 'full' : 'active';
}

/** credState is the credential line on a card. */
export function credState(c, now = Date.now()) {
  if (!c) return { tone: 'warn', text: t('ui.sub.credNone') };
  if (c.reauth_required) return { tone: 'bad', text: t('ui.sub.credReauth') };
  if (c.refresh_error) return { tone: 'bad', text: t('ui.sub.credError') };
  const end = toMs(c.secret_expires_at);
  if (Number.isFinite(end) && end > 0) {
    if (end <= now) return { tone: 'bad', text: t('ui.sub.credExpired') };
    if (end - now < 30 * 86400000) return { tone: 'warn', text: t('ui.sub.credEnds', { when: fmtDate(end, undefined, false) }) };
  }
  return { tone: 'ok', text: t('ui.sub.credOk', { when: fmtDate(c.created_at, undefined, false) }) };
}

/** headroom is the pool's free share of a window (mean over cards that
 *  report it) and the soonest reset; null when no card reports it. */
export function headroom(cards, which, now = Date.now()) {
  const ws = cards.filter((c) => !c.paused && c[which] && c[which].p != null).map((c) => c[which]);
  if (!ws.length) return null;
  const free = Math.round(ws.reduce((a, w) => a + (100 - w.p), 0) / ws.length);
  const next = ws.map((w) => toMs(w.resets)).filter((ms) => Number.isFinite(ms) && ms > now).sort((a, b) => a - b)[0];
  return { free, next: next || null };
}

/** leaseRows is "who is on which subscription": one row per live session
 *  with an account, newest first; people by their machine login, named by
 *  the GitHub account /v1/fleet/users maps it to. */
export function leaseRows(live, cards, users) {
  const byId = new Map(cards.map((c) => [c.id, c.label]));
  const who = new Map();
  for (const u of (users && users.users) || []) if (u.machine_login) who.set(u.machine_login, u.login);
  return ((live && live.sessions) || []).filter((s) => s.account)
    .map((s) => ({
      session: (s.worktree || s.cwd || '').split('/').filter(Boolean).pop() || String(s.session_id || '').slice(0, 8),
      person: who.get(s.os_user) || s.os_user || '—', sub: byId.get(s.account) || s.account, since: s.started_at || s.observed_at,
    }))
    .sort((a, b) => toMs(b.since) - toMs(a.since));
}

/** switchRows labels /v1/account-switches with the cards' names. */
export function switchRows(sw, cards) {
  const byId = new Map(cards.map((c) => [c.id, c.label]));
  return (Array.isArray(sw) ? sw : []).map((x) => ({
    from: byId.get(x.from_account) || x.from_account || '—', to: byId.get(x.to_account) || x.to_account || '—',
    at: x.observed_at, where: x.endpoint_id || '',
  }));
}

/** LABEL_RE is the vault's account label rule (fleet_creds.go validAccountLabel). */
export const LABEL_RE = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$/;

/** addSubCommands is what to run on a fleet machine to hand the hub a new
 *  subscription: sign in with the provider's own CLI, then import it —
 *  { cmds, note }, the note saying where a Claude token goes in between. */
export function addSubCommands(prov, label) {
  const imp = '~/.claude/fleet/bin/fleet-creds-import.sh';
  if (prov === 'codex') return { cmds: [`CODEX_HOME=~/.codex-accounts/${label} codex login`, `${imp} --codex ${label}`], note: '' };
  return { cmds: ['claude setup-token', `${imp} ${label}`], note: t('ui.sub.add.saveAs', { file: `~/.config/claude-fleet/accounts/${label}` }) };
}

/** arrived is the credential audit's put that answers an add started at
 *  since (epoch ms): the first put of that provider + label at or after it,
 *  else null. The wait polls /v1/fleet/credentials/audit and stops here. */
export function arrived(audit, prov, label, since) {
  const rows = (audit && Array.isArray(audit.audit)) ? audit.audit : [];
  return rows.find((r) => r.action === 'put' && r.provider === prov && norm(r.account) === norm(label) && toMs(r.at) >= since - 1000) || null;
}

/** machineCards are /v1/nodes' machines, lost last, by name. name is the
 *  hostname's first label (what the actions send); label is the short name
 *  the admin gave it (fleet.machine_names → alias), else name. */
export function machineCards(snap) {
  const ms = (snap && Array.isArray(snap.machines)) ? snap.machines : [];
  const vers = {};
  const eps = {};
  for (const n of (snap && snap.nodes) || []) {
    const h = n.hostname;
    if (n.endpoint_id) (eps[h] = eps[h] || []).push(n.endpoint_id);
    const v = n.fleet_version || n.agent_version || '';
    if (v && (!vers[h] || v > vers[h])) vers[h] = v;
  }
  const rank = { online: 0, maintenance: 1, lost: 2 };
  return ms.map((m) => ({
    host: m.hostname, name: String(m.hostname || '').split('.')[0], label: m.alias || String(m.hostname || '').split('.')[0], status: m.status, kind: m.kind,
    sessions: m.sessions, loadCore: m.ncpu ? m.load1 / m.ncpu : null, hist: Array.isArray(m.load_hist) ? m.load_hist : [],
    version: vers[m.hostname] || '', seen: m.last_heartbeat, maintenance: m.maintenance || null,
    eps: eps[m.hostname] || [],
  })).sort((a, b) => (rank[a.status] ?? 3) - (rank[b.status] ?? 3) || a.label.localeCompare(b.label));
}

/** joined is the join code that answers a wait started for label: used, or null. */
export function joined(codes, label) {
  const rows = (codes && Array.isArray(codes.codes)) ? codes.codes : [];
  return rows.find((c) => c.label === label && c.used_at) || null;
}

/** countdown is "29:41" until expires (epoch ms or ISO); "0:00" once past. */
export function countdown(expires, now = Date.now()) {
  const s = Math.max(0, Math.round((toMs(expires) - now) / 1000));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

/** GH_LOGIN_RE is a GitHub user name. */
export const GH_LOGIN_RE = /^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){0,38}$/i;

/** cleanLogin is what someone typed as a GitHub name: no @, no URL. */
export const cleanLogin = (s) => String(s || '').trim().replace(/^https?:\/\/github\.com\//i, '').replace(/^@/, '').replace(/\/+$/, '');

/** userRows: deploy admins first, then everyone by name. */
export function userRows(list) {
  const users = (list && Array.isArray(list.users)) ? list.users : [];
  return users.slice().sort((a, b) => (b.deploy ? 1 : 0) - (a.deploy ? 1 : 0) || (a.role === b.role ? 0 : a.role === 'admin' ? -1 : 1) || String(a.login).localeCompare(String(b.login)));
}

/** The switches and fields Settings draws, in groups, after the prototype.
 *  Each is a hub setting key (hub_settings.go); type on/off, pct, hosts or names. */
export const SETTING_GROUPS = Object.freeze([
  { id: 'public', items: [{ key: 'hub.public_meter', type: 'onoff' }, { key: 'hub.public_badges', type: 'onoff' }] },
  { id: 'pool', items: [{ key: 'pool.skip_pct', type: 'pct' }, { key: 'pool.move_when_full', type: 'onoff' }] },
  { id: 'people', items: [{ key: 'fleet.auto_assign', type: 'hosts' }, { key: 'fleet.machine_names', type: 'names' }, { key: 'fleet.spot', type: 'onoff' }] },
]);

/** settingValue is what applies for key in a /v1/fleet/settings answer:
 *  its hub row (stored, the old variable, or the default). */
export function settingValue(answer, key) {
  const row = ((answer && answer.hub) || []).find((h) => h.key === key);
  if (row) return { value: row.value, source: row.source };
  const v = answer && answer.settings ? answer.settings[key] : undefined;
  return { value: v == null ? '' : String(v), source: v == null ? 'default' : 'set' };
}

/** AUDIT_KINDS are the Audit page's filters, in order; ids are the hub's. */
export const AUDIT_KINDS = Object.freeze(['all', 'sub', 'mach', 'dev', 'user', 'set', 'sess']);

/** auditDays groups events (newest first) by local day: [{day, events}]. */
export function auditDays(events) {
  const out = [];
  for (const e of Array.isArray(events) ? events : []) {
    const day = fmtDate(e.at, undefined, false);
    if (!out.length || out[out.length - 1].day !== day) out.push({ day, events: [] });
    out[out.length - 1].events.push(e);
  }
  return out;
}

/** auditWho is the actor a row names, without the principal's "(gh:…)". */
export const auditWho = (e) => String((e && e.actor) || '').replace(/\s*\((gh|wecom)[^)]*\)$/, '') || '—';
