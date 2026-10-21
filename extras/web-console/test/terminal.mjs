import assert from 'node:assert/strict';
import { touchWheel } from '../src/shared/touch-wheel.ts';
import { webGoTarget } from '../src/shared/web-go.ts';

// C8X3: a finger moving down 3 cells scrolls back 3 wheel steps (wheel up, < 0)
assert.deepEqual(touchWheel(0, 60, 20), { steps: -3, carry: 0 });
// moving up scrolls forward; a partial cell is carried, never lost or doubled
assert.deepEqual(touchWheel(0, -50, 20), { steps: 2, carry: -10 });
assert.deepEqual(touchWheel(-10, -10, 20), { steps: 1, carry: 0 });
assert.deepEqual(touchWheel(0, 5, 20), { steps: 0, carry: 5 });
// a tiny or unmeasured cell never turns one drag into a flood of reports
assert.equal(touchWheel(0, 80, 0).steps, -10);
console.log('terminal: ok');
const wid = '33333333-3333-4333-8333-333333333333/44444444-4444-4444-8444-444444444444';
assert.equal(webGoTarget('web-go;w=' + wid), wid);
assert.equal(webGoTarget('cur;token=x;m=-;l=-;w=' + wid), null); // the thin loop's word, not ours
assert.equal(webGoTarget('web-go;w=../../etc'), null);
assert.equal(webGoTarget('web-go;w=' + wid + ';x=1'), null);
console.log('web-go: ok');
// BBVR: every scheme's ANSI colours read on its own background (WCAG AA) but
// its background twins; light / dark are the shared theme's page colours
import { readFileSync } from 'node:fs';
import { SCHEMES, MIN_CONTRAST, xtermTheme, contrast, schemeOf } from '../src/shared/term-theme.ts';
const css = readFileSync(new URL('../../fleet-theme/theme.css', import.meta.url), 'utf8');
assert.match(css, new RegExp(`--background: ${schemeOf('light').bg};`));
assert.match(css, new RegExp(`--fleet-bg: ${schemeOf('dark').bg};`));
assert.match(css, new RegExp(`--fleet-ink: ${schemeOf('dark').fg};`));
assert.equal(schemeOf('light').fg, schemeOf('dark').bg); // light's --foreground is --fleet-bg
assert.equal(new Set(SCHEMES.map((s) => s.id)).size, SCHEMES.length);
for (const s of SCHEMES) {
  assert.equal(s.ansi.length, 16, s.id);
  assert.ok(s.zh && s.en, s.id);
  assert.ok(contrast(s.fg, s.bg) >= 4.5, `${s.id} fg`);
  assert.ok(s.twins.length <= 2, `${s.id} twins`);
  s.ansi.forEach((c, i) => {
    if (s.twins.includes(i)) { assert.ok(contrast(c, s.bg) < 2.5, `${s.id} twin ${i} is not a background tone`); return; }
    assert.ok(contrast(c, s.bg) >= 4.5, `${s.id} ansi ${i} ${c}: ${contrast(c, s.bg).toFixed(2)}`);
  });
}
assert.ok(MIN_CONTRAST >= 4.5);
assert.equal(xtermTheme('follow', false).background, schemeOf('light').bg);
assert.equal(xtermTheme('follow', true).background, schemeOf('dark').bg);
assert.equal(xtermTheme('solarized-dark', false).background, '#002b36');
assert.equal(xtermTheme('gone', true).yellow, schemeOf('dark').ansi[3]);
assert.ok(contrast('#e5e510', schemeOf('light').bg) < 4.5); // xterm's default yellow: the unreadable one
console.log('term-theme: ok');
