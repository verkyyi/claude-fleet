// web/dist/admin/nodes.js — Machines, at /nodes (claude-fleet#1990): one card per
// computer that runs sessions (load trend, status, sessions, version) — a
// client device (role client) is on All devices instead, one grey line
// pointing there (claude-fleet#2795) — the
// maintenance switch behind a confirm, «add a machine» (a one-time join code,
// its command and countdown, waiting for the machine to join), and the SPOT
// switch. A code from 「添加机器」 is trusted and managed (claude-fleet#2214,
// POST /v1/fleet/nodes/join-codes), and each card says where its trust came
// from and, for a managed machine, its 期望 / 实际 version.
// Reads /v1/nodes, /v1/fleet/join-codes, /v1/fleet/settings; writes
// fleet.node_maintenance.<machine> and fleet.spot, and 「移除」 (claude-fleet#1928)
// retires every enrollment on the machine through /v1/fleet/nodes/retire — its
// token stops working and its card leaves the page. Below the cards, every
// machine's 服务与定时任务 (claude-fleet#2526, lib/services.js). An admin's.
import { Shell } from '../app-shell.js';
import { esc, ic, spark, relTime } from '../lib/shell.js';
import { machineCards, clientMachines, joined, countdown } from '../lib/admin.js';
import { serviceRows, servicesSection, svcClick } from '../lib/services.js';
import { machineHref, listNav } from '../lib/machine-view.js';
import { t } from '../lib/i18n.js';

const join = { label: '', expires: 0, timer: 0, tick: 0 };

function stop() { clearTimeout(join.timer); clearInterval(join.tick); }

function status(m) {
  if (m.status === 'online') return `<span class="status"><span class="dot ok"></span>${esc(t('ui.mach.online'))}</span>`;
  if (m.status === 'maintenance') return `<span class="status"><span class="dot warn"></span>${esc(t('ui.mach.maint'))}</span>`;
  return `<span class="status"><span class="dot bad"></span>${esc(t('ui.mach.lost'))}</span>`;
}

function card(m) {
  const load = m.loadCore == null || m.status === 'lost' ? '—' : m.loadCore.toFixed(2);
  const trend = m.hist.length ? spark(m.hist, m.status === 'lost' ? 'var(--bad)' : 'var(--brand)', true)
    : `<div class="ghostrow" style="font-size:12px">${esc(t('ui.mach.noTrend'))}</div>`;
  const why = m.maintenance ? `<span style="font-size:12px;color:var(--muted)">${esc(t('ui.mach.maintWhy', { reason: m.maintenance.reason || '—', by: m.maintenance.by || '—', when: relTime(m.maintenance.since) }))}</span>` : '';
  const btn = m.status === 'maintenance' || (m.status === 'lost' && m.maintenance)
    ? `<button class="btn sm" data-act="leave" data-m="${esc(m.name)}">${ic('wrench')}${esc(t('ui.mach.endMaint'))}</button>`
    : m.status === 'online' ? `<button class="btn sm" data-act="enter" data-m="${esc(m.name)}" data-n="${m.sessions == null ? '' : m.sessions}">${ic('wrench')}${esc(t('ui.mach.maintBtn'))}</button>` : '';
  const rm = m.eps.length ? `<button class="btn sm ghost" data-act="remove" data-m="${esc(m.name)}" data-eps="${esc(m.eps.join(' '))}" data-n="${m.sessions == null ? '' : m.sessions}">${ic('trash')}${esc(t('ui.mach.removeBtn'))}</button>` : '';
  const href = machineHref(m.host, true);
  return `<div class="panel mc" data-href="${esc(href)}" tabindex="0"><div class="mc-h"><a href="${esc(href)}" style="color:inherit"><b>${esc(m.label)}</b></a>${m.label !== m.name ? `<span class="mono" style="opacity:.6">${esc(m.name)}</span>` : ''}${m.kind === 'ephemeral' ? `<span class="chip brand">${esc(t('ui.mach.spot'))}</span>` : ''}${status(m)}</div>${why}` +
    trend +
    `<div class="stats"><div><b>${m.sessions == null ? '?' : m.sessions}</b>${esc(t('ui.mach.sessions'))}</div><div><b>${esc(load)}</b>${esc(t('ui.mach.load'))}</div><div><b>${esc(m.version || '—')}</b>${esc(t('ui.mach.version'))}</div>${m.spare == null ? '' : `<div><b>${m.spare}</b>${esc(t('ui.mach.spare', { used: m.used ?? '?', cap: m.cap ?? '?' }))}</div>`}${desired(m)}</div>` +
    trustLine(m) + linksLine(m) + refusedLine(m) +
    `<div class="mc-f"><span>${esc(t('ui.mach.seen', { when: relTime(m.seen) }))}</span><span>${btn}${rm}</span></div></div>`;
}

