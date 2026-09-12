import { el } from './lib/dom.js';
import { fmtInt } from './lib/format.js';
import * as C from './charts.js';

import {windowName, loginLabel} from './lib/providers.js';
export {selectLive, windowName} from './lib/providers.js';

export function quotaGauges(v) {
  const out = [];
  if (v.windows) for (const w of v.windows) out.push(C.gauge(windowName(w), w));
  else {
    if (v.five_hour) out.push(C.gauge('5-hour window', v.five_hour));
    if (v.seven_day) out.push(C.gauge('7-day window', v.seven_day));
  }
  for (const c of v.credits || []) out.push(el('p', { class: 'hint' },
    `${c.limit_id} credits: ${c.unlimited ? 'unlimited' : c.balance != null ? c.balance : c.has_credits ? 'available' : 'none'}`));
  if (v.blocked) out.push(el('p', { class: 'hint' }, `Limit reached: ${v.reason || 'reported by service'}`));
  if (v.source === 'codex') out.push(el('p', { class: 'hint' },
    `${v.plan || 'Codex account'} · observed ${v.observed_at ? new Date(v.observed_at).toLocaleString() : 'unknown'} · projections are estimates`));
  return out;
}

export function highestQuota(v) {
  return Math.max(v?.five_hour?.utilization || 0, ...(v?.windows || []).map((w) => w.utilization));
}

export function collectorsCard(result, endpoints = [], accounts = []) {
  const card = el('div', { class: 'card' }, el('h2', {}, 'Collection by source'));
  if (result.status !== 'fulfilled') return el('div', { class: 'card empty' }, 'Collector status unavailable.');
  const names = new Map(endpoints.map((e) => [e.endpoint_id, e.label || e.hostname]));
  const accountMap = new Map(accounts.map((a) => [a.account_uuid, a]));
  const rows = result.value || [];
  if (!rows.length) card.appendChild(el('p', { class: 'empty' }, 'No collector observations for this selection.'));
  for (const c of rows) {
    const stale = Date.now() - Date.parse(c.observed_at) > 180000;
    const account = accountMap.get(c.account_uuid) || {};
    const name = c.profile_name || 'default';
    const commands = c.profile_managed && /^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$/.test(name);
    const login = c.login;
    const loginPanel = c.source === 'codex' ? el('div', {class:'codex-login'},
      el('p', {}, `${account.email || account.display_name || 'Unlinked account'}${account.subscription_type ? ' · ' + account.subscription_type : ''} · profile ${name}${c.profile_default ? ' · default for new ccquota launches' : ''}`),
      el('p', {class:'hint'}, `${loginLabel(login)}${login ? ' · automatic renewal ' + (login.auto_refresh ? 'on' : 'off') : ''}`),
      login?.access_expires_at ? el('p', {class:'hint'}, `Access expires ${new Date(login.access_expires_at).toLocaleString()}${login.last_refresh_at ? ' · credentials refreshed ' + new Date(login.last_refresh_at).toLocaleString() : ''}`) : null,
      login?.refresh_attempt_at ? el('p', {class:'hint'}, `Last renewal attempt ${new Date(login.refresh_attempt_at).toLocaleString()}${login.retry_at ? ' · retry after ' + new Date(login.retry_at).toLocaleString() : ''}`) : null,
      login?.reason ? el('p', {class:'hint'}, login.reason) : null,
      commands ? el('details', {}, el('summary', {}, 'Manage this account'),
        el('p', {class:'hint'}, 'Run on this machine as the same OS user. Switching selects the account for new ccquota launches; existing sessions keep their login.'),
        el('pre', {style:'white-space:pre-wrap;overflow-wrap:anywhere'}, `ccquota codex list\nccquota codex run ${name}\nccquota codex use ${name}\nccquota codex refresh ${name}\nccquota codex login ${name}`)) : null) : null;
    card.appendChild(el('div', { style: 'margin:12px 0' },
      el('b', {}, `${names.get(c.endpoint_id) || c.endpoint_id} · ${c.source === 'codex' ? 'Codex' : 'Claude Code'}`),
      el('p', { class: 'hint' }, `${stale ? 'stale' : c.state.replaceAll('_', ' ')} · ${c.files} indexed transcripts${c.client_version ? ' · ' + (c.client_version_basis === 'account_query' ? 'CLI v' : 'last log v') + c.client_version : ''}`),
      el('p', { class: 'hint' }, `Last scan ${new Date(c.observed_at).toLocaleString()}${c.last_event_at ? ' · last usage ' + new Date(c.last_event_at).toLocaleString() : ''}${c.queue_bytes ? ' · agent queue ' + fmtInt(c.queue_bytes) + ' bytes' : ''}`),
      loginPanel,
      c.reason ? el('p', { class: 'hint' }, c.reason) : null,
      c.limits_reason ? el('p', { class: 'hint' }, `Quota: ${c.limits_reason}`) : null));
  }
  if (rows.some((c) => c.source === 'codex')) card.appendChild(el('details', {}, el('summary', {}, 'Add another Codex account'),
    el('p', {class:'hint'}, 'Create a separate login directory on the machine where you use Codex. The agent discovers it automatically; each account keeps its own quota.'),
    el('pre', {style:'white-space:pre-wrap'}, 'ccquota codex add work\nccquota codex login work\nccquota codex run work')));
  return card;
}

export function accountUsageCard(result, accounts = []) {
  if (result.status !== 'fulfilled' || !result.value.observations?.length) return null;
  const card = el('div', { class: 'card' }, el('h2', {}, 'Service account activity'),
    el('p', { class: 'hint' }, result.value.note));
  const names = new Map(accounts.map((a) => [a.account_uuid, a.email || a.display_name || a.account_uuid]));
  for (const u of result.value.observations) {
    const total = u.lifetime_tokens == null ? 'not provided' : fmtInt(u.lifetime_tokens);
    card.appendChild(el('h3', {}, names.get(u.account_uuid) || u.account_uuid));
    card.appendChild(el('p', {}, `${total} lifetime tokens reported by the service`));
	card.appendChild(el('p', {}, `${fmtInt(u.local_attributed_tokens || 0)} tokens in local details attributed to this account · ${fmtInt(u.local_attributed_requests || 0)} requests`));
    card.appendChild(el('p', { class: 'hint' }, `Observed ${new Date(u.observed_at).toLocaleString()} · ${(u.daily || []).length} daily buckets available`));
    if (u.daily?.length) {
      const rows = u.daily.slice(-14);
      card.appendChild(el('details', {}, el('summary', {}, 'Recent daily service totals'),
        el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, 'Service date'), el('th', {}, 'Tokens'))),
          el('tbody', {}, rows.map((d) => el('tr', {}, el('td', {}, d.date), el('td', {}, fmtInt(d.tokens))))))));
    }
  }
  return card;
}
