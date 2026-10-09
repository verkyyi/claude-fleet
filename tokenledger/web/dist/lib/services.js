// web/dist/lib/services.js — 服务与定时任务 (claude-fleet#2526, EPIC #2524 C2):
// the background services and scheduled tasks registered on a machine's daemon
// (`fleet service add`), as the hub hands them on /v1/nodes —
// `machines[].services`, already cut to the viewer's own (machine, login)s.
// Two tables (常驻 / 定时) of 机器 · 登录 · 名称 · 状态 · 上次 · 下次 · 最近日志, a
// failed one red, and a drawer (ctx.drawer) with its log's last line. The same table
// `fleet ls --services` prints (bin/fleet-services.py) and the same failed set
// as the hub's service_failed alert. No fetch for the tables: the page that
// shows them (我的机器, Machines) passes its /v1/nodes answer. The drawer's
// buttons (claude-fleet#2527, C3) — 停 · 起 · 重启 · 现在跑一次 · 改计划 — post the
// hub's service_control, the write `fleet service|task stop|start|restart|run|
// schedule` sends too; the hub refuses another login's entry (403).
// web/test/services.test.mjs.
import { t } from './i18n.js';
import { esc, ic, relTime } from './shell.js';
import { fmtIn } from './admin.js';

/** FAILED is the states that want a person (control.ServiceStatus.Failed). */
export const FAILED = ['down', 'failed', 'invalid', 'no_login'];

/** STATES is every state with a word: a service's, and a task's
 *  scheduled · retrying · ok (claude-fleet#2529). */
export const STATES = ['running', 'stopped', 'down', 'failed', 'invalid', 'no_login', 'scheduled', 'retrying', 'ok'];

/** serviceRows is every registered entry on snap's machines, by machine,
 *  login, name — failed or not. */
export function serviceRows(snap) {
  const out = [];
  for (const m of (snap && Array.isArray(snap.machines)) ? snap.machines : []) {
    const host = String(m.hostname || '');
    const label = m.alias || host.split('.')[0];
    for (const s of Array.isArray(m.services) ? m.services : []) {
      if (!s || !s.name) continue;
      out.push({
        host, machine: label, login: s.login || '', name: s.name, kind: s.kind === 'task' ? 'task' : 'service',
        state: s.state || 'unknown', failed: FAILED.includes(s.state),
        lastRun: s.last_run || s.started_at || null, nextRun: s.next_run || null,
        line: s.last_log_line || '', why: s.why || '', restarts: s.restarts || 0,
        rc: typeof s.last_rc === 'number' ? s.last_rc : null, at: m.services_at || null,
      });
    }
  }
  return out.sort((a, b) => a.machine.localeCompare(b.machine) || a.login.localeCompare(b.login) || a.name.localeCompare(b.name));
}

/** stateWord is a row's state as a person reads it. */
export function stateWord(r) {
  const w = t('ui.svc.st.' + (STATES.includes(r.state) ? r.state : 'unknown'));
  return r.state === 'down' && r.rc ? t('ui.svc.rc', { state: w, rc: r.rc }) : w;
}

function row(r, i, now) {
  const next = r.nextRun ? (fmtIn(r.nextRun, now) || relTime(r.nextRun, now)) : '—';
  return `<tr data-svc="${i}" style="cursor:pointer${r.failed ? ';color:var(--bad)' : ''}">` +
    `<td><b>${esc(r.machine)}</b></td><td class="mono">${esc(r.login)}</td><td class="mono">${esc(r.name)}</td>` +
    `<td><span class="chip ${r.failed ? 'bad' : r.state === 'running' || r.state === 'ok' ? 'ok' : r.state === 'retrying' ? 'warn' : ''}">${esc(stateWord(r))}</span></td>` +
    `<td class="mono">${esc(r.lastRun ? relTime(r.lastRun, now) : '—')}</td><td class="mono">${esc(next)}</td>` +
    `<td class="mono" style="max-width:28em;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${esc(r.line)}">${esc(r.line || '—')}</td></tr>`;
}