// trustLine says whether the machine is trusted and where that came from
// (claude-fleet#2214): the join code, the operator, the old machine-name rule,
// or a borrowed name that inherits nothing.
function trustLine(m) {
  if (!m.trust) return '';
  const src = m.trustSource ? t('ui.mach.trustSrc.' + m.trustSource) : '';
  const word = t(m.trust === 'trusted' ? 'ui.mach.trusted' : 'ui.mach.untrusted');
  return `<div style="font-size:12px;color:${m.trustSource === 'name_borrowed' ? 'var(--bad)' : 'var(--muted)'}">${esc(src ? t('ui.mach.trustFrom', { trust: word, src }) : word)}</div>`;
}

// linksLine is how many connections the machine holds and the logins under
// them (claude-fleet#2333): one node program per machine reads 「1 条连接」.
function linksLine(m) {
  if (m.links == null || m.status === 'lost') return '';
  return `<div style="font-size:12px;color:var(--muted)">${esc(t('ui.mach.links', { n: m.links, logins: m.logins.join(t('ui.mach.loginSep')) || '—' }))}</div>`;
}

// refusedLine names the logins the hub will not take on the machine's node
// program (claude-fleet#2501) — a token reissued away: 令牌失效 · 需要 relogin.
function refusedLine(m) {
  const ls = Object.keys(m.refused || {}).sort();
  if (!ls.length) return '';
  return ls.map((l) => `<div style="font-size:12px;color:var(--bad)" title="${esc(m.refused[l])}">${esc(t('ui.mach.refused', { login: l }))}</div>`).join('');
}

// desired is the 期望 / 实际 pair of a managed machine; nothing for any other.
function desired(m) {
  const d = m.desired;
  if (!d) return '';
  const rel = (v) => (v ? String(v).slice(0, 7) : '');
  const show = (n, r) => (n ? `v${n}${r ? ' · ' + rel(r) : ''}` : '—');
  const off = d.want !== d.reached || !!d.diff;
  return `<div><b>${esc(show(d.want, d.want_release))}</b>${esc(t('ui.mach.want'))}</div>` +
    `<div><b${off ? ' style="color:var(--warn)"' : ''} title="${esc(d.diff || '')}">${esc(show(d.reached, d.release))}</b>${esc(t('ui.mach.reached'))}</div>`;
}

function joinModal(ctx, j) {
  ctx.modal(`<div class="modal-h"><h3>${esc(t('ui.mach.add.title'))}</h3><button class="btn ghost sm" data-shell="close" aria-label="${esc(t('ui.close'))}">${ic('x')}</button></div><div class="modal-b">` +
    `<p>${esc(t('ui.mach.add.run'))}</p><div class="cmdbox"><span>${esc(j.command)}</span><button class="btn sm" data-shell="copy" data-text="${esc(j.command)}" aria-label="${esc(t('ui.copy'))}">${ic('copy')}</button></div>` +
    `<dl class="kv"><dt>${esc(t('ui.mach.add.code'))}</dt><dd class="mono">${esc(j.code)}</dd><dt>${esc(t('ui.mach.add.works'))}</dt><dd>${esc(t('ui.mach.add.once'))}</dd><dt>${esc(t('ui.mach.add.expires'))}</dt><dd class="mono" id="exp">${esc(countdown(j.expires_at))}</dd></dl>` +
    `<div class="waiting" id="joinwait"><span class="spinner"></span>${esc(t('ui.mach.add.waiting'))}</div></div>` +
    `<div class="modal-f"><button class="btn ghost" data-shell="close">${esc(t('ui.close'))}</button></div>`);
}

async function pollJoin(ctx) {
  clearTimeout(join.timer);
  if (!document.getElementById('joinwait')) { stop(); return; }
  try {
    const hit = joined(await ctx.api('/v1/fleet/join-codes'), join.label);
    if (hit) {
      stop();
      const w = document.getElementById('joinwait');
      if (w) w.innerHTML = `${ic('check')}<b>${esc(t('ui.mach.add.joined', { host: hit.joined_host || '—' }))}</b>`;
      ctx.toast(t('ui.mach.add.joined', { host: hit.joined_host || '—' }));
      ctx.refresh();
      return;
    }
  } catch { /* keep waiting */ }
  join.timer = ctx.after(3000, () => pollJoin(ctx));
}

