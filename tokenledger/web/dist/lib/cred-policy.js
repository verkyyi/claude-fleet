// Subscription permissions: the hub owns identity resolution and verdicts.
// This editor only writes one scope through the audited administrator API.
import { esc, ic } from './shell.js';
import { t } from './i18n.js';

export const POLICY_PATH = '/v1/fleet/cred-policy';
export function policyEntry(view, scope, id) {
  return (view[scope === 'node' ? 'nodes' : 'users'] || []).find((x) => x.id === id);
}
export function policyMode(entry) {
  return !entry ? 'deny' : entry.error ? 'invalid' : entry.all ? 'all' : entry.allow.length ? 'selected' : 'deny';
}
const modeText = (mode) => ({ all: t('ui.policy.all'), selected: t('ui.policy.selected'), deny: t('ui.policy.deny'), invalid: t('ui.policy.invalid') })[mode];
const validID = (id) => /^(?:[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}|codex:account:[a-f0-9]{32})$/.test(id);

// Never guess an ID from a label. Keep selected IDs even after their
// credential was removed, so an unrelated edit cannot silently drop them.
export function policyChoices(credentials, entry, scope, id) {
  const choices = new Map();
  const missing = [];
  for (const c of credentials || []) {
    if (!['claude', 'codex'].includes(c.provider)) continue;
    if (scope === 'user' && !['pool', id].includes(c.principal_id)) continue;
    const uuid = String(c.account_uuid || '').toLowerCase();
    const label = `${c.provider === 'claude' ? 'Claude' : 'Codex'} · ${c.account}`;
    if (!validID(uuid)) { missing.push({ id: '', label }); continue; }
    const old = choices.get(uuid);
    choices.set(uuid, { id: uuid, label: old ? old.label + ' / ' + label : label });
  }
  for (const uuid of entry?.allow || []) {
    if (!choices.has(uuid)) choices.set(uuid, { id: uuid, label: t('ui.policy.unavailable') });
  }
  return [...choices.values(), ...missing];
}
export function policyPayload(scope, id, mode, selected) {
  if (!['node', 'user'].includes(scope) || !id) throw new Error(t('ui.policy.choose'));
  if (!['all', 'deny', 'selected'].includes(mode)) throw new Error(t('ui.policy.chooseMode'));
  const allow = mode === 'all' ? null : mode === 'deny' ? [] : [...new Set(selected)].sort();
  if (mode === 'selected' && !allow.length) throw new Error(t('ui.policy.chooseSubscriptions'));
  if (allow?.some((uuid) => !validID(uuid))) throw new Error(t('ui.policy.missingID'));
  return mode === 'all' ? { scope, id, allow, all: true } : { scope, id, allow };
}
const fingerprint = (entry) => JSON.stringify(entry ? { all: !!entry.all, allow: [...entry.allow].sort(), error: entry.error || '' } : null);

export async function savePolicy(api, before, payload) {
  const latest = await api(POLICY_PATH);
  if (fingerprint(policyEntry(latest, payload.scope, payload.id)) !== fingerprint(before)) {
    throw new Error(t('ui.policy.changed'));
  }
  // The API has no revision token: this detects changes before saving, but
  // is not an atomic compare-and-set across simultaneous administrators.
  return api(POLICY_PATH, { method: 'PUT', json: payload });
}

export function effectiveHTML(effective) {
  const rows = effective.accounts || [];
  return `<p class="sub">${esc(t('ui.policy.resultNote'))}</p>` + (rows.length
    ? `<div class="tw"><table class="t"><thead><tr><th>${esc(t('ui.policy.subscription'))}</th><th>${esc(t('ui.policy.verdict'))}</th><th>${esc(t('ui.policy.reason'))}</th></tr></thead><tbody>` + rows.map((c) =>
      `<tr><td>${esc(c.provider)} · ${esc(c.account)}<br><small class="mono">${esc(c.account_uuid || t('ui.policy.missingID'))}</small></td><td>${esc(c.allowed ? t('ui.policy.allowed') : t('ui.policy.denied'))}</td><td>${esc(c.reason || '—')}</td></tr>`).join('') + '</tbody></table></div>'
    : `<p>${esc(t('ui.policy.empty'))}</p>`);
}

