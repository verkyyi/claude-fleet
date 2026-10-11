// web/dist/lib/usage-view.js — 我的用量 as one page (claude-fleet#3229, EPIC
// #3225 C4), with no DOM: what is left of the viewer's own limit, today and
// this week, each day split Claude / Codex, the models by name, and where it
// went — by task, by repo, by batch — with a row's drawer. usage.js fetches
// /v1/me/usage (C2, me_usage.go) and draws; web/test/usage-view.test.mjs pins
// these.
//
// Only the viewer's limit is shown, never the pool's windows (those are an
// admin's, Subscriptions). No limit set = 「不限额」 and no remaining number:
// remaining is limit − used, worked out here when the hub left it out.
import { esc, ic, fmtTokens, spark } from './shell.js';
import { t, fmtDate } from './i18n.js';
import { areaChart, stack, delta, hb, fullFrom, utcMidnight } from './pages.js';

const DAY = 86400000;

/** RANGES are the page's range switch: [?range= value, t() key]. */
export const RANGES = Object.freeze([['today', 'ui.use.r.today'], ['7d', 'ui.use.r.7d'], ['30d', 'ui.use.r.30d']]);

/** rangeOf is a ?range= value the page takes, else 7d (the hub's default). */
export const rangeOf = (v) => (RANGES.some((r) => r[0] === v) ? v : '7d');

/** MODES are where-it-went's three ways: [work key, t() key]. */
export const MODES = Object.freeze([['issue', 'ui.use.by.issue'], ['repo', 'ui.use.by.repo'], ['epic', 'ui.use.by.epic']]);

const num = (v) => Number(v) || 0;

/** repoName is owner/name's name — the row says the repo, the title the owner. */
export const repoName = (r) => String(r || '').split('/').pop();