function table(kind, rows, all, now) {
  const head = ['ui.col.machine', 'ui.svc.colLogin', 'ui.svc.colName', 'ui.svc.colState', 'ui.svc.colLast', 'ui.svc.colNext', 'ui.svc.colLine']
    .map((k) => `<th>${esc(t(k))}</th>`).join('');
  const body = rows.length ? rows.map((r) => row(r, all.indexOf(r), now)).join('')
    : `<tr><td colspan="7"><div class="ghostrow" style="font-size:12px">${esc(t('ui.svc.none.' + kind))}</div></td></tr>`;
  const bad = rows.filter((r) => r.failed).length;
  return `<div class="panel" id="svc-${kind}"><div class="panel-h"><div><h3>${esc(t('ui.svc.title.' + kind))}</h3>` +
    `<span class="sub">${esc(bad ? t('ui.svc.failedN', { n: bad, total: rows.length }) : t('ui.svc.count', { n: rows.length }))}</span></div></div>` +
    `<div class="tw"><table class="t"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div></div>`;
}

/** servicesSection is the two tables — 常驻服务 and 定时任务 — for rows. */
export function servicesSection(rows, now = Date.now()) {
  return table('service', rows.filter((r) => r.kind === 'service'), rows, now) +
    table('task', rows.filter((r) => r.kind === 'task'), rows, now);
}

/** actionsFor is the drawer's buttons for a row, as service_control actions: a
 *  stopped entry starts; a service restarts or stops; a task runs now, takes a
 *  new schedule or stops. An entry the daemon will not run has none. */
export function actionsFor(r) {
  if (r.state === 'invalid' || r.state === 'no_login') return [];
  if (r.state === 'stopped') return ['start'];
  return r.kind === 'task' ? ['run_now', 'set_schedule', 'stop'] : ['restart', 'stop'];
}

/** svcRequest is the service_control body for one action on a row. */
export function svcRequest(r, action, extra = {}) {
  const rnd = Math.random().toString(36).slice(2, 8);
  return { machine: r.host, login: r.login, name: r.name, action, ...extra,
    idempotency_key: `web-${action}-${Date.now().toString(36)}-${rnd}` };
}

/** svcAct posts one action and says how it went; the drawer closes. */
export async function svcAct(ctx, r, action, extra = {}) {
  const what = t('ui.svc.act.' + action);
  try {
    const op = await ctx.api('/v1/fleet/service_control', { json: svcRequest(r, action, extra) });
    const err = op && op.result && op.result.error;
    if (op && op.status === 'failed') ctx.toast(t('ui.svc.refused', { what, why: (err && err.message) || '' }));
    else if (op && op.status === 'succeeded') ctx.toast(t(action === 'run_now' ? 'ui.svc.ranNow' : 'ui.svc.done', { what, name: r.name }));
    else ctx.toast(t('ui.svc.sent', { what, name: r.name }));
  } catch (e) {
    ctx.toast(t('ui.svc.refused', { what, why: e.message }));
  }
  if (ctx.close) ctx.close();
}

/** svcDrawerClick handles a click inside a row's drawer: an action button
 *  posts it; 改计划 first opens its form, whose 保存 posts set_schedule. */
export function svcDrawerClick(ctx, e, r, root) {
  const b = e.target && e.target.closest ? e.target.closest('[data-svc-act]') : null;
  if (!b) return false;
  const act = b.dataset.svcAct;
  if (act === 'set_schedule') {
    const f = root && root.querySelector('[data-svc-sched]');
    if (f) f.hidden = false;
    return true;
  }
  if (act === 'save_schedule') {
    const v = (sel) => ((root && root.querySelector(sel)) || {}).value || '';
    const at = v('[data-svc-at]').trim(), tz = v('[data-svc-tz]').trim();
    if (!/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/.test(at)) { ctx.toast(t('ui.svc.badAt')); return true; }
    svcAct(ctx, r, 'set_schedule', tz ? { at, tz } : { at });
    return true;
  }
  svcAct(ctx, r, act);
  return true;
}