// A machine's display hostname is never an authorization key. Resolve the
// enrolled identity once, and collapse all its logins into one editable row.
export async function machineTargets(view, snapshot, api) {
  const targets = new Map((view.nodes || []).map((n) => [n.id, { id: n.id, label: n.id }]));
  const endpoints = [...new Map((snapshot.nodes || []).filter((n) => n.endpoint_id).map((n) => [n.endpoint_id, n])).values()];
  const answers = await Promise.allSettled(endpoints.map((n) => api(POLICY_PATH + '?endpoint_id=' + encodeURIComponent(n.endpoint_id))));
  const failed = [];
  answers.forEach((answer, i) => {
    const id = answer.status === 'fulfilled' && answer.value.effective?.machine;
    if (id) targets.set(id, { id, label: id });
    else failed.push({ id: 'unresolved:' + endpoints[i].endpoint_id, label: endpoints[i].hostname || endpoints[i].endpoint_id,
      error: answer.status === 'rejected' ? answer.reason.message : t('ui.policy.unknownMachine') });
  });
  return [...targets.values(), ...failed];
}
export function userTargets(view, users) {
  const targets = new Map((view.users || []).map((u) => [u.id, { id: u.id, label: u.id }]));
  for (const u of [...(users.users || []), ...(users.admins || [])]) {
    const id = u.principal || (u.github_id ? 'gh:' + u.github_id : '');
    if (id) targets.set(id, { id, label: u.login || id });
  }
  return [...targets.values()];
}
export function newDraft(entry) {
  return { before: entry, mode: policyMode(entry), selected: [...(entry?.allow || [])] };
}
export function draftChanged(draft) {
  const mode = policyMode(draft.before);
  return draft.mode !== mode || (mode === 'selected' && JSON.stringify([...draft.selected].sort()) !== JSON.stringify([...draft.before.allow].sort()));
}
const statusText = (entry) => policyMode(entry) === 'selected' ? t('ui.policy.count', { n: entry.allow.length }) : modeText(policyMode(entry));