/** epicNum is the batch's number off owner/name#N, '' when none. */
export const epicNum = (e) => { const m = /#(\d+)$/.exec(String(e || '')); return m ? m[1] : ''; };

function usedTile(label, used, limit, reset) {
  used = num(used); limit = num(limit);
  const left = Math.max(0, limit - used);
  const p = Math.round(used / limit * 100);
  const lvl = p >= 100 ? 'bad' : p >= 70 ? 'warn' : '';
  const note = t('ui.use.limitNote', { limit: fmtTokens(limit), used: fmtTokens(used) }) +
    (reset ? ' · ' + t('ui.use.resetAt', { at: fmtDate(reset) }) : '');
  return `<div class="panel kpi"><span class="lbl">${esc(label)}</span><span class="val">${esc(t('ui.use.left', { n: fmtTokens(left) }))}</span>` +
    `<div class="win"><div class="track"><i class="${lvl}" style="width:${Math.min(100, p)}%"></i></div></div>` +
    `<span class="delta" style="color:var(${lvl === 'bad' ? '--bad' : '--muted'})">${esc(note)}</span></div>`;
}

const plainTile = (label, val, note) => `<div class="panel kpi"><span class="lbl">${esc(label)}</span><span class="val">${esc(val)}</span><span class="delta" style="color:var(--muted)">${esc(note)}</span></div>`;

/** limitTiles are the first tiles: what is left this week (and in 5 hours,
 *  only when that window is set), or one 「不限额」 tile with no number left. */
export function limitTiles(lim) {
  const l = lim || {};
  const week = num(l.limit_week) > 0, h5 = num(l.limit_5h) > 0;
  if (!l.set || (!week && !h5)) return [plainTile(t('ui.use.myLimit'), t('ui.use.unlimited'), t('ui.use.unlimitedHint'))];
  const out = [];
  if (week) out.push(usedTile(t('ui.use.weekLeft'), l.used_week, l.limit_week, l.reset_week));
  if (h5) out.push(usedTile(t('ui.use.h5Left'), l.used_5h, l.limit_5h, l.reset_5h));
  return out;
}

/** kpis are the four tiles: the limit's, today, 7 days, and — while no
 *  5-hour window is set — the last 5 hours as a record. Yesterday and last
 *  week are compared only when pool usage was recorded from their start
 *  (since_first, fullFrom): pool_usage began on one day, and a percent off a
 *  near-empty base reads +300805% (claude-fleet#3230). */
export function kpis(u, now = Date.now()) {
  const x = u || {}, l = x.limit || {};
  const days = Array.isArray(x.days) ? x.days : [];
  const trend = days.slice(-7).map((d) => num(d.claude) + num(d.codex));
  const dt = delta(x.today, x.today_prev, 'ui.use.vsYesterday', fullFrom(x.since_first, utcMidnight(now) - DAY) ? '' : 'ui.use.noFullYesterday');
  const dw = delta(x.week, x.week_prev, 'ui.use.vsLastWeek', fullFrom(x.since_first, now - 14 * DAY) ? '' : 'ui.use.noFullWeek');
  const tiles = limitTiles(l);
  tiles.push(`<div class="panel kpi"><span class="lbl">${esc(t('ui.use.today'))}</span><span class="val">${esc(fmtTokens(num(x.today)))}</span>${trend.some((v) => v) ? spark(trend, 'var(--brand)', true) : ''}<span class="delta${dt.down ? ' down' : ''}"${dt.muted ? ' style="color:var(--muted)"' : ''}>${esc(dt.text || ' ')}</span></div>`);
  tiles.push(`<div class="panel kpi"><span class="lbl">${esc(t('ui.use.week7'))}</span><span class="val">${esc(fmtTokens(num(x.week)))}</span><span class="delta${dw.down ? ' down' : ''}"${dw.muted ? ' style="color:var(--muted)"' : ''}>${esc(dw.text || ' ')}</span></div>`);
  if (!(l.set && num(l.limit_5h) > 0)) {
    tiles.push(plainTile(t('ui.use.h5Used'), fmtTokens(num(l.used_5h)), t(l.set ? 'ui.use.h5NoLimit' : 'ui.use.h5Record')));
  }
  return tiles;
}

/** dayChart is the per-day stacked chart (Claude below, Codex on top), or
 *  the empty state when nothing was counted. */
export function dayChart(days) {
  const list = Array.isArray(days) ? days : [];
  if (!list.some((d) => num(d.claude) + num(d.codex) > 0)) {
    return `<div class="empty">${ic('list')}<b>${esc(t('ui.use.none'))}</b><span>${esc(t('ui.use.noneHint'))}</span></div>`;
  }
  return areaChart(stack(list.map((d) => num(d.claude)), list.map((d) => num(d.codex))), list.map((d) => d.day));
}

/** modelBars are the models by their human name, Codex in its own colour. */
export function modelBars(models) {
  const rows = (Array.isArray(models) ? models : []).filter((m) => num(m.tokens) > 0)
    .map((m) => [m.name || '—', num(m.tokens), m.provider === 'codex' ? 'var(--codex)' : 'var(--brand)']);
  return hb(rows, 'var(--brand)', false);
}

/** workRows are one breakdown's rows as the page draws them: a title, the
 *  task's repo and batch, the share of the range. The hub's "none" row is
 *  always there (each breakdown sums to the total); a row at 0 is dropped. */
export function workRows(work, mode) {
  const list = (work && Array.isArray(work[mode]) ? work[mode] : []).filter((r) => num(r.tokens) > 0);
  const total = list.reduce((s, r) => s + num(r.tokens), 0) || 1;
  return list.map((r) => {
    const n = epicNum(r.epic);
    let title;
    if (r.kind === 'orch') title = t('ui.use.orch');
    else if (r.kind === 'none') title = t('ui.use.none.' + mode);
    else if (mode === 'issue') title = r.issue ? `#${r.issue}${r.title ? ' ' + r.title : ''}` : (r.title || '—');
    else if (mode === 'repo') title = repoName(r.repo || r.title);
    else title = n ? `#${n}${r.epic_title || r.title ? ' ' + (r.epic_title || r.title) : ''}` : (r.title || '—');
    return {
      item: r, kind: r.kind, title, muted: r.kind === 'orch' || r.kind === 'none',
      repo: mode === 'issue' && r.repo ? repoName(r.repo) : '', repoFull: r.repo || '',
      epic: mode === 'issue' && n ? t('ui.use.batchChip', { n }) : '', epicTitle: r.epic_title || '',
      tokens: num(r.tokens), pct: Math.round(num(r.tokens) / total * 100),
    };
  });
}

const bar = (r) => `<div class="win"><div class="track"><i style="width:${r.pct}%;background:var(${r.muted ? '--muted' : '--brand'})"></i></div></div>`;
const name = (r) => `<b style="font-weight:${r.muted ? 400 : 500}${r.muted ? ';color:var(--muted)' : ''}">${esc(r.title)}</b>`;

/** workTable is a breakdown as a table (desktop), each row data-row=i. */
export function workTable(rows, mode) {
  if (!rows.length) return `<div class="panel-b"><div class="ghostrow">${esc(t('ui.use.noWork'))}</div></div>`;
  const head = mode === 'issue'
    ? `<th>${esc(t('ui.use.col.task'))}</th><th>${esc(t('ui.use.col.repo'))}</th><th>${esc(t('ui.use.col.batch'))}</th>`
    : `<th>${esc(t(mode === 'repo' ? 'ui.use.col.repo' : 'ui.use.col.batch'))}</th>`;
  const dash = '<span style="color:var(--muted)">—</span>';
  const body = rows.map((r, i) => {
    const cells = mode === 'issue'
      ? `<td>${name(r)}</td><td class="mono" title="${esc(r.repoFull)}">${r.repo ? esc(r.repo) : dash}</td><td>${r.epic ? `<span class="chip brand" title="${esc(r.epicTitle)}">${esc(r.epic)}</span>` : dash}</td>`
      : `<td>${name(r)}</td>`;
    return `<tr data-row="${i}" tabindex="0" style="cursor:pointer">${cells}<td style="width:30%">${bar(r)}</td><td class="mono r">${esc(fmtTokens(r.tokens))}</td><td class="mono r" style="color:var(--muted)">${r.pct}%</td></tr>`;
  }).join('');
  return `<div class="tw"><table class="t"><thead><tr>${head}<th>${esc(t('ui.use.col.share'))}</th><th class="r">${esc(t('ui.use.col.tokens'))}</th><th class="r"></th></tr></thead><tbody>${body}</tbody></table></div>`;
}

/** workList is a breakdown one line a row (phone width), each data-row=i;
 *  a task's repo · batch · share under it. */
export function workList(rows, mode) {
  if (!rows.length) return `<div class="panel-b"><div class="ghostrow">${esc(t('ui.use.noWork'))}</div></div>`;
  return '<div class="panel-b" style="display:grid;gap:12px">' + rows.map((r, i) => {
    const sub = mode === 'issue' ? [r.repo, r.epic].filter(Boolean).join(' · ') : '';
    return `<div data-row="${i}" tabindex="0" style="display:grid;gap:4px;cursor:pointer"><div style="display:flex;justify-content:space-between;gap:10px;font-size:13.5px">${name(r)}<span class="mono" style="white-space:nowrap">${esc(fmtTokens(r.tokens))}</span></div>${bar(r)}` +
      (sub ? `<span style="font-size:12px;color:var(--muted)">${esc(`${sub} · ${r.pct}%`)}</span>` : '') + '</div>';
  }).join('') + '</div>';
}

/** workDrawer is a row's drawer. A task (or 编排与管家, or 没挂在任务上): its
 *  sessions, models, where it ran (service node · login — said here only,
 *  never a way to split) and whose name it is under. A repo or a batch: the
 *  tasks in it, from the task breakdown. */
export function workDrawer(row, mode, ctx) {
  const c = ctx || {};
  const r = row.item || {};
  const close = `<button class="btn ghost sm" data-shell="close" aria-label="${esc(t('ui.close'))}">${ic('x')}</button>`;
  const rangeWord = t(c.rangeKey || 'ui.use.r.7d');
  const sub = [row.repoFull, row.epicTitle && row.epic ? `${row.epic} ${row.epicTitle}` : row.epic, `${rangeWord} ${fmtTokens(row.tokens)}`].filter(Boolean).join(' · ');
  const head = `<div class="modal-h"><div style="display:grid;gap:2px;min-width:0"><h3>${esc(row.title)}</h3><span style="font-size:12.5px;color:var(--muted)">${esc(sub)}</span></div>${close}</div>`;
  if (mode !== 'issue') {
    const all = workRows(c.work, 'issue');
    const inside = all.filter((x) => (mode === 'repo'
      ? (row.kind === 'none' ? !x.repoFull : x.repoFull === r.repo)
      : (row.kind === 'none' ? !x.item.epic : x.item.epic === r.epic)));
    const list = inside.length
      ? '<div class="hb">' + inside.map((x) => `<div class="hb-row"><span class="name" title="${esc(x.title)}">${esc(x.title)}</span>${bar({ ...x, pct: Math.round(x.tokens / (row.tokens || 1) * 100) })}<span class="v">${esc(fmtTokens(x.tokens))}</span></div>`).join('') + '</div>'
      : `<div class="ghostrow">${esc(t('ui.use.noWork'))}</div>`;
    return head + `<div class="modal-b"><h4 style="margin:0 0 10px;font-size:13px">${esc(t('ui.use.d.tasks'))}</h4>${list}</div>`;
  }
  const sessions = Array.isArray(r.sessions) && r.sessions.length ? r.sessions.map((s) => esc(s)).join('<br>') : '—';
  const models = Array.isArray(r.models) && r.models.length
    ? r.models.map((m) => `${esc(m[0])} <span class="mono" style="color:var(--muted)">${esc(fmtTokens(num(m[1])))}</span>`).join('<br>') : '—';
  const where = r.node || r.login
    ? esc(t('ui.use.d.node')) + ` <b>${esc(r.node || '—')}</b>` + (r.login ? ` · ${esc(t('ui.use.d.login'))} <span class="mono">${esc(r.login)}</span>` : '')
    : '—';
  return head + `<div class="modal-b"><dl class="kv"><dt>${esc(t('ui.use.d.sessions'))}</dt><dd class="mono">${sessions}</dd>` +
    `<dt>${esc(t('ui.use.d.models'))}</dt><dd>${models}</dd><dt>${esc(t('ui.use.d.where'))}</dt><dd>${where}</dd>` +
    `<dt>${esc(t('ui.use.d.whose'))}</dt><dd>${esc(c.me || t('ui.me.you'))} <span style="color:var(--muted)">${esc(t('ui.use.d.whoseWhy'))}</span></dd></dl>` +
    `<p style="font-size:12.5px;color:var(--muted);margin-top:16px">${esc(t('ui.use.d.whereNote'))}</p></div>`;
}
