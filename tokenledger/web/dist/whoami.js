// web/dist/whoami.js — the one page header every human page shares
// (claude-fleet#1467): who is signed in, and the way out.
//
// Loaded by index.html, connect.html, sessions.html, nodes.html and
// credentials.html, which each carry a `<div id="whoami" class="whoami"
// hidden>` slot. It asks /v1/me once, hands the answer to lib/whoami.js, and
// draws the decision: the name top-right with how they got in under it, a
// <details> popover with 姓名 / 企微账号 / 登录方式, and 退出 as a plain
// same-origin form POST to /logout -- no script needed for the way out, the
// same as OPS. Fails closed: no answer, nothing drawn, the slot stays hidden.
import { whoami, strings } from './lib/whoami.js';

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function render(root, me) {
  const lang = document.documentElement.getAttribute('lang') || 'zh-CN';
  const v = whoami(me, lang);
  if (!v) { root.hidden = true; root.replaceChildren(); return; }
  const s = strings(lang);
  const rows = [[s.name, v.name, false]];
  if (v.person) rows.push([s.userid, v.person, true]);
  rows.push([s.via, v.via, false]);
  root.innerHTML = `<details class="whoami-fold">
    <summary class="whoami-user" title="${esc(s.title)}">
      <span class="whoami-name">${esc(v.name)}</span><span class="whoami-sub">${esc(v.sub)}</span>
    </summary>
    <div class="whoami-panel">
      <dl>${rows.map(([k, val, mono]) => `<dt>${esc(k)}</dt><dd${mono ? ' class="mono"' : ''}>${esc(val)}</dd>`).join('')}</dl>
      ${v.logout ? `<form method="post" action="/logout" class="whoami-logout"><button type="submit">${esc(s.logout)}</button></form>` : ''}
    </div>
  </details>`;
  root.hidden = false;
  // A click anywhere else closes the popover, the way a popover is expected
  // to behave; a <details> on its own only closes from its summary.
  document.addEventListener('click', (e) => {
    const fold = root.querySelector('.whoami-fold');
    if (fold && fold.open && !fold.contains(e.target)) fold.open = false;
  });
}

async function boot() {
  const root = document.getElementById('whoami');
  if (!root) return;
  let me = null;
  try {
    // Accept JSON, not HTML: a signed-out browser gets the honest 401 here
    // rather than a login redirect it cannot follow from a fetch.
    const r = await fetch('/v1/me', { credentials: 'same-origin', cache: 'no-store', headers: { Accept: 'application/json' } });
    if (r.ok) me = await r.json();
  } catch { me = null; }
  render(root, me);
}

boot();