// One object, one editor. Kept outside the machine page's polling region.
export async function mountObjectPolicy(ctx, root, scope, id) {
  if (!ctx.admin) return;
  root.innerHTML = `<p class="panel-b">${esc(t('ui.loading'))}</p>`;
  try {
    const [view, creds] = await Promise.all([ctx.api(POLICY_PATH), ctx.api('/v1/fleet/credentials')]);
    if (!root.isConnected) return;
    const draft = newDraft(policyEntry(view, scope, id));
    const legacyUnset = !draft.before && view.mode === 'legacy';
    if (legacyUnset) draft.mode = 'legacy';
    const choices = policyChoices(creds.credentials, draft.before, scope, id);
    root.innerHTML = `<div class="panel-h"><div><h3>${esc(t('ui.policy.title'))}</h3><p class="sub">${esc(t(scope === 'user' ? 'ui.policy.userHint' : 'ui.policy.machineHint'))}</p></div><span class="chip">${esc(legacyUnset ? t('ui.policy.pending') : statusText(draft.before))}</span></div>` +
      `<div class="panel-b">${view.mode === 'legacy' ? `<div class="notice">${esc(t('ui.policy.legacy'))} <a href="/subscriptions/settings">${esc(t('ui.policy.global'))}</a></div>` : ''}<form>` +
      `<fieldset class="policy-modes"><legend>${esc(t('ui.policy.mode'))}</legend>` +
      [['deny', 'denyHint'], ['selected', 'selectedHint'], ['all', 'allHint']].map(([mode,hint]) => `<label class="policy-mode"><input type="radio" name="mode" value="${mode}"${draft.mode === mode ? ' checked' : ''}><span><strong>${esc(modeText(mode))}</strong><small>${esc(t('ui.policy.' + hint))}</small></span></label>`).join('') + '</fieldset>' +
      `<fieldset class="policy-subscriptions" data-choices><legend>${esc(t('ui.policy.subscription'))}</legend>` + choices.map((c) => `<label class="policy-subscription"><input type="checkbox" name="subscription" value="${esc(c.id)}"${draft.selected.includes(c.id) ? ' checked' : ''}${!c.id ? ' disabled' : ''}><span>${esc(c.label)}${!c.id ? `<small>${esc(t('ui.policy.missingID'))}</small>` : ''}</span></label>`).join('') + '</fieldset>' +
      `<div class="policy-save"><span class="sub" data-dirty></span><div class="acts"><button type="button" class="btn danger" data-revoke>${esc(t('ui.policy.revoke'))}</button><button type="submit" class="btn primary">${esc(t('ui.policy.save'))}</button></div></div><p class="err" role="alert"></p></form>` +
      `<p class="sub">${esc(t('ui.policy.defaults'))}</p><details class="policy-notes"><summary>${esc(t('ui.policy.notes'))}</summary><p>${esc(t('ui.policy.scopeNote'))}</p><p>${esc(t('ui.policy.timing'))}</p></details></div>`;
    const form = root.querySelector('form'); let busy = false;
    // An absent legacy rule is not a denial. Force an explicit save if chosen.
    const changed = () => ['deny','selected','all'].includes(draft.mode) && (draftChanged(draft) || legacyUnset);
    const update = () => {
      const box = form.querySelector('[data-choices]'); box.hidden = draft.mode !== 'selected'; box.disabled = draft.mode !== 'selected';
      form.querySelector('[type=submit]').disabled = busy || !changed();
      form.querySelector('[data-dirty]').textContent = t(changed() ? 'ui.policy.unsaved' : 'ui.policy.savedState');
    };
    form.onchange = () => { draft.mode = form.elements.mode.value; draft.selected = [...form.querySelectorAll('[name=subscription]:checked')].map((c) => c.value); update(); };
    form.querySelector('[data-revoke]').onclick = () => { draft.mode = 'deny'; form.querySelector('[value=deny]').checked = true; update(); };
    form.onsubmit = async (e) => {
      e.preventDefault(); if (busy) return;
      try {
        const payload = policyPayload(scope,id,draft.mode,draft.selected); busy = true;
        form.querySelectorAll('input,button').forEach((el) => { el.disabled = true; });
        await savePolicy(ctx.api,draft.before,payload);
        ctx.toast(t('ui.policy.saved')); await mountObjectPolicy(ctx,root,scope,id);
      } catch (err) {
        busy = false; form.querySelectorAll('input,button').forEach((el) => { el.disabled = el.name === 'subscription' && !el.value; });
        form.querySelector('.err').textContent = err.message; update();
      }
    };
    update();
    const inspector = document.createElement('div');root.querySelector('.panel-b').append(inspector);
    void mountObjectInspector(ctx,inspector,scope,id);
  } catch (err) { root.innerHTML = `<p class="panel-b err">${esc(err.message)}</p>`; }
}

