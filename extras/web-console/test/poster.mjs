// poster.mjs — the 试用海报's words and layout (claude-fleet CHZ0), run on the
// production module (Node strips the types): both languages say the plan the
// code gives, an approval code says it is approved first, and every line the
// poster draws — at either language, with the longest words — stays inside the
// 1080 × 1440 picture and above its footer rule.
import assert from 'node:assert/strict';
import { drawPoster, H, posterWords, W, wrap } from '../src/admin/poster.ts';

const DEF = 'days=7,tokens=3000000,sessions=1';
const code = { channel: '朋友圈', terms: '', approval: false, until: '0001-01-01T00:00:00Z' };

// words
let zh = posterWords(code, 'zh', DEF);
assert.equal(zh.plan, '7 天免费试用');
assert.equal(zh.tokens, '含 300 万 tokens 额度');
assert.equal(zh.until, '');
assert.match(zh.how, /不用审批/);
let en = posterWords({ ...code, terms: 'days=14,tokens=5000000' }, 'en', DEF);
assert.equal(en.plan, '14-day free trial');
assert.equal(en.tokens, '5M tokens included');
const ap = posterWords({ ...code, approval: true, until: '2026-11-29T16:00:00Z' }, 'zh', DEF);
assert.match(ap.steps[1], /通过后/);
assert.doesNotMatch(ap.how, /不用审批/);
assert.equal(ap.until, '本码 2026-11-30 前有效'); // Beijing's day
assert.equal(posterWords({ ...code, terms: 'sessions=1' }, 'en', DEF).plan, 'Free trial');

// wrap: a 中文 character breaks, a Latin word does not, a mark never starts a line
const m = (s) => s.length * 10;
assert.deepEqual(wrap(m, '说一句话，它替你做完', 50), ['说一句话，', '它替你做完']);
assert.deepEqual(wrap(m, 'Claude Code always on', 120), ['Claude Code', 'always on']);
for (const l of wrap(m, '一二三四，五六七八。九十', 40)) assert.doesNotMatch(l, /^[，。]/);

// layout: a recorder standing in for the canvas, text measured wide (a 中文
// character a full em, Latin 0.6 em) so the bound holds with room to spare
const drawn = [];
const fake = () => {
  const g = {
    font: '10px x', fillStyle: '', strokeStyle: '', lineWidth: 1, lineCap: '', lineJoin: '', textBaseline: '', textAlign: 'left', imageSmoothingEnabled: true,
    measureText(s) {
      const px = Number(/(\d+)px/.exec(g.font)[1]);
      return { width: [...s].reduce((a, ch) => a + (/[^\x00-\xff]/.test(ch) ? px : px * 0.6), 0) };
    },
    fillText(s, x, y) { drawn.push({ s, x, y, w: g.measureText(s).width, align: g.textAlign }); },
    createRadialGradient: () => ({ addColorStop() {} }), createLinearGradient: () => ({ addColorStop() {} }),
  };
  for (const k of ['fillRect', 'beginPath', 'moveTo', 'lineTo', 'arc', 'roundRect', 'fill', 'stroke', 'drawImage', 'save', 'restore']) g[k] = () => {};
  return g;
};
const th = Object.fromEntries(['bg', 'surface', 'line', 'ink', 'ink2', 'muted', 'clay', 'clayHi', 'clayDeep', 'sand', 'onClay', 'display', 'ui', 'mono'].map((k) => [k, '#000000']));
for (const words of [zh, en, ap, posterWords({ ...code, approval: true, until: '2026-11-29T16:00:00Z' }, 'en', DEF)]) {
  drawn.length = 0;
  drawPoster(fake(), words, null, th);
  for (const d of drawn) {
    const left = d.align === 'center' ? d.x - d.w / 2 : d.align === 'right' ? d.x - d.w : d.x;
    assert.ok(left >= 40 && left + d.w <= W - 40, `"${d.s}" runs off the side (${left}..${left + d.w})`);
    assert.ok(d.y > 0 && d.y <= H - 40, `"${d.s}" runs off the bottom (${d.y})`);
  }
  const footer = drawn.filter((d) => d.s === words.asks || d.s === words.until).map((d) => d.y);
  const body = drawn.filter((d) => d.s !== words.asks && d.s !== words.until);
  assert.ok(Math.max(...body.map((d) => d.y)) < Math.min(...footer) - 70, 'the steps run into the footer');
  for (const s of [words.head[0], words.head[1], words.scan, ...words.steps.map((x) => x.split(/\s/)[0])]) {
    assert.ok(drawn.some((d) => d.s.includes(s.slice(0, 3))), `"${s}" is not drawn`);
  }
}
console.log('poster: words, wrap and layout OK');
