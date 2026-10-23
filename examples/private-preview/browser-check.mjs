// Run while the Go relay test holds FLEET_PREVIEW_BROWSER_FIXTURE.
import fs from 'node:fs/promises';
import { chromium } from 'playwright';
const fixture = JSON.parse(await fs.readFile(process.env.FLEET_PREVIEW_BROWSER_FIXTURE || '/tmp/fleet-preview-browser.json', 'utf8'));
const source = new URL('./message.js', import.meta.url);
const original = await fs.readFile(source, 'utf8');
await fs.writeFile(source, "export const message = 'HMR initial';\n");
const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true,
  args: ['--no-proxy-server', `--host-resolver-rules=MAP hub.example.com:443 ${fixture.listen}, MAP *.preview.example.net:443 ${fixture.listen}`],
});
try {
  const context = await browser.newContext({ ignoreHTTPSErrors: true });
  await context.addCookies([{ name: '__Host-fleet-preview', value: fixture.cookie, url: fixture.preview, secure: true, httpOnly: true }]);
  const page = await context.newPage(), errors = [], frames = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('websocket', ws => ws.on('framereceived', f => frames.push(String(f.payload))));
  await page.goto(fixture.preview);
  await page.waitForFunction(() => document.querySelector('#hmr')?.textContent === 'HMR initial');
  // An update before the HMR handshake is not replayed by Vite.
  await new Promise((resolve, reject) => {
    const deadline = Date.now() + 10000;
    const timer = setInterval(() => {
      if (frames.some(f => f.includes('"connected"'))) { clearInterval(timer); resolve(); }
      else if (Date.now() > deadline) { clearInterval(timer); reject(Error('Vite WS did not connect')); }
    }, 50);
  });
  await page.evaluate(() => { window.hmrSentinel = 'same-document'; });
  await fs.writeFile(source, "export const message = 'HMR updated through private relay';\n");
  await page.waitForFunction(() => document.querySelector('#hmr')?.textContent === 'HMR updated through private relay');
  await page.locator('#post').click();
  await page.waitForFunction(() => document.querySelector('#api').textContent.includes('browser-post'));
  const receipt = await page.evaluate(() => ({ url: location.href, hmr: document.querySelector('#hmr').textContent, sentinel: window.hmrSentinel, api: document.querySelector('#api').textContent, sse: document.querySelector('#sse').textContent }));
  if (receipt.sentinel !== 'same-document' || errors.length || !frames.some(f => f.includes('"update"'))) throw Error(JSON.stringify({receipt, errors, frames}));
  for (const [name, width, height] of [['desktop',1440,900],['mobile',390,844]]) {
    await page.setViewportSize({width,height}); await page.screenshot({path:`/tmp/fleet-preview-hmr-${name}.png`});
  }
  console.log(JSON.stringify({...receipt, jsErrors:errors, hotUpdate:true}, null, 2));
} finally { await fs.writeFile(source, original); await browser.close(); }