export default Shell.mount('machines', async (ctx) => {
  const [snapR, setR] = await Promise.allSettled([ctx.api('/v1/nodes'), ctx.api('/v1/fleet/settings')]);
  if (snapR.status === 'rejected') throw snapR.reason;
  const snap = snapR.value;
  const ms = machineCards(snap);
  ctx.setCount('machines', ms.length);
  const settings = setR.status === 'fulfilled' ? setR.value : null;
  const spotRow = settings && (settings.hub || []).find((h) => h.key === 'fleet.spot');
  const spotOn = !!(spotRow && spotRow.value === 'on');
  const spot = snap.spot;
  const spotLine = !spot ? t('ui.mach.spotNone')
    : spotOn ? t('ui.mach.spotOn', { max: spot.max || 0, idle: spot.idle_minutes || 30, n: (spot.nodes || []).length })
      : t('ui.mach.spotOff', { n: (spot.nodes || []).length });

  const cards = ms.length ? `<div class="mcards">${ms.map(card).join('')}</div>`
    : `<div class="panel"><div class="empty">${ic('server')}<b>${esc(t('ui.mach.empty'))}</b><span>${esc(t('ui.mach.emptySub'))}</span><button class="btn primary" data-act="add">${ic('plus')}${esc(t('ui.mach.addBtn'))}</button></div></div>`;
  // 服务与定时任务 (claude-fleet#2526): every machine's register, when any
  const svcs = serviceRows(snap);
  // The client devices left off (claude-fleet#2795): said, so none looks lost.
  const nClient = clientMachines(snap).length;
  const clientsLine = nClient ? `<p class="sub" style="font-size:12.5px;color:var(--muted);margin:-4px 0 14px"><a href="/admin/devices" data-clients style="color:inherit">${esc(t('ui.mach.clients', { n: nClient }))}</a></p>` : '';
  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.mach.lead'))}</p></div><div class="acts"><button class="btn primary" data-act="add">${ic('plus')}${esc(t('ui.mach.addBtn'))}</button></div></div>` +
    cards + clientsLine + (svcs.length ? servicesSection(svcs) : '') +
    `<div class="panel"><div class="panel-h"><div><h3>${esc(t('ui.mach.spotTitle'))}</h3><span class="sub">${esc(t('ui.mach.spotSub'))}</span></div>` +
    `<button class="switch" role="switch" aria-checked="${spotOn}" data-act="spot" aria-label="${esc(t('ui.mach.spotTitle'))}"${settings ? '' : ' disabled'}></button></div>` +
    `<div class="panel-b" style="font-size:13px;color:var(--muted)">${esc(spotLine)}</div></div>`;

  const put = async (key, value, ok) => {
    try {
      await ctx.api('/v1/fleet/settings', { method: 'PUT', json: { key, value } });
      ctx.toast(ok);
      await ctx.refresh();
    } catch (err) { ctx.toast(t('ui.err.action', { e: err.message })); }
  };
  // A card opens the machine's page (claude-fleet#2796): a click off its
  // buttons, or j/k to pick and ↵.
  listNav(ctx, '.mc[data-href]');
  ctx.el.onclick = async (e) => {
    if (svcClick(ctx, e, svcs)) return;
    const b = e.target.closest('[data-act]');
    if (!b) return;
    const m = b.dataset.m;
    if (b.dataset.act === 'enter') {
      const n = b.dataset.n === '' ? '?' : b.dataset.n;
      // The confirm clears its layer before it calls back: keep the reason
      // as it is typed.
      let reason = t('ui.mach.reasonDefault');
      ctx.confirm(t('ui.mach.enterQ', { m }), esc(t('ui.mach.enterBody', { n })) +
        `</p><label class="f">${esc(t('ui.mach.reason'))}<input class="input" id="mreason" maxlength="200" value="${esc(reason)}"></label><p>`,
      t('ui.mach.enterBtn'), () => put('fleet.node_maintenance.' + m, reason.trim() || t('ui.mach.reasonDefault'), t('ui.mach.entered', { m })));
      const inp = document.getElementById('mreason');
      if (inp) inp.oninput = () => { reason = inp.value; };
    } else if (b.dataset.act === 'leave') {
      put('fleet.node_maintenance.' + m, '', t('ui.mach.left', { m }));
    } else if (b.dataset.act === 'remove') {
      const eps = (b.dataset.eps || '').split(' ').filter(Boolean);
      const n = b.dataset.n === '' ? '?' : b.dataset.n;
      ctx.confirm(t('ui.mach.removeQ', { m }), esc(t('ui.mach.removeBody', { n })), t('ui.mach.removeBtn'), async () => {
        try {
          for (const id of eps) await ctx.api('/v1/fleet/nodes/retire', { json: { endpoint_id: id, reason: 'removed on the machines page' } });
          ctx.toast(t('ui.mach.removed', { m }));
          await ctx.refresh();
        } catch (err) { ctx.toast(t('ui.err.action', { e: err.message })); }
      });
    } else if (b.dataset.act === 'spot') {
      put('fleet.spot', spotOn ? 'off' : 'on', t(spotOn ? 'ui.mach.spotOffToast' : 'ui.mach.spotOnToast'));
    } else if (b.dataset.act === 'add') {
      try {
        stop();
        join.label = 'web-' + Date.now().toString(36);
        // 托管 (claude-fleet#2214): the code carries trust — the machine holds
        // it on its own identity, no separate 「标记可信」 step.
        const j = await ctx.api('/v1/fleet/nodes/join-codes', { json: { label: join.label } });
        joinModal(ctx, j);
        join.tick = ctx.every(1000, () => {
          const el = document.getElementById('exp');
          if (!el) { stop(); return; }
          el.textContent = countdown(j.expires_at);
        });
        pollJoin(ctx);
      } catch (err) { ctx.toast(t('ui.err.action', { e: err.message })); }
    }
  };
}, { dispose: stop });