export async function mountGlobalPolicy(ctx, root) {
  const view = await ctx.api(POLICY_PATH);
  root.innerHTML = `<div class="panel-h"><div><h3>${esc(t('ui.policy.global'))}</h3><p class="sub">${esc(t('ui.policy.defaults'))}</p></div><span class="chip ${view.mode === 'legacy' ? 'warn' : 'ok'}">${esc(t(view.mode === 'legacy' ? 'ui.policy.pending' : 'ui.policy.strict'))}</span></div><div class="panel-b" data-review></div>`;
  const body = root.querySelector('[data-review]');
  if (view.mode !== 'legacy') { body.innerHTML = `<p>${esc(t('ui.policy.globalHint'))}</p><div class="acts"><a class="btn" href="/admin/users">${esc(t('ui.policy.byUser'))}</a><a class="btn" href="/nodes">${esc(t('ui.policy.byMachine'))}</a></div>`; return; }
  const review = view.migration;
  body.innerHTML = `<p>${esc(t('ui.policy.migrateHint'))}</p><form><div class="tw"><table class="t"><thead><tr><th>${esc(t('ui.policy.object'))}</th><th>${esc(t('ui.policy.after'))}</th></tr></thead><tbody>` + review.objects.map((o) => `<tr><td><b>${esc(o.label || o.id)}</b><br><small>${esc(t(o.scope === 'user' ? 'ui.policy.user' : 'ui.policy.node'))} · ${esc(o.id)}</small></td><td><select class="input" required data-key="${esc(o.key)}"><option value="">${esc(t('ui.policy.decision'))}</option><option value="retain">${esc(t('ui.policy.retain'))}</option><option value="revoke">${esc(t('ui.policy.revoke'))}</option></select></td></tr>`).join('') + `</tbody></table></div><div class="policy-save"><p class="sub">${esc(t('ui.policy.migrateNote'))}</p><button class="btn primary" type="submit">${esc(t('ui.policy.activate'))}</button></div><p class="err" role="alert"></p></form>`;
  const form = body.querySelector('form');
  form.onsubmit = (e) => {
    e.preventDefault(); const selects = [...form.querySelectorAll('select')];
    const retain = selects.filter((el) => el.value === 'retain').map((el) => el.dataset.key);
    ctx.confirm(t('ui.policy.activate'),esc(t('ui.policy.confirmMigration',{keep:retain.length,revoke:selects.length-retain.length})),t('ui.policy.activate'),async () => {
      form.querySelector('button').disabled = true;
      try { await ctx.api(POLICY_PATH,{method:'PUT',json:{action:'activate',revision:review.revision,retain}}); await mountGlobalPolicy(ctx,root); }
      catch(err) { form.querySelector('.err').textContent = err.message; form.querySelector('button').disabled = false; }
    });
  };
}

