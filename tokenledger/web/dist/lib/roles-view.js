// web/dist/lib/roles-view.js — 「角色与规则」 on /config (claude-fleet#2787,
// EPIC #2781 C6). The hub merges (GET /v1/fleet/person-bundle/roles?merged=1,
// internal/rolemerge — the same answer `fleet role show --sources` prints);
// this file only draws it and edits the person's layer: every change is the
// whole person bundle PUT back with its base version, so a page and a session
// editing at once never overwrite each other (409 → read again).
//
// A role's layer is stored as {front: {<field>: …}, body: "…"} — one of the
// forms bin/fleet-role.py's overlay_of reads; the rule table's as a list of
// rows {n, role, cond, action, tier, keywords}, replacing a built-in row by
// number (tier off = removed; a new rule numbers from 100).
import { esc, ic } from './shell.js';
import { t } from './i18n.js';

export const ROLES = Object.freeze(['orchestrator', 'steward', 'worker', 'epic-driver']);
export const FIELD_ORDER = Object.freeze(['model', 'effort', 'permissionMode', 'description', 'tools', 'disallowedTools', 'skills', 'mcpServers', 'hooks', 'memory']);
export const MODELS = Object.freeze(['fable', 'opus', 'sonnet', 'haiku']);
export const EFFORTS = Object.freeze(['low', 'medium', 'high', 'xhigh', 'max']);
export const MODES = Object.freeze(['default', 'acceptEdits', 'auto', 'dontAsk', 'plan', 'bypassPermissions']);
export const MEMORY = Object.freeze(['user', 'project', 'local']);
export const TIERS = Object.freeze(['auto', 'default', 'ask', 'off']);
const SELECTS = { model: MODELS, effort: EFFORTS, permissionMode: MODES, memory: MEMORY };
const LISTS = ['tools', 'disallowedTools', 'skills'];
const HEADS = ['## （你加的）', '## （本机加的）'];

const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));

/** sayLabel is one source label as a person reads it (fleet-role.py say_source). */
export function sayLabel(l) {
  if (l === 'agents') return t('ui.roles.srcBuiltin');
  if (l === 'lock') return '🔒';
  if (typeof l === 'string' && l.startsWith('person:')) return t('ui.roles.srcYours', { v: l.slice(7) });
  if (l === 'local') return t('ui.roles.srcLocal');
  return String(l);
}

/** layerOf is the person's layer for role as {front, body}, a copy. */
export function layerOf(view, role) {
  const l = view && view.roles && view.roles[role] && view.roles[role].layer;
  return { front: isObj(l && l.front) ? clone(l.front) : {}, body: (l && typeof l.body === 'string') ? l.body : '' };
}

/** setField is layer with field k set to v (undefined = taken out: 还原). */
export function setField(layer, k, v) {
  const out = { front: { ...layer.front }, body: layer.body || '' };
  if (v === undefined) delete out.front[k]; else out.front[k] = v;
  return out;
}

/** layerEmpty: nothing a merge would use. */
export const layerEmpty = (l) => !Object.keys(l.front).some((k) => k !== 'name') && !String(l.body || '').trim();

/** withRoleLayer is bundle (a copy) with role's layer replaced; an empty
 *  layer takes the role out, and no role left takes `roles` out. */
export function withRoleLayer(bundle, role, layer) {
  const b = clone(isObj(bundle) ? bundle : {});
  const roles = isObj(b.roles) ? b.roles : {};
  if (layerEmpty(layer)) delete roles[role];
  else roles[role] = layer.body ? { front: layer.front, body: layer.body } : { front: layer.front };
  if (Object.keys(roles).length) b.roles = roles; else delete b.roles;
  return b;
}

/** listEdit applies "+X" / "-X" / "X" to a layer's list field: an item the
 *  layer already says the opposite of is replaced, never doubled. */