/** logDrawer is the drawer for one row: what it is, its state, its log's last
 *  line, the command that shows the whole log on the machine, and its buttons. */
export function logDrawer(r, now = Date.now()) {
  const kv = [
    ['ui.col.machine', r.machine], ['ui.svc.colLogin', r.login], ['ui.svc.colKind', t('ui.svc.kind.' + r.kind)],
    ['ui.svc.colState', stateWord(r) + (r.why ? ' — ' + r.why : '')],
    ['ui.svc.colLast', r.lastRun ? relTime(r.lastRun, now) : '—'],
    ['ui.svc.colNext', r.nextRun ? (fmtIn(r.nextRun, now) || relTime(r.nextRun, now)) : '—'],
  ].concat(r.kind === 'service' ? [['ui.svc.restarts', String(r.restarts)]] : []).map(([k, v]) => `<dt>${esc(t(k))}</dt><dd>${esc(v)}</dd>`).join('');
  const cmd = `fleet ${r.kind === 'task' ? 'task' : 'service'} logs ${r.name} -n 200`;
  const acts = actionsFor(r);
  return `<div class="modal-h"><h3>${esc(r.name)}</h3><button class="btn ghost sm" data-shell="close" aria-label="${esc(t('ui.close'))}">${ic('x')}</button></div>` +
    `<div class="modal-b"><dl class="kv">${kv}</dl>` +
    `<p>${esc(t('ui.svc.tail'))}</p><pre class="mono" style="white-space:pre-wrap;${r.failed ? 'color:var(--bad)' : ''}">${esc(r.line || t('ui.svc.noLine'))}</pre>` +
    `<p>${esc(t('ui.svc.more', { machine: r.machine }))}</p><div class="cmdbox"><span>${esc(cmd)}</span><button class="btn sm" data-shell="copy" data-text="${esc(cmd)}" aria-label="${esc(t('ui.copy'))}">${ic('copy')}</button></div>` +
    (r.at ? `<p style="font-size:12px;color:var(--muted)">${esc(t('ui.svc.at', { when: relTime(r.at, now) }))}</p>` : '') +
    (acts.includes('set_schedule') ? `<div data-svc-sched hidden style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">` +
      `<label>${esc(t('ui.svc.at.label'))} <input class="mono" data-svc-at size="5" placeholder="07:00"></label>` +
      `<label>${esc(t('ui.svc.tz.label'))} <input class="mono" data-svc-tz size="16" placeholder="Asia/Shanghai"></label>` +
      `<button class="btn sm solid" data-svc-act="save_schedule">${esc(t('ui.svc.save'))}</button></div>` : '') +
    `</div><div class="modal-f">` +
    acts.map((a) => `<button class="btn${a === 'stop' ? ' danger' : ''}" data-svc-act="${a}">${esc(t('ui.svc.act.' + a))}</button>`).join('') +
    `<button class="btn ghost" data-shell="close">${esc(t('ui.close'))}</button></div>`;
}

/** svcClick opens the drawer for a click on a row of servicesSection(rows);
 *  true when it was one. A page calls it first in its own el.onclick (one
 *  handler per page, so a re-draw never stacks listeners). */
export function svcClick(ctx, e, rows) {
  const tr = e.target && e.target.closest ? e.target.closest('tr[data-svc]') : null;
  const r = tr ? rows[Number(tr.dataset.svc)] : null;
  if (!r) return false;
  ctx.drawer(logDrawer(r));
  // the drawer lives in the shell's layer, outside the page: its own handler
  const d = typeof document !== 'undefined' ? document.querySelector('#layer .drawer') : null;
  if (d) d.onclick = (ev) => { svcDrawerClick(ctx, ev, r, d); };
  return true;
}
