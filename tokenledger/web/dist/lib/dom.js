// web/dist/lib/dom.js — DOM helpers: element builder, HTML escaping, tooltip.
// `el`, `escapeHTML`, `showTip`, `hideTip` are moved from the old <script>
// block of web/dist/index.html (pre-Task-11), with `$` split out alongside
// them since app.js / scope.js / now.js all need the same `document.querySelector`
// one-liner the old page kept inline. The SVG tag allowlist gains a few names
// (polyline, pattern, defs) that charts.js's new chart primitives need but the
// old page never drew.

export const $ = (sel, root = document) => root.querySelector(sel);

const SVG_TAGS = new Set([
  'g', 'rect', 'text', 'line', 'path', 'circle', 'svg', 'title',
  'polyline', 'pattern', 'defs',
]);

export const el = (tag, attrs = {}, ...kids) => {
  const n = document.createElementNS(
    tag === 'svg' || SVG_TAGS.has(tag) ? 'http://www.w3.org/2000/svg' : 'http://www.w3.org/1999/xhtml', tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === 'class') n.setAttribute('class', v);
    else if (k === 'text') n.textContent = v;
    else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
    else n.setAttribute(k, v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    n.appendChild(typeof kid === 'string' ? document.createTextNode(kid) : kid);
  }
  return n;
};

/** localizeShell rewrites the strings that live in index.html itself — the
 *  band labels, the operations summary, the two toolbar buttons' titles.
 *
 *  The markup keeps its English text as the WRITTEN default: it is what a
 *  reader gets before this runs, and it keeps index.html legible on its own.
 *  `data-i18n` names the key that replaces the text, `data-i18n-title` the key
 *  that replaces the title attribute. Called once, from app.js's boot. */
export function localizeShell(t, root = document) {
  for (const n of root.querySelectorAll('[data-i18n]')) n.textContent = t(n.dataset.i18n);
  for (const n of root.querySelectorAll('[data-i18n-title]')) n.setAttribute('title', t(n.dataset.i18nTitle));
}

export const escapeHTML = (s) => String(s).replace(/[&<>"']/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const tip = $('#tip');
export function showTip(evt, html) {
  if (!tip) return;
  tip.innerHTML = html;
  tip.style.opacity = '1';
  const pad = 14, r = tip.getBoundingClientRect();
  let x = evt.clientX + pad, y = evt.clientY + pad;
  if (x + r.width > innerWidth - 8) x = evt.clientX - r.width - pad;
  if (y + r.height > innerHeight - 8) y = evt.clientY - r.height - pad;
  tip.style.left = x + 'px';
  tip.style.top = y + 'px';
}
export const hideTip = () => { if (tip) tip.style.opacity = '0'; };
addEventListener('scroll', hideTip, { passive: true });