export function listEdit(layer, k, word) {
  word = String(word || '').trim();
  if (!word || word === '+' || word === '-') return layer;
  const cur = Array.isArray(layer.front[k]) ? [...layer.front[k]]
    : (typeof layer.front[k] === 'string' && layer.front[k] ? layer.front[k].split(',').map((s) => s.trim()).filter(Boolean) : []);
  const name = word.replace(/^[+-]/, '');
  const kept = cur.filter((x) => x.replace(/^[+-]/, '') !== name);
  return setField(layer, k, [...kept, word.startsWith('-') ? word : (word.startsWith('+') ? word : '+' + word)]);
}

/** listUndo takes one of the layer's own list items back out. */
export function listUndo(layer, k, item) {
  const cur = Array.isArray(layer.front[k]) ? layer.front[k].filter((x) => x !== item) : [];
  return setField(layer, k, cur.length ? cur : undefined);
}

/** setBody is the layer with its appended paragraph replaced ('' = none). */
export function setBody(layer, text) {
  return { front: { ...layer.front }, body: String(text || '').trim() ? String(text).replace(/\s+$/, '') + '\n' : '' };
}

// ── the rule table ──────────────────────────────────────────────────────

/** personRows reads the bundle's `rules` (a list of rows, or a Markdown table
 *  in conf/role-rules.default.md's format) as row objects. */
export function personRows(rules) {
  if (Array.isArray(rules)) {
    return rules.map((r) => (Array.isArray(r)
      ? { n: Number(r[0]), role: r[1], cond: r[2], action: r[3], tier: r[4], keywords: String(r[5] || '').split(/[,，、]/).map((s) => s.trim()).filter(Boolean) }
      : { ...r, n: Number(r.n) }));
  }
  if (typeof rules !== 'string') return [];
  const out = [];
  let inside = false;
  for (const ln of rules.split('\n')) {
    const s = ln.trim();
    if (!s.startsWith('|')) { inside = false; continue; }
    const c = s.replace(/^\|/, '').replace(/\|$/, '').split('|').map((x) => x.trim());
    if (c[0] === '编号') { inside = true; continue; }
    if (!inside || /^[-: ]*$/.test(c.join(''))) continue;
    out.push({ n: Number(c[0]), role: c[1], cond: c[2], action: c[3], tier: c[4], keywords: String(c[5] || '').split(/[,，、]/).map((x) => x.trim()).filter(Boolean) });
  }
  return out;
}

function withRows(bundle, rows) {
  const b = clone(isObj(bundle) ? bundle : {});
  rows.sort((a, z) => a.n - z.n);
  if (rows.length) b.rules = rows; else delete b.rules;
  return b;
}

/** setRuleTier is bundle with rule `row` (a merged row) at `tier` in the
 *  person's layer — the whole row copied, so it stands on its own. */
export function setRuleTier(bundle, row, tier) {
  const rows = personRows(bundle && bundle.rules).filter((r) => r.n !== Number(row.n));
  rows.push({ n: Number(row.n), role: row.role, cond: row.cond, action: row.action, tier, keywords: [...(row.keywords || [])] });
  return withRows(bundle, rows);
}

/** resetRule takes rule n out of the person's layer: 还原 to the built-in. */
export function resetRule(bundle, n) {
  return withRows(bundle, personRows(bundle && bundle.rules).filter((r) => r.n !== Number(n)));
}

// ── drawing ─────────────────────────────────────────────────────────────

const roleName = (r) => t('ui.roles.r.' + r);
const fmtVal = (v) => (v == null || v === '' ? '—' : typeof v === 'string' ? v : JSON.stringify(v));
const mine = (srcs) => (srcs || []).some((s) => String(s).startsWith('person:'));

/** roleCard is one of the four cards. */
export function roleCard(role, r, on) {
  const f = (r && r.fields) || {};
  const n = (r && r.changed) || 0;
  const line = [f.model, f.effort].filter(Boolean).join(' · ') || '—';
  return `<button class="rc${on ? ' on' : ''}" data-role="${esc(role)}" aria-pressed="${on}"><b>${esc(roleName(role))}</b>` +
    `<small class="mono">${esc(line)}</small>` +
    (r && r.problem ? `<span class="chip bad">${ic('alert')}${esc(t('ui.roles.unused'))}</span>`
      : n ? `<span class="chip you">${esc(t('ui.roles.changed', { n }))}</span>` : `<span class="chip">${esc(t('ui.roles.allBuiltin'))}</span>`) + '</button>';
}

