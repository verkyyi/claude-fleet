#!/bin/bash
# site-images.sh — draw the website's PNGs once (issue #3584): the two share
# cards (1200×630, 中文 / English), the PNG icons and favicon.ico, all from
# extras/fleet-theme's logo.svg, colours and fonts (the one theme, issue #3924). The output is
# committed under site/assets/; bin/site-build.sh only copies it, so the build
# needs no browser.
#
#   site-images.sh            write site/assets/{og/cover-zh.png,og/cover-en.png,
#                             icon-192.png,icon-512.png,apple-touch-icon.png,favicon.ico}
#
# Needs node and the `playwright` package with its Chromium (PLAYWRIGHT_DIR =
# the package's directory; default: the newest one npx has cached). A share card
# never states a time — the page's seconds come from the live drill only.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
A="$REPO/site/assets"
THEME="$REPO/extras/fleet-theme"
pw="${PLAYWRIGHT_DIR:-}"
if [ -z "$pw" ]; then
  pw="$(ls -dt "$HOME"/.npm/_npx/*/node_modules/playwright 2>/dev/null | head -1 || true)"
fi
[ -n "$pw" ] && [ -d "$pw" ] || { echo "site-images: no playwright package (set PLAYWRIGHT_DIR, or: npx -y playwright --version)" >&2; exit 2; }
mkdir -p "$A/og"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

node - "$pw" "$A" "$tmp" "$THEME" <<'JS'
const [pw, A, tmp, THEME] = process.argv.slice(2);
const { chromium } = require(pw);
const fs = require('fs');
const logo = fs.readFileSync(THEME + '/logo.svg', 'utf8').replace(/<title>.*?<\/title>/, '');
// the theme's own @font-face rules and fleet:tokens block — no colour or family typed here
const fonts = fs.readFileSync(THEME + '/fonts.css', 'utf8').replace(/url\(\.\/fonts\//g, `url(file://${THEME}/fonts/`)
  + fs.readFileSync(THEME + '/theme.css', 'utf8').match(/\/\* fleet:tokens \*\/([\s\S]*?)\/\* \/fleet:tokens \*\//)[1];
const card = (lang, h1, sub, chips) => `<!doctype html><html lang="${lang}"><meta charset="utf-8"><style>${fonts}
*{box-sizing:border-box;margin:0}
body{width:1200px;height:630px;background:var(--fleet-bg);color:var(--fleet-ink);font-family:var(--fleet-font-ui);position:relative;overflow:hidden;padding:84px 96px}
body::before{content:"";position:absolute;right:-220px;top:-160px;width:900px;height:900px;background:radial-gradient(closest-side,rgba(217,118,90,.26),transparent 70%)}
.b{display:flex;align-items:center;gap:20px;font:800 40px var(--fleet-font-display);position:relative}
.b svg{width:76px;height:76px}
h1{position:relative;margin-top:72px;font:800 ${lang === 'en' ? 76 : 70}px/1.12 var(--fleet-font-display);letter-spacing:${lang === 'en' ? '-.02em' : '0'}}
h1 em{font-style:normal;color:var(--fleet-clay)}
p{position:relative;margin-top:28px;font-size:32px;color:var(--fleet-ink-2)}
.c{position:absolute;left:96px;bottom:72px;display:flex;gap:14px;font:500 22px var(--fleet-font-mono);color:var(--fleet-sand)}
.c span{border:1px solid rgba(236,211,184,.3);background:rgba(236,211,184,.08);border-radius:999px;padding:8px 18px}
</style><div class="b">${logo}ClaudeFleet</div><h1>${h1}</h1><p>${sub}</p><div class="c">${chips.map(c => `<span>${c}</span>`).join('')}</div></html>`;
const icon = (size, rounded) => `<!doctype html><style>${fonts}*{margin:0}body{width:${size}px;height:${size}px;background:${rounded ? 'transparent' : 'var(--fleet-bg)'}}svg{width:${size}px;height:${size}px;display:block}</style>${rounded ? logo : logo.replace(/rx="15"/, 'rx="0"')}`;
(async () => {
  const b = await chromium.launch();
  const shot = async (htmlText, w, h, out, transparent) => {
    const p = await b.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });
    fs.writeFileSync(tmp + '/p.html', htmlText);
    await p.goto('file://' + tmp + '/p.html');
    await p.evaluate(() => document.fonts.ready);
    await p.screenshot({ path: out, omitBackground: !!transparent });
    await p.close();
  };
  await shot(card('zh-CN', 'Claude Code，<br><em>已经为你配好。</em>', '电脑或手机打开就能用。', ['官方 Claude Code', '开源 MIT', '可选自带订阅']), 1200, 630, A + '/og/cover-zh.png');
  await shot(card('en', 'Claude Code,<br><em>already set up for you.</em>', 'Open it on your laptop or phone and start working.', ['Official Claude Code', 'MIT open source', 'Own subscription optional']), 1200, 630, A + '/og/cover-en.png');
  await shot(icon(512, true), 512, 512, A + '/icon-512.png', true);
  await shot(icon(192, true), 192, 192, A + '/icon-192.png', true);
  await shot(icon(180, false), 180, 180, A + '/apple-touch-icon.png');
  for (const s of [16, 32, 48]) await shot(icon(s, true), s, s, `${tmp}/ico-${s}.png`, true);
  await b.close();
})().catch(e => { console.error(e); process.exit(1); });
JS

# favicon.ico: the three PNGs as they are (an ICO may hold PNG images).
python3 - "$tmp" "$A/favicon.ico" <<'PY'
import struct, sys
tmp, out = sys.argv[1], sys.argv[2]
imgs = [(s, open('%s/ico-%d.png' % (tmp, s), 'rb').read()) for s in (16, 32, 48)]
head = struct.pack('<HHH', 0, 1, len(imgs))
off, dirs, data = 6 + 16 * len(imgs), b'', b''
for s, png in imgs:
    dirs += struct.pack('<BBBBHHII', s, s, 0, 0, 1, 32, len(png), off)
    off += len(png)
    data += png
open(out, 'wb').write(head + dirs + data)
PY
ls -la "$A"/og "$A"/*.png "$A"/favicon.ico
