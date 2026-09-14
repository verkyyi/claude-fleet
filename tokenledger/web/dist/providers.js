import { el } from './lib/dom.js';
import { fmtInt } from './lib/format.js';
import * as C from './charts.js';

import {windowName, loginLabel} from './lib/providers.js';
import { t } from './lib/i18n.js';
export {selectLive, windowName} from './lib/providers.js';

export function quotaGauges(v) {
  const out = [];
  if (v.windows) for (const w of v.windows) out.push(C.gauge(windowName(w), w));
  else {
    if (v.five_hour) out.push(C.gauge(t('quota.fiveHour'), v.five_hour));
    if (v.seven_day) out.push(C.gauge(t('quota.sevenDay'), v.seven_day));
  }
  for (const c of v.credits || []) out.push(el('p', { class: 'hint' },
    t('quota.credits', {
      id: c.limit_id,
      value: c.unlimited ? t('quota.credits.unlimited')
        : c.balance != null ? c.balance
        : c.has_credits ? t('quota.credits.available') : t('quota.credits.none'),
    })));
  if (v.blocked) out.push(el('p', { class: 'hint' },
    t('quota.blocked', { reason: v.reason || t('quota.blocked.reported') })));
  if (v.source === 'codex') out.push(el('p', { class: 'hint' },
    t('quota.codexNote', {
      plan: v.plan || t('quota.codexAccount'),
      when: v.observed_at ? new Date(v.observed_at).toLocaleString() : t('common.unknownTime'),
    })));
  return out;
}

export function highestQuota(v) {
  return Math.max(v?.five_hour?.utilization || 0, ...(v?.windows || []).map((w) => w.utilization));
}

export function collectorsCard(result, endpoints = [], accounts = []) {
  const card = el('div', { class: 'card' }, el('h2', {}, t('collectors.title')));
  if (result.status !== 'fulfilled') return el('div', { class: 'card empty' }, t('collectors.unavailable'));
  const names = new Map(endpoints.map((e) => [e.endpoint_id, e.label || e.hostname]));
  const accountMap = new Map(accounts.map((a) => [a.account_uuid, a]));
  const rows = result.value || [];
  if (!rows.length) card.appendChild(el('p', { class: 'empty' }, t('collectors.empty')));
  for (const c of rows) {
    const stale = Date.now() - Date.parse(c.observed_at) > 180000;
    const account = accountMap.get(c.account_uuid) || {};
    const name = c.profile_name || 'default';
    const commands = c.profile_managed && /^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$/.test(name);
    const login = c.login;
    const loginPanel = c.source === 'codex' ? el('div', {class:'codex-login'},
      el('p', {}, `${account.email || account.display_name || t('collectors.unlinked')}${account.subscription_type ? ' · ' + account.subscription_type : ''} · ${t('collectors.profile', { name })}${c.profile_default ? t('collectors.defaultProfile') : ''}`),
      el('p', {class:'hint'}, `${loginLabel(login)}${login ? t(login.auto_refresh ? 'collectors.autoRenewOn' : 'collectors.autoRenewOff') : ''}`),
      login?.access_expires_at ? el('p', {class:'hint'}, t('collectors.accessExpires', { when: new Date(login.access_expires_at).toLocaleString() }) + (login.last_refresh_at ? t('collectors.credsRefreshed', { when: new Date(login.last_refresh_at).toLocaleString() }) : '')) : null,
      login?.refresh_attempt_at ? el('p', {class:'hint'}, t('collectors.lastRenewalAttempt', { when: new Date(login.refresh_attempt_at).toLocaleString() }) + (login.retry_at ? t('collectors.retryAfter', { when: new Date(login.retry_at).toLocaleString() }) : '')) : null,
      login?.reason ? el('p', {class:'hint'}, login.reason) : null,
      commands ? el('details', {}, el('summary', {}, t('collectors.manage')),
        el('p', {class:'hint'}, t('collectors.manageHint')),
        el('pre', {style:'white-space:pre-wrap;overflow-wrap:anywhere'}, `ccquota codex list\nccquota codex run ${name}\nccquota codex use ${name}\nccquota codex refresh ${name}\nccquota codex login ${name}`)) : null) : null;
    card.appendChild(el('div', { style: 'margin:12px 0' },
      el('b', {}, `${names.get(c.endpoint_id) || c.endpoint_id} · ${c.source === 'codex' ? 'Codex' : 'Claude Code'}`),
      el('p', { class: 'hint' }, t('collectors.state', { state: stale ? t('collectors.stale') : c.state.replaceAll('_', ' '), files: c.files })
        + (c.client_version ? t(c.client_version_basis === 'account_query' ? 'collectors.cliVersion' : 'collectors.logVersion', { version: c.client_version }) : '')),
      el('p', { class: 'hint' }, t('collectors.lastScan', { when: new Date(c.observed_at).toLocaleString() })
        + (c.last_event_at ? t('collectors.lastUsage', { when: new Date(c.last_event_at).toLocaleString() }) : '')
        + (c.queue_bytes ? t('collectors.queue', { bytes: fmtInt(c.queue_bytes) }) : '')),
      loginPanel,
      c.reason ? el('p', { class: 'hint' }, c.reason) : null,
      c.limits_reason ? el('p', { class: 'hint' }, t('collectors.quota', { reason: c.limits_reason })) : null));
  }
  if (rows.some((c) => c.source === 'codex')) card.appendChild(el('details', {}, el('summary', {}, t('collectors.addCodex')),
    el('p', {class:'hint'}, t('collectors.addCodexHint')),
    el('pre', {style:'white-space:pre-wrap'}, 'ccquota codex add work\nccquota codex login work\nccquota codex run work')));
  return card;
}

export function accountUsageCard(result, accounts = []) {
  if (result.status !== 'fulfilled' || !result.value.observations?.length) return null;
  const card = el('div', { class: 'card' }, el('h2', {}, t('accountUsage.title')),
    el('p', { class: 'hint' }, result.value.note));
  const names = new Map(accounts.map((a) => [a.account_uuid, a.email || a.display_name || a.account_uuid]));
  for (const u of result.value.observations) {
    const total = u.lifetime_tokens == null ? t('accountUsage.notProvided') : fmtInt(u.lifetime_tokens);
    card.appendChild(el('h3', {}, names.get(u.account_uuid) || u.account_uuid));
    card.appendChild(el('p', {}, t('accountUsage.lifetime', { total })));
    card.appendChild(el('p', {}, t('accountUsage.local', {
      tokens: fmtInt(u.local_attributed_tokens || 0), requests: fmtInt(u.local_attributed_requests || 0) })));
    card.appendChild(el('p', { class: 'hint' }, t('accountUsage.observed', {
      when: new Date(u.observed_at).toLocaleString(), n: (u.daily || []).length })));
    if (u.daily?.length) {
      const rows = u.daily.slice(-14);
      card.appendChild(el('details', {}, el('summary', {}, t('accountUsage.recentDaily')),
        el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, t('accountUsage.col.date')), el('th', {}, t('accountUsage.col.tokens')))),
          el('tbody', {}, rows.map((d) => el('tr', {}, el('td', {}, d.date), el('td', {}, fmtInt(d.tokens))))))));
    }
  }
  return card;
}