function srcChip(srcs, locked) {
  const list = (srcs || ['agents']).filter((s) => s !== 'lock');
  const txt = list.map(sayLabel).join(' + ');
  return `<span class="chip${mine(srcs) ? ' you' : ''}">${esc(txt)}</span>` + (locked ? `<span class="chip" title="${esc(t('ui.roles.lockedTip'))}">${ic('lock')}${esc(t('ui.roles.locked'))}</span>` : '');
}

function listCell(k, base, merged, layer) {
  const b = Array.isArray(base) ? base.map(String) : [];
  const m = Array.isArray(merged) ? merged.map(String) : [];
  const own = Array.isArray(layer.front[k]) ? layer.front[k] : [];
  let html = '';
  if (k === 'tools' && !m.length) html += `<span class="chip">${esc(t('ui.roles.allTools'))}</span>`;
  for (const x of m) html += `<span class="chip${b.includes(x) ? '' : ' you'}">${esc(x)}</span>`;
  for (const x of b) if (!m.includes(x)) html += `<span class="chip gone">${esc(x)}</span>`;
  if (own.length) {
    html += `<div class="own">${esc(t('ui.roles.yourEdits'))} ` + own.map((x) => `<button class="chip you" data-undo="${esc(k)}" data-item="${esc(x)}" title="${esc(t('ui.roles.undoItem'))}">${esc(x)} ${ic('x')}</button>`).join('') + '</div>';
  }
  return html;
}

function control(k, v, has, builtin) {
  if (SELECTS[k]) {
    // the first option is the built-in value: choosing it is 还原
    const opts = SELECTS[k].includes(v) || !v ? SELECTS[k] : [v, ...SELECTS[k]];
    return `<select data-field="${esc(k)}" aria-label="${esc(k)}"><option value=""${has ? '' : ' selected'}>${esc(t('ui.roles.builtinOpt', { v: builtin || '—' }))}</option>` +
      opts.map((o) => `<option value="${esc(o)}"${has && o === v ? ' selected' : ''}>${esc(o)}</option>`).join('') + '</select>';
  }
  if (k === 'description') return `<button class="btn sm" data-edit="description">${esc(t('ui.roles.edit'))}</button>`;
  if (LISTS.includes(k)) return `<form class="addf" data-list="${esc(k)}"><input name="w" placeholder="+X / -X" aria-label="${esc(k)}" autocomplete="off"><button class="btn sm">${esc(t('ui.roles.apply'))}</button></form>`;
  return has ? '' : `<span class="sub">${esc(t('ui.roles.bySession'))}</span>`;
}

/** splitBody marks the parts of a merged body a layer appended. */
export function splitBody(body) {
  const s = String(body || '');
  let at = -1;
  for (const h of HEADS) { const i = s.indexOf('\n' + h + '\n'); if (i >= 0 && (at < 0 || i < at)) at = i; }
  return at < 0 ? [s, ''] : [s.slice(0, at), s.slice(at)];
}

/** roleDetail is the selected role: each field as merged, where it came
 *  from, and how to change or put it back. */
