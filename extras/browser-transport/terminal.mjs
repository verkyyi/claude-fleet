// Built customer console + actual hub/node PTY. Output is an isolated byte
// probe. Native Fleet/agent interaction and OS IME are explicitly not simulated
// into passing results here. All screenshots and trace are CI artifacts.
import assert from 'node:assert/strict'
import { mkdir } from 'node:fs/promises'
import { chromium } from 'playwright'

const origin = process.env.FLEET_TEST_ORIGIN
const cookie = process.env.FLEET_TEST_COOKIE
const worker = process.env.FLEET_TEST_WORKER
assert(origin && cookie && worker)
const dir = 'evidence/terminal'
await mkdir(dir, { recursive: true })
const browser = await chromium.launch()
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: 'en-US' })
const eq = cookie.indexOf('=')
await context.addCookies([{ name: cookie.slice(0, eq), value: cookie.slice(eq + 1), url: origin }, { name: 'cf_lang', value: 'en', url: origin }])
await context.tracing.start({ screenshots: true, snapshots: true, sources: true })
const page = await context.newPage()
const failures = []
page.on('pageerror', e => failures.push(e.message))
const received = []
// Instrument the outgoing frame boundary without changing xterm or transport.
await context.addInitScript(() => {
  window.__terminalBytes = []
  const capture = data => {
    if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) window.__terminalBytes.push(Array.from(new Uint8Array(data.buffer || data, data.byteOffset || 0, data.byteLength)))
  }
  const ws = WebSocket.prototype.send
  WebSocket.prototype.send = function(data) { capture(data); return ws.call(this, data) }
  const dc = RTCDataChannel.prototype.send
  RTCDataChannel.prototype.send = function(data) { capture(data); return dc.call(this, data) }
})
const ready = async () => {
  await page.getByRole('button', { name: 'Fleet menu', exact: true }).waitFor()
  await page.waitForFunction(() => ![...document.querySelectorAll('button')].find(b => b.textContent === 'Fleet menu')?.disabled)
  await page.getByText('Isolated PTY input probe - not native Fleet', { exact: false }).waitFor()
}
const bytes = async () => page.evaluate(() => new TextDecoder().decode(new Uint8Array(window.__terminalBytes.flat())))
const clear = async () => page.evaluate(() => { window.__terminalBytes = [] })
const input = () => page.locator('.xterm-helper-textarea')
try {
  await page.goto(`${origin}/app/sessions`)
  await page.getByRole('link', { name: 'Terminal', exact: true }).first().click()
  await ready()
  assert.equal(new URL(page.url()).searchParams.get('worker'), worker)
  await clear()
  await page.getByRole('button', { name: 'Fleet menu', exact: true }).click()
  await page.getByRole('button', { name: 'Open shell', exact: true }).click()
  await page.getByRole('button', { name: 'Open shell', exact: true }).click()
  await input().press('Control+BracketRight')
  await input().press('p')
  await input().press('Control+c')
  await input().press('Shift+Tab')
  await input().press('ArrowUp')
  await input().press('Escape')
  const keys = await bytes()
  assert.equal(keys, '\x1b[927~\x1c\x1c\x1dp\x03\x1b[Z\x1b[A\x1b')
  received.push('menu button, shell/return, Ctrl+] p, Ctrl+C, Shift+Tab, arrows and Esc: exact bytes')
  await clear()
  const paste = '中文、日本語、한국어 ASCII 🙂 e\u0301\nsecond line'
  await input().evaluate((el, text) => {
    const dt = new DataTransfer(); dt.setData('text/plain', text)
    el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }))
  }, paste)
  assert.equal(await bytes(), '\x1b[200~' + paste.replaceAll('\n', '\r') + '\x1b[201~')
  received.push('CJK/multiline paste: xterm requested bracketed paste sent once')
  await clear()
  // Dispatch (not press) reserved keys so the test does not close its own tab.
  const reserved = await input().evaluate(el => ['p', 'w', 'l', 't', 'r'].map(key => {
    const e = new KeyboardEvent('keydown', { key, ctrlKey: true, bubbles: true, cancelable: true })
    el.dispatchEvent(e); return e.defaultPrevented
  }))
  assert(reserved.every(x => !x))
  assert.equal(await bytes(), '')
  await page.setViewportSize({ width: 1200, height: 780 })
  await page.waitForTimeout(100)
  await page.screenshot({ path: `${dir}/session-light.png` })
  await page.evaluate(() => { document.documentElement.dataset.theme = 'dark' })
  await page.screenshot({ path: `${dir}/session-dark.png` })
  // Route leave must release the attachment; no pending composition can travel
  // into the next target. Native OS IME candidate behavior remains manual.
  await input().dispatchEvent('compositionstart', { data: '未提交' })
  await page.getByRole('link', { name: 'Sessions', exact: true }).last().click()
  await page.getByRole('link', { name: 'My Terminal', exact: true }).last().click()
  await ready()
  assert.equal(new URL(page.url()).searchParams.has('worker'), false)
  assert.equal(await bytes(), '')
  received.push('route cleanup during synthetic composition: no stale text to personal target')
  await page.getByRole('link', { name: 'Sessions', exact: true }).last().click()
  // Empty list keeps the personal entry. Isolated fixture only, API unchanged.
  await page.route('**/v1/fleet/sessions*', route => route.fulfill({ json: { sessions: [] } }))
  await page.route('**/v1/fleet/stream*', route => route.abort())
  await page.reload()
  await page.getByText('No sessions yet', { exact: true }).waitFor()
  await page.getByRole('link', { name: 'My Terminal', exact: true }).last().click()
  await ready()
  for (const state of ['unsupported', 'offline', 'maintenance']) {
    await page.route('**/v1/term/home', route => route.fulfill({ json: { state } }))
    await page.reload()
    await page.getByRole('alert').waitFor()
    assert.equal(await page.locator('.xterm-helper-textarea').count(), 0)
    await page.unroute('**/v1/term/home')
  }
  await page.route('**/v1/term/home', route => route.fulfill({ status: 401, json: { code: 'login' } }))
  await page.reload()
  await page.getByRole('link', { name: 'Sign in', exact: true }).waitFor()
  assert.deepEqual(failures, [])
  console.log(JSON.stringify({ browser: browser.version(), received, nativeFleet: 'pending lifecycle integration', osIME: 'manual pending', safari: 'manual pending' }))
} finally {
  await context.tracing.stop({ path: `${dir}/chromium.zip` })
  await context.close()
  await browser.close()
}