export async function mountSubscriptionAccess(ctx, root, uuid) {
  try {
    const [view, users, snapshot] = await Promise.all([ctx.api(POLICY_PATH),ctx.api('/v1/fleet/users'),ctx.api('/v1/nodes')]);
    const machines = await machineTargets(view,snapshot,ctx.api);
    if (!root.isConnected) return;
    const group = (scope,targets) => {
      const rows = targets.map((o) => {
        const entry = policyEntry(view,scope,o.id);
        const allowed = !o.error && (!entry ? view.mode === 'legacy' : !entry.error && (entry.all || !!uuid && entry.allow.includes(uuid)));
        const reason = o.error ? 'identityUnknown' : entry?.error ? 'ruleInvalid' : !entry ? (view.mode === 'legacy' ? 'legacyGrant' : 'notConfigured') : entry.all ? 'viaAll' : allowed ? 'viaSelected' : entry.allow.length ? 'notIncluded' : 'accessRevoked';
        return {...o, allowed, reason};
      });
      const allowed = rows.filter((o) => o.allowed), others = rows.filter((o) => !o.allowed);
      const row = (o) => `<div class="grant-row"><span class="grant-avatar${o.allowed ? ' granted' : ''}" aria-hidden="true">${ic(scope === 'user' ? 'users' : 'server')}</span><div class="grant-identity"><b>${esc(o.label)}</b><span>${esc(t('ui.policy.' + o.reason))}</span></div>` +
        (o.error ? `<span class="chip warn">${esc(t('ui.policy.needsReview'))}</span>` : `<a class="grant-edit" href="${scope === 'user' ? '/admin/users/' : '/machines/'}${encodeURIComponent(o.id)}${scope === 'node' ? '?from=nodes' : ''}" aria-label="${esc(t('ui.policy.manageObject', {name:o.label}))}">${esc(t('ui.policy.manageGrant'))}<span aria-hidden="true">↗</span></a>`) + '</div>';
      return `<section class="grant-group" aria-label="${esc(t(scope === 'user' ? 'ui.policy.grantedUsers' : 'ui.policy.grantedMachines'))}"><div class="grant-group-head"><h4>${esc(t(scope === 'user' ? 'ui.policy.grantedUsers' : 'ui.policy.grantedMachines'))}<span class="grant-count">${allowed.length}</span></h4><span class="grant-total">${esc(t('ui.policy.totalObjects',{n:rows.length}))}</span></div>` +
        `<div class="grant-list">${allowed.length ? allowed.map(row).join('') : `<div class="grant-empty">${esc(t(scope === 'user' ? 'ui.policy.noGrantedUsers' : 'ui.policy.noGrantedMachines'))}</div>`}</div>` +
        (others.length ? `<details class="grant-others"${!allowed.length ? ' open' : ''}><summary>${esc(t(others.some((o) => o.error) ? 'ui.policy.otherGrantCount' : 'ui.policy.notGrantedCount',{n:others.length}))}</summary><div>${others.map(row).join('')}</div></details>` : '') + '</section>';
    };
    root.innerHTML = `<div class="panel-h"><div><h3>${esc(t('ui.policy.accessSources'))}</h3><p class="grant-lead">${esc(t('ui.policy.accessLead'))}</p></div></div><div class="grant-groups">${group('user',userTargets(view,users))}${group('node',machines)}</div><div class="grant-footnote">${ic('shield')}<p>${esc(t('ui.policy.accessHint'))}</p></div>`;
  } catch(err) { root.innerHTML = `<p class="panel-b err">${esc(err.message)}</p>`; }
}

async function mountObjectInspector(ctx, root, scope, id) {
  root.innerHTML = `<details class="policy-notes"><summary>${esc(t('ui.policy.inspectTitle'))}</summary><div data-inspector></div></details>`;
  const details = root.querySelector('details');
  details.ontoggle = async () => {
    if (!details.open || details.dataset.loaded) return;
    details.dataset.loaded = '1'; const area = details.querySelector('[data-inspector]');
    try {
      const targets = scope === 'user' ? await machineTargets({},await ctx.api('/v1/nodes'),ctx.api) : userTargets({},await ctx.api('/v1/fleet/users'));
      area.innerHTML = `<form class="toolbar"><label class="f">${esc(t(scope === 'user' ? 'ui.policy.node' : 'ui.policy.user'))}<select class="input" required><option value="">${esc(t('ui.policy.optional'))}</option>` + targets.filter((o)=>!o.error).map((o)=>`<option value="${esc(o.id)}">${esc(o.label)}</option>`).join('') + `</select></label><button class="btn">${esc(t('ui.policy.inspect'))}</button></form><div data-result></div>`;
      const form = area.querySelector('form'),result = area.querySelector('[data-result]'); let sequence = 0;
      form.onchange = () => { sequence++;result.innerHTML=''; };
      form.onsubmit = async(e) => {
        e.preventDefault();const gen=++sequence;
        const other = form.querySelector('select').value;
        const query = new URLSearchParams({machine:scope==='node'?id:other,principal:scope==='user'?id:other});
        result.textContent = t('ui.loading');
        try { const out = await ctx.api(POLICY_PATH+'?'+query);if(gen===sequence&&result.isConnected)result.innerHTML=effectiveHTML(out.effective); }
        catch(err) { if(gen===sequence&&result.isConnected)result.textContent=err.message; }
      };
    } catch(err) { area.textContent=err.message;delete details.dataset.loaded; }
  };
}