export function roleDetail(role, r, layer) {
  if (!r) return '';
  const f = r.fields || {};
  const base = (r.base && r.base.front) || {};
  const src = r.sources || {};
  const locked = r.locked || [];
  let rows = '';
  if (r.problem) rows += `<div class="ghostrow err">${ic('alert')} ${esc(t('ui.roles.problem', { why: r.problem }))}</div>`;
  if (!r.fields) {
    rows += `<div class="ghostrow">${esc(t('ui.roles.noBuiltin'))}</div>`;
  }
  const keys = FIELD_ORDER.filter((k) => k in f || k in base || k in layer.front || SELECTS[k] && k !== 'memory');
  for (const k of keys) {
    const has = k in layer.front;
    let val;
    if (LISTS.includes(k)) val = listCell(k, base[k], f[k], layer);
    else if (has && r.fields && JSON.stringify(base[k]) !== JSON.stringify(f[k])) val = `<s>${esc(fmtVal(base[k]))}</s> → <b class="youtxt">${esc(fmtVal(f[k]))}</b>`;
    else val = `<span class="mono">${esc(fmtVal(r.fields ? f[k] : layer.front[k]))}</span>`;
    rows += `<div class="rrow"><div class="k mono">${esc(k)}</div><div class="v">${val}</div>` +
      `<div class="s">${srcChip(src[k] || (has ? ['person:'] : ['agents']), locked.includes(k))}</div>` +
      `<div class="a">${control(k, f[k] !== undefined ? f[k] : layer.front[k], has, base[k])}${has ? `<button class="btn sm ghost" data-reset="${esc(k)}">${esc(t('ui.roles.reset'))}</button>` : ''}</div></div>`;
  }
  const [own, added] = splitBody(r.fields ? r.body : '');
  rows += `<div class="rrow body"><div class="k mono">body</div><div class="v"><details><summary>${esc(t('ui.roles.bodySummary'))} ${srcChip(src.body, false)}</summary>` +
    `<pre class="prompt">${esc(own)}${added ? `<span class="add">${esc(added)}</span>` : ''}</pre></details>` +
    `<label class="sub" for="rbody">${esc(t('ui.roles.bodyAdd'))}</label><textarea id="rbody" rows="3" placeholder="${esc(t('ui.roles.bodyPh'))}">${esc(layer.front.body === 'replace' ? '' : layer.body)}</textarea>` +
    (layer.front.body === 'replace' ? `<div class="ghostrow err">${ic('alert')} ${esc(t('ui.roles.bodyReplaced'))}</div>` : '') +
    `</div><div class="s"></div><div class="a"><button class="btn sm primary" data-save-body>${esc(t('ui.roles.save'))}</button>${layer.body ? `<button class="btn sm ghost" data-reset-body>${esc(t('ui.roles.reset'))}</button>` : ''}</div></div>`;
  return `<div class="rdetail"><div class="rdetail-h"><h4>${esc(roleName(role))} <span class="mono sub">agents/${esc(role)}.md</span></h4></div>${rows}</div>`;
}

/** rulesTable is the merged table, plus the person's rows the merge dropped
 *  (tier off), each with its tier to change and 还原 for the person's own. */
export function rulesTable(rules, bundle) {
  const rows = (rules && rules.rows) || [];
  const own = personRows(bundle && bundle.rules);
  const ownN = new Set(own.map((r) => r.n));
  const off = own.filter((r) => r.tier === 'off');
  const tierSel = (r) => `<select data-rule="${esc(r.n)}" aria-label="${esc(t('ui.roles.tier'))} ${esc(r.n)}">` +
    TIERS.map((x) => `<option value="${x}"${x === r.tier ? ' selected' : ''}>${esc(t('ui.roles.tier.' + x))}</option>`).join('') + '</select>';
  const tr = (r, gone) => `<tr class="${ownN.has(r.n) ? 'you' : ''}${gone ? ' gone' : ''}"><td class="n mono">${esc(r.n)}</td><td>${esc(roleName(r.role))}</td>` +
    `<td>${esc(r.cond)}<div class="sub">→ ${esc(r.action)}</div>${(r.keywords || []).length ? `<div class="sub mono">${esc(r.keywords.join(', '))}</div>` : ''}</td>` +
    `<td>${tierSel(r)}${ownN.has(r.n) ? `<button class="btn sm ghost" data-rule-reset="${esc(r.n)}">${esc(t('ui.roles.reset'))}</button>` : ''}</td></tr>`;
  const probs = ((rules && rules.problems) || []).map((p) => `<div class="ghostrow err">${ic('alert')} ${esc(p)}</div>`).join('');
  return probs + `<div class="tablewrap"><table class="rules"><thead><tr><th>#</th><th>${esc(t('ui.roles.role'))}</th><th>${esc(t('ui.roles.when'))}</th><th>${esc(t('ui.roles.tier'))}</th></tr></thead><tbody>` +
    rows.map((r) => tr(r, false)).join('') + off.map((r) => tr(r, true)).join('') + '</tbody></table></div>';
}
